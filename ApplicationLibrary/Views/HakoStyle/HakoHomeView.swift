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
    /// The mode the core last reported, which is the only value this page may fall back to.
    ///
    /// The core can only report a mode while the tunnel is running and the command client is
    /// connected, so `commandClient.clashMode` stays empty on a cold launch with the tunnel stopped.
    /// A row that waited for it instead of choosing optimistically would not move at all in that
    /// state - which is why `localMode` exists. This field is the other half of that bargain: when a
    /// switch is *refused* rather than merely unconfirmed, the optimistic value has to be given back,
    /// and this is what it is given back to. It is written only from `commandClient.clashMode`, so
    /// it never holds a value the core did not say.
    @State private var confirmedMode: String = ""
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
            confirmedMode = environments.commandClient.clashMode
            localMode = confirmedMode
            liveGroupCount = environments.commandClient.groups?.count ?? 0
            liveConnectionCount = Int(environments.commandClient.status?.connectionsIn ?? 0)
        }
        .onReceive(environments.commandClient.$groups) { groups in
            liveGroupCount = groups?.count ?? 0
        }
        .onReceive(environments.commandClient.statusPublisher) { status in
            liveConnectionCount = Int(status?.connectionsIn ?? 0)
        }
        // The count is this page's own copy of a live figure, and the row that shows it is gated on
        // the tunnel being connected. Clearing it the moment the tunnel stops is what keeps a
        // reconnecting page from showing the previous session's number: `status` turns connected
        // before the new status stream has delivered anything, so for that moment the row would
        // otherwise come back carrying the count from the session before it. The stream itself is
        // still the only thing that ever raises it.
        .onChangeCompat(of: profile.status) { status in
            if !status.isConnected {
                liveConnectionCount = 0
            }
        }
        .onChangeCompat(of: environments.commandClient.clashMode) { newValue in
            if !newValue.isEmpty {
                confirmedMode = newValue
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
    /// primary action, with the profile's name at `title3.weight(.bold)`, the accessory beside it
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
                    .font(.title3.weight(.bold))
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
            return (String(localized: "Remote Control"), nil, .info)
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
    ///
    /// Both cards are given the page's card tone explicitly. The traffic pair above is the
    /// reference for how a card on this page looks, and it is deliberately left exactly as it was:
    /// these two were the pair rendering as a much darker panel, so only they change.
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
            .dashboardCardSurfaceStyle(.hako)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var connectionsCard: some View {
        ConnectionsCard()
            .environmentObject(environments.commandClient)
            .dashboardCardSurfaceStyle(.hako)
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
    ///
    /// `surfaceStyle: .hako` is asked for here and only here: the card is shared with the
    /// dashboard grid, and the card language on this page is this page's, so the phone opts in
    /// rather than the card's default carrying HAKO into the iPad's and the desktop's cards.
    private var httpProxyCard: some View {
        HTTPProxyCard(
            systemProxyAvailable: $systemProxyAvailable,
            systemProxyEnabled: Binding(
                get: { systemProxyEnabledLocal },
                set: { systemProxyEnabledLocal = $0 }
            ),
            surfaceStyle: .hako
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
            // Only while the tunnel is running. The row opens the live connection list and its
            // subtitle counts live sessions, so with nothing connected it offered a way into an
            // empty list and kept showing a count nothing was updating any more. The gate is the
            // page's own - the same one the outbound-mode, traffic and kernel cards use - and the
            // divider is inside it, so the card never ends on a rule of its own.
            if showsConnectedCards {
                shortcutRow(
                    title: String(localized: "Connections"),
                    subtitle: connectionsSubtitle,
                    systemImage: "list.bullet.rectangle.portrait.fill",
                    tint: HakoAccentRole.neutral.color,
                    identifier: "hako.home.connections",
                    action: actions.showConnections
                )
                HakoRowDivider()
            }
            shortcutRow(
                title: String(localized: "Logs"),
                subtitle: logsSubtitle,
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

    /// The outbound mode, in one of the two shapes the list can honestly take.
    ///
    /// The conventional three modes are a quick choice, and the home page draws them the way it
    /// draws a quick choice: one row, three equal thirds, the chosen third marked. Anything else
    /// keeps the reference's shape - a painted section of selection rows, each carrying the reason
    /// its mode exists - because a mode the product has no words for is a setting, and the list
    /// that renders whatever the core sent is the only one that cannot drop it.
    ///
    /// This was a `Picker` with `.segmented` once, and it had to fit its labels into the width it
    /// was given: the client carried a `GeometryReader`, two preference keys and a menu fallback
    /// for the case where they did not fit. Neither shape below measures anything, so none of that
    /// machinery is coming back with the row.
    ///
    /// The list comes from the core, and only the core may decide what is in it: `clashmode`
    /// derives it from the `clash_mode` values that appear in the configuration's route and DNS
    /// rules (`experimental/clashmode/mode_list.go`), and the manager prepends the default mode, so
    /// a configuration that declares none reports exactly one entry and this section stays hidden.
    /// That gate is the reason the control has looked absent rather than merely unstyled: without a
    /// `clash_mode` rule anywhere, there is no mode to offer and no mode for a switch to change.
    ///
    /// The values are reported exactly as the configuration spells them, and the conventional
    /// configuration spells them `Rule`, `Global` and `Direct`. They are therefore never compared
    /// against a lower-case literal here: a mode is recognised by the case-insensitive test the
    /// core itself uses, and every string that reaches the core is a string the core sent - see
    /// `selectClashMode`.
    ///
    /// # Why the section no longer wears a caption
    ///
    /// The explanation each mode used to carry under its own name answers the question the three
    /// words already answer. On a settings page that cost nothing; on the home page it was three
    /// two-line rows - a caption, three subtitles and three selection marks - between the reader
    /// and the shortcuts below, for a control whose whole content is "which of three". The
    /// conventional configuration therefore gets one compact row, and the explanations stay where
    /// they are still a setting's explanation: the fallback below, which serves the modes the
    /// product has no words for.
    ///
    /// A configuration whose list is not exactly the conventional three keeps the list it had -
    /// see `conventionalModes`. It is the only shape that could *lose* a mode, so it is the only
    /// shape that must be allowed to be taller.
    @ViewBuilder
    private var modeSection: some View {
        let modes = environments.commandClient.clashModeList
        let current = currentMode(in: modes)
        if modes.count > 1 {
            if let conventionalModes = conventionalModes(in: modes) {
                HakoPageSection {
                    compactModePicker(modes: conventionalModes, current: current)
                }
            } else {
                HakoPageSection(String(localized: "Outbound Mode")) {
                    ForEach(Array(modes.enumerated()), id: \.offset) { index, mode in
                        if index > 0 {
                            HakoRowDivider()
                        }
                        HakoSelectionRow(
                            title: modeTitle(mode),
                            subtitle: modeExplanation(mode),
                            isSelected: mode.caseInsensitiveCompare(current) == .orderedSame,
                            identifier: "hako.home.mode.\(mode)"
                        ) {
                            selectClashMode(mode)
                        }
                    }
                }
            }
        }
    }

    /// The core's three conventional modes, in the order the picker shows them, or `nil` when the
    /// list is anything else.
    ///
    /// `clash_mode` is not a closed set. `clashmode` builds its list from whatever values the
    /// reader's own route and DNS rules declare, so a configuration may define a fourth mode this
    /// client has never heard of, and upstream may define more later. A picker with three fixed
    /// slots would drop that value - it would be missing from the screen and unreachable from it -
    /// so the compact shape is offered only when the list is exactly `Rule`, `Global` and
    /// `Direct`, and everything else falls back to the list that renders whatever it is given.
    ///
    /// The test is the core's own, case-insensitively: the configuration decides the spelling, and
    /// `rule`, `GLOBAL`, `Direct` is as conventional as `Rule`, `Global`, `Direct`. The order the
    /// core reports is not the test either - the list is a set of modes, and the picker's order is
    /// the reading order of the three words, so a core that reports them reversed still gets the
    /// same control. What is returned is the core's own spelling, because that is what the core
    /// accepts and what `selectClashMode` must send back.
    ///
    /// Present-and-three is a complete answer: a list holding all three of three values holds no
    /// others, and so holds no duplicates, which is why each returned element has exactly one
    /// match in the list it came from.
    private func conventionalModes(in modes: [String]) -> [String]? {
        guard modes.count == 3 else {
            return nil
        }
        let conventional = ["rule", "global", "direct"]
        let matched = conventional.compactMap { name in
            modes.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return matched.count == conventional.count ? matched : nil
    }

    /// The three conventional modes as one row of equal thirds: the home page's shape for the
    /// choice, where the reference's three rows are the settings page's shape for it.
    ///
    /// The row is `HakoTheme.Control.compactChoiceRowMinHeight` tall - the touch target - and the
    /// chosen third is marked by a `HakoTheme.Control.segmentedTabHeight` capsule of the design
    /// system's chosen-surface fill. The selected fill is the accent at
    /// `HakoTheme.Opacity.selectedFill`, which is the same weight the page's other chosen surfaces
    /// wear; the unselected thirds stay at full primary text, because a mode one may switch to is
    /// not a disabled control. Nothing else is drawn: no icons, no captions, no selection marks,
    /// and no dividers, which is what keeps one row one row.
    ///
    /// Equal thirds come from `maxWidth: .infinity` and a zero spacing, so the three labels sit in
    /// one `HStack` and divide it. Nothing here measures text: the three words are two characters
    /// each and the row is the page's width.
    ///
    /// Every one of the three is `hako.home.mode.<the core's spelling>`, the identifier the
    /// fallback rows carry, so a test naming a mode names it the same way in either shape. Each
    /// carries the selected trait the fallback row carries, for the same reason.
    private func compactModePicker(modes: [String], current: String) -> some View {
        HStack(spacing: 0) {
            ForEach(modes, id: \.self) { mode in
                let isSelected = mode.caseInsensitiveCompare(current) == .orderedSame
                Button {
                    selectClashMode(mode)
                } label: {
                    Text(modeTitle(mode))
                        .font(isSelected
                            ? HakoTheme.FontRole.rowPrimary.weight(.semibold)
                            : HakoTheme.FontRole.rowPrimary)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, HakoTheme.Spacing.compact)
                        .frame(height: HakoTheme.Control.segmentedTabHeight)
                        .background(
                            Capsule().fill(isSelected
                                ? Color.accentColor.opacity(HakoTheme.Opacity.selectedFill)
                                : Color.clear)
                        )
                        .frame(maxWidth: .infinity, minHeight: HakoTheme.Control.compactChoiceRowMinHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HakoCompactChoiceButtonStyle())
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("hako.home.mode.\(mode)")
            }
        }
    }

    /// The mode the section marks as chosen: the local choice while one is pending, otherwise what
    /// the core last reported.
    ///
    /// Matched against the core's own list case-insensitively, and returned in the core's own
    /// spelling, so a core that reports `Rule` and a local choice of `rule` are the same mode
    /// rather than two rows lit at once or none.
    private func currentMode(in modes: [String]) -> String {
        let candidate = localMode.isEmpty ? confirmedMode : localMode
        return canonicalMode(candidate, in: modes)
    }

    /// The core's own spelling of `mode`, or `mode` itself when the list does not contain it.
    ///
    /// The list is read from the core, so its element is by construction a value the core accepts;
    /// echoing it back is what keeps the display name and the value the core is sent from drifting
    /// apart. `SetMode` normalises case itself, but normalising here means a switch sends the same
    /// string the row is labelled with.
    private func canonicalMode(_ mode: String, in modes: [String]) -> String {
        modes.first { $0.caseInsensitiveCompare(mode) == .orderedSame } ?? mode
    }

    /// The name a reader sees for a core mode value, or the value itself when it is not one of the
    /// three the product has words for.
    ///
    /// The core's values are not guaranteed lower-case: the list is whatever the configuration
    /// declared, and the conventional spelling is `Rule`, `Global`, `Direct`. Matching the literal
    /// lower-case names was a defect with two visible faces - a translated name was never used for a
    /// conventional configuration, and a genuinely unknown future mode was echoed through
    /// `capitalized`, which is a transformation rather than the value. Folding the case first fixes
    /// the first and dropping the transformation fixes the second: an unrecognised mode is shown
    /// exactly as the core named it, so a mode this client has never heard of still appears and is
    /// still selectable.
    private func modeTitle(_ mode: String) -> String {
        switch mode.lowercased() {
        case "rule": String(localized: "Rules")
        case "global": String(localized: "Global")
        case "direct": String(localized: "Direct")
        default: mode
        }
    }

    /// The reason the mode exists, for a mode the product has a reason for. `nil` for any other,
    /// which is what the reference does with a mode it has no copy for: the row keeps its name and
    /// grows no explanation rather than wearing one borrowed from a different mode.
    private func modeExplanation(_ mode: String) -> String? {
        switch mode.lowercased() {
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
    ///
    /// The optimistic half needs the other half to be complete, and it was not: a switch that
    /// *failed* - the tunnel stopped between the row being drawn and the row being pressed, a mode
    /// the core's list does not accept - raised its alert and left the chosen row lit over a core
    /// that had never moved, because a failure is not a report and nothing else writes `localMode`.
    /// The refusal is therefore given back to the last value the core did report. That value is
    /// `confirmedMode`, never a fresh read of `commandClient.clashMode`: when the client is
    /// disconnected that property is empty, and falling back to it would silently move the
    /// selection again instead of restoring what the reader had.
    private func selectClashMode(_ mode: String) {
        let modes = environments.commandClient.clashModeList
        let requested = canonicalMode(mode, in: modes)
        withAnimation {
            localMode = requested
        }
        // The fixture runs no tunnel, so there is no command server to send to. Attempting
        // it raises a blocking alert with an IPC error over the very page a snapshot exists
        // to photograph, and the alert reports a condition the fixture invented.
        guard !Variant.screenshotMode else {
            return
        }
        Task {
            do {
                try CommandTarget.standaloneClient().setClashMode(requested)
            } catch {
                alert = AlertState(action: "set clash mode", error: error)
                withAnimation {
                    localMode = confirmedMode
                }
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

    /// What the logs row says it opens.
    ///
    /// With the tunnel up the log stream is the tunnel's own output. With it down there is no
    /// stream to describe - the page opens what the client has already collected - so the
    /// subtitle says that rather than promising output that is not arriving.
    private var logsSubtitle: String {
        showsConnectedCards
            ? String(localized: "Tunnel output")
            : String(localized: "Recent logs")
    }
}

/// The press feedback of one third of the compact mode picker.
///
/// A plain `Button` inside a card has no highlight on touch platforms, which is why the page's
/// rows carry `HakoPushRowButtonStyle`; this is that style for a control whose shape is a
/// capsule rather than a row - the same `HakoTheme.Opacity.pressedFill` weight, on the third
/// the finger is on rather than on the whole card. The chosen third's own mark is drawn by the
/// label, so this never competes with it.
private struct HakoCompactChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(
                    configuration.isPressed
                        ? Color.primary.opacity(HakoTheme.Opacity.pressedFill)
                        : Color.clear
                )
            )
    }
}
