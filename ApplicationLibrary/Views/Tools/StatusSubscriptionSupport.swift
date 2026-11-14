import Foundation
import Library
import os

private let logger = Logger(category: "StatusSubscription")

/// Who owns a status subscription while the handle is still being created.
///
/// # The race this exists for
///
/// Every tools page builds its subscription the same way: `subscribe()` raises `isSubscribed`
/// synchronously, then gets the handle from a `Task.detached` that calls into the core. `cancel()` can
/// run in the window before that task resumes - the reader leaves the page, the tunnel drops, the
/// page is rebuilt - and it cannot close a handle that does not exist yet. The completion then stored
/// the live handle into a view model that had already cancelled, and **nothing ever closed it**: the
/// stream stayed open for the life of the process, one more of each per visit.
///
/// The generation is the ownership token. `begin()` claims a subscription, `cancel()` invalidates
/// whatever is in flight, and a completion whose token is stale closes what it just made instead of
/// adopting it. This is deliberately not an actor or a state machine: the state it protects is one
/// counter read and written on the main actor.
public struct SubscriptionOwnership {
    private var generation: UInt64 = 0

    public init() {}

    /// Claims a new attempt and returns its token.
    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Abandons every attempt made so far, including any still creating its handle.
    public mutating func invalidate() {
        generation &+= 1
    }

    /// Whether `token` still names the current attempt.
    public func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }
}

/// Why a status subscription is not running.
///
/// The distinction matters to the reader: "the service is not up yet" is not a Tailscale, OpenVPN or
/// USB-IP fault, and telling them it is - with the raw gRPC text - is what produced the modal
/// `tailscale status recv: rpc error: code = Unknown desc = invalid argument` report.
public enum StatusSubscriptionFailure: Equatable {
    /// The service is not started, so the stream was refused before it could carry anything.
    case serviceNotRunning
    /// This kernel has no such subscription (older builds, or a feature the CLI does not ship).
    case unsupportedByCore
    /// Anything else - worth showing, because it is a real fault.
    case failed(String)

    /// Classifies a message produced by the core's status stream.
    ///
    /// # Where these strings come from
    ///
    /// `daemon.StartedService.waitForStarted` returns `os.ErrInvalid` when the service is neither
    /// STARTED nor STARTING, i.e. during a start, a stop or a reload. gRPC surfaces that plain Go
    /// error as `code = Unknown desc = invalid argument`, and `libbox.subscribeStatus` reports every
    /// stream error that is neither `NotFound` nor `Unavailable` through `onError(... " recv")` with
    /// the RPC text attached. So this message is the *service not running* condition, observed at a
    /// moment when the page is entitled to be waiting for it.
    ///
    /// Nothing here swallows a real error: the message is logged in full either way, and a genuine
    /// fault still reaches the reader.
    public static func classify(_ message: String) -> StatusSubscriptionFailure {
        let lowered = message.lowercased()
        if lowered.contains("invalid argument") || lowered.contains("not started") || lowered.contains("service is not started") {
            return .serviceNotRunning
        }
        if lowered.contains("unimplemented") || lowered.contains("not implemented") {
            return .unsupportedByCore
        }
        return .failed(message)
    }

    /// Whether this is worth an alert.
    public var deservesAlert: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// Records the failure where a developer can find it, without a modal for a transient condition.
    public func log(_ name: String, message: String?) {
        switch self {
        case .serviceNotRunning:
            logger.debug("\(name) status stream not running yet: \(message ?? "-")")
        case .unsupportedByCore:
            logger.info("\(name) status stream is not supported by this core: \(message ?? "-")")
        case let .failed(detail):
            logger.error("\(name) status stream failed: \(detail)")
        }
    }
}

extension StatusSubscriptionFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .serviceNotRunning: "service not running"
        case .unsupportedByCore: "unsupported by core"
        case let .failed(detail): "failed: \(detail)"
        }
    }
}
