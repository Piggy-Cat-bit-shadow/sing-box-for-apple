import XCTest

@testable import Contract

/// The apply receipt: what the extension's answer proves, and what it does not.
final class ExtensionApplyReceiptTests: XCTestCase {
    private func message(
        requestID: String = "req-1",
        status: String = "restarted",
        ok: Bool? = true
    ) -> ExtensionApplyReceiptMessage {
        ExtensionApplyReceiptMessage(
            requestID: requestID,
            sessionID: "session-1",
            profileID: 7,
            bodyRevision: "rev-1",
            ok: ok,
            status: status,
            targetRevision: "target-1",
            activeRevision: "active-1",
            retained: false,
            restartRequired: true,
            persistence: "saved",
            reason: nil
        )
    }

    func testAnEmptyAnswerIsNotAFailure() {
        XCTAssertEqual(ExtensionApplyReceiptParser.parse(nil, expecting: "req-1"), .noReceipt)
        XCTAssertEqual(ExtensionApplyReceiptParser.parse(Data(), expecting: "req-1"), .noReceipt)
    }

    func testAnAppliedReceiptIsReadAsApplied() throws {
        let data = try JSONEncoder().encode(message())
        guard case let .receipt(receipt) = ExtensionApplyReceiptParser.parse(data, expecting: "req-1") else {
            return XCTFail("a well-formed receipt must decode")
        }
        XCTAssertEqual(receipt.requestID, "req-1")
        XCTAssertEqual(receipt.tunnelSessionID, "session-1")
        XCTAssertEqual(receipt.profileID, 7)
        XCTAssertEqual(receipt.bodyRevision, "rev-1")
        XCTAssertEqual(receipt.targetRevision, "target-1")
        XCTAssertEqual(receipt.restartRequired, true)
        XCTAssertEqual(receipt.persistence, "saved")
        XCTAssertEqual(receipt.outcome, .applied(.restarted, activeRevision: "active-1"))
        XCTAssertTrue(receipt.outcome.didApplyRequest)
    }

    /// The statuses that mean "the service is up but the requested document is not what runs" must
    /// never read as a successful apply: a recovery returns no error from the daemon.
    func testARecoveryIsNotAnAppliedRequest() {
        for status in ["recovered", "interrupted", "failed"] {
            let classified = ExtensionApplyReceiptParser.classify(message(status: status, ok: false), expecting: "req-1")
            guard case let .receipt(receipt) = classified else {
                return XCTFail("status \(status) must still decode")
            }
            XCTAssertFalse(receipt.outcome.didApplyRequest, "status \(status) must not read as applied")
        }
    }

    func testARecoveryNamesTheRevisionThatRuns() {
        let classified = ExtensionApplyReceiptParser.classify(message(status: "recovered", ok: false), expecting: "req-1")
        guard case let .receipt(receipt) = classified else {
            return XCTFail("a recovery must decode")
        }
        XCTAssertEqual(receipt.outcome, .recovered(activeRevision: "active-1"))
    }

    func testAnInterruptedApplyIsNotAFailedApply() {
        let classified = ExtensionApplyReceiptParser.classify(message(status: "interrupted", ok: false), expecting: "req-1")
        guard case let .receipt(receipt) = classified else {
            return XCTFail("an interruption must decode")
        }
        XCTAssertEqual(receipt.outcome, .interrupted)
    }

    func testAFailedApplyKeepsWhetherThePreviousDocumentStillRuns() {
        var failed = message(status: "failed", ok: false)
        failed.reason = "provider refused"
        failed.retained = true
        let classified = ExtensionApplyReceiptParser.classify(failed, expecting: "req-1")
        guard case let .receipt(receipt) = classified else {
            return XCTFail("a failure must decode")
        }
        XCTAssertEqual(receipt.outcome, .failed(reason: "provider refused", retained: true))
    }

    func testAReplyForAnotherRequestIsNotThisUpdatesAnswer() {
        let data = try? JSONEncoder().encode(message(requestID: "req-2"))
        guard let data, case let .otherRequest(expected, received) = ExtensionApplyReceiptParser.parse(data, expecting: "req-1") else {
            return XCTFail("a reply for another request must be recognised")
        }
        XCTAssertEqual(expected, "req-1")
        XCTAssertEqual(received, "req-2")
    }

    func testAMessageWithoutASessionCannotBeAttributed() {
        var anonymous = message()
        anonymous.sessionID = nil
        let classified = ExtensionApplyReceiptParser.classify(anonymous, expecting: "req-1")
        guard case let .unreadable(reason) = classified else {
            return XCTFail("a receipt without a session id cannot be attributed to a tunnel")
        }
        XCTAssertTrue(reason.contains("session"), reason)
    }

    func testAFutureEnvelopeVersionIsNotGuessed() {
        var future = message()
        future.version = ExtensionApplyReceipt.version + 1
        let classified = ExtensionApplyReceiptParser.classify(future, expecting: "req-1")
        guard case let .unreadable(reason) = classified else {
            return XCTFail("a newer envelope must not be read with this build's rules")
        }
        XCTAssertTrue(reason.contains("version"), reason)
    }

    func testAnUnknownFieldIsIgnored() throws {
        let json = """
        {"version":1,"requestID":"req-1","sessionID":"session-1","status":"applied_live",
         "activeRevision":"active-1","somethingNew":"ignored"}
        """
        guard case let .receipt(receipt) = ExtensionApplyReceiptParser.parse(Data(json.utf8), expecting: "req-1") else {
            return XCTFail("an added field must not break the decoder")
        }
        XCTAssertEqual(receipt.outcome, .applied(.appliedLive, activeRevision: "active-1"))
    }

    func testGarbageIsUnreadableRatherThanUnconfirmed() {
        guard case .unreadable = ExtensionApplyReceiptParser.parse(Data("not json".utf8), expecting: "req-1") else {
            return XCTFail("a reply this build cannot parse is unreadable, not a silent success")
        }
    }

    func testAnEnvelopeWithoutAStatusIsUndetermined() {
        var statusless = message()
        statusless.status = nil
        statusless.ok = nil
        let classified = ExtensionApplyReceiptParser.classify(statusless, expecting: "req-1")
        guard case let .receipt(receipt) = classified else {
            return XCTFail("the envelope still decodes")
        }
        guard case .undetermined = receipt.outcome else {
            return XCTFail("no status is not a decision")
        }
        XCTAssertFalse(receipt.outcome.didApplyRequest)
    }
}
