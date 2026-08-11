#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
app=${1:-$repo_root/Artifacts/PlayCover VRChat Patcher.app}

[[ $app == /* && -d $app && ! -L $app ]] || {
    print -u2 -- "Usage: ${0:t} /absolute/path/PlayCover\\ VRChat\\ Patcher.app"
    exit 64
}

identifier=$(/usr/bin/codesign -d --verbose=2 "$app" 2>&1 | \
    /usr/bin/awk -F= '$1 == "Identifier" { print $2 }')
[[ $identifier == io.github.northstarxyzz.PlayCover-VRChat-Patcher ]] || {
    print -u2 -- "Unexpected patcher identifier: $identifier"
    exit 79
}
/usr/bin/codesign --verify --strict --verbose=2 "$app"

icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
    "$app/Contents/Info.plist")
[[ $icon_name == PCVRPatcher.icns && \
   -f "$app/Contents/Resources/PCVRPatcher.icns" && \
   ! -L "$app/Contents/Resources/PCVRPatcher.icns" ]] || {
    print -u2 -- "Patcher app is missing its reviewed icon."
    exit 79
}

manifest="$app/Contents/Resources/CompatibilityManifest.json"
/usr/bin/python3 "$repo_root/Scripts/validate-manifest.py" "$manifest"

payload="$app/Contents/Resources/Payload/PlayCover.app"
if [[ -d $payload ]]; then
    controller_package="$app/Contents/Resources/Controller/PlayCoverVRChatMemoryPolicy.pkg"
    [[ -f $controller_package && ! -L $controller_package ]] || {
        print -u2 -- "Payload-bearing Patcher is missing its exact controller package."
        exit 79
    }
    package_count=$(/usr/bin/find "$app/Contents/Resources" -type f -name '*.pkg' -print | \
        /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [[ $package_count == 1 ]] || {
        print -u2 -- "Payload-bearing Patcher must contain exactly one package."
        exit 79
    }
    /bin/zsh "$repo_root/Controller/package/verify-package.sh" \
        "$controller_package"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$payload"
    /bin/zsh "$repo_root/Scripts/verify-playcover-payload.sh" "$payload"
    /usr/bin/swift run --package-path "$repo_root" -c release pcvr-manifest-tool \
        verify "$manifest" patched "$payload"
else
    /usr/bin/python3 -c \
        'import json,sys; value=json.load(open(sys.argv[1])); sys.exit(0 if value.get("patchedPlayCover") is None and value.get("controllerPackage") is None else 79)' \
        "$manifest" || {
        print -u2 -- "Source-only manifest declares a payload or controller package."
        exit 79
    }
    if [[ -e "$app/Contents/Resources/Payload" || \
          -L "$app/Contents/Resources/Payload" || \
          -e "$app/Contents/Resources/Controller" || \
          -L "$app/Contents/Resources/Controller" ]] || \
       /usr/bin/find "$app/Contents/Resources" -name '*.pkg' -print -quit | \
           /usr/bin/grep -q .; then
        print -u2 -- "Source-only Patcher contains a forbidden controller package."
        exit 79
    fi
    print -- "Verified source-only Patcher app; no payload is embedded."
fi

print -- "Patcher app verification passed: $app"
