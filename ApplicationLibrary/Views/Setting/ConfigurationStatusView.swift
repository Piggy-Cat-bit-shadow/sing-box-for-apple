import Foundation
import Library
import SwiftUI

/// One labelled fact about the running configuration.
struct ConfigurationStatusLine: Identifiable {
    let id: String
    let label: String
    let value: String
}

/// Reads the daemon's configuration documents once per appearance.
///
/// The read is a set of blocking Libbox calls, so it happens in a `Task` and the view renders a
/// placeholder until it lands; nothing here may run on the main thread.
@MainActor
final class ConfigurationStatusModel: ObservableObject {
    @Published private(set) var lines: [ConfigurationStatusLine] = []
    @Published private(set) var loading = true

    private var started = false

    func load() async {
        guard !started else {
            return
        }
        started = true
        lines = await ConfigurationStatusProbe.load().lines
        loading = false
    }
}

/// The three documents as user-facing lines.
///
/// `absent` and `unsupported` say different things on purpose: the first means nothing has happened
/// yet on this instance, the second that this kernel cannot answer. A recovery is the only one of
/// the three that is shown as a warning even when nothing failed now - it means the service is
/// running a document the user did not ask for.
extension ConfigurationStatus {
    var lines: [ConfigurationStatusLine] {
        var lines = [
            ConfigurationStatusLine(
                id: "source",
                label: String(localized: "Reading"),
                value: sourceDescription
            ),
        ]
        if targetChanged {
            // The one state where the three rows below are NOT the answer: the session moved between
            // capturing the target and asking for its client, so the page says that instead of
            // describing a daemon the user has left.
            lines.append(
                ConfigurationStatusLine(
                    id: "target-changed",
                    label: String(localized: "Reading"),
                    value: String(localized: "The target changed while this page was opening; nothing was read.")
                )
            )
            return lines
        }
        lines.append(contentsOf: [
            ConfigurationStatusLine(
                id: "plan",
                label: String(localized: "Configuration Plan"),
                value: preview.localizedDescription
            ),
            ConfigurationStatusLine(
                id: "last-change",
                label: String(localized: "Last Apply"),
                value: lastChange.localizedDescription
            ),
        ])
        if let recovery = lastRecovery.localizedDescription {
            lines.append(
                ConfigurationStatusLine(
                    id: "recovery",
                    label: String(localized: "Recovery"),
                    value: recovery
                )
            )
        }
        return lines
    }

    /// Which daemon every row above came from.
    ///
    /// A page that can render a plan and a report has to say whether they describe this device's
    /// tunnel or a remote server: the same sentence means something else about another machine, and
    /// the two can be on screen together only by being wrong.
    var sourceDescription: String {
        switch source.kind {
        case .localTunnel:
            return String(localized: "this device's tunnel")
        case .remoteSession:
            if let label = source.remoteLabel, !label.isEmpty {
                return String(localized: "the remote server \(label)")
            }
            return String(localized: "a remote server")
        }
    }
}

extension ConfigurationDocumentProbe {
    var unavailableReason: String? {
        if case let .unavailable(reason) = self {
            return reason
        }
        return nil
    }

    var notApplicableReason: String? {
        if case let .notApplicable(reason) = self {
            return reason
        }
        return nil
    }
}

extension ConfigurationDocumentProbe where Value == ConfigurationPlan {
    var localizedDescription: String {
        switch self {
        case let .document(plan):
            return plan.localizedDescription
        case .absent:
            return String(localized: "No plan for this document yet")
        case .unsupported:
            return String(localized: "This kernel cannot preview a configuration")
        case let .unavailable(reason):
            return String(localized: "Preview unavailable: \(reason)")
        case let .notApplicable(reason):
            return reason
        }
    }
}

extension ConfigurationDocumentProbe where Value == ConfigurationReport {
    var localizedDescription: String {
        switch self {
        case let .document(report):
            return report.localizedDescription
        case .absent:
            return String(localized: "This instance has not applied a configuration yet")
        case .unsupported:
            return String(localized: "This kernel cannot report the last apply")
        case let .unavailable(reason):
            return String(localized: "Last apply unavailable: \(reason)")
        case let .notApplicable(reason):
            return reason
        }
    }
}

extension ConfigurationDocumentProbe where Value == ConfigurationRecovery {
    /// `nil` when the last start was normal: a missing recovery is not a fact worth a row.
    var localizedDescription: String? {
        switch self {
        case let .document(recovery):
            return recovery.localizedDescription
        case .absent:
            return nil
        case .unsupported:
            return String(localized: "This kernel cannot report a recovery")
        case let .unavailable(reason):
            return String(localized: "Recovery unavailable: \(reason)")
        case let .notApplicable(reason):
            return reason
        }
    }
}

/// The revisions a plan moves between, or nil when the plan carries none.
private func configurationVersionPair(current: String?, target: String?) -> String? {
    let from = configurationRevisionLabel(current)
    let to = configurationRevisionLabel(target)
    switch (from.isEmpty, to.isEmpty) {
    case (true, true):
        return nil
    case (false, true):
        return from
    case (true, false):
        return to
    case (false, false):
        return "\(from) → \(to)"
    }
}

/// The plan's sentence is chosen by `ConfigurationPlan.verdict`, which is the one place the
/// `started` semantics are decided. This extension only renders: an inline revision pair or the
/// restart reasons, when the verdict carries them.
extension ConfigurationPlan {
    var localizedDescription: String {
        switch verdict {
        case let .unchanged(target):
            let revision = configurationRevisionLabel(target)
            return revision.isEmpty
                ? String(localized: "The running service already runs this document")
                : String(localized: "The running service already runs revision \(revision)")
        case .stale:
            return String(localized: "The plan is stale: the running configuration changed since it was computed")
        case let .firstStart(target):
            let revision = configurationRevisionLabel(target)
            return revision.isEmpty
                ? String(localized: "Applying this document starts a new instance")
                : String(localized: "Applying this document starts a new instance (target revision \(revision))")
        case let .restartRequired(current, target, reasons):
            // The reasons are appended outside the localized sentence so the catalog key has one
            // placeholder, not one per interpolated fragment.
            let detail = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
            if let versions = configurationVersionPair(current: current, target: target) {
                return String(localized: "Applying this document restarts the service (\(versions))") + detail
            }
            return String(localized: "Applying this document restarts the service") + detail
        case let .liveApply(current, target):
            if let versions = configurationVersionPair(current: current, target: target) {
                return String(localized: "Applying this document takes effect live, without restarting (\(versions))")
            }
            return String(localized: "Applying this document takes effect live, without restarting")
        case let .needsNoRestart(current, target):
            if let versions = configurationVersionPair(current: current, target: target) {
                return String(localized: "Applying this document needs no restart (\(versions))")
            }
            return String(localized: "Applying this document needs no restart")
        }
    }
}

extension ConfigurationReport {
    var localizedDescription: String {
        var parts = [statusDescription]
        if retained {
            parts.append(String(localized: "the previous document is still running"))
        }
        let active = configurationRevisionLabel(activeRevision)
        if !active.isEmpty {
            parts.append(String(localized: "active \(active)"))
        }
        if persistence == "degraded" {
            parts.append(String(localized: "the last-good store is degraded"))
        } else if persistence == "not_configured" {
            parts.append(String(localized: "no last-good store"))
        }
        if let provider {
            parts.append(provider.localizedDescription)
        }
        return parts.joined(separator: " · ")
    }

    private var statusDescription: String {
        switch status {
        case "started":
            return String(localized: "started")
        case "unchanged":
            return String(localized: "unchanged")
        case "applied_live":
            return String(localized: "applied live")
        case "restarted":
            return String(localized: "restarted")
        case "recovered":
            return String(localized: "recovered to the previous document")
        case "interrupted":
            return String(localized: "interrupted; nothing is running")
        case "failed":
            return String(localized: "failed")
        default:
            return status
        }
    }
}

extension ConfigurationProviderReport {
    var localizedDescription: String {
        guard let results, !results.isEmpty else {
            return String(localized: "providers: \(status)")
        }
        let entries = results.map { result -> String in
            var detail = "\(result.tag): \(result.status)"
            if let pending = result.pendingTags, !pending.isEmpty {
                detail += " (\(pending.count) pending)"
            }
            if result.restartRequired == true {
                detail += " (restart required)"
            }
            return detail
        }
        return String(localized: "providers: \(entries.joined(separator: ", "))")
    }
}

extension ConfigurationRecovery {
    var localizedDescription: String {
        String(
            localized:
                "Recovered at \(time): \(configurationRevisionLabel(failedRevision)) failed, now running \(configurationRevisionLabel(activeRevision)) - \(error)"
        )
    }
}

/// The official UI's rows for the three documents.
///
/// `@MainActor` because the state object it creates is main-actor isolated: a View's body is main
/// actor, but the stored property's initializer is not, and a Swift 6 language mode build treats
/// that difference as an error rather than a warning.
@MainActor
struct ConfigurationStatusRows: View {
    @StateObject private var model = ConfigurationStatusModel()

    var body: some View {
        Group {
            if model.loading {
                HStack {
                    Text(String(localized: "Configuration"))
                    Spacer()
                    ProgressView()
                }
            } else {
                ForEach(model.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.label)
                        Spacer()
                        Text(line.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .task {
            await model.load()
        }
    }
}
