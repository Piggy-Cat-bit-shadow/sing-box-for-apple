import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public final class STUNTestViewModel: BaseViewModel, OutboundSelectable {
    @Published public var phase: Int32 = -1
    @Published public var externalAddr: String = ""
    @Published public var latencyMs: Int32 = 0
    @Published public var natMapping: Int32 = 0
    @Published public var natFiltering: Int32 = 0
    @Published public var natTypeSupported: Bool = false
    @Published public var isRunning = false
    @Published public var selectedOutbound: String = ""

    @Published public var server: String = LibboxSTUNDefaultServer {
        didSet {
            guard !isLoadingPreferences else { return }
            saveServerTask?.cancel()
            saveServerTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await SharedPreferences.stunServer.set(server)
            }
        }
    }

    private var isLoadingPreferences = false
    private var saveServerTask: Task<Void, Never>?
    private var standaloneTest: LibboxSTUNTest?
    private var stunSession: LibboxSTUNTestSession?
    private var runningTask: Task<Void, Never>?
    /// Who owns the test while the core is still answering with its session handle.
    private var ownership = SubscriptionOwnership()

    public func loadPreferences() async {
        isLoadingPreferences = true
        let saved = await SharedPreferences.stunServer.get()
        if !saved.isEmpty {
            server = saved
        }
        isLoadingPreferences = false
    }

    public func startTest(vpnConnected: Bool) {
        phase = -1
        externalAddr = ""
        latencyMs = 0
        natMapping = 0
        natFiltering = 0
        natTypeSupported = false
        isRunning = true
        let token = ownership.begin()

        let server = server
        let outboundTag = selectedOutbound

        if vpnConnected {
            let handler = TestHandler(self)
            Task { [weak self] in
                do {
                    let session = try await Task.detached {
                        try CommandTarget.standaloneClient().startSTUNTest(server, outboundTag: outboundTag, handler: handler)
                    }.value
                    guard let self else {
                        try? session.close()
                        return
                    }
                    guard self.ownership.isCurrent(token) else {
                        // Cancelled while the core was creating the session. See
                        // `SubscriptionOwnership`: without this the test keeps running with nothing
                        // holding a handle to stop it.
                        try? session.close()
                        return
                    }
                    self.stunSession = session
                } catch {
                    guard let self, self.ownership.isCurrent(token) else { return }
                    self.isRunning = false
                    self.alert = AlertState(action: "STUN test", error: error)
                }
            }
        } else {
            // Removed force-unwrap: a nil test object is an error to report, not a trap on the path a
            // reader takes when they are not connected.
            guard let test = LibboxNewSTUNTest() else {
                isRunning = false
                alert = AlertState(errorMessage: "The STUN test could not be created")
                return
            }
            standaloneTest = test
            let handler = TestHandler(self)
            // Synchronous FFI that opens sockets; it used to run on the main actor. See the same
            // change in `NetworkQualityViewModel.startTest`.
            Task.detached(priority: .userInitiated) {
                test.start(server, handler: handler)
            }
        }
    }

    public func cancel() {
        ownership.invalidate()
        try? stunSession?.close()
        stunSession = nil
        runningTask?.cancel()
        runningTask = nil
        standaloneTest?.cancel()
        standaloneTest = nil
        isRunning = false
    }

    private final class TestHandler: NSObject, LibboxSTUNTestHandlerProtocol, @unchecked Sendable {
        private weak var viewModel: STUNTestViewModel?

        init(_ viewModel: STUNTestViewModel?) {
            self.viewModel = viewModel
        }

        func onProgress(_ progress: LibboxSTUNTestProgress?) {
            guard let progress else { return }
            let phase = progress.phase
            let externalAddr = progress.externalAddr
            let latencyMs = progress.latencyMs
            let natMapping = progress.natMapping
            let natFiltering = progress.natFiltering
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.phase = phase
                if !externalAddr.isEmpty {
                    viewModel.externalAddr = externalAddr
                }
                if latencyMs > 0 {
                    viewModel.latencyMs = latencyMs
                }
                viewModel.natMapping = natMapping
                viewModel.natFiltering = natFiltering
            }
        }

        func onResult(_ result: LibboxSTUNTestResult?) {
            guard let result else { return }
            let externalAddr = result.externalAddr
            let latencyMs = result.latencyMs
            let natMapping = result.natMapping
            let natFiltering = result.natFiltering
            let natTypeSupported = result.natTypeSupported
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.phase = LibboxSTUNPhaseDone
                viewModel.externalAddr = externalAddr
                viewModel.latencyMs = latencyMs
                viewModel.natMapping = natMapping
                viewModel.natFiltering = natFiltering
                viewModel.natTypeSupported = natTypeSupported
                viewModel.isRunning = false
                viewModel.stunSession = nil
                viewModel.runningTask = nil
                viewModel.standaloneTest = nil
            }
        }

        func onError(_ message: String?) {
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.isRunning = false
                viewModel.stunSession = nil
                viewModel.runningTask = nil
                viewModel.standaloneTest = nil
                if let message {
                    viewModel.alert = AlertState(errorMessage: message)
                }
            }
        }
    }
}
