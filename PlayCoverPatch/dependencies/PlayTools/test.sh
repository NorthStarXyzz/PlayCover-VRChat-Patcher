#!/bin/zsh

set -eu
setopt PIPE_FAIL

script_dir=${0:A:h}
patch_file="$script_dir/patches/0001-xcode26-rich-presence-buttons.patch"
preimage="$script_dir/fixtures/DiscordIPC.preimage.swift"
postimage="$script_dir/fixtures/DiscordIPC.postimage.swift"
resolution="$script_dir/overlay/Package.resolved"
pristine_checkout=${1:-}

if (( $# > 1 )) || [[ -n "$pristine_checkout" && "$pristine_checkout" != /* ]]; then
    print -u2 -- "Usage: /bin/zsh $0 [/absolute/path/to/pristine/Carthage/Checkouts/PlayTools]"
    exit 64
fi

readonly expected_patch_sha256=2b70506b9b0b4bb349f2929357772a3e222e8bd9de22228fc3bf6ceaf6599057
readonly expected_preimage_sha256=c5eb4448850192a3656d4bac5d3c69ca1453ebc5166431b1d6d783a30d8a811b
readonly expected_postimage_sha256=c2aedb3ad93aa8a36fad6beffdb07bb1e2451efbab644bd60db4d80872348967
readonly expected_resolution_sha256=861745ad8d24152ba8e00f426164b618e50a131e164eb17499d7d9f82069caf6
readonly expected_source_preimage_sha256=4c9fc2965e7906e14caeb4abb60b9f669b5096fc452a390ef4fdf09f0c46ded2

verify_hash() {
    local expected=$1
    local path=$2
    local actual
    actual=$(/usr/bin/shasum -a 256 "$path")
    actual=${actual%% *}
    if [[ "$actual" != "$expected" ]]; then
        print -u2 -- "Unexpected reviewed artifact hash: $path"
        exit 79
    fi
}

verify_hash "$expected_patch_sha256" "$patch_file"
verify_hash "$expected_preimage_sha256" "$preimage"
verify_hash "$expected_postimage_sha256" "$postimage"
verify_hash "$expected_resolution_sha256" "$resolution"
/bin/zsh -n "$script_dir/apply.sh" "$script_dir/bootstrap-and-build.sh" \
    "$script_dir/check.sh" "$script_dir/test.sh"

require_fixed_count() {
    local expected=$1
    local needle=$2
    local count
    count=$(/usr/bin/grep -F -c -- "$needle" "$resolution" || true)
    if [[ "$count" != "$expected" ]]; then
        print -u2 -- "Expected $expected SwiftPM resolution match(es) for: $needle"
        exit 79
    fi
}

require_fixed_count 5 '"identity" :'
require_fixed_count 5 '"revision" :'
require_fixed_count 1 '"revision" : "0442cb5a3f98ab802acb777929fdb446bda11a34"'
require_fixed_count 1 '"revision" : "a0cb0954ecb21e4e31b0070e6ed5674e8556685a"'
require_fixed_count 1 '"revision" : "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b"'
require_fixed_count 1 '"revision" : "704705c5c51156ede21172a38654d522ce487074"'
require_fixed_count 1 '"revision" : "4403152a16a040d8448d33d65ad5a034c9d1fa1b"'

temporary_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pcvr-playtools-patch-test.XXXXXX")
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

fixture_target="$temporary_dir/PlayTools/DiscordActivity/DiscordIPC.swift"
/bin/mkdir -p "${fixture_target:h}"
/usr/bin/install -m 0644 "$preimage" "$fixture_target"

/usr/bin/git -C "$temporary_dir" init -q
/usr/bin/git -C "$temporary_dir" apply --check \
    --whitespace=error-all "$patch_file"
/usr/bin/git -C "$temporary_dir" apply \
    --whitespace=error-all "$patch_file"
/usr/bin/cmp -s "$postimage" "$fixture_target" || {
    print -u2 -- "PlayTools patch did not produce the reviewed fixture postimage."
    exit 79
}

if /usr/bin/git -C "$temporary_dir" apply --check \
    --whitespace=error-all "$patch_file" 2>/dev/null; then
    print -u2 -- "Raw PlayTools patch unexpectedly applied twice."
    exit 79
fi

if [[ -n "$pristine_checkout" ]]; then
    /bin/zsh "$script_dir/check.sh" --preimage "$pristine_checkout"

    integration_final="$temporary_dir/integration-final"
    /usr/bin/ditto "$pristine_checkout" "$integration_final"
    /bin/zsh "$script_dir/apply.sh" "$integration_final"
    /bin/zsh "$script_dir/apply.sh" "$integration_final"
    /bin/zsh "$script_dir/check.sh" --applied "$integration_final"

    tampered_resolution="$temporary_dir/Package.tampered.resolved"
    /usr/bin/install -m 0644 "$resolution" "$tampered_resolution"
    /usr/bin/sed -i '' \
        's/4403152a16a040d8448d33d65ad5a034c9d1fa1b/0000000000000000000000000000000000000000/' \
        "$tampered_resolution"
    if [[ $(/usr/bin/shasum -a 256 "$tampered_resolution") == \
          "$expected_resolution_sha256 "* ]]; then
        print -u2 -- "Tampered SwiftPM resolution retained the reviewed hash."
        exit 79
    fi

    wrong_lock_case="$temporary_dir/wrong-lock"
    /usr/bin/ditto "$pristine_checkout" "$wrong_lock_case"
    wrong_lock_dir="$wrong_lock_case/PlayTools.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    /bin/mkdir -m 0755 "$wrong_lock_dir"
    /bin/mkdir -m 0755 "$wrong_lock_dir/configuration"
    /usr/bin/install -m 0644 "$tampered_resolution" \
        "$wrong_lock_dir/Package.resolved"
    if /bin/zsh "$script_dir/apply.sh" "$wrong_lock_case" >/dev/null 2>&1; then
        print -u2 -- "Apply unexpectedly replaced an existing different SwiftPM resolution."
        exit 79
    fi
    wrong_target="$wrong_lock_case/PlayTools/DiscordActivity/DiscordIPC.swift"
    verify_hash "$expected_source_preimage_sha256" "$wrong_target"

    altered_lock_case="$temporary_dir/altered-lock"
    /usr/bin/ditto "$integration_final" "$altered_lock_case"
    /usr/bin/install -m 0644 "$tampered_resolution" \
        "$altered_lock_case/PlayTools.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if /bin/zsh "$script_dir/check.sh" --applied "$altered_lock_case" >/dev/null 2>&1; then
        print -u2 -- "Applied check accepted a different SwiftPM resolution."
        exit 79
    fi

    extra_file_case="$temporary_dir/extra-file"
    /usr/bin/ditto "$integration_final" "$extra_file_case"
    /usr/bin/install -m 0644 "$preimage" "$extra_file_case/UNREVIEWED"
    if /bin/zsh "$script_dir/check.sh" --applied "$extra_file_case" >/dev/null 2>&1; then
        print -u2 -- "Applied check accepted an extra file."
        exit 79
    fi

    symlink_case="$temporary_dir/symlink"
    /usr/bin/ditto "$integration_final" "$symlink_case"
    /bin/ln -s README.md "$symlink_case/UNREVIEWED-LINK"
    if /bin/zsh "$script_dir/check.sh" --applied "$symlink_case" >/dev/null 2>&1; then
        print -u2 -- "Applied check accepted a symlink."
        exit 79
    fi

    print -- "PlayToolsDependencyIntegrationTests: PASS"
fi

print -- "PlayToolsDependencyPatchTests: PASS"
