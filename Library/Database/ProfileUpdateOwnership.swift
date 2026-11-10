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
    /// The metadata timestamps this update read, with the body, at decision time.
    ///
    /// They are the metadata half's compare-and-set: the URL says WHICH subscription the figures
    /// describe, these say WHETHER anyone committed newer ones since. Without them a late refresh of
    /// the same URL overwrites a newer quota and a newer capture time - the source check cannot see
    /// that, because the source did not change.
    public let expectedLastUpdated: Date?
    public let expectedCapturedAt: Date?

    public init(
        profileID: Int64,
        requestID: String,
        remoteURL: String?,
        storedBodyRevision: String?,
        expectedLastUpdated: Date? = nil,
        expectedCapturedAt: Date? = nil
    ) {
        self.profileID = profileID
        self.requestID = requestID
        self.remoteURL = remoteURL
        self.storedBodyRevision = storedBodyRevision
        self.expectedLastUpdated = expectedLastUpdated
        self.expectedCapturedAt = expectedCapturedAt
    }
}

/// Why an update no longer owns what it was about to commit.
public enum ProfileSupersedeReason: Equatable, Sendable {
    /// The stored body is not the one this update read: another writer got there first.
    case bodyReplaced(storedRevision: String?)
    /// The profile now points at a different remote source.
    case sourceChanged(storedURL: String?)
    /// Someone committed metadata for the SAME source after this update read it: a newer quota, or
    /// a newer capture time. The URL check cannot see this - the source did not change.
    case metadataAdvanced(storedLastUpdated: Date?, storedCapturedAt: Date?)
}

/// Whether a commit may proceed.
public enum ProfileCommitVerdict: Equatable, Sendable {
    case commit
    case superseded(ProfileSupersedeReason)
}

/// The outcome of one test-and-set body commit.
///
/// It is a RETURN VALUE of a single operation, not two calls the caller has to keep adjacent: the
/// comparison and the write have to happen in one critical section, or another writer can install a
/// newer body between them and this update overwrites it. Handing the caller a "read the revision"
/// closure and a "write the body" closure makes that mistake the easy one to make.
public enum ProfileBodyCommit: Equatable, Sendable {
    /// The body this update wrote is now the stored one.
    case committed(newRevision: String)
    /// The stored body was no longer the one this update read. Nothing was written.
    case superseded(storedRevision: String?)
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
        case let .metadataAdvanced(storedLastUpdated, storedCapturedAt):
            // Rendered without the dates on purpose: this string reaches a user-facing alert, and a
            // wall-clock timestamp there reads as a failure the user caused.
            _ = storedLastUpdated
            _ = storedCapturedAt
            return "a newer update committed this subscription's metadata while this one was running"
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
    /// Two questions, because the database knows two things: which subscription the row is about (the
    /// URL), and whether somebody committed newer FIGURES for that subscription while this update was
    /// in flight (the timestamps). It cannot answer the third - whether the body it describes is still
    /// the stored one - because the body's authority is the file; that comparison is part of the body
    /// commit, which happens in the file's own critical section.
    ///
    /// The timestamps are the cross-process half. Reading the row and deciding inside the same write
    /// transaction that performs the commit makes this a real compare-and-set for another process
    /// (the shortcuts extension) too, because SQLite serialises writers across processes. A strict
    /// "stored is newer than expected" is the test: equal timestamps mean nobody committed anything
    /// after this update read them.
    public static func metadataVerdict(
        ticket: ProfileUpdateTicket,
        storedRemoteURL: String?,
        storedLastUpdated: Date?,
        storedCapturedAt: Date?
    ) -> ProfileCommitVerdict {
        switch sourceVerdict(ticket: ticket, storedRemoteURL: storedRemoteURL) {
        case let .superseded(reason):
            return .superseded(reason)
        case .commit:
            break
        }
        if isNewer(storedLastUpdated, than: ticket.expectedLastUpdated)
            || isNewer(storedCapturedAt, than: ticket.expectedCapturedAt)
        {
            return .superseded(.metadataAdvanced(storedLastUpdated: storedLastUpdated, storedCapturedAt: storedCapturedAt))
        }
        return .commit
    }

    /// Whether a stored timestamp is evidence of a commit that happened AFTER this update read.
    ///
    /// A stored value where the update read none is such evidence: the row gained metadata after the
    /// read. A stored value that is merely equal is not.
    private static func isNewer(_ stored: Date?, than expected: Date?) -> Bool {
        guard let stored else {
            return false
        }
        guard let expected else {
            return true
        }
        return stored > expected
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
    /// Four things must agree, and every one of them is required: the request id (two applies can
    /// overlap), the profile id (the selection can move), the body revision the extension echoes
    /// back (the stored body can be replaced between the write and the reply), and this update's own
    /// record of the revision it wrote.
    ///
    /// A missing field is NOT skipped as "an older extension": an extension that predates the
    /// envelope answers nothing at all, so a receipt WITHOUT one of these fields is a document this
    /// build cannot attribute - and `unconfirmed` is the answer, not a guess in the caller's favour.
    static func ownership(
        of receipt: ExtensionApplyReceipt,
        ticket: ProfileUpdateTicket,
        expectedBodyRevision: String?
    ) -> ProfileApplyOwnership {
        guard receipt.requestID == ticket.requestID else {
            return .notThisUpdate("the extension answered request \(receipt.requestID)")
        }
        guard let profileID = receipt.profileID else {
            return .unconfirmed("the extension did not name the profile it applied")
        }
        guard profileID == ticket.profileID else {
            return .notThisUpdate("the extension applied profile \(profileID)")
        }
        guard let expectedBodyRevision else {
            return .unconfirmed("this update did not record the body revision it wrote")
        }
        guard let bodyRevision = receipt.bodyRevision else {
            return .unconfirmed("the extension did not name the body it applied")
        }
        guard bodyRevision == expectedBodyRevision else {
            return .notThisUpdate("the extension applied body \(bodyRevision), not the body this update wrote")
        }
        if case let .undetermined(reason) = receipt.outcome {
            return .unconfirmed(reason)
        }
        return .matches(receipt)
    }
}
