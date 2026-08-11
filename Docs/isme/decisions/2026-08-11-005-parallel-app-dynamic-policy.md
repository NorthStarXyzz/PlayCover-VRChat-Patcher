# SKMB-2026-08-11-005: Parallel Patched App and Dynamic Memory Policy

- status: accepted
- decided_by: designer
- approval_source: user explicitly requested implementation of the parallel-install plan and selected the recommended independent-library, dual-authorization and 4 GiB lower-bound options on 2026-08-11
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - B_state_persistence
  - C_concurrent_operations
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: patched PlayCover installation, VRChat import, dynamic memory selection and privileged-helper lifecycle

## Decision

Keep `/Applications/PlayCover.app` byte-for-byte unchanged. Publish the reviewed
custom payload beside it as `/Applications/PlayCover VRChat.app`, with bundle
identifier `io.github.northstarxyzz.PlayCoverVRChat` and an independent library
at `~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat`.

Before publishing the patched copy, require the exact supported VRChat in the
original PlayCover library. Import it into the independent library using an APFS
clone when available and an ordinary copy otherwise; never use hard links.
Verify the complete imported identity before commit. Do not copy or inject
PlayTools, PlayChain, compatibility shims or experimental artifacts. The global
VRChat user container remains shared because the imported app retains the
original VRChat bundle identifier.

The default non-fatal soft memory limit is the host's physical memory multiplied
by 75 percent and rounded down to an integral GiB. A user may select any integral
GiB value from 4 GiB through that ceiling. Values below 8 GiB are permitted with
a warning. A session snapshots one validated value before authorization; changes
during a running session apply only to the next launch. Invalid or stale values
fail closed and are never silently clamped.

Developer Alpha uses a fixed reviewed root-owned runner and a per-session macOS
administrator authorization dialog without Terminal or password handling.
Public silent builds embed an on-demand `SMAppService` LaunchDaemon in the
customized PlayCover, with neither `RunAtLoad` nor `KeepAlive`, and require
Developer ID signing and notarization. The formal backend must never downgrade
to the development authorization path. Both backends must authenticate the
versioned protocol and independently validate the host, imported target and
requested limit before reporting WAITING.

Remove first confirms that no lease is active and that the formal helper is
unregistered, then removes only the exact patched app. It leaves the independent
library in place and never deletes the original PlayCover library or the VRChat
user container.

## Applies To

- Patcher inspect/create/repair/remove states and transaction journal
- independent PlayCover library and verified VRChat import
- dynamic memory-policy UI, persistence and protocol
- developer authorization provider and formal SMAppService provider
- target identity, controller maintenance and release verification
- coexistence, interruption, authorization and long-session tests

## Alternatives

- Replacing the original PlayCover was rejected because the designer requires a
  CXPatcher-style parallel copy.
- Reusing the original bundle identifier was rejected because LaunchServices
  can resolve two copies ambiguously.
- Sharing the original PlayCover library was rejected because concurrent signing,
  settings and file writes would not be isolated.
- An unrestricted or above-75-percent memory value was rejected to preserve a
  nominal 25-percent host reserve.
- Making the Patcher a permanent runtime dependency was rejected; the formal
  helper belongs to the customized PlayCover.

## Supersedes

- SKMB-2026-08-11-002 only where it described replacing the original PlayCover;
  its verified staging, journal, unknown-state and atomic-commit invariants remain.
- SKMB-2026-08-11-003 for the product authorization path. The root-owned runner
  remains the Developer Alpha mechanism, but is launched only through the fixed
  system-authorization provider and is not a Terminal or ordinary-launch fallback.
