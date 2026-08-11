#!/usr/bin/python3
"""Generate the deterministic v0.1 patch and upstream inventory."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
from typing import Any, Dict, Iterable, List


PROJECT_REPOSITORY = "https://github.com/NorthStarXyzz/PlayCover-VRChat-Patcher"
PLAYTOOLS_REPOSITORY = "https://github.com/PlayCover/PlayTools.git"
EXPECTED_PLAYTOOLS_COMMIT = "f17b9211211fb4cf5652d4930ea82613ee3c92a5"
EXPECTED_PLAYTOOLS_RESOLUTION_SHA256 = "861745ad8d24152ba8e00f426164b618e50a131e164eb17499d7d9f82069caf6"
EXPECTED_PLAYTOOLS_RESOLUTION = {
    "originHash": "dd4b3820190814028b7a4ca2c138f5215df145753ed2a434b6bb89422721bd74",
    "pins": [
        {
            "identity": "swift-atomics",
            "kind": "remoteSourceControl",
            "location": "https://github.com/apple/swift-atomics.git",
            "state": {
                "revision": "0442cb5a3f98ab802acb777929fdb446bda11a34",
                "version": "1.3.1",
            },
        },
        {
            "identity": "swift-collections",
            "kind": "remoteSourceControl",
            "location": "https://github.com/apple/swift-collections.git",
            "state": {
                "revision": "a0cb0954ecb21e4e31b0070e6ed5674e8556685a",
                "version": "1.6.0",
            },
        },
        {
            "identity": "swift-nio",
            "kind": "remoteSourceControl",
            "location": "https://github.com/apple/swift-nio",
            "state": {
                "revision": "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b",
                "version": "2.101.3",
            },
        },
        {
            "identity": "swift-system",
            "kind": "remoteSourceControl",
            "location": "https://github.com/apple/swift-system.git",
            "state": {
                "revision": "704705c5c51156ede21172a38654d522ce487074",
                "version": "1.8.0",
            },
        },
        {
            "identity": "swordrpc",
            "kind": "remoteSourceControl",
            "location": "https://github.com/PlayCover/SwordRPC",
            "state": {
                "branch": "main",
                "revision": "4403152a16a040d8448d33d65ad5a034c9d1fa1b",
            },
        },
    ],
    "version": 3,
}
ALPHA_TAG = re.compile(r"^v0\.1\.0-alpha\.[1-9][0-9]*$")


class InventoryError(RuntimeError):
    pass


def git(repo: pathlib.Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repo), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise InventoryError("git {} failed: {}".format(" ".join(arguments), detail))
    return result.stdout.strip()


def require_clean_checkout(repo: pathlib.Path, commit: str) -> None:
    head = git(repo, "rev-parse", "HEAD")
    if head != commit:
        raise InventoryError("requested commit does not match HEAD")
    dirty = git(repo, "status", "--porcelain=v1", "--untracked-files=all")
    if dirty:
        raise InventoryError("refusing metadata generation from a dirty checkout")


def require_tracked_regular_file(repo: pathlib.Path, relative: str) -> pathlib.Path:
    path = repo / relative
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise InventoryError("missing release input: {}".format(relative)) from error
    if not stat.S_ISREG(mode) or path.is_symlink():
        raise InventoryError("release input is not a regular non-symlink file: {}".format(relative))
    git(repo, "ls-files", "--error-unmatch", "--", relative)
    return path


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tracked_under(repo: pathlib.Path, prefix: str) -> Iterable[str]:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repo), "ls-files", "-z", "--", prefix],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise InventoryError(result.stderr.decode("utf-8", "replace").strip())
    for raw_path in result.stdout.split(b"\0"):
        if raw_path:
            yield raw_path.decode("utf-8")


def load_manifest(repo: pathlib.Path, relative: str) -> Dict[str, Any]:
    path = require_tracked_regular_file(repo, relative)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError("invalid compatibility manifest: {}".format(relative)) from error
    for key in ("patchID", "supportState", "playCover", "vrChat", "host"):
        if key not in value:
            raise InventoryError("{} is missing {}".format(relative, key))
    return value


def parse_series(repo: pathlib.Path) -> List[Dict[str, Any]]:
    series_path = require_tracked_regular_file(repo, "PlayCoverPatch/series")
    patches: List[Dict[str, Any]] = []
    seen = set()
    for line_number, raw_line in enumerate(series_path.read_text(encoding="utf-8").splitlines(), 1):
        name = raw_line.strip()
        if not name or name.startswith("#"):
            continue
        candidate = pathlib.PurePosixPath(name)
        if (
            candidate.is_absolute()
            or ".." in candidate.parts
            or len(candidate.parts) != 2
            or candidate.parts[0] != "patches"
            or candidate.suffix != ".patch"
        ):
            raise InventoryError("unsafe patch path on series line {}: {}".format(line_number, name))
        if name in seen:
            raise InventoryError("duplicate patch in series: {}".format(name))
        seen.add(name)
        relative = "PlayCoverPatch/{}".format(name)
        path = require_tracked_regular_file(repo, relative)
        patches.append(
            {
                "order": len(patches) + 1,
                "path": relative,
                "sha256": sha256(path),
            }
        )
    if not patches:
        raise InventoryError("PlayCoverPatch/series contains no patches")
    return patches


def parse_playtools_reference(repo: pathlib.Path) -> str:
    relative = "PlayCoverPatch/overlay/Cartfile.resolved"
    path = require_tracked_regular_file(repo, relative)
    pattern = re.compile(r'^github\s+"PlayCover/PlayTools"\s+"([^"\s]+)"$')
    references = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(raw_line.strip())
        if match:
            references.append(match.group(1))
    if len(references) != 1:
        raise InventoryError("Cartfile.resolved must contain one pinned PlayCover/PlayTools reference")
    if references[0] != EXPECTED_PLAYTOOLS_COMMIT:
        raise InventoryError("unsupported PlayTools reference for v0.1")
    return references[0]


def parse_playtools_patches(repo: pathlib.Path, target_commit: str) -> List[Dict[str, Any]]:
    prefix = "PlayCoverPatch/dependencies/PlayTools/patches"
    patch_paths = sorted(
        relative
        for relative in tracked_under(repo, prefix)
        if relative.endswith(".patch")
    )
    if not patch_paths:
        raise InventoryError("no reviewed PlayTools compatibility patch")
    patches = []
    for order, relative in enumerate(patch_paths, 1):
        path = require_tracked_regular_file(repo, relative)
        patches.append(
            {
                "order": order,
                "path": relative,
                "sha256": sha256(path),
                "targetCommit": target_commit,
                "targetRepository": PLAYTOOLS_REPOSITORY,
            }
        )
    return patches


def parse_playtools_resolution(repo: pathlib.Path) -> Dict[str, Any]:
    relative = "PlayCoverPatch/dependencies/PlayTools/overlay/Package.resolved"
    path = require_tracked_regular_file(repo, relative)
    if sha256(path) != EXPECTED_PLAYTOOLS_RESOLUTION_SHA256:
        raise InventoryError("reviewed PlayTools SwiftPM resolution hash differs")
    try:
        resolution = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError("invalid PlayTools SwiftPM resolution") from error
    if resolution != EXPECTED_PLAYTOOLS_RESOLUTION:
        raise InventoryError("unsupported PlayTools SwiftPM resolution pins")
    return {
        "originHash": resolution["originHash"],
        "path": relative,
        "pins": resolution["pins"],
        "sha256": EXPECTED_PLAYTOOLS_RESOLUTION_SHA256,
        "version": resolution["version"],
    }


def write_json_exclusive(path: pathlib.Path, value: Dict[str, Any]) -> None:
    if not path.is_absolute():
        raise InventoryError("output path must be absolute")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise InventoryError("output parent must be an existing non-symlink directory")
    if path.exists() or path.is_symlink():
        raise InventoryError("refusing to replace existing output: {}".format(path))
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".pcvr-inventory-", dir=str(path.parent))
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(str(temporary), 0o644)
        os.link(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def build_inventory(repo: pathlib.Path, release_tag: str, commit: str) -> Dict[str, Any]:
    if not ALPHA_TAG.fullmatch(release_tag):
        raise InventoryError("release tag must match v0.1.0-alpha.N")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise InventoryError("commit must be a full lowercase SHA-1")
    require_clean_checkout(repo, commit)

    tree = git(repo, "rev-parse", "{}^{{tree}}".format(commit))
    epoch_text = git(repo, "show", "-s", "--format=%ct", commit)
    try:
        source_date_epoch = int(epoch_text)
    except ValueError as error:
        raise InventoryError("commit timestamp is not an integer") from error

    manifest_paths = sorted(tracked_under(repo, "Compatibility/manifests"))
    if not manifest_paths:
        raise InventoryError("no tracked compatibility manifests")

    manifests = []
    upstream_by_key: Dict[str, Dict[str, Any]] = {}
    for relative in manifest_paths:
        if not relative.endswith(".json"):
            continue
        value = load_manifest(repo, relative)
        playcover = value["playCover"]
        upstream_key = "{}@{}".format(playcover["repository"], playcover["commit"])
        upstream_by_key[upstream_key] = {
            "buildVersion": playcover["buildVersion"],
            "commit": playcover["commit"],
            "repository": playcover["repository"],
            "shortVersion": playcover["shortVersion"],
        }
        manifests.append(
            {
                "hostBuild": value["host"]["buildVersion"],
                "patchID": value["patchID"],
                "path": relative,
                "sha256": sha256(repo / relative),
                "supportState": value["supportState"],
                "vrChatBuild": value["vrChat"]["buildVersion"],
                "vrChatVersion": value["vrChat"]["shortVersion"],
                "xnuVersion": value["host"]["xnuVersion"],
            }
        )

    overlays = []
    for relative in sorted(tracked_under(repo, "PlayCoverPatch/overlay")):
        path = require_tracked_regular_file(repo, relative)
        overlays.append({"path": relative, "sha256": sha256(path)})
    if not overlays:
        raise InventoryError("PlayCover patch overlay is empty")

    metadata_files = []
    for relative in ("Compatibility/schema.json", "Compatibility/PCVRPatchManifest.json"):
        path = require_tracked_regular_file(repo, relative)
        metadata_files.append({"path": relative, "sha256": sha256(path)})

    design_assets = []
    for purpose, relative in (
        ("patcherAppIconMaster", "Design/Logo/pcvrpatcher-app-icon-v10.png"),
        ("customizedPlayCoverIconMaster", "Design/Logo/playcover-vrchat-app-icon-v10.png"),
    ):
        path = require_tracked_regular_file(repo, relative)
        design_assets.append(
            {"path": relative, "purpose": purpose, "sha256": sha256(path)}
        )

    playtools_reference = parse_playtools_reference(repo)
    return {
        "compatibilityManifests": sorted(manifests, key=lambda item: item["path"]),
        "compatibilityMetadata": metadata_files,
        "designAssets": design_assets,
        "excludedBinaryInputs": [
            "patched PlayCover payload",
            "VRChat IPA or binaries",
            "root controller binary",
            "signing credentials",
        ],
        "patchSeries": parse_series(repo),
        "playTools": {
            "compatibilityPatches": parse_playtools_patches(repo, playtools_reference),
            "pinnedReference": playtools_reference,
            "repository": PLAYTOOLS_REPOSITORY,
            "swiftPackageResolution": parse_playtools_resolution(repo),
        },
        "release": {
            "repository": PROJECT_REPOSITORY,
            "sourceCommit": commit,
            "sourceDateEpoch": source_date_epoch,
            "sourceTree": tree,
            "tag": release_tag,
            "version": release_tag[1:],
        },
        "schemaVersion": 1,
        "upstreamPlayCover": [upstream_by_key[key] for key in sorted(upstream_by_key)],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, type=pathlib.Path)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()

    try:
        repo = arguments.repo_root.resolve(strict=True)
        if not repo.is_dir() or not (repo / ".git").exists():
            raise InventoryError("repo-root is not a Git checkout")
        output = arguments.output.absolute()
        inventory = build_inventory(repo, arguments.release_tag, arguments.commit)
        write_json_exclusive(output, inventory)
    except (InventoryError, OSError, KeyError, TypeError) as error:
        parser.exit(1, "error: {}\n".format(error))

    print("Wrote deterministic release inventory: {}".format(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
