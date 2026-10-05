//
//  HakoScaffold.swift
//  ApplicationLibrary
//
//  The page shells: root, settings, workspace, modal and report.
//
//  # Why there is more than one
//
//  The previous round presented every page through one arrangement - a
//  `NavigationStack` around a `List` or a `Form` - and the result was that a proxy
//  workspace, a settings page, a report inbox and a modal all had the same chrome,
//  the same title treatment and the same scrolling behaviour. That is the "several
//  UIs stitched together" this migration removes.
//
//  A page now declares what it IS, and the shell decides what that looks like:
//
//    HakoRootScaffold       a first-level destination. Only these carry the tab bar.
//    HakoSettingsScaffold   a secondary settings page: sections of rows, footnotes.
//    HakoWorkspaceScaffold  a high-density live page: tabs, data cards, search.
//    HakoModalScaffold      a sheet that manages something: X / title / +.
//    HakoReportScaffold     a report inbox or a report's contents.
//
//  # Who draws the chrome
//
//  The platform, wherever it can. On the touch client the page keeps a real
//  navigation bar and puts a circular control in it rather than hiding the bar and
//  painting a header: the bar is what owns the interactive swipe-back gesture, the
//  status-bar inset and the Dynamic Type-scaled title. Painting our own header would
//  have meant re-implementing all three, and getting the gesture wrong is a change
//  users notice immediately.
//
//  So "Hako chrome" here means: an inline centred title, a circular leading control
//  in place of the platform's chevron, and the page's own actions on the trailing
//  side. On the desktop the same declaration lands in the window toolbar, which is
//  the Mac idiom for the same thing.
//

import SwiftUI

// MARK: - Navigation controls

/// The control a secondary page wears in place of the platform's plain back chevron.
///
/// # Why this is a system control and not a drawn disc
///
/// The reference implementation does not draw its own back control on iOS. Its pushed
/// pages keep the system's chevron and the system's interactive swipe-back gesture, and
/// only the desktop replaces the control - with a plain `chevron.backward` toolbar item
/// (`Layout/HakoRegularDetailLayout.swift`, identifier `chevron.backward`). Its sheets use
/// a plain icon-only `xmark` in `.cancellationAction` (`Components/HakoSheetCloseButton.swift`,
/// identifier `sheet.close`).
///
/// This client had a hand-drawn 32pt disc with a custom hit region. It is replaced here
/// because the manual's layout diagram asked for a "circular back" and the reference - read
/// and run - plainly does not have one, and a drawn control has to re-earn the hit target,
/// the Dynamic Type scaling, the focus behaviour and the interactive pop gesture that the
/// system's own control already has. That is recorded as an intentional deviation from the
/// manual's diagram in the migration report.
///
/// The identifiers are kept: the UI tests address the way back by identifier, which is what
/// lets them pass in any language.
public struct HakoBackButton: View {
    private let action: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(action: (() -> Void)? = nil) {
        self.action = action
    }

    public var body: some View {
        Button {
            if let action {
                action()
            } else {
                dismiss()
            }
        } label: {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .hakoToolbarGlyph()
        }
        .accessibilityIdentifier("hako.nav.back")
        .accessibilityLabel(Text("Back"))
    }
}

/// The control a modal wears: a close mark rather than a chevron, because a sheet ends
/// rather than goes back.
public struct HakoCloseButton: View {
    private let action: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(action: (() -> Void)? = nil) {
        self.action = action
    }

    public var body: some View {
        Button {
            if let action {
                action()
            } else {
                dismiss()
            }
        } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .hakoToolbarGlyph()
        }
        .accessibilityIdentifier("hako.nav.close")
        .accessibilityLabel(Text("Close"))
    }
}

public extension View {
    /// The glyph metrics a navigation-bar control uses.
    ///
    /// The reference's `hakoToolbarGlyph()`: `.font(.body).imageScale(.medium)`, so a
    /// toolbar symbol agrees with the bar's own text rather than being sized by a literal.
    func hakoToolbarGlyph() -> some View {
        font(.body).imageScale(.medium)
    }

    /// The padding a control takes when it sits at one end of a grouped toolbar run.
    ///
    /// The reference's `hakoToolbarCapsuleEnd`: on iOS a trailing item takes 9pt and a
    /// leading one takes `Spacing.tight`, because a `ControlGroup` draws its own capsule and
    /// the glyph has to sit inside it rather than against its edge. The desktop needs
    /// nothing, because the platform spaces toolbar items itself.
    @ViewBuilder
    func hakoToolbarCapsuleEnd(_ edge: Edge.Set) -> some View {
        #if os(iOS)
            padding(edge, edge == .trailing ? 9 : HakoTheme.Spacing.tight)
        #else
            self
        #endif
    }
}

/// One icon-only action, sized for a navigation bar.
///
/// Every instance carries a label and a disabled state, because these are the controls a
/// user reaches for without looking: a refresh, a test, a sort. An icon-only button without
/// an accessibility label is invisible to VoiceOver.
///
/// Several of them belong in a `ControlGroup`, which is what the reference uses: on iOS that
/// is the system's own grouped capsule, so the actions read as one control with parts rather
/// than as a row of separate buttons.
public struct HakoActionItem: View {
    private let systemImage: String
    private let label: String
    private let isEnabled: Bool
    private let isBusy: Bool
    private let action: () -> Void

    public init(
        systemImage: String,
        label: String,
        isEnabled: Bool = true,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .hakoToolbarGlyph()
            }
        }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(Text(label))
    }
}

/// A row of actions grouped into one control, for a bar that has more than one.
public struct HakoActionGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        // `ControlGroup` and its navigation style are iOS 16 and later. Before that the
        // actions are simply adjacent, which is what the platform did anyway.
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            ControlGroup {
                content
            }
            .controlGroupStyle(.navigation)
        } else {
            content
        }
    }
}

/// The fixed search field a workspace wears when it is presented as a sheet.
///
/// Not a toolbar item and not a system `.searchable` field: a sheet has no bottom bar, so
/// the reference draws a capsule and pins it above the safe area - which is also what the
/// manual asks a workspace for. It clears, it focuses, and the page underneath reserves its
/// height so the last card is never behind it.
public struct HakoBottomSearchBar: View {
    @FocusState private var isFocused: Bool
    private let search: HakoWorkspaceSearch

    public init(_ search: HakoWorkspaceSearch) {
        self.search = search
    }

    public var body: some View {
        HStack(spacing: HakoTheme.Spacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(search.prompt, text: search.text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                #endif
                .accessibilityIdentifier(search.accessibilityIdentifier ?? "")

            if !search.text.wrappedValue.isEmpty {
                Button {
                    search.text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(
                            minWidth: HakoTheme.Control.minimumHitTarget,
                            minHeight: HakoTheme.Control.minimumHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hako.search.clear")
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, HakoTheme.Spacing.row)
        .frame(height: HakoTheme.Layout.bottomSearchHeight)
        .background(
            RoundedRectangle(cornerRadius: HakoTheme.Radius.searchField, style: .continuous)
                .fill(HakoProductPalette.system.control)
        )
        .padding(.horizontal, HakoTheme.Layout.bottomSearchInset)
        .padding(.vertical, HakoTheme.Layout.bottomSearchInset)
        .background(.bar)
    }
}

/// The hairline between two actions of a toolbar run.
public struct HakoActionDivider: View {
    public init() {}

    public var body: some View {
        Divider()
    }
}

// MARK: - Text

/// The explanation under a card or a row.
///
/// A footnote is part of the design language, not an apology: a setting with a side
/// effect, a default that is not obvious, or a platform limit gets one short line.
/// One component so the inset, the size and the colour are the same on every page -
/// the failure it replaces was nine pages each choosing `.caption` or `.footnote` and
/// each insetting it by a different amount.
public struct HakoFootnote: View {
    private let text: LocalizedStringKey
    private let isInset: Bool

    public init(_ text: LocalizedStringKey, isInset: Bool = true) {
        self.text = text
        self.isInset = isInset
    }

    public var body: some View {
        Text(text)
            .font(HakoTheme.FontRole.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isInset && !HakoPlatformLayout.pageUsesSystemSettingsIdiom
                ? HakoTheme.Layout.cardHorizontalInset
                : 0)
    }
}

// MARK: - The navigation chrome modifier

/// The page chrome every non-root page wears.
///
/// Applied once per page, from the scaffold, so a page cannot half-adopt it. The
/// leading control replaces the platform's back chevron; the trailing content is the
/// page's own actions; the title is inline and centred.
public struct HakoNavigationChrome<Trailing: View>: ViewModifier {
    private let title: String
    private let leading: HakoNavigationLeadingControl
    private let showsLeading: Bool
    private let trailing: Trailing

    public init(
        title: String,
        leading: HakoNavigationLeadingControl,
        showsLeading: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.leading = leading
        self.showsLeading = showsLeading
        self.trailing = trailing()
    }

    public func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .hakoInlineTitle()
            // A page that wears the chrome with a leading control is a detail page, so the
            // root tab bar goes away. This is applied HERE rather than by the shell because
            // there are two ways a page gets pushed: the shell pushes a `NavigationPage`,
            // and a page pushes a `NavigationLink`. Only the shell was hiding the bar, so
            // every settings page still had it - which is exactly the "root tab appears in
            // detail" defect, found by the UI test that walks every More destination.
            .hakoHidesRootTabBar(when: showsLeading && leading != .none)
            .hakoLeadingControl(leading, isVisible: showsLeading)
            .toolbar {
                #if os(macOS)
                    ToolbarItemGroup(placement: .primaryAction) {
                        trailing
                    }
                #else
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        trailing
                    }
                #endif
            }
    }
}

public enum HakoNavigationLeadingControl: Equatable, Sendable {
    case back
    case close
    /// The page is a root: it has nothing to go back to, and shows no control.
    case none
}

public extension View {
    /// Marks a page as a detail page for the root tab bar's rule.
    ///
    /// For a page that still owns its own form and title and has not yet adopted a
    /// scaffold. It is the same rule the chrome applies, expressed once, so a page can
    /// never hide the bar in its own way.
    func hakoHidesRootTabBarForDetail() -> some View {
        hakoHidesRootTabBar(when: true)
    }
}

private extension View {
    /// Hides the enclosing `TabView`'s bar while this page is on screen.
    ///
    /// iOS 16 and later. On iOS 15 there is no SwiftUI way to hide it, and reaching into
    /// the backing `UITabBarController` would be an untestable hack on a system this build
    /// cannot run on.
    @ViewBuilder
    func hakoHidesRootTabBar(when shouldHide: Bool) -> some View {
        #if os(iOS)
            if shouldHide {
                if #available(iOS 16.0, *) {
                    toolbar(.hidden, for: .tabBar)
                } else {
                    self
                }
            } else {
                self
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func hakoInlineTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }

    @ViewBuilder
    func hakoLeadingControl(_ control: HakoNavigationLeadingControl, isVisible: Bool) -> some View {
        switch control {
        case .back where isVisible:
            navigationBarBackButtonHidden(true)
                .toolbar {
                    #if os(macOS)
                        ToolbarItem(placement: .navigation) { HakoBackButton() }
                    #else
                        ToolbarItem(placement: .topBarLeading) { HakoBackButton() }
                    #endif
                }
        case .close where isVisible:
            navigationBarBackButtonHidden(true)
                .toolbar {
                    #if os(macOS)
                        ToolbarItem(placement: .navigation) { HakoCloseButton() }
                    #else
                        ToolbarItem(placement: .topBarLeading) { HakoCloseButton() }
                    #endif
                }
        default:
            self
        }
    }
}

public extension View {
    /// The grouped form style, where the platform has it.
    ///
    /// `.formStyle(.grouped)` and `.scrollContentBackground(.hidden)` are both iOS 16 and
    /// later. The client still runs on iOS 15, where a plain `Form` is already the
    /// inset-grouped idiom and its background is the system's - so the guarded no-op is the
    /// correct behaviour rather than a compromise.
    @ViewBuilder
    func hakoGroupedFormStyle() -> some View {
        #if os(macOS)
            formStyle(.grouped)
                .environment(\.defaultMinListRowHeight, 0)
        #else
            if #available(iOS 16.0, *) {
                scrollContentBackground(.hidden)
            } else {
                self
            }
        #endif
    }

    /// The inline title treatment a page uses.
    ///
    /// The reference's `HakoPageTitle`: every page title is inline, and a page that wants a
    /// large heading draws it in the content instead. Exposed so a root page - which the
    /// shell titles rather than a scaffold - can take the same treatment.
    @ViewBuilder
    func hakoInlineNavigationTitle() -> some View {
        #if os(iOS)
            if #available(iOS 17.0, *) {
                toolbarTitleDisplayMode(.inline)
            } else {
                navigationBarTitleDisplayMode(.inline)
            }
        #else
            self
        #endif
    }

    /// The keyboard behaviour a scrolling page wants, where the platform has it.
    ///
    /// The client still runs on iOS 15, where `scrollDismissesKeyboard` does not
    /// exist, so this is a guarded no-op there rather than a raised deployment target:
    /// scrolling a form is what dismisses the keyboard on that system anyway.
    @ViewBuilder
    func hakoScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    /// Applies the shared navigation chrome with no trailing actions.
    func hakoNavigationChrome(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        showsLeading: Bool = true
    ) -> some View {
        modifier(HakoNavigationChrome(title: title, leading: leading, showsLeading: showsLeading) {
            EmptyView()
        })
    }

    /// Applies the shared navigation chrome with the page's own trailing actions.
    func hakoNavigationChrome<Trailing: View>(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        showsLeading: Bool = true,
        @ViewBuilder actions: () -> Trailing
    ) -> some View {
        modifier(HakoNavigationChrome(
            title: title,
            leading: leading,
            showsLeading: showsLeading,
            trailing: actions
        ))
    }
}

/// The page body the settings, modal and report scaffolds share: a system grouped form.
///
/// The reference implementation's `HakoMacSettingsFormContainer` is one `Form` whose only
/// platform difference is `.formStyle(.grouped)`, which is a macOS-only API. On iOS a plain
/// `Form` is already an inset-grouped list, so a settings page is the same page on both
/// platforms - and the system draws the card, the caption, the footnote and the separators.
///
/// This is the counterpart of `HakoPageSection`: that one paints a card for a root or
/// workspace page, this one lets the system paint it for a settings page. A page that used
/// the wrong one drew a card inside a card, or a `Section` with nothing to be a section in.
///
/// `defaultMinListRowHeight` is zeroed on the desktop, as the reference does, so a row's
/// own floor decides its height instead of the platform's default.
struct HakoScaffoldBody<Content: View>: View {
    let palette: HakoProductPalette
    let content: Content

    var body: some View {
        Form {
            content
        }
        .hakoGroupedFormStyle()
        .background(palette.canvas)
        .hakoScrollDismissesKeyboard()
        // A `Form` is a `List`, so the container draws the disclosure indicator: the rows
        // must not draw a second one.
        .hakoContainerDrawsDisclosure(true)
    }
}

// MARK: - Toolbar action

/// One icon-only action in the navigation bar.
///
/// The bar's own actions are platform toolbar items rather than a hand-drawn capsule:
/// the bar is where the platform's hit testing, focus, keyboard shortcuts and - on the
/// releases that have it - the system's own button treatment live. Drawing a capsule
/// inside the bar would put a second surface inside a surface.
///
/// What is shared is what the reference implementation actually shares: one place to
/// declare the action, one label, one disabled state, one accessibility label.
public struct HakoToolbarAction: View {
    private let systemImage: String
    private let label: String
    private let isEnabled: Bool
    private let isBusy: Bool
    private let action: () -> Void

    public init(
        systemImage: String,
        label: String,
        isEnabled: Bool = true,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(label, systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Section container

// MARK: - Root scaffold

/// The canvas a first-level destination draws on.
///
/// The one thing this owns is the room the shell's floating tab bar needs: the bar is
/// an overlay, so a root page's own scroll view has to reserve the space under it.
/// A secondary page asks for no clearance, because it has no tab bar above its content.
public struct HakoRootScaffold<Content: View>: View {
    private let palette: HakoProductPalette
    private let content: Content

    public init(
        palette: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HakoTheme.Layout.sectionSpacing) {
                content
            }
            .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
            .padding(.top, HakoTheme.Spacing.standard)
            .padding(.bottom, HakoTheme.Layout.rootTabClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.canvas.ignoresSafeArea())
        .hakoScrollDismissesKeyboard()
        .hakoContainerDrawsDisclosure(false)
    }
}

// MARK: - Settings scaffold

/// A secondary settings page: sections of rows, in the shared page language.
///
/// This is the golden sample the manual asks for - on-demand rules, core, app, tunnel,
/// reload, remote control, geo, storage all present through it - so the page's own body
/// contains only its sections. Everything that is chrome, spacing, inset or typography
/// is decided here, once.
public struct HakoSettingsScaffold<Content: View, Actions: View>: View {
    private let title: String
    private let leading: HakoNavigationLeadingControl
    private let palette: HakoProductPalette
    private let content: Content
    private let actions: Actions

    public init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.palette = palette
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        HakoScaffoldBody(palette: palette, content: content)
            .hakoNavigationChrome(title: title, leading: leading) {
                actions
            }
    }
}

public extension HakoSettingsScaffold where Actions == EmptyView {
    init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            palette: palette,
            actions: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Workspace scaffold

/// A high-density live page: proxies, activity, rules, connections, logs.
///
/// # What the reference actually composes
///
/// A workspace in the reference is a `HakoProductRootPage` - a `ScrollView` of self-drawn
/// cards - with three things on top:
///
///   - the page's own segmented strip, pinned to the top of the scroll with
///     `hakoPinnedTopBar` (`safeAreaBar(edge: .top)` on the current system), so it stays
///     while the data moves under it;
///   - the SYSTEM search field, not a drawn one. On the current system the reference puts
///     it in the bottom bar with `.searchable(placement: .toolbar)` plus a
///     `DefaultToolbarItem(kind: .search, placement: .bottomBar)`, and hides the tab bar
///     there because the bottom bar slot is the tab bar's; before that it uses the
///     navigation-bar drawer. (See `Features/Activity/HakoActivityPageView.swift`.)
///   - the page's actions in the navigation bar, grouped into one `ControlGroup`.
///
/// This replaces a hand-drawn search field fixed above the safe area. The system's own
/// field brings the keyboard behaviour, the clear button, the scroll-to-dismiss and the
/// focus ring, and it is what the reference puts on screen; a drawn field has to re-earn all
/// four and was in the bottom bar's slot rather than in the bottom bar.
public struct HakoWorkspaceScaffold<Tabs: View, Content: View, Actions: View>: View {
    private let title: String
    private let leading: HakoNavigationLeadingControl
    private let palette: HakoProductPalette
    private let tabs: Tabs
    private let actions: Actions
    private let content: Content
    private let search: HakoWorkspaceSearch?

    public init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        search: HakoWorkspaceSearch? = nil,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.palette = palette
        self.search = search
        self.tabs = tabs()
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        scrollingBody
            .hakoWorkspaceSearch(search)
            .background(palette.canvas.ignoresSafeArea())
            // A workspace draws its own page, so its rows own the disclosure indicator.
            .hakoContainerDrawsDisclosure(false)
            .hakoNavigationChrome(title: title, leading: leading) {
                actions
            }
    }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HakoTheme.Layout.cardSpacing) {
                content
            }
            .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
            .padding(.vertical, HakoTheme.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hakoScrollDismissesKeyboard()
        // Pinned, not scrolled: the reference's `hakoPinnedTopBar`. A strip that scrolls
        // away cannot be used to change lens halfway down a long list.
        .hakoPinnedTopBar {
            tabs
        }
    }
}

public extension HakoWorkspaceScaffold where Tabs == EmptyView, Actions == EmptyView {
    init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        search: HakoWorkspaceSearch? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            palette: palette,
            search: search,
            tabs: { EmptyView() },
            actions: { EmptyView() },
            content: content
        )
    }
}

public extension HakoWorkspaceScaffold where Actions == EmptyView {
    init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        search: HakoWorkspaceSearch? = nil,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            palette: palette,
            search: search,
            tabs: tabs,
            actions: { EmptyView() },
            content: content
        )
    }
}

public extension HakoWorkspaceScaffold where Tabs == EmptyView {
    /// A workspace with actions and a search field but no segmented tabs.
    ///
    /// The proxy workspace is this shape: one list, two page-level actions, and a search
    /// field. Without this the caller would have to pass an empty tab builder, which
    /// reads as though the page had considered tabs and rejected them.
    init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        search: HakoWorkspaceSearch? = nil,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            palette: palette,
            search: search,
            tabs: { EmptyView() },
            actions: actions,
            content: content
        )
    }
}

public extension View {
    /// Applies a workspace's search field, in the platform's own idiom.
    ///
    /// The reference's rule, from `HakoActivityPageView`: on the current system the field
    /// goes in the bottom bar - which is also why the tab bar is hidden there, since the
    /// two share the slot - and before that it goes in the navigation-bar drawer. A page
    /// does not choose; the same call produces the right one on each system.
    @ViewBuilder
    func hakoWorkspaceSearch(_ search: HakoWorkspaceSearch?) -> some View {
        if let search, search.placement == .bottomBar {
            safeAreaInset(edge: .bottom, spacing: 0) {
                HakoBottomSearchBar(search)
            }
        } else if let search {
            #if os(iOS)
                if #available(iOS 26.0, *) {
                    searchable(text: search.text, placement: .toolbar, prompt: search.prompt)
                        .toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
                        .toolbar(.hidden, for: .tabBar)
                } else if #available(iOS 16.0, *) {
                    searchable(
                        text: search.text,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: search.prompt
                    )
                } else {
                    searchable(text: search.text, prompt: search.prompt)
                }
            #else
                searchable(text: search.text, prompt: search.prompt)
            #endif
        } else {
            self
        }
    }

    /// Pins a view to the top of the enclosing scroll, where the system can do it.
    ///
    /// The reference's `hakoPinnedTopBar`: `safeAreaBar(edge: .top)` on the current system,
    /// which gives the bar the system's own scroll-edge treatment, and a plain
    /// `safeAreaInset` before it.
    @ViewBuilder
    func hakoPinnedTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                bar()
                    .background(.bar)
            }
        }
    }
}

/// The search a workspace owns.
///
/// A value rather than two loose bindings, because a workspace has to hand the same
/// thing to the field and to the inset calculation.
public struct HakoWorkspaceSearch {
    /// Where the field goes, which follows from how the page is presented.
    public enum Placement {
        /// A pushed page: the system's own search, in the bottom bar on the current system
        /// and in the navigation-bar drawer before it.
        case system
        /// A sheet: a drawn capsule pinned above the safe area. The reference shows exactly
        /// this on its proxy sheet, and a sheet has no bottom bar for a system field.
        case bottomBar
    }

    public let text: Binding<String>
    public let prompt: LocalizedStringKey
    public let placement: Placement

    public init(
        text: Binding<String>,
        prompt: LocalizedStringKey = "Search",
        placement: Placement = .system,
        accessibilityIdentifier: String? = nil
    ) {
        self.text = text
        self.prompt = prompt
        self.placement = placement
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// Kept so a UI test can address a drawn field; a system field is addressed by type.
    public let accessibilityIdentifier: String?
}

// MARK: - Modal scaffold

/// A sheet that manages something: the config centre, an import, an editor.
///
/// A modal wears a close control rather than a back one, and it may carry a primary
/// creation action on the trailing side. It deliberately does not wear the root tab
/// bar: a sheet is presented over the shell, so the shell's bar is behind it, and a
/// page that claimed to be a root from inside a sheet would be lying about where it is.
public struct HakoModalScaffold<Content: View, Actions: View>: View {
    private let title: String
    private let palette: HakoProductPalette
    private let content: Content
    private let actions: Actions

    public init(
        title: String,
        palette: HakoProductPalette = .system,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.palette = palette
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        HakoScaffoldBody(palette: palette, content: content)
            .hakoNavigationChrome(title: title, leading: .close) {
                actions
            }
    }
}

public extension HakoModalScaffold where Actions == EmptyView {
    init(
        title: String,
        palette: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, palette: palette, actions: { EmptyView() }, content: content)
    }
}

// MARK: - Report scaffold

/// A report inbox or a report's own contents.
///
/// A report page is a settings-shaped page with a different voice: the inbox is a
/// list of records, the detail is a reading surface. The chrome is shared with the
/// settings scaffold on purpose - the manual's complaint about the power report was
/// that its oversized left-aligned title belonged to a different product than the page
/// it was reached from.
public struct HakoReportScaffold<Content: View, Actions: View>: View {
    private let title: String
    private let leading: HakoNavigationLeadingControl
    private let palette: HakoProductPalette
    private let content: Content
    private let actions: Actions

    public init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.leading = leading
        self.palette = palette
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        HakoScaffoldBody(palette: palette, content: content)
            .hakoNavigationChrome(title: title, leading: leading) {
                actions
            }
    }
}

public extension HakoReportScaffold where Actions == EmptyView {
    init(
        title: String,
        leading: HakoNavigationLeadingControl = .back,
        palette: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            leading: leading,
            palette: palette,
            actions: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Empty and loading

/// A page whose content has not arrived, or cannot be shown, in the shared language.
///
/// The busy form keeps the page's own shape - a progress view where the content would
/// be - rather than replacing the whole page with a spinner, so a page does not jump
/// when its data lands.
public struct HakoLoadingState: View {
    private let message: LocalizedStringKey

    public init(_ message: LocalizedStringKey = "Loading...") {
        self.message = message
    }

    public var body: some View {
        HakoEmptyState(symbol: "ellipsis", title: message, isBusy: true)
    }
}
