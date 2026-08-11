#!/bin/zsh

set -euo pipefail
setopt EXTENDED_GLOB NULL_GLOB PIPE_FAIL

repo_root=${0:A:h:h}
manifest=$repo_root/Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json
runtime_stamp=$repo_root/Compatibility/PCVRPatchManifest.json
controller_package_manifest=$repo_root/Controller/package/ControllerPackageManifest.json

/usr/bin/python3 -m json.tool "$manifest" >/dev/null
/usr/bin/python3 -m json.tool "$runtime_stamp" >/dev/null
/usr/bin/python3 -m json.tool "$repo_root/Compatibility/schema.json" >/dev/null
/usr/bin/python3 -m json.tool "$controller_package_manifest" >/dev/null
/usr/bin/python3 "$repo_root/Scripts/validate-manifest.py" "$manifest"
/usr/bin/python3 "$repo_root/Tests/test_manifest_validation.py"
/usr/bin/python3 "$repo_root/Tests/test_release_binary_gate.py"
/usr/bin/python3 "$repo_root/Scripts/reject-release-binaries.py" \
    --repo-root "$repo_root"

controller_build_id=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerBuildID"])' \
    "$runtime_stamp")
main_normalized_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["vrChat"]["mainIdentity"]["normalizedUnsignedSHA256"])' \
    "$manifest")
main_loads_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["vrChat"]["mainIdentity"]["normalizedLoadCommandsSHA256"])' \
    "$manifest")
entitlements_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["vrChat"]["mainIdentity"]["normalizedEntitlementsSHA256"])' \
    "$manifest")
macho_allowlist_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["vrChat"]["machoAllowlist"]["digestSHA256"])' \
    "$manifest")
package_controller_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["controller"]["sha256"])' \
    "$controller_package_manifest")
package_runner_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["runner"]["sha256"])' \
    "$controller_package_manifest")
package_attestation_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["attestation"]["sha256"])' \
    "$controller_package_manifest")
actual_runner_sha=$(/usr/bin/shasum -a 256 "$repo_root/Controller/root-runner" | \
    /usr/bin/awk '{print $1}')
actual_attestation_sha=$(/usr/bin/shasum -a 256 \
    "$repo_root/Controller/package/installation.json" | /usr/bin/awk '{print $1}')
expected_controller_sha=$(/usr/bin/awk -F= '/^expected_sha=/{print $2; exit}' \
    "$repo_root/Controller/build.sh")
if [[ "$package_controller_sha" != "$expected_controller_sha" ||
      "$package_runner_sha" != "$actual_runner_sha" ||
      "$package_attestation_sha" != "$actual_attestation_sha" ]]; then
    print -u2 -- "Controller package manifest and reviewed source hashes differ."
    exit 79
fi
if ! /usr/bin/grep -F -x -q \
       "#define PCVR_CONTROLLER_BUILD_ID \"$controller_build_id\"" \
       "$repo_root/Controller/pcvr-status-protocol.h" || \
   ! /usr/bin/grep -F -q \
       "static let controllerBuildID = \"$controller_build_id\"" \
       "$repo_root/PlayCoverPatch/overlay/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift" || \
   ! /usr/bin/grep -F -q "\"$main_normalized_sha\"" \
       "$repo_root/Controller/pcvr-bundle-identity.h" || \
   ! /usr/bin/grep -F -q "\"$main_loads_sha\"" \
       "$repo_root/Controller/pcvr-bundle-identity.h" || \
   ! /usr/bin/grep -F -q "\"$entitlements_sha\"" \
       "$repo_root/Controller/pcvr-bundle-identity.h" || \
   ! /usr/bin/grep -F -q "\"$macho_allowlist_sha\"" \
       "$repo_root/Controller/pcvr-reviewed-macho-allowlist.h"; then
    print -u2 -- "Compatibility stamp, coordinator, and controller constants differ."
    exit 79
fi

if ! /usr/bin/grep -F -q \
       'Library/Containers/io.github.northstarxyzz.PlayCoverVRChat' \
       "$repo_root/Controller/pcvr-target.c"; then
    print -u2 -- "Controller does not bind only the independent PlayCover VRChat library."
    exit 79
fi

for script in $repo_root/Scripts/*.sh(N) $repo_root/Controller/**/*.sh(N) \
              $repo_root/PlayCoverPatch/**/*.sh(N); do
    /bin/zsh -n "$script"
done
/bin/zsh -n "$repo_root/Controller/root-runner"
for python_script in $repo_root/Scripts/*.py(N); do
    /usr/bin/python3 -c \
        'import pathlib,sys; path=pathlib.Path(sys.argv[1]); compile(path.read_text(), str(path), "exec")' \
        "$python_script"
done
/usr/bin/swift package --package-path "$repo_root" dump-package >/dev/null

for forbidden in $repo_root/**/*.(ipa|p12|mobileprovision|provisionprofile)(N); do
    if /usr/bin/git -C "$repo_root" check-ignore -q "$forbidden"; then
        continue
    fi
    print -u2 -- "forbidden release input: $forbidden"
    exit 1
done

if [[ ${PCVR_SKIP_PACKAGE_GATE:-0} == 1 ]]; then
    print -- "Skipped deterministic package gate (non-target CI host)."
else
    package_test_root=$(/usr/bin/mktemp -d /tmp/pcvr-package-gate.XXXXXX)
    cleanup_package_gate() {
        local result=$?
        trap - EXIT INT TERM HUP
        if [[ -d "$package_test_root" &&
              "$package_test_root" == /tmp/pcvr-package-gate.* ]]; then
            /bin/rm -R "$package_test_root"
        fi
        exit "$result"
    }
    trap cleanup_package_gate EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    /bin/mkdir "$package_test_root/a" "$package_test_root/b"
    for package_copy in a b; do
        candidate="$package_test_root/$package_copy/PlayCoverVRChatMemoryPolicy.pkg"
        /bin/zsh "$repo_root/Controller/package/build-package.sh" --output "$candidate"
        /bin/zsh "$repo_root/Controller/package/verify-package.sh" "$candidate"
    done
    /usr/bin/cmp \
        "$package_test_root/a/PlayCoverVRChatMemoryPolicy.pkg" \
        "$package_test_root/b/PlayCoverVRChatMemoryPolicy.pkg"
fi

print -- "Repository policy checks passed."
