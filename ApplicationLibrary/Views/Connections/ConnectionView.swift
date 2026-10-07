import Libbox
import Library
import SwiftUI

/// How a connection row is presented.
public enum ConnectionRowStyle {
    /// The row draws its own card. Used where the list is a scroll of independent cards.
    case standalone
    /// The row draws nothing around itself, because the list groups rows into one card.
    ///
    /// This is the shape a connection list wants: it can hold hundreds of rows, and a card per
    /// row means a material, a corner radius and a stroke per row - the per-row cost the design
    /// notes warn about - as well as a list of cards rather than a grouped list.
    case groupedRow
}

@MainActor
public struct ConnectionView: View {
    private let connection: Connection
    private let style: ConnectionRowStyle

    public init(_ connection: Connection, style: ConnectionRowStyle = .standalone) {
        self.connection = connection
        self.style = style
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func format(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    public func formatInterval(_ createdAt: Date, _ closedAt: Date) -> String {
        LibboxFormatDuration(Int64((closedAt.timeIntervalSince1970 - createdAt.timeIntervalSince1970) * 1000))
    }

    @State private var alert: AlertState?
    @State private var showDetails = false

    public var body: some View {
        Button {
            showDetails = true
        } label: {
            rowBody
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .modifier(ConnectionRowCard(style: style))
        #endif
        .alert($alert)
        .contextMenu {
            if connection.closedAt == nil {
                Button("Close", role: .destructive) {
                    Task {
                        await closeConnection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background {
            NavigationLink(isActive: $showDetails) {
                ConnectionDetailsView(connection)
                #if os(tvOS)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            BackButton()
                        }
                    }
                #endif
            } label: {
                EmptyView()
            }
            .opacity(0)
        }
    }

    /// The record, in the shared data-row composition.
    ///
    /// The row this replaces was three columns of `caption2` monospaced text under a
    /// title: the destination, the figures and the route, all at the same weight and all
    /// truncated at the same moment. On a long host name or an IPv6 literal the figures
    /// and the route won the line and the destination - the only part that says what the
    /// connection *is* - became `2001:db8:…:1`.
    ///
    /// The order is now the manual's: the record's identity first and with
    /// `layoutPriority`, its route beneath it, the badges next, and the figures in a
    /// trailing column that yields first and is monospaced so a list of rows can be read
    /// down rather than across.
    @ViewBuilder
    private var rowBody: some View {
        #if os(tvOS)
            legacyBody
        #else
            HakoDataRow(
                title: connection.displayDestination,
                route: routeSummary,
                badges: badges,
                badgeRole: .category,
                titleIsMonospaced: connection.ipVersion == 6
            ) {
                // The review removed the leading icon: every row led with the same shape in one of
                // four colours, which is decoration on a list that is read for its text, and it
                // pushed the destination off the left edge. The row is its text now, and the mode
                // chip below says what the icon was trying to say.
                EmptyView()
            } trailing: {
                HakoMetricStack(metrics, tint: connection.closedAt == nil ? .primary : .secondary)
            }
            // The review's item on this list, twice over: it is read as a list, and the gap under
            // each record was `row`, then `compact`. `tight` still separates two records - the
            // divider does the separating - without the list feeling airy.
            .padding(.vertical, style == .standalone ? HakoTheme.Spacing.standard : HakoTheme.Spacing.tight)
            .padding(.horizontal, style == .standalone ? HakoTheme.Spacing.standard : 0)
            .foregroundStyle(Color.textColor)
        #endif
    }

    /// What the connection is: its network, its protocol, the inbound it arrived on, and its state.
    private var badges: [String] {
        var items = [connection.network.uppercased()]
        if !connection.protocolName.isEmpty {
            items.append(connection.protocolName)
        }
        if let mode = inboundMode {
            items.append(mode)
        }
        items.append(connection.closedAt == nil ? String(localized: "Active") : String(localized: "Closed"))
        return items
    }

    /// The inbound this connection arrived on, as the core reported it.
    ///
    /// The review asked for a TUN/Mixed chip that is never guessed, so this reads the field the
    /// connection was built with: `Connection.inboundType` comes straight from the core's
    /// `inboundType`, the same value the connection's detail page shows as "Inbound Type".
    /// The two names the review asked for are the two this client actually runs - the tun and the
    /// mixed inbound - and anything else is shown as the core names it rather than mapped onto a
    /// vocabulary this client does not own.
    private var inboundMode: String? {
        let raw = connection.inboundType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "tun": return "TUN"
        case "mixed": return "Mixed"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Where it went: the group that chose it, and the node that carried it.
    ///
    /// The whole chain was here, plus the rule that matched and the inbound it arrived on, joined
    /// into a line long enough to be truncated on nearly every row. The review's point is that a
    /// folded list is read to answer one question - which group, which node - and the rest is
    /// detail. Two hops, and the row is legible at a glance.
    private var routeSummary: String {
        let chain = Array(connection.chain.reversed())
        let group = chain.first
        let node = connection.outbound.isEmpty ? chain.dropFirst().first : connection.outbound
        // Named, not arrowed.
        //
        // The review asked for the group and the node to be readable as what they are: "a → b"
        // leaves the reader to work out which is which, and on a direct connection it read as a
        // node that does not exist. The names are the core's own - nothing is invented for a
        // direct route.
        switch (group, node) {
        case let (group?, node?):
            return group == node
                ? String(localized: "Group: \(group)")
                : String(localized: "Group: \(group) · Node: \(node)")
        case let (group?, nil):
            return String(localized: "Group: \(group)")
        case let (nil, node?):
            return String(localized: "Node: \(node)")
        default:
            return ""
        }
    }

    /// What it has cost, and when it started.
    private var metrics: [HakoMetricStack.Line] {
        var lines = [
            HakoMetricStack.Line(symbol: "arrow.up", text: LibboxFormatBytes(connection.uploadTotal)),
            HakoMetricStack.Line(symbol: "arrow.down", text: LibboxFormatBytes(connection.downloadTotal)),
        ]
        if let closedAt = connection.closedAt {
            lines.append(HakoMetricStack.Line(
                symbol: "clock",
                text: formatInterval(connection.createdAt, closedAt)
            ))
        } else {
            lines.append(HakoMetricStack.Line(
                symbol: "speedometer",
                text: "\(LibboxFormatBytes(connection.upload))/s"
            ))
        }
        lines.append(HakoMetricStack.Line(symbol: "calendar", text: format(connection.createdAt)))
        return lines
    }

    /// The focus platform keeps the previous arrangement, whose larger type and simpler
    /// structure suit a television at ten feet.
    private var legacyBody: some View {
        HStack(alignment: .top, spacing: HakoTheme.Spacing.row) {
            HakoIconWell(tint: connectionAccent.color) {
                Image(systemName: connectionSymbol)
                    .font(.caption.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: HakoTheme.Spacing.compact) {
                    Text(verbatim: "\(connection.network.uppercased()) \(connection.displayDestination)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: HakoTheme.Spacing.compact)
                    HakoStatusBadge(
                        connection.closedAt == nil ? String(localized: "Active") : String(localized: "Closed"),
                        emphasis: connection.closedAt == nil ? .success : .failure
                    )
                }

                HStack(alignment: .top, spacing: HakoTheme.Spacing.compact) {
                    VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                        Text(verbatim: "\u{2191} \(LibboxFormatBytes(connection.uploadTotal))")
                        Text(verbatim: "\u{2193} \(LibboxFormatBytes(connection.downloadTotal))")
                    }
                    VStack(alignment: .leading, spacing: HakoTheme.Spacing.tight) {
                        Text(format(connection.createdAt))
                        if let closedAt = connection.closedAt {
                            Text(formatInterval(connection.createdAt, closedAt))
                        } else {
                            Text(verbatim: "\(LibboxFormatBytes(connection.upload))/s")
                        }
                    }
                    Spacer(minLength: HakoTheme.Spacing.compact)
                    VStack(alignment: .trailing, spacing: HakoTheme.Spacing.tight) {
                        Text(connection.inboundType + "/" + connection.inbound)
                        Text(connection.chain.reversed().joined(separator: "/"))
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .foregroundColor(.textColor)
    }

    /// The icon a row leads with: what kind of traffic this connection is.
    private var connectionSymbol: String {
        switch connection.network {
        case "udp":
            return "arrow.up.arrow.down"
        default:
            return "arrow.left.arrow.right"
        }
    }

    private var connectionAccent: HakoAccentRole {
        connection.closedAt == nil ? .green : .blue
    }

    private nonisolated func closeConnection() async {
        do {
            try await CommandTarget.standaloneClient().closeConnection(connection.id)
        } catch {
            await MainActor.run {
                alert = AlertState(action: "close connection", error: error)
            }
        }
    }
}

/// Draws a connection row's card, or nothing when the list owns the card.
private struct ConnectionRowCard: ViewModifier {
    let style: ConnectionRowStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .standalone:
            content.cardStyle()
        case .groupedRow:
            content
        }
    }
}
