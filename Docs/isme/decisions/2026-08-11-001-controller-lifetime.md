# SKMB-2026-08-11-001: Controller Lifetime

- status: accepted
- decided_by: designer
- approval_source: user explicitly requested implementation of the v0.1 plan on 2026-08-11
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - B_state_persistence
  - C_concurrent_operations
  - E_security_boundary
  - F_fail_semantics
- scope: VRChat memory-policy session

## Decision

Wait at most 300 seconds for the single reviewed VRChat executable. After the
policy is applied there is no elapsed-time maintenance limit. Maintain the
policy until that exact task exits. A normal task exit is successful completion.
If identity or policy can no longer be safely verified, fail closed by
terminating only the exact audit-token-bound task and waiting for it to exit.
Process exit is the authoritative rollback.

## Applies To

- worker and guardian lifecycle
- RunningBoard reset repair
- critical memory-pressure response
- socket state events and PlayCover UI
- controller fault-injection tests

## Alternatives

- Timed maintenance was rejected because it can leave a live game with the
  incompatible zero-memory state.
- Fail-open maintenance was rejected because the UI could claim compatibility
  after the kernel policy disappeared.

## Supersedes

The experimental 30-minute observation controller.

