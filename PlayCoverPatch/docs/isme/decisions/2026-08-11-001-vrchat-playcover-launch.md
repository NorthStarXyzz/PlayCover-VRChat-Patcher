# SKMB-2026-08-11-001: VRChat PlayCover Launch Coordination

- status: superseded
- decided_by: designer
- approval_source: The designer explicitly required VRChat no-PlayTools install/export, default compatible double-click, explicit context-menu standard launch, root-authenticated Unix-socket WAITING, five-second timeout, pre-bind-only CANCEL, and no fallback on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - C_concurrent_operations
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: PlayCover patch for VRChat installation and launch coordination

## Context

Upstream PlayCover commit `55638e98f36eac1f3d09803799480e9d83f663f8`
injects PlayTools during ordinary installation/export and launches applications
directly through LLDB or NSWorkspace. VRChat's compatible path must preserve the
unmodified application and establish an external root controller session before
LaunchServices creates the target process.

## Decision

For bundle `com.vrchat.mobile`, installation and export never inject PlayTools.
An ordinary double-click selects compatible launch. After the existing PlayCover
preflight, the global coordinator connects
`/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock`, requires a
peer effective UID of zero, and requires ordered lines
`PCVR/1 HELLO <buildID>` then `PCVR/1 WAITING` within one five-second deadline.
Only then may PlayCover invoke NSWorkspace.

The controller subsequently emits TARGET_BOUND, LEASE_ACTIVE, METRICS,
COMPLETED, or FAILED using the accepted line protocol. PlayCover may send
`PCVR/1 CANCEL` only after a LaunchServices error and before TARGET_BOUND. It
never retries by launching without the controller. A context-menu command is
the sole explicit standard-launch entry for VRChat; non-VRChat behavior remains
upstream-compatible.

## Applies To

- PlayCover install and export PlayTools selection
- `VRChatMemoryPolicySessionProvider` and Unix-socket adapter
- global coordinator state transitions
- `PlayApp` preflight and NSWorkspace sequencing
- `PlayAppView` double-click and context-menu actions
- patch-local state-machine and structural tests

## Rationale

The root peer check prevents a same-user socket server from authorizing launch.
Waiting before NSWorkspace removes the target-discovery startup race. Explicit
standard launch preserves an operator escape hatch without silently weakening
compatible-mode failure semantics.

## Alternatives

- JSON framing was rejected in favor of the dependency-free PCVR/1 line protocol.
- Silent fallback to ordinary launch was rejected.
- The old profile/shim and direct binary-patch experiments are outside this patch.

## Supersedes

None.

## Superseded By

- SKMB-2026-08-11-007 parallel customized PlayCover identity and no-bypass launch
- SKMB-2026-08-11-008 dynamic PCVR/2 policy and system authorization
