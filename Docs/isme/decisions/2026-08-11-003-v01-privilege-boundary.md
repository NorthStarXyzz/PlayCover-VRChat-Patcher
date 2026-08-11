# SKMB-2026-08-11-003: v0.1 Privilege Boundary

- status: accepted
- decided_by: designer
- approval_source: user explicitly requested the fixed v0.1 plan; earlier controller checkpoint explicitly chose no hooks and no daemon
- date: 2026-08-11
- commit: pending
- patterns:
  - A_async_wait
  - E_security_boundary
  - F_fail_semantics
- scope: v0.1 authorization and root IPC

## Decision

v0.1 has no daemon, LaunchDaemon, login item, setuid tool or privileged XPC
service. The reviewed runner is root-owned and the user explicitly invokes one
fixed absolute `sudo` command in Terminal. PlayCover never reads a password.
The controller exposes status through a versioned Unix socket, verifies the
console user's peer credentials, and accepts only pre-bind cancellation. It
does not accept path, PID, memory limit, wait duration or arbitrary commands.

Do not install SKMB Git hooks in v0.1. A demand-launched, notarized
`SMAppService` helper is a separate v0.2 decision.

## Applies To

- controller runner and package layout
- Unix socket ownership and protocol
- authorization sheet and launch coordinator
- release documentation

## Alternatives

- Passing an administrator password to PlayCover was rejected.
- A persistent or demand-launched daemon was deferred until Developer ID
  signing and notarization are available.

## Supersedes

The experimental user-writable `.command` launcher.
