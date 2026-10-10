# Screen state and lock state: the facts, the contract, and what is still unknown

> **Second-phase verification.** This file replaces the phase-1 report's account of upstream's
> behaviour, which was wrong in a way that mattered. Everything below is read from source at the
> commits named, not inferred from comments.

---

## 1. The correction

Phase 1 (`docs/APPLE-ARCHITECTURE-AUDIT.md` §5.2) said upstream's observer published a failed
`notify_get_state` as `recordLockState(false)`, which on this core is
`Box.LockStateChanged(false)` → `lifecycle.woke()` → the pause is lifted.

**That is wrong twice, and both corrections are load-bearing.**

1. **Upstream never calls `recordLockState` at all.** It does not exist in the upstream kernel:
   `SagerNet/sing-box` `experimental/libbox/command_server.go` declares `Pause`, `Wake`, `WakeNow`
   and `RecordScreenState`, and nothing else in that family.
2. Upstream registers **one** notification name, `com.apple.iokit.hid.displayStatus`. It never
   observes `com.apple.springboard.lockstate`, so it has no lock axis to report.

The real upstream observer, at `SagerNet/sing-box-for-apple` @ `089d35e`, is 19 lines:

```swift
notify_register_dispatch("com.apple.iokit.hid.displayStatus", &displayToken, queue) { token in
    var state: UInt64 = 0
    notify_get_state(token, &state)            // status discarded
    commandServer.recordScreenState(state == 1)
    if state == 1 {
        commandServer.wakeNow()                // <-- the defect
    }
}
```

### What the defect actually is

`wakeNow()` in the upstream kernel is `instance.PauseManager().DeviceWake()` - the only call that
lifts the device pause. The client calls it on **display on**.

On iOS a push notification lights the lock screen. So does raise-to-wake. So does a notification the
user glanced at and dismissed. Each of those released the pause - and therefore health checks,
URLTests and provider refreshes - for a phone in a pocket. Upstream's own superproject says so, in
`box_lifecycle.go`:

> A DISPLAY TURNING ON IS NOT AN UNLOCK. On iOS a push notification lights the lock screen; so does
> raise-to-wake; so does a notification the user glanced at and dismissed. Treating any of those as
> "the device is usable" releases health checks, URLTests and provider refreshes for a phone in a
> pocket, which is the wake storm the power policy exists to prevent.

The discarded status code is a **second, smaller** defect: a failed read leaves `state` at its `0`
initialiser, which maps to `false`, so a failed read published `recordScreenState(false)` - a
display-off claim nobody observed. It could not produce an unlock. It produced a wrong display fact.

---

## 2. The two kernels, side by side

This fork's client ships against the **parent repository's** kernel
(`Piggy-Cat-bit-shadow/sing-box`, default branch `testing`), not upstream's. They differ on exactly
the axis this file is about, and the difference is deliberate.

| Kernel API | `SagerNet/sing-box` | `Piggy-Cat-bit-shadow/sing-box` |
|---|---|---|
| `RecordScreenState(on:)` | writes the power report only; **does not touch the pause axis** | + `Box.ScreenStateChanged(on)`; `on` = resume **EDGE** only |
| `RecordLockState(locked:)` | **does not exist** | + `Box.LockStateChanged(locked)`; `false` = resume edge **and the LEVEL WAKE** |
| `WakeNow()` | `PauseManager().DeviceWake()` - the only level release | still present; narrowed to "a wake the platform confirmed by other means" |
| `Wake()` | on iOS: power report only, returns early | publishes the reuse edge; does not lift the level |
| `Pause()` | level pause; `CloseIdleConnections()` on every screen-off | sleep edge + level; pool released later by the DEEP_IDLE transition |

The parent kernel documents the contract this client has to satisfy, in `box_lifecycle.go`:

```
sleep()          the device is going to sleep.  -> the sleep EDGE and the device LEVEL pause
wake()           the extension ran again.        -> the resume EDGE only
displayStatus    the display is on / off.        -> off: the sleep EDGE and the level pause
                                                    on:  the resume EDGE only
lockstate        the device is locked / unlocked. -> locked:   the sleep EDGE and the level pause
                                                    unlocked: the resume EDGE and the LEVEL WAKE
```

and it names the missing client half explicitly:

> Before this file, the Apple level had no lift at all: the pause manager's device axis is a level,
> `Wake()` never moved it on iOS (correctly, because a resume is not a wake), and the shipped client
> never called the one method that did. So the level was entered on the first sleep and held for the
> life of the process … A platform that reports no such fact keeps the latch, and that is stated as a
> limitation rather than papered over with a guess: see the client patch in
> `docs/fork/apple-screen-state-observer.md`.

**Conclusion.** Phase 1's client change is not a fork invention layered on a kernel that did not ask
for it. It is the client half of a contract the kernel had already written down and was waiting for.
The phase-1 *justification* was wrong; the *change* was right.

---

## 3. What this client does now, against that contract

`Library/Network/ScreenStateObserver.swift`, plus the Darwin adapter in
`ScreenStateObserverDarwin.swift`. The mapping, as the code states it:

| Fact | Publisher call | Kernel | Effect |
|---|---|---|---|
| display on | `recordScreenState(on: true)` | `Box.ScreenStateChanged(true)` | resume **EDGE** only |
| display off | `recordScreenState(on: false)` | `Box.ScreenStateChanged(false)` | sleep edge + level pause |
| locked | `recordLockState(locked: true)` | `Box.LockStateChanged(true)` | sleep edge + level pause |
| unlocked | `recordLockState(locked: false)` | `Box.LockStateChanged(false)` | resume edge + **level wake** |

`ScreenStatePublishing` deliberately does **not** offer `wakeNow()`. A publisher that did would be
offering a way to turn a lit lock screen into a wake storm, and the type is the place to make that
unrepresentable rather than to rely on nobody calling it.

### Availability, stated honestly

Neither notification name is public API. `com.apple.iokit.hid.displayStatus` and
`com.apple.springboard.lockstate` are undocumented Darwin notifications; upstream depends on the
first, and this client depends on both. Whether either is posted **to a sandboxed NetworkExtension**
differs by iOS release and **cannot be established from source**.

That is why `ScreenStateStartResult.failed` carries the notification names out of `start()` instead
of only logging a boolean: a device log saying which name failed is the only evidence that question
has. This is `UNVERIFIED_SDK` until then.

---

## 4. The three fault scenarios the phase-2 brief asks about

Verified against the source and by the tests in `Tests/HakoScreenState` (§5).

### 4.1 Partial registration — `FIXED_WITH_TEST` (fail-closed, and it is the right choice here)

`start()` attempts both names, and if **either** fails it cancels the one that succeeded and reports
`failed(sources:)`. Half-registered is refused.

Is fail-closed right? Yes, and the reason is sharper than "both or nothing":

- The **lock** axis is the only source of a level wake. Without it, `Pause()` still pauses on sleep
  and on display-off, and nothing ever lifts the level - the latch the kernel calls out as the
  pre-existing limitation.
- The **display** axis can pause and can publish a resume edge, but can never lift the level.

So the two half-successes are not equally bad. Display-only reproduces exactly the state the kernel
documents as broken (level entered, never lifted). Lock-only would actually be *more* capable than
upstream, because it can lift. The implementation refuses both rather than choosing, which is
conservative: it keeps the kernel's documented fallback (NetworkExtension `sleep()`/`wake()`), and it
makes the failure visible in the log instead of silently shipping a different pause behaviour per
launch. **That is a decision, and it is recorded here rather than implied.**

### 4.2 Missed unlock — `RECOVERABLE_BY_DESIGN`, with a residual `NEEDS_DEVICE`

Darwin notifications are delivered to a running process and nobody else. While the extension is
suspended, a lock or an unlock is simply not delivered.

`ExtensionProvider.wake()` calls `screenStateObserver?.resync()`, which re-reads both names once. A
snapshot may publish only a **sleep** fact (§4.3), so a resume can add a pause and can never invent a
wake. A lock missed while suspended is therefore recovered; an unlock missed while suspended is not,
and cannot be, because the fact is gone.

Does that latch? Not for a device a person is using: the next real unlock is delivered, and an
unlock is what lifts the level. The residual case is a device that was **unlocked while the extension
was suspended and then never unlocked again** before the extension stops - which requires the
extension to be running, the device locked, the extension suspended, the user to unlock, and the
extension to resume with no further lock/unlock cycle. `NEEDS_DEVICE`: the frequency of that shape is
a device question, and the exposure is bounded by the governor's staggered release rather than by a
full wake storm.

### 4.3 Snapshot cannot invent a wake — `FIXED_WITH_TEST`

`notify_get_state` answers `NOTIFY_STATUS_OK` with `0` for a name whose state was never set. On the
lock source `0` means **unlocked**, so a snapshot that published it would invent a wake at every
extension start. `ScreenStatePolicy.decide` therefore refuses any non-sleep fact from a `.snapshot`,
while still *remembering* the value so the next real transition is measured against it.

### 4.4 Cancel race — `NO_BUG_FOUND`, and here is the argument

The brief asks whether a `cancel()` can return after the last `isCurrent(epoch)` check and before
`publish(fact)`, letting a fact reach the core after teardown.

It cannot, and the reason is serialisation rather than the generation counter:

- `observe(source:provenance:epoch:)` runs **on the observer's serial queue** - it is only reached
  from `handleEvent` (a notify callback, registered against that queue), from `start()`, and from
  `resync()`, and all three enter through `syncOnQueue`.
- `publish(fact)` is a **synchronous** call on that same queue. It does not dispatch anywhere.
- Therefore nothing else can run on that queue between the second `isCurrent` check and the
  `publisher` call. `cancel()` advances the generation under `access`, but it cannot interleave into
  the middle of a queue block, and after it returns the block either has not started (and will be
  refused by the first check) or has already finished.

The generation fence is doing real work - it is what stops a callback *queued* before `cancel()` from
publishing after it, because that callback starts a fresh block and fails the first check. It is not,
and does not need to be, a lock around `publish`.

There is a **second, independent** barrier for the same window: `observe` also requires
`registration(for: source)`, and `cancel()` clears the registration table. A callback that somehow
passed the generation check would still find no token to read.

`Tests/HakoScreenState` drives the worst case deterministically: the fake's `getState` calls
`cancel()` from inside the read, which is the in-flight window the fence exists for, and asserts that
nothing is published.

### 4.5 What was *not* changed

Nothing in the observer or in `ExtensionProvider` was modified this phase. The implementation already
matches the kernel contract, and the brief's own rule applies: *"如果现有修复已正确且没有未决风险，
就只补充分清事实的审计文档和测试，不为改而改。"* The deliverable is the corrected attribution, the
kernel-contract evidence, and the fault-injection tests.

---

## 5. What can be proven on this machine, and what cannot

| Layer | Where it is proven | Status |
|---|---|---|
| Which fact a value maps to; failed read; undefined value; repeat; snapshot rules | `Tests/HakoScreenState` (pure, no frameworks) | **written**; not executed — no Swift toolchain here |
| The cancel fence, including the in-flight window | same | **written**; not executed |
| Partial registration, retry, idempotent start/cancel, deinit | same | **written**; not executed |
| Resync recovers a lock and cannot invent a wake | same | **written**; not executed |
| The Darwin adapter's status handling | `ScreenStateObserverDarwin.swift` | `UNVERIFIED_SDK` — needs iOS |
| Whether the two notification names are delivered to a sandboxed extension | device log from `ScreenStateStartResult` | `NEEDS_DEVICE` |
| Whether the pause actually latches on a real device | `docs/APPLE-DEVICE-ACCEPTANCE.md` §2.5 | `DEFERRED` |
| Whether the kernel's contract is *correct* for hotspot / Wi-Fi-sharing traffic | parent repository `docs/fork/` | not this repository's question; see §6 |

**A Python model of this policy would be a second implementation, and a passing Python model would
not be evidence about the Swift.** None was written.

---

## 6. Recorded, not changed: screen-off is not "no traffic needed"

The brief raises the hotspot case: the device screen goes off while a computer stays associated to
the phone's Wi-Fi, and the computer still needs forwarding. Locking the screen is not the same
statement as "nothing needs to be routed".

This client cannot answer it. The mapping from a lock fact to a paused device axis lives in the
kernel (`box_lifecycle.go`), and the policy that decides what a paused device still forwards lives in
`common/power` and the governor. Changing any of that from the Apple client would be changing kernel
lifecycle semantics without evidence, which this phase is explicitly not allowed to do.

Recorded as `NEEDS_DEVICE` with the observation to look for: **connected to the phone's hotspot,
phone screen off, laptop traffic stops, then resumes**. If it stops and does not resume, that is the
scenario, and it belongs to the kernel repository with this document as the client-side evidence.
