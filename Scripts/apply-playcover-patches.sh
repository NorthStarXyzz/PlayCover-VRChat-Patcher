#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
playcover_tree=${1:-$repo_root/Build/PlayCover}

[[ -d $playcover_tree/.git ]] || {
    print -u2 -- "not a PlayCover checkout: $playcover_tree"
    exit 1
}
/bin/zsh "$repo_root/PlayCoverPatch/apply.sh" "$playcover_tree"
