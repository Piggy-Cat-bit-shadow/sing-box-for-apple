import Foundation
import XCTest

@testable import Policy

// MARK: - Fakes

/// A `DarwinNotifyAPI` whose every answer is decided by the test.
///
/// The two things that matter are that a failing call is *representable* (`NotifyRegistration.failed`
/// carries no token, `NotifyStateRead.failed` carries no value) and that the test can make a call fail
/// on demand, including in the middle of a sequence.
final class FakeNotify: DarwinNotifyAPI {
    /// What each name's `registerDispatch` should answer.
    var registrationResult: [String: NotifyRegistration] = [:]
    /// What each token's `getState` should answer, keyed by token.
    var stateResult: [Int32: NotifyStateRead] = [:]
    /// Registered callbacks, so a test can deliver a notification by hand.
    private(set) var handlers: [String: (Int32) -> Void] = [:]
    private(set) var registeredTokens: [String: Int32] = [:]
    private(set) var cancelledTokens: [Int32] = []
    /// Every `getState` call, in order, so ordering can be asserted rather than assumed.
    private(set) var readOrder: [Int32] = []
    /// Answers the next `getState` for a token, then falls through to `stateResult`.
    var stateResultOverride: [Int32: [NotifyStateRead]] = [:]
    /// Called at the start of every `getState`. Used to drive the in-flight window: the test cancels
    /// the observer from inside the read, which is the interleaving the generation fence exists for.
    var onGetState: ((Int32) -> Void)?

    private var nextToken: Int32 = 100

    func registerDispatch(name: String,
                          queue _: DispatchQueue,
                          handler: @escaping (Int32) -> Void) -> NotifyRegistration {
        if let canned = registrationResult[name] {
            if case let .registered(token) = canned {
                handlers[name] = handler
                registeredTokens[name] = token
            }
            return canned
        }
        let token = nextToken
        nextToken += 1
        handlers[name] = handler
        registeredTokens[name] = token
        return .registered(token: token)
    }

    func getState(token: Int32) -> NotifyStateRead {
        readOrder.append(token)
        onGetState?(token)
        if var queued = stateResultOverride[token], !queued.isEmpty {
            let next = queued.removeFirst()
            stateResultOverride[token] = queued
            return next
        }
        return stateResult[token] ?? .failed(status: 1)
    }

    func cancel(token: Int32) -> NotifyOutcome {
        cancelledTokens.append(token)
        return .ok
    }

    /// Deliver a notification for a name, as the system would.
    func deliver(_ name: String) {
        guard let token = registeredTokens[name], let handler = handlers[name] else {
            XCTFail("no registration for \(name)")
            return
        }
        handler(token)
    }
}

/// A `ScreenStatePublishing` that records what it was told, in order.
final class RecordingPublisher: ScreenStatePublishing {
    enum Call: Equatable {
        case screen(Bool)
        case lock(Bool)
    }

    private(set) var calls: [Call] = []

    func recordScreenState(on: Bool) {
        calls.append(.screen(on))
    }

    func recordLockState(locked: Bool) {
        calls.append(.lock(locked))
    }
}

private let displayName = ScreenStateSource.display.notificationName
private let lockName = ScreenStateSource.lock.notificationName

// MARK: - The value mapping

final class ScreenStateSourceTests: XCTestCase {
    func testDisplayValuesMapToOneFactEach() {
        XCTAssertEqual(ScreenStateSource.display.fact(for: 0), .displayOff)
        XCTAssertEqual(ScreenStateSource.display.fact(for: 1), .displayOn)
    }

    func testLockValuesMapToOneFactEach() {
        XCTAssertEqual(ScreenStateSource.lock.fact(for: 0), .unlocked)
        XCTAssertEqual(ScreenStateSource.lock.fact(for: 1), .locked)
    }

    /// The mapping is total on `0` and `1` and undefined anywhere else.
    ///
    /// This is the difference from the revision this replaces, which wrote `state == 1` and therefore
    /// mapped every other value to `false` - and `false` on the lock source is `unlocked`, the one
    /// fact that lifts the device pause.
    func testValuesOtherThanZeroAndOneEstablishNothing() {
        for value: UInt64 in [2, 3, 42, .max] {
            XCTAssertNil(ScreenStateSource.display.fact(for: value), "display \(value)")
            XCTAssertNil(ScreenStateSource.lock.fact(for: value), "lock \(value)")
        }
    }

    /// The two facts the core reads as "nobody is using this device", and the two it does not.
    func testSleepAndWakeRoles() {
        XCTAssertTrue(ScreenFact.displayOff.isSleep)
        XCTAssertTrue(ScreenFact.locked.isSleep)
        XCTAssertFalse(ScreenFact.displayOn.isSleep)
        XCTAssertFalse(ScreenFact.unlocked.isSleep)

        XCTAssertTrue(ScreenFact.unlocked.isWake)
        for fact: ScreenFact in [.displayOn, .displayOff, .locked] {
            XCTAssertFalse(fact.isWake, "\(fact) must not lift the level")
        }

        XCTAssertTrue(ScreenFact.displayOn.isResumeEdge)
        for fact: ScreenFact in [.displayOff, .locked, .unlocked] {
            XCTAssertFalse(fact.isResumeEdge, "\(fact) is not a resume edge")
        }
    }
}

// MARK: - The policy, one observation at a time

final class ScreenStatePolicyTests: XCTestCase {
    private func decide(_ read: NotifyStateRead,
                        _ source: ScreenStateSource,
                        _ provenance: ScreenStateProvenance = .event,
                        last: UInt64? = nil) -> ScreenStateDecision {
        ScreenStatePolicy.decide(read: read, source: source, provenance: provenance, lastObserved: last)
    }

    // The four successful readings, from an event.

    func testSuccessfulReadsPublishTheirFact() {
        XCTAssertEqual(decide(.value(1), .display, last: 0).publish, .displayOn)
        XCTAssertEqual(decide(.value(0), .display, last: 1).publish, .displayOff)
        XCTAssertEqual(decide(.value(1), .lock, last: 0).publish, .locked)
        XCTAssertEqual(decide(.value(0), .lock, last: 1).publish, .unlocked)
    }

    /// A read that failed established nothing, and above all did not establish an unlock.
    func testAFailedReadPublishesNothingAndRemembersNothing() {
        for source: ScreenStateSource in [.display, .lock] {
            let decision = decide(.failed(status: 1), source, last: 1)
            XCTAssertNil(decision.publish, "\(source) published on a failed read")
            XCTAssertNil(decision.rememberValue, "\(source) remembered a value it never read")
        }
    }

    /// The counterfactual for the defect: a failed lock read must not be an unlock, whichever value
    /// was observed before. The old code produced `false` here, which the core reads as `woke()`.
    func testAFailedLockReadIsNeverAnUnlock() {
        for last: UInt64? in [nil, 0, 1] {
            let decision = decide(.failed(status: 2), .lock, last: last)
            XCTAssertNotEqual(decision.publish, .unlocked)
        }
    }

    /// A value that is neither 0 nor 1 establishes nothing either - and remembering nothing is what
    /// keeps the next successful read of a different value an edge rather than a repeat.
    func testAnUndefinedValuePublishesNothingAndRemembersNothing() {
        let decision = decide(.value(7), .lock, last: 1)
        XCTAssertNil(decision.publish)
        XCTAssertNil(decision.rememberValue)
    }

    /// A repeated value is not a second edge, so a system that re-posts an unchanged fact cannot
    /// produce a second sleep measurement or a wake storm. The value is still remembered.
    func testARepeatedValueIsNotAnEdge() {
        let decision = decide(.value(1), .lock, last: 1)
        XCTAssertNil(decision.publish)
        XCTAssertEqual(decision.rememberValue, 1)
    }

    /// A snapshot may only establish that the device is NOT in use.
    ///
    /// `notify_get_state` answers `NOTIFY_STATUS_OK` with `0` for a name whose state was never set,
    /// and `0` on the lock source means "unlocked" - so a snapshot that published it would invent a
    /// wake at every extension start. A snapshot of a sleep fact is the recovery path for a lock that
    /// happened while the extension was suspended, and it is allowed.
    func testASnapshotMayPublishASleepFactButNeverAWakeOne() {
        XCTAssertNil(decide(.value(0), .lock, .snapshot, last: 1).publish, "snapshot invented an unlock")
        XCTAssertNil(decide(.value(1), .display, .snapshot, last: 0).publish, "snapshot invented a display-on")
        XCTAssertEqual(decide(.value(1), .lock, .snapshot, last: 0).publish, .locked)
        XCTAssertEqual(decide(.value(0), .display, .snapshot, last: 1).publish, .displayOff)
    }

    /// A snapshot still remembers what it read, so the next real transition is measured against it
    /// rather than re-published.
    func testASnapshotRemembersTheValueItDidNotPublish() {
        let decision = decide(.value(0), .lock, .snapshot, last: 1)
        XCTAssertNil(decision.publish)
        XCTAssertEqual(decision.rememberValue, 0)

        // And the transition the snapshot suppressed is not published later either, because the value
        // is already the remembered one.
        XCTAssertNil(decide(.value(0), .lock, .event, last: 0).publish)
    }

    /// A snapshot of a sleep fact whose value is already known is also a repeat.
    func testASnapshotOfAnAlreadyKnownSleepFactIsARepeat() {
        XCTAssertNil(decide(.value(1), .lock, .snapshot, last: 1).publish)
    }

    /// The whole truth table, so a future change to `decide` has to face every cell.
    func testTheWholeTruthTable() {
        let reads: [(NotifyStateRead, String)] = [
            (.value(0), "0"), (.value(1), "1"), (.value(2), "2"), (.failed(status: 1), "fail"),
        ]
        for (read, readName) in reads {
            for source: ScreenStateSource in [.display, .lock] {
                for provenance: ScreenStateProvenance in [.event, .snapshot] {
                    for last: UInt64? in [nil, 0, 1] {
                        let decision = ScreenStatePolicy.decide(
                            read: read, source: source, provenance: provenance, lastObserved: last)
                        let label = "\(readName) \(source) \(provenance) last=\(String(describing: last))"

                        if decision.publish == .unlocked {
                            // The single strongest invariant: only a successful read of 0 on the lock
                            // source, delivered as an event, may lift the device pause.
                            XCTAssertEqual(read, .value(0), "an unlock was published for \(label)")
                            XCTAssertEqual(source, .lock, "an unlock was published for \(label)")
                            XCTAssertEqual(provenance, .event, "an unlock was published from a snapshot for \(label)")
                            XCTAssertEqual(last, 1, "an unlock was published without a transition for \(label)")
                        }
                        if decision.publish == .displayOn {
                            XCTAssertEqual(read, .value(1), "a display-on was published for \(label)")
                            XCTAssertEqual(source, .display, "a display-on was published for \(label)")
                            XCTAssertEqual(provenance, .event, "a display-on was published from a snapshot for \(label)")
                        }
                        if case .failed = read {
                            XCTAssertNil(decision.publish, "a failed read published for \(label)")
                            XCTAssertNil(decision.rememberValue, "a failed read remembered for \(label)")
                        }
                        if case .value(2) = read {
                            XCTAssertNil(decision.publish, "an undefined value published for \(label)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - The observer: start, publish, cancel

final class ScreenStateObserverTests: XCTestCase {
    private func makeObserver() -> (ScreenStateObserver, FakeNotify, RecordingPublisher) {
        let notify = FakeNotify()
        let publisher = RecordingPublisher()
        let observer = ScreenStateObserver(notify: notify, publisher: publisher)
        return (observer, notify, publisher)
    }

    /// A start with both names registered reads both once, inside the start, and publishes what the
    /// current values are - which is how a tunnel that starts while the device is already locked
    /// reports it.
    func testStartRegistersBothNamesAndReadsBothOnce() {
        let (observer, notify, publisher) = makeObserver()
        notify.stateResult[100] = .value(1) // display off
        notify.stateResult[101] = .value(1) // locked

        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(notify.readOrder.count, 2, "the snapshot is one read per source")
        XCTAssertEqual(publisher.calls, [.screen(false), .lock(true)])
    }

    /// Registration happens before the snapshot, and both happen inside the start, so a callback
    /// cannot interleave with the snapshot.
    func testRegistrationPrecedesTheSnapshot() {
        let (observer, notify, publisher) = makeObserver()
        notify.stateResult[100] = .value(1)
        notify.stateResult[101] = .value(0)

        XCTAssertEqual(observer.start(), .started)
        // Both names are in the handler table by the time the reads happened.
        XCTAssertEqual(notify.handlers.count, 2)
        XCTAssertEqual(publisher.calls.count, 1, "only the sleep fact is publishable at start")
        XCTAssertEqual(publisher.calls, [.screen(false)])
    }

    /// `start()` twice does nothing the second time: no second registration, no second snapshot, no
    /// duplicate token.
    func testStartIsIdempotent() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        let readsAfterFirst = notify.readOrder.count
        let callsAfterFirst = publisher.calls.count

        XCTAssertEqual(observer.start(), .alreadyStarted)
        XCTAssertEqual(notify.readOrder.count, readsAfterFirst, "the second start took a snapshot")
        XCTAssertEqual(publisher.calls.count, callsAfterFirst, "the second start published")
    }

    /// A delivered event publishes, and a repeated delivery of the same value does not.
    func testAnEventPublishesOnceAndARepeatDoesNot() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [])

        notify.stateResult[101] = .value(1)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [.lock(true)])

        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [.lock(true)], "a repeated value produced a second edge")
    }

    /// The sequence the device actually produces when a notification lights the lock screen:
    /// locked -> display on -> still locked -> unlocked. Only the lock axis may move the level.
    func testNotificationLightsTheScreenAndTheDeviceStaysLocked() {
        let (observer, notify, publisher) = makeObserver()
        notify.stateResult[100] = .value(0) // display on
        notify.stateResult[101] = .value(1) // locked
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.lock(true)])

        notify.deliver(displayName)
        XCTAssertEqual(publisher.calls, [.lock(true), .screen(true)],
                       "a display-on publishes the resume edge and nothing else")

        // The user locks again, then unlocks for real.
        notify.stateResult[101] = .value(0)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls.last, .lock(false), "the unlock is the level release")
    }

    /// A display going off is a sleep fact; a display going on is not a wake. The publisher offers no
    /// `wakeNow`, so this is also a statement about the type: there is no path to a false wake.
    func testDisplayOnNeverReachesAWakeEntryPoint() {
        let (observer, notify, publisher) = makeObserver()
        notify.stateResult[100] = .value(1)
        XCTAssertEqual(observer.start(), .started)
        publisher.calls.removeAll()

        notify.stateResult[100] = .value(0)
        notify.deliver(displayName)
        XCTAssertEqual(publisher.calls, [.screen(true)])
        // The only two calls the publisher can make are the two record methods; neither is a wake.
        XCTAssertFalse(publisher.calls.contains { call in
            if case .lock(false) = call { return true }
            return false
        }, "a display-on published an unlock")
    }

    // MARK: Partial registration

    /// Both names are attempted even when the first fails, so the failure is reported for every
    /// source rather than only for the first.
    func testBothNamesAreAttemptedWhenTheFirstFails() {
        let (observer, notify, _) = makeObserver()
        notify.registrationResult[displayName] = .failed(status: 1)
        notify.registrationResult[lockName] = .registered(token: 500)

        XCTAssertEqual(observer.start(), .failed(sources: [.display]))
        XCTAssertTrue(notify.cancelledTokens.contains(500),
                      "the registration that succeeded must be cancelled, or it leaks into notifyd")
    }

    /// A half-registered observer is refused, and refused *visibly*: the result names what failed so
    /// a device log can say whether these two undocumented names reach a sandboxed extension at all.
    func testAPartialRegistrationFailsClosedAndNamesTheSource() {
        let (observer, notify, publisher) = makeObserver()
        notify.registrationResult[lockName] = .failed(status: 4)

        let result = observer.start()
        XCTAssertFalse(result.isStarted)
        XCTAssertEqual(result.failedNotificationNames, [lockName])
        XCTAssertEqual(publisher.calls, [], "a half-registered observer published")
    }

    /// A failed start leaves nothing registered, so a later start can succeed.
    func testAFailedStartCanBeRetried() {
        let (observer, notify, publisher) = makeObserver()
        notify.registrationResult[displayName] = .failed(status: 1)
        XCTAssertFalse(observer.start().isStarted)
        XCTAssertEqual(publisher.calls, [])

        notify.registrationResult.removeValue(forKey: displayName)
        notify.stateResult[100] = .value(1)
        notify.stateResult[101] = .value(1)
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.screen(false), .lock(true)])
    }

    /// Neither name registering is reported as both.
    func testNeitherNameRegisteringIsReportedAsBoth() {
        let (observer, notify, _) = makeObserver()
        notify.registrationResult[displayName] = .failed(status: 1)
        notify.registrationResult[lockName] = .failed(status: 1)

        let result = observer.start()
        XCTAssertEqual(result.failedNotificationNames, [displayName, lockName])
    }

    // MARK: Cancel

    /// After `cancel()` returns, nothing is published - including from a callback that the
    /// notification centre had already queued.
    func testACallbackAfterCancelPublishesNothing() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        publisher.calls.removeAll()

        let queued = notify.handlers[lockName]
        observer.cancel()
        notify.stateResult[101] = .value(1)
        queued?(101) // the callback the centre had already submitted

        XCTAssertEqual(publisher.calls, [], "a callback ran after cancel() returned")
    }

    /// The specific interleaving the phase-2 brief asks about: a callback that is in flight while
    /// `cancel()` returns. `observe` runs on the observer's serial queue and `publish` is a
    /// synchronous call on that same queue, so the generation cannot advance between the final
    /// `isCurrent` check and the publish - the fence and the publish are serialised with each other.
    ///
    /// The test drives it deterministically: the fake's `getState` cancels the observer **while the
    /// read is in flight**, which is the worst case the fence exists for.
    func testCancelDuringAnInFlightReadStopsThePublish() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        publisher.calls.removeAll()

        var cancelled = false
        notify.stateResult[101] = .value(1)
        notify.onGetState = { token in
            if token == 101, !cancelled {
                cancelled = true
                observer.cancel()
            }
        }
        notify.deliver(lockName)

        XCTAssertTrue(cancelled, "the test did not reach the in-flight window")
        XCTAssertEqual(publisher.calls, [], "a fact read before the fence was published after it")
    }

    /// `cancel()` twice is harmless and does not cancel a token twice.
    func testCancelIsIdempotent() {
        let (observer, notify, _) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        observer.cancel()
        let after = notify.cancelledTokens.count
        observer.cancel()
        XCTAssertEqual(notify.cancelledTokens.count, after, "the second cancel released tokens again")
    }

    /// A start after a cancel registers afresh and works.
    func testStartAfterCancelWorks() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        observer.cancel()

        notify.stateResult[100] = .value(1) // display off, a publishable snapshot fact
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.screen(false)])
    }

    // MARK: Resync

    /// `resync()` can recover a lock that happened while the extension was suspended.
    func testResyncRecoversAMissedLock() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [])

        // The device locked while the extension was away: the notification was never delivered, and
        // the value on the source has since changed.
        notify.stateResult[101] = .value(1)
        observer.resync()

        XCTAssertEqual(publisher.calls, [.lock(true)], "resync did not recover the missed lock")
    }

    /// And it can never invent a wake, which is the property that makes it safe to call on every
    /// NetworkExtension resume.
    func testResyncCanNeverPublishAWake() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)

        // The extension resumed, the device was locked the whole time, and both sources now read
        // "in use" - which is what a lit lock screen looks like.
        notify.stateResult[100] = .value(0)
        notify.stateResult[101] = .value(0)
        observer.resync()

        XCTAssertFalse(publisher.calls.contains(.lock(false)), "resync published an unlock")
        XCTAssertFalse(publisher.calls.contains(.screen(true)), "resync published a display-on")
        XCTAssertEqual(publisher.calls, [], "resync published a non-sleep fact")
    }

    /// A resync that finds a sleep fact already known publishes nothing, so a resume loop cannot
    /// produce a repeating pause.
    func testResyncOfAnUnchangedFactPublishesNothing() {
        let (observer, notify, publisher) = makeObserver()
        notify.stateResult[101] = .value(1)
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.lock(true)])

        observer.resync()
        XCTAssertEqual(publisher.calls, [.lock(true)], "resync republished an unchanged fact")
    }

    // MARK: Reads that fail

    /// A read that fails during a callback publishes nothing, and the remembered value survives so
    /// the next successful read of the same value is still a repeat.
    func testAFailedEventReadPublishesNothingAndKeepsTheLastValue() {
        let (observer, notify, publisher) = makeObserver()
        notify.stateResult[101] = .value(1)
        notify.deliver(lockName) // not registered yet: harmless
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.lock(true)])
        publisher.calls.removeAll()

        notify.stateResult[101] = .failed(status: 1)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [], "a failed read published")

        // The value is still 1, so this is a repeat and not a fresh edge.
        notify.stateResult[101] = .value(1)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [], "the failed read lost the remembered value")
    }

    /// Teardown releases the registrations it holds, so a stopped observer does not leave a handler
    /// in notifyd for the life of the process. `deinit` timing is not guaranteed by the language, so
    /// this asserts the fact the owner depends on - `cancel()` releases every token that registered -
    /// rather than relying on when the runtime collects the object.
    func testCancelReleasesEveryTokenThatRegistered() {
        let (observer, notify, _) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(notify.registeredTokens.count, 2)

        observer.cancel()
        XCTAssertEqual(Set(notify.cancelledTokens), Set(notify.registeredTokens.values),
                       "cancel() must release both registrations, not just the first")
    }

    /// Destroying the observer without cancelling still releases the tokens, as a last resort.
    func testDeinitReleasesRegistrations() {
        let notify = FakeNotify()
        var observer: ScreenStateObserver? = ScreenStateObserver(notify: notify,
                                                                 publisher: RecordingPublisher())
        XCTAssertEqual(observer?.start(), .started)
        let tokens = Set(notify.registeredTokens.values)

        observer = nil
        XCTAssertEqual(Set(notify.cancelledTokens), tokens,
                       "deinit left a registration behind in notifyd")
    }
}
