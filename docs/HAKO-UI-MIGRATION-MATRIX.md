# Hako UI migration matrix

What the phone shows today, page by page, and what it does not yet.

**How to read this.** The only column that decides whether a page is migrated is
**`HakoPageContent` route**: the switch in `SFI/HakoPageContent.swift` is the single place a page is
turned into a view, and a page whose route is an upstream type is upstream's page no matter how many
Hako files exist beside it. `scripts/dev/audit_apple_ui_boundary.py --only hako-page-coverage` reads
that switch and reports the count; it **fails** while the count is incomplete, so this table cannot
drift away from the source without the audit saying so.

Last verified: `22c263c` (branch `jiejiebox/integrated`).

**What was out of date in this file, and is fixed here.** Two things, one of which was actively misleading:

* the SHA above, and
* the whole second-level section, which listed the Tools, More, Profile, Terminal and Connections
  sub-pages as `PENDING`. They are not pending - they were migrated in the rounds after that line was
  written - so a reader checking this file would have concluded the opposite of the truth. The section now
  records what each one actually is.

For the question this file does **not** answer - whether the phone's call sites actually construct the Hako
page rather than upstream's, entry by entry - see
[`HAKO-REAL-REACHABILITY-MATRIX.md`](HAKO-REAL-REACHABILITY-MATRIX.md). The distinction is not academic: a
page can be listed here as migrated, have its file present, and still be reached through an upstream type at
the call site. That is exactly what happened once, and it is why the second document exists.

---

## First-level pages

| Page | Reference (`hako-ui@c1935cf`) | `HakoPageContent` route | New file | Data and side effects | Status | Static evidence | Apple check |
|---|---|---|---|---|---|---|---|
| **Home** | `HakoStyle/HakoHomeView.swift` (616 lines) | `HakoHomeView` | `HakoStyle/HakoHomeView.swift` (600 lines) | `DashboardViewModel` (profile list, proxy snapshot, card configuration), `ExtensionEnvironments`, `ExtensionProfile`, `CommandTarget` for the outbound mode | **MIGRATED** | `hako-page-coverage`, `hako-feature-preservation` | Home draws; start/stop; mode rows; shortcuts open Proxies/Activity/Logs; configuration centre opens with new/edit/delete/reorder/QR/update; quota row shows and is absent when the panel reports no total |
| **Proxies** (`groups`) | `Groups/GroupListView.swift` (+273/-30) | `HakoGroupListView` | `HakoStyle/HakoGroupListView.swift` | upstream `GroupListViewModel` plus the additive `testingItems`; `CommandClient` | **MIGRATED** | `hako-page-coverage`, `hako-feature-preservation` | Group list; expand/collapse; member selection; the per-group and per-member latency sweep, with the spinner on the row being measured; search; the summary card. **Not done:** the group detail page (`GroupView`) |
| **Activity** (`connections`) | `Connections/ConnectionListView.swift` (+207/-34) | `HakoConnectionListView` | `HakoStyle/HakoConnectionListView.swift` | upstream `ConnectionListViewModel`; `CommandClient` | **MIGRATED** | same | Connection list; search; the row's rule and outbound columns. **Not done:** `ConnectionView` (the per-connection detail page) and the screenshot data-density fixture |
| **Logs** | `Log/LogView.swift` Hako mode (+52/-10) | `HakoLogView` | `HakoStyle/HakoLogView.swift` | upstream `LogViewContent` through the raised visibility; `LogViewModel`, `CommandClient` | **MIGRATED** | `hako-page-coverage`, `hako-feature-preservation` | Logs streams; level filter; search; export; scroll follows; the detail chrome shows a disc rather than the platform chevron. **Not done:** the four `HakoEmptyState` texts and the `HakoCardSurface` around the log surface — both are private members of a private inner view, recorded below rather than approximated |
| **Tools** | `Tools/ToolsView.swift` (+304/-237) | `HakoToolsView` | `HakoStyle/HakoToolsView.swift` | shared services; `TailscaleStatusViewModel`; the three report managers | **MIGRATED** | same | Every tool row, and the re-grouped sections. **Not done:** every page a row opens — about fourteen files, one modifier or one row each |
| **More** (`settings`) | `Setting/SettingView.swift` (+427/-191) | `HakoSettingView` | `HakoStyle/HakoSettingView.swift` | `SettingsPage`; the fork's pending-sub-page machinery | **MIGRATED** | same | The destination list, and a requested sub-page carried into the destination that owns it. **Not done:** the settings sub-pages — about nine files, `HakoSettingsScaffold` each |

**6 of 6 migrated.** `hako-page-coverage` passes without `--allow-partial`, and the second-level pages are listed below with what each needs.

---

## Where the reference work lives

Most of the fork's presentation is not a separate file - it is a modification of a shared page. Those
modifications are kept as evidence rather than applied, so the plan for each pending page has to be
read from a diff rather than from a file:

| Page | Reference source | `git diff --numstat` (`2b1763a..origin/hako-ui`) |
|---|---|---|
| More (`settings`) | `ApplicationLibrary/Views/Setting/SettingView.swift` | +427 / -191 |
| Tools | `ApplicationLibrary/Views/Tools/ToolsView.swift` | +304 / -237 |
| Proxies (`groups`) | `ApplicationLibrary/Views/Groups/GroupListView.swift` | +273 / -30 |
| Activity (`connections`) | `ApplicationLibrary/Views/Connections/ConnectionListView.swift` | +207 / -34 |
| ~~Logs~~ (done) | `ApplicationLibrary/Views/Log/LogView.swift` | +52 / -10 |

Read one with:

```bash
git diff 2b1763a..origin/hako-ui -- ApplicationLibrary/Views/Setting/CoreView.swift
```

**Do not copy the diff over the upstream file.** Each of these files is on
`REVIEWED_UPSTREAM_MODIFICATIONS`'s complement: it must stay byte-identical to upstream, because an
iPad and a Mac load it too. The presentation has to become a Hako-owned page, the way Home did.

---

## The section-level pages

Second-level pages are reached from Tools and More. They are **not** in the coverage count - that count is
the six first-level destinations - but they are **migrated**, not pending. Every row below was `PENDING`
here until round 8; the disposition column is now what the source says.

| Page | Fork change | Disposition |
|---|---|---|
| `Tools/NetworkQualityView.swift` | `FormItem` → a plain row; `navigationTitle` → `hakoNavigationChrome` | **MIGRATED** → `HakoStyle/HakoNetworkQualityView.swift`, reached from `HakoToolsView.swift:261` |
| `Tools/OutboundPickerView.swift` | `HakoSelectionRow` / `HakoIconWell` | **MIGRATED** → `HakoStyle/HakoOutboundPickerView.swift`, reached through the Network Quality / STUN section chain |
| `Tools/CrashReportDetailView.swift`, `OOMReportDetailView.swift`, `PowerReportDetailView.swift` | `HakoReportScaffold`, `HakoEmptyState` | **MIGRATED** → `HakoStyle/Hako*ReportDetailView.swift`, constructed by their own list pages |
| `Tools/CrashReportListView.swift`, `OOMReportListView.swift`, `PowerReportListView.swift` | `HakoWorkspaceScaffold` | **MIGRATED** → `HakoStyle/Hako*ReportListView.swift`, reached from `HakoToolsView.swift:298`, `:327`, `:341` |
| `Tools/ReportShared.swift` | one modifier or one row each | **MIGRATED in part, deliberately**: `HakoStyle/HakoReportShared.swift` holds the Hako-namespaced presentation types; `createReportZip` and `presentShareSheet` stay upstream's in `Tools/ReportShared.swift`, because they are free functions with no presentation in them and copying them produced a duplicate declaration |
| `Tools/STUNTestView.swift`, `TaildropView.swift`, `USBIPServerView.swift`, `Tailscale*View.swift` | one modifier or one row each | **MIGRATED** → `HakoStyle/HakoSTUNTestView.swift`, `HakoTaildropView.swift`, `HakoUSBIPServerView.swift`, `HakoTailscaleSSHPromptView.swift` |
| `Setting/CoreView.swift`, `PacketTunnelView.swift`, `OnDemandRulesView.swift`, `ProfileOverrideView.swift` | `HakoSettingsScaffold` and its rows | **MIGRATED** → `HakoStyle/HakoCoreView.swift`, `HakoPacketTunnelView.swift`, `HakoOnDemandRulesView.swift`, `HakoProfileOverrideView.swift`, all pushed from `HakoSettingView.swift:293-319` |
| `Setting/MacAppView.swift` | `HakoSettingsScaffold` and its rows | **MIGRATED** → `HakoStyle/HakoMacAppView.swift`, whose type is `HakoAppView`. The caution this row used to carry is answered: the file is reachable only from `HakoSettingView.swift:329`, which is the phone's own page, and `SFM` reaches its own `AppView` through upstream's `SettingView.swift`. Note the file's *name*: upstream's original is not macOS-only - line 99 of it constructs `GhosttyConfigurationView()`, which is how the phone reaches Terminal Appearance |
| `Setting/FontPickerView.swift`, `ThemePickerView.swift` | one modifier each | **MIGRATED** → `HakoStyle/HakoFontPickerView.swift`, `HakoThemePickerView.swift`, reached from `HakoGhosttyConfigurationView.swift:75` and `:139` |
| `Connections/ConnectionView.swift`, `Groups/GroupItemView.swift`, `Groups/GroupView.swift` | shared row language | **MIGRATED** → `HakoStyle/HakoConnectionView.swift`, `HakoGroupItemView.swift`, `HakoGroupView.swift` |
| `Terminal/TerminalSessionContentView.swift` | shared chrome | **MIGRATED** → `HakoStyle/HakoTerminalSessionContentView.swift`, reached from `HakoTerminalSessionContainerView.swift:43` |

The row a reader should still check twice is `MacAppView`, for the reason given there: the phone's variant
and the Mac's are different types with the same upstream ancestor, and the phone's must never become
reachable from `SFM`. `ipad-mac-ui-gate` asserts that, and `MainView.swift` being byte-identical to upstream
is what makes the assertion trustworthy rather than list-based.

---

## What is already Hako-owned and reachable

| File | Why it is the phone's |
|---|---|
| `HakoStyle/HakoPrimaryShell.swift` | the three-destination shell |
| `HakoStyle/HakoNavigation.swift` | the phone's page names, kept out of `NavigationPage` |
| `HakoStyle/HakoTheme.swift`, `HakoSurface.swift`, `HakoCard.swift`, `HakoRow.swift`, `HakoScaffold.swift`, `HakoStatus.swift`, `HakoData.swift`, `HakoEmptyState.swift`, `HakoUITrace.swift` | the design system |
| `HakoStyle/HakoHomeView.swift` | Home |
| `HakoStyle/HakoProfilePickerSheet.swift` | the configuration centre, with the remaining-quota row |
| `SFI/HakoPhoneRootView.swift` | the phone root: selection, environment, lifecycle |
| `SFI/HakoPageContent.swift` | the page factory — the routing |

Every one of them is reachable only from `SFI/HakoPhoneRootView.swift`. The audit's
`no-reverse-dependency` check asserts that no file outside this list and the phone root names a Hako
symbol, and it covers every `.swift` file in the tree rather than a hand-kept list.

---

## The rule for adding a page

1. Create the Hako page under `ApplicationLibrary/Views/HakoStyle/`, named `Hako…`.
2. Point the page's arm in `SFI/HakoPageContent.swift` at it.
3. Set that page's entry in `HAKO_PAGE_ROUTING` in the audit to the Hako view's name.
4. Add any new wiring to `hako-feature-preservation`'s table - the opener and the consumer.
5. Run both scripts. `hako-page-coverage` fails until the arm is changed, which is the point.
6. Record the page in this table with the reference it came from and what is not done.

**Do not edit a shared page to make the phone look right.** That is what phase 1 did to
`ProfilePickerSheet`, and it is why an iPad showed a quota row the product says it must not.
