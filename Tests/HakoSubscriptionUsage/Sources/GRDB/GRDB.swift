// A minimal stand-in for GRDB 7, covering only the surface `Library/Database/Profile.swift` uses.
//
// This is NOT GRDB. It exists so the profile record's storage contract can be tested with no
// network and no simulator, and it is deliberately faithful to the two behaviours that decide
// whether subscription metadata survives a round trip:
//
//  * `Record` derives its changed columns by comparing `encode(to:)` against the row it was
//    fetched from - not by any change-notification hook. GRDB 7 has no `didChange`; a record that
//    tried to call one would not compile against the real library either.
//  * a nullable column reads back as `nil`, and a `nil` written into a container stores SQL NULL
//    rather than zero.
//
// If the app's use of GRDB ever outgrows this surface, the compile failure is the signal to
// widen the stub or retire this test - the point is that the *app* file is what compiles.

import Foundation

public protocol DatabaseValueConvertible {}

extension Int64: DatabaseValueConvertible {}
extension Int: DatabaseValueConvertible {}
extension Int32: DatabaseValueConvertible {}
extension Int16: DatabaseValueConvertible {}
extension Int8: DatabaseValueConvertible {}
extension UInt64: DatabaseValueConvertible {}
extension UInt32: DatabaseValueConvertible {}
extension UInt16: DatabaseValueConvertible {}
extension UInt8: DatabaseValueConvertible {}
extension Double: DatabaseValueConvertible {}
extension Float: DatabaseValueConvertible {}
extension String: DatabaseValueConvertible {}
extension Bool: DatabaseValueConvertible {}
extension Date: DatabaseValueConvertible {}
extension Data: DatabaseValueConvertible {}

public protocol ColumnExpression {
    var name: String { get }
}

/// The default that lets a column enum be declared as
/// `enum Columns: String, ColumnExpression { case id, name }`.
extension ColumnExpression where Self: RawRepresentable, Self.RawValue == String {
    public var name: String { rawValue }
}

public struct Column: ColumnExpression, ExpressibleByStringLiteral {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral value: String) {
        name = value
    }
}

/// A stored value, modelling SQL NULL as `.null` so `nil` never silently becomes `0`.
public enum DatabaseValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public extension DatabaseValue {
    init?(_ value: (any DatabaseValueConvertible)?) {
        switch value {
        case nil:
            self = .null
        case let value as Int64:
            self = .integer(value)
        case let value as Int:
            self = .integer(Int64(value))
        case let value as Int32:
            self = .integer(Int64(value))
        case let value as Int16:
            self = .integer(Int64(value))
        case let value as Int8:
            self = .integer(Int64(value))
        case let value as UInt64:
            self = .integer(Int64(clamping: value))
        case let value as UInt32:
            self = .integer(Int64(value))
        case let value as UInt16:
            self = .integer(Int64(value))
        case let value as UInt8:
            self = .integer(Int64(value))
        case let value as Bool:
            self = .integer(value ? 1 : 0)
        case let value as Double:
            self = .real(value)
        case let value as Float:
            self = .real(Double(value))
        case let value as String:
            self = .text(value)
        case let value as Date:
            self = .real(value.timeIntervalSince1970)
        case let value as Data:
            self = .blob(value)
        default:
            return nil
        }
    }

    var int64Value: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var isNull: Bool {
        self == .null
    }
}

/// The encoded column set of a record.
public struct PersistenceContainer: Sequence {
    private var storage: [String: DatabaseValue] = [:]

    public init() {}

    /// Encodes a record, which is how GRDB obtains the current column values to compare against
    /// the row it was fetched from.
    public init(_ record: Record) throws {
        try record.encode(to: &self)
    }

    public subscript(column: ColumnExpression) -> (any DatabaseValueConvertible)? {
        get { nil }
        set {
            if let newValue, let value = DatabaseValue(newValue) {
                storage[column.name] = value
            } else {
                storage[column.name] = .null
            }
        }
    }

    public func makeIterator() -> AnyIterator<(String, DatabaseValue)> {
        var iterator = storage.makeIterator()
        return AnyIterator { iterator.next() }
    }

    public var columns: [String: DatabaseValue] {
        storage
    }
}

/// A fetched row.
public struct Row {
    private var storage: [String: DatabaseValue]
    public let isFetched: Bool

    public init(columns: [String: DatabaseValue], isFetched: Bool = true) {
        storage = columns
        self.isFetched = isFetched
    }

    public init(_ container: PersistenceContainer) {
        storage = container.columns
        isFetched = false
    }

    public func copy() -> Row {
        self
    }

    public subscript(column: ColumnExpression) -> DatabaseValue? {
        storage[column.name]
    }

    /// Models GRDB's row decoding: a null or absent column yields `nil`, and a value that does not
    /// fit the requested type yields `nil` rather than trapping.
    public subscript<T: DatabaseValueConvertible>(column: ColumnExpression) -> T? {
        guard let value = storage[column.name] else { return nil }
        switch value {
        case .null:
            return nil
        case let .integer(int):
            switch T.self {
            case is Int64.Type: return int as? T
            case is Int.Type: return Int(int) as? T
            case is Int32.Type: return Int32(exactly: int) as? T
            case is Int16.Type: return Int16(exactly: int) as? T
            case is Int8.Type: return Int8(exactly: int) as? T
            case is UInt64.Type: return UInt64(exactly: int) as? T
            case is UInt32.Type: return UInt32(exactly: int) as? T
            case is UInt16.Type: return UInt16(exactly: int) as? T
            case is UInt8.Type: return UInt8(exactly: int) as? T
            case is Double.Type: return Double(int) as? T
            case is Float.Type: return Float(int) as? T
            case is Bool.Type: return (int != 0) as? T
            case is Date.Type: return Date(timeIntervalSince1970: TimeInterval(int)) as? T
            default: return nil
            }
        case let .real(double):
            switch T.self {
            case is Date.Type: return Date(timeIntervalSince1970: double) as? T
            case is Double.Type: return double as? T
            case is Float.Type: return Float(double) as? T
            default: return nil
            }
        case let .text(text):
            return text as? T
        case let .blob(data):
            return data as? T
        }
    }
}

public struct InsertionSuccess {
    public let rowID: Int64
    public let persistenceContainer: PersistenceContainer
}

open class Record {
    /// The row this record was fetched from, as GRDB 7 keeps it: changed columns are derived by
    /// comparing `encode(to:)` against this, and nothing else.
    public var referenceRow: Row?

    /// Neither initializer is `required`, matching GRDB: the app's `Profile` declares
    /// `required init(row: Row) throws` with `override` for the first, and provides no `init()` of
    /// its own for the second - both of which are only valid when the superclass declarations are
    /// non-required.
    public init() {}

    /// `required` and no `override` on the subclass side, which is what the app's
    /// `Profile` relies on when it writes `required init(row: Row) throws` alone.
    public required init(row: Row) throws {
        if row.isFetched {
            referenceRow = row.copy()
        }
    }

    open class var databaseTableName: String {
        fatalError("subclass must override")
    }

    open func encode(to container: inout PersistenceContainer) throws {}

    open func didInsert(_ inserted: InsertionSuccess) {}

    /// Column name to the value it held before the change, matching GRDB's own semantics.
    ///
    /// A column the encoded record has but the fetched row does not is treated as having held NULL,
    /// which is what the real `Row` reports for a column outside the `SELECT`: the two compare as
    /// different. Collapsing absent and NULL into the same value here would hide exactly the class
    /// of bug these tests exist to catch.
    public func databaseChanges() throws -> [String: DatabaseValue?] {
        let oldRow = referenceRow
        var changes: [String: DatabaseValue?] = [:]
        for (column, newValue) in try PersistenceContainer(self) {
            let oldValue: DatabaseValue = oldRow?[Column(column)] ?? .null
            if newValue != oldValue {
                changes[column] = oldValue
            }
        }
        return changes
    }

    public var hasDatabaseChanges: Bool {
        (try? databaseChanges().isEmpty == false) ?? true
    }
}
