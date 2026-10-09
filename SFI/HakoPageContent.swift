//
//  HakoPageContent.swift
//  SFI
//
//  The page factory for the phone presentation.
//
//  # Why this is a fork-owned factory instead of `NavigationPage.contentView`
//
//  Upstream's factory lives in `ApplicationLibrary/Views/NavigationPage.swift` and is
//  shared by the iPad root, the Mac root and this one. That is exactly what makes it
//  unusable as the seam for this fork's presentation: editing it means editing a file
//  all three presentations load, so the phone's look and the iPad's look cannot move
//  independently, and any upstream change to it arrives as a conflict with Hako work.
//
//  So the phone routes through its own factory. The rule this file exists to make
//  checkable is one-directional:
//
//      SFI/HakoPhoneRootView.swift -> HakoPageContent -> { Hako page, upstream page }
//
//  and never
//
//      upstream page -> Hako chrome
//
//  A page listed here as an upstream type is upstream's file, unmodified, with upstream's
//  own chrome; a page listed as a `Hako…` type is a fork file under
//  `ApplicationLibrary/Views/HakoStyle/`. The static audit
//  (`scripts/dev/audit_apple_ui_boundary.py`) reads this switch, so a page added here
//  without a decision is a failing check rather than a silent default.
//
//  # Migration state
//
//  Every arm currently renders the upstream page, which is what makes the routing change
//  land on its own: the family split, the shell and the environment wiring are one
//  reviewable change, and each Hako page is a separate one. Pages move to their Hako
//  variant by changing their arm here and adding the fork file - no shared file is
//  touched by either step.
//

import ApplicationLibrary
import Library
import SwiftUI

/// The phone presentation's page for a `NavigationPage`.
struct HakoPageContent: View {
    let page: NavigationPage

    var body: some View {
        Group {
            switch page {
            case .dashboard:
                DashboardView()
            #if !os(tvOS)
                case .groups:
                    GroupListView()
                case .connections:
                    ConnectionListView()
            #endif
            case .logs:
                LogView()
            case .tools:
                ToolsView()
            case .settings:
                SettingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
