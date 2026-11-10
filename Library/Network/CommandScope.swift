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
/// It records WHICH daemon an operation resolved, and it is carried into the result so a page can
/// name the source of every row it shows. Attribution is structural rather than re-checked later:
/// the client is resolved from this token once per read, and `CommandTarget.setRemoteServer`
/// discards the session's shared remote channel whenever the selection changes - so a client a
/// reader already holds cannot silently start talking to another daemon.
public struct CommandTargetToken: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case localTunnel
        case remoteSession
    }

    public let kind: Kind
    /// A non-secret label of the remote server, for reports and UI. Never the URL, never the secret:
    /// a connection URL can carry both.
    public let remoteLabel: String?

    public init(kind: Kind, remoteLabel: String?) {
        self.kind = kind
        self.remoteLabel = remoteLabel
    }

    /// This device's tunnel.
    public static let localTunnel = CommandTargetToken(kind: .localTunnel, remoteLabel: nil)

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
    /// - Parameter remote: the selected server's non-secret label, or nil when the session is on this
    ///   device's tunnel.
    public static func token(remoteLabel: String?) -> CommandTargetToken {
        guard let remoteLabel else {
            return .localTunnel
        }
        return CommandTargetToken(kind: .remoteSession, remoteLabel: remoteLabel)
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
