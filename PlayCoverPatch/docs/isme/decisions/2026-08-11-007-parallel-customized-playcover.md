# SKMB-2026-08-11-007: Parallel Customized PlayCover

- status: accepted
- decided_by: designer
- approval_source: The designer explicitly required the parallel customized identity, isolated library, disabled aliases and global PlayTools install, read-only imported VRChat validation, and compatible-only VRChat launch on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - B_state_persistence
  - C_concurrent_operations
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: customized PlayCover identity, library, import, and launch isolation

## Decision

The customized application uses bundle identifier
`io.github.northstarxyzz.PlayCoverVRChat`, display name `PlayCover VRChat`, and
the independent library root
`~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat`. It never reads
or writes the official PlayCover library implicitly.

Aliases are disabled. LaunchServices receives the exact installed app bundle
URL from the customized library. The customized build does not invoke global
`PlayTools.installOnSystem`, and normal VRChat IPA install/export is rejected;
the compatible VRChat bundle must arrive through the separately verified import
transaction.

Before every VRChat launch, PlayCover performs only read operations. If
entitlements, signature metadata, architecture, or PlayTools absence would make
upstream repair, re-sign, rewrite, convert, or inject the bundle, launch fails
before authorization. Every VRChat launch uses compatible mode. The old
diagnostic context-menu standard launch is removed and no failure path falls
back to standard launch. Non-VRChat apps retain standard launch behavior.

## Applies To

- Xcode target identity and Info.plist display name
- PlayCover container and application-library paths
- alias creation, settings display, and LaunchServices URLs
- AppsVM global PlayTools setup
- VRChat installer/export and read-only launch preflight
- structural and state tests

## Supersedes

- SKMB-2026-08-11-001 diagnostic standard-launch exception
- SKMB-2026-08-11-002 historical branding and Terminal copy-command behavior

## Superseded By

None.
