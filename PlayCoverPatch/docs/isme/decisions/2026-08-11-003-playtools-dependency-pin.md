# SKMB-2026-08-11-003: PlayTools Dependency Pin

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly identified PlayTools v3.1.0 commit f17b9211211fb4cf5652d4930ea82613ee3c92a5 as the reviewed baseline and required a checked overlay plus Carthage bootstrap instead of update on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: PlayCover Carthage dependency resolution

## Context

A clean build that runs `carthage update` may resolve the floating PlayTools
`master` dependency to unreviewed code. The reviewed compatibility baseline is
the v3.1.0 tree at commit
`f17b9211211fb4cf5652d4930ea82613ee3c92a5`.

## Decision

The patch package owns a reviewed `Cartfile.resolved` overlay containing the
exact commit. Application installs that file and applied validation requires
byte-for-byte identity. The Xcode Carthage phase invokes `bootstrap` with
XCFrameworks and never invokes `update`.

If the reviewed file is absent or differs, validation fails closed. Scripts do
not fetch, update, or infer a replacement dependency revision.

## Applies To

- `overlay/Cartfile.resolved`
- patch 0004 Xcode Carthage phase
- patch apply and validation scripts
- build and release documentation

## Supersedes

None.

## Superseded By

None.
