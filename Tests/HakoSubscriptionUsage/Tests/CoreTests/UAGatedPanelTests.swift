import Core
import Foundation
import XCTest

/// Case 9, end to end over real HTTP: a panel that gates `subscription-userinfo` on the User-Agent.
///
/// Opt-in, because it needs a listening socket and the ordinary unit run must stay offline. Start
/// the mock panel first, then point the variable at it:
///
///     python ua_gated_panel.py 8791 &
///     HAKO_UA_PROBE_URL=http://127.0.0.1:8791/sub swift test --filter UAGatedPanelTests
///
/// Skipped when the variable is unset, so a normal `swift test` is unaffected.
///
/// This is the only case that exercises the real `URLSession` request, the real header read and a
/// real gating rule together. It exists because the claim under test - "the identity that fetches
/// the body is denied the header the probe is granted" - cannot be established by inspecting the
/// User-Agent strings alone: it is a claim about what a panel does with them.
final class UAGatedPanelTests: XCTestCase {
    private func probeURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment["HAKO_UA_PROBE_URL"], !url.isEmpty else {
            throw XCTSkip("set HAKO_UA_PROBE_URL to run the UA-gated panel A/B")
        }
        return url
    }

    /// The whole asymmetry, in one test: same URL, same instant, two identities, two different
    /// answers from the panel.
    func testProbeIsGrantedTheHeaderTheBodyIdentityIsDenied() async throws {
        let url = try probeURL()

        // The body request, under the client's own identity: denied the quota, granted the body.
        let bodyResponse = try await RemoteProfileFetcher.fetch(url)
        XCTAssertNil(
            bodyResponse.subscriptionUserInfo,
            "the panel sent a quota to the body identity; the mock gates on a Clash marker, so this "
                + "means the identity carries one and the body request is no longer format-safe"
        )
        XCTAssertTrue(
            bodyResponse.content.contains("outbounds"),
            "the body request must still receive the configuration"
        )

        // The metadata probe, under the Clash-compatible identity: granted the quota.
        let capture = try await RemoteProfileFetcher.captureMetadata(url)
        XCTAssertTrue(
            capture.didCapture,
            "the Clash-compatible probe was denied the quota the panel is supposed to gate on: \(capture)"
        )
        XCTAssertEqual(
            capture.info,
            SubscriptionInfo(upload: 161_061_273_600, download: 0, total: 429_496_729_600, expire: 5)
        )
    }

    /// Both requests must reach the same URL under two identities, and the probe must not be
    /// satisfied from the HTTP cache. The mock sends `Cache-Control: max-age=3600` precisely so a
    /// cached response would be reused if the policy allowed it, and it counts the requests it
    /// actually served - so repeating a probe that still captures the quota is evidence the policy
    /// bypassed the cache rather than evidence the panel cooperated.
    func testRepeatedProbesKeepCapturingDespiteACacheablePanelResponse() async throws {
        let url = try probeURL()

        for attempt in 1 ... 3 {
            let capture = try await RemoteProfileFetcher.captureMetadata(url)
            XCTAssertTrue(
                capture.didCapture,
                "probe \(attempt) was denied the quota; a cacheable response served from the HTTP "
                    + "cache would show up exactly like this"
            )
        }
    }
}
