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
            #if !os(tvOS)
                .padding(.vertical, style == .standalone ? HakoTheme.Spacing.standard : HakoTheme.Spacing.row)
                .padding(.horizontal, style == .standalone ? HakoTheme.Spacing.standard : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            #endif
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
