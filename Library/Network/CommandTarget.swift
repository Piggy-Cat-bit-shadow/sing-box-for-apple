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

    /// The target the session is on, as a value an operation can carry and report.
    public static func currentToken() -> CommandTargetToken {
        lock.lock()
        defer { lock.unlock() }
        guard let server = activeRemoteServer else {
            return .localTunnel
        }
        return CommandTargetPolicy.token(remoteLabel: server.displayName)
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

    /// The scope an operation on this target must use, or nil when the operation may not run.
    ///
    /// Kept as the typed bridge between the policy and the client factory: a caller that has a token
    /// asks this instead of re-deriving `.localTunnel`/`.session` from `isRemote`, which is the
    /// derivation that used to send a local document to the session's target.
    public static func scope(for token: CommandTargetToken) -> CommandScope? {
        switch CommandTargetPolicy.localProfileDecision(token) {
        case .permitted:
            return .localTunnel
        case .refused:
            return nil
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
