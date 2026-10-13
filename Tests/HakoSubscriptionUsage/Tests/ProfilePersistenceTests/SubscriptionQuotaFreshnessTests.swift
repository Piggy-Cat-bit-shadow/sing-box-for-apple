import Core
import Foundation
import GRDB
import ProfileUnderTest
import XCTest

/// The quota-freshness contract, exercised through the shipping `Profile.refreshRemoteProfile()`.
///
/// The one sentence these cases exist to hold true:
///
/// > The quota's freshness advances only when this refresh actually captured a quota.
/// > The configuration body refreshing successfully is a different fact.
///
/// Every case below is a variation on that sentence. The panel's YAML is deliberately identical
/// across them, because a real panel's YAML stays byte-identical for days while its usage counter
/// moves on every request.
final class SubscriptionQuotaFreshnessTests: XCTestCase {
    private var directory: URL!

    private let yaml = "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}]}"
    private let quotaA = SubscriptionInfo(upload: 100, download: 0, total: 400 * 1_073_741_824, expire: 5)
    private let quotaB = SubscriptionInfo(upload: 161_061_273_600, download: 0, total: 429_496_729_600, expire: 5)

    /// A capture time in the past, distinguishable from "now" by a wide margin.
    private let t1 = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hako-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("configs"),
            withIntermediateDirectories: true
        )
        FilePath.sharedDirectory = directory
        try yaml.write(
            to: directory.appendingPathComponent("configs/config_1.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeRemoteProfile(
        subscriptionInfo: SubscriptionInfo?,
        capturedAt: Date?
    ) -> Profile {
        // No `lastUpdated` is passed: the initializer would default it, so it is set explicitly
        // below to a known past instant.
        Profile(
            id: 1,
            name: "airport",
            type: .remote,
            path: "configs/config_1.json",
            remoteURL: "https://panel.example.invalid/sub",
            lastUpdated: t1,
            subscriptionInfo: subscriptionInfo,
            subscriptionInfoUpdatedAt: capturedAt
        )
    }

    // MARK: - Case 1: a response that does carry a quota

    func testCapturedQuotaAdvancesBothTheValueAndItsFreshness() async throws {
        let profile = makeRemoteProfile(subscriptionInfo: quotaA, capturedAt: t1)

        try await profile.refreshRemoteProfile(
            fetch: { _ in
                RemoteProfileResponse(
                    content: self.yaml,
                    subscriptionUserInfo: "upload=161061273600; download=0; total=429496729600; expire=5"
                )
            },
            validate: { _ in },
            persist: { _ in }
        )

        XCTAssertEqual(profile.subscriptionInfo, quotaB, "a captured quota must replace the stored one")
        let capturedAt = try XCTUnwrap(profile.subscriptionInfoUpdatedAt)
        let lastUpdated = try XCTUnwrap(profile.lastUpdated)
        XCTAssertGreaterThan(capturedAt, t1, "a capture must move the quota's freshness")
        // One instant per refresh: the two facts agree about when "now" was, while meaning
        // different things.
        XCTAssertEqual(capturedAt, lastUpdated)
    }

    // MARK: - Case 2: the body refreshed, the panel sent no quota  (the headline regression)

    func testMissingHeaderKeepsTheStoredQuotaAndItsFreshnessWhileTheBodyRefreshes() async throws {
        let profile = makeRemoteProfile(subscriptionInfo: quotaA, capturedAt: t1)

        try await profile.refreshRemoteProfile(
            fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: nil) },
            validate: { _ in },
            persist: { _ in }
        )

        XCTAssertEqual(profile.subscriptionInfo, quotaA, "last-known-good must survive an absent header")
        XCTAssertEqual(
            profile.subscriptionInfoUpdatedAt, t1,
            "the quota was not captured this round, so its freshness must not move"
        )
        let lastUpdated = try XCTUnwrap(profile.lastUpdated)
        XCTAssertGreaterThan(
            lastUpdated, t1,
            "the configuration did refresh successfully, and lastUpdated still says so"
        )
        XCTAssertNotEqual(
            lastUpdated, profile.subscriptionInfoUpdatedAt,
            "the whole defect was these two being the same value"
        )
    }

    // MARK: - Case 3: the header is present but unreadable

    func testMalformedHeaderKeepsTheStoredQuotaAndItsFreshness() async throws {
        for malformed in ["garbage", ";;;", "upload=abc", "   "] {
            let profile = makeRemoteProfile(subscriptionInfo: quotaA, capturedAt: t1)

            try await profile.refreshRemoteProfile(
                fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: malformed) },
                validate: { _ in },
                persist: { _ in }
            )

            XCTAssertEqual(profile.subscriptionInfo, quotaA, "malformed \"\(malformed)\" lost the quota")
            XCTAssertEqual(
                profile.subscriptionInfoUpdatedAt, t1,
                "a malformed header is not a capture, so freshness must not move"
            )
        }
    }

    // MARK: - Case 4: nothing stored, nothing captured

    func testFirstRefreshWithNoHeaderLeavesBothFactsUnknown() async throws {
        let profile = makeRemoteProfile(subscriptionInfo: nil, capturedAt: nil)

        try await profile.refreshRemoteProfile(
            fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: nil) },
            validate: { _ in },
            persist: { _ in }
        )

        XCTAssertNil(profile.subscriptionInfo)
        XCTAssertNil(
            profile.subscriptionInfoUpdatedAt,
            "an unknown capture time must stay unknown rather than being filled with now"
        )
        let lastUpdated = try XCTUnwrap(profile.lastUpdated)
        XCTAssertGreaterThan(lastUpdated, t1, "the body did refresh")
    }

    // MARK: - Case 5: a profile stored before this field existed

    func testLegacyRowDecodesWithQuotaAndUnknownCaptureTime() throws {
        // Exactly the shape `add_subscription_info` left: four quota columns, and no
        // `subscriptionInfoUpdatedAt` column at all.
        let legacy = Row(columns: [
            "id": .integer(1),
            "name": .text("airport"),
            "order": .integer(0),
            "type": .integer(Int64(ProfileUnderTest.ProfileType.remote.rawValue)),
            "path": .text("configs/config_1.json"),
            "remoteURL": .text("https://panel.example.invalid/sub"),
            "autoUpdate": .integer(1),
            "autoUpdateInterval": .integer(60),
            "lastUpdated": .real(t1.timeIntervalSince1970),
            "subscriptionUpload": .integer(quotaA.upload),
            "subscriptionDownload": .integer(quotaA.download),
            "subscriptionTotal": .integer(quotaA.total),
            "subscriptionExpire": .integer(quotaA.expire),
        ])

        let profile = try profileFromRow(legacy)

        XCTAssertEqual(profile.subscriptionInfo, quotaA, "the four quota columns must still decode")
        XCTAssertNil(
            profile.subscriptionInfoUpdatedAt,
            "an older row does not know when its quota was captured, and must not be given a time"
        )
    }

    /// The reverse direction: a capture time that is known must survive the round trip, so the
    /// UI's age claim is not lost on the next launch.
    func testCaptureTimeSurvivesEncodingAndDecoding() throws {
        let profile = makeRemoteProfile(subscriptionInfo: quotaB, capturedAt: t1)
        let columns = try profileEncodedColumns(profile)

        XCTAssertEqual(
            columns["subscriptionInfoUpdatedAt"], .real(t1.timeIntervalSince1970),
            "the capture time must be encoded under the column the migration adds"
        )

        let restored = try profileFromRow(Row(columns: columns))
        XCTAssertEqual(restored.subscriptionInfo, quotaB)
        XCTAssertEqual(restored.subscriptionInfoUpdatedAt, t1)
    }

    // MARK: - Case 10: identical body, changed quota

    func testUnchangedBodyStillAdvancesACapturedQuota() async throws {
        let profile = makeRemoteProfile(subscriptionInfo: quotaA, capturedAt: t1)

        try await profile.refreshRemoteProfile(
            fetch: { _ in
                RemoteProfileResponse(
                    content: self.yaml,
                    subscriptionUserInfo: "upload=161061273600; download=0; total=429496729600; expire=5"
                )
            },
            validate: { _ in },
            persist: { _ in }
        )

        XCTAssertEqual(profile.subscriptionInfo, quotaB, "a body that did not change still carries a new quota")
        let capturedAt = try XCTUnwrap(profile.subscriptionInfoUpdatedAt)
        XCTAssertGreaterThan(capturedAt, t1, "a capture advances freshness even when the body is unchanged")
    }

    // MARK: - The metadata probe

    /// Case 12, at the decision level: the primary response captured nothing, and the probe did.
    func testProbeSuppliesTheQuotaWhenThePrimaryResponseCannot() async throws {
        let profile = makeRemoteProfile(subscriptionInfo: quotaA, capturedAt: t1)
        var probedURLs: [String] = []

        let outcome = try await RemoteProfileRefresh.evaluate(
            remoteURL: profile.remoteURL,
            previous: SubscriptionSnapshot(info: quotaA, capturedAt: t1),
            currentBody: yaml,
            now: Date(timeIntervalSince1970: 2_000_000),
            fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: nil) },
            validate: { _ in },
            metadataProbe: { url in
                probedURLs.append(url)
                return .updated(self.quotaB)
            }
        )

        XCTAssertEqual(probedURLs, ["https://panel.example.invalid/sub"])
        XCTAssertTrue(outcome.usedMetadataProbe)
        XCTAssertEqual(outcome.subscriptionInfo, quotaB)
        XCTAssertEqual(outcome.subscriptionInfoUpdatedAt, Date(timeIntervalSince1970: 2_000_000))
    }

    /// The probe must not cost a second request when the panel already sent the header.
    func testProbeIsNotUsedWhenThePrimaryResponseCapturedAQuota() async throws {
        var probeCalls = 0

        let outcome = try await RemoteProfileRefresh.evaluate(
            remoteURL: "https://panel.example.invalid/sub",
            previous: SubscriptionSnapshot(info: quotaA, capturedAt: t1),
            currentBody: yaml,
            fetch: { _ in
                RemoteProfileResponse(
                    content: self.yaml,
                    subscriptionUserInfo: "upload=161061273600; download=0; total=429496729600; expire=5"
                )
            },
            validate: { _ in },
            metadataProbe: { _ in probeCalls += 1; return .updated(self.quotaA) }
        )

        XCTAssertEqual(probeCalls, 0, "a panel that sends the header must not be asked twice")
        XCTAssertFalse(outcome.usedMetadataProbe)
        XCTAssertEqual(outcome.subscriptionInfo, quotaB)
    }

    /// Case 7: a failing probe must not fail the refresh, and must not manufacture freshness.
    func testFailingProbeLeavesTheRefreshSuccessfulAndTheFreshnessUnmoved() async throws {
        struct ProbeFailed: Error {}

        let outcome = try await RemoteProfileRefresh.evaluate(
            remoteURL: "https://panel.example.invalid/sub",
            previous: SubscriptionSnapshot(info: quotaA, capturedAt: t1),
            currentBody: yaml,
            now: Date(timeIntervalSince1970: 2_000_000),
            fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: nil) },
            validate: { _ in },
            metadataProbe: { _ in throw ProbeFailed() }
        )

        XCTAssertFalse(outcome.usedMetadataProbe)
        XCTAssertEqual(outcome.subscriptionInfo, quotaA)
        XCTAssertEqual(outcome.subscriptionInfoUpdatedAt, t1, "a failed probe is not a capture")
        XCTAssertFalse(outcome.writeBody)
    }

    /// A probe that answers with a header this client cannot read is also not a capture.
    func testProbeReturningMalformedDoesNotAdvanceFreshness() async throws {
        let outcome = try await RemoteProfileRefresh.evaluate(
            remoteURL: "https://panel.example.invalid/sub",
            previous: SubscriptionSnapshot(info: quotaA, capturedAt: t1),
            currentBody: yaml,
            now: Date(timeIntervalSince1970: 2_000_000),
            fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: nil) },
            validate: { _ in },
            metadataProbe: { _ in .malformed }
        )

        XCTAssertEqual(outcome.subscriptionInfoUpdatedAt, t1)
        XCTAssertEqual(outcome.capture, .malformed)
        XCTAssertEqual(outcome.subscriptionInfo, quotaA)
    }

    // MARK: - The URL-change rule keeps both fields together

    func testChangingTheRemoteURLClearsTheQuotaAndItsCaptureTime() {
        let profile = makeRemoteProfile(subscriptionInfo: quotaA, capturedAt: t1)
        profile.remoteURL = "https://other-panel.example.invalid/sub"

        profile.normalizeRemoteSourceChange(previousURL: "https://panel.example.invalid/sub")

        XCTAssertNil(profile.subscriptionInfo, "panel B's figures are not panel A's")
        XCTAssertNil(
            profile.subscriptionInfoUpdatedAt,
            "a capture time with no quota would be a freshness claim about nothing"
        )
    }
}
