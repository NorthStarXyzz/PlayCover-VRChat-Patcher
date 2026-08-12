# AGENTS.md

## Project

PlayCover VRChat Patcher is a small, GPL-3.0-only macOS tool for creating a
separate PlayCover build for VRChat. The official `/Applications/PlayCover.app`
must remain unchanged. The supported copy is `/Applications/PlayCover VRChat.app`
with its own PlayCover container.

The public Alpha is source-only. It does not ship a VRChat IPA, VRChat binary,
patched PlayCover payload, or root controller package. Do not describe the
source-only DMG as a ready-to-install compatibility fix.

## Repository map

- `Patcher/` — SwiftUI Patcher app and transactional copy/repair/remove logic.
- `PlayCoverPatch/` — ordered, reviewable patches for the pinned PlayCover tree.
- `Controller/` — memory-policy controller, runner, package scripts, and protocol.
- `Compatibility/` — version, identity, and controller package manifests.
- `Scripts/` — fetch, patch, build, verify, and release commands.
- `Tests/` — Swift, controller, manifest, and PlayCover patch tests.
- `Docs/` — development, architecture, release, and third-party notes.

## Compatibility baseline

The reviewed test baseline is:

- Apple silicon arm64
- macOS 26.6, build `25G70` (metadata only; not a runtime lock)
- PlayCover `3.1.0 (856)`
- VRChat `2026.2.30300 (1365)`

PlayCover/VRChat identities remain pinned. Host build/XNU strings are not used as
an allowlist; the controller uses arm64 and live policy/readback/runtime-image
checks, and fails closed when those checks fail.

## Required checks

Run the relevant checks before committing:

```zsh
swift test -c release
/bin/zsh Tests/Controller/run-tests.sh
/bin/zsh PlayCoverPatch/run-tests.sh
/bin/zsh Scripts/verify-repository.sh
swift build -c release --product PlayCoverVRChatPatcher
```

Build a source-only inspection app with:

```zsh
/bin/zsh Scripts/build-patcher-app.sh \
  --output "$PWD/Artifacts/PlayCover VRChat Patcher.app"
/bin/zsh Scripts/verify-patcher-app.sh \
  "$PWD/Artifacts/PlayCover VRChat Patcher.app"
```

For a tagged Alpha release, use a clean checkout, an annotated tag, and the
target macOS build:

```zsh
/bin/zsh Scripts/package-alpha.sh --release-tag v0.1.0-alpha.N
```

GitHub CI may build on a different macOS point release. That does not weaken the
runtime guard: package installation still requires arm64 and the controller
performs its live identity and policy checks before maintaining a session.

## Patch and runtime rules

- Apply patches in the order listed by `PlayCoverPatch/series`.
- Use `Scripts/fetch-playcover.sh`, `Scripts/apply-playcover-patches.sh`, and
  `PlayCoverPatch/check.sh`; do not hand-edit a generated `Build/PlayCover` tree.
- VRChat must launch from the independent library's exact URL.
- PlayTools must not be injected or installed for VRChat. The compatible launch
  path verifies that PlayTools is absent and fails closed if it is present.
- The controller applies a temporary XNU `memorystatus_control` soft limit to
  the exact reviewed VRChat process. It does not hook Unity, patch VRChat, or
  modify Appdome/libloader.
- Never disable SIP/AMFI, modify system libraries, or use an arbitrary PID,
  path, limit, or command from UI input.
- Never run `sudo`, an Installer package, or VRChat as part of automated tests.

## Do not commit

Never commit any of the following:

- VRChat IPAs, app bundles, binaries, caches, or user data.
- PlayCover payloads, controller binaries, `.pkg` files, or signed artifacts.
- `Build/`, `.build/`, `Artifacts/`, Carthage outputs, or local DerivedData.
- Passwords, signing credentials, provisioning profiles, private keys, or tokens.
- User-specific absolute paths, local hashes, temporary logs, or screenshots
  containing personal data.
- Old logo concepts, chroma/reference assets, generated previews, or unrelated
  binary assets. Only reviewed release assets belong in `Design/Logo/`.

## Documentation and localization

Keep `README.md` and `README_CN.md` concise and in sync. User-facing strings in
the patched PlayCover UI must have a fallback in every supported localization;
never expose localization keys such as `playapp.keymap` to users. When changing
launch states, errors, memory settings, or compatibility claims, update the
corresponding tests and README text.

## Compatibility changes

Any change to a version, hash, UUID, controller build ID, protocol, memory
policy, PlayTools behavior, or bundle identity requires all of:

1. a reviewed manifest/schema update;
2. matching controller and PlayCover constants;
3. regression tests and a clean patch-series check; and
4. updated user-facing documentation.

Do not add a new allowlist entry merely to make a local failure pass.

## Git and release hygiene

Keep commits focused and inspect `git diff --check` before pushing. Do not
force-push or rewrite an existing release tag. Release artifacts must include
the arm64 Patcher DMG, source archive, and `SHA256SUMS`; SPDX and patch
inventory files are provenance records, not installation requirements.
