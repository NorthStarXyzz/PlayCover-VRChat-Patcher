# SKMB-2026-08-11-002: Patch Transaction and Recovery

- status: accepted
- decided_by: designer
- approval_source: user explicitly requested implementation of the v0.1 patch/repair/restore plan on 2026-08-11
- date: 2026-08-11
- commit: pending
- patterns:
  - B_state_persistence
  - C_concurrent_operations
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: PlayCover inspection, patching, repair and restore

## Decision

Never edit the installed PlayCover bundle in place. Verify the exact supported
original, create and verify a durable backup, build and verify a staging bundle
on the same volume, then commit by replacement. If commit fails after moving
the original, restore the verified backup before returning. Unknown or mixed
states are inspect-only and must not be overwritten. Restore accepts only a
backup whose manifest and hashes match the recorded original.

## Applies To

- `inspect`, `patch`, `repair` and `restore`
- backup manifest and staging layout
- process-running preconditions
- interruption and idempotency tests

## Alternatives

- In-place Mach-O edits were rejected as non-transactional and hard to audit.
- Deleting an unknown installation was rejected as destructive and ambiguous.

## Supersedes

None.

