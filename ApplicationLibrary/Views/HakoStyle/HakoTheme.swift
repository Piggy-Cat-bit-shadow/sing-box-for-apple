//
//  HakoTheme.swift
//  ApplicationLibrary
//
//  Design tokens for the HAKO/Clash-inspired presentation layer.
//
//  # Provenance
//
//  Extracted from Hako-Client (https://github.com/TokenPLS/Hako-Client, GPL-3.0),
//  `apple/HakoClientUI/Sources/HakoClientUI/Design/HakoTheme.swift` at
//  commit 62aa2f2fedffd46c245d5a87d2258c24bef3cd82, together with the platform
//  branch rules from `Layout/HakoPlatformLayout.swift`.
//
//  Only the numbers and the platform rules were taken. HAKO's models, providers,
//  kernel bindings and localization system are deliberately NOT part of this
//  migration: sing-box-for-apple stays the single source of truth for state and
//  behaviour, and these tokens only describe how a page is laid out.
//
//  # Why the constants are copied rather than re-estimated
//
//  The visual language this migration reproduces is a set of measurements, not a
//  look. Re-deriving "close enough" values from screenshots is how a port drifts:
//  every element is individually plausible and the whole page is wrong. These are
//  the values the reference implementation actually composes with, so a reviewer
//  can diff this file against HAKO's and find them unchanged.
//

import SwiftUI

public enum HakoTheme {
    /// Vertical rhythm. Every gap in the primary pages comes from here.
    public enum Spacing {
        public static let tight: CGFloat = 4
        public static let compact: CGFloat = 8
        public static let row: CGFloat = 12
        public static let cardGap: CGFloat = 10
        public static let standard: CGFloat = 16
        public static let section: CGFloat = 24
    }

    public enum Control {
        /// Pointer-sized rows on the desktop, touch-sized everywhere else.
        #if os(macOS)
            public static let pointerRowTarget: CGFloat = 28
        #else
            public static let pointerRowTarget: CGFloat = 44
        #endif

        public static let minimumHitTarget: CGFloat = 44
        public static let compactChoiceRowMinHeight: CGFloat = 48
        public static let fullWidthRowMinHeight: CGFloat = 49
    }

    /// Type that changes with the language, and the reason it does.
    ///
    /// A Han-script subtitle at `subheadline` is wider than its Latin counterpart at
    /// the same size, and the two-line rows this design uses would reflow. HAKO
    /// compensates by stepping the subtitle down and tightening the gap, so the row
    /// keeps one shape in every language the client ships.
    public enum Typography {
        public static func usesHanDensity(_ locale: Locale) -> Bool {
            let language = locale.identifier.prefix(2).lowercased()
            return language == "zh" || language == "ja"
        }

        public static func rowSubtitle(_ locale: Locale) -> Font {
            usesHanDensity(locale) ? .footnote : .subheadline
        }

        public static func rowSubtitleGap(_ locale: Locale) -> CGFloat {
            usesHanDensity(locale) ? 5 : Spacing.tight
        }
    }

    public enum Radius {
        public static let control: CGFloat = 8
        public static let icon: CGFloat = 9

        /// Cards grew a rounded-rectangle language in the 26 releases. The older
        /// radius is kept for the systems this client still supports, because the
        /// larger value reads as a bubble rather than a card there.
        public static var card: CGFloat {
            if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
                return 26
            }
            return 12
        }

        public static var groupedSection: CGFloat {
            if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
                return 26
            }
            return 20
        }

        public static let liquidGlassCard: CGFloat = 24
    }

    public enum Opacity {
        public static let regularSidebarSelection: Double = 0.08
    }

    /// Geometry of the desktop's sidebar-and-detail layout.
    ///
    /// The desktop keeps `NavigationSplitView`, so these are the measurements that
    /// make its sidebar and detail column read as the same design as the touch
    /// client's pages rather than as a second interface.
    public enum Regular {
        public enum Sidebar {
            public static let iconSize: CGFloat = 22
            public static let minimumWidth: CGFloat = 220
            /// The desktop sidebar is narrower than the touch one by design: a Mac
            /// window has a detail column beside it and a phone does not.
            public static let width: CGFloat = {
                #if os(macOS)
                    return 220
                #else
                    return 256
                #endif
            }()
            public static let maximumWidth: CGFloat = 272
            public static let topInset: CGFloat = 32
        }

        public enum Detail {
            public static let maximumContentWidth: CGFloat = 1_120
            public static let horizontalInset: CGFloat = 56
            public static let destinationRowMinHeight: CGFloat = 68
        }
    }

    /// Geometry that exists only on the desktop.
    public enum MacOS {
        public static let destinationRowIconSize: CGFloat = 26
    }

    /// Geometry of the primary pages.
    public enum Layout {
        /// The icon well in a primary destination row.
        public static let destinationRowIconSize: CGFloat = 29
        /// The row's floor when it carries a subtitle. Not a round number because it
        /// is the sum of the reference implementation's parts, and rounding it moves
        /// every row on the page.
        public static let destinationRowTargetHeight: CGFloat = 62.7
        /// Horizontal inset of the primary pages' content column.
        public static let cardHorizontalInset: CGFloat = 20
        /// The divider starts where the row's text does, which is the icon plus the
        /// gap after it.
        public static var destinationRowDividerInset: CGFloat {
            destinationRowIconSize + Spacing.row
        }
    }
}
