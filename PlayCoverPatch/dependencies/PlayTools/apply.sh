#!/bin/zsh

set -eu
setopt PIPE_FAIL

script_dir=${0:A:h}
checkout=${1:-}
readonly expected_patch_sha256=2b70506b9b0b4bb349f2929357772a3e222e8bd9de22228fc3bf6ceaf6599057
readonly expected_resolution_sha256=861745ad8d24152ba8e00f426164b618e50a131e164eb17499d7d9f82069caf6
readonly resolution_relative=PlayTools.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

if [[ "$checkout" != /* ]]; then
    print -u2 -- "Usage: /bin/zsh $0 /absolute/path/to/Carthage/Checkouts/PlayTools"
    exit 64
fi
patch_file="$script_dir/patches/0001-xcode26-rich-presence-buttons.patch"
resolution_overlay="$script_dir/overlay/Package.resolved"
for artifact in "$patch_file" "$resolution_overlay"; do
    if [[ ! -f "$artifact" || -L "$artifact" || \
          $(/usr/bin/stat -f '%p' "$artifact") != 100644 ]]; then
        print -u2 -- "Reviewed PlayTools artifact must be regular mode 100644: $artifact"
        exit 66
    fi
done
patch_sha=$(/usr/bin/shasum -a 256 "$patch_file")
resolution_sha=$(/usr/bin/shasum -a 256 "$resolution_overlay")
if [[ "${patch_sha%% *}" != "$expected_patch_sha256" || \
      "${resolution_sha%% *}" != "$expected_resolution_sha256" ]]; then
    print -u2 -- "Reviewed PlayTools patch or SwiftPM resolution hash differs."
    exit 79
fi

if /bin/zsh "$script_dir/check.sh" --applied "$checkout" \
    >/dev/null 2>&1; then
    /bin/zsh "$script_dir/check.sh" --applied "$checkout"
    print -- "PlayTools compatibility patch and SwiftPM resolution were already applied; no changes made."
    exit 0
fi

resolution_destination="$checkout/$resolution_relative"
if [[ -e "$resolution_destination" || -L "$resolution_destination" ]]; then
    print -u2 -- "Existing PlayTools SwiftPM resolution is not the exact final state; refusing to replace it."
    exit 79
fi

if /bin/zsh "$script_dir/check.sh" --patched "$checkout" >/dev/null 2>&1; then
    /bin/zsh "$script_dir/check.sh" --patched "$checkout"
else
    /bin/zsh "$script_dir/check.sh" --preimage "$checkout"
    checkout=${checkout:A}
    /usr/bin/patch -C -p1 -d "$checkout" -i "$patch_file"
    /usr/bin/patch -N -s -V none -p1 -d "$checkout" -i "$patch_file"
    /bin/zsh "$script_dir/check.sh" --patched "$checkout"
fi

checkout=${checkout:A}
resolution_parent="${resolution_destination:h:h}"
if [[ ! -d "$resolution_parent" || -L "$resolution_parent" ]]; then
    print -u2 -- "Reviewed SwiftPM parent directory is missing or unsafe: $resolution_parent"
    exit 66
fi
resolution_directory="${resolution_destination:h}"
if [[ -e "$resolution_directory" || -L "$resolution_directory" ]]; then
    print -u2 -- "Unexpected existing SwiftPM resolution directory: $resolution_directory"
    exit 79
fi

resolution_staging=$(/usr/bin/mktemp -d "$resolution_parent/.pcvr-swiftpm.XXXXXX")
cleanup_resolution() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -n ${resolution_staging:-} && -d "$resolution_staging" ]]; then
        /bin/rm -R -- "$resolution_staging"
    fi
    exit "$result"
}
trap cleanup_resolution EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/bin/chmod 0755 "$resolution_staging"
/bin/mkdir -m 0755 "$resolution_staging/configuration"
/usr/bin/install -m 0644 "$resolution_overlay" \
    "$resolution_staging/Package.resolved"
/usr/bin/cmp -s "$resolution_overlay" \
    "$resolution_staging/Package.resolved"

/bin/mv -n "$resolution_staging" "$resolution_directory"
if [[ -d "$resolution_staging" ]]; then
    print -u2 -- "SwiftPM resolution destination appeared concurrently; refusing to overwrite it."
    exit 79
fi
resolution_staging=
trap - EXIT INT TERM HUP

/bin/zsh "$script_dir/check.sh" --applied "$checkout"

print -- "Applied reviewed PlayTools Xcode 26 patch and exact SwiftPM resolution."
