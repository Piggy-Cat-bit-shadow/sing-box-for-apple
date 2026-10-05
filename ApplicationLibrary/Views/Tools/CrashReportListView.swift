import Libbox
import Library
import SwiftUI

@MainActor
public struct CrashReportListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var alert: AlertState?
    #if os(tvOS)
        @State private var showCrashTrigger = false
        @State private var selectedReport: CrashReport?
    #endif

    public init() {}

    private var manager: CrashReportManager {
        environments.crashReportManager
    }

    public var body: some View {
        HakoReportScaffold(title: String(localized: "Crash Report")) {
            if !isLoading {
                HakoSettingsSection("Reports", footnote: "You will receive a report when a crash occurs.") {
                    if manager.reports.isEmpty {
                        HakoCardEmptyState(
                            symbol: "ladybug.fill",
                            title: "No crash reports",
                            message: "Crash reports recorded on this device appear here."
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
                                    CrashReportDetailView(report: report)
                                } label: {
                                    reportLabel(report)
                                }
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
                isLoading = false
            }
        }
        .alert($alert)
        #if os(tvOS)
            .navigationDestination(item: $selectedReport) { report in
                CrashReportDetailView(report: report)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            BackButton()
                        }
                    }
            }
        #endif
        #if os(tvOS)
        .navigationDestination(isPresented: $showCrashTrigger) {
            CrashTriggerView()
        }
        .toolbar {
            if Variant.inDebug {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showCrashTrigger = true
                    } label: {
                        Image(systemName: "ant.fill")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                CrashReportDeleteButton(manager: manager)
            }
        }
        #else
        .toolbar {
                    ToolbarItem {
                        CrashReportToolbarMenu(manager: manager)
                    }
                }
        #endif
    }

    private func reportLabel(_ report: CrashReport) -> some View {
        #if os(tvOS)
            ReportLabel(date: report.date, isRead: report.isRead, origin: report.origin)
        #else
            HakoNavigationRow(
                title: report.date.formatted(date: .abbreviated, time: .shortened),
                subtitle: report.origin == ReportArchive.tvOSDeviceOrigin
                    ? String(localized: "From Apple TV")
                    : String(localized: "From this device"),
                systemImage: "ladybug.fill",
                tint: HakoAccentRole.pink.color,
                badge: report.isRead ? nil : String(localized: "Unread"),
                badgeEmphasis: .info
            )
        #endif
    }
}

#if os(tvOS)
    private struct CrashTriggerView: View {
        @Environment(\.dismiss) private var dismiss
        @EnvironmentObject private var environments: ExtensionEnvironments

        var body: some View {
            Form {
                Section("Application") {
                    Button("Go Crash") {
                        LibboxTriggerGoPanic()
                    }
                    Button("Native Crash") {
                        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
                            fatalError("debug native crash")
                        }
                    }
                }
                if let profile = environments.extensionProfile, profile.status.isConnectedStrict {
                    Section("NetworkExtension") {
                        Button("Go Crash") {
                            try? LibboxNewStandaloneCommandClient()?.triggerGoCrash()
                            dismiss()
                            Task {
                                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                                await environments.crashReportManager.refresh()
                            }
                        }
                        Button("Native Crash") {
                            try? LibboxNewStandaloneCommandClient()?.triggerNativeCrash()
                            dismiss()
                            Task {
                                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                                await environments.crashReportManager.refresh()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Crash Trigger")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    BackButton()
                }
            }
        }
    }
#else
    private struct NetworkExtensionCrashMenu: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @ObservedObject var profile: ExtensionProfile

        var body: some View {
            if profile.status.isConnectedStrict {
                Menu("NetworkExtension") {
                    Button("Go Crash") {
                        try? LibboxNewStandaloneCommandClient()?.triggerGoCrash()
                        Task {
                            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                            await environments.crashReportManager.refresh()
                        }
                    }
                    Button("Native Crash") {
                        try? LibboxNewStandaloneCommandClient()?.triggerNativeCrash()
                        Task {
                            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                            await environments.crashReportManager.refresh()
                        }
                    }
                }
            }
        }
    }
#endif

#if os(macOS)
    private struct RootHelperCrashMenu: View {
        @EnvironmentObject private var environments: ExtensionEnvironments

        var body: some View {
            if Variant.useSystemExtension, HelperServiceManager.rootHelperStatus == .enabled {
                Menu("RootHelper") {
                    Button("Go Crash") {
                        try? RootHelperClient.shared.triggerGoCrash()
                        Task {
                            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                            await environments.crashReportManager.refresh()
                        }
                    }
                    Button("Native Crash") {
                        try? RootHelperClient.shared.triggerNativeCrash()
                        Task {
                            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                            await environments.crashReportManager.refresh()
                        }
                    }
                }
            }
        }
    }
#endif

#if os(tvOS)
    private struct CrashReportDeleteButton: View {
        @ObservedObject var manager: CrashReportManager

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
    private struct CrashReportToolbarMenu: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @ObservedObject var manager: CrashReportManager

        var body: some View {
            if !manager.reports.isEmpty || Variant.inDebug {
                Menu {
                    if Variant.inDebug {
                        Menu {
                            Menu("Application") {
                                Button("Go Crash") {
                                    LibboxTriggerGoPanic()
                                }
                                Button("Native Crash") {
                                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
                                        fatalError("debug native crash")
                                    }
                                }
                            }
                            if let profile = environments.extensionProfile {
                                NetworkExtensionCrashMenu(profile: profile)
                            }
                            #if os(macOS)
                                RootHelperCrashMenu()
                            #endif
                        } label: {
                            Label("Crash Trigger", systemImage: "ant.fill")
                        }
                    }
                    if !manager.reports.isEmpty {
                        Button(role: .destructive) {
                            Task {
                                await manager.deleteAll()
                            }
                        } label: {
                            Label("Delete All", systemImage: "trash.fill")
                        }
                    }
                } label: {
                    Label("Others", systemImage: "line.3.horizontal.circle")
                }
            }
        }
    }
#endif
