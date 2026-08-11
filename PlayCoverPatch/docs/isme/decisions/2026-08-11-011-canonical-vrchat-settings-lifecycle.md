# SKMB-2026-08-11-011: Canonical VRChat Settings Lifecycle

- status: superseded
- decided_by: designer
- approval_source: The designer approved a canonical 34-key VRChat settings shape, disabled PlayChain/injection/bypass/debug settings, retained the Discord entitlement-compatible value, bypassed KeyCover, and required retained-library-safe Remove semantics on 2026-08-11.
- date: 2026-08-11
- commit: pending
- patterns:
  - B_state_persistence
  - C_concurrent_operations
  - E_security_boundary
  - F_fail_semantics
- scope: VRChat App Settings import, decode, GUI write-back, launch, and removal

## Decision

The Patcher publishes exactly the complete 34-key `AppSettingsData` property-list
shape. Twenty display/input fields retain their already-reviewed migrated values.
The remaining fourteen fields are canonical and are never accepted as free-form
input:

| Key | Canonical value |
|---|---|
| `blockSleepSpamming` | `false` |
| `bypass` | `false` |
| `checkMicPermissionSync` | `false` |
| `disableTimeout` | `false` |
| `discordActivity` | `enable=true`; all four text fields empty |
| `ignoreUnityKeyboardInitializationError` | `false` |
| `injectIntrospection` | `false` |
| `iosDeviceModel` | `iPad13,8` |
| `limitMotionUpdateFrequency` | `false` |
| `metalHUD` | `false` |
| `playChain` | `false` |
| `playChainDebugging` | `false` |
| `rootWorkDir` | `true` (Boolean compatibility setting, not a path) |
| `windowFixMethod` | `0` |

`discordActivity.enable` remains true because the exact reviewed VRChat code
signature already contains the corresponding `(allow network* ipc-posix*)`
sandbox rule. It does not authorize PlayTools injection. The customized build
normalizes these values in memory and again at every encode boundary, suppresses
the Metal HUD side effect, disables VRChat settings controls that could rewrite
or re-sign the application, and never unlocks or relocks KeyCover for VRChat.
This prevents the generic KeyCover session restore from persisting
`playChain=true` after exit.

The only forward migration inputs are the exact reviewed legacy 20-key shape and
the exact legacy 34-key shape produced by unpatched PlayCover's Codable defaults.
Both are normalized one way into canonical 34-key output. Legacy 34-key values
such as `playChain=true` are never copied through. Canonical 34-key output is the
only configuration eligible for a new Patch or Repair transaction.

The Patcher classifies a retained legacy, GUI-expanded, or otherwise drifted
independent-library configuration as `.removalOnly`. This state is eligible only
for Remove. Remove neither validates nor modifies the retained library and is
not blocked solely by App Settings drift; it verifies and removes only the
transaction-owned customized application, receipt, controller, and journals.
The retained library is never reused by Patch or Repair. Executable, receipt,
root-controller, and transaction-state checks remain fail-closed.

## Applies To

- `AppSettingsData` VRChat policy normalization and persistence
- VRChat settings UI mutation boundaries
- VRChat KeyCover/PlayChain lifecycle
- Patcher configuration publication, classification, and Remove semantics
- clean patch application and lifecycle regression tests

## Superseded By

SKMB-2026-08-11-012.
