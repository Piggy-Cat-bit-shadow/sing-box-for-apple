import Foundation
import Libbox
import NetworkExtension
import os.log
#if os(iOS)
    import WidgetKit
#endif
#if os(macOS)
    import CoreLocation
#endif

open class ExtensionProvider: NEPacketTunnelProvider {
    private static let logger = Logger(category: "ExtensionProvider")

    public private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    public var tunnelOptions: [String: NSObject]?
    private var startOptionsURL: URL?

    public struct OverridePreferences {
        public var includeAllNetworks: Bool = false
        public var systemProxyEnabled: Bool = true
        public var excludeDefaultRoute: Bool = false
        public var autoRouteUseSubRangesByDefault: Bool = false
        public var excludeAPNsRoute: Bool = false
    }

    public var overridePreferences: OverridePreferences?
    #if os(iOS)
        /// The device-axis observer: the display and lock notifications, reported to the core.
        ///
        /// Created once per tunnel process, in `startTunnel`, and torn down once, in `stopTunnel`
        /// before the command server is closed. `reloadService()` does not touch it.
        private var screenStateObserver: ScreenStateObserver?

        /// Starts the observer, once.
        ///
        /// Called only from `startTunnel`. A reload restarts the service inside the same command
        /// server, so re-creating the observer there would register the notifications a second time
        /// and hand the core two independent device axes; the guard makes that impossible even if a
        /// second caller appears. A failure to register is reported rather than swallowed: without
        /// the notifications the device axis falls back to the NetworkExtension sleep/wake pair
        /// alone, which on iOS enters the pause and never lifts it.
        private func startScreenStateObserver() {
            guard screenStateObserver == nil, let commandServer else {
                return
            }
            let observer = ScreenStateObserver(commandServer: commandServer)
            let result = observer.start()
            guard result.isStarted else {
                writeMessage("(packet-tunnel) screen state observer: could not register \(result.failedNotificationNames.joined(separator: ", ")); the device axis is driven by sleep/wake only")
                return
            }
            screenStateObserver = observer
        }

        /// Stops the observer and releases both registrations.
        ///
        /// Idempotent, and safe to call when nothing was ever registered.
        private func stopScreenStateObserver() {
            screenStateObserver?.cancel()
            screenStateObserver = nil
        }
    #endif

    private func applyStartOptions(_ options: [String: NSObject]) throws {
        try ApplicationLocale.apply(options["locale"] as? String)
        tunnelOptions = options
        overridePreferences = OverridePreferences(
            includeAllNetworks: (options["includeAllNetworks"] as? NSNumber)?.boolValue ?? false,
            systemProxyEnabled: (options["systemProxyEnabled"] as? NSNumber)?.boolValue ?? true,
            excludeDefaultRoute: (options["excludeDefaultRoute"] as? NSNumber)?.boolValue ?? false,
            autoRouteUseSubRangesByDefault: (options["autoRouteUseSubRangesByDefault"] as? NSNumber)?.boolValue ?? false,
            excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false
        )
    }

    private func platformMetadata() -> String {
        var metadata: [String: Any] = [:]
        #if !os(tvOS)
            var networkExtension: [String: Any] = [
                "includeAllNetworks": protocolConfiguration.includeAllNetworks,
                "excludeLocalNetworks": protocolConfiguration.excludeLocalNetworks,
                "enforceRoutes": protocolConfiguration.enforceRoutes,
            ]
            if #available(iOS 16.4, macOS 13.3, *) {
                networkExtension["excludeAPNs"] = protocolConfiguration.excludeAPNs
                networkExtension["excludeCellularServices"] = protocolConfiguration.excludeCellularServices
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                networkExtension["excludeDeviceCommunication"] = protocolConfiguration.excludeDeviceCommunication
            }
            metadata["networkExtension"] = networkExtension
        #endif
        if let overridePreferences {
            metadata["profileOverride"] = [
                "systemProxyEnabled": overridePreferences.systemProxyEnabled,
                "excludeDefaultRoute": overridePreferences.excludeDefaultRoute,
                "autoRouteUseSubRangesByDefault": overridePreferences.autoRouteUseSubRangesByDefault,
                "excludeAPNsRoute": overridePreferences.excludeAPNsRoute,
            ]
        }
        return PlatformMetadata.json(metadata)
    }

    private func persistStartOptions(_ options: [String: NSObject]) throws {
        guard let startOptionsURL else {
            return
        }
        let data = try ExtensionStartOptions.encode(options)
        try data.write(to: startOptionsURL, options: .atomic)
    }

    private func loadPersistedStartOptions() throws -> [String: NSObject]? {
        guard let startOptionsURL, FileManager.default.fileExists(atPath: startOptionsURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: startOptionsURL)
        return try ExtensionStartOptions.decode(data)
    }

    private func resolveStartOptions(_ startOptions: [String: NSObject]?) throws -> [String: NSObject] {
        if let startOptions, startOptions["configContent"] as? String != nil {
            return startOptions
        }
        let persistedOptions: [String: NSObject]?
        do {
            persistedOptions = try loadPersistedStartOptions()
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: load start options: \(error.localizedDescription)")
        }
        if let persistedOptions {
            if let startOptions {
                return persistedOptions.merging(startOptions) { _, new in new }
            }
            return persistedOptions
        }
        throw ExtensionStartupError("(packet-tunnel) error: missing start options")
    }

    #if os(macOS)
        private var xpcListener: NSXPCListener!
        private var xpcService: CommandXPCService!
        private var locationManager: CLLocationManager?
        private var locationDelegate: stubLocationDelegate?
    #endif

    override public init() {
        LibboxPrepareCrashSignalHandlers()
        #if os(macOS)
            if Variant.useSystemExtension {
                NativeCrashReporter.installForCurrentProcess(
                    basePath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("NativeCrash")
                )
            } else {
                NativeCrashReporter.installForCurrentProcess()
            }
        #else
            NativeCrashReporter.installForCurrentProcess()
        #endif
        LibboxReinstallCrashSignalHandlers()
        super.init()
    }

    override open func startTunnel(options startOptions: [String: NSObject]?) async throws {
        let basePath: String
        let workingPath: String
        let tempPath: String

        #if os(macOS)
            if Variant.useSystemExtension {
                let containerURL = FileManager.default.homeDirectoryForCurrentUser
                basePath = containerURL.path
                workingPath = containerURL.appendingPathComponent("Working").path
                tempPath = containerURL.appendingPathComponent("Temp").path
            } else {
                basePath = FilePath.sharedDirectory.relativePath
                workingPath = FilePath.workingDirectory.relativePath
                tempPath = FilePath.cacheDirectory.relativePath
            }
        #else
            basePath = FilePath.sharedDirectory.relativePath
            workingPath = FilePath.workingDirectory.relativePath
            tempPath = FilePath.cacheDirectory.relativePath
        #endif

        startOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(ExtensionStartOptions.snapshotFileName)

        #if os(macOS)
            if Variant.useSystemExtension {
                let socketPath = basePath + "/command.sock"
                let machServiceName = AppConfiguration.systemExtensionMachServiceName
                xpcService = CommandXPCService(socketPath: socketPath)
                xpcListener = NSXPCListener(machServiceName: machServiceName)
                xpcListener.delegate = xpcService
            }
        #endif

        let effectiveOptions = try resolveStartOptions(startOptions)
        try applyStartOptions(effectiveOptions)
        if effectiveOptions["configContent"] == nil {
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }
        do {
            try persistStartOptions(effectiveOptions)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: persist start options: \(error.localizedDescription)")
        }
        let options = LibboxSetupOptions()
        options.basePath = basePath
        options.workingPath = workingPath
        options.tempPath = tempPath

        options.logMaxLines = 3000
        options.debug = Variant.inDebug
        options.crashReportSource = "NetworkExtension"
        options.appVersion = Bundle.application.versionNumber
        options.appMarketingVersion = Bundle.application.version
        options.platformMetadata = platformMetadata()

        #if os(tvOS)
            if let port = effectiveOptions["commandServerPort"] as? NSNumber {
                options.commandServerListenPort = port.int32Value
            }
            if let secret = effectiveOptions["commandServerSecret"] as? String {
                options.commandServerSecret = secret
            }
        #endif

        #if os(macOS)
            options.oomKillerEnabled = (effectiveOptions["oomKillerEnabled"] as? NSNumber)?.boolValue ?? false
            let oomMemoryLimitMB = (effectiveOptions["oomMemoryLimitMB"] as? NSNumber)?.int64Value ?? 0
            options.oomMemoryLimit = oomMemoryLimitMB * 1024 * 1024
            options.oomKillerDisabled = !((effectiveOptions["oomKillerKillConnections"] as? NSNumber)?.boolValue ?? false)
        #else
            options.oomKillerEnabled = true
        #endif
        options.powerReportEnabled = (effectiveOptions["powerReportEnabled"] as? NSNumber)?.boolValue ?? false

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw ExtensionStartupError("(packet-tunnel) error: setup service: \(setupError.localizedDescription)")
        }
        LibboxPromoteOOMDraft()
        LibboxDiscardPowerReportDraft()

        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            throw ExtensionStartupError("(packet-tunnel): create command server error: \(error.localizedDescription)")
        }
        do {
            try commandServer!.start()
        } catch {
            throw ExtensionStartupError("(packet-tunnel): start command server error: \(error.localizedDescription)")
        }

        #if os(macOS)
            if Variant.useSystemExtension {
                xpcListener.resume()
                Self.logger.info("set Command Server")
                xpcService.commandServer = commandServer
            }
        #endif

        do {
            try await startService()
        } catch {
            #if os(macOS)
                if Variant.useSystemExtension {
                    xpcService.markServiceNotReady(error)
                }
            #endif
            throw error
        }
        writeMessage("(packet-tunnel): Here I stand")
        #if os(iOS)
            startScreenStateObserver()
        #endif
        #if os(macOS)
            if Variant.useSystemExtension {
                xpcService.markServiceReady()
            }
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    func writeMessage(_ message: String, level: LogLevel = .error) {
        if let commandServer {
            commandServer.writeMessage(Int32(level.rawValue), message: message)
        }
    }

    private func startService() async throws {
        guard let configContent = tunnelOptions?["configContent"] as? String else {
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }

        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(configContent, options: options)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: start service: \(error.localizedDescription)")
        }
        #if os(macOS)
            if !Variant.useSystemExtension, commandServer!.needWIFIState() {
                locationManager = CLLocationManager()
                locationDelegate = stubLocationDelegate()
                locationManager!.delegate = locationDelegate
                locationManager!.requestLocation()
            }
        #endif
    }

    #if os(macOS)

        class stubLocationDelegate: NSObject, CLLocationManagerDelegate {
            func locationManagerDidChangeAuthorization(_: CLLocationManager) {}

            func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}

            func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
        }

    #endif

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    /// Restarts the service inside the same command server.
    ///
    /// This is deliberately not a place the screen-state observer is touched. A reload replaces the
    /// running config, not the process or the command server, and re-registering the notifications
    /// here would leave the previous tokens behind and hand the core a second, independent device
    /// axis. The observer outlives a reload by construction - see `startScreenStateObserver` and
    /// `stopScreenStateObserver`, which are the only two call sites and are both in the tunnel
    /// lifecycle.
    func reloadService() async throws {
        writeMessage("(packet-tunnel) reloading service")
        reasserting = true
        defer {
            reasserting = false
        }
        try await startService()
    }

    override open func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        #if os(iOS)
            // Before the command server, and before `stopService()`. The observer publishes into
            // the server through a weak reference, and `cancel()` fences the callbacks
            // synchronously, so nothing can reach the core once this returns.
            stopScreenStateObserver()
        #endif
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
        #if os(macOS)
            if Variant.useSystemExtension {
                xpcService.markServiceNotReady(NSError(domain: "CommandXPC", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Command server stopped",
                ]))
                xpcListener.invalidate()
                xpcListener = nil
                xpcService.commandServer = nil
                xpcService = nil
                UserServiceEndpointRegistry.shared.clear()
            }
            locationManager = nil
            locationDelegate = nil
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        do {
            let options = try ExtensionStartOptions.decode(messageData)
            try applyStartOptions(options)
            try persistStartOptions(options)
            try await reloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    /// The process is going to sleep.
    ///
    /// `pause()` publishes the sleep EDGE and then the LEVEL: on iOS the level is entered once and
    /// lifted by an unlock, so a level-only pause would leave the next sleep unmeasured.
    override open func sleep() async {
        if let commandServer {
            commandServer.pause()
        }
    }

    /// The process ran again.
    ///
    /// `wake()` is an EDGE only on iOS - the platform resumes the extension for every push and
    /// background task, and letting a resume lift the device pause would release health checks,
    /// probes and statistics for a phone in a pocket.
    ///
    /// A resume is also the one moment the process knows it was suspended, and Darwin notifications
    /// are not delivered to a suspended process: a lock that happened while the extension was away
    /// was never delivered. `resync()` re-reads both names once so that lock is not lost. It is not
    /// a poll, nothing schedules it, and a snapshot may only publish a sleep fact - so it can add a
    /// pause and can never invent a wake.
    override open func wake() {
        if let commandServer {
            commandServer.wake()
        }
        #if os(iOS)
            screenStateObserver?.resync()
        #endif
    }
}
