# iPhone UI behaviour closure — 2026-11-07

What this round changed on the phone surface, why, and what is still only arguable without a
device. It is the report for commit `c5d92c2`; the code it describes is `HakoHomeView`,
`HakoClashModeLayout`, `HakoProfileSwitchQueue` and the two gates named in §E.

**Xcode/iOS compilation was not verified (Windows host, no Xcode). iPhone behaviour was not
verified (no device).** Every claim below is marked with the level it actually reached.

---

## A. Identity and boundaries

| Field | Value | How checked |
|---|---|---|
| Repository | `Piggy-Cat-bit-shadow/sing-box-for-apple` | `git remote -v` |
| Worktree | `IOS客户端/_work/main-fix` (linked worktree of `IOS客户端/sing-box-for-apple`) | `git worktree list` |
| Branch | `main` — the product branch; no new branch was created. The work moved from the `_work/main-fix` worktree into the primary checkout during the branch cleanup (§H) | `git branch -vv` |
| Start SHA | `e8c08744a001767e20bc2f75d935e65e6901ff8c`, working tree clean | `git status --short` (0 entries) |
| End SHA | `c5d92c2` (the fix), `563bc4b` (the secondary pages), `3160100` (this report), `d968800` (merge of `origin/main`), `eb8a8ac` (merge of the self-sign line), `da87fa4` (localization) | `git log --oneline` |
| `origin/main` | `3aedd74`, merged in during the cleanup; `main` is now ahead of it and behind by nothing | `git log --oneline main..origin/main` (empty) |
| Upstream reference | pin `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85`; local `upstream/dev` has moved to `0d1b59f` | `git rev-parse upstream/dev` |
| Kernel (read-only) | `JiejieBox` `testing` @ `fc7e400243d46a451b2dffbe68cb5a3147c66289` | `git -C _p01_main rev-parse HEAD` |

Two deliberate non-actions:

* **`origin/main` was not merged while the UI work was being written** — its one commit is the
  network layer, and folding a non-UI change into a UI commit would blur both. It was merged
  afterwards, as its own commit, once the UI work was closed (`d968800`, §H).
* **The kernel was not entered.** `_p01_main` carries 12 pre-existing modified/untracked entries
  (`KNOWLEDGE/*`, `clients/android` gitlink); they are not this round's and were left exactly as
  found. `git -C _p01_main ls-tree HEAD clients/apple` reports the gitlink at
  `ab575dace8190a48a9d7cf666ef009f803e6ca62` — see §G for the source drift this exposes.

### What the commit touched

```
A  ApplicationLibrary/Views/HakoStyle/HakoClashModeLayout.swift
M  ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift
A  ApplicationLibrary/Views/HakoStyle/HakoProfileSwitchQueue.swift
M  README.md
M  SFI/HakoPhoneRootView.swift
M  scripts/dev/check_compact_mode_picker.py
A  scripts/dev/check_hako_profile_switch.py
A  scripts/dev/test_hako_ui_gates.py
```

Nothing under `Library/Network/`, `Extension*/`, `SystemExtension/`, `TVExtension/`,
`Frameworks/`, `sing-box.xcodeproj/`, no entitlement, plist, App Group, bundle identifier,
`source-lock.json` or Libbox reference. The kernel repository has no diff attributable to this
round. `VERIFIED_GIT`.

A second commit carries the two secondary pages this sweep found (`HakoPacketTunnelView`,
`HakoOnDemandRulesView`), the new platform-symbol gate, and the extended mutation suite. Same rule:
both files are phone-only Hako presentation.

---

## B. Findings, root cause and fix

| ID | Severity | What the reader saw | Hako file / line | Official counterpart | Root cause | Fix | Evidence |
|---|---|---|---|---|---|---|---|
| **F-1** | P0 | Choosing a configuration in Profiles closed the sheet and the page redrew, but the tunnel kept serving the previous configuration; after a relaunch the old choice was back | `HakoHomeView.swift:341` (`profileSelection`), `:365` (`selectProfile`), sheet call at `:288` | `OverviewView.swift:105-116` passes a `Binding(get:set:)` into `ProfileCard` → `ProfilePickerSheet`; `OverviewViewModel.swift:10-22` does persist + broadcast + reload | The centre was handed `$dashboard.selectedProfileID`, a plain `@Published` field. Its four `onSelect` sites assigned that field and dismissed — no `SharedPreferences` write, no `selectedProfileUpdate`, no `reloadService` | The sheet is handed a `Binding(get:set:)` whose setter calls the existing `OverviewViewModel.switchProfile`; the page's own `selectedProfileID` stays written only by `updateSelectedProfile` | `VERIFIED_SOURCE` + `VERIFIED_UNIT` (gate compiles the dispatch) |
| **F-2** | P0 | Three modes the configuration defines itself (`Proxy/Block/Auto`, `代理/直连/拦截`) drew as a three-row list instead of the one-row thirds control | `HakoHomeView.swift:781` (`modeSection`), `:785` | `ClashModeCard.swift:101-131` draws a tab bar for whatever list the core sends | The shape was decided by `conventionalModes(in:)`, which returned non-`nil` only for exactly `rule`/`global`/`direct` (case-insensitive). `clash_mode` is not a closed set: the core derives the list from the reader's own rules | `HakoClashModeLayout.shape(titles:)`: 2–3 modes whose names fit the thirds get the row; every other list gets the list; no list is ever shortened; identifiers and the string sent back are the core's own | `VERIFIED_UNIT` (10 cases) + `VERIFIED_SOURCE` |
| **F-3** | P1 | A mode the core reported did not repaint the row; worse, the mode list itself was read through the nested observable, so a configuration switch could leave the previous configuration's modes on screen | `HakoHomeView.swift:236` and `:241` (the two subscriptions) | `ClashModeCard.swift:6` takes `@EnvironmentObject private var commandClient: CommandClient` — a *direct* environment object, which is the observation | `commandClient` is a `@Published` property of `ExtensionEnvironments`; changes inside it do not publish on the parent. `onChangeCompat(of: environments.commandClient.clashMode)` could therefore never fire, and `body` read `clashModeList` through the same path | `modeList` / `confirmedMode` / `localMode` are mirrored from `$clashModeList` and `$clashMode`; `modeSection` and `selectClashMode` read the mirror | `VERIFIED_SOURCE` + gate assertion |
| **F-4** | P1 | A failed configuration switch reported nothing at all; on the root, a failed profile import reported nothing | `HakoHomeView.swift:311` (`pageAlert`), `SFI/HakoPhoneRootView.swift:294` | — (upstream has no phone root) | Two `.alert` modifiers on one view are **one** presentation and the outer one wins. Home stacked `$coordinator.alert` inside `$alert`; the root stacked `$alert` inside `$dashboard.alert`. Both inner bindings were unreachable | Both views present one `Binding<AlertState?>` that folds their two sources and clears both on dismissal | `VERIFIED_SOURCE` + gate assertion (and both mutants are caught) |
| **F-5** | P1 | Two quick taps could apply the older choice last, and `reasserting` dropped between two queued switches | `HakoHomeView.swift:365`; `HakoProfileSwitchQueue.swift:69,84` | `OverviewViewModel.switchProfile` sets `reasserting = false` as its **last line** (`:21`) | Nothing serialised the async switch. Each call spawned its own task; the gate was raised by the caller and cleared by whichever call finished | `HakoProfileSwitchQueue`: one pending slot, one drainer. The last accepted choice is the one applied; the gate is raised **per switch**, which is what the official method's own reset requires | `VERIFIED_UNIT` (6 cases) — F-5 was found by this gate against my first version and fixed before the commit |
| **F-6** | P2 | — (same as F-3's second half) | — | — | — | — | — |
| **F-7** | P0 (tvOS build) | none on iPhone — the tvOS slice of `ApplicationLibrary` would not compile | `HakoPacketTunnelView.swift` (12 use sites) | `Setting/PacketTunnelView.swift` wraps the same six toggles and reads in `#if !os(tvOS)` | The page was generated by `migrate_secondary_page.py`, which resolves `#if` for iOS and keeps one arm. The six `SharedPreferences` members it writes are declared inside `#if !os(tvOS)` (`SharedPreferences.swift:31-39`), so the port lost the condition the original had | The two sections and `loadSettings` are wrapped in `#if !os(tvOS)`, matching the original | `VERIFIED_SOURCE` + new gate `check_hako_platform_symbols.py` |
| **F-8** | P1 | Tunnel routing switches seem to do nothing until the app itself next starts the tunnel — a system-initiated (On Demand / Always On) start keeps the old values | `HakoPacketTunnelView.swift` `applySettings()` | `Setting/PacketTunnelView.swift:112-129` calls `updateProtocolConfiguration()` when not connected | The copy had `restartService()` with `guard … isConnected else { return }`, so with the tunnel down the page persisted the preference and wrote nothing to the `NETunnelProviderProtocol`; the system reads that protocol, not the preference | `applySettings()` restores upstream's two branches, reporting the write failure through the page's alert | `VERIFIED_SOURCE` |
| **F-9** | P1 | Turning On Demand **off** while the tunnel is down wrote nothing to the system; **Reset** re-enabled On Demand in the system config while the page then displayed "Disabled" | `HakoOnDemandRulesView.swift` `updateService(_:)`, `saveMode`, `resetSection` | `Setting/OnDemandRulesView.swift:326-344` passes the mode and guards `newMode == .disabled \|\| isConnected` | `updateService()` read `self.mode` and guarded on `isConnected` alone. Reset does not change `mode` first, so the call after `resetOnDemandRules()` re-applied the previous mode to the system — `isOnDemandEnabled = true` over preferences that now say disabled, and the reloaded page shows Disabled | `updateService(_ newMode:)` takes the mode; reset passes `.disabled`; the guard restores upstream's disabling half | `VERIFIED_SOURCE` |
| **F-10** | P2 (57 strings) | 57 strings in the phone UI rendered English (or Chinese) in every language: every empty state on Proxies / Activity / Logs / the report pages, the On-Demand rule editor's captions, the Back/Clear/Selected/Working… chrome, the Tunnel and Profile Override explanations, and the "no shared container" state | `HakoScaffold`, `HakoRow`, `HakoData`, `HakoEmptyState`, `HakoHomeView`, `HakoConnectionListView`, `HakoOnDemandRulesView`, `HakoTailscaleSSHPromptView`, `HakoStartStopButton`, `HakoPacketTunnelView`, `HakoProfileOverrideView`, `HakoLogView`, `SFI/HakoPhoneRootView` | — (the catalog is the counterpart) | The gate that exists for exactly this could not see them: it matched no file on Windows, its literal extractor was off by one so only `String(localized:)` was checked, it compared escapes raw, and it never looked at labelled arguments (`explanation:`, `footnote:`, `title:`, `message:`, `subtitle:`) at all. The literals are catalog *keys*, so a miss is silent by design | Gate fixed (four defects) and 57 keys added with zh-Hans; `HakoLogView`'s new state now uses English keys with the Chinese in the catalog | `VERIFIED_STATIC` + mutation case |
| **F-11** | P1 | A configuration whose only live service is a **USB/IP server** shows no Endpoints card at all on Tools, so the USB/IP page is unreachable | `HakoToolsView.swift` `endpointSection` (the `if` at the top of the card) | `Tools/ToolsView.swift:109` gives USB/IP its own section gated on `!usbipViewModel.servers.isEmpty` | The reference put the USB/IP rows inside the Endpoints card, and the port's gate listed only the three *endpoint* arrays — so the rows rendered from `usbipViewModel.servers` were nested under a condition that never mentions them | The gate now includes `!usbipViewModel.servers.isEmpty`: same card, same rows, one condition — no visual or information-architecture change | `VERIFIED_SOURCE` (compared line by line with upstream's gate) |
| **F-12** | P2 | A failed read of the remote-control server list hid the whole card, looking exactly like "there are none" | `HakoMacAppView.swift` `reloadRemoteServers()`, `HakoLogView.swift` `reloadRemoteServers()` | `HakoRemoteControlView.reload()` reports the same failure through an alert | `remoteServers = await (try? RemoteServerManager.list()) ?? []` — a silent `try?` on the value that decides whether the card is drawn, and on the Logs page on the value that decides which servers the menu offers | Both reads now report the failure through the page's existing alert; the list is cleared only on failure, not flattened into a fake empty success | `VERIFIED_SOURCE` |
| **F-13** | P2 | "Go Crash" / "Native Crash" in the crash-report menu could do nothing at all, with no explanation | `HakoCrashReportListView.swift` `NetworkExtensionCrashMenu`, and `HakoOOMReportListView.triggerOOMReport` | — (the fix follows the OOM page's `AlertState(action:error:)` shape) | `LibboxNewStandaloneCommandClient()` returns an **Optional**, and both buttons were `try? LibboxNewStandaloneCommandClient()?.trigger…()`. An optional chain over **nil does not throw — it skips the call**, so "no command channel" and "a crash ran and produced no report" were the same thing to the reader. The OOM trigger had the identical hole behind its own `do/catch` | Both now `guard let` the client and report the nil answer with the catalog's existing "Status Channel Unavailable" key; thrown errors keep the `AlertState(action:error:)` shape. New gate `check_hako_command_channel.py` forbids the optional-chained form | `VERIFIED_SOURCE` + mutation case |

### Found and **not** fixed: the shared cards now depend on Hako types

`audit_apple_ui_boundary.py --strict` fails `shared-pages-are-clean` and
`no-reverse-dependency` on three files that are not Hako files:

```
ApplicationLibrary/Views/Abstract/ViewModifiers.swift:209      (comment only)
ApplicationLibrary/Views/Dashboard/Cards/DashboardCardView.swift:45-46   HakoCardSurface(...), HakoProductPalette.system.card
ApplicationLibrary/Views/Dashboard/Cards/HTTPProxyCard.swift:67-70       the same
```

This is pre-existing — introduced by `54e9a5c fix(ui): align dashboard card tone …` and
`0c13cf7 fix(apple): scope Hako HTTP proxy styling to iPhone home`, both already on `e8c0874` — not
caused by this round, and it is a real violation of invariant 2: `DashboardCardView` is compiled
into the iPad and the Mac and now names a phone-only design type. It is **not** fixed here because
the fix is a cross-file refactor of two shared views, and this host cannot compile SwiftUI. The
minimal shape a macOS host should apply: give `DashboardCardSurfaceStyle` / `HTTPProxyCard.SurfaceStyle`
a `.filled(fill:separator:cornerRadius:)` case carrying plain `Color`/`CGFloat`, have the phone pass
`HakoProductPalette.system.card` at its call sites, and delete the Hako references from the shared
files. `INFERRED` remedy, `VERIFIED_SOURCE` defect.

---

## C. Behaviour map for the phone surface

`REUSED` = official code path, unmodified; `WIRED` = changed this round; `DEVICE` = needs hardware;
`OPEN` = known gap, not touched.

| Area | Phone entry | Official path | State source | Status |
|---|---|---|---|---|
| Configuration selection | `HakoProfilePickerSheet` (4 `onSelect` sites) → `profileSelection` → `OverviewViewModel.switchProfile` | same function as iPad's `OverviewView` | persisted preference + `selectedProfileUpdate` → `HakoPhoneRootView:211` → `dashboard.updateSelectedProfile()` | **WIRED** (F-1, F-5) |
| Configuration create / import | `HakoNewProfileMenuView` → `SharedPreferences.selectedProfileID.set` + `profileUpdate` | `NewProfileMenuView` does the same | preference | REUSED. Note: like upstream, an import selects the new configuration *without* reloading a running tunnel — `OPEN` |
| Remote subscription update | `updateProfile` / `updateAllProfiles` in the centre | `Profile.origin.updateRemoteProfile()` + `profileUpdate` | `profileUpdate` → `dashboard.reload()` | REUSED |
| VPN start / stop / install | `HakoStartStopButton` | `ExtensionProfile.start/stop/install` | `profile.status` | REUSED |
| Groups / nodes | `HakoGroupListView`, `HakoGroupView` | `GroupListViewModel` | `commandClient.$groups` / outbounds | REUSED (not re-audited line by line this round) |
| Clash mode | `HakoHomeView.modeSection` | `CommandTarget.standaloneClient().setClashMode` | `commandClient.$clashMode` / `$clashModeList` | **WIRED** (F-2, F-3) |
| Traffic / status | `UploadTrafficCard`, `DownloadTrafficCard`, `StatusCard` | the same cards as the iPad | `commandClient.statusPublisher` | REUSED |
| Connections / logs | shortcut rows → sheets; `HakoLogView` | command client streams | `commandClient` publishers | REUSED |
| System HTTP proxy | `HTTPProxyCard` + `coordinator.setSystemProxyEnabled` | `OverviewViewModel.setSystemProxyEnabled` | `dashboard.reloadSystemProxy()` | REUSED; its failure alert is now reachable (F-4) |
| Profile override | `HakoProfileOverrideView` | `SharedPreferences` + `reloadService()` | preference + service reload | REUSED (verified against upstream line by line) |
| Tunnel routing settings | `HakoPacketTunnelView` | `applySettings()` → `updateProtocolConfiguration()` / `restart()` | preferences + the `NETunnelProviderProtocol` | **WIRED** (F-7, F-8) |
| On-Demand / Always On | `HakoOnDemandRulesView` | `saveMode` / `saveRules` / reset → `profile.updateOnDemand` | preferences + `manager.isOnDemandEnabled` | **WIRED** (F-9) |
| Tools / reports / navigation | `HakoToolsView`, shell | official types | own view models | REUSED |
| Background return | `scenePhase` → `connect`, `postReload`, `reloadSystemProxy` | upstream's iOS root does the same | — | REUSED |

The only two places this round changed behaviour are the two this round was asked to close. The rest
was read to confirm the control path reaches an official function; that is `VERIFIED_SOURCE`, not a
runtime test.

---

## D. What the change is, exactly

1. **`HakoHomeView` hands the centre a side-effecting binding.** The four `onSelect` closures in the
   generated picker keep assigning into their `@Binding`; one binding here covers all four, so a
   future regeneration of that file cannot silently re-open the hole in one branch only.
2. **`selectProfile` drives the official function, serially.** It never writes
   `selectedProfileID`, so the header's name cannot get ahead of the persisted choice; the field is
   still written by `updateSelectedProfile` from `selectedProfileUpdate`, which is the same
   reconciliation the iPad relies on.
3. **`HakoClashModeLayout` decides the mode row's shape** from the count and the display width of
   the names. The width budget (10 units of one narrow glyph, a full-width glyph counting two) is
   derived from a 375pt phone: 375 − 2×20 page inset − 2×16 section padding = 303, ÷3 = 101 per
   third, − 2×8 label padding = 85pt of text, against ~8.4pt per narrow glyph at `.body`. Values
   sent back are always the core's own strings.
4. **`HakoProfileSwitchQueue` orders the switches.** One slot, one drainer; a burst is coalesced to
   the last choice, which is the contract ("the last accepted choice is the one applied"), and the
   busy gate is raised per switch because `switchProfile` always clears it.
5. **One alert presentation per phone view.** Two sources folded, both cleared on dismissal.
6. **The two settings pages that write the tunnel's own configuration now write it.** The tunnel
   page restores upstream's `updateProtocolConfiguration()` branch and the `#if !os(tvOS)` guards
   its own switches need; the On-Demand page passes the mode it was given and writes the disabling
   half whatever the tunnel is doing, which is what makes Reset mean Reset.
7. **The localization gate measures again, and the phone's untranslated copy has keys.** It was blind
   five ways, each found by making it run rather than by reading it: the file walk matched nothing on
   Windows, the literal extractor was off by one, escapes were compared raw, labelled arguments were
   never read, and the comment stripper cut each line at the first `//` — including inside a string
   literal, which hid the one string in the tree that *is* a URL. With all five fixed it found 57
   strings that rendered English in every language; all 57 are in the catalog with zh-Hans. One call
   site changed with them: the "no shared container" state was a Chinese title over a Chinese/English
   message, which is what every locale saw; it now uses English keys and the catalog carries the
   Chinese. The gate also refuses a localized URL that is no longer a URL — the docs link is
   `URL(string: String(localized: "https://…"))!`, so prose there would be a crash, not a typo.
8. **The Tools page's Endpoints card no longer hides a service it renders.** Its gate listed the
   three endpoint arrays and the USB/IP rows came from a fourth; the condition now includes it, which
   is upstream's own condition in a different card (F-11). The remote-control server list on Client
   Settings reports a failed read instead of flattening it into an empty list (F-12).
9. **A nil command client is reported, not skipped.** `LibboxNewStandaloneCommandClient()` is
   Optional and an optional chain over nil does not throw, so the crash-report triggers and the OOM
   trigger could do nothing at all without saying so (F-13). They now unwrap and report the nil
   answer with the catalog's existing "Status Channel Unavailable" key, and
   `check_hako_command_channel.py` refuses the optional-chained form anywhere in the phone files.

Design constraint kept: no second `ProfileManager`, no second event bus, no new persistence, no new
reload state machine. Everything the page does goes through a type upstream already ships.

---

## E. Evidence

Run from the worktree root on Windows, CPython 3.12.10, Swift 6.3.3 (`swiftc` present, no Xcode).

| Command | Result | Level |
|---|---|---|
| `check_hako_profile_switch.py --root .` | 6 behavioural cases + 2 wiring assertions, exit 0 | `VERIFIED_UNIT` (the shipped queue and the extracted `selectProfile` compile and run) |
| `check_compact_mode_picker.py --root .` | 10 cases + 1 wiring assertion, exit 0 | `VERIFIED_UNIT` (the shipped `HakoClashModeLayout` compiles and runs) |
| `test_hako_ui_gates.py --root .` | 13 mutants, 13 caught, exit 0 — two of them mutate a scratch tree and require the *compiled* cases to fail, one requires the platform gate to fail | `VERIFIED_UNIT` (negative) |
| `check_hako_platform_symbols.py --root .` | `PASS: 58 Hako file(s) checked; 25 platform-gated SharedPreferences member(s), every use inside its condition`, exit 0 | `VERIFIED_STATIC` (new gate; it reported 12 unguarded uses before F-7's fix) |
| `check_hako_command_channel.py --root .` | `PASS: 58 phone file(s) checked; every command client is unwrapped before use, so a nil answer can be reported`, exit 0 | `VERIFIED_STATIC` (new gate for F-13; it reported both optional-chained call sites before the fix) |
| `audit_apple_ui_boundary.py --root . --upstream-ref 089d35e6… --strict` | `PASS 17 FAIL 3 UNKNOWN 0`, exit 1 — the same three failures as at `e8c0874`, listed in §B | `VERIFIED_STATIC` |
| `check_hako_macos_parse.py --root . --platform ios` | `checked=56 errors=0 undecidable=0`, exit 0 (54 before this round; the two new files are in scope) | `VERIFIED_STATIC` |
| `check_platform_structure.py` | exit 0, "every ported file still carries the platform structure its original had" | `VERIFIED_STATIC` |
| `check_swift_structure.py ApplicationLibrary/Views/HakoStyle SFI/HakoPhoneRootView.swift` | 2 targets balanced, exit 0 | `VERIFIED_STATIC` |
| `check_generated_headers.py` | 33 portable headers, 0 naming a missing path, exit 0 | `VERIFIED_STATIC` |
| `test_platform_gates.py` | 0 failing of 19, scope report covers 56 of 56 files, exit 0 | `VERIFIED_STATIC` |
| `git diff --check` | clean | `VERIFIED_GIT` |
| `audit_hako_lossless_parity.py --root .` | `PARTIAL`, `lost UI tokens: 2` (`Remote control`, `Out of Memory Report`), `HakoData 952 vs 920`, `HakoRow 879 vs 855`, exit 1 | `VERIFIED_STATIC` — **same as before this round**, and the two tokens are the documented intentional renames |
| `dup_module_scope.py` | exit 1, **20** candidate findings — every one an `extension` of a type several files extend, plus one `formattedSize` free function; **none involves a file this round added** | `VERIFIED_STATIC`, pre-existing. Previously reported as 18: the script's default root pointed at a stale worktree (`_work/r8/w-main`), and it now resolves from its own location — see the branch-cleanup note below |
| `check_localization.py` | `PASS: 502 visible string(s) across 58 fork-owned file(s) … (26 exempt, 0 pending)`, exit 0 | `VERIFIED_STATIC` — **this row used to read `INVALID COVERAGE`**: the gate was vacuous on Windows and, independently, could not see a bare literal, a labelled argument, or any string containing `//` (see F-10). Five defects fixed; the 57 keys it then found are in the catalog, and a localized URL that stops being a URL now fails the gate |
| `check_commit_messages.py` | exit 0, `commits in --root:` empty | **BLOCKED_BY_ENVIRONMENT** — scanned 0 commits, proves nothing |
| `test_audit_reverse_routing.py` | 29 executed, 1 skipped (`refs/up-hako` absent), 2 mutations could not be applied (`HakoEditProfileView()` ×3 expected 2; `#endif` ×2 expected 1) | pre-existing drift in that suite's mutation targets; neither file is touched by this round |
| `test_fail_closed_exit_codes.py` | 2 passed, 1 failed (`lossless-positive: lost_tokens=2`) | pre-existing, same intentional renames |
| `test_audit_apple_ui_boundary.py` | **SKIPPED** — it runs `git reset` / `git checkout -- .` in a copy whose `.git` points at this clone's git directory, and this round's work was uncommitted while the gates ran | deliberate skip, not a pass |

Not verified anywhere in this list: that the iPhone builds, that the row renders, that a switch
actually reloads the tunnel. Those are §F.

---

## F. Device acceptance (all `NEEDS_DEVICE`)

1. Two visibly different local sing-box JSONs, A and B.
2. **Cold start, no tunnel**, tap A→B in Profiles: the header name changes; force-quit and relaunch;
   the header still says B.
3. **Connected**, tap A→B: the alert-free path reloads; proxies/current node/mode/traffic/logs/status
   all belong to B afterwards; the header never names B while the mode row still shows A's modes.
4. **Connected**, tap B→A→B quickly (double tap in the sheet): the tunnel ends on B, one reload
   visible, the page is disabled during it and re-enabled after.
5. **A→B where B is an unreadable/deleted file**: the switch reports through the page's alert (F-4)
   and the header still shows what is actually persisted.
6. **Fast switching with the tunnel stopping mid-switch**: no permanent disabled page.
7. A configuration whose rules declare `clash_mode: 代理 / 直连 / 拦截`: the row draws three equal
   thirds reading those names, tapping sends the same string, and the core's report marks the third.
8. Same with a fourth mode: the list appears and all four are reachable.
9. Same with two long custom names: the list appears, nothing is truncated or hidden.
10. Stop and restart the tunnel: the mode row comes back with the new session's list, never the
    previous one's.
11. Profile import failure (bad URL / corrupt file): the alert appears (previously it could not on
    the root — F-4).
12. Self-signed IPA: Packet Tunnel permission, App Group, command channel, real TUN capture,
    loopback + SideStore dual-stack renewal — unchanged by this round and must be re-run anyway.
13. iPad: `MainView` still official, including the profile picker and the Clash-mode card.
14. **Tunnel page:** with the tunnel down, toggle "Include All Networks", force-quit the app, then let
    On Demand start the tunnel — the new value must be in effect (F-8). With the tunnel up, a toggle
    must reload the service and report a failure through an alert.
15. **On-Demand page:** with the tunnel **down**, switch to On Demand and back to Disabled, then
    change Wi-Fi ↔ cellular — the tunnel must not start by itself (F-9 part 1). Then enable Again,
    press Reset, and confirm the system stops auto-connecting *and* the page says Disabled (F-9 part 2).
16. **Language:** set the iPhone to Simplified Chinese and walk Home → Profiles → Proxies → Activity →
    Logs → More → every More sub-page. No English sentence should remain (F-10), and the On-Demand
    rule editor is where the gate found the most.
17. **Tools:** with a configuration that declares only a USB/IP server (no Tailscale / OpenConnect /
    OpenVPN endpoint), Tools must still show the Endpoints card and the USB/IP row must open its page
    (F-11). With none of the four, the card must be absent — not empty.

---

## G. Remaining risks

**P0**

* `Xcode/iOS compilation is unverified on this host.` The changed view code is source-reviewed and
  structurally checked, and the two decision files compile with `swiftc`, but `HakoHomeView` itself
  has never been compiled. The first macOS build is the real gate; the risk is concentrated in
  three small additions (`pageAlert`, `profileSelection`, the two `onReceive`).
* `iPhone behaviour is unverified.` F-1's fix routes into upstream's method; whether that method's
  reload path does what the reader expects on a real tunnel is exactly §F.

**P1**

* **Shared cards depend on phone-only types** (§B). Invariant 2 is currently violated at
  `DashboardCardView.swift:45` and `HTTPProxyCard.swift:67`; the audit is red for it and was red
  before this round. A macOS host should apply the `.filled(...)` shape described there.
* **A reload failure cannot be rolled back.** `OverviewViewModel.switchProfile` persists and
  broadcasts *before* it reloads, so a failed reload leaves preference = B while the running
  service is still A. The page now reports the failure through its alert (that is the improvement),
  but it shows B, because B is what is persisted. A true rollback needs an upstream change; do not
  fake one in the page.
* **The mode list is not cleared when a configuration changes.** It mirrors the core's last report,
  which is the honest source; if the core does not re-publish `initializeClashMode` after a reload,
  the previous list persists until the next session. Device item 10 is the check.

**P2**

* **The tvOS slice is still unverified.** F-7 removes the twelve compile errors this round found,
  but nothing here can type-check an `appletvos` build. `check_hako_platform_symbols.py` closes the
  *specific* hole (a platform-gated `SharedPreferences` member) and can only see that one file: a
  Hako page that reached for another platform-exclusive symbol — a `UIKit` API, a
  `NETunnelProviderProtocol` member — would still be caught only by a real build.
* Importing or deleting a configuration sets the preference without reloading a running tunnel —
  upstream behaviour on both platforms, left alone.
* The mode row's width budget assumes the default text size; at accessibility sizes the third may
  still compress. The previous fixed-three rule had the same limitation. Recorded in
  `HakoClashModeLayout`'s header.
* `origin/main` is no longer ahead: the branch-cleanup pass merged its one commit (§H).
* The kernel's `clients/apple` gitlink names
  `ab575dace8`, which is **absent from this clone's object store** (`git cat-file -t` fails), so the
  distance to this `main` cannot be measured here — `EXTERNAL_CHECK_REQUIRED`, and a release-time
  concern rather than a UI defect. Moving either pin is a release action.
* `dup_module_scope.py`, `audit_hako_lossless_parity.py` and two negative suites are red at this
  baseline for reasons recorded in §E. None of them is caused by this round; none was made green by
  editing its inputs.

---

## H. Branch cleanup (same session, after the fixes)

The clone carried eleven local branches and fifteen worktrees, all left over from the rounds that
produced the knowledge base. They were consolidated to **one branch, `main`**, in this order:

| Was | Verdict |
|---|---|
| `fix/compact-outbound-mode-ui` (`3cc3aae`) | ancestor of `main` — deleted |
| `jiejiebox/integrated` (`2207852`), `r8/main` (`2a18968`), `r8/a-generator`, `r8/b-boundary`, `r8/c-platform`, `r8/d-reach`, `r8/e-redteam` | ancestors of `main` — deleted |
| `jiejiebox/v0.1.6-hardening` (`ff849cc`) | not in `main`; tip preserved by the new tag `archive/v0.1.6-hardening-tip-2026-11-07`, then deleted |
| `jiejiebox/hako-ui-migration-wip` (`83127c2`) | not in `main`; tip preserved by `archive/hako-ui-migration-wip-2026-11-07`, then deleted |
| `dev` (`d1224bb`, upstream 1.15.0-alpha.10) | not in `main` and not in `upstream/dev`; tip preserved by `archive/dev-tip-2026-11-07`, then deleted |
| `origin/main` (1 commit) | merged into `main` — it touched only `Library/Network/ExtensionPlatformInterface.swift`, already on the reviewed list |

Every deleted tip was re-checked with `git cat-file -e` afterwards.

### The remote moved while this was being written, and the push

`origin/main` advanced from `3aedd74` to **`ab575da`** during the session: the local-signing
loopback, the self-sign startup fixes, the shared-container/App-Group work and the
1.15.0-alpha.13 upstream absorption — the line the kernel's `clients/apple` gitlink pins. None of
its 40 files is one of the 21 this line touched, so it was merged as its own commit (`eb8a8ac`)
rather than rebased, and the six UI commits keep the SHAs their gates and this report cite.

Then, all of it was pushed: `main` (`ab575da..eb8a8ac` at the time) and the three preservation tags,
so the deleted tips survive on the remote as well as locally. A follow-up push carried `da87fa4`
(localization). `fix/compact-outbound-mode-ui` and the two fully-merged self-sign branches
(`experiment/selfsign-compat`, `feat/ios-local-signing-loopback`) were deleted remotely; their
content is on `main`.

### `hotfix/ios-command-socket` — audited, archived, deleted

The last remote branch besides `main` held one commit `main` did not: `ceffc5b`
(*feat(tunnel): say when this build has no shared container*, 2026-11-04, 13 lines). It is an earlier
form of the diagnostic `eb8286a` carries on `main`: the same
`if FilePath.isUsingProcessLocalDirectory { writeMessage(same text, level: .info) }`, refined there
with `#if os(iOS)`. So the function is covered — `ceffc5b` is superseded, not patch-equivalent.

No workflow depended on it: neither repository has CI (no `.github`), no `Makefile` / `fastlane` /
script names the branch or the commit, and the parent pins `clients/apple` by **SHA**
(`ab575dace8…`), not by branch. The only text hit in either repo is a documentation *path*
(`docs/fork/ios-command-socket-path-fix.md`) inside the kernel's knowledge base, which is not a ref.

It was classified obsolete and handled as the user directed: the commit is preserved by the annotated
tag **`archive/hotfix-ios-command-socket-2026-11-07`** (pushed), and the remote branch was deleted.
`main` is now the only branch locally and remotely, and the five gates plus the audit are unchanged by
this — it touched no file in this tree.

Pushing also means `main` is no longer a local-only line: the SHAs this report cites are the
published ones.

Two consequences worth knowing:

* the primary checkout is now on `main` and the `_work/main-fix` worktree is gone — the tree this
  report describes is at `IOS客户端/sing-box-for-apple/`;
* nine `scripts/dev/` tools had a hard-coded default root naming `_work/r8/w-main`, so removing that
  worktree exposed that they had been scanning a **stale tree** when run without an argument. Their
  defaults now resolve from the script's own location. `dup_module_scope.py` is the visible
  difference: 18 candidates against the stale tree, 20 against the real one, none involving this
  round's files.

The five `_work/refs/up-*` checkouts were kept: they are detached reference trees, not branches, and
`restore_picker_guards.py` names one of them by path.

`KNOWLEDGE/BASELINE.md`'s "Local branches at this refresh" list is now stale by design — this was not
a Knowledge Refresh, so `KNOWLEDGE/` was not edited.
