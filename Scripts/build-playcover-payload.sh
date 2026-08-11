#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

repo_root=${0:A:h:h}
source_root=${1:-$repo_root/Build/PlayCover}
output=${2:-$repo_root/Artifacts/PlayCover.app}
output_name=${output:t}
derived_data_parent="$repo_root/Build/DerivedData"
resolved_line='github "PlayCover/PlayTools" "f17b9211211fb4cf5652d4930ea82613ee3c92a5"'

[[ $source_root == /* && -d $source_root/.git ]] || {
    print -u2 -- "Usage: ${0:t} /absolute/patched/PlayCover /absolute/output/PlayCover.app"
    exit 64
}
[[ $output == /* && ${output:t} == PlayCover.app ]] || {
    print -u2 -- "Output must be an absolute path ending in PlayCover.app."
    exit 64
}
/bin/mkdir -p "${output:h}"
source_root=${source_root:A}
output_parent=${output:h:A}
output="$output_parent/$output_name"
if [[ -e $output || -L $output ]]; then
    print -u2 -- "Refusing to replace existing output: $output"
    exit 73
fi

/bin/mkdir -p "$derived_data_parent"
derived_data=$(/usr/bin/mktemp -d "$derived_data_parent/PlayCover.XXXXXX")
output_stage=$(/usr/bin/mktemp -d "${output:h}/.pcvr-payload.XXXXXX")
staged_app="$output_stage/PlayCover.app"
cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -d $derived_data ]]; then
        /bin/rm -rf -- "$derived_data"
    fi
    if [[ -d $output_stage ]]; then
        /bin/rm -rf -- "$output_stage"
    fi
    exit $result
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/bin/zsh "$repo_root/PlayCoverPatch/check.sh" --applied "$source_root"

resolved="$source_root/Cartfile.resolved"
[[ -f $resolved && ! -L $resolved && $(<"$resolved") == $resolved_line ]] || {
    print -u2 -- "Missing or unreviewed PlayTools resolution. Expected v3.1.0."
    exit 79
}

carthage=''
for candidate in /opt/homebrew/bin/carthage /usr/local/bin/carthage /opt/local/bin/carthage; do
    if [[ -x $candidate ]]; then
        carthage=$candidate
        break
    fi
done
[[ -n $carthage ]] || {
    print -u2 -- "Carthage is required to build pinned PlayTools v3.1.0."
    exit 69
}
carthage_version=$($carthage version)
[[ $carthage_version == 0.40.0 ]] || {
    print -u2 -- "Unsupported Carthage version: $carthage_version (expected 0.40.0)."
    exit 79
}

env -i HOME="$HOME" PATH="${carthage:h}:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    /bin/zsh "$repo_root/PlayCoverPatch/dependencies/PlayTools/bootstrap-and-build.sh" \
        "$source_root" "$carthage"

build_log="$derived_data/xcodebuild.log"
if ! /usr/bin/env FASTLANE=1 /usr/bin/xcodebuild \
        -project "$source_root/PlayCover.xcodeproj" \
        -scheme PlayCover \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$derived_data/SourcePackages" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
        build >"$build_log" 2>&1; then
    print -u2 -- "Customized PlayCover xcodebuild failed; final diagnostics:"
    /usr/bin/tail -n 200 "$build_log" >&2
    exit 70
fi
print -- "Customized PlayCover xcodebuild succeeded."

built_app="$derived_data/Build/Products/Release/PlayCover VRChat.app"
[[ -d $built_app && ! -L $built_app ]] || {
    print -u2 -- "xcodebuild did not produce PlayCover VRChat.app."
    exit 70
}

/usr/bin/install -m 0644 "$repo_root/Compatibility/PCVRPatchManifest.json" \
    "$built_app/Contents/Resources/PCVRPatchManifest.json"
/bin/zsh "$repo_root/Scripts/build-icons.sh" runtime \
    "$built_app/Contents/Resources/PCVRRuntime.icns"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
    "$built_app/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile PCVRRuntime.icns' \
        "$built_app/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string PCVRRuntime.icns' \
        "$built_app/Contents/Info.plist"
fi

/usr/bin/codesign --force --sign - \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    "$built_app"
/bin/zsh "$repo_root/Scripts/verify-playcover-payload.sh" "$built_app"

/usr/bin/ditto --noqtn "$built_app" "$staged_app"
/bin/zsh "$repo_root/Scripts/verify-playcover-payload.sh" "$staged_app"

if [[ -e $output || -L $output ]]; then
    print -u2 -- "Output appeared while building; refusing to replace it: $output"
    exit 73
fi
/bin/mv "$staged_app" "$output"
/bin/zsh "$repo_root/Scripts/verify-playcover-payload.sh" "$output"

/usr/bin/swift build --package-path "$repo_root" -c release --product pcvr-manifest-tool
bin_dir=$(/usr/bin/swift build --package-path "$repo_root" -c release --show-bin-path)
manifest_tool="$bin_dir/pcvr-manifest-tool"
package_manifest="$repo_root/Controller/package/ControllerPackageManifest.json"
package_review_dir="$output_stage/controller-package-review"
/bin/mkdir "$package_review_dir"
reviewed_package="$package_review_dir/PlayCoverVRChatMemoryPolicy.pkg"
/bin/zsh "$repo_root/Controller/package/build-package.sh" \
    --output "$reviewed_package"
/bin/zsh "$repo_root/Controller/package/verify-package.sh" \
    "$reviewed_package" "$package_manifest"
candidate_output="${output:h}/patchedPlayCover-candidate.json"
[[ ! -e "$candidate_output" && ! -L "$candidate_output" ]] || {
    print -u2 -- "Refusing to replace existing candidate manifest: $candidate_output"
    exit 73
}
candidate_stage="$output_stage/patchedPlayCover-candidate.json"
"$manifest_tool" propose \
    "$repo_root/Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json" \
    "$output" \
    "$package_manifest" \
    "$candidate_stage"
/usr/bin/python3 "$repo_root/Scripts/validate-manifest.py" "$candidate_stage"
"$manifest_tool" verify "$candidate_stage" patched "$output"
/bin/mv "$candidate_stage" "$candidate_output"

print -- "Built reviewed-source payload candidate: $output"
print -- "The candidate identity is untrusted until independently reviewed and committed."
