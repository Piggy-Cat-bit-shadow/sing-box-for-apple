//
//  HakoNavigation.swift
//  ApplicationLibrary
//
//  The phone presentation's names for pages, kept out of `NavigationPage`.
//
//  # Why this file exists rather than an edit to `NavigationPage`
//
//  `NavigationPage` is shared by all three presentations. Its `title` is what the iPad
//  sidebar, the iPad tab bar and the Mac sidebar read, and those are upstream's
//  presentation - the product requirement is that they keep upstream's vocabulary
//  ("Dashboard", "Tools", "Settings") and keep updating with upstream.
//
//  The phone's first-level destinations are named for the *reference* the Hako shell is
//  built from: Home, Tools, More. That naming is this presentation's own, so it lives
//  with this presentation. Nothing outside `ApplicationLibrary/Views/HakoStyle/` and the
//  phone root (`SFI/HakoPhoneRootView.swift`) may read `hakoTitle`.
//
//  `hakoPrimary` and `HakoPrimaryTab` live in `HakoStyle/HakoPrimaryShell.swift`; this
//  file adds only the naming.
//

import Foundation
import SwiftUI

public extension NavigationPage {
    /// The page's name in the phone presentation.
    ///
    /// Two of the four differ from `title`, and both differences are deliberate:
    ///
    ///   - `dashboard` is **Home**. It stopped being a grid of kernel figures when the
    ///     shell landed; the tab bar has called it Home since, so "Dashboard" was a second
    ///     name for one page.
    ///   - `settings` is **More**. The destination contains the settings, but it also
    ///     contains the About links, the sponsors and the licence terms.
    var hakoTitle: String {
        switch self {
        case .dashboard:
            return String(localized: "Home")
        #if !os(tvOS)
            case .groups:
                return String(localized: "Proxies")
            case .connections:
                return String(localized: "Activity")
        #endif
        case .logs:
            return String(localized: "Logs")
        case .tools:
            return String(localized: "Tools")
        case .settings:
            return String(localized: "More")
        }
    }
}
