import ApplicationLibrary
import Library
import SwiftUI

/// The sidebar rows.
///
/// The desktop keeps its own navigation - a `List` with a selection, which is what a
/// Mac window is expected to be - and takes the shared icon size and type from the
/// design tokens so the glyphs and the row text match the touch client's rather than
/// being sized by accident.
private extension View {
    func hakoSidebarRow() -> some View {
        self
            .labelStyle(.titleAndIcon)
            .imageScale(.large)
            .font(.system(size: HakoTheme.Regular.Sidebar.iconSize - 6, weight: .medium))
    }
}

/// The sidebar's information architecture: which page lives under which heading.
///
/// The list this replaces changed shape depending on the connection state - a
/// disconnected client saw one flat list, a connected one saw a `Section` captioned
/// "Dashboard" holding a row captioned "Overview", and the remote client saw a third
/// arrangement. Three lists, one product: the same page could be reached from three
/// different sidebar layouts depending on what the tunnel was doing.
///
/// The grouping is now a value, and it does not depend on the connection. What depends
/// on the connection is which rows are *available*, which is a different question and is
/// answered by hiding nothing: a session page is absent while there is no session to
/// show, and the headings do not move.
enum HakoSidebarSection: String, CaseIterable, Identifiable {
    /// A page reached without a session: the client's own front page.
    case primary
    /// What the tunnel is doing: the outbounds it can use and the traffic it carries.
    case session
    /// The tools and the settings: the pages that are about the client rather than
    /// about the traffic. HAKO calls this area Utilities, and the manual does too.
    case utilities

    var id: String {
        rawValue
    }

    var title: String? {
        switch self {
        case .primary: nil
        case .session: String(localized: "Session")
        case .utilities: String(localized: "Utilities")
        }
    }

    func pages(hasSession: Bool) -> [NavigationPage] {
        switch self {
        case .primary:
            return [.dashboard]
        case .session:
            return hasSession ? [.groups, .connections, .logs] : [.logs]
        case .utilities:
            return [.tools, .settings]
        }
    }
}

private struct HakoSidebarContent: View {
    @Binding var selection: NavigationPage
    @Binding var localSelection: NavigationPage
    /// Whether there is a tunnel whose outbounds and traffic can be listed.
    let hasSession: Bool
    /// Whether the core has reported any proxy group. A session without groups cannot
    /// show the proxy page, because there would be nothing on it.
    let hasGroups: Bool
    let toolsBadge: Int

    private var visibleSections: [HakoSidebarSection] {
        HakoSidebarSection.allCases
    }

    private func pages(in section: HakoSidebarSection) -> [NavigationPage] {
        section.pages(hasSession: hasSession).filter { page in
            if page == .groups {
                return hasGroups
            }
            return page.visible(nil) || hasSession
        }
    }

    var body: some View {
        List(selection: $localSelection) {
            ForEach(visibleSections) { section in
                let rows = pages(in: section)
                if !rows.isEmpty {
                    if let title = section.title {
                        Section(title) {
                            rowList(rows)
                        }
                    } else {
                        rowList(rows)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            localSelection = selection
        }
        .onChangeCompat(of: selection) { newValue in
            if localSelection != newValue {
                localSelection = newValue
            }
        }
        .onChangeCompat(of: localSelection) { newValue in
            if selection != newValue {
                Task { @MainActor in
                    selection = newValue
                }
            }
        }
    }

    @ViewBuilder
    private func rowList(_ rows: [NavigationPage]) -> some View {
        ForEach(rows, id: \.self) { page in
            page.label
                .hakoSidebarRow()
                .badge(page == .tools ? toolsBadge : 0)
        }
    }
}

public struct SidebarView: View {
    @Binding var selection: NavigationPage
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var sendManager: TaildropSendManager
    @State private var localSelection: NavigationPage = .dashboard

    public init(selection: Binding<NavigationPage>) {
        _selection = selection
    }

    public var body: some View {
        Group {
            if environments.remoteServer != nil {
                remoteContent
            } else if environments.extensionProfileLoading {
                ProgressView()
            } else if let profile = environments.extensionProfile {
                localContent(profile: profile)
            } else {
                HakoSidebarContent(
                    selection: $selection,
                    localSelection: $localSelection,
                    hasSession: false,
                    hasGroups: false,
                    toolsBadge: environments.toolsBadgeCount + sendManager.failedSessionCount
                )
            }
        }
    }

    private func localContent(profile: ExtensionProfile) -> some View {
        HakoSidebarContent(
            selection: $selection,
            localSelection: $localSelection,
            hasSession: profile.status.isConnectedStrict,
            hasGroups: Variant.screenshotMode || environments.commandClient.groups?.isEmpty == false,
            toolsBadge: environments.toolsBadgeCount + sendManager.failedSessionCount
        )
        .onChangeCompat(of: profile.status) {
            if !localSelection.visible(profile) {
                Task { @MainActor in
                    localSelection = .dashboard
                }
            }
        }
        .onReceive(environments.commandClient.$groups) { groups in
            if localSelection == .groups, groups?.isEmpty != false {
                Task { @MainActor in
                    localSelection = .dashboard
                }
            }
        }
    }

    private var remoteContent: some View {
        RemoteSessionSidebar(selection: $selection, localSelection: $localSelection)
    }
}

/// The sidebar while this client drives another device.
///
/// It is its own view rather than the local one with flags, because the questions it
/// asks are different: whether the *remote* core has reported groups, and what to do
/// with a selection that pointed at a page the remote session has taken away.
private struct RemoteSessionSidebar: View {
    @Binding var selection: NavigationPage
    @Binding var localSelection: NavigationPage
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var sendManager: TaildropSendManager
    @State private var hasGroups = false

    var body: some View {
        HakoSidebarContent(
            selection: $selection,
            localSelection: $localSelection,
            hasSession: true,
            hasGroups: hasGroups,
            toolsBadge: environments.toolsBadgeCount + sendManager.failedSessionCount
        )
        .onAppear {
            hasGroups = environments.commandClient.groups?.isEmpty == false
            // The remote session is a real one, so the session pages are reachable even
            // before the first status arrives.
            if localSelection == .dashboard, selection != .dashboard {
                localSelection = selection
            }
        }
        .onReceive(environments.commandClient.$groups) { groups in
            hasGroups = groups?.isEmpty == false
            if localSelection == .groups, groups?.isEmpty != false {
                Task { @MainActor in
                    localSelection = .dashboard
                }
            }
        }
        .onDisappear {
            if localSelection == .groups || localSelection == .connections {
                Task { @MainActor in
                    localSelection = .dashboard
                }
            }
        }
    }
}
