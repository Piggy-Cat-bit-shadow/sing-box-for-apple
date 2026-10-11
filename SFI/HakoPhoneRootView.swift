//
//  HakoPhoneRootView.swift
//  SFI
//
//  The iPhone root. This is the fork's presentation and the only place it is entered.
//
//  # Where it sits
//
//      SFI/Application.swift  ->  SFIUIFamily.resolve(idiom:)
//                                   .phone       -> HakoPhoneRootView   (this file)
//                                   anything else -> MainView            (upstream, untouched)
//
//  It is reached from exactly one call site. `MainView` never references this type and
//  this type never references `MainView`, so neither presentation can pull the other in.
//
//  # What it owns
//
//    - `selection`: the same `NavigationPage` the rest of the client already uses for
//      navigation, notification routing, deep links and the screenshot harness. The shell
//      derives its tab from it and writes back to it, so no existing entry point changes.
//    - the environment the pages read: `\.selection`, `\.importProfile`,
//      `\.importRemoteProfile`, the two editor closures.
//    - the global lifecycle wiring upstream's iOS root also performs: profile reload on
//      becoming active, connecting the command client when Logs is selected, and the
//      crash/OOM report notification.
//
//  # What it deliberately does not own
//
//  Page *contents*. `HakoPageContent` (below) is the one place a page is turned into a
//  view, and it is the seam the Hako page migration moves through - page by page, each
//  time with the upstream page as the thing being replaced rather than the thing being
//  edited.
//

import ApplicationLibrary
import Combine
import Libbox
import Library
import NetworkExtension
import SwiftUI

struct HakoPhoneRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var sendManager: TaildropSendManager

    @State private var selection: NavigationPage = {
        if Variant.screenshotMode,
           let pageValue = ProcessInfo.processInfo.environment["SCREENSHOT_PAGE"],
           let page = NavigationPage(snapshotValue: pageValue)
        {
            return page
        }
        return .dashboard
    }()

    @State private var importProfile: LibboxProfileContent?
    @State private var importRemoteProfile: LibboxImportRemoteProfile?
    @State private var alert: AlertState?

    /// The configuration list and the system-proxy snapshot, for the phone's pages.
    ///
    /// The dashboard already builds this object and reloads it; the phone's Home reads the same one
    /// rather than growing a second. `DashboardView` creates its own for the iPad, which is correct:
    /// the two roots are never alive together.
    @StateObject private var dashboard = DashboardViewModel()
    @StateObject private var cardConfiguration = DashboardCardConfiguration()
    /// Groups and connections are presented as sheets, so their presentation state lives at the root
    /// and reaches the page through `\.hakoHomeActions`.
    @State private var showGroups = false
    @State private var showConnections = false

    private let profileEditor: (Binding<String>, Bool) -> AnyView = { text, isEditable in
        AnyView(ProfileEditorWrapperView(text: text, isEditable: isEditable, restyled: true))
    }

    private let ghosttyConfigEditor: (Binding<String>) -> AnyView = { text in
        AnyView(GhosttyConfigEditorWrapperView(text: text))
    }

    var body: some View {
        if Variant.screenshotMode {
            mainBody.preferredColorScheme(.dark)
        } else {
            mainBody
        }
    }

    /// The shell. Home / Tools / More, with `NavigationPage` as the state of record.
    private var shell: some View {
        HakoPrimaryShell(
            selection: $selection,
            toolsBadge: environments.toolsBadgeCount + sendManager.failedSessionCount
        ) { page in
            pageContent(for: page)
        }
    }

    /// One page, titled for the phone.
    ///
    /// The title treatment is the shell's, not the page's: a root page's title is inline
    /// and the tab bar is what names it, which is what keeps a root page starting at its
    /// first card instead of under a large headline.
    @ViewBuilder
    private func pageContent(for page: NavigationPage) -> some View {
        HakoPageContent(page: page, dashboard: dashboard, cardConfiguration: cardConfiguration)
            .navigationTitle(page.hakoTitle)
            .hakoInlineNavigationTitle()
            .modifier(RemoteControlChipModifier())
    }

    /// The chip a page wears while this client is driving another device.
    ///
    /// The remote session is global - it changes what the whole client is showing - so it
    /// belongs in the navigation bar the page already has rather than in a second floating
    /// bar reserved for the one state most users are never in. It is also where
    /// disconnecting lives: the tab bar has no room for it, and a modal "you are in remote
    /// mode" interstitial is not a thing anyone wants.
    private struct RemoteControlChipModifier: ViewModifier {
        @EnvironmentObject private var environments: ExtensionEnvironments

        func body(content: Content) -> some View {
            content.toolbar {
                if environments.remoteServer != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        RemoteControlChip(serverName: environments.remoteServer?.displayName ?? "")
                    }
                }
            }
        }
    }

    private struct RemoteControlChip: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        let serverName: String

        var body: some View {
            Menu {
                Section(serverName) {
                    RemoteUptimeText(commandClient: environments.commandClient)
                }
                Button(role: .destructive) {
                    environments.exitRemoteControl()
                } label: {
                    Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(serverName)
                        .lineLimit(1)
                }
                .font(.footnote.weight(.medium))
            }
            .accessibilityLabel(Text("Remote control: \(serverName)"))
        }
    }

    private var mainBody: some View {
        shell
            .onAppear {
                environments.postReload()
                // The Home page reads this object, and the dashboard's own view is what normally
                // calls this. The phone's root is the equivalent owner here.
                dashboard.setEnvironments(environments)
                Task { await dashboard.reload() }
                Task { await cardConfiguration.reload() }
            }
            .alert($alert)
            .globalChecks()
            .environment(\.selection, $selection)
            .environment(\.importProfile, $importProfile)
            .environment(\.importRemoteProfile, $importRemoteProfile)
            .environment(\.profileEditor, profileEditor)
            .environment(\.ghosttyConfigEditor, ghosttyConfigEditor)
            // The extension profile is injected where the dashboard's card grid injects it, so the
            // Home page reads it from the same place rather than from a second owner.
            .environment(\.hakoHomeActions, HakoHomeActions(
                showGroups: { showGroups = true },
                showConnections: { showConnections = true }
            ))
            .handlesExternalEvents(preferring: [], allowing: ["*"])
            .onOpenURL(perform: openURL)
            .sheet(isPresented: $showGroups) {
                HakoGroupsSheetContent()
            }
            .sheet(isPresented: $showConnections) {
                HakoConnectionsSheetContent()
            }
            .onReceive(environments.profileUpdate) { _ in
                Task {
                    await dashboard.reload()
                    await cardConfiguration.reload()
                }
            }
            .onReceive(environments.selectedProfileUpdate) { _ in
                Task { await dashboard.updateSelectedProfile() }
            }
            .onChangeCompat(of: scenePhase) { newValue in
                if newValue == .active {
                    environments.postReload()
                    Task { await dashboard.reloadSystemProxy() }
                }
            }
            .onReceive(environments.$extensionProfile) { profile in
                // `DashboardView` does this for the same reason: the Home page's environment needs
                // the profile object, and its presence is what tells the page a tunnel exists.
                dashboard.setEnvironments(environments)
                _ = profile
            }
            .onChangeCompat(of: selection) { newValue in
                // Upstream's iOS root does this too: the log view is a stream from the
                // command client, so selecting it is what opens the client.
                if newValue == .logs {
                    environments.connect()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reportReceived)) { _ in
                Task {
                    await environments.crashReportManager.refresh()
                    await environments.oomReportManager.refresh()
                    selection = .tools
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSettingsPage)) { _ in
                // The page itself decides which settings sub-page to push; this only has to
                // put the user on the destination that contains it.
                selection = .settings
            }
    }

    private func openURL(url: URL) {
        if url.schemeAction == "taildrop" {
            environments.pendingTaildropEndpointTag = url.schemeQueryValue("endpoint") ?? ""
            selection = .tools
        } else if url.host == "import-remote-profile" {
            var error: NSError?
            importRemoteProfile = LibboxParseRemoteProfileImportLink(url.absoluteString, &error)
            if let error {
                alert = AlertState(action: "parse remote profile import link", error: error)
            }
        } else if url.pathExtension == "bpf" {
            do {
                importProfile = try url.withSecurityScopedAccess {
                    try .from(Data(contentsOf: url))
                }
            } catch {
                alert = AlertState(action: "import profile from URL", error: error)
            }
        } else {
            alert = AlertState(errorMessage: String(localized: "Handled unknown URL \(url.absoluteString)"))
        }
    }
}
