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

/// Where a page lives in the shell: the primary that owns it, and whether it is that
/// primary's root or a child pushed on top of it.
///
/// This is extracted as a value rather than left inline in the shell because the failure
/// it guards against is invisible in a view: a child selected before its primary's
/// navigation stack existed cannot be pushed, and a `NavigationLink` whose binding is
/// already true when it is added to the hierarchy is not guaranteed to activate. The
/// mapping is therefore a decision the shell makes twice - what to render as the root, and
/// what to push onto it - and a decision that can be tested directly.
public struct HakoPrimaryRoute: Equatable {
    public let primary: HakoPrimaryTab
    public let child: NavigationPage?

    public init(_ page: NavigationPage) {
        primary = page.hakoPrimary
        child = page.isHakoPrimaryRoot ? nil : page
    }

    /// What the primary renders as its root. Always a root page, never a child.
    public var root: NavigationPage {
        primary.rootPage
    }

    public var hasChild: Bool {
        child != nil
    }
}

/// The shell's child-route state machine.
///
/// Given what each primary currently has pushed and the page the client says is selected,
/// it answers what each primary should have pushed. Two properties matter and both are
/// deliberate:
///
///   - a primary that is not the selected page keeps whatever it had. SwiftUI keeps a tab's
///     navigation stack alive, so returning to that tab must return to the same place;
///     clearing it would silently pop a page the user left open.
///   - a selected child is armed even when it was already selected before anything was
///     rendered, which is the launch case. The shell applies the result only once the
///     primary's root has appeared, which is what makes the push valid.
public enum HakoPrimaryChildArmer {
    /// The whole rule, as one value-producing function so the shell and its harness exercise the
    /// same decision instead of the harness restating it.
    ///
    /// `arming` is the primary whose column is applying the route - each tab has its own
    /// `onChangeCompat`, and all of them see the same `selection`. Only the one that owns the
    /// selection may write: every other primary returns the map unchanged, which is what keeps its
    /// stack alive while the user is elsewhere.
    public static func applying(
        arming primary: HakoPrimaryTab,
        pushed: [HakoPrimaryTab: NavigationPage],
        selection: NavigationPage
    ) -> [HakoPrimaryTab: NavigationPage] {
        guard primary == selection.hakoPrimary else {
            return pushed
        }
        return next(pushed: pushed, selection: selection)
    }

    public static func next(
        pushed: [HakoPrimaryTab: NavigationPage],
        selection: NavigationPage
    ) -> [HakoPrimaryTab: NavigationPage] {
        let route = HakoPrimaryRoute(selection)
        var updated = pushed
        updated[route.primary] = route.child
        return updated
    }
}

/// The touch client's shell.
///
/// The caller supplies the page contents and the badge; the shell owns the tab bar,
/// the mapping to and from `selection`, and the first-appearance animation rule.
///
/// # Why there is no accessory slot
///
/// There used to be one, and the previous round used it to float a second global bar -
/// a runtime status pill with its own start control - above the tab bar. Two stacked
/// global bars is the single largest source of the "several apps stitched together"
/// reading this migration removes: the user cannot tell which of the two is the app's
/// navigation and which is a status readout, and every page pays for both.
///
/// The slot is gone rather than merely unused, because an unused slot is an invitation.
/// Runtime state is a card on Home, the start control is Home's primary action, and the
/// remote-control state is a banner on the page that owns it.
public struct HakoPrimaryShell: View {
    @Binding private var selection: NavigationPage
    private let palette: HakoProductPalette
    private let toolsBadge: Int
    @ViewBuilder private let pageContent: (NavigationPage) -> AnyView

    @State private var initializedTabs: Set<HakoPrimaryTab> = []
    /// The child each primary currently has pushed.
    ///
    /// Kept per primary rather than derived from `selection`, because SwiftUI keeps a tab's
    /// navigation stack alive: a user who opens Logs, switches to Home and comes back must
    /// find Logs still open, so the state cannot be "whatever is selected right now".
    @State private var pushedChild: [HakoPrimaryTab: NavigationPage] = [:]

    public init(
        selection: Binding<NavigationPage>,
        palette: HakoProductPalette = .system,
        toolsBadge: Int = 0,
        @ViewBuilder pageContent: @escaping (NavigationPage) -> some View
    ) {
        _selection = selection
        self.palette = palette
        self.toolsBadge = toolsBadge
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
                        .onAppear {
                            // The root has now rendered, so its navigation host exists and a
                            // child selected before this moment can be pushed onto it. This is
                            // the ordering the whole arrangement exists for: resolve the
                            // primary, render its root, then apply the optional child.
                            applySelectedRoute(for: primary)
                            guard !initializedTabs.contains(primary) else { return }
                            DispatchQueue.main.async {
                                initializedTabs.insert(primary)
                            }
                        }
                        .onChangeCompat(of: selection) { _ in
                            applySelectedRoute(for: primary)
                        }
                }
                .tag(primary)
                // Carries the tag view's accessibility identifier onto the tab bar item SwiftUI
                // generates, so a UI test can address a tab without matching a localized title.
                .accessibilityIdentifier("hako.tab.\(primary.rawValue)")
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
                // A tab keeps its stack while the user is elsewhere, so returning to it has to
                // return to where it was left - not to its root. Without this the child was
                // restored in `pushedChild` and then immediately popped by this very write, which is
                // why "open Logs, go to Home, come back" landed on the Tools root.
                let destination = pushedChild[newPrimary] ?? newPrimary.rootPage
                HakoUITrace.transition(
                    "primary",
                    from: selection.hakoPrimary.rawValue,
                    to: newPrimary.rawValue,
                    source: "HakoPrimaryShell.primarySelection"
                )
                HakoUITrace.transition(
                    "primary-page \(newPrimary.rawValue)",
                    from: String(selection.rawValue),
                    to: String(destination.rawValue),
                    source: "HakoPrimaryShell.primarySelection"
                )
                selection = destination
            }
        )
    }

    /// Arms the child this primary should push, if any, without touching the others.
    ///
    /// The decision - whether this column may arm at all - lives in
    /// `HakoPrimaryChildArmer.applying`, so the harness exercises the same rule rather than a
    /// restatement of it. This method only records what the rule decided.
    private func applySelectedRoute(for primary: HakoPrimaryTab) {
        let updated = HakoPrimaryChildArmer.applying(
            arming: primary,
            pushed: pushedChild,
            selection: selection
        )
        guard updated != pushedChild else {
            // Nothing changed for this column. That is either "the selection belongs to another
            // primary, so this stack is left alone" or "the same child was selected again"; both are
            // the evidence for a page being pushed at most once, so neither writes state.
            HakoUITrace.event(
                "child-unchanged \(primary.rawValue)/\(pushedChild[primary].map { String($0.rawValue) } ?? "nil")",
                source: "HakoPrimaryShell.applySelectedRoute"
            )
            return
        }
        HakoUITrace.transition(
            "child \(primary.rawValue)",
            from: pushedChild[primary].map { String($0.rawValue) },
            to: updated[primary].map { String($0.rawValue) },
            source: "HakoPrimaryShell.applySelectedRoute"
        )
        pushedChild = updated
    }

    /// Whether this tab currently has a child page pushed.
    private func childIsPresented(in primary: HakoPrimaryTab) -> Bool {
        pushedChild[primary] != nil
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
                    // A pop - by the back button or an interactive dismissal - leaves the
                    // selection on the primary's root rather than on a page that is no longer
                    // on screen, and forgets the push so the next selection can arm it again.
                    guard !presented, childIsPresented(in: primary) else { return }
                    HakoUITrace.transition(
                        "child-dismiss \(primary.rawValue)",
                        from: pushedChild[primary].map { String($0.rawValue) },
                        to: nil,
                        source: "HakoPrimaryShell.childDestination"
                    )
                    pushedChild[primary] = nil
                    selection = HakoPrimaryRoute(selection).root
                }
            )
        ) {
            if let child = pushedChild[primary] {
                childPage(child)
            }
        }
    }

    /// A page pushed inside a primary.
    ///
    /// The root tab bar belongs to the roots and to nothing else, so a pushed page
    /// hides it. That is the whole rule of the presentation policy, and it is applied
    /// here - at the one place a child page is built - rather than by each page
    /// remembering to ask, because a page that forgot would be a page whose tab bar
    /// leaked.
    ///
    /// `toolbar(_:for: .tabBar)` is iOS 16 and later. On iOS 15 there is no SwiftUI
    /// way to hide the bar of an enclosing `TabView`, and reaching into the backing
    /// `UITabBarController` would be an untestable hack on a system this build cannot
    /// run on; the bar therefore stays on that one system version.
    @ViewBuilder
    private func childPage(_ child: NavigationPage) -> some View {
        #if os(iOS)
            if #available(iOS 16.0, *) {
                pageContent(child)
                    .toolbar(.hidden, for: .tabBar)
            } else {
                pageContent(child)
            }
        #else
            pageContent(child)
        #endif
    }
}
