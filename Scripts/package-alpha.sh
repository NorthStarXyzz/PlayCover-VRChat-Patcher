#!/bin/zsh

set -euo pipefail
setopt PIPE_FAIL
umask 022

repo_root=${0:A:h:h}
release_tag=v0.1.0-alpha.1
output_parent="$repo_root/Artifacts"
output_was_default=1

usage() {
    print -u2 -- "Usage: ${0:t} [--release-tag v0.1.0-alpha.N] [--output-dir /existing/directory]"
}

while (( $# > 0 )); do
    case $1 in
        --release-tag)
            (( $# >= 2 )) || { usage; exit 64; }
            release_tag=$2
            shift 2
            ;;
        --output-dir)
            (( $# >= 2 )) || { usage; exit 64; }
            output_parent=$2
            output_was_default=0
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ $release_tag =~ '^v0\.1\.0-alpha\.[1-9][0-9]*$' ]] || {
    print -u2 -- "Release tag must match v0.1.0-alpha.N."
    exit 64
}
[[ $output_parent == /* ]] || {
    print -u2 -- "Output directory must be absolute."
    exit 64
}
if (( output_was_default )); then
    /bin/mkdir -p "$output_parent"
fi
[[ -d $output_parent && ! -L $output_parent ]] || {
    print -u2 -- "Output directory must be an existing non-symlink directory: $output_parent"
    exit 73
}
output_parent=$(cd "$output_parent" && /bin/pwd -P)

if [[ "$output_parent/" == "$repo_root/"* ]] && \
   ! /usr/bin/git -C "$repo_root" check-ignore -q "$output_parent"; then
    print -u2 -- "An output directory inside the checkout must be Git-ignored."
    exit 73
fi

object_type=$(/usr/bin/git -C "$repo_root" cat-file -t "$release_tag" 2>/dev/null || true)
[[ $object_type == tag ]] || {
    print -u2 -- "Release tag must exist as an annotated tag: $release_tag"
    exit 65
}
commit=$(/usr/bin/git -C "$repo_root" rev-parse "$release_tag^{commit}")
head=$(/usr/bin/git -C "$repo_root" rev-parse HEAD)
[[ $commit == $head ]] || {
    print -u2 -- "Release tag does not resolve to HEAD."
    exit 65
}
[[ -z $(/usr/bin/git -C "$repo_root" status --porcelain=v1 --untracked-files=all) ]] || {
    print -u2 -- "Refusing to package a dirty checkout."
    exit 73
}
if /usr/bin/git -C "$repo_root" ls-files --stage | \
   /usr/bin/awk '$1 == "160000" { found=1 } END { exit(found ? 0 : 1) }'; then
    print -u2 -- "Submodules are not supported by the source Alpha packager."
    exit 65
fi

version=${release_tag#v}
release_name="PlayCover-VRChat-Patcher-$release_tag"
final_directory="$output_parent/$release_name"
[[ ! -e $final_directory && ! -L $final_directory ]] || {
    print -u2 -- "Refusing to replace an existing release directory: $final_directory"
    exit 73
}

print -- "Running non-privileged release gates for $release_tag ($commit)."
"$repo_root/Scripts/verify-repository.sh"
/usr/bin/swift test --package-path "$repo_root"
"$repo_root/Tests/Controller/run-tests.sh"
"$repo_root/PlayCoverPatch/run-tests.sh"
/bin/zsh "$repo_root/PlayCoverPatch/dependencies/PlayTools/test.sh"

[[ -z $(/usr/bin/git -C "$repo_root" status --porcelain=v1 --untracked-files=all) ]] || {
    print -u2 -- "A release gate changed the checkout; refusing to package."
    exit 73
}

staging_root=$(/usr/bin/mktemp -d "$output_parent/.pcvr-alpha.XXXXXX")
work_directory="$staging_root/work"
release_directory="$staging_root/$release_name"
/bin/mkdir -p "$work_directory" "$release_directory"

cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ -n ${staging_root:-} && -d $staging_root ]]; then
        /bin/rm -R "$staging_root"
    fi
    exit $result
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

source_app="$work_directory/PlayCover VRChat Patcher.app"
"$repo_root/Scripts/build-patcher-app.sh" --output "$source_app"
"$repo_root/Scripts/verify-patcher-app.sh" "$source_app"

manifest="$source_app/Contents/Resources/CompatibilityManifest.json"
/usr/bin/python3 - "$manifest" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if value.get("patchedPlayCover") is not None:
    raise SystemExit("source-only release manifest must not trust a patched payload")
if value.get("controllerPackage") is not None:
    raise SystemExit("source-only release manifest must not trust a controller package")
PY
[[ ! -e "$source_app/Contents/Resources/Payload" && \
   ! -L "$source_app/Contents/Resources/Payload" && \
   ! -e "$source_app/Contents/Resources/Controller" && \
   ! -L "$source_app/Contents/Resources/Controller" ]] || {
    print -u2 -- "Source-only Patcher unexpectedly contains payload resources."
    exit 79
}

source_epoch=$(/usr/bin/git -C "$repo_root" show -s --format=%ct "$commit")
source_archive="PlayCover-VRChat-Patcher-$version-source.tar.gz"
app_archive="PlayCover-VRChat-Patcher-$version-source-only-macos-arm64.zip"
inventory_name="PlayCover-VRChat-Patcher-$version-patch-inventory.json"
sbom_name="PlayCover-VRChat-Patcher-$version.spdx.json"

/usr/bin/git -C "$repo_root" archive \
    --format=tar \
    --prefix="PlayCover-VRChat-Patcher-$version/" \
    "$release_tag" | /usr/bin/gzip -9 -n > "$release_directory/$source_archive"
/usr/bin/python3 "$repo_root/Scripts/reject-release-binaries.py" \
    --tar "$release_directory/$source_archive"

/usr/bin/python3 "$repo_root/Scripts/create-deterministic-zip.py" \
    --input "$source_app" \
    --output "$release_directory/$app_archive" \
    --source-date-epoch "$source_epoch"

/usr/bin/python3 "$repo_root/Scripts/generate-release-inventory.py" \
    --repo-root "$repo_root" \
    --release-tag "$release_tag" \
    --commit "$commit" \
    --output "$release_directory/$inventory_name"

/usr/bin/python3 "$repo_root/Scripts/generate-sbom.py" \
    --repo-root "$repo_root" \
    --release-tag "$release_tag" \
    --commit "$commit" \
    --output "$release_directory/$sbom_name"

/usr/bin/python3 - "$release_directory/$source_archive" "$release_directory/$app_archive" <<'PY'
import pathlib
import sys
import tarfile
import zipfile

source_path = pathlib.Path(sys.argv[1])
zip_path = pathlib.Path(sys.argv[2])
forbidden_suffixes = (
    ".app",
    ".dmg",
    ".ipa",
    ".p12",
    ".pkg",
    ".provisionprofile",
    ".mobileprovision",
    ".xcarchive",
    ".zip",
)

with tarfile.open(str(source_path), "r:gz") as archive:
    members = archive.getmembers()
    if not members:
        raise SystemExit("source archive is empty")
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or ".git" in path.parts:
            raise SystemExit("unsafe source archive member: " + member.name)
        if not (member.isfile() or member.isdir()):
            raise SystemExit("source archive contains a non-file entry: " + member.name)
        if member.name.lower().endswith(forbidden_suffixes):
            raise SystemExit("forbidden source archive member: " + member.name)

with zipfile.ZipFile(str(zip_path), "r") as archive:
    if archive.testzip() is not None:
        raise SystemExit("source-only Patcher ZIP failed CRC verification")
    names = archive.namelist()
    if not names or any(
        "/payload/" in name.lower()
        or "/contents/resources/controller/" in name.lower()
        or "vrchat-memory-policy-controller" in name.lower()
        or name.lower().endswith(".ipa")
        or name.lower().endswith(".pkg")
        for name in names
    ):
        raise SystemExit("source-only Patcher ZIP contains a forbidden payload")
PY

(
    cd "$release_directory"
    LC_ALL=C /usr/bin/shasum -a 256 \
        "$source_archive" "$app_archive" "$inventory_name" "$sbom_name" > SHA256SUMS
    /usr/bin/shasum -a 256 -c SHA256SUMS
)

/bin/mv -n "$release_directory" "$output_parent/"
[[ ! -e $release_directory && -d $final_directory ]] || {
    print -u2 -- "Could not publish release directory without replacement."
    exit 73
}

print -- "Created source-only Alpha release: $final_directory"
print -- "This artifact cannot Patch PlayCover and contains no patched payload."
