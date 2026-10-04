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
public enum HakoSurfaceRole: String, CaseIterable, Sendable {
    case primaryPageCard
    case secondaryPageCard
    case groupedSection
    case selection
    case destructiveAction

    /// Only the top-level page card is allowed to take the system's glass
    /// treatment: it is the one surface with nothing behind it to obscure.
    public var permitsNativeGlass: Bool {
        self == .primaryPageCard
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
}

/// The colours a page draws with. Passed in rather than read from a global so the
/// screenshots' forced-dark mode and the normal appearance cannot disagree.
public struct HakoProductPalette: Equatable {
    public let canvas: Color
    public let surface: Color
    public let raisedFill: Color
    public let separator: Color
    public let card: Color

    public init(
        canvas: Color,
        surface: Color,
        raisedFill: Color,
        separator: Color,
        card: Color? = nil
    ) {
        self.canvas = canvas
        self.surface = surface
        self.raisedFill = raisedFill
        self.separator = separator
        self.card = card ?? surface
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
