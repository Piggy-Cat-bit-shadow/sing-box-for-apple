import Combine
import Foundation
import Libbox
import Library
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
public class LogDataModel: ObservableObject {
    @Published public var filteredLogs: [LogEntry] = []
    @Published public private(set) var visibleLogs: [LogEntry] = []
    @Published public private(set) var initialLogsReceived = false
    @Published public var showFileExporter = false
    @Published public var logFileURL: URL?

    private let commandClient: CommandClient
    /// The log window, which is its own observable object - see `LogStore`.
    ///
    /// Its `buffer` is not published: this pipeline is driven by `$revision`, and takes the window
    /// when it fires. That is what lets the store mutate the array in place instead of copying it on
    /// every batch.
    private var logStore: LogStore {
        commandClient.logStore
    }

    private weak var viewModel: LogViewModel?
    private var pausedLogSnapshot: LogBuffer?
    private var lastPaused = false
    private var hasProcessed = false
    private var lastProcessedTotal = 0
    private var lastEffectiveLevel: Int?
    private var lastSearchText = ""
    private var cancellables = Set<AnyCancellable>()
    private var isPreparingLogFile = false

    private static let maxVisibleLogs = 1000
    private static let maxFilteredLogs = 3000
    /// Trimming the head of visibleLogs makes the text view delete from the front of
    /// its storage, which invalidates layout for the whole document. Letting the
    /// window overgrow and trimming in chunks keeps steady-state batches append-only.
    private static let visibleLogsTrimThreshold = 1250

    public var isEmpty: Bool {
        logStore.buffer.entries.isEmpty
    }

    /// Tells the store whether a log page is on screen.
    ///
    /// Called from the page's own lifecycle and from the shell's selection, because the tab shell
    /// keeps a tab's stack alive and a tab switch does not always run `onDisappear`. While no page is
    /// on screen the store stops announcing, and this pipeline - which is the only expensive reader -
    /// stops running.
    public func setPageVisible(_ visible: Bool) {
        logStore.setPageVisible(visible)
    }

    public var isConnected: Bool {
        commandClient.isConnected
    }

    private func rebuildVisibleLogs() {
        if filteredLogs.count <= Self.maxVisibleLogs {
            visibleLogs = filteredLogs
        } else {
            visibleLogs = Array(filteredLogs.suffix(Self.maxVisibleLogs))
        }
    }

    private func appendVisibleLogs(_ newLogs: [LogEntry]) {
        visibleLogs.append(contentsOf: newLogs)
        if visibleLogs.count > Self.visibleLogsTrimThreshold {
            visibleLogs.removeFirst(visibleLogs.count - Self.maxVisibleLogs)
        }
    }

    public init(commandClient: CommandClient, viewModel: LogViewModel) {
        self.commandClient = commandClient
        self.viewModel = viewModel

        let debouncedSearchText = viewModel.$searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)

        Publishers.CombineLatest3(
            Publishers.CombineLatest4(
                logStore.$revision,
                logStore.$defaultLogLevel,
                viewModel.$selectedLogLevel,
                debouncedSearchText
            ),
            viewModel.$isPaused,
            logStore.$initialLogsReceived
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] combined, isPaused, initialLogsReceived in
            guard let self else { return }
            if self.initialLogsReceived != initialLogsReceived {
                self.initialLogsReceived = initialLogsReceived
            }
            let (_, defaultLogLevel, selectedLogLevel, searchText) = combined
            // The window is taken now, not carried by the publisher: the store owns one array and
            // mutates it in place. Holding it here (the pause snapshot) is what makes the next append
            // copy, and nothing else does.
            let logBuffer = self.commandClient.logStore.buffer
            let effectiveLevel = selectedLogLevel ?? defaultLogLevel

            if isPaused, !self.lastPaused {
                self.pausedLogSnapshot = logBuffer
            } else if !isPaused, self.lastPaused {
                self.pausedLogSnapshot = nil
            }
            self.lastPaused = isPaused

            let sourceBuffer = self.pausedLogSnapshot ?? logBuffer
            let filter: (LogEntry) -> Bool = { log in
                log.level <= effectiveLevel &&
                    (searchText.isEmpty || log.message.contains(searchText))
            }

            if self.hasProcessed, effectiveLevel == self.lastEffectiveLevel, searchText == self.lastSearchText {
                let newCount = sourceBuffer.totalCount - self.lastProcessedTotal
                if newCount == 0 {
                    return
                }
                // Tracking the cumulative total keeps appends incremental even after
                // the buffer saturates and starts dropping entries from the front.
                if newCount > 0, newCount <= sourceBuffer.entries.count {
                    self.lastProcessedTotal = sourceBuffer.totalCount
                    let newFilteredLogs = sourceBuffer.entries.suffix(newCount).filter(filter)
                    guard !newFilteredLogs.isEmpty else {
                        return
                    }
                    self.filteredLogs.append(contentsOf: newFilteredLogs)
                    if self.filteredLogs.count > Self.maxFilteredLogs {
                        self.filteredLogs.removeFirst(self.filteredLogs.count - Self.maxFilteredLogs)
                    }
                    self.appendVisibleLogs(newFilteredLogs)
                    return
                }
            }

            self.filteredLogs = sourceBuffer.entries.filter(filter)
            self.rebuildVisibleLogs()
            self.hasProcessed = true
            self.lastProcessedTotal = sourceBuffer.totalCount
            self.lastEffectiveLevel = effectiveLevel
            self.lastSearchText = searchText
        }
        .store(in: &cancellables)
    }

    public func clearLogs() {
        viewModel?.isPaused = false
        pausedLogSnapshot = nil
        lastPaused = false
        hasProcessed = false
        lastProcessedTotal = 0
        lastEffectiveLevel = nil
        lastSearchText = ""
        filteredLogs = []
        visibleLogs = []
        logStore.clear()
        Task.detached {
            try? CommandTarget.standaloneClient().clearLogs()
        }
    }

    public func getLogsText() -> String {
        filteredLogs.map(\.message).joined(separator: "\n")
    }

    #if !os(tvOS)
        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HH:mm:ss"
            return formatter
        }()

        public func copyToClipboard() {
            let text = getLogsText()
            #if os(iOS)
                UIPasteboard.general.string = text
            #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            #endif
        }

        public func cleanupLogFile(_ url: URL?) async {
            guard let url else { return }
            if logFileURL == url {
                logFileURL = nil
            }
            await BlockingIO.run {
                try? FileManager.default.removeItem(at: url)
            }
        }

        public func prepareLogFile(export: Bool = false) async {
            guard !isPreparingLogFile else { return }
            isPreparingLogFile = true
            defer { isPreparingLogFile = false }
            let text = getLogsText()
            await cleanupLogFile(logFileURL)
            let dateString = Self.dateFormatter.string(from: Date())
            let fileURL = FilePath.cacheDirectory.appendingPathComponent("logs-\(dateString)-\(UUID().uuidString).txt")
            do {
                try Task.checkCancellation()
                try await BlockingIO.run {
                    try text.write(to: fileURL, atomically: true, encoding: .utf8)
                }
                try Task.checkCancellation()
                showFileExporter = export
                logFileURL = fileURL
            } catch {
                await cleanupLogFile(fileURL)
                if !Task.isCancelled {
                    viewModel?.alert = AlertState(action: "prepare log file", error: error)
                }
            }
        }
    #endif
}

@MainActor
public class LogViewModel: BaseViewModel {
    @Published public var selectedLogLevel: Int?
    @Published public var isPaused = false
    @Published public var searchText = ""
    @Published public var isSearching = false

    public let commandClient: CommandClient
    public private(set) var dataModel: LogDataModel!

    public init(commandClient: CommandClient, searchText: String = "") {
        self.commandClient = commandClient
        self.searchText = searchText
        isSearching = !searchText.isEmpty
        super.init()
        dataModel = LogDataModel(commandClient: commandClient, viewModel: self)
    }

    public func togglePause() {
        isPaused.toggle()
    }

    public func toggleSearch() {
        isSearching.toggle()
        if !isSearching {
            searchText = ""
        }
    }
}
