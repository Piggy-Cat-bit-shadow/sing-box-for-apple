import XCTest

@testable import Contract

/// B — the commit points, driven as interleavings rather than as two strings.
///
/// Each case fixes the order at a real boundary of `RemoteRefreshApplier` (the body commit, the
/// post-write read, the reload) and then asserts what the loser of the race did NOT do. The point is
/// never "the verdict is superseded"; it is that a superseded update has no side effect.
final class InterleavingTests: XCTestCase {
    private let olderBody = "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"old\"}]}"
    private let newerBody = "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"new\"}]}"

    private func outcome(body: String) -> RemoteRefreshOutcome {
        RemoteRefreshOutcome(
            subscriptionInfo: nil,
            subscriptionInfoUpdatedAt: nil,
            capture: .missing,
            usedMetadataProbe: false,
            writeBody: true,
            reloadService: true,
            bodyToWrite: body
        )
    }

    /// The store the two updates fight over: one body slot, exactly like the profile file.
    private final class BodyStore {
        private let lock = NSLock()
        private var body: String

        init(_ body: String) {
            self.body = body
        }

        /// The test-and-set a real commit performs: read, compare, write, all inside the lock.
        func commit(_ candidate: String, expectingRevision: String?) -> ProfileBodyCommit {
            lock.lock()
            defer { lock.unlock() }
            let storedRevision = ConfigurationBodyRevision.fingerprint(of: body)
            guard storedRevision == expectingRevision else {
                return .superseded(storedRevision: storedRevision)
            }
            body = candidate
            return .committed(newRevision: ConfigurationBodyRevision.fingerprint(of: candidate))
        }

        /// The pre-fix protocol, kept here to demonstrate what it does: the comparison and the write
        /// are two separate steps, so another update can commit in between.
        func legacyCommit(
            _ candidate: String,
            expectingRevision: String?,
            pauseBetweenCompareAndWrite: () -> Void
        ) -> Bool {
            lock.lock()
            let storedRevision = ConfigurationBodyRevision.fingerprint(of: body)
            lock.unlock()
            pauseBetweenCompareAndWrite()
            guard storedRevision == expectingRevision else {
                return false
            }
            lock.lock()
            body = candidate
            lock.unlock()
            return true
        }

        var current: String {
            lock.lock()
            defer { lock.unlock() }
            return body
        }

        var revision: String {
            ConfigurationBodyRevision.fingerprint(of: current)
        }
    }

    /// The interleaving the audit reproduced: A1 compares, A2 commits `newer`, A1 writes `older`.
    /// Under the two-step protocol the disk ends with the OLD body - that is why the protocol is gone.
    func testTheTwoStepProtocolLosesTheRaceItWasSupposedToPrevent() {
        let store = BodyStore(olderBody)
        let expected = store.revision
        var resultA1 = true
        // A1 is released after A2 has already committed.
        resultA1 = store.legacyCommit(olderBody, expectingRevision: expected) {
            _ = store.commit(self.newerBody, expectingRevision: expected)
        }
        XCTAssertTrue(resultA1, "the old protocol let the late update believe it had won")
        XCTAssertEqual(store.current, olderBody,
                       "and it overwrote the newer body: the comparison and the write were separate")
    }

    /// The same interleaving through the committed protocol: the comparison and the write are one
    /// operation, so the late update cannot win.
    func testALateUpdateCannotOverwriteTheOneThatWon() async throws {
        let store = BodyStore(olderBody)
        let expected = store.revision
        _ = store.commit(newerBody, expectingRevision: expected)

        var wrote: [String] = []
        var reloads = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: olderBody),
            applyMetadata: {},
            persist: {},
            commitBody: { body in
                let verdict = store.commit(body, expectingRevision: expected)
                if case .committed = verdict {
                    wrote.append(body)
                }
                return verdict
            },
            reloadService: { _ in
                reloads += 1
                return .applied(.restarted, activeRevision: "newer")
            },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertTrue(wrote.isEmpty, "the loser must not touch the body the winner wrote")
        XCTAssertEqual(reloads, 0, "and must not reload the winner's instance")
        XCTAssertEqual(store.current, newerBody)
    }

    /// The same race, seen from the other side: the newer update commits normally.
    func testTheWinnerOfTheSameRaceCommits() async throws {
        let store = BodyStore(olderBody)
        let expected = store.revision
        var wrote: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: {},
            persist: {},
            commitBody: { body in
                let verdict = store.commit(body, expectingRevision: expected)
                if case .committed = verdict {
                    wrote.append(body)
                }
                return verdict
            },
            storedBody: { store.current },
            reloadService: { _ in .applied(.restarted, activeRevision: "newer") },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(wrote, [newerBody])
        XCTAssertEqual(store.current, newerBody)
    }

    /// The stored-body check is the LAST thing before the send, not the first thing after the write.
    ///
    /// With the check right after the write there were two awaits (`canApply`, `isStillCurrent`)
    /// between the proof and the commit, and another writer replacing the body in that gap made this
    /// operation apply the older document while both updates reported a coherent story. It cannot be
    /// atomic with the send - the send is the commit and it crosses a process - but it can be adjacent
    /// to it.
    func testTheStoredBodyIsCheckedImmediatelyBeforeTheSend() async throws {
        var events: [String] = []
        let store = BodyStore(olderBody)
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            commitBody: { body in
                events.append("commit")
                let verdict = store.commit(body, expectingRevision: store.revision)
                return verdict
            },
            storedBody: {
                events.append("storedBody")
                return store.current
            },
            reloadService: { _ in
                events.append("reload")
                return .applied(.restarted, activeRevision: "newer")
            },
            canApply: {
                events.append("canApply")
                return true
            },
            isStillCurrent: {
                events.append("isStillCurrent")
                return true
            },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(
            events,
            ["metadata", "persist", "commit", "canApply", "isStillCurrent", "storedBody", "reload",
             "isStillCurrent", "storedBody"],
            "the stored-body proof sits between the last cheap check and the send, and is repeated afterwards"
        )
    }

    /// A failed apply must not roll the body back. The new body is what the user asked for and what is
    /// on disk; the failure is about the running instance, and the daemon's own report says whether
    /// the previous document is still serving. There is no restore path here, and a second write would
    /// be one.
    func testAFailedApplyDoesNotRollTheBodyBack() async throws {
        let store = BodyStore(olderBody)
        var writes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: {},
            persist: {},
            commitBody: { body in
                writes += 1
                return store.commit(body, expectingRevision: store.revision)
            },
            storedBody: { store.current },
            reloadService: { _ in throw NSError(domain: "test", code: 7) },
            refreshProviders: { _ in .notActive }
        )
        guard case .applyFailed = report.config else {
            return XCTFail("a refused reload is a failure, got \(report.config)")
        }
        XCTAssertEqual(writes, 1, "exactly one commit: the user's body, never a rollback")
        XCTAssertEqual(store.current, newerBody)
    }

    /// A recovery is not a rollback either: the daemon recovered to its stored last-good document, the
    /// body on disk is still the one this update wrote, and nothing rewrites it.
    func testARecoveryDoesNotRewriteTheBody() async throws {
        let store = BodyStore(olderBody)
        var writes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: {},
            persist: {},
            commitBody: { body in
                writes += 1
                return store.commit(body, expectingRevision: store.revision)
            },
            storedBody: { store.current },
            reloadService: { _ in .recovered(activeRevision: "stored-1") },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .recovered(activeRevision: "stored-1"))
        XCTAssertEqual(writes, 1, "the recovery is the daemon's, not a rewrite by this update")
        XCTAssertEqual(store.current, newerBody)
    }
}
