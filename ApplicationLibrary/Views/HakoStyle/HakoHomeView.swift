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
//  Every card, binding and action below is sing-box-for-apple's own: the start/stop control is the
//  tunnel's one state machine (`StartStopButton`), the outbound mode is sent through the same
//  `CommandTarget` the mode card uses, and the traffic and status cards read the command client's
//  stream. None of that is re-implemented here, because a second implementation of any of it would
//  be a second source of truth.
//
//  What HAKO supplies is the page: one canvas, one column, one card language, and destination rows
//  that lead into the rest of the client.
//
//  # What changed when this was taken from `hako-ui` @ `c1935cf`
//
//  Three of this page's dependencies came from the fork's modified copies of shared files rather
//  than from upstream, and each is resolved here rather than by copying the shared file:
//
//    * `StartStopButton` - the fork added an `isCompact` parameter and an "install the tunnel"
//      closure. Upstream's button already carries the whole state machine, including its own alert
//      for a startup error, so the page uses it as it is; the install path is the notice's own
//      action, which is where the fork put that text anyway.
//    * `HTTPProxyCard` - upstream's initialiser is the one the fork calls, and its `onToggle` is
//      wired to `OverviewViewModel.setSystemProxyEnabled`, the same method the card grid's own
//      system-proxy card calls.
//    * `ProfilePickerSheet` - the remaining-quota row is phone presentation and cannot live in a
//      file an iPad can open, so this page presents `HakoProfilePickerSheet` instead. The **data**
//      behind that row is the shared, tested chain and is not forked.
//
//  The page no longer owns an `OverviewViewModel`: the fork used exactly two of that type's
//  members, and one of them wrote an `alert` this page holds itself. Reading the configuration list
//  and the system-proxy snapshot from the `DashboardViewModel` the dashboard already builds and
//  reloads keeps one source of truth for both pages instead of two objects polling the same things.
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
    /// Raised by the one action this page performs itself: sending the outbound mode.
    @State private var alert: AlertState?
    /// The system-proxy action's own state.
    ///
    /// The frozen design holds one `OverviewViewModel` here (`@StateObject private var coordinator`), gives it
    /// to the system-proxy action, presents `$coordinator.alert`, and folds `coordinator.reasserting` into the
    /// page's disable gate. The migration dropped the object and called
    /// `await OverviewViewModel().setSystemProxyEnabled(...)` instead - a **throwaway**, so when the action
    /// fails, `setSystemProxyEnabled` writes the failure to its own `alert` and nothing ever reads it. The
    /// system-proxy failure was silent, and `reasserting` could not reach the gate.
    ///
    /// Held as `@StateObject` rather than `@State` because `OverviewViewModel` is an `ObservableObject`: a
    /// `@State` copy would be rebuilt on every body evaluation, which is the same defect one level down.
    @StateObject private var coordinator = OverviewViewModel()
    /// The system-proxy switch, held locally because the core snapshot is read-only.
    @State private var systemProxyEnabledLocal: Bool

    /// Whether a tunnel profile exists at all.
    ///
    /// When it does not, the page still draws - that is the point - and says so where the reader
    /// is already looking, with the action that fixes it.
    private let tunnelIsInstalled: Bool
    private let installTunnel: () async -> Void
    /// Why the configuration list could not be read, if it could not be.
    private let profileLoadFailure: String?
    @Binding private var profileList: [ProfilePreview]
    /// Whether the configuration centre is open. Opened from the row that used to be a picker.
    @State private var showsConfigurationCentre = false
    @Binding private var selectedProfileID: Int64
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool
    @ObservedObject private var cardConfiguration: DashboardCardConfiguration

    public init(
        profileList: Binding<[ProfilePreview]>,
        selectedProfileID: Binding<Int64>,
        systemProxyAvailable: Binding<Bool>,
        systemProxyEnabled: Binding<Bool>,
        tunnelIsInstalled: Bool = true,
        installTunnel: @escaping () async -> Void = {},
        profileLoadFailure: String? = nil,
        cardConfiguration: DashboardCardConfiguration
    ) {
        self.tunnelIsInstalled = tunnelIsInstalled
        self.installTunnel = installTunnel
        self.profileLoadFailure = profileLoadFailure
        _profileList = profileList
        _selectedProfileID = selectedProfileID
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        _systemProxyEnabledLocal = State(initialValue: systemProxyEnabled.wrappedValue)
        _cardConfiguration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        HakoRootScaffold {
            // The page's first screen, and the reference's own shape for it: a header row on the
            // canvas carrying the configuration's name and the one action that starts or stops it,
            // with the page's condition, if it has one, as a line under it. It was a white card
            // holding the same two things, which is the difference the review's reference image
            // shows - the reference's header sits on the page, not in a card, and its action is a
            // fixed-size capsule rather than the row's full width.
            homeHeader
            // The system HTTP proxy, restored here: it is a proxy entry, and the review moved it
            // back out of the client settings page. It sits with the other cards that describe the
            // current working mode, after the header and before the shortcuts.
            if systemProxyAvailable {
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
        .onChangeCompat(of: systemProxyEnabled) { newValue in
            systemProxyEnabledLocal = newValue
        }
        .alert($coordinator.alert)
        .alert($alert)
        // The same gate the card grid applies: no control on the page may act while the tunnel is
        // moving. Only while it is *moving*: `isSwitchable` is connected-or-disconnected, so testing
        // it disabled the whole page for a client that has no tunnel at all - which greyed out the
        // install action in the notice above and left the page's action inert. A page whose only job
        // is to offer the next step must not be disabled before the first step is taken.
        // `coordinator.reasserting` is the frozen design's second term: turning the system proxy
        // off restarts the service, and the page must not act while that is in flight.
        .disabled(profile.status == .connecting || profile.status == .disconnecting || coordinator.reasserting)
        // Outside the Form and outside the Section: a presentation attached to a `Section` is
        // dropped, because a Section is the Form's layout container rather than a view in the
        // hierarchy. The configuration centre is presented from the page.
        .sheet(isPresented: $showsConfigurationCentre) {
            // Wrapped the way the card that used to present it wrapped it: the centre is a
            // `NavigationSheet`, and that is what gives it a title, a toolbar for its own
            // actions, and a navigation container for the close control below.
            //
            // The close is attached **here**, to the content, rather than to the shared container. A
            // presentation's content is rendered inside the container's `NavigationStackCompat`, so a
            // `.toolbar` on it reaches the same bar - and that keeps the Hako symbol out of
            // `Profile/ProfileSheetHelpers.swift`, which an iPad also compiles. The shared container's own
            // close was the original fork's, and it reached every iPad modal; this reaches only the
            // phone's.
            NavigationSheet(
                title: String(localized: "Profiles"),
                size: .large,
                content: {
                    HakoProfilePickerSheet(
                        profileList: $profileList,
                        selectedProfileID: $selectedProfileID
                    )
                    .environmentObject(environments)
                    .hakoModalClose()
                }
            )
        }
    }

    // MARK: - Session

    /// The top of the page: which configuration is in use, and the action that starts it.
    ///
    /// Structure, type and metrics are the reference's `profileAndPrimaryAction` at commit
    /// 62aa2f2f: a row of `HStack(spacing: Spacing.row)` holding a profile button and a fixed-size
    /// primary action, with the profile's name at `title2.weight(.bold)`, the accessory beside it
    /// at `title3`, and the action a `Control.minimumHitTarget`-tall capsule 104pt wide, tinted by
    /// what it will do. The header is padding on the page's canvas, not a card.
    private var homeHeader: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Spacing.compact) {
            HStack(alignment: .center, spacing: HakoTheme.Spacing.row) {
                profileButton
                Spacer(minLength: HakoTheme.Spacing.compact)
                primaryAction
            }

            // The page's condition, as a line under the header - the reference's error and notice
            // rows, which carry no card of their own either. One line, one `Text`, no control of its
            // own: the header's action is the page's action in every state.
            if let condition {
                Text(condition)
                    .font(.subheadline)
                    .foregroundStyle(HakoAccentRole.orange.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hako.home.condition")
            }

            if let detail = sessionDetail {
                HakoStatusLine(detail.title, detail: detail.value, tint: detail.emphasis)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The configuration's name and the way into the configuration centre, as one control.
    private var profileButton: some View {
        Button {
            showsConfigurationCentre = true
        } label: {
            HStack(spacing: HakoTheme.Spacing.compact) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(HakoAccentRole.primaryAction.color)
                    .accessibilityHidden(true)

                Circle()
                    .fill(sessionTint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(selectedProfileName ?? String(localized: "No profile selected"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Image(systemName: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HakoAccentRole.primaryAction.color)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text(selectedProfileName ?? String(localized: "No profile selected")))
        .accessibilityHint(Text("Opens Profiles"))
        .accessibilityIdentifier("hako.profile.select")
    }

    /// What the page's one action is, and what it says.
    ///
    /// `HakoStartStopButton` is the fork's own component, ported whole by
    /// `scripts/dev/port_hako_components.py`. It is not upstream's `StartStopButton`, and the
    /// difference is the design: upstream's no longer takes `isCompact` - the capsule sized to its own
    /// label that this header needs, because a full-width action beside the configuration's name
    /// pushes the name off the row - and no longer takes the `install` closure, so upstream's control
    /// cannot be the page's action in the state that exists to be fixed.
    ///
    /// The reference fixes this at 104pt because its labels are one word; the same width in Chinese
    /// truncated "断开连接" to "断开…". The reference's *minimum* is kept and the button may grow to
    /// fit its own title.
    private var primaryAction: some View {
        HakoStartStopButton(showsRuntimeDuration: false, isCompact: true) {
            await installTunnel()
        }
        .frame(minWidth: 104, minHeight: HakoTheme.Control.minimumHitTarget)
    }

    /// The condition the page is in, if it is in one: nothing installed, or a configuration that
    /// cannot be read. One line, in one place, with the action beside it in the header.
    ///
    /// A `String?` rather than a view, which is the original's shape: the header draws it as one line
    /// under the configuration's name, and the action is the header's own action rather than a button
    /// this notice grows. The notice used to be a `VStack` holding the text and an "Install" button,
    /// which put a second control in the header and moved the page's action out of the control the
    /// design gives it.
    private var condition: String? {
        if !tunnelIsInstalled {
            return String(localized: "The VPN extension is not installed yet. Install it to start the tunnel.")
        }
        return profileLoadFailure
    }

    /// The line under the configuration's name: what the tunnel is doing, and nothing else.
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

    /// The system HTTP proxy, as the client's own toggle row inside a painted card.
    ///
    /// Upstream's `HTTPProxyCard` with upstream's initialiser. The toggle is sent through
    /// `OverviewViewModel.setSystemProxyEnabled`, the same method the card grid's own system-proxy
    /// card calls, so the page does not grow a second way to change the proxy.
    private var httpProxyCard: some View {
        HTTPProxyCard(
            systemProxyAvailable: $systemProxyAvailable,
            systemProxyEnabled: Binding(
                get: { systemProxyEnabledLocal },
                set: { systemProxyEnabledLocal = $0 }
            )
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
    /// carries the explanation, not a segmented control. A segmented control also had to fit its
    /// labels into the width it was given, so this client carried a `GeometryReader`, two preference
    /// keys and a menu fallback for the case where they did not fit - machinery that no longer has a
    /// reason to exist.
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
                alert = AlertState(action: "set clash mode", error: error)
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
