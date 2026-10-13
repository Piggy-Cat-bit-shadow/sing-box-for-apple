import SwiftUI

public struct PlatformSheetSize {
    let minWidth: CGFloat
    let minHeight: CGFloat

    public init(minWidth: CGFloat, minHeight: CGFloat) {
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    public static let `default` = PlatformSheetSize(minWidth: 500, minHeight: 400)
    public static let small = PlatformSheetSize(minWidth: 400, minHeight: 300)
}

public extension View {
    func platformSheet(
        isPresented: Binding<Bool>,
        size: PlatformSheetSize = .default,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(PlatformSheetModifier(isPresented: isPresented, size: size, onDismiss: onDismiss, content: content))
    }

    func platformSheet<Item: Identifiable>(
        item: Binding<Item?>,
        size: PlatformSheetSize = .default,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        modifier(PlatformSheetItemModifier(item: item, size: size, onDismiss: onDismiss, content: content))
    }
}

private struct PlatformSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let size: PlatformSheetSize
    let onDismiss: (() -> Void)?
    @ViewBuilder let content: () -> SheetContent

    func body(content: Content) -> some View {
        #if os(iOS)
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                NavigationStackCompat {
                    self.content()
                }
            }
        #elseif os(macOS)
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                NavigationStackCompat {
                    self.content()
                }
                .frame(minWidth: size.minWidth, minHeight: size.minHeight)
            }
        #elseif os(tvOS)
            content.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
                NavigationStackCompat {
                    self.content()
                }
            }
        #endif
    }
}

private struct PlatformSheetItemModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let size: PlatformSheetSize
    let onDismiss: (() -> Void)?
    @ViewBuilder let content: (Item) -> SheetContent

    func body(content: Content) -> some View {
        #if os(iOS)
            content.sheet(item: $item, onDismiss: onDismiss) { item in
                NavigationStackCompat {
                    self.content(item)
                }
            }
        #elseif os(macOS)
            content.sheet(item: $item, onDismiss: onDismiss) { item in
                NavigationStackCompat {
                    self.content(item)
                }
                .frame(minWidth: size.minWidth, minHeight: size.minHeight)
            }
        #elseif os(tvOS)
            content.fullScreenCover(item: $item, onDismiss: onDismiss) { item in
                NavigationStackCompat {
                    self.content(item)
                }
            }
        #endif
    }
}

public extension View {
    @ViewBuilder
    func presentationDetentsIfAvailable() -> some View {
        #if os(iOS) || os(tvOS)
            if #available(iOS 16.0, tvOS 17.0, *) {
                presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                self
            }
        #else
            self
        #endif
    }

    #if os(iOS) || os(tvOS)
        @available(iOS 16.0, tvOS 17.0, *)
        @ViewBuilder
        func presentationDetentsIfAvailable(_ detents: PresentationDetent...) -> some View {
            let detentSet: Set<PresentationDetent> = detents.isEmpty ? [.large] : Set(detents)
            presentationDetents(detentSet)
                .presentationDragIndicator(.visible)
        }
    #endif

    @ViewBuilder
    func actionButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(ActionButtonStyle())
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                frame(width: 44, height: 32)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
            } else {
                frame(width: 44, height: 32)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        #endif
    }
}

#if os(tvOS)
    /// The frame has to be applied to the label rather than to the button: the focus engine
    /// takes each button's focus region from the button's own layout frame, so sizing from the
    /// outside leaves the region at the glyph's size while the pill drawn around it is 70x48.
    private struct ActionButtonStyle: ButtonStyle {
        @Environment(\.isFocused) private var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: 70, height: 48)
                .contentShape(Rectangle())
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .background(isFocused ? Color.white : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
        }
    }
#endif

public struct ActionIconButton: View {
    let systemImage: String
    let action: () -> Void

    public init(_ systemImage: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
            #if !os(tvOS)
                .frame(width: 44, height: 32)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            #endif
                .contentShape(Rectangle())
        }
        #if os(tvOS)
        .actionButtonStyle()
        #else
        .buttonStyle(.plain)
        #endif
    }
}

public extension View {
    func cardStyle() -> some View {
        modifier(CardStyleModifier())
    }
}

/// Which surface a `DashboardCardView` draws on.
///
/// This exists because `cardStyle()` draws *a material whose colour depends on the release and on
/// how much content the card happens to hold*, which is fine for the dashboard grid that has always
/// used it and wrong for a page that has its own card language: on the phone's Home page the
/// status/connections pair rendered as a much darker panel than the upload/download pair and than
/// every other card on the page.
///
/// The same class of problem was already met and fixed once, for `HTTPProxyCard` - see that type's
/// `SurfaceStyle`, which is what this mirrors.
///
/// It is opt-in per card rather than set by the page, because the page's correct tone is the one
/// its cards already show: a card that is already right must not be restyled to fix a card that is
/// not. A container that sets it declares the tone for everything inside it, so a caller is free to
/// scope it to the cards that need it.
public enum DashboardCardSurfaceStyle: Sendable {
    /// `cardStyle()` - what the dashboard grid has always drawn, and the default everywhere.
    case standard
    /// The page's own card tone, taken from `HakoProductPalette.system.card`.
    case hako
}

private struct DashboardCardSurfaceStyleKey: EnvironmentKey {
    static let defaultValue: DashboardCardSurfaceStyle = .standard
}

public extension EnvironmentValues {
    var dashboardCardSurfaceStyle: DashboardCardSurfaceStyle {
        get { self[DashboardCardSurfaceStyleKey.self] }
        set { self[DashboardCardSurfaceStyleKey.self] = newValue }
    }
}

public extension View {
    /// Declares the surface every `DashboardCardView` inside this view draws on.
    func dashboardCardSurfaceStyle(_ style: DashboardCardSurfaceStyle) -> some View {
        environment(\.dashboardCardSurfaceStyle, style)
    }
}

private struct CardStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(backgroundColor)
                .cornerRadius(16)
        }
    }

    private var backgroundColor: Color {
        #if os(iOS)
            return Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
            return Color(nsColor: .textBackgroundColor)
        #elseif os(tvOS)
            switch colorScheme {
            case .dark:
                return Color(uiColor: .black)
            default:
                return Color(uiColor: .white)
            }
        #else
            return Color.clear
        #endif
    }
}
