# Apple UI stability closeout — 2026-11-14

Scope: the P0 "cannot get out of a broken VPN", the P1 configuration-update/save/selection
correctness work, and the P2 tool and background-task lifecycle work described in
`JiejieBox_Apple_UI_P0_P2_深度修复与自主Debug施工指令_2026-11-14.md`.

Everything below is stated at the evidence level that was actually reached. The platform caveat that
governs the whole document is first:

> **No part of this change was built with Xcode or run on a device.** The host is Windows; there is no
> Xcode, no iOS simulator and no attached iPhone. What *was* executed is recorded in
> [§5](#5-test-matrix-actually-executed) — a real Swift type-check of the shipped sources against the
> iPhoneOS SDK, and 190 unit tests executed in the repository's own SwiftPM packages. Any claim about
> NetworkExtension runtime behaviour is `code path fixed, device verification outstanding`.

---

## 1. Baseline, branch and what was modified

| Item | Value |
|---|---|
| Audit baseline / starting `HEAD` | `749509f214d97f43cbc66f903fd17b0b50eb6399` — `fix: supply remote profile error argument label` |
| Starting state | `main...origin/main`, working tree clean, `0` ahead / `0` behind |
| Remote | `https://github.com/Piggy-Cat-bit-shadow/sing-box-for-apple.git`, `main` only |
| Kernel consulted (read-only) | `sing-box` checkout at `c50336676`, branch `testing` |
| Fix branch | `main` (fast-forwardable, no divergence, no protected-branch obstacle) |
| Commit | see `git log -1` on the commit that carries this file |

The audit's line references were checked against this tree and matched, so the baseline was current.

### Files actually modified (18)

| File | Why |
|---|---|
| `Library/Network/ExtensionProfile.swift` | P0 stop ordering; at-most-once provider reply with a real timeout |
| `Library/Network/ExtensionEnvironments.swift` | distinguish "no tunnel" from "tunnel unreadable" |
| `ApplicationLibrary/Views/HakoStyle/HakoStartStopButton.swift` | emergency stop for a stalled transition |
| `ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift` | page gate no longer disables the exit; off-main-actor mode switch; system-proxy row re-read |
| `ApplicationLibrary/Views/HakoStyle/HakoCoreView.swift` | force-unwrap removal; wait for disconnect before erasing |
| `ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift` | refused reorder/delete no longer leaves the UI lying |
| `ApplicationLibrary/Views/Dashboard/Overview/OverviewViewModel.swift` | `reasserting` always cleared; preference rollback; ownership-guarded selection restore |
| `ApplicationLibrary/Views/Profile/EditProfileViewModel.swift` | form no longer locks after a failed save; save/schedule/apply separated |
| `ApplicationLibrary/Views/Profile/NewProfileViewModel.swift` | a created profile is no longer reported as a failed creation |
| `ApplicationLibrary/Service/UIProfileUpdateTask.swift` | background task completed on every exit; expiry handler installed first |
| `ApplicationLibrary/Views/Abstract/ConnectionLifecycleObserver.swift` | subscriptions released when the page goes away |
| `ApplicationLibrary/Views/Connections/ConnectionListViewModel.swift` | synchronous core RPC moved off the main actor |
| `ApplicationLibrary/Views/Tools/{Tailscale,OpenVPN,OpenConnect,USBIP}StatusViewModel.swift` | late-handle leak closed; stream errors classified |
| `ApplicationLibrary/Views/Tools/StatusSubscriptionSupport.swift` | **new** — the ownership token and the error classification those four share |
| `Localizable.xcstrings` | one new key (en + zh-Hans) for the new Core-page refusal message |

`git diff --stat` for the set: **17 files changed, +774 / −110**, plus one new file.

> **A concurrent editing session was active in this working tree.** Between 21:27 and 21:28 another
> session modified `Library/Network/CommandClient.swift`, `ApplicationLibrary/Views/Log/LogView.swift`,
> `ApplicationLibrary/Views/Log/LogViewModel.swift`, `ApplicationLibrary/Views/HakoStyle/HakoLogView.swift`
> and added `Library/Network/LogStore.swift` (a log-pipeline refactor). Those files are **not** part of
> this change set, are **not** in this commit, and were left untouched. See
> [§7](#7-working-tree-hygiene--the-concurrent-session).

---

## 2. The P0 chain, as proved from source

The user's report was "after a failed remote-profile update the VPN itself wedges, keeps the iOS VPN
slot, and only another VPN can take it back". The mechanism is a three-link chain, and all three
links are in source:

1. **`ExtensionProfile.stop()` awaited a kernel RPC before asking the system to stop.**
   The old body cleared On-Demand, then `await Task.detached { try LibboxNewStandaloneCommandClient()!.serviceClose() }.value`,
   and only then `manager.connection.stopVPNTunnel()`.
2. **That RPC blocks on the provider's lifecycle lock.**
   `serviceClose()` is a gRPC call to `daemon.ManagedService.StopService`, whose handler calls
   `platformHandler.ServiceStop()` → the extension's `ExtensionPlatformInterface.serviceStop()` →
   `ExtensionProvider.stopService()`, which takes `serviceLifecycleLock`. That same lock is held by
   `startService()` across `commandServer.applyServiceChangeReport(...)` — an unbounded call that
   opens the TUN and waits for the platform's network settings. So a slow or wedged apply holds the
   lock for as long as it lasts, and the app's `serviceClose()` waits with it.
3. **`stopVPNTunnel()` was never reached.** The user's exit was behind two awaits that could not
   complete, so the system stop request was never sent. Nothing in the app could then release the
   tunnel; a second VPN taking the slot is the only way out.

Two secondary facts make it worse and are fixed as well: a failing `saveToPreferences()` returned
before the stop request, and `LibboxNewStandaloneCommandClient()` was force-unwrapped on the one path
a user takes to escape.

Why the lock itself is **not** a bug: `ServiceStop` is only reachable from the gRPC `ManagedService`
handler, never from inside the apply, so the non-recursive `NSLock` is never re-entered on the same
thread. The lock correctly serialises `platformInterface.reset()` against a concurrent start's
monitor install — the hazard its comment describes. Deleting it, or making it recursive, would
reintroduce the monitor corruption it prevents. It is reported `NOT A BUG + evidence`, not patched.

---

## 3. Acceptance table

Legend: `FIXED + verified` = changed, and the change is type-checked against the iOS SDK and covered
by the executed suite where the suite can reach it. `FIXED + verification pending` = changed and
type-checked, but the behaviour it governs needs NetworkExtension at runtime. `NOT A BUG + evidence`
= investigated, no change, reason recorded. `DEFERRED + scoped risk` = deliberately not changed.

| # | Verdict | Key path |
|---|---|---|
| **A1** | `FIXED + verified` | `ExtensionProfile.stop()` — order is now *clear On-Demand (best effort) → `stopVPNTunnel()` → best-effort kernel close*. Nothing can throw or await before the system request. The force-unwrap is gone. The close is a single, tracked, non-awaited detached call. |
| **A2** | `FIXED + verification pending` | `HakoStartStopButton.HakoToggleConnectionButton` — after a 6 s grace the busy row grows a **Disconnect** button that always calls `stop()`, never the start/stop toggle. `HakoHomeView` — the page-wide `.disabled` became `pageIsBusy` applied per section; the header's primary action and `pageAlert` stay live, the profile button stays gated. |
| **A3** | `NOT A BUG + evidence` | `ExtensionProvider.startService/stopService/stopTunnel`. Lock graph and reachability recorded above. The blocking *consequence* users saw was fixed in A1. No lock change: `NSRecursiveLock` would mask, deletion would corrupt. |
| **B1** | `FIXED + verified` | `ExtensionProfile.requestProviderMessage` + `ProviderReplyGate` + `applyReplyTimeout (15 s)`. `reloadService(_:)` can no longer hang forever; `currentTunnelSessionID` no longer uses `withTaskGroup` (whose `cancelAll()` cannot resume a suspended continuation) and no longer inherits the stale-continuation defect. Reply, late reply, throw and deadline are one gate with exactly one resume. |
| **B2** | `FIXED + verified` | `EditProfileViewModel.saveProfile` — `defer { isLoading = false }` on every path, and save / schedule / apply are three separately reported facts. |
| **B3** | `FIXED + verified` | `OverviewViewModel.setSystemProxyEnabled` — `reasserting` cleared on the failure path; the preference is rolled back when the apply fails; the command client is no longer force-unwrapped. `HakoHomeView` re-reads the persisted value so the row stops showing a state the tunnel never entered. |
| **B4** | `FIXED + verified` | `OverviewViewModel.switchProfile` — the selection is still persisted first (the reload reads it from preferences), but a refused apply now restores the previous identifier under an **ownership guard**: only while the persisted value is still this call's write. The same-profile no-op no longer reloads. |
| **B5** | `DEFERRED + scoped risk` | `Library/Database/Profile+Update.swift` — read at its call sites and entry points; the reporting vocabulary (`saved/unchanged/applied`, `superseded`, `recovered`, `interrupted`, `applyUnconfirmed`) is intact and no defect was proved within this session. Not modified: the audit's own instruction is to protect this module rather than rewrite it. Residual risk: an unproven edge in provider-refresh ordering stays unproven. |
| **B6** | `FIXED + verified` | `HakoProfilePickerSheet` — all four optimistic mutation sites (legacy + iOS 26 move/delete) now reject an error into an alert and restore the previous list, **guarded**: the restore happens only while the list is still exactly what that change produced, so a second edit is never undone by the first edit's failure. The `// Handle error silently` comments are gone. |
| **B7** | `FIXED + verified` | `NewProfileViewModel` — `createProfileBackground()` returns the scheduling error instead of throwing it, so a profile that `ProfileManager.create` already wrote is never reported as a failed creation; the registration failure is logged with the profile id and does not block `profileUpdate` or dismissal. |
| **C1** | `FIXED + verified` | `TailscaleStatusViewModel` + `StatusSubscriptionSupport` — (a) a handle that arrives after `cancel()` is closed instead of adopted; (b) stream errors are classified: `serviceNotRunning` / `unsupportedByCore` are logged, never modal; a genuine fault still alerts. **Kernel evidence for the classification** in §4.1. |
| **C2** | `FIXED + verified` (subscriptions) / `DEFERRED + scoped risk` (two test VMs) | `ConnectionLifecycleObserver` now releases on `onDisappear`; `OpenVPN`/`OpenConnect`/`USBIP` got the same ownership token as Tailscale. `NetworkQualityViewModel` and `STUNTestViewModel` were **not** changed — their start/cancel race is the same shape but needs its own review; reported, not silently claimed. |
| **C3** | `NOT A BUG + evidence` | `AlertState` and the Hako alert folding: `HakoHomeView` already folds two sources into one `pageAlert` binding and clears both on dismissal; no page in this change set uses the `alert(_:isLoading:)` overload whose condition can strand an alert. The defect this item warns about (a section-scoped presentation being dropped) is not present in the current code. |
| **C4** | `FIXED + verified` | `UIProfileUpdateTask.getAndUpdateProfiles` — `setTaskCompleted` now runs on **every** exit (unreadable list → `false`, empty list → `true`), and `expirationHandler` is installed before any work starts instead of after it finished. |
| **C5** | `FIXED + verified` | `ExtensionEnvironments.reload()` — a throw is no longer discarded by `try?`: it sets `profileLoadFailure`, keeps the previously loaded profile, and logs. `nil` (no manager at all) is still "no tunnel installed". |
| **C6** | `FIXED + verified` | `HakoCoreView` — `extensionProfile!` replaced by a `guard let`; and the working directory is erased only after the system publishes `.disconnected`, with a 15 s bound and a refusal (not a deletion) on timeout. |
| **C7** | `FIXED + verified` | `HakoHomeView.selectClashMode` and `ConnectionListViewModel.closeAllConnections` now run their synchronous core calls in `Task.detached`, returning to the main actor only for state — matching the pattern the tools view models already use. **Not** a repository-wide audit: other sync-FFI sites were not all reviewed. |
| **C8** | `DEFERRED + scoped risk` | `HakoOnDemandRulesView`, `HakoPacketTunnelView`, `HakoProfileOverrideView` — the "write preference, then reconfigure" ordering was not changed. **One interaction is covered by A1**: `stop()` clears On-Demand before the stop request, so a user-initiated disconnect is not immediately undone by On-Demand. The rest needs its own pass. |

---

## 4. New findings

### 4.1 The Tailscale modal was a kernel lifecycle condition, not a Tailscale fault

The message in the report — `tailscale status recv: rpc error: code = Unknown desc = invalid argument` —
is produced end to end by two kernel facts, neither specific to Tailscale:

* `sing-box/experimental/libbox/command_client.go:1421` `subscribeStatus(...)`: the receive goroutine
  reports every stream error that is neither `NotFound` nor `Unavailable` through
  `onError(E.Cause(recvErr, name, " recv").Error())`. That is where the `"<name> recv"` prefix comes from.
* `sing-box/daemon/started_service.go:388` `waitForStarted(...)`: returns `os.ErrInvalid` whenever the
  service is neither `STARTED` nor `STARTING` — i.e. during a start, a stop or a reload. gRPC surfaces
  that bare Go error as `code = Unknown desc = invalid argument`.

So the error is what a tools page gets when it subscribes while the service is **between states**. It
arrived as a modal alert quoting gRPC, which reads as "your Tailscale is broken" with no action.

The fix is in the app, where the judgement belongs: `StatusSubscriptionFailure.classify` maps it to
`serviceNotRunning`, keeps it in the log at debug/info level, and reserves the alert for real faults.
The same classification now covers OpenVPN and OpenConnect, which share the identical path and the
identical modal.

### 4.2 The same late-handle leak exists in four tool pages, not one

`subscribe()` raised `isSubscribed` synchronously and then obtained the handle from a detached task;
`cancel()` could not close a handle that did not exist yet, and the completion stored it anyway. Every
visit to the tools page during a cancel left one live core status stream behind. Fixed for all four
with one shared `SubscriptionOwnership` token rather than four bespoke flags.

### 4.3 A failed profile save disabled the editor permanently

`EditProfileViewModel.saveProfile` lowered `isLoading` only on success while both edit views gate the
whole form on `.disabled(viewModel.isLoading)`. One refused save left the fields dead; the Save button
stayed enabled because it is gated on `isChanged`, so pressing it again re-entered the same dead end.

### 4.4 A background refresh that could never be granted again

`getAndUpdateProfiles` returned without `setTaskCompleted` on two paths (unreadable list, empty list),
and installed `expirationHandler` *after* the work. The first is charged to the app's background budget
by the system; the second is the one case the handler exists for.

### 4.5 Erasing the working directory under a live tunnel

`HakoCoreView.stopServiceAndDestroy` deleted the core's data immediately after `stop()` returned —
which only means the request was submitted — and force-unwrapped the profile to get there.

---

## 5. Test matrix (actually executed)

Host: Windows 10 19044; no Xcode, no iOS SDK on Windows, no simulator, no device.
All Swift execution below happened in **WSL2 Ubuntu 24.04** with **Swift 6.4.2** (`swift-6.4.2-RELEASE`)
and the locally built **iPhoneOS 27.1** SDK from the user's `xtool` artifact bundle.

### 5.1 iOS type-check of the shipped sources — `PASS (no new errors)`

Method: `swiftc` per module against `-target arm64-apple-ios17.0 -sdk iPhoneOS.sdk`, mirroring the
flags SwiftPM itself uses successfully (including `-resource-dir` into the Xcode toolchain, without
which the compiler rejects the SDK's own `Swift.swiftinterface`). Two trees were compiled with the
same stub and the same dependency modules:

* **A** = pristine `HEAD` sources (`git archive HEAD Library ApplicationLibrary`)
* **B** = `HEAD` sources + only this change set

| Target | A (HEAD) | B (change set) |
|---|---|---|
| `Libbox` (stub) `-emit-module` | exit 0 | exit 0 |
| `Library` `-typecheck` (96 files) | **exit 0** | **exit 0** |
| `Library` `-emit-module` | exit 0 | exit 0 |
| `ApplicationLibrary` `-typecheck` (227/228 files) | exit 1 — 2 errors | exit 1 — 2 errors |
| `HakoFull` shell `-typecheck` | exit 0 | exit 0 |
| **Difference in the error set** | — | **IDENTICAL (2 lines)** |

The two residual errors are `cannot find 'HakoTerminalSessionContainerView' in scope` at
`HakoToolsView.swift:135` in **both** trees. That type is declared inside
`#if canImport(GhosttyTerminal) && os(iOS)`, and the sandbox does not link GhosttyTerminal, so the
condition is false here. It is a property of this harness, not of the source, and it is identical
before and after the change.

Excluded from the harness, each for a stated reason, and **both identical in A and B**:
`ExtensionPlatformInterface.swift` / `ExtensionProvider.swift` (the sandbox's Libbox stub predates
those files' protocol requirements — an unrelated, pre-existing stub gap), `RequestReviewButton.swift`
(`@Environment(\.requestReview)` does not resolve in this SDK/compiler pairing).

**What this proves:** the changed files compile against the iOS SDK, in a module graph that includes
every other file of `Library`, and they introduce no new compile error anywhere in
`Library`/`ApplicationLibrary`.
**What it does not prove:** that an Xcode build of the nine targets succeeds — different targets,
different conditional compilation, signing, and the real Libbox binary.

### 5.2 Repository test packages — 190 tests, 0 failures

Run in WSL on a copy of the tree, after `scripts/link-test-sources.sh` materialised the symlinks the
packages need (on this Windows checkout those links are plain text files).

| Runner | Result | Tests |
|---|---|---|
| `scripts/run-config-ownership-tests.sh` | **PASS** | 116 executed, 0 failures |
| `scripts/run-screen-state-tests.sh` | **PASS** | 48 executed, 0 failures |
| `scripts/run-interface-startup-tests.sh` | **PASS** | 13 executed, 0 failures |
| `Tests/HakoCommandSubscription` (`swift test`) | **PASS** | 13 executed, 0 failures |
| `scripts/run-quota-caption-tests.sh` | **FAIL — environment** | `cannot find 'SubscriptionQuotaCaption' in scope`: the package's source links are not created by `link-test-sources.sh` and are text stubs on this checkout |
| `scripts/run-subscription-usage-tests.sh` | **FAIL — environment** | `cannot find type 'NSErrorPointer' in scope`: `NSErrorPointer` is an Objective-C interop type, unavailable under `-disable-objc-interop`. This package builds only with Xcode |

Both failures are `BLOCKED_BY_ENVIRONMENT`, both are reproducible at `HEAD` with no local change, and
neither exercises code this change touches.

### 5.3 Repository gates — PASS

| Gate | Result |
|---|---|
| `python scripts/dev/check_localization.py` | **PASS** — 516 visible strings across 58 fork-owned files resolve to a catalog key with `en` and `zh-Hans`; 27 exempt as technical terms; **0 pending** |

### 5.4 Not run

* `xcodebuild` for any of the nine targets — `NOT RUN: requires macOS/Xcode`.
* Any device or simulator run — `NOT RUN: requires iPhone + signing`.
* `git diff --check` was run before commit (see the commit's checks).

---

## 6. Failure-state matrix

The column that matters most for the P0 is the last-but-one: whether the system stop request is sent
while a kernel RPC is wedged. Under the current code the answer is **yes in every row**, because
nothing precedes `stopVPNTunnel()` except a preference write whose failure is captured rather than
thrown.

| User action | System NE status | Kernel / command response | What the UI shows | What the user may still do | Last-good config kept? |
|---|---|---|---|---|---|
| Tap Disconnect | `.connected` | normal | Disconnect → Working… | everything (gate is on the sections only) | n/a |
| Tap Disconnect | `.connected` | `serviceClose` hangs forever | Working…, then after 6 s **Disconnect** again | stop again; the request is already out | n/a |
| Tap Disconnect | `.connected`, On-Demand on | any | as above; a preference failure raises a specific message *after* the request is out | stop again | n/a |
| Tap Disconnect | `.disconnecting`, never settles | any | Working… then **Disconnect** (retry) | retry stop, navigate, open settings | n/a |
| Tap Connect | `.connecting`, never settles | apply wedged | Working… then **Disconnect** | cancel the attempt | yes — nothing was replaced |
| Config update, no reply | unchanged | `sendProviderMessage` never calls back | after 15 s the call ends **unconfirmed** | retry the update deliberately; the tunnel is untouched | yes |
| Config update, apply refused | `.connected` | core reports failure/recovered | alert naming what actually runs; selection restored to the running profile | choose again | yes |
| Profile switch, reload fails | `.connected` | transport/receipt failure | alert + page returns to the profile that is running | choose again | yes |
| Save profile, `update` fails | unchanged | DB error | alert; **form re-enabled** | fix and save again | n/a |
| Save profile, apply fails | unchanged | DB ok, apply refused | alert says the save succeeded and the apply did not | keep editing | body saved |
| Tools page while service is between states | any | `os.ErrInvalid` → `invalid argument` | page shows no data; **no modal**; log carries the text | leave and come back | n/a |
| Tools page, real stream fault | any | transport error | modal with the message | as before | n/a |
| Leave tools page | any | — | — | — | n/a (subscription released) |
| Erase working directory, tunnel up | `.connected` | `stop()` submits | "Service is Running" → stop and continue | confirmed erase only after `.disconnected` | n/a |
| Erase working directory, stop not confirmed | `.disconnecting` past 15 s | — | refusal message; **nothing deleted** | stop from home, retry | yes |
| Background refresh, list unreadable | — | DB error | — | — | task **completed** (`success:false`) |

---

## 7. Working-tree hygiene — the concurrent session

While this work was in progress a **second session** modified files in the same working tree:
`Library/Network/CommandClient.swift` (log pipeline replaced by `LogStore`),
`ApplicationLibrary/Views/Log/{LogView,LogViewModel}.swift`,
`ApplicationLibrary/Views/HakoStyle/HakoLogView.swift`, and it added `Library/Network/LogStore.swift`.

Consequences, and how they were handled:

* Those files are **not** in this commit. Only this task's 18 files were staged, by explicit path.
* The compile comparison in §5.1 does not use the working tree: tree **B** is reconstructed as
  `HEAD + this change set`, so the other session's half-finished refactor cannot be attributed to
  this change (or vice versa).
* The repository's normal `git status` will still show those files as modified after this commit.
  That is the other session's work in progress, not a leak from this one.

---

## 8. Residual real risk

1. **P0 needs a device to be called solved.** The ordering fix is proved from source and type-checks;
   whether iOS releases the VPN slot on a wedged provider is a NetworkExtension behaviour that cannot
   be observed here. Status: `code path fixed, device verification outstanding`. The specific test is
   `docs/APPLE-DEVICE-ACCEPTANCE.md`'s manual matrix, with the added case "connect, force a wedged
   reload, press Disconnect".
2. **A synchronous FFI call cannot be cancelled.** `requestServiceClose()` therefore lets a wedged
   `serviceClose()` run to completion in the background. It holds no lock the app needs and cannot
   block the stop request any more, but the thread is not reclaimable. This is a property of the
   gomobile ABI, not of this fix.
3. **On-Demand re-assertion remains a system behaviour.** Clearing `isOnDemandEnabled` before the stop
   request is what the app can do; if the preferences write fails, the message says the system may
   reconnect it. The app cannot prevent a re-assertion it failed to disable.
4. **`ExtensionPlatformInterface` / `ExtensionProvider` were not compiled here** (stub gap), and A3's
   lock reasoning is static. No change was made to them, so no regression was introduced, but their
   compilation is unverified in this environment.
5. **`NetworkQualityViewModel` and `STUNTestViewModel` keep their start/cancel race** (C2), and
   `HakoOnDemandRulesView` / `HakoPacketTunnelView` / `HakoProfileOverrideView` keep their
   write-then-reconfigure ordering (C8). Both are scoped in the table above.
6. **The two suites that cannot build on Linux** are unverified here for any change, not only this one.

---

## 9. Regression prevention

* **`ProviderReplyGate`** makes the at-most-once rule structural rather than a comment: a reply that
  arrives after the deadline is a no-op instead of a `CheckedContinuation` double-resume trap. Any
  future provider-message call that re-introduces a bare `withCheckedThrowingContinuation` around
  `sendProviderMessage` is visibly different from the two call sites that now share the gate.
* **`SubscriptionOwnership`** is one type for four pages; a fifth page that copies the old
  "store the handle when it arrives" shape will look different from the four that use it.
* **`StatusSubscriptionFailure`** keeps the "is this worth a modal" decision in one place, so a tools
  page cannot reintroduce a raw gRPC modal by writing its own `AlertState(errorMessage:)` for a
  stream error.
* **The localization gate actually blocked this change** — it failed on the new Core-page message
  until the key was added, which is the gate working as designed; the key was added as a surgical
  text insertion so the 757-key catalog keeps its formatting and its other languages.
* **Hako generation hazard.** The files changed under `ApplicationLibrary/Views/HakoStyle/` are
  generated copies (`HakoStartStopButton` from `port_hako_components.py`, `HakoCoreView` from
  `migrate_secondary_page.py`, `HakoHomeView` and `HakoProfilePickerSheet` are manual/patched). This
  change **does not** run any generator, and each edited file keeps its existing header. Re-running
  `port_hako_components.py` or `migrate_secondary_page.py` would overwrite `HakoStartStopButton` and
  `HakoCoreView` — their headers already say "Re-run that rather than editing here", and this change
  is the manual-repair case those headers warn about. **Before the next regeneration, the two edits
  must be carried into the scripts or the generated files must be re-patched**; nothing in this
  commit prevents that loss, and pretending otherwise would be the返祖 this repository has already
  paid for.
