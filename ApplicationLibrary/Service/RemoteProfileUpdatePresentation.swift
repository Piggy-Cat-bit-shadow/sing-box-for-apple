import Foundation
import Library

/// User-facing text for the two halves of a remote update.
///
/// Kept in the app layer rather than the model: `RemoteProfileUpdateReport` must stay compilable
/// and testable without a UI (the SwiftPM package compiles it on its own), and `String(localized:)`
/// is a Darwin convenience the model does not need. The existing error alert is the only consumer.
extension RemoteProfileUpdateReport {
    var localizedDescription: String {
        "\(configLocalizedDescription) · \(providers.localizedDescription)"
    }

    private var configLocalizedDescription: String {
        switch config {
        case .unchanged:
            return String(localized: "Configuration unchanged")
        case .saved:
            return String(localized: "Configuration saved; it applies on the next start")
        case .applied:
            return String(localized: "Configuration applied")
        case let .applyFailed(message):
            return message.map { String(localized: "Configuration apply failed: \($0)") }
                ?? String(localized: "Configuration apply failed")
        case .applyUnconfirmed:
            return String(localized: "Configuration apply was not confirmed")
        case let .invalidConfig(message):
            return message.map { String(localized: "Configuration rejected: \($0)") }
                ?? String(localized: "Configuration rejected")
        case let .downloadFailed(message):
            return message.map { String(localized: "Subscription download failed: \($0)") }
                ?? String(localized: "Subscription download failed")
        case .superseded:
            return String(localized: "Update superseded by a newer action")
        case .recovered:
            // The service is running - just not this document. Saying "failed" sends the user
            // looking for a dead tunnel; saying "applied" hides that their profile is not in force.
            // The revision is deliberately left out: it identifies the document for diagnostics,
            // not for the person deciding whether the update worked.
            return String(localized: "The new configuration failed; the service recovered to the saved one")
        case let .interrupted(message):
            return message.map { String(localized: "The tunnel stopped and nothing is running: \($0)") }
                ?? String(localized: "The tunnel stopped and nothing is running")
        }
    }
}

/// The existing error alert's payload for a whole report.
///
/// `RemoteProfileUpdateError` lives in the framework and can only describe the config half in
/// plain English. The app's alert already has a localized two-half sentence, so it wraps the report
/// rather than re-deriving one error from one enum case.
struct RemoteProfileUpdateAlertError: LocalizedError {
    let report: RemoteProfileUpdateReport

    var errorDescription: String? {
        report.localizedDescription
    }
}

extension RemoteProviderRefreshSummary {
    var localizedDescription: String {
        switch status {
        case .published:
            // Only meaningful non-zero counts: "1 published, 0 unchanged" is noise, not a result.
            if counts.unchanged > 0 {
                return String(localized: "Providers: \(counts.published) published, \(counts.unchanged) unchanged")
            }
            return String(localized: "Providers: \(counts.published) published")
        case .unchanged:
            return String(localized: "Providers unchanged")
        case .partial:
            // A partial result can also contain outright failures. Folding them into "partial"
            // without saying so is how a failed source disappeared behind a pending one.
            var parts: [String] = []
            if counts.pendingTags > 0 {
                parts.append(String(localized: "\(counts.pendingTags) pending"))
            }
            if counts.restartRequired > 0 {
                parts.append(String(localized: "\(counts.restartRequired) need a restart"))
            }
            if counts.failed > 0 {
                parts.append(String(localized: "\(counts.failed) failed"))
            }
            guard !parts.isEmpty else {
                return String(localized: "Providers partly applied")
            }
            return String(localized: "Providers partly applied: \(parts.joined(separator: ", "))")
        case .failed:
            if let detail {
                return String(localized: "Provider refresh failed: \(detail)")
            }
            if counts.total > 0 {
                return String(localized: "Provider refresh failed: \(counts.failed) of \(counts.total)")
            }
            return String(localized: "Provider refresh failed")
        case .busy:
            return String(localized: "Provider refresh did not run: another refresh is in progress")
        case .cancelled:
            return String(localized: "Provider refresh was cancelled")
        case .boxChanged:
            return String(localized: "Provider refresh did not finish: the running instance changed")
        case .none:
            return String(localized: "The running configuration has no remote providers")
        case .notActive:
            return String(localized: "Providers not refreshed: this profile is not active")
        case .notRunning:
            return String(localized: "Providers not refreshed: the service is not running")
        case .superseded:
            return String(localized: "Providers not refreshed: a newer operation replaced this update")
        case .unsupported:
            return String(localized: "Providers not refreshed: the running service does not support this refresh")
        case .unavailable:
            return detail.map { String(localized: "Provider refresh unavailable: \($0)") }
                ?? String(localized: "Provider refresh unavailable")
        case .skipped:
            // `detail` is the skip cause's raw value. Showing it directly leaked a camelCase enum
            // token into an alert; translate each cause into a sentence instead.
            guard let detail, let reason = ProviderRefreshSkip(rawValue: detail) else {
                return String(localized: "Providers not refreshed")
            }
            switch reason {
            case .superseded:
                return String(localized: "Providers not refreshed: a newer operation replaced this update")
            case .notRunningThisProfile:
                return String(localized: "Providers not refreshed: this profile is not active")
            case .notApplied:
                return String(localized: "Providers not refreshed: the new configuration was not applied")
            }
        }
    }
}
