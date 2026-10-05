//
//  HakoSurface.swift
//  ApplicationLibrary
//
//  Surfaces and layout rules. Extracted from Hako-Client (GPL-3.0),
//  `Design/HakoSurfaceRole.swift`, `Design/HakoAccentRole.swift` and
//  `Layout/HakoPlatformLayout.swift` at commit 62aa2f2f.
//
//  HAKO's surfaces are system semantic colours, not a brand palette: the page
//  canvas is the grouped background, cards are the secondary grouped background,
//  and separators are the system separator. That is why this migration inherits a
//  design language without inheriting a colour scheme, and why light and dark both
//  work without a second set of constants.
//

import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

/// What a surface is for, which decides whether it may use the native material.
///
/// The set is closed on purpose. A page that needs a surface the list does not have
/// is a page asking for a new role, and adding one here is a decision about the whole
/// client - which is the point, because the alternative is a page inventing a fill
/// that happens to look right on that page and nowhere else.
public enum HakoSurfaceRole: String, CaseIterable, Sendable {
    /// A card on a root page. The only role that may take the system's glass.
    case primaryPageCard
    /// A card on a settings or detail page: always a stable grouped surface.
    case secondaryPageCard
    /// The grouped card a section of rows is drawn inside.
    case groupedSection
    /// A surface that is currently chosen: a selected member, a selected list row.
    case selection
    /// A surface that has been opened in place, without being chosen: an expanded
    /// proxy group's body, a disclosure that is showing its contents.
    case expanded
    /// A surface behind an interactive control: an icon button, a value field.
    case control
    /// The page canvas itself, behind everything.
    case pageCanvas
    /// A destructive action's own surface, where it has one.
    case destructiveAction

    /// Only the top-level page card is allowed to take the system's glass
    /// treatment: it is the one surface with nothing behind it to obscure.
    public var permitsNativeGlass: Bool {
        self == .primaryPageCard
    }

    /// Whether the role is a grouped card rather than a page-level surface.
    ///
    /// A card takes the grouped radius and a border; a canvas does not.
    public var isCard: Bool {
        switch self {
        case .primaryPageCard, .secondaryPageCard, .groupedSection:
            return true
        case .selection, .expanded, .control, .pageCanvas, .destructiveAction:
            return false
        }
    }
}

/// Icon tint roles. The mapping is to system colours so that a role keeps its
/// meaning under Increase Contrast and in both appearances.
public enum HakoAccentRole: String, CaseIterable, Sendable {
    case blue
    case cyan
    case green
    case indigo
    case orange
    case pink
    case purple
    case teal

    public var color: Color {
        switch self {
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .indigo: .indigo
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .teal: .teal
        }
    }
}

/// The platform rules the pages ask about, rather than branching at each site.
public enum HakoPlatformLayout {
    /// macOS presents a page as the system settings idiom - a grouped `Form`
    /// whose sections are the platform's own cards - instead of painting cards
    /// inside a scroll view.
    ///
    /// This is the single most load-bearing branch in the whole design system: it
    /// decides whether a page is a `Form` with `Section`s or a `ScrollView` with
    /// painted cards, and the two are not interchangeable at the row level. It is
    /// `true` on macOS deliberately, because a desktop settings window that wears a
    /// phone's card stack reads as an iPad app on a Mac.
    public static var pageUsesSystemSettingsIdiom: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    /// Desktop primary cards are painted; the glass treatment is reserved for the
    /// touch platforms where the card really does float over content.
    public static var primaryPageCardUsesLiquidGlass: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    /// Touch cards wear the system material up to (not including) the release that
    /// introduced the glass language, where the reference implementation swaps to
    /// `glassEffect`. The cutoff is on the *system* version, so a build running on
    /// an older system keeps the material it was designed against.
    public static func touchCardWearsSystemMaterial(onSystemMajorVersion major: Int) -> Bool {
        major < 27
    }

    public static var touchCardWearsSystemMaterial: Bool {
        touchCardWearsSystemMaterial(
            onSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    /// Whether the container a row sits in draws the disclosure indicator itself.
    ///
    /// This is the fix for the double chevron, and it is deliberately a property of
    /// the container rather than a per-call-site flag. On the touch client a page is a
    /// `ScrollView` of painted cards, so nothing else draws an indicator and the row
    /// does. On the desktop and on the focus platform the container is the system's
    /// grouped form, which draws one for every navigable row, so the row does not.
    ///
    /// The failure mode this prevents is precise: a `NavigationLink` inside a `Form`
    /// gets the platform's indicator, and a custom chevron on top of it renders as
    /// `>>`. Hiding one with an opacity would leave the row's trailing inset wrong, so
    /// the rule is expressed as "who owns the indicator" and answered here once.
    public static var containerDrawsDisclosureIndicator: Bool {
        #if os(iOS)
            false
        #else
            true
        #endif
    }
}

/// The colours a page draws with. Passed in rather than read from a global so the
/// screenshots' forced-dark mode and the normal appearance cannot disagree.
///
/// The first five slots are the reference implementation's own set. `selected`,
/// `expanded` and `control` were added by this migration because complex pages - the
/// proxy workspace, the connection list, an expanded group - need to say "this one"
/// and "this is open" with a surface, and the alternative was each of them reaching
/// for `Color.accentColor.opacity(...)` with its own number.
public struct HakoProductPalette: Equatable {
    public let canvas: Color
    public let surface: Color
    public let raisedFill: Color
    public let separator: Color
    public let card: Color
    /// The fill of a surface that is currently chosen.
    public let selected: Color
    /// The fill of a surface that has been opened in place.
    public let expanded: Color
    /// The fill behind an interactive control that is not a card.
    public let control: Color

    public init(
        canvas: Color,
        surface: Color,
        raisedFill: Color,
        separator: Color,
        card: Color? = nil,
        selected: Color? = nil,
        expanded: Color? = nil,
        control: Color? = nil
    ) {
        self.canvas = canvas
        self.surface = surface
        self.raisedFill = raisedFill
        self.separator = separator
        self.card = card ?? surface
        // The accent is the same role in every appearance, so a selection is the
        // accent at the token's alpha rather than a second colour constant.
        self.selected = selected ?? Color.accentColor.opacity(HakoTheme.Opacity.selectedFill)
        self.expanded = expanded ?? raisedFill
        self.control = control ?? raisedFill
    }

    /// The palette the app draws with, built from system semantic colours.
    public static var system: HakoProductPalette {
        #if os(macOS)
            HakoProductPalette(
                canvas: Color(nsColor: .windowBackgroundColor),
                surface: Color(nsColor: .controlBackgroundColor),
                raisedFill: Color(nsColor: .unemphasizedSelectedContentBackgroundColor),
                separator: Color(nsColor: .separatorColor),
                card: Color(nsColor: Self.macOSCardColor)
            )
        #elseif os(tvOS)
            // tvOS has none of the grouped or plain system backgrounds, and this
            // migration does not restyle the focus platform. The roles are filled
            // with appearance-adaptive hierarchical colours so the shared
            // components compile and look neutral there rather than pulling the
            // touch palette in by force.
            HakoProductPalette(
                canvas: Color.clear,
                surface: Color.primary.opacity(0.08),
                raisedFill: Color.primary.opacity(0.12),
                separator: Color.primary.opacity(0.20)
            )
        #else
            HakoProductPalette(
                canvas: Color(uiColor: .systemGroupedBackground),
                surface: Color(uiColor: .secondarySystemGroupedBackground),
                raisedFill: Color(uiColor: .tertiarySystemFill),
                separator: Color(uiColor: .separator)
            )
        #endif
    }

    /// The fill a role draws with.
    ///
    /// A page asks for the role it means and the palette answers with a colour, so
    /// "the selected member" is one decision in one place rather than a literal at
    /// every call site.
    public func fill(for role: HakoSurfaceRole) -> Color {
        switch role {
        case .primaryPageCard, .secondaryPageCard, .groupedSection:
            return card
        case .selection:
            return selected
        case .expanded:
            return expanded
        case .control:
            return control
        case .pageCanvas:
            return canvas
        case .destructiveAction:
            return surface
        }
    }

    #if os(macOS)
        /// The card fill on the desktop. `alternatingContentBackgroundColors` is the
        /// pair AppKit uses for exactly this purpose; the fallback covers the
        /// configurations where the list is empty rather than indexing blindly.
        private static var macOSCardColor: NSColor {
            let colors = NSColor.alternatingContentBackgroundColors
            return colors.count > 1 ? colors[1] : .controlBackgroundColor
        }
    #endif
}

/// The desktop detail column's geometry.
///
/// Frame, padding, alignment and background, and nothing else - see `HakoTheme.Regular.Detail`.
/// The pages that fill it keep their own scroll view or form and their own title, which is what
/// makes this a column rather than a page.
public struct HakoRegularDetailContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(
                maxWidth: HakoTheme.Regular.Detail.maximumContentWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, HakoTheme.Regular.Detail.horizontalInset)
            .background(HakoProductPalette.system.canvas)
    }
}
