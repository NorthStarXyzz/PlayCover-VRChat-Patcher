#!/bin/zsh

set -eu
setopt PIPE_FAIL

# Carthage 0.40 exports Checkouts/PlayTools without .git. These digests cover
# every relative path, file/directory mode, and regular-file SHA-256 in that
# exact f17b921 export. The patched intermediate differs only in DiscordIPC.swift;
# the applied state additionally contains the reviewed SwiftPM resolution.
readonly expected_preimage_tree_sha256=fc01f3d38b3cd7fc49e2a87473bd64e420326f14b4cc693eba7d1b64a6b44732
readonly expected_patched_tree_sha256=58a6bff917c3b21642683f9f46930efdf689f137763e549089483301ce3715f7
readonly expected_applied_tree_sha256=6084fc6a95f2c3e940c2bad5b963f12db0a3af95cf2b68860483bdef38916d3e
readonly expected_preimage_sha256=4c9fc2965e7906e14caeb4abb60b9f669b5096fc452a390ef4fdf09f0c46ded2
readonly expected_postimage_sha256=54a55ed15cfcdadbc8eeabd7067b720d16e8a3f0e9b4597328f527757edd2e76
readonly expected_project_sha256=afe79aab89d891931545ce21c80e61462b8ce3e0d0ada3d22663105dd0ac3273
readonly expected_resolution_sha256=861745ad8d24152ba8e00f426164b618e50a131e164eb17499d7d9f82069caf6
readonly target_relative=PlayTools/DiscordActivity/DiscordIPC.swift
readonly project_relative=PlayTools.xcodeproj/project.pbxproj
readonly resolution_relative=PlayTools.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

mode=${1:-}
checkout_input=${2:-}

usage() {
    print -u2 -- "Usage: /bin/zsh $0 --preimage|--patched|--applied /absolute/path/to/Carthage/Checkouts/PlayTools"
    exit 64
}

[[ "$mode" == --preimage || "$mode" == --patched || "$mode" == --applied ]] || usage
[[ "$checkout_input" == /* ]] || usage
[[ -d "$checkout_input" && ! -L "$checkout_input" ]] || {
    print -u2 -- "PlayTools checkout must be a non-symlink directory: $checkout_input"
    exit 66
}
checkout=${checkout_input:A}

file_sha256() {
    local path=$1
    local digest
    digest=$(/usr/bin/shasum -a 256 "$path")
    print -- "${digest%% *}"
}

tree_sha256() {
    local root=$1
    local digest
    digest=$(
        (
            cd "$root"
            LC_ALL=C /usr/bin/find . -mindepth 1 -print0 |
                LC_ALL=C /usr/bin/sort -z |
                while IFS= read -r -d '' relative; do
                    if [[ -L "$relative" ]]; then
                        print -u2 -- "Symlinks are not permitted in the reviewed PlayTools export: ${relative#./}"
                        exit 79
                    fi
                    entry_mode=$(/usr/bin/stat -f '%p' "$relative")
                    if [[ -d "$relative" ]]; then
                        /usr/bin/printf 'd\0%s\0%s\0-\0' \
                            "$entry_mode" "${relative#./}"
                    elif [[ -f "$relative" ]]; then
                        entry_sha=$(file_sha256 "$relative")
                        /usr/bin/printf 'f\0%s\0%s\0%s\0' \
                            "$entry_mode" "${relative#./}" "$entry_sha"
                    else
                        print -u2 -- "Special files are not permitted in the reviewed PlayTools export: ${relative#./}"
                        exit 79
                    fi
                done
        ) | /usr/bin/shasum -a 256
    )
    print -- "${digest%% *}"
}

target="$checkout/$target_relative"
project="$checkout/$project_relative"
resolution="$checkout/$resolution_relative"
for required in "$target" "$project"; do
    if [[ ! -f "$required" || -L "$required" ]]; then
        print -u2 -- "Reviewed PlayTools file must be regular and non-symlink: $required"
        exit 79
    fi
    if [[ $(/usr/bin/stat -f '%p' "$required") != 100644 ]]; then
        print -u2 -- "Reviewed PlayTools file must have mode 100644: $required"
        exit 79
    fi
done

if [[ $(file_sha256 "$project") != "$expected_project_sha256" ]]; then
    print -u2 -- "PlayTools project does not match the reviewed f17b921 export."
    exit 79
fi

actual_file_sha256=$(file_sha256 "$target")
actual_tree_sha256=$(tree_sha256 "$checkout")

case "$mode" in
    --preimage)
        if [[ "$actual_file_sha256" != "$expected_preimage_sha256" || \
              "$actual_tree_sha256" != "$expected_preimage_tree_sha256" ]]; then
            print -u2 -- "PlayTools checkout is not the exact reviewed f17b921 export preimage."
            exit 79
        fi
        print -- "Verified exact exported PlayTools f17b921 preimage."
        ;;
    --patched)
        if [[ "$actual_file_sha256" != "$expected_postimage_sha256" || \
              "$actual_tree_sha256" != "$expected_patched_tree_sha256" ]]; then
            print -u2 -- "PlayTools checkout is not the exact Discord compatibility-patched intermediate."
            exit 79
        fi
        print -- "Verified exact Discord compatibility-patched PlayTools intermediate."
        ;;
    --applied)
        if [[ ! -f "$resolution" || -L "$resolution" || \
              $(/usr/bin/stat -f '%p' "$resolution") != 100644 || \
              $(file_sha256 "$resolution") != "$expected_resolution_sha256" || \
              "$actual_file_sha256" != "$expected_postimage_sha256" || \
              "$actual_tree_sha256" != "$expected_applied_tree_sha256" ]]; then
            print -u2 -- "PlayTools checkout is not the exact reviewed Xcode 26 + SwiftPM postimage."
            exit 79
        fi
        print -- "Verified exact applied PlayTools Xcode 26 patch and SwiftPM resolution."
        ;;
esac
