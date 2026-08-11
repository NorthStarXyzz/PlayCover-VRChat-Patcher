#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
kind=${1:-}
output=${2:-}

case $kind in
    patcher)
        source="$repo_root/Design/Logo/pcvrpatcher-app-icon-v10.png"
        expected_sha=9962e1e2281a1c50f92a99df50937215707fb0a3f79895f0c1bd2c4046bf4719
        ;;
    runtime)
        source="$repo_root/Design/Logo/playcover-vrchat-app-icon-v10.png"
        expected_sha=9962e1e2281a1c50f92a99df50937215707fb0a3f79895f0c1bd2c4046bf4719
        ;;
    *)
        print -u2 -- "Usage: ${0:t} patcher|runtime /absolute/output.icns"
        exit 64
        ;;
esac

[[ $output == /* && ${output:e} == icns ]] || {
    print -u2 -- "Output must be an absolute .icns path."
    exit 64
}
[[ -f $source && ! -L $source ]] || {
    print -u2 -- "Reviewed icon master is missing: $source"
    exit 66
}
actual_sha=$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')
[[ $actual_sha == $expected_sha ]] || {
    print -u2 -- "Reviewed icon master hash mismatch for $kind."
    exit 79
}
if [[ -e $output || -L $output ]]; then
    print -u2 -- "Refusing to replace icon output: $output"
    exit 73
fi

/bin/mkdir -p "${output:h}"
work=$(/usr/bin/mktemp -d "${output:h}/.pcvr-icon.XXXXXX")
iconset="$work/PCVR.iconset"
cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    [[ ! -d $work ]] || /bin/rm -rf -- "$work"
    exit $result
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/bin/mkdir "$iconset"
for spec in \
    icon_16x16.png:16 \
    icon_16x16@2x.png:32 \
    icon_32x32.png:32 \
    icon_32x32@2x.png:64 \
    icon_128x128.png:128 \
    icon_128x128@2x.png:256 \
    icon_256x256.png:256 \
    icon_256x256@2x.png:512 \
    icon_512x512.png:512 \
    icon_512x512@2x.png:1024; do
    name=${spec%%:*}
    pixels=${spec##*:}
    /usr/bin/sips -s format png -z "$pixels" "$pixels" "$source" \
        --out "$iconset/$name" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset" -o "$work/PCVR.icns"
[[ -f "$work/PCVR.icns" && ! -L "$work/PCVR.icns" ]] || {
    print -u2 -- "iconutil did not produce an ICNS file."
    exit 70
}
/bin/mv "$work/PCVR.icns" "$output"
print -- "Built reviewed $kind icon: $output"
