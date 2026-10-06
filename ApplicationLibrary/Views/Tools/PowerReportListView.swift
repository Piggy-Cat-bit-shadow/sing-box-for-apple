import Library
import SwiftUI

@MainActor
public struct PowerReportListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var powerReportEnabled = false
    @State private var alert: AlertState?
    #if os(tvOS)
        @State private var selectedReport: PowerReport?
    #endif

    public init() {}

    private var manager: PowerReportManager {
        environments.powerReportManager
    }

    public var body: some View {
        HakoReportScaffold(title: String(localized: "Power Report")) {
            if !isLoading {
                HakoSettingsSection(
                    footnote: "Record a report for each service run."
                ) {
                    HakoToggleRow(
                        String(localized: "Enable Power Report"),
                        isOn: $powerReportEnabled,
                        tightensVerticalPadding: true
                    ) { newValue in
                        Task {
                            await SharedPreferences.powerReportEnabled.set(newValue)
                            await restartService()
                        }
                    }
                }

                HakoSettingsSection("Reports", footnote: "A report is saved for each service run.") {
                    if manager.reports.isEmpty {
                        HakoCardEmptyState(
                            symbol: "battery.50percent",
                            title: "No power reports",
                            message: "A report is recorded for each service run."
                        )
                        .frame(minHeight: 180)
                    } else {
                        ForEach(manager.reports) { report in
                            #if os(tvOS)
                                Button {
                                    selectedReport = report
                                } label: {
                                    reportLabel(report)
                                }
                            #else
                                FormNavigationLink {
                                    PowerReportDetailView(report: report)
                                } label: {
                                    reportLabel(report)
                                }
                                // The report's own identifier, as the crash list's rows have:
                                // a test can address the row rather than guess at it by position.
                                .accessibilityIdentifier("hako.report.\(report.id)")
                            #endif
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .onAppear {
            Task {
                await manager.refresh()
                powerReportEnabled = await SharedPreferences.powerReportEnabled.get()
                isLoading = false
            }
        }
        .alert($alert)
        #if os(tvOS)
            .navigationDestination(item: $selectedReport) { report in
                PowerReportDetailView(report: report)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            BackButton()
                        }
                    }
            }
        #endif
            .toolbar {
                #if os(tvOS)
                    ToolbarItem(placement: .confirmationAction) {
                        PowerReportDeleteButton(manager: manager)
                    }
                #else
                    ToolbarItem {
                        PowerReportToolbarMenu(manager: manager)
                    }
                #endif
            }
    }

    private func reportLabel(_ report: PowerReport) -> some View {
        #if os(tvOS)
            ReportLabel(date: report.date, isRead: report.isRead, origin: report.origin)
        #else
            HakoNavigationRow(
                title: report.date.formatted(date: .abbreviated, time: .shortened),
                subtitle: report.origin == ReportArchive.tvOSDeviceOrigin
                    ? String(localized: "From Apple TV")
                    : String(localized: "From this device"),
                systemImage: "battery.50percent",
                tint: HakoAccentRole.neutral.color,
                badge: report.isRead ? nil : String(localized: "Unread"),
                badgeEmphasis: .info
            )
        #endif
    }

    private func restartService() async {
        guard let profile = environments.extensionProfile, profile.status.isConnected else {
            return
        }
        do {
            try await profile.restart()
        } catch {
            alert = AlertState(action: "restart service", error: error)
        }
    }
}

#if os(tvOS)
    private struct PowerReportDeleteButton: View {
        @ObservedObject var manager: PowerReportManager

        var body: some View {
            if !manager.reports.isEmpty {
                Button {
                    Task {
                        await manager.deleteAll()
                    }
                } label: {
                    Image(systemName: "trash.fill")
                }
                .tint(.red)
            }
        }
    }
#else
    private struct PowerReportToolbarMenu: View {
        @ObservedObject var manager: PowerReportManager

        var body: some View {
            if !manager.reports.isEmpty {
                Menu {
                    Button(role: .destructive) {
                        Task {
                            await manager.deleteAll()
                        }
                    } label: {
                        Label("Delete All", systemImage: "trash.fill")
                    }
                } label: {
                    Label("Others", systemImage: "line.3.horizontal.circle")
                }
            }
        }
    }
#endif
