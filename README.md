# PlayCover VRChat Patcher

<p align="center">
  <img src="Design/Logo/pcvrpatcher-app-icon-v10.png" alt="PlayCover VRChat Patcher logo" width="140" />
</p>

<p align="center">
  <strong>Play VRChat normally on Mac with PlayCover</strong>
</p>

<p align="center">
  A free, open-source compatibility patcher for supported PlayCover and VRChat
  versions. The official PlayCover installation stays untouched.
</p>

<p align="center">
  <a href="./README_CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="macOS">
  <img src="https://img.shields.io/badge/status-alpha-yellow" alt="Alpha">
  <img src="https://img.shields.io/badge/license-GPL--3.0--only-green" alt="GPL-3.0-only">
</p>

---

## What it does

- Keeps `/Applications/PlayCover.app` unchanged.
- Creates `/Applications/PlayCover VRChat.app` with its own library.
- Imports and verifies the supported VRChat installation.
- Starts VRChat with a transient memory soft limit.
- Lets you use automatic 75% memory or choose a custom whole-GiB limit.

The UI flow is inspired by [CXPatcher](https://github.com/italomandara/CXPatcher).
The patch engine, verification, and controller are original to this project.

## How it works

1. The patcher copies the official PlayCover into a separate app and library.
2. It imports a verified VRChat bundle without changing VRChat or injecting a dylib.
3. When VRChat starts, the patched PlayCover asks the authorized controller to wait
   for that exact VRChat process.
4. The controller applies a non-fatal memory soft limit and repairs known
   RunningBoard resets while the game is running.
5. When the exact process exits, the temporary policy is removed automatically.

PlayTools is kept out of the VRChat launch path because its injection can make the
game's integrity check fail. Removing that conflict lets the check pass normally.
The memory policy changes the system's reported limit; it does not pre-allocate RAM.

On the reviewed VRChat build, the T5/T6 comparison showed that a non-zero memory
result was necessary for the observed remote avatar and model AssetBundle loading.
This is a compatibility observation for the locked build, not a promise for every
future VRChat version.

## How the installed controller works

The `.pkg` installs a root-owned runner and a small fixed-purpose controller. It is
not a daemon and does not patch the kernel. When requested, the controller uses
macOS's XNU `memorystatus_control` interface to apply a temporary memory limit to
the exact VRChat process. It uses
`MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES`, then reads the policy back.

It calculates the safe maximum from `hw.memsize`, verifies the supported VRChat
bundle and macOS build, waits for the process, reads the policy back, and repairs
known RunningBoard resets. When VRChat exits, the policy is removed. Any identity,
pressure, or policy mismatch stops safely instead of touching another process.

The reported headroom is dynamic: selected limit minus current footprint. The
controller does not fake a memory API result, hook Unity, or modify Appdome or
`libloader`; it applies the real XNU policy outside the game.

## Quick start

### Current supported environment

- Apple silicon Mac
- macOS 26.6 / build `25G70`
- PlayCover `3.1.0 (856)`
- VRChat `2026.2.30300 (1365)`

These are the versions currently covered by the reviewed manifest. Other versions
are rejected safely until a matching compatibility entry is reviewed.

### First launch

1. In the original PlayCover, open VRChat settings and choose:

```text
Settings → Misc → Remove PlayTools
```

PlayTools can make the integrity check fail. Removing it removes the conflicting
injection, so the integrity check can pass normally. VRChat may then report `0 MB`
of available memory. On the reviewed build, that zero-memory state prevented the
remote avatar/model loading path observed in T5; the non-zero policy used by T6
allowed it to proceed.

2. Open **PlayCover VRChat Patcher**.
3. Drag the official `PlayCover.app` into the window, or choose it manually.
4. Click **Create Patched Copy** and approve the macOS installer when asked.
5. Open **PlayCover VRChat** from `/Applications`, then launch VRChat normally.

The patched app keeps PlayTools disabled for VRChat and applies the memory policy
before launch. The first setup may ask for administrator authorization; the tool
does not read or store your password.

## Real-device test

<p align="center">
  <img src="Docs/Images/vrchat-world-session.png" alt="VRChat in-world session on macOS" width="49%" />
  <img src="Docs/Images/vrchat-worlds-loaded.png" alt="VRChat remote worlds loaded on macOS" width="49%" />
</p>

## Memory settings

In **PlayCover VRChat**, open VRChat's settings and choose **VRChat Memory**.

- **Automatic** uses 75% of physical memory, rounded down to whole GiB.
- **Custom** accepts 4 GiB through that safe maximum in 1 GiB steps.
- The value is a non-fatal soft limit, not pre-allocated memory.
- Changes apply to the next launch.

## Files and data

| Item | Location |
| --- | --- |
| Official PlayCover | `/Applications/PlayCover.app` |
| Patched PlayCover | `/Applications/PlayCover VRChat.app` |
| Patched library | `~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat` |
| Shared VRChat user data | `~/Library/Containers/com.vrchat.mobile` |

The original app and its library are not removed by Patch, Repair, or Remove.

## Limitations

- This is a version-locked developer Alpha, not a general PlayCover release.
- Unsupported PlayCover, VRChat, macOS, or architecture combinations stop safely.
- Do not use unreviewed CI artifacts or modified payloads.
- A public signed and notarized release is not available yet.

## Build from source

```zsh
swift test -c release
/bin/zsh PlayCoverPatch/run-tests.sh
swift build -c release --product PlayCoverVRChatPatcher
```

To build a source-only inspection app:

```zsh
/bin/zsh Scripts/build-patcher-app.sh \
  --output "$PWD/Artifacts/PlayCover VRChat Patcher.app"
```

Payload builds require a separately reviewed PlayCover payload and manifest. See
[Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md) for the complete release workflow.

## Repository layout

```text
Patcher/          SwiftUI patcher app and install transaction
PlayCoverPatch/   Reviewable PlayCover patch series
Controller/       VRChat memory-policy controller and package
Compatibility/    Version and identity manifests
Scripts/          Build and verification scripts
Docs/             Development and release notes
```

## License

This project is licensed under [GPL-3.0-only](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices.
