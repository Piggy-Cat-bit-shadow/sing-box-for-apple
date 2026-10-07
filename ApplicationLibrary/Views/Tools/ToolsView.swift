import Library
import NetworkExtension
import SwiftUI

@MainActor
public struct ToolsView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var peerStore: TailscaleSSHPeerStore
    @Environment(\.selection) private var selection
    @EnvironmentObject private var tailscaleViewModel: TailscaleStatusViewModel
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
        Group {
            #if os(iOS)
                HakoRootScaffold {
                    sections
                }
            #else
                FormView {
                    sections
                }
            #endif
        }
        .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { usbipViewModel.subscribe() }, onInactive: { usbipViewModel.cancel() }))
        .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { openConnectViewModel.subscribe() }, onInactive: { openConnectViewModel.cancel() }))
        .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { openVPNViewModel.subscribe() }, onInactive: { openVPNViewModel.cancel() }))
        #if os(macOS)
            .modifier(ConnectionLifecycleObserver(profile: environments.extensionProfile, remoteServerID: environments.remoteServer?.id, onActive: { usbipProviderViewModel.start() }, onInactive: { usbipProviderViewModel.cancel() }))
        #endif
            .alert($tailscaleViewModel.alert)
        // The top-right menu lived here. It held the home-layout sheet and the remote control
        // picker, and the review's item is that neither belongs in a root page's chrome: both are
        // settings, and both are on the client settings page now.
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

    // MARK: - Information architecture

    /// The page's sections, grouped by the question a user is asking.
    ///
    /// The list this replaces was flat and used the client's own vocabulary as its
    /// headings: an "Endpoints" section, a "Services" section, a "Network" section and
    /// a "Debug" section whose last row read `Taiwan Flag Available` with a boolean
    /// beside it. Almost nothing on it said what the tool was for.
    ///
    /// The rows are the same tools. The headings are now the user's questions, and the
    /// debug readout is gone: it measured whether the device's font renders a flag,
    /// which is a real check the client performs for its network-permission flow, but
    /// it is not something to show a user who came here to test their connection.
    @ViewBuilder
    private var sections: some View {
        // The session section held one row - Logs - and the home already offers it, so the review
        // removed the duplicate rather than the row: an empty "Current Session" card would be a
        // worse answer than no card.
        endpointSection
        networkToolsSection
        diagnosticsSection
    }

    /// Live endpoints reported by the core: a Tailscale node, a VPN gateway.
    @ViewBuilder
    private var endpointSection: some View {
        if !tailscaleViewModel.endpoints.isEmpty || !openConnectViewModel.endpoints.isEmpty || !openVPNViewModel.endpoints.isEmpty {
            HakoPageSection(String(localized: "Endpoints")) {
                ForEach(Array(tailscaleViewModel.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                    if index > 0 { HakoRowDivider() }
                    FormNavigationLink {
                        TailscaleEndpointView(viewModel: tailscaleViewModel, endpointTag: endpoint.endpointTag)
                    } label: {
                        HStack {
                            Group {
                                HakoNavigationRow(
                                    title: tailscaleViewModel.endpoints.count == 1
                                        ? String(localized: "Tailscale")
                                        : String(localized: "Tailscale: \(endpoint.endpointTag)"),
                                    subtitle: endpoint.unreadFileCount > 0
                                        ? String(localized: "\(endpoint.unreadFileCount) unread")
                                        : nil,
                                    systemImage: "point.3.filled.connected.trianglepath.dotted",
                                    tint: HakoAccentRole.neutral.color
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
                    HakoRowDivider()
                    FormNavigationLink {
                        OpenConnectEndpointView(viewModel: openConnectViewModel, endpointTag: endpoint.endpointTag)
                    } label: {
                        HakoNavigationRow(
                            title: openConnectViewModel.endpoints.count == 1
                                ? String(localized: "OpenConnect")
                                : String(localized: "OpenConnect: \(endpoint.endpointTag)"),
                            systemImage: "network.badge.shield.half.filled",
                            tint: HakoAccentRole.neutral.color
                        )
                    }
                }

                ForEach(openVPNViewModel.endpoints) { endpoint in
                    HakoRowDivider()
                    FormNavigationLink {
                        OpenVPNEndpointView(viewModel: openVPNViewModel, endpointTag: endpoint.endpointTag)
                    } label: {
                        HakoNavigationRow(
                            title: openVPNViewModel.endpoints.count == 1
                                ? String(localized: "OpenVPN")
                                : String(localized: "OpenVPN: \(endpoint.endpointTag)"),
                            systemImage: "network.badge.shield.half.filled",
                            tint: HakoAccentRole.neutral.color
                        )
                    }
                }

                ForEach(usbipViewModel.servers) { server in
                    HakoRowDivider()
                    FormNavigationLink {
                        #if os(macOS)
                            USBIPServerView(viewModel: usbipViewModel, serverTag: server.serverTag)
                                .environmentObject(usbipProviderViewModel)
                        #else
                            USBIPServerView(viewModel: usbipViewModel, serverTag: server.serverTag)
                        #endif
                    } label: {
                        HakoNavigationRow(
                            title: usbipViewModel.servers.count == 1
                                ? String(localized: "USB/IP")
                                : String(localized: "USB/IP: \(server.serverTag)"),
                            systemImage: "externaldrive.connected.to.line.below",
                            tint: HakoAccentRole.neutral.color
                        )
                    }
                }
            }
        }
    }

    private var networkToolsSection: some View {
        HakoPageSection(
            String(localized: "Network Tools")
        ) {
            FormNavigationLink {
                NetworkQualityView()
            } label: {
                HakoNavigationRow(
                    title: String(localized: "Network Quality"),
                    subtitle: String(localized: "Throughput and responsiveness"),
                    systemImage: "network",
                    tint: HakoAccentRole.neutral.color
                )
            }
            .accessibilityIdentifier("hako.tools.networkQuality")
            HakoRowDivider()
            FormNavigationLink {
                STUNTestView()
            } label: {
                HakoNavigationRow(
                    title: String(localized: "STUN & NAT"),
                    subtitle: String(localized: "UDP reachability and NAT behaviour"),
                    systemImage: "arrow.triangle.swap",
                    tint: HakoAccentRole.neutral.color
                )
            }
            .accessibilityIdentifier("hako.tools.stun")
        }
    }

    /// The reports this device has recorded.
    ///
    /// Reports read the local device, which the remote-control API does not reach, so
    /// the section is absent while this client is driving another one.
    @ViewBuilder
    private var diagnosticsSection: some View {
        if environments.remoteServer == nil {
            HakoPageSection(
                String(localized: "Runtime & Reports")
            ) {
                #if os(iOS)
                    NavigationLink(isActive: $showCrashReportList) {
                        CrashReportListView()
                    } label: {
                        reportRow(
                            title: String(localized: "Crash Report"),
                            subtitle: String(localized: "Signals from the runs that ended early"),
                            systemImage: "ladybug.fill",
                            tint: HakoAccentRole.neutral,
                            unread: environments.crashReportManager.unreadCount
                        )
                    }
                    .buttonStyle(HakoPushRowButtonStyle())
                    .accessibilityIdentifier("hako.tools.crashReports")
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
                    HakoRowDivider()
                    NavigationLink(isActive: $showOOMReportList) {
                        OOMReportListView()
                    } label: {
                        reportRow(
                            title: String(localized: "Out of Memory Report"),
                            subtitle: String(localized: "Memory use before the system killed it"),
                            systemImage: "memorychip",
                            tint: HakoAccentRole.neutral,
                            unread: environments.oomReportManager.unreadCount
                        )
                    }
                    .buttonStyle(HakoPushRowButtonStyle())
                    .accessibilityIdentifier("hako.tools.oomReports")
                    HakoRowDivider()
                    NavigationLink(isActive: $showPowerReportList) {
                        PowerReportListView()
                    } label: {
                        reportRow(
                            title: String(localized: "Power Report"),
                            subtitle: String(localized: "Battery use during each run"),
                            systemImage: "battery.50percent",
                            tint: HakoAccentRole.neutral,
                            unread: environments.powerReportManager.unreadCount
                        )
                    }
                    .buttonStyle(HakoPushRowButtonStyle())
                    .accessibilityIdentifier("hako.tools.powerReports")
                #else
                    FormNavigationLink {
                        CrashReportListView()
                    } label: {
                        HakoNavigationRow(
                            title: String(localized: "Crash Report"),
                            subtitle: unreadDetail(environments.crashReportManager.unreadCount),
                            systemImage: "ladybug.fill",
                            tint: HakoAccentRole.neutral.color
                        )
                    }
                    HakoRowDivider()
                    FormNavigationLink {
                        OOMReportListView()
                    } label: {
                        HakoNavigationRow(
                            title: String(localized: "Out of Memory Report"),
                            subtitle: unreadDetail(environments.oomReportManager.unreadCount),
                            systemImage: "memorychip",
                            tint: HakoAccentRole.neutral.color
                        )
                    }
                    HakoRowDivider()
                    FormNavigationLink {
                        PowerReportListView()
                    } label: {
                        HakoNavigationRow(
                            title: String(localized: "Power Report"),
                            subtitle: unreadDetail(environments.powerReportManager.unreadCount),
                            systemImage: "battery.50percent",
                            tint: HakoAccentRole.neutral.color
                        )
                    }
                #endif
            }
        }
    }

    /// A report row on the touch client: the count is the row's own badge rather than a
    /// subtitle, because it is a number that changes and the row already has its title.
    /// A report row, built like the rows above it.
    ///
    /// The subtitle used to appear only when something was unread, so in the ordinary case
    /// these three rows were a single line where Logs and Network Quality were two - the three
    /// entries sat visibly shorter and higher than their siblings in the same card language. The
    /// description is permanent now and the count is the badge, which is what a count is for.
    private func reportRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: HakoAccentRole,
        unread: Int
    ) -> some View {
        HakoNavigationRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint.color,
            badge: unread > 0 ? "\(unread)" : nil,
            badgeEmphasis: .info
        )
    }

    /// The second line a report row shows on the touch platforms, where a row has one.
    private func unreadDetail(_ count: Int) -> String? {
        count > 0 ? String(localized: "\(count) unread") : nil
    }

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
