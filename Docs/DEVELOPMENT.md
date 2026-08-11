# Developer guide

This guide builds and tests the developer Alpha without changing PlayCover,
VRChat, or system memory policy. Do not run commands with `sudo` unless you are
performing a separately approved controller installation test.

## Prerequisites

- Apple silicon Mac with Xcode and its command-line tools
- Git and Python 3
- Carthage 0.40.0
- macOS 26.6 (25G70) for runtime compatibility checks
- A host whose 75% whole-GiB ceiling is at least 4 GiB for a real session

The Swift unit tests and source-only GUI build can run without VRChat or an IPA.

## Verify a checkout

Run the repository policy checks and all non-privileged tests:

```zsh
Scripts/verify-repository.sh
swift test
Tests/Controller/run-tests.sh
```

The Swift suite covers parallel create/repair/remove, interrupted import and
publish recovery, clone/copy fallback, hard-link rejection, unknown
modifications, a missing payload, and the schema-2 manifest. Controller tests
cover bounded dynamic policies, composite VRChat identity, PCVR/2, fake target
backends, and a local socket pair.

## Build the source-only SwiftUI app

```zsh
Scripts/build-patcher-app.sh \
  --output "$PWD/Artifacts/PlayCover VRChat Patcher-source-only.app"

Scripts/verify-patcher-app.sh \
  "$PWD/Artifacts/PlayCover VRChat Patcher-source-only.app"
```

This build can inspect an official PlayCover installation. It deliberately has
no `Payload/PlayCover.app`, so the GUI reports **Source-only developer build**
and refuses Patch or Repair.

## Verify the pinned PlayCover patch series

Fetch only the reviewed upstream commit, then apply each ordered patch:

```zsh
Scripts/fetch-playcover.sh
Scripts/apply-playcover-patches.sh
```

The checkout is written under ignored `Build/PlayCover`. No full PlayCover
history is copied into this repository.

Build the complete customized PlayCover from that exact checkout with:

```zsh
Scripts/build-playcover-payload.sh \
  "$PWD/Build/PlayCover" \
  "$PWD/Artifacts/payload-candidate/PlayCover.app"
```

The build uses only the reviewed seven-pin PlayCover `Package.resolved`, the
reviewed PlayTools commit, and the reviewed five-pin PlayTools SwiftPM
resolution.
Automatic SwiftPM updates and Carthage binary caches are disabled. The patched
target neither links nor embeds Sparkle, so an ad-hoc Hardened Runtime build
does not rely on an absent Team Identifier to pass Library Validation. The
candidate directory remains named `PlayCover.app` inside the Patcher payload,
but its required bundle ID is `io.github.northstarxyzz.PlayCoverVRChat` and its
installed path is `/Applications/PlayCover VRChat.app`. The result is
deep-signature verified and accompanied by an explicitly **untrusted**
candidate identity; it does not become a trust anchor until independent review
and real-machine acceptance are complete.

Two clean builds must compile and pass the same invariants. The controller is
required to be byte-identical across builds. The complete ad-hoc PlayCover app
is not currently byte-identical because Apple's asset compiler writes a build
timestamp and random temporary rendition names into `Assets.car`; ad-hoc root
seals consequently differ as well. In the validated Xcode 26.6 builds, the main
Mach-O UUID was identical and its pre-signature content became byte-identical
after removing the build-path-bearing local/debug symbol table. A release pins
and tests one exact payload tree rather than accepting either build output.

## Build the controller

```zsh
Controller/build.sh
```

The build is deterministic and must match the reviewed SHA-256 embedded in the
runner. A mismatch is a hard failure. `Controller/install.sh` only builds and
verifies the deterministic component package; it does not invoke `sudo`,
Installer, or modify installed state. macOS Installer owns the administrator
trust boundary. The runner accepts one canonical whole-GiB argument; root
recomputes the 75% ceiling and refuses invalid or stale GUI input without
clamping.

## Build a payload-bearing Patcher

A release payload must already be fully built, signed, and independently
reviewed. `Scripts/build-playcover-payload.sh` generates an untrusted candidate
outside the tracked manifest directory. The candidate pairs the observed
`patchedPlayCover` identity with the exact reviewed controller-package
requirement. The lower-level equivalent is:

```zsh
swift run pcvr-manifest-tool propose \
  Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json \
  "/absolute/path/to/PlayCover.app" \
  Controller/package/ControllerPackageManifest.json \
  Compatibility/local/candidate.json
```

Review the complete payload, its build provenance, and the candidate diff.
Only a maintainer may copy the reviewed `patchedPlayCover` and
`controllerPackage` pair into the tracked compatibility manifest in one
reviewed commit. Either field without the other is invalid. Building a Patcher
never creates its own trust anchor.

After the reviewed identity is committed, run:

```zsh
Scripts/build-patcher-app.sh \
  --payload "/absolute/path/to/PlayCover.app" \
  --manifest "/absolute/path/to/patchedPlayCover-candidate.json" \
  --output "$PWD/Artifacts/PlayCover VRChat Patcher.app"
```

The script recomputes the parallel payload bundle ID, executable UUID,
executable SHA-256, and full tree SHA-256 with `AppTreeVerifier`. It requires an
exact match with the already-reviewed manifest, builds and verifies the exact
component package, and embeds it only at
`Contents/Resources/Controller/PlayCoverVRChatMemoryPolicy.pkg` before signing
the outer Patcher. If either payload changes by one byte, packaging fails
closed.

The outer ad-hoc signature is suitable only for developer Alpha testing. A
public installer still requires Developer ID signing, notarization, stapling,
and the release gates in [Docs/COMPATIBILITY.md](COMPATIBILITY.md).

The source-only Alpha release bundle is produced by the fail-closed process in
[RELEASING.md](RELEASING.md). It does not embed a PlayCover payload and cannot
perform Patch or Repair.

## Important boundaries

- Never add a VRChat IPA, cookie, token, Keychain export, or signing key.
- Never add MemoryShim, Empty dylib, PlayTools injection, or a replacement
  Appdome loader.
- Never change, replace, or remove `/Applications/PlayCover.app` or its library.
- Never accept a caller-supplied path, PID, shell command, fractional limit, or
  value outside 4 GiB through the root-computed 75% ceiling.
- Never loosen the manifest to guess support for a new macOS or VRChat build.
- Never publish a controller whose exact binary did not complete the final
  two-session, 30-minute real-machine acceptance test.
