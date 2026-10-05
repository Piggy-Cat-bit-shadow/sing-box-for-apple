import Library
import SwiftUI

@MainActor
public struct SheetContent<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        #if os(iOS) || os(tvOS)
            NavigationStackCompat {
                content
                    .navigationTitle(title)
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            .presentationDetentsIfAvailable()
        #endif
    }
}

/// The proxy workspace, presented.
///
/// The title is the page's own - the sheet's wrapper and the page inside it must not
/// disagree about what the page is called, which is how a sheet ends up captioned
/// "Groups" while the bar above its content says "Proxies".
@MainActor
public struct GroupsSheetContent: View {
    public init() {}

    public var body: some View {
        SheetContent("Proxies") {
            GroupListView()
        }
    }
}

/// The activity workspace, presented.
@MainActor
public struct ConnectionsSheetContent: View {
    public init() {}

    public var body: some View {
        SheetContent("Activity") {
            ConnectionListView()
        }
    }
}
