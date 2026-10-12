import Library
import SwiftUI

public struct HTTPProxyCard: View {
    /// The card surface this card is drawn on.
    ///
    /// HAKO is the phone's presentation layer and is not the shared component's own
    /// language, so the surface is the caller's choice rather than this type's default. A
    /// caller that says nothing gets `.standard`, which is what this card looked like
    /// before the phone's page asked for anything - so `OverviewView` and the desktop's
    /// card grid, which share this type, are untouched by the phone's styling.
    ///
    /// Only the wrapper differs between the two. The row, the toggle, the bindings and the
    /// toggle action below are one implementation, evaluated the same way in both cases.
    public enum SurfaceStyle {
        /// `DashboardCardView`, i.e. the dashboard's own `cardStyle()`.
        case standard
        /// The card language of the phone's HAKO pages - `HakoCardSurface`.
        case hako
    }

    @EnvironmentObject private var profile: ExtensionProfile
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool
    private let surfaceStyle: SurfaceStyle
    private let onToggle: (Bool) async -> Void

    public init(
        systemProxyAvailable: Binding<Bool>,
        systemProxyEnabled: Binding<Bool>,
        surfaceStyle: SurfaceStyle = .standard,
        onToggle: @escaping (Bool) async -> Void
    ) {
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        self.surfaceStyle = surfaceStyle
        self.onToggle = onToggle
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

    /// The surface this card has always had, unchanged: `DashboardCardView` at its own
    /// metrics. This is the default, and the one the phone is the only caller *not* to use.
    private var standardSurface: some View {
        DashboardCardView(title: "") {
            content
        }
    }

    /// The phone home's card language, which is where this card sits among HAKO cards: the
    /// same painted surface the page's other cards are drawn with - `HakoProductPalette.system`
    /// and `HakoTheme.Radius.groupedSection` - rather than `cardStyle()`. That surface is a
    /// different material (a glass effect on the 26 releases), a different radius (16 against
    /// the token's 26/20) and no hairline, which is what made this one card disagree with the
    /// cards beneath it.
    ///
    /// `DashboardCardView`'s own padding and width, so nothing but the surface changes.
    private var hakoSurface: some View {
        HakoCardSurface(
            fill: HakoProductPalette.system.card,
            separator: HakoProductPalette.system.separator,
            cornerRadius: HakoTheme.Radius.groupedSection
        ) {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The card's one row: the icon and name, and the switch. The only implementation of
    /// this card's content, shared by both surfaces.
    private var content: some View {
        HStack {
            DashboardCardHeader(icon: "network", title: "System HTTP Proxy")
            Spacer()
            Toggle(isOn: $systemProxyEnabled) {}
                .labelsHidden()
            #if os(macOS)
                .toggleStyle(.switch)
            #endif
                .onChangeCompat(of: systemProxyEnabled) { newValue in
                    Task {
                        await onToggle(newValue)
                    }
                }
        }
    }
}
