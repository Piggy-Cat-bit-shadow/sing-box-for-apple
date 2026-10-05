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

    @Binding private var profileList: [ProfilePreview]
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
        cardConfiguration: DashboardCardConfiguration
    ) {
        _profileList = profileList
        _selectedProfileID = selectedProfileID
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        _cardConfiguration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        HakoRootScaffold {
            sessionCard
            profileCard
            if showsConnectedCards, enabledCards.contains(.clashMode) {
                ClashModeCard()
                    .environmentObject(environments.commandClient)
            }
            shortcutsSection
            if showsConnectedCards {
                trafficSection
                if enabledCards.contains(.httpProxy), systemProxyAvailable {
                    httpProxyCard
                }
                runtimeSection
            }
        }
        .alert($coordinator.alert)
        // The same gate the card grid applies: while the tunnel is switching
        // profiles or cannot be switched, no control on the page may act. The flag
        // lives here because the switch itself is asynchronous and this page owns the
        // control that started it.
        .disabled(!Variant.screenshotMode && (!profile.status.isSwitchable || coordinator.reasserting))
    }

    // MARK: - Session

    /// The first card: the tunnel's state, the profile it is running, and the one
    /// control that starts or stops it.
    ///
    /// This is where the floating start control went when the second global bottom bar
    /// was removed. It belongs here rather than on a bar: "start the tunnel" is the
    /// page's primary action, and a primary action that follows the user onto every
    /// other page is a bar, not a button.
    private var sessionCard: some View {
        HakoCardSurface(
            fill: HakoProductPalette.system.card,
            separator: HakoProductPalette.system.separator,
            cornerRadius: HakoTheme.Radius.groupedSection
        ) {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.standard) {
                HStack(alignment: .center, spacing: HakoTheme.Spacing.row) {
                    VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                        HStack(spacing: HakoTheme.Spacing.compact) {
                            Circle()
                                .fill(sessionTint)
                                .frame(width: 9, height: 9)
                                .accessibilityHidden(true)
                            Text(sessionTitle)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        Text(selectedProfileName ?? String(localized: "No profile selected"))
                            .font(HakoTheme.Typography.rowSubtitle(Locale.current))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: HakoTheme.Spacing.compact)

                    StartStopButton(showsRuntimeDuration: true)
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

    private var sessionTitle: String {
        switch profile.status {
        case .connected: String(localized: "Started")
        case .connecting: String(localized: "Starting")
        case .disconnecting: String(localized: "Stopping")
        case .reasserting: String(localized: "Reasserting")
        case .disconnected: String(localized: "Stopped")
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
        if !profile.status.isSwitchable {
            return (String(localized: "Switching…"), nil, .info)
        }
        return nil
    }

    private var selectedProfileName: String? {
        profileList.first { $0.id == selectedProfileID }?.name
    }

    // MARK: - Cards

    @ViewBuilder
    private var profileCard: some View {
        if enabledCards.contains(.profile) || enabledCards.isEmpty {
            ProfileCard(
                profileList: $profileList,
                selectedProfileID: Binding(
                    get: { selectedProfileID },
                    set: { newID in
                        coordinator.reasserting = true
                        Task {
                            await coordinator.switchProfile(
                                newID,
                                profile: profile,
                                environments: environments
                            )
                        }
                    }
                )
            )
        }
    }

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
        HakoSettingsSection(palette: .system) {
            if showGroups {
                shortcutRow(
                    title: String(localized: "Proxies"),
                    subtitle: groupsSubtitle,
                    systemImage: "rectangle.3.group.fill",
                    tint: HakoAccentRole.indigo.color,
                    identifier: "hako.home.groups",
                    action: actions.showGroups
                )
                HakoRowDivider()
            }
            shortcutRow(
                title: String(localized: "Connections"),
                subtitle: connectionsSubtitle,
                systemImage: "list.bullet.rectangle.portrait.fill",
                tint: HakoAccentRole.green.color,
                identifier: "hako.home.connections",
                action: actions.showConnections
            )
            HakoRowDivider()
            shortcutRow(
                title: String(localized: "Logs"),
                subtitle: String(localized: "Tunnel output"),
                systemImage: "list.bullet.rectangle",
                tint: HakoAccentRole.orange.color,
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

    private var groupsSubtitle: String {
        let count = environments.commandClient.groups?.count ?? 0
        return count > 0
            ? String(localized: "\(count) groups")
            : String(localized: "Proxy groups")
    }

    private var connectionsSubtitle: String {
        let count = Int(environments.commandClient.status?.connectionsIn ?? 0)
        return count > 0
            ? String(localized: "\(count) active")
            : String(localized: "Current sessions")
    }
}
