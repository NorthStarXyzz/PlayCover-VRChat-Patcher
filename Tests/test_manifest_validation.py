#!/usr/bin/env python3

import copy
import json
import pathlib
import subprocess
import sys
import tempfile


REPO = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = REPO / "Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json"
SCHEMA = REPO / "Compatibility/schema.json"
VALIDATOR = REPO / "Scripts/validate-manifest.py"
PACKAGE_MANIFEST = REPO / "Controller/package/ControllerPackageManifest.json"


def run_validator(value: dict) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="pcvr-manifest-test.") as directory:
        candidate = pathlib.Path(directory) / "manifest.json"
        candidate.write_text(json.dumps(value), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(candidate)],
            check=False,
            capture_output=True,
            text=True,
        )


def main() -> None:
    source = json.loads(MANIFEST.read_text(encoding="utf-8"))
    patched = {
        "bundleIdentifier": "io.github.northstarxyzz.PlayCoverVRChat",
        "shortVersion": "3.1.0",
        "buildVersion": "856",
        "executableName": "PlayCover VRChat",
        "executableSHA256": "1" * 64,
        "executableUUID": "11111111-1111-1111-1111-111111111111",
        "treeSHA256": "2" * 64,
        "infoPlistSHA256": "3" * 64,
        "codeResourcesSHA256": "4" * 64,
    }

    valid = copy.deepcopy(source)
    valid["patchedPlayCover"] = patched
    valid["controllerPackage"] = json.loads(
        PACKAGE_MANIFEST.read_text(encoding="utf-8")
    )["controllerPackage"]
    result = run_validator(valid)
    if result.returncode != 0:
        raise SystemExit(f"valid parallel identity was rejected: {result.stderr}")

    invalid = copy.deepcopy(valid)
    invalid["patchedPlayCover"]["executableName"] = "PlayCover"
    result = run_validator(invalid)
    if result.returncode == 0:
        raise SystemExit("legacy patched executable name was accepted")

    patched_only = copy.deepcopy(source)
    patched_only["patchedPlayCover"] = patched
    if run_validator(patched_only).returncode == 0:
        raise SystemExit("patched PlayCover without controller package was accepted")

    package_only = copy.deepcopy(source)
    package_only["controllerPackage"] = valid["controllerPackage"]
    if run_validator(package_only).returncode == 0:
        raise SystemExit("controller package without patched PlayCover was accepted")

    tampered_package = copy.deepcopy(valid)
    tampered_package["controllerPackage"]["sha256"] = "0" * 64
    if run_validator(tampered_package).returncode == 0:
        raise SystemExit("unreviewed controller package hash was accepted")

    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    identity = schema["$defs"]["patchedPlayCoverIdentity"]
    if identity["properties"]["executableName"].get("const") != "PlayCover VRChat":
        raise SystemExit("schema and runtime disagree on the patched executable name")
    required = set(identity["required"])
    if not {"infoPlistSHA256", "codeResourcesSHA256"}.issubset(required):
        raise SystemExit("schema does not seal patched metadata hashes")

    print("Manifest parallel-identity validation tests passed.")


if __name__ == "__main__":
    main()
