#!/usr/bin/env python3
"""Validate the reviewed PCVR schema-2 compatibility manifest."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


SHA256 = re.compile(r"^[0-9a-f]{64}$")
UUID = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)
PATCH_ID = re.compile(r"^[a-z0-9][a-z0-9._-]+$")


def fail(message: str) -> None:
    raise SystemExit(f"manifest validation failed: {message}")


def require_object(
    value: object,
    label: str,
    required: set[str],
    optional: set[str] | None = None,
) -> dict[str, object]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    optional = optional or set()
    keys = set(value)
    missing = required - keys
    unknown = keys - required - optional
    if missing:
        fail(f"{label} is missing: {', '.join(sorted(missing))}")
    if unknown:
        fail(f"{label} has unknown fields: {', '.join(sorted(unknown))}")
    return value


def require_sha(value: object, label: str) -> None:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        fail(f"invalid {label} SHA-256")


def require_uuid(value: object, label: str) -> None:
    if not isinstance(value, str) or not UUID.fullmatch(value):
        fail(f"invalid {label} UUID")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-manifest.py MANIFEST.json")

    path = Path(sys.argv[1])
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)

    value = require_object(
        value,
        "manifest",
        {
            "schemaVersion", "patchID", "supportState", "architecture",
            "playCover", "layout", "vrChat", "host", "policy", "ipc",
        },
        {"patchedPlayCover", "controllerPackage"},
    )
    if value.get("schemaVersion") != 2:
        fail("schemaVersion must be 2")
    if not PATCH_ID.fullmatch(str(value.get("patchID", ""))):
        fail("invalid patchID")
    if value.get("supportState") not in {"experimental", "supported", "revoked"}:
        fail("invalid supportState")
    if value.get("architecture") != "arm64":
        fail("only arm64 is supported")
    if (value.get("patchedPlayCover") is None) != (value.get("controllerPackage") is None):
        fail("patchedPlayCover and controllerPackage must be present or absent together")

    playcover = require_object(
        value.get("playCover"),
        "playCover",
        {
            "repository", "commit", "bundleIdentifier", "shortVersion",
            "buildVersion", "executableName", "executableSHA256",
            "executableUUID", "treeSHA256", "infoPlistSHA256",
            "codeResourcesSHA256",
        },
    )
    expected_playcover = {
        "repository": "https://github.com/PlayCover/PlayCover.git",
        "commit": "55638e98f36eac1f3d09803799480e9d83f663f8",
        "bundleIdentifier": "io.playcover.PlayCover",
        "shortVersion": "3.1.0",
        "buildVersion": "856",
        "executableName": "PlayCover",
        "executableSHA256": "82c73cc8ecdad4e1b5f47696413613f9d223bcb57833f1ae6a6145642cd6c8a7",
        "executableUUID": "BEA1F86C-247B-3C5A-80F4-9C028ED04240",
        "treeSHA256": "9a2780df76622d6f4bb9b2f0c215c2c0dd85b0424654e1f0ea00c9e454ac15f5",
        "infoPlistSHA256": "e3ddbac0036eaead5fd27676c4d398b707817f4799645598f095cf1dee77c70f",
        "codeResourcesSHA256": "234697cef7973b4059bc6c9303dfec3f0fdd40b77a3f930d1a3c6f9fd352e7ce",
    }
    if playcover != expected_playcover:
        fail("unexpected original PlayCover identity")

    layout = require_object(
        value.get("layout"),
        "layout",
        {
            "originalAppPath", "patchedAppPath", "originalLibraryRelativePath",
            "patchedLibraryRelativePath", "sharedVRChatContainerRelativePath",
        },
    )
    if layout != {
        "originalAppPath": "/Applications/PlayCover.app",
        "patchedAppPath": "/Applications/PlayCover VRChat.app",
        "originalLibraryRelativePath": "Library/Containers/io.playcover.PlayCover",
        "patchedLibraryRelativePath": "Library/Containers/io.github.northstarxyzz.PlayCoverVRChat",
        "sharedVRChatContainerRelativePath": "Library/Containers/com.vrchat.mobile",
    }:
        fail("unexpected parallel-install layout")

    vrchat = require_object(
        value.get("vrChat"),
        "vrChat",
        {
            "bundleIdentifier", "shortVersion", "buildVersion",
            "sourceAppRelativePath", "destinationAppRelativePath",
            "executableName", "mainIdentity", "unityFramework",
            "appdomeLibloader", "machoAllowlist",
        },
    )
    expected_vrchat_metadata = {
        "bundleIdentifier": "com.vrchat.mobile",
        "shortVersion": "2026.2.30300",
        "buildVersion": "1365",
        "sourceAppRelativePath": "Library/Containers/io.playcover.PlayCover/Applications/com.vrchat.mobile.app",
        "destinationAppRelativePath": "Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/com.vrchat.mobile.app",
        "executableName": "VRChat",
    }
    for key, expected in expected_vrchat_metadata.items():
        if vrchat.get(key) != expected:
            fail(f"unexpected VRChat {key}")

    main_identity = require_object(
        vrchat.get("mainIdentity"),
        "vrChat.mainIdentity",
        {
            "executableUUID", "normalizedUnsignedSHA256",
            "normalizedLoadCommandsSHA256", "normalizedEntitlementsSHA256",
        },
    )
    expected_main_identity = {
        "executableUUID": "41CADB30-CCEF-3B6C-8A1D-237CE5D64C42",
        "normalizedUnsignedSHA256": "cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3",
        "normalizedLoadCommandsSHA256": "664266000f81b937260522d25eda5d81bff3f5d460e5e14512f471c8eaec9afb",
        "normalizedEntitlementsSHA256": "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4",
    }
    if main_identity != expected_main_identity:
        fail("unexpected reviewed VRChat main identity")

    macho_allowlist = require_object(
        vrchat.get("machoAllowlist"),
        "vrChat.machoAllowlist",
        {"format", "digestSHA256", "count"},
    )
    if macho_allowlist != {
        "format": "PCVR-MACHO-ALLOWLIST/1",
        "digestSHA256": "60df094badbe3fb9e8f051f07d2a38a54cfb7bd592c3cf62a69e355050ec5109",
        "count": 46,
    }:
        fail("unexpected reviewed VRChat Mach-O allowlist")

    nested_expected = {
        "unityFramework": {
            "relativePath": "Frameworks/UnityFramework.framework/UnityFramework",
            "executableSHA256": "497d0ea4416d734ef0fb8dbb1376a0c31370577ed86bfd8f37a6d1f63e2163e9",
            "executableUUID": "37732282-7315-38F5-9DD3-124F2B1162B4",
        },
        "appdomeLibloader": {
            "relativePath": "Frameworks/libloader.framework/libloader",
            "executableSHA256": "90fd505324581d09883e03cbb46ac6cf8817c18181fa9438381551d589d62440",
            "executableUUID": "64B5DAFB-DE12-3089-AE61-912CE193C876",
        },
    }
    for key, expected in nested_expected.items():
        observed = require_object(
            vrchat.get(key),
            f"vrChat.{key}",
            {"relativePath", "executableSHA256", "executableUUID"},
        )
        require_sha(observed.get("executableSHA256"), f"vrChat.{key}")
        require_uuid(observed.get("executableUUID"), f"vrChat.{key}")
        if observed != expected:
            fail(f"unexpected reviewed VRChat {key} identity")

    host = require_object(
        value.get("host"), "host",
        {"productVersion", "buildVersion", "xnuVersion"},
    )
    if any(not isinstance(host.get(key), str) or not host[key]
           for key in ("productVersion", "buildVersion", "xnuVersion")):
        fail("host metadata must contain non-empty strings")

    policy = require_object(
        value.get("policy"), "policy",
        {
            "defaultMode", "minimumGiB", "maximumPhysicalMemoryPercent",
            "stepGiB", "waitSeconds", "fatal",
        },
    )
    if policy != {
        "defaultMode": "automatic75Percent",
        "minimumGiB": 4,
        "maximumPhysicalMemoryPercent": 75,
        "stepGiB": 1,
        "waitSeconds": 300,
        "fatal": False,
    }:
        fail("unexpected dynamic memory policy")

    ipc = require_object(
        value.get("ipc"), "ipc", {"protocolVersion", "socketPath"},
    )
    if ipc != {
        "protocolVersion": 2,
        "socketPath": "/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock",
    }:
        fail("unexpected IPC contract")

    controller_package = value.get("controllerPackage")
    if controller_package is not None:
        controller_package = require_object(
            controller_package,
            "controllerPackage",
            {
                "relativePath", "identifier", "version", "sha256",
                "controllerBuildID", "controllerQuarantinePath",
                "runnerQuarantinePath", "runner", "controller", "attestation",
                "uninstallJournal", "installJournal", "timeoutSeconds",
                "operationClaim", "pollMilliseconds",
            },
        )
        require_sha(controller_package.get("sha256"), "controller package")
        for artifact_name in (
            "runner", "controller", "attestation",
            "uninstallJournal", "installJournal",
            "operationClaim",
        ):
            artifact = require_object(
                controller_package.get(artifact_name),
                f"controllerPackage.{artifact_name}",
                {"path", "sha256", "uid", "gid", "mode", "linkCount"},
            )
            require_sha(artifact.get("sha256"), f"controllerPackage.{artifact_name}")
            if not isinstance(artifact.get("path"), str) or not artifact["path"].startswith("/"):
                fail(f"controllerPackage.{artifact_name} path must be absolute")
            if (artifact.get("uid"), artifact.get("gid"), artifact.get("linkCount")) != (0, 0, 1):
                fail(f"controllerPackage.{artifact_name} metadata is not root-owned single-link")
            if artifact.get("mode") not in {"0555", "0500", "0444", "0400"}:
                fail(f"controllerPackage.{artifact_name} has an unexpected mode")

        package_manifest_path = (
            Path(__file__).resolve().parents[1]
            / "Controller/package/ControllerPackageManifest.json"
        )
        with package_manifest_path.open("r", encoding="utf-8") as stream:
            reviewed_package = json.load(stream).get("controllerPackage")
        if controller_package != reviewed_package:
            fail("controllerPackage differs from the reviewed package manifest")

    patched = value.get("patchedPlayCover")
    if patched is not None:
        patched = require_object(
            patched,
            "patchedPlayCover",
            {
                "bundleIdentifier", "shortVersion", "buildVersion",
                "executableName", "executableSHA256", "executableUUID",
                "treeSHA256", "infoPlistSHA256", "codeResourcesSHA256",
            },
        )
        if patched.get("bundleIdentifier") != "io.github.northstarxyzz.PlayCoverVRChat":
            fail("invalid patched PlayCover bundle identifier")
        if patched.get("executableName") != "PlayCover VRChat":
            fail("invalid patched PlayCover executable name")
        if (patched.get("shortVersion"), patched.get("buildVersion")) != ("3.1.0", "856"):
            fail("patched PlayCover changed locked version")
        require_sha(patched.get("executableSHA256"), "patched PlayCover executable")
        require_uuid(patched.get("executableUUID"), "patched PlayCover executable")
        require_sha(patched.get("treeSHA256"), "patched PlayCover tree")
        require_sha(patched.get("infoPlistSHA256"), "patched PlayCover Info.plist")
        require_sha(patched.get("codeResourcesSHA256"), "patched PlayCover CodeResources")

    print(f"validated {path}")


if __name__ == "__main__":
    main()
