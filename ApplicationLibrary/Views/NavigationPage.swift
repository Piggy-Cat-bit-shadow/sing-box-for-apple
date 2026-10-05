import Foundation
import Library
import SwiftUI

public enum NavigationPage: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case dashboard
    #if os(macOS)
        case groups
        case connections
    #endif
    case logs
    case tools
    case settings
}

public extension NavigationPage {
    init?(snapshotValue: String) {
        switch snapshotValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dashboard":
            self = .dashboard
        case "logs":
            self = .logs
        case "tools":
            self = .tools
        case "settings":
            self = .settings
        #if os(macOS)
            case "groups":
                self = .groups
            case "connections":
                self = .connections
        #endif
        default:
            return nil
        }
    }

    #if os(macOS)
        static var macosDefaultPages: [NavigationPage] {
            [.logs, .tools, .settings]
        }
    #endif

    var label: some View {
        Label(title, systemImage: iconImage)
            .tint(.textColor)
    }

    var title: String {
        switch self {
        case .dashboard:
            // The first-level destination is Home. It was "Dashboard" - a name that
            // belonged to the page's previous shape, a grid of kernel figures - and
            // the tab bar has called it Home since the shell was introduced, so the
            // two were showing the user two names for one page.
            return String(localized: "Home")
        #if os(macOS)
            case .groups:
                // The proxy workspace. "Groups" is the core's word for the object;
                // "Proxies" is what the page is to the person reading the sidebar.
                return String(localized: "Proxies")
            case .connections:
                return String(localized: "Connections")
        #endif
        case .logs:
            return String(localized: "Logs")
        case .tools:
            return String(localized: "Tools")
        case .settings:
            // The third tab is More, not Settings: it contains the settings, and it
            // also contains the About links, the sponsors and the licence terms.
            return String(localized: "More")
        }
    }

    /// The one-line explanation a sidebar or a destination row shows beneath the title.
    ///
    /// A Mac sidebar row has room for one; the touch client's tab bar does not, which is
    /// why this is a separate value rather than part of `title`.
    var subtitle: String? {
        switch self {
        case .dashboard:
            return String(localized: "Session and traffic")
        #if os(macOS)
            case .groups:
                return String(localized: "Choose an outbound")
            case .connections:
                return String(localized: "What is being routed")
        #endif
        case .logs:
            return String(localized: "Tunnel output")
        case .tools:
            return String(localized: "Diagnostics and network tools")
        case .settings:
            return String(localized: "Connection, application and core")
        }
    }

    private var iconImage: String {
        switch self {
        case .dashboard:
            return "text.and.command.macwindow"
        #if os(macOS)
            case .groups:
                return "rectangle.3.group.fill"
            case .connections:
                return "list.bullet.rectangle.portrait.fill"
        #endif
        case .logs:
            return "list.bullet.rectangle"
        case .tools:
            return "terminal.fill"
        case .settings:
            return "gear.circle.fill"
        }
    }

    @MainActor
    var contentView: some View {
        Group {
            switch self {
            case .dashboard:
                DashboardView()
            #if os(macOS)
                case .groups:
                    GroupListView()
                case .connections:
                    ConnectionListView()
            #endif
            case .logs:
                LogView()
            case .tools:
                ToolsView()
            case .settings:
                SettingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #if os(iOS)
            .background(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    #if os(macOS)
        @MainActor
        func visible(_ profile: ExtensionProfile?) -> Bool {
            switch self {
            case .groups, .connections:
                return profile?.status.isConnectedStrict == true
            default:
                return true
            }
        }
    #endif
}
