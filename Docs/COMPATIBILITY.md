# Compatibility policy

Compatibility is allowlisted rather than inferred. A schema-2 manifest is
eligible only when all of these match:

- official PlayCover source commit, release version/build, Developer ID release
  identity, executable/resource hashes, UUID, and full tree;
- customized payload bundle ID `io.github.northstarxyzz.PlayCoverVRChat`, exact
  version/build, reviewed signature/notarization state, manifest, and full tree;
- fixed official/customized app paths and distinct library roots;
- VRChat bundle ID and version/build;
- VRChat normalized main Mach-O, load-command and semantic-entitlement hashes;
- exact UnityFramework and Appdome `libloader` hashes and UUIDs;
- arm64, macOS product/build, and XNU build;
- PCVR/2 build ID, socket contract, 300-second wait, non-fatal policy, 4 GiB
  floor, 1 GiB step, and 75% physical-memory ceiling.

There is no general minimum physical-memory gate. The helper computes
`floor(physical bytes × 75% / GiB)` on each session; a result below 4 GiB is
unsupported. Limits below 8 GiB are allowed with a warning.

`experimental` manifests may be used for developer validation but are never
presented as generally supported. `revoked` manifests must not launch, import,
patch, repair, or register a helper.

Adding support for a new PlayCover, VRChat, macOS, XNU, controller, helper, or
identity-normalization revision requires a new manifest and patch ID, clean
builds, the full automated gate, and two cold-start 30-minute gameplay sessions.
An existing manifest is immutable except for a documented support-state change.

The imported source and destination VRChat trees must also match each other
byte-for-byte after copy. That dynamic equality check is in addition to, not a
replacement for, the stable reviewed identity above.
