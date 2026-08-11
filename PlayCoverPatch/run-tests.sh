#!/bin/zsh

set -eu
setopt PIPE_FAIL

script_dir=${0:A:h}
temporary_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pcvr-playcover-tests.XXXXXX")
playcover_resolution="$script_dir/overlay/PlayCover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
readonly expected_playcover_resolution_sha256=324e7c5d4b57421c2a4098cc4dc944da093382098c2595a1f84dcd9ecf848b04

cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -d "$temporary_dir" ]]; then
        /bin/rm -rf -- "$temporary_dir"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ ! -f "$playcover_resolution" || -L "$playcover_resolution" || \
      $(/usr/bin/stat -f '%p' "$playcover_resolution") != 100644 ]]; then
    print -u2 -- "PlayCover SwiftPM resolution fixture is missing or unsafe."
    exit 79
fi
playcover_resolution_sha=$(/usr/bin/shasum -a 256 "$playcover_resolution")
if [[ "${playcover_resolution_sha%% *}" != "$expected_playcover_resolution_sha256" ]] || \
   [[ $(/usr/bin/grep -F -c '"identity" :' "$playcover_resolution") != 7 ]] || \
   [[ $(/usr/bin/grep -F -c '"revision" :' "$playcover_resolution") != 7 ]] || \
   /usr/bin/grep -F -q '"identity" : "sparkle"' "$playcover_resolution"; then
    print -u2 -- "PlayCover SwiftPM resolution fixture differs from the reviewed seven-pin state."
    exit 79
fi

source_file="$script_dir/overlay/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
test_file="$script_dir/Tests/CoordinatorStateMachineTests.swift"
test_binary="$temporary_dir/coordinator-state-machine-tests"

/usr/bin/xcrun swiftc \
    -swift-version 5 \
    -parse-as-library \
    "$source_file" \
    "$test_file" \
    -o "$test_binary"

"$test_binary"
/usr/bin/python3 "$script_dir/Tests/test-settings-lifecycle.py" \
    --patch "$script_dir/patches/0009-canonicalize-vrchat-settings-lifecycle.patch"
/bin/zsh "$script_dir/dependencies/PlayTools/test.sh"
