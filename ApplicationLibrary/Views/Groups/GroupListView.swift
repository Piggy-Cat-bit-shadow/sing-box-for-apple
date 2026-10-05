import Library
import SwiftUI

public struct GroupListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = GroupListViewModel()

    public init() {}
    public var body: some View {
        VStack {
            if viewModel.isLoading {
                HakoEmptyState(symbol: "square.stack.3d.up", title: "Loading...", isBusy: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(viewModel.groups, id: \.tag) { group in
                            if group.isExpand {
                                Section {
                                    GroupContentView(group: group)
                                        .padding(.bottom, HakoTheme.Spacing.standard)
                                } header: {
                                    GroupHeaderView(group: group)
                                }
                            } else {
                                GroupHeaderView(group: group)
                                GroupContentView(group: group)
                                    .padding(.bottom, HakoTheme.Spacing.standard)
                            }
                        }
                    }
                    .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
                    .padding(.vertical, HakoTheme.Spacing.section)
                }
            }
        }
        // The page canvas comes from the shared palette rather than a per-platform literal, so
        // this list sits on the same surface as the primary pages it is reached from.
        .background(HakoProductPalette.system.canvas)
        .environmentObject(viewModel)
        .alert($viewModel.alert)
        .onAppear {
            viewModel.connect()
        }
        .onReceive(environments.commandClient.$groups) { groups in
            Task { @MainActor in
                viewModel.setGroups(groups)
            }
        }
    }
}
