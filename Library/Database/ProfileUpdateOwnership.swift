import Foundation

// Who owns a profile's stored document, and when an update loses that ownership.
//
// # The problem this replaces
//
// The shipping order was: persist the metadata, write the body, then re-read the selected profile id
// and the stored body and compare the latter with the body this update just wrote. The last check
// cannot fail in the case it was written for. A slow update of profile A, superseded by a newer
// update of the same profile, still reads back ITS OWN body after its own write - so it reports
// "applied" while the newer document was replaced, and the metadata it just committed may describe a
// different remote URL than the profile now points at.
//
// Comparing a body AFTER writing it proves the write happened. What is needed is a test-and-set: the
// update names the revision it read, and the write happens only while the stored revision is still
// that one.
//
// # Why a content-addressed revision, and not a stored counter
//
// A counter column would need a migration, would be missing on every row written before it, and
// would have to be reconciled with the file store that is the actual authority for the body. A
// fingerprint of the body has none of those problems: it exists for every row ever written, it
// cannot drift from the file, and it is computable in the app, in the extension and in a test. `nil`
// (no body) is distinct from the fingerprint of an empty body, which is a real and different state.
//
// # The three identities this file keeps apart
//
//   - the update's ownership of the local profile (this ticket);
//   - the content the running service was given (`ConfigurationBodyRevision`);
//   - the tunnel session that applied it (`ExtensionApplyReceipt.tunnelSessionID`).
//
// One content can be applied by two sessions, and one session can apply several contents. They are
// not interchangeable, and an update that compares only the profile id cannot see any of them move.

/// A content-addressed revision of one configuration body.
///
/// FNV-1a over the UTF-8 bytes plus the byte count: stable across processes and platforms, cheap
/// enough to compute on every read, and with no dependency beyond Foundation. It is an identity, not
/// a security primitive - the body is the user's own document, and nothing is protected by it.
///
/// There is deliberately no optional overload: a `String?` argument would make every call site
/// choose between two conversions of the same value, and the one case that has to keep `nil`
/// distinct from the empty document is written out explicitly with `map`.
public enum ConfigurationBodyRevision {
    public static func fingerprint(of body: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in body.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let count = body.utf8.count
        return String(format: "%016llx-%llx", hash, UInt64(count))
    }
}

/// One update's identity, captured once and carried to every commit point.
public struct ProfileUpdateTicket: Equatable, Sendable {
    /// The profile this update is about.
    public let profileID: Int64
    /// Unique per request. The extension echoes it, so a reply can be matched to the request that
    /// produced it even when two updates overlap.
    public let requestID: String
    /// The remote source the body was fetched from. An update that resolves a URL, downloads and
    /// then commits must not commit onto a profile whose URL was edited in between.
    public let remoteURL: String?
    /// The revision of the stored body at decision time, or nil when there was none / it could not
    /// be read. This is the value the body write is test-and-set against.
    public let storedBodyRevision: String?

    public init(profileID: Int64, requestID: String, remoteURL: String?, storedBodyRevision: String?) {
        self.profileID = profileID
        self.requestID = requestID
        self.remoteURL = remoteURL
        self.storedBodyRevision = storedBodyRevision
    }
}

/// Why an update no longer owns what it was about to commit.
public enum ProfileSupersedeReason: Equatable, Sendable {
    /// The stored body is not the one this update read: another writer got there first.
    case bodyReplaced(storedRevision: String?)
    /// The profile now points at a different remote source.
    case sourceChanged(storedURL: String?)
}

/// Whether a commit may proceed.
public enum ProfileCommitVerdict: Equatable, Sendable {
    case commit
    case superseded(ProfileSupersedeReason)
}

/// Thrown by the persistence path when an update no longer owns the profile it is committing to.
///
/// It is an error rather than a return value because the commit happens inside a database
/// transaction, whose only way out is a throw. The caller turns it into `.superseded`: it is not a
/// failure of the update, it is the update losing to a newer one.
public struct ProfileSupersededError: LocalizedError, Equatable, Sendable {
    public let reason: ProfileSupersedeReason
    public let requestID: String

    public init(reason: ProfileSupersedeReason, requestID: String) {
        self.reason = reason
        self.requestID = requestID
    }

    public var errorDescription: String? {
        switch reason {
        case let .bodyReplaced(storedRevision):
            return "the stored body is no longer the one this update read (\(storedRevision ?? "none"))"
        case let .sourceChanged(storedURL):
            return "the profile now points at \(storedURL ?? "another source")"
        }
    }
}

/// The ownership rules, as pure functions.
public enum ProfileUpdateOwnership {
    /// The verdict for writing the body, checked immediately before the write.
    public static func bodyVerdict(ticket: ProfileUpdateTicket, storedBodyRevision: String?) -> ProfileCommitVerdict {
        guard storedBodyRevision == ticket.storedBodyRevision else {
            return .superseded(.bodyReplaced(storedRevision: storedBodyRevision))
        }
        return .commit
    }

    /// The verdict for the remote source alone.
    ///
    /// It is separately useful because the two authorities are separate: the database is the
    /// authority for the URL it stores, the file is the authority for the body. A metadata write
    /// that happens inside a database transaction can check the source there; it cannot read the
    /// file, so it must not pretend to check the body.
    public static func sourceVerdict(ticket: ProfileUpdateTicket, storedRemoteURL: String?) -> ProfileCommitVerdict {
        guard storedRemoteURL == ticket.remoteURL else {
            return .superseded(.sourceChanged(storedURL: storedRemoteURL))
        }
        return .commit
    }

    /// The verdict for committing the metadata, checked inside the database write.
    ///
    /// The source is checked as well as the body: metadata describes one subscription, and committing
    /// panel A's figures onto a profile that now points at panel B is the same defect one level up.
    public static func metadataVerdict(
        ticket: ProfileUpdateTicket,
        storedRemoteURL: String?,
        storedBodyRevision: String?
    ) -> ProfileCommitVerdict {
        switch sourceVerdict(ticket: ticket, storedRemoteURL: storedRemoteURL) {
        case let .superseded(reason):
            return .superseded(reason)
        case .commit:
            return bodyVerdict(ticket: ticket, storedBodyRevision: storedBodyRevision)
        }
    }
}

/// What a receipt proves about one update.
///
/// It answers ownership only. Whether the apply SUCCEEDED is the receipt's own outcome, and the two
/// questions are deliberately separate: a receipt that belongs to this update may still say the
/// daemon recovered to another document, and a receipt that says "applied" may belong to a different
/// request.
public enum ProfileApplyOwnership: Equatable, Sendable {
    /// The receipt names this request, this profile and this body.
    case matches(ExtensionApplyReceipt)
    /// The receipt is a valid answer for a different request, profile or body.
    case notThisUpdate(String)
    /// The extension answered, but not in a way this build can read as a decision.
    case unconfirmed(String)
}

public extension ProfileUpdateOwnership {
    /// Whether a receipt may be read as this update's answer.
    ///
    /// Three things must agree: the request id (two applies can overlap), the profile id (the
    /// selection can move), and the body revision the extension echoes back (the stored body can be
    /// replaced between the write and the reply). Anything less is a reply about something else, and
    /// reporting it as "applied" is how a superseded update claims a success it did not have.
    static func ownership(
        of receipt: ExtensionApplyReceipt,
        ticket: ProfileUpdateTicket,
        expectedBodyRevision: String?
    ) -> ProfileApplyOwnership {
        guard receipt.requestID == ticket.requestID else {
            return .notThisUpdate("the extension answered request \(receipt.requestID)")
        }
        if let profileID = receipt.profileID, profileID != ticket.profileID {
            return .notThisUpdate("the extension applied profile \(profileID)")
        }
        if let bodyRevision = receipt.bodyRevision, bodyRevision != expectedBodyRevision {
            return .notThisUpdate("the extension applied body \(bodyRevision), not the body this update wrote")
        }
        if case let .undetermined(reason) = receipt.outcome {
            return .unconfirmed(reason)
        }
        return .matches(receipt)
    }
}
