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

    // MARK: Accounting, so the blind spots below are observable

    /// One successful `notify_register_dispatch`, kept in full.
    ///
    /// # Why this exists
    ///
    /// The fake used to record only the *latest* handler and token per name (`handlers[name]`,
    /// `registeredTokens[name]`), overwriting whatever was there. Three things followed, and all
    /// three were blind spots rather than conveniences:
    ///
    ///   * A duplicate registration - the observer registering a name it had already registered, or
    ///     registering twice across a cancel/start pair - was invisible. The table just held the new
    ///     value. `testStartIsIdempotent` could only assert that the number of *reads* did not grow,
    ///     which is a different claim.
    ///   * A callback notifyd had queued before a `cancel()` belonged to a registration the fake
    ///     could no longer name, so the two tests that deliver one had to grab `handlers[name]` and
    ///     call it with a literal token (`101`, `500`) that no registration ever issued. A literal
    ///     token cannot be checked against anything, so "this is a post-cancel callback" was an
    ///     assumption rather than a fact.
    ///   * `deliver()` looked up the *live* registration, so there was no way to express "deliver
    ///     the callback that registration #1 installed, after registration #2 is live" - which is
    ///     the interleaving the generation fence exists for.
    struct Registration {
        let name: String
        /// 1-based, per name.
        let ordinal: Int
        let token: Int32
        let queue: DispatchQueue
        let handler: (Int32) -> Void
    }

    /// Every successful registration, in order, per name. Never cleared by `cancel` - a callback the
    /// notification centre has already queued cannot be un-queued, so the registration it belongs to
    /// stays nameable after the token is gone. That is the whole point.
    private(set) var registrations: [String: [Registration]] = [:]

    /// Every `registerDispatch` call, successful or not.
    private(set) var registrationAttempts: [String: Int] = [:]
    /// Every `registerDispatch` that returned a token.
    private(set) var successfulRegistrations: [String: Int] = [:]
    /// Tokens `cancel` has invalidated, minus any a later registration revived.
    private(set) var invalidatedTokens: Set<Int32> = []
    /// The token each delivered callback was handed, so a test can refuse a made-up one.
    private(set) var deliveredTokens: [Int32] = []

    /// `NOTIFY_STATUS_INVALID_TOKEN`.
    ///
    /// The value is from `<notify.h>`; nothing in the observer branches on the number - every
    /// `.failed` establishes nothing - so this is documentation rather than behaviour. What matters
    /// is that it is representable at all, which it was not before: `cancel` answered `.ok` to
    /// everything and `getState` answered a configured *value* for a token that notifyd had already
    /// released.
    static let invalidTokenStatus: UInt32 = 2

    /// Every `getState` call, in order, so ordering can be asserted rather than assumed.
    private(set) var readOrder: [Int32] = []
    /// Answers the next `getState` for a token, then falls through to `stateResult`.
    var stateResultOverride: [Int32: [NotifyStateRead]] = [:]
    /// Called at the start of every `getState`. Used to drive the in-flight window: the test cancels
    /// the observer from inside the read, which is the interleaving the generation fence exists for.
    var onGetState: ((Int32) -> Void)?

    /// Tokens are fixed per notification name rather than handed out in registration order.
    ///
    /// Registration order is an implementation detail - `ScreenStateObserver.start()` registers in
    /// `allCases` order and a registration told to fail consumes nothing - so a token number derived
    /// from it is not a constant a test can name. Four assertions in this file used to configure
    /// `stateResult[100]`/`[101]` and were configuring the wrong source. The values are above every
    /// canned token any test passes in, so they cannot collide with one.
    private static let fixedTokens: [String: Int32] = [
        ScreenStateSource.display.notificationName: 1000,
        ScreenStateSource.lock.notificationName: 1001,
    ]

    /// Called (on the importing thread) immediately after a successful `registerDispatch`.
    ///
    /// This is the seam that makes `start()` racing `cancel()` deterministic. The real race is a
    /// different thread calling `cancel()` while `start()` is between its generation bump and the
    /// point it stores the tokens; blocking here puts that thread exactly inside that window, with no
    /// sleeps and no probability. The observer's own callback is deliberately not called by this hook.
    var onRegisterDispatch: ((String) -> Void)?

    /// The queue each name registered against, and the mark that lets `deliver` recognise it.
    ///
    /// # Why the fake has to carry these at all
    ///
    /// `registerDispatch` used to bind `queue _: DispatchQueue` and throw the argument away, and
    /// `deliver` called the handler inline on whatever thread the test happened to be on. The
    /// observer's whole design rests on the opposite being true - one serial queue for registration,
    /// the snapshot and every callback, which is what makes the snapshot "never older than a fact the
    /// core already has" and what makes `syncOnQueue` safe - so every claim about queue confinement
    /// went untested. A refactor to `DispatchQueue.global()` would have left every test here green.
    ///
    /// The fake now puts the callback where the real `notify_register_dispatch` would have put it: on
    /// the queue the registration asked for. That is the mechanism rather than an assertion about it,
    /// so a test written against this fake exercises the same confinement production relies on.
    private(set) var registrationQueues: [String: DispatchQueue] = [:]

    /// Marks a queue as a delivery context, so `deliver` can tell whether it is already on it.
    ///
    /// Not `nonisolated(unsafe)`: `DispatchSpecificKey` is `Sendable`, so a plain `let` is correct and
    /// the compiler says so.
    static let deliveryQueueKey = DispatchSpecificKey<UInt8>()

    func registerDispatch(name: String,
                          queue: DispatchQueue,
                          handler: @escaping (Int32) -> Void) -> NotifyRegistration {
        registrationQueues[name] = queue
        queue.setSpecific(key: Self.deliveryQueueKey, value: 1)
        registrationAttempts[name, default: 0] += 1

        let registration: NotifyRegistration
        if let canned = registrationResult[name] {
            if case let .registered(token) = canned {
                handlers[name] = handler
                registeredTokens[name] = token
                invalidatedTokens.remove(token)
            }
            registration = canned
        } else if let token = Self.fixedTokens[name] {
            handlers[name] = handler
            registeredTokens[name] = token
            // A successful registration revives the name's token. Darwin hands back the same token
            // id for the same notification name, so a cancel followed by a fresh registration
            // produces a token that is live again - which is exactly the sequence
            // `testStartAfterCancelWorks` and `testAFailedStartCanBeRetried` exercise.
            invalidatedTokens.remove(token)
            registration = .registered(token: token)
        } else {
            XCTFail("FakeNotify has no token for \(name); add it to fixedTokens")
            registration = .failed(status: 1)
        }

        if case let .registered(token) = registration {
            var list = registrations[name] ?? []
            var ordinal = successfulRegistrations[name] ?? 0
#if FAKE_BLIND_DUPLICATE_REGISTRATION
            // MUTATION FLAG, off in every real run. Reintroduces the "duplicate registration
            // counting" blind spot: the fake forgets that this name was ever registered before, so a
            // second or leaked registration is invisible. `FakeNotifyBlindSpotTests` goes red under
            // it; see `fakenotify-red-proof.ps1`.
            list = []
            ordinal = 0
#endif
            ordinal += 1
            successfulRegistrations[name] = ordinal
            list.append(Registration(name: name,
                                     ordinal: ordinal,
                                     token: token,
                                     queue: queue,
                                     handler: handler))
            registrations[name] = list
            onRegisterDispatch?(name)
        }
        return registration
    }

    func getState(token: Int32) -> NotifyStateRead {
        readOrder.append(token)
        onGetState?(token)
#if !FAKE_BLIND_INVALID_TOKEN
        // notifyd answers NOTIFY_STATUS_INVALID_TOKEN for a token `cancel` has released. Modelling
        // that is what makes "a read on a dead token establishes nothing" a test rather than a
        // comment: the fake used to answer whatever value the test had configured, so the observer's
        // failure path was never reached by a cancelled token.
        if invalidatedTokens.contains(token) {
            return .failed(status: Self.invalidTokenStatus)
        }
#endif
        if var queued = stateResultOverride[token], !queued.isEmpty {
            let next = queued.removeFirst()
            stateResultOverride[token] = queued
            return next
        }
        return stateResult[token] ?? .failed(status: 1)
    }

    func cancel(token: Int32) -> NotifyOutcome {
#if FAKE_BLIND_INVALID_TOKEN
        // MUTATION FLAG, off in every real run. Reintroduces the INVALID_TOKEN blind spot: every
        // cancel answers `.ok` and the token stays usable, so a double cancel and a cancel of a dead
        // token are indistinguishable from a first cancel.
        cancelledTokens.append(token)
        return .ok
#else
        if invalidatedTokens.contains(token) {
            // Already released. `notify_cancel` does not succeed twice for the same token, and a
            // double cancel that answered `.ok` would make `testCancelIsIdempotent` unable to tell
            // "cancelled once" from "cancelled a token that was already gone".
            return .failed(status: Self.invalidTokenStatus)
        }
        invalidatedTokens.insert(token)
        cancelledTokens.append(token)
        return .ok
#endif
    }

    // MARK: Reading the accounting

    /// The registrations recorded for a name, oldest first.
    func registrations(of name: String) -> [Registration] {
        registrations[name] ?? []
    }

    /// The registration with a given 1-based ordinal for a name.
    func registration(of name: String, ordinal: Int) -> Registration? {
        registrations(of: name).first { $0.ordinal == ordinal }
    }

    /// The most recent registration for a name.
    func latestRegistration(of name: String) -> Registration? {
        registrations(of: name).last
    }

    /// The registrations notifyd would still deliver: the latest token per name, when it is live.
    var liveRegistrations: [String: Int32] {
        var result: [String: Int32] = [:]
        for (name, list) in registrations {
            guard let last = list.last else { continue }
            if !invalidatedTokens.contains(last.token) {
                result[name] = last.token
            }
        }
        return result
    }

    func isInvalidated(_ token: Int32) -> Bool {
        invalidatedTokens.contains(token)
    }

    /// Deliver a notification for a name, as the system would.
    ///
    /// On the queue the registration asked for, which is what `notify_register_dispatch` does and what
    /// the observer's design depends on. Delivering inline on the caller's thread - which is what this
    /// fake used to do - made the observer's queue confinement unobservable and let a callback
    /// interleave with the snapshot in a way production cannot.
    ///
    /// This delivers the *latest* registration. `deliver(_:)` below delivers one specific
    /// registration, which is how a test reaches a callback that outlived its own registration.
    func deliver(_ name: String) {
        guard let registration = latestRegistration(of: name) else {
            XCTFail("no registration for \(name)")
            return
        }
        deliver(registration)
    }

    /// Deliver the callback one specific registration installed, with that registration's own token.
    ///
    /// A real post-cancel callback is exactly this: the block the notification centre queued before
    /// `cancel()` ran, arriving with a token that is now invalid. The token is carried through and
    /// recorded, so a test can refuse a callback whose token no registration ever issued - which is
    /// what the previous spelling (`queued?(101)`) could not do.
    func deliver(_ registration: Registration) {
#if FAKE_BLIND_STALE_CALLBACK
        // MUTATION FLAG, off in every real run. Reintroduces the post-cancel blind spot exactly as
        // the previous revision had it: the callback is invoked with a literal token that no
        // registration ever issued (`queued?(101)`), so nothing about the delivered callback can be
        // checked. `FakeNotifyBlindSpotTests` goes red under it.
        deliveredTokens.append(101)
#else
        deliveredTokens.append(registration.token)
#endif
        // A test may deliver from inside a hook that already runs on that queue (`onGetState` is called
        // from `observe`, which is on the queue); re-entering it would deadlock, and running inline is
        // what real dispatch does there too.
        if DispatchQueue.getSpecific(key: Self.deliveryQueueKey) != nil {
            registration.handler(registration.token)
        } else {
            registration.queue.sync { registration.handler(registration.token) }
        }
    }

    /// The token a source's registration will get, or did get.
    ///
    /// Static because a test must be able to configure a value BEFORE `start()` - which is what "the
    /// phone was already locked when the tunnel came up" means - and there is no registration to read
    /// a token from yet. The instance method below is the post-start form.
    static func token(for source: ScreenStateSource) -> Int32 {
        guard let token = fixedTokens[source.notificationName] else {
            XCTFail("FakeNotify has no token for \(source)")
            return -1
        }
        return token
    }

    /// Points a source's reads at a value before anything is registered.
    ///
    /// Kept as an explicit spelling so a test that means "this is the state at launch" says so; the
    /// instance method below now also works before `start()`.
    static func setState(_ read: NotifyStateRead, of source: ScreenStateSource, in fake: FakeNotify) {
        fake.setState(read, of: source)
    }

    /// The token a registered source actually got, or `nil` before it has registered.
    ///
    /// This is the non-failing form, for callers that have a legitimate reason to ask before
    /// `start()`. `token(for:)` below is the one a test should use when it means "the source IS
    /// registered and I want its token".
    func registeredToken(for source: ScreenStateSource) -> Int32? {
        registeredTokens[source.notificationName]
    }

    /// The token a registered source actually got, or a test failure.
    ///
    /// Tests read this instead of a literal like `100`. The numbers are not stable: `ScreenStateSource`
    /// is `CaseIterable` and the observer registers in `allCases` order, and a registration that was
    /// told to fail consumes no token. Hard-coded numbers therefore stop configuring anything the
    /// moment either changes, and the failure they produce is a silently empty publication rather
    /// than a compile error - which is what made several assertions in this file unreachable before it
    /// was first run.
    func token(for source: ScreenStateSource) -> Int32 {
        guard let token = registeredToken(for: source) else {
            XCTFail("\(source) is not registered, so it has no token to read")
            return -1
        }
        return token
    }

    /// Points a source's next reads at a value, without naming its token.
    ///
    /// Works before and after `start()`. Before, the token is the one the source is about to register
    /// with, which is the only way to express "the phone was already locked when the tunnel came up";
    /// after, it is the token the registration actually got. One method rather than two, so a call site
    /// does not have to know which side of `start()` it is on - getting that wrong is silent, because
    /// it writes a value under a token nobody reads.
    func setState(_ read: NotifyStateRead, of source: ScreenStateSource) {
        guard let token = registeredToken(for: source) ?? Self.fixedTokens[source.notificationName] else {
            XCTFail("FakeNotify has no token for \(source)")
            return
        }
        stateResult[token] = read
    }
}

/// A one-slot box for a value produced on another thread.
///
/// Used by the start/cancel race test. `NSLock` rather than a captured `var`, because a captured `var`
/// mutated from a detached thread is a data race and a Swift 6 diagnostic.
final class StartResultBox: @unchecked Sendable {
    private let access = NSLock()
    private var value: ScreenStateStartResult?

    func store(_ result: ScreenStateStartResult) {
        access.lock()
        defer { access.unlock() }
        value = result
    }

    var stored: ScreenStateStartResult? {
        access.lock()
        defer { access.unlock() }
        return value
    }
}

/// A `ScreenStatePublishing` that records what it was told, in order.
///
/// The recording has two seams and no writable property. `calls` is `private(set)` so a test cannot
/// poke it, and the two seams below are what the tests use instead: `reset()` between phases of one
/// test, and `deliver(_:)` for the two facts `ScreenStatePublishing` has no method for. Both exist
/// because the previous revision of this file called `publisher.calls.removeAll()` in four places,
/// which does not compile - `private(set)` makes the setter inaccessible outside the type, so the
/// whole package failed to build and not one of its assertions had ever run.
final class RecordingPublisher: ScreenStatePublishing {
    enum Call: Equatable {
        case screen(Bool)
        case lock(Bool)
    }

    private(set) var calls: [Call] = []

    /// Forgets the calls recorded so far, so one test can assert phase by phase.
    func reset() {
        calls.removeAll()
    }

    /// The seam that keeps `calls` private while still letting a fake drive it directly. Nothing in
    /// this file needs it today; it is here so the next fake that does does not reopen the setter.
    func record(_ call: Call) {
        calls.append(call)
    }

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
                            // An unlock is only a transition when the lock source was actually
                            // observed locked (`1`) first - rule 5 of `decide`. A `lastObserved` of
                            // `nil` is a source that has never been read, and a `0` from an axis
                            // whose prior value is unknown is indistinguishable from the never-set
                            // `0` that rule 4 refuses on a snapshot, so it is refused on an event
                            // too. Both `nil` and `0` are therefore pinned as non-publishing here.
                            XCTAssertEqual(last, 1, "an unlock was published without a lock having been observed for \(label)")
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
        // Each observer builds its own serial queue, so the fake's queue expectation is per-test.
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
        notify.setState(.value(0), of: .display) // display off
        notify.setState(.value(1), of: .lock) // locked

        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(notify.readOrder.count, 2, "the snapshot is one read per source")
        // `allCases` puts `.lock` first, so the lock fact is read and published before the display's.
        XCTAssertEqual(publisher.calls, [.screen(false), .lock(true)])
    }

    /// Registration happens before the snapshot, and both happen inside the start, so a callback
    /// cannot interleave with the snapshot.
    func testRegistrationPrecedesTheSnapshot() {
        let (observer, notify, publisher) = makeObserver()
        notify.setState(.value(0), of: .display) // display off: the one fact a snapshot may publish
        notify.setState(.value(0), of: .lock) // unlocked: a snapshot must not publish this

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

    /// `cancel()` racing `start()` must not leave a live-looking observer behind.
    ///
    /// `cancel()` is deliberately callable from outside the observer's queue - `stopTunnel` calls it
    /// from whatever thread the NetworkExtension uses - and it fences by bumping the generation. But
    /// `start()` takes its epoch and only stores the tokens after the registration loop, so a
    /// `cancel()` that lands inside that window finds an empty token table, cancels nothing, and
    /// returns; `start()` then stores tokens whose epoch is already dead. The observer reports
    /// `.started`, no callback it holds can ever publish again (`isCurrent` refuses), `hasRegistrations`
    /// is true forever so no later `start()` can revive it, and the two registrations live in notifyd
    /// for the life of the process - which is exactly the "the pause is entered and never lifted"
    /// failure this file's own comments set out to prevent.
    ///
    /// Deterministic by construction: the fake blocks the main thread inside `registerDispatch` while
    /// `start()` runs on another thread, so the interleaving is chosen by the test rather than by the
    /// scheduler. No sleeps.
    func testCancelDuringStartDoesNotLeaveAStartedButDeadObserver() {
        let (observer, notify, _) = makeObserver()

        let insideStart = DispatchSemaphore(value: 0)
        let cancelDone = DispatchSemaphore(value: 0)
        let registrations = (0 ..< ScreenStateSource.allCases.count).map { _ in DispatchSemaphore(value: 0) }
        var registrationIndex = 0

        notify.onRegisterDispatch = { _ in
            // Publish the registration, then wait for the test to have cancelled. Every registration
            // is held, so the window is covered wherever `cancel()` lands.
            insideStart.signal()
            let index = registrationIndex
            registrationIndex += 1
            _ = registrations[min(index, registrations.count - 1)].wait(timeout: .now() + 5)
        }

        // The result crosses a thread boundary, so it is carried in a box with a lock rather than a
        // captured `var` - which Swift 6 mode rejects, and which would be a data race in any case.
        let resultBox = StartResultBox()
        let started = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resultBox.store(observer.start())
            started.signal()
        }

        // Wait until `start()` is provably inside the registration loop, then cancel from here.
        _ = insideStart.wait(timeout: .now() + 5)
        observer.cancel()
        cancelDone.signal()
        for semaphore in registrations { semaphore.signal() }
        _ = started.wait(timeout: .now() + 5)
        notify.onRegisterDispatch = nil

        // Whatever `start()` decided to report, the tokens it registered must not outlive the cancel.
        XCTAssertEqual(Set(notify.cancelledTokens), Set(notify.registeredTokens.values),
                       "cancel() returned but start() kept registrations that no cancel will ever release")

        // And the observer must be genuinely live again, not merely "not refused".
        //
        // The distinction matters and this assertion used to elide it: `XCTAssertTrue(second.isStarted)`
        // is also satisfied by `.alreadyStarted`, which is the exact state this test exists to rule out -
        // a `hasRegistrations == true` left behind by the lost race. The equality below refuses both
        // `.alreadyStarted` (so the stranded state cannot pass) and `.failed` (so a start that could not
        // register cannot pass either).
        let second = observer.start()
        XCTAssertEqual(second, .started,
                       "a start that lost the race left the observer unusable: \(second)")
        observer.cancel()
    }

    /// A delivered event publishes, and a repeated delivery of the same value does not.
    func testAnEventPublishesOnceAndARepeatDoesNot() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [])

        notify.setState(.value(1), of: .lock)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [.lock(true)])

        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [.lock(true)], "a repeated value produced a second edge")
    }

    /// The sequence the device actually produces when a notification lights the lock screen:
    /// locked -> display on -> still locked -> unlocked. Only the lock axis may move the level.
    ///
    /// The start snapshot reads the real state at that moment, which is the locked phone with its
    /// screen off: `displayStatus == 0` and `lockstate == 1`. Both are sleep facts, so the snapshot
    /// publishes **both** - and the order is `ScreenStateSource.allCases` order, which follows the
    /// declaration: the display first, then the lock.
    func testNotificationLightsTheScreenAndTheDeviceStaysLocked() {
        let (observer, notify, publisher) = makeObserver()
        notify.setState(.value(0), of: .display) // display off
        notify.setState(.value(1), of: .lock) // locked
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.screen(false), .lock(true)])

        // The push arrives and the lock screen lights: the display goes on, the device is still locked.
        notify.setState(.value(1), of: .display)
        notify.deliver(displayName)
        XCTAssertEqual(publisher.calls, [.screen(false), .lock(true), .screen(true)],
                       "a display-on publishes the resume edge and nothing else")

        // The user locks again, then unlocks for real.
        notify.setState(.value(0), of: .lock)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls.last, .lock(false), "the unlock is the level release")
    }

    /// A display going off is a sleep fact; a display going on is not a wake. The publisher offers no
    /// `wakeNow`, so this is also a statement about the type: there is no path to a false wake.
    ///
    /// The values are set after `start()`, because a token only exists once the source registered;
    /// setting them through `setState` before that would read no token and configure nothing.
    func testDisplayOnNeverReachesAWakeEntryPoint() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        publisher.reset()

        // The display goes off and comes back on. The first half is a sleep fact and the second is
        // the resume edge, and the case is that the second is a `recordScreenState` and not a wake.
        // Driving the transition rather than delivering a lone display-on is what makes the
        // assertion below about the resume edge instead of about a fact `start()` had already read.
        notify.setState(.value(0), of: .display) // display off
        notify.deliver(displayName)
        XCTAssertEqual(publisher.calls, [.screen(false)], "a display-off pauses")

        notify.setState(.value(1), of: .display) // display on
        notify.deliver(displayName)
        XCTAssertEqual(publisher.calls, [.screen(false), .screen(true)],
                       "a display-on publishes the resume edge and nothing else")
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
    ///
    /// The token numbers are looked up rather than assumed. `FakeNotify` does not consume a token for
    /// a registration it was told to fail - a failed `notify_register_dispatch` returns no token - so
    /// the numbers a test sees depend on how many failures preceded them, and a literal `100`/`101`
    /// silently configures nothing once that count changes.
    func testAFailedStartCanBeRetried() {
        let (observer, notify, publisher) = makeObserver()
        notify.registrationResult[displayName] = .failed(status: 1)
        XCTAssertFalse(observer.start().isStarted)
        XCTAssertEqual(publisher.calls, [])

        notify.registrationResult.removeValue(forKey: displayName)
        notify.setState(.value(1), of: .lock) // locked
        notify.setState(.value(0), of: .display) // display off

        // The retry's own snapshot reads both sources through the tokens it just registered.
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
    ///
    /// # What the name promises, and what the body used to check
    ///
    /// The name says a callback ran after the cancel. The body said `queued?(101)`: optional
    /// chaining, so a fixture that had failed to record a handler would have made the whole test a
    /// no-op that still passed, and the token `101` is one no registration ever issued, so nothing
    /// about the delivered callback could be asserted. It also had no positive control, so a
    /// regression that stopped ALL deliveries would have left it green.
    ///
    /// It now takes the callback from the registration that installed it, fails if there is none,
    /// proves the delivery path works before the cancel, and asserts the token it was handed is the
    /// dead one - so the test can only pass because the observer refused a genuine post-cancel
    /// callback.
    func testACallbackAfterCancelPublishesNothing() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)

        // Positive control: while the registration is live, the same delivery DOES publish. Without
        // this, "nothing was published" would also be satisfied by `deliver` doing nothing at all.
        notify.setState(.value(1), of: .lock)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [.lock(true)],
                       "the fixture cannot deliver a live callback, so the rest of this test proves nothing")
        publisher.reset()

        guard let queued = notify.latestRegistration(of: lockName) else {
            XCTFail("the fixture recorded no registration for \(lockName)")
            return
        }
        let deliveriesBefore = notify.deliveredTokens.count

        observer.cancel()

        // The value would publish an unlock if the queued callback were still live.
        notify.setState(.value(0), of: .lock)
        notify.deliver(queued) // the callback the centre had already submitted

        XCTAssertEqual(publisher.calls, [], "a callback ran after cancel() returned")
        XCTAssertEqual(Array(notify.deliveredTokens.dropFirst(deliveriesBefore)), [queued.token],
                       "the callback was handed a token no registration issued, so nothing about it was checked")
        XCTAssertTrue(notify.isInvalidated(queued.token),
                      "the token the callback arrived on was still live, so this was not a post-cancel callback")
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
        publisher.reset()

        var cancelled = false
        notify.setState(.value(1), of: .lock)
        let lockToken = notify.token(for: .lock)
        notify.onGetState = { token in
            if token == lockToken, !cancelled {
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
    ///
    /// The value is set through `setState`, which reads the token from the *new* registration, so the
    /// test does not depend on which numbers the two registrations happened to take.
    func testStartAfterCancelWorks() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        observer.cancel()

        XCTAssertEqual(observer.start(), .started)
        // Set through the new registration's token, and read by a resync: a token only exists once
        // the source registered, so a value configured before `start()` configures nothing.
        notify.setState(.value(0), of: .display) // display off, a publishable snapshot fact
        observer.resync()

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
        notify.setState(.value(1), of: .lock)
        observer.resync()

        XCTAssertEqual(publisher.calls, [.lock(true)], "resync did not recover the missed lock")
    }

    /// And it can never invent a wake, which is the property that makes it safe to call on every
    /// NetworkExtension resume.
    func testResyncCanNeverPublishAWake() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)

        // The extension resumed, the device was unlocked and the lock screen is lit, so both sources
        // now read the "in use" value: display 1 is on, lock 0 is unlocked. Both are facts a snapshot
        // is forbidden to publish, and neither may reach the core from this path.
        notify.setState(.value(1), of: .display)
        notify.setState(.value(0), of: .lock)
        observer.resync()

        XCTAssertFalse(publisher.calls.contains(.lock(false)), "resync published an unlock")
        XCTAssertFalse(publisher.calls.contains(.screen(true)), "resync published a display-on")
        XCTAssertEqual(publisher.calls, [], "resync published a non-sleep fact")
    }

    /// A resync that finds a sleep fact already known publishes nothing, so a resume loop cannot
    /// produce a repeating pause.
    func testResyncOfAnUnchangedFactPublishesNothing() {
        let (observer, notify, publisher) = makeObserver()
        notify.setState(.value(1), of: .lock)
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
        notify.setState(.value(1), of: .lock)
        XCTAssertEqual(observer.start(), .started)
        XCTAssertEqual(publisher.calls, [.lock(true)])
        publisher.reset()

        notify.setState(.failed(status: 1), of: .lock)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [], "a failed read published")

        // The value is still 1, so this is a repeat and not a fresh edge.
        notify.setState(.value(1), of: .lock)
        notify.deliver(lockName)
        XCTAssertEqual(publisher.calls, [], "the failed read lost the remembered value")
    }

    /// A callback queued before a `cancel()` publishes nothing, even after the observer has started
    /// again.
    ///
    /// This is the `deliver()` that used to sit, as a bare statement with a "not registered yet:
    /// harmless" comment, at the top of the test above. It was not harmless: `FakeNotify.deliver`
    /// calls `XCTFail` when the name has no handler, so the test above could never pass even once the
    /// package compiled.
    ///
    /// # What this proves, corrected
    ///
    /// An earlier version of this comment claimed it reached `observe`'s **registration lookup** - "the
    /// second half" of the guard, with the epoch deliberately still valid. That is false, and the
    /// arrangement cannot be made to reach it: `observe` checks `isCurrent(epoch)` FIRST, and any
    /// `cancel()` that empties the registration table also advances the generation, so the epoch check
    /// always refuses before the lookup runs. The lookup is unreachable by this route, which is why no
    /// test covers it.
    ///
    /// What the arrangement does prove is the property that matters and that
    /// `testACallbackAfterCancelPublishesNothing` does not: the callback is invoked **after a fresh
    /// `start()`**, so the observer is live again, holding a new epoch and a new token for the same
    /// source - and the stale callback still publishes nothing.
    func testACallbackQueuedBeforeACancelDoesNotPublishAfterARestart() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        publisher.reset()

        // A callback the notification centre could still deliver: captured while the registration was
        // live, and released by the cancel below. Taken from the registration itself, so the token it
        // arrives on is the one that registration took rather than a literal.
        guard let queued = notify.latestRegistration(of: lockName) else {
            XCTFail("the fixture did not record a registration for \(lockName)")
            return
        }
        observer.cancel()

        // The observer is running again: a new epoch, and a new registration for this same source.
        XCTAssertEqual(observer.start(), .started)
        publisher.reset()

        // The read answers "locked", so a publication here could only come from the stale callback
        // being treated as current.
        notify.setState(.value(1), of: .lock)
        notify.deliver(queued)

        XCTAssertEqual(publisher.calls, [],
                       "a callback queued before a cancel published into a later generation")
        XCTAssertEqual(notify.deliveredTokens, [queued.token],
                       "the stale callback did not arrive on the token of the registration that queued it")
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

// MARK: - The fixture's own blind spots

/// The three things `FakeNotify` used to be unable to say, and the tests that now depend on it
/// being able to.
///
/// Each of these fails if the corresponding ability is removed from the fake. That is checked by
/// execution rather than asserted: `fakenotify-red-proof.ps1` compiles this file with one of the
/// `FAKE_BLIND_*` mutation flags set, which restores the pre-fix behaviour inside `FakeNotify`, and
/// shows this class going red. A test whose fixture cannot fail is not a test.
final class FakeNotifyBlindSpotTests: XCTestCase {
    private func makeObserver() -> (ScreenStateObserver, FakeNotify, RecordingPublisher) {
        let notify = FakeNotify()
        let publisher = RecordingPublisher()
        let observer = ScreenStateObserver(notify: notify, publisher: publisher)
        return (observer, notify, publisher)
    }

    /// BLIND SPOT 1: `INVALID_TOKEN`.
    ///
    /// `cancel` used to answer `.ok` to everything, and `getState` used to answer whatever value the
    /// test had configured for a token notifyd had already released. So a read on a dead token looked
    /// exactly like a read on a live one, and "a read that failed establishes nothing" could never be
    /// reached through the one path that produces it on a device.
    ///
    /// Mutation that makes this red: `-D FAKE_BLIND_INVALID_TOKEN`.
    func testACancelledTokenIsInvalidAndEstablishesNothing() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)
        let token = notify.token(for: .lock)
        // A value that would publish an unlock if it were ever read back.
        notify.setState(.value(0), of: .lock)

        observer.cancel()

        XCTAssertTrue(notify.isInvalidated(token), "cancel() left the token live")
        XCTAssertEqual(notify.getState(token: token), .failed(status: FakeNotify.invalidTokenStatus),
                       "a read on a released token answered a value instead of NOTIFY_STATUS_INVALID_TOKEN")
        XCTAssertEqual(notify.cancel(token: token), .failed(status: FakeNotify.invalidTokenStatus),
                       "releasing a released token was reported as a fresh success")
        XCTAssertEqual(notify.cancelledTokens.filter { $0 == token }.count, 1,
                       "the same token was released more than once")

        // And the configured value must not be able to reach the publisher through that dead token.
        guard let stale = notify.latestRegistration(of: lockName) else {
            XCTFail("the fixture lost the registration")
            return
        }
        publisher.reset()
        notify.deliver(stale)
        XCTAssertEqual(publisher.calls, [], "a callback on a released token published")
    }

    /// BLIND SPOT 2: duplicate registration counting.
    ///
    /// The fake used to keep one handler and one token per name, overwriting on every registration,
    /// so registering a name twice was indistinguishable from registering it once.
    /// `testStartIsIdempotent` asserted that the number of *reads* did not grow, which a start that
    /// registered a second handler and skipped its snapshot would also satisfy.
    ///
    /// Mutation that makes this red: `-D FAKE_BLIND_DUPLICATE_REGISTRATION`.
    func testStartRegistersEachNameExactlyOnceAcrossARestart() {
        let (observer, notify, _) = makeObserver()
        let names = ScreenStateSource.allCases.map(\.notificationName)

        XCTAssertEqual(observer.start(), .started)
        for name in names {
            XCTAssertEqual(notify.registrationAttempts[name], 1, "one start() attempted \(name) more than once")
            XCTAssertEqual(notify.successfulRegistrations[name], 1, "one start() registered \(name) more than once")
            XCTAssertEqual(notify.registrations(of: name).count, 1)
        }
        XCTAssertEqual(notify.liveRegistrations.count, 2)

        // A second start() must not register anything at all - not merely skip the snapshot.
        XCTAssertEqual(observer.start(), .alreadyStarted)
        for name in names {
            XCTAssertEqual(notify.registrationAttempts[name], 1, "the second start() re-registered \(name)")
            XCTAssertEqual(notify.registrations(of: name).count, 1)
        }

        observer.cancel()
        XCTAssertEqual(notify.liveRegistrations.count, 0, "cancel() left a registration live in notifyd")

        // A restart is a fresh registration per name, and the history says so.
        XCTAssertEqual(observer.start(), .started)
        for name in names {
            XCTAssertEqual(notify.registrationAttempts[name], 2, "\(name) was not attempted afresh after the cancel")
            XCTAssertEqual(notify.successfulRegistrations[name], 2, "\(name) did not register afresh after the cancel")
            XCTAssertEqual(notify.registrations(of: name).count, 2)
        }
        XCTAssertEqual(notify.registrations(of: lockName).map(\.ordinal), [1, 2],
                       "the restarted registrations are not distinguishable from the first")
        // Exactly one live registration per source. A restart that leaked the previous one would
        // leave three registrations behind and still report success.
        XCTAssertEqual(notify.liveRegistrations.count, 2, "a restart leaked a registration")
        observer.cancel()
    }

    /// BLIND SPOT 3: a callback arriving after `cancel()`.
    ///
    /// The fake used to keep only the live handler, so a callback that outlived its own registration
    /// could not be named. The two tests that deliver one reached into `handlers[name]` and called it
    /// with a literal token (`101`, `500`) that no registration had ever issued - and with optional
    /// chaining, so "there was no handler at all" and "the observer refused the handler" produced the
    /// same green.
    ///
    /// Here the callback comes from the registration that installed it, carries that registration's
    /// own token, and the test refuses any token the fake did not issue.
    ///
    /// Mutation that makes this red: `-D FAKE_BLIND_STALE_CALLBACK`.
    func testACallbackFromACancelledRegistrationArrivesWithItsOwnDeadToken() {
        let (observer, notify, publisher) = makeObserver()
        XCTAssertEqual(observer.start(), .started)

        guard let queued = notify.latestRegistration(of: lockName) else {
            XCTFail("the fixture recorded no registration for \(lockName)")
            return
        }
        XCTAssertEqual(queued.token, notify.token(for: .lock),
                       "the fixture handed back a registration for the wrong token")

        publisher.reset()
        observer.cancel()

        // The registration outlives its token: a callback the notification centre had already queued
        // cannot be un-queued, so the registration that queued it has to stay nameable.
        XCTAssertEqual(notify.registrations(of: lockName).count, 1,
                       "cancel() erased the registration the queued callback came from")
        XCTAssertTrue(notify.isInvalidated(queued.token))

        // The value would publish an unlock if the callback were still live.
        notify.setState(.value(0), of: .lock)
        let readsBefore = notify.readOrder.count
        notify.deliver(queued)

        XCTAssertEqual(publisher.calls, [], "a post-cancel callback published an unlock")
        XCTAssertEqual(notify.readOrder.count, readsBefore,
                       "the observer read state through a released token instead of refusing on the epoch")
        XCTAssertEqual(notify.deliveredTokens, [queued.token],
                       "the callback was handed a token no registration issued")
        for delivered in notify.deliveredTokens {
            XCTAssertTrue(notify.isInvalidated(delivered),
                          "a callback was delivered on a token that was never released")
        }
    }
}
