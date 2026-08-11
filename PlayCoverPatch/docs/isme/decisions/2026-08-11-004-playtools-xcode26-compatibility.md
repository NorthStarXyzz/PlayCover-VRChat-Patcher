# SKMB-2026-08-11-004: PlayTools Xcode 26 Compatibility

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly required a minimal reviewed patch for the DiscordIPC.swift Xcode 26 failure on exact PlayTools f17b921, with idempotent fail-closed scripts and no dependency bump on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: pinned PlayTools checkout compatibility patch

## Context

PlayTools v3.1.0 commit `f17b9211211fb4cf5652d4930ea82613ee3c92a5`
mutates `RichPresence.buttons` by indexing two presumed placeholder elements.
With the SwordRPC API resolved by Xcode 26, the property is optional and those
mutations do not compile.

## Decision

Replace only those three mutations with an assignment containing one
`RichPresence.Button` with the same label and URL. This preserves the resulting
Discord activity while compiling against the current API.

Because Carthage 0.40 exports the checkout without `.git`, the patcher accepts only
the complete reviewed f17b921 export preimage: every relative path, regular-file
SHA-256, and file/directory mode contributes to one fixed tree digest. A second
invocation accepts the exact source-patched intermediate. It then atomically
installs the reviewed SwiftPM resolution, whose five revisions include SwordRPC
`4403152a16a040d8448d33d65ad5a034c9d1fa1b`, and verifies a new complete-tree
digest. A completed second invocation performs no write. Additions, deletions,
mode changes, symlinks, special files, different existing locks, and unknown
hashes fail closed; scripts never reset, merge, fetch, or select another
dependency revision.

Carthage must first materialize the checkout without building, then the reviewed
patch and exact resolution are applied, and only then may Carthage build
PlayTools. Cached builds are disabled. Xcode 26 builds set `FASTLANE=1` to bypass
PlayTools' SwiftLint phase while leaving compilation intact.

## Applies To

- `dependencies/PlayTools/patches/0001-xcode26-rich-presence-buttons.patch`
- `dependencies/PlayTools/overlay/Package.resolved`
- dependency apply/check/test scripts and fixtures
- PlayCover patch validation and build instructions

## Supersedes

None.

## Superseded By

None.
