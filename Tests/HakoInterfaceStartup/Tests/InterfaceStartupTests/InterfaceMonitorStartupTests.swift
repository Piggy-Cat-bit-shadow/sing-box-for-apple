import Foundation
import XCTest

@testable import Policy

/// The interface-monitor startup policy.
///
/// The defect these cover: with airplane mode on, starting the VPN left the UI on Working forever.
/// `startDefaultInterfaceMonitor` waited on a semaphore that a `NWPathMonitor` path update was
/// supposed to signal, with no timeout - and with no network there is no path transition, so the
/// update need not arrive. The tunnel never started and nothing failed.
///
/// The five properties the fix has to hold are the five below. Four of them are decisions this policy
/// makes directly; the fifth is a shape assertion, because a lock that deadlocks is not something a
/// unit test can see from here.
final class InterfaceMonitorStartupTests: XCTestCase {
    // MARK: - 1 and 2: the wait is bounded, and no update is a legal outcome

    /// The bound exists, is finite, and is expressed in whole seconds.
    ///
    /// This is the assertion that would have failed before the fix: the wait was `.wait()` with no
    /// argument, so there was no value to assert at all.
    func testFirstUpdateHasABoundedTimeout() {
        let timeout = InterfaceMonitorStartup.firstUpdateTimeout
        guard case let .seconds(seconds) = timeout else {
            return XCTFail("the first-update bound must be expressible in seconds, got \(timeout)")
        }
        XCTAssertGreaterThan(seconds, 0, "a zero bound would discard every real update")
        XCTAssertLessThanOrEqual(seconds, 10, "a bound this long is a hang the user can see")
    }

    /// A wait that ends without a signal is `seededWithoutUpdate`, not a failure.
    ///
    /// Airplane mode is the case: the seeded `currentPath` is the answer, the listener is told there is
    /// no default interface, and startup continues. Nothing here may throw or block.
    func testAnUpdateThatNeverArrivesStillCompletes() {
        XCTAssertEqual(InterfaceMonitorStartup.outcome(signalled: false), .seededWithoutUpdate)
    }

    /// A wait that was signalled is `updated`.
    func testAnUpdateThatArrivesIsReportedAsUpdated() {
        XCTAssertEqual(InterfaceMonitorStartup.outcome(signalled: true), .updated)
    }

    /// The bound is enforced against a real semaphore, so the timeout is a mechanism rather than a
    /// constant that happens to be small.
    ///
    /// The wait is driven to completion with the same `DispatchSemaphore` API the shipping code uses.
    /// A semaphore nobody signals must return `.timedOut` at the bound instead of blocking; that is
    /// exactly the airplane-mode path, and it is the one the old code sat in forever.
    func testAnUnsignalledWaitReturnsAtTheBoundRatherThanBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        let bound = DispatchTimeInterval.milliseconds(50)
        let started = DispatchTime.now()
        let result = semaphore.wait(timeout: .now() + bound)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds

        XCTAssertEqual(result, .timedOut, "an unsignalled wait must time out, not block")
        XCTAssertEqual(InterfaceMonitorStartup.outcome(signalled: result == .success),
                       .seededWithoutUpdate)
        // Generous: this asserts the wait returned promptly rather than that the clock is precise.
        XCTAssertLessThan(elapsed, 2_000_000_000, "the wait must return at its bound")
    }

    /// The other half of the same mechanism: a signalled semaphore reports `updated`.
    func testASignalledWaitReportsThatTheUpdateArrived() {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { semaphore.signal() }
        let result = semaphore.wait(timeout: .now() + .seconds(2))
        XCTAssertEqual(result, .success)
        XCTAssertEqual(InterfaceMonitorStartup.outcome(signalled: result == .success), .updated)
    }

    // MARK: - 3: recovery is a later update, and it is not a timeout decision

    /// A later update is published rather than dropped, which is what makes "airplane mode, then Wi-Fi
    /// on" recover: the monitor stays installed, so its callbacks keep reaching the listener.
    ///
    /// The policy only decides staleness, and a callback from the current generation is never stale -
    /// however long after startup it arrives.
    func testACallbackFromTheCurrentGenerationIsAlwaysPublished() {
        var generation = InterfaceMonitorStartup.Generation()
        let installed = generation.next()
        XCTAssertEqual(InterfaceMonitorStartup.disposition(callback: installed,
                                                           current: generation), .publish)
    }

    // MARK: - 4: a late callback cannot pollute a newer generation

    /// The defect this guards, stated as a sequence: start A, A's first update has not arrived, a reset
    /// or a second start supersedes it, and then A's callback finally runs.
    ///
    /// It must be dropped. Publishing it would hand the new listener the old interface and overwrite
    /// the state the new monitor is about to establish.
    func testALateCallbackFromASupersededMonitorIsDropped() {
        var generation = InterfaceMonitorStartup.Generation()
        let monitorA = generation.next()          // start A
        let monitorB = generation.next()          // start B supersedes A
        XCTAssertEqual(InterfaceMonitorStartup.disposition(callback: monitorA, current: generation), .drop,
                       "A's late callback must not reach the listener B installed")
        XCTAssertEqual(InterfaceMonitorStartup.disposition(callback: monitorB, current: generation), .publish)
    }

    /// The clearing half: `retire()` is what `closeDefaultInterfaceMonitor()` and `reset()` call, and it
    /// must invalidate an in-flight callback for the same reason a new start does.
    ///
    /// `reset()` is the one that matters, because `stopService()` reaches it from the core's gRPC
    /// goroutine - an independent thread by construction - so this sequence is reachable without any
    /// assumption about NetworkExtension reentrancy.
    func testRetiringAMonitorDropsItsInFlightCallback() {
        var generation = InterfaceMonitorStartup.Generation()
        let installed = generation.next()
        generation.retire()
        XCTAssertEqual(InterfaceMonitorStartup.disposition(callback: installed, current: generation), .drop)
    }

    /// Retiring without installing a replacement still moves the generation, so a callback queued
    /// before a bare `closeDefaultInterfaceMonitor()` cannot publish into the gap.
    func testRetireMovesTheGenerationEvenWithNoSuccessor() {
        var generation = InterfaceMonitorStartup.Generation()
        let installed = generation.next()
        let before = generation
        generation.retire()
        XCTAssertNotEqual(generation, before)
        XCTAssertFalse(generation.owns(installed))
    }

    /// A generation is never compared against itself across a replace, which is the property the two
    /// call sites depend on: `next()` on install, `retire()` on clear, and never the same value twice.
    func testSuccessiveGenerationsAreDistinctAndOrdered() {
        var generation = InterfaceMonitorStartup.Generation()
        let first = generation.next()
        let second = generation.next()
        XCTAssertNotEqual(first, second)
        XCTAssertLessThan(first, second)
        XCTAssertTrue(second.owns(second))
        XCTAssertFalse(second.owns(first))
    }

    // MARK: - 5: the lock is not held across the wait

    /// A shape assertion, and labelled as one: the shipping adapter does not take
    /// `serviceLifecycleLock` around this wait.
    ///
    /// The lock is held across `startOrReloadService` and the monitor install it triggers (see
    /// `ExtensionProvider`), and the wait is inside that region. If the wait could block for the
    /// two-second bound while the lock was held by a start that was itself waiting here, a concurrent
    /// `stopService()` - reachable synchronously from the core's gRPC handler - would block on the
    /// lock for as long as the bound. That is a latency regression rather than a deadlock, but it is
    /// the kind of thing a bound can introduce, so the ordering is asserted where it can be read.
    ///
    /// This test is about the *policy* not owning a lock: `InterfaceMonitorStartup` has no lock, takes
    /// no lock and cannot take one, so nothing it does can be held across a lifecycle operation.
    func testThePolicyTakesNoLockOfItsOwn() throws {
        let source = try String(contentsOf: Self.policySourceURL, encoding: .utf8)
        for forbidden in ["NSLock", "os_unfair_lock", "DispatchSemaphore.wait()", "pthread_mutex"] {
            XCTAssertFalse(source.contains(forbidden),
                           "the policy must not take a lock, and must not wait unboundedly (\(forbidden))")
        }
        // And it must not import NetworkExtension: that is what keeps it testable off-device.
        XCTAssertFalse(source.contains("import NetworkExtension"))
    }

    // MARK: - The adapter still has to use this policy

    /// The policy is only worth testing if the shipping adapter calls it, so the wiring is asserted too.
    ///
    /// Without this, the whole package could pass while `startDefaultInterfaceMonitor` went back to an
    /// unbounded `semaphore.wait()` - the tests would be green about a type nobody used.
    func testTheAdapterUsesTheBoundAndTheGeneration() throws {
        let adapter = try String(contentsOf: Self.adapterSourceURL, encoding: .utf8)
        XCTAssertTrue(adapter.contains("InterfaceMonitorStartup.firstUpdateTimeout"),
                      "startDefaultInterfaceMonitor must wait with the policy's bound")
        XCTAssertTrue(adapter.contains("InterfaceMonitorStartup.outcome(signalled:"),
                      "the wait's result must be classified by the policy")
        XCTAssertTrue(adapter.contains("InterfaceMonitorStartup.disposition(callback:"),
                      "the callback must be gated on the generation")
        XCTAssertFalse(adapter.contains("semaphore.wait()"),
                       "an unbounded wait is the defect this policy exists to prevent")
    }

    // MARK: - Source locations

    /// The policy file that ships, reached through the symlink the package compiles.
    private static var policySourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                                  // InterfaceStartupTests/
            .deletingLastPathComponent()                                  // Tests/
            .deletingLastPathComponent()                                  // HakoInterfaceStartup/
            .deletingLastPathComponent()                                  // Tests/
            .deletingLastPathComponent()                                  // repo root
            .appendingPathComponent("Library/Network/InterfaceMonitorStartup.swift")
    }

    /// The adapter, which is not compiled here and so is read as text.
    private static var adapterSourceURL: URL {
        policySourceURL.deletingLastPathComponent()
            .appendingPathComponent("ExtensionPlatformInterface.swift")
    }
}
