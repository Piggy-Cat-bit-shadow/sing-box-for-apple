import XCTest

@testable import Contract

/// The receiving side's half of the identity check.
///
/// The app compares "is this still the selected profile" immediately before the send; the extension
/// asks the same question again when the message arrives, because a switch can land in the gap. The
/// rule is pure so both halves can be described precisely, and so the refusal reasons are testable.
final class ApplyRequestAdmissionTests: XCTestCase {
    func testARequestForTheSelectedProfileIsAdmitted() {
        XCTAssertEqual(
            ApplyRequestAdmission.decision(requestProfileID: 7, selectedProfileID: 7),
            .admit
        )
    }

    func testARequestForAnotherProfileIsRefusedWithTheReason() {
        XCTAssertEqual(
            ApplyRequestAdmission.decision(requestProfileID: 7, selectedProfileID: 9),
            .refuse(reason: "the selection moved to profile 9 before this request was received")
        )
    }

    func testARequestWithNothingSelectedIsRefused() {
        XCTAssertEqual(
            ApplyRequestAdmission.decision(requestProfileID: 7, selectedProfileID: nil),
            .refuse(reason: "no profile is selected")
        )
    }

    /// A caller that sends no profile id keeps the old behaviour: refusing it would be a protocol
    /// change disguised as a safety check, and nothing in this app produces such a request.
    func testARequestWithoutAProfileIDIsAdmitted() {
        XCTAssertEqual(ApplyRequestAdmission.decision(requestProfileID: nil, selectedProfileID: 9), .admit)
        XCTAssertEqual(ApplyRequestAdmission.decision(requestProfileID: nil, selectedProfileID: nil), .admit)
    }
}
