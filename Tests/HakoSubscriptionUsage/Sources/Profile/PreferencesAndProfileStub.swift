import Core
import Foundation

// The two symbols `Profile.onProfileUpdated()` names. In the app the first is GRDB-backed
// preferences and the second drives the tunnel; both are inert here, because a refresh test asserts
// that the reload path was *not* reached rather than that it worked.
//
// The shapes have to match the shipping ones exactly, because `Profile+Update.swift` is compiled
// from the shipping file: `ExtensionProfile.StartSnapshot` is what an apply request is, and the
// receipt it answers with is the domain type, not a second definition of it.

public enum SharedPreferences {
    /// Never matches a real profile id, so `onProfileUpdated()` finds nothing selected and returns.
    public static let selectedProfileID = InertPreference<Int64>(defaultValue: -1)
}

public struct InertPreference<Value> {
    private let defaultValue: Value

    public init(defaultValue: Value) {
        self.defaultValue = defaultValue
    }

    public func get() async -> Value {
        defaultValue
    }

    public func set(_ value: Value) async {}
}

public final class ExtensionProfile: @unchecked Sendable {
    public struct StartSnapshot: Equatable, Sendable {
        public let profileID: Int64
        public let requestID: String
        public let bodyRevision: String
        public let configContent: String

        public init(profileID: Int64, requestID: String, bodyRevision: String, configContent: String) {
            self.profileID = profileID
            self.requestID = requestID
            self.bodyRevision = bodyRevision
            self.configContent = configContent
        }
    }

    public enum Status {
        case connected
        case disconnected
    }

    public var status: Status = .disconnected

    public static func load() async throws -> ExtensionProfile? {
        nil
    }

    /// Never answers with a receipt: the tests that reach this path are asserting that the reload
    /// was not needed, and a receipt here would let a test read "applied" from a tunnel that does
    /// not exist.
    public func reloadService(_ snapshot: StartSnapshot) async throws -> ExtensionApplyReceipt? {
        _ = snapshot
        return nil
    }
}
