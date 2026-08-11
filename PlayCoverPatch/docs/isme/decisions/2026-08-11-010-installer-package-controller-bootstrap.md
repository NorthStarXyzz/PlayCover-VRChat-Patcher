# SKMB-2026-08-11-010: Installer-Package Controller Bootstrap

- status: accepted
- decided_by: designer
- approval_source: The designer's parallel-install plan required Patch-time automatic setup with no extra player configuration, then explicitly selected the macOS Installer package option instead of the one-shot Authorization Services installer on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - B_state_persistence
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: Patcher completion, controller package installation, Repair, and Remove

## Context

The first real Create test correctly published the parallel application,
imported VRChat and migrated configuration, but then exposed that the installed
root runner was an older reviewed build.  The Patcher had already written its
final receipt and reported success, even though compatible launch had to reject
the stale runner.  A completed Patch must include root-controller readiness,
not merely application-file readiness.

The Developer Alpha has no Developer ID Installer certificate.  Its package is
therefore a local development artifact whose exact bytes are pinned by the
embedded compatibility manifest.  A public installable release remains blocked
on Developer ID signing, notarization and stapling.

## Decision

A payload-bearing Patcher embeds exactly one reviewed macOS Installer package.
After the parallel payload, imported VRChat and sanitized configuration verify,
Create enters `controller_setup_required` unless the exact current r6
installation already exists.  Beginning setup opens only the embedded package
in the system Installer application.  Installer owns the administrator prompt;
the Patcher never invokes `sudo`, sends a root shell program, reads a password,
or stores credentials.

The package manifest fixes its identifier, numeric version, relative bundle
path, complete package SHA-256, root-owned attestation contents, controller
SHA-256 and runner SHA-256.  Preinstall accepts only an absent installation, the
exact current installation, or an explicit allowlist of reviewed previous
installations.  It refuses unknown ownership, mode, ACL, flags, link count,
hash, active-session and partial-state combinations.  Postinstall verifies the
complete current state before returning success.

Patcher monitors Installer and independently checks the package receipt plus
root-owned attestation and the user-readable runner identity.  Only that exact
state permits `fully_patched`, writing the final receipt and removing the
transaction journal.  It polls the exact installation identity every 500 ms
for at most 900 seconds.  Cancellation, Installer failure, timeout or identity
mismatch retains the verified parallel app and journal in
`controller_setup_required`; Repair resumes at package setup without recopying
VRChat.

The package moves the controller contract to r6.  Remove preserves the original
and parallel game libraries.  It removes the exact root installation first when
present and inactive, using the already reviewed fixed root-owned runner
authorization path rather than a user-writable installer executable.  The r6
uninstall operation removes the controller, runner and root-owned installation
attestation and forgets the fixed Installer receipt.  Only then may Patcher
delete the exact parallel application.  If absence or safe uninstall cannot be
proven, Remove does not delete the parallel application.

Because forgetting an Installer receipt and unlinking a running script cannot
be one filesystem transaction, r6 uses a fixed persistent root-owned uninstall
journal and a closed recovery table.  The runner is always the last installed
file removed.  Immediately before its final self-unlink the journal is removed;
the sole accepted journal-free partial state is therefore an exact r6 runner by
itself with the receipt already absent.  A later `--uninstall` may finish only
that state.  Every other subset or journal transition fails closed.  Tests inject
an interruption after every transition.

Every controller launch, Installer preflight, and clean uninstall also owns the
same fixed root-owned operation-claim inode.  The claimant opens a temporary
inode before atomically linking it at the reviewed path, reopens the fixed link,
binds both descriptors to the same device/inode, and keeps them open for its
entire destructive lifetime.  A second live owner fails before reading or
caching uninstall state.  Only an exact claim with no live descriptor may be
recovered after a crash.  Uninstall retains ownership through runner self-unlink;
Installer preflight acquires ownership before creating its install journal.
The unique crash state after runner unlink but before claim cleanup is repaired
by reinstalling the exact package, then repeating reviewed uninstall.

## Applies To

- controller component-package root, scripts, receipt and attestation
- compatibility manifest and Patcher embedded resources
- Patcher inspection, Create, Repair, Remove and durable transaction phases
- macOS Installer adapter and its fake test provider
- package, identity, cancellation, interruption, upgrade and removal tests
- Alpha/release documentation and Developer ID release gates

## Supersedes

None.  This adds the missing bootstrap completion boundary to
SKMB-2026-08-11-007 through SKMB-2026-08-11-009.

## Superseded By

None.
