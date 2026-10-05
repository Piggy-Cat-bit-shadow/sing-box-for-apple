//
//  HakoCard.swift
//  ApplicationLibrary
//
//  Cards, sections and the page containers.
//
//  Extracted from Hako-Client (GPL-3.0) at commit 62aa2f2f:
//  `Sources/HakoClientUI/Components/HakoCardSurface.swift`,
//  `Components/HakoSection.swift`, `Components/HakoProductRootPage.swift`
//  (`HakoProductPageSection`), `Components/HakoRowDivider.swift` and
//  `Components/HakoSectionCaption.swift`.
//
//  # The two section systems, which are not interchangeable
//
//  The reference implementation has TWO section components, and reading it is the only
//  way to know which page uses which:
//
//    `HakoProductPageSection`  a caption and a PAINTED card, used inside
//                              `HakoProductRootPage` - a `ScrollView` - for the root
//                              pages: Home, Utilities, More, Proxies, Activity.
//
//    `HakoSection`             a real SwiftUI `Section`, used inside a `Form`/`List`,
//                              for the SECONDARY settings pages: On Demand, Tunnel,
//                              Client Settings, the modal editors, the report pages.
//
//  The platform decides only whether that `Form` also takes `.formStyle(.grouped)`,
//  which is a macOS-only API. On iOS a plain `Form` is already an inset-grouped list,
//  so a settings page looks the same on both platforms - which is why
//  `HakoPlatformLayout.pageUsesSystemSettingsIdiom` is about the grouped style and not
//  about whether a form is used at all.
//
//  This file therefore provides one component per system, with the names this client
//  already used:
//
//    `HakoPageSection`       the painted one   (root and workspace pages)
//    `HakoSettingsSection`   the real `Section` (settings, modal and report pages)
//
//  Wrapping a settings row in a painted card is what made the earlier round's settings
//  pages read as a different product from the same client's root pages: the system's
//  own grouped list already draws the card, its header, its footer and its separators,
//  and a second card painted inside it is a card inside a card.
//

import SwiftUI

/// A painted card: the root and workspace pages' section body.
public struct HakoCardSurface<Content: View>: View {
    public let fill: Color
    public let separator: Color
    public let cornerRadius: CGFloat
    private let content: Content

    public init(
        fill: Color,
        separator: Color,
        cornerRadius: CGFloat = HakoTheme.Radius.card,
        @ViewBuilder content: () -> Content
    ) {
        self.fill = fill
        self.separator = separator
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .background(shape.fill(fill))
            .clipShape(shape)
            .overlay(shape.stroke(separator.opacity(HakoTheme.Opacity.cardBorder), lineWidth: 0.5))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// A section of rows on a root or workspace page: a caption and a painted card.
///
/// The card's inner padding is the reference's: horizontal `Spacing.standard`, and
/// vertical `Spacing.compact` only at the regular widths, because a compact touch page
/// gives the rows their own vertical rhythm through the row floor and a second inset on
/// top of it makes the card taller than its contents.
public struct HakoPageSection<Content: View>: View {
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
                .padding(.horizontal, HakoTheme.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let footnote {
                HakoFootnote(footnote)
            }
        }
    }
}

/// A section of rows on a settings, modal or report page: a real SwiftUI `Section`.
///
/// The system draws the card, the caption, the footnote and the separators. A page that
/// paints its own card here draws a card inside a card.
public struct HakoSettingsSection<Content: View>: View {
    private let title: String?
    private let footnote: LocalizedStringKey?
    private let content: Content

    public init(
        _ title: String? = nil,
        footnote: LocalizedStringKey? = nil,
        palette _: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    public var body: some View {
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
    }
}

/// The divider between two rows of a painted card.
///
/// It is inset to the row's text column, which is the icon plus the gap after it, and it
/// is a `Divider` rather than a separator because a painted card has no separators of its
/// own. A settings page does not use this: the system's grouped list draws its own, and a
/// second line beside one is the "double divider" the manual names.
public struct HakoRowDivider: View {
    private let leadingInset: CGFloat?

    public init(leadingInset: CGFloat? = HakoTheme.Layout.destinationRowDividerInset) {
        self.leadingInset = leadingInset
    }

    public var body: some View {
        if !HakoPlatformLayout.pageUsesSystemSettingsIdiom {
            if let leadingInset {
                Divider().padding(.leading, leadingInset)
            } else {
                Divider()
            }
        }
    }
}
