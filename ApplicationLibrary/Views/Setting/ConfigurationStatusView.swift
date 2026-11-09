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
                id: "plan",
                label: String(localized: "Configuration Plan"),
                value: preview.localizedDescription
            ),
            ConfigurationStatusLine(
                id: "last-change",
                label: String(localized: "Last Apply"),
                value: lastChange.localizedDescription
            ),
        ]
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
}

extension ConfigurationDocumentProbe {
    var unavailableReason: String? {
        if case let .unavailable(reason) = self {
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
        }
    }
}

private func configurationRevision(_ revision: String) -> String {
    if revision.isEmpty {
        return ""
    }
    return revision.count > 12 ? String(revision.prefix(12)) : revision
}

extension ConfigurationPlan {
    var localizedDescription: String {
        if unchanged {
            let revision = configurationRevision(targetRevision ?? "")
            return revision.isEmpty
                ? String(localized: "The running service already runs this document")
                : String(localized: "The running service already runs revision \(revision)")
        }
        if started {
            return String(localized: "Applying this document starts a new instance")
        }
        if stale == true {
            return String(localized: "The running configuration changed while this plan was computed")
        }
        var reasons: [String] = []
        if changedDocument {
            reasons.append(String(localized: "the document differs outside the live domains"))
        }
        if let changedSections, !changedSections.isEmpty {
            reasons.append(changedSections.joined(separator: ", "))
        }
        if restartRequired {
            let detail = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
            return String(localized: "Applying restarts the service\(detail)")
        }
        if liveOnly {
            return String(localized: "Applying takes effect live, without a restart")
        }
        return String(localized: "Applying needs no restart")
    }
}

extension ConfigurationReport {
    var localizedDescription: String {
        var parts = [statusDescription]
        if retained {
            parts.append(String(localized: "the previous document is still running"))
        }
        if let activeRevision, !activeRevision.isEmpty {
            parts.append(String(localized: "active \(configurationRevision(activeRevision))"))
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
            return String(localized: "providers \(status)")
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
        return String(localized: "providers ") + entries.joined(separator: ", ")
    }
}

extension ConfigurationRecovery {
    var localizedDescription: String {
        String(
            localized:
                "Recovered at \(time): \(configurationRevision(failedRevision)) failed, now running \(configurationRevision(activeRevision)) - \(error)"
        )
    }
}

/// The official UI's rows for the three documents.
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
