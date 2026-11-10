import Foundation

/// What one remote-profile update did to the configuration.
public enum RemoteConfigUpdateOutcome: Equatable, Sendable {
    /// The fetched body is byte-identical to the stored one; no reload was requested.
    case unchanged
    /// The body changed but the profile is not the running/selected one; it applies on next start.
    case saved
    /// The body changed and the daemon confirmed a new startedAt for the running instance.
    case applied
    /// The reload failed; the previous document is still on disk.
    case applyFailed(String?)
    /// The reload returned but the daemon did not confirm a new instance.
    case applyUnconfirmed
    /// The body downloaded but was refused by static validation; the stored body was kept.
    case invalidConfig(String?)
    case downloadFailed(String?)
    /// Another action replaced the profile/instance while this update was in flight.
    case superseded
}

/// Why the provider half has (or has not) a report.
public enum RemoteProviderRefreshProbe: Equatable, Sendable {
    case response(String)
    case notActive
    case notRunning
    /// The live Box is not the one this operation confirmed.
    case superseded
    case unsupported
    case failed(String)
}

/// The two halves of one update, as one value.
public struct RemoteProfileUpdateReport: Equatable, Sendable {
    public let config: RemoteConfigUpdateOutcome
    public let providers: RemoteProviderRefreshSummary

    public init(config: RemoteConfigUpdateOutcome, providers: RemoteProviderRefreshSummary) {
        self.config = config
        self.providers = providers
    }

    /// True when the user must not read this as a clean update.
    public var isFailure: Bool {
        switch config {
        case .applyFailed, .invalidConfig, .downloadFailed:
            true
        case .unchanged, .saved, .applied, .applyUnconfirmed, .superseded:
            false
        }
    }

    /// The stricter contract of the legacy `async throws` entry points.
    ///
    /// Those callers have no way to show a structured report: a superseded or unconfirmed apply
    /// used to look exactly like success, which is how the edit page sent its refresh notification
    /// and the shortcut returned `true` after a failed download. They must see those outcomes as
    /// errors; the reporting API keeps them as values.
    public var isLegacyFailure: Bool {
        switch config {
        case .applyFailed, .invalidConfig, .downloadFailed, .applyUnconfirmed, .superseded:
            true
        case .unchanged, .saved, .applied:
            false
        }
    }
}

/// A body that has been saved but deliberately not applied yet.
///
/// Batch update saves every subscription first and then applies only the profile that is still
/// selected. [body] is the exact bytes the prepare step stored, so the apply step can refuse to
/// reload a document another writer replaced in between.
public struct PreparedRemoteProfileUpdate: Sendable {
    public let report: RemoteProfileUpdateReport
    public let body: String?

    public init(report: RemoteProfileUpdateReport, body: String?) {
        self.report = report
        self.body = body
    }
}

/// The error a legacy caller gets for a structured failure it cannot present.
public struct RemoteProfileUpdateError: LocalizedError, Sendable {
    public let report: RemoteProfileUpdateReport

    public init(_ report: RemoteProfileUpdateReport) {
        self.report = report
    }

    public var errorDescription: String? {
        switch report.config {
        case .unchanged:
            return "Configuration unchanged"
        case .saved:
            return "Configuration saved; it applies on the next start"
        case .applied:
            return "Configuration applied"
        case let .applyFailed(message):
            return message.map { "Configuration apply failed: \($0)" } ?? "Configuration apply failed"
        case .applyUnconfirmed:
            return "Configuration apply was not confirmed"
        case let .invalidConfig(message):
            return message.map { "Configuration rejected: \($0)" } ?? "Configuration rejected"
        case let .downloadFailed(message):
            return message.map { "Subscription download failed: \($0)" } ?? "Subscription download failed"
        case .superseded:
            return "Update superseded by a newer action"
        }
    }
}

extension RemoteProviderRefreshProbe {
    /// Maps the probe into the provider half. `nil`/malformed JSON is `unavailable`, never a
    /// silent "no providers".
    public var summary: RemoteProviderRefreshSummary {
        switch self {
        case let .response(json):
            RemoteProviderRefreshParser.summarize(json: json)
        case .notActive:
            RemoteProviderRefreshSummary(status: .notActive, counts: .init(), detail: nil)
        case .notRunning:
            RemoteProviderRefreshSummary(status: .notRunning, counts: .init(), detail: nil)
        case .superseded:
            RemoteProviderRefreshSummary(status: .superseded, counts: .init(), detail: nil)
        case .unsupported:
            RemoteProviderRefreshSummary(status: .unsupported, counts: .init(), detail: nil)
        case let .failed(message):
            RemoteProviderRefreshSummary(status: .unavailable, counts: .init(), detail: message)
        }
    }
}
