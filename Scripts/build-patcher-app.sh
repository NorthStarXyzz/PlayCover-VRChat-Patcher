#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
base_manifest="$repo_root/Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json"
output="$repo_root/Artifacts/PlayCover VRChat Patcher.app"
payload=''
payload_manifest=''

usage() {
    print -u2 -- "Usage: ${0:t} [--payload /absolute/path/PlayCover.app --manifest /absolute/path/candidate.json] [--output /absolute/path/Patcher.app]"
}

while (( $# > 0 )); do
    case $1 in
        --payload)
            (( $# >= 2 )) || { usage; exit 64; }
            payload=$2
            shift 2
            ;;
        --manifest)
            (( $# >= 2 )) || { usage; exit 64; }
            payload_manifest=$2
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { usage; exit 64; }
            output=$2
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ $output == /* && ${output:t} == *.app ]] || {
    print -u2 -- "Output must be an absolute .app path."
    exit 64
}
if [[ -e $output || -L $output ]]; then
    print -u2 -- "Refusing to replace existing output: $output"
    exit 73
fi
if [[ -n $payload ]]; then
    [[ $payload == /* && -d $payload && ! -L $payload && ${payload:t} == PlayCover.app ]] || {
        print -u2 -- "Payload must be an absolute, non-symlink PlayCover.app directory."
        exit 64
    }
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$payload"
    /bin/zsh "$repo_root/Scripts/verify-playcover-payload.sh" "$payload"
    [[ $payload_manifest == /* && -f $payload_manifest && ! -L $payload_manifest ]] || {
        print -u2 -- "Payload builds require an absolute, non-symlink candidate manifest."
        exit 64
    }
    /usr/bin/python3 "$repo_root/Scripts/validate-manifest.py" "$payload_manifest"
elif [[ -n $payload_manifest ]]; then
    print -u2 -- "--manifest is valid only together with --payload."
    exit 64
fi

/bin/mkdir -p "${output:h}"
staging_root=$(/usr/bin/mktemp -d "${output:h}/.pcvr-patcher.XXXXXX")
staging_app="$staging_root/PlayCover VRChat Patcher.app"

cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -d $staging_root ]]; then
        /bin/rm -R "$staging_root"
    fi
    exit $result
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/usr/bin/swift build --package-path "$repo_root" -c release \
    --product PlayCoverVRChatPatcher
/usr/bin/swift build --package-path "$repo_root" -c release \
    --product pcvr-manifest-tool
bin_dir=$(/usr/bin/swift build --package-path "$repo_root" -c release --show-bin-path)
patcher_binary="$bin_dir/PlayCoverVRChatPatcher"
manifest_tool="$bin_dir/pcvr-manifest-tool"

[[ -x $patcher_binary && -x $manifest_tool ]] || {
    print -u2 -- "SwiftPM did not produce the expected products."
    exit 70
}

/bin/mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
/usr/bin/install -m 0755 "$patcher_binary" "$staging_app/Contents/MacOS/PlayCoverVRChatPatcher"
/usr/bin/install -m 0644 "$repo_root/Patcher/Resources/Info.plist" "$staging_app/Contents/Info.plist"
/bin/zsh "$repo_root/Scripts/build-icons.sh" patcher \
    "$staging_app/Contents/Resources/PCVRPatcher.icns"

if [[ -n $payload ]]; then
    /bin/mkdir -p \
        "$staging_app/Contents/Resources/Payload" \
        "$staging_app/Contents/Resources/Controller"
    /usr/bin/ditto --noqtn "$payload" "$staging_app/Contents/Resources/Payload/PlayCover.app"
    controller_package="$staging_app/Contents/Resources/Controller/PlayCoverVRChatMemoryPolicy.pkg"
    /bin/zsh "$repo_root/Controller/package/build-package.sh" \
        --output "$controller_package"
    /bin/zsh "$repo_root/Controller/package/verify-package.sh" \
        "$controller_package"
    /usr/bin/install -m 0644 "$payload_manifest" \
        "$staging_app/Contents/Resources/CompatibilityManifest.json"
    "$manifest_tool" verify \
        "$staging_app/Contents/Resources/CompatibilityManifest.json" patched \
        "$staging_app/Contents/Resources/Payload/PlayCover.app"
else
    source_only_manifest="$staging_app/Contents/Resources/CompatibilityManifest.json"
    /usr/bin/python3 - "$base_manifest" "$source_only_manifest" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
value = json.loads(source.read_text(encoding="utf-8"))
value.pop("patchedPlayCover", None)
value.pop("controllerPackage", None)
destination.write_text(
    json.dumps(value, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
PY
    /bin/chmod 0644 "$source_only_manifest"
    /usr/bin/python3 "$repo_root/Scripts/validate-manifest.py" \
        "$source_only_manifest"
    print -- "Building a source-only inspection app (no patched payload)."
fi

/usr/bin/codesign --force --sign - \
    --identifier io.github.northstarxyzz.PlayCover-VRChat-Patcher \
    "$staging_app"
/usr/bin/codesign --verify --strict --verbose=2 "$staging_app"

/bin/mv "$staging_app" "$output"
/bin/rmdir "$staging_root"
staging_root=''

print -- "Built: $output"
/usr/bin/shasum -a 256 "$output/Contents/MacOS/PlayCoverVRChatPatcher"
