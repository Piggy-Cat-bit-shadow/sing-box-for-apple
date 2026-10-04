//
//  HakoCard.swift
//  ApplicationLibrary
//
//  Cards and sections. Extracted from Hako-Client (GPL-3.0),
//  `Components/HakoCardSurface.swift` and `Components/HakoSection.swift` at commit
//  62aa2f2f, reduced to the parts this client uses.
//
//  # The two idioms
//
//  A section is presented one of two ways, and the platform decides which:
//
//    touch   a caption, then a painted rounded card holding the rows
//    desktop the system's own grouped form section, which is already a card
//
//  Both are "a section with rows in it". Keeping one component that branches at
//  this level is what stops the desktop from growing a second set of row views.
//

import SwiftUI

/// A painted card: the touch platforms' section body.
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
            .overlay(shape.stroke(separator.opacity(0.16), lineWidth: 0.5))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// A section of rows: a caption and a card on touch platforms, a native grouped
/// section on the desktop.
///
/// The content is expected to be a vertical stack of rows separated by
/// `HakoRowDivider`, which is what the reference implementation does; the card does
/// not insert separators itself because a row may legitimately be the last one.
public struct HakoSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let palette: HakoProductPalette
    private let content: Content

    public init(
        _ title: String? = nil,
        footer: String? = nil,
        palette: HakoProductPalette,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
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
                if let footer {
                    Text(footer)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.compact) {
                if let title {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
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

                if let footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
                }
            }
        }
    }
}

/// The divider between two rows of a card.
///
/// It is inset to the row's text column on touch platforms, and omitted entirely on
/// the desktop because the system section already draws its own separators.
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

/// The page container: a canvas, and the sections stacked on it.
///
/// Touch platforms scroll a column of painted cards with the page's own horizontal
/// inset; the desktop hands the sections to a grouped `Form`, which owns scrolling,
/// selection and its own card geometry.
public struct HakoPrimaryPage<Content: View>: View {
    private let palette: HakoProductPalette
    private let navigationTitle: String?
    private let content: Content

    public init(
        palette: HakoProductPalette = .system,
        navigationTitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.navigationTitle = navigationTitle
        self.content = content()
    }

    public var body: some View {
        #if os(macOS)
            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(palette.canvas)
        #else
            ScrollView {
                VStack(alignment: .leading, spacing: HakoTheme.Spacing.section) {
                    content
                }
                .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
                .padding(.vertical, HakoTheme.Spacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.canvas)
        #endif
    }
}
