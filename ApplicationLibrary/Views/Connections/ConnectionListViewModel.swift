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

        // And a page must not spin for something that is not coming.
        //
        // `isLoading` was an unconditional initial `true` that only a delivered connection
        // list could clear, so with the tunnel stopped - no command client, nothing to
        // deliver - the Activity page showed a spinner for as long as it was open. The page
        // has an empty state that says exactly that; it was unreachable.
        //
        // Subscribing to a published flag delivers its current value immediately, so this also
        // settles the state on the first run of a launch that never connects.
        commandClient.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self, !isConnected else { return }
                self.finishLoading()
            }
            .store(in: &cancellables)
    }

    /// The manual's high-density cases, as display rows.
    ///
    /// §44 names the values an activity row must survive and the ways it must not fail: a metric
    /// that squeezes the domain out, a badge that overflows, an IPv6 literal that cannot be read,
    /// a route that overlaps the numbers. A `LibboxConnection` is a Go-backed object and cannot
    /// be fabricated, but the row renders `Connection`, which is this client's own struct - so
    /// the hostile values go in at the display layer, which is where they are laid out.
    func seedDataDensityFixture() {
        func make(_ id: String, domain: String, ipVersion: Int32, network: String, protocolName: String,
                  rule: String, outbound: String, chain: [String], up: Int64, down: Int64,
                  upTotal: Int64, downTotal: Int64, closed: Bool = false) -> Connection {
            Connection(
                id: id,
                inbound: "tun-in",
                inboundType: "tun",
                ipVersion: ipVersion,
                network: network,
                source: ipVersion == 6 ? "[fd00::1]:51234" : "192.168.1.24:51234",
                destination: domain,
                domain: domain,
                displayDestination: domain,
                protocolName: protocolName,
                user: "",
                fromOutbound: outbound,
                createdAt: Date().addingTimeInterval(-120),
                closedAt: closed ? Date() : nil,
                upload: up,
                download: down,
                uploadTotal: upTotal,
                downloadTotal: downTotal,
                rule: rule,
                outbound: outbound,
                outboundType: "shadowsocks",
                chain: chain
            )
        }

        connections = [
            // A long domain, a long protocol name and three badges.
            make("d1",
                 domain: "very-long-subdomain-name.analytics.example-corporation-internal.example.com",
                 ipVersion: 4, network: "tcp", protocolName: "shadowsocks-2022-blake3-aes-256-gcm",
                 rule: "DOMAIN-SUFFIX,example.com", outbound: "Proxy Group With A Long Name",
                 chain: ["direct", "proxy-a", "proxy-b", "Proxy Group With A Long Name"],
                 up: 12_345_678, down: 9_876_543_210, upTotal: 1_234_567_890, downTotal: 12_345_678_901),
            // An IPv6 literal.
            make("d2", domain: "[2001:db8:85a3::8a2e:370:7334]:443",
                 ipVersion: 6, network: "tcp", protocolName: "",
                 rule: "IP-CIDR6,2001:db8::/32", outbound: "direct", chain: ["direct"],
                 up: 0, down: 512, upTotal: 0, downTotal: 512),
            // A Chinese rule and zero traffic.
            make("d3", domain: "assets.测试站点.中国",
                 ipVersion: 4, network: "udp", protocolName: "",
                 rule: "域名后缀:中国", outbound: "direct", chain: ["direct"],
                 up: 0, down: 0, upTotal: 0, downTotal: 0),
            // Kilobyte and megabyte order values, closed.
            make("d4", domain: "cdn.example.net",
                 ipVersion: 4, network: "tcp", protocolName: "http",
                 rule: "GEOIP,CN", outbound: "proxy-a", chain: ["proxy-a", "proxy-b"],
                 up: 1_024, down: 1_048_576, upTotal: 98_304, downTotal: 734_003_200, closed: true),
        ]
        updateFilteredConnections()
        finishLoading()
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
            if Variant.screenshotState == "activity" {
                dataModel.seedDataDensityFixture()
            } else {
                dataModel.finishLoading()
            }
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
