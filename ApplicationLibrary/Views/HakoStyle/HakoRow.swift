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
///
/// # Why the glyph is sized from the tile
///
/// The tile is a fixed measurement - 29pt on the touch platforms, 26 on the desktop - and
/// the glyph inside it used to inherit the row's Dynamic Type body font. At the
/// accessibility sizes that font is larger than the tile, so the symbol overflowed it and
/// painted over the row's own title: the screenshot pass at
/// `accessibility-extra-extra-extra-large` showed the proxy, network-tool and report rows
/// with their labels half-covered by their own icons.
///
/// A fixed-size mark cannot scale with the text around it. The `systemImage` initializer
/// derives the glyph from the tile; the generic one clamps Dynamic Type and clips, so a
/// caller that supplies its own icon cannot break out of the square either.
public struct HakoIconWell<Icon: View>: View {
    public let tint: Color
    public let size: CGFloat
    public let cornerRadius: CGFloat
    private let icon: Icon

    public init(
        tint: Color,
        size: CGFloat = HakoTheme.Layout.resolvedDestinationRowIconSize,
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
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

public extension HakoIconWell where Icon == AnyView {
    /// A well whose glyph is sized from the tile rather than from the row's text.
    init(
        tint: Color,
        systemImage: String,
        size: CGFloat = HakoTheme.Layout.resolvedDestinationRowIconSize,
        cornerRadius: CGFloat = HakoTheme.Radius.icon
    ) {
        self.init(tint: tint, size: size, cornerRadius: cornerRadius) {
            AnyView(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
            )
        }
    }
}

/// A destination row: icon well, title, optional subtitle, trailing chevron.
///
/// The row itself carries no action. It is the label of whatever presents the
/// destination - a `NavigationLink`, a `Button`, or a selection row - which keeps
/// this component free of navigation policy and lets the same row serve a push, a
/// sheet and a sidebar.
///
/// # Why the chevron is a parameter
///
/// A row inside the system's own grouped form already gets the platform's disclosure
/// indicator: a `NavigationLink` in a `Form` draws one. Drawing this component's
/// chevron on top of that is what produced the `>>` this migration exists to remove.
///
/// The two are therefore not both allowed, and the rule is structural rather than
/// cosmetic: this row draws its own indicator exactly when the surrounding container
/// does not. `HakoPlatformLayout.pageUsesSystemSettingsIdiom` is the same switch that
/// decides whether the container is a `Form` or a painted card, so it is also the
/// answer here - and a caller that knows better says so explicitly rather than hiding
/// one behind an opacity.
public struct HakoDestinationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.hakoContainerDrawsDisclosure) private var containerDrawsDisclosure

    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let tint: Color
    /// A short fact that belongs on the row's own line: a count, a state.
    public let badge: String?
    public let badgeEmphasis: HakoStatusBadge.Emphasis
    private let showsDisclosureOverride: Bool?

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color,
        badge: String? = nil,
        badgeEmphasis: HakoStatusBadge.Emphasis = .neutral,
        showsDisclosure: Bool? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.badge = badge
        self.badgeEmphasis = badgeEmphasis
        showsDisclosureOverride = showsDisclosure
    }

    /// One indicator, drawn by exactly one of the two parties.
    private var showsDisclosure: Bool {
        showsDisclosureOverride ?? !containerDrawsDisclosure
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
        HakoIconWell(tint: tint, systemImage: systemImage)
    }

    private var destinationCopy: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Typography.rowSubtitleGap(locale)) {
            HStack(alignment: .firstTextBaseline, spacing: HakoTheme.Spacing.compact) {
                Text(title)
                    .font(HakoTheme.FontRole.rowPrimary)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Inline only while the row still has one line to give: at
                // accessibility sizes the badge would push the title into a
                // truncation, so it moves below the copy instead.
                if let badge, !badge.isEmpty, dynamicTypeSize < .accessibility1 {
                    HakoStatusBadge(badge, emphasis: badgeEmphasis)
                }
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(HakoTheme.Typography.rowSubtitle(locale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let badge, !badge.isEmpty, dynamicTypeSize >= .accessibility1 {
                HakoStatusBadge(badge, emphasis: badgeEmphasis)
            }
        }
    }

    @ViewBuilder
    private var disclosureIcon: some View {
        if showsDisclosure {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
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

/// A navigable row's label: icon well, title, optional subtitle, one chevron.
///
/// It carries no action, exactly like `HakoDestinationRow`, and exists under its own
/// name because its contract is narrower: this is the label of something that pushes a
/// page, so it is the only row that draws a disclosure indicator, and it draws exactly
/// one. A page composes it with the presenter it already uses -
/// `NavigationLink { } label: { }` on the touch client, `NavigationLink(value:)` on the
/// desktop - and never adds a chevron of its own.
public struct HakoNavigationRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let tint: Color
    private let value: String?
    private let badge: String?
    private let badgeEmphasis: HakoStatusBadge.Emphasis
    private let linksOut: Bool
    private let showsDisclosure: Bool?

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color,
        value: String? = nil,
        badge: String? = nil,
        badgeEmphasis: HakoStatusBadge.Emphasis = .neutral,
        linksOut: Bool = false,
        showsDisclosure: Bool? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.value = value
        self.badge = badge
        self.badgeEmphasis = badgeEmphasis
        self.linksOut = linksOut
        self.showsDisclosure = showsDisclosure
    }

    public var body: some View {
        HakoRowBody(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            value: value,
            badge: badge,
            badgeEmphasis: badgeEmphasis,
            showsDisclosure: showsDisclosure ?? (linksOut ? false : nil)
        ) {
            // A row that leaves the app says so with the platform's external-link mark
            // rather than a chevron: a chevron promises another page inside this client,
            // and the difference is the one thing a user needs to know before tapping.
            if linksOut {
                Image(systemName: "arrow.up.forward.app")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(linksOut ? Text("Opens outside the app") : Text(""))
    }
}

/// The shared body of every row that carries an icon well, a title and a trailing
/// element.
///
/// Extracted so the navigable row, the toggle row and the destructive row cannot
/// drift: the icon size, the icon-to-text gap and the two-line spacing are the design
/// language, and three copies of them is how a page ends up with one row a point
/// taller than its neighbours.
struct HakoRowBody<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.hakoContainerDrawsDisclosure) private var containerDrawsDisclosure

    let title: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color?
    var value: String?
    var badge: String?
    var badgeEmphasis: HakoStatusBadge.Emphasis = .neutral
    /// `nil` defers to the container: the indicator is drawn by the row only when the
    /// container does not draw one. `false` suppresses it outright, which is what a row
    /// whose trailing element is a control needs.
    var showsDisclosure: Bool?
    /// A view that replaces the trailing disclosure - a toggle, a picker, a mark.
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        value: String? = nil,
        badge: String? = nil,
        badgeEmphasis: HakoStatusBadge.Emphasis = .neutral,
        showsDisclosure: Bool? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.value = value
        self.badge = badge
        self.badgeEmphasis = badgeEmphasis
        self.showsDisclosure = showsDisclosure
        self.trailing = trailing
    }

    var body: some View {
        HStack(
            alignment: dynamicTypeSize >= .accessibility1 ? .top : .center,
            spacing: HakoTheme.Spacing.row
        ) {
            if let systemImage, let tint {
                HakoIconWell(tint: tint, systemImage: systemImage)
            }

            copy

            Spacer(minLength: HakoTheme.Spacing.compact)

            trailing()

            if showsDisclosure ?? !containerDrawsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, HakoPlatformLayout.pageUsesSystemSettingsIdiom
            ? HakoTheme.Spacing.tight
            : HakoTheme.Spacing.compact)
        .frame(minHeight: HakoPlatformLayout.pageUsesSystemSettingsIdiom
            ? nil
            : HakoTheme.Control.toggleRowMinHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Typography.rowSubtitleGap(locale)) {
            HStack(alignment: .firstTextBaseline, spacing: HakoTheme.Spacing.compact) {
                Text(title)
                    .font(HakoTheme.FontRole.rowPrimary)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge, !badge.isEmpty, dynamicTypeSize < .accessibility1 {
                    HakoStatusBadge(badge, emphasis: badgeEmphasis)
                }
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(HakoTheme.Typography.rowSubtitle(locale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let badge, !badge.isEmpty, dynamicTypeSize >= .accessibility1 {
                HakoStatusBadge(badge, emphasis: badgeEmphasis)
            }

            if let value, !value.isEmpty {
                Text(value)
                    .font(HakoTheme.FontRole.value)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row whose trailing side is a switch, in the shared row language.
///
/// The toggle is the row's only control: the row's text does not also act, because a
/// row that both navigates and switches is the "error hit" this migration removes.
public struct HakoToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let isOn: Binding<Bool>
    private let isEnabled: Bool
    private let identifier: String?
    private let onChange: ((Bool) -> Void)?

    public init(
        _ title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        identifier: String? = nil,
        onChange: ((Bool) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.identifier = identifier
        self.onChange = onChange
    }

    public var body: some View {
        HakoRowBody(title: title, subtitle: subtitle, showsDisclosure: false) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .disabled(!isEnabled)
                .onChangeCompat(of: isOn.wrappedValue) { newValue in
                    onChange?(newValue)
                }
        }
        // The row is one combined accessibility element, so a test cannot reach its title
        // as a separate static text. The identifier is how a test asks the row what it says
        // - which is what the manual's "no raw property names" check needs.
        .accessibilityIdentifier(identifier ?? "")
        .opacity(isEnabled ? 1 : HakoTheme.Opacity.disabled)
    }
}

/// A row that carries out a destructive action: erase, reset, delete, uninstall.
///
/// One component so every destructive control in the client is red, is a row, and is
/// disabled in the same way, rather than three pages inventing three treatments for
/// the same promise.
public struct HakoDestructiveRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String = "trash.fill",
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HakoRowBody(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                tint: .red,
                showsDisclosure: false
            ) {
                EmptyView()
            }
        }
        .buttonStyle(HakoPushRowButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : HakoTheme.Opacity.disabled)
    }
}

/// A row that chooses one value out of several: a profile, a mode, an option.
///
/// The mark is drawn in both states rather than added and removed, so the row's
/// trailing edge does not move when the selection changes - which is what made the
/// pickers disagree about what "not selected" looks like.
public struct HakoSelectionRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let tint: Color?
    private let isSelected: Bool
    private let identifier: String?
    private let action: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        isSelected: Bool,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.isSelected = isSelected
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HakoRowBody(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                tint: tint,
                showsDisclosure: false
            ) {
                HakoSelectionMark(isSelected: isSelected)
            }
        }
        .buttonStyle(HakoPushRowButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// A row that says one thing and shows another: a label and its measured figure,
/// aligned so a column of them can be read down.
public struct HakoMetricRow: View {
    private let title: String
    private let value: String
    private let systemImage: String?
    private let tint: HakoAccentRole?

    public init(
        _ title: String,
        value: String,
        systemImage: String? = nil,
        tint: HakoAccentRole? = nil
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HakoCardLine(title, value: value, systemImage: systemImage, tint: tint)
    }
}
