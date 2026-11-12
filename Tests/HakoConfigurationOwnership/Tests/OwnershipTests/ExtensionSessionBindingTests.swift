import XCTest

@testable import Contract

/// Which tunnel session a request and a receipt belong to.
///
/// The extension checks a request before applying it; the app checks a receipt before it settles a
/// pending update. Both must degrade, never silently accept, when one side is older and does not
/// send the identity.
final class ExtensionSessionBindingTests: XCTestCase {
    func testARequestWithoutADeclaredSessionIsAdmitted() {
        XCTAssertEqual(ExtensionSessionBinding.admission(expectedSessionID: nil, currentSessionID: "session-b"), .admit)
        XCTAssertEqual(ExtensionSessionBinding.admission(expectedSessionID: "", currentSessionID: "session-b"), .admit)
    }

    func testARequestForTheCurrentSessionIsAdmitted() {
        XCTAssertEqual(ExtensionSessionBinding.admission(expectedSessionID: "session-b", currentSessionID: "session-b"), .admit)
    }

    func testARequestForAStoppedSessionIsRefused() {
        let decision = ExtensionSessionBinding.admission(expectedSessionID: "session-a", currentSessionID: "session-b")
        guard case let .refuse(reason) = decision else {
            return XCTFail("expected refusal, got \(decision)")
        }
        XCTAssertTrue(reason.contains("session-a"))
        XCTAssertTrue(reason.contains("session-b"))
    }

    func testAReceiptWithoutAnExpectationKeepsTheOldBehaviour() {
        XCTAssertEqual(ExtensionSessionBinding.receiptMatches(expectedSessionID: nil, receiptSessionID: "session-a"), .admit)
    }

    func testAReceiptFromAnotherSessionIsRefused() {
        let decision = ExtensionSessionBinding.receiptMatches(expectedSessionID: "session-b", receiptSessionID: "session-a")
        guard case let .refuse(reason) = decision else {
            return XCTFail("expected refusal, got \(decision)")
        }
        XCTAssertTrue(reason.contains("session-a"))
        XCTAssertTrue(reason.contains("session-b"))
    }

    func testTheIdentityMessageRoundTrips() throws {
        let request = try XCTUnwrap(TunnelSessionIdentityMessage.Request().encode())
        let decoded = try JSONSerialization.jsonObject(with: request) as? [String: String]
        XCTAssertEqual(decoded?[TunnelSessionIdentityMessage.operationKey], TunnelSessionIdentityMessage.operationValue)

        let response = try JSONEncoder().encode(TunnelSessionIdentityMessage.Response(sessionID: "session-b"))
        XCTAssertEqual(TunnelSessionIdentityMessage.Response.decode(response), "session-b")
    }

    func testAnUnreadableIdentityAnswerIsNilNotAGuess() {
        XCTAssertNil(TunnelSessionIdentityMessage.Response.decode(Data("not json".utf8)))
        XCTAssertNil(TunnelSessionIdentityMessage.Response.decode(Data(#"{"sessionID":""}"#.utf8)))
        XCTAssertNil(TunnelSessionIdentityMessage.Response.decode(nil))
    }

    func testTheParserRejectsAReceiptFromAnotherSession() {
        let message = ExtensionApplyReceiptMessage(
            requestID: "request-1",
            sessionID: "session-a",
            profileID: 7,
            bodyRevision: "rev-1",
            ok: true,
            status: "restarted"
        )
        let result = ExtensionApplyReceiptParser.classify(message, expecting: "request-1", expectingSessionID: "session-b")
        guard case let .otherSession(expected, received) = result else {
            return XCTFail("expected otherSession, got \(result)")
        }
        XCTAssertEqual(expected, "session-b")
        XCTAssertEqual(received, "session-a")
    }

    func testTheParserAcceptsAReceiptFromTheExpectedSession() {
        let message = ExtensionApplyReceiptMessage(
            requestID: "request-1",
            sessionID: "session-b",
            profileID: 7,
            bodyRevision: "rev-1",
            instanceID: "instance-2",
            ok: true,
            status: "restarted"
        )
        let result = ExtensionApplyReceiptParser.classify(message, expecting: "request-1", expectingSessionID: "session-b")
        guard case let .receipt(receipt) = result else {
            return XCTFail("expected receipt, got \(result)")
        }
        XCTAssertEqual(receipt.tunnelSessionID, "session-b")
        XCTAssertEqual(receipt.instanceID, "instance-2", "the kernel instance travels with the receipt")
    }

    func testTheParserKeepsWorkingForACallerThatDoesNotTrackSessions() {
        let message = ExtensionApplyReceiptMessage(
            requestID: "request-1",
            sessionID: "session-a",
            profileID: 7,
            bodyRevision: "rev-1",
            ok: true,
            status: "restarted"
        )
        let result = ExtensionApplyReceiptParser.classify(message, expecting: "request-1")
        guard case .receipt = result else {
            return XCTFail("expected receipt, got \(result)")
        }
    }
}
