//
//  HakoHomeView.swift
//  ApplicationLibrary
//
//  The Home page, in the HAKO/Clash page language.
//
//  Structure follows Hako-Client (GPL-3.0) `Features/Home/HakoHomeView.swift` at
//  commit 62aa2f2f: profile and service state first, then the outbound mode, then
//  the shortcuts into proxies and activity, then traffic.
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
//  # Why the cards are not wrapped in a section
//
//  Each card already draws its own surface, now with the shared card radius and
//  insets. Wrapping one in a painted section would put a card inside a card, so the
//  page stacks them on the canvas and only the bare destination rows get a painted
//  section of their own.
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
        HakoPrimaryPage {
            profileCard
            if showsConnectedCards, enabledCards.contains(.clashMode) {
                ClashModeCard()
                    .environmentObject(environments.commandClient)
            }
            shortcutsSection
            if showsConnectedCards {
                trafficCards
                if enabledCards.contains(.httpProxy), systemProxyAvailable {
                    httpProxyCard
                }
                if enabledCards.contains(.status) {
                    StatusCard()
                        .environmentObject(environments.commandClient)
                }
                if enabledCards.contains(.connections) {
                    ConnectionsCard()
                        .environmentObject(environments.commandClient)
                }
            }
        }
        .alert($coordinator.alert)
        // The same gate the card grid applies: while the tunnel is switching
        // profiles or cannot be switched, no control on the page may act. The flag
        // lives here because the switch itself is asynchronous and this page owns the
        // control that started it.
        .disabled(!Variant.screenshotMode && (!profile.status.isSwitchable || coordinator.reasserting))
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

    @ViewBuilder
    private var trafficCards: some View {
        if enabledCards.contains(.uploadTraffic) {
            UploadTrafficCard()
                .environmentObject(environments.commandClient)
        }
        if enabledCards.contains(.downloadTraffic) {
            DownloadTrafficCard()
                .environmentObject(environments.commandClient)
        }
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
    /// presents, and the log page, which is selected rather than pushed so the
    /// existing "logs selected → connect the command client" hook still runs.
    private var shortcutsSection: some View {
        HakoSection(palette: .system) {
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
            HakoDestinationRow(
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
