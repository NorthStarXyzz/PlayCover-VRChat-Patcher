# SKMB-2026-08-11-008: Dynamic PCVR/2 Policy and Alpha Authorization

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly required automatic 75-percent and bounded custom-GiB modes, next-session snapshots, PCVR/2 dynamic metrics, a fixed-runner system authorization provider, no fallback, and a gated SMAppService policy on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - B_state_persistence
  - C_concurrent_operations
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
- scope: VRChat dynamic memory-policy selection, authorization, and controller protocol

## Decision

`VRChatMemoryPolicyMode` has exactly two cases:
`automatic75Percent` and `customGiB(UInt16)`. The safe maximum is the exact
integer result of `floor(physicalBytes * 75% / GiB)`. Automatic mode selects
that maximum. Custom mode accepts only whole GiB values in `4...safeMaximum`.
No layer clamps an invalid value. A selected value below 8 GiB remains valid but
is presented with a warning.

At launch, the coordinator creates an immutable snapshot containing the mode,
selected GiB, safe maximum GiB, and low-memory warning. Settings changes after
that point apply only to the next session.

The Developer Alpha authorization adapter validates that
`/usr/local/bin/playcover-vrchat-memory-policy` is a non-symlink, root-owned,
non-group/world-writable executable. Through macOS Authorization Services it
invokes only that path with exactly one canonical ASCII decimal GiB argument.
It never opens Terminal, constructs a shell command, reads a password, or calls
`Shell.runSu`. The adapter is injected behind a protocol for deterministic
tests. Any failure aborts before LaunchServices.

After authorization, the client authenticates a root Unix-socket peer and
requires PCVR/2 build `capability-vrchat-2026.2.30300-1365-r7`. `WAITING` reports the
selected and safe MiB values. `LEASE_ACTIVE` and every `METRICS` line must use
the selected limit and bound PID. Metrics carry one-decimal footprint/headroom,
reapply count, and pressure. Client `PCVR/2 CANCEL` is legal only before
`TARGET_BOUND`.

Formal `SMAppService` onboarding is unavailable in this Developer Alpha. It
must not be exposed until the application embeds a signed LaunchDaemon,
reviewed plist and code requirement and is eligible for Developer ID signing,
notarization, and stapling.

## Applies To

- memory-policy settings model and SwiftUI controls
- immutable session snapshot and low-memory warning
- authorization provider protocol and system adapter
- PCVR/2 Unix socket adapter, parser, coordinator, and live metrics
- localized errors, settings text, and tests

## Supersedes

- SKMB-2026-08-11-001 fixed 16 GiB PCVR/1 protocol
- SKMB-2026-08-11-002 Terminal copy-command recovery

## Superseded By

None.
