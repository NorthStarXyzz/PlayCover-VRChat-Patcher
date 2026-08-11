# SKMB-2026-08-11-004: Remove the Disabled Sparkle Dependency

- status: accepted
- decided_by: designer
- approval_source: user-approved v0.1 plan explicitly requires official Sparkle updates to be disabled so upstream updates cannot overwrite the reviewed patch
- date: 2026-08-11
- commit: pending
- patterns:
  - D_external_dependency
  - E_security_boundary
  - F_fail_semantics
- scope: customized PlayCover updater dependency and launch validation

## Context

The update UI, feed, updater model, and automatic checks are already disabled.
Sparkle nevertheless remained linked and embedded. The first exact payload
candidate used Hardened Runtime with ad-hoc signatures, so dyld Library
Validation rejected the otherwise valid Sparkle framework before application
code ran because neither image had a Team Identifier.

## Decision

Remove Sparkle from the customized PlayCover target's package references,
framework linkage, embedding, and signing phase. Keep Hardened Runtime and
Library Validation enabled. Do not add
`com.apple.security.cs.disable-library-validation` and do not weaken SIP,
AMFI, or system policy.

Payload verification must reject a main executable that still loads Sparkle
or a bundle that still contains `Sparkle.framework`. A successful deep
`codesign` check alone is not a launchability claim.

## Applies To

- PlayCover patch series and seven-pin SwiftPM resolution
- payload build and verification gates
- CI full-build job
- M5 payload candidate selection

## Supersedes

The retained-but-disabled Sparkle dependency in the first `repro-d` candidate.
