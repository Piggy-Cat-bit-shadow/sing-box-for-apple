//
//  HakoData.swift
//  ApplicationLibrary
//
//  The data-presentation layer: cards and rows for the pages that show live values
//  rather than settings.
//
//  # Why this is separate from HakoRow
//
//  A settings row and a data row are different objects that happen to be drawn with
//  the same measurements. A settings row is a promise - "tapping this changes
//  something" - and its shape is title, optional explanation, one control. A data row
//  is a record: it says where a connection is going, how it is routed and what it has
//  cost, all at once, in a list of hundreds, while the numbers change underneath it.
//
//  Wrapping a connection in a settings row is what produced the previous round's
//  layout failures: the metric pushed the destination off the line, the badge
//  overflowed, and an IPv6 literal was truncated into something unrecognisable.
//  These components put the priorities in the right order, so the record's identity
//  survives and the figures give way.
//

import SwiftUI

/// A badge's role, which decides how strongly it reads.
public enum HakoBadgeRole: String, CaseIterable, Sendable {
    /// A live fact about the record: its protocol, its state.
    case status
    /// Something the record satisfies: a rule's type, a group's strategy.
    case requirement
    /// A category the record belongs to. Reads the quietest.
    case category

    var emphasis: HakoStatusBadge.Emphasis {
        switch self {
        case .status: .info
        case .requirement: .neutral
        case .category: .neutral
        }
    }
}

/// The shared badge: a short label in a capsule, in one of three roles.
///
/// It is deliberately not a button and not a control. Anything interactive belongs in
/// the row's trailing slot, which is why a badge can never steal a tap.
public struct HakoBadge: View {
    private let text: String
    private let role: HakoBadgeRole
    private let emphasis: HakoStatusBadge.Emphasis?

    public init(_ text: String, role: HakoBadgeRole = .status, emphasis: HakoStatusBadge.Emphasis? = nil) {
        self.text = text
        self.role = role
        self.emphasis = emphasis
    }

    public var body: some View {
        HakoStatusBadge(text, emphasis: emphasis ?? role.emphasis)
            .accessibilityHidden(true)
    }
}

/// A horizontal run of badges that never overflows its row.
///
/// The run shows what fits and folds the rest into a `+n`, because a badge that pushes
/// the record's own name off the line has done more harm than the fact it carried. The
/// complete set is still in the row's accessibility label.
public struct HakoBadgeRow: View {
    private let badges: [String]
    private let role: HakoBadgeRole
    private let maximumVisible: Int

    public init(_ badges: [String], role: HakoBadgeRole = .status, maximumVisible: Int = 3) {
        self.badges = badges
        self.role = role
        self.maximumVisible = maximumVisible
    }

    public var body: some View {
        let visible = Array(badges.prefix(maximumVisible))
        let overflow = badges.count - visible.count

        HStack(spacing: HakoTheme.Spacing.tight) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, badge in
                HakoBadge(badge, role: role)
            }
            if overflow > 0 {
                HakoBadge("+\(overflow)", role: .category)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(badges.joined(separator: ", ")))
    }
}

/// A card that holds records rather than settings.
///
/// One card for the whole list on the touch client, not one per record: a connection
/// list holds hundreds of rows, and per-row material is the cost the design notes call
/// out. The card takes an optional header and an optional footnote, and draws its own
/// dividers between the rows it is given.
public struct HakoDataCard<Content: View, Header: View, Footer: View>: View {
    private let palette: HakoProductPalette
    private let header: Header
    private let footer: Footer
    private let content: Content

    public init(
        palette: HakoProductPalette = .system,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.header = header()
        self.footer = footer()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Spacing.compact) {
            header

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

            footer
        }
    }
}

public extension HakoDataCard where Header == EmptyView, Footer == EmptyView {
    init(
        palette: HakoProductPalette = .system,
        @ViewBuilder content: () -> Content
    ) {
        self.init(palette: palette, header: { EmptyView() }, footer: { EmptyView() }, content: content)
    }
}

/// A single record in a data card.
///
/// The composition, in the order it is laid out:
///
///   1. a leading mark - an icon well, a protocol tile, a state dot;
///   2. the record's identity: its destination or name, which gets the line's
///      `layoutPriority` and may be truncated only in the middle;
///   3. the route or chain beneath it, one line, secondary;
///   4. the badges, which yield before the identity;
///   5. the trailing figures, which yield last and are monospaced so a column of
///      them lines up.
///
/// A record therefore stays recognisable at every width: the destination is the last
/// thing to give way, and the metric is the first.
public struct HakoDataRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let route: String?
    private let badges: [String]
    private let badgeRole: HakoBadgeRole
    private let titleIsMonospaced: Bool
    private let leading: Leading
    private let trailing: Trailing

    public init(
        title: String,
        route: String? = nil,
        badges: [String] = [],
        badgeRole: HakoBadgeRole = .status,
        titleIsMonospaced: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.route = route
        self.badges = badges
        self.badgeRole = badgeRole
        self.titleIsMonospaced = titleIsMonospaced
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: HakoTheme.Spacing.row) {
            leading

            VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                Text(title)
                    .font(titleIsMonospaced
                        ? .subheadline.monospaced().weight(.semibold)
                        : HakoTheme.FontRole.dataPrimary)
                    // The identity is what the row is about, so it is the only part
                    // allowed to ask for space first, and the only part allowed to
                    // truncate - in the middle, because the end of a host name and the
                    // end of an IPv6 literal are what identify it.
                    .truncationMode(.middle)
                    .lineLimit(2)
                    .layoutPriority(2)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if let route, !route.isEmpty {
                    // Two lines, truncating at the end rather than in the middle.
                    //
                    // A route is composed of parts in reading order - the outbound chain, then
                    // the rule that chose it, then the inbound - and a middle truncation drops
                    // whatever is in the middle of that string, which is the rule as soon as the
                    // chain is long. `proxy-b / proxy-a...IP,CN` names neither the rule nor which
                    // part was lost. Truncating at the end loses only the tail.
                    Text(route)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                        .lineLimit(2)
                        .layoutPriority(1)
                        .textSelection(.enabled)
                }

                if !badges.isEmpty {
                    HakoBadgeRow(badges, role: badgeRole)
                        .layoutPriority(0)
                }
            }

            Spacer(minLength: HakoTheme.Spacing.compact)

            trailing
        }
        .padding(.vertical, HakoTheme.Spacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

public extension HakoDataRow where Leading == EmptyView, Trailing == EmptyView {
    init(
        title: String,
        route: String? = nil,
        badges: [String] = [],
        badgeRole: HakoBadgeRole = .status,
        titleIsMonospaced: Bool = false
    ) {
        self.init(
            title: title,
            route: route,
            badges: badges,
            badgeRole: badgeRole,
            titleIsMonospaced: titleIsMonospaced,
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

/// The figures at the end of a data row: uploaded, downloaded, duration.
///
/// A column of them, right-aligned and monospaced, so a list of connections can be
/// read down rather than across. Each pair is one line, because two figures on two
/// lines is what makes a dense list scanable.
public struct HakoMetricStack: View {
    public struct Line: Identifiable {
        public let id = UUID()
        public let symbol: String
        public let text: String

        public init(symbol: String, text: String) {
            self.symbol = symbol
            self.text = text
        }
    }

    private let lines: [Line]
    private let tint: Color?

    public init(_ lines: [Line], tint: Color? = nil) {
        self.lines = lines
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: HakoTheme.Spacing.tight) {
            ForEach(lines) { line in
                HStack(spacing: HakoTheme.Spacing.tight) {
                    Image(systemName: line.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(line.text)
                        .font(HakoTheme.FontRole.metric)
                        .foregroundStyle(tint ?? .secondary)
                        // A large figure gives way before the record's name does: the
                        // alternative is a rate that pushes a host name off the row.
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one-line summary above a data list: how many records there are, and what they
/// add up to.
///
/// It is a card rather than a row of loose figures because it is the list's own
/// heading, and a heading that is not a surface reads as content that has not loaded.
public struct HakoSummaryCard<Content: View>: View {
    private let title: String
    private let symbol: String
    private let tint: HakoAccentRole
    private let content: Content

    public init(
        _ title: String,
        symbol: String,
        tint: HakoAccentRole,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        HakoCardSurface(
            fill: HakoProductPalette.system.card,
            separator: HakoProductPalette.system.separator,
            cornerRadius: HakoTheme.Radius.groupedSection
        ) {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.row) {
                HakoCardTitle(verbatim: title, systemImage: symbol, tint: tint.color)
                content
            }
            .padding(HakoTheme.Layout.cardInnerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One labelled figure inside a summary card.
public struct HakoSummaryMetric: View {
    private let label: String
    private let value: String
    private let symbol: String?

    public init(_ label: String, value: String, symbol: String? = nil) {
        self.label = label
        self.value = value
        self.symbol = symbol
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
            HStack(spacing: HakoTheme.Spacing.tight) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A row of summary figures that becomes a column when the text is large.
///
/// The figures were laid out by each page in a plain `HStack`, so at the accessibility sizes
/// each cell took a third of the card and a single-word label - "Groups" - wrapped inside
/// itself, breaking after the "p". Three columns cannot hold accessibility-sized text in the
/// width of a phone.
public struct HakoSummaryMetrics<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HakoTheme.Spacing.standard) {
                content
            }
        } else {
            HStack(alignment: .top, spacing: HakoTheme.Spacing.standard) {
                content
            }
        }
    }
}

/// The header of a proxy group.
///
/// Composed from the reference's `HakoProxyGroupHeader` at commit 62aa2f2f, in its card
/// presentation: the group's name, and beneath it the strategy and the member it currently
/// resolves to as one uppercase line (`SELECT · DIRECT` in the reference's own render),
/// with the member count and the fold chevron together on the trailing side and the group
/// test as its own control.
///
/// The two controls are separate on purpose. Tapping the header folds the group; tapping
/// the test glyph measures every member. A single tap target for both is how a group gets
/// folded when the user meant to test it, which the manual names as a defect.
public struct HakoExpandableGroupRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let name: String
    private let strategy: String
    private let selectedMember: String?
    private let memberCount: Int
    private let isExpanded: Bool
    private let isTesting: Bool
    private let isSelectable: Bool
    private let onToggle: () -> Void
    private let onTest: (() -> Void)?

    public init(
        name: String,
        strategy: String,
        selectedMember: String?,
        memberCount: Int,
        isExpanded: Bool,
        isTesting: Bool = false,
        isSelectable: Bool = true,
        onToggle: @escaping () -> Void,
        onTest: (() -> Void)? = nil
    ) {
        self.name = name
        self.strategy = strategy
        self.selectedMember = selectedMember
        self.memberCount = memberCount
        self.isExpanded = isExpanded
        self.isTesting = isTesting
        self.isSelectable = isSelectable
        self.onToggle = onToggle
        self.onTest = onTest
    }

    public var body: some View {
        HStack(alignment: .center, spacing: HakoTheme.Spacing.compact) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: HakoTheme.Spacing.compact) {
                    copy
                    Spacer(minLength: HakoTheme.Spacing.compact)
                    countAndFold
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HakoPushRowButtonStyle())
            .accessibilityLabel(Text(name))
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("proxies.group.\(name)")

            if let onTest, !dynamicTypeSize.isAccessibilitySize {
                HakoActionItem(
                    systemImage: "bolt.fill",
                    label: String(localized: "Test latency"),
                    isBusy: isTesting,
                    action: onTest
                )
            }
        }
        .padding(.vertical, HakoTheme.Spacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// The strategy and the current selection as one line, in the reference's voice: the
    /// strategy alone when the group selects for itself, and `strategy · selection` when it
    /// does not, because a group that chooses automatically has no selection to name.
    private var summaryLine: String {
        let strategyText = strategy.uppercased()
        guard isSelectable, let selectedMember, !selectedMember.isEmpty else {
            return strategyText
        }
        return "\(strategyText) · \(selectedMember.uppercased())"
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
            Text(name)
                .font(HakoTheme.FontRole.dataPrimary)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Tail, not middle: a middle truncation of `SELECTOR · SERVER` renders as
                // `SEL...VER`, which is neither word. The beginning identifies the strategy.
                .truncationMode(.tail)
        }
    }

    private var countAndFold: some View {
        HStack(spacing: HakoTheme.Spacing.compact) {
            Text("\(memberCount)")
                .font(HakoTheme.FontRole.metric)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .accessibilityHidden(true)
        }
    }
}

/// A member of a proxy group, in the reference's card presentation.
///
/// The selected member is marked by a tinted surface and a 3pt bar down its leading edge
/// (`HakoProxyMemberCard`: `RoundedRectangle(cornerRadius: .control).fill(.tint.opacity(0.16))`
/// plus a 3pt `.tint` bar), not by a checkmark moved from column to column. A grid of
/// members is scanned left to right, and a mark that changes the row's leading inset as it
/// moves makes every row in the column shift.
public struct HakoProxyMemberRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let name: String
    private let protocolName: String
    private let latency: String?
    private let latencyTint: Color?
    private let isSelected: Bool
    private let isSelectable: Bool
    private let isTesting: Bool
    private let onSelect: () -> Void
    private let onTest: (() -> Void)?

    public init(
        name: String,
        protocolName: String,
        latency: String?,
        latencyTint: Color? = nil,
        isSelected: Bool,
        isSelectable: Bool = true,
        isTesting: Bool = false,
        onSelect: @escaping () -> Void,
        onTest: (() -> Void)? = nil
    ) {
        self.name = name
        self.protocolName = protocolName
        self.latency = latency
        self.latencyTint = latencyTint
        self.isSelected = isSelected
        self.isSelectable = isSelectable
        self.isTesting = isTesting
        self.onSelect = onSelect
        self.onTest = onTest
    }

    public var body: some View {
        HStack(spacing: HakoTheme.Spacing.compact) {
            Button(action: onSelect) {
                HStack(spacing: HakoTheme.Spacing.compact) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .truncationMode(.middle)
                        Text(protocolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: HakoTheme.Spacing.tight)
                }
                .padding(.vertical, HakoTheme.Spacing.compact)
                .padding(.leading, HakoTheme.Spacing.row)
                .padding(.trailing, HakoTheme.Spacing.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isSelectable)
            .accessibilityLabel(Text(name))
            .accessibilityValue(isSelected ? Text("Selected") : Text(""))
            .accessibilityIdentifier("proxies.member.\(name)")
            .background(
                RoundedRectangle(cornerRadius: HakoTheme.Radius.control, style: .continuous)
                    .fill(isSelected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                        : AnyShapeStyle(Color.clear))
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .opacity(isSelected ? 1 : 0)
            }

            if isTesting {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 44, minHeight: 44)
            } else if let latency {
                Text(latency)
                    .font(HakoTheme.FontRole.metric)
                    .foregroundStyle(latencyTint ?? .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            // The per-member test control is the first thing to go when the text is large: the
            // row's purpose is to name the member and be chosen, the group's own test action
            // measures every member anyway, and at accessibility sizes this control was eating
            // the width the name needed - `server2` rendered as `se...er2`.
            if let onTest, !dynamicTypeSize.isAccessibilitySize {
                HakoActionItem(
                    systemImage: "bolt.fill",
                    label: String(localized: "Test latency"),
                    isBusy: false,
                    action: onTest
                )
                .frame(width: HakoTheme.Control.actionItemMinimumWidth)
            }
        }
        .frame(minHeight: HakoTheme.Control.toggleRowMinHeight)
    }
}

/// A tile that carries out an action the page cannot express as a row: import, scan,
/// restore.
///
/// Used in the config centre and the import sheets, where the action is the point of
/// the page rather than an entry in a list.
public struct HakoActionTile: View {
    private let title: String
    private let systemImage: String
    private let tint: HakoAccentRole
    private let isEnabled: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String,
        tint: HakoAccentRole,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HakoActionTileLabel(title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(HakoPushRowButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : HakoTheme.Opacity.disabled)
        .accessibilityLabel(Text(title))
    }
}

/// The tile's face, for a caller that presents its own destination.
///
/// A tile whose action pushes a page cannot be a `Button`, and a page that re-drew the
/// tile by hand would be a second version of it. The face is therefore its own component
/// and `HakoActionTile` is one caller of it.
public struct HakoActionTileLabel: View {
    private let title: String
    private let systemImage: String
    private let tint: HakoAccentRole

    public init(_ title: String, systemImage: String, tint: HakoAccentRole) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    /// The reference's own tile: a soft tinted panel, a tinted glyph, a tinted label.
    ///
    /// It was a solid saturated square with a white glyph and a neutral label - the loudest
    /// thing on a page whose every other control is quiet, which is the "jarring button" this
    /// client was reported for. The reference's `QuickAddDoorLabelStyle` is the other way
    /// round: `.tint.opacity(0.11)` behind the glyph, a 52pt panel at the icon radius, and
    /// the label in the same tint as the glyph, so the tile reads as one soft object rather
    /// than a filled badge with a caption under it.
    public var body: some View {
        VStack(spacing: HakoTheme.Spacing.compact - 2) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    tint.color.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: HakoTheme.Radius.icon, style: .continuous)
                )
            Text(title)
                .font(.footnote)
                .foregroundStyle(tint.color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HakoTheme.Spacing.row)
        .contentShape(Rectangle())
    }
}

/// A full-width progress or status line above a card of records: an update in flight,
/// a subscription's expiry.
public struct HakoStatusLine: View {
    private let title: String
    private let detail: String?
    private let tint: HakoStatusBadge.Emphasis
    private let isBusy: Bool

    public init(_ title: String, detail: String? = nil, tint: HakoStatusBadge.Emphasis = .neutral, isBusy: Bool = false) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.isBusy = isBusy
    }

    public var body: some View {
        HStack(spacing: HakoTheme.Spacing.compact) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(tint.roleTint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: HakoTheme.Spacing.compact)
            if let detail {
                Text(detail)
                    .font(HakoTheme.FontRole.metric)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension HakoStatusBadge.Emphasis {
    var roleTint: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

/// A condition the page has to report but cannot resolve on its own.
///
/// Composed from the reference's Home at commit 62aa2f2f, which reports an unreadable VPN
/// configuration this way: the page's name, a prominent action to try again, and the reason
/// beneath it in the warning colour. The rest of the page still renders - the cards are
/// drawn from whatever is known, and the notice sits above them.
///
/// # Why this is not an alert
///
/// A passive condition - something the client found when it looked, rather than something the
/// user just asked for - must not take the screen. An alert for it blocks the page, hides the
/// cards that did load, and demands a tap before the user can do anything else, including
/// reading the error. A failure the user *caused* by an action is a different thing and still
/// belongs in an alert.
public struct HakoInlineNotice: View {
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
            HStack(spacing: HakoTheme.Spacing.compact) {
                Text(title)
                    .font(HakoTheme.FontRole.cardTitle)
                    .foregroundStyle(.primary)

                Spacer(minLength: HakoTheme.Spacing.compact)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hako.notice.action")
                }
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(HakoAccentRole.orange.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
        .padding(.vertical, HakoTheme.Spacing.standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hako.notice")
    }
}
