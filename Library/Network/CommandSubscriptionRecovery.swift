import Foundation

/// Whether the command client should keep, rebuild, or give up on its status subscription.
///
/// This is the decision `CommandClient` makes around its connection, extracted so that it can be
/// driven directly. It is three facts and one question, deliberately not a state machine: the
/// client already owns the subscription through `activeConnectionToken`, and the only thing that
/// was wrong was *when* a lost subscription gets rebuilt.
///
/// # Why the loss has to drive the rebuild
///
/// `scenePhase` becoming active calls `ExtensionEnvironments.connect()`, and that only connects
/// while `!isConnected`. But the scene becomes active *before* the death of the old stream has been
/// observed, so at that moment `isConnected` is still true and the foreground call returns having
/// done nothing. The observation arrives afterwards, and nothing was watching for it - so the
/// subscription stayed dead, and every card reading `status` stopped updating until the app was
/// relaunched. The rebuild therefore has to be driven from the loss itself.
///
/// # Why it is bounded
///
/// A tunnel that is genuinely gone must not produce a retry loop, so recovery is attempted at most
/// once per loss. The bound is re-armed only by a connection that actually succeeded, which makes
/// it "one attempt per loss" rather than "one attempt per process": a subscription that comes up
/// and later dies again is recoverable in its turn.
///
/// Foundation only, and free of Libbox, so the file that decides is the file the tests compile.
public struct CommandSubscriptionRecovery: Equatable, Sendable {
    /// Whether a subscription is wanted at all. Raised when a connection is asked for, lowered by a
    /// teardown the client asked for. This is what tells an unexpected loss apart from a
    /// `disconnect()` the client meant, so a teardown cannot start a reconnect.
    public private(set) var wantsConnection = false

    /// Whether the client has parked the connection for a trip through the background. While this
    /// is set, a teardown is expected and nothing should be rebuilt until `resume()`.
    public private(set) var isSuspended = false

    /// Whether an unexpected loss has already been recovered from. Cleared by a connection that
    /// succeeded, and by a teardown.
    public private(set) var hasAttemptedRecovery = false

    public init() {}

    /// A connection was asked for, and the attempt is starting.
    public mutating func connectionRequested() {
        wantsConnection = true
    }

    /// A connection came up. This is what re-arms the recovery bound.
    public mutating func connectionEstablished() {
        hasAttemptedRecovery = false
    }

    /// The client is tearing the connection down on purpose, so there is no loss to recover from.
    public mutating func teardownRequested() {
        wantsConnection = false
        hasAttemptedRecovery = false
        isSuspended = false
    }

    /// The connection is being parked for the background. Only the remote path does this; a local
    /// extension connection is left alone, which is why `resume()` is a no-op when nothing was
    /// suspended.
    public mutating func suspend() {
        isSuspended = true
    }

    /// The connection is being brought back after `suspend()`.
    public mutating func resume() {
        isSuspended = false
    }

    /// Whether a connect request would be accepted right now.
    ///
    /// The same three refusals `connect()` has always made: already connected, already connecting,
    /// or parked for the background.
    public func acceptsConnect(isConnected: Bool, isConnecting: Bool) -> Bool {
        !isConnected && !isConnecting && !isSuspended
    }

    /// Whether a connection that ended should be rebuilt, and records the attempt when it should.
    ///
    /// - Parameter wasLive: whether a subscription had actually been established. An attempt that
    ///   never came up is not a loss the user sees as "the cards stopped"; it reports through
    ///   `lastError` instead, and must not spin.
    /// - Returns: `true` exactly once per loss, while a subscription is still wanted and the
    ///   connection is not parked.
    public mutating func recoverIfNeeded(wasLive: Bool) -> Bool {
        guard wasLive, wantsConnection, !isSuspended, !hasAttemptedRecovery else {
            return false
        }
        hasAttemptedRecovery = true
        return true
    }
}
