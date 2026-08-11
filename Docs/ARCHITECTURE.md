# Architecture

## Trust boundaries

The product has three separately reviewable components:

1. **Patcher** verifies an official PlayCover and an embedded, prebuilt payload,
   imports one exact VRChat bundle, and publishes a separate app. It never edits
   the official app or VRChat.
2. **PlayCover VRChat** owns settings and launch ordering. It cannot set a memory
   policy, cannot receive administrator credentials, and never falls back to a
   standard VRChat launch.
3. **Controller/helper** runs as root only after an explicit authorization. It
   accepts one bounded GiB selection and can affect only the reviewed VRChat
   executable in the independent library.

No component downloads executable, identity, or policy input at runtime.

## Parallel-install transaction

```text
exact /Applications/PlayCover.app
              │ read-only identity + version verification
              ▼
 exact source-library VRChat
              │ composite Mach-O/entitlement/framework verification
              ▼
 hidden same-volume app + import staging
              │ clone/copy; forbid hard links; verify full source=destination
              ▼
 exact prebuilt PlayCover VRChat payload
              │ bundle ID/signature/notarization/manifest/tree verification
              ▼
 atomic create /Applications/PlayCover VRChat.app
              │
              └── original app and library remain byte-for-byte unchanged
```

An existing exact customized app is repairable. A same-name object with unknown
identity is inspect-only and is never overwritten. In the current Alpha no
helper is registered: Remove deletes only the exact customized app and preserves
both the official library and the independent imported library. The separately
installed experimental root runner/controller must be removed through its
reviewed `--uninstall` flow. A future formal Remove may unregister the helper
only after the signed, notarized maintenance protocol passes its release gate.

## VRChat identity

The signed main executable SHA is not portable across PlayCover's per-machine
ad-hoc signatures. The import and root controller therefore share one stable,
fail-closed identity:

- thin arm64 main UUID;
- normalized unsigned Mach-O SHA-256;
- normalized header/load-command SHA-256;
- canonical semantic-entitlements SHA-256 with only the console-home prefix
  replaced by `@CONSOLE_HOME@`;
- a canonical 46-entry `PCVR-MACHO-ALLOWLIST/1` covering every thin-arm64
  Mach-O in the reviewed bundle, including UnityFramework and Appdome
  `libloader`;
- exact bundle ID and version/build.

Normalization zeroes `LC_CODE_SIGNATURE` dataoff/datasize and `__LINKEDIT`
vmsize/filesize, then omits the original signature blob. It does not ignore any
executable code, load dependency, entitlement, Unity, or Appdome difference.
The root controller also binds the target's actual executable VM mappings to
the reviewed paths and vnode metadata before policy activation and while the
lease is maintained; extra, missing, moved, or swapped file-backed code fails
closed.

## Memory selection

```text
safeMaximumGiB = floor(physicalMemoryBytes × 75 / 100 / 1 GiB)
automatic      = safeMaximumGiB
custom         = integer GiB in 4...safeMaximumGiB
```

The setting is snapshotted at session start. Root independently recomputes the
ceiling and rejects invalid, fractional, stale, or out-of-range values; it never
clamps. A ceiling below 4 GiB is unsupported, while a selected limit below
8 GiB produces a warning only.

## Launch transaction

```text
PlayCover VRChat read-only preflight
  → snapshot and validate memory mode
  → macOS authorization launches fixed root-owned runner with one GiB argument
  → authenticate PCVR/2 root socket and receive WAITING
  → LaunchServices starts imported VRChat by exact absolute URL
  → TARGET_BOUND
  → LEASE_ACTIVE with matching snapshotted limit
  → MAINTAINING metrics
  → exact task exits
  → COMPLETED and transient policy disappears
```

Before `TARGET_BOUND`, the client may send one `CANCEL`. After bind, identity,
maintenance, guardian, or critical-pressure failure terminates only the exact
task. Authorization cancellation, helper failure, and protocol mismatch all
abort before LaunchServices; no standard-launch fallback exists.

## PCVR/2 wire protocol

The root-owned Unix socket uses newline-delimited ASCII and protocol prefix
`PCVR/2`. Server messages are:

```text
PCVR/2 HELLO <controller-build-id>
PCVR/2 WAITING <limit-mib> <safe-max-mib>
PCVR/2 TARGET_BOUND <pid>
PCVR/2 LEASE_ACTIVE <pid> <limit-mib>
PCVR/2 METRICS <pid> <limit-mib> <footprint-mib> <headroom-mib> <reapplies> <pressure>
PCVR/2 COMPLETED
PCVR/2 FAILED <stable-error-code>
PCVR/2 REJECTED <stable-rejection-code>
```

The only client message is `PCVR/2 CANCEL`, accepted before bind. Unknown
commands, fields, versions, oversized lines, non-root peers, and late
cancellation are rejected without granting policy authority.

## Authorization backends

The Developer Alpha uses a fixed Authorization Services request and the
reviewed root-owned runner. It does not open Terminal, construct a shell line,
or read/store a password.

The public backend is an on-demand `SMAppService` LaunchDaemon with a restricted
XPC interface. It has neither `RunAtLoad` nor `KeepAlive` and is unavailable
until the customized app and helper share a Developer ID signature, are
notarized, and pass the signing-requirement gates. There is no automatic
fallback from the formal backend to the Alpha backend.
