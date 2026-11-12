import Foundation

// Which selection attempt a confirmation belongs to.
//
// # The problem
//
// The group list used to settle a selection by its tags:
//
//   pendingSelections[groupTag] = outboundTag        // fire and forget
//   ... later: if the next groups snapshot says something else, overwrite it with the pending tag
//
// A tag is not an attempt. Two taps on the same group are two attempts with the same group tag, and
// the kernel's answer - "the group now holds member X at revision R" - could not be matched to
// either. Three things followed from that:
//
//   * a late answer for tap A could pin the row to A after the user tapped B;
//   * a failed attempt left the pending tag in place forever, so every later snapshot was
//     overwritten with a value the daemon never took;
//   * nothing recorded the revision, so the read-back could not be checked against what the view
//     had already seen.
//
// # The contract this file implements
//
// The kernel's `SelectOutboundWithRequest` returns a read-back carrying the request id, the member
// the group actually holds, and the group revision after the selection. `SelectionLedger` keeps the
// latest attempt per group and decides what a read-back may change:
//
//   * an answer for an older attempt is ignored, never applied;
//   * an answer whose revision is older than one already applied is ignored;
//   * an answer from a daemon that cannot confirm identity clears the attempt and is reported as
//     unconfirmed - the selection may have happened, but nobody can say which one it was;
//   * only a read-back for the latest attempt, at a revision not older than the last applied one,
//     moves the row and records the revision.
//
// It is deliberately a value type with no Foundation dependency beyond JSON decoding, so the same
// decisions are testable on a host without a running daemon or an Xcode target.

/// One selection attempt, as sent to the kernel.
public struct SelectionRequest: Equatable, Sendable {
    public let groupTag: String
    public let outboundTag: String
    /// Unique per attempt within one client.
    public let requestID: UInt64
    /// The group revision this client last observed, or 0 when it has none.
    public let expectedRevision: UInt64

    public init(groupTag: String, outboundTag: String, requestID: UInt64, expectedRevision: UInt64) {
        self.groupTag = groupTag
        self.outboundTag = outboundTag
        self.requestID = requestID
        self.expectedRevision = expectedRevision
    }
}

/// The kernel's read-back, decoded from the JSON document CommandClient returns.
public struct SelectionReadBack: Equatable, Sendable {
    /// False when the daemon predates the identity fields: the selection was performed, but the
    /// answer cannot be attributed to this attempt.
    public let supported: Bool
    public let unconfirmed: Bool
    public let requestID: UInt64
    /// The member the group holds after the request - not necessarily the member requested.
    public let appliedOutboundTag: String?
    /// The group revision after the request. Zero when the daemon did not report one.
    public let appliedRevision: UInt64
    /// The caller's expectedRevision did not match when the request arrived.
    public let stale: Bool

    public init(
        supported: Bool,
        unconfirmed: Bool,
        requestID: UInt64,
        appliedOutboundTag: String?,
        appliedRevision: UInt64,
        stale: Bool
    ) {
        self.supported = supported
        self.unconfirmed = unconfirmed
        self.requestID = requestID
        self.appliedOutboundTag = appliedOutboundTag
        self.appliedRevision = appliedRevision
        self.stale = stale
    }

    /// Decodes the document `CommandClient.SelectOutboundWithRequest` produces. A document this
    /// build cannot read is `nil`, never a guessed success.
    public static func decode(_ document: String) -> SelectionReadBack? {
        guard let data = document.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(SelectionReadBack.self, from: data)
    }
}

extension SelectionReadBack: Decodable {
    private enum CodingKeys: String, CodingKey {
        case supported
        case unconfirmed
        case requestID = "requestId"
        case appliedOutboundTag
        case appliedRevision
        case stale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        unconfirmed = try container.decodeIfPresent(Bool.self, forKey: .unconfirmed) ?? false
        requestID = try container.decodeIfPresent(UInt64.self, forKey: .requestID) ?? 0
        appliedOutboundTag = try container.decodeIfPresent(String.self, forKey: .appliedOutboundTag)
        appliedRevision = try container.decodeIfPresent(UInt64.self, forKey: .appliedRevision) ?? 0
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }
}

/// What one read-back is allowed to do to the list.
public enum SelectionSettlement: Equatable, Sendable {
    /// Apply this read-back: the member the group holds and its revision.
    case applied(outboundTag: String, revision: UInt64, stale: Bool)
    /// A newer attempt for the same group exists; this answer belongs to the replaced attempt.
    case ignoredOlderRequest(latestRequestID: UInt64)
    /// The answer is for this attempt but reports a revision older than one already applied.
    case ignoredOlderRevision(latestRevision: UInt64)
    /// The selection may have happened, but the daemon cannot confirm which attempt it was.
    case unconfirmed(reason: String)
    /// The attempt failed. The pending overlay is gone; the stream is the truth again.
    case failed(reason: String)
}

/// A selection failure with a message the UI can show.
///
/// The ledger's settlements are values, not errors; the view model still has to tell the user why
/// an attempt did not settle, and this is the smallest `LocalizedError` that carries that text.
public struct SelectionOrderingFailure: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// The per-group attempt ledger the group list owns.
public struct SelectionLedger {
    public struct Pending: Equatable, Sendable {
        public let requestID: UInt64
        public let outboundTag: String

        public init(requestID: UInt64, outboundTag: String) {
            self.requestID = requestID
            self.outboundTag = outboundTag
        }
    }

    private var pending: [String: Pending] = [:]
    private var appliedRevisions: [String: UInt64] = [:]
    private var nextRequestID: UInt64 = 0

    public init() {}

    /// The tag the list should keep showing for a group while its attempt is in flight.
    public func pendingSelection(for groupTag: String) -> Pending? {
        pending[groupTag]
    }

    /// The last revision this client applied for a group, used as `expectedRevision`.
    public func appliedRevision(for groupTag: String) -> UInt64 {
        appliedRevisions[groupTag] ?? 0
    }

    /// Starts a new attempt and makes it the latest for its group. Any earlier attempt for the
    /// same group is replaced here; its answer will be ignored when it arrives.
    public mutating func begin(groupTag: String, outboundTag: String) -> SelectionRequest {
        nextRequestID &+= 1
        let request = SelectionRequest(
            groupTag: groupTag,
            outboundTag: outboundTag,
            requestID: nextRequestID,
            expectedRevision: appliedRevisions[groupTag] ?? 0
        )
        pending[groupTag] = Pending(requestID: request.requestID, outboundTag: outboundTag)
        return request
    }

    /// A groups snapshot arrived. If it already shows the member the pending attempt asked for,
    /// the stream confirmed the attempt even before the read-back lands; the overlay can go.
    /// Returns true when that happened.
    public mutating func confirmFromStream(groupTag: String, selectedTag: String) -> Bool {
        guard let current = pending[groupTag], current.outboundTag == selectedTag else {
            return false
        }
        pending.removeValue(forKey: groupTag)
        return true
    }

    /// Applies the kernel's read-back for one attempt, if it may still move the list.
    public mutating func settle(_ readBack: SelectionReadBack, for request: SelectionRequest) -> SelectionSettlement {
        guard let current = pending[request.groupTag], current.requestID == request.requestID else {
            return .ignoredOlderRequest(latestRequestID: pending[request.groupTag]?.requestID ?? request.requestID)
        }
        guard readBack.requestID == request.requestID else {
            // The transport refuses this case; keeping the attempt pending is still the honest
            // state, because nothing about THIS attempt was answered.
            return .unconfirmed(reason: "the daemon answered request \(readBack.requestID), not \(request.requestID)")
        }
        guard readBack.supported, !readBack.unconfirmed else {
            pending.removeValue(forKey: request.groupTag)
            return .unconfirmed(reason: "the running daemon cannot confirm which selection this was")
        }
        guard let appliedTag = readBack.appliedOutboundTag else {
            pending.removeValue(forKey: request.groupTag)
            return .unconfirmed(reason: "the daemon did not name the member the group holds")
        }
        let latestRevision = appliedRevisions[request.groupTag] ?? 0
        if readBack.appliedRevision < latestRevision {
            pending.removeValue(forKey: request.groupTag)
            return .ignoredOlderRevision(latestRevision: latestRevision)
        }
        pending.removeValue(forKey: request.groupTag)
        appliedRevisions[request.groupTag] = readBack.appliedRevision
        return .applied(outboundTag: appliedTag, revision: readBack.appliedRevision, stale: readBack.stale)
    }

    /// Reports a failed attempt. A failure for an attempt that has been replaced changes nothing.
    public mutating func fail(_ request: SelectionRequest, reason: String) -> SelectionSettlement {
        guard let current = pending[request.groupTag], current.requestID == request.requestID else {
            return .ignoredOlderRequest(latestRequestID: pending[request.groupTag]?.requestID ?? request.requestID)
        }
        pending.removeValue(forKey: request.groupTag)
        return .failed(reason: reason)
    }
}
