# iOS Debug hitch and diagnostics load — closeout, 2026-11-14

This is the record of one focused round on the iOS client's Debug-build responsiveness: what the
source actually does by default, what was changed, what was measured, and what was not.

**The one-sentence result:** in Debug, the hang watchdog no longer arms its most expensive path by
default and can never take an unbounded number of reports; the log window is no longer a published
property of the object every dashboard card observes; the home page's three mirrors, the start/stop
clock and the foreground report scan are gated on there being something to draw or something that
changed. Release's numbers and every user-visible feature are unchanged. **No frame-rate or CPU
measurement was possible on this machine — see §5 — so nothing here is a claim about measured
performance.**

---

## 1. Baseline, scope and isolation

| Item | Value |
|---|---|
| Repository | `sing-box-for-apple` (fork `Piggy-Cat-bit-shadow/sing-box-for-apple`), `origin` = `https://github.com/Piggy-Cat-bit-shadow/sing-box-for-apple.git` |
| Base | `main` @ `749509f214d97f43cbc66f903fd17b0b50eb6399` when the round started (identical to `origin/main` then, after `git fetch origin` with no `--prune`); rebased onto `dffa979299419ea7153e1b6acbb595d92e4ab7eb`, `main`'s tip when the round ended |
| Branch | `fix/ios-debug-hitch-diagnostics-20261114`, created from that SHA |
| Worktree | `C:\Deepseek\sing-box-for-apple-hitch-debug` — a second worktree, **not** the primary checkout |
| Kernel | untouched. `Libbox.xcframework` is a prebuilt artifact and is not tracked (`.gitignore`: `/Libbox.xcframework/`); no kernel pin moved, no kernel branch was created |
| Build verification | none. This machine is Windows; `xcodebuild` cannot run here (§6) |
| Device / Instruments | none available. Every performance figure is `NOT MEASURED` (§5) |
| Deployment targets (from `project.pbxproj`) | iOS 15.0 (and 16/18/26.2 for other targets), macOS 13.0, tvOS 17.0 |

### 1.1 Why a second worktree

The primary checkout was **not clean** when this round started, and it was being edited at the same
time: 17 modified files and 2 untracked files (`Library/Network/LogStore.swift`,
`ApplicationLibrary/Views/Tools/StatusSubscriptionSupport.swift`), with modification times inside the
45 minutes preceding this session's first command. Those edits overlap this round's subject
(`HakoHomeView.swift`, `HakoLogView.swift`, `HakoStartStopButton.swift`, `CommandClient.swift`,
`ExtensionEnvironments.swift`), so they belong to a different session's in-flight work.

Nothing in that worktree was reset, stashed, checked out, cleaned or committed by this round. The
branch was created in a worktree of its own from the base SHA, which also isolates the untracked
files.

**That work landed on `main` while this branch was being written**, in three commits: `69768a3`
("fix(network,ui): make the system stop request independent of a wedged kernel RPC"), then `221eaab`
and `dffa979`. A third worktree on a third branch
(`fix/ios-screenstate-missed-unlock-recovery-20261114`) exists as well; it touches
`Library/Network/ScreenStateObserver.swift` and nothing this round changed.

The branch was **rebased onto `dffa979`** (that `main` tip) at the end of the round, so it is a
fast-forward of `main` and there is nothing left for a merger to decide. What that integration cost,
recorded because it is the part a later reader cannot reconstruct from the diff:

* Six of the seven commits applied with no conflict at all. `HakoHomeView.swift` merged cleanly even
  though both lines changed it: this branch changed the two `onReceive` mirrors and the disconnect
  clear, and the parallel commits changed the scaffold's `.disabled`, the header, the system-proxy
  closure and the clash-mode call.
* `HakoStartStopButton.swift` conflicted in exactly one place, and it was the place both lines were
  aiming at. `69768a3` had made the busy state a superset of the spinner this branch renders: a
  `VStack` that also offers a "Disconnect" exit once a transition has stopped moving
  (`isTransitionStalled`, `requestStop()`), and it evaluates that stall from this view's `currentTime`
  tick. The resolution keeps that side whole, keeps one `isBusy` (both lines had introduced one, and
  left alone the file would not have compiled), and keeps the gated clock from commit 6.
* The consequence that mattered: gating the tick on "a duration is on screen" would have made the
  emergency exit never appear on the home page — a silent failure with no error and a control that
  never shows up. That is why commit 6 exists, and why the clock's condition counts "a transition is
  in flight" as a reason to tick.
* One comment on the merged side said the tick "is the one-second tick this view already runs for the
  session duration"; it now says what is true after commit 6, because a stale explanation of a timer is
  how the timer gets broken again.
* Everything was re-run on the rebased tree: the boundary gate, the 29 tests, `swiftc -parse` on the 13
  Apple-only files, and the repository's gate set — §6 has the results.
* The evidence for the primary worktree's state at the start (file list, timestamps) is in this round's
  session log; it is not reproduced here because it will be stale by the time anyone reads this.

### 1.2 Why no kernel change

The audit's §3.3 stands and was re-checked: the OOM killer is enabled in the Network Extension, not
in the app process (`Library/Network/ExtensionProvider.swift` vs `Library/Shared/ServiceSetup.swift`),
so `GOGC`/`GOMEMLIMIT` cannot explain "the home page drops frames". Nothing in this round touches
`service/oomkiller`, `experimental/libbox/setup.go`, the 50 MiB budget, TUN, routing, DNS or the
connection pool. The kernel repository was not opened for edits.

---

## 2. Root-cause matrix

Statuses: **fact** = read from source at this base; **inference** = a performance claim the source
supports but this machine could not measure; **untested** = needs a device.

| # | Problem | Cause chain | Source | Status | Fix | Evidence |
|---|---|---|---|---|---|---|
| P0 | A desktop-launched Debug build arms the most expensive observation path by default | `#if DEBUG` replaced Release's constants with 1 s threshold / 5 s cooldown / `Int.max` cap; each report suspends the main thread (`NativeCrashReporter.liveReportText`), calls `LibboxGoroutineDump()` (`runtime.Stack(..., all)`), and rewrites an archive at each of `0, 0.5, 2, 8, 30` s | `Library/Shared/HangWatchdog.swift` (`#if DEBUG` constants at old lines 26–34; `beginReport`, `captureSnapshot`, `goroutineDump`, `persist`); `SFI/ApplicationDelegate.swift:18` | fact for the chain; **inference** for "this is what the user feels" | `HangCapturePolicy` with three *bounded* profiles; Debug's routine profile is 2 s / 60 s / 3; the 1 s profile is opt-in | §3.1; `Tests/HakoDiagnosticsCost` — 13 tests |
| P0b | A report that was refused was still written | `beginReport` called `captureSnapshot` then `persist(includeStacks: true)` unconditionally, and the snapshot ladder did the same; `captureSnapshot` returns early once the main thread has moved on, so the second archive rewrite wrote what the first already had | `HangWatchdog.swift` (old 379, 330–331) | fact | `captureSnapshot` returns whether it captured; callers rewrite only then | §3.1 |
| P1 | Log lines invalidate four dashboard cards, two of them `Canvas` charts | `logBuffer` is `@Published` on `CommandClient`; the four cards read the client through `@EnvironmentObject`, and `@EnvironmentObject` invalidates on *any* published property; the environment subscribes `.log` permanently, so the window flushes every 100 ms whether or not the Logs page is open | `CommandClient.swift` (old 123–127, 306–320, 150); `UploadTrafficCard.swift:6`, `DownloadTrafficCard.swift:6`, `StatusCard.swift:6`, `ConnectionsCard.swift:6`; `HakoHomeView.swift:565/571/599/606`; `ExtensionEnvironments.swift:185` | fact for the chain; **inference** for the frame cost | the window moves to `LogStore`, which only the Logs page observes; publish window 100 ms → 250 ms; first batch still paints immediately | §3.2 |
| P1b | The home page's own body is re-evaluated at 1 Hz for a subtitle | `statusPublisher` and `$groups` write `liveConnectionCount` / `liveGroupCount` unconditionally; `body` is the whole page | `HakoHomeView.swift` (old 220–225) | fact | equality guards on both mirrors, on the mode list, and on the disconnect clear | §3.3 |
| P1c | A one-second timer runs for a value that is never drawn | the start/stop button subscribed `Timer.publish(every: 1, …).autoconnect()` and wrote `currentTime` even when `showsRuntimeDuration == false`, which is what the home page passes | `HakoStartStopButton.swift` (old 95, 166–171); `HakoHomeView.swift:468` | fact | `.task(id: tracksTime)` — no work unless a duration is drawn or a transition is in flight | §3.4 |
| P2 | A foreground return starts the report scans twice and republishes unchanged archives | `onAppear` and `scenePhase → .active` both call `postReload()`; each manager assigns its `@Published` list and count unconditionally, and the environment forwards every manager `objectWillChange` into its own | `SFI/HakoPhoneRootView.swift:171, 226`; `ExtensionEnvironments.swift:233–248, 283–291`; the three managers' `refresh()` | fact | `ReportRefreshGate` coalescing + publish-only-on-change | §3.5; `Tests/HakoDiagnosticsCost` — 6 tests |
| — | GC / OOM budget | not changed, and not implicated: the app process does not enable the OOM killer, so it has no `GOMEMLIMIT`; the extension does, and the extension is a different process | `Library/Shared/ServiceSetup.swift`, `Library/Network/ExtensionProvider.swift` | fact | none, deliberately | §7 |
| — | DNS history, active diagnostics, connection events, Power report | already opt-in, bounded, or default-off | audit §2.1 / §3.5, re-checked | fact | none, deliberately | §7 |

---

## 3. What changed, by cost

Every change below is stated as the work it removes. Where the work cannot be removed without
changing what a user sees, it was not removed.

### 3.1 P0 — the capture budget is a policy, and it is bounded

`Library/Shared/HangCapturePolicy.swift` (new) holds the three numbers `HangWatchdog` used to keep as
a second copy of the constants:

| Profile | Threshold | Cooldown | Reports per process | When |
|---|---|---|---|---|
| `release` | 2 s | 300 s | 3 | every non-Debug build — **unchanged numbers** |
| `debugRoutine` | 2 s | 60 s | 3 | Debug, no opt-in — the new default |
| `debugCapture` | 1 s | 30 s | 3 | Debug, opt-in |

`HangWatchdog` resolves one profile at launch, logs it, and takes every number from it. The
`P_TRACED` gate, the run-loop observers, the lifecycle notifications, the report contents, the
archive layout, the snapshot ladder and the outcome bookkeeping are untouched.

Why each part:

* **The cap is on every profile.** A cooldown is a rate, not a bound: at the old Debug settings a
  process left open for an hour could write twelve reports a minute forever. `maxReportsPerProcess` is
  what makes the worst case finite. There is deliberately no profile with `Int.max`.
* **Debug's routine threshold is Release's.** Two seconds without main-thread progress is a stall in
  an unoptimised build too; the difference is the shorter cooldown, because a Debug session is short.
* **The lower threshold is opt-in.** `debugCapture` is what the report's P0 wanted *available*, not
  what every Debug launch should get.

`captureSnapshot` now reports whether it captured anything, and its two callers rewrite the archive
only when the answer is true. This is the second half of the same problem: a rewrite at the moment the
main thread has recovered is the most expensive possible time to write a file.

### 3.2 P1 — the log window left `CommandClient`

`LogHistory` (new, Foundation-only) owns the retention rule: append, trim to the bound, cumulative
drop count. `LogStore` (new, `ObservableObject`) owns the batch window and the publication.
`CommandClient` keeps a `let logStore` instead of `@Published logBuffer` / `@Published
initialLogsReceived`, and its log callback only forwards to it.

What this removes: a log batch changed a `@Published` property of the object that every dashboard card
reads through `@EnvironmentObject`, so four card bodies — two of which draw a `Canvas` — were
re-evaluated at up to 10 Hz by lines none of them display. Now a batch changes an object that only the
Logs page observes, so the dashboard's cost per log line is **zero**, whether or not the page is open.

What is preserved on purpose:

* the window still retains 3000 lines and still fills whether or not the Logs page is open;
* the backlog still paints immediately on the first batch after a subscription, instead of waiting out
  the window;
* `initialLogsReceived`, `droppedCount`, the pause snapshot, search and level filtering are unchanged;
* `clearLogs()` still exists on the client (the core calls it), and it now clears the store;
* a connection that replaces an earlier one still resets both the window and the loaded flag.

The publication window moves from 100 ms to 250 ms. This is a change in *how often a change is
announced*, not in what is retained, and it is bounded by the fact that the only observer is a page
that is on screen or not.

### 3.3 P1b — the home page's mirrors are written only when they move

`liveGroupCount`, `liveConnectionCount` and `modeList` are mirrored out of the client (it is a nested
observable, so the page cannot read through it in `body` — that is why the mirrors exist). The
publishers fire with a new value object even when the number is the one already on screen, and each
write re-evaluates the whole page. Each mirror now has an equality guard, and the disconnect clear is
also guarded. Nothing about when the values change; only the writes that cannot change what is drawn.

### 3.4 P1c — the start/stop clock exists only while a running time is drawn

The old subscription woke the main run loop once a second for the whole session and wrote a `@State`
that the home page never reads (`showsRuntimeDuration: false`, `isCompact: true`). It is now
`.task(id: tracksTime)`, which schedules nothing when the condition is false and cancels itself when
the condition stops holding. `currentTime` is re-read from the clock when `profile.status` changes, so
displaying the duration never starts from a value carried over from an earlier session.

`tracksTime` is true in two cases, and the second one is not about the duration: a running time is on
screen, or a transition is in flight (`isBusy`, which is also what the body uses to draw "Working…").
The second case exists because a control that can stay busy for seconds must be able to re-evaluate on
its own clock, and because the parallel commit described in §1.1 measures its stop-request grace period
from exactly this tick.

This is the one change in this round with a scheduling behaviour that is not a plain equality guard,
and it is stated as such: on the pages that *do* draw the duration, the clock still ticks once a
second (that is what it is for). The button's label, size, colours, layout and start/stop semantics are
untouched.

### 3.5 P2 — the foreground report scan is one round, and it publishes only changes

`postReload()` now routes the three managers through `ReportRefreshGate`: one round runs, a request
that arrives while it is running is *remembered* and becomes a follow-up round immediately afterwards.
This is deliberately not a time-window throttle — a report written during a scan must not be lost.

Each manager's `refresh()` now assigns its `@Published` list and unread count only when they differ.
The scan itself is unchanged and was already off the main actor (`BlockingIO.run`); what was wrong was
that an unchanged result was announced as a change, into an environment object that forwards every
such announcement to the root's invalidation.

---

## 4. What was found and deliberately not fixed

| Item | Why it is not in this round |
|---|---|
| `ExtensionEnvironments` still forwards all three managers' `objectWillChange` wholesale | With publish-only-on-change this now costs one invalidation per *real* report change. Narrowing the root's dependency to an unread summary is a genuine improvement and a bigger change than this round's budget; recorded as a follow-up. |
| `CrashReportManager.refresh()` reads every archived report's contents in `coalesceArchivedCrashReports()` before deciding there is nothing to merge | Real I/O, but on a background queue and once per real refresh. A metadata-only pre-scan would be the fix; without a measurement of how many reports a real device holds, this would be optimising an unquantified cost. |
| `postReload()` still calls `ExtensionProfile.load()` on every foreground return | It is one NetworkExtension IPC call, not a scan; the same gate could cover it, but the current `reload()` already refuses to replace a live profile. Left alone to keep this round's diff readable. |
| The home page clears `liveConnectionCount` on disconnect but not `liveGroupCount` | The Proxies row's gate is `liveGroupCount > 0`, and the client's own `groups` are not cleared on disconnect either, so the two agree. Whether the row should disappear when the tunnel stops is a product decision, not a performance fix. |
| `HangWatchdog`'s report ladder still takes five snapshots per report | It only runs while the main thread is *still* stalled, and the cap now bounds how often a report can start at all. Reducing it further would remove information from real hangs for a saving that cannot be measured here. |

---

## 5. Performance: `NOT MEASURED`

No iOS device, simulator or Instruments session was available on this machine (Windows, no Xcode).
**Nothing in this document is a measurement of frame time, CPU share or hitch count.** The user's
`log.level` A/B (about 7 % → 2 % CPU) is a *previous* observation and is not claimed as this round's
result.

What can be stated as a static path argument, each line traceable to §3:

| Path | Before | After | Basis |
|---|---|---|---|
| Log window publishes | ≤ 10 per second | ≤ 4 per second | batch window 100 ms → 250 ms |
| View bodies invalidated by a log window change | the 4 dashboard cards (2 with `Canvas`), plus anything else observing `CommandClient`, even with no Logs page open | the Logs page only, and only while it is on screen | the store boundary; `LogStore` is named only by the log path (enforced by the gate) |
| Home page `body` evaluations caused by status/groups/mode-list mirrors | up to 1 per second plus one per groups/ mode-list publish | only when the count, label or list actually changes | equality guards |
| Main-run-loop wake-ups from the start/stop clock | 1 per second, for the whole session | 0 while idle with no running time drawn (the home page's configuration, its normal state); 1 per second only while a duration is drawn or a transition is in flight | `.task(id:)` |
| Report-archive rounds started per foreground return | up to 2, one per trigger | 1, plus 1 follow-up only if a second trigger arrives while the first is running | `ReportRefreshGate` |
| Report publishes per unchanged refresh | 6 (3 managers × list + count) | 0 | publish-only-on-change |

### 5.1 What the log-level A/B would mean for this change

At `debug` the kernel produces far more lines than at `error`. Per line, the costs are: generation and
formatting inside the Go core (not in this repository), IPC framing into the app, an allocation on the
client's callback thread, an append into the window, and — before this round — a SwiftUI invalidation
of four cards. After this round the last term is zero when the Logs page is closed and bounded at 4 Hz
when it is open. So the fix is expected to move the *app-side* share of the 7 % → 2 % gap, and is not
expected to change the kernel-side share at all. That is a hypothesis with a source-level argument, not
a measurement.

If someone can run the matrix, the interesting comparisons are, in order: desktop-launched Debug with
`log.level=error` and the Logs page closed (should be the floor); the same with `debug` (the app-side
delta this round removed); the same with the Logs page open (the page's own cost); and Xcode-attached
Debug (watchdog disabled by `P_TRACED`, so it is a different experiment, not a control).

---

## 6. Tests

### 6.1 What runs on this machine, and how

The repository's SwiftPM packages compile the *shipped* source files through git symlinks
(`scripts/link-test-sources.sh`). A Windows checkout materialises those symlinks as one-line text
placeholders, so the packages cannot be built in place. Two harnesses were used, both **outside the
repository**, and neither is part of this branch:

* **materialise-only** (for packages whose tests do not read app files): copy the package to a scratch
  directory and replace each placeholder with the file it names.
* **reroot** (for packages whose tests read app files by relative path): the same, in a directory that
  reproduces the checkout's depth (`Tests/<pkg>/Tests/<suite>/…` is four levels below the root), with
  `Library`, `ApplicationLibrary` and `SFI` joined to the real checkout.

Both compile `Library/` files verbatim. Neither can compile anything that imports SwiftUI, Combine,
Libbox or NetworkExtension — which is the whole reason the changed decisions live in Foundation-only
files.

Toolchain: `swift 6.3.3 (swift-6.3.3-RELEASE)`, target `x86_64-unknown-windows-msvc`.

On a machine with Xcode the same packages run as they are:

```bash
bash scripts/run-diagnostics-cost-tests.sh          # the new package
bash scripts/run-config-ownership-tests.sh          # and the other run-*-tests.sh scripts
python scripts/dev/check_hako_diagnostics_boundaries.py
python scripts/dev/check_swift_structure.py <changed Swift files>
```

| Package | Tests | Result | Notes |
|---|---:|---|---|
| `Tests/HakoDiagnosticsCost` (**new**) | 29 | **PASS** | the three new policies/boundaries |
| `Tests/HakoCommandSubscription` | 13 | **PASS** | existing |
| `Tests/HakoScreenState` | 48 | **PASS** | existing |
| `Tests/HakoInterfaceStartup` | 13 | **PASS** | existing; needs the reroot harness (its tests read app files by path) |
| `Tests/HakoConfigurationOwnership` | 116 | **PASS** | existing |
| `Tests/SubscriptionQuotaCaption` | 10 | **PASS** | existing |
| `Tests/HakoSubscriptionUsage` | — | **BLOCKED (environment)** | its `Sources/Libbox/LibboxStub.swift:11` declares a libbox stub with `NSErrorPointer`, which swift-corelibs-foundation on Windows does not export. Unrelated to this branch; needs macOS. |

The new package's 29 tests are the executable form of this round's decisions: Release's numbers are
unchanged; Debug's default is bounded and is not 1 s / 5 s / unbounded; the opt-in lowers the threshold
without lifting the cap; no profile is unbounded or degenerate; the capture work a profile can reach
inside a minute is bounded; both activation switches are honoured with the spellings a person types;
the refresh gate merges a burst into exactly one follow-up and loses no request; and the log window's
retention, drop count and "did anything change" answers hold at and past the bound.

### 6.2 Repository gates

| Gate | Result |
|---|---|
| `scripts/dev/check_hako_diagnostics_boundaries.py` (**new**) | **PASS** — and each of its four invariants was shown to fail the gate when reverted (published log window, unguarded home mirror, unbounded profile, unconditional timer) |
| `scripts/dev/check_swift_structure.py <changed files>` | **PASS** — "all 13 target(s) structurally balanced" for the app sources the branch changes (17 when the package's Swift files are included) |
| `scripts/dev/check_hako_command_channel.py` | **PASS** — 58 phone files |
| `scripts/dev/check_hako_platform_symbols.py` | **PASS** — 58 Hako files, 25 gated members |
| `scripts/dev/check_localization.py` | **PASS** — 512 strings, 0 pending |
| `scripts/dev/check_hako_profile_switch.py` | **PASS** |
| `scripts/dev/check_compact_mode_picker.py` | **PASS** — 10 cases |
| `scripts/dev/guard_hako_platform_modifiers.py` | **PASS** — 56 files, 0 would-guard |
| `scripts/dev/guard_export_profile.py` | **PASS** (dry run) — 2 of 2 wrapped |
| `scripts/dev/check_generated_headers.py` | **PASS** — 33 headers |
| `scripts/dev/check_platform_structure.py` | **PASS** |
| `scripts/dev/check_commit_messages.py` | **PASS** on this branch's range (no BOM) |
| `scripts/dev/check_swift_test_sources.py` | **FAIL, and identical on `main` at `dffa979`** — see below |
| `scripts/dev/gate_hako_platform_imports.py` | **FAIL, and identical on `main` at `dffa979`** — `checked=56 errors=0 undecidable=62`; every finding is an `NS*` type its platform facts cannot decide for tvOS (`NSFontManager`, `NSFont`, `NSView`, `NSColor`, …). Pre-existing, and this branch adds no finding: the two runs' outputs differ only in the scope path. |

The last two are red on `main` itself. Both were run against a second worktree at `dffa979` (the
commit this branch is based on) and compared: `gate_hako_platform_imports.py` produces the same 56
files and the same 62 undecidable findings, and `check_swift_test_sources.py` produces the same six
problems.

`check_swift_test_sources.py` was investigated further rather than written off as a Windows artifact:
a reroot was built with the test packages' symlinked sources materialised into real files, and it
still reports the same six problems, all inside `Tests/HakoScreenState` and all defects of the gate's
own tables — `DispatchSemaphore` and `Thread` are missing from its `SDK_NAMES`, the generic parameter
`T` is read as a type name, and three ALL-CAPS test constants are read as type names. Nothing in those
files is changed by this branch. Fixing that gate is a separate change and deliberately not folded in
here.

### 6.3 Blocked

| Item | Why |
|---|---|
| `xcodebuild` for SFI / SFM / SFT (Debug and Release) | no Xcode on this machine |
| SFI/SFM/SFT UI tests, snapshot tests, `-FASTLANE_SNAPSHOT` fixtures | same |
| Instruments: Animation Hitches, Time Profiler, extension-process sampling | same |
| Device matrix of §5.1 (standalone Debug, attached Debug, `log.level` levels, Logs page open/closed, repeated foregrounding) | same |

Reports for a SwiftUI body count or a hitched frame are therefore absent on purpose. The gate and the
unit tests prove the wiring; only a device can prove the experience.

### 6.4 Syntax of the files only Xcode can compile

The 13 changed Swift files that import SwiftUI, Combine, Libbox or NetworkExtension were each run
through `swiftc -parse` with the same toolchain: all 13 parse, 0 failures. That is a syntax check and
nothing more — it cannot see a missing member, a wrong argument label or a type mismatch, and it says
nothing about whether the Apple targets build. It exists because a whole-file rewrite of a 1000-line
SwiftUI view is exactly the kind of edit that breaks a brace or a `guard` without a compiler noticing
on this host, and `check_swift_structure.py` only counts delimiters.

---

## 7. Compatibility and semantics

**Debug.** Installs the watchdog with `debugRoutine` (2 s / 60 s / 3). The opt-in lowers the threshold
to 1 s (`debugCapture`, 30 s / 3). Activation: `ENABLE_HANG_WATCHDOG=1` in the process environment, or
the persisted `hako.debug.hang_watchdog` `UserDefaults` flag. The environment variable is usable in the
target scenario — a launch that is not a debugger attach — through
`xcrun devicectl device process launch --environment-variables '{"ENABLE_HANG_WATCHDOG":"1"}' …`, which
launches the app on the device without attaching, so the `P_TRACED` gate stays out of the way. On a
simulator, `SIMCTL_CHILD_ENABLE_HANG_WATCHDOG=1` before `xcrun simctl launch` does the same. **What is
not true:** an Xcode scheme environment variable cannot arm it, because Xcode attaches a debugger and
`P_TRACED` disables the watchdog entirely — that gate is unchanged and deliberate.

**Release.** `HangCapturePolicy.release` is 2 s / 300 s / 3 — the numbers Release already used. Nothing
else in this round is conditional on the build configuration.

**macOS / tvOS.** `HangWatchdog` still compiles for all three platforms; the policy is Foundation only;
the `kinfo_proc`/`P_TRACED` path, the lifecycle observers and the report format are untouched. The
start/stop change is in the phone's own button, which macOS and tvOS never instantiate (they use
upstream's `StartStopButton`, untouched).

**Logs.** Retention (3000), the loaded-backlog flag, the drop count, pause, search, level filtering,
clearing and the immediate first paint are preserved. The publication window is 250 ms; the first batch
after a subscription is still published immediately. The page observes the store instead of the client
— the page's own model is the only observer.

**Reports.** Archives, unread counts, read markers, badge counts, the `reportReceived` path and the
three pages are unchanged. The only difference is that an unchanged rescan no longer announces itself,
and two triggers that fire together no longer start two scans.

**Profile / mode / tunnel.** No state machine, connection, mode or profile-selection code was touched.
The only change near them is that the home page no longer writes identical values into its mirrors, and
that the mode list is not reassigned when it is equal. The historical regressions the repository guards
— profile switching that must actually switch, mode switching driven by the client's publisher rather
than by a parent's re-evaluation — are untouched by construction, and `check_hako_profile_switch.py`
and `check_compact_mode_picker.py` still pass.

**Visual.** No layout, colour, typography, icon, spacing, animation or copy change. The start/stop
label draws the same string from the same `Date` and `connectedDate`; it now simply is not recomputed
when it is not on screen. No new page, toggle, badge or debug surface was added.

---

## 8. Risk and rollback

| Risk | Who can be affected | Mitigation in this branch |
|---|---|---|
| Something depended on `CommandClient.objectWillChange` firing for log lines | a view that shows log content but was not updated | the only consumers of log state are `LogDataModel` (updated) and the two Logs pages through it; `check_hako_diagnostics_boundaries.py` restricts which files may name `LogStore`, so a new observer has to be a deliberate edit. Still: the Logs page has no automated UI test here, so this is the one change that needs a device look. |
| `.task(id:)` and the duration label disagree about when to tick | a page that draws the duration, or one waiting out a transition | the duration branch uses the same predicate as `tracksTime`; the busy case is read through the same `isBusy` property the body uses, so the two cannot drift |
| A coalesced refresh delays a report by one round | the report badge and list | the gate never drops a request; the follow-up starts as soon as the running round ends |
| An unchanged-looking archive change is missed by publish-only-on-change | the report list | the comparison is the whole list, not a count or a timestamp: any added, removed or re-read report differs and publishes |
| Debug hang reports become rarer than before | someone debugging a hang in a Debug build | that is the intent; the opt-in restores the 1 s threshold and the log line at install states the active numbers |

Rollback is per commit (§9): the fix, the two perf commits and the report commit are independent of
each other, and `git revert` of any one of them leaves the others coherent. The test commit is the one
exception and it is stated as such: its package compiles the files the fix and the perf commits add, so
it has to be reverted first when unwinding those (reverting it alone leaves a package whose sources no
longer exist, which fails to build rather than misbehaving). There is no schema, archive format,
persisted key or migration involved. The one persisted thing this round reads is an optional
`UserDefaults` key that is absent by default and ignored by Release.

---

## 9. Commits

See `git log dffa979..HEAD` on the branch — seven commits on top of `main`'s tip. They are, in
order:

1. `fix(apple): bound debug hang watchdog capture` — `HangCapturePolicy`, `HangWatchdog`, the refused
   capture/rewrite.
2. `perf(apple): isolate high-frequency log observation from dashboard` — `LogHistory`, `LogStore`,
   `CommandClient`, `LogViewModel`.
3. `perf(apple): avoid redundant home state and runtime timer updates` — `HakoHomeView`,
   `HakoStartStopButton`.
4. `perf(apple): coalesce foreground report refresh` — `ReportRefreshGate`, the three managers,
   `ExtensionEnvironments`.
5. `test(apple): cover debug diagnostics and observation boundaries` — `Tests/HakoDiagnosticsCost`,
   `scripts/link-test-sources.sh`, `scripts/run-diagnostics-cost-tests.sh`,
   `scripts/dev/check_hako_diagnostics_boundaries.py`.
6. `perf(apple): keep the start/stop clock while a transition is in flight` — the busy case in
   `HakoStartStopButton`, and the interaction with `main`'s `69768a3` (§1.1).
7. `docs(apple): audit iOS debug hitch remediation and residual risks` — this file.

Each commit's message states the cost it removes and the evidence for it.

---

## 10. What is still open

1. **Device verification.** Nothing here has been run on a phone. The two experiments worth doing
   first: a desktop-launched Debug build with `log.level=error` and the Logs page closed, scrolled for
   30 s, against the same build at `debug`; and a foreground/background cycle with the report badge
   visible, checking that the badge updates and the archive list does not flicker.
2. **Instruments.** Time Profiler on the four card bodies and the two `Canvas` drawings, to confirm the
   log window is no longer in their invalidation path; Animation Hitches to see whether the remaining
   hitches line up with the 1 Hz status publish or with the kernel's own work.
3. **Two repository gates are red on `main`** — `check_swift_test_sources.py` (six name-table
   defects in its own scanner, reproduced with materialised sources) and
   `gate_hako_platform_imports.py` (62 tvOS availability questions its facts cannot decide). Both are
   documented in §6.2 and both are unchanged by this branch; fixing them is a separate change.
4. **Merging the branch.** It is based on `main`'s tip `dffa979` and needs no conflict resolution;
   the only thing to keep in place when it is merged is commit 6, because it is what keeps `main`'s
   stop-request emergency exit ticking (§1.1).
5. **The extension process.** If the device shows a tunnel that gets hot after several minutes rather
   than a home page that drops frames, that is the OOM/GC question the audit deferred, and it is not
   this branch.
