import Combine
import Libbox
import Library
import SwiftUI

@MainActor
public class ConnectionDataModel: ObservableObject {
    @Published public private(set) var connections: [Connection] = []
    @Published public private(set) var filteredConnections: [Connection] = []
    @Published public private(set) var isLoading = true

    private let commandClient: CommandClient
    private var searchText: String
    private var cancellables = Set<AnyCancellable>()

    init(commandClient: CommandClient, viewModel: ConnectionListViewModel) {
        self.commandClient = commandClient
        searchText = viewModel.searchText

        viewModel.$connectionStateFilter
            .sink { [weak self] filter in
                guard let self else { return }
                self.commandClient.connectionStateFilter = filter
                self.commandClient.filterConnectionsNow()
            }
            .store(in: &cancellables)

        viewModel.$connectionSort
            .sink { [weak self] sort in
                guard let self else { return }
                self.commandClient.connectionSort = sort
                self.commandClient.filterConnectionsNow()
            }
            .store(in: &cancellables)

        viewModel.$searchText
            .dropFirst()
            .sink { [weak self] searchText in
                guard let self else { return }
                self.searchText = searchText
                self.updateFilteredConnections()
            }
            .store(in: &cancellables)

        commandClient.$connections
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.setConnections(connections)
            }
            .store(in: &cancellables)

        // A page must not spin for something that is not coming.
        //
        // `isLoading` was an unconditional initial `true` that only a delivered connection list could
        // clear. With the tunnel stopped there is no command client and nothing to deliver, so the
        // Activity page showed a spinner for as long as it was open and the empty state that says
        // exactly that was unreachable.
        //
        // Subscribing to a published flag delivers its current value immediately, so this also settles
        // the state on the first run of a launch that never connects. `finishLoading()` is idempotent,
        // so a disconnect after a delivered list is a no-op rather than a regression.
        //
        // The original fork had this and the integration dropped it. It is a behaviour fix rather than
        // a visual one and it is correct on an iPad and a Mac too - the same spinner appears there with
        // the tunnel stopped - so it belongs in the shared view model, unlike the phone's presentation.
        commandClient.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self, !isConnected else { return }
                self.finishLoading()
            }
            .store(in: &cancellables)
    }

    func finishLoading() {
        if isLoading {
            isLoading = false
        }
    }

    private func setConnections(_ goConnections: [LibboxConnection]) {
        connections = convertConnections(goConnections)
        updateFilteredConnections()
        finishLoading()
    }

    private func updateFilteredConnections() {
        if searchText.isEmpty {
            filteredConnections = connections
        } else {
            filteredConnections = connections.filter { $0.performSearch(searchText) }
        }
    }

    private func convertConnections(_ goConnections: [LibboxConnection]) -> [Connection] {
        var connections = [Connection]()
        for goConnection in goConnections {
            if goConnection.outboundType == "dns" {
                continue
            }
            var closedAt: Date?
            if goConnection.closedAt > 0 {
                closedAt = Date(timeIntervalSince1970: Double(goConnection.closedAt) / 1000)
            }
            connections.append(Connection(
                id: goConnection.id_,
                inbound: goConnection.inbound,
                inboundType: goConnection.inboundType,
                ipVersion: goConnection.ipVersion,
                network: goConnection.network,
                source: goConnection.source,
                destination: goConnection.destination,
                domain: goConnection.domain,
                displayDestination: goConnection.displayDestination(),
                protocolName: goConnection.protocol,
                user: goConnection.user,
                fromOutbound: goConnection.fromOutbound,
                createdAt: Date(timeIntervalSince1970: Double(goConnection.createdAt) / 1000),
                closedAt: closedAt,
                upload: goConnection.uplink,
                download: goConnection.downlink,
                uploadTotal: goConnection.uplinkTotal,
                downloadTotal: goConnection.downlinkTotal,
                rule: goConnection.rule,
                outbound: goConnection.outbound,
                outboundType: goConnection.outboundType,
                chain: goConnection.chain()!.toArray()
            ))
        }
        return connections
    }
}

@MainActor
public class ConnectionListViewModel: BaseViewModel {
    @Published public var searchText = ""
    @Published public var isSearching = false

    @Published public var connectionStateFilter: ConnectionStateFilter {
        didSet {
            saveStateFilterTask?.cancel()
            saveStateFilterTask = Task {
                await SharedPreferences.connectionStateFilter.set(connectionStateFilter.rawValue)
            }
        }
    }

    @Published public var connectionSort: ConnectionSort {
        didSet {
            saveSortTask?.cancel()
            saveSortTask = Task {
                await SharedPreferences.connectionSort.set(connectionSort.rawValue)
            }
        }
    }

    public let commandClient = CommandClient([.connections])
    public private(set) var dataModel: ConnectionDataModel!

    private var connectTask: Task<Void, Never>?
    private var saveStateFilterTask: Task<Void, Never>?
    private var saveSortTask: Task<Void, Never>?

    override public init() {
        connectionStateFilter = .active
        connectionSort = .byDate
        super.init()
        dataModel = ConnectionDataModel(commandClient: commandClient, viewModel: self)
    }

    public func toggleSearch() {
        isSearching.toggle()
        if !isSearching {
            searchText = ""
        }
    }

    public func connect() {
        commandClient.connect()

        if Variant.screenshotMode {
            dataModel.finishLoading()
            return
        }

        connectTask?.cancel()
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPreferences()
            if Task.isCancelled {
                return
            }
            self.connectTask = nil
        }
    }

    private func loadPreferences() async {
        let filter = await ConnectionStateFilter(rawValue: SharedPreferences.connectionStateFilter.get()) ?? .active
        let sort = await ConnectionSort(rawValue: SharedPreferences.connectionSort.get()) ?? .byDate
        connectionStateFilter = filter
        connectionSort = sort
    }

    public func disconnect() {
        commandClient.disconnect()
        connectTask?.cancel()
        connectTask = nil
        saveStateFilterTask = nil
        saveSortTask = nil
    }

    public func closeAllConnections() {
        do {
            try CommandTarget.standaloneClient().closeConnections()
        } catch {
            alert = AlertState(action: "close all connections", error: error)
        }
    }
}
