# Compatibility policy

Compatibility is allowlisted for the bundled payload and inferred from the fixed
runtime contract. The selected source PlayCover is intentionally not pinned to a
release build: it only needs the expected PlayCover bundle identity and safe
arm64 app structure. A schema-2 manifest is eligible only when these items match:

- the bundled patched PlayCover payload's source commit, release version/build,
  Developer ID release identity, executable/resource hashes, UUID, and full tree;
- customized payload bundle ID `io.github.northstarxyzz.PlayCoverVRChat`, exact
  version/build, reviewed signature/notarization state, manifest, and full tree;
- fixed official/customized app paths and distinct library roots;
- arm64 and a readable host capability;
- PCVR/2 build ID, socket contract, 300-second wait, non-fatal policy, 4 GiB
  floor, 1 GiB step, and 75% physical-memory ceiling.

There is no general minimum physical-memory gate. The helper computes
`floor(physical bytes × 75% / GiB)` on each session; a result below 4 GiB is
unsupported. Limits below 8 GiB are allowed with a warning.

`experimental` manifests may be used for developer validation but are never
presented as generally supported. `revoked` manifests must not launch, import,
patch, repair, or register a helper.

Adding a new patched PlayCover payload, controller, helper, or protocol revision
requires a new manifest and patch ID, clean builds, the full automated gate, and
two cold-start 30-minute gameplay sessions. A source-only PlayCover nightly does
not require a manifest entry; it is accepted structurally, but the Patcher still
publishes the reviewed payload bundled in that build. An existing manifest is
immutable except for a documented support-state change.

VRChat is not pinned to a version or binary identity. The importer only checks
that the source exists in the original PlayCover library, is safe to copy, and
matches the destination byte-for-byte after import. The controller then binds
the exact destination executable path; it does not inspect VRChat's contents.
