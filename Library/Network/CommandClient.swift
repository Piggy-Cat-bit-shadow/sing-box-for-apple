import Combine
import Foundation
import Libbox
import os
#if canImport(UIKit)
    import UIKit
#endif

private let logger = Logger(category: "CommandClient")

public enum LogLevel: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case error = 2
    case warn = 3
    case info = 4
    case debug = 5
    case trace = 6

    public var name: String {
        switch self {
        case .error:
            return "Error"
        case .warn:
            return "Warn"
        case .info:
            return "Info"
        case .debug:
            return "Debug"
        case .trace:
            return "Trace"
        }
    }
}

public struct TrafficSnapshot {
    public var status: LibboxStatusMessage?
    public var uplinkHistory: [CGFloat]
    public var downlinkHistory: [CGFloat]

    public init(
        status: LibboxStatusMessage? = nil,
        uplinkHistory: [CGFloat] = Array(repeating: 0, count: 30),
        downlinkHistory: [CGFloat] = Array(repeating: 0, count: 30)
    ) {
        self.status = status
        self.uplinkHistory = uplinkHistory
        self.downlinkHistory = downlinkHistory
    }
}

public class CommandClient: ObservableObject {
    public enum ConnectionType {
        case status
        case groups
        case log
        case clashMode
        case connections
        case outbounds
    }

    private let connectionTypes: [ConnectionType]
    private let localOnly: Bool
    private var commandClient: LibboxCommandClient?
    private var connectTask: Task<Void, Never>?
    private var activeConnectionToken: UInt64 = 0
    private var isConnecting = false
    /// The subscription's lifecycle: whether one is wanted, whether it is parked for the
    /// background, and whether a loss has already been recovered from.
    ///
    /// All three decisions live in `CommandSubscriptionRecovery`, which is Foundation-only on
    /// purpose so that the tests compile the file that ships rather than a re-implementation of it.
    private var recovery = CommandSubscriptionRecovery()
    private var cancellables = Set<AnyCancellable>()
    @Published public var isConnected: Bool
    @Published public private(set) var isReconnecting = false
    @Published public private(set) var startedAt: Date?
    @Published public var lastError: String?
    // Coalesce traffic updates so SwiftUI re-renders once per status tick.
    @Published private var trafficSnapshot = TrafficSnapshot()
    public var status: LibboxStatusMessage? {
        trafficSnapshot.status
    }

    public var statusPublisher: AnyPublisher<LibboxStatusMessage?, Never> {
        $trafficSnapshot
            .map(\.status)
            .eraseToAnyPublisher()
    }

    @Published public var groups: [OutboundGroup]?
    @Published public var outbounds: [LibboxOutboundGroupItem]?
    /// The log window, as its own observable object.
    ///
    /// It is deliberately *not* a `@Published` property of this client. Every view reading the
    /// client through `@EnvironmentObject` is invalidated by any of its published properties
    /// changing, and the log window changes on a hundred-millisecond batch window - so it used to
    /// invalidate the dashboard's cards, and the two `Canvas` charts among them, at up to ten
    /// hertz for log lines none of them display. `LogStore` is the boundary: only the Logs page
    /// observes it. See `LogStore` and `LogHistory`.
    public let logStore: LogStore
    @Published public var defaultLogLevel = 0
    @Published public var selectedLogLevel: Int?
    @Published public var clashModeList: [String]
    @Published public var clashMode: String

    @Published public var connectionStateFilter = ConnectionStateFilter.active
    @Published public var connectionSort = ConnectionSort.byDate
    @Published public var connections: [LibboxConnection]?
    @Published public var hasAnyConnection: Bool = false
    private var connectionsStore: LibboxConnections?

    public var uplinkHistory: [CGFloat] {
        trafficSnapshot.uplinkHistory
    }

    public var downlinkHistory: [CGFloat] {
        trafficSnapshot.downlinkHistory
    }

    public init(_ connectionTypes: [ConnectionType], logMaxLines: Int = 3000, localOnly: Bool = false) {
        self.connectionTypes = connectionTypes
        self.localOnly = localOnly
        logStore = LogStore(maxLines: logMaxLines)
        clashModeList = []
        clashMode = ""
        isConnected = false
        #if canImport(UIKit)
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { [weak self] _ in
                    self?.suspend()
                }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                .sink { [weak self] _ in
                    self?.resume()
                }
                .store(in: &cancellables)
        #endif
    }

    public convenience init(_ connectionType: ConnectionType, logMaxLines: Int = 300, localOnly: Bool = false) {
        self.init([connectionType], logMaxLines: logMaxLines, localOnly: localOnly)
    }

    public func setupMockData() {
        isConnected = true
        // The three modes are Clash's, and sing-box has no built-in outbound mode - the core
        // derives the list from `clash_mode` actions in the reader's own rules, so a normal
        // configuration has none. They are installed only when the fixture is not being asked for
        // a configuration without them: `test14bOutboundModeWhenTheConfigurationDefinesIt` needs
        // them present and `test14OutboundModeIsAbsentByDefault` needs them absent, from the same
        // launch. Absent means an empty list rather than a sentinel, which is what a real
        // configuration with no `clash_mode` action reports.
        if Variant.uiTestFixtureState != "noClashModes" {
            clashModeList = ["rule", "global", "direct"]
            clashMode = "rule"
        }
        trafficSnapshot = TrafficSnapshot(
            uplinkHistory: Array(repeating: CGFloat(1000), count: 30),
            downlinkHistory: Array(repeating: CGFloat(5000), count: 30)
        )
        // The groups the fixture shows, published here so that every view counting them counts the
        // same ones. Home reads this property; the proxy sheet seeds its own view model from the
        // same call. Before this, only the sheet had them, so under the fixture it reported two
        // groups while Home - reading a property nothing ever wrote - reported none.
        groups = ScreenshotFixtureGroups.make()
        hasAnyConnection = true
    }

    public func connect() {
        guard recovery.acceptsConnect(isConnected: isConnected, isConnecting: isConnecting) else {
            return
        }
        startConnection()
    }

    private func startConnection() {
        if let commandClient {
            try? commandClient.disconnect()
            self.commandClient = nil
        }
        recovery.connectionRequested()
        isConnecting = true
        activeConnectionToken &+= 1
        let token = activeConnectionToken
        connectTask = Task { [weak self] in
            await self?.performConnection(token: token)
        }
    }

    public func disconnect() {
        // A teardown this object asked for: no loss to recover from, and the next explicit
        // `connect()` starts from a clean slate.
        recovery.teardownRequested()
        isReconnecting = false
        closeConnection()
        if isConnected {
            isConnected = false
        }
        startedAt = nil
    }

    /// Re-establish the subscription after a connection that was live ended on its own.
    ///
    /// This is the one case the foreground ensure cannot see. `scenePhase` becoming active calls
    /// `ExtensionEnvironments.connect()`, which only connects when `!isConnected` - and at that
    /// instant the loss has usually not been observed yet, so `isConnected` is still `true` and
    /// that call returns without doing anything. The observation then arrives here, a moment
    /// later, and nothing else is watching for it: without this, the status stream stays dead and
    /// every card that reads `status` stops updating until the app is relaunched.
    ///
    /// The decision itself - whether a subscription is still wanted, whether the connection is
    /// parked, and whether this loss has already been recovered from - is
    /// `CommandSubscriptionRecovery.recoverIfNeeded(wasLive:)`, which is where the bound to one
    /// attempt per loss lives.
    ///
    /// It goes through `connect()`, which is already the idempotent entry point - it refuses while
    /// connected, connecting or suspended, and `startConnection()` bumps the generation token so
    /// the previous stream can no longer publish. So this adds no second owner of the subscription
    /// and cannot produce a duplicate one.
    private func recoverFromUnexpectedLoss(wasLive: Bool) {
        guard recovery.recoverIfNeeded(wasLive: wasLive) else {
            return
        }
        connect()
    }

    private func closeConnection() {
        if let connectTask {
            connectTask.cancel()
            self.connectTask = nil
        }
        isConnecting = false
        activeConnectionToken &+= 1
        if let commandClient {
            try? commandClient.disconnect()
            self.commandClient = nil
        }
    }

    private func suspend() {
        guard !localOnly, CommandTarget.isRemote, isConnected || isConnecting else {
            return
        }
        closeConnection()
        recovery.suspend()
    }

    private func resume() {
        guard recovery.isSuspended else {
            return
        }
        recovery.resume()
        isReconnecting = true
        startConnection()
    }

    public func loadStartedAt() {
        guard isConnected, startedAt == nil else { return }
        let token = activeConnectionToken
        Task.detached { [weak self] in
            guard let client = try? CommandTarget.standaloneClient() else { return }
            var value: Int64 = 0
            try? client.getStartedAt(&value)
            guard value > 0 else { return }
            let date = Date(timeIntervalSince1970: Double(value) / 1000)
            await MainActor.run {
                guard let self, self.activeConnectionToken == token, self.isConnected else { return }
                self.startedAt = date
            }
        }
    }

    /// Empties the log window at the reader's or the core's request.
    ///
    /// Kept on the client because the core asks for it here, but the state itself belongs to
    /// `logStore` - this client no longer publishes log lines.
    public func clearLogs() {
        logStore.clear()
    }

    public func filterConnectionsNow() {
        guard let store = connectionsStore else {
            return
        }
        let result = filterConnections(store)
        connections = result.connections
        hasAnyConnection = result.hasAny
    }

    private func filterConnections(_ message: LibboxConnections) -> (connections: [LibboxConnection], hasAny: Bool) {
        let hasAny = message.iterator()?.hasNext() ?? false
        message.filterState(Int32(connectionStateFilter.rawValue))
        switch connectionSort {
        case .byDate:
            message.sortByDate()
        case .byTraffic:
            message.sortByTraffic()
        case .byTrafficTotal:
            message.sortByTrafficTotal()
        }
        let connectionIterator = message.iterator()!
        var connections: [LibboxConnection] = []
        while connectionIterator.hasNext() {
            connections.append(connectionIterator.next()!)
        }
        return (connections: connections, hasAny: hasAny)
    }

    private func initializeConnectionFilterState() async {
        let newFilter: ConnectionStateFilter = await .init(rawValue: SharedPreferences.connectionStateFilter.get()) ?? .active
        let newSort: ConnectionSort = await .init(rawValue: SharedPreferences.connectionSort.get()) ?? .byDate
        await MainActor.run {
            connectionStateFilter = newFilter
            connectionSort = newSort
        }
    }

    private nonisolated func performConnection(token: UInt64) async {
        if connectionTypes.contains(.connections) {
            await initializeConnectionFilterState()
        }

        let clientOptions = LibboxCommandClientOptions()
        for connectionType in connectionTypes {
            switch connectionType {
            case .status:
                clientOptions.addCommand(LibboxCommandStatus)
            case .groups:
                clientOptions.addCommand(LibboxCommandGroup)
            case .log:
                clientOptions.addCommand(LibboxCommandLog)
            case .clashMode:
                clientOptions.addCommand(LibboxCommandClashMode)
            case .connections:
                clientOptions.addCommand(LibboxCommandConnections)
            case .outbounds:
                clientOptions.addCommand(LibboxCommandOutbounds)
            }
        }
        clientOptions.statusInterval = Int64(NSEC_PER_SEC)
        let client: LibboxCommandClient
        if !localOnly, let server = CommandTarget.remoteServer {
            var clientError: NSError?
            let remoteClient = LibboxNewRemoteCommandClient(clientHandler(self, connectionToken: token), clientOptions, CommandTarget.libboxOptions(server), &clientError)
            if let clientError {
                await reportConnectError(token: token, error: clientError)
                await finishConnectionAttempt(token: token, client: nil)
                return
            }
            client = remoteClient!
        } else {
            client = LibboxNewCommandClient(clientHandler(self, connectionToken: token), clientOptions)!
        }
        do {
            try client.connect()
        } catch {
            await reportConnectError(token: token, error: error)
            await finishConnectionAttempt(token: token, client: nil)
            return
        }
        await finishConnectionAttempt(token: token, client: client)
    }

    private func reportConnectError(token: UInt64, error: Error) async {
        await MainActor.run { [self] in
            guard token == activeConnectionToken else { return }
            lastError = error.localizedDescription
            if isConnected {
                isConnected = false
            }
            isReconnecting = false
            startedAt = nil
        }
    }

    private func finishConnectionAttempt(token: UInt64, client: LibboxCommandClient?) async {
        await MainActor.run { [self] in
            guard token == activeConnectionToken else {
                if let client {
                    try? client.disconnect()
                }
                return
            }
            isConnecting = false
            connectTask = nil
            if let client {
                commandClient = client
            }
        }
    }

    private class clientHandler: NSObject, LibboxCommandClientHandlerProtocol {
        private let commandClient: CommandClient
        private let connectionToken: UInt64
        private var lastGroups: [OutboundGroup]?

        init(_ commandClient: CommandClient, connectionToken: UInt64) {
            self.commandClient = commandClient
            self.connectionToken = connectionToken
        }

        private func isActiveConnection() -> Bool {
            commandClient.activeConnectionToken == connectionToken
        }

        func connected() {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if commandClient.connectionTypes.contains(.log) {
                    commandClient.logStore.resetForNewConnection()
                }
                commandClient.lastError = nil
                commandClient.isConnected = true
                commandClient.isReconnecting = false
                // A connection that actually came up re-arms the recovery, so a later loss can be
                // recovered from in its turn. This is what keeps the bound to "one attempt per
                // loss" rather than "one attempt per process".
                commandClient.recovery.connectionEstablished()
                if commandClient.startedAt != nil {
                    commandClient.startedAt = nil
                    commandClient.loadStartedAt()
                }
            }
        }

        func disconnected(_ message: String?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if let message {
                    commandClient.lastError = message
                }
                // Whether this was a live subscription ending, as opposed to an attempt that never
                // established one. Only the former is a loss the user can see as "the cards
                // stopped"; the latter already reports through `lastError`.
                let wasLive = commandClient.isConnected
                commandClient.isConnected = false
                commandClient.isReconnecting = false
                commandClient.startedAt = nil
                if wasLive {
                    commandClient.recoverFromUnexpectedLoss(wasLive: wasLive)
                }
            }
            if let message {
                logger.debug("client disconnected: \(message)")
            }
        }

        func setDefaultLogLevel(_ level: Int32) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.defaultLogLevel = Int(level)
            }
        }

        func clearLogs() {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.clearLogs()
            }
        }

        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
            guard let messageList else {
                return
            }
            guard isActiveConnection() else { return }

            // Collect new logs
            var newLogs: [LogEntry] = []
            while messageList.hasNext() {
                let logEntry = messageList.next()!
                newLogs.append(LogEntry(level: Int(logEntry.level), message: logEntry.message))
            }

            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                // The store owns the window, the drop count and the batch window; this callback's
                // job is only to hand it the batch from the connection that is still current.
                commandClient.logStore.reportInitialBacklogReceived()
                guard !newLogs.isEmpty else { return }
                commandClient.logStore.append(newLogs)
            }
        }

        func writeStatus(_ message: LibboxStatusMessage?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                var snapshot = commandClient.trafficSnapshot
                snapshot.status = message
                if let message, message.trafficAvailable {
                    snapshot.uplinkHistory.removeFirst()
                    snapshot.uplinkHistory.append(CGFloat(message.uplink))

                    snapshot.downlinkHistory.removeFirst()
                    snapshot.downlinkHistory.append(CGFloat(message.downlink))
                }
                commandClient.trafficSnapshot = snapshot
            }
        }

        func writeGroups(_ groups: LibboxOutboundGroupIteratorProtocol?) {
            guard let groups else {
                return
            }
            guard isActiveConnection() else { return }
            var newGroups: [OutboundGroup] = []
            while groups.hasNext() {
                newGroups.append(OutboundGroup(groups.next()!))
            }
            if newGroups == lastGroups {
                return
            }
            lastGroups = newGroups
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.groups = newGroups
            }
        }

        func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {
            guard let message else { return }
            guard isActiveConnection() else { return }
            var newOutbounds: [LibboxOutboundGroupItem] = []
            while message.hasNext() {
                newOutbounds.append(message.next()!)
            }
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.outbounds = newOutbounds
            }
        }

        func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.clashModeList = modeList!.toArray()
                commandClient.clashMode = currentMode!
            }
        }

        func updateClashMode(_ newMode: String?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.clashMode = newMode!
            }
        }

        func write(_ events: LibboxConnectionEvents?) {
            guard let events else {
                return
            }
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if commandClient.connectionsStore == nil {
                    commandClient.connectionsStore = LibboxNewConnections()
                }
                commandClient.connectionsStore?.apply(events)
                let result = commandClient.filterConnections(commandClient.connectionsStore!)
                commandClient.connections = result.connections
                commandClient.hasAnyConnection = result.hasAny
            }
        }
    }
}

public enum ConnectionStateFilter: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case all
    case active
    case closed
}

public extension ConnectionStateFilter {
    var name: String {
        switch self {
        case .all:
            return NSLocalizedString("All", comment: "")
        case .active:
            return NSLocalizedString("Active", comment: "")
        case .closed:
            return NSLocalizedString("Closed", comment: "")
        }
    }
}

public enum ConnectionSort: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case byDate
    case byTraffic
    case byTrafficTotal
}

public extension ConnectionSort {
    var name: String {
        switch self {
        case .byDate:
            return NSLocalizedString("Date", comment: "")
        case .byTraffic:
            return NSLocalizedString("Traffic", comment: "")
        case .byTrafficTotal:
            return NSLocalizedString("Traffic Total", comment: "")
        }
    }
}
