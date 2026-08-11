#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

script_dir=${0:A:h}
package="$script_dir/package/build/PlayCoverVRChatMemoryPolicy.pkg"

print -u2 -- "The legacy direct root installer has been retired."
print -u2 -- "Building the exact reviewed macOS Installer component package instead."
if [[ -e "$package" || -L "$package" ]]; then
    print -u2 -- "Refusing to replace existing package output: $package"
    print -u2 -- "Remove the disposable build artifact explicitly, then retry."
    exit 73
fi
/bin/zsh "$script_dir/package/build-package.sh" --output "$package"
/bin/zsh "$script_dir/package/verify-package.sh" "$package"
print -- "Built and verified: $package"
print -- "Open this exact package in macOS Installer to request administrator authorization."
print -- "This script does not invoke sudo, Installer, or modify installed state."
