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
//  All six destinations route to the phone's own pages. This comment used to say that only `.dashboard`
//  and `.logs` did, which was true when it was written and has been wrong since the other four landed -
//  a reader checking the routing here would have been told the wrong answer by the file that decides it.
//  `scripts/dev/audit_apple_ui_boundary.py --only hako-page-coverage` reads this switch and is the
//  authority; it fails while any arm still returns an upstream type.
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

    /// What went wrong installing the tunnel, if it did.
    ///
    /// The original reported this and the migration dropped the report: `installTunnel` was
    /// `{ await environments.reload() }`, and `reload()` only *loads* an already-installed extension -
    /// `ExtensionProfile.load()` returns nil when there is no manager. So the notice's action ran, changed
    /// nothing, and repainted: a system-authorisation refusal looked exactly like a press that had not
    /// registered yet. `ExtensionProfile.install()` had no caller anywhere on the phone's path.
    @State private var installAlert: AlertState?

    var body: some View {
        Group {
            switch page {
            case .dashboard:
                dashboardPage
            #if !os(tvOS)
                case .groups:
                    HakoGroupListView()
                case .connections:
                    HakoConnectionListView()
            #endif
            case .logs:
                HakoLogView()
            case .tools:
                HakoToolsView()
            case .settings:
                HakoSettingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(uiColor: .systemGroupedBackground))
        .alert($installAlert)
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
                // The original's own action, restored with the error it reported
                // (`up-hako/ActiveDashboardView.swift:172-181`): install, then reload so the page
                // learns the tunnel exists, and say so when installing fails instead of repainting.
                installTunnel: installTunnel,
                cardConfiguration: cardConfiguration
            )
            .environmentObject(placeholderProfile)
        }
    }

    /// Ask the system to install the tunnel, then re-read the environment so the page sees it.
    ///
    /// A closure over `self` rather than the bare method reference: this view's `@State installAlert` is
    /// written here, and a `@State` mutation through a method reference taken in a `@ViewBuilder` is the
    /// kind of capture that is easy to get subtly wrong. The shape is the one the original used, an
    /// action that awaits the install and reports its failure.
    private var installTunnel: () async -> Void {
        {
            do {
                try await ExtensionProfile.install()
                await environments.reload()
            } catch {
                installAlert = AlertState(action: "install network extension", error: error)
            }
        }
    }
}
