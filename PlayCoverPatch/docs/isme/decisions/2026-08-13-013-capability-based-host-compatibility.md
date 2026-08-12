# SKMB-2026-08-13-013: Capability-Based Host Compatibility

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly requested removal of the hard-coded macOS build/XNU compatibility lock after the controller rejected macOS 26.6.2 build 25G82 on 2026-08-13.
- date: 2026-08-13
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
- scope: Host checks for the VRChat memory-policy controller, package installer, Patcher runtime inspection, and compatibility manifests

## Decision

The controller and installer must not reject a host solely because its
`kern.osversion` or `kern.version` differs from the machine used to build the
reviewed artifact. The old exact `25G70`/`xnu-12377.161.13~4` string gate is
removed. The host remains required to be arm64; the controller still performs
the reviewed VRChat identity check, memorystatus policy write/readback,
runtime-image verification, process binding, and fail-closed rollback.

The Patcher records the manifest host values as tested-environment metadata,
not as a launch gate. It rejects a non-arm64 runtime or a host that cannot
meet the configured memory-policy floor, but it does not compare the current
macOS product/build/XNU strings to the tested metadata.

The controller build ID is bumped so an older exact-build controller cannot be
mistaken for this capability-based implementation. A failed capability or
identity check remains terminal; no ordinary VRChat launch fallback is added.

## Applies To

- `Controller/vrchat-memory-policy-controller.c`
- package preinstall/postinstall host checks
- Patcher runtime inspection and manifest schema validation
- PCVR/2 build identity, package manifests, and user documentation

## Fail Semantics

- Non-arm64 host, unreadable host capability data, invalid VRChat identity,
  policy write/readback failure, or runtime-image mismatch: stop before or
  during the session and report failure.
- A new macOS build is not itself an error. The policy operation is the
  compatibility probe; it must succeed and be read back before the session is
  considered active.

## Supersedes

- The host portion of SKMB-2026-08-11-008 and the fixed-build statements in
  the earlier v0.1 compatibility decisions.
