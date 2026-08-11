# State Machine Knowledge Base

This index records the designer-owned launch and controller-coordination
decisions encoded by the PlayCover patch series. Git hooks are intentionally
not installed because this project limits all generated material to
`PlayCoverPatch/`.

## Decision Index

| id | status | scope | patterns | file | commit |
| --- | --- | --- | --- | --- | --- |
| SKMB-2026-08-11-001 | superseded | VRChat PlayCover install and launch coordination | A, C, D, E, F, G | decisions/2026-08-11-001-vrchat-playcover-launch.md | pending |
| SKMB-2026-08-11-002 | superseded | Patched-build update lockout, branding, and controller recovery guidance | D, E, F, G | decisions/2026-08-11-002-patched-build-safety-ui.md | pending |
| SKMB-2026-08-11-003 | accepted | Reproducible PlayTools dependency resolution | D, E, F, G | decisions/2026-08-11-003-playtools-dependency-pin.md | pending |
| SKMB-2026-08-11-004 | accepted | Exact PlayTools Xcode 26 compatibility patch | D, E, F, G | decisions/2026-08-11-004-playtools-xcode26-compatibility.md | pending |
| SKMB-2026-08-11-005 | superseded | Exact PlayCover Xcode 26.6 SwiftPM resolution | D, E, F, G | decisions/2026-08-11-005-playcover-swiftpm-resolution.md | pending |
| SKMB-2026-08-11-006 | accepted | Remove disabled Sparkle dependency and lock seven-pin graph | D, E, F, G | decisions/2026-08-11-006-remove-sparkle-dependency.md | pending |
| SKMB-2026-08-11-007 | accepted | Parallel customized identity, library, import, and launch isolation | B, C, E, F, G | decisions/2026-08-11-007-parallel-customized-playcover.md | pending |
| SKMB-2026-08-11-008 | accepted | Dynamic PCVR/2 memory policy and Alpha authorization | A, B, C, D, E, F | decisions/2026-08-11-008-dynamic-pcvr2-authorization.md | pending |
| SKMB-2026-08-11-009 | accepted | Exact bundle identity, returned-process binding, and runner TOCTOU hardening | A, C, D, E, F, G | decisions/2026-08-11-009-launch-identity-and-runner-toctou.md | pending |
| SKMB-2026-08-11-010 | accepted | Installer-package controller bootstrap and Patcher completion | A, B, D, E, F, G | decisions/2026-08-11-010-installer-package-controller-bootstrap.md | pending |
| SKMB-2026-08-11-011 | superseded | Canonical 34-key VRChat settings lifecycle and removal-only retained library | B, C, E, F | decisions/2026-08-11-011-canonical-vrchat-settings-lifecycle.md | pending |
| SKMB-2026-08-11-012 | accepted | Small-tool lifecycle: mutable retained data and simple Remove | B, E, F, G | decisions/2026-08-11-012-small-tool-lifecycle.md | pending |

## Named States

| state | meaning | owner | notes | source |
| --- | --- | --- | --- | --- |
| idle | No controller session is owned by PlayCover | coordinator | Initial or reset state | SKMB-2026-08-11-008 |
| authorizing | System Authorization Services is launching the fixed root-owned runner with one snapshotted GiB argument | authorization provider | No Terminal or password channel | SKMB-2026-08-11-008 |
| connecting | The provider is connecting and authenticating the PCVR/2 root peer | coordinator | Five-second connect plus WAITING deadline | SKMB-2026-08-11-008 |
| waiting | Authenticated controller sent HELLO then dynamic WAITING matching the session snapshot | controller/coordinator | NSWorkspace has not been called | SKMB-2026-08-11-008 |
| launching | PlayCover has begun the one compatible LaunchServices request | coordinator | No fallback or explicit standard VRChat launch exists | SKMB-2026-08-11-007 |
| target_bound | Controller reported TARGET_BOUND for one PID | controller | CANCEL is no longer permitted | SKMB-2026-08-11-008 |
| lease_active | Controller reported a lease whose dynamic limit matches the snapshot | controller | Dynamic METRICS update this state | SKMB-2026-08-11-008 |
| completed | Controller reported normal completion | controller | A later launch takes a new settings snapshot | SKMB-2026-08-11-008 |
| cancel_requested | LaunchServices failed and PlayCover sent pre-bind CANCEL | coordinator | Never used after TARGET_BOUND | SKMB-2026-08-11-008 |
| failed | Validation, authorization, authentication, timeout, protocol, controller, or launch setup failed | coordinator | No standard-launch fallback | SKMB-2026-08-11-008 |
| controller_setup_required | The parallel payload and imported library verify, but the exact root-owned r6 package installation is absent or stale | Patcher | Create/Repair may open the reviewed package in macOS Installer | SKMB-2026-08-11-010 |
| installing_controller | macOS Installer is presenting or processing the exact embedded controller package | Patcher | Patcher never handles the administrator password | SKMB-2026-08-11-010 |
| fully_patched | Parallel payload, imported VRChat, sanitized configuration, receipt, and exact r6 installation all verify | Patcher | This is the only successful Create/Repair terminal state | SKMB-2026-08-11-010 |

## Transition Decisions

| id | from_state | event | to_state | actions | source |
| --- | --- | --- | --- | --- | --- |
| SKMB-2026-08-11-008-T1 | idle/terminal | compatible launch requested | authorizing | Snapshot validated mode and launch fixed runner with exactly one canonical GiB argument | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T2 | authorizing | runner accepted | connecting | Connect fixed socket and authenticate root peer | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T3 | connecting | PCVR/2 HELLO then matching WAITING within 30 seconds | waiting | Return launch readiness with selected and safe limits | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T4 | waiting | NSWorkspace request begins | launching | Preserve immutable session snapshot | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T5 | launching | TARGET_BOUND | target_bound | Permanently disable client CANCEL | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T6 | target_bound | LEASE_ACTIVE for same PID and selected dynamic limit | lease_active | Begin dynamic metrics tracking | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T7 | launching | LaunchServices fails before observed bind | cancel_requested | Send exactly one PCVR/2 CANCEL line | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T8 | lease_active | COMPLETED | completed | Close the client session | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-T9 | active | FAILED or protocol violation | failed | Close; never invoke a fallback launch | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-009-T1 | idle/terminal | compatible launch requested | preflighting | Require exact independent-library URL, a no-symlink tree, and reviewed composite allowlist identity before authorization | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-T2 | waiting | launch request is about to begin | waiting | Revalidate the same exact URL and reviewed identity immediately before LaunchServices | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-T3 | launching | LaunchServices returns a running application | target_bound | Require exact bundle/executable URLs and require its PID to equal the controller's first TARGET_BOUND event | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-T4 | launching | returned path/PID or TARGET_BOUND differs | failed | Cancel if still pre-bind, close the controller session, and terminate the exact NSRunningApplication returned by LaunchServices | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-010-T1 | payload/configuration verified | exact r6 install missing or stale | controller_setup_required | Preserve the verified parallel copy and recoverable transaction state | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-T2 | controller_setup_required | user begins setup | installing_controller | Open only the exact embedded package in macOS Installer | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-T3 | installing_controller | exact package receipt, attestation, runner metadata/hash, and r6 build identity verify within the 900-second window | fully_patched | Poll every 500ms, then write the final receipt and remove the transaction journal | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-T4 | installing_controller | Installer is cancelled, fails, exceeds 900 seconds, or post-install identity differs | controller_setup_required | Keep the journal and expose Repair; never report success | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-012-T1 | exact customized App installed | Inspect/Remove | fully_patched/removing | Treat the independent library as mutable user data; verify only transaction-owned App, receipt, and helper before Remove | SKMB-2026-08-11-012 |

## Invariants

| id | invariant | source |
| --- | --- | --- |
| SKMB-2026-08-11-007-I1 | The customized app identity is `io.github.northstarxyzz.PlayCoverVRChat`, display name is `PlayCover VRChat`, and every library path is rooted at its independent container | SKMB-2026-08-11-007 |
| SKMB-2026-08-11-007-I2 | The customized build creates no application aliases and launches the exact library bundle URL | SKMB-2026-08-11-007 |
| SKMB-2026-08-11-007-I3 | Global `PlayTools.installOnSystem` is never invoked; VRChat IPA install/export and PlayTools injection are unavailable | SKMB-2026-08-11-007 |
| SKMB-2026-08-11-007-I4 | Imported VRChat launch validation is read-only; any state that upstream would repair by signing, rewriting, conversion, or injection fails before authorization | SKMB-2026-08-11-007 |
| SKMB-2026-08-11-007-I5 | Every VRChat launch uses compatible mode; there is no explicit, implicit, or failure fallback to standard mode | SKMB-2026-08-11-007 |
| SKMB-2026-08-11-008-I1 | Safe maximum is exactly `floor(physicalBytes * 75% / GiB)` and every custom value is a whole GiB in `4...safeMaximum` | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-I2 | Values below 8 GiB are accepted with a warning; invalid values are rejected and never clamped | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-I3 | A launch snapshots mode, selected limit, and safe maximum; later settings changes affect only the next session | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-I4 | Authorization invokes only `/usr/local/bin/playcover-vrchat-memory-policy` with one canonical decimal argument, handles no password, and is injectable in tests | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-I5 | Only a PCVR/2 Unix-socket peer whose effective UID is root can authorize compatible launch; dynamic WAITING, lease, and metrics limits must match the session snapshot | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-I6 | Client CANCEL is permitted only before TARGET_BOUND; all authorization, protocol, and controller failures remain fail-closed | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-I7 | Formal SMAppService onboarding is unavailable until a signed embedded daemon and plist are part of a notarizable payload | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-009-I1 | Bundle ID alone never authorizes VRChat: `PlayApp.url` must equal the independent library URL byte-for-byte and every path object must be non-symlinked | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-I2 | Before root authorization, the complete thin-arm64 Mach-O set must reproduce the reviewed count and canonical allowlist SHA-256; signature, version, bundle ID, and main composite identity are also exact | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-I3 | The fixed runner and `/`, `/usr`, `/usr/local`, `/usr/local/bin` chain are root-owned, non-writable, ACL-free, and metadata-safe; the runner is one-link, executable, and has the reviewed SHA-256 | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-I4 | Authorization retains an O_NOFOLLOW descriptor identity and revalidates path dev/inode/metadata/hash immediately before the legacy path-only execute call | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-010-I1 | A payload-bearing Patcher embeds exactly one reviewed controller package; its identifier, version, relative path, SHA-256, installed attestation, controller hash, and runner hash come from the signed compatibility manifest | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-I2 | Initial install and upgrade run only through macOS Installer; Patcher never invokes sudo, a root shell, or a user-writable executable with privileges and never reads or stores an administrator password | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-I3 | Package scripts accept only absent, exact-current, or explicitly reviewed prior controller installations; unknown files, metadata, ACLs, an active lease, or a partial unrecognized state fail closed | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-I4 | Remove preserves both game libraries and may delete the exact parallel App only after the absent/exact root installation is safely removed; the exact r6 root-owned runner removes controller, runner, attestation, and pkg receipt through the already accepted Authorization Services boundary | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-I5 | Clean uninstall uses a fixed persistent root-owned journal, deletes the runner last, and accepts only journal-declared transitions plus the exact final runner-only/receipt-absent recovery subset; every other partial combination is unknown | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-I6 | Launch, Installer preflight, and uninstall share one atomic root-owned operation claim; a live owner excludes every other actor before state caching, stale recovery is identity-bound, and uninstall holds ownership through runner self-unlink | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-012-I1 | App Settings, imported VRChat, keymaps, caches, and the independent library are mutable user data after creation and are not receipt or Remove identity anchors | SKMB-2026-08-11-012 |
| SKMB-2026-08-11-012-I2 | Remove does not inspect, rewrite, delete, or otherwise condition success on either PlayCover game library | SKMB-2026-08-11-012 |
| SKMB-2026-08-11-012-I3 | The customized build defaults VRChat PlayChain off and bypasses KeyCover for VRChat without imposing a canonical 34-key settings state machine | SKMB-2026-08-11-012 |
| SKMB-2026-08-11-003-I1 | Carthage resolves PlayTools only from reviewed commit `f17b9211211fb4cf5652d4930ea82613ee3c92a5`; build paths use bootstrap and never update | SKMB-2026-08-11-003 |
| SKMB-2026-08-11-004-I1 | The pinned PlayTools checkout is the exact pristine export, exact Discord-only intermediate, or exact source-plus-SwiftPM final tree; every other state is rejected | SKMB-2026-08-11-004 |
| SKMB-2026-08-11-004-I2 | Alpha builds normalize an empty or `Sign to Run Locally` nested-code-sign identity to ad-hoc `-`; real identities pass through unchanged | SKMB-2026-08-11-004 |
| SKMB-2026-08-11-004-I3 | PlayTools builds consume the reviewed five-pin SwiftPM resolution, including SwordRPC revision `4403152a16a040d8448d33d65ad5a034c9d1fa1b`, and do not reuse a cached build | SKMB-2026-08-11-004 |
| SKMB-2026-08-11-006-I1 | The patched target does not link or embed Sparkle and consumes the exact reviewed seven-pin Xcode 26.6 SwiftPM resolution | SKMB-2026-08-11-006 |

## Fail Semantics

| id | context | behavior | source |
| --- | --- | --- | --- |
| SKMB-2026-08-11-007-F1 | Imported VRChat requires any repair or contains PlayTools | Abort before authorization without changing the bundle | SKMB-2026-08-11-007 |
| SKMB-2026-08-11-008-F1 | Mode resolution, authorization, connect, root-peer authentication, WAITING, or PCVR/2 parsing fails | Abort before NSWorkspace and never launch standard mode | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-F2 | LaunchServices fails after WAITING | Request pre-bind cancellation when still legal; surface the original error; do not retry or fall back | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-008-F3 | Controller reports FAILED after launch begins | Record terminal failure and close the channel; controller owns target fail-closed behavior | SKMB-2026-08-11-008 |
| SKMB-2026-08-11-009-F1 | Exact URL, path topology, signature, version, allowlist, main identity, runner ACL/metadata/hash, or runner revalidation differs | Fail before authorization or execution; never clamp, repair, substitute, or launch | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-009-F2 | LaunchServices returns another location/PID or controller TARGET_BOUND does not match | Terminate the returned application, close/cancel the controller session as legally permitted, and never continue to LEASE_ACTIVE | SKMB-2026-08-11-009 |
| SKMB-2026-08-11-010-F1 | Package is missing, altered, cancelled, fails, times out, or does not produce the exact reviewed installation | Preserve the verified parallel copy and transaction journal as controller_setup_required; Repair retries setup and VRChat remains fail-closed | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-010-F2 | Remove cannot prove the controller absent, inactive, and safely uninstallable | Keep the parallel App and independent library unchanged; do not partially remove | SKMB-2026-08-11-010 |
| SKMB-2026-08-11-003-F1 | Reviewed Cartfile.resolved is missing or differs | Refuse applied validation; do not resolve a floating replacement | SKMB-2026-08-11-003 |
| SKMB-2026-08-11-004-F1 | PlayTools exported-tree path, file hash, mode, type, lock, or complete tree digest differs | Refuse to patch or build; do not infer, replace the lock, merge, reset, or update the dependency | SKMB-2026-08-11-004 |
| SKMB-2026-08-11-005-F1 | PlayCover SwiftPM state exists in a source tree or its applied lock, mode, type, children, or pin set differs | Refuse source/application validation; never overwrite or infer a replacement resolution | SKMB-2026-08-11-005 |
| SKMB-2026-08-11-006-F1 | Sparkle remains linked/embedded or the seven-pin lock differs | Refuse patch validation and payload publication; never disable Library Validation as a fallback | SKMB-2026-08-11-006 |

## Statistical Defaults Allowed Temporarily

| id | pattern | context | default | reason_allowed | review_by | file |
| --- | --- | --- | --- | --- | --- | --- |

## Open Decisions

| id | pattern | context | needed_before | file |
| --- | --- | --- | --- | --- |
