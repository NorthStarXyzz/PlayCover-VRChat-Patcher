# SKMB-2026-08-11-002: Patched-Build Safety UI

- status: superseded
- decided_by: designer
- approval_source: The designer explicitly required official Sparkle updates to be disabled, clear VRChat Patch branding in About and the main UI, and a copy-only fixed controller command on unavailable-controller failures on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: PlayCover patched-build update and recovery UI

## Context

An upstream Sparkle update can replace the reviewed PlayCover patch. Compatible
launch also needs an actionable recovery message when the separately installed
root controller is unavailable, without turning PlayCover into a privilege or
credential boundary.

## Decision

The patched build never starts Sparkle, never checks the official feed in the
background, and exposes no working automatic or manual official-update trigger.
The official feed keys are removed from the application plist. Update settings
show a localized explanation instead of controls.

The standard About panel is replaced with a localized panel that names the build
“PlayCover — VRChat Patch”, and the main window carries a persistent localized
“VRChat Patch” toolbar badge.

When compatible launch fails because the fixed controller endpoint is unavailable,
PlayCover remains fail-closed and presents the exact command
`/usr/bin/sudo /usr/local/bin/playcover-vrchat-memory-policy`. The only offered
action copies that string to the pasteboard. PlayCover never executes the command,
invokes a sudo helper, reads a password, or silently falls back. The explicit
context-menu standard launch remains available.

## Applies To

- Sparkle view model, Help menu, update settings, and application plist
- About panel and main-window branding
- controller-unavailable error classification and copy-only alert
- patch-local state and structural tests

## Supersedes

None.

## Superseded By

- SKMB-2026-08-11-007 parallel customized PlayCover identity and no-bypass launch
- SKMB-2026-08-11-008 dynamic PCVR/2 policy and system authorization
