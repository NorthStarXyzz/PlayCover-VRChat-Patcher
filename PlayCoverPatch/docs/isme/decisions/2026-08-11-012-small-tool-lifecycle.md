# SKMB-2026-08-11-012: Small-Tool Lifecycle

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly rejected the over-designed lifecycle and said this is a small tool on 2026-08-11; the previously accepted parallel-install plan already requires Remove to retain both game libraries.
- date: 2026-08-11
- commit: pending
- patterns:
  - B_state_persistence
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: Patcher inspection, receipt, configuration, and Remove behavior

## Decision

Keep the product flow small: choose the official PlayCover, create the parallel
customized app, install the fixed helper, and launch VRChat normally afterward.

The independent PlayCover library, imported VRChat, App Settings, entitlements,
keymaps, caches, and VRChat user data are mutable user data after creation. They
do not determine whether the customized app is installed and they never block
Remove. Remove verifies only the exact transaction-owned customized app, the
Patcher receipt, and the fixed helper state; it then removes those objects while
leaving both game libraries byte-for-byte untouched.

Initial import may still copy a small safe settings subset. The customized build
defaults PlayChain off and bypasses KeyCover for VRChat, but it does not enforce
a canonical 34-key settings state machine or expose a removal-only state.

Unknown customized App contents are never overwritten or deleted, VRChat is
never modified by the Patcher, and privileged operations remain fixed.

## Applies To

- installed-state inspection and receipt ownership checks
- Create/Repair reuse of ordinary mutable configuration
- Remove and interrupted-Remove recovery
- customized PlayCover PlayChain/KeyCover defaults
- user-facing state text and lifecycle tests

## Supersedes

SKMB-2026-08-11-011, except for its already compatible requirement that Remove
preserve the independent library.
