# VRChat dynamic memory-policy controller

This directory contains the fixed-purpose root controller used by PlayCover
VRChat Patcher. It does not modify VRChat or inject code; it applies one
transient, non-fatal XNU memory policy to one exact, reviewed task.

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

On the locked VRChat build, the T5/T6 comparison found that non-zero memory
semantics were necessary for the observed remote avatar/model AssetBundle path.
The controller therefore applies a real XNU policy outside the game; it does not
fabricate an API result, hook Unity, or modify Appdome or `libloader`. Reported
headroom is the selected limit minus the current footprint and naturally falls
as the process grows.

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

Tests use fake console-user/status backends, synthetic Mach-O fixtures,
sanitizers, strict compiler warnings, CLI rejection canaries, runtime-region
simulation, public `libproc` enumeration, unsafe-metadata fixtures,
exhaustive package crash-state tables, deterministic double builds, and
Installer-package hash-chain checks. When
`PCVR_TEST_REVIEWED_EXECUTABLE` names the reviewed source executable, the test
also regenerates the complete code allowlist and compares it byte-for-byte.
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
PCVR/2 HELLO 25G70-vrchat-2026.2.30300-1365-r6
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

## Cross-user executable-code identity gate

The controller does not trust the machine-specific full hash of an ad-hoc
signature. Instead, the generated reviewed allowlist binds all 46 thin arm64
Mach-O files in VRChat 2026.2.30300 (1365), including the main executable,
every bundled framework, Appdome `libloader`, Python extension frameworks, and
the notification extension. Each entry contains its exact relative path,
Mach-O UUID, normalized unsigned SHA-256, and normalized load-command SHA-256.
An extra, missing, duplicate, fat, symlinked, or mismatching Mach-O fails the
preflight.

The canonical allowlist SHA-256 is
`60df094badbe3fb9e8f051f07d2a38a54cfb7bd592c3cf62a69e355050ec5109`.
Canonical bytes begin `PCVR-MACHO-ALLOWLIST/1\n`; entries sort by raw UTF-8
relative path and use exactly:

```text
M <pathByteCount> <relativePath> <lowercaseUUIDHex32> <normalizedUnsignedSHA64> <normalizedLoadsSHA64>\n
```

The main entry remains UUID `41CADB30-CCEF-3B6C-8A1D-237CE5D64C42`,
normalized unsigned SHA-256
`cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3`,
and normalized load-command SHA-256
`664266000f81b937260522d25eda5d81bff3f5d460e5e14512f471c8eaec9afb`.
Its exact reviewed semantic entitlements are also required after console-home
substitution.

Mach-O normalization zeroes only `LC_CODE_SIGNATURE.dataoff/datasize` and the
signature-size-dependent `__LINKEDIT` `vmsize/filesize`, then omits the exact
original signature blob. It retains `__LINKEDIT.fileoff` and every other byte.

The normalized entitlement SHA-256 is
`5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4`.
Canonicalization is UTF-8 and begins `PCVR-ENTITLEMENTS/1\n`. The exact console
home in the three path-bearing SBPL strings becomes `@CONSOLE_HOME@`.
Dictionary keys sort by raw UTF-8; true booleans use
`B <keyByteCount> <key>\n`; the ordered array uses
`A <keyByteCount> <key> <count>\n`, followed by
`S <valueByteCount> <value>\n` per element. There is no whitespace or trailing
material beyond those record newlines. The controller additionally compares
the decoded Security.framework entitlement dictionary semantically.

Every directory from the resolved console home through the imported app, and
every directory inside that app, must be a real (non-symlink) directory owned
by the console UID, without group/other write access, extended ACL entries, or
immutable/append flags. Every reviewed Mach-O must be a single-link regular
file with the same protections and stable descriptor metadata.

After process discovery, the controller enumerates the target's executable VM
regions using `PROC_PIDREGIONPATHINFO`. Every path-bearing image must be either
an exact allowlist path whose mapped vnode identity matches preflight, or a
root-owned, non-writable image under a fixed Apple system prefix. Pathless
file-backed executable mappings are rejected; anonymous `dev=ino=0` mappings
remain permitted for Unity JIT. The mapped main, UnityFramework, and Appdome
`libloader` are mandatory before the first policy write, immediately after
readback, and on every one-second safety pass. Any enumeration uncertainty,
disk metadata change, or unreviewed image publishes `FAILED runtime_images`
and triggers the existing exact-task fail-closed path.

The first launch-time check allows at most two seconds for the required
UnityFramework and `libloader` mappings to appear after the exact main process
is discovered. Only a missing required core image is retried in that window;
unreviewed paths, vnode mismatches, and enumeration errors fail immediately.

## Fail-closed safety

- macOS build `25G70`, XNU `xnu-12377.161.13~4`, and reviewed identities are
  mandatory.
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
