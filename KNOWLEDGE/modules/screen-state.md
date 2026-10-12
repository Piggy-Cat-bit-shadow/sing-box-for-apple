# Screen state, suspend and resume

## Where it lives

| File | Role |
|---|---|
| `Library/Network/ScreenStateObserver.swift` | platform-neutral policy, **731 lines** |
| `Library/Network/ScreenStateObserverDarwin.swift` | `#if os(iOS)` Darwin `notify` adapter |
| `Tests/HakoScreenState/Sources/Policy/ScreenStateObserver.swift` | **symlink** → `../../../../Library/Network/ScreenStateObserver.swift`, so the tests exercise real source rather than a copy |
| `Tests/HakoScreenState/Tests/ScreenStateTests/ScreenStateObserverTests.swift` | the suite itself (real file, not a symlink) |

Platform ownership of the *action* is not here: the observer produces facts, and
`ExtensionProvider` decides what to do with them.

## Four axes, and the whole point is not to collapse them

Two provenance cases, two delivery kinds, and they are separate types on purpose:

```swift
enum ScreenStateProvenance { case event, snapshot }      // where the observation came from
enum ScreenStateDelivery   { case edge, level }          // how the fact may reach the core
```

Snapshots happen exactly twice: once in `start()` after registration, and once in
`resync()`. `ScreenStateDelivery` is derived from the provenance by an **initialiser, not a
default** — `init(provenance:)` maps `.event → .edge` and `.snapshot → .level` totally, so a
new provenance cannot silently fall through to the destructive one.

The edge/level split is per **fact**, not per observer:

```swift
var isSleep: Bool { case .displayOff, .locked: true; case .displayOn, .unlocked: false }
var isWake: Bool { self == .unlocked }        // the one LEVEL release
var isResumeEdge: Bool { self == .displayOn } // a resume edge with no level movement
```

## The delivery table, as written in the source

```text
EDGE  (a transition the system delivered)
locked=1    -> recordLockState(true)     -> Box.LockStateChanged(true)     -> slept()        (EDGE + LEVEL)
unlocked=0  -> recordLockState(false)    -> Box.LockStateChanged(false)    -> woke()         (EDGE + LEVEL wake)
display=on  -> recordScreenState(true)   -> Box.ScreenStateChanged(true)   -> resumed()      (EDGE only)
display=off -> recordScreenState(false)  -> Box.ScreenStateChanged(false)  -> slept()        (EDGE + LEVEL)

LEVEL (a current-state read; rule 4 limits it to the sleep facts)
locked=1    -> reconcileLockState(true)     -> Box.ReconcileLockState(true)     -> DevicePause() (LEVEL only)
display=off -> reconcileScreenState(false)  -> Box.ReconcileScreenState(false)  -> DevicePause() (LEVEL only)
```

There is deliberately **no path to `wakeNow()`**: an unlock already publishes the wake, and a
display turning on must not. `wake()` is not proof of unlock either — background activity can
resume the extension while the device is still locked.

The publish switch is exhaustive over the fact/delivery **pair**, so a sleep fact can never
reach an edge entry point from a snapshot: that combination does not compile its way to
`recordScreenState`. The two unreachable arms are spelled out rather than folded into
`default`, so a future case has to be classified.

## The policy: six ordered rules

`ScreenStatePolicy.decide` is pure and ordered. At this baseline it implements **six** rules,
because the two the old baseline lacked are now present:

1. A read that did not return `NOTIFY_STATUS_OK` established nothing. Nothing is published and
   the previous value is kept.
2. A value that is neither `0` nor `1` established nothing. Nothing is published.
3. A value equal to the last value this source successfully observed is a repeat. Nothing is
   published.
4. A snapshot may publish **only** `isSleep`. A re-read may establish or retain a *sleep*
   fact, but it must never invent an unlock or a wake.
5. **An unlock is a transition**, so it is published only when the lock source was actually
   observed locked (`1`) first. `.unlocked` is the one fact that lifts the device pause, and a
   `0` from an axis whose prior value is unknown is indistinguishable from the never-set `0`
   that rule 4 refuses on a snapshot — so it is refused on an event too. The value is still
   remembered, so a genuine lock-then-unlock still publishes.
6. Whatever survives is delivered as the provenance it came from: an `.event` as an EDGE, a
   `.snapshot` as a LEVEL.

Rule 3 operates on the last successfully observed value per source (`lastObserved`), not on
the raw last read. `decide` returns a `ScreenStateDecision` carrying `rememberValue`,
`publish` and `delivery` together, so the rule lives in one pure function the tests can pin
without an observer.

### AI caution: rule 5 and rule 6 are fixes, and they were both got wrong before

The **previous baseline is where these were missing**, and the repository recorded it:

- Without rule 5, `decide(read: .value(0), source: .lock, provenance: .event, lastObserved: nil)`
  published `.unlocked` and silently released the device pause. The repository's own test
  asserted the missing rule and **therefore failed** — this was a known red, not an unknown.
  Fixed by `891c6cb`; the suite went to 9 of 9 policy cases.
- Without rule 6, a snapshot was delivered through the **edge** verb. The client re-reads both
  notification names on every NetworkExtension resume, *after* waking the core, so the edge
  from the re-read arrived with a resume already noted and re-anchored the measurement the
  resume had just published. That is the P1-C defect. Fixed by `987134b`:
  *"deliver a current-state read as a level, never a sleep edge."*

`ScreenStateProvenance` was already known at the decision site and stopped at the type's
doorstep — the provenance was recorded but had no way to influence *how* the fact was
published. If a future change publishes a `.snapshot` through an edge verb again, both fixes
regress together. `c58b1f7` closed the fake's blind spots so the fake can now express a stale
callback, an invalid token and a duplicate registration.

`resync()` exists because Darwin notifications are **not delivered to a suspended process** —
a lock that happened while the extension was away was never delivered. It re-reads both names
once, on resume. It is not a poll; nothing schedules it.

## Fencing

Three independent mechanisms, and they are not redundant:

1. **Generation fence.** `generation` is bumped by `start()` and by `cancel()`. A callback may
   publish only while the generation it registered under is current. The fence is checked **on
   both sides** of the read — before it, and again after, because `cancel()` can land while
   the read is in flight. `start()` also re-checks after the snapshot loop, so a cancel that
   lands during it cannot leave a caller holding a live-looking observer with no tokens.
2. **Weak publisher.** The observer publishes through a weak reference to the command server,
   so a released server cannot be written to.
3. **`deinit` cancel.** A registration that outlived the observer would otherwise keep a dead
   handler alive in notifyd for the life of the process.

`cancel()` advances the generation *before* taking and cancelling tokens. `start()` takes its
epoch and its token table in **one** critical section (`advanceGenerationAndStore`), because
split in two a cancel landing inside the registration loop finds an empty table, cancels
nothing, and leaves a dead observer whose callbacks can never publish and whose tokens leak.

The queue is serial with a `DispatchSpecificKey` re-entrancy marker, which is what makes
`cancel()` and `resync()` safe to call from inside a callback.

## Failure is typed so it cannot read as a value

`NotifyOutcome` / `NotifyRegistration` / `NotifyStateRead` exist so a failed
`notify_get_state` cannot be mistaken for `0`, which would read as "unlocked". Only one
place interprets the status, and it returns `.failed(status:)` rather than a value.

`f77289f` records the essential rule: **a failed notification read is `unknown`, not an
unlock.**

## Test-double blind spots

- The two notification names are non-public API
  (`com.apple.iokit.hid.displayStatus`, `com.apple.springboard.lockstate`). Whether they
  are delivered inside a sandboxed NetworkExtension differs per iOS release and cannot
  be established from source. Failures surface at runtime through
  `ScreenStateStartResult.failedNotificationNames`, and `ExtensionProvider` logs them
  rather than swallowing them.
- The `#if os(iOS)` adapter is **never compiled by any test**. The SwiftPM package tests
  the policy file only, so the `notify` call sites are validated by nothing but an iOS
  build. The policy is separated from the adapter precisely so every *decision* is
  testable; the adapter is not.
- Delivery ordering and hardware notification behaviour cannot be produced by a fake.
  Only physical-device closure validates those.

## AI cautions

- Do not unify rule 4 into rule 3. A snapshot that publishes a wake is the bug.
- Do not move the generation bump in `cancel()` after the token cancellation.
- Do not remove either half of the double-sided generation check.
- Do not deliver a snapshot through an edge verb. That is the P1-C regression.
- Do not add an unbounded wait or a poll to `resync()`; it is one re-read, on resume.
- A "sleep anchor" is **not** an identifier in this code. The source constructs that phrase
  gestures at are `lastObserved` (last value observed per source) plus rule 3.

## Evidence

`VERIFIED_SOURCE` for all code above, re-read at `5cab4ec`.
`VERIFIED_STATIC` for the structural claims about the observer's file set.
`VERIFIED_UNIT` is **not** claimed here: the suite is a SwiftPM package whose policy source is
a git symlink, and this host cannot materialise symlinks — see `modules/tests-audits.md`.
`NEEDS_DEVICE` for notification delivery, sleep/wake closure and hardware behaviour.
`EXTERNAL_CHECK_REQUIRED` for per-iOS-release delivery of the two non-public
notification names.
