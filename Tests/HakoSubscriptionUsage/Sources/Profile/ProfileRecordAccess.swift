import Core
import Foundation
import GRDB

// `Profile.init(row:)` is a `required` initializer inherited from GRDB's `Record`, and Swift does
// not re-export a superclass's required initializer across a module boundary once the subclass
// declares its own designated initializers. The app never calls it from outside the module either:
// GRDB's own `fetchOne` does, through the same module.
//
// These factories therefore live inside the module under test, so the record's real initializer and
// its real `encode(to:)` are what the tests exercise - rather than a second, hand-written
// initializer that could disagree with them.

/// Build a profile exactly as a `profiles` row decodes it.
public func profileFromRow(_ row: GRDB.Row) throws -> Profile {
    try Profile(row: row)
}

/// Encode a profile exactly as GRDB does before persisting it.
public func profileEncodedColumns(_ profile: Profile) throws -> [String: DatabaseValue] {
    var container = PersistenceContainer()
    try profile.encode(to: &container)
    return container.columns
}

/// The columns GRDB would write for this profile, which is how `updateChanges` decides what to
/// save.
public func profileDatabaseChanges(_ profile: Profile) throws -> [String: DatabaseValue?] {
    try profile.databaseChanges()
}
