import Foundation
import Libbox
import NetworkExtension
import os
#if os(iOS)
    import FileProvider
#endif

private let logger = Logger(category: "ExtensionProfile")

@MainActor
public class ExtensionProfile: ObservableObject {
    public static let controlKind = AppConfiguration.widgetControlKind

    private let manager: NEVPNManager?
    private var connection: NEVPNConnection?
    private var observer: Any?
    private let isMock: Bool

    @Published public var status: NEVPNStatus
    @Published public var connectedDate: Date?

    public init(_ manager: NEVPNManager) {
        self.manager = manager
        connection = manager.connection
        status = manager.connection.status
        connectedDate = manager.connection.connectedDate
        isMock = false
    }

    private init(mockStatus: NEVPNStatus, mockConnectedDate: Date?) {
        manager = nil
        connection = nil
        status = mockStatus
        connectedDate = mockConnectedDate
        isMock = true
    }

    private static var _mock: ExtensionProfile?

    public static var mock: ExtensionProfile {
        if _mock == nil {
            _mock = ExtensionProfile(mockStatus: .connected, mockConnectedDate: Date().addingTimeInterval(-3600))
        }
        return _mock!
    }

    public func register() {
        guard !isMock, let manager else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NEVPNStatusDidChange,
            object: manager.connection,
            queue: nil
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else {
                return
            }
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.connection = connection
                self.status = connection.status
                self.connectedDate = connection.connectedDate
                if connection.status == .disconnected {
                    Self.schedulePromoteOOMDraft()
                }
                #if os(iOS)
                    if #available(iOS 16.0, *) {
                        if connection.status == .connected || connection.status == .disconnected {
                            Self.signalFileProviderChanges()
                        }
                    }
                #endif
            }
        }
    }

    private static func schedulePromoteOOMDraft() {
        Task.detached {
            try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
            #if os(macOS)
                if Variant.useSystemExtension {
                    guard HelperServiceManager.rootHelperStatus == .enabled else {
                        return
                    }
                    do {
                        try RootHelperClient.shared.promoteOOMDraft()
                    } catch {
                        logger.warning("promote OOM draft: \(error.localizedDescription)")
                    }
                    return
                }
            #endif
            LibboxPromoteOOMDraft()
        }
    }

    #if os(iOS)
        @available(iOS 16.0, *)
        private static func signalFileProviderChanges() {
            Task.detached {
                guard let domain = try? await NSFileProviderManager.domains()
                    .first(where: { $0.identifier.rawValue == AppConfiguration.fileProviderDomainID }),
                    let manager = NSFileProviderManager(for: domain)
                else {
                    return
                }
                try? await manager.signalEnumerator(for: .workingSet)
            }
        }
    #endif

    nonisolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func makeDefaultOnDemandRules() -> [NEOnDemandRule] {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        rule.probeURL = URL(string: "http://captive.apple.com")
        return [rule]
    }

    private func setOnDemandRules(useDefaultRules: Bool) async {
        guard let manager else { return }
        if useDefaultRules {
            manager.onDemandRules = Self.makeDefaultOnDemandRules()
        } else {
            let rules = await SharedPreferences.onDemandRules.get()
            manager.onDemandRules = rules.isEmpty ? Self.makeDefaultOnDemandRules() : rules.map { $0.toNERule() }
        }
    }

    public func updateOnDemand(enabled: Bool, useDefaultRules: Bool) async throws {
        guard let manager else { return }
        manager.isOnDemandEnabled = enabled
        if !enabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
                    proto.providerConfiguration = config
                }
            }
        }
        await setOnDemandRules(useDefaultRules: useDefaultRules)
        try await manager.saveToPreferences()
    }

    private func applyProtocolConfiguration() async {
        #if !os(tvOS)
            guard let protocolConfiguration = manager?.protocolConfiguration else { return }
            protocolConfiguration.includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
            protocolConfiguration.excludeLocalNetworks = await SharedPreferences.excludeLocalNetworks.get()
            protocolConfiguration.enforceRoutes = await SharedPreferences.enforceRoutes.get()
            if #available(iOS 16.4, macOS 13.3, *) {
                protocolConfiguration.excludeAPNs = await SharedPreferences.excludeAPNs.get()
                protocolConfiguration.excludeCellularServices = await SharedPreferences.excludeCellularServices.get()
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                protocolConfiguration.excludeDeviceCommunication = await SharedPreferences.excludeDeviceCommunication.get()
            }
        #endif
    }

    public func updateProtocolConfiguration() async throws {
        guard let manager else { return }
        await applyProtocolConfiguration()
        try await manager.saveToPreferences()
    }

    @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
    public func fetchLastDisconnectError() async throws {
        guard let connection else { return }
        try await connection.fetchLastDisconnectError()
    }

    public func start() async throws {
        if isMock {
            status = .connecting
            try await Task.sleep(nanoseconds: 500_000_000)
            status = .connected
            connectedDate = Date()
            return
        }
        guard let manager else { return }
        try await fetchProfile()
        manager.isEnabled = true
        let alwaysOn = await SharedPreferences.alwaysOn.get()
        let onDemandEnabled = await SharedPreferences.onDemandEnabled.get()
        manager.isOnDemandEnabled = alwaysOn || onDemandEnabled
        if manager.isOnDemandEnabled {
            await setOnDemandRules(useDefaultRules: alwaysOn)
        }
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            var config = proto.providerConfiguration ?? [:]
            if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
                proto.providerConfiguration = config
            }
        }
        await applyProtocolConfiguration()
        try await manager.saveToPreferences()
        let options = try await prepareStartOptions()
        try manager.connection.startVPNTunnel(options: options)
    }

    /// Applies whatever is currently selected, and confirms it with the extension's receipt.
    ///
    /// # Why this is no longer "send and check for an empty answer"
    ///
    /// The extension used to answer `nil` on success and an error string on failure, so this entry
    /// treated any non-empty answer as a failure. That contract changed: every exit of
    /// `handleAppMessage` now answers with a receipt envelope, INCLUDING success - so the old rule
    /// would have thrown a JSON document at every caller on every successful reload. There are six
    /// production callers (the two shortcut intents, the macOS status bar, the dashboard's profile
    /// switch and the two override panels), and none of them may tell the user an apply failed when
    /// it worked.
    ///
    /// The answer is read the same way the profile path reads it: build the snapshot from the
    /// selection, and throw only when the outcome is not "the requested document is running".
    public func reloadService() async throws {
        guard !isMock else {
            return
        }
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw NSError(domain: "ExtensionProfile", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing selected profile",
            ])
        }
        let content = try await profile.readAsync()
        // A reload goes to a session that already exists. Naming it before the send is what lets
        // the extension refuse a request built for a session that has since stopped, and lets the
        // receipt be checked against the session this call actually addressed. An extension that
        // predates the identity query answers nothing, so the snapshot keeps the old shape.
        let expectedSessionID = await currentTunnelSessionID()
        let snapshot = StartSnapshot(
            profileID: profileID,
            requestID: UUID().uuidString,
            bodyRevision: ConfigurationBodyRevision.fingerprint(of: content),
            configContent: content,
            expectedSessionID: expectedSessionID
        )
        // The SAME attribution the profile path uses: a receipt only counts when it names this
        // request, this profile and this body. Matching the request id alone would accept a reply
        // about another profile's document, and that is the one mistake this entry can make that the
        // user cannot see.
        let ticket = ProfileUpdateTicket(
            profileID: snapshot.profileID,
            requestID: snapshot.requestID,
            remoteURL: profile.remoteURL,
            storedBodyRevision: snapshot.bodyRevision
        )
        let receipt = try await reloadService(snapshot)
        guard let receipt,
              case let .matches(matched) = ProfileUpdateOwnership.ownership(
                  of: receipt,
                  ticket: ticket,
                  expectedBodyRevision: snapshot.bodyRevision,
                  expectedSessionID: expectedSessionID
              )
        else {
            // No receipt this call can attribute to itself. Reporting success would claim an apply
            // nothing confirmed; reporting a failure would claim the opposite. The caller only has
            // "throw or not", so it throws - and the message says exactly that.
            throw ExtensionApplyError(message: String(localized: "the extension did not confirm the configuration"))
        }
        try Self.confirmApplied(matched.outcome)
    }

    /// Throws unless the outcome means the requested document is the one running.
    ///
    /// `nonisolated` because it is a pure decision over a value: the two callers that only handle
    /// errors - this legacy entry and `Profile.onProfileUpdated()` - are `nonisolated` themselves, and
    /// a synchronous call into this `@MainActor` class from one of them is a compile error, not a
    /// style question. It touches no actor state, so crossing the boundary would buy nothing.
    nonisolated static func confirmApplied(_ outcome: ExtensionApplyOutcome) throws {
        switch outcome {
        case .applied:
            return
        case .recovered:
            throw ExtensionApplyError(
                message: String(localized: "the new configuration failed and the service recovered to the saved one")
            )
        case .interrupted:
            throw ExtensionApplyError(message: String(localized: "the tunnel stopped and nothing is running"))
        case let .failed(reason, _):
            throw ExtensionApplyError(message: reason)
        case let .undetermined(reason):
            throw ExtensionApplyError(message: reason)
        }
    }

    /// One apply request, as this side defines it.
    ///
    /// The identity, the body and the caller's own fingerprint of that body travel together, because
    /// the extension echoes them back and the receipt is only usable if it names the same three
    /// things. Reading any of them separately at send time is how a reload ends up applying a body
    /// the caller did not write.
    public struct StartSnapshot: Equatable, Sendable {
        public let profileID: Int64
        public let requestID: String
        public let bodyRevision: String
        public let configContent: String
        /// The tunnel session this request is addressed to, when the caller knows it.
        ///
        /// A reload is sent to a session that already exists, and `currentTunnelSessionID()` can
        /// name it. The extension refuses the request if its own session no longer matches, which
        /// is what stops a request built for a stopped session from being applied by its
        /// replacement. A start has no session yet, so it leaves this nil and keeps the old
        /// behaviour on both sides.
        public let expectedSessionID: String?

        public init(
            profileID: Int64,
            requestID: String,
            bodyRevision: String,
            configContent: String,
            expectedSessionID: String? = nil
        ) {
            self.profileID = profileID
            self.requestID = requestID
            self.bodyRevision = bodyRevision
            self.configContent = configContent
            self.expectedSessionID = expectedSessionID
        }
    }

    /// Sends one apply request and returns the receipt the extension proved, or nil when it answered
    /// nothing this call can attribute to itself.
    ///
    /// # Why nil is a value and not a throw
    ///
    /// `sendProviderMessage` calls its handler with nil when the message could not be delivered, and
    /// an extension that predates the receipt envelope answers nil on SUCCESS. A nil answer is
    /// therefore "unconfirmed": throwing here would make the caller report a failure for an apply
    /// that may well have worked, and the caller has no way to tell.
    ///
    /// Only a transport error - no tunnel session, or the send itself failing - is thrown, because
    /// that one is a fact about this call.
    public func reloadService(_ snapshot: StartSnapshot) async throws -> ExtensionApplyReceipt? {
        if isMock {
            return nil
        }
        let options = await buildStartOptions(snapshot)
        let data = try ExtensionStartOptions.encode(options)
        guard let session = connection as? NETunnelProviderSession else {
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel session unavailable",
            ])
        }
        let response = await Self.requestProviderMessage(session, data, timeout: Self.applyReplyTimeout)
        switch ExtensionApplyReceiptParser.parse(response, expecting: snapshot.requestID, expectingSessionID: snapshot.expectedSessionID) {
        case let .receipt(receipt):
            return receipt
        case .noReceipt, .otherRequest, .otherSession, .unreadable:
            // Not attributable to this request - which includes "nothing arrived" - so this call
            // has no answer of its own. The caller reports it as unconfirmed; nothing is retried
            // and nothing is rolled back.
            return nil
        }
    }

    /// How long an apply reply is waited for before the call gives up on hearing one.
    ///
    /// A liveness bound, not a verdict. An apply that a device is genuinely working through can
    /// legitimately take several seconds - the extension's own tunnel-takeover check allows three,
    /// before the kernel's work is counted - so this is deliberately generous. What it exists to stop
    /// is the *infinite* case: `sendProviderMessage` has no timeout of its own, and a handler that is
    /// never called left this call, and every flag raised behind it, suspended for as long as the
    /// app lived. Hitting this bound means "no verifiable receipt arrived", which the caller already
    /// has a state for (`unconfirmed`); it must not be read as "the apply failed", and it must not be
    /// retried automatically.
    nonisolated static let applyReplyTimeout: TimeInterval = 15

    /// Sends one provider message and waits at most `timeout` for the reply.
    ///
    /// # Why this is not a task group
    ///
    /// The session query used to race a `withTaskGroup` continuation against `Task.sleep` and then
    /// `group.cancelAll()`. Cancelling a group does **not** resume a continuation another child is
    /// suspended in: the cancelled sleep returns, `group.next()` hands back the timeout's `nil`, and
    /// the group still cannot finish until the abandoned child finishes - which it never does when
    /// the extension does not answer. The "timeout" therefore returned early only in the case where
    /// nothing was stuck. `sendProviderMessage` also calls its handler at most once and may call it
    /// after this call has given up, so the reply has to be gated rather than merely awaited.
    ///
    /// `ProviderReplyGate` is that gate: whichever of the four paths completes first - a reply, a
    /// late reply, a throwing send, the deadline - wins, and the others become no-ops. The deadline
    /// task is cancelled when the reply wins, so it does not linger.
    ///
    /// Returns nil for "no reply this call can use", never throws: a transport failure and a missing
    /// answer are the same fact to the callers that use this, and both mean "unconfirmed".
    private nonisolated static func requestProviderMessage(
        _ session: NETunnelProviderSession,
        _ data: Data,
        timeout: TimeInterval
    ) async -> Data? {
        let gate = ProviderReplyGate()
        let deadline = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            gate.complete(nil)
        }
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            gate.wait(continuation)
            do {
                try session.sendProviderMessage(data) { response in
                    gate.complete(response)
                }
            } catch {
                logger.debug("sendProviderMessage error: \(error.localizedDescription)")
                gate.complete(nil)
            }
        }
        deadline.cancel()
        return response
    }

    /// Asks the extension which tunnel session is running, or nil when it cannot say.
    ///
    /// A reload needs the session before it can name it. The query is a normal provider message
    /// with no configuration; an extension that predates it answers a failure receipt (or nothing),
    /// which decodes to nil, and the caller then sends the reload without an expectation - the old
    /// behaviour, not a false confirmation.
    ///
    /// The timeout exists because `sendProviderMessage` has none: an extension that is starting up
    /// would otherwise hold the reload behind a query that may never be answered.
    public func currentTunnelSessionID(timeout: TimeInterval = 1.5) async -> String? {
        if isMock {
            return nil
        }
        guard let session = connection as? NETunnelProviderSession,
              let request = TunnelSessionIdentityMessage.Request().encode()
        else {
            return nil
        }
        let response = await Self.requestProviderMessage(session, request, timeout: timeout)
        return TunnelSessionIdentityMessage.Response.decode(response)
    }

    /// The start options for the currently selected profile.
    ///
    /// A start is the one place where "whatever is selected" is the right input: the user pressed
    /// connect, and the selection is what they asked to connect with.
    private func prepareStartOptions() async throws -> [String: NSObject] {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw NSError(domain: "ExtensionProfile", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing selected profile",
            ])
        }
        let configContent = try await profile.readAsync()
        return await buildStartOptions(
            StartSnapshot(
                profileID: profileID,
                requestID: UUID().uuidString,
                bodyRevision: ConfigurationBodyRevision.fingerprint(of: configContent),
                configContent: configContent
            )
        )
    }

    /// The start options for one explicit snapshot.
    ///
    /// Everything about the platform that the extension needs, plus the request identity the receipt
    /// echoes. Nothing here re-reads the selection: the caller's snapshot IS the request.
    private func buildStartOptions(_ snapshot: StartSnapshot) async -> [String: NSObject] {
        var options: [String: NSObject] = [
            "manualStart": NSNumber(value: true),
            "locale": NSString(string: ApplicationLocale.preferredIdentifier),
            "requestID": NSString(string: snapshot.requestID),
            "profileID": NSNumber(value: snapshot.profileID),
            "bodyRevision": NSString(string: snapshot.bodyRevision),
            "configContent": NSString(string: snapshot.configContent),
        ]
        // Only a caller that actually knows the session names one. An old extension ignores the
        // key; a new one refuses the request when its session no longer matches.
        if let expectedSessionID = snapshot.expectedSessionID, !expectedSessionID.isEmpty {
            options["expectedSessionID"] = NSString(string: expectedSessionID)
        }

        #if os(macOS)
            options["oomKillerEnabled"] = await NSNumber(value: SharedPreferences.oomKillerEnabled.get())
            options["oomMemoryLimitMB"] = await NSNumber(value: SharedPreferences.oomMemoryLimitMB.get())
            options["oomKillerKillConnections"] = await NSNumber(value: SharedPreferences.oomKillerKillConnections.get())
        #endif
        options["powerReportEnabled"] = await NSNumber(value: SharedPreferences.powerReportEnabled.get())
        options["systemProxyEnabled"] = await NSNumber(value: SharedPreferences.systemProxyEnabled.get())
        options["excludeDefaultRoute"] = await NSNumber(value: SharedPreferences.excludeDefaultRoute.get())
        options["autoRouteUseSubRangesByDefault"] = await NSNumber(value: SharedPreferences.autoRouteUseSubRangesByDefault.get())
        options["excludeAPNsRoute"] = await NSNumber(value: SharedPreferences.excludeAPNsRoute.get())
        #if os(iOS)
            // Only the iOS/iPadOS build has the switch; every other platform sends the key with
            // its stored default, which is false, so the extension applies nothing.
            options["localSigningLoopback"] = await NSNumber(value: SharedPreferences.localSigningLoopback.get())
        #endif

        #if !os(tvOS)
            options["includeAllNetworks"] = await NSNumber(value: SharedPreferences.includeAllNetworks.get())
        #endif

        #if os(tvOS)
            options["commandServerPort"] = await NSNumber(value: SharedPreferences.commandServerPort.get())
            options["commandServerSecret"] = await NSString(string: SharedPreferences.commandServerSecret.get())
        #endif

        return options
    }

    public func fetchProfile() async throws {
        let profileID = await SharedPreferences.selectedProfileID.get()
        if let profile = try await ProfileManager.get(profileID), profile.type == .icloud {
            _ = try await profile.readAsync()
        }
    }

    /// Asks the system to stop the tunnel. Returns once the request has been *submitted*.
    ///
    /// # Why the order of the three steps is the fix
    ///
    /// This used to clear On-Demand, then `await` a standalone command-client `serviceClose()`, and
    /// only then call `stopVPNTunnel()`. Two separate failures could therefore leave the user with
    /// no way out of a running tunnel:
    ///
    ///   * `saveToPreferences()` threw, and the function returned **before the stop was sent**. A
    ///     preference write failing is exactly the kind of thing that happens when the Network
    ///     Extension preferences are already in a bad state - the state the user is trying to leave.
    ///   * `serviceClose()` is a synchronous Go RPC that the extension answers from
    ///     `ExtensionPlatformInterface.serviceStop()` -> `ExtensionProvider.stopService()`, which
    ///     takes the provider's `serviceLifecycleLock`. A reload holds that same lock across
    ///     `commandServer.applyServiceChangeReport()` - an unbounded call that opens the TUN and
    ///     waits for the platform's network settings. When the apply was slow or wedged, this call
    ///     waited with it, and the system stop request behind it was never sent. That is the
    ///     "the VPN is stuck and only another VPN can take the slot back" report.
    ///
    /// So the system stop request goes out **first and unconditionally**: it needs nothing from the
    /// core, and nothing before it may throw. Disabling On-Demand still has to happen before the
    /// request, because the system re-establishes a tunnel that On-Demand still wants up - but a
    /// failure to persist it is *reported* rather than *returned early on*.
    ///
    /// `stopVPNTunnel()` only submits the request. This function deliberately does not claim the
    /// tunnel is down; callers observe `status`, and the caller that shows progress must be able to
    /// distinguish "requested" from "disconnected".
    public func stop() async throws {
        if isMock {
            status = .disconnecting
            try await Task.sleep(nanoseconds: 300_000_000)
            status = .disconnected
            connectedDate = nil
            return
        }
        guard let manager else { return }

        // Before the stop request, because On-Demand would otherwise start it again. Not allowed to
        // prevent the request.
        var onDemandFailure: Error?
        if manager.isOnDemandEnabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                config["wasOnDemandEnabled"] = true
                proto.providerConfiguration = config
            }
            manager.isOnDemandEnabled = false
            do {
                try await manager.saveToPreferences()
            } catch {
                onDemandFailure = error
                logger.warning("stop: could not persist On-Demand off: \(error.localizedDescription)")
            }
        }

        // The user's exit. Nothing above may prevent it and nothing below may delay it.
        manager.connection.stopVPNTunnel()

        // Best effort, and after the request: ask the core to close its service so the provider
        // shuts down promptly instead of waiting for its own `stopTunnel()`. Not awaited - the call
        // is a synchronous FFI that cannot be cancelled, so awaiting it is what used to gate the
        // stop. `requestServiceClose()` de-duplicates, so a second stop cannot pile a second blocked
        // RPC on top of the first.
        requestServiceClose()

        if let onDemandFailure {
            throw NSError(domain: "ExtensionProfile", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "The VPN was asked to disconnect, but On-Demand could not be switched off, so the system may reconnect it."
                ) + " " + onDemandFailure.localizedDescription,
            ])
        }
    }

    /// One in-flight best-effort `serviceClose()`, or nil.
    ///
    /// A slot rather than a `Task.detached` per press: the call is a synchronous Go RPC into the
    /// extension and cannot be cancelled, so an unbounded number of them is an unbounded number of
    /// threads waiting on the provider's lifecycle lock. A call that never returns deliberately keeps
    /// the slot occupied - the retry would hang the same way, and the system stop request that
    /// actually ends the tunnel has already been sent.
    private var serviceCloseTask: Task<Void, Never>?

    private func requestServiceClose() {
        guard serviceCloseTask == nil else {
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            do {
                // The force-unwrap this replaces is removed on purpose: `stop()` runs on the path a
                // user takes to get *out* of a broken tunnel, and a nil command client there was a
                // trap that killed the app before `stopVPNTunnel()` could be reached.
                guard let client = LibboxNewStandaloneCommandClient() else {
                    logger.debug("serviceClose: no standalone command client")
                    return
                }
                try client.serviceClose()
            } catch {
                logger.debug("serviceClose error: \(error.localizedDescription)")
            }
        }
        serviceCloseTask = task
        // Release the slot once the call returns, so a later stop can try again. The comparison
        // keeps a slow completion from clearing a slot a newer request has since taken.
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self, self.serviceCloseTask == task else {
                return
            }
            self.serviceCloseTask = nil
        }
    }

    public func restart() async throws {
        try await stop()
        var waitSeconds = 0
        while status != .disconnected {
            try await Task.sleep(nanoseconds: NSEC_PER_SEC)
            waitSeconds += 1
            if waitSeconds >= 5 {
                throw NSError(domain: "ExtensionProfile", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Restart service timeout")])
            }
        }
        try await start()
    }

    public static func load() async throws -> ExtensionProfile? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if managers.isEmpty {
            return nil
        }
        let profile = ExtensionProfile(managers[0])
        if profile.status == .disconnected {
            schedulePromoteOOMDraft()
        }
        return profile
    }

    public static func install() async throws {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = Variant.applicationName
        let tunnelProtocol = NETunnelProviderProtocol()
        if Variant.useSystemExtension {
            tunnelProtocol.providerBundleIdentifier = AppConfiguration.systemExtensionBundleID
        } else {
            tunnelProtocol.providerBundleIdentifier = AppConfiguration.extensionBundleID
        }
        tunnelProtocol.serverAddress = "sing-box"
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await manager.saveToPreferences()
    }
}

/// Lets one async reply be completed exactly once, from any of several racing sources.
///
/// `sendProviderMessage` invokes its handler at most once, on an arbitrary queue, and may never
/// invoke it at all. Awaiting it through a bare `withCheckedContinuation` therefore has two failure
/// modes that are not the caller's to handle: a reply that never arrives suspends the caller
/// forever, and a reply that arrives *after* a timeout has already resumed it is a second resume -
/// which is a `CheckedContinuation` misuse trap, not an error.
///
/// So the continuation is stored rather than captured, and both entry points are funnelled through
/// one lock: `wait` installs it (or answers immediately if the outcome is already known), `complete`
/// resolves it (or records the outcome for a `wait` that has not happened yet). Whichever path runs
/// first wins; the rest are no-ops. `@unchecked Sendable` because the lock is the whole point -
/// every stored field is read and written only under it.
private final class ProviderReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var isCompleted = false
    private var completion: Data?

    func wait(_ continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        if isCompleted {
            let value = completion
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func complete(_ value: Data?) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        completion = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
