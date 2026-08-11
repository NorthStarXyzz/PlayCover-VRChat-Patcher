#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
app=${1:-}
[[ $app == /* && -d $app && ! -L $app && \
   ( ${app:t} == PlayCover.app || ${app:t} == 'PlayCover VRChat.app' ) ]] || {
    print -u2 -- "Usage: ${0:t} /absolute/path/PlayCover[ VRChat].app"
    exit 64
}

info_plist="$app/Contents/Info.plist"
[[ -f $info_plist && ! -L $info_plist ]] || {
    print -u2 -- "Missing PlayCover Info.plist."
    exit 66
}
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$info_plist")
[[ $executable_name == 'PlayCover VRChat' ]] || {
    print -u2 -- "Unexpected customized PlayCover executable name: $executable_name"
    exit 79
}
main="$app/Contents/MacOS/$executable_name"
[[ -f $main && ! -L $main ]] || {
    print -u2 -- "Missing PlayCover executable."
    exit 66
}

# The patched PlayCover coordinator invokes the root runner by fixed path and
# embeds its reviewed SHA.  Keep that compiled identity paired with the exact
# package that the Patcher will install; checking only the outer package and
# app signatures would otherwise allow a stale coordinator to pass and fail
# later at launch with a misleading sha256_mismatch error.
package_manifest="$repo_root/Controller/package/ControllerPackageManifest.json"
reviewed_runner_sha=$(/usr/bin/plutil -extract controllerPackage.runner.sha256 raw \
    -o - "$package_manifest")
runner_pin_count=$(/usr/bin/strings "$main" | \
    /usr/bin/grep -F -c -- "$reviewed_runner_sha" || true)
[[ "$runner_pin_count" -ge 1 ]] || {
    print -u2 -- "PlayCover coordinator does not embed the reviewed runner SHA: $reviewed_runner_sha"
    exit 79
}

reviewed_stamp="$repo_root/Compatibility/PCVRPatchManifest.json"
embedded_stamp="$app/Contents/Resources/PCVRPatchManifest.json"
if [[ ! -f $embedded_stamp || -L $embedded_stamp ]] || \
   ! /usr/bin/cmp -s "$reviewed_stamp" "$embedded_stamp"; then
    print -u2 -- "PlayCover embeds a missing or stale PCVR patch manifest."
    exit 79
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$info_plist")
[[ $bundle_id == io.github.northstarxyzz.PlayCoverVRChat ]] || {
    print -u2 -- "Unexpected PlayCover bundle identifier: $bundle_id"
    exit 79
}

display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' \
    "$info_plist")
[[ $display_name == 'PlayCover VRChat' ]] || {
    print -u2 -- "Unexpected customized PlayCover display name: $display_name"
    exit 79
}

icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
    "$info_plist")
[[ $icon_name == PCVRRuntime.icns && \
   -f "$app/Contents/Resources/PCVRRuntime.icns" && \
   ! -L "$app/Contents/Resources/PCVRRuntime.icns" ]] || {
    print -u2 -- "Customized PlayCover is missing its reviewed runtime icon."
    exit 79
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

code_directory=$(/usr/bin/codesign -dvvv "$main" 2>&1 | \
    /usr/bin/awk '/^CodeDirectory / { print; exit }')
[[ $code_directory == *'(runtime)'* || $code_directory == *',runtime)'* ]] || {
    print -u2 -- "PlayCover executable is not protected by Hardened Runtime."
    exit 79
}

if /usr/bin/codesign -d --entitlements :- "$main" 2>/dev/null | \
   /usr/bin/grep -F -q '<key>com.apple.security.cs.disable-library-validation</key>'; then
    print -u2 -- "PlayCover unexpectedly disables Library Validation."
    exit 79
fi

if [[ -e "$app/Contents/Frameworks/Sparkle.framework" || \
      -L "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    print -u2 -- "Disabled Sparkle framework is still embedded."
    exit 79
fi

unexpected_dependencies=$(/usr/bin/otool -L "$main" | /usr/bin/awk '
    NR > 1 {
        dependency = $1
        if (dependency !~ /^\/System\/Library\// && dependency !~ /^\/usr\/lib\//) {
            print dependency
        }
    }
')
if [[ -n $unexpected_dependencies ]]; then
    print -u2 -- "PlayCover has non-system launch dependencies that require an explicit signing-team review:"
    print -u2 -- "$unexpected_dependencies"
    exit 79
fi

print -- "PlayCover launchability invariants passed: $app"
