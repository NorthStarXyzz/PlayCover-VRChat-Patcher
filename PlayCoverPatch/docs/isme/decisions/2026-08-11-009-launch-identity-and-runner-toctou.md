# SKMB-2026-08-11-009: Launch Identity and Runner TOCTOU Hardening

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly required exact independent-library URL and reviewed composite/allowlist validation before authorization, returned LaunchServices PID/path binding to TARGET_BOUND, fail-closed termination, ACL/metadata runner hardening, O_NOFOLLOW descriptor binding, and immediate pre-execute revalidation on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - C_concurrent_operations
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: VRChat launch identity and Developer Alpha privileged-runner execution

## Decision

A compatible launch is authorized only for the literal independent-library URL
`~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/com.vrchat.mobile.app`.
Bundle identifier equality is insufficient. The path chain and complete bundle
tree must contain no symlinks, and validation before authorization must reproduce
the reviewed thin-arm64 Mach-O count and canonical allowlist SHA-256, exact main
composite identity, bundle version, identifier, and valid strict code signature.
The same identity is revalidated immediately before LaunchServices.

LaunchServices must return that exact bundle and executable URL. Its positive
PID must equal the controller's first `TARGET_BOUND` event before monitoring may
advance. A path or PID mismatch closes or legally cancels the controller session
and causes the exact returned `NSRunningApplication` to be terminated. No same-ID
application from another directory and no fallback launch is accepted.

The Developer Alpha provider rejects extended ACLs, non-root ownership,
group/other write permission, unsafe append/immutable flags, unexpected file
types, unsafe link counts, a non-executable runner, or an unreviewed runner hash
on the fixed runner and its fixed ancestor chain. It opens the runner with
`O_NOFOLLOW`, retains its device/inode/metadata/hash identity through user
authorization, and reopens and revalidates that identity immediately before
calling the legacy authorization execution ABI.

On Darwin, a nil `acl_get_file`/`acl_get_fd_np` result with `ENOENT` is the only
accepted no-ACL result. Every nonnil extended `acl_t` means that an ACL exists;
the numeric success return from `acl_get_entry` is never used as an emptiness
test.

`AuthorizationExecuteWithPrivileges` accepts only a pathname, not an already
validated descriptor. Therefore a final path lookup remains between the last
check and kernel execution. The Alpha documents this residual, pins the complete
root-owned wrapper hash, and treats replacement detected before or after the call
as failure. A production release must replace this ABI with a signed helper and
code requirement rather than claiming descriptor-atomic execution.

## Applies To

- exact VRChat location and reviewed-bundle identity validator
- PlayApp LaunchServices bridge and coordinator TARGET_BOUND transition
- fixed runner filesystem inspection and authorization adapter
- wrong-location, symlink, ACL, replacement-race, and PID mismatch tests
- bilingual failure text and patch structural verifier

## Supersedes

None. This decision tightens SKMB-2026-08-11-007 and SKMB-2026-08-11-008.

## Superseded By

None.
