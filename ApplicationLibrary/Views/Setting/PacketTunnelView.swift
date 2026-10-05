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
                routingSection
                exclusionSection
                resetSection
                documentationSection
            }
        }
        .alert($alert)
    }

    // MARK: - Sections

    private var routingSection: some View {
        HakoSettingsSection(
            String(localized: "Routing"),
            footnote: "Changing any of these restarts the tunnel."
        ) {
            HakoToggleRow(
                String(localized: "Include All Networks"),
                subtitle: String(localized: "Route everything through the tunnel, except the system services the device needs to stay online."),
                isOn: $includeAllNetworks,
                identifier: "hako.tunnel.includeAllNetworks"
            ) { newValue in
                Task {
                    await SharedPreferences.includeAllNetworks.set(newValue)
                    await restartService()
                }
            }


            HakoToggleRow(
                String(localized: "Enforce Routes"),
                subtitle: String(localized: "Keep the routes the tunnel does not carry on the current network interface, overriding the system routing table."),
                isOn: $enforceRoutes,
                identifier: "hako.tunnel.enforceRoutes"
            ) { newValue in
                Task {
                    await SharedPreferences.enforceRoutes.set(newValue)
                    await restartService()
                }
            }
        }
    }

    private var exclusionSection: some View {
        HakoSettingsSection(
            String(localized: "Excluded Traffic"),
            footnote: "These apply only while Include All Networks or Enforce Routes is on."
        ) {
            if #available(iOS 16.4, macOS 13.3, *) {
                HakoToggleRow(
                    String(localized: "Exclude APNs"),
                    subtitle: String(localized: "Leave Apple Push Notification traffic outside the tunnel."),
                    isOn: $excludeAPNs,
                    identifier: "hako.tunnel.excludeAPNs"
                ) { newValue in
                    Task {
                        await SharedPreferences.excludeAPNs.set(newValue)
                        await restartService()
                    }
                }


                HakoToggleRow(
                    String(localized: "Exclude Cellular Services"),
                    subtitle: String(localized: "Leave Wi-Fi Calling, MMS, SMS and Visual Voicemail outside the tunnel."),
                    isOn: $excludeCellularServices,
                    identifier: "hako.tunnel.excludeCellularServices"
                ) { newValue in
                    Task {
                        await SharedPreferences.excludeCellularServices.set(newValue)
                        await restartService()
                    }
                }

            }

            HakoToggleRow(
                String(localized: "Exclude Local Networks"),
                subtitle: String(localized: "Leave AirPlay, AirDrop, CarPlay and other local-network traffic outside the tunnel."),
                isOn: $excludeLocalNetworks,
                identifier: "hako.tunnel.excludeLocalNetworks"
            ) { newValue in
                Task {
                    await SharedPreferences.excludeLocalNetworks.set(newValue)
                    await restartService()
                }
            }

            if #available(iOS 17.4, macOS 14.4, *) {

                HakoToggleRow(
                    String(localized: "Exclude Device Communication"),
                    subtitle: String(localized: "Leave traffic between this device and nearby devices outside the tunnel."),
                    isOn: $excludeDeviceCommunication,
                    identifier: "hako.tunnel.excludeDeviceCommunication"
                ) { newValue in
                    Task {
                        await SharedPreferences.excludeDeviceCommunication.set(newValue)
                        await restartService()
                    }
                }
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
                    tint: HakoAccentRole.blue.color,
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
