import Core
import Foundation
import XCTest

/// The header-capture vocabulary, and the request facts the subscription path depends on.
///
/// These cases are about *classification* and *request shape* rather than about the merge, which
/// `RemoteRefreshPolicyTests` and `SubscriptionQuotaFreshnessTests` cover. They exist because the
/// previous code collapsed "the panel sent nothing" and "the panel sent something unreadable" into
/// one `nil`, and because the User-Agent and cache policy are the two request properties that
/// decide whether a panel sends the header at all.
final class SubscriptionCaptureTests: XCTestCase {
    // MARK: - Case 3, at the classification level

    func testAbsentAndBlankHeadersAreMissingRatherThanMalformed() {
        for header in [nil, "", "   ", "\n"] as [String?] {
            XCTAssertEqual(
                SubscriptionInfo.capture(header: header), .missing,
                "header \(header.map { "\"\($0)\"" } ?? "nil") should be 'said nothing'"
            )
        }
    }

    func testPresentButUnreadableHeaderIsMalformed() {
        for header in ["garbage", ";;;", "upload=abc", "=1", "upload"] {
            XCTAssertEqual(
                SubscriptionInfo.capture(header: header), .malformed,
                "header \"\(header)\" should be 'said something unreadable'"
            )
        }
    }

    func testReadableHeaderIsAUdateAndCarriesTheQuota() {
        let capture = SubscriptionInfo.capture(header: "upload=1; download=2; total=3; expire=4")
        XCTAssertEqual(capture, .updated(SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)))
        XCTAssertEqual(capture.info, SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4))
        XCTAssertTrue(capture.didCapture)
    }

    func testOnlyTheUpdatedCaseCountsAsACapture() {
        XCTAssertTrue(SubscriptionInfoCapture.updated(
            SubscriptionInfo(upload: 1, download: 1, total: 1, expire: 1)
        ).didCapture)
        XCTAssertFalse(SubscriptionInfoCapture.missing.didCapture)
        XCTAssertFalse(SubscriptionInfoCapture.malformed.didCapture)
        XCTAssertNil(SubscriptionInfoCapture.missing.info)
        XCTAssertNil(SubscriptionInfoCapture.malformed.info)
    }

    // MARK: - Case 9, premise: the client carries a Clash-compatible marker on the probe only

    func testSubscriptionMetadataUserAgentCarriesAClashCompatibleMarker() {
        let identity = HTTPClient.userAgent
        let probeAgent = HTTPClient.subscriptionMetadataUserAgent

        XCTAssertTrue(
            probeAgent.contains(HTTPClient.clashCompatibleMarker),
            "the probe must advertise a marker panels recognise"
        )
        XCTAssertTrue(
            probeAgent.lowercased().contains("clash"),
            "the marker must actually name a Clash-family client; \"\(probeAgent)\" does not"
        )
        XCTAssertTrue(
            probeAgent.hasPrefix(identity),
            "the probe must keep the client's own identity, not replace it"
        )
        XCTAssertNotEqual(
            probeAgent, identity,
            "the whole point is that the probe differs from the body request"
        )
    }

    /// The body request must keep the identity that keeps the subscription *format* correct.
    /// Sending a Clash marker there risks receiving Clash YAML where sing-box JSON is required.
    func testTheIdentityUsedForTheBodyIsUnchangedAndCarriesNoClashMarker() {
        XCTAssertFalse(
            HTTPClient.userAgent.lowercased().contains("clash"),
            "the body request's identity must not claim to be a Clash client"
        )
    }

    // MARK: - Case 8: the cache policy is explicit, and asserted rather than eyeballed

    func testSubscriptionRequestsExplicitlyBypassTheHTTPCache() {
        XCTAssertEqual(RemoteProfileFetcher.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNotEqual(
            RemoteProfileFetcher.cachePolicy, .useProtocolCachePolicy,
            "the default policy would let a panel's Cache-Control hand back the old quota"
        )
    }

    // MARK: - Case 12, premise: the probe's failure mode is a thrown error the caller swallows

    func testCaptureMetadataThrowsRatherThanProducingACaptureWhenItCannotProceed() async {
        do {
            let capture = try await RemoteProfileFetcher.captureMetadata("not a url")
            XCTFail("an unusable URL produced a capture instead of throwing: \(capture)")
        } catch {
            // Any error is acceptable here, and the assertion is deliberately not on its type:
            // the contract the refresh relies on is only that a failed probe *throws* rather than
            // returning a capture, because `evaluate` swallows the throw and retains the stored
            // metadata. Which layer rejects the URL depends on the platform - `URL(string:)` is
            // permissive enough to accept some malformed strings and let URLSession fail instead.
        }
    }
}
