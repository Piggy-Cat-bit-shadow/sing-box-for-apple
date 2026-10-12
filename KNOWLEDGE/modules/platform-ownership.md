# Platform ownership

## The whole decision is five lines

```swift
// SFI/Application.swift
static func resolve(idiom: UIUserInterfaceIdiom) -> SFIUIFamily {
    switch idiom {
    case .phone:  return .hakoPhone
    default:      return .upstreamPad
    }
}

@MainActor
static var current: SFIUIFamily { resolve(idiom: UIDevice.current.userInterfaceIdiom) }
```

and the only routing site in the process:

```swift
Group {
    switch SFIUIFamily.current {
    case .hakoPhone:   HakoPhoneRootView()
    case .upstreamPad: MainView()
    }
}
```

The environment wiring hangs off the `Group` above both arms, so the model objects, the command
client and the subscription are created **once** and shared — presentation differs, state does
not.

| Candidate input | Verdict |
|---|---|
| **device idiom** | **CONFIRMED — the sole discriminator** |
| horizontal size class | REFUTED as a routing input. It appears once, *inside* upstream's presentation: `SidebarLayout.isEnabled(_:)` requires `idiom == .pad && sizeClass == .regular`. The file header states the intent: an iPad in Split View, Slide Over, Stage Manager or a narrow window is **still an iPad** |
| `#if os(...)` | REFUTED as a routing input. OS conditionals gate *compilation* of Hako symbols, not selection. There is no `#if` around the routing switch |
| `UIDevice` | CONFIRMED and required: `UIDevice.current.userInterfaceIdiom` is the value |

The single-positive-arm design is deliberate and documented in the source. The header names each
negative case and why it is not spelled out: `.pad` is the product requirement, `.unspecified`
is the conservative answer (guessing "phone" in an extension/preview/test context would hand the
Hako shell to something not known to be a phone), `.mac` (Catalyst) is not a shipping
configuration, `.tv` is unreachable because tvOS has its own scene, and `.carPlay` does not
ship. Naming every SDK case would be a compile error on platforms where the case does not exist,
and an `@unknown default`-only switch over an imported enum is not exhaustive.

The design rationale, in the file's own words: "a rule with one arm that grants the fork's
presentation is also the rule a static audit can check."

## Product boundaries

| Platform | Presentation | Provenance |
|---|---|---|
| iPhone | fork-owned Hako | fork |
| iPad | official/upstream UI, deliberately preserved | upstream |
| macOS | official/upstream UI, deliberately preserved | upstream |
| tvOS | **UI out of scope** | upstream |

`tvOS` needs care: its *UI ownership* is out of scope for this fork, but tvOS is still
**built and shipped** — `Makefile` `build_all` includes `build_tvos`, and `SFT`,
`TVExtension`, `SFTUITests` are live targets. `ApplicationLibrary` is compiled for
`appletvos appletvsimulator iphoneos iphonesimulator macosx`, so all 54 Hako files must
*compile* on tvOS even though nothing routes to them. That is precisely why the
platform-guard gates exist. "tvOS is out of scope" is a statement about product UI, not
about the build.

## Where each root leads

```text
SFI/Application.swift
  |-- .hakoPhone   -> SFI/HakoPhoneRootView.swift -> HakoPrimaryShell -> SFI/HakoPageContent.swift
  |                    -> ApplicationLibrary/Views/HakoStyle/*        (54 files)
  `-- .upstreamPad -> SFI/MainView.swift -> upstream views

SFM/Application.swift  -> MacLibrary/MacApplication.swift -> MacLibrary/MainView.swift
SFT/Application.swift  -> its own scene, no Hako
```

iPad, macOS and tvOS each reach *an* upstream `MainView`, but they are three different
types in three targets. `SFI/MainView.swift` contains zero `Hako` tokens.

## AI cautions

- **Do not** make a shared view inspect `UIDevice` or size class to select Hako. The
  rule is one arm at the root; anything else is a second, conflicting ownership rule.
- **Do not** replace upstream files with copies. The audit's
  `upstream-files-untouched` check reports **434 of 458** upstream files byte-identical to
  the pinned upstream, with the **24** modified ones on a reviewed list. That number is the
  preservation contract. (It was 447/11 at the previous baseline; the fork deliberately took
  on more upstream-file changes, each individually reviewed and printed with a reason.)
- `SFI/ProfileEditorWrapperView.swift` is shared by both roots and defaults
  (`restyled: false`) to the upstream toolbar. Only the phone passes `restyled: true`.
  An unconditional Hako toolbar there would put the phone's design on an iPad.
- The one place a shared file may not carry a Hako symbol is enforced by a gate, not by
  the compiler: `HakoEnvironmentValues.swift` moved a member out of the shared
  `EnvironmentValues.swift` because an iPad and a Mac compile that file. Swift would
  happily accept the extension from anywhere. `2f0024c` is the commit where the audit caught
  a shared file naming a phone page — the gate earns its keep.

## Verification

`audit_apple_ui_boundary.py --upstream-ref 089d35e6…` is the gate. Re-run at this refresh
(2026-10-12, tree at `331a676`):

```text
PASS 20   FAIL 0   UNKNOWN 0   UNDECIDABLE 0   exit 0
```

Relevant checks and what they reported:

| Check | Report |
|---|---|
| `phone-entry` | the phone route is selected by the device idiom alone |
| `tablet-and-mac-entry` | the same for the official route |
| `no-reverse-dependency` | all **319** Swift files outside the Hako namespace and the phone root are free of Hako symbols, with 54 files in the namespace to be divided from |
| `reverse-routing-contract` | **25** constructions across **6** user paths resolve to the fork's own view |
| `ipad-mac-ui-gate` | no Hako symbol is reachable from the iPad or the Mac |
| `hako-page-coverage` | all 6 first-level pages route to a Hako view |
| `hako-feature-preservation` | 11 reached types and 11 wiring paths verified on the phone's own files |
| `hako-type-has-caller` | all 70 live Hako types are named beyond their own declaration; 3 orphans are inherited from the frozen original (which names each exactly once too) |
| `upstream-files-untouched` | 434 of 458 byte-identical; 24 modified, all reviewed |
| `project-membership` | every source file is in the target it belongs to |

This is `VERIFIED_STATIC`. It is **not** compilation, rendering, or device proof. Run it
with `--strict` **and** `--upstream-ref` before quoting a pass — without `--upstream-ref` the
upstream comparison reports `UNKNOWN` and the run still exits 0.
