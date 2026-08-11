# SKMB-2026-08-11-005: PlayCover SwiftPM Resolution

- status: superseded
- decided_by: designer
- approval_source: The designer approved the Xcode 26.6-generated eight-pin PlayCover Package.resolved as a reviewed overlay on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: upstream PlayCover SwiftPM dependency resolution

## Context

Upstream ignores the workspace `Package.resolved`, so a clean build can resolve
package requirements differently over time without appearing in normal Git
status. Xcode 26.6 generated a reviewed resolution containing eight pins.

## Decision

The patch package owns the exact resolution at
`overlay/PlayCover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
with SHA-256 `d96bb56c45c36a72df385018f330b83b5c407c5ae9fc0951b700b9d1bbadbcea`.
Application atomically installs a mode-0755 `swiftpm` directory containing only
an empty mode-0755 `configuration` directory and the mode-0644 lock.

Source validation requires that ignored state to be absent. Applied validation
includes the ignored lock explicitly in the exact untracked set and rejects
different contents, modes, symlinks, or extra children.

## Applies To

- the reviewed PlayCover SwiftPM overlay
- PlayCover patch apply/check/test scripts
- build and release documentation

## Supersedes

None.

## Superseded By

SKMB-2026-08-11-006.
