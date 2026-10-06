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

        /// The navigation header's controls.
        ///
        /// The circle a back or close control draws is deliberately smaller than the
        /// target it answers to: the reference implementation keeps a compact glyph
        /// and expands only the hit area, which is why these are two numbers and
        /// not one. A 44pt circle in a 52pt header would be a button with a header
        /// around it.
        public static let navigationControlDiameter: CGFloat = 32
        public static let navigationControlGlyphSize: CGFloat = 14

        /// The action capsule in a workspace header: one row of icon-only actions.
        public static let actionCapsuleHeight: CGFloat = 34
        public static let actionItemMinimumWidth: CGFloat = 40
        public static let actionCapsuleHorizontalPadding: CGFloat = 4

        /// A row whose trailing side is a switch. The floor is the touch target,
        /// not the glyph, so a toggle row never shrinks below what a finger needs.
        public static let toggleRowMinHeight: CGFloat = 44

        /// The segmented control above a workspace's content.
        public static let segmentedTabHeight: CGFloat = 32
    }

    /// Fonts, by role rather than by page.
    ///
    /// A page picks a role - "this is a section header", "this is the value" - and
    /// the design system decides the face. The alternative, which this migration
    /// replaces, was nine pages each choosing `.headline` or `.caption` for the same
    /// job and drifting apart one edit at a time.
    ///
    /// Only the roles that a page genuinely needs are here. A metric is monospaced
    /// because a column of figures has to line up, not because it is a number.
    public enum FontRole {
        /// The centered title of a navigation header.
        public static var navigationTitle: Font {
            .headline
        }

        /// The caption above a grouped card.
        public static var sectionHeader: Font {
            .footnote.weight(.semibold)
        }

        /// A row's title.
        public static var rowPrimary: Font {
            .body
        }

        /// A row's title where the row is a data row rather than a setting.
        public static var dataPrimary: Font {
            .subheadline.weight(.semibold)
        }

        /// A row's value, aligned in a column.
        public static var value: Font {
            .subheadline.monospacedDigit()
        }

        /// A measured figure: a latency, a rate, a byte count.
        public static var metric: Font {
            .caption.monospacedDigit().weight(.semibold)
        }

        /// A badge or pill.
        public static var badge: Font {
            .caption.weight(.semibold)
        }

        /// The explanation under a card or a row.
        public static var footnote: Font {
            .footnote
        }

        /// An empty state's headline and body.
        public static var emptyTitle: Font {
            .headline
        }

        public static var emptyBody: Font {
            .subheadline
        }

        /// A card's own heading, inside the card.
        public static var cardTitle: Font {
            .footnote.weight(.semibold)
        }
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

        /// The capsule around a workspace's actions and the bottom search field.
        public static let capsule: CGFloat = 17
        public static let searchField: CGFloat = 22
    }

    public enum Opacity {
        public static let regularSidebarSelection: Double = 0.08

        /// The hairline a card draws around itself. One value, because a card that
        /// outlines itself more strongly than the card beside it reads as selected.
        public static let cardBorder: Double = 0.16

        /// The divider between two rows of the same card.
        public static let rowDivider: Double = 0.18

        /// A row's fill while the finger is down.
        public static let pressedFill: Double = 0.06

        /// A surface that is currently chosen, rather than merely present.
        public static let selectedFill: Double = 0.12

        /// A surface that has been opened in place - an expanded proxy group.
        public static let expandedFill: Double = 0.06

        /// A control that cannot act. Applied to the whole control, glyph included.
        public static let disabled: Double = 0.35
    }

    /// Geometry of the desktop's sidebar-and-detail layout.
    ///
    /// The desktop keeps `NavigationSplitView`, so these are the measurements that
    /// make its sidebar and detail column read as the same design as the touch
    /// client's pages rather than as a second interface.
    public enum Regular {
        public enum Sidebar {
            public static let iconSize: CGFloat = 22
            /// The floor a Mac window's sidebar may be dragged to. Below it the
            /// section captions and the two-line remote-control row truncate, which
            /// is the failure this number exists to prevent.
            public static let minimumWidth: CGFloat = 200
            /// The desktop sidebar is narrower than the touch one by design: a Mac
            /// window has a detail column beside it and a phone does not.
            public static let idealWidth: CGFloat = {
                #if os(macOS)
                    return 220
                #else
                    return 256
                #endif
            }()
            /// Kept under the alias the earlier round introduced, so a call site that
            /// already asked for `width` keeps compiling while every reader sees the
            /// same number as `idealWidth`.
            public static var width: CGFloat {
                idealWidth
            }

            public static let maximumWidth: CGFloat = 280
            public static let topInset: CGFloat = 32
        }

        public enum Detail {
            public static let maximumContentWidth: CGFloat = 1_120
            public static let horizontalInset: CGFloat = 56
            public static let destinationRowMinHeight: CGFloat = 68
            /// The narrowest detail column that still reads as a column rather than a
            /// squeezed list. A Mac window at its own minimum width lands here.
            public static let minimumContentWidth: CGFloat = 420
        }
    }

    /// Geometry that exists only on the desktop.
    public enum MacOS {
        public static let destinationRowIconSize: CGFloat = 26
        /// The smallest window the client lays out correctly, not the smallest one
        /// AppKit would allow. The sidebar plus `Detail.minimumContentWidth`, with the
        /// divider between them.
        public static let minimumWindowWidth: CGFloat = 760
        public static let minimumWindowHeight: CGFloat = 480
    }

    /// Geometry of the primary pages.
    public enum Layout {
        /// The icon well in a primary destination row.
        public static let destinationRowIconSize: CGFloat = 29
        /// The row's floor when it carries a subtitle. Not a round number because it
        /// is the sum of the reference implementation's parts, and rounding it moves
        /// every row on the page.
        public static let destinationRowTargetHeight: CGFloat = 62.7
        /// The icon tile of a list row that is not a primary destination: a profile, a proxy
        /// group, a member inside one.
        ///
        /// Smaller than `destinationRowIconSize` because these rows appear inside a grouped
        /// card rather than as the card's own entries, and the reference implementation sizes
        /// them separately for that reason.
        public static let proxyGroupIconSize: CGFloat = 24
        public static let proxyGroupIconCornerRadius: CGFloat = 6

        /// The desktop detail column.
        ///
        /// The regular layout centres a content column and insets it, rather than letting a page
        /// stretch across a wide window. It only ever applies frame, padding, alignment and
        /// background: a container that created a scroll view, list or form of its own would sit
        /// around pages that already own one, and nesting two is how a desktop page ends up with
        /// two scroll indicators.
        public enum Detail {
            public static let maximumContentWidth: CGFloat = 1_120
            public static let horizontalInset: CGFloat = 56
        }

        /// The leading selection slot of a row that can be chosen. Reserved whether or not the row
        /// is the chosen one, so every row's text begins at the same place and choosing a row does
        /// not move anything.
        public static let selectionSlotWidth: CGFloat = 22

        /// The icon column of a metrics block - a connection row's traffic figures, a group's
        /// counts. Fixed so the glyphs of every row share one vertical line.
        public static let metricSymbolColumn: CGFloat = 13
        /// And its value column. Fixed for the same reason: a value sized to its own text moved
        /// the column beside it, so "1.2 GB" and "0 kB" could not be read down the page.
        public static let metricValueColumn: CGFloat = 66

        /// Horizontal inset of the primary pages' content column.
        public static let cardHorizontalInset: CGFloat = 20

        /// The icon well's size on the platform that is drawing.
        ///
        /// The reference implementation carries two numbers for one role: 29 on the touch
        /// platforms, where the row is the page's own composition, and 26 on the desktop,
        /// where the row sits inside the system's settings form and a 29pt tile makes the
        /// system's own row metrics look wrong. Resolving it here is what keeps a divider
        /// inset, an icon well and a row floor agreeing about which one applies.
        public static var resolvedDestinationRowIconSize: CGFloat {
            HakoPlatformLayout.pageUsesSystemSettingsIdiom
                ? MacOS.destinationRowIconSize
                : destinationRowIconSize
        }

        /// The divider starts where the row's text does, which is the icon plus the
        /// gap after it - on the platform that is drawing.
        public static var destinationRowDividerInset: CGFloat {
            resolvedDestinationRowIconSize + Spacing.row
        }

        /// A card's own inner padding. `HakoSection` insets horizontally by this and
        /// a card's content does the same, so a row's title lines up with the section
        /// caption above it rather than with the card's edge.
        public static let cardInnerPadding: CGFloat = Spacing.standard

        /// The navigation header a settings, workspace, modal or report page wears.
        ///
        /// Tall enough for a 44pt hit target with the page's own top inset above it,
        /// which is what keeps the control off the status bar on a notched phone.
        public static let navigationHeaderHeight: CGFloat = 52
        public static let pageTopInset: CGFloat = Spacing.compact

        /// The bottom search field of a workspace, and the room a scrolling page has
        /// to leave so its last card is not underneath one.
        public static let bottomSearchHeight: CGFloat = 44
        public static let bottomSearchInset: CGFloat = Spacing.standard
        public static var bottomSearchClearance: CGFloat {
            bottomSearchHeight + bottomSearchInset * 2
        }

        /// How much room a root page's last row leaves for the floating tab bar. The
        /// shell's bar floats over the canvas, so the page has to reserve the space
        /// itself; without this the last card sits under it.
        public static let rootTabClearance: CGFloat = 12

        /// The gap between two sections of a page, and between two cards of one
        /// section. Named so a page asks for "a section gap" rather than for 24.
        public static let sectionSpacing: CGFloat = Spacing.section
        public static let cardSpacing: CGFloat = Spacing.cardGap

        /// The icon well of a list row that is not a primary destination: a profile, a proxy
        /// group, a member inside one.
        public static var listRowIconSize: CGFloat {
            proxyGroupIconSize
        }
    }
}
