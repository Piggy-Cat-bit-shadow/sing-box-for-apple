//
//  HakoRow.swift
//  ApplicationLibrary
//
//  Rows. Extracted from Hako-Client (GPL-3.0), `Components/HakoIconWell.swift`,
//  `Components/HakoEntryRow.swift` and the row half of
//  `Components/HakoProductRootPage.swift` at commit 62aa2f2f.
//
//  # The row is the design language
//
//  Three measurements carry the look: a 29pt tinted icon well with a white glyph, a
//  4pt (Han) / 4pt-with-footnote (Latin) gap between title and subtitle, and a
//  trailing tertiary chevron. Everything else on a page is a stack of these.
//

import SwiftUI

/// A tinted rounded square holding a white glyph.
public struct HakoIconWell<Icon: View>: View {
    public let tint: Color
    public let size: CGFloat
    public let cornerRadius: CGFloat
    private let icon: Icon

    public init(
        tint: Color,
        size: CGFloat = HakoTheme.Layout.destinationRowIconSize,
        cornerRadius: CGFloat = HakoTheme.Radius.icon,
        @ViewBuilder icon: () -> Icon
    ) {
        self.tint = tint
        self.size = size
        self.cornerRadius = cornerRadius
        self.icon = icon()
    }

    public var body: some View {
        icon
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            )
            .accessibilityHidden(true)
    }
}

/// A destination row: icon well, title, optional subtitle, trailing chevron.
///
/// The row itself carries no action. It is the label of whatever presents the
/// destination - a `NavigationLink`, a `Button`, or a selection row - which keeps
/// this component free of navigation policy and lets the same row serve a push, a
/// sheet and a sidebar.
public struct HakoDestinationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let tint: Color

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        Group {
            if dynamicTypeSize >= .accessibility1 {
                // At accessibility sizes the title and subtitle cannot share a line
                // with the icon without truncating, so the reference implementation
                // moves the copy under the icon instead of shrinking it.
                VStack(alignment: .leading, spacing: HakoTheme.Spacing.standard) {
                    HStack {
                        leadingIcon
                        Spacer(minLength: HakoTheme.Spacing.standard)
                        disclosureIcon
                    }
                    destinationCopy
                }
            } else {
                HStack(alignment: .center, spacing: HakoTheme.Spacing.row) {
                    leadingIcon
                    destinationCopy
                    Spacer(minLength: 0)
                    disclosureIcon
                }
            }
        }
        .padding(.vertical, HakoPlatformLayout.pageUsesSystemSettingsIdiom
            ? HakoTheme.Spacing.tight
            : HakoTheme.Spacing.compact)
        .frame(minHeight: rowFloor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var leadingIcon: some View {
        HakoIconWell(tint: tint) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
        }
    }

    private var destinationCopy: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Typography.rowSubtitleGap(locale)) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(HakoTheme.Typography.rowSubtitle(locale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var disclosureIcon: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// The row floor on touch platforms only: the desktop section idiom sizes its
    /// own rows, and forcing a height there fights the system form metrics.
    private var rowFloor: CGFloat? {
        guard !HakoPlatformLayout.pageUsesSystemSettingsIdiom else { return nil }
        return subtitle?.isEmpty == false ? HakoTheme.Layout.destinationRowTargetHeight : nil
    }
}

/// A full-width row with a trailing value: title, spacer, value, chevron.
///
/// The desktop settings idiom and the compact tool lists both use it, which is why
/// it takes plain strings rather than a destination.
public struct HakoEntryRow: View {
    private let title: String
    private let value: String?
    private let action: () -> Void

    public init(_ title: String, value: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: HakoTheme.Spacing.compact) {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: HakoTheme.Spacing.standard)
                if let value, !value.isEmpty {
                    Text(value)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: HakoPlatformLayout.pageUsesSystemSettingsIdiom
                    ? nil
                    : HakoTheme.Control.fullWidthRowMinHeight
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row whose trailing side is a control the caller owns - a toggle, a picker, a
/// button - with the same title metrics as the other rows.
public struct HakoValueRow<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: HakoTheme.Spacing.compact) {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: HakoTheme.Spacing.standard)
            trailing
        }
        .frame(minHeight: HakoTheme.Control.minimumHitTarget * 0.8)
    }
}

/// The press feedback of a row that pushes a destination.
///
/// A plain `Button` inside a card has no highlight on touch platforms, so the row
/// reads as static text. The desktop keeps the platform's own behaviour.
public struct HakoPushRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        #else
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: HakoTheme.Radius.control, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? Color.primary.opacity(0.06)
                                : Color.clear
                        )
                )
        #endif
    }
}

public extension View {
    /// The primary action button: a filled button, or the system's prominent glass
    /// button where that language exists.
    @ViewBuilder
    func hakoPrimaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// The row a tool or settings page presents.
///
/// One component so a page written once reads correctly on both idioms: the touch
/// platforms draw the tinted icon well and a chevron, the desktop keeps the
/// platform's own settings row. A page that branches on the platform at every row
/// would drift the moment one of them is edited.
public struct HakoToolRow: View {
    private let title: String
    private let systemImage: String
    private let tint: HakoAccentRole
    private let detail: String?

    /// - Parameter detail: a short trailing fact the row already knows - an unread
    ///   count, an endpoint's tag. It is a subtitle on the touch platforms, where the
    ///   row has a second line, and is left to the caller's own `.badge` on the
    ///   desktop, where the settings idiom has a dedicated place for it.
    public init(
        title: String,
        systemImage: String,
        tint: HakoAccentRole,
        detail: String? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
    }

    public var body: some View {
        #if os(macOS)
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
        #else
            HakoDestinationRow(
                title: title,
                subtitle: detail,
                systemImage: systemImage,
                tint: tint.color
            )
        #endif
    }
}
