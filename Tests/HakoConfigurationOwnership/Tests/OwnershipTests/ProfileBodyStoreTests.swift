import XCTest

@testable import Contract

/// The cross-process half of a body commit.
///
/// The app and the shortcuts extension write the same file, each with its own in-process lock.
/// These tests use two `ProfileBodyStore` instances on one file to stand in for the two processes:
/// the directory lock, the sidecar revision and the journal are the only things that cross.
final class ProfileBodyStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-body-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private var bodyURL: URL {
        root.appendingPathComponent("config_7.json")
    }

    private func makeStore(lockTimeout: TimeInterval = 5, staleLockAge: TimeInterval = 30) -> ProfileBodyStore {
        ProfileBodyStore(bodyURL: bodyURL, lockTimeout: lockTimeout, staleLockAge: staleLockAge)
    }

    private func body() throws -> String? {
        guard FileManager.default.fileExists(atPath: bodyURL.path) else {
            return nil
        }
        return try String(contentsOf: bodyURL, encoding: .utf8)
    }

    private func writeJournal(previousRevision: String?, intentRevision: String, generation: UInt64) throws {
        var journal: [String: Any] = [
            "schema": 1,
            "intentRevision": intentRevision,
            "generation": generation,
            "writer": "crashed-request",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let previousRevision {
            journal["previousRevision"] = previousRevision
        } else {
            journal["previousRevision"] = NSNull()
        }
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: makeStore().journalURL)
    }

    func testTheFirstCommitWritesTheBodyAndItsRevision() throws {
        let outcome = try makeStore().commit("{\"tag\":\"a\"}", expecting: nil, writer: "request-1")
        guard case let .committed(state) = outcome else {
            return XCTFail("expected committed, got \(outcome)")
        }
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.writer, "request-1")
        XCTAssertEqual(state.revision, ConfigurationBodyRevision.fingerprint(of: "{\"tag\":\"a\"}"))
        XCTAssertEqual(try body(), "{\"tag\":\"a\"}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: makeStore().sidecarURL.path),
                      "the revision is stored next to the body, not only in memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: makeStore().journalURL.path),
                       "a completed commit leaves no journal")
    }

    func testACommitThatReadAnOlderRevisionIsSuperseded() throws {
        _ = try makeStore().commit("A", expecting: nil, writer: "request-1")
        let revisionOfA = ConfigurationBodyRevision.fingerprint(of: "A")
        _ = try makeStore().commit("B", expecting: revisionOfA, writer: "request-2")

        let late = try makeStore().commit("C", expecting: revisionOfA, writer: "request-3")
        guard case let .superseded(storedRevision) = late else {
            return XCTFail("expected superseded, got \(late)")
        }
        XCTAssertEqual(storedRevision, ConfigurationBodyRevision.fingerprint(of: "B"))
        XCTAssertEqual(try body(), "B", "the losing writer did not touch the file")
    }

    func testAnOldWriterLosesAcrossTwoStoreInstances() throws {
        // The interleaving the in-process lock cannot see: instance one reads, instance two
        // commits, instance one tries to commit what it read.
        let one = makeStore()
        let two = makeStore()
        _ = try one.commit("A", expecting: nil, writer: "process-one")
        let readRevision = try XCTUnwrap(try one.currentState()?.revision)
        _ = try two.commit("B", expecting: readRevision, writer: "process-two")
        let late = try one.commit("C", expecting: readRevision, writer: "process-one")
        guard case let .superseded(storedRevision) = late else {
            return XCTFail("expected superseded, got \(late)")
        }
        XCTAssertEqual(storedRevision, ConfigurationBodyRevision.fingerprint(of: "B"))
        XCTAssertEqual(try body(), "B")
    }

    func testTheDirectoryLockBlocksASecondStore() throws {
        let holder = makeStore()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        holder.beforeBodyWrite = {
            entered.signal()
            release.wait()
        }

        let finished = DispatchSemaphore(value: 0)
        var heldOutcome: ProfileBodyCommitOutcome?
        DispatchQueue.global().async {
            heldOutcome = try? holder.commit("held", expecting: nil, writer: "process-one")
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the holder reached its critical section")

        let blocked = try? makeStore(lockTimeout: 0.3).commit("intruder", expecting: nil, writer: "process-two")
        XCTAssertNil(blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path),
                       "the second writer wrote nothing while the lock was held")

        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try body(), "held")
        guard case .committed = heldOutcome else {
            return XCTFail("the holder's own commit did not complete")
        }
    }

    func testTheSecondWriterProceedsOnceTheLockIsReleased() throws {
        _ = try makeStore().commit("first", expecting: nil, writer: "process-one")
        let outcome = try makeStore().commit("second", expecting: ConfigurationBodyRevision.fingerprint(of: "first"), writer: "process-two")
        guard case .committed = outcome else {
            return XCTFail("expected committed, got \(outcome)")
        }
        XCTAssertEqual(try body(), "second")
    }

    func testAnInterruptedCommitIsCompletedFromItsJournal() throws {
        // The crash window: the body was replaced, the sidecar was not written.
        try Data("B".utf8).write(to: bodyURL)
        try writeJournal(
            previousRevision: ConfigurationBodyRevision.fingerprint(of: "A"),
            intentRevision: ConfigurationBodyRevision.fingerprint(of: "B"),
            generation: 2
        )

        let state = try XCTUnwrap(try makeStore().currentState())
        XCTAssertEqual(state.revision, ConfigurationBodyRevision.fingerprint(of: "B"))
        XCTAssertEqual(state.generation, 2, "the interrupted commit's generation is adopted, not invented")
        XCTAssertEqual(state.writer, "crashed-request")
        XCTAssertFalse(FileManager.default.fileExists(atPath: makeStore().journalURL.path),
                       "recovery clears the journal")
        XCTAssertEqual(try body(), "B")
    }

    func testAnInterruptedCommitThatCannotBeReconciledIsRefused() throws {
        try Data("C".utf8).write(to: bodyURL)
        try writeJournal(
            previousRevision: ConfigurationBodyRevision.fingerprint(of: "A"),
            intentRevision: ConfigurationBodyRevision.fingerprint(of: "B"),
            generation: 2
        )

        XCTAssertThrowsError(try makeStore().currentState()) { error in
            guard case ProfileBodyStoreError.untrustedBody = error else {
                return XCTFail("expected untrustedBody, got \(error)")
            }
        }
        XCTAssertEqual(try body(), "C", "an unattributable body is left alone, not repaired into a guess")
        XCTAssertTrue(FileManager.default.fileExists(atPath: makeStore().journalURL.path),
                      "the journal is kept as the evidence that something is wrong")
    }

    func testASaveIsUnconditionalAndAdvancesTheGeneration() throws {
        _ = try makeStore().commit("A", expecting: nil, writer: "request-1")
        let saved = try makeStore().save("B", writer: "editor-save")
        guard case let .committed(state) = saved else {
            return XCTFail("expected committed, got \(saved)")
        }
        XCTAssertEqual(state.generation, 2)
        XCTAssertEqual(try body(), "B")
    }

    func testCreateRefusesToReplaceAnExistingBody() throws {
        _ = try makeStore().create("A", writer: "new-profile")
        let second = try makeStore().create("B", writer: "other-new-profile")
        guard case let .superseded(storedRevision) = second else {
            return XCTFail("expected superseded, got \(second)")
        }
        XCTAssertEqual(storedRevision, ConfigurationBodyRevision.fingerprint(of: "A"))
        XCTAssertEqual(try body(), "A")
    }

    func testRemoveDeletesTheBodyAndItsCompanions() throws {
        _ = try makeStore().commit("A", expecting: nil, writer: "request-1")
        try makeStore().remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: makeStore().sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: makeStore().lockURL.path))
    }

    func testAnAbandonedLockIsReclaimed() throws {
        try FileManager.default.createDirectory(at: makeStore().lockURL, withIntermediateDirectories: false)
        // A lock whose owner died leaves no process to remove it. `staleLockAge: 0` models that
        // abandoned directory without depending on being able to move a directory's mtime, which
        // some filesystems (and Windows) refuse.
        let outcome = try makeStore(staleLockAge: 0).commit("A", expecting: nil, writer: "request-1")
        guard case .committed = outcome else {
            return XCTFail("expected committed, got \(outcome)")
        }
        XCTAssertEqual(try body(), "A")
    }

    func testABodyThatIsNotUTF8IsRefused() throws {
        try Data([0xFF, 0xFE]).write(to: bodyURL)
        XCTAssertThrowsError(try makeStore().commit("A", expecting: nil, writer: "request-1")) { error in
            guard case ProfileBodyStoreError.untrustedBody = error else {
                return XCTFail("expected untrustedBody, got \(error)")
            }
        }
    }
}
