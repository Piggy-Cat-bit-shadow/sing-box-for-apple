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
    /// Not attempted because this update lost ownership of the profile: the winner owns the refresh.
    case skipped(ProviderRefreshSkip)
}

/// Why a refresh left the provider half alone.
public enum ProviderRefreshSkip: String, Equatable, Sendable {
    /// Another update committed the same profile first.
    case superseded
    /// The body was saved, but the running instance serves a different profile.
    case notRunningThisProfile
    /// The document did not reach the running service: the instance is not serving this update's body,
    /// so its providers are not this update's to refresh.
    case notApplied
}

/// An update that did not end with the running service using the new configuration.
///
/// It lives in the database layer, not in the app's presentation layer, because the wrapper the
/// shortcuts call is there: `Profile.updateRemoteProfile()` can only say "throw or not", and it must
/// say it from the framework that owns the update. The app's `RemoteProfileUpdateError` remains the
/// type its own UI entries throw, because that one carries the full presentation.
public struct ProfileUpdateFailure: LocalizedError, Equatable {
    public let report: RemoteProfileUpdateReport

    public init(report: RemoteProfileUpdateReport) {
        self.report = report
    }

    /// Plain sentences on purpose: this type is compiled by the contract package as well, where
    /// `String(localized:)` is unavailable. The app's own entries present the localized wording.
    public var errorDescription: String? {
        switch report.config {
        case .applied, .unchanged, .saved:
            return nil
        case let .applyFailed(reason):
            return reason ?? "The configuration could not be applied"
        case let .invalidConfig(reason):
            return reason ?? "The downloaded configuration is not valid"
        case let .downloadFailed(reason):
            return reason ?? "The subscription could not be downloaded"
        case let .recovered(activeRevision):
            return activeRevision.map { "The service recovered to an earlier configuration (\($0))" }
                ?? "The service recovered to an earlier configuration"
        case let .interrupted(reason):
            return reason ?? "The service stopped and nothing is running"
        case .superseded:
            return "A newer update replaced this one before it was applied"
        case .applyUnconfirmed:
            return "The extension did not confirm the configuration"
        }
    }
}

/// Whether an update may touch the running instance's providers.
///
/// # Why this is a policy and not four `if`s
///
/// Refreshing providers is a live side effect: one HTTP request per provider, and the resulting nodes
/// are published. It belongs to exactly one outcome - the update whose document reached the running
/// service. Every other outcome means the instance is serving something else, so the side effect would
/// be attached to a claim the update does not own.
///
/// The first version of that rule lived only in `RemoteRefreshApplier`'s final branch, and the profile
/// path kept refreshing on its own three failure branches (invalid configuration, failed download,
/// lost metadata commit) - the same side effect, reached around the guard. One function, called by
/// every branch, is what keeps the next caller from reintroducing it.
public enum ProviderRefreshPolicy {
    public static func decision(for config: RemoteConfigUpdateOutcome) -> ProviderRefreshDecision {
        switch config {
        case .applied, .unchanged:
            // .unchanged is a successful refresh that carried no new body (304, or a metadata-only
            // update): the running instance IS the one this profile describes, so its providers are
            // this update's to refresh.
            return .refresh
        case .saved:
            // Saved, but the running instance serves a different profile.
            return .skip(.notRunningThisProfile)
        case .superseded:
            return .skip(.superseded)
        case .applyFailed, .invalidConfig, .downloadFailed, .recovered, .interrupted, .applyUnconfirmed:
            return .skip(.notApplied)
        }
    }

    /// The probe to report when the policy says "do not refresh", or nil when the refresh must run.
    public static func skippedProbe(for config: RemoteConfigUpdateOutcome) -> RemoteProviderRefreshProbe? {
        switch decision(for: config) {
        case .refresh:
            return nil
        case let .skip(reason):
            return .skipped(reason)
        }
    }
}

/// See `ProviderRefreshPolicy`.
public enum ProviderRefreshDecision: Equatable, Sendable {
    case refresh
    case skip(ProviderRefreshSkip)
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
        case let .skipped(reason):
            RemoteProviderRefreshSummary(status: .skipped, counts: .init(), detail: reason.rawValue)
        }
    }
}
