import Policy
import XCTest

/// The subscription-recovery decisions, driven directly.
///
/// The defect these pin: after a trip through the background the status subscription can be dead
/// while the client still reports itself connected. The foreground path connects only while
/// `!isConnected`, and it runs *before* the loss is observed, so it does nothing; the loss then
/// arrives with nobody watching for it. The rebuild therefore has to come from the loss - and only
/// once, so a tunnel that is genuinely gone cannot spin.
final class CommandSubscriptionRecoveryTests: XCTestCase {
    /// A client that has asked for a connection and got one - the ordinary running state.
    private func liveClient() -> CommandSubscriptionRecovery {
        var recovery = CommandSubscriptionRecovery()
        recovery.connectionRequested()
        recovery.connectionEstablished()
        return recovery
    }

    // MARK: - The case that was broken

    func testALiveSubscriptionThatEndsIsRebuilt() {
        var recovery = liveClient()
        XCTAssertTrue(
            recovery.recoverIfNeeded(wasLive: true),
            "a subscription that was live and ended must be rebuilt; this is the whole fix"
        )
    }

    /// The exact ordering the app produces, and the reason the foreground path cannot cover it.
    func testForegroundEnsureIsRefusedWhileTheLossIsStillUnobservedAndTheLossThenRebuilds() {
        var recovery = liveClient()

        // The scene became active first. `isConnected` was still true, so `connect()` refused -
        // nothing was rebuilt by the foreground path, and nothing will call it again.
        XCTAssertFalse(
            recovery.acceptsConnect(isConnected: true, isConnecting: false),
            "the foreground ensure is refused while the client still believes it is connected"
        )

        // The loss is observed a moment later, and that is what drives the rebuild.
        XCTAssertTrue(recovery.recoverIfNeeded(wasLive: true))
    }

    // MARK: - Bounded: one attempt per loss

    func testASecondLossBeforeAConnectionSucceedsIsNotRebuilt() {
        var recovery = liveClient()
        XCTAssertTrue(recovery.recoverIfNeeded(wasLive: true))
        XCTAssertFalse(
            recovery.recoverIfNeeded(wasLive: true),
            "a tunnel that is genuinely gone must not produce a retry loop"
        )
        XCTAssertFalse(recovery.recoverIfNeeded(wasLive: true))
    }

    func testTheBoundIsReArmedByAConnectionThatSucceeded() {
        var recovery = liveClient()
        XCTAssertTrue(recovery.recoverIfNeeded(wasLive: true))
        XCTAssertFalse(recovery.recoverIfNeeded(wasLive: true))

        recovery.connectionEstablished()
        XCTAssertTrue(
            recovery.recoverIfNeeded(wasLive: true),
            "one attempt per loss, not one attempt per process"
        )
    }

    /// A failed attempt reports through `lastError`; it is not a loss the user sees as "the cards
    /// stopped", and treating it as one would spin.
    func testAnAttemptThatNeverCameUpIsNotRebuilt() {
        var recovery = CommandSubscriptionRecovery()
        recovery.connectionRequested()
        XCTAssertFalse(recovery.recoverIfNeeded(wasLive: false))
        XCTAssertFalse(recovery.recoverIfNeeded(wasLive: false))
    }

    // MARK: - A teardown the client asked for is not a loss

    func testATeardownIsNotRebuilt() {
        var recovery = liveClient()
        recovery.teardownRequested()
        XCTAssertFalse(recovery.recoverIfNeeded(wasLive: true))
    }

    func testATeardownReArmsTheNextSubscription() {
        var recovery = liveClient()
        recovery.teardownRequested()
        XCTAssertFalse(recovery.wantsConnection)

        recovery.connectionRequested()
        recovery.connectionEstablished()
        XCTAssertTrue(recovery.recoverIfNeeded(wasLive: true))
    }

    // MARK: - Parked for the background

    func testASuspendedConnectionIsNotRebuiltUntilItResumes() {
        var recovery = liveClient()
        recovery.suspend()
        XCTAssertFalse(
            recovery.recoverIfNeeded(wasLive: true),
            "a connection parked for the background was torn down on purpose"
        )
        recovery.resume()
        XCTAssertTrue(recovery.recoverIfNeeded(wasLive: true))
    }

    func testSuspendAndResumeDoNotChangeWhetherASubscriptionIsWanted() {
        var recovery = liveClient()
        recovery.suspend()
        XCTAssertTrue(recovery.wantsConnection, "parking the connection is not giving it up")
        recovery.resume()
        XCTAssertTrue(recovery.wantsConnection)
    }

    func testTeardownClearsASuspension() {
        var recovery = liveClient()
        recovery.suspend()
        recovery.teardownRequested()
        XCTAssertFalse(recovery.isSuspended)
        XCTAssertTrue(
            recovery.acceptsConnect(isConnected: false, isConnecting: false),
            "an explicit disconnect must leave the client connectable again"
        )
    }

    // MARK: - Whether a connect request is accepted

    func testConnectIsRefusedWhileConnectedConnectingOrSuspended() {
        XCTAssertTrue(liveClient().acceptsConnect(isConnected: false, isConnecting: false))

        var recovery = liveClient()
        XCTAssertFalse(
            recovery.acceptsConnect(isConnected: true, isConnecting: false),
            "already connected"
        )
        XCTAssertFalse(
            recovery.acceptsConnect(isConnected: false, isConnecting: true),
            "already connecting - this is what keeps one subscription, not two"
        )
        recovery.suspend()
        XCTAssertFalse(
            recovery.acceptsConnect(isConnected: false, isConnecting: false),
            "parked for the background"
        )
    }

    /// Whatever the order, exactly one of the two triggers rebuilds the subscription, and the
    /// client never ends up wanting two.
    func testEitherOrderingOfForegroundAndLossEndsUpConnectable() {
        // Loss observed first: the foreground ensure then finds a disconnected client.
        var lossFirst = liveClient()
        XCTAssertTrue(lossFirst.recoverIfNeeded(wasLive: true))
        XCTAssertTrue(lossFirst.acceptsConnect(isConnected: false, isConnecting: false))

        // Foreground first: it is refused, and the loss rebuilds.
        var foregroundFirst = liveClient()
        XCTAssertFalse(foregroundFirst.acceptsConnect(isConnected: true, isConnecting: false))
        XCTAssertTrue(foregroundFirst.recoverIfNeeded(wasLive: true))
        XCTAssertTrue(foregroundFirst.acceptsConnect(isConnected: false, isConnecting: false))
    }

    // MARK: - The default state

    func testAFreshClientWantsNothing() {
        let recovery = CommandSubscriptionRecovery()
        XCTAssertFalse(recovery.wantsConnection)
        XCTAssertFalse(recovery.isSuspended)
        XCTAssertFalse(recovery.hasAttemptedRecovery)
        XCTAssertTrue(
            recovery.acceptsConnect(isConnected: false, isConnecting: false),
            "a fresh client is connectable"
        )
    }
}
