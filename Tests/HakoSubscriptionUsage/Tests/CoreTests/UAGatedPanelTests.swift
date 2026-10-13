import Core
import Foundation
import XCTest

/// End to end over real HTTP, against the mock panel in `scripts/dev/ua_gated_panel.py`.
///
/// Opt-in, because it needs a listening socket and the ordinary unit run must stay offline. Start
/// the mock panel first, then point the variable at it:
///
///     python scripts/dev/ua_gated_panel.py 8791 &
///     HAKO_UA_PROBE_URL=http://127.0.0.1:8791/sub swift test --filter UAGatedPanelTests
///
/// Skipped when the variable is unset, so a normal `swift test` is unaffected.
///
/// These are the cases that exercise the real `URLSession` request, the real header read and a real
/// server, because the claims cannot be established by inspecting strings: "the identity that
/// fetches the body is denied the header the probe is granted" is a claim about what a panel does,
/// and "the probe does not download the body" is a claim about what the server was asked to send.
///
/// The server's own accounting is read back through `fetch`, so no `URLSession` is used directly
/// here and the file needs no platform-conditional import.
final class UAGatedPanelTests: XCTestCase {
    private func baseURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment["HAKO_UA_PROBE_URL"], !url.isEmpty else {
            throw XCTSkip("set HAKO_UA_PROBE_URL to run the UA-gated panel tests")
        }
        return url
    }

    /// The mock's own record of what it served.
    private struct Served: Decodable {
        struct Request: Decodable {
            let path: String
            let userAgent: String
            let cacheControl: String

            private enum CodingKeys: String, CodingKey {
                case path
                case userAgent = "user_agent"
                case cacheControl = "cache_control"
            }
        }

        struct Big: Decodable {
            let contentLength: Int
            let bytesSent: Int
            let completed: Bool

            private enum CodingKeys: String, CodingKey {
                case contentLength = "content_length"
                case bytesSent = "bytes_sent"
                case completed
            }
        }

        let requests: [Request]
        let big: Big
    }

    private func served() async throws -> Served {
        let base = try baseURL()
        let seen = base.replacingOccurrences(of: "/sub", with: "/seen")
        let response = try await RemoteProfileFetcher.fetch(seen)
        return try JSONDecoder().decode(Served.self, from: Data(response.content.utf8))
    }

    /// Case 9: the whole asymmetry, in one test - same URL, same instant, two identities, two
    /// different answers from the panel.
    func testProbeIsGrantedTheHeaderTheBodyIdentityIsDenied() async throws {
        let url = try baseURL()

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

    /// The probe must not be satisfied from a shared cache. The mock sends
    /// `Cache-Control: max-age=3600` precisely so a cached response would be reused if anything
    /// allowed it, so a repeated probe that still captures the quota is evidence rather than luck.
    func testRepeatedProbesKeepCapturingDespiteACacheablePanelResponse() async throws {
        let url = try baseURL()

        for attempt in 1 ... 3 {
            let capture = try await RemoteProfileFetcher.captureMetadata(url)
            XCTAssertTrue(
                capture.didCapture,
                "probe \(attempt) was denied the quota; a cacheable response served from the HTTP "
                    + "cache would show up exactly like this"
            )
        }
    }

    // MARK: - Case 13: the probe stops the body

    /// The probe reads one header and must not transfer the subscription a second time.
    ///
    /// This is the round's central assertion, and it is made against the *server's* byte count, not
    /// against anything the client believes it did: `/big` advertises 8 MiB, streams it in 64 KiB
    /// chunks with a pause between them, and records how much it actually managed to write. A probe
    /// that cancels once the headers arrive leaves that far below the advertised length. A probe
    /// built on `URLSession.data(for:)` would pull the whole 8 MiB and report it as complete.
    func testProbeCapturesTheHeaderWithoutDownloadingTheBody() async throws {
        let base = try baseURL()
        let big = base.replacingOccurrences(of: "/sub", with: "/big")

        let capture = try await RemoteProfileFetcher.captureMetadata(big)
        XCTAssertTrue(
            capture.didCapture,
            "the large endpoint gates on the same marker, so the probe must still capture: \(capture)"
        )

        // Read the server's accounting *after* the probe has returned.
        let record = try await served()
        XCTAssertEqual(record.big.contentLength, 8 * 1024 * 1024)
        XCTAssertFalse(
            record.big.completed,
            "the server finished sending the whole body, so the probe transferred all of it"
        )
        XCTAssertLessThan(
            record.big.bytesSent,
            record.big.contentLength / 4,
            "the probe was asked for 8 MiB and the server sent \(record.big.bytesSent) bytes; "
                + "a probe that only wants the headers must leave that far lower"
        )
    }

    /// The body request is the opposite case and must keep reading the whole configuration: only
    /// the metadata probe is header-only.
    func testTheBodyRequestStillReadsTheWholeConfiguration() async throws {
        let base = try baseURL()
        let big = base.replacingOccurrences(of: "/sub", with: "/big")

        // The body endpoint advertises 8 MiB of `x`, which is what `fetch` must read.
        let response = try await RemoteProfileFetcher.fetch(big)
        XCTAssertGreaterThan(
            response.content.count,
            4 * 1024 * 1024,
            "the body request must receive the whole configuration, not just its headers"
        )
    }

    // MARK: - Case 14: the request the probe actually sends

    /// The probe asks intermediaries to revalidate, and does it with a standard request header.
    ///
    /// A cache-busting query parameter is deliberately *not* used: a subscription URL may carry an
    /// authentication signature, and rewriting it would break the request. This asserts the header
    /// on the wire rather than the constant, which is why it lives here with a server to observe it.
    func testProbeRequestAsksIntermediariesToRevalidate() async throws {
        let url = try baseURL()
        _ = try await RemoteProfileFetcher.captureMetadata(url)

        let record = try await served()
        let probe = try XCTUnwrap(
            record.requests.last { $0.path.hasSuffix("/sub") },
            "the probe's request was not recorded by the server"
        )
        XCTAssertEqual(
            probe.cacheControl.lowercased(),
            "no-cache",
            "the probe must ask a shared cache to revalidate; a quota served from a cache is the "
                + "stale value this change exists to stop presenting as fresh"
        )
        XCTAssertTrue(
            probe.userAgent.lowercased().contains("clash"),
            "the probe must carry the Clash-compatible marker: \(probe.userAgent)"
        )
        XCTAssertTrue(
            probe.path.hasSuffix("/sub"),
            "the probe must not rewrite the subscription URL: \(probe.path)"
        )
    }
}
