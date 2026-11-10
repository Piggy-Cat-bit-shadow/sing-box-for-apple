import Foundation
import Libbox

public enum CommandTarget {
    private static let lock = NSLock()
    private static var activeRemoteServer: RemoteServer?
    /// One gRPC channel per remote session: standalone calls reuse it instead of
    /// paying a TCP+TLS handshake (and leaking the connection) on every action.
    private static var sharedRemoteClient: LibboxCommandClient?

    public static var remoteServer: RemoteServer? {
        lock.lock()
        defer { lock.unlock() }
        return activeRemoteServer
    }

    public static func setRemoteServer(_ server: RemoteServer?) {
        lock.lock()
        let previousClient = sharedRemoteClient
        // The shared channel is dropped on EVERY selection change, including one that only replaces
        // the server object. That is what makes a client a reader already holds unable to start
        // talking to another daemon: the reader keeps its own client, which points at the target it
        // was resolved for, and the session gets a new one.
        sharedRemoteClient = nil
        activeRemoteServer = server
        lock.unlock()
        if let previousClient {
            try? previousClient.disconnect()
        }
    }

    public static var isRemote: Bool {
        remoteServer != nil
    }

    /// One selection of the session's target, captured together with the server it names.
    ///
    /// A token alone is not enough to READ from: resolving it later asks the session again, and a
    /// session that moved in between would answer with another server's documents while the caller
    /// still labels them with the captured target's name. A binding keeps the server object, so the
    /// read and the label are about the same daemon.
    public struct Binding {
        public let token: CommandTargetToken
        fileprivate let server: RemoteServer?
    }

    /// Captures the session's target in one step.
    public static func bind() -> Binding {
        lock.lock()
        defer { lock.unlock() }
        if let server = activeRemoteServer {
            return Binding(token: CommandTargetPolicy.token(remoteLabel: server.displayName), server: server)
        }
        return Binding(token: .localTunnel, server: nil)
    }

    /// The client for a binding captured earlier, or nil when the session has moved since.
    ///
    /// The check and the client resolution happen under the SAME lock, so there is no window
    /// between "the target is still current" and "here is its client" - the two facts a status page
    /// needs to describe one daemon. Nil means the page's reads would describe a target the user has
    /// left, which is reported instead of answered.
    public static func sessionClient(for binding: Binding) throws -> LibboxCommandClient? {
        lock.lock()
        defer { lock.unlock() }
        switch (activeRemoteServer, binding.server) {
        case (nil, nil):
            return LibboxNewStandaloneCommandClient()!
        case let (active?, bound?) where active === bound:
            if let client = sharedRemoteClient {
                return client
            }
            let client = try newStandaloneClient(for: active)
            sharedRemoteClient = client
            return client
        default:
            return nil
        }
    }

    public static func libboxOptions(_ server: RemoteServer) -> LibboxRemoteConnectionOptions {
        let options = LibboxRemoteConnectionOptions()
        options.url = RemoteServer.connectURL(server.url)
        options.secret = server.secret
        return options
    }

    /// One-shot reachability probe for a draft (unsaved) server. Dials over the network
    /// and blocks until the probe completes, so it must run off the main thread.
    public static func probe(url: String, secret: String) -> Bool {
        let options = LibboxRemoteConnectionOptions()
        options.url = RemoteServer.connectURL(url)
        options.secret = secret
        var error: NSError?
        guard let client = LibboxNewStandaloneRemoteCommandClient(options, &error), error == nil else {
            return false
        }
        defer { try? client.disconnect() }
        var startedAt: Int64 = 0
        do {
            try client.getStartedAt(&startedAt)
            return true
        } catch {
            return false
        }
    }

    /// Returns a client for one-shot calls and streamed sessions. In remote mode the
    /// client is shared for the whole session — callers must not disconnect it.
    public static func standaloneClient() throws -> LibboxCommandClient {
        lock.lock()
        defer { lock.unlock() }
        guard let server = activeRemoteServer else {
            return LibboxNewStandaloneCommandClient()!
        }
        if let client = sharedRemoteClient {
            return client
        }
        let client = try newStandaloneClient(for: server)
        sharedRemoteClient = client
        return client
    }

    /// Returns a client for an operation that named its scope.
    ///
    /// The scope is a required argument and there is no default, because the default is what the
    /// defect was: every caller silently followed the session. A caller that means "whatever the
    /// user is looking at" says `.session`; a caller that touches a locally stored profile says
    /// `.localTunnel` and cannot be redirected by the remote-control settings.
    ///
    /// `.localTunnel` always builds a fresh standalone client, exactly as the local mode of
    /// `standaloneClient()` always did, and never hands out the session's shared remote channel.
    public static func standaloneClient(scope: CommandScope) throws -> LibboxCommandClient {
        switch scope {
        case .session:
            return try standaloneClient()
        case .localTunnel:
            return LibboxNewStandaloneCommandClient()!
        }
    }

    /// Returns a dedicated client owned by the caller, who is responsible for
    /// disconnecting it (e.g. the SSH terminal closes its client on session end).
    public static func ownedStandaloneClient() throws -> LibboxCommandClient {
        if let server = remoteServer {
            return try newStandaloneClient(for: server)
        }
        return LibboxNewStandaloneCommandClient()!
    }

    private static func newStandaloneClient(for server: RemoteServer) throws -> LibboxCommandClient {
        var error: NSError?
        let client = LibboxNewStandaloneRemoteCommandClient(libboxOptions(server), &error)
        if let error {
            throw error
        }
        return client!
    }
}
