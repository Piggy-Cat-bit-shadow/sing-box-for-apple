//
//  HakoHomeView.swift
//  ApplicationLibrary
//
//  The Home page, in the HAKO/Clash page language.
//
//  Structure follows Hako-Client (GPL-3.0) `Sources/OverviewContent.swift` at commit
//  62aa2f2f: the connection card first and unconditionally, then the widgets the user
//  has kept, then the way into everything else.
//
//  # The order, and why it is this order
//
//    1. session      what am I running, and the one control that changes it
//    2. profile      which configuration, and what can be done to it
//    3. mode         how outbound traffic is being routed
//    4. shortcuts    the way into proxies, activity and logs
//    5. traffic      what it is costing, live
//    6. runtime      what the kernel is doing
//
//  The page this replaces opened with a grid of figures - memory, goroutines,
//  connections, upload, download - which is a dashboard for someone watching the
//  kernel rather than a home screen for someone using the tunnel. The figures are all
//  still here; they have moved behind the state they describe, and they are the part
//  of the page that yields when the page is short.
//
//  # What is reused and what is not
//
//  Every card, binding and action below is sing-box-for-apple's own: `ProfileCard`
//  switches profiles and owns the profile picker, QR and editor; `StartStopButton`
//  is the tunnel's only state machine; `ClashModeCard` sends the mode to the command
//  client; the traffic and status cards read the command client's stream. None of
//  that is re-implemented here, because a second implementation of any of it would
//  be a second source of truth.
//
//  What HAKO supplies is the page: one canvas, one column, one card language, and
//  destination rows that lead into the rest of the client.
//

import Foundation
import Libbox
import Library
import SwiftUI

/// The navigation the Home page can start, supplied by the shell.
///
/// Groups and connections are presented as sheets by the iOS root view, which owns
/// their presentation state; passing the two actions through the environment keeps
/// those presenters in one place instead of threading callbacks through every view
/// between the root and this page.
public struct HakoHomeActions {
    public var showGroups: () -> Void
    public var showConnections: () -> Void

    public init(
        showGroups: @escaping () -> Void = {},
        showConnections: @escaping () -> Void = {}
    ) {
        self.showGroups = showGroups
        self.showConnections = showConnections
    }
}

private struct HakoHomeActionsKey: EnvironmentKey {
    static let defaultValue = HakoHomeActions()
}

public extension EnvironmentValues {
    var hakoHomeActions: HakoHomeActions {
        get { self[HakoHomeActionsKey.self] }
        set { self[HakoHomeActionsKey.self] = newValue }
    }
}

@MainActor
public struct HakoHomeView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @Environment(\.hakoHomeActions) private var actions
    @Environment(\.selection) private var selection
    /// The chosen outbound mode, held here until the core confirms it. See `selectClashMode`.
    @State private var localMode: String = ""
    /// The counts the shortcut rows report.
    ///
    /// Held here rather than read from the client in `body`, because the client is a *nested*
    /// observable: `environments.commandClient` is a published property of the environment
    /// object, and a change inside the client does not invalidate a view that read through it.
    /// The counts did not move, so Home said "Proxy groups" while the proxy sheet said "2" -
    /// two views disagreeing about the same data, one observing it and one not.
    @State private var liveGroupCount = 0
    @State private var liveConnectionCount = 0

    /// Whether a tunnel profile exists at all.
    ///
    /// When it does not, the page still draws - that is the point - and says so where the reader
    /// is already looking, with the action that fixes it.
    private let tunnelIsInstalled: Bool
    private let installTunnel: () async -> Void
    /// Why the configuration list could not be read, if it could not be.
    private let profileLoadFailure: String?
    private let retryProfileLoad: () async -> Void
    @Binding private var profileList: [ProfilePreview]
    /// Whether the configuration centre is open. Opened from the row that used to be a picker.
    @State private var showsConfigurationCentre = false
    @Binding private var selectedProfileID: Int64
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool
    @ObservedObject private var cardConfiguration: DashboardCardConfiguration
    @StateObject private var coordinator = OverviewViewModel()

    public init(
        profileList: Binding<[ProfilePreview]>,
        selectedProfileID: Binding<Int64>,
        systemProxyAvailable: Binding<Bool>,
        systemProxyEnabled: Binding<Bool>,
        tunnelIsInstalled: Bool = true,
        installTunnel: @escaping () async -> Void = {},
        profileLoadFailure: String? = nil,
        retryProfileLoad: @escaping () async -> Void = {},
        cardConfiguration: DashboardCardConfiguration
    ) {
        self.tunnelIsInstalled = tunnelIsInstalled
        self.installTunnel = installTunnel
        self.profileLoadFailure = profileLoadFailure
        self.retryProfileLoad = retryProfileLoad
        _profileList = profileList
        _selectedProfileID = selectedProfileID
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        _cardConfiguration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        HakoRootScaffold {
            // A condition the page found rather than one the user caused. It is reported
            // where it stands, above everything, and the rest of the page still draws: the
            // reference does exactly this when its configuration cannot be read.
            // Nothing to start is a condition of the page, not a reason for another page.
            if !tunnelIsInstalled {
                // No button here: the card below carries the action, and two identical buttons
                // for one action is the redundancy the reference's own notice card avoids -
                // its notice is a line of text and the card's action is the control.
                HakoInlineNotice(
                    title: String(localized: "Network Extension"),
                    message: String(localized: "The VPN extension is not installed yet. Install it to start the tunnel.")
                )
            }
            if let profileLoadFailure {
                HakoInlineNotice(
                    title: String(localized: "Profiles"),
                    message: profileLoadFailure,
                    actionTitle: String(localized: "Retry")
                ) {
                    Task {
                        await retryProfileLoad()
                    }
                }
            }
            // The page's first screen: which configuration is in use, and the action that
            // starts or stops it - the reference's own order, and the review's first item.
            // Everything below this is state; nothing below it repeats these two.
            topOperationCard
            // How traffic is leaving the device right now, with the other cards that describe
            // the current working mode - not below the traffic totals at the foot of the page,
            // where the review found it. It is a statement about the mode, and the mode is
            // decided at the top of this page.
            if enabledCards.contains(.httpProxy), systemProxyAvailable {
                httpProxyCard
            }
            if showsConnectedCards, enabledCards.contains(.clashMode) {
                modeSection
            }
            shortcutsSection
            if showsConnectedCards {
                trafficSection
                runtimeSection
            }
        }
        .onAppear {
            localMode = environments.commandClient.clashMode
            liveGroupCount = environments.commandClient.groups?.count ?? 0
            liveConnectionCount = Int(environments.commandClient.status?.connectionsIn ?? 0)
        }
        .onReceive(environments.commandClient.$groups) { groups in
            liveGroupCount = groups?.count ?? 0
        }
        .onReceive(environments.commandClient.statusPublisher) { status in
            liveConnectionCount = Int(status?.connectionsIn ?? 0)
        }
        .onChangeCompat(of: environments.commandClient.clashMode) { newValue in
            if !newValue.isEmpty {
                localMode = newValue
            }
        }
        .alert($coordinator.alert)
        // The same gate the card grid applies: while the tunnel is switching
        // profiles or cannot be switched, no control on the page may act. The flag
        // lives here because the switch itself is asynchronous and this page owns the
        // control that started it.
        // Only while the tunnel is *moving*. `isSwitchable` is connected-or-disconnected, so
        // testing it disabled the whole page for a client that has no tunnel at all - which
        // greyed out the install button in the notice above and left the card's action inert.
        // A page whose only job is to offer the next step must not be disabled before the
        // first step is taken.
        .disabled(coordinator.reasserting
            || profile.status == .connecting
            || profile.status == .disconnecting)
        // Outside the Form and outside the Section: a presentation attached to a `Section` is
        // dropped, because a Section is the Form's layout container rather than a view in the
        // hierarchy. The configuration centre is presented from the page.
        .sheet(isPresented: $showsConfigurationCentre) {
            // Wrapped the way the card that used to present it wrapped it: the centre is a
            // `NavigationSheet`, and that is what gives it a title, a toolbar for its own
            // actions, and a close control. Presented bare, its `.toolbar` had no navigation
            // container to attach to and the sheet had no way out.
            NavigationSheet(
                title: String(localized: "Profiles"),
                size: .large,
                content: {
                    ProfilePickerSheet(
                        profileList: $profileList,
                        selectedProfileID: $selectedProfileID
                    )
                    .environmentObject(environments)
                }
            )
        }
    }

    // MARK: - Session

    /// The top of the page: the configuration in use and the control that starts it.
    ///
    /// The review asked for the two operations a reader actually comes here to perform - pick or
    /// import a configuration, and start or stop the tunnel - to be the first thing on the page,
    /// with nothing below repeating them. This was two cards: a session card whose action was a
    /// full-width button, and a configuration card holding a picker and three more controls. One
    /// profile appeared in both, and the page offered the same journey twice.
    ///
    /// The shape is the reference's: a row that names the configuration (with the way into the
    /// configuration centre beside it), the primary action on the trailing side, and the state as
    /// a line under it. Its name is the profile's, and the line under it carries the file the
    /// profile actually reads - the review's "the current configuration must show its real file
    /// name, not a generic placeholder".
    private var topOperationCard: some View {
        HakoCardSurface(
            fill: HakoProductPalette.system.card,
            separator: HakoProductPalette.system.separator,
            cornerRadius: HakoTheme.Radius.groupedSection
        ) {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.standard) {
                HStack(alignment: .center, spacing: HakoTheme.Spacing.row) {
                    HakoIconWell(
                        tint: HakoAccentRole.neutral.color,
                        systemImage: "doc.text.fill"
                    )

                    VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                        HStack(spacing: HakoTheme.Spacing.compact) {
                            Circle()
                                .fill(sessionTint)
                                .frame(width: 9, height: 9)
                                .accessibilityHidden(true)
                            Text(selectedProfileName ?? String(localized: "No profile selected"))
                                .font(HakoTheme.FontRole.rowPrimary)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // The door to the centre, beside the thing it configures - the
                            // reference puts its add action here too.
                            Button {
                                showsConfigurationCentre = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(HakoAccentRole.primaryAction.color)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Profiles"))
                            .accessibilityIdentifier("hako.profile.select")
                        }
                        Text(sessionSummary)
                            .font(HakoTheme.Typography.rowSubtitle(Locale.current))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: HakoTheme.Spacing.compact)

                    StartStopButton(showsRuntimeDuration: false, isCompact: true) {
                        await installTunnel()
                    }
                }

                if let detail = sessionDetail {
                    HakoStatusLine(
                        detail.title,
                        detail: detail.value,
                        tint: detail.emphasis
                    )
                }
            }
            .padding(HakoTheme.Layout.cardInnerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The line under the configuration's name: what the tunnel is doing, and nothing else.
    ///
    /// It read "\(state) · \(file)", which printed the configuration's name a second time
    /// directly under the row that already showed it. The review asked for the file name to appear
    /// once in this card; the title carries it, so this line carries the state.
    private var sessionSummary: String {
        sessionTitle
    }

    private var sessionTitle: String {
        switch profile.status {
        case .connected: String(localized: "Started")
        case .connecting: String(localized: "Starting")
        case .disconnecting: String(localized: "Stopping")
        case .reasserting: String(localized: "Reasserting")
        case .disconnected: String(localized: "Stopped")
        case .invalid: String(localized: "Not Installed")
        default: String(localized: "Unknown")
        }
    }

    private var sessionTint: Color {
        switch profile.status {
        case .connected: .green
        case .connecting, .reasserting: .orange
        case .disconnecting: .orange
        case .disconnected: .secondary
        default: .red
        }
    }

    /// One line of live state, and only one: the page's job is to answer "is it
    /// running" first and "how is it doing" second, and the second answer belongs to
    /// the runtime card further down.
    private var sessionDetail: (title: String, value: String?, emphasis: HakoStatusBadge.Emphasis)? {
        if environments.remoteServer != nil {
            return (String(localized: "Remote control"), nil, .info)
        }
        if environments.emptyProfiles {
            return (String(localized: "Add a profile to start"), nil, .warning)
        }
        // Before the switchable check: `.invalid` is not switchable either, and it is not
        // switching - there is no configuration to switch. The notice above the card says what
        // to do about it; this line must not claim progress that is not happening.
        if profile.status == .invalid {
            return nil
        }
        if !profile.status.isSwitchable {
            return (String(localized: "Switching…"), nil, .info)
        }
        return nil
    }

    private var selectedProfileName: String? {
        profileList.first { $0.id == selectedProfileID }?.name
    }

    // MARK: - Cards

    /// Traffic, side by side where both cards are enabled and stacked where only one is.
    ///
    /// The two cards are half-width by design and were previously laid out by the card
    /// grid's own grouping rules. A single card is *not* left at half width, because a
    /// half-width card alone on a page reads as a layout that failed rather than as one
    /// the user configured.
    @ViewBuilder
    private var trafficSection: some View {
        let showsUpload = enabledCards.contains(.uploadTraffic)
        let showsDownload = enabledCards.contains(.downloadTraffic)

        if showsUpload, showsDownload {
            LazyVGrid(columns: HakoHomeView.pairColumns, alignment: .leading, spacing: HakoTheme.Spacing.cardGap) {
                uploadCard
                downloadCard
            }
        } else if showsUpload {
            uploadCard
        } else if showsDownload {
            downloadCard
        }
    }

    private var uploadCard: some View {
        UploadTrafficCard()
            .environmentObject(environments.commandClient)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var downloadCard: some View {
        DownloadTrafficCard()
            .environmentObject(environments.commandClient)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The kernel's own figures, under one heading rather than as the page's skeleton.
    @ViewBuilder
    private var runtimeSection: some View {
        let showsStatus = enabledCards.contains(.status)
        let showsConnections = enabledCards.contains(.connections)

        if showsStatus, showsConnections {
            LazyVGrid(columns: HakoHomeView.pairColumns, alignment: .leading, spacing: HakoTheme.Spacing.cardGap) {
                statusCard
                connectionsCard
            }
        } else if showsStatus {
            statusCard
        } else if showsConnections {
            connectionsCard
        }
    }

    private var statusCard: some View {
        StatusCard()
            .environmentObject(environments.commandClient)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var connectionsCard: some View {
        ConnectionsCard()
            .environmentObject(environments.commandClient)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The two equal columns a paired card row uses.
    ///
    /// `LazyVGrid` rather than an `HStack` so the pair collapses to one column by itself
    /// on a narrow window or at a large Dynamic Type size, without the page having to
    /// measure anything.
    private static var pairColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: HakoTheme.Spacing.cardGap)]
    }

    private var httpProxyCard: some View {
        HTTPProxyCard(
            systemProxyAvailable: $systemProxyAvailable,
            systemProxyEnabled: $systemProxyEnabled
        ) { enabled in
            await coordinator.setSystemProxyEnabled(enabled, profile: profile)
        }
    }

    /// The shortcuts the reference design puts between the mode and the traffic.
    ///
    /// These are the client's own destinations: the two sheets the root view
    /// presents, and the logs page, which is selected rather than pushed so the
    /// existing "logs selected → connect the command client" hook still runs.
    private var shortcutsSection: some View {
        HakoPageSection(palette: .system) {
            if showGroups {
                shortcutRow(
                    title: String(localized: "Proxies"),
                    subtitle: groupsSubtitle,
                    systemImage: "rectangle.3.group.fill",
                    tint: HakoAccentRole.neutral.color,
                    identifier: "hako.home.groups",
                    action: actions.showGroups
                )
                HakoRowDivider()
            }
            shortcutRow(
                title: String(localized: "Connections"),
                subtitle: connectionsSubtitle,
                systemImage: "list.bullet.rectangle.portrait.fill",
                tint: HakoAccentRole.neutral.color,
                identifier: "hako.home.connections",
                action: actions.showConnections
            )
            HakoRowDivider()
            shortcutRow(
                title: String(localized: "Logs"),
                subtitle: String(localized: "Tunnel output"),
                systemImage: "list.bullet.rectangle",
                tint: HakoAccentRole.neutral.color,
                identifier: "hako.home.logs",
                action: {
                    HakoUITrace.event("shortcut logs")
                    selection.wrappedValue = .logs
                }
            )
        }
    }

    private func shortcutRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HakoNavigationRow(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                tint: tint
            )
        }
        .buttonStyle(HakoPushRowButtonStyle())
        // Only the interactive nodes a UI test has to reach get an identifier: the three shortcuts
        // are the whole of this page's navigation, and their labels are localized.
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Card configuration

    /// The cards the user has enabled, in their order.
    ///
    /// Reading the same configuration the card grid reads is what keeps the existing
    /// "Dashboard Items" sheet meaningful on the new page.
    private var enabledCards: [DashboardCard] {
        cardConfiguration.orderedEnabledCards
    }

    private var showsConnectedCards: Bool {
        Variant.screenshotMode || profile.status.isConnected
    }

    private var showGroups: Bool {
        Variant.screenshotMode || environments.commandClient.groups?.isEmpty == false
    }

    /// The outbound mode, as the reference presents it.
    ///
    /// A painted section of selection rows with the reason each mode exists, which is what
    /// the reference's Home shows: its mode card is a vertical list where the chosen row
    /// carries the explanation (`规则` / `按配置规则分流`), not a segmented control. A
    /// segmented control also had to fit its labels into the width it was given, so this
    /// client carried a `GeometryReader`, two preference keys and a menu fallback for the
    /// case where they did not fit - machinery that no longer has a reason to exist.
    @ViewBuilder
    private var modeSection: some View {
        let modes = environments.commandClient.clashModeList
        let current = localMode.isEmpty ? environments.commandClient.clashMode : localMode
        if modes.count > 1 {
            HakoPageSection(String(localized: "Outbound Mode")) {
                ForEach(Array(modes.enumerated()), id: \.offset) { index, mode in
                    if index > 0 {
                        HakoRowDivider()
                    }
                    HakoSelectionRow(
                        title: modeTitle(mode),
                        subtitle: modeExplanation(mode),
                        isSelected: mode == current,
                        identifier: "hako.home.mode.\(mode)"
                    ) {
                        selectClashMode(mode)
                    }
                }
            }
        }
    }

    /// The core names the modes `rule`, `global` and `direct`; a user reads words.
    private func modeTitle(_ mode: String) -> String {
        switch mode {
        case "rule": String(localized: "Rules")
        case "global": String(localized: "Global")
        case "direct": String(localized: "Direct")
        default: mode.capitalized
        }
    }

    private func modeExplanation(_ mode: String) -> String? {
        switch mode {
        case "rule": String(localized: "Split traffic by the profile's rules")
        case "global": String(localized: "Send every connection through the proxy")
        case "direct": String(localized: "Send every connection out directly")
        default: nil
        }
    }

    /// Choose a mode.
    ///
    /// The choice is held locally first and sent to the core second, which is what the card
    /// this replaced did: the core can only report a mode back while it is running, so a row
    /// that waited for it would not move at all with the tunnel stopped. The published value
    /// reconciles the local one whenever the core does report.
    private func selectClashMode(_ mode: String) {
        withAnimation {
            localMode = mode
        }
        // The fixture runs no tunnel, so there is no command server to send to. Attempting
        // it raises a blocking alert with an IPC error over the very page a snapshot exists
        // to photograph, and the alert reports a condition the fixture invented.
        guard !Variant.screenshotMode else {
            return
        }
        Task {
            do {
                try CommandTarget.standaloneClient().setClashMode(mode)
            } catch {
                coordinator.alert = AlertState(action: "set clash mode", error: error)
            }
        }
    }

    private var groupsSubtitle: String {
        let count = liveGroupCount
        return count > 0
            ? String(localized: "\(count) groups")
            : String(localized: "Proxy groups")
    }

    private var connectionsSubtitle: String {
        let count = liveConnectionCount
        return count > 0
            ? String(localized: "\(count) active")
            : String(localized: "Current sessions")
    }
}
