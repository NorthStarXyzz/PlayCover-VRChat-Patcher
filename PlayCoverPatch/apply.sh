#!/bin/zsh

set -eu
setopt PIPE_FAIL

readonly expected_upstream=55638e98f36eac1f3d09803799480e9d83f663f8
readonly swiftpm_relative=PlayCover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
script_dir=${0:A:h}
source_root=${1:-}

if [[ -z "$source_root" ]]; then
    print -u2 -- "Usage: /bin/zsh $0 /path/to/clean/PlayCover"
    exit 64
fi
source_root=${source_root:A}

if [[ ! -d "$source_root/.git" ]]; then
    print -u2 -- "Not a Git worktree: $source_root"
    exit 66
fi

actual_head=$(/usr/bin/git -C "$source_root" rev-parse HEAD)
if [[ "$actual_head" != "$expected_upstream" ]]; then
    print -u2 -- "Refusing unsupported upstream commit: $actual_head"
    exit 65
fi

if [[ -n $(/usr/bin/git -C "$source_root" status --porcelain --untracked-files=all) ]]; then
    print -u2 -- "Refusing to patch a non-clean PlayCover worktree."
    exit 73
fi

destination="$source_root/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
if [[ -e "$destination" || -L "$destination" ]]; then
    print -u2 -- "Refusing to overwrite existing overlay destination: $destination"
    exit 73
fi

swiftpm_destination="$source_root/$swiftpm_relative"
if [[ -e "$swiftpm_destination" || -L "$swiftpm_destination" ]]; then
    print -u2 -- "Refusing to overwrite existing PlayCover SwiftPM state: $swiftpm_destination"
    exit 73
fi

/bin/zsh "$script_dir/check.sh" --source "$source_root"

while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
    [[ -n "$patch_name" ]] || continue
    /usr/bin/git -C "$source_root" apply \
        --whitespace=error-all "$script_dir/$patch_name"
done < "$script_dir/series"

/usr/bin/install -m 0644 \
    "$script_dir/overlay/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift" \
    "$destination"
/usr/bin/install -m 0644 \
    "$script_dir/overlay/Cartfile.resolved" \
    "$source_root/Cartfile.resolved"

swiftpm_parent="${swiftpm_destination:h}"
if [[ ! -d "$swiftpm_parent" || -L "$swiftpm_parent" ]]; then
    print -u2 -- "PlayCover SwiftPM parent is missing or unsafe: $swiftpm_parent"
    exit 66
fi
swiftpm_staging=$(/usr/bin/mktemp -d "$swiftpm_parent/.pcvr-swiftpm.XXXXXX")
cleanup_swiftpm() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -n ${swiftpm_staging:-} && -d "$swiftpm_staging" ]]; then
        /bin/rm -R -- "$swiftpm_staging"
    fi
    exit "$result"
}
trap cleanup_swiftpm EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/bin/chmod 0755 "$swiftpm_staging"
/bin/mkdir -m 0755 "$swiftpm_staging/configuration"
/usr/bin/install -m 0644 \
    "$script_dir/overlay/PlayCover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "$swiftpm_staging/Package.resolved"
/usr/bin/cmp -s \
    "$script_dir/overlay/PlayCover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "$swiftpm_staging/Package.resolved"

/bin/mv -n "$swiftpm_staging" "$swiftpm_destination"
if [[ -d "$swiftpm_staging" ]]; then
    print -u2 -- "PlayCover SwiftPM destination appeared concurrently; refusing to overwrite it."
    exit 79
fi
swiftpm_staging=
trap - EXIT INT TERM HUP

/bin/zsh "$script_dir/check.sh" --applied "$source_root"

print -- "Applied reviewed PlayCover VRChat patch series."
print -- "No commit was created; inspect the resulting git diff before committing."
