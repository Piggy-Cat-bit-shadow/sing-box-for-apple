import ApplicationLibrary
import Libbox
import Library
import NetworkExtension
import SwiftUI

struct MainView: View {
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
    @State private var showGroups = false
    @State private var showConnections = false
    @State private var buttonState = ButtonVisibilityState()
    /// A settings page the notification asked for, handed to the settings root when it exists.
    ///
    /// Recording it here rather than inside the settings page is what makes the request survive
    /// the tab switch: the page is installed by that switch, so a receiver living in it misses a
    /// notification that arrives first.
    @State private var pendingSettingsPage: SettingsPage?

    private let profileEditor: (Binding<String>, Bool) -> AnyView = { text, isEditable in
        AnyView(ProfileEditorWrapperView(text: text, isEditable: isEditable))
    }

    private let ghosttyConfigEditor: (Binding<String>) -> AnyView = { text in
        AnyView(GhosttyConfigEditorWrapperView(text: text))
    }

    /// The primary shell.
    ///
    /// This used to be a `TabView` over every `NavigationPage`, which put Logs on
    /// the tab bar next to Dashboard, Tools and Settings. The shell presents the
    /// three first-level destinations the design calls for - Home, Tools, More - and
    /// keeps `NavigationPage` as the state of record, so every existing entry point
    /// (the crash-report notification, the settings notification, the deep links, the
    /// screenshot harness) still selects the same page it always did.
    ///
    /// The accessory inset, the badge and the first-appearance animation rule moved
    /// into the shell; the page content builder below is unchanged in what it puts on
    /// screen.
    private var tabViewContent: some View {
        HakoPrimaryShell(
            selection: $selection,
            toolsBadge: environments.toolsBadgeCount + sendManager.failedSessionCount,
            accessory: { accessoryInset }
        ) { page in
            tabContent(for: page)
        }
    }

    var body: some View {
        if Variant.screenshotMode {
            mainBody.preferredColorScheme(.dark)
        } else {
            mainBody
        }
    }

    @ViewBuilder
    private func tabContent(for page: NavigationPage) -> some View {
        // The accessory inset and the first-appearance animation rule now live in
        // HakoPrimaryShell, which applies them per primary instead of per page.
        let content = page.contentView
            .navigationTitle(page.title)
        if page == .logs {
            content.navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }

    @ViewBuilder
    private var accessoryInset: some View {
        if environments.remoteServer != nil {
            remoteStatusBarPill
        } else if let profile = environments.extensionProfile, !environments.extensionProfileLoading, !environments.emptyProfiles {
            AccessoryInset(profile: profile) {
                statusBarPill
            } fab: {
                fabInset
            }
        }
    }

    private var fabInset: some View {
        HStack {
            Spacer()
            FABStartButton()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var statusBarPill: some View {
        bottomAccessoryContent
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .modifier(AccessoryPillBackgroundModifier(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var remoteStatusBarPill: some View {
        remoteAccessoryContent
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .modifier(AccessoryPillBackgroundModifier(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var remoteAccessoryContent: some View {
        HStack(spacing: 12) {
            RemoteStatusText(
                commandClient: environments.commandClient,
                serverName: environments.remoteServer?.displayName ?? ""
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            NavigationButtonsView(
                showGroupsButton: buttonState.showGroupsButton,
                showConnectionsButton: buttonState.showConnectionsButton,
                groupsCount: buttonState.groupsCount,
                connectionsCount: buttonState.connectionsCount,
                onGroupsTap: { showGroups = true },
                onConnectionsTap: { showConnections = true }
            )
            Divider()
            RemoteUptimeText(commandClient: environments.commandClient)
            Button {
                environments.exitRemoteControl()
            } label: {
                Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal)
        .tint(.primary)
        .buttonStyle(BarItemButtonStyle())
    }

    private struct RemoteStatusText: View {
        @ObservedObject var commandClient: CommandClient
        let serverName: String

        var body: some View {
            statusText
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        private var statusText: Text {
            if commandClient.isConnected {
                return Text(serverName)
            } else {
                return Text("Connecting...")
            }
        }
    }

    private struct AccessoryPillBackgroundModifier: ViewModifier {
        let cornerRadius: CGFloat
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *), !Variant.debugNoIOS26 {
                content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.background(.bar, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
    }

    private var bottomAccessoryContent: some View {
        HStack(spacing: 12) {
            if let profile = environments.extensionProfile {
                StatusText(profile: profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            NavigationButtonsView(
                showGroupsButton: buttonState.showGroupsButton,
                showConnectionsButton: buttonState.showConnectionsButton,
                groupsCount: buttonState.groupsCount,
                connectionsCount: buttonState.connectionsCount,
                onGroupsTap: { showGroups = true },
                onConnectionsTap: { showConnections = true }
            )
            Divider()
            StartStopButton(showsRuntimeDuration: true)
        }
        .padding(.horizontal)
        .tint(.primary)
        .buttonStyle(BarItemButtonStyle())
    }

    private struct BarItemButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.5 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    private var mainBody: some View {
        tabViewContent
            .onAppear {
                updateButtonVisibility()
            }
            .onReceive(environments.commandClient.$groups) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.commandClient.$connections) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.commandClient.$hasAnyConnection) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.commandClient.$isConnected) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.commandClient.statusPublisher) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.$remoteServer) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.$extensionProfile) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .onReceive(environments.$emptyProfiles) { _ in
                Task { @MainActor in updateButtonVisibility() }
            }
            .sheet(isPresented: $showGroups) {
                GroupsSheetContent()
            }
            .sheet(isPresented: $showConnections) {
                ConnectionsSheetContent()
            }
            .onChangeCompat(of: buttonState.showGroupsButton) { newValue in
                if !newValue {
                    showGroups = false
                }
            }
            .onChangeCompat(of: buttonState.showConnectionsButton) { newValue in
                if !newValue {
                    showConnections = false
                }
            }
            .onAppear {
                environments.postReload()
            }
            .alert($alert)
            .globalChecks()
            .onChangeCompat(of: scenePhase) { newValue in
                if newValue == .active {
                    environments.postReload()
                }
            }
            .onChangeCompat(of: selection) { newValue in
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
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSettingsPage)) { notification in
                guard let page = notification.object as? SettingsPage else { return }
                pendingSettingsPage = page
                selection = .settings
            }
            .environment(\.pendingSettingsPage, $pendingSettingsPage)
            .environment(\.selection, $selection)
            .environment(
                \.hakoHomeActions,
                HakoHomeActions(
                    showGroups: { showGroups = true },
                    showConnections: { showConnections = true }
                )
            )
            .environment(\.importProfile, $importProfile)
            .environment(\.importRemoteProfile, $importRemoteProfile)
            .environment(\.profileEditor, profileEditor)
            .environment(\.ghosttyConfigEditor, ghosttyConfigEditor)
            .handlesExternalEvents(preferring: [], allowing: ["*"])
            .onOpenURL(perform: openURL)
    }

    private func updateButtonVisibility() {
        var newState = buttonState
        if environments.remoteServer != nil {
            newState.update(remoteClient: environments.commandClient)
        } else {
            newState.update(
                profile: environments.extensionProfile,
                commandClient: environments.commandClient
            )
        }
        if newState != buttonState {
            buttonState = newState
        }
    }

    private struct AccessoryInset<StatusBar: View, FAB: View>: View {
        @ObservedObject var profile: ExtensionProfile
        @ViewBuilder let statusBar: () -> StatusBar
        @ViewBuilder let fab: () -> FAB

        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                if profile.status == .disconnected {
                    fab()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    statusBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: profile.status)
        }
    }

    private struct FABStartButton: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @State private var alert: AlertState?

        var body: some View {
            Button {
                guard let profile = environments.extensionProfile else { return }
                Task {
                    do {
                        try await profile.start()
                    } catch {
                        alert = AlertState(action: "start service", error: error)
                    }
                }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
                    .modifier(FABBackgroundModifier())
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(environments.extensionProfile == nil || environments.emptyProfiles)
            .alert($alert)
        }

        private struct FABBackgroundModifier: ViewModifier {
            func body(content: Content) -> some View {
                if #available(iOS 26.0, *), !Variant.debugNoIOS26 {
                    content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    content.background(.bar, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private struct StatusText: View {
        @ObservedObject var profile: ExtensionProfile

        var body: some View {
            statusText
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }

        private var statusText: Text {
            switch profile.status {
            case .disconnected:
                return Text("Stopped")
            case .connecting:
                return Text("Starting")
            case .connected:
                return Text("Started")
            case .reasserting:
                return Text("Reasserting")
            case .disconnecting:
                return Text("Stopping")
            default:
                return Text("Unknown")
                    .foregroundColor(.red)
            }
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
