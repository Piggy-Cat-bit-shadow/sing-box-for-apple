import Library
import SwiftUI

public struct ProfileOverrideView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var alert: AlertState?
    @State private var excludeDefaultRoute = false
    @State private var autoRouteUseSubRangesByDefault = false
    @State private var excludeAPNsRoute = false
    #if os(iOS)
        @State private var localSigningLoopback = false
    #endif

    public init() {}
    public var body: some View {
        Group {
            if isLoading {
                ProgressView().onAppear {
                    Task {
                        await loadSettings()
                    }
                }
            } else {
                FormView {
                    FormToggle("Hide VPN Icon", "Append `0.0.0.0/31` and `::/127` to `route_exclude_address` if not exists.", $excludeDefaultRoute) { newValue in
                        await applyChange(newValue, to: SharedPreferences.excludeDefaultRoute, isOn: $excludeDefaultRoute)
                    }

                    FormToggle("No Default Route", """
                    By default, segment routing is used in `auto_route` instead of global routing.
                    If `<route_address/route_exclude_address>` exists in the configuration, this item will not take effect on the corresponding network (commonly used to resolve HomeKit compatibility issues).
                    On macOS, enabling this option will cause Internet Sharing to not work properly.
                    """, $autoRouteUseSubRangesByDefault) { newValue in
                        await applyChange(newValue, to: SharedPreferences.autoRouteUseSubRangesByDefault, isOn: $autoRouteUseSubRangesByDefault)
                    }

                    FormToggle("Exclude APNs Route", "Append `push.apple.com` to `bypass_domain`, and `17.0.0.0/8` to `route_exclude_address`.", $excludeAPNsRoute) { newValue in
                        await applyChange(newValue, to: SharedPreferences.excludeAPNsRoute, isOn: $excludeAPNsRoute)
                    }

                    #if os(iOS)
                        FormToggle("Local Signing Loopback", "Answer for `10.7.0.1` inside the tunnel so a sideloaded build can refresh itself over a local connection. Off by default.", $localSigningLoopback) { newValue in
                            await applyChange(newValue, to: SharedPreferences.localSigningLoopback, isOn: $localSigningLoopback)
                        }
                    #endif

                    FormButton {
                        Task {
                            await SharedPreferences.resetProfileOverride()
                            await reloadService()
                            isLoading = true
                        }
                    } label: {
                        Label("Reset", systemImage: "eraser.fill")
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Profile Override")
        .alert($alert)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Writes the override, applies it, and gives it back if the running service refused it.
    ///
    /// The switch has already moved when this runs, and the preference is what the next start reads -
    /// but the apply is a separate fact. Reporting that failure and leaving both halves on the new
    /// value showed a setting the running tunnel did not have; this is the shared counterpart of the
    /// same fix in `HakoStyle/HakoProfileOverrideView`, and it is here for the same reason: an iPad and
    /// a Mac load this page, so fixing only the phone would leave them the defect.
    private func applyChange(_ value: Bool, to preference: SharedPreferences.Preference<Bool>, isOn: Binding<Bool>) async {
        let previous = await preference.get()
        await preference.set(value)
        guard await reloadService() else {
            await preference.set(previous)
            isOn.wrappedValue = previous
            return
        }
    }

    /// - Returns: false when the service was running and refused the change. With no running tunnel
    ///   the preference is the next start's input, so there is nothing that failed.
    @discardableResult
    private func reloadService() async -> Bool {
        guard let profile = environments.extensionProfile, profile.status.isConnected else {
            return true
        }
        do {
            try await profile.reloadService()
            return true
        } catch {
            alert = AlertState(action: "reload service", error: error)
            return false
        }
    }

    @MainActor
    private func loadSettings() async {
        excludeDefaultRoute = await SharedPreferences.excludeDefaultRoute.get()
        autoRouteUseSubRangesByDefault = await SharedPreferences.autoRouteUseSubRangesByDefault.get()
        excludeAPNsRoute = await SharedPreferences.excludeAPNsRoute.get()
        #if os(iOS)
            localSigningLoopback = await SharedPreferences.localSigningLoopback.get()
        #endif
        isLoading = false
    }
}
