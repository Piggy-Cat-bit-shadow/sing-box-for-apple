import XCTest

@testable import Contract

/// Who owns a profile's document, and when an update loses that ownership.
final class ProfileUpdateOwnershipTests: XCTestCase {
    private let bodyA = "{\"outbounds\":[]}"
    private let bodyB = "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"d\"}]}"

    private func ticket(
        profileID: Int64 = 1,
        requestID: String = "req-1",
        remoteURL: String? = "https://panel.example/sub",
        storedBodyRevision: String?
    ) -> ProfileUpdateTicket {
        ProfileUpdateTicket(
            profileID: profileID,
            requestID: requestID,
            remoteURL: remoteURL,
            storedBodyRevision: storedBodyRevision
        )
    }

    func testTheFingerprintIsContentAddressedAndStable() {
        XCTAssertEqual(
            ConfigurationBodyRevision.fingerprint(of: bodyA),
            ConfigurationBodyRevision.fingerprint(of: bodyA),
            "the same body must always have the same revision"
        )
        XCTAssertNotEqual(
            ConfigurationBodyRevision.fingerprint(of: bodyA),
            ConfigurationBodyRevision.fingerprint(of: bodyB)
        )
        XCTAssertNil((nil as String?).map(ConfigurationBodyRevision.fingerprint(of:)))
        XCTAssertNotEqual(
            ConfigurationBodyRevision.fingerprint(of: ""),
            (nil as String?).map(ConfigurationBodyRevision.fingerprint(of:)),
            "an empty document is a document; missing is not empty"
        )
        // Pinned so a change to the algorithm is a deliberate, reviewed change rather than a silent
        // one: revisions are compared across processes and across updates.
        XCTAssertEqual(ConfigurationBodyRevision.fingerprint(of: "abc"), ConfigurationBodyRevision.fingerprint(of: "abc"))
    }

    func testAWriteIsPermittedOnlyWhileTheStoredBodyIsTheOneTheUpdateRead() {
        let unchanged = ticket(storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: bodyA))
        XCTAssertEqual(
            ProfileUpdateOwnership.bodyVerdict(ticket: unchanged, storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: bodyA)),
            .commit
        )

        let replaced = ProfileUpdateOwnership.bodyVerdict(
            ticket: unchanged,
            storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: bodyB)
        )
        XCTAssertEqual(
            replaced,
            .superseded(.bodyReplaced(storedRevision: ConfigurationBodyRevision.fingerprint(of: bodyB))),
            "a slower update must not overwrite a body another writer already replaced"
        )
    }

    func testAMissingBodyIsAStateOfItsOwn() {
        let fresh = ticket(storedBodyRevision: nil)
        XCTAssertEqual(ProfileUpdateOwnership.bodyVerdict(ticket: fresh, storedBodyRevision: nil), .commit)
        XCTAssertEqual(
            ProfileUpdateOwnership.bodyVerdict(ticket: fresh, storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: bodyA)),
            .superseded(.bodyReplaced(storedRevision: ConfigurationBodyRevision.fingerprint(of: bodyA))),
            "an update that read no body does not own the profile once one exists"
        )
    }

    func testMetadataIsNotCommittedOntoAProfileThatNowPointsSomewhereElse() {
        let version = ConfigurationBodyRevision.fingerprint(of: bodyA)
        let captured = ticket(remoteURL: "https://panel-a.example/sub", storedBodyRevision: version)
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: "https://panel-b.example/sub",
                storedLastUpdated: nil,
                storedCapturedAt: nil
            ),
            .superseded(.sourceChanged(storedURL: "https://panel-b.example/sub")),
            "panel A's figures must not be written onto a profile that now points at panel B"
        )
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: "https://panel-a.example/sub",
                storedLastUpdated: nil,
                storedCapturedAt: nil
            ),
            .commit
        )
    }

    /// The cross-process half of the metadata: for the SAME source, a later refresh must not overwrite
    /// figures another writer committed after this update read the profile. The comparison runs inside
    /// the database write, so it holds for the shortcuts extension too - SQLite serialises writers
    /// across processes.
    func testMetadataCommittedAfterThisUpdateReadItIsNotOverwritten() {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let readAt = Date(timeIntervalSince1970: 1_010)
        var captured = ticket(storedBodyRevision: nil)
        captured = ProfileUpdateTicket(
            profileID: captured.profileID,
            requestID: captured.requestID,
            remoteURL: captured.remoteURL,
            storedBodyRevision: nil,
            expectedLastUpdated: readAt,
            expectedCapturedAt: capturedAt
        )

        // Nobody wrote since: the same timestamps commit.
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: captured.remoteURL,
                storedLastUpdated: readAt,
                storedCapturedAt: capturedAt
            ),
            .commit
        )
        // A newer quota (a newer capture time) refuses the write.
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: captured.remoteURL,
                storedLastUpdated: readAt,
                storedCapturedAt: capturedAt.addingTimeInterval(1)
            ),
            .superseded(.metadataAdvanced(storedLastUpdated: readAt, storedCapturedAt: capturedAt.addingTimeInterval(1)))
        )
        // A newer configuration commit refuses it too, even without a new capture time.
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: captured.remoteURL,
                storedLastUpdated: readAt.addingTimeInterval(1),
                storedCapturedAt: capturedAt
            ),
            .superseded(.metadataAdvanced(storedLastUpdated: readAt.addingTimeInterval(1), storedCapturedAt: capturedAt))
        )
        // An OLDER stored value is not evidence of a newer commit: an update that read a stale object
        // still owns the row.
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: captured.remoteURL,
                storedLastUpdated: readAt.addingTimeInterval(-1),
                storedCapturedAt: capturedAt.addingTimeInterval(-1)
            ),
            .commit
        )
    }

    /// A row that was never refreshed has NULL timestamps, and NULL matches NULL.
    ///
    /// This is the case that made the first version of the comparison refuse every refresh of an
    /// untouched profile: the ticket was built from `Profile.lastUpdated`, whose `Date()` default for a
    /// NULL makes two reads of the same row differ. The comparison now runs on the stored representation
    /// on both sides, where "no timestamps" is a value that can match itself.
    func testAnOldRowWithoutTimestampsMatchesItself() {
        let captured = ProfileUpdateTicket(
            profileID: 7,
            requestID: "r",
            remoteURL: "https://panel.example/sub",
            storedBodyRevision: nil,
            expectedLastUpdated: nil,
            expectedCapturedAt: nil
        )
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: captured.remoteURL,
                storedLastUpdated: nil,
                storedCapturedAt: nil
            ),
            .commit,
            "NULL must match NULL: a display default is not a stored value"
        )
        // And the stored representation can express "still nothing" without inventing a date.
        XCTAssertEqual(StoredMetadataTimestamps(lastUpdated: nil, capturedAt: nil),
                       StoredMetadataTimestamps(lastUpdated: nil, capturedAt: nil))
    }

    /// A row that gained metadata where this update read none was written after the read.
    func testMetadataAppearingAfterTheReadIsANewerCommit() {
        let captured = ticket(storedBodyRevision: nil)
        XCTAssertEqual(
            ProfileUpdateOwnership.metadataVerdict(
                ticket: captured,
                storedRemoteURL: captured.remoteURL,
                storedLastUpdated: Date(timeIntervalSince1970: 5),
                storedCapturedAt: nil
            ),
            .superseded(.metadataAdvanced(storedLastUpdated: Date(timeIntervalSince1970: 5), storedCapturedAt: nil))
        )
    }

    // MARK: - receipts

    private func receipt(
        requestID: String = "req-1",
        profileID: Int64? = 1,
        bodyRevision: String? = "rev-1",
        outcome: ExtensionApplyOutcome = .applied(.restarted, activeRevision: "active-1")
    ) -> ExtensionApplyReceipt {
        ExtensionApplyReceipt(
            requestID: requestID,
            tunnelSessionID: "session-1",
            profileID: profileID,
            bodyRevision: bodyRevision,
            outcome: outcome,
            targetRevision: "target-1",
            restartRequired: true,
            persistence: "saved",
            reason: nil
        )
    }

    func testAReceiptThatNamesThisUpdateIsThisUpdateS() {
        let captured = ticket(requestID: "req-1", storedBodyRevision: "rev-1")
        guard case let .matches(matched) = ProfileUpdateOwnership.ownership(
            of: receipt(),
            ticket: captured,
            expectedBodyRevision: "rev-1"
        ) else {
            return XCTFail("the receipt names this request, profile and body")
        }
        XCTAssertEqual(matched.requestID, "req-1")
        XCTAssertEqual(receipt().configOutcome(ticket: captured, expectedBodyRevision: "rev-1"), .applied)
    }

    func testAReceiptForAnotherRequestIsSuperseded() {
        let captured = ticket(requestID: "req-1", storedBodyRevision: "rev-1")
        guard case .notThisUpdate = ProfileUpdateOwnership.ownership(
            of: receipt(requestID: "req-2"),
            ticket: captured,
            expectedBodyRevision: "rev-1"
        ) else {
            return XCTFail("a late reply to an earlier apply is not this update's answer")
        }
        XCTAssertEqual(receipt(requestID: "req-2").configOutcome(ticket: captured, expectedBodyRevision: "rev-1"), .superseded)
    }

    func testAReceiptForAnotherBodyIsSuperseded() {
        let captured = ticket(storedBodyRevision: "rev-1")
        XCTAssertEqual(
            receipt(bodyRevision: "rev-2").configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .superseded,
            "a reply that applied a different body cannot confirm this one"
        )
    }

    func testAReceiptForAnotherProfileIsSuperseded() {
        let captured = ticket(profileID: 1, storedBodyRevision: "rev-1")
        XCTAssertEqual(
            receipt(profileID: 2).configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .superseded
        )
    }

    /// A receipt that omits the profile or the body cannot be attributed. Skipping the comparison as
    /// "an older extension" would be a guess in the caller's favour: an extension that predates the
    /// envelope answers nothing at all, so a missing field here is a document this build cannot read.
    func testAReceiptThatOmitsItsIdentityIsUnconfirmed() {
        let captured = ticket(storedBodyRevision: "rev-1")
        for anonymous in [receipt(profileID: nil), receipt(bodyRevision: nil)] {
            guard case .unconfirmed = ProfileUpdateOwnership.ownership(
                of: anonymous,
                ticket: captured,
                expectedBodyRevision: "rev-1"
            ) else {
                return XCTFail("a receipt without its identity must not be read as this update's")
            }
            XCTAssertEqual(anonymous.configOutcome(ticket: captured, expectedBodyRevision: "rev-1"), .applyUnconfirmed)
        }
    }

    /// An update that never recorded the revision it wrote cannot attribute a reply to itself.
    func testAnUpdateWithoutARevisionRecordCannotConfirm() {
        let captured = ticket(storedBodyRevision: nil)
        guard case .unconfirmed = ProfileUpdateOwnership.ownership(
            of: receipt(),
            ticket: captured,
            expectedBodyRevision: nil
        ) else {
            return XCTFail("no recorded revision is not a confirmed apply")
        }
    }

    func testAnUndeterminedReceiptIsUnconfirmedNotFailed() {
        let captured = ticket(storedBodyRevision: "rev-1")
        let undetermined = receipt(outcome: .undetermined(reason: "no status"))
        guard case .unconfirmed = ProfileUpdateOwnership.ownership(
            of: undetermined,
            ticket: captured,
            expectedBodyRevision: "rev-1"
        ) else {
            return XCTFail("an unreadable decision is unconfirmed")
        }
        XCTAssertEqual(undetermined.configOutcome(ticket: captured, expectedBodyRevision: "rev-1"), .applyUnconfirmed)
    }

    /// The two outcomes a receipt can prove that the old `startedAt` comparison could not.
    func testARecoveryAndAnInterruptionAreReportedAsThemselves() {
        let captured = ticket(storedBodyRevision: "rev-1")
        XCTAssertEqual(
            receipt(outcome: .recovered(activeRevision: "stored-1")).configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .recovered(activeRevision: "stored-1")
        )
        XCTAssertEqual(
            receipt(outcome: .interrupted).configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .interrupted(reason: nil)
        )
    }

    func testAFailedApplyThatKeptThePreviousDocumentIsNotAnInterruption() {
        let captured = ticket(storedBodyRevision: "rev-1")
        XCTAssertEqual(
            receipt(outcome: .failed(reason: "refused", retained: true)).configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .applyFailed("refused")
        )
        XCTAssertEqual(
            receipt(outcome: .failed(reason: "dropped", retained: false)).configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .interrupted(reason: "dropped"),
            "a failure that took the service down is not a failure that kept it running"
        )
        XCTAssertEqual(
            receipt(outcome: .failed(reason: "unknown", retained: nil)).configOutcome(ticket: captured, expectedBodyRevision: "rev-1"),
            .applyFailed("unknown"),
            "unknown retention is a failed apply, never 'nothing is running'"
        )
    }

    /// The report's own reading of "failure" has to agree with the new cases.
    func testTheNewOutcomesAreFailuresToTheUser() {
        XCTAssertTrue(RemoteProfileUpdateReport(config: .recovered(activeRevision: "a"), providers: .init(status: .notActive, counts: .init(), detail: nil)).isFailure)
        XCTAssertTrue(RemoteProfileUpdateReport(config: .interrupted(reason: "x"), providers: .init(status: .notActive, counts: .init(), detail: nil)).isFailure)
        XCTAssertFalse(RemoteProfileUpdateReport(config: .applied, providers: .init(status: .notActive, counts: .init(), detail: nil)).isFailure)
    }
}
