import Foundation
import GRDB

public enum ProfileManager {
    public nonisolated static func create(_ profile: Profile) async throws {
        profile.order = try await nextOrder()
        try await Database.sharedWriter.write { db in
            try profile.insert(db, onConflict: .fail)
        }
    }

    public nonisolated static func get(_ profileID: Int64) async throws -> Profile? {
        try await Database.sharedWriter.read { db in
            try Profile.fetchOne(db, id: profileID)
        }
    }

    public nonisolated static func get(by profileName: String) async throws -> Profile? {
        try await Database.sharedWriter.read { db in
            try Profile.filter(Column("name") == profileName).fetchOne(db)
        }
    }

    public nonisolated static func delete(_ profile: Profile) async throws {
        _ = try await Database.sharedWriter.write { db in
            try profile.delete(db)
        }
    }

    public nonisolated static func delete(by id: Int64) async throws {
        _ = try await Database.sharedWriter.write { db in
            try Profile.deleteOne(db, id: id)
        }
    }

    public nonisolated static func delete(_ profileList: [Profile]) async throws -> Int {
        try await Database.sharedWriter.write { db in
            try Profile.deleteAll(db, keys: profileList.map {
                ["id": $0.id!]
            })
        }
    }

    public nonisolated static func delete(by id: [Int64]) async throws -> Int {
        try await Database.sharedWriter.write { db in
            try Profile.deleteAll(db, ids: id)
        }
    }

    public nonisolated static func update(_ profile: Profile) async throws {
        _ = try await Database.sharedWriter.write { db in
            // Compared against the row on disk rather than against a copy the caller kept, so the
            // decision holds however the caller reached this point. See
            // `Profile.normalizeRemoteSourceChange(previousURL:)`.
            //
            // A profile with no id has never been written, so there is no previous source to
            // compare against and nothing to invalidate.
            if let id = profile.id {
                let storedURL = try Profile.fetchOne(db, id: id)?.remoteURL
                profile.normalizeRemoteSourceChange(previousURL: storedURL)
            }
            try profile.updateChanges(db)
        }
    }

    /// Commits an update's metadata, but only onto the profile the update read.
    ///
    /// # Why the check is inside the transaction
    ///
    /// The remote URL is the ownership key for the metadata: a refresh resolved a source, downloaded
    /// from it, and fetched a quota that describes THAT subscription. If the user edits the URL while
    /// the request is in flight, the row now describes another subscription, and committing panel A's
    /// figures onto it shows A's traffic for B. Reading the stored URL inside the same write
    /// transaction that the comparison protects is what makes the answer true at the instant of the
    /// write rather than at the instant of the read.
    ///
    /// The body is NOT checked here. The file is its authority, and the caller checks it immediately
    /// before writing it (`RemoteRefreshApplier`). This function checks what it can actually see.
    ///
    /// - Throws: `ProfileSupersededError` when the profile now points at another source.
    public nonisolated static func update(_ profile: Profile, ticket: ProfileUpdateTicket) async throws {
        _ = try await Database.sharedWriter.write { db in
            let stored = try profile.id.flatMap { try Profile.fetchOne(db, id: $0) }
            if case let .superseded(reason) = ProfileUpdateOwnership.sourceVerdict(
                ticket: ticket,
                storedRemoteURL: stored?.remoteURL
            ) {
                throw ProfileSupersededError(reason: reason, requestID: ticket.requestID)
            }
            if let id = profile.id {
                profile.normalizeRemoteSourceChange(previousURL: stored?.remoteURL)
            }
            try profile.updateChanges(db)
        }
    }

    public nonisolated static func update(_ profileList: [Profile]) async throws {
        // TODO: batch update
        try await Database.sharedWriter.write { db in
            for profile in profileList {
                try profile.updateChanges(db)
            }
        }
    }

    public nonisolated static func list() async throws -> [Profile] {
        try await Database.sharedWriter.read { db in
            try Profile.all().order(Column("order").asc).fetchAll(db)
        }
    }

    public nonisolated static func listRemote() async throws -> [Profile] {
        try await Database.sharedWriter.read { db in
            try Profile.filter(Column("type") == ProfileType.remote.rawValue).order(Column("order").asc).fetchAll(db)
        }
    }

    public nonisolated static func listAutoUpdateEnabled() async throws -> [Profile] {
        try await Database.sharedWriter.read { db in
            try Profile.filter(Column("autoUpdate") == true).order(Column("order").asc).fetchAll(db)
        }
    }

    public nonisolated static func nextID() async throws -> Int64 {
        try await Database.sharedWriter.read { db in
            if let lastProfile = try Profile.select(Column("id")).order(Column("id").desc).fetchOne(db) {
                return lastProfile.id! + 1
            } else {
                return 1
            }
        }
    }

    private nonisolated static func nextOrder() async throws -> UInt32 {
        try await Database.sharedWriter.read { db in
            try UInt32(Profile.fetchCount(db))
        }
    }

    public nonisolated static func uniqueName(_ baseName: String) async throws -> String {
        let profiles = try await list()
        let existingNames = Set(profiles.map(\.name))
        if !existingNames.contains(baseName) {
            return baseName
        }
        var counter = 1
        while true {
            let candidate = "\(baseName) (\(counter))"
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }
}
