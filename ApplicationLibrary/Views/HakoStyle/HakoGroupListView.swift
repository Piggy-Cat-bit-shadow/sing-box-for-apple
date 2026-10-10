//
//  HakoGroupListView.swift
//  ApplicationLibrary
//
//  The phone's Proxies page, from `hako-ui` @ `c1935cf`.
//
//  # Why this is a copy rather than a wrapper
//
//  The reference's change to this page is a rewrite, not a decoration: `GroupListView.swift` is
//  48 lines upstream and 291 in the reference, and the reference version is the page. A
//  wrapper would have had to reimplement it anyway.
//
//  So the page lives here, in the fork's own namespace, and it is reachable only from the phone. The
//  upstream file at `ApplicationLibrary/Views/Groups/GroupListView.swift`
//  is untouched, which is what keeps an iPad and a Mac on upstream's presentation.
//
//  # What is shared
//
//  The view model, the command client and the connection model are upstream's, unchanged. The fork's
//  page reads `GroupListViewModel` exactly as upstream's page does; nothing about the data or the command-client
//  subscription is forked.
//
//  Generated from `origin/hako-ui` by `scripts/dev/port_hako_pages.py`. Re-run that after a sync
//  rather than editing here, or the next port will disagree with this file.
//

import Library
import SwiftUI

/// The proxy workspace: every outbound group, its strategy, what it currently resolves
/// to, and its members - expanded in place.
///
/// # What this replaces
///
/// The page was already a list of expandable group cards, which is the right shape. What
/// it was missing is everything that makes a workspace a workspace rather than a list:
/// no search, so finding one node among a hundred and thirty-seven meant scrolling; no
/// actions, so testing every group meant tapping each one; no summary, so the page never
/// said how many groups it was showing or whether a test was running; and a card whose
/// top and bottom halves were drawn by two different modifiers, so an expanded group's
/// body did not meet its own header.
///
/// The expansion stays inline. It is the reference implementation's behaviour and it is
/// the right one here: a group's members are a property of the group, and pushing a page
/// per group would make comparing two groups a navigation exercise.
///
/// # What is not here
///
/// The reference's proxy page carries actions this client has no backend for - editing a
/// member, inspecting its JSON, pinning a group, updating a provider. They are absent
/// rather than disabled, because a disabled button that will never enable is worse than
/// no button. What this client can do is what is offered: test everything, test one
/// group, test one member, select a member, and open or close every group.
public struct HakoGroupListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = GroupListViewModel()
    @State private var searchText = ""

    public init() {}

    public var body: some View {
        page
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

    @ViewBuilder
    private var page: some View {
        #if os(tvOS)
            // The focus platform keeps the previous arrangement: a grid of members with a
            // caption per group, and no search field, because there is no keyboard.
            legacyContent
        #else
            HakoWorkspaceScaffold(
                title: String(localized: "Proxies"),
                leading: Self.leadingControl,
                search: HakoWorkspaceSearch(
                    text: $searchText,
                    prompt: "Search proxies",
                    placement: .bottomBar,
                    accessibilityIdentifier: "hako.proxies.search"
                ),
                actions: { workspaceActions },
                content: { workspaceContent }
            )
        #endif
    }

    /// The page is a sheet on the touch client and a sidebar selection on the desktop.
    /// Neither is a push, so neither wears a back control: a sheet ends and a desktop
    /// page is not somewhere the user arrived from somewhere else.
    private static var leadingControl: HakoNavigationLeadingControl {
        #if os(iOS)
            .close
        #else
            .none
        #endif
    }

    // MARK: - Actions

    @ViewBuilder
    private var workspaceActions: some View {
        if !viewModel.groups.isEmpty {
            HakoActionGroup {
                HakoToolbarAction(
                systemImage: "bolt.fill",
                label: String(localized: "Test all groups"),
                    isEnabled: viewModel.testingGroups.isEmpty
                ) {
                    for group in viewModel.groups {
                        viewModel.performGroupURLTest(group.tag)
                    }
                }

                HakoActionDivider()

                HakoToolbarAction(
                    systemImage: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                    label: allExpanded
                        ? String(localized: "Collapse all groups")
                        : String(localized: "Expand all groups")
                ) {
                    let expanded = !allExpanded
                    for group in viewModel.groups where group.isExpand != expanded {
                        viewModel.toggleExpand(groupTag: group.tag)
                    }
                }
            }
        }
    }

    private var allExpanded: Bool {
        !viewModel.groups.isEmpty && viewModel.groups.allSatisfy(\.isExpand)
    }

    // MARK: - Content

    @ViewBuilder
    private var workspaceContent: some View {
        if viewModel.isLoading {
            HakoLoadingState()
        } else if viewModel.groups.isEmpty {
            HakoEmptyState(
                symbol: "rectangle.3.group",
                title: "No proxies",
                message: "Proxy groups appear here once the core has loaded a configuration that has them."
            )
        } else if filteredGroups.isEmpty {
            HakoEmptyState(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "No group or node matches what you typed."
            )
        } else {
            summaryCard
            groupCards
        }
    }

    private var summaryCard: some View {
        HakoSummaryCard(
            String(localized: "Groups"),
            symbol: "rectangle.3.group.fill",
            tint: HakoAccentRole.neutral
        ) {
            HakoSummaryMetrics {
                HakoSummaryMetric(
                    String(localized: "Groups"),
                    value: "\(filteredGroups.count)",
                    symbol: "square.stack.3d.up.fill"
                )
                HakoSummaryMetric(
                    String(localized: "Nodes"),
                    value: "\(filteredGroups.reduce(0) { $0 + $1.items.count })",
                    symbol: "circle.grid.2x2.fill"
                )
                // The review's item on this page: a test used to add a third metric here - a
                // "Testing" label and its count - and take it away again when the test ended,
                // which pushed the card's two real figures sideways for as long as the test ran
                // and read as two controls appearing out of nowhere. The card is the page's
                // summary and its shape does not depend on what is happening; the group rows
                // themselves already say which group is being tested.
            }
        }
    }

    private var groupCards: some View {
        ForEach(filteredGroups, id: \.tag) { group in
            HakoDataCard(palette: .system) {
                HakoExpandableGroupRow(
                    name: group.tag,
                    strategy: group.displayType,
                    selectedMember: group.selected,
                    memberCount: group.items.count,
                    isExpanded: group.isExpand,
                    isTesting: viewModel.testingGroups.contains(group.tag),
                    isSelectable: group.selectable,
                    onToggle: {
                        viewModel.toggleExpand(groupTag: group.tag)
                    },
                    onTest: {
                        viewModel.performGroupURLTest(group.tag)
                    }
                )

                if group.isExpand {
                    HakoRowDivider(leadingInset: 0)
                    memberGrid(group)
                }
            }
        }
    }

    private func memberGrid(_ group: OutboundGroup) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: HakoTheme.Spacing.row, alignment: .leading)],
            alignment: .leading,
            spacing: 0
        ) {
            ForEach(group.items, id: \.tag) { item in
                HakoProxyMemberRow(
                    name: item.tag,
                    protocolName: item.displayType,
                    latency: item.urlTestDelay > 0 ? item.delayString : nil,
                    latencyTint: item.delayColor,
                    isSelected: group.selected == item.tag,
                    isSelectable: group.selectable,
                    isTesting: viewModel.testingItems.contains(item.tag),
                    onSelect: {
                        guard group.selectable, group.selected != item.tag else { return }
                        viewModel.selectOutbound(groupTag: group.tag, outboundTag: item.tag)
                    },
                    onTest: {
                        viewModel.performURLTest(item.tag)
                    }
                )
            }
        }
        .padding(.vertical, HakoTheme.Spacing.tight)
    }

    // MARK: - Search

    /// The groups the search leaves.
    ///
    /// A group survives if its own name matches, and it also survives if any of its
    /// members match - in which case it is shown with only those members, expanded, so
    /// the match is visible rather than hidden inside a collapsed card. The view model's
    /// groups are copied rather than filtered in place: a search must not change what the
    /// core reported, and a selection made while a filter is applied has to reach the
    /// real group.
    private var filteredGroups: [OutboundGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return viewModel.groups
        }
        return viewModel.groups.compactMap { group in
            if group.tag.lowercased().contains(query) {
                return group
            }
            let members = group.items.filter {
                $0.tag.lowercased().contains(query) || $0.displayType.lowercased().contains(query)
            }
            guard !members.isEmpty else { return nil }
            var matched = group
            matched.items = members
            matched.isExpand = true
            return matched
        }
    }

    // MARK: - The focus platform

    #if os(tvOS)
        private var legacyContent: some View {
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
            // The page canvas comes from the shared palette rather than a per-platform
            // literal, so this list sits on the same surface as the primary pages it is
            // reached from.
            .background(HakoProductPalette.system.canvas)
        }
    #endif
}
