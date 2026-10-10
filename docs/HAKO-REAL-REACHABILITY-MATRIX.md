# Hako real reachability matrix

What a user on an iPhone actually reaches today, page by page, with the construction site named for every
hop and the static evidence that says so.

**This is not the migration matrix.** [`HAKO-UI-MIGRATION-MATRIX.md`](HAKO-UI-MIGRATION-MATRIX.md) answers
"is the page migrated" by reading one switch. This file answers the harder question the previous rounds did
not: **is the ported page actually constructed on the phone's path, and is the thing it constructs the
Hako one?** A file can exist, be reachable, and still be bypassed by a caller that names the upstream type -
which is the defect that shipped and had to be repaired in `e1cefe6`.

Last verified: `22c263c` (branch `jiejiebox/integrated` at the time of writing).

## The two roots, and why only one of them is discussed here

| Target | Root | UI |
|---|---|---|
| `SFI` (iPhone + iPad) | `SFI/HakoPhoneRootView.swift` when the phone idiom is chosen, `SFI/MainView.swift` otherwise | the phone gets Hako, the tablet gets upstream's |
| `SFM` (macOS) | `MacLibrary/MainView.swift` | upstream's, unchanged |

The dispatch is in `SFI/Application.swift` / `MainView.swift` and is guarded by the pad idiom, not by
`#if os(iOS)` - **`#if os(iOS)` includes iPad**, so it can never be used as "iPhone only". Every claim
below is therefore about the `HakoPhoneRootView` path, and `MAINVIEW_IPAD` never enters the Hako UI:

```
MAINVIEW_IPAD = upstream presentation, via SFI/MainView.swift
                -> ProfileEditorWrapperView(restyled:) defaults to `false`
                -> DashboardView, LogView, ToolsView, SettingView, GroupListView, ConnectionListView
                -> asserted by the audit's `ipad-mac-ui-gate`, `tablet-and-mac-entry`, `phone-entry`
```

## How to read the tables

* **Route** - the arm of the factory in `SFI/HakoPageContent.swift`. It is the only place a `NavigationPage`
  becomes a view, and `scripts/dev/audit_apple_ui_boundary.py --only hako-page-coverage` reads it.
* **Classification**
  * `HAKO` - the phone constructs a `Hako…` type from `ApplicationLibrary/Views/HakoStyle/`.
  * `ORIGINAL_SHARED_OK` - the original never customised this page, so using the official view is correct.
    These are **not** findings and must not be reported as ones.
  * `BROKEN` - a real user path that does not work or shows the wrong page. None are open as of the SHA above.
* **Static evidence** - the script and check that fail if this row stops being true, or the `file:line` of
  the construction. `hako-feature-preservation` is the check that requires an opener *and* a consumer for
  each feature, so a row cannot pass on a declaration alone.

---

## First level: the six destinations

| Page | Route | Construction | Classification | Static evidence |
|---|---|---|---|---|
| **Home** | `.dashboard` | `HakoPageContent.swift:68` → `dashboardPage` (`:102-133`) → `HakoHomeView` (`:107`, `:119`) | `HAKO` | `hako-page-coverage`, `hako-feature-preservation` (Home: 3 reaching files) |
| **Proxies** | `.groups` | `HakoPageContent.swift:71` → `HakoGroupListView` | `HAKO` | same; `#if !os(tvOS)` on the arm |
| **Activity** | `.connections` | `HakoPageContent.swift:73` → `HakoConnectionListView` | `HAKO` | same; `#if !os(tvOS)` on the arm |
| **Logs** | `.logs` | `HakoPageContent.swift:76` → `HakoLogView` | `HAKO` | same, plus the connect hook below |
| **Tools** | `.tools` | `HakoPageContent.swift:78` → `HakoToolsView` | `HAKO` | same |
| **More** | `.settings` | `HakoPageContent.swift:80` → `HakoSettingView` | `HAKO` | same |

The shell that owns the tab bar is `HakoPrimaryShell`, constructed once by `SFI/HakoPhoneRootView.swift:91`.
`NavigationPage.hakoPrimary` decides which tab a page belongs to, and its gate is `#if !os(tvOS)` - the same
width as `NavigationPage`'s own declaration of `.groups`/`.connections`. It was `#if os(macOS)` and that left
the iOS switch non-exhaustive; see `bce950c`.

### The lifecycle that makes Home work

Home's Proxies row and outbound-mode card read the command client, so the client has to be connected. The
original opened it from three places (`up-hako@c1935cf
ApplicationLibrary/Views/Dashboard/ActiveDashboardView.swift:105-116`); the phone root now does the same
(`SFI/HakoPhoneRootView.swift`):

| Trigger | Site | Why it matters |
|---|---|---|
| page appears | `:161-175` `.onAppear`, `environments.connect()` at `:169` | a cold launch with a running tunnel has no other trigger |
| app becomes active | `:213-221` `.onChangeCompat(of: scenePhase)`, connect at `:217` | the client's connection does not survive the background |
| tunnel reports connected | `:222-232` `.onReceive(environments.$extensionProfile)`, connect at `:230` | starting the tunnel after launch is when the groups arrive |
| `.logs` selected | `:233-241` `.onChangeCompat(of: selection)`, connect at `:237` | the original's fourth hook - Logs is a stream from the client |

Only the fourth existed before `bce950c`, which is why Home could lose its route to Proxies entirely.

---

## Profile, Add and Edit

| Entry | Chain | Classification | Static evidence |
|---|---|---|---|
| Home → configuration centre row / header action | `HakoHomeView.swift:241` `.sheet(isPresented: $showsConfigurationCentre)` → `HakoProfilePickerSheet` | `HAKO` | `hako-feature-preservation` wiring: `showsConfigurationCentre = true` → `.sheet(isPresented: $showsConfigurationCentre)` |
| configuration centre → Add | `HakoProfilePickerSheet.swift:118` → `HakoNewProfileSheetContent` (`HakoSheetContent.swift:169`) → `HakoNewProfileMenuView` | `HAKO` | the chain is three constructions in the phone's own files |
| Add → manual create | `HakoNewProfileMenuView.swift:104` → `HakoNewProfileView(onSuccess:)` | `HAKO` | the arm names the Hako type |
| Add → remote import | `HakoNewProfileMenuView.swift:55` → `HakoNewProfileView(request)` with `ImportRequest` | `HAKO` | the request types are `HakoNewProfileView`'s own nested types, not renamed |
| Add → local file import | `HakoNewProfileMenuView.swift:61` → `HakoNewProfileView(localImportRequest:)` with `LocalImportRequest` | `HAKO` | same |
| configuration centre → Edit | `HakoProfilePickerSheet.swift:123` and `:188` → `HakoEditProfileView` → `HakoProfileActionToolbar` (`HakoEditProfileView.swift:89`) | `HAKO` | two entry points, one destination |
| configuration centre → QR share | `HakoProfilePickerSheet.swift:438` (and the second presentation at `:799`) → `HakoQRSSheet` (`HakoQRSDisplayView.swift:188`) → `HakoQRSDisplayView(data:filename:)` (`:200`) | `HAKO` | the arm names the Hako type; `QRCodeSheet` stays upstream's (see the shared-pages list below) |
| any phone modal → close | `.hakoModalClose()` from `HakoSheetContent.swift:79-81` | `HAKO` | 5 `NavigationSheet` sites on the phone path, 5 closes |

`HakoNewProfileView.ImportRequest` and `.LocalImportRequest` are the case the generator's rename rules exist
for: they are **nested**, so they keep their original spelling, and `NewProfileViewModel.init`'s signature
(`NewProfileViewModel.swift`) is the golden reference for that. A renamed copy does not type-check.

---

## More: the settings destinations

`HakoSettingView` is a list of `HakoSettingsDestination` values, each carrying the view it pushes
(`HakoSettingView.swift:286-341`):

| Section | Row | Destination | Classification |
|---|---|---|---|
| Connection Behavior | On Demand | `HakoOnDemandRulesView` (`:293`) | `HAKO` |
| Connection Behavior | Tunnel | `HakoPacketTunnelView` (`:301`) | `HAKO` |
| Connection Behavior | Profile Override | `HakoProfileOverrideView` (`:309`) | `HAKO` |
| Core Settings | Core | `HakoCoreView` (`:319`) | `HAKO` |
| App Settings | Client Settings | `HakoAppView` (`:329`) | `HAKO` |
| Integrations | Remote Control | `HakoRemoteControlView` (`:339`) | `HAKO` |

**Terminal appearance is reachable, and it was worth checking twice.** `HakoAppView` is declared in
`HakoStyle/HakoMacAppView.swift` (a port of upstream's `Setting/MacAppView.swift`, whose name is misleading -
line 99 of the original constructs `GhosttyConfigurationView()` and it is not inside the file's macOS-only
region). The chain is:

```
More -> Client Settings -> HakoAppView
  -> HakoMacAppView.swift:86  FormNavigationLink { HakoGhosttyConfigurationView() }
  -> HakoGhosttyConfigurationView.swift:75   HakoFontPickerView
  -> HakoGhosttyConfigurationView.swift:139  HakoThemePickerView
```

`HakoRemoteControlView` was the one modal on this path without a close; `More → Remote Control → "+"` or a
server row opened a sheet with no way out. Fixed in `bce950c`.

`HakoSettingView`'s remaining rows are links out (`Documentation`, `Source Code`) or destructive actions
(`HakoDestructiveRow`), not page pushes.

---

## Tools: reports, network utilities and the terminal

| Entry | Construction | Classification | Static evidence |
|---|---|---|---|
| Tools → Crash Reports | `HakoToolsView.swift:298` → `HakoCrashReportListView` → `:55` `HakoCrashReportDetailView(report:)` | `HAKO` | this is the chain `e1cefe6` repaired; the **construction site and the destination's own `let report:` read** are both checked |
| Tools → OOM Reports | `HakoToolsView.swift:327` → `HakoOOMReportListView` → `:47` `HakoOOMReportDetailView(report:)` | `HAKO` | same |
| Tools → Power Reports | `HakoToolsView.swift:341` → `HakoPowerReportListView` → `:62` `HakoPowerReportDetailView(report:)` | `HAKO` | same |
| Tools → Network Quality | `HakoToolsView.swift:261` → `HakoNetworkQualityView` → `HakoToolOutboundSection` / `HakoOutboundPickerView` chain | `HAKO` | the outbound picker is reached from the network tools, not from Proxies |
| Tools → STUN | `HakoToolsView.swift:273` → `HakoSTUNTestView` | `HAKO` | same section chain |
| Tools → Taildrop | `HakoToolsView.swift:87` → `HakoTaildropView` | `HAKO` | the arm passes the endpoint tag it was opened with |
| Tools → USB/IP | `HakoToolsView.swift:240` → `HakoUSBIPServerView` | `HAKO` | constructed with the selected server |
| Tools → terminal session | `HakoToolsView.swift:106` → `HakoTailscaleSSHPromptView`; `:117` → `HakoTerminalSessionContainerView` (`:29`, inside `#if canImport(GhosttyTerminal) && os(iOS)`) → `HakoTerminalSessionContentView` (`:43`) | `HAKO` | the container's guard is the original's; the content view's file-level `#if canImport(GhosttyTerminal)` was restored in `bce950c` |

The three report chains are the ones to re-check first after any generator run: they are exactly what a
`--write` pass over `Tools/*ReportDetailView.swift` silently rewrote once already.

---

## Reports share

| Feature | Chain | Classification |
|---|---|---|
| report → share / save | `HakoReportSharePopup` (`HakoReportShared.swift:151`) presented by all three detail pages | `HAKO` |
| report → zip | `createReportZip` from `Tools/ReportShared.swift:108` | `ORIGINAL_SHARED_OK` - a free function with no presentation in it; the rename could not touch it, and copying it produced a duplicate declaration until `bce950c` |
| report → share sheet | `presentShareSheet` from `Tools/ReportShared.swift:235` | `ORIGINAL_SHARED_OK`, same reason |
| document export | `HakoReportZipDocument` (`HakoReportShared.swift:207`) | `HAKO` |

---

## The editor toolbar

`ProfileEditorWrapperView(restyled:)` is a single file compiled into `SFI`, and **both of that target's
roots build it**. The choice is therefore a parameter, not a change to the default:

| Root | Argument | Site |
|---|---|---|
| phone | `restyled: true` | `SFI/HakoPhoneRootView.swift:74` |
| iPad | default `false` | `SFI/MainView.swift:33-35`; the default is declared at `SFI/ProfileEditorWrapperView.swift:22` |

`restyled` selects `HakoEditorToolbarView` (`SFI/ProfileEditorWrapperView.swift:33-40`), which is the
original's restyle of four toolbar elements. The gate that matters is that the *iPad* must not follow it;
`ipad-mac-ui-gate` and `tablet-and-mac-entry` assert that, and `MainView.swift` is byte-identical to
upstream so the assertion is not resting on a hand-written list.

---

## Shared pages that stay upstream's, on purpose

These are `ORIGINAL_SHARED_OK`. The original never changed them, so the phone showing the official view is
the correct behaviour and a report that they "were not ported" is a false positive:

`ConnectionDetailsView`, `MetadataFormView`, `OpenConnectEndpointView`, `OpenVPNEndpointView`,
`TailscaleEndpointView`, `OpenConnectBrowserView`, `ExportReportView`, `EditProfileContentView`,
`QRCodeSheet`, `ExternalQRCodeView`, `ImportProfileView`, `SponsorsView`, `UpdateSheet`.

The audit distinguishes them by `UPSTREAM_REACHABLE_PAGES` in `scripts/dev/audit_apple_ui_boundary.py`
(`:194`) and by `REVIEWED_UPSTREAM_MODIFICATIONS` (`:540`), not by a name pattern.

## What is still only verifiable on a Mac

Every row above is a static claim: a construction site, a condition, a declaration. None of it is a build
result or a picture. The following remain `UNVERIFIED` because this environment has no Xcode, no Swift
toolchain, no `Libbox.xcframework` and no `GhosttyTerminal` framework, and no iPhone, iPad or Mac:

* that the `SFI` scheme builds for `iphoneos` and `ipados`, and the `SFM` scheme for `macosx`
  (schemes found in the project: `SFI`, `SFM`, `SFM.System`, `SFT`, `JailbreakDaemon`);
* that `ApplicationLibrary` compiles for each of `iphoneos`, `macosx` and `appletvos`, which is where the
  restored guards matter;
* that the pages draw, that the navigation pushes as the table says, and that the pixels match
  `hako-ui@c1935cf`;
* that `canImport(GhosttyTerminal)` is true for any given slice - the guards are correct either way, but
  which way it resolves decides whether the terminal UI is present.

`scripts/dev/audit_hako_lossless_parity.py` answers the token half of the pixel question and never claims
more than `STATIC_PARITY_EVIDENCE`; it explicitly does not claim `PIXEL_PARITY_PASS` or `DEVICE_PASS`.
