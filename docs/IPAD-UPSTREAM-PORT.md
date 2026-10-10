# iPad / macOS presentation ownership

**Repository:** `Piggy-Cat-bit-shadow/sing-box-for-apple`
**Branch:** `ipad-upstream-ui`
**Freeze baseline:** `iphone-hako-ui-freeze-v1` → `fc7f77b82a7ca432294addfa001fcacfd5776223`
**Date:** 2026-10-08

## The rule

> **We override iPhone presentation only. Upstream owns iPad and macOS presentation.**

| Surface | Design authority | Owner |
| --- | --- | --- |
| iPhone presentation | The validated Hako UI | **Hako** |
| iPad presentation | Current SagerNet upstream | **Upstream** |
| macOS presentation | Current SagerNet upstream | **Upstream** |
| Product display name | `Jiejiebox` | **Fork (branding)** — see `HAKO-OWNERSHIP.md` §11b |
| Shared application/core state | One set of objects for all families | Shared |

Conflict order:

```
iPhone presentation       -> Hako wins
iPad / macOS presentation -> upstream wins
product branding          -> Jiejiebox wins (all three)
shared business logic     -> prefer upstream/shared; never copy without reason
```

## What is forbidden

Forking a copy of upstream presentation in order to have an "iPad version":

```
IPadMainView            ✗  a re-implementation of upstream's root
IPadNavigationPage      ✗  a second navigation enum
IPadSidebarView         ✗  a copy of upstream's SidebarView
IPadSidebarLayout       ✗  a copy of upstream's SidebarLayout
IPadUpstream/           ✗  a maintained mirror of upstream presentation
```

> **Correction, 2026-10-08.** An earlier revision of this branch *did* build exactly those files
> (`SFI/IPadMainView.swift`, `ApplicationLibrary/Views/IPadUpstream/{IPadNavigationPage,
> IPadSidebarView,SidebarLayout}.swift`, `SFIUITests/IPadNavigationUITests.swift`, plus a routing
> switch in `SFI/Application.swift`). That direction was cancelled and **all of it was removed**.
> Nothing from it was committed. The rest of this document describes the corrected approach.

---

## 1. Upstream reference

| Item | Value |
| --- | --- |
| Upstream repo | `https://github.com/SagerNet/sing-box-for-apple` |
| Upstream branch | `dev` |
| Upstream SHA audited | `3cc0835f2a44d9fc5ecc6140c149d374f915d43c` |
| First iPad architecture commit | `3131ed68564394b7c91fb08818134a4b9740ba1e` — "Adapt layout for iPad" |
| iPad architecture follow-ups | `8d01771` (remote-control picker when the sidebar is hidden); `a1e78ca` (terminal) |

The iPad architecture was not revised after `3131ed6`. Verified:

```bash
git log --oneline 3131ed6..upstream/dev -- \
  ApplicationLibrary/Views/SidebarView.swift \
  ApplicationLibrary/Views/Abstract/SidebarLayout.swift \
  SFI/MainView.swift ApplicationLibrary/Views/NavigationPage.swift
# -> 0c49b8f, 8d01771 — neither is an architecture change
```

## 2. Upstream architecture (what iPad should be running)

Upstream reaches iPad from a **single** `SFI/MainView.swift` that also serves the phone:

```
SFI/MainView.swift  (rootContent)
├── iOS 18+ & SidebarLayout.isEnabled  -> TabView(.sidebarAdaptable) + TabBarPlacementReader
├── iOS 16+ & SidebarLayout.isEnabled  -> NavigationSplitView { SidebarView } detail: { page }
└── otherwise                          -> TabView over NavigationPage.tabPages   (phone)
```

`SidebarLayout.isEnabled` consults idiom **and** size class:

```swift
UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
```

`3131ed6` also **moved** `SidebarView` from `MacLibrary/` into `ApplicationLibrary/` so the Mac app
and the iPad shell share one sidebar.

> **Important for this branch:** `SFI/Application.swift` in upstream is the root that reaches this
> architecture. It differs from Hako's by a single `await`. So `SFI/Application.swift` is the seam
> where a device-family decision can live *above* `MainView`, which is exactly what §4 describes.

---

## 3. Why "just use upstream's iPad code" is not a mechanical change

This is the crux, and it is the reason no presentation was restored in this pass.

Upstream's iPad presentation is reached **through** `SFI/MainView.swift` and depends on
`NavigationPage` having `groups` and `connections` **on iOS**:

| Upstream file | Depends on | Hako's state | Consequence |
| --- | --- | --- | --- |
| `SFI/MainView.swift` | `NavigationPage.tabPages`, `.sidebarDefaultPages`, `.groups`, `.connections`, `.visible(_:)` | Hako replaced this file entirely with the Hako shell | Cannot be used as-is |
| `ApplicationLibrary/Views/SidebarView.swift` | `NavigationPage.groups` / `.connections` on iOS | **Absent from the branch** (added upstream in `3131ed6`) | Cannot be used as-is |
| `ApplicationLibrary/Views/NavigationPage.swift` | — | Hako declares `groups`/`connections` **`#if os(macOS)` only**, and renames `dashboard`→"Home", `settings`→"More" | Upstream depends on iOS cases Hako removed |
| `ApplicationLibrary/Views/Abstract/SidebarLayout.swift` | — | **Absent** | Must come from upstream |

So there are two candidate ways to give iPad upstream's presentation, and **neither is a simple
file copy**:

1. **Put back upstream's versions** of `SFI/MainView.swift`, `SidebarView.swift`,
   `SidebarLayout.swift`, `NavigationPage.swift`. But Hako's iPhone shell needs the *Hako* root
   (`HakoPrimaryShell`) and the Hako `NavigationPage` semantics, so the phone path must be
   preserved separately — i.e. the phone root has to be relocated, not the upstream root.
2. **Keep upstream's root file untouched and dispatch around it** — which requires the phone's
   shell to stop depending on the modified shared files.

Both are real refactors of the boundary. Neither was attempted, because doing it blind would risk
the frozen iPhone UI, which is the highest-priority constraint.

### 3.1 What has been established, and helps

A prerequisite for option 1 has been checked, and it is favourable:

* The iPhone **tab bar** renders `HakoPrimaryTab.title` ("Home"/"Tools"/"More"), which is Hako's
  own type — it does **not** read `NavigationPage.title`.
* `NavigationPage.subtitle` (a Hako addition) has **no reader**.
* `NavigationPage.title` has exactly **two** readers: `SFI/MainView.swift:101` and
  `MacLibrary/MainView.swift:82`.

So the Hako `NavigationPage` renames surface in only one iPhone navigation title. Restoring
upstream's `NavigationPage` is therefore *closer to feasible than it looks* — but it still changes
that one iPhone title, which is a user-visible change and therefore out of bounds without an
explicit decision.

---

## 4. The integration boundary to build

```
                       Shared application/core state
                        (ExtensionEnvironments, CommandClient,
                         ExtensionProfile, profiles, reports)
                                     |
                    +----------------+----------------+
                    |                                 |
                  iOS                              macOS
                    |                                 |
           device-family router               upstream macOS path
            /                \                         |
        iPhone              iPad                 upstream SFM UI
          |                   |
      Hako UI          upstream iOS/iPad UI
   HakoPrimaryShell   NavigationSplitView / sidebarAdaptable
                      + SidebarView (+ SidebarLayout)
```

The router belongs **above** both roots — in `SFI/Application.swift`, whose `WindowGroup` currently
calls `MainView()`:

```swift
Group {
    switch SFIUIFamily.current {          // UIDevice.current.userInterfaceIdiom
    case .hakoPhone:   HakoPhoneRoot()    // today's validated Hako path, unchanged
    case .upstreamPad: UpstreamRoot()     // upstream's SFI root, unmodified
    }
}
```

Two rules for that router:

1. **Device family is the idiom, never the size class.** An iPad in Split View, Slide Over, Stage
   Manager or a narrow window stays `upstreamPad`; it must never fall into the Hako shell. Size
   class is used *inside* the iPad family (by `SidebarLayout`) to choose split view vs compact.
2. **`Shared application/core state` is not forked.** One `ExtensionEnvironments`, one
   `CommandClient`, one profile store — injected once in `Application.swift`, consumed by both
   roots.

### 4.1 What `UpstreamRoot` must be

It must be **upstream's `SFI/MainView.swift`**, not a port of it. Which means, before it can exist:

* `NavigationPage` must regain `groups`/`connections` on iOS and upstream's titles — the shared
  enum, restored; and
* the iPhone path must stop needing the Hako variants of those, which means the iPhone shell has
  to derive its titles from `HakoPrimaryTab` alone (it already does for the tab bar), and
  `SFI/MainView.swift:101`'s `.navigationTitle(page.title)` must come from the Hako side.

That is the shape of the remaining work. It is a boundary refactor, and it is why this document
records the map rather than a finished port.

---

## 5. Conflict map

| Upstream item | Hako state | Conflict | Correct move |
| --- | --- | --- | --- |
| `SFI/Application.swift` | differs by one `await` | Low | The seam. Add the family router here. |
| `SFI/MainView.swift` | **replaced** by `HakoPrimaryShell` | **High** | Move the Hako root aside as the phone root; restore upstream's as the iPad root. |
| `ApplicationLibrary/Views/SidebarView.swift` | absent | — | Restore from upstream; used by Mac + iPad. |
| `ApplicationLibrary/Views/Abstract/SidebarLayout.swift` | absent | — | Restore from upstream. |
| `ApplicationLibrary/Views/NavigationPage.swift` | iOS cases removed; titles renamed | **High** | Restore upstream; move Hako naming into the Hako shell. |
| `ApplicationLibrary/Views/EnvironmentValues.swift` | `hakoCompactRows` added | Medium | Keep the key (additive); ensure upstream keys are untouched. |
| `Dashboard/*`, `Groups/*`, `Connections/*`, `Log/*`, `Tools/*`, `Setting/*` | modified by Hako | **High** | These are the iPhone presentation. iPad/macOS should consume upstream versions. |
| `MacLibrary/*` | `MainView.swift` + `SidebarView.swift` modified | **High** | macOS must go back to upstream presentation. |
| `sing-box.xcodeproj/project.pbxproj` | iOS 16 target (Hako) + display name (branding) | Low | Upstream owns the target; branding owns 4 display-name lines. |
| `Localizable.xcstrings` | +202 keys | Medium | Strings are shared; renames must not leak into iPad/macOS wording. |

**Not to be touched for this:** `ApplicationLibrary/Views/HakoStyle/` stays a high-protection zone.

---

## 6. Deliberately not done in this pass

* No presentation file was restored or moved. The prerequisite refactor (§4.1) has not been done,
  and attempting it without a way to prove the iPhone UI is unchanged would risk the one thing that
  must not change.
* No upstream merge, rebase or cherry-pick. `3131ed6` is not additive — it also edits
  `NavigationPage`, `DashboardView`, `StartStopButton`, `FormItem`, `SettingView`, `ReportShared`
  and `SFI/MainView`, all of which Hako has touched.
* macOS was not restructured. `SFM` cannot be built in this environment at all — see §7.

## 7. Environment blocker for macOS

`SFM` **cannot be built on this host**:

```
Libbox.xcframework:1:1: error: While building for macOS, no library for this platform was found
```

`Libbox.xcframework` contains only `ios-arm64` and `ios-arm64_x86_64-simulator`. There is no macOS
slice, so no macOS verification — and therefore no safe macOS presentation change — is possible
here. This is a pre-existing environment limitation, not a consequence of any change on this branch.
