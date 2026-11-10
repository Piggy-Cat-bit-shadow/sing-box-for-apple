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

    /// Identifies this tunnel SESSION, not this process.
    ///
    /// A reload keeps it - the TUN, the Box and the process are the same. A new session gets a new
    /// one, so a receipt from a previous session is recognisable as belonging to a tunnel that no
    /// longer exists. That is the third identity the app needs: the request, the body it applied and
    /// the tunnel that applied it.
    private var tunnelSessionID = UUID().uuidString

    /// The platform settings the system last installed for this tunnel.
    ///
    /// Set after every successful apply, and the reason a settings-only change can be detected at
    /// all: the profile document is byte-identical, the core answers "already runs this document",
    /// and only a rebuild reinstalls the routes and proxy the platform owns. Nil before the first
    /// apply - see `PlatformSettingsPolicy.change(from:to:)` for why that is not a rebuild.
    private var appliedPlatformSettings: PlatformSettingsSnapshot?

    /// Serialises the service lifecycle so a teardown cannot overlap a start.
    ///
    /// # Why this is needed, and why it is not an actor
    ///
    /// The core reaches `stopService()` **synchronously from a gRPC handler goroutine**, not from a
    /// NetworkExtension entry point: `ExtensionPlatformInterface.serviceStop()` calls
    /// `tunnel.stopService()` on whatever thread is running the handler. `stopTunnel` calls it too, on
    /// the tunnel's task. Nothing serialised those two, and the damage is not the double call itself:
    ///
    ///   * `stopService()` ends in `platformInterface.reset()`, which cancels and nils `nwMonitor`.
    ///     A reload's `startService()` installs a **fresh** monitor in
    ///     `ExtensionPlatformInterface.startDefaultInterfaceMonitor`, and that method blocks on a
    ///     semaphore until the monitor's first path update - so the window between "the new monitor is
    ///     assigned" and "the new monitor has delivered" is not short. A `reset()` landing in it
    ///     cancels the live monitor, and the next `getInterfaces()` throws "NWMonitor not started" with
    ///     nothing to repair it.
    ///   * Two concurrent `stopService()` calls run `reset()` twice over the same four unsynchronised
    ///     statements.
    ///
    /// Reachability does not rest on whether NetworkExtension permits its own callbacks to overlap,
    /// which is why this is fixed rather than listed as device-only: the gRPC path is an independent
    /// thread by construction, and a reload can be in flight while it arrives.
    ///
    /// A lock rather than an actor or a state machine, because the protected region is a direct call
    /// into the core plus a handful of assignments - there is nothing to suspend on, so the smallest
    /// correct mechanism is the one that adds no new lifecycle concept.
    private let serviceLifecycleLock = NSLock()
    /// Bumped by every start attempt and by every stop. A start that is about to wait for the tunnel
    /// takeover compares it after each sleep, so a stop is not blocked behind that wait and a stopped
    /// attempt cannot be mistaken for the current one. Guarded by `serviceLifecycleLock`.
    private var serviceLifecycleGeneration: UInt64 = 0

    #if os(iOS)
        /// The takeover check runs once per NEW start attempt. It is reset when a fresh tunnel session
        /// starts (never on a reload), so a reused provider instance cannot accept the previous
        /// session's applied settings as evidence for the new one.
        private var tunnelTakeoverChecked = false
    #endif

    /// The address the switch asks the tunnel to answer for locally.
    ///
    /// One constant, in one place: the core merges whatever the platform lists, and the Apple
    /// Network Extension installs a host route for the same list, so the two halves cannot drift
    /// by editing one of them.
    public static let localSigningLoopbackAddress = "10.7.0.1"

    public struct OverridePreferences {
        public var includeAllNetworks: Bool = false
        public var systemProxyEnabled: Bool = true
        public var excludeDefaultRoute: Bool = false
        public var autoRouteUseSubRangesByDefault: Bool = false
        public var excludeAPNsRoute: Bool = false
        /// The local signing loopback switch. Startup options only: false for every build that
        /// does not send the key, which is every non-iOS one.
        public var localSigningLoopback: Bool = false
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
            excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false,
            localSigningLoopback: (options["localSigningLoopback"] as? NSNumber)?.boolValue ?? false
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
                "localSigningLoopback": overridePreferences.localSigningLoopback,
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
        // A new tunnel session, even when the platform reuses this provider instance.
        tunnelSessionID = UUID().uuidString
        appliedPlatformSettings = nil

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

        #if os(iOS)
            // The App Group is what lets this process and the app share a container. A re-signed
            // build whose profile does not grant it runs here with a private one: the tunnel and
            // the VPN work (the configuration arrives in the start options), but the app's
            // statistics and command channel cannot reach this process, and the command socket
            // lives in this process's own temporary directory.
            //
            // Saying so is the difference between "the statistics are broken" and "this build's
            // signature cannot give me statistics".
            if FilePath.isUsingProcessLocalDirectory {
                writeMessage(
                    "(packet-tunnel) the App Group is unavailable to this build; running with a private container. VPN traffic works, but the app's statistics and command channel cannot reach this process. Re-sign with a provisioning profile that grants the group to restore them.",
                    level: .info
                )
            }
        #endif

        // Everything from here to the end of this function is the start TRANSACTION, and it is
        // wrapped so that a failure unwinds what it created instead of leaving it live.
        //
        // Before this, every failure below threw without releasing anything. `commandServer` was
        // left created and - after `start()` returned - listening on `command.pb`, with the Go side's
        // power-report worker and OOM recorder already running and nothing left to stop them. On
        // macOS the XPC listener had been resumed, so the app's command channel pointed at a server
        // whose service never started and which no `stopTunnel` would be told about.
        //
        // # Why a `do/catch` and not `defer` plus a flag
        //
        // The successful path must NOT unwind, and a `catch` says that in the shape of the code
        // rather than in a boolean. On failure the order is the one `stopTunnel` uses, for the same
        // reason: the observer first (it publishes into the server), then the service, then the
        // server, then the platform interface.
        do {
            try await startTunnel0()
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
        } catch {
            #if os(macOS)
                if Variant.useSystemExtension {
                    xpcService.markServiceNotReady(error)
                }
            #endif
            unwindFailedStart()
            throw error
        }
    }

    /// The half of `startTunnel` that runs once the command server exists.
    ///
    /// Split out so the caller can hold the whole thing in one `do/catch`: there is no way to write
    /// that block around the inline version without either indenting the entire function or giving
    /// the failures a shared label.
    private func startTunnel0() async throws {
        guard let commandServer else {
            throw ExtensionStartupError("(packet-tunnel): command server was not created")
        }
        do {
            try commandServer.start()
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

        _ = try await startService()
        writeMessage("(packet-tunnel): Here I stand")
        #if os(iOS)
            startScreenStateObserver()
        #endif
    }

    /// Releases what a failed `startTunnel` created, in the order `stopTunnel` releases it.
    ///
    /// Idempotent and safe when only part of the start ran: every step tolerates its resource being
    /// absent. `commandServer` is cleared last, so the closing calls can still reach it.
    ///
    /// This is not a substitute for `stopTunnel` - it deliberately does not touch the XPC listener or
    /// the location manager, which belong to the macOS entry points and are torn down there - it only
    /// guarantees that a throw leaves no live command server, no registered notifications and no
    /// platform state pointing at a service that never started.
    private func unwindFailedStart() {
        #if os(iOS)
            stopScreenStateObserver()
        #endif
        stopService()
        commandServer?.close()
        commandServer = nil
    }

    func writeMessage(_ message: String, level: LogLevel = .error) {
        if let commandServer {
            commandServer.writeMessage(Int32(level.rawValue), message: message)
        }
    }

    /// Runs `body` with the lifecycle lock held, and nothing else. Keeping this a function rather
    /// than a `defer` at the call site is what makes it visible that the takeover wait below is
    /// outside the protected region.
    private func withServiceLifecycleLock<T>(_ body: () throws -> T) rethrows -> T {
        serviceLifecycleLock.lock()
        defer { serviceLifecycleLock.unlock() }
        return try body()
    }

    #if os(iOS)
        private enum TunnelTakeoverResult {
            case applied
            case timedOut
            case superseded
        }

        /// Waits for the platform interface to install this attempt's network settings.
        ///
        /// The wait is outside `serviceLifecycleLock`: it can last three seconds, and a concurrent
        /// `stopService()` - reachable synchronously from the core's gRPC goroutine - must not sit
        /// behind it. The generation check is what keeps that safe: a stop (or a newer start) bumps
        /// the generation, this call returns `.superseded`, and the caller reports that instead of
        /// accepting a flag an older attempt set.
        private func waitForTunnelTakeover(generation: UInt64) async -> TunnelTakeoverResult {
            for _ in 0 ..< 30 {
                // Check the generation FIRST: if a stop landed after an old attempt applied its
                // settings, the stale success must not be accepted as this attempt's evidence.
                let isCurrent = withServiceLifecycleLock { generation == serviceLifecycleGeneration }
                if !isCurrent {
                    return .superseded
                }
                if ExtensionPlatformInterface.didApplyTunnelNetworkSettings {
                    return .applied
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let isCurrent = withServiceLifecycleLock { generation == serviceLifecycleGeneration }
            if !isCurrent {
                return .superseded
            }
            return ExtensionPlatformInterface.didApplyTunnelNetworkSettings ? .applied : .timedOut
        }
    #endif

    /// Starts (or reloads) the service inside the running command server.
    ///
    /// # Why the server is a `guard` and not a force-unwrap
    ///
    /// This used to be `commandServer!.startOrReloadService(...)`, the only force-unwrap of that
    /// property in the file. It is reachable with `commandServer == nil`, on two paths that need no
    /// exotic timing:
    ///
    ///   * `stopTunnel` sets `commandServer = nil` (its own assignment inside the shutdown block, now
    ///     guarded by an identity check so it cannot nil a server a concurrent start installed), and
    ///     the guard above the call reads `tunnelOptions` - which `stopTunnel` never clears. A
    ///     `handleAppMessage` that arrives
    ///     during or after a stop therefore passes the guard and traps.
    ///   * `startTunnel` sets `tunnelOptions` (`:201`) before it creates the server (`:250`), so a
    ///     start that fails in between leaves exactly that state behind.
    ///
    /// A trap in the extension is not a caught error: it kills the provider process, which is the one
    /// outcome this whole file is arranged to avoid, and on the device it is indistinguishable from
    /// "the tunnel stopped working". The other two uses of `commandServer` in this function's family
    /// are folded in for the same reason.
    ///
    /// # Why the apply goes through the report entry
    ///
    /// `startOrReloadService` returns an error or nothing, and an interrupted or recovered apply
    /// returns NOTHING - so the extension could not tell "my document is running" from "the daemon
    /// recovered to another one". `applyServiceChangeReport` returns the report the call itself
    /// produced, which is what the receipt the app reads is built from. The error-only contract is
    /// kept in the kernel for every other embedder; this one no longer needs it.
    ///
    /// - Parameter reinstallsPlatformSettings: true when this apply is happening because the
    ///   platform's own settings changed. The document may be identical, so the core will satisfy
    ///   the request in place and never call `openTun`; the platform half must therefore be treated
    ///   as a NEW install and confirmed with the takeover check.
    private func startService(isReload: Bool = false, reinstallsPlatformSettings: Bool = false) async throws -> LibboxApplyOutcomeDocument? {
        guard let configContent = tunnelOptions?["configContent"] as? String else {
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }
        guard let commandServer else {
            // Not `ExtensionStartupError`: this is the ordinary "the server is gone" case, and the
            // caller's `handleAppMessage` catch turns it into a message for the app rather than a
            // process death. `reloadService` rethrows it, so `reasserting` is still restored by its
            // `defer`.
            throw ExtensionStartupError("(packet-tunnel) error: command server is not running")
        }

        let options = LibboxOverrideOptions()
        #if os(iOS)
            // The local signing loopback address is injected into this run's in-memory
            // configuration, never into the profile file. Turning the switch off and reloading
            // therefore leaves the user's configuration exactly as they wrote it, and the core
            // only ever sees the address while the switch is on.
            if overridePreferences?.localSigningLoopback == true {
                options.loopbackAddress = [Self.localSigningLoopbackAddress].toStringIterator()
            }
        #endif
        #if os(iOS)
            // A new tunnel session must not inherit the previous session's success. A reload keeps
            // the running TUN and deliberately does not re-check - unless it is reinstalling the
            // platform's settings, which is exactly what the check exists to confirm.
            if !isReload || reinstallsPlatformSettings {
                tunnelTakeoverChecked = false
                ExtensionPlatformInterface.resetTunnelTakeoverCheck()
            }
        #endif
        // Held only across the apply and the generation bump. The takeover wait below is NOT in this
        // region: it can take three seconds, and `stopService()` (called from the core's gRPC
        // goroutine) must not block behind it. The generation makes that safe.
        var generation: UInt64 = 0
        var document: LibboxApplyOutcomeDocument?
        do {
            try withServiceLifecycleLock {
                serviceLifecycleGeneration &+= 1
                generation = serviceLifecycleGeneration
                guard let box = commandServer.applyServiceChangeReport(configContent, options: options) else {
                    throw ExtensionStartupError("(packet-tunnel) the command server returned no apply report")
                }
                document = LibboxApplyOutcomeDocument.decode(box.value)
            }
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: start service: \(error.localizedDescription)")
        }
        guard let document, let result = document.outcomeStatus else {
            // The bridge answered something this build cannot read. Treating that as success is the
            // one option that must not be taken: the app would show a configuration that nothing
            // confirmed.
            throw ExtensionStartupError("(packet-tunnel) the apply report could not be read")
        }
        if document.ok == false, result != .recovered {
            // `recovered` is not a failure: the daemon is running the stored last-good document, and
            // the tunnel works. Every other not-ok status means the requested document is not what
            // runs.
            throw ExtensionStartupError(document.error ?? "(packet-tunnel) the configuration was not applied")
        }
        #if os(iOS)
            // A tunnel that started but never asked the system to route through it is connected and
            // carries nothing, and nothing reports it: the NE session stays up, the start call
            // returned without error, and the app has no shared container from which to read this
            // process's log. The check costs at most three seconds on the first start and turns that
            // silent state into an error the system shows the user.
            if !tunnelTakeoverChecked {
                switch await waitForTunnelTakeover(generation: generation) {
                case .applied:
                    tunnelTakeoverChecked = true
                case .superseded:
                    throw ExtensionStartupError(
                        "(packet-tunnel) the start was superseded by a stop or another start while waiting for network settings"
                    )
                case .timedOut:
                    let hasTunInbound = configContent.contains("\"tun\"")
                    throw ExtensionStartupError(
                        "(packet-tunnel) the tunnel is connected but the core never took it over: no network settings were applied within 3s. "
                            + "config mentions a tun inbound: \(hasTunInbound); config bytes: \(configContent.utf8.count)"
                    )
                }
            }
        #endif
        #if os(macOS)
            if !Variant.useSystemExtension, commandServer.needWIFIState() {
                locationManager = CLLocationManager()
                locationDelegate = stubLocationDelegate()
                locationManager!.delegate = locationDelegate
                locationManager!.requestLocation()
            }
        #endif
        // What the system now has installed. Recorded even for the initial start: without it the
        // first reload would compare against "unknown", and "unknown" is deliberately not a rebuild.
        if let tunnelOptions {
            appliedPlatformSettings = platformSettings(tunnelOptions)
        }
        return document
    }

    #if os(macOS)

        class stubLocationDelegate: NSObject, CLLocationManagerDelegate {
            func locationManagerDidChangeAuthorization(_: CLLocationManager) {}

            func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}

            func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
        }

    #endif

    func stopService() {
        // Single-entry, and mutually exclusive with `startService()`. See `serviceLifecycleLock`:
        // `reset()` cancels a monitor that a concurrent start has just installed and is still waiting
        // on, and this is reachable from the core's gRPC goroutine without any NetworkExtension
        // reentrancy assumption.
        serviceLifecycleLock.lock()
        // Invalidate any start that is currently waiting for the takeover outside the lock: it must
        // report that it was superseded, not accept a flag that an older attempt set.
        serviceLifecycleGeneration &+= 1
        defer { serviceLifecycleLock.unlock() }
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
        _ = try await startService(isReload: true)
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
        // # Why this identity check is load-bearing
        //
        // `if let server = commandServer` captures the CURRENT server, and the `Task.sleep` below is a
        // suspension point: the extension's actor can run another task during it. If a new
        // `startTunnel` completes in that window it creates and starts a NEW command server and
        // assigns it to this same property - and the unconditional `commandServer = nil` that used to
        // be here would then have (a) closed the new, healthy server and (b) dropped the only
        // reference to it. The tunnel would be running with a closed command server, so the app's
        // channel to it dies, `reloadService` starts failing, and a later `stopTunnel` would find
        // `commandServer == nil` and skip the cleanup entirely - leaking whatever the new start built.
        //
        // The same reasoning applies to the macOS block below: `xpcListener.invalidate()`,
        // `xpcService = nil` and the command-server release are all "tear down the surface I owned", so they
        // are conditional on the server being the one this call captured. The earlier comment here
        // claimed this ordering was safe for macOS *because* the stop runs first; that is only true
        // when nothing started in between, which is exactly what cannot be assumed.
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            let serverIsStillCurrent = commandServer === server
            server.close()
            if serverIsStillCurrent {
                commandServer = nil
                #if os(macOS)
                    if Variant.useSystemExtension {
                        xpcService.markServiceNotReady(NSError(domain: "CommandXPC", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "Command server stopped",
                        ]))
                        xpcListener.invalidate()
                        xpcListener = nil
                        xpcService.commandServer = nil
                        xpcService = nil
                    }
                #endif
            } else {
                Self.logger.info("stopTunnel: a new command server was installed during the stop; releasing the previous one only")
            }
        }
        #if os(macOS)
            locationManager = nil
            locationDelegate = nil
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    /// The app's apply channel: decode the request, decide whether the platform half changed, apply,
    /// and answer with a receipt.
    ///
    /// # Why the answer is never nil
    ///
    /// `sendProviderMessage` calls its handler with nil when the message could not be delivered, so
    /// an extension that answers nil on SUCCESS makes "applied", "crashed" and "never arrived" one
    /// value to the app. Every exit from here - including a failure - answers with the envelope
    /// `ExtensionApplyReceiptParser` decodes.
    ///
    /// # Why the platform settings are compared here
    ///
    /// A switch that only moves the platform's own settings (the APNs exclusion, the default-route
    /// exclusion, `include_all_networks`) leaves the profile document byte-identical. The core then
    /// answers "already runs this document" - truthfully, for the document - and may satisfy the
    /// reload by refreshing a provider in place, so `openTun` is never called and the new routes are
    /// never installed. The change is invisible to every comparison the kernel can make, so it is
    /// made here, where the settings live.
    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        let options: [String: NSObject]
        do {
            options = try ExtensionStartOptions.decode(messageData)
        } catch {
            return encodeReceipt(
                requestID: "",
                profileID: nil,
                bodyRevision: nil,
                ok: false,
                status: ExtensionApplyStatus.failed.rawValue,
                targetRevision: nil,
                activeRevision: nil,
                retained: nil,
                restartRequired: nil,
                persistence: nil,
                reason: "(packet-tunnel) the request could not be decoded: \(error.localizedDescription)"
            )
        }
        let requestID = options["requestID"] as? String ?? ""
        let profileID = (options["profileID"] as? NSNumber)?.int64Value
        let bodyRevision = options["bodyRevision"] as? String
        guard let configContent = options["configContent"] as? String else {
            return encodeReceipt(
                requestID: requestID,
                profileID: profileID,
                bodyRevision: bodyRevision,
                ok: false,
                status: ExtensionApplyStatus.failed.rawValue,
                targetRevision: nil,
                activeRevision: nil,
                retained: nil,
                restartRequired: nil,
                persistence: nil,
                reason: "(packet-tunnel) the request carries no configuration"
            )
        }

        let candidate = platformSettings(options)
        let platformChange = PlatformSettingsPolicy.change(from: appliedPlatformSettings, to: candidate)
        var reinstallsPlatformSettings = false
        switch platformChange {
        case .unchanged:
            break
        case .proxyOnly:
            // The platform can re-apply the proxy to the installed settings; the document apply
            // below still happens, because the profile itself may have changed too.
            writeMessage("(packet-tunnel) the system proxy switch changed; it is applied to the installed settings", level: .info)
            // A no-op when the installed settings carry no proxy: that is the same state the switch
            // describes.
            try? platformInterface.setSystemProxyEnabled(candidate.systemProxyEnabled)
        case let .needsRebuild(keys):
            reinstallsPlatformSettings = true
            writeMessage(
                "(packet-tunnel) the platform settings changed (\(keys.joined(separator: ", "))); the tunnel is rebuilt so the system reinstalls them",
                level: .info
            )
        }

        do {
            try applyStartOptions(options)
            try persistStartOptions(options)
        } catch {
            return encodeReceipt(
                requestID: requestID,
                profileID: profileID,
                bodyRevision: bodyRevision,
                ok: false,
                status: ExtensionApplyStatus.failed.rawValue,
                targetRevision: nil,
                activeRevision: nil,
                retained: nil,
                restartRequired: nil,
                persistence: nil,
                reason: "(packet-tunnel) the request could not be applied: \(error.localizedDescription)"
            )
        }

        do {
            let document = try await performApply(reinstallsPlatformSettings: reinstallsPlatformSettings)
            appliedPlatformSettings = candidate
            return encodeReceipt(
                requestID: requestID,
                profileID: profileID,
                bodyRevision: bodyRevision,
                ok: document?.ok ?? false,
                status: document?.status ?? ExtensionApplyStatus.failed.rawValue,
                targetRevision: document?.report?.plan?.targetRevision,
                activeRevision: document?.report?.activeRevision,
                retained: document?.report?.retained,
                restartRequired: document?.report?.restartRequired,
                persistence: document?.report?.persistence,
                reason: document?.report?.reason ?? document?.error
            )
        } catch {
            return encodeReceipt(
                requestID: requestID,
                profileID: profileID,
                bodyRevision: bodyRevision,
                ok: false,
                status: ExtensionApplyStatus.failed.rawValue,
                targetRevision: nil,
                activeRevision: nil,
                retained: nil,
                restartRequired: nil,
                persistence: nil,
                reason: error.localizedDescription
            )
        }
    }

    /// One apply attempt, holding `reasserting` across a rebuild.
    ///
    /// `defer` runs at the end of its enclosing SCOPE, so the flag is set and cleared in a function
    /// of its own: inside the `if` it would be cleared the moment the close returned, which is
    /// exactly the gap the app draws as "the tunnel came back" while nothing is running.
    private func performApply(reinstallsPlatformSettings: Bool) async throws -> LibboxApplyOutcomeDocument? {
        reasserting = reinstallsPlatformSettings
        defer {
            reasserting = false
        }
        if reinstallsPlatformSettings {
            writeMessage("(packet-tunnel) reloading service (rebuild)", level: .info)
            // Close first: the core's own restart path would also close the old Box, but the
            // document is IDENTICAL here, so it would take the live path instead and never ask the
            // platform to open a TUN. Closing is what makes the next apply a fresh start.
            stopService()
        }
        return try await startService(
            isReload: !reinstallsPlatformSettings,
            reinstallsPlatformSettings: reinstallsPlatformSettings
        )
    }

    /// The platform settings an apply would install, as one comparable value.
    ///
    /// Both halves are here because both reach the system: the protocol configuration is what iOS
    /// routes on, and the start options carry the platform's own route and proxy decisions.
    private func platformSettings(_ options: [String: NSObject]) -> PlatformSettingsSnapshot {
        var snapshot = PlatformSettingsSnapshot(
            systemProxyEnabled: (options["systemProxyEnabled"] as? NSNumber)?.boolValue ?? true,
            excludeDefaultRoute: (options["excludeDefaultRoute"] as? NSNumber)?.boolValue ?? false,
            autoRouteUseSubRangesByDefault: (options["autoRouteUseSubRangesByDefault"] as? NSNumber)?.boolValue ?? false,
            excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false,
            localSigningLoopback: (options["localSigningLoopback"] as? NSNumber)?.boolValue ?? false
        )
        #if !os(tvOS)
            snapshot.includeAllNetworks = protocolConfiguration.includeAllNetworks
            snapshot.excludeLocalNetworks = protocolConfiguration.excludeLocalNetworks
            snapshot.enforceRoutes = protocolConfiguration.enforceRoutes
            if #available(iOS 16.4, macOS 13.3, *) {
                snapshot.excludeAPNs = protocolConfiguration.excludeAPNs
                snapshot.excludeCellularServices = protocolConfiguration.excludeCellularServices
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                snapshot.excludeDeviceCommunication = protocolConfiguration.excludeDeviceCommunication
            }
        #endif
        return snapshot
    }

    /// Encodes one receipt. It is the ONLY shape this extension answers with, so the app has one
    /// decoder and one set of rules.
    private func encodeReceipt(
        requestID: String,
        profileID: Int64?,
        bodyRevision: String?,
        ok: Bool,
        status: String,
        targetRevision: String?,
        activeRevision: String?,
        retained: Bool?,
        restartRequired: Bool?,
        persistence: String?,
        reason: String?
    ) -> Data? {
        let message = ExtensionApplyReceiptMessage(
            requestID: requestID,
            sessionID: tunnelSessionID,
            profileID: profileID,
            bodyRevision: bodyRevision,
            ok: ok,
            status: status,
            targetRevision: targetRevision,
            activeRevision: activeRevision,
            retained: retained,
            restartRequired: restartRequired,
            persistence: persistence,
            reason: reason
        )
        do {
            return try JSONEncoder().encode(message)
        } catch {
            Self.logger.error("encode apply receipt: \(error.localizedDescription)")
            return nil
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
