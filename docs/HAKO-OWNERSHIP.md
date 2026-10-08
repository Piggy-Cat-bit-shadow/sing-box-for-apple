# Hako Ownership Map — sing-box-for-apple

**Audit type:** logical ownership only. No source was moved, renamed, reformatted, or refactored.
**Repository:** `Piggy-Cat-bit-shadow/sing-box-for-apple`
**Audited ref:** `hako-ui` @ `fc7f77b82a7ca432294addfa001fcacfd5776223`
**Audit date:** 2026-10-08

This document answers one question: *for every file in this repository, whose code is it?*
It deliberately does **not** propose refactors, and it does **not** move files between
directories. Ownership is expressed here, not in the source tree — so that upstream
synchronisation stays a normal `git merge` instead of a rename war.

---

## 0. Frozen baseline

Captured before any work. All comparisons in this document are against these exact objects.

### Apple repository

| Ref | SHA |
| --- | --- |
| `hako-ui` (local HEAD) | `fc7f77b82a7ca432294addfa001fcacfd5776223` |
| `origin/hako-ui` | `5911580a6366da78e6b4b5b4459596e5a2cf1eb4` |
| `origin/dev` | `d1224bb5081b3df5d0ecc55b1bd3d72ea6c60628` |
| `origin/main` | `ab33c3f083bb79928ef83c4fb96e9c7ac01bf3ba` |
| `origin/stable` | `0b84ea472fbc9e1a7e11992b1f2daadbe2d30556` |
| `origin/wip` | `b3714ed957cb1505600943ca2bc15db9ef7a3222` |
| upstream fork point of `hako-ui` | `2b1763a80f2c1dee1ab3ac62d84dbda7dc5178f4` |

`2b1763a` is the merge-base of `hako-ui` and `origin/dev`, and also of `hako-ui` and
`upstream/dev`. Every "Hako changed this" claim below is a diff from that commit, so it
isolates Hako's work from ordinary upstream drift.

### Parent repository (`Piggy-Cat-bit-shadow/sing-box`)

| Item | Value |
| --- | --- |
| Branch | `testing` |
| HEAD | `1a920197dc06f1aab77cd1211065be97b711edd4` |
| `clients/apple` gitlink (tree **and** index) | `5911580a6366da78e6b4b5b4459596e5a2cf1eb4` |
| `clients/apple` submodule worktree HEAD | `fc7f77b82a7ca432294addfa001fcacfd5776223` |

> **Discrepancy found, recorded not fixed.** The parent gitlink pins `5911580`
> (`origin/hako-ui`), but the submodule worktree is one commit further ahead at `fc7f77b`
> ("port Hako subscription usage metadata"), which is **not yet pushed**. The parent's
> gitlink is therefore *not* pinning the local `hako-ui` HEAD. Pushing `fc7f77b` and
> bumping the gitlink is a separate decision and was not taken in this round.

---

## 1. Branch roles

Only `hako-ui` and `ipad-upstream-ui` carry fork work.

| Branch | Role | Hako work? | Notes |
| --- | --- | --- | --- |
| `hako-ui` | **Product branch.** Hako UI + Hako data/network layer. | **Yes** — 80 commits | Only branch containing Hako work. Pinned by the parent submodule. |
| `ipad-upstream-ui` | Presentation split: iPhone keeps Hako, iPad/macOS take upstream presentation. | Carries the split + branding | Cut from `hako-ui`. Also carries the `Jiejiebox` display-name change. |
| `dev` | Fork's mirror of the upstream development channel, carrying a small amount of fork-local platform work. | Partly | Default branch of the fork. 3 fork commits ahead, 11 upstream commits behind. |
| `main` | Upstream release-channel mirror. | No | Exact ancestor of `origin/dev`; 8 commits behind upstream. |
| `stable` | Upstream stable-channel mirror. | No | Byte-identical to `upstream/stable`. |
| `wip` | Historical upstream branch. | No | Byte-identical to `upstream/wip`; ancestor of every maintained branch. |

### 1.1 Hako's work is one linear run of 80 commits

Every commit in `2b1763a..hako-ui` is authored by `Piggy-Cat-bit-shadow`:

```
ui(apple): add the HAKO/Clash design system          <- first Hako commit
...
fix(ui): the route is an arrow, not two labelled lines
feat(apple): port Hako subscription usage metadata   <- fc7f77b, current HEAD
```

There are **no upstream commits** interleaved in that range, so `hako-ui` can be read as
"upstream at `2b1763a`, plus 80 Hako commits", with no attribution ambiguity.

### 1.2 `hako-ui` and `dev` are separate lineages

This is the single most important structural fact in the audit and it is easy to miss:

* `hako-ui` forked at `2b1763a` and never took the fork's later `dev` commits.
* `origin/dev` carries **3 fork-local commits that `hako-ui` does not have**:
  * `2070ae1` Add stub for platform auto redirect
  * `e3edd71` Pass process paths through helper XPC
  * `d1224bb` Bump version 1.15.0-alpha.10
* Those 3 commits touch **94 files**, **56 of which `hako-ui` never touches**.

Consequence: **`git diff origin/dev hako-ui` is not a Hako diff.** It mixes Hako's UI work
with 56 files of fork-platform work and 11 releases of upstream drift. All classification
below therefore uses `2b1763a` as the baseline instead.

---

## 1b. Presentation ownership — the rule that decides every conflict

Ownership is not one axis. There are **two**, and conflating them is what made the first attempt at
the iPad work wrong. The correction:

> **We override iPhone presentation only. Upstream owns iPad and macOS presentation.**

| Surface | Design authority | Owner |
| --- | --- | --- |
| iPhone presentation | The validated Hako UI | **Hako** |
| iPad presentation | Current SagerNet upstream | **Upstream** |
| macOS presentation | Current SagerNet upstream | **Upstream** |
| Product display name | `Jiejiebox`, on all three platforms | **Fork (branding)** |
| Shared application/core state | One set of objects, both families | Shared |

### What this forbids

Forking a second copy of upstream presentation in order to have an "iPad version":

```
IPadMainView            ✗  a re-implementation of upstream's root
IPadNavigationPage      ✗  a second navigation enum
IPadSidebarView         ✗  a copy of upstream's SidebarView
IPadSidebarLayout       ✗  a copy of upstream's SidebarLayout
IPadUpstream/           ✗  a maintained mirror of upstream presentation
```

iPad must run **upstream's implementation**. Where a Hako modification stands in the way, the fix is
to **isolate the Hako behaviour out of the shared presentation** — not to fork the presentation.

### Conflict-resolution order

```
iPhone presentation       -> Hako wins
iPad / macOS presentation -> upstream wins
product branding          -> Jiejiebox wins (all three)
shared business logic     -> prefer upstream/shared; never copy without reason
```

### The freeze, restated precisely

Earlier revisions of this document said "every Swift source file is frozen". That was too broad and
is corrected here:

> **The validated iPhone user experience is frozen — not every shared file that Hako has touched.**

To restore upstream ownership of iPad/macOS presentation it is *permitted* to extract a Hako
adapter, split platform presentation, or restore an upstream version of a shared file — **provided
the iPhone UI and interaction do not change by one pixel**, proved by the snapshot, navigation and
runtime tests.

`ApplicationLibrary/Views/HakoStyle/` remains a high-protection zone: do not modify it if the
isolation can be achieved without doing so.

---

## 2. Directory roles

Ownership is per-file, not per-directory. Hako modified files inside otherwise-upstream
directories, so no directory may be labelled wholesale. The table gives the dominant role
and flags exceptions.

| Directory | Dominant role | Hako involvement |
| --- | --- | --- |
| `ApplicationLibrary/` | Upstream shared UI + services layer. | **Heavy.** Contains all Hako UI (`Views/HakoStyle/`) and 76 modified upstream view files. |
| `ApplicationLibrary/Views/HakoStyle/` | **Hako-owned design system.** | 100% Hako, 11 files. |
| `Library/` | Upstream shared model/network/database code (compiled into app + extensions). | 14 files added, 14 modified by Hako. |
| `SFI/` | Upstream iOS app target (`SFI` = sing-box for iOS). | `MainView.swift` is the primary integration boundary. `Application.swift`/`ApplicationDelegate.swift` are fork-local (`dev`) work, untouched by Hako. |
| `SFM/` | Upstream macOS app target. | Only `Info.plist` touched, by the fork's `dev` work. |
| `SFM.System/` | Upstream macOS system extension (packaging + `Info.plist`). | `dev`-only. |
| `SFT/` | Upstream tvOS app target. | `dev`-only (`Application.swift`, `ApplicationDelegate.swift`). |
| `MacLibrary/` | Upstream macOS UI library. | Hako modified `MainView.swift` and `SidebarView.swift`; Hako *added* a second `SidebarView.swift` here (see §5). |
| `Extension/` | Upstream iOS network extension entry point. | Untouched by Hako. |
| `SystemExtension/` | Upstream macOS system extension target. | Untouched by Hako. |
| `TVExtension/` | Upstream tvOS extension. | Untouched by Hako. |
| `WidgetExtension/` | Upstream iOS widget extension. | Untouched by Hako. |
| `ShareExtension/`, `ShareExtension.System/` | Upstream share extensions. | Untouched by Hako. |
| `ActionExtension/` | Upstream action extension. | Untouched by Hako. |
| `IntentsExtension/` | Upstream Siri/App Intents extension. | Untouched by Hako. |
| `FileProviderExtension/` | Upstream file provider extension. | Untouched by Hako. |
| `HelperService/` | Upstream privileged helper (XPC). | `dev`-only (`RootHelperService.swift`, `main.swift`). |
| `JailbreakDaemon/`, `Jailbreak/` | Upstream jailbreak packaging. | `IOSRootHelperService.swift` is `dev`-only. |
| `Frameworks/` | Vendored dependencies. `Runestone` is a gitlink; `TreeSitterJSON5` a subtree. | Identical in all three refs — not Hako's. |
| `scripts/` | Upstream build/release scripts, **plus Hako dev tooling**. | 4 Hako files under `scripts/dev/` and `scripts/`. |
| `fastlane/` | Upstream release/snapshot automation. | Untouched by Hako. |
| `SFIUITests/`, `SFMUITests/`, `SFTUITests/`, `UITests/` | Upstream UI test targets. | `SFIUITests/` has 2 Hako files; the rest untouched. |
| `Tests/` | Test targets. | Holds the Hako-owned `Tests/HakoSubscriptionUsage/` package. |
| `sing-box.xcodeproj/` | Xcode project. | `project.pbxproj` changed by Hako (iOS 16 target); `Package.resolved` changed by `dev`. |

---

## 3. Classification method

### 3.1 The population is the union of three trees, and it is 510

The classification population is **the union of distinct paths** present in any of the three
audited trees — not the file count of any single tree, and not a directory count:

| Tree | Distinct paths |
| --- | --- |
| `2b1763a` (fork point) | 456 |
| `hako-ui` | 500 |
| `upstream/dev` | 463 |
| **union (deduplicated)** | **510** |

Reproduce with:

```bash
{ git ls-tree -r --name-only 2b1763a80f2c1dee1ab3ac62d84dbda7dc5178f4
  git ls-tree -r --name-only hako-ui
  git ls-tree -r --name-only upstream/dev
} | sort -u | wc -l        # -> 510
```

### 3.2 The seven classes sum to exactly 510

| Class | Count | Meaning |
| --- | --- | --- |
| `UNTOUCHED_BY_EITHER` | 315 | Same in all three refs. Pure upstream, no action. |
| `UPSTREAM_DRIFT_ONLY` | 53 | Upstream moved after `2b1763a`; Hako never touched it. |
| `HAKO_ADDED` | 45 | Exists in `hako-ui`, absent from both `2b1763a` and `upstream/dev`. |
| `HAKO_MODIFIED` | 44 | Present at `2b1763a`, unchanged upstream, changed by Hako. |
| `BOTH_MODIFIED_DIFFERENTLY` | 42 | Changed by Hako **and** independently by upstream. **Conflict zone.** |
| `OTHER` | 10 | Present upstream, absent from `hako-ui` and `2b1763a` — upstream additions Hako never merged. |
| `HAKO_ABSENT_UPSTREAM_PRESENT` | 1 | Deleted by Hako. |
| **total** | **510** | `315 + 53 + 45 + 44 + 42 + 10 + 1 = 510` |

Each union path lands in exactly one class, so the sum must equal the population. It does.

### 3.3 One entry is a gitlink, not a file

The `OTHER` bucket's **10** entries are **9 regular files plus 1 gitlink**:

| Entry | Kind | Detail |
| --- | --- | --- |
| 9 × `*` upstream-only paths | regular files | Listed in §7 |
| `Frameworks/Runestone` | **gitlink** (`160000 commit baeb3cbf…`) | Vendored dependency pointer |

`Frameworks/Runestone` is recorded as `160000` in all three refs — it is **identical in all
three**, i.e. genuinely `UNTOUCHED_BY_EITHER`. It appears in the `OTHER` bucket only because
the classifier compares blob object IDs and a gitlink's object ID is a *commit*, not a blob,
so the `upstream == base` equality test that drives every other class cannot hold for it.

This is a reporting artefact, not an ownership difference. **The correct reading is: 510
union paths classified, of which 509 are regular files and 1 is a gitlink that is unchanged.**
Earlier revisions of this document said "9 files" in §7 while §3 counted 10 in `OTHER`
without explaining the tenth; both figures were right about different things. The count was
never 509 — `510` is correct — but the mismatch between the two sections was a real
documentation defect, corrected here.

---

## 4. HAKO_OWNED — 45 files added by Hako

### 4.1 Hako UI design system — `ApplicationLibrary/Views/HakoStyle/` (11 files)

**FROZEN THIS ROUND.** Do not move, rename, reformat, refactor, or split.

| File | Lines | Role |
| --- | --- | --- |
| `HakoTheme.swift` | 374 | Colour, spacing, typography tokens |
| `HakoSurface.swift` | 320 | Card/surface backgrounds, glass effects |
| `HakoCard.swift` | 196 | Card container |
| `HakoRow.swift` | 855 | Row language (list rows, value rows, pickers) |
| `HakoScaffold.swift` | 1067 | Page scaffolds and navigation chrome |
| `HakoHomeView.swift` | 615 | The Home destination |
| `HakoPrimaryShell.swift` | 387 | The three-destination primary shell |
| `HakoStatus.swift` | 279 | Status presentation |
| `HakoData.swift` | 920 | View-model / data adaptation for Hako pages |
| `HakoEmptyState.swift` | 122 | Shared empty/loading presentation |
| `HakoUITrace.swift` | 131 | Debug UI-transition tracing |

### 4.2 Hako data / network layer (4 files)

Ported in `fc7f77b` (`feat(apple): port Hako subscription usage metadata`), from Hako-Client
`62aa2f2f`. These are not UI, but they are Hako-owned:

* `Library/Network/SubscriptionInfo.swift`
* `Library/Network/RemoteProfileFetcher.swift`
* `Library/Database/RemoteProfileUpdatePolicy.swift`
* `Library/Database/RemoteRefreshApplier.swift`

### 4.3 Hako UI tests (2 files) — `HAKO_TEST`

**Valuable regression guards for the frozen iPhone UI. Not disposable.**

* `SFIUITests/HakoNavigationUITests.swift` (27 KB)
* `SFIUITests/HakoSnapshotUITests.swift` (30 KB)

### 4.4 Hako subscription test package (24 files) — `HAKO_TEST`

`Tests/HakoSubscriptionUsage/` is a self-contained SwiftPM package that compiles the
production sources through symlinks (see `scripts/link-test-sources.sh`) rather than copies.
It exists so the four files in §4.2 are testable outside the app target.

```
Tests/HakoSubscriptionUsage/
├── .gitignore
├── Package.swift
├── Sources/AppStubs/TestDependencyStubs.swift
├── Sources/Core/{AppStubImport,BlockingIO,RemoteProfileFetcher,
│                 RemoteProfileUpdatePolicy,RemoteRefreshApplier,SubscriptionInfo}.swift
├── Sources/GRDB/GRDB.swift
├── Sources/Libbox/LibboxStub.swift
├── Sources/Profile/{CoreImport,FilePathStub,PreferencesAndProfileStub,
│                   Profile+Hashable,Profile+RW,Profile+Update,Profile,
│                   ProfileManagerStub,ProfileRecordAccess}.swift
├── Tests/CoreTests/{RemoteRefreshPolicyTests,SubscriptionInfoTests}.swift
└── Tests/ProfilePersistenceTests/{ProfileRecordTests,ProfileRefreshIntegrationTests}.swift
```

### 4.5 Hako dev tooling (4 files) — `HAKO_DEV_TOOL`

**Not disposable.** The `check-hako-primary-route` pair is the navigation-route guard for
the frozen iPhone UI.

| File | Role |
| --- | --- |
| `scripts/dev/check-hako-primary-route.sh` | Navigation route checker (shell driver) |
| `scripts/dev/check-hako-primary-route.swift` | Navigation route checker (Swift) |
| `scripts/link-test-sources.sh` | Symlinks production sources into the test package |
| `scripts/run-subscription-usage-tests.sh` | Runs the test package |

A runtime check being environment-limited today is not evidence that the file is dead.

---

## 5. UPSTREAM_MODIFIED_BY_HAKO

**86 files** were modified by Hako while already existing at the fork point:
**44** `HAKO_MODIFIED` (upstream untouched them) + **42** `BOTH_MODIFIED_DIFFERENTLY`
(upstream touched them independently). `Localizable.xcstrings` and
`sing-box.xcodeproj/project.pbxproj` are inside that 86 and are verified separately in §5.4.
These remain upstream files at upstream paths; Hako's changes ride along. **That is
deliberate** — moving them would break future merges.

### 5.1 Integration / glue — `HAKO_GLUE`

| File | Why mixed |
| --- | --- |
| `SFI/MainView.swift` | Upstream app root + Hako shell takeover + environment wiring + navigation bridge. See §6. |
| `MacLibrary/MainView.swift` | Same shape on macOS (70 lines changed). |
| `ApplicationLibrary/Views/EnvironmentValues.swift` | Upstream env values **+** Hako's `hakoCompactRows` compact-row metric. |
| `ApplicationLibrary/Views/NavigationPage.swift` | Upstream page enum **+** Hako vocabulary (`Dashboard`→`Home`, `Settings`→`More`, `Groups`→`Proxies`) and a new `subtitle`. |
| `ApplicationLibrary/Views/Abstract/NavigationSheetContent.swift` | Sheet/navigation bridge for Hako chrome. |
| `Library/Network/ExtensionEnvironments.swift` | Environment wiring consumed by the Hako shell. |

### 5.2 Presentation / navigation / shell semantics

Files Hako changed, grouped by area (counts include files that are also in the §5.5 conflict
zone — those are counted once here and once there, because they carry both properties):

| Area | Files touched by Hako | Hako's purpose |
| --- | --- | --- |
| `ApplicationLibrary/Views/Tools/**` | 16 | Report/tool page chrome, empty & loading presentation, shared surface |
| `ApplicationLibrary/Views/Dashboard/**` | 16 | Hako home integration, card styling, headers/value lines, status presentation, pickers, sheets |
| `ApplicationLibrary/Views/Setting/**` | 9 | Section-per-setting layout, density (74pt → 57pt rows), modal chrome, pickers |
| `ApplicationLibrary/Views/Profile/**` | 7 | Shared row language, toolbars, modal chrome, picker mark |
| `ApplicationLibrary/Views/Abstract/**` | 4 | Form/density primitives, sheet routing, view modifiers |
| `ApplicationLibrary/Views/Groups/**` | 4 | Shared rows and canvas on the proxy workspace |
| `ApplicationLibrary/Views/Connections/**` | 3 | List grouping and shared row rhythm |
| `ApplicationLibrary/Views/Terminal/**` | 2 | Shared chrome / picker mark |
| `ApplicationLibrary/Views/Log/` | 1 | Native log on the shared surface |
| `ApplicationLibrary/Views/RemoteControl/` | 1 | Shared empty presentation |
| `ApplicationLibrary/Views/NavigationPage.swift` | 1 | Hako vocabulary + `subtitle` |
| `ApplicationLibrary/Views/EnvironmentValues.swift` | 1 | `hakoCompactRows` compact-row metric |
| `MacLibrary/` | 2 | macOS shell and sidebar on the shared tokens |

The remaining Hako-modified files are the supporting model / reporting layers in §5.3.

### 5.3 Supporting model / reporting changes

* `Library/Shared/Variant.swift` — **+52 lines, additive only.** Screenshot-fixture states
  (`SCREENSHOT_APPEARANCE`, `SCREENSHOT_STATE`, `screenshotRemoteControl`, …). No existing
  member changed.
* `Library/Shared/{OOMReportArchive,OOMReportManager,PowerReportArchive,PowerReportManager}.swift`
  and `Library/Shared/{CrashReportArchive,CrashReportManager}.swift` — writers/presentation
  so the Hako report pages have data.
* `Library/Database/{Database,Profile,Profile+Update,ProfileManager}.swift` — Hako subscription
  metadata columns + migration.
* `Library/Network/{HTTPClient,CommandClient,ExtensionProfile,ExtensionPlatformInterface}.swift` —
  Hako fetch/presentation support.

### 5.4 Build configuration — verified, not guessed

* `sing-box.xcodeproj/project.pbxproj` — **verified.** The only Hako change is
  `IPHONEOS_DEPLOYMENT_TARGET` `15.0` → `16.0`, introduced by commit `82bf1ce`
  ("build: the iOS minimum is 16.0, not 15.0"). 10 insertions, 6 deletions. **No UI, no target
  membership, no resource or file-reference changes.**
* `Localizable.xcstrings` — **verified.** Hako's catalog holds 696 keys vs 510 at `2b1763a`:
  * **+202** keys added,
  * **16** keys removed,
  * only **2** existing translations changed: `Goroutines` (→ `Goroutine`) and `Releases`
    (→ `版本发布`). Both match the `fix(i18n)` / `docs(i18n)` commits.

  All **16** removed keys are the old `PacketTunnelView` long-form documentation strings
  (`enforceRoutes`, `includeAllNetworks`, `excludeAPNs`, `excludeCellularServices`,
  `excludeLocalNetworks`, `excludeDeviceCommunication`, `No documentation.`,
  `Please grant the permission for **SFMExtension**…`, `Clash Mode`,
  `Ghostty Configuration`, and the multi-paragraph `If this property is true…` blocks).
  They are **orphaned, not lost**: `PacketTunnelView.swift` was rewritten by Hako (158
  insertions / 80 deletions) to use its own capitalised labels — `Include All Networks`,
  `Enforce Routes`, `Exclude APNs`, `Exclude Cellular Services`, `Exclude Local Networks`,
  `Exclude Device Communication` — each of which **is present** in Hako's catalog. The
  toggles themselves still exist and still bind the same `SharedPreferences` keys; only the
  prose-style help strings and two orphaned entries (`Clash Mode`, `Ghostty Configuration`,
  no longer referenced anywhere) were dropped. No setting was deleted.

  The large line churn (12 052 / 9 082) is Xcode re-serialisation, not semantic change.

### 5.5 The 42-file conflict zone

These are the files a future upstream merge will actually fight over — changed by Hako
**and** independently by upstream after `2b1763a`:

```
ApplicationLibrary/Views/Abstract/FormItem.swift
ApplicationLibrary/Views/Abstract/GlobalChecksModifier.swift
ApplicationLibrary/Views/Abstract/ViewModifiers.swift
ApplicationLibrary/Views/Connections/ConnectionListView.swift
ApplicationLibrary/Views/Dashboard/Cards/DashboardCard.swift
ApplicationLibrary/Views/Dashboard/Cards/DashboardCardView.swift
ApplicationLibrary/Views/Dashboard/Cards/HTTPProxyCard.swift
ApplicationLibrary/Views/Dashboard/Cards/ProfileCard.swift
ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift
ApplicationLibrary/Views/Dashboard/Components/StartStopButton.swift
ApplicationLibrary/Views/Dashboard/DashboardView.swift
ApplicationLibrary/Views/Dashboard/Overview/OverviewView.swift
ApplicationLibrary/Views/Dashboard/RemoteDashboardView.swift
ApplicationLibrary/Views/EnvironmentValues.swift
ApplicationLibrary/Views/Groups/GroupView.swift
ApplicationLibrary/Views/Log/LogView.swift
ApplicationLibrary/Views/NavigationPage.swift
ApplicationLibrary/Views/Profile/NewProfileMenuView.swift
ApplicationLibrary/Views/Setting/GhosttyConfigurationView.swift
ApplicationLibrary/Views/Setting/OnDemandRulesView.swift
ApplicationLibrary/Views/Setting/PacketTunnelView.swift
ApplicationLibrary/Views/Setting/SettingView.swift
ApplicationLibrary/Views/Setting/SponsorsView.swift
ApplicationLibrary/Views/Terminal/TerminalSessionContentView.swift
ApplicationLibrary/Views/Tools/CrashReportListView.swift
ApplicationLibrary/Views/Tools/NetworkQualityView.swift
ApplicationLibrary/Views/Tools/ReportShared.swift
ApplicationLibrary/Views/Tools/STUNTestView.swift
ApplicationLibrary/Views/Tools/TaildropView.swift
ApplicationLibrary/Views/Tools/TailscaleSSHPromptView.swift
ApplicationLibrary/Views/Tools/ToolsView.swift
Library/Network/CommandClient.swift
Library/Network/ExtensionEnvironments.swift
Library/Network/ExtensionPlatformInterface.swift
Library/Network/ExtensionProfile.swift
Library/Shared/CrashReportArchive.swift
Library/Shared/CrashReportManager.swift
Localizable.xcstrings
MacLibrary/MainView.swift
MacLibrary/SidebarView.swift
SFI/MainView.swift
sing-box.xcodeproj/project.pbxproj
```

---

## 6. `SFI/MainView.swift` — the primary integration boundary

| Ref | Lines | Blob |
| --- | --- | --- |
| `2b1763a` (fork point) | 430 | `c896546f` |
| `hako-ui` | **368** | `a92992b8` |
| `origin/dev` | 576 | `ae10d3e5` |
| `upstream/dev` | 576 | `ae10d3e5` |

Upstream's `MainView` owns the entire root presentation: a `TabView` over every
`NavigationPage`, an `adaptiveTabViewContent` using `.tabViewStyle(.sidebarAdaptable)`, a
`NavigationSplitView` hosting `SidebarView`, a `TabBarPlacementReader`, the bottom
`accessoryInset` (runtime pill / FAB / remote-control pill) with `AccessoryHeightKey`, and
`AccessoryInset`/`FABStartButton`/`StatusText`/`BarItemButtonStyle`.

Hako **removed all of that** and replaced it with:

* `HakoPrimaryShell(selection:toolsBadge:)` driving three first-level destinations
  (Home / Tools / More) instead of one tab per `NavigationPage`;
* a `RemoteControlChipModifier` that moves remote control from a floating pill into the
  navigation-bar toolbar;
* `pendingSettingsPage` so a settings notification survives the tab switch;
* `hakoInlineNavigationTitle()` instead of system large titles;
* `HakoUITrace` instrumentation on status transitions and navigation;
* `applyScreenshotFixture()` extending `SCREENSHOT_PAGE` to sheets and settings sub-pages;
* `.environment(\.hakoHomeActions, …)` and `.environment(\.pendingSettingsPage, …)` wiring.

Classification:

```
SFI/MainView.swift = UPSTREAM ROOT FILE + HAKO INTEGRATION = HIGH CONFLICT AREA
```

The same file also carries the fork's `dev` lineage differently (576 lines there), so this
one file has **three** independent versions. It is the single most dangerous file in the
repository.

**This round made no attempt to resolve it.** The future direction — `iPhone → Hako UI`,
`iPad → upstream adaptive UI` — would be implemented here, but that is a separate project.

---

## 7. UPSTREAM_ADDED_AFTER_FORK_POINT, NEVER_MERGED_BY_HAKO

> Correction to a natural first guess. These files are **not** "upstream files that Hako
> deleted or bypassed". They did not exist at the fork point `2b1763a`; upstream added them
> afterwards, and `hako-ui` simply never merged those commits. Calling them *deleted* would
> wrongly imply Hako removed them and could be restored from Hako's history — it cannot.

| File | Upstream commit that added it | Purpose |
| --- | --- | --- |
| `ApplicationLibrary/Views/SidebarView.swift` | `3131ed6` Adapt layout for iPad | iPad sidebar |
| `ApplicationLibrary/Views/Abstract/SidebarLayout.swift` | `3131ed6` Adapt layout for iPad | iPad sidebar geometry |
| `ApplicationLibrary/Views/Dashboard/Components/RuntimeDurationText.swift` | — | Runtime duration display |
| `ApplicationLibrary/Views/Terminal/TerminalCommands.swift` | — | Terminal commands |
| `ApplicationLibrary/Views/Terminal/TerminalPresentation.swift` | — | Terminal presentation |
| `Library/Network/ScreenStateObserver.swift` | `f8ad6d0` Observe screen state in the extension | Extension screen-state observation |
| `Library/Shared/HangReport.swift` | `3bcb8ca` Report main thread hangs as crash reports | Hang reporting |
| `Library/Shared/HangWatchdog.swift` | `3bcb8ca` Report main thread hangs as crash reports | Hang watchdog |
| `Library/Shared/PlatformMetadata.swift` | `e8ab4f4` Report platform and network extension settings in metadata | Platform metadata |

**That is 9 regular files.** These 9 plus the `Frameworks/Runestone` gitlink (§3.3) are the
10 entries in the `OTHER` bucket. This table intentionally lists only the files; the gitlink
is not an upstream addition — it is identical in all three refs.

This set is exactly why the iPad story is unfinished: **the upstream iPad adaptation
(`3131ed6`) has never reached `hako-ui`.** It is the material to merge when the
`iPhone = Hako UI / iPad = upstream adaptive UI` split is built. **Nothing was restored or
deleted in this round.**

## 7b. `HAKO_DELETED` — 1 file

| File | Why |
| --- | --- |
| `ApplicationLibrary/Views/Dashboard/Components/InstallProfileButton.swift` | Existed at `2b1763a`, removed by Hako. The home page offers the install flow itself (`3af99d3` "the install flow takes the screen once"), so the standalone button was replaced. |

No other file was deleted by Hako.

---

## 8. High-risk integration points

Analysis only — nothing changed.

| Path | Why mixed | Why dangerous | Future isolation direction |
| --- | --- | --- | --- |
| `SFI/MainView.swift` | Upstream root + Hako shell + env wiring + navigation bridge; 3 independent versions | Any edit risks the frozen iPhone UI; the root owns tab order, titles, toolbar, sheets, deep links, screenshot fixture | Introduce a platform/idiom branch (`iPhone → HakoPrimaryShell`, `iPad → upstream adaptive`) *behind* the existing `Variant` seam. Do it once, deliberately, with the UI tests as the gate. |
| `ApplicationLibrary/Views/NavigationPage.swift` | Upstream enum + Hako vocabulary + new `subtitle` | Renaming titles is user-visible; any future upstream rename collides | Keep the enum upstream; express Hako naming as a presentation mapping applied at the shell boundary. |
| `ApplicationLibrary/Views/EnvironmentValues.swift` | Upstream env + Hako `hakoCompactRows` | Density propagates into every row; a default flip silently changes many pages | Move Hako-only keys into a Hako-prefixed file; keep upstream keys untouched. |
| `sing-box.xcodeproj/project.pbxproj` | iOS 15→16 target, single-purpose | Xcode rewrites the file wholesale; merge conflicts here are noisy and easy to mis-resolve | Leave as-is. Never hand-edit; always change via Xcode. |
| `Localizable.xcstrings` | +202 keys, 2 changed translations, heavy re-serialisation | Structural churn makes semantic diffs nearly invisible; snapshot baselines depend on strings | Keep translations semantic (as done here); never reformat the catalog by hand. |
| `ApplicationLibrary/Views/HakoStyle/*` | 100% Hako | The frozen UI itself | None needed. Treat as read-only. |
| `SFIUITests/Hako*UITests.swift` + `scripts/dev/check-hako-primary-route.*` | Test/tooling guards | If these rot, the freeze loses its enforcement | Keep green; never regenerate snapshot baselines to make a change "pass". |

---

## 9. Branch audit

`ahead`/`behind` are relative to the fork's own refs and to `upstream/*` where a counterpart
exists. The fork has **no GitHub Actions workflows, no tags, and no pull requests** (open or
closed), so no CI or PR references any branch.

| Branch | Role | HEAD SHA | Relation | Unique commits | References | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| `hako-ui` | Hako product branch | `fc7f77b` | Forked at `2b1763a`; 80 Hako commits | 80 | Parent submodule gitlink (`5911580`); `scripts/ci/apple-client-source.sh`; `.github/workflows/client-apple.yml`; `scripts/ci/check-apple-source-selection.sh`; `apple-libbox-artifact.sh` | **KEEP** |
| `dev` | Upstream dev channel + fork platform work; fork default branch | `d1224bb` | 3 ahead / 11 behind `upstream/dev`; ancestor of nothing else | 3 (`2070ae1`, `e3edd71`, `d1224bb`) | Default branch; `scripts/ci/apple-client-source.sh` (`macOS` source); `apple-libbox-artifact.sh` | **KEEP** |
| `main` | Upstream release channel | `ab33c3f` | 8 behind `upstream/main`; exact ancestor of `origin/dev` | 0 | — | **KEEP** |
| `stable` | Upstream stable channel | `0b84ea4` | Identical to `upstream/stable` | 0 | — | **KEEP** |
| `wip` | Historical upstream branch | `b3714ed` | Identical to `upstream/wip`; full ancestor of `dev`, `main`, `stable`, **and** `hako-ui` | **0** | None | **DELETED_SAFE → DELETED** (see §9.2) |

### 9.1 Branches explicitly retained

`hako-ui` and `dev` are load-bearing (product branch and upstream development baseline
respectively). `main` and `stable` are **KEEP** despite being fully contained in
`dev`/upstream history: they are upstream channel mirrors, and "`dev` is ahead of `main`" is
not a reason to delete a release channel.

### 9.2 Branch actually deleted

| Branch | Old HEAD SHA | Reason | Why history remains reachable |
| --- | --- | --- | --- |
| `Piggy-Cat-bit-shadow/sing-box-for-apple` `wip` | `b3714ed957cb1505600943ca2bc15db9ef7a3222` | Byte-identical to `upstream/wip`; zero unique commits; ancestor of every maintained branch; referenced by nothing. | `b3714ed` is an ancestor of `dev`, `main`, `stable`, and `hako-ui` (all confirmed with `git merge-base --is-ancestor`), and SagerNet still hosts `upstream/wip` at the same SHA. No object is lost. |

Only the **fork's** copy was deleted. SagerNet's `wip` was not touched. No backup branch
(`wip-backup`, `backup-wip`, `old-wip`, `archive-wip`) was created — the SHA above plus
upstream's own copy is the record.

### 9.3 Why `wip` was safe to delete

Checklist from the brief, each verified before deletion:

1. **Unique commits:** `git rev-list --count origin/wip..origin/wip` → n/a; `origin/wip`
   and `upstream/wip` are the *same object* (`b3714ed`), so unique commits = **0**.
2. **GitHub Actions workflow reference:** none — the fork has **zero** workflows.
3. **Shell/script reference:** `grep -rnw wip` across `.github`, `scripts`, `Makefile` in
   both the Apple repo and the parent repo → **no matches**.
4. **Submodule operation reference:** the parent's `.gitmodules` and `submodule.*` config
   reference only URLs (`Piggy-Cat-bit-shadow/sing-box-for-apple.git`), never a branch. The
   parent pins the Apple submodule by **gitlink SHA**, so no branch name is involved.
5. **PR reference:** no PRs exist at all on the fork.
6. **Default branch:** `dev` (confirmed via `origin/HEAD` and the GitHub API). Not `wip`.
7. **Unrecoverable objects:** `b3714ed` is fully reachable from `dev`, `main`, `stable`, and
   `hako-ui`, and is byte-identical to `upstream/wip`, which SagerNet still hosts.

All seven checks passed before the deletion was issued.

---

## 10. Source-integrity proof

| Check | Result |
| --- | --- |
| Starting `hako-ui` SHA | `fc7f77b82a7ca432294addfa001fcacfd5776223` |
| Ending `hako-ui` SHA | `fc7f77b82a7ca432294addfa001fcacfd5776223` (**unchanged**) |
| Swift runtime source changed | **NO** |
| `ApplicationLibrary/Views/HakoStyle/*` changed | **NO** |
| `SFI/MainView.swift` changed | **NO** |
| `ApplicationLibrary/Views/NavigationPage.swift` changed | **NO** |
| Hako UI tests changed | **NO** |
| Xcode project changed | **NO** |
| Assets / localization changed | **NO** |
| Parent `clients/apple` gitlink changed | **NO** (still `5911580`) |
| Snapshot baselines regenerated | **NO** |

The only additions in this round are this document and the `docs/` directory. The only
mutations are Git branch metadata (§9.2).

### 10.1 Known divergences recorded, deliberately not acted on

1. **Local `hako-ui` (`fc7f77b`) is 1 commit ahead of `origin/hako-ui` (`5911580`).** The
   parent gitlink pins `5911580`, so the parent is *not* pinning the local HEAD. Not pushed,
   not rebased, not reset — recorded only.
2. **`hako-ui` lacks the fork's 3 `dev` commits** (56 files of helper-XPC /
   platform-auto-redirect / version work). Merging them is a separate decision.
3. **`hako-ui` lacks the upstream iPad adaptation `3131ed6`** and other post-fork upstream
   work. Not synced — upstream sync is explicitly out of scope this round.
4. **Deleted:** fork branch `wip` @ `b3714ed` (§9.2). Nothing else was deleted, and no
   runtime, project, asset, localization, or test file was touched.

---

## 11b. PRODUCT_BRANDING — the cross-platform fork overlay

`PRODUCT_BRANDING` is deliberately **not** a kind of Hako ownership. The two have opposite reach:

```
Hako presentation   -> iPhone only
Jiejiebox branding  -> iPhone + iPad + macOS
```

Conflating them is dangerous in both directions: treating branding as "Hako UI" would lose it on
iPad and macOS, and treating Hako UI as branding would push the Hako shell onto platforms that must
stay upstream.

### 11b.1 Branding commits in history

**There are none.** This is a finding, not an omission:

```bash
git log -S'Jiejiebox' --all --oneline   # -> empty
git grep -i jiejiebox                    # -> no tracked file contains it
```

`Jiejiebox` has never existed in this repository or anywhere in its history, on any branch. The
display name was upstream's `sing-box` everywhere, and Hako never touched it either:

```bash
git diff 2b1763a hako-ui -- sing-box.xcodeproj/project.pbxproj | grep -iE 'CFBundle|PRODUCT_NAME'
# -> empty: Hako changed the deployment target, not the name
```

So there was no historic branding change to restore or preserve. The branding overlay is
**introduced by this work**, in commit `docs/ipad`-series on `ipad-upstream-ui`.

### 11b.2 Where the displayed name actually comes from

Not from any `Info.plist` file — every one of them omits both `CFBundleDisplayName` and
`CFBundleName`. It comes from the Xcode build setting `INFOPLIST_KEY_CFBundleDisplayName`, which is
synthesised into the generated `Info.plist` because `GENERATE_INFOPLIST_FILE = YES`.

The name is set in **12 places**, one per app/extension target's Debug and Release configuration:

| Lines | Target | Era | Value |
| --- | --- | --- | --- |
| 3108, 3152 | `SFI` | iOS app (**iPhone + iPad**) | **`Jiejiebox`** |
| 3198, 3237 | `SFM` | macOS app | **`Jiejiebox`** |
| 2683, 2719 | `SFT` | tvOS app | `sing-box` (out of scope) |
| 3383, 3431 | `SFM.System` | macOS system extension | `SFMExtension` |
| 3473, 3515 | `SystemExtension` | system extension | `sing-box` |
| 3626, 3665 | `ShareExtension` | share extension | `sing-box` |
| 3781, 3817 | `ShareExtension.System` | share extension | `sing-box` |
| 2191, 2232 | `Extension` | network extension | `Extension` |
| 2484, 2523 | `IntentsExtension` | intents | `IntentsExtension` |
| 2614, 2647 | `FileProviderExtension` | file provider | `FileProviderExtension` |
| 2753, 2789 | `TVExtension` | tvOS extension | `TVExtension` |
| 2828, 2859 | `WidgetExtension` | widget | `WidgetExtension` |

**Only 4 lines changed** (SFI Debug/Release + SFM Debug/Release). Extensions are not apps and keep
their upstream names.

`SFI` alone covers iPhone *and* iPad — `TARGETED_DEVICE_FAMILY = "1,2"` — so one product serves both
and they cannot disagree.

### 11b.3 Deliberately NOT changed

| Setting | Value | Why |
| --- | --- | --- |
| `PRODUCT_NAME` | `sing-box` | Renaming it changes the `.app` filename and build outputs, which the parent repo's CI scripts consume. Display name and product name are `CFBundleDisplayName` vs `CFBundleName` and are independent; only the displayed one was in scope. |
| `PRODUCT_BUNDLE_IDENTIFIER` | `io.nekohasekai.sfamt` | Never change — signing, App Groups and the parent build all depend on it. |
| `Variant.applicationName` | `SFI` / `SFM` / `SFT` | Internal identifier, not a display name. It feeds the HTTP `User-Agent`, the VPN profile's `localizedDescription` and Siri intent phrases. Renaming it would change what servers see and what the system VPN list shows — a behavioural change, not branding. |
| Target / scheme / module / directory names | `SFI`, `SFM`, … | Internal. Renaming creates Xcode churn for no user-visible gain. |
| `sing-box` as a *project* name in prose ("sing-box version", "sing-box documentation") | unchanged | Those refer to the kernel/project, not the app. They must not be rebranded. |

### 11b.4 Upstream-sync rule for branding

Branding will conflict on every upstream sync, because upstream owns line 3108/3152/3198/3237 and
will keep writing `sing-box` there. The standing rule:

> On an upstream merge, **UI/layout/navigation: upstream wins on iPad/macOS. App display name:
> `Jiejiebox` wins on all three.** Never restore the app name to `sing-box` while restoring
> upstream UI.

---

## 11c. Summary

### Ownership model

The model is deliberately **not** "everything the fork changed is Hako". Each class answers a
different question — who owns the pixels, who owns the name, and who merely shipped the feature:

```
PURE_UPSTREAM ...................... 315 untouched + 53 upstream-drift-only paths
UPSTREAM_DRIFT ..................... same 53, seen from the fork's side
HAKO_IPHONE_PRESENTATION ........... 45 added (11 HakoStyle, 4 network/database, 2 UITests,
                                     24 test pkg, 4 scripts) + Hako's edits inside the 44
UPSTREAM_MODIFIED_FOR_HAKO_IPHONE .. 44 modified + 42 conflict-zone
HAKO_GLUE / INTEGRATION_BOUNDARY ... SFI/MainView.swift, MacLibrary/MainView.swift,
                                     EnvironmentValues.swift, NavigationPage.swift,
                                     NavigationSheetContent.swift, ExtensionEnvironments.swift
PRODUCT_BRANDING ................... 4 build-setting lines; iPhone + iPad + macOS; §11b
FORK_PLATFORM_FEATURE .............. the 3 fork `dev` commits (helper XPC, platform auto
                                     redirect, version bump) — not Hako, not upstream
TEST_TOOLING ....................... SFIUITests/Hako*UITests.swift, Tests/HakoSubscriptionUsage/,
                                     scripts/dev/check-hako-primary-route.{sh,swift},
                                     scripts/link-test-sources.sh,
                                     scripts/run-subscription-usage-tests.sh,
                                     scripts/dev/check-iphone-hako-freeze.sh
UPSTREAM_ADDED_AFTER_FORK_POINT .... 9 files, never merged by Hako (incl. iPad adaptation)
HAKO_DELETED ....................... 1 file (InstallProfileButton.swift)
UNKNOWN / NEEDS_FUTURE_AUDIT ....... none — all 510 union paths classified
                                     (509 regular files + 1 unchanging gitlink; see §3.1–§3.3)
```

The distinction that matters most:

```
HAKO_IPHONE_PRESENTATION  ->  iPhone only
PRODUCT_BRANDING          ->  iPhone + iPad + macOS
```

### Branch cleanup outcome

```
KEEP ................. hako-ui, ipad-upstream-ui, dev, main, stable
DELETED ............... wip (fork only) @ b3714ed957cb1505600943ca2bc15db9ef7a3222
```

### The one thing to remember

`hako-ui` is **not** "upstream plus a Hako folder". It is upstream at `2b1763a` plus 80 Hako
commits that reach into 86 upstream files, of which **42 are fresh conflict material** against
current upstream. The `HakoStyle/` directory is only **11 of the 45 files Hako added** and a
small fraction of Hako's actual footprint. The real boundary is `SFI/MainView.swift`.

**The validated iPhone experience is frozen** — and only that. iPad and macOS presentation belongs
to upstream; where a Hako edit stands in the way, isolate the Hako behaviour rather than fork the
presentation. Product branding is a separate, cross-platform overlay in which `Jiejiebox` wins on
all three. If tidying the tree and preserving the current iPhone UI ever conflict, the UI wins.
