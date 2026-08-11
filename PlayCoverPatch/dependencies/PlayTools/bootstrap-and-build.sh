#!/bin/zsh

set -eu
setopt PIPE_FAIL

script_dir=${0:A:h}
patch_root=${script_dir:h:h}
source_root=${1:-}
carthage=${2:-/opt/homebrew/bin/carthage}

if [[ "$source_root" != /* || "$carthage" != /* ]]; then
    print -u2 -- "Usage: /bin/zsh $0 /absolute/path/to/patched/PlayCover /absolute/path/to/carthage"
    exit 64
fi
source_root=${source_root:A}
carthage=${carthage:A}
if [[ ! -x "$carthage" || -d "$carthage" ]]; then
    print -u2 -- "Carthage is not executable: $carthage"
    exit 66
fi

/bin/zsh "$patch_root/check.sh" --applied "$source_root"

checkout="$source_root/Carthage/Checkouts/PlayTools"
if [[ -e "$checkout" ]]; then
    if ! /bin/zsh "$script_dir/check.sh" --preimage "$checkout" >/dev/null 2>&1 && \
       ! /bin/zsh "$script_dir/check.sh" --patched "$checkout" >/dev/null 2>&1 && \
       ! /bin/zsh "$script_dir/check.sh" --applied "$checkout" >/dev/null 2>&1; then
        print -u2 -- "Existing PlayTools checkout is not a reviewed preimage, intermediate, or final tree."
        print -u2 -- "Refusing to overwrite it: $checkout"
        exit 79
    fi
else
    "$carthage" bootstrap --no-build --no-use-binaries \
        --project-directory "$source_root" PlayTools
fi

/bin/zsh "$script_dir/apply.sh" "$checkout"
FASTLANE=1 "$carthage" build --use-xcframeworks \
    --project-directory "$source_root" PlayTools
/bin/zsh "$script_dir/check.sh" --applied "$checkout"

print -- "Built PlayTools from the exact reviewed Xcode 26 + SwiftPM postimage."
