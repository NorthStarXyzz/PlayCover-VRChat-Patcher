# Release guide

This guide creates the source-only `v0.1` developer Alpha. The resulting
Patcher can inspect an official PlayCover installation. It cannot patch or
repair PlayCover because it contains no reviewed PlayCover payload.

## Release boundary

The source-only Alpha contains:

- the complete tagged project source;
- an ad-hoc-signed, source-only SwiftUI Patcher;
- an SPDX 2.3 software bill of materials (SBOM);
- a hash inventory for the upstream commit, patch series, overlays, and
  compatibility manifests;
- `SHA256SUMS` for every published file.

It does not contain a VRChat IPA, VRChat binary, patched PlayCover payload,
controller `.pkg` or binary, signing credential, or CXPatcher source. Its
compatibility manifest has neither `patchedPlayCover` nor `controllerPackage`;
those trust anchors are valid only as a reviewed pair.

Do not use this process for a payload-bearing or public installer release.
That release needs a separate commit containing the independently reviewed
`patchedPlayCover` plus `controllerPackage` pair. It must embed the exact pinned
package only at
`Contents/Resources/Controller/PlayCoverVRChatMemoryPolicy.pkg`. A public
installable release also needs the completed real-machine acceptance report,
Developer ID signing, notarization, and stapling; the unsigned package is only
for the local Developer Alpha workflow.

## Prerequisites

- a clean checkout on the exact release commit;
- Xcode and its command-line tools;
- Git and the Xcode-provided Python 3;
- an annotated tag named `v0.1.0-alpha.N` that resolves to `HEAD`.

Before tagging, complete the review and non-privileged test gates described in
[DEVELOPMENT.md](DEVELOPMENT.md). Creating or signing a tag is a maintainer
action and is intentionally not automated by the packaging script.

## Build the Alpha bundle

From the repository root, run:

```zsh
Scripts/package-alpha.sh --release-tag v0.1.0-alpha.1
```

The script refuses a lightweight tag, a dirty checkout, a tag not pointing at
`HEAD`, a submodule, an existing output directory, or an unsupported version
name. It reruns the repository, Swift, controller protocol, and PlayCover
coordinator gates before packaging.

By default, output is written atomically to:

```text
Artifacts/PlayCover-VRChat-Patcher-v0.1.0-alpha.1/
```

Use an existing absolute directory when a different destination is required:

```zsh
Scripts/package-alpha.sh \
  --release-tag v0.1.0-alpha.1 \
  --output-dir /absolute/path/to/release-staging
```

An output directory inside the checkout must be ignored by Git. The script
never replaces an existing release directory.

## Expected files

The release directory contains exactly these release artifacts:

```text
PlayCover-VRChat-Patcher-0.1.0-alpha.1-source.tar.gz
PlayCover-VRChat-Patcher-0.1.0-alpha.1-source-only-macos-arm64.zip
PlayCover-VRChat-Patcher-0.1.0-alpha.1-patch-inventory.json
PlayCover-VRChat-Patcher-0.1.0-alpha.1.spdx.json
SHA256SUMS
```

The source archive comes from `git archive` at the annotated tag. Its gzip
header has no local filename or timestamp. ZIP entries are sorted and use the
release commit time, Unix modes, and stored compression. The inventory and
SBOM use only tracked compatibility and patch metadata plus the release commit
time. This removes machine-local paths and wall-clock time from those files.

The compiled Swift binary can still change when the Apple toolchain changes.
Compare app ZIPs only when the Xcode, Swift, SDK, architecture, tag, and build
settings are identical.

## Verify before upload

Verify all checksums from inside the release directory:

```zsh
cd Artifacts/PlayCover-VRChat-Patcher-v0.1.0-alpha.1
shasum -a 256 -c SHA256SUMS
```

Validate the JSON documents:

```zsh
python3 -m json.tool \
  PlayCover-VRChat-Patcher-0.1.0-alpha.1-patch-inventory.json >/dev/null
python3 -m json.tool \
  PlayCover-VRChat-Patcher-0.1.0-alpha.1.spdx.json >/dev/null
```

Expand the ZIP into a temporary directory and verify the app again:

```zsh
repo_root=$(git rev-parse --show-toplevel)
release_dir=$PWD
verification_dir=$(mktemp -d)
ditto -x -k \
  "$release_dir/PlayCover-VRChat-Patcher-0.1.0-alpha.1-source-only-macos-arm64.zip" \
  "$verification_dir"
"$repo_root/Scripts/verify-patcher-app.sh" \
  "$verification_dir/PlayCover VRChat Patcher.app"
```

Remove the temporary verification directory after inspection. Confirm that
the app reports **Source-only developer build** and that **Patch** remains
disabled. Never test this Alpha by entering an administrator password.

## Upload checklist

- The tag and commit shown in the patch inventory match the intended release.
- Every patch listed in `PlayCoverPatch/series` appears once in the inventory.
- The inventory contains only the two reviewed v10 icon masters;
  no reference, chroma-key, or earlier concept image is present in either
  release archive.
- The inventory records the PlayTools compatibility patch path, SHA-256, and
  exact `f17b921…` target commit.
- The inventory records the reviewed PlayTools `Package.resolved` SHA-256 and
  exactly five SwiftPM pins, including SwordRPC revision `4403152a…`.
- The SBOM lists the pinned PlayCover, PlayTools, and XNU references, plus the
  reviewed PlayTools patch as an SPDX file with a `PATCH_FOR` relationship.
- `SHA256SUMS` verifies without warnings.
- The release is marked **Developer Alpha / source-only / cannot patch**.
- No executable controller, VRChat asset, IPA, or patched PlayCover app is
  attached.

Publish all five files together. Do not publish an app ZIP without its source
archive, SPDX document, inventory, and checksum file.
