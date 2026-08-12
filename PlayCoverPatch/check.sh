#!/bin/zsh

set -eu
setopt PIPE_FAIL

readonly expected_upstream=55638e98f36eac1f3d09803799480e9d83f663f8
readonly expected_playtools_commit=f17b9211211fb4cf5652d4930ea82613ee3c92a5
readonly expected_playcover_resolution_sha256=324e7c5d4b57421c2a4098cc4dc944da093382098c2595a1f84dcd9ecf848b04
readonly playcover_resolution_relative=PlayCover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
script_dir=${0:A:h}
mode=${1:-}
source_root=${2:-}
package_manifest="$script_dir/../Controller/package/ControllerPackageManifest.json"
reviewed_runner_sha=$(/usr/bin/plutil -extract controllerPackage.runner.sha256 raw \
    -o - "$package_manifest")

usage() {
    print -u2 -- "Usage: /bin/zsh $0 --source|--applied /path/to/PlayCover"
    exit 64
}

[[ "$mode" == --source || "$mode" == --applied ]] || usage
[[ -n "$source_root" ]] || usage
source_root=${source_root:A}

if [[ ! -d "$source_root/.git" ]]; then
    print -u2 -- "Not a Git worktree: $source_root"
    exit 66
fi

actual_head=$(/usr/bin/git -C "$source_root" rev-parse HEAD)
if [[ "$actual_head" != "$expected_upstream" ]]; then
    print -u2 -- "Unsupported upstream commit."
    print -u2 -- "Expected: $expected_upstream"
    print -u2 -- "Found:    $actual_head"
    exit 65
fi

if /usr/bin/grep -R -n -E \
    'diagnosticEmpty|memoryShim|PlayCoverCompatEmpty|PlayCoverMemoryShim|VRChatMemoryPatch' \
    "$script_dir/overlay" "$script_dir/patches"; then
    print -u2 -- "Forbidden legacy VRChat patch/profile artifact found."
    exit 79
fi

resolved_overlay="$script_dir/overlay/Cartfile.resolved"
expected_resolved_line="github \"PlayCover/PlayTools\" \"$expected_playtools_commit\""
if [[ ! -f "$resolved_overlay" ]] || \
   [[ $(/usr/bin/wc -l < "$resolved_overlay" | /usr/bin/tr -d ' ') != 1 ]] || \
   ! /usr/bin/grep -F -x -q -- "$expected_resolved_line" "$resolved_overlay"; then
    print -u2 -- "Reviewed Cartfile.resolved does not contain the exact PlayTools commit."
    exit 79
fi

playcover_resolution_overlay="$script_dir/overlay/$playcover_resolution_relative"
if [[ ! -f "$playcover_resolution_overlay" || -L "$playcover_resolution_overlay" || \
      $(/usr/bin/stat -f '%p' "$playcover_resolution_overlay") != 100644 ]]; then
    print -u2 -- "Reviewed PlayCover SwiftPM resolution must be a regular mode-100644 file."
    exit 79
fi
playcover_resolution_sha=$(/usr/bin/shasum -a 256 "$playcover_resolution_overlay")
if [[ "${playcover_resolution_sha%% *}" != "$expected_playcover_resolution_sha256" ]]; then
    print -u2 -- "Reviewed PlayCover SwiftPM resolution hash differs."
    exit 79
fi

require_resolution_count() {
    local expected=$1
    local needle=$2
    local count
    count=$(/usr/bin/grep -F -c -- "$needle" "$playcover_resolution_overlay" || true)
    if [[ "$count" != "$expected" ]]; then
        print -u2 -- "Expected $expected PlayCover resolution match(es) for: $needle"
        exit 79
    fi
}

require_resolution_count 7 '"identity" :'
require_resolution_count 7 '"revision" :'
require_resolution_count 1 '"revision" : "cb253e111528c082381af54b67dab7a15eefde16"'
require_resolution_count 1 '"revision" : "cdef39b1f7f539ff722e7954746b2876ef12178c"'
require_resolution_count 1 '"revision" : "1f6c3ebbc361311e5abae53947ac5ade7542a575"'
require_resolution_count 1 '"revision" : "4ee23a45f25763f61903b1111bce7605617a4dd7"'
require_resolution_count 1 '"revision" : "6a52f3251125d74daf04fcbd5e6f08a75d074382"'
require_resolution_count 1 '"revision" : "6d808c0522471d9f8892c85601164ed5b462f8c0"'
require_resolution_count 1 '"revision" : "3d6871d5b4a5cd519adf233fbb576e0a2af71c17"'

playcover_resolution_destination="$source_root/$playcover_resolution_relative"
playcover_swiftpm_directory="${playcover_resolution_destination:h}"
if [[ "$mode" == --source && \
      ( -e "$playcover_swiftpm_directory" || -L "$playcover_swiftpm_directory" ) ]]; then
    print -u2 -- "Source PlayCover checkout already contains ignored SwiftPM state."
    exit 79
fi

/bin/zsh -n "$script_dir/apply.sh" "$script_dir/check.sh" "$script_dir/run-tests.sh" \
    "$script_dir/dependencies/PlayTools/apply.sh" \
    "$script_dir/dependencies/PlayTools/bootstrap-and-build.sh" \
    "$script_dir/dependencies/PlayTools/check.sh" \
    "$script_dir/dependencies/PlayTools/test.sh"
/bin/zsh "$script_dir/run-tests.sh"

if [[ "$mode" == --source ]]; then
    temporary_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pcvr-patch-check.XXXXXX")
    cleanup() {
        local result=$?
        trap - EXIT INT TERM HUP
        if [[ -d "$temporary_dir" ]]; then
            /bin/rm -rf -- "$temporary_dir"
        fi
        exit "$result"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    temporary_index="$temporary_dir/index"
    GIT_INDEX_FILE="$temporary_index" \
        /usr/bin/git -C "$source_root" read-tree "$expected_upstream"

    while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
        [[ -n "$patch_name" ]] || continue
        patch_path="$script_dir/$patch_name"
        if [[ ! -f "$patch_path" ]]; then
            print -u2 -- "Missing series patch: $patch_path"
            exit 66
        fi
        GIT_INDEX_FILE="$temporary_index" \
            /usr/bin/git -C "$source_root" apply \
                --cached --whitespace=error-all "$patch_path"
    done < "$script_dir/series"

    GIT_INDEX_FILE="$temporary_index" \
        /usr/bin/git -C "$source_root" diff --cached --check
    print -- "Patch series applies cleanly to $expected_upstream."
    exit 0
fi

/usr/bin/python3 "$script_dir/Tests/test-settings-lifecycle.py" \
    --applied-root "$source_root"

destination="$source_root/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
if [[ ! -f "$destination" ]]; then
    print -u2 -- "Applied overlay is missing: $destination"
    exit 66
fi
/usr/bin/cmp -s \
    "$script_dir/overlay/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift" \
    "$destination" || {
        print -u2 -- "Applied coordinator differs from the reviewed overlay."
        exit 79
    }

resolved_destination="$source_root/Cartfile.resolved"
if [[ ! -f "$resolved_destination" ]]; then
    print -u2 -- "Applied dependency lock is missing: $resolved_destination"
    exit 66
fi
/usr/bin/cmp -s "$resolved_overlay" "$resolved_destination" || {
    print -u2 -- "Applied Cartfile.resolved differs from the reviewed overlay."
    exit 79
}

playcover_configuration_directory="$playcover_swiftpm_directory/configuration"
if [[ ! -d "$playcover_swiftpm_directory" || -L "$playcover_swiftpm_directory" || \
      ! -d "$playcover_configuration_directory" || -L "$playcover_configuration_directory" || \
      ! -f "$playcover_resolution_destination" || -L "$playcover_resolution_destination" ]]; then
    print -u2 -- "Applied PlayCover SwiftPM overlay structure is missing or unsafe."
    exit 79
fi
if [[ $(/usr/bin/stat -f '%p' "$playcover_swiftpm_directory") != 40755 || \
      $(/usr/bin/stat -f '%p' "$playcover_configuration_directory") != 40755 || \
      $(/usr/bin/stat -f '%p' "$playcover_resolution_destination") != 100644 ]]; then
    print -u2 -- "Applied PlayCover SwiftPM overlay modes differ from the reviewed state."
    exit 79
fi
if ! /usr/bin/cmp -s "$playcover_resolution_overlay" \
    "$playcover_resolution_destination"; then
    print -u2 -- "Applied PlayCover SwiftPM resolution differs from the reviewed overlay."
    exit 79
fi
swiftpm_child_count=$(/usr/bin/find "$playcover_swiftpm_directory" \
    -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if [[ "$swiftpm_child_count" != 2 ]] || \
   [[ -n $(/usr/bin/find "$playcover_configuration_directory" -mindepth 1 -print -quit) ]]; then
    print -u2 -- "Applied PlayCover SwiftPM overlay contains unreviewed extra state."
    exit 79
fi

provenance_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pcvr-provenance-check.XXXXXX")
cleanup_provenance() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -d "$provenance_dir" ]]; then
        /bin/rm -rf -- "$provenance_dir"
    fi
    exit "$result"
}
trap cleanup_provenance EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

expected_index="$provenance_dir/index"
GIT_INDEX_FILE="$expected_index" \
    /usr/bin/git -C "$source_root" read-tree "$expected_upstream"
while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
    [[ -n "$patch_name" ]] || continue
    GIT_INDEX_FILE="$expected_index" \
        /usr/bin/git -C "$source_root" apply \
            --cached --whitespace=error-all "$script_dir/$patch_name"
done < "$script_dir/series"

expected_tracked="$provenance_dir/expected-tracked"
actual_tracked="$provenance_dir/actual-tracked"
GIT_INDEX_FILE="$expected_index" \
    /usr/bin/git -C "$source_root" diff --cached --name-only \
        --no-renames "$expected_upstream" > "$expected_tracked"
print -- "Cartfile.resolved" >> "$expected_tracked"
LC_ALL=C /usr/bin/sort -u -o "$expected_tracked" "$expected_tracked"
/usr/bin/git -C "$source_root" diff --name-only --no-renames \
    "$expected_upstream" > "$actual_tracked"
LC_ALL=C /usr/bin/sort -u -o "$actual_tracked" "$actual_tracked"
if ! /usr/bin/cmp -s "$expected_tracked" "$actual_tracked"; then
    print -u2 -- "Applied tracked change set differs from series plus dependency overlay."
    /usr/bin/diff -u "$expected_tracked" "$actual_tracked" >&2 || true
    exit 79
fi

expected_untracked="$provenance_dir/expected-untracked"
actual_untracked="$provenance_dir/actual-untracked"
{
    print -- "PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
    print -- "$playcover_resolution_relative"
} > "$expected_untracked"
{
    /usr/bin/git -C "$source_root" ls-files --others --exclude-standard
    /usr/bin/git -C "$source_root" ls-files --others -- \
        "$playcover_resolution_relative"
} > "$actual_untracked"
LC_ALL=C /usr/bin/sort -u -o "$expected_untracked" "$expected_untracked"
LC_ALL=C /usr/bin/sort -u -o "$actual_untracked" "$actual_untracked"
if ! /usr/bin/cmp -s "$expected_untracked" "$actual_untracked"; then
    print -u2 -- "Applied untracked file set differs from the reviewed overlay set."
    /usr/bin/diff -u "$expected_untracked" "$actual_untracked" >&2 || true
    exit 79
fi

integer expected_file_number=0
while IFS= read -r tracked_path || [[ -n "$tracked_path" ]]; do
    [[ -n "$tracked_path" ]] || continue
    expected_file_number+=1
    expected_file="$provenance_dir/expected-$expected_file_number"
    GIT_INDEX_FILE="$expected_index" \
        /usr/bin/git -C "$source_root" show ":$tracked_path" > "$expected_file"
    if [[ ! -f "$source_root/$tracked_path" ]] || \
       ! /usr/bin/cmp -s "$expected_file" "$source_root/$tracked_path"; then
        print -u2 -- "Applied file differs from reviewed series: $tracked_path"
        exit 79
    fi
    index_record=$(GIT_INDEX_FILE="$expected_index" \
        /usr/bin/git -C "$source_root" ls-files -s -- "$tracked_path")
    expected_mode=${index_record%% *}
    actual_mode=$(/usr/bin/stat -f '%p' "$source_root/$tracked_path")
    if [[ "$actual_mode" != "$expected_mode" ]]; then
        print -u2 -- "Applied file mode differs for $tracked_path: expected $expected_mode, found $actual_mode"
        exit 79
    fi
done < <(GIT_INDEX_FILE="$expected_index" \
    /usr/bin/git -C "$source_root" diff --cached --name-only \
        --no-renames "$expected_upstream")

if [[ $(/usr/bin/stat -f '%p' "$destination") != 100644 ]] || \
   [[ $(/usr/bin/stat -f '%p' "$resolved_destination") != 100644 ]] || \
   [[ $(/usr/bin/stat -f '%p' "$playcover_resolution_destination") != 100644 ]]; then
    print -u2 -- "Reviewed overlays must be regular mode-100644 files."
    exit 79
fi

/usr/bin/git -C "$source_root" diff --check

require_count() {
    local expected=$1
    local pattern=$2
    local path=$3
    local count
    count=$(/usr/bin/grep -E -c -- "$pattern" "$path" || true)
    if [[ "$count" != "$expected" ]]; then
        print -u2 -- "Expected $expected match(es) for '$pattern' in $path; found $count."
        exit 79
    fi
}

require_count 1 'throw VRChatReadOnlyLaunchError\.importRequiresCompatibleCopy' \
    "$source_root/PlayCover/AppInstaller/Installer.swift"
require_count 0 'supportsPlayTools' \
    "$source_root/PlayCover/AppInstaller/Installer.swift"
require_count 1 'try await runVRChatCompatible\(\)' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'runningApp = try await runAppExecAwaitingLaunchServices\(\)' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'appURL: url' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'try await coordinator\.bindLaunchServicesProcess\(' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'pid: runningApp\.processIdentifier' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'bundleURL: runningApp\.bundleURL' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'executableURL: runningApp\.executableURL' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 '_ = runningApp\.forceTerminate\(\)' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 0 'launchServicesSucceeded\(' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 '^                    runAppExec\(\)$' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 0 'launchApp\(mode: \.standard\)|playapp\.launch\.standard' \
    "$source_root/PlayCover/Views/App Views/PlayAppView.swift"
require_count 1 'private func launchVRChatReadOnly\(\) async throws' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 '^                at: url,$' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 '^            at: aliasURL,$' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'func isCodeSignatureValid\(\) throws -> Bool' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 0 'NSPasteboard|controllerStartCommand' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 4 'VRChatMemoryPolicyCoordinator.swift' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 1 'carthage bootstrap --cache-builds --use-xcframeworks' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 0 'carthage update' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 1 'IDENTITY=\$\{EXPANDED_CODE_SIGN_IDENTITY_NAME:--\}' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 1 'Sign to Run Locally' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 0 'IDENTITY=\$\{EXPANDED_CODE_SIGN_IDENTITY_NAME\};' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 3 'Codesign PlayTools' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 1 '--sign \\"\$IDENTITY\\" \\"\$\{BUILT_PRODUCTS_DIR\}' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 0 '--sign \\"\$IDENTITY\\" \$\{BUILT_PRODUCTS_DIR\}' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 0 'Codesign sparkle|Sparkle.framework|sparkle-project/Sparkle|productName = Sparkle|Sparkle in Frameworks' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 1 'officialUpdatesDisabled = true' \
    "$source_root/PlayCover/Views/Sparkle.swift"
require_count 0 'import Sparkle|SPUStandardUpdaterController|checkForUpdates(InBackground)?\(' \
    "$source_root/PlayCover/Views/Sparkle.swift"
require_count 0 'UpdaterViewModel' \
    "$source_root/PlayCover/Views/PlayCoverApp.swift"
require_count 1 'CommandGroup\(replacing: \.appInfo\)' \
    "$source_root/PlayCover/Views/MenuBarView.swift"
require_count 0 'Label\("patch.brand.badge"' \
    "$source_root/PlayCover/Views/MainView.swift"
require_count 1 '"playapp\.keymap"' \
    "$source_root/PlayCover/zh-Hans.lproj/Localizable.strings"
require_count 2 'PRODUCT_BUNDLE_IDENTIFIER = io\.github\.northstarxyzz\.PlayCoverVRChat;' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 2 'PRODUCT_NAME = "PlayCover VRChat";' \
    "$source_root/PlayCover.xcodeproj/project.pbxproj"
require_count 1 '<string>PlayCover VRChat</string>' \
    "$source_root/PlayCover/Info.plist"
require_count 1 'appendingPathComponent\("io\.github\.northstarxyzz\.PlayCoverVRChat"\)' \
    "$source_root/PlayCover/Utils/PlayTools.swift"
require_count 0 'PlayTools\.installOnSystem\(\)' \
    "$source_root/PlayCover/ViewModel/AppsVM.swift"
require_count 1 'fileURLWithPath: "/Applications/PlayCover VRChat\.app"' \
    "$source_root/PlayCover/Utils/AppIntegrity.swift"
require_count 1 'appendingPathComponent\("PlayCover VRChat"\)' \
    "$source_root/PlayCover/Model/PlayApp.swift"
require_count 1 'VRChatMemoryPolicySettingsView\(\)' \
    "$source_root/PlayCover/Views/AppSettingsView.swift"
require_count 1 'ScrollView \{' \
    "$source_root/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
require_count 0 'Form \{' \
    "$source_root/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
require_count 1 'Stepper\(value: \$customGiB' \
    "$source_root/PlayCover/Utils/VRChatMemoryPolicyCoordinator.swift"
require_count 1 'Label\("patch.updates.disabled.title"' \
    "$source_root/PlayCover/Views/Settings/UpdateSettings.swift"
require_count 0 'SUFeedURL|SUPublicEDKey' \
    "$source_root/PlayCover/Info.plist"
require_count 0 'Shell\.runSu|runSu\(' \
    "$destination"
require_count 0 'PCVR/1' \
    "$destination"
require_count 1 'static let protocolVersion = "PCVR/2"' \
    "$destination"
require_count 1 'static let runnerPath = "/usr/local/bin/playcover-vrchat-memory-policy"' \
    "$destination"
require_count 1 'static let controllerBuildID = "capability-vrchat-2026\.2\.30300-1365-r7"' \
    "$destination"
require_count 1 'static let reviewedRunnerSHA256 =' \
    "$destination"
require_count 1 "$reviewed_runner_sha" \
    "$destination"
require_count 1 'static let reviewedMachOCount = 46' \
    "$destination"
require_count 1 '60df094badbe3fb9e8f051f07d2a38a54cfb7bd592c3cf62a69e355050ec5109' \
    "$destination"
require_count 1 '5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4' \
    "$destination"
require_count 1 'static let reviewedMainUUID = "41cadb30ccef3b6c8a1d237ce5d64c42"' \
    "$destination"
require_count 1 'cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3' \
    "$destination"
require_count 1 '664266000f81b937260522d25eda5d81bff3f5d460e5e14512f471c8eaec9afb' \
    "$destination"
require_count 1 'appendingPathComponent\("Applications", isDirectory: true\)' \
    "$destination"
require_count 1 'struct SystemVRChatCompatibleBundleIdentityValidator:' \
    "$destination"
require_count 1 'static func validateExactLocation\(' \
    "$destination"
require_count 1 'SecStaticCodeCheckValidity\(' \
    "$destination"
require_count 1 'kSecCSCheckNestedCode' \
    "$destination"
require_count 1 'PCVR-MACHO-ALLOWLIST/1\\n' \
    "$destination"
require_count 1 'func bindLaunchServicesProcess\(' \
    "$destination"
require_count 1 'guard boundPID == pid else' \
    "$destination"
require_count 0 'func launchServicesSucceeded\(' \
    "$destination"
require_count 1 'case automatic75Percent' \
    "$destination"
require_count 1 'case customGiB\(UInt16\)' \
    "$destination"
require_count 1 'line: "PCVR/2 CANCEL"' \
    "$destination"
require_count 1 '"AuthorizationExecuteWithPrivileges"' \
    "$destination"
require_count 1 'acl_get_file\(path, ACL_TYPE_EXTENDED\)' \
    "$destination"
require_count 1 'acl_get_fd_np\(descriptor, ACL_TYPE_EXTENDED\)' \
    "$destination"
require_count 0 'acl_get_entry\(' \
    "$destination"
require_count 2 'savedError == ENOENT, expectedMetadata != nil \{ return false \}' \
    "$destination"
require_count 1 'static func validateRunnerNode\(' \
    "$destination"
require_count 1 '^            "/",$' \
    "$destination"
require_count 3 'O_RDONLY \| O_CLOEXEC \| O_NOFOLLOW' \
    "$destination"
require_count 2 'try revalidateFixedRunner\(binding\)' \
    "$destination"
require_count 1 'path_replaced_after_authorization' \
    "$destination"
require_count 1 'static let isAvailable = false' \
    "$destination"
require_count 0 '/usr/bin/sudo|Shell\.|NSWorkspace.*Terminal|NSAppleScript' \
    "$destination"
/usr/bin/xcrun swiftc -frontend -parse \
    "$source_root/PlayCover/AppInstaller/Installer.swift" \
    "$source_root/PlayCover/Model/PlayApp.swift" \
    "$source_root/PlayCover/Views/App Views/PlayAppView.swift" \
    "$source_root/PlayCover/Views/MainView.swift" \
    "$source_root/PlayCover/Views/MenuBarView.swift" \
    "$source_root/PlayCover/Views/PlayCoverApp.swift" \
    "$source_root/PlayCover/Views/Settings/PlayCoverSettingsView.swift" \
    "$source_root/PlayCover/Views/Settings/UpdateSettings.swift" \
    "$source_root/PlayCover/Views/Sparkle.swift" \
    "$source_root/PlayCover/Views/AppSettingsView.swift" \
    "$source_root/PlayCover/Utils/PlayTools.swift" \
    "$source_root/PlayCover/Utils/AppIntegrity.swift" \
    "$source_root/PlayCover/Utils/Extensions/PlayAppExtensions.swift" \
    "$source_root/PlayCover/Utils/Extensions/URLExtensions.swift" \
    "$source_root/PlayCover/Utils/Keymapping.swift" \
    "$source_root/PlayCover/ViewModel/AppsVM.swift" \
    "$destination"
/usr/bin/xcrun swiftc -typecheck -swift-version 5 \
    -target arm64-apple-macos12.0 "$destination"
/usr/bin/plutil -lint \
    "$source_root/PlayCover.xcodeproj/project.pbxproj" \
    "$source_root/PlayCover/Info.plist" \
    "$source_root/PlayCover/en.lproj/Localizable.strings" \
    "$source_root/PlayCover/zh-Hans.lproj/Localizable.strings"

/usr/bin/python3 - "$source_root/PlayCover" <<'PY'
import re
import sys
from pathlib import Path

key_pattern = re.compile(r'^"([^"\\]+)"\s*=', re.MULTILINE)

def keys(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return {match.group(1) for match in key_pattern.finditer(text)}

root = Path(sys.argv[1])
english = keys(root / "en.lproj" / "Localizable.strings")
for path in sorted(root.glob("*.lproj/Localizable.strings")):
    if path.parent.name == "en.lproj":
        continue
    missing = sorted(english - keys(path))
    if missing:
        print(f"{path.parent.name} is missing localized keys: {', '.join(missing)}", file=sys.stderr)
        raise SystemExit(79)
PY

print -- "Applied PlayCover patch invariants verified."
