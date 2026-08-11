#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
manifest=${1:-$repo_root/Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json}
destination=${2:-$repo_root/Build/PlayCover}
commit=$(/usr/bin/plutil -extract playCover.commit raw -o - "$manifest")
repository=$(/usr/bin/plutil -extract playCover.repository raw -o - "$manifest")

if [[ -e $destination ]]; then
    print -u2 -- "destination already exists: $destination"
    exit 1
fi

/usr/bin/git clone --filter=blob:none --no-checkout "$repository" "$destination"
/usr/bin/git -C "$destination" fetch --depth 1 origin "$commit"
/usr/bin/git -C "$destination" checkout --detach "$commit"

actual=$(/usr/bin/git -C "$destination" rev-parse HEAD)
[[ $actual == $commit ]] || {
    print -u2 -- "PlayCover checkout mismatch: $actual"
    exit 1
}

print -- "Fetched reviewed PlayCover commit $actual"

