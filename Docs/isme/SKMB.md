# State Machine Knowledge Base

This index records the designer-approved state and failure semantics for
PlayCover VRChat Patcher. Decisions are append-only and live in `decisions/`.

## Decision Index

| id | status | scope | patterns | file | commit |
| --- | --- | --- | --- | --- | --- |
| SKMB-2026-08-11-001 | accepted | memory-policy session lifetime | A,B,C,E,F | decisions/2026-08-11-001-controller-lifetime.md | pending |
| SKMB-2026-08-11-002 | accepted | patch transaction and recovery | B,C,E,F,G | decisions/2026-08-11-002-patch-transaction.md | pending |
| SKMB-2026-08-11-003 | accepted | v0.1 privilege boundary | A,E,F | decisions/2026-08-11-003-v01-privilege-boundary.md | pending |
| SKMB-2026-08-11-004 | accepted | disabled updater dependency boundary | D,E,F | decisions/2026-08-11-004-remove-disabled-sparkle.md | pending |
| SKMB-2026-08-11-005 | accepted | parallel patched app, dynamic policy and helper lifecycle | A,B,C,E,F,G | decisions/2026-08-11-005-parallel-app-dynamic-policy.md | pending |

## Named States

| state | meaning | owner | source |
| --- | --- | --- | --- |
| inspected | PlayCover was read and classified without mutation | Patcher | SKMB-002 |
| staged | verified customized-app and VRChat-import trees exist at owned temporary paths | Patcher | SKMB-005 |
| parallel_published | the exact customized app was atomically created beside the untouched original | Patcher | SKMB-005 |
| waiting | controller is authenticated and waiting for VRChat | Controller | SKMB-001 |
| lease_active | the exact task has the snapshotted, root-validated dynamic soft policy | Controller | SKMB-005 |
| maintaining | policy and identity are continuously verified | Controller | SKMB-001 |
| completed | the exact VRChat task exited and its ledger vanished | Controller | SKMB-001 |
| failed_closed | the controller terminated the exact target after losing safety | Controller | SKMB-001 |
| imported | the exact supported VRChat tree exists in the patched app's independent library | Patcher | SKMB-005 |
| helper_ready | the selected authorization backend has authenticated and reported WAITING | PlayCover VRChat | SKMB-005 |

## Invariants

| id | invariant | source |
| --- | --- | --- |
| I-001 | VRChat, UnityFramework, Appdome and macOS system files are never modified. | user-approved v0.1 plan |
| I-002 | The root controller accepts no caller path, PID or command and only one root-revalidated whole-GiB value within the signed 4 GiB...75% contract. | SKMB-005 |
| I-003 | No compatibility failure silently falls back to a standard launch. | SKMB-001 |
| I-004 | The original PlayCover app and library are verified before and after publication and are never transaction-owned mutation targets. | SKMB-005 |
| I-005 | Process exit is the authoritative policy rollback. | SKMB-001 |
| I-006 | The customized PlayCover target neither links nor embeds Sparkle; Hardened Runtime and Library Validation remain enabled. | SKMB-004 |
| I-007 | `/Applications/PlayCover.app` and its library are never replaced or modified by Patch, Repair or Remove. | SKMB-005 |
| I-008 | The patched app uses a distinct bundle identifier and independent PlayCover library. | SKMB-005 |
| I-009 | A requested memory limit is an integral GiB value from 4 GiB through the host's rounded-down 75% ceiling. | SKMB-005 |

## Fail Semantics

| id | context | behavior | source |
| --- | --- | --- | --- |
| F-001 | controller identity/policy/watchdog failure after bind | terminate only the exact task and wait for exit | SKMB-001 |
| F-002 | patch staging or verification failure | leave the original app untouched and remove staging | SKMB-002 |
| F-003 | create/remove interruption | recover only manifest-owned staging/journal state; never move, replace or restore over the original | SKMB-005 |
| F-004 | authorization cancelled or controller unavailable | do not launch VRChat | SKMB-003 |
| F-005 | import, helper registration, dynamic-policy validation or patched-copy verification fails | leave the original untouched and do not launch VRChat | SKMB-005 |

## Open Decisions

Developer Alpha uses per-session system authorization. Public silent operation
remains gated on Developer ID signing and notarization of the embedded
`SMAppService` helper.
