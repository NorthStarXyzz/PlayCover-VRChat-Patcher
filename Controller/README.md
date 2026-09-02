# VRChat dynamic memory-policy controller

This directory contains the fixed-purpose root controller used by PlayCover
VRChat Patcher. It does not modify VRChat or inject code; it applies one
transient, non-fatal XNU memory policy to one exact task path.

## Policy contract

The patched PlayCover passes exactly one whole-GiB limit. Automatic mode uses:

```text
safeMaximumGiB = floor(physicalMemoryBytes * 75% / 1 GiB)
```

The root controller independently reads `hw.memsize` and accepts only a
canonical ASCII decimal in `4...safeMaximumGiB`. It never clamps an invalid
request or silently substitutes a fallback. Values below 8 GiB are valid but
emit a warning because VRChat may disable memory-intensive features. The value
is a soft-limit ceiling, not an up-front allocation or a measurement of free
system memory.

The write uses XNU `memorystatus_control` with
`MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES`, followed by a policy readback.

The non-zero policy addresses the `0 MB` memory report that can prevent remote
avatar and image resources from loading. The controller applies a real XNU
policy outside the game; it does not fabricate an API result, hook Unity, or
modify Appdome or `libloader`. Reported headroom is the selected limit minus the
current footprint and naturally falls as the process grows.

Target discovery waits at most 300 seconds. The console user's home comes only
from `/dev/console` plus `getpwuid_r`; no caller path or PID is accepted. The
only target is the independent patched library:

```text
~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/
com.vrchat.mobile.app/VRChat
```

The original `io.playcover.PlayCover` library is therefore not bindable.

## Build, tests, and reviewed hashes

From the repository root:

```zsh
zsh Tests/Controller/run-tests.sh
zsh Controller/build.sh
```

Tests use fake console-user/status backends, sanitizers, strict compiler
warnings, CLI rejection canaries, unsafe-metadata fixtures, exhaustive package
crash-state tables, deterministic double builds, and Installer-package
hash-chain checks. No VRChat binary allowlist or content fixture is generated
or required.
Tests do not invoke `sudo`, VRChat, or `memorystatus_control`.

The exact reviewed artifact hashes are generated from and pinned by
`package/ControllerPackageManifest.json`. The package verifier checks the
controller, runner, attestation, payload/BOM/script metadata, component
identity and complete flat-package SHA-256.

## Development Alpha installation

```zsh
zsh Controller/install.sh
```

That compatibility entry point now only builds and verifies
`Controller/package/build/PlayCoverVRChatMemoryPolicy.pkg`; it never invokes
`sudo`, Installer, or a root shell. Open the exact package in macOS Installer,
which owns the system authorization UI. Payload-bearing Patcher builds embed
the same exact package at
`Contents/Resources/Controller/PlayCoverVRChatMemoryPolicy.pkg`. Source-only
builds must not contain a `.pkg`.

The reviewed runner accepts exactly one canonical numeric limit or the exact
`--uninstall` operation. It passes the value as one quoted argv element—never
through `eval` or shell command construction—and the C controller revalidates
it. The runner also rechecks root-owned parent directories, ownership, modes,
ACLs, flags, controller hash, and strict code signature.

This Alpha package does not install a daemon, LaunchDaemon, login item, or
privileged XPC service. A future signed/notarized `SMAppService` frontend may
call the same fixed session engine, but must preserve this validation contract.

## PCVR/2 session protocol

The root controller creates the fixed socket:

```text
/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock
```

Its directory is root-owned mode `0755`; the socket is owned by the console
UID/GID, mode `0600`. The server checks every client with `getpeereid`; a client
must independently verify that the server UID is root.

The ASCII, newline-delimited protocol is:

```text
PCVR/2 HELLO capability-vrchat-2026.2.30300-1365-r7
PCVR/2 WAITING <selectedLimitMiB> <safeMaximumMiB>
PCVR/2 TARGET_BOUND <pid>
PCVR/2 LEASE_ACTIVE <pid> <selectedLimitMiB>
PCVR/2 METRICS <pid> <selectedLimitMiB> <footprintMiB> <headroomMiB> <reapplies> <pressure>
PCVR/2 COMPLETED
PCVR/2 FAILED <stableCode>
```

Metric MiB values have one decimal digit. Pressure is the XNU value 1, 2, or
4. Snapshots replay HELLO, the current phase, and the latest metrics. The only
client command is exact `PCVR/2 CANCEL`, accepted only in WAITING. Unknown,
combined, oversized, path-bearing, PID-bearing, or limit-bearing messages are
rejected. UI disconnects do not weaken guardian or controller safety.

## Target safety

The controller does not inspect VRChat's version, signature, UUID, entitlements,
framework hashes, or Mach-O inventory. It accepts updates without requiring a
new compatibility entry.

It still checks the exact independent-library executable path, console UID,
regular-file metadata, and stable process identity. These checks prevent a path
confusion or cross-user bind; they are not a VRChat content allowlist.

## Fail-closed safety

- The controller must run on arm64. The recorded macOS build/XNU values are test
  metadata, not a point-release lock; live policy readback remains mandatory.
- File descriptor metadata, process UUID/UID/PID/unique ID/start time,
  audit-token path, and readback policy must remain exact.
- Only the known RunningBoard `-1/-1` reset is repaired. Unfamiliar policy,
  excessive resets, critical pressure, identity uncertainty, or guardian
  failure stops the exact task and retries cleanup until task exit is proven.
- Maintenance has no elapsed timeout. Natural process exit is authoritative
  rollback; the policy cannot outlive its task.
- SIP, AMFI, and authenticated root remain enabled.

## Uninstall

Patcher Remove invokes only the fixed reviewed root-owned runner's exact
`--uninstall` operation through the same system authorization boundary.
Uninstall refuses an active singleton, an install transaction, or unexpected
runtime objects. A fixed root-owned operation claim excludes concurrent launch,
install, and uninstall before either transaction can cache state. Its root-owned
journal admits only the tested ordered crash subsets; the runner is removed last
while the claim is still held, and the sole journal-free recovery is the
exact runner-only final state with no package directory or receipt.
