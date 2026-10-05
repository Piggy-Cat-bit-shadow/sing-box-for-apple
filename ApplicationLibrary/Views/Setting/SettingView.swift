import Library
import SwiftUI

#if os(macOS)
    private struct SettingsNavigationPathKey: EnvironmentKey {
        static let defaultValue: Binding<NavigationPath>? = nil
    }

    public extension EnvironmentValues {
        var settingsNavigationPath: Binding<NavigationPath>? {
            get { self[SettingsNavigationPathKey.self] }
            set { self[SettingsNavigationPathKey.self] = newValue }
        }
    }
#endif

#if os(iOS)
    private struct PendingSettingsPageKey: EnvironmentKey {
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
            get { self[PendingSettingsPageKey.self] }
            set { self[PendingSettingsPageKey.self] = newValue }
        }
    }
#endif

/// What the settings page should do about a page the root asked it to open.
///
/// A value rather than three lines inside a view, because the interesting cases are the ones a
/// screenshot cannot show: a request that arrives before the page exists, one that arrives while
/// the page is already open, and one that names a page this mechanism does not push.
public enum HakoSettingsPush {
    public struct Decision: Equatable {
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

    public static func decide(requested: SettingsPage?, isRemoteControlPresented: Bool) -> Decision {
        guard let requested, requested == pushedPage else {
            // Nothing was asked for, or something this mechanism does not push. Clearing a request
            // it cannot satisfy would silently drop a page the user asked for, so it is left alone.
            return Decision(pushRemoteControl: false, clearRequest: false)
        }
        guard !isRemoteControlPresented else {
            // Already open: the request is satisfied, and pushing again would give the user two
            // copies of the page to dismiss.
            return Decision(pushRemoteControl: false, clearRequest: true)
        }
        return Decision(pushRemoteControl: true, clearRequest: true)
    }
}

public extension Notification.Name {
    static let navigateToSettingsPage = Notification.Name("navigateToSettingsPage")
}

public enum SettingsPage: Hashable {
    case app
    case core, packetTunnel, onDemandRules, profileOverride, remoteControl, sponsors
}

public struct SettingView: View {
    /// A destination the More tab can open.
    ///
    /// It carries everything the row needs and everything the push needs, so the two
    /// cannot disagree: a row whose title says one thing and whose destination is
    /// another is the kind of defect a hand-written list of links produces.
    struct Destination: Identifiable {
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
        #if os(macOS)
            /// The value `NavigationLink(value:)` pushes. Derived from the row's own key
            /// rather than written twice, so a row cannot push a page it does not name.
            var page: SettingsPage? {
                SettingsPage(settingsKey: pageKey)
            }
        #endif
    }

    /// The More tab's information architecture.
    ///
    /// The tab this replaces was a flat list of the client's own vocabulary - App, Core,
    /// Packet Tunnel, On Demand Rules, Profile Override, Remote Control - which is a
    /// map of the source tree rather than of anything a user does. The same pages are
    /// here, grouped by the question they answer.
    struct SettingsGroup: Identifiable {
        var id: String {
            title
        }

        let title: String
        let destinations: [Destination]
    }

    #if os(iOS)
        @State private var showRemoteControl = false
        @Environment(\.pendingSettingsPage) private var pendingSettingsPage
    #endif

    public init() {}

    public var body: some View {
        #if os(macOS) || os(tvOS)
            formBody
        #else
            compactBody
        #endif
    }

    // MARK: - The compact root

    #if os(iOS)
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
        private func navigationRow(_ destination: Destination) -> some View {
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

        private func rowLabel(_ destination: Destination) -> some View {
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
            let decision = HakoSettingsPush.decide(
                requested: pendingSettingsPage?.wrappedValue,
                isRemoteControlPresented: showRemoteControl
            )
            if let requested = pendingSettingsPage?.wrappedValue {
                HakoUITrace.transition(
                    "settings-apply \(requested)",
                    from: showRemoteControl ? "presented" : "absent",
                    to: decision.pushRemoteControl ? "push" : "no-push",
                    source: "SettingView.applyPendingSettingsPage"
                )
            }
            if decision.clearRequest {
                pendingSettingsPage?.wrappedValue = nil
            }
            if decision.pushRemoteControl {
                showRemoteControl = true
            }
        }
    #endif

    // MARK: - The desktop form

    #if os(macOS) || os(tvOS)
        private var formBody: some View {
            FormView {
                ForEach(desktopGroups) { group in
                    Section {
                        ForEach(group.destinations) { destination in
                            #if os(macOS)
                                FormNavigationLink(value: destination.page) {
                                    HakoToolRow(
                                        title: destination.title,
                                        systemImage: destination.systemImage,
                                        tint: destination.accent
                                    )
                                }
                            #else
                                FormNavigationLink {
                                    destination.content()
                                } label: {
                                    HakoToolRow(
                                        title: destination.title,
                                        systemImage: destination.systemImage,
                                        tint: destination.accent
                                    )
                                }
                            #endif
                        }
                    } header: {
                        Text(group.title)
                    }
                }

                aboutFormSection
            }
            #if os(macOS)
            .formNavigationDestination(for: SettingsPage.self) { page in
                Self.destinationView(for: page)
            }
            #endif
        }

        #if os(macOS)
            @MainActor
            private static func destinationView(for page: SettingsPage) -> some View {
                Group {
                    switch page {
                    case .app:
                        AppView()
                    case .core:
                        CoreView()
                    case .packetTunnel:
                        PacketTunnelView()
                    case .onDemandRules:
                        OnDemandRulesView()
                    case .profileOverride:
                        ProfileOverrideView()
                    case .remoteControl:
                        RemoteControlView()
                    case .sponsors:
                        SponsorsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        #endif
    #endif

    // MARK: - About

    #if os(iOS)
        private var aboutSection: some View {
            HakoPageSection(String(localized: "About")) {
                Link(destination: URL(string: String(localized: "https://sing-box.sagernet.org/"))!) {
                    rowLabel(aboutDestination(
                        title: String(localized: "Documentation"),
                        subtitle: String(localized: "The manual for the core this client runs"),
                        systemImage: "doc.text.fill",
                        accent: .blue
                    ))
                }
                .buttonStyle(HakoPushRowButtonStyle())
                HakoRowDivider()
                Link(destination: URL(string: "https://github.com/Piggy-Cat-bit-shadow/sing-box")!) {
                    rowLabel(aboutDestination(
                        title: String(localized: "Source Code"),
                        subtitle: String(localized: "This client's repository"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        accent: .purple
                    ))
                }
                .buttonStyle(HakoPushRowButtonStyle())
                HakoRowDivider()
                RequestReviewButton {
                    rowLabel(aboutDestination(
                        title: String(localized: "Rate on the App Store"),
                        subtitle: nil,
                        systemImage: "text.bubble.fill",
                        accent: .pink
                    ))
                }
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
        ) -> Destination {
            Destination(
                pageKey: "about.\(title)",
                title: title,
                subtitle: subtitle ?? "",
                systemImage: systemImage,
                accent: accent,
                linksOut: true,
                content: { AnyView(EmptyView()) }
            )
        }
    #endif

    #if os(macOS) || os(tvOS)
        private var aboutFormSection: some View {
            Section("About") {
                Link(destination: URL(string: String(localized: "https://sing-box.sagernet.org/"))!) {
                    Label("Documentation", systemImage: "doc.on.doc.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .contextMenu {
                    Link(destination: URL(string: String(localized: "https://sing-box.sagernet.org/changelog/"))!) {
                        Text("Changelog")
                    }
                    Link(destination: URL(string: String(localized: "https://sing-box.sagernet.org/configuration/"))!) {
                        Text("Configuration")
                    }
                }
                Link(destination: URL(string: String("https://github.com/Piggy-Cat-bit-shadow/sing-box"))!) {
                    Label("Source Code", systemImage: "pills.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .contextMenu {
                    Link(destination: URL(string: "https://github.com/Piggy-Cat-bit-shadow/sing-box/releases")!) {
                        Text("Releases")
                    }
                }
                RequestReviewButton {
                    Label("Rate on the App Store", systemImage: "text.bubble.fill")
                }
                #if os(macOS)
                    // Sponsors is part of the About section on the desktop, because that
                    // is where the platform's own settings windows put it, and because
                    // the desktop only offers it on the system-extension build.
                    if Variant.useSystemExtension {
                        ForEach(sponsorsDestination) { destination in
                            FormNavigationLink(value: destination.page) {
                                HakoToolRow(
                                    title: destination.title,
                                    systemImage: destination.systemImage,
                                    tint: destination.accent
                                )
                            }
                        }
                    }
                    #if JAILBREAK
                        FormNavigationLink {
                            JailbreakView()
                        } label: {
                            Label("Jailbreak", systemImage: "lock.shield.fill")
                        }
                    #endif
                #endif
            }
        }

        private var sponsorsDestination: [Destination] {
            groups.flatMap(\.destinations).filter { $0.pageKey == "sponsors" }
        }

        /// The desktop renders the same groups minus the ones the About section owns.
        private var desktopGroups: [SettingsGroup] {
            #if os(macOS)
                groups.filter { $0.id != String(localized: "Support") }
            #else
                groups
            #endif
        }
    #endif

    // MARK: - The map

    private var groups: [SettingsGroup] {
        [
            SettingsGroup(title: String(localized: "Connection Behavior"), destinations: [
                Destination(
                    pageKey: "onDemandRules",
                    title: String(localized: "On Demand"),
                    subtitle: String(localized: "When the tunnel connects and disconnects by itself"),
                    systemImage: "filemenu.and.selection",
                    accent: .orange,
                    content: { AnyView(OnDemandRulesView()) }
                ),
                Destination(
                    pageKey: "packetTunnel",
                    title: String(localized: "Tunnel"),
                    subtitle: String(localized: "What the system routes through the tunnel"),
                    systemImage: "aspectratio.fill",
                    accent: .teal,
                    content: { AnyView(PacketTunnelView()) }
                ),
            ]),
            SettingsGroup(title: String(localized: "App Settings"), destinations: [
                Destination(
                    pageKey: "app",
                    title: String(localized: "Client Settings"),
                    subtitle: String(localized: "Language, menu bar, updates and caches"),
                    systemImage: "app.badge.fill",
                    accent: .blue,
                    content: { AnyView(AppView()) }
                ),
            ]),
            SettingsGroup(title: String(localized: "Core Settings"), destinations: [
                Destination(
                    pageKey: "core",
                    title: String(localized: "Core"),
                    subtitle: String(localized: "Version and working directory"),
                    systemImage: "shippingbox.fill",
                    accent: .indigo,
                    content: { AnyView(CoreView()) }
                ),
            ]),
            SettingsGroup(title: String(localized: "Remote and Configuration"), destinations: [
                Destination(
                    pageKey: "profileOverride",
                    title: String(localized: "Profile Override"),
                    subtitle: String(localized: "Routes the client adjusts for compatibility"),
                    systemImage: "square.dashed.inset.filled",
                    accent: .purple,
                    content: { AnyView(ProfileOverrideView()) }
                ),
                Destination(
                    pageKey: "remoteControl",
                    title: String(localized: "Remote Control"),
                    subtitle: String(localized: "Drive another device from this one"),
                    systemImage: "antenna.radiowaves.left.and.right",
                    accent: .cyan,
                    content: { AnyView(RemoteControlView()) }
                ),
            ]),
            SettingsGroup(title: String(localized: "Support"), destinations: [
                Destination(
                    pageKey: "sponsors",
                    title: String(localized: "Sponsors"),
                    subtitle: String(localized: "Support the project"),
                    systemImage: "heart.fill",
                    accent: .pink,
                    content: { AnyView(SponsorsView()) }
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
        [.app, .core, .packetTunnel, .onDemandRules, .profileOverride, .remoteControl, .sponsors]
    }

    /// The key `HakoSettingsPush` and the destination list agree on.
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
