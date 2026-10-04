import Library
import NetworkExtension
import SwiftUI

@MainActor
public struct ToolsView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var peerStore: TailscaleSSHPeerStore
    @EnvironmentObject private var tailscaleViewModel: TailscaleStatusViewModel
    @StateObject private var viewModel = SettingViewModel()
    @StateObject private var usbipViewModel = USBIPStatusViewModel()
    @StateObject private var openConnectViewModel = OpenConnectStatusViewModel()
    @StateObject private var openVPNViewModel = OpenVPNStatusViewModel()
    #if os(macOS)
        @StateObject private var usbipProviderViewModel = USBIPProviderViewModel()
    #endif
    #if os(iOS)
        @State private var showCrashReportList = false
        @State private var showOOMReportList = false
        @State private var showPowerReportList = false
        @State private var remoteServers: [RemoteServer] = []
    #endif
    #if !os(tvOS)
        @EnvironmentObject private var sendManager: TaildropSendManager
        @State private var sshPromptPeer: TailscalePeerData?
        @State private var sshPromptEndpointTag: String = ""
        @State private var sshPresentedSession: TailscaleSSHPresentedSession?
        @State private var pendingSSHSession: TailscaleSSHPresentedSession?
        @State private var taildropEndpointTag: String?
    #endif
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    public init() {}

    public var body: some View {
        FormView {
            if !tailscaleViewModel.endpoints.isEmpty || !openConnectViewModel.endpoints.isEmpty || !openVPNViewModel.endpoints.isEmpty {
                Section("Endpoints") {
                    ForEach(tailscaleViewModel.endpoints) { endpoint in
                        FormNavigationLink {
                            TailscaleEndpointView(viewModel: tailscaleViewModel, endpointTag: endpoint.endpointTag)
                        } label: {
                            HStack {
                                Group {
                                    HakoToolRow(
                                        title: tailscaleViewModel.endpoints.count == 1
                                            ? String(localized: "Tailscale")
                                            : String(localized: "Tailscale: \(endpoint.endpointTag)"),
                                        systemImage: "point.3.filled.connected.trianglepath.dotted",
                                        tint: .indigo,
                                        detail: endpoint.unreadFileCount > 0
                                            ? String(localized: "\(endpoint.unreadFileCount) unread")
                                            : nil
                                    )
                                }
                                #if !os(tvOS)
                                    if sendManager.hasFailedSessions(endpointTag: endpoint.endpointTag) {
                                        Spacer()
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                #endif
                            }
                            #if !os(tvOS)
                            .badge(sendManager.hasFailedSessions(endpointTag: endpoint.endpointTag) ? 0 : Int(endpoint.unreadFileCount))
                            #endif
                        }
                        #if !os(tvOS)
                        .contextMenu {
                            let sshPeers = sshAvailablePeers
                            if sshPeers.count == 1 {
                                Button {
                                    handleSSH(sshPeers[0])
                                } label: {
                                    Label("Connect via SSH", systemImage: "terminal")
                                }
                            } else if sshPeers.count > 1 {
                                Section("Connect via SSH") {
                                    ForEach(sshPeers) { info in
                                        Button(info.peer.hostName) {
                                            handleSSH(info)
                                        }
                                    }
                                }
                            }
                        }
                        #endif
                    }
                    ForEach(openConnectViewModel.endpoints) { endpoint in
                        FormNavigationLink {
                            OpenConnectEndpointView(viewModel: openConnectViewModel, endpointTag: endpoint.endpointTag)
                        } label: {
                            HakoToolRow(
                                title: openConnectViewModel.endpoints.count == 1
                                    ? String(localized: "OpenConnect")
                                    : String(localized: "OpenConnect: \(endpoint.endpointTag)"),
                                systemImage: "network.badge.shield.half.filled",
                                tint: .teal
                            )
                        }
                    }
                    ForEach(openVPNViewModel.endpoints) { endpoint in
                        FormNavigationLink {
                            OpenVPNEndpointView(viewModel: openVPNViewModel, endpointTag: endpoint.endpointTag)
                        } label: {
                            HakoToolRow(
                                title: openVPNViewModel.endpoints.count == 1
                                    ? String(localized: "OpenVPN")
                                    : String(localized: "OpenVPN: \(endpoint.endpointTag)"),
                                systemImage: "network.badge.shield.half.filled",
                                tint: .cyan
                            )
                        }
                    }
                }
            }

            if !usbipViewModel.servers.isEmpty {
                Section("Services") {
                    ForEach(usbipViewModel.servers) { server in
                        FormNavigationLink {
                            #if os(macOS)
                                USBIPServerView(viewModel: usbipViewModel, serverTag: server.serverTag)
                                    .environmentObject(usbipProviderViewModel)
                            #else
                                USBIPServerView(viewModel: usbipViewModel, serverTag: server.serverTag)
                            #endif
                        } label: {
                            HakoToolRow(
                                title: usbipViewModel.servers.count == 1
                                    ? String(localized: "USB/IP")
                                    : String(localized: "USB/IP: \(server.serverTag)"),
                                systemImage: "externaldrive.connected.to.line.below",
                                tint: .orange
                            )
                        }
                    }
                }
            }

            Section("Network") {
                FormNavigationLink {
                    NetworkQualityView()
                } label: {
                    HakoToolRow(
                        title: String(localized: "Network Quality"),
                        systemImage: "network",
                        tint: .blue
                    )
                }
                FormNavigationLink {
                    STUNTestView()
                } label: {
                    HakoToolRow(
                        title: String(localized: "STUN Test"),
                        systemImage: "arrow.triangle.swap",
                        tint: .purple
                    )
                }
            }

            // Crash/OOM reports and device checks read the local device, which the
            // remote control API does not reach.
            if environments.remoteServer == nil {
                Section("Debug") {
                    #if os(iOS)
                        NavigationLink(isActive: $showCrashReportList) {
                            CrashReportListView()
                        } label: {
                            HakoToolRow(
                                title: String(localized: "Crash Report"),
                                systemImage: "ladybug.fill",
                                tint: .pink,
                                detail: unreadDetail(environments.crashReportManager.unreadCount)
                            )
                            .badge(environments.crashReportManager.unreadCount)
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .reportReceived)) { notification in
                            Task {
                                try? await Task.sleep(nanoseconds: NSEC_PER_MSEC * 300)
                                if let reportType = notification.object as? ReportType {
                                    switch reportType {
                                    case .crash:
                                        showCrashReportList = true
                                    case .oom:
                                        showOOMReportList = true
                                    case .power:
                                        showPowerReportList = true
                                    }
                                }
                            }
                        }
                        NavigationLink(isActive: $showOOMReportList) {
                            OOMReportListView()
                        } label: {
                            HakoToolRow(
                                title: String(localized: "OOM Report"),
                                systemImage: "memorychip",
                                tint: .indigo,
                                detail: unreadDetail(environments.oomReportManager.unreadCount)
                            )
                            .badge(environments.oomReportManager.unreadCount)
                        }
                        NavigationLink(isActive: $showPowerReportList) {
                            PowerReportListView()
                        } label: {
                            HakoToolRow(
                                title: String(localized: "Power Report"),
                                systemImage: "battery.50percent",
                                tint: .green,
                                detail: unreadDetail(environments.powerReportManager.unreadCount)
                            )
                            .badge(environments.powerReportManager.unreadCount)
                        }
                    #else
                        FormNavigationLink {
                            CrashReportListView()
                        } label: {
                            #if os(tvOS)
                                HakoToolRow(
                                    title: String(localized: "Crash Report"),
                                    systemImage: "ladybug.fill",
                                    tint: .pink,
                                    detail: unreadDetail(environments.crashReportManager.unreadCount)
                                )
                            #else
                                HakoToolRow(
                                    title: String(localized: "Crash Report"),
                                    systemImage: "ladybug.fill",
                                    tint: .pink
                                )
                                .badge(environments.crashReportManager.unreadCount)
                            #endif
                        }
                    #endif
                    #if !os(iOS)
                        FormNavigationLink {
                            OOMReportListView()
                        } label: {
                            #if os(tvOS)
                                HakoToolRow(
                                    title: String(localized: "OOM Report"),
                                    systemImage: "memorychip",
                                    tint: .indigo,
                                    detail: unreadDetail(environments.oomReportManager.unreadCount)
                                )
                            #else
                                HakoToolRow(
                                    title: String(localized: "OOM Report"),
                                    systemImage: "memorychip",
                                    tint: .indigo
                                )
                                .badge(environments.oomReportManager.unreadCount)
                            #endif
                        }
                        FormNavigationLink {
                            PowerReportListView()
                        } label: {
                            #if os(tvOS)
                                HakoToolRow(
                                    title: String(localized: "Power Report"),
                                    systemImage: "battery.50percent",
                                    tint: .green,
                                    detail: unreadDetail(environments.powerReportManager.unreadCount)
                                )
                            #else
                                HakoToolRow(
                                    title: String(localized: "Power Report"),
                                    systemImage: "battery.50percent",
                                    tint: .green
                                )
                                .badge(environments.powerReportManager.unreadCount)
                            #endif
                        }
                    #endif
                    FormTextItem("Taiwan Flag Available", "touchid") {
                        if viewModel.isLoading {
                            Text("Loading...")
                                .onAppear {
                                    Task.detached {
                                        await viewModel.checkTaiwanFlagAvailability()
                                    }
                                }
                        } else {
                            Text(viewModel.taiwanFlagAvailable.toString())
                        }
                    }
                }
            }
        }
        .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { usbipViewModel.subscribe() }, onInactive: { usbipViewModel.cancel() }))
        .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { openConnectViewModel.subscribe() }, onInactive: { openConnectViewModel.cancel() }))
        .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { openVPNViewModel.subscribe() }, onInactive: { openVPNViewModel.cancel() }))
        #if os(macOS)
            .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { usbipProviderViewModel.start() }, onInactive: { usbipProviderViewModel.cancel() }))
        #endif
            .alert($tailscaleViewModel.alert)
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !remoteServers.isEmpty {
                        othersMenu
                    }
                }
            }
            .onAppear {
                Task { await reloadRemoteServers() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteServersUpdated)) { _ in
                Task { await reloadRemoteServers() }
            }
        #endif
        #if !os(tvOS)
        .background {
            NavigationDestinationCompat(isPresented: Binding(
                get: { taildropEndpointTag != nil },
                set: { newValue in
                    if !newValue {
                        taildropEndpointTag = nil
                    }
                }
            )) {
                if let taildropEndpointTag {
                    TaildropView(endpointTag: taildropEndpointTag)
                }
            }
        }
        .onAppear {
            resolveTaildropNavigation()
        }
        .onChangeCompat(of: environments.pendingTaildropEndpointTag) { _ in
            resolveTaildropNavigation()
        }
        .onChangeCompat(of: tailscaleViewModel.endpoints.map(\.endpointTag)) { _ in
            resolveTaildropNavigation()
        }
        .platformSheet(item: $sshPromptPeer, size: PlatformSheetSize(minWidth: 360, minHeight: 220), onDismiss: {
            if let session = pendingSSHSession {
                pendingSSHSession = nil
                sshPresentedSession = session
            }
        }) { peer in
            TailscaleSSHPromptView(peer: peer, endpointTag: sshPromptEndpointTag, onConnect: { session in pendingSSHSession = session })
        }
            #if os(iOS)
        .sheet(item: $sshPresentedSession) { presented in
            NavigationStackCompat {
                TerminalSessionContainerView(presented)
            }
        }
            #elseif os(macOS)
        .onChangeCompat(of: sshPresentedSession) { newValue in
            guard let newValue else { return }
            openWindow(value: newValue)
            sshPresentedSession = nil
        }
            #endif
        #endif
    }

    /// The second line a report row shows on the touch platforms, where a row has one.
    private func unreadDetail(_ count: Int) -> String? {
        count > 0 ? String(localized: "\(count) unread") : nil
    }

    #if os(iOS)
        private var othersMenu: some View {
            Menu {
                RemoteControlMenuItems(servers: remoteServers)
            } label: {
                Label("Others", systemImage: "line.3.horizontal.circle")
            }
        }

        private func reloadRemoteServers() async {
            remoteServers = await (try? RemoteServerManager.list()) ?? []
        }
    #endif

    #if !os(tvOS)
        private func resolveTaildropNavigation() {
            guard let requested = environments.pendingTaildropEndpointTag else { return }
            guard let endpoint = tailscaleViewModel.endpoint(tag: requested) ?? tailscaleViewModel.endpoints.first else { return }
            environments.pendingTaildropEndpointTag = nil
            taildropEndpointTag = endpoint.endpointTag
        }

        private struct SSHPeerInfo: Identifiable {
            var id: String {
                peer.stableID
            }

            let peer: TailscalePeerData
            let endpointTag: String
        }

        private var sshAvailablePeers: [SSHPeerInfo] {
            tailscaleViewModel.endpoints.flatMap { endpoint in
                endpoint.userGroups.flatMap { group in
                    group.peers.compactMap { peer in
                        guard peer.online, !peer.sshHostKeys.isEmpty, !peer.tailscaleIPs.isEmpty else { return nil }
                        return SSHPeerInfo(peer: peer, endpointTag: endpoint.endpointTag)
                    }
                }
            }
        }

        private func handleSSH(_ info: SSHPeerInfo) {
            Task {
                let quickPeers = await SharedPreferences.tailscaleSSHQuickConnectPeers.get()
                if quickPeers.contains(info.peer.stableID) {
                    let usernames = await SharedPreferences.tailscaleSSHRememberedUsernames.get()
                    let termTypes = await SharedPreferences.tailscaleSSHRememberedTerminalTypes.get()
                    #if os(macOS)
                        let forwardAgent = await SharedPreferences.tailscaleSSHForwardAgent.get()
                    #else
                        let forwardAgent = false
                    #endif
                    sshPresentedSession = TailscaleSSHPresentedSession(
                        endpointTag: info.endpointTag,
                        peerHostName: info.peer.hostName,
                        peerAddress: info.peer.tailscaleIPs.first!,
                        username: usernames[info.peer.stableID] ?? "root",
                        terminalType: termTypes[info.peer.stableID] ?? "xterm-256color",
                        hostKeys: info.peer.sshHostKeys,
                        forwardAgent: forwardAgent
                    )
                } else {
                    sshPromptEndpointTag = info.endpointTag
                    sshPromptPeer = info.peer
                }
            }
        }
    #endif
}
