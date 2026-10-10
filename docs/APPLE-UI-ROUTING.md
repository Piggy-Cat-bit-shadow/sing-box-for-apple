# Apple UI routing — entry graph and root ownership

Facts only. Recorded from the working tree and `upstream/dev`.

## Baselines

| Ref | SHA |
| --- | --- |
| `upstream/dev` (SagerNet) | `3cc0835f2a44d9fc5ecc6140c149d374f915d43c` |
| `ipad-upstream-ui` (at time of writing) | `fb18443eb3db683315f82853d83784f43ec37fa2` |
| `iphone-hako-ui-freeze-v1` | `fc7f77b82a7ca432294addfa001fcacfd5776223` |
| `hako-ui` | `24bd463a9ec581314f692459ca75efb638f0c524` |
| `hako-ui` ↔ `upstream/dev` merge-base | `2b1763a80f2c1dee1ab3ac62d84dbda7dc5178f4` |

## iOS entry graph (SFI)

```
SFI/Application.swift            @main struct Application: App
└── body: some Scene
    └── WindowGroup
        └── Group
            └── switch SFIUIFamily.current          <-- the family router
                ├── .hakoPhone   -> HakoPhoneRootView()
                └── .upstreamPad -> MainView()
            .tailscaleStatusSubscription(...)
            .environmentObject(environments)         ExtensionEnvironments
            .environmentObject(peerStore)            TailscaleSSHPeerStore
            .environmentObject(tailscaleViewModel)   TailscaleStatusViewModel
            .environmentObject(taildropSendManager)  TaildropSendManager
            .environmentObject(taildropInbox)        TaildropInboxViewModel
```

`SFI/Application.swift` is the **only** place an iOS root view is instantiated, and the only place
the environment objects are injected. That makes it the seam: the family decision lives here and
needs no change inside any root view.

### Current roots — the split is built

| Surface | Root today | File |
| --- | --- | --- |
| iPhone | `HakoPhoneRootView` → `HakoPrimaryShell` | `SFI/HakoPhoneRootView.swift` |
| iPad | upstream's `MainView` | `SFI/MainView.swift` — byte-identical to upstream |

The family is chosen from the device idiom and nothing else:

```swift
static func resolve(idiom: UIUserInterfaceIdiom) -> SFIUIFamily {
    switch idiom {
    case .pad:  return .upstreamPad
    default:    return .hakoPhone
    }
}
```

`resolve` is pure, so the rule can be stated and checked without a device. Every modifier hangs off
the `Group` above the switch, so both families receive identical environment wiring and share one set
of model objects. **Presentation differs; state does not.**

This section previously read "iPad | **the same `MainView`** → `HakoPrimaryShell` … That is the
defect." Kept as the record of what the defect was — one SwiftUI shell serving the whole iOS target,
with iPad getting the phone design. The split above replaced it, and two checks keep the replacement
honest: `scripts/dev/check-iphone-hako-freeze.sh` asserts that `SFI/MainView.swift` is byte-identical
to the pinned upstream blob in the HEAD tree, the index and the working tree, and
`SFI/Application.swift` reads only the idiom, so no size class can move an iPad back into the phone
shell.

### Upstream iOS root

`upstream/dev:SFI/MainView.swift` is a single root that serves phone, iPad and compact iPad by
choosing a presentation from the size class:

```
rootContent
├── iOS 18+ and SidebarLayout.isEnabled(horizontalSizeClass)
│     └── adaptiveTabViewContent  -> TabView(.sidebarAdaptable) + TabBarPlacementReader
├── iOS 16+ and SidebarLayout.isEnabled(horizontalSizeClass)
│     └── splitViewContent        -> NavigationSplitView { SidebarView } detail: { page }
└── otherwise                     -> tabViewContent -> TabView over NavigationPage.tabPages
```

`SidebarLayout.isEnabled`:

```swift
UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
```

Upstream files this root needs, and their state on this branch:

| Path | Upstream blob | On this branch |
| --- | --- | --- |
| `SFI/MainView.swift` | `ae10d3e5` | Hako version `a92992b8` |
| `ApplicationLibrary/Views/SidebarView.swift` | `88aa562f` | **absent** |
| `ApplicationLibrary/Views/Abstract/SidebarLayout.swift` | `dcd7a443` | **absent** |
| `ApplicationLibrary/Views/NavigationPage.swift` | `4bd46bb9` | Hako version `797a1452` |

## macOS entry graph (SFM)

```
SFM/Application.swift            @main struct Application: App
└── body: some Scene
    └── MacApplication(applicationState:)     <-- MacLibrary/MacApplication.swift
        └── MainView                          <-- MacLibrary/MainView.swift
            └── NavigationSplitView
                ├── SidebarView(selection:)
                └── NavigationStack { selection.contentView }
```

| Surface | Root today | Upstream root | Deviation |
| --- | --- | --- | --- |
| macOS | `MacApplication` → `MacLibrary/MainView` | same structure | `MacLibrary/MainView.swift` modified by Hako (design tokens for column widths/window size, `HakoRegularDetailContainer`, `HakoUITrace` calls) |

macOS is **not** running a Hako shell — it is upstream's `NavigationSplitView` structure with Hako
styling and tracing layered in. `MacApplication` itself is upstream-owned.

## Strings that move if `NavigationPage` is restored to upstream

`NavigationPage.title` has exactly three readers:

| Reader | Reader's surface | Frozen? |
| --- | --- | --- |
| `SFI/MainView.swift:101` `.navigationTitle(page.title)` | iPhone + iPad | **iPhone is frozen** |
| `MacLibrary/MainView.swift:82` `.navigationTitle(viewModel.selection.title)` | macOS | no |
| `SFT/MainView.swift:34` `Text(verbatim: "\(page.title) ...")` | tvOS | no (out of scope) |

The Hako iPhone tab bar does **not** read it — `HakoPrimaryShell` renders `HakoPrimaryTab.title`,
which is Hako's own type (`HakoPrimaryShell.swift:41-50`) returning "Home" / "Tools" / "More".

So restoring `NavigationPage.title` to upstream's strings changes exactly **one** iPhone string: the
navigation-bar title of the selected root page, `Home` → `Dashboard`. That must be held at `Home`
for the iPhone, which is why a Hako-side title mapping is needed rather than a change to the shell.

## Target conclusion — reached

```
SFI/Application.swift
└── family router                         (device idiom; never size class)
    ├── .hakoPhone -> HakoPhoneRootView   today's Hako presentation, moved not rewritten
    └── .upstreamPad -> MainView          upstream's SFI root, restored byte-identical
```

This is the target as it was written before the work, and it is what the source now does. The one
naming difference is the case label: `.phone`/`.pad` became `.hakoPhone`/`.upstreamPad`, because the
question the router answers is which *presentation* owns the surface, not which hardware it is on —
an iPad is `.upstreamPad` at every width, and that is the whole point of not reading size class here.

macOS keeps `MacApplication` → `MacLibrary/MainView`, with that file's Hako styling reconsidered
separately from the iOS routing.
