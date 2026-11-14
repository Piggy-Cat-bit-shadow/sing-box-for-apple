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
| `ApplicationLibrary/Views/Tools/{NetworkQuality,STUN}TestViewModel.swift` | same late-handle leak for a **running test**; force-unwrapped test object; socket-opening FFI off the main thread |
| `ApplicationLibrary/Views/Tools/StatusSubscriptionSupport.swift` | **new** — the ownership token and the error classification those four share |
| `ApplicationLibrary/Views/HakoStyle/HakoProfileOverrideView.swift` | refused override no longer shows as applied |
| `ApplicationLibrary/Views/HakoStyle/HakoPacketTunnelView.swift` | same, for the six tunnel-routing switches |
| `ApplicationLibrary/Views/HakoStyle/HakoOnDemandRulesView.swift` | same, for the On-Demand mode |
| `ApplicationLibrary/Views/Setting/{ProfileOverride,PacketTunnel,OnDemandRules}View.swift` | the same three fixes on the shared iPad/macOS counterparts |
| `Localizable.xcstrings` | one new key (en + zh-Hans) for the new Core-page refusal message |

`git diff --stat 749509f..HEAD` for the set: **25 files changed, +1065 / −146**, plus one new file.

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
| **A1** | `FIXED + verification pending` | `ExtensionProfile.stop()` — order is now *clear On-Demand (best effort) → `stopVPNTunnel()` → best-effort kernel close*. Nothing can throw or await before the system request. The force-unwrap is gone. The close is a single, tracked, non-awaited detached call. **The ordering property itself is verified from source** (no `await` and no `throw` precedes the request on any path); whether iOS then releases the slot is NetworkExtension behaviour, so the user-visible outcome is device-pending, exactly like A2. |
| **A2** | `FIXED + verification pending` | `HakoStartStopButton.HakoToggleConnectionButton` — after a 6 s grace the busy row grows a **Disconnect** button that always calls `stop()`, never the start/stop toggle. `HakoHomeView` — the page-wide `.disabled` became `pageIsBusy` applied per section; the header's primary action and `pageAlert` stay live, the profile button stays gated. |
| **A3** | `NOT A BUG + evidence` | `ExtensionProvider.startService/stopService/stopTunnel`. Lock graph and reachability recorded above. The blocking *consequence* users saw was fixed in A1. No lock change: `NSRecursiveLock` would mask, deletion would corrupt. |
| **B1** | `FIXED + verified` | `ExtensionProfile.requestProviderMessage` + `ProviderReplyGate` + `applyReplyTimeout (15 s)`. `reloadService(_:)` can no longer hang forever; `currentTunnelSessionID` no longer uses `withTaskGroup` (whose `cancelAll()` cannot resume a suspended continuation) and no longer inherits the stale-continuation defect. Reply, late reply, throw and deadline are one gate with exactly one resume. |
| **B2** | `FIXED + verified` | `EditProfileViewModel.saveProfile` — `defer { isLoading = false }` on every path, and save / schedule / apply are three separately reported facts. |
| **B3** | `FIXED + verified` | `OverviewViewModel.setSystemProxyEnabled` — `reasserting` cleared on the failure path; the preference is rolled back when the apply fails; the command client is no longer force-unwrapped. `HakoHomeView` re-reads the persisted value so the row stops showing a state the tunnel never entered. |
| **B4** | `FIXED + verified` | `OverviewViewModel.switchProfile` — the selection is still persisted first (the reload reads it from preferences), but a refused apply now restores the previous identifier under an **ownership guard**: only while the persisted value is still this call's write. The same-profile no-op no longer reloads. |
| **B5** | `NOT A BUG + evidence` | `Library/Database/Profile+Update.swift` — traced the whole chain the audit names. `refreshRemoteProfile` (`:550`) returns `downloadFailed` / `invalidConfig` **before** `RemoteRefreshApplier.applyReporting` is reached (`:609`, `:598` vs `:626`), so a failed download or a rejected body never persists and never touches the live tunnel: last-good is preserved by construction, not by a guard that could be forgotten. `superseded` is caught as a result and explicitly not retried (`:654`). The body is committed in one critical section (`commitBody`, `:364`), whose compare-and-swap returns `superseded(storedRevision:)` rather than overwriting a newer write. `applyUnconfirmed` exists as the "no receipt" outcome (`:306`). One observation recorded, not changed: the generic `catch` at `:609` labels an unexpected error from `evaluate` as `downloadFailed`; the message carries the real text and nothing claims success, so the label is cosmetic and changing it would touch the reporting vocabulary the tests pin. |
| **B6** | `FIXED + verified` | `HakoProfilePickerSheet` — all four optimistic mutation sites (legacy + iOS 26 move/delete) now reject an error into an alert and restore the previous list, **guarded**: the restore happens only while the list is still exactly what that change produced, so a second edit is never undone by the first edit's failure. The `// Handle error silently` comments are gone. |
| **B7** | `FIXED + verified` | `NewProfileViewModel` — `createProfileBackground()` returns the scheduling error instead of throwing it, so a profile that `ProfileManager.create` already wrote is never reported as a failed creation; the registration failure is logged with the profile id and does not block `profileUpdate` or dismissal. |
| **C1** | `FIXED + verified` | `TailscaleStatusViewModel` + `StatusSubscriptionSupport` — (a) a handle that arrives after `cancel()` is closed instead of adopted; (b) stream errors are classified: `serviceNotRunning` / `unsupportedByCore` are logged, never modal; a genuine fault still alerts. **Kernel evidence for the classification** in §4.1. |
| **C2** | `FIXED + verified` | `ConnectionLifecycleObserver` releases on `onDisappear`; `Tailscale`/`OpenVPN`/`OpenConnect`/`USBIP` share one ownership token, and `NetworkQualityViewModel` / `STUNTestViewModel` got the same treatment for their **start** race: a session that arrives after `cancel()` is closed instead of adopted. Those last two matter more than the streams, because an adopted test keeps putting traffic on the wire. |
| **C3** | `NOT A BUG + evidence` | `AlertState` and the Hako alert folding: `HakoHomeView` already folds two sources into one `pageAlert` binding and clears both on dismissal; no page in this change set uses the `alert(_:isLoading:)` overload whose condition can strand an alert. The defect this item warns about (a section-scoped presentation being dropped) is not present in the current code. |
| **C4** | `FIXED + verified` | `UIProfileUpdateTask.getAndUpdateProfiles` — `setTaskCompleted` now runs on **every** exit (unreadable list → `false`, empty list → `true`), and `expirationHandler` is installed before any work starts instead of after it finished. |
| **C5** | `FIXED + verified` | `ExtensionEnvironments.reload()` — a throw is no longer discarded by `try?`: it sets `profileLoadFailure`, keeps the previously loaded profile, and logs. `nil` (no manager at all) is still "no tunnel installed". |
| **C6** | `FIXED + verified` | `HakoCoreView` — `extensionProfile!` replaced by a `guard let`; and the working directory is erased only after the system publishes `.disconnected`, with a 15 s bound and a refusal (not a deletion) on timeout. |
| **C7** | `FIXED + verified` | Four main-actor blocking sites moved to `Task.detached`, returning to the actor only for state: `HakoHomeView.selectClashMode`, `ConnectionListViewModel.closeAllConnections`, and the standalone `start(...)` of `NetworkQualityViewModel` / `STUNTestViewModel` (which ran a socket-opening FFI call on the main thread from a view callback). This is the set the audit named plus the two it did not; it is not a repository-wide audit of every sync-FFI call site. |
| **C8** | `FIXED + verified` | All three pages, phone **and** shared: `HakoProfileOverrideView` + `ProfileOverrideView`, `HakoPacketTunnelView` + `PacketTunnelView`, `HakoOnDemandRulesView` + `OnDemandRulesView`. Each toggle now reads the previously stored value, writes, applies, and **restores both the preference and the switch** if the apply is refused; the On-Demand mode additionally restores the page's own `mode`. The shared pages were fixed too because an iPad and a Mac load them - fixing only `HakoStyle` would have left the same defect on two other surfaces. A refused *rules* edit keeps the edited rules (they are stored and the next start installs them) and reports the system write failure. |

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

### 4.6 A running probe that could outlive its page

`NetworkQualityViewModel.startTest` and `STUNTestViewModel.startTest` had the status-subscription race
in a worse form: the handle they adopt is a **running test**, not a passive stream, and it was stored
into a view model that had already cancelled. Nothing then held a handle to stop it, so a Network
Quality test could keep generating traffic after the reader left the page. Both also force-unwrapped
the standalone test object (`LibboxNewNetworkQualityTest()!`, `LibboxNewSTUNTest()!`) on the
not-connected branch, and started it with a synchronous FFI call on the main actor.

### 4.7 The three settings pages disagreed with the system in both directions

`ProfileOverride`, `PacketTunnel` and `OnDemandRules` all wrote the preference and then applied it,
and reported an apply failure with an alert while leaving the switch, the preference and the page's
own mode on the new value. The tunnel kept the old one. The shared (iPad/macOS) copies had exactly the
same defect, so fixing only `HakoStyle/` would have corrected one of three surfaces.

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

### 5.3 Repository gates — executed

| Gate | Result |
|---|---|
| `python scripts/dev/check_localization.py` | **PASS** — 516 visible strings across 58 fork-owned files resolve to a catalog key with `en` and `zh-Hans`; 27 exempt as technical terms; **0 pending** |
| `python scripts/dev/check_hako_profile_switch.py` | **PASS** — 6 cases, including "failed switch releases the gate" and "one presentation per phone view" |
| `python scripts/dev/test_hako_ui_gates.py` | **PASS** — 26 mutation cases (the gates catch the faults they exist for) |
| `python scripts/dev/check_generated_headers.py` (with `DSH_GIT`/`DSH_REPO`) | **PASS** — 33 portable headers, 33 naming a path that exists at the pin, 0 missing |
| `python scripts/dev/test_port_script_authorization.py` | **FAIL — 4 of 6 cases, and already failing at `749509f`** (see below) |
| `python scripts/dev/check_swift_test_sources.py` | **FAIL — already failing at `749509f`** (flags `DispatchSemaphore`/`Thread` as "declared nowhere in this repository") |

The last two, and `check_generated_headers.py` when run without the overrides, are **red at the
pre-change commit**. That was checked rather than assumed: the same three gates were run against a
`git archive 749509f` tree and produced the same failures. `check_generated_headers.py` hardcodes
`C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe`, a path that does not exist on this machine; it
honours `DSH_GIT`, and with the real git it passes, which is why it is listed as a PASS above and as
an environment failure in the residual-risk section. No gate that passed before this change fails
after it.

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
5. **The two suites that cannot build on Linux** are unverified here for any change, not only this one.
6. **Three repository gates were already red before this change** (`test_port_script_authorization.py`,
   `check_swift_test_sources.py`, and `check_generated_headers.py` without its `DSH_GIT` override).
   They are not silent: nothing here claims them as passing, and the last one is a hardcoded Windows
   path that any checkout not at `C:\Deepseek\IOS客户端` will trip over.
7. **The two hand-repaired generated pages will relapse on regeneration.** See §9 - the repair is
   recorded in each file's header, and nothing mechanical re-applies it.

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
* **Hako generation hazard.** Of the edited files under `ApplicationLibrary/Views/HakoStyle/`, exactly
  **two are generated copies**: `HakoStartStopButton.swift` (`scripts/dev/port_hako_components.py`) and
  `HakoCoreView.swift` (`scripts/dev/migrate_secondary_page.py`). `HakoHomeView.swift`,
  `HakoProfilePickerSheet.swift`, `HakoProfileOverrideView.swift`, `HakoPacketTunnelView.swift` and
  `HakoOnDemandRulesView.swift` carry no generated-header provenance and are treated as owned source.
  This change runs **no generator**, and each edited file keeps its header.

  For the two generated files the header now records the hand repair and says explicitly that
  re-applying the generator will lose it, with a pointer to this document. That is a note for a
  maintainer, **not** a mechanism: nothing re-applies the patch. Carrying the two repairs into
  `port_hako_components.py` and `migrate_secondary_page.py` (or into a `restore_*.py` in the style of
  `restore_core_view_guards.py`) is the durable fix and is not done here, because those scripts are
  themselves guarded by the 26 mutation cases in `test_hako_ui_gates.py` and changing them without
  being able to run the port end to end would be the larger risk.

  `check_generated_headers.py` still passes after the header notes (33 of 33 headers name a path that
  exists at the pin), so the notes did not damage provenance.
