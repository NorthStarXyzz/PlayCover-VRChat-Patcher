#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL
umask 022

package_root=${0:A:h}
controller_root=${package_root:h}
repo_root=${controller_root:h}
manifest="$package_root/ControllerPackageManifest.json"
output="$package_root/build/PlayCoverVRChatMemoryPolicy.pkg"

usage() {
    print -u2 -- "Usage: ${0:t} [--output /absolute/path/PlayCoverVRChatMemoryPolicy.pkg]"
}

while (( $# > 0 )); do
    case $1 in
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

[[ "$output" == /* && "${output:t}" == PlayCoverVRChatMemoryPolicy.pkg ]] || {
    print -u2 -- "Output must be an absolute PlayCoverVRChatMemoryPolicy.pkg path."
    exit 64
}
[[ ! -e "$output" && ! -L "$output" ]] || {
    print -u2 -- "Refusing to replace package output: $output"
    exit 73
}
if [[ $(/usr/bin/sw_vers -buildVersion) != 25G70 ]]; then
    [[ ${PCVR_ALLOW_NON_TARGET_BUILD:-0} == 1 ]] || {
        print -u2 -- "Deterministic package builds require macOS build 25G70."
        exit 79
    }
    print -u2 -- "Warning: building an unpublishable package on non-target macOS; runtime installation still requires 25G70."
fi

/usr/bin/python3 -m json.tool "$manifest" >/dev/null
/bin/zsh "$controller_root/build.sh" >/dev/null

expected_controller_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["controller"]["sha256"])' \
    "$manifest")
expected_runner_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["runner"]["sha256"])' \
    "$manifest")
expected_attestation_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["attestation"]["sha256"])' \
    "$manifest")

verify_source() {
    local source_file=$1
    local expected_sha=$2
    local actual_sha

    [[ -f "$source_file" && ! -L "$source_file" ]] || {
        print -u2 -- "Refusing non-regular package input: $source_file"
        exit 79
    }
    actual_sha=$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')
    [[ "$actual_sha" == "$expected_sha" ]] || {
        print -u2 -- "Package input SHA-256 mismatch: $source_file"
        print -u2 -- "Expected: $expected_sha"
        print -u2 -- "Found:    $actual_sha"
        exit 79
    }
}

controller_source="$controller_root/build/vrchat-memory-policy-controller"
runner_source="$controller_root/root-runner"
attestation_source="$package_root/installation.json"
verify_source "$controller_source" "$expected_controller_sha"
verify_source "$runner_source" "$expected_runner_sha"
verify_source "$attestation_source" "$expected_attestation_sha"
/usr/bin/codesign --verify --strict "$controller_source"

/bin/mkdir -p "${output:h}"
staging=$(/usr/bin/mktemp -d "${output:h}/.pcvr-component-package.XXXXXX")
payload_root="$staging/root"
scripts_root="$staging/scripts"
expanded_root="$staging/expanded"
raw_bom="$staging/raw.bom"
bom_listing="$staging/bom-listing"
raw_package="$staging/raw.pkg"
canonical_outer="$staging/canonical-outer.pkg"
normalized_package="$staging/PlayCoverVRChatMemoryPolicy.pkg"

cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -d "$staging" ]]; then
        /bin/rm -R "$staging"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/bin/mkdir -p \
    "$payload_root/usr/local/bin" \
    "$payload_root/usr/local/libexec/playcover-vrchat-memory-policy" \
    "$scripts_root"
/usr/bin/install -m 0755 "$runner_source" \
    "$payload_root/usr/local/bin/playcover-vrchat-memory-policy"
/usr/bin/install -m 0700 "$controller_source" \
    "$payload_root/usr/local/libexec/playcover-vrchat-memory-policy/controller"
/usr/bin/install -m 0644 "$attestation_source" \
    "$payload_root/usr/local/libexec/playcover-vrchat-memory-policy/installation.json"
/usr/bin/install -m 0755 "$package_root/scripts/preinstall" "$scripts_root/preinstall"
/usr/bin/install -m 0755 "$package_root/scripts/postinstall" "$scripts_root/postinstall"
/usr/bin/install -m 0644 "$package_root/scripts/common.zsh" "$scripts_root/common.zsh"

/usr/bin/xattr -cr "$payload_root" "$scripts_root"
/bin/chmod -RN "$payload_root" "$scripts_root"
/bin/chmod 0555 "$payload_root/usr/local/bin/playcover-vrchat-memory-policy"
/bin/chmod 0500 "$payload_root/usr/local/libexec/playcover-vrchat-memory-policy/controller"
/bin/chmod 0444 "$payload_root/usr/local/libexec/playcover-vrchat-memory-policy/installation.json"
/bin/chmod 0555 "$scripts_root/preinstall" "$scripts_root/postinstall"
/bin/chmod 0444 "$scripts_root/common.zsh"
while IFS= read -r staged_object; do
    TZ=UTC /usr/bin/touch -t 202001010000 "$staged_object"
done < <(/usr/bin/find "$payload_root" "$scripts_root" -depth -print | LC_ALL=C /usr/bin/sort)

export COPYFILE_DISABLE=1
export LC_ALL=C
export TZ=UTC
/usr/bin/pkgbuild --quiet \
    --root "$payload_root" \
    --scripts "$scripts_root" \
    --identifier io.github.northstarxyzz.pcvrpatcher.memory-policy \
    --version 0.1.0 \
    --install-location / \
    --ownership recommended \
    --compression legacy \
    "$raw_package"

/bin/mkdir "$expanded_root"
/usr/bin/xar -x -C "$expanded_root" -f "$raw_package"

# pkgbuild records protected provenance xattrs as AppleDouble payload entries.
# Rebuild only the four unsigned component members from the already normalized
# staging trees so the package cannot write xattrs onto /usr/local ancestors.
/usr/bin/mkbom "$payload_root" "$raw_bom"
/usr/bin/lsbom "$raw_bom" | /usr/bin/awk -F '\t' \
    'BEGIN { OFS="\t" } { $3="0/0"; print }' > "$bom_listing"
/bin/unlink "$expanded_root/Bom"
/bin/unlink "$expanded_root/Payload"
/bin/unlink "$expanded_root/Scripts"
/usr/bin/mkbom -i "$bom_listing" "$expanded_root/Bom"
(
    cd "$payload_root"
    /usr/bin/find . -print | LC_ALL=C /usr/bin/sort | \
        /usr/bin/cpio -o --format odc -R 0:0 2>/dev/null | \
        /usr/bin/gzip -9 -n > "$expanded_root/Payload"
)
(
    cd "$scripts_root"
    /usr/bin/find . -print | LC_ALL=C /usr/bin/sort | \
        /usr/bin/cpio -o --format odc -R 0:0 2>/dev/null | \
        /usr/bin/gzip -9 -n > "$expanded_root/Scripts"
)
/usr/bin/python3 - "$expanded_root/PackageInfo" "$payload_root" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

path = pathlib.Path(sys.argv[1])
payload_root = pathlib.Path(sys.argv[2])
root = ET.parse(path).getroot()
payload = root.find("payload")
if payload is None:
    raise SystemExit("PackageInfo is missing payload metadata")
payload.set("numberOfFiles", "9")
payload_bytes = sum(item.stat().st_size for item in payload_root.rglob("*") if item.is_file())
payload.set("installKBytes", str((payload_bytes + 1023) // 1024))
ET.indent(root, space="    ")
path.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n")
PY

for member in Bom Payload Scripts PackageInfo; do
    [[ -f "$expanded_root/$member" && ! -L "$expanded_root/$member" ]] || {
        print -u2 -- "pkgbuild omitted required flat-package member: $member"
        exit 79
    }
    /bin/chmod u+w "$expanded_root/$member"
    /usr/bin/xattr -c "$expanded_root/$member"
    /bin/chmod -N "$expanded_root/$member"
    /bin/chmod 0644 "$expanded_root/$member"
    TZ=UTC /usr/bin/touch -t 202001010000 "$expanded_root/$member"
done
TZ=UTC /usr/bin/touch -t 202001010000 "$expanded_root"

(
    cd "$expanded_root"
    /usr/bin/xar -c \
        --toc-cksum sha256 \
        --file-cksum sha256 \
        --compression none \
        -f "$canonical_outer" \
        PackageInfo Scripts Payload Bom
)
/usr/bin/python3 "$package_root/normalize-flat-package.py" \
    "$canonical_outer" "$normalized_package"
/bin/chmod 0644 "$normalized_package"

set +e
/bin/zsh "$package_root/verify-package.sh" "$normalized_package" "$manifest"
verify_result=$?
set -e
if (( verify_result != 0 )); then
    actual_package_sha=$(/usr/bin/shasum -a 256 "$normalized_package" | \
        /usr/bin/awk '{print $1}')
    print -u2 -- "Built package SHA-256: $actual_package_sha"
    exit "$verify_result"
fi

/bin/mv "$normalized_package" "$output"
print -- "Built deterministic component package: $output"
/usr/bin/shasum -a 256 "$output"
