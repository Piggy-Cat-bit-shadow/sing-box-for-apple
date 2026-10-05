import Library
import SwiftUI

public struct ProfileOverrideView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var alert: AlertState?
    @State private var excludeDefaultRoute = false
    @State private var autoRouteUseSubRangesByDefault = false
    @State private var excludeAPNsRoute = false

    public init() {}

    /// The page the manual names as the second golden sample: related options in one
    /// card, one footnote per card, and the destructive action on its own at the end.
    ///
    /// The rows keep the same preferences with the same polarity. What changed is that
    /// the footnotes no longer read as configuration file text: "Append `0.0.0.0/31` and
    /// `::/127` to `route_exclude_address` if not exists." is a description of an
    /// implementation, and the user's question is what the switch does to their traffic.
    public var body: some View {
        HakoSettingsScaffold(title: String(localized: "Profile Override")) {
            if isLoading {
                HakoLoadingState()
                    .onAppear {
                        Task {
                            await loadSettings()
                        }
                    }
            } else {
                routingSection
                resetSection
            }
        }
        .alert($alert)
    }

    private var routingSection: some View {
        HakoSettingsSection(
            String(localized: "Compatibility"),
            footnote: "Changing any of these reloads the running service."
        ) {
            HakoToggleRow(
                String(localized: "Hide VPN Icon"),
                subtitle: String(localized: "Stop the system from showing its VPN badge, by excluding the addresses the badge probes."),
                isOn: $excludeDefaultRoute
            ) { newValue in
                Task {
                    await SharedPreferences.excludeDefaultRoute.set(newValue)
                    await reloadService()
                }
            }

            HakoSettingsDivider()

            HakoToggleRow(
                String(localized: "No Default Route"),
                subtitle: String(localized: "Route by subnet rather than taking over the default route. Fixes some HomeKit problems; on the Mac it stops Internet Sharing from working."),
                isOn: $autoRouteUseSubRangesByDefault
            ) { newValue in
                Task {
                    await SharedPreferences.autoRouteUseSubRangesByDefault.set(newValue)
                    await reloadService()
                }
            }

            HakoSettingsDivider()

            HakoToggleRow(
                String(localized: "Exclude APNs Route"),
                subtitle: String(localized: "Keep Apple Push Notification traffic off the tunnel by bypassing its hosts."),
                isOn: $excludeAPNsRoute
            ) { newValue in
                Task {
                    await SharedPreferences.excludeAPNsRoute.set(newValue)
                    await reloadService()
                }
            }
        }
    }

    private var resetSection: some View {
        HakoSettingsSection(footnote: "Returns every option on this page to its default.") {
            HakoDestructiveRow(
                String(localized: "Reset Profile Override"),
                subtitle: String(localized: "Use the defaults the client ships with."),
                systemImage: "eraser.fill"
            ) {
                Task {
                    await SharedPreferences.resetProfileOverride()
                    await reloadService()
                    isLoading = true
                }
            }
        }
    }

    private func reloadService() async {
        guard let profile = environments.extensionProfile, profile.status.isConnected else {
            return
        }
        do {
            try await profile.reloadService()
        } catch {
            alert = AlertState(action: "reload service", error: error)
        }
    }

    @MainActor
    private func loadSettings() async {
        excludeDefaultRoute = await SharedPreferences.excludeDefaultRoute.get()
        autoRouteUseSubRangesByDefault = await SharedPreferences.autoRouteUseSubRangesByDefault.get()
        excludeAPNsRoute = await SharedPreferences.excludeAPNsRoute.get()
        isLoading = false
    }
}
