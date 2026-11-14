import Policy
import XCTest

/// How many report-archive rounds a foreground return may start.
///
/// The defect these pin: the phone's root asks for `postReload()` from `onAppear` and from
/// `scenePhase` becoming active, and both fire on the same return from the background. Each round
/// walks three archives and reads a file per report, on the path where the app is drawing its first
/// frames. The gate's contract is two-sided: redundant rounds are merged, and a request that arrives
/// while a round is running is never lost.
final class ReportRefreshGateTests: XCTestCase {
    func testTheFirstRequestOwnsTheRound() {
        var gate = ReportRefreshGate()
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.begin(), "an idle gate starts the round")
        XCTAssertTrue(gate.isBusy)
        XCTAssertFalse(gate.isAnotherRoundPending)
    }

    func testASecondRequestDuringARoundIsRememberedNotStarted() {
        var gate = ReportRefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "the scan already running covers this request")
        XCTAssertTrue(gate.isAnotherRoundPending)
    }

    func testTheRememberedRequestGetsItsOwnRoundImmediatelyAfter() {
        var gate = ReportRefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.end(), "the follow-up is owed")
        XCTAssertTrue(gate.isBusy, "the caller still owns the work while it runs the follow-up")
        XCTAssertFalse(gate.end(), "and nothing further is owed")
        XCTAssertFalse(gate.isBusy)
    }

    /// The reason this is not a throttle: a burst during one round must collapse to exactly one
    /// follow-up, not to one per request.
    func testABurstDuringOneRoundCollapsesToOneFollowUp() {
        var gate = ReportRefreshGate()
        XCTAssertTrue(gate.begin())
        for _ in 0 ..< 5 {
            XCTAssertFalse(gate.begin())
        }
        XCTAssertTrue(gate.end())
        XCTAssertFalse(gate.end())
        XCTAssertFalse(gate.isBusy)
    }

    func testTheGateAcceptsANewRoundAfterEverythingSettled() {
        var gate = ReportRefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.end())
        XCTAssertFalse(gate.end())

        XCTAssertTrue(gate.begin(), "a later foreground return still gets its refresh")
        XCTAssertFalse(gate.end())
    }

    /// A request that arrives during the follow-up round is remembered in its turn, so a scan that
    /// keeps overlapping with new triggers still converges instead of starving them.
    func testARequestDuringTheFollowUpRoundIsRememberedAgain() {
        var gate = ReportRefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.end())

        XCTAssertFalse(gate.begin(), "this arrives while the follow-up runs")
        XCTAssertTrue(gate.end(), "so it is owed a third round")
        XCTAssertFalse(gate.end())
        XCTAssertFalse(gate.isBusy)
    }
}
