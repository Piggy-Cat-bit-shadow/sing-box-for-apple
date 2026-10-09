import Foundation
import GRDB
import Network

public class Profile: Record, Identifiable, ObservableObject {
    public var id: Int64?
    public var mustID: Int64 {
        id!
    }

    @Published public var name: String
    public var order: UInt32
    public var type: ProfileType
    public var path: String
    @Published public var remoteURL: String?
    @Published public var autoUpdate: Bool
    @Published public var autoUpdateInterval: Int32
    public var lastUpdated: Date?

    /// The airport panel's reported traffic, or `nil` when this profile has none.
    ///
    /// `nil` is the ordinary state for a local or iCloud profile, for a remote profile whose panel
    /// sends no `subscription-userinfo`, and for one whose remote URL was just changed. It is
    /// distinct from an all-zero `SubscriptionInfo`, which means "the panel reported zero usage".
    ///
    /// No change-tracking hook is needed for this property. `ProfileManager.update` persists
    /// through `updateChanges`, and GRDB derives the changed columns by comparing `encode(to:)`
    /// against the row the record was fetched from, so a new value here is picked up and written as
    /// long as the profile was read from the database rather than hand-built. Keep `encode(to:)`
    /// below in agreement with the `add_subscription_info` migration in `Database.swift`.
    @Published public var subscriptionInfo: SubscriptionInfo?

    public init(id: Int64? = nil, name: String, order: UInt32 = 0, type: ProfileType, path: String, remoteURL: String? = nil, autoUpdate: Bool = false, autoUpdateInterval: Int32 = 0, lastUpdated: Date? = nil, subscriptionInfo: SubscriptionInfo? = nil) {
        self.id = id
        self.name = name
        self.order = order
        self.type = type
        self.path = path
        self.remoteURL = remoteURL
        self.autoUpdate = autoUpdate
        self.autoUpdateInterval = autoUpdateInterval
        self.lastUpdated = lastUpdated
        self.subscriptionInfo = subscriptionInfo
        super.init()
    }

    override public class var databaseTableName: String {
        "profiles"
    }

    enum Columns: String, ColumnExpression {
        case id, name, order, type, path, remoteURL, autoUpdate, autoUpdateInterval, lastUpdated, userAgent
        case subscriptionUpload, subscriptionDownload, subscriptionTotal, subscriptionExpire
    }

    required init(row: Row) throws {
        id = row[Columns.id]
        name = row[Columns.name] ?? ""
        order = row[Columns.order] ?? 0
        type = ProfileType(rawValue: row[Columns.type] ?? ProfileType.local.rawValue)!
        path = row[Columns.path] ?? ""
        remoteURL = row[Columns.remoteURL] ?? ""
        autoUpdate = row[Columns.autoUpdate] ?? false
        autoUpdateInterval = row[Columns.autoUpdateInterval] ?? 0
        lastUpdated = row[Columns.lastUpdated] ?? Date()
        // A row written before `add_subscription_info`, or one whose panel sends no metadata,
        // leaves all four null and reads back as `nil` - never as a zero-valued quota.
        if let upload: Int64 = row[Columns.subscriptionUpload],
           let download: Int64 = row[Columns.subscriptionDownload],
           let total: Int64 = row[Columns.subscriptionTotal],
           let expire: Int64 = row[Columns.subscriptionExpire]
        {
            subscriptionInfo = SubscriptionInfo(upload: upload, download: download, total: total, expire: expire)
        } else {
            subscriptionInfo = nil
        }
        try super.init(row: row)
    }

    override public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.order] = order
        container[Columns.type] = type.rawValue
        container[Columns.path] = path
        container[Columns.remoteURL] = remoteURL
        container[Columns.autoUpdate] = autoUpdate
        container[Columns.autoUpdateInterval] = autoUpdateInterval
        container[Columns.lastUpdated] = lastUpdated
        // Written together or not at all, so a half-known quota can never be read back.
        container[Columns.subscriptionUpload] = subscriptionInfo?.upload
        container[Columns.subscriptionDownload] = subscriptionInfo?.download
        container[Columns.subscriptionTotal] = subscriptionInfo?.total
        container[Columns.subscriptionExpire] = subscriptionInfo?.expire
    }

    override public func didInsert(_ inserted: InsertionSuccess) {
        super.didInsert(inserted)
        id = inserted.rowID
    }
}

public struct ProfilePreview: Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public var order: UInt32
    public let type: ProfileType
    public let path: String
    public let remoteURL: String?
    public let autoUpdate: Bool
    public let autoUpdateInterval: Int32
    public let lastUpdated: Date?
    /// Mirrored so the phone's profile rows can read the panel's traffic from the snapshot they
    /// already hold, without reaching back to `origin` for it.
    public let subscriptionInfo: SubscriptionInfo?
    public let origin: Profile

    public init(_ profile: Profile) {
        id = profile.mustID
        name = profile.name
        order = profile.order
        type = profile.type
        path = profile.path
        remoteURL = profile.remoteURL
        autoUpdate = profile.autoUpdate
        autoUpdateInterval = profile.autoUpdateInterval
        lastUpdated = profile.lastUpdated
        subscriptionInfo = profile.subscriptionInfo
        origin = profile
    }
}

public enum ProfileType: Int {
    case local = 0, icloud, remote
}
