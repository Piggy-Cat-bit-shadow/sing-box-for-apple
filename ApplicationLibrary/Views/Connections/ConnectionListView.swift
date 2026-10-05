import Libbox
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
        #if os(tvOS)
            ConnectionListContentView(dataModel: viewModel.dataModel)
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
        #else
            HakoWorkspaceScaffold(
                title: String(localized: "Activity"),
                leading: Self.leadingControl,
                search: HakoWorkspaceSearch(
                    text: $viewModel.searchText,
                    prompt: "Search connections",
                    // This workspace is presented as a sheet, and a sheet has no bottom bar
                    // for the system's search field - the same reason the proxy sheet draws
                    // its own. `.system` is for a page pushed inside a tab, which is how the
                    // reference presents its Activity page and how this one is not.
                    placement: Self.searchPlacement,
                    accessibilityIdentifier: "hako.activity.search"
                ),
                actions: { actions },
                // The content observes the data model itself. `ConnectionDataModel` owns the
                // loading flag and the connection list, and the workspace read both *through*
                // the view model - which the view does observe - so the model's changes
                // invalidated nothing: the page rendered its initial state and kept it. The
                // tunnel-stopped case showed a spinner that had already been cleared, and a
                // live connection list would not have appeared either.
                content: {
                    ConnectionDataObserver(dataModel: viewModel.dataModel) { content }
                }
            )
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
        #endif
    }

    /// A sheet on the touch client, a sidebar selection on the desktop. Neither is a
    /// push, so neither wears a back control.
    ///
    /// The manual's activity workspace has three lenses - connections, requests and logs.
    /// This client's core does not record requests, so there are two pages rather than a
    /// third tab that would have nothing behind it, and the connections lens is this one.
    private static var leadingControl: HakoNavigationLeadingControl {
        #if os(iOS)
            .close
        #else
            .none
        #endif
    }

    private static var searchPlacement: HakoWorkspaceSearch.Placement {
        #if os(iOS)
            // Presented as a sheet on the touch client, so the field is drawn.
            .bottomBar
        #else
            // A sidebar selection on the desktop, where the system field works.
            .system
        #endif
    }

    #if !os(tvOS)
        @ViewBuilder
        private var actions: some View {
            Menu {
                Picker("State", selection: $viewModel.connectionStateFilter) {
                    ForEach(ConnectionStateFilter.allCases) { state in
                        Text(state.name).tag(state)
                    }
                }

                Picker("Sort By", selection: $viewModel.connectionSort) {
                    ForEach(ConnectionSort.allCases, id: \.self) { sortBy in
                        Text(sortBy.name).tag(sortBy)
                    }
                }

                Divider()

                Button(role: .destructive) {
                    viewModel.closeAllConnections()
                } label: {
                    Label("Close All Connections", systemImage: "xmark.circle")
                }
                .disabled(viewModel.dataModel.filteredConnections.isEmpty)
            } label: {
                Label("Filter and sort", systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(Text("Filter and sort"))
        }

        @ViewBuilder
        private var content: some View {
            if viewModel.dataModel.isLoading {
                HakoLoadingState()
            } else if viewModel.dataModel.filteredConnections.isEmpty {
                HakoEmptyState(
                    symbol: "arrow.left.arrow.right",
                    title: viewModel.searchText.isEmpty ? "No connections" : "No matches",
                    message: viewModel.searchText.isEmpty
                        ? "Connections appear here while the service routes traffic."
                        : "No connection matches what you typed."
                )
            } else {
                summaryCard
                connectionCard
            }
        }

        private var summaryCard: some View {
            HakoSummaryCard(
                String(localized: "Connections"),
                symbol: "arrow.left.arrow.right",
                tint: .green
            ) {
                HakoSummaryMetrics {
                    HakoSummaryMetric(
                        String(localized: "Shown"),
                        value: "\(viewModel.dataModel.filteredConnections.count)",
                        symbol: "list.bullet"
                    )
                    HakoSummaryMetric(
                        String(localized: "Uploaded"),
                        value: LibboxFormatBytes(viewModel.dataModel.filteredConnections.reduce(0) { $0 + $1.uploadTotal }),
                        symbol: "arrow.up"
                    )
                    HakoSummaryMetric(
                        String(localized: "Downloaded"),
                        value: LibboxFormatBytes(viewModel.dataModel.filteredConnections.reduce(0) { $0 + $1.downloadTotal }),
                        symbol: "arrow.down"
                    )
                }
            }
        }

        /// One card for the whole list rather than one per row: a connection list holds
        /// hundreds of records, and a material, a corner radius and a stroke per record is
        /// the cost the design notes call out.
        private var connectionCard: some View {
            let connections = viewModel.dataModel.filteredConnections
            return HakoDataCard(palette: .system) {
                ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                    ConnectionView(connection, style: .groupedRow)
                    if index != connections.count - 1 {
                        HakoRowDivider(leadingInset: HakoTheme.Layout.proxyGroupIconSize + HakoTheme.Spacing.row)
                    }
                }
            }
        }
    #endif
}

#if os(tvOS)
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
#endif


/// Re-renders its content when the connections data model changes.
private struct ConnectionDataObserver<Content: View>: View {
    @ObservedObject var dataModel: ConnectionDataModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
