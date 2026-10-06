import Library
import SwiftUI

struct ProfileSelectorButton: View {
    let selectedItem: ProfilePreview?
    @Binding var isPickerPresented: Bool

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            HStack {
                Text(selectedItem?.name ?? "Select Profile")
                    .font(.system(size: buttonFontSize, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: buttonHeight)
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(SelectorButtonStyle())
        #else
        .buttonStyle(.plain)
        .selectorBackground()
        #endif
        .accessibilityIdentifier("hako.profile.select")
        .accessibilityLabel(Text("Profile"))
        .accessibilityValue(Text(selectedItem?.name ?? String(localized: "Select Profile")))
    }

    private var buttonHeight: CGFloat {
        #if os(tvOS)
            60
        #elseif os(macOS)
            32
        #else
            44
        #endif
    }

    private var buttonFontSize: CGFloat {
        #if os(macOS)
            13
        #else
            17
        #endif
    }

    private var chevronSize: CGFloat {
        #if os(macOS)
            10
        #else
            12
        #endif
    }
}

#if os(tvOS)
    private struct SelectorButtonStyle: ButtonStyle {
        @Environment(\.isFocused) private var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isFocused ? Color.white : Color.secondary.opacity(0.1))
                )
                .foregroundStyle(isFocused ? .black : .primary)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
#endif

// MARK: - View Extension

extension View {
    /// The control surface, from the design system.
    ///
    /// This was a glass capsule on the 26 releases and a hand-mixed grey rectangle, with a
    /// radius of 12 that no token named - a third material, for a control that sits among rows
    /// which are neither glass nor hand-mixed grey.
    func selectorBackground() -> some View {
        background(
            HakoProductPalette.system.control,
            in: RoundedRectangle(cornerRadius: HakoTheme.Radius.control, style: .continuous)
        )
    }
}
