import SwiftUI

/// The state a page shows when it has nothing to show.
///
/// Three of these existed as bare centred text - "Empty logs", "Connecting...",
/// "Service not started", "No servers", "Loading..." - each saying the same kind of thing in
/// its own way. A page that is waiting, a page that is empty and a page that cannot reach its
/// service are different, and the user can only tell them apart if the client says which one it
/// is and shows it the same way every time.
///
/// The symbol and tone come from the caller, so the primitive stays a layout.
public struct HakoEmptyState: View {
    private let symbol: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let isBusy: Bool
    private let accent: HakoAccentRole

    public init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        isBusy: Bool = false,
        accent: HakoAccentRole = .blue
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.isBusy = isBusy
        self.accent = accent
    }

    public var body: some View {
        VStack(spacing: HakoTheme.Spacing.section) {
            HakoIconWell(tint: accent.color, size: HakoTheme.Layout.destinationRowIconSize + 12) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                }
            }

            VStack(spacing: HakoTheme.Spacing.tight) {
                Text(title)
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(HakoTheme.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
