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
    private enum Tabs: Int, CaseIterable, Identifiable {
        var id: Self {
            self
        }

        case app, core, packetTunnel, onDemandRules, profileOverride, remoteControl, sponsors

        #if os(macOS)
            var page: SettingsPage {
                switch self {
                case .app:
                    return .app
                case .core:
                    return .core
                case .packetTunnel:
                    return .packetTunnel
                case .onDemandRules:
                    return .onDemandRules
                case .profileOverride:
                    return .profileOverride
                case .remoteControl:
                    return .remoteControl
                case .sponsors:
                    return .sponsors
                }
            }
        #endif

        /// The row this page presents.
        ///
        /// The two idioms are the ones the whole design system uses: the touch
        /// platforms draw a tinted icon well with a chevron, and the desktop keeps
        /// the platform's own settings row, where an icon well would read as a
        /// foreign element in a `Form`.
        @ViewBuilder
        var label: some View {
            #if os(macOS)
                Label(title, systemImage: iconImage)
            #else
                HakoDestinationRow(
                    title: title,
                    systemImage: iconImage,
                    tint: accent.color
                )
            #endif
        }

        /// The tint of this destination's icon well.
        private var accent: HakoAccentRole {
            switch self {
            case .app: return .blue
            case .core: return .indigo
            case .packetTunnel: return .teal
            case .onDemandRules: return .orange
            case .profileOverride: return .purple
            case .remoteControl: return .cyan
            case .sponsors: return .pink
            }
        }

        var title: String {
            switch self {
            case .app:
                return String(localized: "App")
            case .core:
                return String(localized: "Core")
            case .packetTunnel:
                return String(localized: "Packet Tunnel")
            case .onDemandRules:
                return String(localized: "On Demand Rules")
            case .profileOverride:
                return String(localized: "Profile Override")
            case .remoteControl:
                return String(localized: "Remote Control")
            case .sponsors:
                return String(localized: "Sponsors")
            }
        }

        private var iconImage: String {
            switch self {
            case .app:
                return "app.badge.fill"
            case .core:
                return "shippingbox.fill"
            case .packetTunnel:
                return "aspectratio.fill"
            case .onDemandRules:
                return "filemenu.and.selection"
            case .profileOverride:
                return "square.dashed.inset.filled"
            case .remoteControl:
                return "antenna.radiowaves.left.and.right"
            case .sponsors:
                return "heart.fill"
            }
        }

        @MainActor
        var contentView: some View {
            Group {
                switch self {
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
            #if os(iOS)
                .background(Color(uiColor: .systemGroupedBackground))
            #endif
        }

        @MainActor
        var navigationLink: some View {
            #if os(macOS)
                FormNavigationLink(value: page) {
                    label
                }
            #else
                FormNavigationLink {
                    contentView
                } label: {
                    label
                }
            #endif
        }
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

    #if os(iOS)
        @State private var showRemoteControl = false
        #if os(iOS)
            @Environment(\.pendingSettingsPage) private var pendingSettingsPage
        #endif
    #endif

    public init() {}
    public var body: some View {
        FormView {
            Section {
                Tabs.app.navigationLink
                Tabs.core.navigationLink
                #if !os(tvOS)
                    Tabs.packetTunnel.navigationLink
                #endif
                Tabs.onDemandRules.navigationLink
                Tabs.profileOverride.navigationLink
                #if !os(tvOS)
                    remoteControlLink
                #endif
                #if JAILBREAK
                    FormNavigationLink {
                        JailbreakView()
                    } label: {
                        Label("Jailbreak", systemImage: "lock.shield.fill")
                    }
                #endif
            }
            #if !os(tvOS)
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
                        Link(destination: URL(string: String("https://github.com/Piggy-Cat-bit-shadow/sing-box/releases"))!) {
                            Text("Releases")
                        }
                    }
                    RequestReviewButton {
                        Label("Rate on the App Store", systemImage: "text.bubble.fill")
                    }
                    #if os(macOS)
                        if Variant.useSystemExtension {
                            Tabs.sponsors.navigationLink
                        }
                    #endif
                }
            #endif
        }
        #if os(macOS)
        .formNavigationDestination(for: SettingsPage.self) { page in
            Self.destinationView(for: page)
        }
        #endif
    }

    #if os(iOS)
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
            if decision.clearRequest {
                pendingSettingsPage?.wrappedValue = nil
            }
            if decision.pushRemoteControl {
                showRemoteControl = true
            }
        }
    #endif

    #if !os(tvOS)
        private var remoteControlLink: some View {
            #if os(iOS)
                NavigationLink(isActive: $showRemoteControl) {
                    Tabs.remoteControl.contentView
                } label: {
                    Tabs.remoteControl.label
                }
                .onAppear { applyPendingSettingsPage() }
                .onChangeCompat(of: pendingSettingsPage?.wrappedValue) { _ in
                    applyPendingSettingsPage()
                }
            #else
                Tabs.remoteControl.navigationLink
            #endif
        }
    #endif
}
