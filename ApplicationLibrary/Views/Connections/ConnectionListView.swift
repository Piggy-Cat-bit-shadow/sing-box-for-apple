import Library
import SwiftUI
#if canImport(UIKit) && !os(tvOS)
    import UIKit
#endif

@MainActor
public struct ConnectionListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = ConnectionListViewModel()

    public init() {}

    public var body: some View {
        ConnectionListContentView(dataModel: viewModel.dataModel)
        #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionMenuButton(
                        connectionStateFilter: $viewModel.connectionStateFilter,
                        connectionSort: $viewModel.connectionSort,
                        closeAllConnections: viewModel.closeAllConnections
                    )
                }
            }
        #elseif os(macOS)
            .applySearchable(text: $viewModel.searchText, isSearching: $viewModel.isSearching, shouldShow: viewModel.isSearching)
            .toolbar {
                ToolbarItemGroup {
                    if #available(macOS 14.0, *) {
                        Button(action: viewModel.toggleSearch) {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    ConnectionMenuView(
                        connectionStateFilter: $viewModel.connectionStateFilter,
                        connectionSort: $viewModel.connectionSort,
                        closeAllConnections: viewModel.closeAllConnections
                    )
                }
            }
        #endif
            .alert($viewModel.alert)
            .onAppear {
                if !environments.connectionSearchText.isEmpty {
                    viewModel.searchText = environments.connectionSearchText
                    viewModel.isSearching = true
                }
                viewModel.connect()
            }
            .onDisappear {
                environments.connectionSearchText = viewModel.searchText
                viewModel.disconnect()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(HakoProductPalette.system.canvas)
    }
}

private struct ConnectionListContentView: View {
    @ObservedObject var dataModel: ConnectionDataModel

    var body: some View {
        VStack {
            if dataModel.isLoading {
                HakoEmptyState(symbol: "arrow.left.arrow.right", title: "Loading...", isBusy: true)
            } else if dataModel.filteredConnections.isEmpty {
                HakoEmptyState(
                    symbol: "arrow.left.arrow.right",
                    title: "No connections",
                    message: "Connections appear here while the service routes traffic."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(dataModel.filteredConnections.enumerated()), id: \.element.id) { index, connection in
                            // One card for the list rather than one per row on the touch
                            // platforms: a connection list holds hundreds of rows, and the
                            // design notes call out per-row material as the cost to avoid. The
                            // desktop keeps its independent cards, which is what a window list
                            // of this kind looks like there.
                            #if os(iOS)
                                ConnectionView(connection, style: .groupedRow)
                                    .padding(.horizontal, HakoTheme.Spacing.standard)
                                if index != dataModel.filteredConnections.count - 1 {
                                    HakoRowDivider(leadingInset: HakoTheme.Spacing.standard + HakoTheme.Layout.proxyGroupIconSize + HakoTheme.Spacing.row)
                                }
                            #else
                                ConnectionView(connection)
                            #endif
                        }
                    }
                    .padding(.vertical, HakoTheme.Spacing.cardGap)
                    #if os(iOS)
                        .background(
                            HakoCardSurface(
                                fill: HakoProductPalette.system.card,
                                separator: HakoProductPalette.system.separator,
                                cornerRadius: HakoTheme.Radius.groupedSection
                            ) {
                                Color.clear
                            }
                        )
                    #endif
                }
                .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
            }
        }
    }
}

#if os(iOS)
    private struct ConnectionMenuButton: UIViewRepresentable {
        @Binding var connectionStateFilter: ConnectionStateFilter
        @Binding var connectionSort: ConnectionSort
        let closeAllConnections: () -> Void
        @Environment(\.colorScheme) private var colorScheme

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        class Coordinator {
            var lastStateFilter: ConnectionStateFilter?
            var lastSort: ConnectionSort?
            var lastColorScheme: ColorScheme?
        }

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            let config = UIImage.SymbolConfiguration(scale: .large)
            button.setImage(UIImage(systemName: "line.3.horizontal.circle", withConfiguration: config), for: .normal)
            if #available(iOS 26.0, *) {
                button.tintColor = colorScheme == .dark ? .white : .black
            }
            button.showsMenuAsPrimaryAction = true
            button.menu = createMenu()
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)

            let coordinator = context.coordinator
            coordinator.lastStateFilter = connectionStateFilter
            coordinator.lastSort = connectionSort
            coordinator.lastColorScheme = colorScheme
            return button
        }

        func updateUIView(_ uiView: UIButton, context: Context) {
            let coordinator = context.coordinator
            let needsMenuUpdate = coordinator.lastStateFilter != connectionStateFilter ||
                coordinator.lastSort != connectionSort

            if needsMenuUpdate {
                coordinator.lastStateFilter = connectionStateFilter
                coordinator.lastSort = connectionSort
                uiView.menu = createMenu()
            }

            if coordinator.lastColorScheme != colorScheme {
                coordinator.lastColorScheme = colorScheme
                if #available(iOS 26.0, *) {
                    uiView.tintColor = colorScheme == .dark ? .white : .black
                }
            }
        }

        private func createMenu() -> UIMenu {
            let stateActions = ConnectionStateFilter.allCases.map { state in
                UIAction(
                    title: state.name,
                    state: connectionStateFilter == state ? .on : .off
                ) { _ in
                    connectionStateFilter = state
                }
            }

            let stateMenu = UIMenu(
                title: NSLocalizedString("State", comment: ""),
                options: .singleSelection,
                children: stateActions
            )

            let sortActions = ConnectionSort.allCases.map { sort in
                UIAction(
                    title: sort.name,
                    state: connectionSort == sort ? .on : .off
                ) { _ in
                    connectionSort = sort
                }
            }

            let sortMenu = UIMenu(
                title: NSLocalizedString("Sort By", comment: ""),
                options: .singleSelection,
                children: sortActions
            )

            let closeAction = UIAction(
                title: NSLocalizedString("Close All Connections", comment: ""),
                image: UIImage(systemName: "xmark.circle"),
                attributes: .destructive
            ) { _ in
                closeAllConnections()
            }

            return UIMenu(children: [stateMenu, sortMenu, closeAction])
        }
    }

#elseif os(macOS)
    private struct ConnectionMenuView: View {
        @Binding var connectionStateFilter: ConnectionStateFilter
        @Binding var connectionSort: ConnectionSort
        let closeAllConnections: () -> Void

        var body: some View {
            Menu {
                Picker("State", selection: $connectionStateFilter) {
                    ForEach(ConnectionStateFilter.allCases) { state in
                        Text(state.name)
                    }
                }

                Picker("Sort By", selection: $connectionSort) {
                    ForEach(ConnectionSort.allCases, id: \.self) { sortBy in
                        Text(sortBy.name)
                    }
                }

                Button("Close All Connections", role: .destructive) {
                    closeAllConnections()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private extension View {
        func applySearchable(text: Binding<String>, isSearching: Binding<Bool>, shouldShow: Bool) -> some View {
            if #available(macOS 14.0, *) {
                if shouldShow {
                    return AnyView(searchable(text: text, isPresented: isSearching))
                } else {
                    return AnyView(self)
                }
            } else {
                return AnyView(searchable(text: text))
            }
        }
    }
#endif
