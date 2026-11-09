import Foundation
import Library

/// User-facing text for the two halves of a remote update.
///
/// Kept in the app layer rather than the model: `RemoteProfileUpdateReport` must stay compilable
/// and testable without a UI (the SwiftPM package compiles it on its own), and `String(localized:)`
/// is a Darwin convenience the model does not need. The existing error alert is the only consumer.
extension RemoteProfileUpdateReport {
    var localizedDescription: String {
        let configText: String
        switch config {
        case .unchanged:
            configText = String(localized: "Configuration unchanged")
        case .saved:
            configText = String(localized: "Configuration saved; it applies on the next start")
        case .applied:
            configText = String(localized: "Configuration applied")
        case let .applyFailed(message):
            configText = message.map { String(localized: "Configuration apply failed: \($0)") }
                ?? String(localized: "Configuration apply failed")
        case .applyUnconfirmed:
            configText = String(localized: "Configuration apply was not confirmed")
        case let .invalidConfig(message):
            configText = message.map { String(localized: "Configuration rejected: \($0)") }
                ?? String(localized: "Configuration rejected")
        case let .downloadFailed(message):
            configText = message.map { String(localized: "Subscription download failed: \($0)") }
                ?? String(localized: "Subscription download failed")
        case .superseded:
            configText = String(localized: "Update superseded by a newer action")
        }
        return "\(configText) · \(providers.localizedDescription)"
    }
}

struct RemoteProfileUpdateError: LocalizedError {
    let report: RemoteProfileUpdateReport

    init(_ report: RemoteProfileUpdateReport) {
        self.report = report
    }

    var errorDescription: String? {
        report.localizedDescription
    }
}

extension RemoteProviderRefreshSummary {
    var localizedDescription: String {
        switch status {
        case .published:
            String(localized: "Providers: \(counts.published) published, \(counts.unchanged) unchanged")
        case .unchanged:
            String(localized: "Providers unchanged")
        case .partial:
            String(
                localized: "Providers partly applied: \(counts.pendingTags) pending, \(counts.restartRequired) need a restart"
            )
        case .failed:
            detail.map { String(localized: "Provider refresh failed: \($0)") }
                ?? String(localized: "Provider refresh failed: \(counts.failed) of \(counts.total)")
        case .busy:
            String(localized: "Providers busy; the refresh did not run")
        case .cancelled:
            String(localized: "Provider refresh cancelled")
        case .boxChanged:
            String(localized: "Provider refresh crossed two Box instances")
        case .none:
            String(localized: "The running configuration has no remote providers")
        case .notActive:
            String(localized: "Providers not refreshed: the profile is not active")
        case .notRunning:
            String(localized: "Providers not refreshed: not connected")
        case .unsupported:
            String(localized: "Providers not refreshed: the kernel predates the provider refresh RPC")
        case .unavailable:
            detail.map { String(localized: "Provider refresh unavailable: \($0)") }
                ?? String(localized: "Provider refresh unavailable")
        }
    }
}
