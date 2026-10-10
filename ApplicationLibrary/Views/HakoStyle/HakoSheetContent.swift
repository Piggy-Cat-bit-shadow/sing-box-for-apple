//
//  HakoSheetContent.swift
//  ApplicationLibrary
//
//  The phone's two workspace sheets: Proxies and Activity.
//
//  # Why this file exists instead of the shared `GroupsSheetContent`
//
//  `Abstract/NavigationSheetContent.swift` is upstream's and is presented by both roots: the phone from
//  `SFI/HakoPhoneRootView.swift`, and an iPad from `SFI/MainView.swift`. It must not be edited, so the
//  phone cannot get its own titles or its own page views from it.
//
//  The original fork had no phone root at all - `SFI/MainView.swift` was the single root and branched
//  internally - so it could change those two titles in place. This integration split the phone into its
//  own root, which is why the titles regressed to upstream's `"Groups"` and `"Connections"` where the
//  original says `"Proxies"` and `"Activity"`. The original's own words:
//
//      /// The title is the page's own - the sheet's wrapper and the page inside it must not
//      /// disagree about what the page is called, which is how a sheet ends up captioned
//      /// "Groups" while the bar above its content says "Proxies".
//
//  # Why the Hako pages are presented bare rather than inside `SheetContent`
//
//  `HakoGroupListView` and `HakoConnectionListView` are complete pages: each draws a
//  `HakoWorkspaceScaffold` with its own title (`"Proxies"` / `"Activity"`), its own search strip and its
//  own leading control. Their source says which control and why:
//
//      /// The page is a sheet on the touch client and a sidebar selection on the desktop.
//      /// Neither is a push, so neither wears a back control: a sheet ends and a desktop
//      /// page is not somewhere the user arrived from somewhere else.
//      private static var leadingControl: HakoNavigationLeadingControl {
//          #if os(iOS)
//              .close
//          #else
//              .none
//          #endif
//      }
//
//  So a `.close` control on the sheet is the original's design, and wrapping either page in
//  `SheetContent` would add a second navigation container and a second title over a page that already
//  draws both. The phone presents them bare.
//
//  The original's `HakoNavigationUITests.swift:244` taps `app.navigationBars.buttons["hako.nav.close"]`
//  to dismiss the Connections workspace, which is the sheet's close and comes from this scaffold - not
//  from `NavigationSheet`.
//

import SwiftUI

/// The Proxies workspace, presented as a sheet on the phone.
@MainActor
public struct HakoGroupsSheetContent: View {
    public init() {}

    public var body: some View {
        HakoGroupListView()
    }
}

/// The Activity workspace, presented as a sheet on the phone.
@MainActor
public struct HakoConnectionsSheetContent: View {
    public init() {}

    public var body: some View {
        HakoConnectionListView()
    }
}
