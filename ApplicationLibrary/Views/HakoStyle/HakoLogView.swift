//
//  HakoLogView.swift
//  ApplicationLibrary
//
//  The phone's Logs page, from `hako-ui` @ `c1935cf`.
//
//  # Why this is a copy rather than a wrapper
//
//  The reference's change is a rewrite of the page rather than a decoration of it: `LogView.swift`
//  is 621 lines upstream and 654 in the reference, and the reference version is the
//  page. A wrapper would have had to reimplement it anyway.
//
//  So the page lives here, in the fork's own namespace, reachable only from the phone. Upstream's
//  `ApplicationLibrary/Views/Log/LogView.swift` stays upstream's, which is
//  what keeps an iPad and a Mac on upstream's presentation.
//
//  # What is deliberately not here
//
//  The pages this one leads to. Every one of them is still upstream's: the reference's change to each
//  is a single modifier or a single row, and the page a user lands on is what this slice delivers.
//  The list, with what each needs, is in `docs/HAKO-LOSSLESS-PARITY-AUDIT.md`.
//
//  Generated from `c1935cf` by `scripts/dev/port_tools_and_more.py`. That script resolves the
//  reference's platform conditionals for iPhone and drops the declarations the shared tree already
//  owns; re-run it rather than editing here, or the next run will disagree with this file.
//

import Library
import SwiftUI

    import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#endif


public struct HakoLogView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments

    public init() {}

    public var body: some View {
        HakoLogViewContent(commandClient: environments.commandClient, initialSearchText: environments.logSearchText)
            // Logs is pushed inside the Tools tab, so it wears the detail chrome: a
            // circular back control, an inline centred title, and no root tab bar. It
            // previously had none of the three, which is how it ended up with the
            // platform's chevron while every page that adopted the design system had a
            // disc.
            .hakoNavigationChrome(title: String(localized: "Logs"))
    }
}

private struct HakoLogViewContent: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel: LogViewModel

        @State private var remoteServers: [RemoteServer] = []


    init(commandClient: CommandClient, initialSearchText: String = "") {
        _viewModel = StateObject(wrappedValue: LogViewModel(commandClient: commandClient, searchText: initialSearchText))
    }

    var body: some View {


            contentWithToolbar
                .onDisappear {
                    environments.logSearchText = viewModel.searchText
                }
                .alert($viewModel.alert)
                .background(
                    HakoLogExportView(
                        dataModel: viewModel.dataModel,
                        alert: $viewModel.alert
                    )
                )

                .onAppear {
                    Task { await reloadRemoteServers() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .remoteServersUpdated)) { _ in
                    Task { await reloadRemoteServers() }
                }


    }


        private var searchableContent: some View {
            HakoLogContentInnerView(dataModel: viewModel.dataModel, viewModel: viewModel)
                .applySearchable(text: $viewModel.searchText, isSearching: $viewModel.isSearching, shouldShow: viewModel.isSearching)
        }

        /// The iOS 15 fallback must be excluded from macOS builds entirely: with
        /// `if #available(iOS 16.0, *)` the else branch is compile-time dead on macOS,
        /// where the compiler permits unavailable declarations, so the Xcode 27 SDK
        /// resolved the HStack's ViewBuilder.buildBlock to the macOS 26-only
        /// `TupleContent` overload. That type still lands in this view's `Body`
        /// associated type witness, and demangling it aborts on macOS < 26
        /// (TestFlight crash in swift_getAssociatedTypeWitness).
        @ViewBuilder
        private var contentWithToolbar: some View {

                if #available(iOS 16.0, *) {
                    groupedToolbarContent
                } else {
                    // iOS 15 renders only one trailing toolbar entry; group all buttons into a single item
                    searchableContent.toolbar {
                        ToolbarItem {
                            HStack {
                                toolbarButtons
                                logMenu
                            }
                        }
                    }
                }


        }

        private var groupedToolbarContent: some View {
            searchableContent.toolbar {
                ToolbarItemGroup {
                    toolbarButtons
                    logMenu
                }
            }
        }

        @ViewBuilder
        private var toolbarButtons: some View {
            if #available(iOS 17.0, macOS 14.0, *) {
                Button(action: viewModel.toggleSearch) {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            Button(action: viewModel.togglePause) {
                Label(
                    viewModel.isPaused ? NSLocalizedString("Resume", comment: "Resume log auto-scroll") : NSLocalizedString("Pause", comment: "Pause log auto-scroll"),
                    systemImage: viewModel.isPaused ? "play.circle" : "pause.circle"
                )
            }
        }

        private var logMenu: AnyView {

                if #available(iOS 16.0, *) {
                    return AnyView(HakoLogMenuButton(
                        viewModel: viewModel,
                        remoteServers: remoteServers,
                        activeRemoteServerID: environments.remoteServer?.id,
                        onSelectLocalDevice: { environments.exitRemoteControl() },
                        onSelectRemoteServer: { server in
                            guard environments.remoteServer?.id != server.id else { return }
                            environments.enterRemoteControl(server)
                        }
                    ))
                } else {
                    // UIViewRepresentable views collapse to zero size in iOS 15 toolbars
                    return AnyView(HakoLogMenuView(viewModel: viewModel, remoteServers: remoteServers))
                }


        }


            private func reloadRemoteServers() async {
                remoteServers = await (try? RemoteServerManager.list()) ?? []
            }


}


        private struct HakoLogMenuButton: UIViewRepresentable {
            let viewModel: LogViewModel
            let remoteServers: [RemoteServer]
            let activeRemoteServerID: Int64?
            let onSelectLocalDevice: () -> Void
            let onSelectRemoteServer: (RemoteServer) -> Void
            @Environment(\.colorScheme) private var colorScheme

            func makeUIView(context _: Context) -> UIButton {
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
                return button
            }

            func updateUIView(_ uiView: UIButton, context _: Context) {
                uiView.menu = createMenu()
                if #available(iOS 17.0, *) {
                    uiView.tintColor = colorScheme == .dark ? .white : .black
                }
            }

            private func createMenu() -> UIMenu {
                let logLevelActions = [
                    UIAction(
                        title: NSLocalizedString("Default", comment: "Log level filter default option"),
                        state: viewModel.selectedLogLevel == nil ? .on : .off
                    ) { _ in
                        viewModel.selectedLogLevel = nil
                    },
                ] + LogLevel.allCases.map { level in
                    UIAction(
                        title: level.name,
                        state: viewModel.selectedLogLevel == level.rawValue ? .on : .off
                    ) { _ in
                        viewModel.selectedLogLevel = level.rawValue
                    }
                }

                let logLevelMenu = UIMenu(
                    title: NSLocalizedString("Log Level", comment: ""),
                    image: UIImage(systemName: "slider.horizontal.3"),
                    children: logLevelActions
                )

                let saveActions = [
                    UIAction(
                        title: NSLocalizedString("To Clipboard", comment: ""),
                        image: UIImage(systemName: "doc.on.clipboard")
                    ) { _ in
                        viewModel.dataModel.copyToClipboard()
                    },
                    UIAction(
                        title: NSLocalizedString("To File", comment: ""),
                        image: UIImage(systemName: "arrow.down.doc")
                    ) { _ in
                        viewModel.dataModel.prepareLogFile()
                        viewModel.dataModel.showFileExporter = true
                    },
                    UIAction(
                        title: NSLocalizedString("Share", comment: ""),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { _ in
                        viewModel.dataModel.prepareLogFile()
                    },
                ]

                let saveMenu = UIMenu(
                    title: NSLocalizedString("Save", comment: ""),
                    image: UIImage(systemName: "square.and.arrow.down"),
                    children: saveActions
                )

                let clearAction = UIAction(
                    title: NSLocalizedString("Clear Logs", comment: "Clear all logs"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    viewModel.dataModel.clearLogs()
                }

                var children: [UIMenuElement] = [logLevelMenu, saveMenu, clearAction]

                if !remoteServers.isEmpty {
                    let remoteControlActions = [
                        UIAction(
                            title: NSLocalizedString("Local Device", comment: ""),
                            state: activeRemoteServerID == nil ? .on : .off
                        ) { _ in
                            onSelectLocalDevice()
                        },
                    ] + remoteServers.map { server in
                        UIAction(
                            title: server.displayName,
                            state: server.id == activeRemoteServerID ? .on : .off
                        ) { _ in
                            onSelectRemoteServer(server)
                        }
                    }

                    children.append(UIMenu(
                        title: NSLocalizedString("Remote Control", comment: ""),
                        options: .displayInline,
                        children: remoteControlActions
                    ))
                }

                return UIMenu(children: children)
            }
        }


    private struct HakoLogMenuView: View {
        let viewModel: LogViewModel
        var remoteServers: [RemoteServer] = []

        var body: some View {
            Menu {
                if #unavailable(iOS 16.0) {
                    // iOS 15 renders a bare Picker inline; wrap it to match the iOS 16+ submenu
                    Menu {
                        logLevelPicker
                    } label: {
                        Label("Log Level", systemImage: "slider.horizontal.3")
                    }
                } else {
                    logLevelPicker
                }
                Menu {
                    Button {
                        viewModel.dataModel.copyToClipboard()
                    } label: {
                        Label("To Clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        viewModel.dataModel.prepareLogFile()
                        viewModel.dataModel.showFileExporter = true
                    } label: {
                        Label("To File", systemImage: "arrow.down.doc")
                    }
                    Button {
                        viewModel.dataModel.prepareLogFile()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    viewModel.dataModel.clearLogs()
                } label: {
                    Label(NSLocalizedString("Clear Logs", comment: "Clear all logs"), systemImage: "trash")
                }
                RemoteControlMenuItems(servers: remoteServers)
            } label: {
                Label("Others", systemImage: "line.3.horizontal.circle")
            }
        }

        private var logLevelPicker: some View {
            Picker(selection: Binding(
                get: { viewModel.selectedLogLevel },
                set: { viewModel.selectedLogLevel = $0 }
            )) {
                Text(NSLocalizedString("Default", comment: "Log level filter default option")).tag(Int?.none)
                ForEach(LogLevel.allCases) { level in
                    Text(level.name).tag(Int?.some(level.rawValue))
                }
            } label: {
                Label("Log Level", systemImage: "slider.horizontal.3")
            }
        }
    }


private struct HakoLogContentInnerView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @ObservedObject var dataModel: LogDataModel
    @ObservedObject var viewModel: LogViewModel
    @Environment(\.colorScheme) private var colorScheme
    private let logFont = Font.system(.caption2, design: .monospaced)

    var body: some View {
        content
            .background(HakoProductPalette.system.canvas)
    }

    @ViewBuilder
    private var content: some View {
        if Variant.screenshotMode {
            previewContent
        } else if dataModel.isEmpty {
            emptyContent
        } else if dataModel.visibleLogs.isEmpty {
            emptyContent
        } else {
            logScrollView
        }
    }

    private var previewContent: some View {
        let logList = [
            "(packet-tunnel) log server started",
            "INFO[0000] router: updated default interface en0, index 11",
            "inbound/tun[0]: started at utun3",
            "sing-box started (1.666s)",
        ]


            let previewLogs = logList.map { message in
                LogEntry(level: 4, message: message)
            }
            return LogTextView(
                logs: previewLogs,
                font: logFont,
                shouldAutoScroll: false,
                searchText: ""
            )

    }

    /// What the page says when there is nothing to show.
    ///
    /// The four states stay distinct - no logs yet, logs arrived but none match, connecting to a
    /// remote, and a service that is not running - because they need different things from the
    /// user. The two that are not connected keep connecting the service when they appear, which is
    /// the behaviour they had before; only their presentation changed.
    private var emptyContent: some View {
        Group {
            if dataModel.isConnected {
                if dataModel.initialLogsReceived {
                    HakoEmptyState(
                        symbol: "text.alignleft",
                        title: "Empty logs",
                        message: "Logs will appear here as the service writes them."
                    )
                } else {
                    HakoEmptyState(symbol: "ellipsis", title: "Loading...", isBusy: true)
                }
            } else if environments.remoteServer != nil {
                HakoEmptyState(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: "Connecting..."
                )
                .onAppear {
                    environments.connect()
                }
            } else {
                HakoEmptyState(
                    symbol: "bolt.slash",
                    title: "Service not started",
                    message: "Start sing-box to see its logs."
                )
                .onAppear {
                    environments.connect()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logScrollView: some View {


            // The log surface. Not a row per line - the text view is what makes a long log
            // cheap to scroll and cheap to select - but the surface it sits on is the client's,
            // so a log page is a page with a log on it rather than text floating in the canvas.
            HakoCardSurface(
                fill: HakoProductPalette.system.card,
                separator: HakoProductPalette.system.separator,
                cornerRadius: HakoTheme.Radius.groupedSection
            ) {
                LogTextView(
                    logs: dataModel.visibleLogs,
                    font: logFont,
                    shouldAutoScroll: !viewModel.isPaused,
                    searchText: viewModel.searchText
                )
            }
            .padding(.horizontal, HakoTheme.Layout.cardHorizontalInset)
            .padding(.vertical, HakoTheme.Spacing.cardGap)

    }


}


    private extension View {
        func applySearchable(text: Binding<String>, isSearching: Binding<Bool>, shouldShow: Bool) -> some View {
            if #available(iOS 17.0, macOS 14.0, *) {
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

    /// Observes the data model directly: presentation state (`showFileExporter`,
    /// `logFileURL`) lives on `LogDataModel`, which the surrounding view does not
    /// observe, so closure-based bindings would only pick up changes on the next
    /// unrelated re-render — leaving the exporter/share sheet stuck until then.
    private struct HakoLogExportView: View {
        @ObservedObject var dataModel: LogDataModel
        @Binding var alert: AlertState?
        @State private var showShareSheet = false

        var body: some View {
            Color.clear
                .fileExporter(
                    isPresented: $dataModel.showFileExporter,
                    document: dataModel.logFileURL.map { HakoLogTextDocument(url: $0) },
                    contentType: .plainText,
                    defaultFilename: "logs.txt"
                ) { result in
                    dataModel.cleanupLogFile()
                    dataModel.logFileURL = nil
                    if case let .failure(error) = result {
                        alert = AlertState(action: "export log file", error: error)
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    if let url = dataModel.logFileURL {

                            HakoShareViewController(activityItems: [url])


                    }
                }
                .onChange(of: dataModel.logFileURL) { newValue in
                    if newValue != nil, !dataModel.showFileExporter {
                        showShareSheet = true
                    }
                }
                .onChange(of: showShareSheet) { newValue in
                    if !newValue {
                        dataModel.cleanupLogFile()
                        dataModel.logFileURL = nil
                    }
                }
        }
    }

    private struct HakoLogTextDocument: FileDocument {
        static var readableContentTypes: [UTType] {
            [.plainText]
        }

        private let url: URL

        init(url: URL) {
            self.url = url
        }

        init(configuration: ReadConfiguration) throws {
            guard let data = configuration.file.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: tempURL)
            url = tempURL
        }

        func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
            try FileWrapper(url: url)
        }
    }


        private struct HakoShareViewController: UIViewControllerRepresentable {
            let activityItems: [Any]

            func makeUIViewController(context _: Context) -> UIActivityViewController {
                UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            }

            func updateUIViewController(_: UIActivityViewController, context _: Context) {}
        }

