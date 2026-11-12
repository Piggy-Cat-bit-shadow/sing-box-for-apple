import XCTest

@testable import Contract

/// A selection is settled by the identity of the ATTEMPT and the state the group reports, not by
/// the tags that happen to be on screen.
///
/// These tests drive the ledger directly: the kernel's read-back is simulated as the JSON document
/// `CommandClient.SelectOutboundWithRequest` produces.
final class SelectionOrderingTests: XCTestCase {
    private func readBack(
        requestID: UInt64,
        tag: String? = "member-b",
        revision: UInt64 = 7,
        supported: Bool = true,
        unconfirmed: Bool = false,
        stale: Bool = false
    ) -> SelectionReadBack {
        SelectionReadBack(
            supported: supported,
            unconfirmed: unconfirmed,
            requestID: requestID,
            appliedOutboundTag: tag,
            appliedRevision: revision,
            stale: stale
        )
    }

    func testTheReadBackAppliesWhatTheGroupHoldsNotWhatWasRequested() {
        var ledger = SelectionLedger()
        let request = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        // A hard switch: the caller asked for b, the group holds c.
        let settlement = ledger.settle(readBack(requestID: request.requestID, tag: "member-c"), for: request)
        XCTAssertEqual(settlement, .applied(outboundTag: "member-c", revision: 7, stale: false))
        XCTAssertNil(ledger.pendingSelection(for: "group-a"))
        XCTAssertEqual(ledger.appliedRevision(for: "group-a"), 7)
    }

    func testAnAnswerForAReplacedAttemptCannotSettleTheNewerOne() {
        var ledger = SelectionLedger()
        let first = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        let second = ledger.begin(groupTag: "group-a", outboundTag: "member-c")

        let late = ledger.settle(readBack(requestID: first.requestID, tag: "member-b"), for: first)
        XCTAssertEqual(late, .ignoredOlderRequest(latestRequestID: second.requestID))
        XCTAssertEqual(ledger.pendingSelection(for: "group-a")?.outboundTag, "member-c",
                       "the late answer did not replace the newer attempt")

        let current = ledger.settle(readBack(requestID: second.requestID, tag: "member-c", revision: 9), for: second)
        XCTAssertEqual(current, .applied(outboundTag: "member-c", revision: 9, stale: false))
    }

    func testAnOlderRevisionCannotOverwriteANewerAppliedOne() {
        var ledger = SelectionLedger()
        let first = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        XCTAssertEqual(ledger.settle(readBack(requestID: first.requestID, revision: 9), for: first),
                       .applied(outboundTag: "member-b", revision: 9, stale: false))

        let second = ledger.begin(groupTag: "group-a", outboundTag: "member-c")
        XCTAssertEqual(second.expectedRevision, 9, "the next attempt carries the revision last applied")
        let settlement = ledger.settle(readBack(requestID: second.requestID, revision: 8), for: second)
        XCTAssertEqual(settlement, .ignoredOlderRevision(latestRevision: 9))
        XCTAssertEqual(ledger.appliedRevision(for: "group-a"), 9)
    }

    func testAFailureForAReplacedAttemptDoesNotClearTheNewerOne() {
        var ledger = SelectionLedger()
        let first = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        let second = ledger.begin(groupTag: "group-a", outboundTag: "member-c")

        XCTAssertEqual(ledger.fail(first, reason: "connection reset"),
                       .ignoredOlderRequest(latestRequestID: second.requestID))
        XCTAssertEqual(ledger.pendingSelection(for: "group-a")?.requestID, second.requestID)
    }

    func testAFailedAttemptStopsPinningTheRow() {
        var ledger = SelectionLedger()
        let request = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        XCTAssertEqual(ledger.fail(request, reason: "timeout"), .failed(reason: "timeout"))
        XCTAssertNil(ledger.pendingSelection(for: "group-a"),
                     "a failure must clear the overlay, or the next snapshot is overwritten forever")
    }

    func testADaemonWithoutIdentityIsUnconfirmedRatherThanASuccess() {
        var ledger = SelectionLedger()
        let request = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        let settlement = ledger.settle(
            readBack(requestID: request.requestID, tag: nil, supported: false, unconfirmed: true),
            for: request
        )
        guard case let .unconfirmed(reason) = settlement else {
            return XCTFail("expected unconfirmed, got \(settlement)")
        }
        XCTAssertTrue(reason.contains("cannot confirm"))
        XCTAssertNil(ledger.pendingSelection(for: "group-a"))
        XCTAssertEqual(ledger.appliedRevision(for: "group-a"), 0, "no revision was invented")
    }

    func testAStreamSnapshotCanConfirmTheAttempt() {
        var ledger = SelectionLedger()
        let request = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        XCTAssertTrue(ledger.confirmFromStream(groupTag: "group-a", selectedTag: "member-b"))
        XCTAssertNil(ledger.pendingSelection(for: "group-a"))
        XCTAssertFalse(ledger.confirmFromStream(groupTag: "group-a", selectedTag: "member-b"))
        // The read-back arriving afterwards belongs to an attempt that is no longer pending.
        XCTAssertEqual(ledger.settle(readBack(requestID: request.requestID), for: request),
                       .ignoredOlderRequest(latestRequestID: request.requestID))
    }

    func testAStreamSnapshotForAnotherMemberDoesNotConfirmTheAttempt() {
        var ledger = SelectionLedger()
        _ = ledger.begin(groupTag: "group-a", outboundTag: "member-b")
        XCTAssertFalse(ledger.confirmFromStream(groupTag: "group-a", selectedTag: "member-c"))
        XCTAssertNotNil(ledger.pendingSelection(for: "group-a"))
    }

    func testTheWireDocumentDecodesTheIdentityTheKernelSends() throws {
        let document = #"{"supported":true,"requestId":41,"appliedOutboundTag":"member-b","appliedRevision":141,"stale":true}"#
        let readBack = try XCTUnwrap(SelectionReadBack.decode(document))
        XCTAssertTrue(readBack.supported)
        XCTAssertFalse(readBack.unconfirmed)
        XCTAssertEqual(readBack.requestID, 41)
        XCTAssertEqual(readBack.appliedOutboundTag, "member-b")
        XCTAssertEqual(readBack.appliedRevision, 141)
        XCTAssertTrue(readBack.stale)
    }

    func testTheOldDaemonDocumentDecodesAsUnconfirmed() throws {
        let document = #"{"supported":false,"unconfirmed":true,"requestId":9}"#
        let readBack = try XCTUnwrap(SelectionReadBack.decode(document))
        XCTAssertFalse(readBack.supported)
        XCTAssertTrue(readBack.unconfirmed)
        XCTAssertEqual(readBack.requestID, 9)
        XCTAssertNil(readBack.appliedOutboundTag)
    }

    func testADocumentThisBuildCannotReadIsNotGuessedAsSuccess() {
        XCTAssertNil(SelectionReadBack.decode("not json"))
        XCTAssertNil(SelectionReadBack.decode(""))
    }
}
