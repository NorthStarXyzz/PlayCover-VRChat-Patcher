#!/bin/zsh

set -eu
setopt PIPE_FAIL

script_dir=${0:A:h}
source_files=(
    "$script_dir/vrchat-memory-policy-controller.c"
    "$script_dir/pcvr-bundle-identity.c"
    "$script_dir/pcvr-memory-policy.c"
    "$script_dir/pcvr-runtime-images.c"
    "$script_dir/pcvr-status-protocol.c"
    "$script_dir/pcvr-target.c"
)
build_dir="$script_dir/build"
output="$build_dir/vrchat-memory-policy-controller"
expected_sha=824c993abf60879472aa448ac89b59816ea232ef81d17850887aaa151aa7254c

/bin/mkdir -p "$build_dir"
temporary_dir=''
temporary=''
cleanup() {
    if [[ -n "$temporary" && ( -e "$temporary" || -L "$temporary" ) ]]; then
        /bin/unlink "$temporary"
    fi
    if [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
        /bin/rmdir "$temporary_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

temporary_dir=$(/usr/bin/mktemp -d "$build_dir/.controller-build.XXXXXX")
temporary="$temporary_dir/controller"

/usr/bin/xcrun clang \
    -std=c11 -O2 \
    -Wall -Wextra -Werror -Wconversion -Wsign-conversion \
    "${source_files[@]}" \
    -framework CoreFoundation -framework Security \
    -o "$temporary"
/usr/bin/codesign --force --sign - \
    --identifier io.playcover.vrchat-memory-policy.controller \
    "$temporary"
/usr/bin/codesign --verify --strict --verbose=2 "$temporary"
actual_sha=$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')
if [[ "$actual_sha" != "$expected_sha" ]]; then
    print -u2 -- "Reviewed controller SHA-256 mismatch."
    print -u2 -- "Expected: $expected_sha"
    print -u2 -- "Found:    $actual_sha"
    exit 79
fi
/bin/chmod 0755 "$temporary"
/bin/mv "$temporary" "$output"

print -- "Built: $output"
/usr/bin/shasum -a 256 "$output"
