#!/bin/zsh

set -eu
setopt PIPE_FAIL

repo_root=${0:A:h:h:h}
test_directory=$(/usr/bin/mktemp -d /tmp/pcvr-controller-tests.XXXXXX)
test_output="$test_directory/protocol-tests"
controller_output="$test_directory/argument-canary"
allowlist_generator="$test_directory/allowlist-generator"

cleanup() {
    if [[ -d "$test_directory" &&
          "$test_directory" == /tmp/pcvr-controller-tests.* ]]; then
        /usr/bin/find "$test_directory" -depth -delete
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/usr/bin/xcrun clang \
    -std=c11 -O1 -g \
    -Wall -Wextra -Werror -Wconversion -Wsign-conversion \
    -fsanitize=address,undefined \
    -I"$repo_root/Controller" \
    "$repo_root/Controller/pcvr-bundle-identity.c" \
    "$repo_root/Controller/pcvr-memory-policy.c" \
    "$repo_root/Controller/pcvr-runtime-images.c" \
    "$repo_root/Controller/pcvr-status-protocol.c" \
    "$repo_root/Controller/pcvr-target.c" \
    "$repo_root/Tests/Controller/fake-backend.c" \
    "$repo_root/Tests/Controller/test-controller-protocol.c" \
    -framework CoreFoundation -framework Security \
    -o "$test_output"

"$test_output"

/usr/bin/xcrun clang \
    -std=c11 -O2 \
    -Wall -Wextra -Werror -Wconversion -Wsign-conversion \
    -I"$repo_root/Controller" \
    "$repo_root/Tests/Controller/generate-reviewed-allowlist.c" \
    "$repo_root/Controller/pcvr-bundle-identity.c" \
    -framework CoreFoundation -framework Security \
    -o "$allowlist_generator"

if [[ -n ${PCVR_TEST_REVIEWED_EXECUTABLE:-} ]]; then
    reviewed_app=${PCVR_TEST_REVIEWED_EXECUTABLE:h}
    regenerated_allowlist="$test_directory/pcvr-reviewed-macho-allowlist.h"
    "$allowlist_generator" "$reviewed_app" > "$regenerated_allowlist"
    /usr/bin/cmp "$regenerated_allowlist" \
        "$repo_root/Controller/pcvr-reviewed-macho-allowlist.h"
fi

/usr/bin/xcrun clang \
    -std=c11 -O2 \
    -Wall -Wextra -Werror -Wconversion -Wsign-conversion \
    "$repo_root/Controller/vrchat-memory-policy-controller.c" \
    "$repo_root/Controller/pcvr-bundle-identity.c" \
    "$repo_root/Controller/pcvr-memory-policy.c" \
    "$repo_root/Controller/pcvr-runtime-images.c" \
    "$repo_root/Controller/pcvr-status-protocol.c" \
    "$repo_root/Controller/pcvr-target.c" \
    -framework CoreFoundation -framework Security \
    -o "$controller_output"
/usr/bin/codesign --force --sign - \
    --identifier io.playcover.vrchat-memory-policy.controller.test \
    "$controller_output" >/dev/null

for arguments in '' '4 extra' '/tmp/not-accepted' '03' '3' '+4' '4.0'; do
    words=(${=arguments})
    set +e
    "$controller_output" "${words[@]}" >/dev/null 2>&1
    argument_result=$?
    set -e
    if (( argument_result != 64 )); then
        print -u2 -- "Controller did not reject invalid argument set: ${arguments:-<none>}"
        exit 1
    fi
done

/bin/zsh -n "$repo_root/Controller/root-runner"
/bin/zsh -n "$repo_root/Controller/build.sh"
/bin/zsh -n "$repo_root/Controller/install.sh"
/bin/zsh -n \
    "$repo_root/Controller/package/build-package.sh" \
    "$repo_root/Controller/package/verify-package.sh" \
    "$repo_root/Controller/package/scripts/common.zsh" \
    "$repo_root/Controller/package/scripts/preinstall" \
    "$repo_root/Controller/package/scripts/postinstall"
/usr/bin/python3 "$repo_root/Tests/Controller/test-package-state-machine.py"

expected_controller_sha=$(/usr/bin/awk -F= \
    '/^expected_sha=/{print $2; exit}' "$repo_root/Controller/build.sh")
runner_controller_sha=$(/usr/bin/awk -F= \
    '/^expected_controller_sha=/{print $2; exit}' "$repo_root/Controller/root-runner")
actual_runner_sha=$(/usr/bin/shasum -a 256 \
    "$repo_root/Controller/root-runner" | /usr/bin/awk '{print $1}')
manifest_runner_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["runner"]["sha256"])' \
    "$repo_root/Controller/package/ControllerPackageManifest.json")
if [[ "$runner_controller_sha" != "$expected_controller_sha" ||
      "$manifest_runner_sha" != "$actual_runner_sha" ]]; then
    print -u2 -- "Controller/runner/package reviewed hash chain is inconsistent."
    exit 1
fi

/bin/zsh "$repo_root/Controller/build.sh" >/dev/null
first_build_sha=$(/usr/bin/shasum -a 256 \
    "$repo_root/Controller/build/vrchat-memory-policy-controller" | \
    /usr/bin/awk '{print $1}')
/bin/zsh "$repo_root/Controller/build.sh" >/dev/null
second_build_sha=$(/usr/bin/shasum -a 256 \
    "$repo_root/Controller/build/vrchat-memory-policy-controller" | \
    /usr/bin/awk '{print $1}')
if [[ "$first_build_sha" != "$expected_controller_sha" ||
      "$second_build_sha" != "$expected_controller_sha" ]]; then
    print -u2 -- "Controller builds are not reproducible or reviewed."
    exit 1
fi

print -- "Controller CLI, deterministic build, and installer hash-chain tests passed."
