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
        let snapshot = StartSnapshot(
            profileID: profileID,
            requestID: UUID().uuidString,
            bodyRevision: ConfigurationBodyRevision.fingerprint(of: content),
            configContent: content
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
                  expectedBodyRevision: snapshot.bodyRevision
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

        public init(profileID: Int64, requestID: String, bodyRevision: String, configContent: String) {
            self.profileID = profileID
            self.requestID = requestID
            self.bodyRevision = bodyRevision
            self.configContent = configContent
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
        let response = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        switch ExtensionApplyReceiptParser.parse(response, expecting: snapshot.requestID) {
        case let .receipt(receipt):
            return receipt
        case .noReceipt, .otherRequest, .unreadable:
            // Not attributable to this request, so this call has no answer of its own. The caller
            // reports it as unconfirmed; nothing is retried and nothing is rolled back.
            return nil
        }
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

    public func stop() async throws {
        if isMock {
            status = .disconnecting
            try await Task.sleep(nanoseconds: 300_000_000)
            status = .disconnected
            connectedDate = nil
            return
        }
        guard let manager else { return }
        if manager.isOnDemandEnabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                config["wasOnDemandEnabled"] = true
                proto.providerConfiguration = config
            }
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibboxNewStandaloneCommandClient()!.serviceClose()
            }.value
        } catch {
            logger.debug("serviceClose error: \(error.localizedDescription)")
        }
        manager.connection.stopVPNTunnel()
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
