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

| Candidate input | Verdict |
|---|---|
| **device idiom** | **CONFIRMED — the sole discriminator** |
| horizontal size class | REFUTED as a routing input. It appears once, *inside* upstream's presentation: `SidebarLayout.isEnabled(_:)` requires `idiom == .pad && sizeClass == .regular`. The file header states the intent: an iPad in Split View, Slide Over, Stage Manager or a narrow window is **still an iPad** |
| `#if os(...)` | REFUTED as a routing input. OS conditionals gate *compilation* of Hako symbols, not selection. There is no `#if` around the routing switch |
| `UIDevice` | CONFIRMED and required: `UIDevice.current.userInterfaceIdiom` is the value |

The `@unknown default`-style single-arm design is deliberate and documented: "a rule
with one arm that grants the fork's presentation is also the rule a static audit can
check."

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
  `upstream-files-untouched` check reports 447 of 458 upstream files byte-identical to
  the pinned upstream, with the 11 modified ones on a reviewed list. That number is the
  preservation contract.
- `SFI/ProfileEditorWrapperView.swift` is shared by both roots and defaults
  (`restyled: false`) to the upstream toolbar. Only the phone passes `restyled: true`.
  An unconditional Hako toolbar there would put the phone's design on an iPad.
- The one place a shared file may not carry a Hako symbol is enforced by a gate, not by
  the compiler: `HakoEnvironmentValues.swift` moved a member out of the shared
  `EnvironmentValues.swift` because an iPad and a Mac compile that file. Swift would
  happily accept the extension from anywhere.

## Verification

`audit_apple_ui_boundary.py --upstream-ref 089d35e6…` is the gate. Run at this review:

```text
PASS 19   FAIL 0   UNKNOWN 0   UNDECIDABLE 0   exit 0
```

Relevant checks it enforces: `phone-entry` (idiom alone), `tablet-and-mac-entry`,
`ipad-mac-ui-gate`, `no-reverse-dependency` (317 Swift files outside the namespace are
free of Hako symbols), `upstream-files-untouched`, `project-membership`.

This is `VERIFIED_STATIC`. It is **not** compilation, rendering, or device proof. Run it
with `--strict` before quoting a pass, from the selected product worktree.
