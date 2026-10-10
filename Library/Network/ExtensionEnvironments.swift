import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

public struct AlertState: Equatable {
    public var title: String
    public var message: String
    public var primaryButton: ButtonState?
    public var secondaryButton: ButtonState?
    public var onDismiss: (() -> Void)?

    public struct ButtonState: Equatable {
        public var label: String
        public var role: ButtonRole?
        public var action: (() -> Void)?

        public init(label: String, role: ButtonRole? = nil, action: (() -> Void)? = nil) {
            self.label = label
            self.role = role
            self.action = action
        }

        public static func == (lhs: ButtonState, rhs: ButtonState) -> Bool {
            lhs.label == rhs.label && lhs.role == rhs.role
        }

        public static func `default`(_ label: String, action: (() -> Void)? = nil) -> ButtonState {
            ButtonState(label: label, action: action)
        }

        public static func cancel(_ label: String = String(localized: "Cancel"), action: (() -> Void)? = nil) -> ButtonState {
            ButtonState(label: label, role: .cancel, action: action)
        }

        public static func destructive(_ label: String, action: (() -> Void)? = nil) -> ButtonState {
            ButtonState(label: label, role: .destructive, action: action)
        }
    }

    private static func formatErrorMessage(action: String, error: Error) -> String {
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionText = normalizedAction.isEmpty ? "complete operation" : normalizedAction
        if normalizedDescription.isEmpty {
            return "Failed to \(actionText)"
        }
        return "Failed to \(actionText)\n\(normalizedDescription)"
    }

    private static func copyErrorMessage(_ text: String) {
        #if canImport(UIKit) && !os(tvOS)
            UIPasteboard.general.string = text
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private static var supportsErrorCopy: Bool {
        #if canImport(UIKit) && !os(tvOS)
            true
        #elseif canImport(AppKit)
            true
        #else
            false
        #endif
    }

    public init(action: String, error: Error, dismiss: (() -> Void)? = nil) {
        let errorMessage = Self.formatErrorMessage(action: action, error: error)
        self.init(errorMessage: errorMessage, dismiss: dismiss)
        if Self.supportsErrorCopy {
            primaryButton = .default(String(localized: "Copy")) {
                Self.copyErrorMessage(errorMessage)
            }
            secondaryButton = .default(String(localized: "Ok"), action: dismiss)
        }
    }

    public init(errorMessage: String, dismiss: (() -> Void)? = nil) {
        title = String(localized: "Error")
        message = errorMessage
        if Self.supportsErrorCopy {
            primaryButton = .default(String(localized: "Copy")) {
                Self.copyErrorMessage(errorMessage)
            }
            secondaryButton = .default(String(localized: "Ok"), action: dismiss)
        } else {
            primaryButton = .default(String(localized: "Ok"), action: dismiss)
            secondaryButton = nil
        }
        onDismiss = nil
    }

    public init(title: String, message: String, dismissButton: ButtonState? = nil) {
        self.title = title
        self.message = message
        primaryButton = dismissButton ?? .default(String(localized: "Ok"))
        secondaryButton = nil
        onDismiss = nil
    }

    public init(title: String, message: String, primaryButton: ButtonState, secondaryButton: ButtonState) {
        self.title = title
        self.message = message
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        onDismiss = nil
    }

    public init(title: String, message: String, primaryButton: ButtonState, secondaryButton: ButtonState, onDismiss: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.onDismiss = onDismiss
    }

    public static func == (lhs: AlertState, rhs: AlertState) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message &&
            lhs.primaryButton == rhs.primaryButton && lhs.secondaryButton == rhs.secondaryButton
    }
}

public extension View {
    func alert(_ binding: Binding<AlertState?>) -> some View {
        alert(
            binding.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { binding.wrappedValue != nil },
                set: { newValue, _ in
                    if !newValue {
                        binding.wrappedValue?.onDismiss?()
                        binding.wrappedValue = nil
                    }
                }
            ),
            presenting: binding.wrappedValue
        ) { alertState in
            if let secondary = alertState.secondaryButton {
                Button(role: alertState.primaryButton?.role) {
                    alertState.primaryButton?.action?()
                } label: {
                    Text(alertState.primaryButton?.label ?? "Ok")
                }
                Button(role: secondary.role) {
                    secondary.action?()
                } label: {
                    Text(secondary.label)
                }
            } else if let primary = alertState.primaryButton {
                Button(role: primary.role) {
                    primary.action?()
                } label: {
                    Text(primary.label)
                }
            }
        } message: { alertState in
            Text(alertState.message)
        }
    }
}

public struct ImportRemoteProfileRequest: Hashable, Identifiable {
    public var id: String {
        url
    }

    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

@MainActor
public class ExtensionEnvironments: ObservableObject {
    @Published public var commandClient = CommandClient([.log, .status, .groups, .clashMode])
    public let crashReportManager = CrashReportManager()
    public let oomReportManager = OOMReportManager()
    public let powerReportManager = PowerReportManager()
    public var totalUnreadReportCount: Int {
        crashReportManager.unreadCount + oomReportManager.unreadCount + powerReportManager.unreadCount
    }

    @Published public var taildropUnreadCount = 0
    @Published public var pendingTaildropEndpointTag: String?
    public var toolsBadgeCount: Int {
        totalUnreadReportCount + taildropUnreadCount
    }

    @Published public var extensionProfileLoading = true
    @Published public var extensionProfile: ExtensionProfile?
    /// Why the configuration could not be read, when it could not be.
    ///
    /// The page has drawn this line since the port - `HakoHomeView.condition` returns it and
    /// renders it under the configuration's name - and **nothing ever set it**, so the two states
    /// the page distinguishes were the same on screen: a configuration that failed to load and a
    /// tunnel that was never installed both arrived as `tunnelIsInstalled == false`.
    ///
    /// The real path is `reload()`, where `try? await ExtensionProfile.load()` throws the reason
    /// away. That is the product defect this property exists to close, and closing it for real
    /// means deciding the wording a user should see - so for now only the fixture sets it, which is
    /// what makes `test15ProfileLoadFailure` able to assert the state at all. See
    /// `docs/SNAPSHOT-FIXTURE-CONTRACT.md`.
    @Published public var profileLoadFailure: String?
    @Published public var emptyProfiles = false
    @Published public var pendingImportRemoteProfile: ImportRemoteProfileRequest?
    @Published public var remoteServer: RemoteServer?
    /// Set when a remote control session fails: the session is already torn down
    /// (back to local device), and the UI should surface this alert once.
    @Published public var remoteControlAlert: AlertState?
    private var remoteSessionHadConnected = false

    public var logSearchText = ""
    public var connectionSearchText = ""

    public let profileUpdate = ObjectWillChangePublisher()
    public let selectedProfileUpdate = ObjectWillChangePublisher()
    public let openSettings = ObjectWillChangePublisher()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        crashReportManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        oomReportManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        powerReportManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        commandClient.$isConnected
            .sink { [weak self] isConnected in
                guard isConnected else { return }
                Task { @MainActor [weak self] in
                    guard let self, remoteServer != nil else { return }
                    remoteSessionHadConnected = true
                }
            }
            .store(in: &cancellables)
        commandClient.$lastError
            .sink { [weak self] message in
                guard let message else { return }
                Task { @MainActor [weak self] in
                    self?.handleRemoteControlError(message)
                }
            }
            .store(in: &cancellables)
        if Variant.screenshotMode {
            extensionProfileLoading = false
            // The fixture's tunnel profile, unless the case is about there being none.
            // `test18HomeWithoutATunnel` drives the page a new reader sees, and the early return
            // above stops the real lookup from running either way - so "no tunnel installed" has
            // to be stated here rather than reached.
            extensionProfile = Variant.usesMockTunnelProfile ? .mock : nil
            // And the unreadable-configuration line, for the case that asks to see it. The tunnel
            // is installed here on purpose: the page reports a failed read only when it is, which
            // is what keeps the two conditions apart.
            if Variant.uiTestFixtureState == "profileError" {
                profileLoadFailure = String(localized: "The configuration could not be read.")
            }
            commandClient.setupMockData()
        }
    }

    public func postReload() {
        Task {
            await restoreRemoteControl()
            await reload()
            await crashReportManager.refresh()
            await oomReportManager.refresh()
            await powerReportManager.refresh()
        }
    }

    private var remoteControlRestored = false
    private func restoreRemoteControl() async {
        // Remote control is not available on tvOS.
        #if !os(tvOS)
            if Variant.screenshotMode {
                return
            }
            guard !remoteControlRestored else { return }
            remoteControlRestored = true
            let serverID = await SharedPreferences.activeRemoteServerID.get()
            guard serverID != 0, remoteServer == nil else { return }
            guard let server = try? await RemoteServerManager.get(serverID) else {
                await SharedPreferences.activeRemoteServerID.set(0)
                return
            }
            enterRemoteControl(server)
        #endif
    }

    public func reload() async {
        if Variant.screenshotMode {
            return
        }
        if let newProfile = try? await ExtensionProfile.load() {
            if extensionProfile == nil || extensionProfile?.status == .invalid {
                newProfile.register()
                extensionProfile = newProfile
                extensionProfileLoading = false
            }
        } else {
            extensionProfile = nil
            extensionProfileLoading = false
        }
    }

    /// Whether a service daemon (local extension or remote server) is available
    /// for command client calls.
    public var serviceAvailable: Bool {
        if remoteServer != nil {
            return true
        }
        return extensionProfile?.status.isConnectedStrict == true
    }

    public func connect() {
        if Variant.screenshotMode {
            return
        }
        if remoteServer != nil {
            if !commandClient.isConnected {
                commandClient.connect()
            }
            return
        }
        guard let profile = extensionProfile else {
            return
        }
        if profile.status.isConnected, !commandClient.isConnected {
            commandClient.connect()
        }
    }

    public func enterRemoteControl(_ server: RemoteServer) {
        CommandTarget.setRemoteServer(server)
        remoteServer = server
        remoteSessionHadConnected = false
        commandClient.disconnect()
        commandClient.lastError = nil
        commandClient.connect()
        Task {
            await SharedPreferences.activeRemoteServerID.set(server.mustID)
        }
    }

    public func exitRemoteControl() {
        guard remoteServer != nil else {
            return
        }
        CommandTarget.setRemoteServer(nil)
        remoteServer = nil
        remoteSessionHadConnected = false
        commandClient.disconnect()
        commandClient.lastError = nil
        connect()
        Task {
            await SharedPreferences.activeRemoteServerID.set(0)
        }
    }

    private func handleRemoteControlError(_ message: String) {
        guard let server = remoteServer, commandClient.lastError == message else {
            return
        }
        let description = remoteSessionHadConnected
            ? "Disconnected from remote server \(server.displayName)"
            : "Failed to connect to remote server \(server.displayName)"
        exitRemoteControl()
        remoteControlAlert = AlertState(errorMessage: "\(description)\n\(message)")
    }
}
