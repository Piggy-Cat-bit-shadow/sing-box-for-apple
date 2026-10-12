import Library
import SwiftUI

public struct HTTPProxyCard: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool
    private let onToggle: (Bool) async -> Void

    public init(
        systemProxyAvailable: Binding<Bool>,
        systemProxyEnabled: Binding<Bool>,
        onToggle: @escaping (Bool) async -> Void
    ) {
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        self.onToggle = onToggle
    }

    public var body: some View {
        // The phone home's card language, which is where this card sits: the same painted
        // surface the page's other cards are drawn with - `HakoProductPalette.system` and
        // `HakoTheme.Radius.groupedSection` - rather than `DashboardCardView`'s own
        // `cardStyle()`. That surface is a different material (a glass effect on the 26
        // releases), a different radius (16 against the token's 26/20) and no hairline,
        // which is what made this one card disagree with the cards beneath it. The card
        // surface is all that changes: the row, the toggle and the padding are as they were.
        HakoCardSurface(
            fill: HakoProductPalette.system.card,
            separator: HakoProductPalette.system.separator,
            cornerRadius: HakoTheme.Radius.groupedSection
        ) {
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
