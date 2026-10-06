import Library
import SwiftUI

/// What the system routes through the tunnel.
///
/// # What this page used to be
///
/// Six toggles whose titles were the NetworkExtension property names -
/// `includeAllNetworks`, `excludeAPNs`, `excludeCellularServices`,
/// `excludeLocalNetworks`, `enforceRoutes`, `excludeDeviceCommunication` - each
/// carrying the framework's own documentation pasted into its footer, each ending in
/// its own high-saturation `Apple Documentation` link, and one of them describing
/// itself as "No documentation."
///
/// That is not a settings page; it is a header file with switches. The properties are
/// still the source of truth and the switches still write the same preferences with the
/// same polarity, but the page now says what each one does to the user's traffic, in one
/// line, and the framework's documentation is a single link at the end of the page.
///
/// # Why the polarity is not inverted
///
/// The manual's wording for these rows is positive - "Include APNs" - while the stored
/// preferences are negative (`exclude_apns` defaults to true). Relabelling them
/// positively would mean inverting each toggle, which changes what an existing user
/// sees without changing what they get, and hides the fact that the default is to
/// exclude. The titles therefore state what the switch does to the traffic, positively
/// where the property is positive and negatively where it is negative.
struct PacketTunnelView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var alert: AlertState?

    @State private var includeAllNetworks = false
    @State private var excludeAPNs = false
    @State private var excludeCellularServices = false
    @State private var excludeLocalNetworks = false
    @State private var enforceRoutes = false
    @State private var excludeDeviceCommunication = false

    init() {}

    var body: some View {
        HakoSettingsScaffold(title: String(localized: "Tunnel")) {
            if isLoading {
                HakoLoadingState()
                    .onAppear {
                        Task {
                            await loadSettings()
                        }
                    }
            } else {
                routingSections
                exclusionSections
                resetSection
                documentationSection
                // The one thing that is true of the whole page rather than of one switch. Its
                // own section with nothing but a footnote, because that is where a page-level
                // note goes now that each switch's own explanation is its section's footnote.
                HakoSettingsSection(footnote: "Changing any of these restarts the tunnel.") {}
            }
        }
        .alert($alert)
    }

    // MARK: - Sections

    /// One section per setting, which is the reference's structure.
    ///
    /// Its tunnel page gives each switch its own caption - the setting's own name - a card
    /// holding that one row, and the explanation as the section's footnote underneath. This page
    /// grouped the switches into two sections and put each explanation in the row as a subtitle,
    /// which is a different page: the row is 63pt instead of 50, and the reader has to find the
    /// switch's name twice to work out which explanation belongs to which switch.
    ///
    /// The captions repeat the row titles because that is what the reference does; the footnote
    /// is where the explanation goes.
    private func settingSection(
        _ title: String,
        explanation: LocalizedStringKey,
        identifier: String,
        isOn: Binding<Bool>,
        set: @escaping (Bool) async -> Void
    ) -> some View {
        HakoSettingsSection(title, footnote: explanation) {
            HakoToggleRow(
                title,
                isOn: isOn,
                identifier: identifier,
                tightensVerticalPadding: true
            ) { newValue in
                Task {
                    await set(newValue)
                    await restartService()
                }
            }
        }
    }

    private var routingSections: some View {
        Group {
            settingSection(
                String(localized: "Include All Networks"),
                explanation: "Route everything through the tunnel, except the system services the device needs to stay online.",
                identifier: "hako.tunnel.includeAllNetworks",
                isOn: $includeAllNetworks
            ) { await SharedPreferences.includeAllNetworks.set($0) }

            settingSection(
                String(localized: "Enforce Routes"),
                explanation: "Keep the routes the tunnel does not carry on the current network interface, overriding the system routing table.",
                identifier: "hako.tunnel.enforceRoutes",
                isOn: $enforceRoutes
            ) { await SharedPreferences.enforceRoutes.set($0) }
        }
    }

    private var exclusionSections: some View {
        Group {
            if #available(iOS 16.4, macOS 13.3, *) {
                settingSection(
                    String(localized: "Exclude APNs"),
                    explanation: "Leave Apple Push Notification traffic outside the tunnel, while Include All Networks is on.",
                    identifier: "hako.tunnel.excludeAPNs",
                    isOn: $excludeAPNs
                ) { await SharedPreferences.excludeAPNs.set($0) }

                settingSection(
                    String(localized: "Exclude Cellular Services"),
                    explanation: "Leave Wi-Fi Calling, MMS, SMS and Visual Voicemail outside the tunnel, while Include All Networks is on.",
                    identifier: "hako.tunnel.excludeCellularServices",
                    isOn: $excludeCellularServices
                ) { await SharedPreferences.excludeCellularServices.set($0) }
            }

            settingSection(
                String(localized: "Exclude Local Networks"),
                explanation: "Leave AirPlay, AirDrop, CarPlay and other local-network traffic outside the tunnel.",
                identifier: "hako.tunnel.excludeLocalNetworks",
                isOn: $excludeLocalNetworks
            ) { await SharedPreferences.excludeLocalNetworks.set($0) }

            if #available(iOS 17.4, macOS 14.4, *) {
                settingSection(
                    String(localized: "Exclude Device Communication"),
                    explanation: "Leave traffic between this device and nearby devices outside the tunnel.",
                    identifier: "hako.tunnel.excludeDeviceCommunication",
                    isOn: $excludeDeviceCommunication
                ) { await SharedPreferences.excludeDeviceCommunication.set($0) }
            }
        }
    }

    private var resetSection: some View {
        HakoSettingsSection(footnote: "Returns every option on this page to its default.") {
            HakoDestructiveRow(
                String(localized: "Reset Tunnel Settings"),
                subtitle: String(localized: "Use the defaults the client ships with."),
                systemImage: "eraser.fill"
            ) {
                Task {
                    await SharedPreferences.resetPacketTunnel()
                    await restartService()
                    isLoading = true
                }
            }
        }
    }

    /// One link for the whole page rather than one per row.
    ///
    /// The properties are Apple's, and the honest place to explain them is Apple's
    /// documentation - once, as a destination, instead of as a saturated word repeated
    /// under six switches.
    private var documentationSection: some View {
        HakoSettingsSection {
            Link(destination: URL(string: "https://developer.apple.com/documentation/networkextension/nevpnprotocol")!) {
                HakoNavigationRow(
                    title: String(localized: "Apple's tunnel routing reference"),
                    subtitle: String(localized: "How the system decides what a VPN routes"),
                    systemImage: "doc.text.fill",
                    tint: HakoAccentRole.neutral.color,
                    linksOut: true
                )
            }
            .buttonStyle(HakoPushRowButtonStyle())
        }
    }

    // MARK: - Behaviour

    private func restartService() async {
        guard let profile = environments.extensionProfile, profile.status.isConnected else {
            return
        }
        do {
            try await profile.restart()
        } catch {
            alert = AlertState(action: "restart service", error: error)
        }
    }

    @MainActor
    private func loadSettings() async {
        #if !os(tvOS)
            includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
            excludeLocalNetworks = await SharedPreferences.excludeLocalNetworks.get()
            enforceRoutes = await SharedPreferences.enforceRoutes.get()
            if #available(iOS 16.4, macOS 13.3, *) {
                excludeAPNs = await SharedPreferences.excludeAPNs.get()
                excludeCellularServices = await SharedPreferences.excludeCellularServices.get()
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                excludeDeviceCommunication = await SharedPreferences.excludeDeviceCommunication.get()
            }
        #endif
        isLoading = false
    }
}
