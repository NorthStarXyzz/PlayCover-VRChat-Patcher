#!/usr/bin/python3
"""Generate a deterministic SPDX 2.3 SBOM for a clean v0.1 Alpha checkout."""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import urllib.parse
from typing import Any, Dict


PROJECT_REPOSITORY = "https://github.com/NorthStarXyzz/PlayCover-VRChat-Patcher"
EXPECTED_PLAYTOOLS_COMMIT = "f17b9211211fb4cf5652d4930ea82613ee3c92a5"
ALPHA_TAG = re.compile(r"^v0\.1\.0-alpha\.[1-9][0-9]*$")


class SBOMError(RuntimeError):
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
        raise SBOMError("git {} failed: {}".format(" ".join(arguments), detail))
    return result.stdout.strip()


def load_json(path: pathlib.Path) -> Dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise SBOMError("missing regular metadata file: {}".format(path))
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SBOMError("invalid JSON metadata: {}".format(path)) from error


def playtools_reference(path: pathlib.Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise SBOMError("missing Cartfile.resolved")
    pattern = re.compile(r'^github\s+"PlayCover/PlayTools"\s+"([^"\s]+)"$')
    values = [
        match.group(1)
        for line in path.read_text(encoding="utf-8").splitlines()
        for match in [pattern.match(line.strip())]
        if match
    ]
    if len(values) != 1:
        raise SBOMError("Cartfile.resolved must pin exactly one PlayCover/PlayTools reference")
    if values[0] != EXPECTED_PLAYTOOLS_COMMIT:
        raise SBOMError("unsupported PlayTools reference for v0.1")
    return values[0]


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def playtools_patches(repo: pathlib.Path, target_commit: str):
    directory = repo / "PlayCoverPatch/dependencies/PlayTools/patches"
    if not directory.is_dir() or directory.is_symlink():
        raise SBOMError("missing PlayTools compatibility patch directory")
    patches = []
    for index, path in enumerate(sorted(directory.glob("*.patch")), 1):
        if not path.is_file() or path.is_symlink():
            raise SBOMError("PlayTools patch must be a regular non-symlink file")
        relative = path.relative_to(repo).as_posix()
        tracked = git(repo, "ls-files", "--error-unmatch", "--", relative)
        if tracked != relative:
            raise SBOMError("PlayTools patch is not tracked: {}".format(relative))
        patches.append(
            {
                "SPDXID": "SPDXRef-File-PlayToolsPatch-{}".format(index),
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": sha256(path)}
                ],
                "comment": "Patch target: PlayCover/PlayTools@{}".format(target_commit),
                "copyrightText": "NOASSERTION",
                "fileName": "./" + relative,
                "fileTypes": ["SOURCE"],
                "licenseConcluded": "NOASSERTION",
                "licenseInfoInFiles": ["NOASSERTION"],
            }
        )
    if not patches:
        raise SBOMError("no reviewed PlayTools compatibility patch")
    return patches


def purl(repository: str, reference: str) -> str:
    path = repository.removesuffix(".git").removeprefix("https://github.com/")
    encoded = urllib.parse.quote(reference, safe="._~-")
    return "pkg:github/{}@{}".format(path, encoded)


def package(
    identifier: str,
    name: str,
    version: str,
    repository: str,
    license_id: str,
    purpose: str,
    reference: str,
) -> Dict[str, Any]:
    return {
        "SPDXID": identifier,
        "copyrightText": "NOASSERTION",
        "downloadLocation": repository.removesuffix(".git"),
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceLocator": purl(repository, reference),
                "referenceType": "purl",
            },
            {
                "referenceCategory": "OTHER",
                "referenceLocator": repository + "@" + reference,
                "referenceType": "vcs",
            },
        ],
        "filesAnalyzed": False,
        "licenseConcluded": license_id,
        "licenseDeclared": license_id,
        "name": name,
        "primaryPackagePurpose": purpose,
        "supplier": "NOASSERTION",
        "versionInfo": version,
    }


def write_exclusive(path: pathlib.Path, document: Dict[str, Any]) -> None:
    if not path.is_absolute():
        raise SBOMError("output path must be absolute")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise SBOMError("output parent must be an existing non-symlink directory")
    if path.exists() or path.is_symlink():
        raise SBOMError("refusing to replace existing output")
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".pcvr-sbom-", dir=str(path.parent))
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


def build_document(repo: pathlib.Path, tag: str, commit: str) -> Dict[str, Any]:
    if not ALPHA_TAG.fullmatch(tag):
        raise SBOMError("release tag must match v0.1.0-alpha.N")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SBOMError("commit must be a full lowercase SHA-1")
    if git(repo, "rev-parse", "HEAD") != commit:
        raise SBOMError("requested commit does not match HEAD")
    if git(repo, "status", "--porcelain=v1", "--untracked-files=all"):
        raise SBOMError("refusing SBOM generation from a dirty checkout")
    if ".package(" in (repo / "Package.swift").read_text(encoding="utf-8"):
        raise SBOMError("unmodeled Swift package dependency in Package.swift")

    manifests = sorted((repo / "Compatibility/manifests").glob("*.json"))
    if not manifests:
        raise SBOMError("no compatibility manifest")
    values = [load_json(path) for path in manifests]
    upstream_keys = {
        (
            value["playCover"]["repository"],
            value["playCover"]["commit"],
            value["playCover"]["shortVersion"],
            value["host"]["xnuVersion"],
        )
        for value in values
    }
    if len(upstream_keys) != 1:
        raise SBOMError("v0.1 SBOM requires one PlayCover/XNU compatibility target")
    playcover_repo, playcover_commit, playcover_version, xnu_version = next(iter(upstream_keys))
    playtools_ref = playtools_reference(repo / "PlayCoverPatch/overlay/Cartfile.resolved")
    dependency_patches = playtools_patches(repo, playtools_ref)
    epoch = int(git(repo, "show", "-s", "--format=%ct", commit))
    created = datetime.datetime.fromtimestamp(
        epoch, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    version = tag[1:]
    archive_name = "PlayCover-VRChat-Patcher-{}-source.tar.gz".format(version)

    root = {
        "SPDXID": "SPDXRef-Package-PCVRPatcher",
        "copyrightText": "NOASSERTION",
        "downloadLocation": "{}/releases/download/{}/{}".format(
            PROJECT_REPOSITORY, tag, archive_name
        ),
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceLocator": purl(PROJECT_REPOSITORY, commit),
                "referenceType": "purl",
            },
            {
                "referenceCategory": "OTHER",
                "referenceLocator": PROJECT_REPOSITORY + ".git@" + commit,
                "referenceType": "vcs",
            },
        ],
        "filesAnalyzed": False,
        "licenseConcluded": "GPL-3.0-only",
        "licenseDeclared": "GPL-3.0-only",
        "name": "PlayCover VRChat Patcher",
        "packageFileName": archive_name,
        "primaryPackagePurpose": "APPLICATION",
        "supplier": "Organization: PlayCover VRChat Patcher contributors",
        "versionInfo": version,
    }
    playcover = package(
        "SPDXRef-Package-PlayCover",
        "PlayCover",
        playcover_version,
        playcover_repo,
        "GPL-3.0-only",
        "APPLICATION",
        playcover_commit,
    )
    playtools = package(
        "SPDXRef-Package-PlayTools",
        "PlayTools",
        playtools_ref,
        "https://github.com/PlayCover/PlayTools.git",
        "NOASSERTION",
        "LIBRARY",
        playtools_ref,
    )
    xnu = package(
        "SPDXRef-Package-AppleXNU",
        "Apple XNU",
        xnu_version,
        "https://github.com/apple-oss-distributions/xnu.git",
        "APSL-2.0",
        "OPERATING-SYSTEM",
        xnu_version,
    )

    relationships = [
        {
            "relatedSpdxElement": "SPDXRef-Package-PCVRPatcher",
            "relationshipType": "DESCRIBES",
            "spdxElementId": "SPDXRef-DOCUMENT",
        },
        {
            "relatedSpdxElement": "SPDXRef-Package-PlayCover",
            "relationshipType": "PATCH_FOR",
            "spdxElementId": "SPDXRef-Package-PCVRPatcher",
        },
        {
            "relatedSpdxElement": "SPDXRef-Package-PlayTools",
            "relationshipType": "DEPENDS_ON",
            "spdxElementId": "SPDXRef-Package-PlayCover",
        },
        {
            "relatedSpdxElement": "SPDXRef-Package-AppleXNU",
            "relationshipType": "HAS_PREREQUISITE",
            "spdxElementId": "SPDXRef-Package-PCVRPatcher",
        },
    ]
    for patch in dependency_patches:
        relationships.extend(
            [
                {
                    "relatedSpdxElement": patch["SPDXID"],
                    "relationshipType": "CONTAINS",
                    "spdxElementId": "SPDXRef-Package-PCVRPatcher",
                },
                {
                    "relatedSpdxElement": "SPDXRef-Package-PlayTools",
                    "relationshipType": "PATCH_FOR",
                    "spdxElementId": patch["SPDXID"],
                },
            ]
        )

    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "annotations": [
            {
                "annotationDate": created,
                "annotationType": "OTHER",
                "annotator": "Tool: pcvr-generate-sbom-0.1",
                "comment": (
                    "Source-only Alpha: no patched PlayCover payload, VRChat IPA/binary, "
                    "root controller binary, or CXPatcher source is included."
                ),
            }
        ],
        "creationInfo": {
            "created": created,
            "creators": ["Tool: pcvr-generate-sbom-0.1"],
            "licenseListVersion": "3.25",
        },
        "dataLicense": "CC0-1.0",
        "documentNamespace": "{}/releases/tag/{}/spdx/{}".format(
            PROJECT_REPOSITORY, tag, commit
        ),
        "files": dependency_patches,
        "name": "PlayCover-VRChat-Patcher-{}-source".format(version),
        "packages": [root, playcover, playtools, xnu],
        "relationships": relationships,
        "spdxVersion": "SPDX-2.3",
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
            raise SBOMError("repo-root is not a Git checkout")
        output = arguments.output.absolute()
        write_exclusive(output, build_document(repo, arguments.release_tag, arguments.commit))
    except (SBOMError, OSError, KeyError, TypeError, ValueError) as error:
        parser.exit(1, "error: {}\n".format(error))
    print("Wrote deterministic SPDX 2.3 SBOM: {}".format(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
