import Foundation
import Libbox
import NetworkExtension
import os
import UserNotifications
#if os(macOS)
    import CoreWLAN
#endif
#if os(iOS) || os(tvOS)
    import DeviceKit
#endif

public class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private static let logger = Logger(category: "ExtensionPlatformInterface")

    /// The MTU iOS gives the Personal Hotspot bridge that carries a tethered client's traffic.
    ///
    /// It is the widest frame any peer behind that bridge can receive, so it is also the only
    /// honest upper bound for an interface that may forward for those peers.
    private static let hotspotBridgeMTU = 1500

    private let tunnel: ExtensionProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?

    init(_ tunnel: ExtensionProvider) {
        self.tunnel = tunnel
    }

    public func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTun0(options, ret0_)
        }
    }

    private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Nil options")])
        }
        guard let ret0_ else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Nil return pointer")])
        }

        let prefs = tunnel.overridePreferences ?? ExtensionProvider.OverridePreferences()
        let autoRouteUseSubRangesByDefault = prefs.autoRouteUseSubRangesByDefault
        let excludeAPNs = prefs.excludeAPNsRoute
        let excludeDefaultRoute = prefs.excludeDefaultRoute
        let systemProxyEnabled = prefs.systemProxyEnabled

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            // The utun's MTU is not private to this device.
            //
            // `include_all_networks` is the one mode in which iOS also routes Personal Hotspot
            // clients into this utun. In that mode the same interface fronts the 1500-byte
            // hotspot bridge, and the NIC MTU becomes the MSS this stack offers to every peer
            // behind it: a 9000-byte utun tells a client on a 1500-byte link to accept segments
            // that link can never deliver intact, and every non-TCP or MSS-ignoring peer on it
            // black-holes rather than negotiating around it. An interface that forwards for
            // others must not promise more than the narrowest link it forwards for.
            //
            // The decision is taken from the start options rather than from hotspot state:
            // iOS exposes no "I am serving a hotspot" signal, and the hotspot may be enabled
            // long after `setTunnelNetworkSettings` has run, at which point this value can no
            // longer be revised for the session.
            let requestedMTU = Int(options.getMTU())
            var effectiveMTU = requestedMTU > 0 ? requestedMTU : Self.hotspotBridgeMTU
            if prefs.includeAllNetworks, effectiveMTU > Self.hotspotBridgeMTU {
                effectiveMTU = Self.hotspotBridgeMTU
            }
            settings.mtu = NSNumber(value: effectiveMTU)

            var dnsSettings: NEDNSSettings?
            if options.getDNSMode()!.value != LibboxDNSModeDisabled {
                let dnsServerIterator = try options.getDNSServerAddress()
                var dnsServers: [String] = []
                while dnsServerIterator.hasNext() {
                    dnsServers.append(dnsServerIterator.next())
                }
                if !dnsServers.isEmpty {
                    dnsSettings = NEDNSSettings(servers: dnsServers)
                }
            }

            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            while ipv4AddressIterator.hasNext() {
                let ipv4Prefix = ipv4AddressIterator.next()!
                ipv4Address.append(ipv4Prefix.address()!.value)
                ipv4Mask.append(ipv4Prefix.mask()!.value)
            }

            let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
            var ipv4Routes: [NEIPv4Route] = []
            var ipv4ExcludeRoutes: [NEIPv4Route] = []

            let inet4RouteAddressIterator = options.getInet4RouteAddress()!
            if inet4RouteAddressIterator.hasNext() {
                while inet4RouteAddressIterator.hasNext() {
                    let ipv4RoutePrefix = inet4RouteAddressIterator.next()!
                    ipv4Routes.append(NEIPv4Route(destinationAddress: ipv4RoutePrefix.address()!.value, subnetMask: ipv4RoutePrefix.mask()!.value))
                }
            } else if autoRouteUseSubRangesByDefault {
                ipv4Routes.append(NEIPv4Route(destinationAddress: "1.0.0.0", subnetMask: "255.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "2.0.0.0", subnetMask: "254.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "4.0.0.0", subnetMask: "252.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "8.0.0.0", subnetMask: "248.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "16.0.0.0", subnetMask: "240.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "32.0.0.0", subnetMask: "224.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "64.0.0.0", subnetMask: "192.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"))
            } else {
                ipv4Routes.append(NEIPv4Route.default())
            }

            let inet4RouteExcludeAddressIterator = options.getInet4RouteExcludeAddress()!
            while inet4RouteExcludeAddressIterator.hasNext() {
                let ipv4RoutePrefix = inet4RouteExcludeAddressIterator.next()!
                ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: ipv4RoutePrefix.address()!.value, subnetMask: ipv4RoutePrefix.mask()!.value))
            }
            if excludeDefaultRoute, !ipv4Routes.isEmpty {
                if !ipv4ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "0.0.0.0" && it.destinationSubnetMask == "255.255.255.254"
                }) {
                    ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"))
                }
            }
            if excludeAPNs, !ipv4Routes.isEmpty {
                if !ipv4ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "17.0.0.0" && it.destinationSubnetMask == "255.0.0.0"
                }) {
                    ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: "17.0.0.0", subnetMask: "255.0.0.0"))
                }
            }

            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
            settings.ipv4Settings = ipv4Settings

            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            let ipv6AddressIterator = options.getInet6Address()!
            while ipv6AddressIterator.hasNext() {
                let ipv6Prefix = ipv6AddressIterator.next()!
                ipv6Address.append(ipv6Prefix.address()!.value)
                ipv6Prefixes.append(NSNumber(value: ipv6Prefix.prefix()))
            }
            // The interface must not claim IPv6 when the core gave it no IPv6 address. The entry
            // decision in the core removes IPv6 addressing, routes and the hijack DNS address when every
            // local IPv6 destination is unreachable; an NEIPv6Settings with empty addresses - and the
            // default ::/0 route built below - would then advertise a family the tunnel cannot deliver.
            if !ipv6Address.isEmpty {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                var ipv6ExcludeRoutes: [NEIPv6Route] = []

                let inet6RouteAddressIterator = options.getInet6RouteAddress()!
                if inet6RouteAddressIterator.hasNext() {
                    while inet6RouteAddressIterator.hasNext() {
                        let ipv6RoutePrefix = inet6RouteAddressIterator.next()!
                        ipv6Routes.append(NEIPv6Route(destinationAddress: ipv6RoutePrefix.address()!.value, networkPrefixLength: NSNumber(value: ipv6RoutePrefix.prefix())))
                    }
                } else if autoRouteUseSubRangesByDefault {
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "100::", networkPrefixLength: 8))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "200::", networkPrefixLength: 7))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "400::", networkPrefixLength: 6))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "800::", networkPrefixLength: 5))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "1000::", networkPrefixLength: 4))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "2000::", networkPrefixLength: 3))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "4000::", networkPrefixLength: 2))
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1))
                } else {
                    ipv6Routes.append(NEIPv6Route.default())
                }

                let inet6RouteExcludeAddressIterator = options.getInet6RouteExcludeAddress()!
                while inet6RouteExcludeAddressIterator.hasNext() {
                    let ipv6RoutePrefix = inet6RouteExcludeAddressIterator.next()!
                    ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: ipv6RoutePrefix.address()!.value, networkPrefixLength: NSNumber(value: ipv6RoutePrefix.prefix())))
                }

                if excludeDefaultRoute, !ipv6Routes.isEmpty {
                    if !ipv6ExcludeRoutes.contains(where: { it in
                        it.destinationAddress == "::" && it.destinationNetworkPrefixLength == 127
                    }) {
                        ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: "::", networkPrefixLength: 127))
                    }
                }

                ipv6Settings.includedRoutes = ipv6Routes
                ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
                settings.ipv6Settings = ipv6Settings
            }

            let hasDefaultRoute = ipv4Routes.contains(where: {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            })
            if !hasDefaultRoute {
                dnsSettings?.matchDomains = [""]
                dnsSettings?.matchDomainsNoSearch = true
            }
            settings.dnsSettings = dnsSettings
        }

        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer()!.value, port: Int(options.getHTTPProxyServerPort()))
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            if systemProxyEnabled {
                proxySettings.httpEnabled = true
                proxySettings.httpsEnabled = true
            }
            var bypassDomains: [String] = []
            let bypassDomainIterator = options.getHTTPProxyBypassDomain()!
            while bypassDomainIterator.hasNext() {
                bypassDomains.append(bypassDomainIterator.next())
            }
            if excludeAPNs {
                if !bypassDomains.contains(where: { it in
                    it == "push.apple.com"
                }) {
                    bypassDomains.append("push.apple.com")
                }
            }
            if !bypassDomains.isEmpty {
                proxySettings.exceptionList = bypassDomains
            }
            var matchDomains: [String] = []
            let matchDomainIterator = options.getHTTPProxyMatchDomain()!
            while matchDomainIterator.hasNext() {
                matchDomains.append(matchDomainIterator.next())
            }
            if !matchDomains.isEmpty {
                proxySettings.matchDomains = matchDomains
            }
            settings.proxySettings = proxySettings
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)
        logInstalledSettings(settings, autoRoute: options.getAutoRoute(), prefs: prefs)

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Missing file descriptor")])
        }
    }

    /// Records the tunnel as the system received it, once per session.
    ///
    /// Nothing else in the client reports what was actually installed: the profile's options,
    /// the platform's own decisions (`includeAllNetworks`, `excludeLocalNetworks`) and the
    /// clamping above all end up as one `NEPacketTunnelNetworkSettings`, and a report of "the
    /// tethered client has no connectivity" cannot be read without it.
    private func logInstalledSettings(_ settings: NEPacketTunnelNetworkSettings, autoRoute: Bool, prefs: ExtensionProvider.OverridePreferences) {
        let ipv4Included = settings.ipv4Settings?.includedRoutes?.count ?? 0
        let ipv4Excluded = settings.ipv4Settings?.excludedRoutes?.count ?? 0
        let ipv6Included = settings.ipv6Settings?.includedRoutes?.count ?? 0
        let ipv6Excluded = settings.ipv6Settings?.excludedRoutes?.count ?? 0
        let dnsServers = settings.dnsSettings?.servers.joined(separator: ",") ?? "none"
        let matchDomains = settings.dnsSettings?.matchDomains?.joined(separator: ",") ?? "none"
        let mtu = settings.mtu?.intValue ?? 0
        let summary = [
            "[tunnel] installed",
            "mtu=\(mtu)",
            "auto_route=\(autoRoute)",
            "ipv4=\(ipv4Included)/\(ipv4Excluded)",
            "ipv6=\(ipv6Included)/\(ipv6Excluded)",
            "dns=\(dnsServers)",
            "match_domains=\(matchDomains)",
            "include_all_networks=\(prefs.includeAllNetworks)",
        ].joined(separator: " ")
        tunnel.writeMessage(summary, level: .info)
    }

    public func usePlatformAutoDetectControl() -> Bool {
        false
    }

    public func autoDetectControl(_: Int32) throws {}

    public func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        #if os(macOS)
            if Variant.useSystemExtension {
                guard let sourceAddress, let destinationAddress else {
                    throw NSError(domain: "findConnectionOwner", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "Missing source or destination address",
                    ])
                }
                let owner = try RootHelperClient.shared.findConnectionOwner(
                    ipProtocol: ipProtocol,
                    sourceAddress: sourceAddress,
                    sourcePort: sourcePort,
                    destinationAddress: destinationAddress,
                    destinationPort: destinationPort
                )
                let result = LibboxConnectionOwner()
                result.userId = owner.userId
                result.userName = owner.userName
                result.setProcessPaths(owner.processPaths.toStringIterator())
                return result
            }
        #elseif JAILBREAK
            guard let sourceAddress, let destinationAddress else {
                throw NSError(domain: "findConnectionOwner", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "Missing source or destination address",
                ])
            }
            let owner = try ShellHelperClient.shared.findConnectionOwner(
                ipProtocol: ipProtocol,
                sourceAddress: sourceAddress,
                sourcePort: sourcePort,
                destinationAddress: destinationAddress,
                destinationPort: destinationPort
            )
            let result = LibboxConnectionOwner()
            result.userId = owner.userId
            result.userName = owner.userName
            result.setProcessPaths(owner.processPaths.toStringIterator())
            return result
        #endif
        throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Not implemented")])
    }

    public func writeLog(_ message: String?) {
        guard let message else {
            return
        }
        tunnel.writeMessage(message)
    }

    private var nwMonitor: NWPathMonitor?
    private var lastNetworkPath: String?

    /// Serialises every delivery and the seed.
    ///
    /// `NWPathMonitor.start(queue:)` only promises that events are delivered on the queue; it does
    /// not promise a serial queue. `DispatchQueue.global()` is concurrent, so two path updates could
    /// run `onUpdateDefaultInterface` at once and interleave `lastNetworkPath`, the dedup and the
    /// two `listener.updateDefaultInterface` calls - the last of which decides the core's default
    /// interface. The queue is therefore a dedicated serial one, and `close` retires the generation
    /// on it so a callback already past the generation check cannot race the cleanup.
    private let pathMonitorQueue = DispatchQueue(label: "io.nekohasekai.sfa.path-monitor")

    /// Identifies the monitor a path callback belongs to, and bounds the first update.
    ///
    /// The rules live in `InterfaceMonitorStartup` - a Foundation-only type with no
    /// `NetworkExtension` import - so the failure paths can be driven in a test rather than only
    /// argued about here. See that file for why the bound and the generation check exist at all;
    /// this property is just the current value.
    ///
    /// Bumped wherever `nwMonitor` is assigned or cleared, through `next()` so the rule is one
    /// function rather than several hand-written increments that can drift apart.
    private var nwMonitorGeneration = InterfaceMonitorStartup.Generation()

    public func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else {
            return
        }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        // The generation is queue-confined too: the callback reads it on `pathMonitorQueue`, so the
        // bump has to happen there as well or a start racing a running callback is a data race.
        let generation = pathMonitorQueue.sync { nwMonitorGeneration.next() }

        let semaphore = DispatchSemaphore(value: 0)
        // One closure for the monitor's whole life. The previous revision replaced the handler from
        // inside the first callback to avoid re-signalling the semaphore; the generation check does
        // that without mutating the handler from the queue it runs on.
        monitor.pathUpdateHandler = { path in
            guard InterfaceMonitorStartup.disposition(callback: generation,
                                                      current: self.nwMonitorGeneration) == .publish
            else {
                return
            }
            self.onUpdateDefaultInterface(listener, path)
            semaphore.signal()
        }
        monitor.start(queue: pathMonitorQueue)

        // Seed from `currentPath` first, so the ordinary case does not wait at all: `NWPathMonitor`
        // populates `currentPath` before `start` returns, and it is `.unsatisfied` rather than invalid
        // when there is no usable path - which is exactly the airplane-mode state, and one
        // `getInterfaces()` already knows how to express (it returns an empty list for `.unsatisfied`).
        //
        // A network with no default interface is a legal state, not a failure to start. The listener is
        // told so and the tunnel continues to start; the callback above keeps it current if a path
        // appears later, which is what makes "airplane mode, then Wi-Fi on" recover.
        //
        // The seed runs ON the monitor queue: it is the same `lastNetworkPath` the callbacks mutate,
        // and a callback that started between `monitor.start` and this call would otherwise be a
        // concurrent writer.
        pathMonitorQueue.sync {
            onUpdateDefaultInterface(listener, monitor.currentPath)
        }

        // Then wait, briefly, for a real update to supersede the seed, and map the result through the
        // policy so the two meanings of "the wait ended" are stated once. The outcome is deliberately
        // not acted on: whether the update arrived or the wait timed out, the listener has a state and
        // startup proceeds. That is the whole fix - the wait is bounded, so there is no state in which
        // startup blocks forever on a callback that never comes.
        let signalled = semaphore.wait(timeout: .now() + InterfaceMonitorStartup.firstUpdateTimeout) == .success
        _ = InterfaceMonitorStartup.outcome(signalled: signalled)
    }

    /// The interface the path is actually using, not merely the first one it could use.
    ///
    /// `NWPath.availableInterfaces` is a list of interfaces the path CAN use, ordered by preference;
    /// it is not the interface the system selected. On a handover the list can still lead with the
    /// interface the device is leaving (Wi-Fi during the moment before the path moves to cellular),
    /// and taking `.first` would report that stale interface to the core - which then keeps dialling
    /// on a path the system no longer uses. `usesInterfaceType` is the API that answers which type
    /// the path is on, so the matching entry wins; `.first` remains only as a fallback for an
    /// interface type the three cases do not name.
    private func activeInterface(of path: Network.NWPath) -> Network.NWInterface? {
        let interfaces = path.availableInterfaces
        if path.usesInterfaceType(.wifi),
           let wifi = interfaces.first(where: { $0.type == .wifi }) {
            return wifi
        }
        if path.usesInterfaceType(.cellular),
           let cellular = interfaces.first(where: { $0.type == .cellular }) {
            return cellular
        }
        if path.usesInterfaceType(.wiredEthernet),
           let wired = interfaces.first(where: { $0.type == .wiredEthernet }) {
            return wired
        }
        return interfaces.first
    }

    private func onUpdateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        let networkPath = describeNetworkPath(path)
        listener.updateNetworkPath(networkPath)
        if networkPath == lastNetworkPath {
            return
        }
        lastNetworkPath = networkPath
        guard path.status != .unsatisfied,
              let defaultInterface = activeInterface(of: path)
        else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private func describeNetworkPath(_ path: Network.NWPath) -> String {
        var components: [String] = []
        switch path.status {
        case .satisfied:
            components.append("satisfied")
        case .unsatisfied:
            components.append("unsatisfied(\(path.unsatisfiedReason))")
        case .requiresConnection:
            components.append("requiresConnection")
        @unknown default:
            components.append("unknown")
        }
        if !path.availableInterfaces.isEmpty {
            components.append("interfaces=" + path.availableInterfaces.map { "\($0.name)#\($0.index)/\($0.type)" }.joined(separator: ","))
        }
        // The interface the path is USING, not just the set it could use. A handover can keep the
        // available set identical (Wi-Fi still associated, cellular already up) while the path moves
        // from one to the other; without this component the dedup key would be unchanged and the
        // update would be suppressed - the core would keep the interface the device has left.
        if let activeInterface = activeInterface(of: path) {
            components.append("active=\(activeInterface.name)#\(activeInterface.index)/\(activeInterface.type)")
        }
        if !path.gateways.isEmpty {
            components.append("gateways=" + path.gateways.map { "\($0)" }.sorted().joined(separator: ","))
        }
        if path.supportsIPv4 {
            components.append("ipv4")
        }
        if path.supportsIPv6 {
            components.append("ipv6")
        }
        if path.supportsDNS {
            components.append("dns")
        }
        if path.isExpensive {
            components.append("expensive")
        }
        if path.isConstrained {
            components.append("constrained")
        }
        return components.joined(separator: " ")
    }

    public func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        // The generation bump and the state clear are ONE step on the queue a callback runs on: a
        // callback already past its generation check would otherwise write `lastNetworkPath` after
        // this function cleared it, and the next monitor would inherit a dedup key from the previous
        // one. Cancelling after the sync also means no callback body is running when the monitor dies.
        pathMonitorQueue.sync {
            nwMonitorGeneration.retire()
            lastNetworkPath = nil
        }
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    public func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "NWMonitor not started")])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return networkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return networkInterfaceArray(interfaces)
    }

    class networkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        private var nextValue: LibboxNetworkInterface?

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    public func underNetworkExtension() -> Bool {
        true
    }

    public func includeAllNetworks() -> Bool {
        #if os(tvOS)
            return false
        #else
            return tunnel.overridePreferences?.includeAllNetworks ?? false
        #endif
    }

    public func clearDNSCache() {
        guard let networkSettings else {
            return
        }
        runBlocking {
            self.tunnel.reasserting = true
            defer { self.tunnel.reasserting = false }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(nil) { _ in
                    continuation.resume()
                }
            }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(networkSettings) { _ in
                    continuation.resume()
                }
            }
        }
    }

    public func readWIFIState() -> LibboxWIFIState? {
        #if os(iOS)
            let network = runBlocking {
                await NEHotspotNetwork.fetchCurrent()
            }
            guard let network else {
                return nil
            }
            return LibboxWIFIState(network.ssid, wifiBSSID: network.bssid)!
        #elseif os(macOS)
            if Variant.useSystemExtension {
                return UserServiceClient.shared.readWIFIState()
            }
            guard let interface = CWWiFiClient.shared().interface() else {
                return nil
            }
            guard let ssid = interface.ssid() else {
                return nil
            }
            guard let bssid = interface.bssid() else {
                return nil
            }
            return LibboxWIFIState(ssid, wifiBSSID: bssid)!
        #else
            return nil
        #endif
    }

    public func readWIFISSID() -> String? {
        #if os(iOS)
            return runBlocking {
                await NEHotspotNetwork.fetchCurrent()?.ssid
            }
        #elseif os(macOS)
            return CWWiFiClient.shared().interface()?.ssid()
        #else
            return nil
        #endif
    }

    public func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        #if os(macOS)
            if Variant.useSystemExtension {
                guard let fd = UserServiceClient.shared.connectSSHAgent() else {
                    throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to connect to SSH agent",
                    ])
                }
                ret0_?.pointee = fd
                return
            }
        #endif
        throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "SSH agent forwarding is not supported",
        ])
    }

    public func serviceStop() throws {
        tunnel.stopService()
    }

    public func serviceReload() throws {
        try runBlocking { [self] in
            try await tunnel.reloadService()
        }
    }

    public func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let networkSettings else {
            return status
        }
        guard let proxySettings = networkSettings.proxySettings else {
            return status
        }
        if proxySettings.httpServer == nil {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    public func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings else {
            return
        }
        guard let proxySettings = networkSettings.proxySettings else {
            return
        }
        if proxySettings.httpServer == nil {
            return
        }
        if proxySettings.httpEnabled == isEnabled {
            return
        }
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxySettings
        try runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(networkSettings)
        }
    }

    public func triggerNativeCrash() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
            fatalError("debug native crash")
        }
    }

    public func writeDebugMessage(_ message: String?) {
        guard let message else {
            return
        }
        Self.logger.debug("\(message, privacy: .public)")
    }

    func reset() {
        networkSettings = nil
        // The same generation bump as `closeDefaultInterfaceMonitor`, and for the same reason: this is
        // reached from `stopService()`, so it can land while a start's first callback is still queued.
        // It runs on the monitor queue so the bump and the dedup key's clear are one step against a
        // callback that is already executing.
        pathMonitorQueue.sync {
            nwMonitorGeneration.retire()
            lastNetworkPath = nil
        }
        nwMonitor?.cancel()
        nwMonitor = nil
        #if os(macOS)
            neighborCallbackListener?.invalidate()
            neighborCallbackListener = nil
            neighborCallbackHandler = nil
        #endif
    }

    public func send(_ notification: LibboxNotification?) throws {
        #if !os(tvOS)
            guard let notification else {
                return
            }
            #if os(macOS)
                if Variant.useSystemExtension {
                    try UserServiceClient.shared.sendNotification(notification)
                    return
                }
            #endif
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()

            content.title = notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            if !notification.openURL.isEmpty {
                content.userInfo["OPEN_URL"] = notification.openURL
                content.categoryIdentifier = "OPEN_URL"
            }
            content.interruptionLevel = .active
            let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
            try runBlocking {
                #if !JAILBREAK
                    try await center.requestAuthorization(options: [.alert])
                #endif
                try await center.add(request)
            }
        #endif
    }

    public func cancelNotification(_ identifier: String?, typeID _: Int32) throws {
        #if !os(tvOS)
            guard let identifier else {
                return
            }
            #if os(macOS)
                if Variant.useSystemExtension {
                    try UserServiceClient.shared.cancelNotification(identifier)
                    return
                }
            #endif
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        #endif
    }

    #if os(macOS)
        private var neighborCallbackListener: NSXPCListener?
        private var neighborCallbackHandler: NeighborCallbackHandler?
    #endif

    public func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        #if os(macOS)
            guard let listener else { return }
            if Variant.useSystemExtension {
                let handler = NeighborCallbackHandler(listener)
                let xpcListener = NSXPCListener.anonymous()
                xpcListener.delegate = handler
                xpcListener.resume()
                try RootHelperClient.shared.startNeighborMonitor(
                    callbackEndpoint: xpcListener.endpoint
                )
                neighborCallbackListener = xpcListener
                neighborCallbackHandler = handler
                return
            }
        #endif
    }

    public func registerMyInterface(_ name: String?) {
        #if os(macOS)
            guard let name, !name.isEmpty else { return }
            if Variant.useSystemExtension {
                try? RootHelperClient.shared.registerMyInterface(name: name)
            }
        #endif
    }

    public func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {
        #if os(macOS)
            if Variant.useSystemExtension {
                try? RootHelperClient.shared.closeNeighborMonitor()
                neighborCallbackListener?.invalidate()
                neighborCallbackListener = nil
                neighborCallbackHandler = nil
                return
            }
        #endif
    }

    public func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    public func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }

    public func usePlatformShell() -> Bool {
        #if os(macOS)
            return Variant.useSystemExtension
        #elseif JAILBREAK
            return true
        #else
            return false
        #endif
    }

    public func checkPlatformShell() throws {
        #if os(macOS) || JAILBREAK
            _ = try ShellHelperClient.shared.getVersion()
        #else
            throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SSH server is not supported",
            ])
        #endif
    }

    public func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: (any LibboxStringIteratorProtocol)?, term: String?, rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol {
        #if os(macOS) || JAILBREAK
            guard let user else {
                throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "missing user",
                ])
            }
            let command = command ?? ""
            let term = term ?? ""
            let envStrings = environ?.toArray() ?? []

            let groups = user.groups()?.toArray() ?? []
            let payload = PlatformUserPayload(
                username: user.username,
                uid: user.uid,
                gid: user.gid,
                homeDir: user.homeDir,
                shell: user.shell,
                groups: groups
            )

            let (fileHandle, handle) = try ShellHelperClient.shared.openShellSession(
                user: payload,
                command: command,
                environ: envStrings,
                term: term,
                rows: rows,
                cols: cols
            )

            return RootHelperShellSession(fileHandle: fileHandle, handle: handle)
        #else
            throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SSH server is not supported",
            ])
        #endif
    }

    public func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        #if os(macOS) || JAILBREAK
            do {
                return try ShellHelperClient.shared.readSystemSSHHostKey()
            } catch let keyError {
                error?.pointee = keyError as NSError
                return ""
            }
        #else
            error?.pointee = NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "not supported on this platform",
            ])
            return ""
        #endif
    }

    public func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        #if JAILBREAK
            return JailbreakConfiguration.sftpServerPath
        #else
            error?.pointee = NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "lookupSFTPServer is not supported on Apple platforms",
            ])
            return ""
        #endif
    }

    public func tailscaleHostname() -> String {
        #if os(iOS) || os(tvOS)
            return Device.current.safeDescription
        #else
            return ""
        #endif
    }

    public func usePlatformBridge() -> Bool {
        #if os(macOS)
            return Variant.useSystemExtension
        #elseif JAILBREAK
            return true
        #else
            return false
        #endif
    }

    public func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        #if os(macOS) || JAILBREAK
            guard let options else {
                throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "createBridge: missing options",
                ])
            }
            let handshake = try ShellHelperClient.shared.createBridgeService(
                bridgeName: options.bridgeName,
                mtu: options.mtu,
                inet4Port: options.inet4Port,
                inet6Port: options.inet6Port,
                interfaceName: options.interface
            )
            let tunFd = dup(handshake.fileHandle.fileDescriptor)
            guard tunFd >= 0 else {
                let dupErrno = errno
                try? ShellHelperClient.shared.closeBridgeService(handle: handshake.handle)
                throw NSError(domain: "ExtensionPlatformInterface", code: Int(dupErrno), userInfo: [
                    NSLocalizedDescriptionKey: "dup bridge tun fd: \(String(cString: strerror(dupErrno)))",
                ])
            }
            try? handshake.fileHandle.close()
            return BridgeServiceSession(
                fileDescriptor: tunFd,
                name: handshake.name,
                inet6Active: handshake.inet6Active,
                handle: handshake.handle
            )
        #else
            throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "bridge is not supported on this platform",
            ])
        #endif
    }

    public func usePlatformAutoRedirect() -> Bool {
        false
    }

    public func createAutoRedirect(_: Data?, handler _: (any LibboxAutoRedirectHandlerProtocol)?) throws -> any LibboxAutoRedirectSessionProtocol {
        throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "auto redirect is not supported on Apple platforms",
        ])
    }

    #if os(macOS) || JAILBREAK
        private class BridgeServiceSession: NSObject, LibboxBridgeSessionProtocol {
            private let tunFileDescriptor: Int32
            private let tunName: String
            private let tunInet6Active: Bool
            private let handle: String

            init(fileDescriptor: Int32, name: String, inet6Active: Bool, handle: String) {
                tunFileDescriptor = fileDescriptor
                tunName = name
                tunInet6Active = inet6Active
                self.handle = handle
            }

            func fileDescriptor() -> Int32 {
                tunFileDescriptor
            }

            // LibboxBridgeSessionProtocol requires the boxed result: Go declares
            // BridgeSession.Name as returning *StringBox so the value does not travel in
            // gomobile's packed result frame. The AIDL handshake still carries a plain
            // String, so it is wrapped here rather than changing that contract.
            func name() -> LibboxStringBox? {
                let nameBox = LibboxStringBox()
                nameBox.value = tunName
                return nameBox
            }

            func inet6Active() -> Bool {
                tunInet6Active
            }

            func setEgress(_ interfaceName: String?) throws {
                try ShellHelperClient.shared.setBridgeEgress(handle: handle, egress: interfaceName ?? "")
            }

            func close() throws {
                try? ShellHelperClient.shared.closeBridgeService(handle: handle)
                Darwin.close(tunFileDescriptor)
            }
        }
    #endif

    public func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        #if os(macOS) || JAILBREAK
            guard let username else {
                throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "lookupUser: username is required",
                ])
            }
            guard let pw = getpwnam(username) else {
                throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "user not found: \(username)",
                ])
            }
            let result = LibboxPlatformUser()
            result.username = String(cString: pw.pointee.pw_name)
            result.uid = Int32(pw.pointee.pw_uid)
            result.gid = Int32(pw.pointee.pw_gid)
            result.homeDir = String(cString: pw.pointee.pw_dir)
            if let shellPtr = pw.pointee.pw_shell {
                result.shell = String(cString: shellPtr)
            }

            var ngroups: Int32 = 64
            var groupIDs = [Int32](repeating: 0, count: Int(ngroups))
            var rc = groupIDs.withUnsafeMutableBufferPointer { buffer in
                getgrouplist(username, Int32(bitPattern: pw.pointee.pw_gid), buffer.baseAddress, &ngroups)
            }
            if rc == -1 {
                groupIDs = [Int32](repeating: 0, count: Int(ngroups))
                rc = groupIDs.withUnsafeMutableBufferPointer { buffer in
                    getgrouplist(username, Int32(bitPattern: pw.pointee.pw_gid), buffer.baseAddress, &ngroups)
                }
            }
            if rc == -1 {
                throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "getgrouplist failed for \(username)",
                ])
            }
            result.setGroups(Array(groupIDs.prefix(Int(ngroups))).toInt32Iterator())
            return result
        #else
            throw NSError(domain: "ExtensionPlatformInterface", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "SSH server is not supported",
            ])
        #endif
    }
}

#if os(macOS)
    private class NeighborCallbackHandler: NSObject, NSXPCListenerDelegate, NeighborTableListenerProtocol {
        private let listener: LibboxNeighborUpdateListenerProtocol

        init(_ listener: LibboxNeighborUpdateListenerProtocol) {
            self.listener = listener
        }

        func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            let exportedInterface = NSXPCInterface(with: NeighborTableListenerProtocol.self)
            RootHelperXPC.configureListenerInterface(exportedInterface)
            newConnection.exportedInterface = exportedInterface
            newConnection.exportedObject = self
            newConnection.resume()
            return true
        }

        func updateNeighborTable(entries: NSArray) {
            let iterator = NeighborEntryArrayIterator(entries)
            listener.updateNeighborTable(iterator)
        }
    }

    private class NeighborEntryArrayIterator: NSObject, LibboxNeighborEntryIteratorProtocol {
        private var entries: [NeighborEntryResult]
        private var index = 0

        init(_ array: NSArray) {
            entries = array.compactMap { $0 as? NeighborEntryResult }
        }

        func hasNext() -> Bool {
            index < entries.count
        }

        func next() -> LibboxNeighborEntry? {
            guard index < entries.count else { return nil }
            let result = entries[index]
            index += 1
            let entry = LibboxNeighborEntry()
            entry.address = result.address
            entry.macAddress = result.macAddress
            entry.hostname = result.hostname
            return entry
        }
    }
#endif
