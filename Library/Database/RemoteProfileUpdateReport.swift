import Foundation

/// What one remote-profile update did to the configuration.
public enum RemoteConfigUpdateOutcome: Equatable, Sendable {
    /// The fetched body is byte-identical to the stored one; no reload was requested.
    case unchanged
    /// The body changed but the profile is not the running/selected one; it applies on next start.
    case saved
    /// The body changed and the daemon confirmed it is the document running now.
    case applied
    /// The reload failed; the previous document is still on disk and still serving.
    case applyFailed(String?)
    /// The reload returned but nothing confirmed which document runs. Never treated as failure, and
    /// never retried automatically: the operation's commit point has already passed.
    case applyUnconfirmed
    /// The body downloaded but was refused by static validation; the stored body was kept.
    case invalidConfig(String?)
    case downloadFailed(String?)
    /// Another action replaced the profile/instance while this update was in flight.
    case superseded
    /// The requested document failed and the daemon is now running the stored last-good one. The
    /// service is up; what runs is not what was asked for. Kept apart from `applyFailed` because a
    /// recovery is a working service with a different document, and because the revision that runs
    /// is known.
    case recovered(activeRevision: String?)
    /// The attempt left nothing running: the previous document was closed and no candidate replaced
    /// it. This is the one outcome in which the user has no service at all.
    case interrupted(reason: String?)
}

/// Why the provider half has (or has not) a report.
public enum RemoteProviderRefreshProbe: Equatable, Sendable {
    case response(String)
    case notActive
    case notRunning
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
        case .applyFailed, .invalidConfig, .downloadFailed, .recovered, .interrupted:
            true
        case .unchanged, .saved, .applied, .applyUnconfirmed, .superseded:
            false
        }
    }
}

public extension ExtensionApplyOutcome {
    /// This outcome in the update report's vocabulary.
    ///
    /// One mapping, used by both readers of a receipt: the applier, which is reporting on an attempt
    /// it just made, and the profile path, which first has to establish that the receipt belongs to
    /// its update. Two mappings would eventually disagree about what a recovery means.
    var configOutcome: RemoteConfigUpdateOutcome {
        switch self {
        case .applied:
            return .applied
        case let .recovered(activeRevision):
            return .recovered(activeRevision: activeRevision)
        case .interrupted:
            return .interrupted(reason: nil)
        case let .failed(reason, retained):
            // Retention is a separate fact and it has three values. `true` is a failure that kept
            // the previous document serving; `false` is the one case that took the service down;
            // `nil` is "nobody established it", which must not be reported as "the tunnel stopped".
            switch retained {
            case .some(false):
                return .interrupted(reason: reason)
            case .some(true), .none:
                return .applyFailed(reason)
            }
        case .undetermined:
            return .applyUnconfirmed
        }
    }
}

public extension ExtensionApplyReceipt {
    /// What this receipt reports about ONE update, once ownership is established.
    ///
    /// The receipt is the app's only strong answer: an apply that recovered or was interrupted
    /// returns no error, so the outcome has to come from the document the extension sent back. The
    /// ownership rules live in `ProfileUpdateOwnership` - a receipt that does not name this request,
    /// this profile and this body is `superseded`, because the update that owns the newer state is
    /// the one whose answer matters.
    func configOutcome(ticket: ProfileUpdateTicket, expectedBodyRevision: String?) -> RemoteConfigUpdateOutcome {
        switch ProfileUpdateOwnership.ownership(of: self, ticket: ticket, expectedBodyRevision: expectedBodyRevision) {
        case .notThisUpdate:
            return .superseded
        case .unconfirmed:
            return .applyUnconfirmed
        case .matches:
            return outcome.configOutcome
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
        case .unsupported:
            RemoteProviderRefreshSummary(status: .unsupported, counts: .init(), detail: nil)
        case let .failed(message):
            RemoteProviderRefreshSummary(status: .unavailable, counts: .init(), detail: message)
        }
    }
}
