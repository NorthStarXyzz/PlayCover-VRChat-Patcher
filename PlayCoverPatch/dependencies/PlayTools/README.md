# PlayTools Xcode 26 compatibility patch

The reviewed dependency remains pinned to PlayTools commit
`f17b9211211fb4cf5652d4930ea82613ee3c92a5` (v3.1.0). The single patch replaces
three mutations of optional `activity.buttons` with an equivalent one-button
assignment. No other PlayTools source is changed. `overlay/Package.resolved`
also fixes the exact SwiftPM graph used by Xcode 26, so PlayTools' upstream
`SwordRPC` branch requirement is never resolved from the live `main` branch at
build time.

Reviewed SwiftPM pins:

- SwordRPC: `4403152a16a040d8448d33d65ad5a034c9d1fa1b`
- swift-atomics 1.3.1: `0442cb5a3f98ab802acb777929fdb446bda11a34`
- swift-collections 1.6.0: `a0cb0954ecb21e4e31b0070e6ed5674e8556685a`
- swift-nio 2.101.3: `0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b`
- swift-system 1.8.0: `704705c5c51156ede21172a38654d522ce487074`

Carthage 0.40 exports `Carthage/Checkouts/PlayTools` without `.git`, so
`check.sh` authenticates the complete exported tree: every relative path,
regular-file SHA-256, and file/directory mode is covered by the reviewed
preimage, Discord-only intermediate, or final locked postimage digest. The
final tree contains only the one source edit and the reviewed resolution.
Symlinks, special files, additions, deletions, different locks, and unknown
changes fail closed.

From this repository, build the dependency with one command:

```zsh
/bin/zsh /absolute/path/to/PlayCover-VRChat-Patcher/PlayCoverPatch/dependencies/PlayTools/bootstrap-and-build.sh \
  /absolute/path/to/patched/PlayCover \
  /opt/homebrew/bin/carthage
```

The wrapper performs `bootstrap --no-build --no-use-binaries`, applies the
exact source patch, atomically installs the resolution, verifies the complete
final tree, then runs `FASTLANE=1 carthage build --use-xcframeworks PlayTools`.
Cached builds are intentionally disabled so an artifact produced from another
SwiftPM resolution cannot be reused.
`FASTLANE=1` only suppresses PlayTools' SwiftLint build phase; it does not alter
the compiled product. Do not use a one-shot `carthage bootstrap` build because
the unpatched f17b921 source does not compile with Xcode 26.

Full positive/fail-closed integration tests can be run against a pristine
Carthage export:

```zsh
/bin/zsh test.sh /absolute/path/to/Carthage/Checkouts/PlayTools
```
