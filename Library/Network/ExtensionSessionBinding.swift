import Foundation

// Which tunnel session a request or a receipt belongs to.
//
// # The gap this closes
//
// `tunnelSessionID` already existed and travelled end to end: the extension creates one per
// `startTunnel`, echoes it in every receipt, and the parser stored it. Nothing compared it with
// anything. The consequence is the reconnect case:
//
//   session A: apply request R1, extension stops, receipt R1 is slow
//   session B: starts, user changes a switch, request R2 is sent
//   receipt R1 arrives while R2 is waiting
//
// The app's ownership check (request id, profile, body revision) could pass for R1 if R2 shares
// the profile and body - a platform-only change does exactly that - so A's answer settled B's
// request. The extension has the mirror-image hazard: a request built for A that arrives after B
// started is applied by B.
//
// # The two checks
//
// `admission` runs in the extension, before any side effect, and compares the request's declared
// `expectedSessionID` with the extension's current session. `receiptMatches` runs in the app and
// compares the receipt's session with the session the request was sent to. Both are nil-tolerant:
// a caller that does not declare a session keeps the old behaviour, so an older app or extension
// is degraded, never silently accepted as a confirmation.
//
// The decision is a pure value so it is testable without NetworkExtension, on any host.

/// What one session check decided.
public enum SessionBindingDecision: Equatable, Sendable {
    case admit
    case refuse(reason: String)
}

public enum ExtensionSessionBinding {
    /// The extension's half: may this request be applied by `currentSessionID`?
    ///
    /// A request with no declared session is admitted: refusing it would be a protocol change
    /// disguised as a safety check, and older apps send none.
    public static func admission(expectedSessionID: String?, currentSessionID: String) -> SessionBindingDecision {
        guard let expectedSessionID, !expectedSessionID.isEmpty else {
            return .admit
        }
        guard !currentSessionID.isEmpty else {
            return .refuse(reason: "the request named a tunnel session but this extension has none")
        }
        guard expectedSessionID == currentSessionID else {
            return .refuse(reason: "the request expected tunnel session \(expectedSessionID); this session is \(currentSessionID)")
        }
        return .admit
    }

    /// The app's half: may this receipt be read as the answer of `expectedSessionID`?
    ///
    /// A nil expectation keeps the old behaviour for callers that do not track sessions. A receipt
    /// with no session is NOT admitted against an expectation: the parser already rejects that
    /// shape as unreadable, and an empty value here is not evidence of anything.
    public static func receiptMatches(expectedSessionID: String?, receiptSessionID: String) -> SessionBindingDecision {
        guard let expectedSessionID, !expectedSessionID.isEmpty else {
            return .admit
        }
        guard receiptSessionID == expectedSessionID else {
            return .refuse(reason: "the extension answered from tunnel session \(receiptSessionID), not \(expectedSessionID)")
        }
        return .admit
    }
}

/// The identity query the app sends before declaring an expected session.
///
/// It is a normal provider message with no configuration: the extension recognises the operation
/// and answers with its current session id. An extension that predates the operation sees a
/// request without a body and answers a failure receipt, which decodes as "no identity" - the app
/// then sends the reload without an expectation, exactly as it did before.
public enum TunnelSessionIdentityMessage {
    public static let operationKey = "operation"
    public static let operationValue = "sessionIdentity"
    public static let sessionIDKey = "sessionID"

    public struct Request: Codable, Equatable, Sendable {
        public init() {}

        public func encode() -> Data? {
            try? JSONEncoder().encode([operationKey: operationValue])
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public let sessionID: String

        public init(sessionID: String) {
            self.sessionID = sessionID
        }

        public static func decode(_ data: Data?) -> String? {
            guard let data, !data.isEmpty else {
                return nil
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                return nil
            }
            return response.sessionID.isEmpty ? nil : response.sessionID
        }
    }
}
