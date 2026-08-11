#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL

package_root=${0:A:h}
package_file=${1:-}
manifest=${2:-$package_root/ControllerPackageManifest.json}

[[ "$package_file" == /* && -f "$package_file" && ! -L "$package_file" ]] || {
    print -u2 -- "Usage: ${0:t} /absolute/path/PlayCoverVRChatMemoryPolicy.pkg [manifest.json]"
    exit 64
}
[[ -f "$manifest" && ! -L "$manifest" ]] || {
    print -u2 -- "Package manifest must be a regular file."
    exit 64
}

expected_package_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["sha256"])' \
    "$manifest")
actual_package_sha=$(/usr/bin/shasum -a 256 "$package_file" | /usr/bin/awk '{print $1}')
[[ "$actual_package_sha" == "$expected_package_sha" ]] || {
    print -u2 -- "Component-package SHA-256 mismatch."
    print -u2 -- "Expected: $expected_package_sha"
    print -u2 -- "Found:    $actual_package_sha"
    exit 79
}

signature_output=''
set +e
signature_output=$(/usr/sbin/pkgutil --check-signature "$package_file" 2>&1)
signature_result=$?
set -e
if (( signature_result != 1 )) || \
   ! print -r -- "$signature_output" | /usr/bin/grep -F -x -q '   Status: no signature'; then
    print -u2 -- "Developer Alpha package must be explicitly unsigned."
    exit 79
fi

members=$(/usr/bin/xar -tf "$package_file")
[[ "$members" == $'PackageInfo\nScripts\nPayload\nBom' ]] || {
    print -u2 -- "Unexpected flat-package member set."
    print -u2 -- "$members"
    exit 79
}

verification_root=$(/usr/bin/mktemp -d /tmp/pcvr-package-verification.XXXXXX)
expanded="$verification_root/expanded"
renormalized="$verification_root/renormalized.pkg"
payload_files="$verification_root/payload-files"
script_files="$verification_root/script-files"
bom_listing="$verification_root/bom-listing"
payload_tree="$verification_root/payload"
scripts_tree="$verification_root/scripts"

cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -d "$verification_root" ]]; then
        /bin/rm -R "$verification_root"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/usr/bin/python3 "$package_root/normalize-flat-package.py" \
    "$package_file" "$renormalized"
/usr/bin/cmp "$package_file" "$renormalized" || {
    print -u2 -- "Flat package is not in canonical deterministic form."
    exit 79
}

/bin/mkdir "$expanded"
/usr/bin/xar -x -C "$expanded" -f "$package_file"
/usr/bin/python3 - "$expanded/PackageInfo" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

root = ET.parse(pathlib.Path(sys.argv[1])).getroot()
expected = {
    "identifier": "io.github.northstarxyzz.pcvrpatcher.memory-policy",
    "version": "0.1.0",
    "install-location": "/",
    "auth": "root",
    "format-version": "2",
}
for key, value in expected.items():
    if root.get(key) != value:
        raise SystemExit(f"PackageInfo {key} mismatch: {root.get(key)!r}")
scripts = root.find("scripts")
if scripts is None:
    raise SystemExit("PackageInfo has no scripts declaration")
names = [child.get("file") for child in scripts]
if names != ["./preinstall", "./postinstall"]:
    raise SystemExit(f"unexpected package scripts: {names!r}")
PY

/usr/bin/lsbom "$expanded/Bom" > "$bom_listing"
/usr/bin/python3 - "$bom_listing" <<'PY'
import pathlib
import sys

expected = {
    ".": "40755",
    "./usr": "40755",
    "./usr/local": "40755",
    "./usr/local/bin": "40755",
    "./usr/local/bin/playcover-vrchat-memory-policy": "100555",
    "./usr/local/libexec": "40755",
    "./usr/local/libexec/playcover-vrchat-memory-policy": "40755",
    "./usr/local/libexec/playcover-vrchat-memory-policy/controller": "100500",
    "./usr/local/libexec/playcover-vrchat-memory-policy/installation.json": "100444",
}
observed = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    fields = line.split("\t")
    if len(fields) < 3:
        raise SystemExit(f"malformed BOM row: {line!r}")
    path, mode, ownership = fields[:3]
    if ownership != "0/0":
        raise SystemExit(f"non-root BOM ownership: {line!r}")
    if path in observed:
        raise SystemExit(f"duplicate BOM path: {path}")
    observed[path] = mode
if observed != expected:
    raise SystemExit(f"BOM metadata mismatch: {observed!r}")
PY

/usr/bin/python3 - "$expanded/Payload" "$expanded/Scripts" <<'PY'
import gzip
import hashlib
import pathlib
import stat
import sys

EPOCH = 1577836800
HEADER_SIZE = 76

expected_orders = (
    [
        (".", 0o040755),
        ("./usr", 0o040755),
        ("./usr/local", 0o040755),
        ("./usr/local/bin", 0o040755),
        ("./usr/local/bin/playcover-vrchat-memory-policy", 0o100555),
        ("./usr/local/libexec", 0o040755),
        ("./usr/local/libexec/playcover-vrchat-memory-policy", 0o040755),
        ("./usr/local/libexec/playcover-vrchat-memory-policy/controller", 0o100500),
        ("./usr/local/libexec/playcover-vrchat-memory-policy/installation.json", 0o100444),
    ],
    [
        (".", 0o040755),
        ("./common.zsh", 0o100444),
        ("./postinstall", 0o100555),
        ("./preinstall", 0o100555),
    ],
)


def octal(field: bytes) -> int:
    try:
        return int(field, 8)
    except ValueError as error:
        raise SystemExit(f"invalid odc field {field!r}: {error}")


def parse(path: pathlib.Path, expected_order: list[tuple[str, int]]) -> None:
    expected = dict(expected_order)
    raw = gzip.decompress(path.read_bytes())
    offset = 0
    observed: dict[str, int] = {}
    observed_order: list[tuple[str, int]] = []
    file_identities: set[tuple[int, int]] = set()
    saw_trailer = False
    while offset + HEADER_SIZE <= len(raw):
        header = raw[offset : offset + HEADER_SIZE]
        offset += HEADER_SIZE
        if header[:6] != b"070707":
            raise SystemExit(f"unexpected odc magic at offset {offset - HEADER_SIZE}")
        fields = (
            header[6:12], header[12:18], header[18:24], header[24:30],
            header[30:36], header[36:42], header[42:48], header[48:59],
            header[59:65], header[65:76],
        )
        dev, ino, mode, uid, gid, nlink, _rdev, mtime, namesize, filesize = map(octal, fields)
        if namesize < 1 or offset + namesize + filesize > len(raw):
            raise SystemExit("truncated odc pathname or data")
        name_bytes = raw[offset : offset + namesize]
        offset += namesize
        if not name_bytes.endswith(b"\0") or b"\0" in name_bytes[:-1]:
            raise SystemExit("invalid odc pathname termination")
        try:
            name = name_bytes[:-1].decode("utf-8")
        except UnicodeDecodeError as error:
            raise SystemExit(f"non-UTF-8 odc pathname: {error}")
        data = raw[offset : offset + filesize]
        offset += filesize
        if name == "TRAILER!!!":
            if filesize != 0:
                raise SystemExit("odc trailer unexpectedly has data")
            saw_trailer = True
            break
        if name in observed:
            raise SystemExit(f"duplicate odc member: {name}")
        if uid != 0 or gid != 0 or mtime != EPOCH:
            raise SystemExit(f"unsafe odc ownership/time: {name}")
        expected_mode = expected.get(name)
        if mode != expected_mode:
            raise SystemExit(f"unsafe odc mode/type: {name} {mode:o}")
        if stat.S_ISREG(mode):
            if nlink != 1:
                raise SystemExit(f"hard-linked odc file: {name}")
            identity = (dev, ino)
            if identity in file_identities:
                raise SystemExit(f"reused odc file identity: {name}")
            file_identities.add(identity)
            hashlib.sha256(data).digest()
        elif not stat.S_ISDIR(mode) or filesize != 0:
            raise SystemExit(f"non-directory/non-regular odc member: {name}")
        observed[name] = mode
        observed_order.append((name, mode))
    if not saw_trailer or any(byte != 0 for byte in raw[offset:]):
        raise SystemExit("odc archive has no clean trailer/padding")
    if observed != expected:
        raise SystemExit(f"odc member set mismatch: {observed!r}")
    if observed_order != expected_order:
        raise SystemExit(f"odc publication order mismatch: {observed_order!r}")


for source, expected_order in zip(map(pathlib.Path, sys.argv[1:]), expected_orders):
    parse(source, expected_order)
PY

/usr/bin/gzip -dc "$expanded/Payload" | /usr/bin/cpio -it > "$payload_files" 2>/dev/null
/usr/bin/gzip -dc "$expanded/Scripts" | /usr/bin/cpio -it > "$script_files" 2>/dev/null
/usr/bin/python3 - "$payload_files" "$script_files" <<'PY'
import pathlib
import sys

expected_payload = [
    ".",
    "./usr",
    "./usr/local",
    "./usr/local/bin",
    "./usr/local/bin/playcover-vrchat-memory-policy",
    "./usr/local/libexec",
    "./usr/local/libexec/playcover-vrchat-memory-policy",
    "./usr/local/libexec/playcover-vrchat-memory-policy/controller",
    "./usr/local/libexec/playcover-vrchat-memory-policy/installation.json",
]
expected_scripts = [".", "./common.zsh", "./postinstall", "./preinstall"]

for source, expected in (
    (pathlib.Path(sys.argv[1]), expected_payload),
    (pathlib.Path(sys.argv[2]), expected_scripts),
):
    values = [line for line in source.read_text().splitlines() if line]
    if values != expected:
        raise SystemExit(f"archive member order mismatch: {values!r}")
    for value in values:
        path = pathlib.PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive member: {value}")
PY

/bin/mkdir "$payload_tree" "$scripts_tree"
(
    cd "$payload_tree"
    /usr/bin/gzip -dc "$expanded/Payload" | /usr/bin/cpio -idm --quiet
)
(
    cd "$scripts_tree"
    /usr/bin/gzip -dc "$expanded/Scripts" | /usr/bin/cpio -idm --quiet
)

expected_controller_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["controller"]["sha256"])' \
    "$manifest")
expected_runner_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["runner"]["sha256"])' \
    "$manifest")
expected_attestation_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["attestation"]["sha256"])' \
    "$manifest")
expected_operation_claim_path=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["operationClaim"]["path"])' \
    "$manifest")
expected_operation_claim_sha=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["controllerPackage"]["operationClaim"]["sha256"])' \
    "$manifest")
/usr/bin/python3 - "$manifest" <<'PY'
import json
import sys

claim = json.load(open(sys.argv[1]))["controllerPackage"]["operationClaim"]
expected = {
    "path": "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.operation",
    "sha256": "c68b37a41ecacd9c60f322dabe15ce1d7bbcff5a3dd9e9926ce014b9c74d13c3",
    "uid": 0,
    "gid": 0,
    "mode": "0400",
    "linkCount": 1,
}
if claim != expected:
    raise SystemExit(f"operationClaim manifest mismatch: {claim!r}")
PY

verify_hash() {
    local target=$1
    local expected=$2
    local actual
    actual=$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')
    [[ "$actual" == "$expected" ]] || {
        print -u2 -- "Expanded package hash mismatch: $target"
        exit 79
    }
}

verify_hash "$payload_tree/usr/local/bin/playcover-vrchat-memory-policy" \
    "$expected_runner_sha"
verify_hash "$payload_tree/usr/local/libexec/playcover-vrchat-memory-policy/controller" \
    "$expected_controller_sha"
verify_hash "$payload_tree/usr/local/libexec/playcover-vrchat-memory-policy/installation.json" \
    "$expected_attestation_sha"
verify_hash "$scripts_tree/common.zsh" \
    "$(/usr/bin/shasum -a 256 "$package_root/scripts/common.zsh" | /usr/bin/awk '{print $1}')"
verify_hash "$scripts_tree/preinstall" \
    "$(/usr/bin/shasum -a 256 "$package_root/scripts/preinstall" | /usr/bin/awk '{print $1}')"
verify_hash "$scripts_tree/postinstall" \
    "$(/usr/bin/shasum -a 256 "$package_root/scripts/postinstall" | /usr/bin/awk '{print $1}')"
for script in \
    "$payload_tree/usr/local/bin/playcover-vrchat-memory-policy" \
    "$scripts_tree/common.zsh"; do
    /usr/bin/grep -F -x -q \
        "operation_claim=$expected_operation_claim_path" "$script" || {
        print -u2 -- "Expanded package does not pin the reviewed operation claim path: $script"
        exit 79
    }
done
/usr/bin/grep -F -x -q \
    "expected_operation_claim_sha=$expected_operation_claim_sha" \
    "$payload_tree/usr/local/bin/playcover-vrchat-memory-policy" || {
    print -u2 -- "Expanded runner does not pin the reviewed operation claim SHA-256."
    exit 79
}
/usr/bin/grep -F -x -q \
    "operation_claim_sha=$expected_operation_claim_sha" \
    "$scripts_tree/common.zsh" || {
    print -u2 -- "Expanded package scripts do not pin the reviewed operation claim SHA-256."
    exit 79
}
/usr/bin/codesign --verify --strict \
    "$payload_tree/usr/local/libexec/playcover-vrchat-memory-policy/controller"

print -- "Verified deterministic unsigned r6 component package: $package_file"
