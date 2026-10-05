import AppKit
import ApplicationLibrary
import Foundation
import Library
import SwiftUI

@MainActor
public struct MainView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel: MainViewModel
    @State private var showCardManagement = false
    @State private var cardConfigurationVersion = 0
    @State private var remoteServers: [RemoteServer] = []
    @State private var settingsNavigationPath = NavigationPath()
    @State private var pendingSettingsPage: SettingsPage?
    @State private var didConfigureScreenshotWindow = false
    @State private var pendingScreenshotSelection: NavigationPage?

    private let profileEditor: (Binding<String>, Bool) -> AnyView = { text, isEditable in
        AnyView(ProfileEditorWrapperView(text: text, isEditable: isEditable))
    }

    private let ghosttyConfigEditor: (Binding<String>) -> AnyView = { text in
        AnyView(GhosttyConfigEditorWrapperView(text: text))
    }

    private let screenshotDefaultPixelHeight: CGFloat = 1000

    public init() {
        let initialSelection: NavigationPage = .dashboard
        if Variant.screenshotMode,
           let pageValue = ProcessInfo.processInfo.environment["SCREENSHOT_PAGE"],
           let page = NavigationPage(snapshotValue: pageValue)
        {
            _pendingScreenshotSelection = State(initialValue: page)
        } else {
            _pendingScreenshotSelection = State(initialValue: nil)
        }
        _viewModel = StateObject(wrappedValue: MainViewModel(selection: initialSelection))
    }

    private func screenshotTargetHeight(baseHeight _: CGFloat, window: NSWindow) -> CGFloat {
        let scale = max(window.backingScaleFactor, 1)
        if let pixelOverride = ProcessInfo.processInfo.environment["SCREENSHOT_WINDOW_PIXEL_HEIGHT"] {
            let trimmed = pixelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if let height = Double(trimmed), height > 0 {
                return CGFloat(height) / scale
            }
        }
        if let override = ProcessInfo.processInfo.environment["SCREENSHOT_WINDOW_HEIGHT"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if let height = Double(trimmed), height > 0 {
                return CGFloat(height)
            }
        }
        return screenshotDefaultPixelHeight / scale
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $viewModel.selection)
                // The sidebar's width comes from the design tokens rather than from a
                // literal here. It used to be `150` while the tokens said `220`, which
                // is how a window ends up with a sidebar narrower than every row it
                // has to draw: the section captions and the two-line remote-control
                // row truncated. A range rather than one number, because a Mac user
                // drags this and a fixed width takes that away.
                .navigationSplitViewColumnWidth(
                    min: HakoTheme.Regular.Sidebar.minimumWidth,
                    ideal: HakoTheme.Regular.Sidebar.idealWidth,
                    max: HakoTheme.Regular.Sidebar.maximumWidth
                )
        } detail: {
            NavigationStack(path: $settingsNavigationPath) {
                // The desktop detail column is centred and inset rather than stretched across the
                // window. The page keeps its own scroll view, form and title; this only supplies
                // the column's geometry, so a page reached from the sidebar looks the same here as
                // it does in the touch client's canvas.
                HakoRegularDetailContainer {
                    viewModel.selection.contentView
                        .navigationTitle(viewModel.selection.title)
                }
            }
            .environment(\.cardConfigurationVersion, cardConfigurationVersion)
            .environment(\.settingsNavigationPath, $settingsNavigationPath)
            // The detail column is bounded rather than pinned. It used to be a flat
            // `650`, so a wide window left the page at 650 points with dead space
            // beside it, and a narrow one squeezed the page below what it can lay out.
            .navigationSplitViewColumnWidth(
                min: HakoTheme.Regular.Detail.minimumContentWidth,
                ideal: 720
            )
        }
        .frame(
            minWidth: Variant.screenshotMode ? 0 : HakoTheme.MacOS.minimumWindowWidth,
            minHeight: Variant.screenshotMode ? 0 : HakoTheme.MacOS.minimumWindowHeight
        )
        .background(WindowAccessor { window in
            guard Variant.screenshotMode, !didConfigureScreenshotWindow, let window else { return }
            didConfigureScreenshotWindow = true
            DispatchQueue.main.async {
                window.hasShadow = true
                let baseSize = window.contentLayoutRect.size
                let targetHeight = screenshotTargetHeight(baseHeight: baseSize.height, window: window)
                let targetSize = NSSize(width: baseSize.width, height: targetHeight)
                guard targetSize.width > 0, targetSize.height > 0 else { return }
                window.contentMinSize = targetSize
                window.contentMaxSize = targetSize
                window.minSize = targetSize
                window.maxSize = targetSize
                window.setContentSize(targetSize)
                if let pending = pendingScreenshotSelection, pending != viewModel.selection {
                    viewModel.selection = pending
                    pendingScreenshotSelection = nil
                }
            }
        })
        .onAppear {
            // The anchor line: one per launch, before any interaction. It is what makes an empty
            // trace readable as "nothing happened yet" rather than "the instrument is not running",
            // and what proves the log level and subsystem reach an operator's terminal.
            HakoUITrace.event(
                "root-appear selection=\(String(viewModel.selection.rawValue)) remote=\(environments.remoteServer != nil)",
                source: "MacLibrary.MainView.onAppear"
            )
            viewModel.onAppear(environments: environments)
            Task { await reloadRemoteServers() }
        }
        .alert($viewModel.alert)
        .globalChecks()
        .toolbar {
            if environments.remoteServer != nil || !remoteServers.isEmpty {
                ToolbarItem(placement: .navigation) {
                    remoteControlPicker
                }
            }
            if environments.remoteServer != nil {
                ToolbarItem(placement: .navigation) {
                    disconnectButton
                }
            } else {
                ToolbarItem(placement: .navigation) {
                    StartStopButton()
                }
            }
            if viewModel.selection == .dashboard {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showCardManagement = true
                    } label: {
                        Label("Dashboard Items", systemImage: "square.grid.2x2")
                    }
                }
            }
        }
        .onChangeCompat(of: controlActiveState) { newValue in
            Task { @MainActor in
                viewModel.onControlActiveStateChange(newValue, environments: environments)
            }
        }
        .onChangeCompat(of: viewModel.selection) { value in
            Task { @MainActor in
                viewModel.onSelectionChange(value, environments: environments)
                if value != .settings {
                    HakoUITrace.transition(
                        "selection",
                        from: settingsNavigationPath.isEmpty ? "none" : "settings-path",
                        to: String(value.rawValue),
                        source: "MacLibrary.MainView.onChange(selection).leaveSettings"
                    )
                    settingsNavigationPath = NavigationPath()
                    pendingSettingsPage = nil
                    return
                }
                if let page = pendingSettingsPage {
                    // The page was requested before Settings was on screen. Pushing it here, once the
                    // selection has settled, is what makes the request deterministic: the path is
                    // rebuilt from the request rather than the request waiting for a mounted page.
                    HakoUITrace.event(
                        "settings-apply \(page) push=true source=pendingSettingsPage",
                        source: "MacLibrary.MainView.onChange(selection)"
                    )
                    settingsNavigationPath = NavigationPath()
                    settingsNavigationPath.append(page)
                    pendingSettingsPage = nil
                }
            }
        }
        .onReceive(environments.openSettings) {
            Task { @MainActor in viewModel.openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettingsPage)) { notification in
            guard let page = notification.object as? SettingsPage else { return }
            HakoUITrace.event(
                "settings-requested \(page)",
                source: "MacLibrary.MainView.onReceive(navigateToSettingsPage)"
            )
            Task { @MainActor in
                pendingSettingsPage = page
                if viewModel.selection == .settings {
                    // Already open: satisfy the request in place, and never stack a second copy.
                    let alreadyThere = !settingsNavigationPath.isEmpty
                    HakoUITrace.event(
                        "settings-apply \(page) push=\(!alreadyThere) alreadyOpen=true",
                        source: "MacLibrary.MainView.onReceive(navigateToSettingsPage)"
                    )
                    settingsNavigationPath = NavigationPath()
                    if !alreadyThere {
                        settingsNavigationPath.append(page)
                    }
                    pendingSettingsPage = nil
                } else {
                    viewModel.selection = .settings
                }
            }
        }
        .environment(\.selection, $viewModel.selection)
        .environment(\.importProfile, $viewModel.importProfile)
        .environment(\.importRemoteProfile, $viewModel.importRemoteProfile)
        .environment(\.profileEditor, profileEditor)
        .environment(\.ghosttyConfigEditor, ghosttyConfigEditor)
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .onOpenURL { url in
            viewModel.openURL(url, environments: environments)
        }
        .sheet(isPresented: $showCardManagement, onDismiss: {
            cardConfigurationVersion += 1
        }, content: {
            CardManagementSheet()
                .frame(minWidth: 400, minHeight: 400)
                .hakoTracePresentation("sheet cardManagement", isPresented: $showCardManagement)
        })
        .onReceive(NotificationCenter.default.publisher(for: .remoteServersUpdated)) { _ in
            Task { @MainActor in
                await reloadRemoteServers()
            }
        }
    }

    private var remoteControlPicker: some View {
        Menu {
            RemoteControlMenuItems(servers: remoteServers)
        } label: {
            Text(environments.remoteServer?.displayName ?? String(localized: "Local Device"))
        }
    }

    private var disconnectButton: some View {
        Button {
            environments.exitRemoteControl()
        } label: {
            HStack(spacing: 8) {
                RemoteUptimeText(commandClient: environments.commandClient)
                Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        }
        .labelStyle(.iconOnly)
    }

    private func reloadRemoteServers() async {
        remoteServers = await (try? RemoteServerManager.list()) ?? []
    }
}
