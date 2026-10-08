import Foundation

// The two symbols `Profile.onProfileUpdated()` names. In the app the first is GRDB-backed
// preferences and the second drives the tunnel; both are inert here, because a refresh test asserts
// that the reload path was *not* reached rather than that it worked.

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
    public enum Status {
        case connected
        case disconnected
    }

    public var status: Status = .disconnected

    public static func load() async throws -> ExtensionProfile? {
        nil
    }

    public func reloadService() async throws {}
}
