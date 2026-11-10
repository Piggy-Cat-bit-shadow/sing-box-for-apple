import Foundation

// Which daemon an operation is allowed to talk to.
//
// The app has two command targets and they are not interchangeable: the tunnel this app installed
// on this device (a Unix socket or the macOS XPC service), and the remote server the user selected
// in the remote-control settings. Every other screen legitimately follows the session - a group
// list, a connection list and a log stream are ABOUT whichever daemon the user is looking at - but
// a local profile's configuration is not: it is a document stored on this device, and the only
// daemon it may be shown to is the one this device runs.
//
// That distinction used to be implicit. `CommandTarget.standaloneClient()` returned whichever
// target the session was on, and the configuration preview, the start-timestamp probe and the
// provider refresh all went through it. With remote control on, opening the Core settings page
// therefore had a path that sent the locally stored configuration body - credentials included - to
// the remote server, and the refresh path compared a remote daemon's start time with a local
// profile's body.
//
// This file is the decision, as a value. It is Foundation-only on purpose: the rules are testable
// without Libbox, a running tunnel or a remote server, which is where they belong.

/// Which daemon an operation addresses.
public enum CommandScope: Equatable, Sendable {
    /// The session's target: the selected remote server when there is one, otherwise this
    /// device's tunnel. What every management screen means by "the daemon".
    case session
    /// This device's tunnel, always and only, whatever the session is on.
    ///
    /// The scope of every operation that reads or writes a locally stored profile: the preview of
    /// its document, the apply that follows, the confirmation of that apply, and the provider
    /// refresh that belongs to it.
    case localTunnel
}

/// The identity of a command target at one instant.
///
/// Carried by an operation from the moment it decides what to talk to until it reports a result, so
/// the result can be attributed to the target it was produced by. Two facts make that checkable:
/// which KIND of target it was, and, for a remote session, the generation of the session's
/// selection - a switch to another server (or back to local) starts a new generation, and a reply
/// that arrives afterwards belongs to the old one.
public struct CommandTargetToken: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case localTunnel
        case remoteSession
    }

    public let kind: Kind
    /// Monotonic number of the session's remote selection; 0 for the local tunnel.
    public let generation: UInt64
    /// A non-secret label of the remote server, for reports and UI. Never the URL, never the secret:
    /// a connection URL can carry both.
    public let remoteLabel: String?

    public init(kind: Kind, generation: UInt64, remoteLabel: String?) {
        self.kind = kind
        self.generation = generation
        self.remoteLabel = remoteLabel
    }

    /// This device's tunnel.
    public static let localTunnel = CommandTargetToken(kind: .localTunnel, generation: 0, remoteLabel: nil)

    /// Whether this token describes a target a local document may be sent to.
    public var isLocalTunnel: Bool {
        kind == .localTunnel
    }
}

/// What a local-profile operation may do with the target it resolved.
public enum LocalProfileCommandDecision: Equatable, Sendable {
    /// The target is this device's tunnel: the operation may read the stored document and send it.
    case permitted(CommandTargetToken)
    /// The target is a remote server. The operation must not read or send the stored document;
    /// `reason` is the sentence the UI shows instead of a failure it cannot explain.
    case refused(CommandTargetToken, reason: String)
}

/// The rules, in one place.
public enum CommandTargetPolicy {
    /// The target a session resolves to.
    ///
    /// - Parameter remote: the selected server's label and the generation of that selection, or
    ///   nil when the session is on this device's tunnel.
    public static func token(remote: (label: String, generation: UInt64)?) -> CommandTargetToken {
        guard let remote else {
            return .localTunnel
        }
        return CommandTargetToken(kind: .remoteSession, generation: remote.generation, remoteLabel: remote.label)
    }

    /// Whether an operation that touches the LOCAL profile may run against `token`.
    ///
    /// This is checked BEFORE the document is read, not after the call fails: a refusal that has
    /// already sent the body is not a refusal.
    public static func localProfileDecision(_ token: CommandTargetToken) -> LocalProfileCommandDecision {
        switch token.kind {
        case .localTunnel:
            return .permitted(token)
        case .remoteSession:
            return .refused(token, reason: refusalReason(token))
        }
    }

    /// Whether a result received now still belongs to the operation that captured `captured`.
    ///
    /// A pinned local operation always does: its target is this process's own tunnel, which the
    /// user's remote selection cannot move. A session operation belongs to the generation it
    /// captured - a reply that arrives after the session moved to another server describes the old
    /// server, and attributing it to the new one is the misattribution this check exists to stop.
    public static func stillOwns(_ captured: CommandTargetToken, now: CommandTargetToken) -> Bool {
        switch captured.kind {
        case .localTunnel:
            return true
        case .remoteSession:
            guard now.kind == .remoteSession, now.generation == captured.generation else {
                return false
            }
            // A generation is one selection; the label is carried for reports, and a token that
            // claims the same generation with a different server is not the same target.
            return now.remoteLabel == captured.remoteLabel
        }
    }

    /// The sentence a refused operation reports.
    ///
    /// It names what the page can still do, because "unavailable" alone leaves the user with no
    /// next step. The document is deliberately not named: the reason is rendered in a settings row
    /// and must not read as an error the user caused.
    public static func refusalReason(_ token: CommandTargetToken) -> String {
        let target = token.remoteLabel.map { "the remote server \($0)" } ?? "a remote server"
        return "this page describes the tunnel on this device; the session is attached to \(target)"
    }
}
