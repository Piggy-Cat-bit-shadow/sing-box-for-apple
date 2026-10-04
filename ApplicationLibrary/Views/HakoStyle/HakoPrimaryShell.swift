//
//  HakoPrimaryShell.swift
//  ApplicationLibrary
//
//  The primary shell: three first-level destinations and the rule that maps the
//  client's existing page selection onto them.
//
//  Structure follows Hako-Client (GPL-3.0) `HakoClientApp.compactTabShell` and
//  `Navigation/HakoPresentationPolicy.swift` at commit 62aa2f2f: Home, Utilities,
//  More, each a navigation container of its own, with the child pages pushed inside
//  the primary they belong to.
//
//  # Why the shell does not own "the current page"
//
//  sing-box-for-apple already models navigation as `NavigationPage`, and a lot of
//  non-presentation code depends on it: notifications that jump to Settings, crash
//  reports that jump to Tools, the screenshot harness that starts on a named page,
//  and the `\.selection` environment value read by the checks and remote-control
//  pages. Replacing that model to get three tabs would have meant rewriting every
//  one of those paths, which is exactly the kind of change this migration must not
//  make.
//
//  So the shell DERIVES its tab from `NavigationPage` and writes back to it. Every
//  existing entry point keeps working, and a page that is not a tab root (Logs, for
//  example) is a child of the primary it belongs to rather than a destination the
//  shell has to know about.
//

import SwiftUI

/// The first-level destinations of the touch client.
public enum HakoPrimaryTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case tools
    case more

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .home:
            return String(localized: "Home")
        case .tools:
            return String(localized: "Tools")
        case .more:
            return String(localized: "More")
        }
    }

    public var systemImage: String {
        switch self {
        case .home:
            return "house.fill"
        case .tools:
            return "briefcase.fill"
        case .more:
            return "ellipsis.circle.fill"
        }
    }

    public var accent: HakoAccentRole {
        switch self {
        case .home: .blue
        case .tools: .indigo
        case .more: .teal
        }
    }

    /// The page shown when the primary is selected and nothing deeper is open.
    public var rootPage: NavigationPage {
        switch self {
        case .home: .dashboard
        case .tools: .tools
        case .more: .settings
        }
    }
}

public extension NavigationPage {
    /// Which primary this page lives under.
    ///
    /// `logs` is a child of Tools rather than its own tab: it is a session-level
    /// view of what the tunnel is doing, which is the same place the connections
    /// list lives. Keeping it a `NavigationPage` is what lets the existing
    /// "logs selected → connect the command client" hook stay untouched.
    var hakoPrimary: HakoPrimaryTab {
        switch self {
        case .dashboard:
            return .home
        case .tools, .logs:
            return .tools
        case .settings:
            return .more
        #if os(macOS)
            case .groups, .connections:
                return .tools
        #endif
        }
    }

    /// Whether this page is a primary's root rather than a child pushed inside it.
    var isHakoPrimaryRoot: Bool {
        self == hakoPrimary.rootPage
    }
}

/// The touch client's shell.
///
/// The caller supplies the page contents, the badge and the bottom accessory; the
/// shell owns the tab bar, the mapping to and from `selection`, and the
/// first-appearance animation rule.
public struct HakoPrimaryShell<Accessory: View>: View {
    @Binding private var selection: NavigationPage
    private let palette: HakoProductPalette
    private let toolsBadge: Int
    @ViewBuilder private let accessory: () -> Accessory
    @ViewBuilder private let pageContent: (NavigationPage) -> AnyView

    @State private var initializedTabs: Set<HakoPrimaryTab> = []

    public init(
        selection: Binding<NavigationPage>,
        palette: HakoProductPalette = .system,
        toolsBadge: Int = 0,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder pageContent: @escaping (NavigationPage) -> some View
    ) {
        _selection = selection
        self.palette = palette
        self.toolsBadge = toolsBadge
        self.accessory = accessory
        self.pageContent = { AnyView(pageContent($0)) }
    }

    public var body: some View {
        TabView(selection: primarySelection) {
            ForEach(HakoPrimaryTab.allCases) { primary in
                NavigationStackCompat {
                    pageContent(primary.rootPage)
                        // A page that is not a primary's root - Logs, today - is
                        // PUSHED onto that primary rather than swapped in as its
                        // root. Swapping would leave the page with no way back: the
                        // tab is already selected, so tapping it again changes
                        // nothing. The push also gives the page the back button and
                        // the interactive dismissal the platform expects.
                        .background(childDestination(for: primary))
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            accessory()
                                .transaction { transaction in
                                    if !initializedTabs.contains(primary) {
                                        transaction.disablesAnimations = true
                                    }
                                }
                        }
                        .onAppear {
                            guard !initializedTabs.contains(primary) else { return }
                            DispatchQueue.main.async {
                                initializedTabs.insert(primary)
                            }
                        }
                }
                .tag(primary)
                .tabItem {
                    Label(primary.title, systemImage: primary.systemImage)
                }
                .badge(primary == .tools ? toolsBadge : 0)
            }
        }
    }

    /// The tab the current page belongs to.
    private var primarySelection: Binding<HakoPrimaryTab> {
        Binding(
            get: { selection.hakoPrimary },
            set: { newPrimary in
                // Only move the selection when the tab actually changed. Writing on
                // every set would reset a child page (Logs, for example) back to its
                // primary's root whenever SwiftUI re-evaluated the binding.
                guard newPrimary != selection.hakoPrimary else { return }
                selection = newPrimary.rootPage
            }
        )
    }

    /// Whether this tab is currently showing one of its child pages.
    private func childIsPresented(in primary: HakoPrimaryTab) -> Bool {
        selection.hakoPrimary == primary && !selection.isHakoPrimaryRoot
    }

    /// The child page of this tab, presented as a push when one is selected.
    ///
    /// The binding writes back on dismissal, so popping the page by its back button
    /// or by an interactive swipe leaves the selection on the primary's root instead
    /// of on a page that is no longer on screen.
    @ViewBuilder
    private func childDestination(for primary: HakoPrimaryTab) -> some View {
        NavigationDestinationCompat(
            isPresented: Binding(
                get: { childIsPresented(in: primary) },
                set: { presented in
                    guard !presented, childIsPresented(in: primary) else { return }
                    selection = primary.rootPage
                }
            )
        ) {
            if childIsPresented(in: primary) {
                pageContent(selection)
            }
        }
    }
}

public extension HakoPrimaryShell where Accessory == EmptyView {
    init(
        selection: Binding<NavigationPage>,
        palette: HakoProductPalette = .system,
        toolsBadge: Int = 0,
        @ViewBuilder pageContent: @escaping (NavigationPage) -> some View
    ) {
        self.init(
            selection: selection,
            palette: palette,
            toolsBadge: toolsBadge,
            accessory: { EmptyView() },
            pageContent: pageContent
        )
    }
}
