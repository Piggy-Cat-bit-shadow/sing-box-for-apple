//
//  HakoPageContent.swift
//  SFI
//
//  The page factory for the phone presentation.
//
//  # Why this is a fork-owned factory instead of `NavigationPage.contentView`
//
//  Upstream's factory lives in `ApplicationLibrary/Views/NavigationPage.swift` and is shared by the
//  iPad root, the Mac root and this one. That is exactly what makes it unusable as the seam for this
//  fork's presentation: editing it means editing a file all three presentations load, so the phone's
//  look and the iPad's look cannot move independently, and every upstream change to it arrives as a
//  conflict with Hako work.
//
//  So the phone routes through its own factory. The rule this file exists to make checkable is
//  one-directional:
//
//      SFI/HakoPhoneRootView.swift -> HakoPageContent -> { Hako page, upstream page }
//
//  and never
//
//      upstream page -> Hako chrome
//
//  A page listed here as an upstream type is upstream's file, unmodified, with upstream's own chrome;
//  a page listed as a `Hako…` type is a fork file under `ApplicationLibrary/Views/HakoStyle/`. The
//  static audit (`scripts/dev/audit_apple_ui_boundary.py`) reads this switch, so a page added here
//  without a decision is a failing check rather than a silent default.
//
//  # Migration state
//
//  `.dashboard` and `.logs` route to the fork's pages. The other four still render upstream's, and
//  each one is a separate change: this switch is the single place such a change is made, and the
//  audit's `hako-page-coverage` check reports exactly how many are done rather than letting the count
//  be inferred from a diff.
//
//  # The environment the pages read
//
//  `\.extensionProfile` is injected around the Home page exactly where `DashboardView` injects it
//  around its own card grid - the two are the same kind of page, so they get their environment the
//  same way instead of the fork inventing a second convention. When there is no profile the modifier
//  is not applied at all, which is what tells the page a tunnel does not exist yet.
//

import ApplicationLibrary
import Library
import NetworkExtension
import SwiftUI

/// The phone presentation's page for a `NavigationPage`.
struct HakoPageContent: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    let page: NavigationPage
    @ObservedObject var dashboard: DashboardViewModel
    let cardConfiguration: DashboardCardConfiguration

    /// The stand-in the page reads before a tunnel exists.
    ///
    /// Built once and held rather than computed: `HakoHomeView` reads it as an `@EnvironmentObject`,
    /// and a fresh instance on every body evaluation would publish to every reader on every redraw.
    /// `ExtensionProfile`'s only public initialiser takes an `NEVPNManager`, and this is the manager
    /// the client has before a tunnel is installed - the same one the rest of the client starts from.
    @StateObject private var placeholderProfile = ExtensionProfile(NEVPNManager.shared())

    var body: some View {
        Group {
            switch page {
            case .dashboard:
                dashboardPage
            #if !os(tvOS)
                case .groups:
                    GroupListView()
                case .connections:
                    ConnectionListView()
            #endif
            case .logs:
                HakoLogView()
            case .tools:
                ToolsView()
            case .settings:
                SettingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// Home, with the extension profile in the environment when one exists.
    ///
    /// The shape follows `DashboardView.mainContent`: a loading state while the profile list is being
    /// read, the page once it is, and nothing about the tunnel's own state decided here.
    @ViewBuilder
    private var dashboardPage: some View {
        if environments.extensionProfileLoading {
            ProgressView()
        } else if let profile = environments.extensionProfile {
            HakoHomeView(
                profileList: $dashboard.profileList,
                selectedProfileID: $dashboard.selectedProfileID,
                systemProxyAvailable: $dashboard.systemProxyAvailable,
                systemProxyEnabled: $dashboard.systemProxyEnabled,
                cardConfiguration: cardConfiguration
            )
            .environmentObject(profile)
        } else {
            // No tunnel installed. The page still draws - it is the screen that explains what to do
            // next - so it gets a placeholder profile whose status is `.invalid`, which is exactly
            // what the page reads as "Not Installed".
            HakoHomeView(
                profileList: $dashboard.profileList,
                selectedProfileID: $dashboard.selectedProfileID,
                systemProxyAvailable: $dashboard.systemProxyAvailable,
                systemProxyEnabled: $dashboard.systemProxyEnabled,
                tunnelIsInstalled: false,
                installTunnel: { await environments.reload() },
                cardConfiguration: cardConfiguration
            )
            .environmentObject(placeholderProfile)
        }
    }
}
