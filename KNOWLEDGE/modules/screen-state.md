# Screen state, suspend and resume

## Where it lives

| File | Role |
|---|---|
| `Library/Network/ScreenStateObserver.swift` | platform-neutral policy, 527 lines |
| `Library/Network/ScreenStateObserverDarwin.swift` | `#if os(iOS)` Darwin `notify` adapter |
| `Tests/HakoScreenState/Tests/ScreenStateTests/ScreenStateObserverTests.swift` | SwiftPM tests against a **symlink** to the shipping policy file, so the tests exercise real source rather than a copy |

Platform ownership of the *action* is not here: the observer produces facts, and
`ExtensionProvider` decides what to do with them.

## Event and snapshot, edge and level — both axes exist

Two provenance cases, deliberately:

```swift
enum ScreenStateProvenance {
    case event     // a notification callback: a transition the system witnessed
    case snapshot  // a `notify_get_state` read outside a callback - at start, or on resume
}
```

Snapshots happen exactly twice: once in `start()` after registration, and once in
`resync()`.

The edge/level split is per **fact**, not per observer:

```swift
var isSleep: Bool { case .displayOff, .locked: true; case .displayOn, .unlocked: false }
var isWake: Bool { self == .unlocked }        // the one LEVEL release
var isResumeEdge: Bool { self == .displayOn } // a resume edge with no level movement
```

The full mapping, as written in the source:

```text
locked=1    -> recordLockState(true)    -> LockStateChanged(true)  -> slept()    (LEVEL pause)
unlocked=0  -> recordLockState(false)   -> LockStateChanged(false) -> woke()     (LEVEL wake)
display=on  -> recordScreenState(true)  -> ScreenStateChanged(true)-> resumed()  (EDGE only)
display=off -> recordScreenState(false) -> ScreenStateChanged(false)-> slept()   (LEVEL pause)
```

There is deliberately **no path to `wakeNow()`**: an unlock already publishes the wake,
and a display turning on must not.

## The policy rules, and the missing one

The decision function is pure and ordered. At **this baseline** it implements four rules:

1. a failed read publishes nothing and keeps the previous value;
2. a non-`0`/`1` value publishes nothing;
3. a repeat of the last value this source successfully observed publishes nothing;
4. a snapshot may publish **only** `isSleep`.

Rule 4 is the one that matters most for the snapshot path: a re-read may establish or
retain a *sleep* fact, but it must never invent an unlock or a wake. Rule 3 operates on
the last successfully observed value per source (`lastObserved`), not on the raw last
read.

### KNOWN DEFECT AT THIS BASELINE — rule 5 is missing

The rules above do **not** cover the **event** path from an unknown state. At this
baseline:

```text
decide(read: .value(0), source: .lock, provenance: .event, lastObserved: nil)
  -> repeat?    no, nil != 0
  -> snapshot?  no, this is an event
  -> publish .unlocked
```

`.unlocked` is the one fact that lifts the device pause
(`recordLockState(false)` → `Box.LockStateChanged(false)` → `lifecycle.woke()`), so a
lock axis whose prior value is unknown, reporting `0`, silently releases the pause.
Rule 4 already refuses that same `0` on the snapshot path for exactly this reason — a
notification name whose state was never set answers `NOTIFY_STATUS_OK` with `0` — but the
event path had no equivalent guard, and the distinction it relied on ("an event is a real
report") does not hold for the **first** event on an axis nobody has observed yet.

**The repository's own test asserts the missing rule and therefore fails at this
baseline.** `Tests/HakoScreenState/…/ScreenStateObserverTests.swift`,
`ScreenStatePolicyTests.testTheWholeTruthTable`:

```swift
if decision.publish == .unlocked {
    XCTAssertEqual(read, .value(0),  "an unlock was published for \(label)")
    XCTAssertEqual(source, .lock,    "an unlock was published for \(label)")
    XCTAssertEqual(provenance, .event, "an unlock was published from a snapshot for \(label)")
    XCTAssertEqual(last, 1,          "an unlock was published without a transition for \(label)")  // <- fails
}
```

That assertion was added by `996c8b7`, an ancestor of this baseline. So this is a
**known red test**, not an unknown: the policy class is 8 of 9 at this baseline.

The fix is already written on the live product line and is **not** here:

```swift
// 891c6cb "an unlock is a transition, so it needs a lock to have been observed"
if fact == .unlocked, lastObserved != 1 {
    return ScreenStateDecision(rememberValue: raw, publish: nil)
}
```

Verified present on `origin/main`. `891c6cb` reports `ScreenStatePolicyTests` going to
9 of 9.

**Do not** restate this policy as safe, and **do not** "fix" the test to match the code.
Production code is out of scope for this knowledge refresh — see
`KNOWLEDGE_STAGE2_REINFORCEMENT_REPORT.md` §H.

`wake()` is not proof of unlock: background activity can resume the extension while the
device is still locked.

`resync()` exists because Darwin notifications are **not delivered to a suspended
process** — a lock that happened while the extension was away was never delivered. It
re-reads both names once. It is not a poll; nothing schedules it.

## Fencing

Three independent mechanisms, and they are not redundant:

1. **Generation fence.** `generation` is bumped by `start()` and by `cancel()`. A
   callback may publish only while the generation it registered under is current. The
   fence is checked **on both sides** of the read — before it, and again after, because
   `cancel()` can land while the read is in flight.
2. **Weak publisher.** The observer publishes through a weak reference to the command
   server, so a released server cannot be written to.
3. **`deinit` cancel.** A registration that outlived the observer would otherwise keep a
   dead handler alive in notifyd for the life of the process.

`cancel()` advances the generation *before* taking and cancelling tokens, so ordering is
not load-bearing there.

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
  `ScreenStateStartResult.failedNotificationNames`.
- The `#if os(iOS)` adapter is **never compiled by any test**. The SwiftPM package tests
  the policy file only, so the `notify` call sites are validated by nothing but an iOS
  build. The package's own manifest concedes this: correctness is argued from the SDK
  signature, and the only way to test it is on a device.
- Delivery ordering and hardware notification behaviour cannot be produced by a fake.
  Only physical-device closure validates those.

## AI cautions

- Do not unify rule 4 into rule 3. A snapshot that publishes a wake is the bug.
- Do not move the generation bump in `cancel()` after the token cancellation.
- Do not remove either half of the double-sided generation check.
- Do not add an unbounded wait or a poll to `resync()`; it is one re-read, on resume.
- A "sleep anchor" is **not** an identifier in this code. If you see that phrase in an
  older report, the source constructs it gestures at are `lastObserved` (last value
  observed per source) plus rule 3 above.

## Evidence

`VERIFIED_SOURCE` for all code above, re-read at `aa1e982`.
`VERIFIED_STATIC` for the structural claims about the observer's file set.
`NEEDS_DEVICE` for notification delivery, sleep/wake closure and hardware behaviour.
`EXTERNAL_CHECK_REQUIRED` for per-iOS-release delivery of the two non-public
notification names.
