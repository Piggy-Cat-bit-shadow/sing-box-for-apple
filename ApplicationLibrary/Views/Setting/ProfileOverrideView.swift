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
                routingSections
                // Page-level rather than per-switch, so it keeps its own footnote section.
                HakoSettingsSection(footnote: "Changing any of these reloads the running service.") {}
                resetSection
            }
        }
        .alert($alert)
    }

    /// One section per setting, as the reference does it; see `PacketTunnelView`.
    private func settingSection(
        _ title: String,
        explanation: LocalizedStringKey,
        isOn: Binding<Bool>,
        set: @escaping (Bool) async -> Void
    ) -> some View {
        HakoSettingsSection(title, footnote: explanation) {
            HakoToggleRow(title, isOn: isOn) { newValue in
                Task {
                    await set(newValue)
                    await reloadService()
                }
            }
        }
    }

    private var routingSections: some View {
        Group {
            settingSection(
                String(localized: "Hide VPN Icon"),
                explanation: "Stop the system from showing its VPN badge, by excluding the addresses the badge probes.",
                isOn: $excludeDefaultRoute
            ) { await SharedPreferences.excludeDefaultRoute.set($0) }

            settingSection(
                String(localized: "No Default Route"),
                explanation: "Route by subnet rather than taking over the default route. Fixes some HomeKit problems; on the Mac it stops Internet Sharing from working.",
                isOn: $autoRouteUseSubRangesByDefault
            ) { await SharedPreferences.autoRouteUseSubRangesByDefault.set($0) }

            settingSection(
                String(localized: "Exclude APNs Route"),
                explanation: "Keep Apple Push Notification traffic off the tunnel by bypassing its hosts.",
                isOn: $excludeAPNsRoute
            ) { await SharedPreferences.excludeAPNsRoute.set($0) }
        }
    }

    private var resetSection: some View {
        HakoSettingsSection {
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
