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

/// The circular control a secondary page wears in place of the platform's plain
/// back chevron.
///
/// The circle is `navigationControlDiameter` and the target it answers to is
/// `minimumHitTarget`: a 44pt circle in a 52pt bar reads as a button with a bar
/// around it, which is why the two numbers are separate tokens.
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
            HakoCircularControlLabel(systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Back"))
    }
}

/// The circular control a modal wears: a close mark rather than a chevron, because a
/// sheet ends rather than goes back.
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
            HakoCircularControlLabel(systemImage: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
    }
}

/// The disc both controls draw, so they cannot disagree about size or tint.
struct HakoCircularControlLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: HakoTheme.Control.navigationControlGlyphSize, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(
                width: HakoTheme.Control.navigationControlDiameter,
                height: HakoTheme.Control.navigationControlDiameter
            )
            .background(Circle().fill(HakoProductPalette.system.control))
            .frame(
                minWidth: HakoTheme.Control.minimumHitTarget,
                minHeight: HakoTheme.Control.minimumHitTarget
            )
            .contentShape(Rectangle())
    }
}

/// One icon-only action, sized for a header.
///
/// Every instance carries a label, a >=44pt target and a disabled state, because
/// these are the controls a user reaches for without looking: a refresh, a test, a
/// sort. An icon-only button without an accessibility label is invisible to VoiceOver
/// and a button under 44pt is invisible to a thumb.
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
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: HakoTheme.Control.navigationControlGlyphSize, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(
                minWidth: HakoTheme.Control.actionItemMinimumWidth,
                minHeight: HakoTheme.Control.minimumHitTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : HakoTheme.Opacity.disabled)
        .accessibilityLabel(Text(label))
    }
}

/// A row of icon-only actions inside a surface.
///
/// Used where a page has actions of its own below the navigation bar - the workspace
/// summary, a card that owns its own refresh. The header's own actions live in the
/// navigation bar instead, which is what the platform's hit-testing, focus and
/// keyboard shortcuts are built around.
public struct HakoActionCapsule<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, HakoTheme.Control.actionCapsuleHorizontalPadding)
        .frame(height: HakoTheme.Control.actionCapsuleHeight)
        .background(
            Capsule(style: .continuous)
                .fill(HakoProductPalette.system.control)
        )
    }
}

/// The hairline between two actions of a capsule.
public struct HakoActionDivider: View {
    public init() {}

    public var body: some View {
        Divider()
            .frame(height: HakoTheme.Spacing.standard)
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

private extension View {
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

/// The scrolling page body the settings, modal and report scaffolds share.
///
/// Its whole job is to be the same shape on every page that is not a workspace: the
/// desktop hands the sections to the system's grouped form, the touch client scrolls
/// a column of painted cards. Extracted so those three scaffolds cannot drift into
/// three slightly different page paddings.
struct HakoScaffoldBody<Content: View>: View {
    let palette: HakoProductPalette
    let content: Content

    var body: some View {
        #if os(macOS)
            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(palette.canvas)
        #else
            ScrollView {
                VStack(alignment: .leading, spacing: HakoTheme.Layout.sectionSpacing) {
                    content
                }
                .padding(.vertical, HakoTheme.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.canvas)
            .hakoScrollDismissesKeyboard()
            // A painted page is not a `List`: no platform indicator exists, so the rows
            // draw their own single chevron.
            .hakoContainerDrawsDisclosure(false)
        #endif
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

/// A grouped card of rows, with the caption above it and the footnote below.
///
/// The touch client paints a caption and a card; the desktop hands the section to the
/// system's grouped form, which is already a card. Both are "a section with rows in
/// it", and keeping that decision here is what stops the desktop from growing a second
/// set of row views.
///
/// `HakoSection` in `HakoCard.swift` is this component's predecessor and is kept for
/// the pages that already adopted it; new pages use this one, which adds the footnote
/// slot, the divider handling and the card's own inner padding.
public struct HakoSettingsSection<Content: View>: View {
    private let title: String?
    private let footnote: LocalizedStringKey?
    private let palette: HakoProductPalette
    private let content: Content

    public init(
        _ title: String? = nil,
        footnote: LocalizedStringKey? = nil,
        palette: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.palette = palette
        self.content = content()
    }

    public var body: some View {
        if HakoPlatformLayout.pageUsesSystemSettingsIdiom {
            Section {
                content
            } header: {
                if let title {
                    Text(title)
                }
            } footer: {
                if let footnote {
                    Text(footnote)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.compact) {
                if let title {
                    Text(title)
                        .font(HakoTheme.FontRole.sectionHeader)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
                        .accessibilityAddTraits(.isHeader)
                }

                HakoCardSurface(
                    fill: palette.card,
                    separator: palette.separator,
                    cornerRadius: HakoTheme.Radius.groupedSection
                ) {
                    VStack(spacing: 0) {
                        content
                    }
                    .padding(.horizontal, HakoTheme.Layout.cardInnerPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let footnote {
                    HakoFootnote(footnote)
                }
            }
        }
    }
}

/// The divider between two rows of a card, drawn only where the container does not
/// draw its own.
public struct HakoSettingsDivider: View {
    private let leadingInset: CGFloat?

    public init(leadingInset: CGFloat? = nil) {
        self.leadingInset = leadingInset
    }

    public var body: some View {
        if !HakoPlatformLayout.pageUsesSystemSettingsIdiom {
            Divider()
                .padding(.leading, leadingInset ?? 0)
                .opacity(HakoTheme.Opacity.rowDivider)
        }
    }
}

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
        .background(palette.canvas)
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
/// Its distinguishing features, in the order they matter:
///
///   - optional segmented tabs above the content, which are the page's own and not the
///     tab bar's;
///   - a scrolling body of data cards, with the bottom inset a search field needs so
///     the last card is never underneath it;
///   - an optional fixed search field above the safe area, which owns the keyboard
///     dismissal and the clear button rather than leaving them to each page.
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
        VStack(spacing: 0) {
            tabs

            ScrollView {
                VStack(alignment: .leading, spacing: HakoTheme.Layout.cardSpacing) {
                    content
                }
                .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
                .padding(.vertical, HakoTheme.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The search field floats over the page, so the page reserves exactly
                // its height. Without this the last row of the last card is reachable
                // only by scrolling it under the field.
                .padding(.bottom, search == nil ? 0 : HakoTheme.Layout.bottomSearchClearance)
            }
            .background(palette.canvas)
            .hakoScrollDismissesKeyboard()

            if let search {
                HakoBottomSearchBar(search)
            }
        }
        .background(palette.canvas)
        // A workspace draws its own page, so its rows own the disclosure indicator.
        .hakoContainerDrawsDisclosure(false)
        .hakoNavigationChrome(title: title, leading: leading) {
            actions
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

/// The search a workspace owns.
///
/// A value rather than two loose bindings, because a workspace has to hand the same
/// thing to the field and to the inset calculation.
public struct HakoWorkspaceSearch {
    public let text: Binding<String>
    public let prompt: LocalizedStringKey
    public let accessibilityIdentifier: String?

    public init(
        text: Binding<String>,
        prompt: LocalizedStringKey = "Search",
        accessibilityIdentifier: String? = nil
    ) {
        self.text = text
        self.prompt = prompt
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// The fixed search field a workspace wears above its safe area.
///
/// It is a field, not a toolbar: it stays put while the data scrolls, it clears, it
/// focuses, and it never lets the page underneath draw under it.
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

/// The segmented tabs above a workspace's content.
///
/// One component because the alternative - a `Picker` on one page, a hand-rolled
/// underline on another - is exactly the inconsistency this migration removes. The
/// touch client underlines; the desktop uses the platform's own segmented control,
/// which is what a Mac window is expected to offer.
public struct HakoSegmentedTabs<Value: Hashable>: View {
    public struct Tab: Identifiable {
        public let value: Value
        public let title: String
        public let badge: Int?

        public var id: Value {
            value
        }

        public init(_ value: Value, _ title: String, badge: Int? = nil) {
            self.value = value
            self.title = title
            self.badge = badge
        }
    }

    @Namespace private var underline
    private let tabs: [Tab]
    @Binding private var selection: Value

    public init(tabs: [Tab], selection: Binding<Value>) {
        self.tabs = tabs
        _selection = selection
    }

    public var body: some View {
        #if os(macOS)
            Picker("", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(tab.title).tag(tab.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
            .padding(.vertical, HakoTheme.Spacing.compact)
        #else
            HStack(spacing: HakoTheme.Spacing.section) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
            .frame(height: HakoTheme.Control.segmentedTabHeight + HakoTheme.Spacing.standard)
            .background(HakoProductPalette.system.canvas)
        #endif
    }

    #if !os(macOS)
        private func tabButton(_ tab: Tab) -> some View {
            let isSelected = tab.value == selection
            return Button {
                guard !isSelected else { return }
                selection = tab.value
            } label: {
                VStack(spacing: HakoTheme.Spacing.tight) {
                    HStack(spacing: HakoTheme.Spacing.tight) {
                        Text(tab.title)
                            .font(HakoTheme.FontRole.rowPrimary)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        if let badge = tab.badge, badge > 0 {
                            HakoStatusBadge("\(badge)", emphasis: .info)
                        }
                    }
                    .frame(height: HakoTheme.Control.segmentedTabHeight)

                    ZStack {
                        Capsule()
                            .fill(.clear)
                            .frame(height: 2)
                        if isSelected {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "hako.tab.underline", in: underline)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    #endif
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
