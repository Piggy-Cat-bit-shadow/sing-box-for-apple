import XCTest

@testable import Contract

/// The body has two writers in one process: a remote refresh (read-compare-write) and an editor save
/// (unconditional). They must not interleave INSIDE the refresh's commit, because then the refresh
/// discards the save while both sides report success.
///
/// These drive the mechanism, not the claim: one shared lock, two threads, and a pause that puts the
/// save attempt exactly between the refresh's comparison and its write.
final class BodyCommitLockTests: XCTestCase {
    private let initial = "{\"outbounds\":[],\"tag\":\"initial\"}"
    private let fetched = "{\"outbounds\":[],\"tag\":\"fetched\"}"
    private let edited = "{\"outbounds\":[],\"tag\":\"edited\"}"

    private final class Store {
        var body: String
        init(_ body: String) {
            self.body = body
        }

        var revision: String {
            ConfigurationBodyRevision.fingerprint(of: body)
        }
    }

    /// The defect, as a model: a commit that compares and then writes WITHOUT a shared lock lets a
    /// save land in between, and the commit overwrites it.
    func testASaveBetweenTheComparisonAndTheWriteIsLostWithoutTheLock() {
        let store = Store(initial)
        let expectedRevision = store.revision
        // The commit's comparison.
        XCTAssertEqual(store.revision, expectedRevision)
        // The editor's save, landing in the gap.
        store.body = edited
        // The commit's write.
        store.body = fetched
        XCTAssertEqual(store.body, fetched,
                       "the save is gone - this is the interleaving the shared lock removes")
    }

    /// With the shared lock the same interleaving is impossible, and both remaining orders are
    /// defined: save first (the commit supersedes) or commit first (the save then wins).
    func testASaveCannotLandInsideACommitThatHoldsTheSharedLock() {
        let lock = BodyCommitLock()
        let store = Store(initial)
        let expectedRevision = store.revision
        let saveAttempted = expectation(description: "the save ran")
        let commitFinished = expectation(description: "the commit finished")
        let pause = DispatchSemaphore(value: 0)
        let saveIsWaiting = DispatchSemaphore(value: 0)

        var commitIsInsideItsCriticalSection = false
        var saveRanBetweenCompareAndWrite = false
        var commitVerdict: ProfileBodyCommit?

        DispatchQueue.global().async {
            commitVerdict = lock.withLock {
                if store.revision != expectedRevision {
                    return .superseded(storedRevision: store.revision)
                }
                commitIsInsideItsCriticalSection = true
                // Let the other writer try to run at the worst possible moment.
                saveIsWaiting.signal()
                _ = pause.wait(timeout: .now() + 2)
                commitIsInsideItsCriticalSection = false
                store.body = self.fetched
                return .committed(newRevision: ConfigurationBodyRevision.fingerprint(of: self.fetched))
            }
            commitFinished.fulfill()
        }

        DispatchQueue.global().async {
            _ = saveIsWaiting.wait(timeout: .now() + 2)
            // This blocks until the commit releases the lock.
            lock.withLock {
                if commitIsInsideItsCriticalSection {
                    saveRanBetweenCompareAndWrite = true
                }
                store.body = self.edited
            }
            saveAttempted.fulfill()
            pause.signal()
        }

        wait(for: [saveAttempted, commitFinished], timeout: 10)
        XCTAssertFalse(saveRanBetweenCompareAndWrite,
                       "the save ran between the comparison and the write: the lock did not serialise them")
        XCTAssertEqual(commitVerdict, .committed(newRevision: ConfigurationBodyRevision.fingerprint(of: fetched)))
        // The save landed after the commit, which is the defined order where the user's edit wins.
        XCTAssertEqual(store.body, edited,
                       "the save must be the last writer's body, not discarded by the commit")
    }

    /// The other order: the save lands BEFORE the commit reads, so the commit supersedes instead of
    /// overwriting it.
    func testASaveThatLandsFirstMakesTheCommitSupersede() {
        let lock = BodyCommitLock()
        let store = Store(initial)
        let expectedRevision = store.revision
        lock.withLock { store.body = edited }

        let verdict = lock.withLock { () -> ProfileBodyCommit in
            guard store.revision == expectedRevision else {
                return .superseded(storedRevision: store.revision)
            }
            store.body = fetched
            return .committed(newRevision: ConfigurationBodyRevision.fingerprint(of: fetched))
        }
        XCTAssertEqual(verdict, .superseded(storedRevision: ConfigurationBodyRevision.fingerprint(of: edited)))
        XCTAssertEqual(store.body, edited, "the commit must not overwrite the body it did not read")
    }
}
