import Core
import GRDB
import ProfileUnderTest
import XCTest

/// What `Profile.swift` does with the four subscription columns, compiled against a GRDB stand-in
/// because the app project resolves the real GRDB over the network.
///
/// The cases here are the record contract, not the SQL: a fetched row with four nulls must read
/// back as "no metadata" rather than as a zero quota, a value must survive `encode(to:)` into a
/// container, and a row that predates the migration must still decode.
final class ProfileRecordTests: XCTestCase {
    /// A row shaped like one the `profiles` table returns, with the subscription columns as the
    /// migration leaves them.
    private func row(
        id: Int64 = 1,
        name: String = "airport",
        order: Int64 = 0,
        type: Int64 = Int64(ProfileUnderTest.ProfileType.remote.rawValue),
        path: String = "configs/config_1.json",
        remoteURL: String = "https://panel.example.invalid/sub",
        autoUpdate: Int64 = 1,
        autoUpdateInterval: Int64 = 60,
        lastUpdated: Date = Date(timeIntervalSince1970: 1_700_000_000),
        upload: DatabaseValue = .null,
        download: DatabaseValue = .null,
        total: DatabaseValue = .null,
        expire: DatabaseValue = .null
    ) -> Row {
        // Annotated so every element is a `DatabaseValue` rather than defaulting to `Int`.
        let columns: [String: DatabaseValue] = [
            "id": .integer(id),
            "name": .text(name),
            "order": .integer(order),
            "type": .integer(type),
            "path": .text(path),
            "remoteURL": .text(remoteURL),
            "autoUpdate": .integer(autoUpdate),
            "autoUpdateInterval": .integer(autoUpdateInterval),
            "lastUpdated": .real(lastUpdated.timeIntervalSince1970),
            "subscriptionUpload": upload,
            "subscriptionDownload": download,
            "subscriptionTotal": total,
            "subscriptionExpire": expire,
        ]
        return Row(columns: columns)
    }

    private func encoded(_ profile: Profile) throws -> [String: DatabaseValue] {
        try profileEncodedColumns(profile)
    }

    // MARK: - CASE 12: a row written before the migration

    func testRowWithNullSubscriptionColumnsDecodesAsNoMetadata() throws {
        let profile = try profileFromRow(self.row())
        XCTAssertNil(profile.subscriptionInfo)
        XCTAssertEqual(profile.name, "airport")
        XCTAssertEqual(profile.remoteURL, "https://panel.example.invalid/sub")
    }

    /// Every pre-existing column the migration must not disturb. A migration that dropped or
    /// renamed one of these would pass a narrower test and fail the user.
    func testRowWithNullSubscriptionColumnsKeepsEveryOtherColumn() throws {
        let profile = try profileFromRow(self.row())
        XCTAssertEqual(profile.id, 1)
        XCTAssertEqual(profile.name, "airport")
        XCTAssertEqual(profile.order, 0)
        XCTAssertEqual(profile.type, ProfileUnderTest.ProfileType.remote)
        XCTAssertEqual(profile.path, "configs/config_1.json")
        XCTAssertEqual(profile.remoteURL, "https://panel.example.invalid/sub")
        XCTAssertTrue(profile.autoUpdate)
        XCTAssertEqual(profile.autoUpdateInterval, 60)
        XCTAssertEqual(profile.lastUpdated, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testRowWithValuesDecodesMetadata() throws {
        let profile = try profileFromRow(self.row(
            upload: .integer(100), download: .integer(200),
            total: .integer(1000), expire: .integer(2_000_000_000)
        ))
        XCTAssertEqual(
            profile.subscriptionInfo,
            SubscriptionInfo(upload: 100, download: 200, total: 1000, expire: 2_000_000_000)
        )
    }

    /// A partially written row is not a quota. Reading it as one would report zero usage.
    func testPartiallyNullRowDecodesAsNoMetadata() throws {
        for columns in [
            (DatabaseValue.integer(1), DatabaseValue.null, DatabaseValue.integer(3), DatabaseValue.integer(4)),
            (DatabaseValue.integer(1), DatabaseValue.integer(2), DatabaseValue.null, DatabaseValue.integer(4)),
            (DatabaseValue.integer(1), DatabaseValue.integer(2), DatabaseValue.integer(3), DatabaseValue.null),
        ] {
            let profile = try profileFromRow(self.row(
                upload: columns.0, download: columns.1, total: columns.2, expire: columns.3
            ))
            XCTAssertNil(profile.subscriptionInfo, "a half-known quota must not read as a quota")
        }
    }

    // MARK: - Encoding writes the migration's column names

    func testWithMetadataEncodesAllFourColumns() throws {
        let profile = ProfileUnderTest.Profile(
            id: 1, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_1.json",
            remoteURL: "https://panel.example.invalid/sub",
            subscriptionInfo: SubscriptionInfo(upload: 10, download: 20, total: 30, expire: 40)
        )
        let container = try encoded(profile)
        XCTAssertEqual(container["subscriptionUpload"], .integer(10))
        XCTAssertEqual(container["subscriptionDownload"], .integer(20))
        XCTAssertEqual(container["subscriptionTotal"], .integer(30))
        XCTAssertEqual(container["subscriptionExpire"], .integer(40))
    }

    /// "No metadata" must be written as NULL, never as a row of zeroes - the difference between
    /// "the panel said nothing" and "the panel said you have used nothing".
    func testWithoutMetadataEncodesNullsNotZeroes() throws {
        let profile = ProfileUnderTest.Profile(
            id: 1, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_1.json",
            remoteURL: "https://panel.example.invalid/sub",
            subscriptionInfo: nil
        )
        let container = try encoded(profile)
        XCTAssertEqual(container["subscriptionUpload"], .null)
        XCTAssertEqual(container["subscriptionDownload"], .null)
        XCTAssertEqual(container["subscriptionTotal"], .null)
        XCTAssertEqual(container["subscriptionExpire"], .null)
    }

    // MARK: - GRDB change tracking
    //
    // `ProfileManager.update` persists through `updateChanges`, and GRDB 7 decides which columns to
    // write by comparing `encode(to:)` against the fetched row. If that comparison did not see the
    // metadata change, the panel's figures would live in memory and vanish on the next read.

    func testChangedMetadataIsVisibleAsADatabaseChange() throws {
        let fetched = try profileFromRow(self.row())
        XCTAssertTrue(try profileDatabaseChanges(fetched).isEmpty)
        fetched.subscriptionInfo = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        XCTAssertEqual(
            Set(try profileDatabaseChanges(fetched).keys),
            ["subscriptionUpload", "subscriptionDownload", "subscriptionTotal", "subscriptionExpire"]
        )
    }

    func testUnchangedMetadataIsNotADatabaseChange() throws {
        let fetched = try profileFromRow(self.row(
            upload: .integer(1), download: .integer(2), total: .integer(3), expire: .integer(4)
        ))
        fetched.subscriptionInfo = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        XCTAssertTrue(try profileDatabaseChanges(fetched).isEmpty)
    }

    func testClearedMetadataIsADatabaseChange() throws {
        let fetched = try profileFromRow(self.row(
            upload: .integer(1), download: .integer(2), total: .integer(3), expire: .integer(4)
        ))
        fetched.subscriptionInfo = nil
        XCTAssertEqual(
            Set(try profileDatabaseChanges(fetched).keys),
            ["subscriptionUpload", "subscriptionDownload", "subscriptionTotal", "subscriptionExpire"]
        )
    }

    // MARK: - CASE 16: local and iCloud profiles carry no remote metadata

    func testLocalProfileHasNoSubscriptionInfoByDefault() {
        let profile = ProfileUnderTest.Profile(name: "local", type: ProfileUnderTest.ProfileType.local, path: "configs/config_1.json")
        XCTAssertNil(profile.subscriptionInfo)
    }

    func testICloudProfileHasNoSubscriptionInfoByDefault() {
        let profile = ProfileUnderTest.Profile(name: "icloud", type: ProfileUnderTest.ProfileType.icloud, path: "config.json")
        XCTAssertNil(profile.subscriptionInfo)
    }

    // MARK: - ProfilePreview mirrors it for the next round's UI

    func testPreviewMirrorsSubscriptionInfo() throws {
        let info = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        let profile = ProfileUnderTest.Profile(
            id: 7, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_7.json",
            remoteURL: "https://panel.example.invalid/sub", subscriptionInfo: info
        )
        let preview = ProfileUnderTest.ProfilePreview(profile)
        XCTAssertEqual(preview.subscriptionInfo, info)
        XCTAssertEqual(preview.id, 7)
        XCTAssertEqual(preview.remoteURL, "https://panel.example.invalid/sub")
    }

    func testPreviewMirrorsAbsentSubscriptionInfo() {
        let profile = ProfileUnderTest.Profile(id: 7, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_7.json")
        XCTAssertNil(ProfileUnderTest.ProfilePreview(profile).subscriptionInfo)
    }

    // MARK: - CASE 11 and CASE 16: source-change normalisation

    func testRemoteURLChangeClearsMetadata() {
        let profile = ProfileUnderTest.Profile(
            id: 7, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_7.json",
            remoteURL: "https://panelB.example.invalid/sub",
            subscriptionInfo: SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        )
        profile.normalizeRemoteSourceChange(previousURL: "https://panelA.example.invalid/sub")
        XCTAssertNil(profile.subscriptionInfo, "panel A's traffic must not survive the move to panel B")
    }

    func testUnchangedRemoteURLKeepsMetadata() {
        let info = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        let profile = ProfileUnderTest.Profile(
            id: 7, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_7.json",
            remoteURL: "https://panelA.example.invalid/sub", subscriptionInfo: info
        )
        profile.normalizeRemoteSourceChange(previousURL: "https://panelA.example.invalid/sub")
        XCTAssertEqual(profile.subscriptionInfo, info)
    }

    func testLocalProfileIgnoresSourceChangeNormalisation() {
        let info = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        let profile = ProfileUnderTest.Profile(
            id: 7, name: "local", type: ProfileUnderTest.ProfileType.local, path: "configs/config_7.json",
            subscriptionInfo: info
        )
        profile.normalizeRemoteSourceChange(previousURL: "https://panelA.example.invalid/sub")
        XCTAssertEqual(profile.subscriptionInfo, info)
    }

    /// The stored URL is what the change is measured against, and a first save has no stored URL.
    func testFirstSaveWithNoStoredURLDoesNotClearOnItsOwn() {
        let info = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        let profile = ProfileUnderTest.Profile(
            id: 7, name: "airport", type: ProfileUnderTest.ProfileType.remote, path: "configs/config_7.json",
            remoteURL: "https://panelA.example.invalid/sub", subscriptionInfo: info
        )
        // A profile that was never in the database has no previous URL, and nothing to invalidate.
        profile.normalizeRemoteSourceChange(previousURL: profile.remoteURL)
        XCTAssertEqual(profile.subscriptionInfo, info)
    }
}
