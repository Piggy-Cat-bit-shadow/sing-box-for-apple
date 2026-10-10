//
//  HakoSettingView.swift
//  ApplicationLibrary
//
//  The phone's More page, from `hako-ui` @ `c1935cf`.
//
//  # Why this is a copy rather than a wrapper
//
//  The reference's change is a rewrite of the page rather than a decoration of it: `SettingView.swift`
//  is 250 lines upstream and 490 in the reference, and the reference version is the
//  page. A wrapper would have had to reimplement it anyway.
//
//  So the page lives here, in the fork's own namespace, reachable only from the phone. Upstream's
//  `ApplicationLibrary/Views/Setting/SettingView.swift` stays upstream's, which is
//  what keeps an iPad and a Mac on upstream's presentation.
//
//  # What is deliberately not here
//
//  The pages this one leads to. Every one of them is still upstream's: the reference's change to each
//  is a single modifier or a single row, and the page a user lands on is what this slice delivers.
//  The list, with what each needs, is in `docs/HAKO-LOSSLESS-PARITY-AUDIT.md`.
//
//  Generated from `c1935cf` by `scripts/dev/port_tools_and_more.py`. That script resolves the
//  reference's platform conditionals for iPhone and drops the declarations the shared tree already
//  owns; re-run it rather than editing here, or the next run will disagree with this file.
//

import Library
import SwiftUI


    private struct HakoPendingSettingsPageKey: EnvironmentKey {
        static let defaultValue: Binding<SettingsPage?>? = nil
    }

    public extension EnvironmentValues {
        /// A settings page the root has been asked to open, applied by the settings page itself
        /// once it exists.
        ///
        /// The request cannot be delivered to the settings page directly: `.remoteControl` is
        /// pushed from the settings root, and when the notification arrives from another tab that
        /// root is not installed yet, so a receiver inside it never runs. It is recorded here, at
        /// the level that is always installed, and applied on appearance.
        var pendingSettingsPage: Binding<SettingsPage?>? {
            get { self[HakoPendingSettingsPageKey.self] }
            set { self[HakoPendingSettingsPageKey.self] = newValue }
        }
    }


/// What the settings page should do about a page the root asked it to open.
///
/// A value rather than three lines inside a view, because the interesting cases are the ones a
/// screenshot cannot show: a request that arrives before the page exists, one that arrives while
/// the page is already open, and one that names a page this mechanism does not push.
public enum HakoSettingsRoute {
    public struct HakoSettingsPushDecision: Equatable {
        /// Whether to open the remote-control page now.
        public let pushRemoteControl: Bool
        /// Whether the request has been satisfied and must not be applied again.
        public let clearRequest: Bool

        public init(pushRemoteControl: Bool, clearRequest: Bool) {
            self.pushRemoteControl = pushRemoteControl
            self.clearRequest = clearRequest
        }
    }

    /// The only page the settings root pushes programmatically. The others are sections of the
    /// root itself, so reaching them needs no push at all.
    public static let pushedPage: SettingsPage = .remoteControl

    public static func decide(requested: SettingsPage?, isRemoteControlPresented: Bool) -> HakoSettingsPushDecision {
        guard let requested, requested == pushedPage else {
            // Nothing was asked for, or something this mechanism does not push. Clearing a request
            // it cannot satisfy would silently drop a page the user asked for, so it is left alone.
            return HakoSettingsPushDecision(pushRemoteControl: false, clearRequest: false)
        }
        guard !isRemoteControlPresented else {
            // Already open: the request is satisfied, and pushing again would give the user two
            // copies of the page to dismiss.
            return HakoSettingsPushDecision(pushRemoteControl: false, clearRequest: true)
        }
        return HakoSettingsPushDecision(pushRemoteControl: true, clearRequest: true)
    }
}



public struct HakoSettingView: View {
    /// A destination the More tab can open.
    ///
    /// It carries everything the row needs and everything the push needs, so the two
    /// cannot disagree: a row whose title says one thing and whose destination is
    /// another is the kind of defect a hand-written list of links produces.
    struct HakoSettingsDestination: Identifiable {
        var id: String {
            pageKey
        }

        let pageKey: String
        let title: String
        /// One short line saying what the page is for, in the user's terms.
        let subtitle: String
        let systemImage: String
        let accent: HakoAccentRole
        /// Whether the row leaves the app rather than pushing a page.
        var linksOut: Bool = false
        let content: () -> AnyView


    }

    /// The More tab's information architecture.
    ///
    /// The tab this replaces was a flat list of the client's own vocabulary - App, Core,
    /// Packet Tunnel, On Demand Rules, Profile Override, Remote Control - which is a
    /// map of the source tree rather than of anything a user does. The same pages are
    /// here, grouped by the question they answer.
    struct HakoSettingsSectionGroup: Identifiable {
        var id: String {
            title
        }

        let title: String
        let destinations: [HakoSettingsDestination]
    }


        @State private var showRemoteControl = false
        @Environment(\.pendingSettingsPage) private var pendingSettingsPage


    public init() {}

    public var body: some View {


            compactBody

    }

    // MARK: - The compact root


        private var compactBody: some View {
            HakoRootScaffold {
                ForEach(groups) { group in
                    HakoPageSection(group.title) {
                        ForEach(Array(group.destinations.enumerated()), id: \.element.id) { index, destination in
                            navigationRow(destination)
                            if index != group.destinations.count - 1 {
                                HakoRowDivider()
                            }
                        }
                    }
                }

                aboutSection
            }
            .onAppear { applyPendingSettingsPage() }
            .onChangeCompat(of: pendingSettingsPage?.wrappedValue) { _ in
                applyPendingSettingsPage()
            }
        }

        @ViewBuilder
        private func navigationRow(_ destination: HakoSettingsDestination) -> some View {
            Group {
                if destination.pageKey == SettingsPage.remoteControl.settingsKey {
                    NavigationLink(isActive: $showRemoteControl) {
                        destination.content()
                    } label: {
                        rowLabel(destination)
                    }
                } else {
                    NavigationLink {
                        destination.content()
                    } label: {
                        rowLabel(destination)
                    }
                }
            }
            .buttonStyle(HakoPushRowButtonStyle())
            // Addressable without matching a localized label, so a UI test can reach a
            // settings page in any language - which is the only way the localization can
            // be tested at all.
            .accessibilityIdentifier("hako.more.\(destination.pageKey)")
        }

        private func rowLabel(_ destination: HakoSettingsDestination) -> some View {
            HakoNavigationRow(
                title: destination.title,
                subtitle: destination.subtitle,
                systemImage: destination.systemImage,
                tint: destination.accent.color,
                linksOut: destination.linksOut
            )
        }

        /// Applies a settings page the root asked for, now that this page exists.
        ///
        /// The request is cleared before the push so a later appearance cannot push twice, and the
        /// guard on `showRemoteControl` covers the other direction: a request that arrives while
        /// the page is already open is already satisfied.
        private func applyPendingSettingsPage() {
            let decision = HakoSettingsRoute.decide(
                requested: pendingSettingsPage?.wrappedValue,
                isRemoteControlPresented: showRemoteControl
            )
            if let requested = pendingSettingsPage?.wrappedValue {
                HakoUITrace.transition(
                    "settings-apply \(requested)",
                    from: showRemoteControl ? "presented" : "absent",
                    to: decision.pushRemoteControl ? "push" : "no-push",
                    source: "HakoSettingView.applyPendingSettingsPage"
                )
            }
            if decision.clearRequest {
                pendingSettingsPage?.wrappedValue = nil
            }
            if decision.pushRemoteControl {
                showRemoteControl = true
            }
        }


    // MARK: - The desktop form


    // MARK: - About


        private var aboutSection: some View {
            HakoPageSection(String(localized: "About")) {
                Link(destination: URL(string: String(localized: "https://sing-box.sagernet.org/"))!) {
                    rowLabel(aboutDestination(
                        title: String(localized: "Documentation"),
                        subtitle: String(localized: "The manual for the core this client runs"),
                        systemImage: "doc.text.fill",
                        accent: HakoAccentRole.neutral
                    ))
                }
                .buttonStyle(HakoPushRowButtonStyle())
                HakoRowDivider()
                Link(destination: URL(string: "https://github.com/Piggy-Cat-bit-shadow/sing-box")!) {
                    rowLabel(aboutDestination(
                        title: String(localized: "Source Code"),
                        subtitle: String(localized: "This client's repository"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        accent: HakoAccentRole.neutral
                    ))
                }
                .buttonStyle(HakoPushRowButtonStyle())
                // The last row of the longest root page: the bottom-safe-area check needs
                // something to ask about once the page is scrolled to its end.
                .accessibilityIdentifier("hako.more.sourceCode")
            }
        }

        /// An About entry uses the same row as a settings destination, so the section does
        /// not switch visual language halfway down the page. It has no destination, which
        /// is why the disclosure is suppressed: the row leaves the app, it does not push.
        private func aboutDestination(
            title: String,
            subtitle: String?,
            systemImage: String,
            accent: HakoAccentRole
        ) -> HakoSettingsDestination {
            HakoSettingsDestination(
                pageKey: "about.\(title)",
                title: title,
                subtitle: subtitle ?? "",
                systemImage: systemImage,
                accent: accent,
                linksOut: true,
                content: { AnyView(EmptyView()) }
            )
        }


    // MARK: - The map

    private var groups: [HakoSettingsSectionGroup] {
        [
            HakoSettingsSectionGroup(title: String(localized: "Connection Behavior"), destinations: [
                HakoSettingsDestination(
                    pageKey: "onDemandRules",
                    title: String(localized: "On Demand"),
                    subtitle: String(localized: "When the tunnel connects and disconnects by itself"),
                    systemImage: "filemenu.and.selection",
                    accent: HakoAccentRole.neutral,
                    content: { AnyView(HakoOnDemandRulesView()) }
                ),
                HakoSettingsDestination(
                    pageKey: "packetTunnel",
                    title: String(localized: "Tunnel"),
                    subtitle: String(localized: "What the system routes through the tunnel"),
                    systemImage: "aspectratio.fill",
                    accent: HakoAccentRole.neutral,
                    content: { AnyView(HakoPacketTunnelView()) }
                ),
                HakoSettingsDestination(
                    pageKey: "profileOverride",
                    title: String(localized: "Profile Override"),
                    subtitle: String(localized: "Routes the client adjusts for compatibility"),
                    systemImage: "square.dashed.inset.filled",
                    accent: HakoAccentRole.neutral,
                    content: { AnyView(HakoProfileOverrideView()) }
                ),
            ]),
            HakoSettingsSectionGroup(title: String(localized: "Core Settings"), destinations: [
                HakoSettingsDestination(
                    pageKey: "core",
                    title: String(localized: "Core"),
                    subtitle: String(localized: "Version and working directory"),
                    systemImage: "shippingbox.fill",
                    accent: HakoAccentRole.neutral,
                    content: { AnyView(HakoCoreView()) }
                ),
            ]),
            HakoSettingsSectionGroup(title: String(localized: "App Settings"), destinations: [
                HakoSettingsDestination(
                    pageKey: "app",
                    title: String(localized: "Client Settings"),
                    subtitle: String(localized: "Language, menu bar, updates and caches"),
                    systemImage: "app.badge.fill",
                    accent: HakoAccentRole.neutral,
                    content: { AnyView(HakoAppView()) }
                ),
            ]),
            HakoSettingsSectionGroup(title: String(localized: "Integrations"), destinations: [
                HakoSettingsDestination(
                    pageKey: "remoteControl",
                    title: String(localized: "Remote Control"),
                    subtitle: String(localized: "Drive another device from this one"),
                    systemImage: "antenna.radiowaves.left.and.right",
                    accent: HakoAccentRole.neutral,
                    content: { AnyView(HakoRemoteControlView()) }
                ),
            ]),
        ]
    }
}

private extension SettingsPage {
    /// The page a destination key names, for the desktop's value links.
    init?(settingsKey: String) {
        guard let page = SettingsPage.allSettingsKeys.first(where: { $0.settingsKey == settingsKey }) else {
            return nil
        }
        self = page
    }

    static var allSettingsKeys: [SettingsPage] {
        [.app, .core, .packetTunnel, .onDemandRules, .profileOverride, .remoteControl]
    }

    /// The key `HakoSettingsRoute` and the destination list agree on.
    /// Opens a named settings page for the screenshot harness, which captures one page per
    /// launch rather than driving the UI test suite: the suite relaunches the app repeatedly
    /// and takes the simulator over, which is the wrong tool for collecting stills.
    public init?(snapshotValue: String) {
        switch snapshotValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "app", "clientsettings": self = .app
        case "core": self = .core
        case "tunnel", "packettunnel": self = .packetTunnel
        case "ondemand", "ondemandrules": self = .onDemandRules
        case "profileoverride", "override": self = .profileOverride
        case "remotecontrol": self = .remoteControl
        default: return nil
        }
    }

    var settingsKey: String {
        switch self {
        case .app: "app"
        case .core: "core"
        case .packetTunnel: "packetTunnel"
        case .onDemandRules: "onDemandRules"
        case .profileOverride: "profileOverride"
        case .remoteControl: "remoteControl"
        case .sponsors: "sponsors"
        }
    }
}
