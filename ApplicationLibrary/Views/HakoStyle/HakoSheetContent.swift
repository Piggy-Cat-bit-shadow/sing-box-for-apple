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
//  # Why the container, not `SheetContent`
//
//  `HakoGroupListView` and `HakoConnectionListView` are complete pages, but they are not self-contained
//  sheets: each ends in a `HakoWorkspaceScaffold` whose chrome is applied by `.navigationTitle(...)`,
//  `.hakoLeadingControl(...)` and `.toolbar { ... }`. Those modifiers need a navigation container above
//  them, and neither page provides one - the original supplied it from the outside, as
//  `SheetContent("Proxies") { GroupListView() }`.
//
//  Presenting them bare therefore produces a sheet with no navigation context: the title has nothing to
//  attach to, the leading control has no bar to attach to, and the close button the original's UI test
//  taps (`app.navigationBars.buttons["hako.nav.close"]`) does not exist. The first version of this file
//  did exactly that and its own comment claimed a `SheetContent` wrapper would add a *second* title;
//  that was wrong, and the scaffold's modifiers only work inside a container.
//
//  So this draws the one thing a sheet needs and nothing else: a single `NavigationStackCompat` and the
//  original's presentation - `.presentationDetentsIfAvailable()`, which is `.large` with a visible drag
//  indicator. It deliberately **does not** set `navigationTitle`, because the page's own scaffold does
//  that and two owners for one title is how a sheet ends up captioned twice.
//
//  The original's own words on why the close lives where it does:
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

import SwiftUI

/// The phone's modal close, attached to a shared container's **content**.
///
/// # Why it is a modifier on the content and not a change to the container
///
/// `Profile/ProfileSheetHelpers.swift` is upstream's and an iPad compiles it. The original fork put
/// `HakoCloseButton()` inside that container's own `iOSBody`, under `#if os(iOS)` - which is true on an
/// iPad as well, so every iPad modal built on the container wore the fork's close mark. That is the one
/// remaining piece of Hako in a shared file, and it cannot be fixed by editing the container without
/// either taking the close away from the phone or leaving a Hako symbol in a file the iPad builds.
///
/// It does not have to be fixed there. A presentation's `content` is rendered **inside** the container's
/// `NavigationStackCompat`:
///
///     NavigationStackCompat { content().navigationTitle(...) }
///
/// so a `.toolbar` applied to the content reaches the same navigation bar the container's own toolbar
/// would have. Attaching it at the call site therefore produces the same bar, and the Hako symbol stays
/// in the fork's own namespace.
///
/// The placement matches the original's: `cancellationAction` on iOS, `.navigation` elsewhere, which is
/// exactly what `HakoScaffold`'s own leading control does so that one control looks the same wherever it
/// appears.
public extension View {
    func hakoModalClose() -> some View {
        modifier(HakoModalCloseModifier())
    }
}

private struct HakoModalCloseModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    HakoCloseButton()
                }
            #elseif !os(tvOS)
                ToolbarItem(placement: .navigation) {
                    HakoCloseButton()
                }
            #endif
        }
    }
}

/// The one navigation container a phone workspace sheet needs.
///
/// Mirrors upstream's `SheetContent` minus the title: upstream's own `GroupsSheetContent` is
/// `SheetContent("Groups") { GroupListView() }`, and its `navigationTitle` is what the title would
/// otherwise have to come from. The Hako pages carry their own titles, so this takes none.
@MainActor
private struct HakoSheetContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(iOS) || os(tvOS)
            NavigationStackCompat {
                content
            }
            .presentationDetentsIfAvailable()
        #else
            content
        #endif
    }
}

/// The Proxies workspace, presented as a sheet on the phone.
@MainActor
public struct HakoGroupsSheetContent: View {
    public init() {}

    public var body: some View {
        HakoSheetContainer {
            HakoGroupListView()
        }
    }
}

/// The Activity workspace, presented as a sheet on the phone.
@MainActor
public struct HakoConnectionsSheetContent: View {
    public init() {}

    public var body: some View {
        HakoSheetContainer {
            HakoConnectionListView()
        }
    }
}

/// Add Configuration, presented as a sheet on the phone.
///
/// Mirrors `ProfileCard.NewProfileNavigationView`, which the picker used to present: a single
/// `NavigationStackCompat` and `.presentationDetentsIfAvailable()` around the menu. That shared view
/// builds `NewProfileMenuView()`, which is upstream's, so the phone's Add-Configuration tiles were
/// upstream's menu under upstream's chrome.
///
/// `HakoNewProfileMenuView` supplies the original's chrome - `HakoModalScaffold(title: "Add
/// Configuration")` - and needs a navigation container above it for its title and `.close` to attach to,
/// which is what this provides. The container is deliberately not `HakoModalScaffold` itself: one owner
/// for the title, and the menu already owns it.
@MainActor
public struct HakoNewProfileSheetContent: View {
    @EnvironmentObject private var environments: ExtensionEnvironments

    public init() {}

    public var body: some View {
        HakoSheetContainer {
            HakoNewProfileMenuView()
                .environmentObject(environments)
        }
    }
}
