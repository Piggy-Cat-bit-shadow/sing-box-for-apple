import SwiftUI

public struct DashboardCardView<Content: View>: View {
    private let title: String
    @ViewBuilder private let content: () -> Content

    /// Which surface this card is drawn on. Read from the container rather than passed by each
    /// card, so that every card on one page is guaranteed to agree - see
    /// `DashboardCardSurfaceStyle`.
    @Environment(\.dashboardCardSurfaceStyle) private var surfaceStyle

    public init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    @ViewBuilder
    public var body: some View {
        switch surfaceStyle {
        case .standard:
            standardSurface
        case .hako:
            hakoSurface
        }
    }

    /// The surface the dashboard grid has always drawn: `cardStyle()` at this card's own metrics.
    @ViewBuilder
    private var standardSurface: some View {
        paddedContent
            .cardStyle()
    }

    /// The page's own card *tone*, at this card's own geometry.
    ///
    /// Only the fill changes. The radius stays this card's own 16 - the same number `cardStyle()`
    /// draws with - and the hairline `HakoCardSurface` can draw is suppressed, because the cards
    /// that already look right have neither a different radius nor a border, and a tone mismatch is
    /// not a reason to introduce one.
    ///
    /// The fill is the token the page's other cards use, so an opted-in card matches those whatever
    /// `cardStyle()` happens to draw on this release. A card that is not opted in keeps exactly what
    /// it drew before - which is what leaves the reference pair untouched.
    private var hakoSurface: some View {
        HakoCardSurface(
            fill: HakoProductPalette.system.card,
            separator: .clear,
            cornerRadius: 16
        ) {
            paddedContent
        }
    }

    private var paddedContent: some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 12) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
            .padding(EdgeInsets(top: 20, leading: 26, bottom: 20, trailing: 26))
        #else
            .padding(16)
        #endif
    }
}
