import Foundation
import GRDB

enum Database {
    static let sharedWriter = makeShared()

    private static func makeShared() -> any DatabaseWriter {
        do {
            try FileManager.default.createDirectory(at: FilePath.sharedDirectory, withIntermediateDirectories: true)
            let database = try DatabasePool(path: FilePath.sharedDirectory.appendingPathComponent("settings.db").relativePath)
            var migrator = DatabaseMigrator().disablingDeferredForeignKeyChecks()
            migrator.registerMigration("initialize") { db in
                try db.create(table: "profiles") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("name", .text).notNull()
                    t.column("order", .integer).notNull()
                    t.column("type", .integer).notNull().defaults(to: ProfileType.local.rawValue)
                    t.column("path", .text).notNull()
                    t.column("remoteURL", .text)
                    t.column("autoUpdate", .boolean).notNull().defaults(to: false)
                    t.column("lastUpdated", .datetime)
                }
                try db.create(table: "preferences") { t in
                    t.primaryKey("name", .text, onConflict: .replace).notNull()
                    t.column("data", .blob)
                }
            }
            migrator.registerMigration("add_auto_update_interval") { db in
                try db.alter(table: "profiles") { t in
                    t.add(column: "autoUpdateInterval", .integer).notNull().defaults(to: 0)
                }
            }
            migrator.registerMigration("fix_cellular_typo") { db in
                try db.execute(sql: "UPDATE preferences SET name = 'exclude_cellular_services' WHERE name = 'exclude_celluar_services'")
            }
            migrator.registerMigration("use_relative_profile_paths") { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, path, type FROM profiles")
                let prefix = FilePath.sharedDirectory.path.hasSuffix("/")
                    ? FilePath.sharedDirectory.path
                    : FilePath.sharedDirectory.path + "/"
                for row in rows {
                    let id: Int64 = row["id"]
                    let path: String = row["path"]
                    let type: Int = row["type"]
                    if type == ProfileType.icloud.rawValue {
                        continue
                    }
                    guard path.hasPrefix("/") else { continue }
                    var newPath = path
                    if path.hasPrefix(prefix) {
                        newPath = String(path.dropFirst(prefix.count))
                    } else if let range = path.range(of: "configs/config_") {
                        newPath = String(path[range.lowerBound...])
                    }
                    if newPath != path {
                        try db.execute(sql: "UPDATE profiles SET path = ? WHERE id = ?", arguments: [newPath, id])
                    }
                }
            }
            migrator.registerMigration("add_remote_servers") { db in
                try db.create(table: "remote_servers") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("name", .text).notNull()
                    t.column("order", .integer).notNull()
                    t.column("url", .text).notNull()
                    t.column("secret", .text).notNull().defaults(to: "")
                }
            }
            migrator.registerMigration("add_subscription_info") { db in
                // Four nullable columns rather than one encoded blob: this table is decoded by
                // hand in `Profile.init(row:)` and encoded in `Profile.encode(to:)`, so separate
                // columns keep the adaptation transparent - and, being nullable, every existing
                // profile row reads back as "no metadata" without a default to mistake for a
                // real all-zero quota.
                //
                // Additive and nullable only. Nothing here renames, drops or rewrites an existing
                // column, so a settings.db written by any earlier build keeps working and a user's
                // profiles, preferences and remote servers are untouched by this migration.
                try db.alter(table: "profiles") { t in
                    t.add(column: "subscriptionUpload", .integer)
                    t.add(column: "subscriptionDownload", .integer)
                    t.add(column: "subscriptionTotal", .integer)
                    t.add(column: "subscriptionExpire", .integer)
                }
            }
            try migrator.migrate(database)
            return database
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
