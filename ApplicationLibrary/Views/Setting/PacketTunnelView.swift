import Library
import SwiftUI

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
        Group {
            if isLoading {
                ProgressView().onAppear {
                    Task {
                        await loadSettings()
                    }
                }
            } else {
                FormView {
                    #if !os(tvOS)
                        FormToggle("includeAllNetworks", """
                        If this property is true, the system routes network traffic through the tunnel except traffic for designated system services necessary for maintaining expected device functionality. You can exclude some types of traffic using the **excludeAPNs**, **excludeLocalNetworks**, and **excludeCellularServices** properties in combination with this property.

                        when enabled, the default TUN stack is changed to `gvisor`, and the `system` and `mixed` stacks are not available.

                        [Apple Documentation](https://developer.apple.com/documentation/networkextension/nevpnprotocol/3131931-includeallnetworks)
                        """, $includeAllNetworks) { newValue in
                            await applyChange(newValue, to: SharedPreferences.includeAllNetworks, isOn: $includeAllNetworks)
                        }

                        if #available(iOS 16.4, macOS 13.3, *) {
                            FormToggle("excludeAPNs", """
                            If this property is true, the system excludes Apple Push Notification services (APNs) traffic, but only when the **includeAllNetworks** property is also true.

                            [Apple Documentation](https://developer.apple.com/documentation/networkextension/nevpnprotocol/4140516-excludeapns)
                            """, $excludeAPNs) { newValue in
                                await applyChange(newValue, to: SharedPreferences.excludeAPNs, isOn: $excludeAPNs)
                            }

                            FormToggle("excludeCellularServices", """
                            If this property is true, the system excludes cellular services — such as Wi-Fi Calling, MMS, SMS, and Visual Voicemail — but only when the **includeAllNetworks** property is also true. This property doesn't impact services that use the cellular network only — such as VoLTE — which the system automatically excludes.

                            [Apple Documentation](https://developer.apple.com/documentation/networkextension/nevpnprotocol/4140517-excludecellularservices)
                            """, $excludeCellularServices) { newValue in
                                await applyChange(newValue, to: SharedPreferences.excludeCellularServices, isOn: $excludeCellularServices)
                            }
                        }

                        FormToggle("excludeLocalNetworks", """
                        If this property is true, the system excludes network connections to hosts on the local network — such as AirPlay, AirDrop, and CarPlay — but only when the **includeAllNetworks** or **enforceRoutes** property is also true.

                        [Apple Documentation](https://developer.apple.com/documentation/networkextension/nevpnprotocol/3143658-excludelocalnetworks)
                        """, $excludeLocalNetworks) { newValue in
                            await applyChange(newValue, to: SharedPreferences.excludeLocalNetworks, isOn: $excludeLocalNetworks)
                        }

                        FormToggle("enforceRoutes", """
                        If this property is true when the **includeAllNetworks** property is false, the system scopes the included routes to the VPN and the excluded routes to the current primary network interface. This property supersedes the system routing table and scoping operations by apps.

                        If you set both the **enforceRoutes** and **excludeLocalNetworks** properties to true, the system excludes network connections to hosts on the local network.

                        [Apple Documentation](https://developer.apple.com/documentation/networkextension/nevpnprotocol/3689459-enforceroutes)
                        """, $enforceRoutes) { newValue in
                            await applyChange(newValue, to: SharedPreferences.enforceRoutes, isOn: $enforceRoutes)
                        }

                        if #available(iOS 17.4, macOS 14.4, *) {
                            FormToggle("excludeDeviceCommunication", """
                            No documentation.

                            [Apple Documentation](https://developer.apple.com/documentation/networkextension/nevpnprotocol/excludedevicecommunication)
                            """, $excludeDeviceCommunication) { newValue in
                                await applyChange(newValue, to: SharedPreferences.excludeDeviceCommunication, isOn: $excludeDeviceCommunication)
                            }
                        }

                    #endif

                    FormButton {
                        Task {
                            await SharedPreferences.resetPacketTunnel()
                            await applySettings()
                            isLoading = true
                        }
                    } label: {
                        Label("Reset", systemImage: "eraser.fill")
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Packet Tunnel")
        .alert($alert)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Writes the switch, applies it, and gives it back if the change did not take effect.
    ///
    /// The switch has already moved, and the preference is what the next start reads - but the apply
    /// is a separate fact and can fail. Reporting that failure and leaving both halves on the new
    /// value showed a routing option that neither the NetworkExtension preferences nor the running
    /// tunnel had. This is the shared counterpart of the same fix in
    /// `HakoStyle/HakoPacketTunnelView`; an iPad and a Mac load this page, so leaving it here would
    /// have fixed only the phone.
    private func applyChange(_ value: Bool, to preference: SharedPreferences.Preference<Bool>, isOn: Binding<Bool>) async {
        let previous = await preference.get()
        await preference.set(value)
        guard await applySettings() else {
            await preference.set(previous)
            isOn.wrappedValue = previous
            return
        }
    }

    /// - Returns: false when the change did not reach the system or the running service.
    @discardableResult
    private func applySettings() async -> Bool {
        guard let profile = environments.extensionProfile else {
            return false
        }
        if !profile.status.isConnected {
            do {
                try await profile.updateProtocolConfiguration()
                return true
            } catch {
                alert = AlertState(action: "update packet tunnel settings", error: error)
                return false
            }
        }
        do {
            try await profile.restart()
            return true
        } catch {
            alert = AlertState(action: "restart service", error: error)
            return false
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
