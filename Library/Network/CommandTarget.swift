import Foundation
import Libbox

public enum CommandTarget {
    private static let lock = NSLock()
    private static var activeRemoteServer: RemoteServer?
    /// One gRPC channel per remote session: standalone calls reuse it instead of
    /// paying a TCP+TLS handshake (and leaking the connection) on every action.
    private static var sharedRemoteClient: LibboxCommandClient?
    /// Bumped whenever the session's remote selection changes, so an operation can tell whether the
    /// target it captured is still the session's target. See `currentToken()`.
    private static var remoteGeneration: UInt64 = 0

    public static var remoteServer: RemoteServer? {
        lock.lock()
        defer { lock.unlock() }
        return activeRemoteServer
    }

    public static func setRemoteServer(_ server: RemoteServer?) {
        lock.lock()
        let previousClient = sharedRemoteClient
        sharedRemoteClient = nil
        // A selection only counts when it MOVES. Bumping on every set would invalidate operations
        // for a re-selection of the same server, and not bumping on a change would let an operation
        // attribute a reply from the old server to the new one.
        let previousServer = activeRemoteServer
        let previousIdentity = previousServer.map(serverIdentity) ?? ""
        let nextIdentity = server.map(serverIdentity) ?? ""
        if previousIdentity != nextIdentity {
            remoteGeneration &+= 1
        }
        activeRemoteServer = server
        lock.unlock()
        if let previousClient {
            try? previousClient.disconnect()
        }
    }

    public static var isRemote: Bool {
        remoteServer != nil
    }

    /// The identity a generation counts: the stored row, its connection URL and its secret.
    ///
    /// The secret is fingerprinted rather than stored here. Two saved servers can share a URL and
    /// differ only in their secret, and treating those as one target would accept a reply from the
    /// other server's daemon. `hashValue` is deliberately not used: it is seeded per process, so it
    /// would silently compare unequal for the same server after a relaunch.
    private static func serverIdentity(_ server: RemoteServer) -> String {
        let secretFingerprint = ConfigurationBodyRevision.fingerprint(of: server.secret)
        return "\(server.id.map(String.init) ?? "-")|\(server.url)|\(secretFingerprint)"
    }

    /// The target the session is on, as a value an operation can carry and re-check.
    public static func currentToken() -> CommandTargetToken {
        lock.lock()
        defer { lock.unlock() }
        guard let server = activeRemoteServer else {
            return .localTunnel
        }
        return CommandTargetPolicy.token(remote: (label: server.displayName, generation: remoteGeneration))
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
    /// This is the one place the two vocabularies meet: the policy says whether a LOCAL PROFILE may
    /// be shown to the target, and the scope is the client that reaches it.
    public static func localProfileScope(for token: CommandTargetToken) -> CommandScope? {
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
