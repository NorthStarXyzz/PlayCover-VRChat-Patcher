# SKMB-2026-08-11-006: Remove Sparkle and Lock the Seven-Pin Graph

- status: accepted
- decided_by: designer
- approval_source: the approved v0.1 plan explicitly disables official Sparkle updates; the exact first candidate then proved the retained unused framework prevented launch under ad-hoc Hardened Runtime
- date: 2026-08-11
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
  - G_irreversible_action
- scope: patched PlayCover target linkage and SwiftPM resolution

## Decision

Remove the unused Sparkle package product, package reference, framework build
entry, embedded framework, and Sparkle signing commands. Retain the PlayTools
signing phase under an accurate name. Do not disable Hardened Runtime or
Library Validation.

Replace the historical eight-pin lock with the Xcode 26.6-generated seven-pin
resolution whose SHA-256 is
`324e7c5d4b57421c2a4098cc4dc944da093382098c2595a1f84dcd9ecf848b04`.
The same ignored-state provenance and fail-closed mode checks continue to
apply.

## Applies To

- ordered PlayCover source patches
- reviewed workspace `Package.resolved`
- patch apply/check/tests
- payload build and launchability invariants

## Supersedes

SKMB-2026-08-11-005.
