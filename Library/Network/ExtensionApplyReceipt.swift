import Foundation

// The receipt one apply request is answered with.
//
// # Why the answer is not nil
//
// `NEPacketTunnelProviderSession.sendProviderMessage(_:responseHandler:)` calls its handler with
// nil when the message could not be delivered, and an extension that answers `nil` on success is
// indistinguishable from one that failed before answering. The Apple client's extension used to do
// exactly that: `handleAppMessage` returned nothing on success, so "the reload worked", "the
// extension crashed" and "the message never arrived" were one value.
//
// # Why it is a document and not an error
//
// The extension already has to say more than "yes": the daemon can report started, restarted,
// applied live, unchanged, recovered or interrupted, and two of those mean the requested document is
// NOT what runs. Collapsing them into "no error" is what made a recovery look like a successful
// apply. The envelope below carries the daemon's status, the revisions it named, and the error text
// in one value the app decodes.
//
// # Why it echoes the request
//
// Two applies can overlap (a manual refresh and a background one). A reply is matched to its request
// by `requestID`, and the profile and body revision are echoed too, so a reply that arrives after a
// different body was written cannot be counted as the confirmation of this one.
//
// The wire form is deliberately flat and optional-heavy: a newer extension may add fields, an older
// app ignores them, and a missing field is "this extension does not say", never a default that reads
// as success.

/// The statuses the daemon reports for one apply attempt.
public enum ExtensionApplyStatus: String, Equatable, Sendable {
    /// There was no running service and one was started.
    case started
    /// The running document was already the requested one.
    case unchanged
    /// The running service absorbed the change in place.
    case appliedLive = "applied_live"
    /// A new service was built and started for the change.
    case restarted
    /// The requested document failed and the stored last-good one is what runs now.
    case recovered
    /// The start was interrupted and nothing is running.
    case interrupted
    /// The target is not the running document.
    case failed

    /// Whether this status means the requested document is the one running.
    public var appliedTheRequest: Bool {
        switch self {
        case .started, .unchanged, .appliedLive, .restarted:
            return true
        case .recovered, .interrupted, .failed:
            return false
        }
    }

    /// Whether the daemon reopened the TUN to reach this status.
    ///
    /// The two live statuses answer "the running Box already was (or absorbed) this document", which
    /// means `openTun` did NOT run: nothing the platform installs with the tunnel - routes,
    /// exclusions, the proxy - was reinstalled. The two rebuild statuses did reopen it, so the
    /// overrides the request had already installed reached the system through that rebuild.
    ///
    /// This is what lets the extension force a rebuild only when one is needed, and in that order:
    /// apply first, read this, and close the old tunnel only if the daemon did not.
    public var reinstalledTunnel: Bool {
        switch self {
        case .started, .restarted:
            return true
        case .unchanged, .appliedLive, .recovered, .interrupted, .failed:
            return false
        }
    }
}

/// What one apply request did, as the app needs to report it.
public enum ExtensionApplyOutcome: Equatable, Sendable {
    /// The requested document is the one running now.
    case applied(ExtensionApplyStatus, activeRevision: String?)
    /// The service runs, but the stored last-good document is what it runs.
    case recovered(activeRevision: String?)
    /// Nothing is running.
    case interrupted
    /// The apply failed. `retained` says whether the previous document is still serving: `true`
    /// when the daemon reported it, `false` only when the daemon said nothing is left, and `nil`
    /// when this build does not know.
    ///
    /// `nil` is not `false`. Reporting "the tunnel stopped" for an apply whose retention nobody
    /// established is the one error that sends a user to look at a tunnel that is working.
    case failed(reason: String, retained: Bool?)
    /// The extension answered, but not with a decision this build can read.
    case undetermined(reason: String)

    /// Whether the user may read this as "the configuration I asked for is running".
    public var didApplyRequest: Bool {
        if case .applied = self {
            return true
        }
        return false
    }
}

/// The daemon's own outcome document, as the libbox apply entry returns it.
///
/// The extension receives it from `CommandServer.applyServiceChangeReport` and turns it into the
/// receipt above. It is decoded here, in a file both sides compile, so the mapping between the two
/// documents cannot drift between the extension and the app.
///
/// The version is the ENVELOPE's version (`daemon.ServiceChangeOutcomeVersion`), not the report's:
/// `report` is the kernel's own JSON and grows additively.
public struct LibboxApplyOutcomeDocument: Decodable, Equatable, Sendable {
    public var version: Int?
    public var ok: Bool?
    public var error: String?
    public var status: String?
    public var report: Report?

    public struct Report: Decodable, Equatable, Sendable {
        public var status: String?
        public var restartRequired: Bool?
        public var retained: Bool?
        public var activeRevision: String?
        public var persistence: String?
        public var persistenceWarning: String?
        public var reason: String?
        /// The token the caller supplied for this apply, echoed by the kernel. Empty when the
        /// caller used the token-less entry point (or an older kernel).
        public var requestID: String?
        /// The kernel instance running after the attempt. This is the identity the NE receipt
        /// carries, and the app checks it against the instance it expected.
        public var instanceID: String?
        public var plan: Plan?

        public struct Plan: Decodable, Equatable, Sendable {
            public var currentRevision: String?
            public var targetRevision: String?
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case restartRequired
            case retained
            case activeRevision
            case persistence
            case persistenceWarning
            case reason
            case requestID = "requestId"
            case instanceID = "instanceId"
            case plan
        }
    }

    /// Decodes the bridge's answer, or nil when it is not a document this build understands.
    public static func decode(_ json: String?) -> LibboxApplyOutcomeDocument? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LibboxApplyOutcomeDocument.self, from: data)
    }

    /// The status as the receipt's vocabulary, or nil when it is not one this build knows.
    ///
    /// An unknown status is deliberately nil rather than a default: `applyUnconfirmed` is the honest
    /// answer for "the daemon said something this build cannot read".
    public var outcomeStatus: ExtensionApplyStatus? {
        guard let status else {
            return nil
        }
        return ExtensionApplyStatus(rawValue: status)
    }
}

/// An apply that did not take effect, as an error a caller that only handles errors can throw.
public struct ExtensionApplyError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
/// One apply request, as the extension echoes it.
public struct ExtensionApplyReceipt: Equatable, Sendable {
    /// The version of the ENVELOPE. A bump means a field changed meaning, not that one was added.
    public static let version = 1

    public let requestID: String
    /// Identifies the tunnel process that answered. A reload keeps it; a new tunnel session does
    /// not, so a receipt from a previous session is recognisable.
    public let tunnelSessionID: String
    public let profileID: Int64?
    /// The caller's own fingerprint of the body it sent, echoed so the receipt names the document it
    /// applied rather than the one that happens to be stored now.
    public let bodyRevision: String?
    /// The kernel instance running after the apply, when the kernel named one. nil for a kernel
    /// that predates request identity, which is why the ownership check treats a missing value as
    /// "unconfirmed" only when the caller expected an instance.
    public let instanceID: String?
    public let outcome: ExtensionApplyOutcome
    public let targetRevision: String?
    public let restartRequired: Bool
    public let persistence: String?
    public let reason: String?

    public init(
        requestID: String,
        tunnelSessionID: String,
        profileID: Int64?,
        bodyRevision: String?,
        instanceID: String? = nil,
        outcome: ExtensionApplyOutcome,
        targetRevision: String?,
        restartRequired: Bool,
        persistence: String?,
        reason: String?
    ) {
        self.requestID = requestID
        self.tunnelSessionID = tunnelSessionID
        self.profileID = profileID
        self.bodyRevision = bodyRevision
        self.instanceID = instanceID
        self.outcome = outcome
        self.targetRevision = targetRevision
        self.restartRequired = restartRequired
        self.persistence = persistence
        self.reason = reason
    }
}

/// The wire form. Flat, all-optional except the identity, so both sides can evolve.
public struct ExtensionApplyReceiptMessage: Codable, Equatable, Sendable {
    public var version: Int?
    public var requestID: String?
    public var sessionID: String?
    public var profileID: Int64?
    public var bodyRevision: String?
    /// The kernel instance the apply left running, when the extension could read one.
    public var instanceID: String?
    public var ok: Bool?
    public var status: String?
    public var targetRevision: String?
    public var activeRevision: String?
    public var retained: Bool?
    public var restartRequired: Bool?
    public var persistence: String?
    public var reason: String?

    public init(
        version: Int? = ExtensionApplyReceipt.version,
        requestID: String? = nil,
        sessionID: String? = nil,
        profileID: Int64? = nil,
        bodyRevision: String? = nil,
        instanceID: String? = nil,
        ok: Bool? = nil,
        status: String? = nil,
        targetRevision: String? = nil,
        activeRevision: String? = nil,
        retained: Bool? = nil,
        restartRequired: Bool? = nil,
        persistence: String? = nil,
        reason: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.sessionID = sessionID
        self.profileID = profileID
        self.bodyRevision = bodyRevision
        self.instanceID = instanceID
        self.ok = ok
        self.status = status
        self.targetRevision = targetRevision
        self.activeRevision = activeRevision
        self.retained = retained
        self.restartRequired = restartRequired
        self.persistence = persistence
        self.reason = reason
    }
}

/// Decodes the extension's answer and decides what it is.
public enum ExtensionApplyReceiptParser {
    public enum Result: Equatable, Sendable {
        case receipt(ExtensionApplyReceipt)
        /// The extension answered nothing. An extension that predates this envelope does that on
        /// success, so this is "unconfirmed", never "failed".
        case noReceipt
        /// A reply for another request: a late answer to an earlier apply, or an extension that
        /// lost track of the id. It must not be counted as this request's confirmation.
        case otherRequest(expected: String, received: String)
        /// A reply from another tunnel session: the extension restarted between the send and this
        /// answer. The request it answers may never have been applied by the session that is
        /// running now, so the answer cannot confirm anything this caller sees.
        case otherSession(expected: String, received: String)
        /// The reply is not an envelope this build understands.
        case unreadable(String)
    }

    /// - Parameters:
    ///   - data: the extension's reply, as `sendProviderMessage` delivered it.
    ///   - requestID: the id this call sent.
    ///   - expectedSessionID: the tunnel session this call was sent to, or nil when the caller
    ///     does not track sessions (the old behaviour).
    public static func parse(_ data: Data?, expecting requestID: String, expectingSessionID: String? = nil) -> Result {
        guard let data, !data.isEmpty else {
            return .noReceipt
        }
        let message: ExtensionApplyReceiptMessage
        do {
            message = try JSONDecoder().decode(ExtensionApplyReceiptMessage.self, from: data)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        return classify(message, expecting: requestID, expectingSessionID: expectingSessionID)
    }

    /// Classifies an already-decoded envelope. Split out so the decision is testable on the value
    /// rather than only through JSON.
    public static func classify(
        _ message: ExtensionApplyReceiptMessage,
        expecting requestID: String,
        expectingSessionID: String? = nil
    ) -> Result {
        if let version = message.version, version > ExtensionApplyReceipt.version {
            // A newer extension may have changed what a field means. Reading it with this build's
            // rules would be guessing, and guessing here means reporting an apply nobody confirmed.
            return .unreadable("the extension answered with receipt version \(version); this build reads \(ExtensionApplyReceipt.version)")
        }
        guard let receivedRequestID = message.requestID, !receivedRequestID.isEmpty else {
            return .unreadable("the extension answered without a request id")
        }
        guard receivedRequestID == requestID else {
            return .otherRequest(expected: requestID, received: receivedRequestID)
        }
        guard let sessionID = message.sessionID, !sessionID.isEmpty else {
            return .unreadable("the extension answered without a tunnel session id")
        }
        if case let .refuse(reason) = ExtensionSessionBinding.receiptMatches(
            expectedSessionID: expectingSessionID,
            receiptSessionID: sessionID
        ) {
            return .otherSession(expected: expectingSessionID ?? "", received: sessionID)
        }
        let outcome = outcome(of: message)
        return .receipt(
            ExtensionApplyReceipt(
                requestID: receivedRequestID,
                tunnelSessionID: sessionID,
                profileID: message.profileID,
                bodyRevision: message.bodyRevision,
                instanceID: message.instanceID,
                outcome: outcome,
                targetRevision: message.targetRevision,
                restartRequired: message.restartRequired ?? false,
                persistence: message.persistence,
                reason: message.reason
            )
        )
    }

    /// The outcome a message describes.
    ///
    /// `ok` is the extension's simple verdict and `status` is the daemon's; they are read together
    /// because neither alone is enough. A recovery returns ok:false with status "recovered" and must
    /// not be reported as a failed apply, and an extension that only sets `ok` still says something
    /// usable.
    static func outcome(of message: ExtensionApplyReceiptMessage) -> ExtensionApplyOutcome {
        if let statusText = message.status, let status = ExtensionApplyStatus(rawValue: statusText) {
            switch status {
            case .recovered:
                return .recovered(activeRevision: message.activeRevision)
            case .interrupted:
                return .interrupted
            case .failed:
                return .failed(reason: message.reason ?? "the daemon refused the configuration", retained: message.retained)
            case .started, .unchanged, .appliedLive, .restarted:
                return .applied(status, activeRevision: message.activeRevision)
            }
        }
        if message.ok == true {
            // No status this build knows, but the extension says the requested document runs.
            return .applied(.unchanged, activeRevision: message.activeRevision)
        }
        if message.ok == false {
            return .failed(reason: message.reason ?? "the extension refused the apply", retained: message.retained)
        }
        return .undetermined(reason: "the extension answered without a status")
    }
}
