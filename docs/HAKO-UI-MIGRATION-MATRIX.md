# Hako UI migration matrix

What the phone shows today, page by page, and what it does not yet.

**How to read this.** The only column that decides whether a page is migrated is
**`HakoPageContent` route**: the switch in `SFI/HakoPageContent.swift` is the single place a page is
turned into a view, and a page whose route is an upstream type is upstream's page no matter how many
Hako files exist beside it. `scripts/dev/audit_apple_ui_boundary.py --only hako-page-coverage` reads
that switch and reports the count; it **fails** while the count is incomplete, so this table cannot
drift away from the source without the audit saying so.

Last verified: `b0f35a6`.

---

## First-level pages

| Page | Reference (`hako-ui@c1935cf`) | `HakoPageContent` route | New file | Data and side effects | Status | Static evidence | Apple check |
|---|---|---|---|---|---|---|---|
| **Home** | `HakoStyle/HakoHomeView.swift` (616 lines) | `HakoHomeView` | `HakoStyle/HakoHomeView.swift` (600 lines) | `DashboardViewModel` (profile list, proxy snapshot, card configuration), `ExtensionEnvironments`, `ExtensionProfile`, `CommandTarget` for the outbound mode | **MIGRATED** | `hako-page-coverage`, `hako-feature-preservation` | Home draws; start/stop; mode rows; shortcuts open Proxies/Activity/Logs; configuration centre opens with new/edit/delete/reorder/QR/update; quota row shows and is absent when the panel reports no total |
| **Proxies** (`groups`) | `Groups/GroupListView.swift` Hako mode | `GroupListView` (upstream) | — | upstream `GroupListViewModel`, `CommandClient` | **PENDING** | `hako-page-coverage` names it as still upstream | — |
| **Activity** (`connections`) | `Connections/ConnectionListView.swift` Hako mode | `ConnectionListView` (upstream) | — | upstream `ConnectionListViewModel`, `CommandClient` | **PENDING** | same | — |
| **Logs** | `Log/LogView.swift` Hako mode | `LogView` (upstream) | — | upstream `LogViewModel` | **PENDING** | same | — |
| **Tools** | `Tools/ToolsView.swift` Hako presentation | `ToolsView` (upstream) | — | shared services, `TailscaleStatusViewModel`, report managers | **PENDING** | same | — |
| **More** (`settings`) | `Setting/SettingView.swift` Hako presentation | `SettingView` (upstream) | — | `SettingsPage` navigation, `FormNavigationLink` | **PENDING** | same | — |

**1 of 6 migrated.** The audit reports the other five by name.

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
| Logs | `ApplicationLibrary/Views/Log/LogView.swift` | +52 / -10 |

Read one with:

```bash
git diff 2b1763a..origin/hako-ui -- ApplicationLibrary/Views/Log/LogView.swift
```

**Do not copy the diff over the upstream file.** Each of these files is on
`REVIEWED_UPSTREAM_MODIFICATIONS`'s complement: it must stay byte-identical to upstream, because an
iPad and a Mac load it too. The presentation has to become a Hako-owned page, the way Home did.

---

## The section-level pages the pending pages lead to

Second-level pages are reached from Tools and More. They are **not** in the coverage count - that
count is the six first-level destinations - so a reader should not assume they are done. The fork's
own changes to them are small and are listed here so the next slice starts from evidence:

| Page | Fork change | Disposition |
|---|---|---|
| `Tools/NetworkQualityView.swift` | `FormItem` → a plain row; `navigationTitle` → `hakoNavigationChrome` | **PENDING** — belongs to the Tools slice |
| `Tools/OutboundPickerView.swift` | `HakoSelectionRow` / `HakoIconWell` | **PENDING** |
| `Tools/CrashReportDetailView.swift`, `OOMReportDetailView.swift`, `PowerReportDetailView.swift` | `HakoReportScaffold`, `HakoEmptyState` | **PENDING** |
| `Tools/CrashReportListView.swift`, `OOMReportListView.swift`, `PowerReportListView.swift` | `HakoWorkspaceScaffold` | **PENDING** |
| `Tools/ReportShared.swift`, `STUNTestView.swift`, `TaildropView.swift`, `USBIPServerView.swift`, `Tailscale*View.swift` | one modifier or one row each | **PENDING** |
| `Setting/CoreView.swift`, `PacketTunnelView.swift`, `OnDemandRulesView.swift`, `ProfileOverrideView.swift`, `MacAppView.swift` | `HakoSettingsScaffold` and its rows | **PENDING — More slice.** `MacAppView` is the one to check twice: it is the macOS shape of the app settings page, and a Hako variant of it must not become reachable from `SFM` |
| `Setting/FontPickerView.swift`, `ThemePickerView.swift` | one modifier each | **PENDING** |
| `Connections/ConnectionView.swift`, `Groups/GroupItemView.swift`, `Groups/GroupView.swift` | shared row language | **PENDING** |
| `Terminal/TerminalSessionContentView.swift` | shared chrome | **PENDING** |

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
