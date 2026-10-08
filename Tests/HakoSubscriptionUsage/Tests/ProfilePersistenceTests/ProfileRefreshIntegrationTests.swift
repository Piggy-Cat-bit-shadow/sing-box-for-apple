import Core
import Foundation
import GRDB
import ProfileUnderTest
import XCTest

/// `Profile.refreshRemoteProfile()` itself - the shipping sequence, with only the fetch and the
/// database write substituted.
///
/// These are the cases that cannot be established by testing the decision value alone, because they
/// are about what the profile does with it: whether the configuration file on disk was touched, and
/// what state the profile was in at the moment it was handed to be persisted.
final class ProfileRefreshIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hako-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FilePath.sharedDirectory = directory
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private let yaml = "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}]}"

    private func makeRemoteProfile(path: String, subscriptionInfo: SubscriptionInfo?) -> Profile {
        Profile(
            id: 1,
            name: "airport",
            type: .remote,
            path: path,
            remoteURL: "https://panel.example.invalid/sub",
            lastUpdated: Date(timeIntervalSince1970: 1_000_000),
            subscriptionInfo: subscriptionInfo
        )
    }

    private func write(_ content: String, to path: String) throws {
        try ensureParentDirectory(of: path)
        try content.write(
            to: directory.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
    }

    /// `Profile.write` uses an atomic write, which needs the containing directory to exist - the app
    /// creates it when a profile is made.
    private func ensureParentDirectory(of path: String) throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(path))
    }

    private func modificationDate(_ path: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(path).path
        )
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    /// Records what the profile looked like at the moment it was persisted.
    private final class Persisted {
        var count = 0
        var subscriptionInfo: SubscriptionInfo??
        var lastUpdated: Date?

        func record(_ profile: Profile) {
            count += 1
            subscriptionInfo = profile.subscriptionInfo
            lastUpdated = profile.lastUpdated
        }
    }

    // MARK: - The round's first acceptance item
    //
    // A panel's YAML does not change for days while its usage counter moves on every request. The
    // metadata must reach the database and the file on disk must not be touched.

    func testUnchangedBodyAdvancesMetadataWithoutTouchingTheFile() async throws {
        let path = "configs/config_1.json"
        try write(yaml, to: path)
        let before = try modificationDate(path)
        let old = SubscriptionInfo(upload: 100 * 1_073_741_824, download: 0, total: 400 * 1_073_741_824, expire: 5)
        let profile = makeRemoteProfile(path: path, subscriptionInfo: old)
        let persisted = Persisted()

        try await profile.refreshRemoteProfile(
            fetch: { _ in
                RemoteProfileResponse(
                    content: self.yaml,
                    subscriptionUserInfo: "upload=161061273600; download=0; total=429496729600; expire=5"
                )
            },
            validate: { _ in },
            persist: { persisted.record($0) }
        )

        XCTAssertEqual(persisted.count, 1, "the metadata must be committed even when the body is unchanged")
        XCTAssertEqual(
            persisted.subscriptionInfo ?? nil,
            SubscriptionInfo(upload: 161_061_273_600, download: 0, total: 429_496_729_600, expire: 5)
        )
        XCTAssertEqual(profile.subscriptionInfo?.upload, 161_061_273_600)
        XCTAssertGreaterThan(profile.lastUpdated ?? .distantPast, Date(timeIntervalSince1970: 1_000_000))
        // The body never reached the write path.
        XCTAssertEqual(try modificationDate(path), before, "a metadata-only refresh rewrote the configuration")
        XCTAssertEqual(try read(path), yaml)
    }

    // MARK: - A changed body still behaves as it always did

    func testChangedBodyIsWrittenToDisk() async throws {
        let path = "configs/config_1.json"
        try write(yaml, to: path)
        let next = "{\"outbounds\":[{\"type\":\"block\",\"tag\":\"block\"}]}"
        let profile = makeRemoteProfile(path: path, subscriptionInfo: nil)
        let persisted = Persisted()

        try await profile.refreshRemoteProfile(
            fetch: { _ in
                RemoteProfileResponse(content: next, subscriptionUserInfo: "upload=1; download=2; total=3; expire=4")
            },
            validate: { _ in },
            persist: { persisted.record($0) }
        )

        XCTAssertEqual(try read(path), next)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.subscriptionInfo ?? nil, SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4))
    }

    // MARK: - Rule 2, end to end

    func testResponseWithoutHeaderKeepsTheStoredMetadataOnDiskAndInTheDatabase() async throws {
        let path = "configs/config_1.json"
        try write(yaml, to: path)
        let old = SubscriptionInfo(upload: 10, download: 20, total: 30, expire: 40)
        let profile = makeRemoteProfile(path: path, subscriptionInfo: old)
        let persisted = Persisted()

        try await profile.refreshRemoteProfile(
            fetch: { _ in RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: nil) },
            validate: { _ in },
            persist: { persisted.record($0) }
        )

        XCTAssertEqual(profile.subscriptionInfo, old)
        XCTAssertEqual(persisted.subscriptionInfo ?? nil, old, "an absent header erased the stored metadata")
    }

    // MARK: - Rule 4, end to end

    func testFailedValidationLeavesEverythingAlone() async throws {
        let path = "configs/config_1.json"
        try write(yaml, to: path)
        let before = try modificationDate(path)
        let old = SubscriptionInfo(upload: 10, download: 20, total: 30, expire: 40)
        let profile = makeRemoteProfile(path: path, subscriptionInfo: old)
        let persisted = Persisted()
        let lastUpdatedBefore = profile.lastUpdated

        struct Rejected: Error {}

        do {
            try await profile.refreshRemoteProfile(
                fetch: { _ in
                    RemoteProfileResponse(content: "not a config", subscriptionUserInfo: "upload=999; download=999; total=999; expire=9")
                },
                validate: { _ in throw Rejected() },
                persist: { persisted.record($0) }
            )
            XCTFail("a rejected configuration must throw")
        } catch {
            // expected
        }

        XCTAssertEqual(persisted.count, 0, "a failed refresh committed metadata")
        XCTAssertEqual(profile.subscriptionInfo, old)
        XCTAssertEqual(profile.lastUpdated, lastUpdatedBefore)
        XCTAssertEqual(try modificationDate(path), before)
        XCTAssertEqual(try read(path), yaml)
    }

    // MARK: - Rule 4, a failed fetch

    func testFailedFetchLeavesEverythingAlone() async throws {
        let path = "configs/config_1.json"
        try write(yaml, to: path)
        let old = SubscriptionInfo(upload: 10, download: 20, total: 30, expire: 40)
        let profile = makeRemoteProfile(path: path, subscriptionInfo: old)
        let persisted = Persisted()

        struct Offline: Error {}

        do {
            try await profile.refreshRemoteProfile(
                fetch: { _ in throw Offline() },
                validate: { _ in },
                persist: { persisted.record($0) }
            )
            XCTFail("a failed fetch must throw")
        } catch {
            // expected
        }

        XCTAssertEqual(persisted.count, 0)
        XCTAssertEqual(profile.subscriptionInfo, old)
    }

    // MARK: - A local profile is not a subscription

    func testLocalProfileIsUntouchedByARefresh() async throws {
        let path = "configs/config_9.json"
        try write(yaml, to: path)
        let profile = Profile(id: 9, name: "local", type: .local, path: path)
        let persisted = Persisted()
        var didFetch = false

        try await profile.refreshRemoteProfile(
            fetch: { _ in didFetch = true; return RemoteProfileResponse(content: "", subscriptionUserInfo: nil) },
            validate: { _ in },
            persist: { persisted.record($0) }
        )

        XCTAssertFalse(didFetch, "a local profile must never be fetched as a subscription")
        XCTAssertEqual(persisted.count, 0)
        XCTAssertNil(profile.subscriptionInfo)
    }

    // MARK: - First refresh of a profile that has nothing yet

    func testFirstRefreshStoresMetadataAndWritesTheBody() async throws {
        let path = "configs/config_1.json"
        try ensureParentDirectory(of: path)
        let profile = makeRemoteProfile(path: path, subscriptionInfo: nil)
        let persisted = Persisted()

        try await profile.refreshRemoteProfile(
            fetch: { _ in
                RemoteProfileResponse(content: self.yaml, subscriptionUserInfo: "upload=1; download=2; total=3; expire=4")
            },
            validate: { _ in },
            persist: { persisted.record($0) }
        )

        XCTAssertEqual(profile.subscriptionInfo, SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4))
        XCTAssertEqual(try read(path), yaml)
        XCTAssertEqual(persisted.count, 1)
    }
}
