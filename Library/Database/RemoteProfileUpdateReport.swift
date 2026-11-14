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
    /// The live Box is not the one this operation confirmed.
    case superseded
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
        case .applied:
            return report.providers.isFailure
                ? "The configuration is applied, but the remote providers could not be refreshed"
                : nil
        case .unchanged:
            return report.providers.isFailure
                ? "The configuration is unchanged, but the remote providers could not be refreshed"
                : nil
        case .saved:
            return report.providers.isFailure
                ? "The configuration is saved, but the remote providers could not be refreshed"
                : nil
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

    /// True when either half failed.
    ///
    /// The config half is not the whole update: a document can be applied and its remote providers
    /// still fail to refresh. Gating the alert on the config alone is how that failure became
    /// invisible, so the provider half is part of this answer now. A partial provider result is a
    /// warning, not a failure; `needsAttention` is what decides whether the user must be told.
    public var isFailure: Bool {
        configIsFailure || providers.isFailure
    }

    /// True when the user must be told something: a failure, an apply that was not confirmed or was
    /// superseded, a profile that was only saved for the next start, or a provider result that did
    /// not finish cleanly. A clean apply/unchanged plus a clean provider result is the only silent
    /// combination.
    public var needsAttention: Bool {
        switch config {
        case .applyFailed, .invalidConfig, .downloadFailed, .recovered, .interrupted,
             .applyUnconfirmed, .superseded, .saved:
            return true
        case .unchanged, .applied:
            return providers.needsAttention
        }
    }

    private var configIsFailure: Bool {
        switch config {
        case .applyFailed, .invalidConfig, .downloadFailed, .recovered, .interrupted:
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
        // A caller that can only say "threw or not" must not answer success while the provider
        // half failed; that is the same failure the structured UI has to show.
        if configIsFailure || providers.isFailure {
            return true
        }
        switch config {
        case .applyFailed, .invalidConfig, .downloadFailed, .recovered, .interrupted,
             .applyUnconfirmed, .superseded:
            return true
        case .unchanged, .saved, .applied:
            return false
        }
    }
}

public extension RemoteProviderRefreshSummary {
    /// True only for a refresh that failed outright. `partial` is a warning: some sources were
    /// published, but the update did not finish cleanly.
    var isFailure: Bool {
        switch status {
        case .failed, .unavailable:
            return true
        case .published, .unchanged, .partial, .busy, .cancelled, .boxChanged, .none,
             .notActive, .notRunning, .superseded, .unsupported, .skipped:
            return false
        }
    }

    /// True when the provider half is not a clean result. The skip statuses are deliberately absent:
    /// not being the active profile, not being connected, and losing the race to a newer operation
    /// are expected outcomes, not warnings the user must act on.
    var needsAttention: Bool {
        switch status {
        case .failed, .unavailable, .partial, .busy, .cancelled, .boxChanged, .superseded,
             .unsupported:
            return true
        case .published, .unchanged, .none, .notActive, .notRunning, .skipped:
            return false
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
    /// The running instance observed when prepare saw this profile selected; nil when it was not
    /// running then. Final apply uses it to distinguish "the old B" from a replacement Box.
    public let startedAtAtPrepare: Int64?

    public init(
        report: RemoteProfileUpdateReport,
        body: String?,
        startedAtAtPrepare: Int64? = nil
    ) {
        self.report = report
        self.body = body
        self.startedAtAtPrepare = startedAtAtPrepare
    }
}

/// The error a legacy caller gets for a structured failure it cannot present.
public struct RemoteProfileUpdateError: LocalizedError, Sendable {
    public let report: RemoteProfileUpdateReport

    public init(_ report: RemoteProfileUpdateReport) {
        self.report = report
    }

    /// Appended when the config half is clean but the provider half failed. This type cannot
    /// localize, but it must not answer with a sentence that contradicts its own legacy-failure
    /// decision.
    private var providerFailureSuffix: String {
        report.providers.isFailure ? "; the remote providers could not be refreshed" : ""
    }

    public var errorDescription: String? {
        switch report.config {
        case .unchanged:
            return "Configuration unchanged\(providerFailureSuffix)"
        case .saved:
            return "Configuration saved; it applies on the next start\(providerFailureSuffix)"
        case .applied:
            return "Configuration applied\(providerFailureSuffix)"
        case let .applyFailed(message):
            return message.map { "Configuration apply failed: \($0)" } ?? "Configuration apply failed"
        case .applyUnconfirmed:
            return "Configuration apply was not confirmed"
        case let .invalidConfig(message):
            return message.map { "Configuration rejected: \($0)" } ?? "Configuration rejected"
        case let .downloadFailed(message):
            return message.map { "Subscription download failed: \($0)" } ?? "Subscription download failed"
        case let .recovered(activeRevision):
            return activeRevision.map { "Service recovered to an earlier configuration (\($0))" }
                ?? "Service recovered to an earlier configuration"
        case let .interrupted(reason):
            return reason.map { "The service stopped and nothing is running: \($0)" }
                ?? "The service stopped and nothing is running"
        case .superseded:
            return "Update superseded by a newer action"
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
        case .superseded:
            RemoteProviderRefreshSummary(status: .superseded, counts: .init(), detail: nil)
        case .unsupported:
            RemoteProviderRefreshSummary(status: .unsupported, counts: .init(), detail: nil)
        case let .failed(message):
            RemoteProviderRefreshSummary(status: .unavailable, counts: .init(), detail: message)
        case let .skipped(reason):
            RemoteProviderRefreshSummary(status: .skipped, counts: .init(), detail: reason.rawValue)
        }
    }
}
