import Foundation

// The cross-process half of a profile body commit.
//
// # Why this exists
//
// `ProfileUpdateOwnership` made the body write a test-and-set, but the lock around it
// (`BodyCommitLock`) is an `NSLock`: it serialises threads in ONE process. The app and the
// shortcuts extension both write the same `configs/config_<id>.json`, each with its own lock
// instance, so this interleaving is possible today:
//
//   app:      read body -> revision R, compare R == ticket -> about to write
//   extension:                                          read R, compare, write B, rename
//   app:      write A, rename
//
//   both report "committed"; the disk holds A; the extension's B was reported as applied and
//   may even be what the running service was given.
//
// Atomic rename makes that a lost update, not a torn file.
//
// # What replaces it
//
// A directory lock (`mkdir` is atomic in the filesystem, for other processes too), a stored
// revision sidecar, and a commit journal:
//
//   1. take `config_<id>.json.lock/` (create-exclusive, stale after `staleLockAge`);
//   2. recover an interrupted commit from `config_<id>.json.commit`, if there is one;
//   3. read the body, compare its fingerprint with the revision the update read;
//   4. write the journal (previous + intent revisions);
//   5. write the body atomically;
//   6. write the sidecar `config_<id>.json.rev` (revision, generation, writer, time);
//   7. remove the journal and the lock.
//
// A crash between 5 and 6 leaves journal+body and no sidecar. The next access (which is under
// the same lock) completes step 6 from the journal. A journal whose body matches NEITHER the
// previous nor the intent revision is not repaired: it is reported as untrusted and the body is
// left alone, so no caller starts from a document nobody can attribute.
//
// # What this deliberately is not
//
// No SQLite, no GRDB, no migration: the files sit next to the body they describe, which is the
// authority for content, and the sidecar can be deleted at any time - the fingerprint of the body
// then answers the revision question again, at generation 0. Losing the sidecar loses the
// generation, not the content.

/// What the store knows about a stored body.
public struct ProfileBodyState: Codable, Equatable, Sendable {
    /// `ConfigurationBodyRevision.fingerprint` of the stored body.
    public let revision: String
    /// Monotonic per body; 0 for a body written before the sidecar existed.
    public let generation: UInt64
    /// Who wrote it: the request id of an update, or a process label for an editor save.
    public let writer: String
    /// When the sidecar was written.
    public let committedAt: Date

    public init(revision: String, generation: UInt64, writer: String, committedAt: Date) {
        self.revision = revision
        self.generation = generation
        self.writer = writer
        self.committedAt = committedAt
    }
}

/// The result of one commit.
public enum ProfileBodyCommitOutcome: Equatable, Sendable {
    /// The body was written and is now the stored one.
    case committed(ProfileBodyState)
    /// The stored body was not the revision the caller read. Nothing was written.
    case superseded(storedRevision: String?)
    /// An interrupted commit was completed from its journal before this one ran.
    case recovered(ProfileBodyState)
}

/// A body this store refuses to treat as trustworthy.
public enum ProfileBodyStoreError: LocalizedError, Equatable, Sendable {
    /// The journal names a body that is not on disk, and the body on disk is not the one the
    /// journal says it replaced. Nothing is repaired: a caller must not start from it.
    case untrustedBody(reason: String)
    /// The cross-process lock could not be taken within the timeout.
    case lockTimeout
    /// The lock directory exists but belongs to a live-looking writer and could not be reclaimed.
    case lockBusy

    public var errorDescription: String? {
        switch self {
        case let .untrustedBody(reason):
            return "the stored configuration cannot be attributed to a completed commit (\(reason))"
        case .lockTimeout:
            return "another process is writing this configuration"
        case .lockBusy:
            return "another process is writing this configuration"
        }
    }
}

private struct ProfileBodySidecar: Codable {
    let schema: Int
    let revision: String
    let generation: UInt64
    let writer: String
    let committedAt: Date
}

private struct ProfileBodyJournal: Codable {
    let schema: Int
    let previousRevision: String?
    let intentRevision: String
    let generation: UInt64
    let writer: String
    let startedAt: Date
}

/// One profile body's cross-process store.
///
/// `bodyURL` is the file the profile already points at (`FilePath.sharedDirectory` + `path`), so
/// the store owns filenames next to it and nothing else: `bodyURL.rev` and `bodyURL.commit` and
/// `bodyURL.lock/`. Two stores pointed at the same `bodyURL` - in one process or two - serialise
/// through the same directory.
public final class ProfileBodyStore {
    public let bodyURL: URL

    private let fileManager: FileManager
    private let lockTimeout: TimeInterval
    private let staleLockAge: TimeInterval
    private let now: () -> Date

    /// Test seam: runs after the journal is written and before the body is replaced. A test uses
    /// it to hold the critical section open and prove the lock blocks another store.
    var beforeBodyWrite: (() -> Void)?

    public init(
        bodyURL: URL,
        fileManager: FileManager = .default,
        lockTimeout: TimeInterval = 5,
        staleLockAge: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.bodyURL = bodyURL
        self.fileManager = fileManager
        self.lockTimeout = lockTimeout
        self.staleLockAge = staleLockAge
        self.now = now
    }

    public var sidecarURL: URL { bodyURL.appendingPathExtension("rev") }
    public var journalURL: URL { bodyURL.appendingPathExtension("commit") }
    public var lockURL: URL { bodyURL.appendingPathExtension("lock") }

    // MARK: - Public operations

    /// Commits a remote update against the revision it read. The comparison and the write happen
    /// in one cross-process critical section.
    public func commit(_ body: String, expecting expectedRevision: String?, writer: String) throws -> ProfileBodyCommitOutcome {
        try withLock {
            _ = try recoverInterruptedCommit()
            let storedRevision = try readStoredRevision()
            guard storedRevision == expectedRevision else {
                return .superseded(storedRevision: storedRevision)
            }
            let generation = (try readSidecar()?.generation ?? 0) + 1
            return try writeBody(body, previousRevision: storedRevision, generation: generation, writer: writer)
        }
    }

    /// Writes a body this process authored - an editor save. Unconditional on purpose: the user's
    /// save wins, but it still cannot land between another process's comparison and its write.
    public func save(_ body: String, writer: String) throws -> ProfileBodyCommitOutcome {
        try withLock {
            _ = try recoverInterruptedCommit()
            let generation = (try readSidecar()?.generation ?? 0) + 1
            return try writeBody(body, previousRevision: try readStoredRevision(), generation: generation, writer: writer)
        }
    }

    /// Creates a body for a profile that has none. It refuses to replace an existing body: the
    /// creation path chooses a filename from a separately-read id, and two creators can pick the
    /// same one.
    public func create(_ body: String, writer: String) throws -> ProfileBodyCommitOutcome {
        try withLock {
            _ = try recoverInterruptedCommit()
            if fileManager.fileExists(atPath: bodyURL.path) {
                return .superseded(storedRevision: try readStoredRevision())
            }
            return try writeBody(body, previousRevision: nil, generation: 1, writer: writer)
        }
    }

    /// The state of the stored body, recovering an interrupted commit first. `nil` when there is
    /// no body. A journal that cannot be reconciled throws `untrustedBody` instead of guessing.
    public func currentState() throws -> ProfileBodyState? {
        try withLock {
            if case let .recovered(state) = try recoverInterruptedCommit() {
                return state
            }
            guard let revision = try readStoredRevision() else {
                return nil
            }
            if let sidecar = try readSidecar(), sidecar.revision == revision {
                return ProfileBodyState(
                    revision: sidecar.revision,
                    generation: sidecar.generation,
                    writer: sidecar.writer,
                    committedAt: sidecar.committedAt
                )
            }
            return ProfileBodyState(revision: revision, generation: 0, writer: "external", committedAt: bodyModificationDate() ?? now())
        }
    }

    /// Removes the body and everything this store keeps next to it. Used when a profile is deleted
    /// so a later profile that reuses the id does not inherit its revision.
    public func remove() throws {
        try withLock {
            for url in [bodyURL, sidecarURL, journalURL] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - The critical section

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        try acquireLock()
        defer { releaseLock() }
        return try body()
    }

    private func acquireLock() throws {
        let deadline = now().addingTimeInterval(lockTimeout)
        while true {
            do {
                try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
                try ownerData().write(to: lockURL.appendingPathComponent("owner.json"), options: .atomic)
                return
            } catch {
                guard fileManager.fileExists(atPath: lockURL.path) else {
                    throw error
                }
                if reclaimStaleLock() {
                    continue
                }
                guard now() < deadline else {
                    throw ProfileBodyStoreError.lockTimeout
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private func releaseLock() {
        try? fileManager.removeItem(at: lockURL)
    }

    /// A lock directory whose owner died leaves no process to remove it. Age is the only signal
    /// available without a heartbeat thread, so a lock older than `staleLockAge` is reclaimed;
    /// a short critical section stays far below it.
    private func reclaimStaleLock() -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
              let modified = attributes[.modificationDate] as? Date,
              now().timeIntervalSince(modified) > staleLockAge
        else {
            return false
        }
        try? fileManager.removeItem(at: lockURL)
        return !fileManager.fileExists(atPath: lockURL.path)
    }

    private func ownerData() -> Data {
        let owner: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "startedAt": now().timeIntervalSince1970,
        ]
        return (try? JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - The commit protocol

    private func writeBody(
        _ body: String,
        previousRevision: String?,
        generation: UInt64,
        writer: String
    ) throws -> ProfileBodyCommitOutcome {
        let revision = ConfigurationBodyRevision.fingerprint(of: body)
        let journal = ProfileBodyJournal(
            schema: 1,
            previousRevision: previousRevision,
            intentRevision: revision,
            generation: generation,
            writer: writer,
            startedAt: now()
        )
        try write(journal, to: journalURL)
        beforeBodyWrite?()
        try Data(body.utf8).write(to: bodyURL, options: .atomic)
        let state = ProfileBodyState(revision: revision, generation: generation, writer: writer, committedAt: now())
        try writeSidecar(state)
        try? fileManager.removeItem(at: journalURL)
        return .committed(state)
    }

    /// Completes a commit that crashed between the body write and the sidecar write.
    ///
    /// Three outcomes:
    ///  - no journal: nothing to do;
    ///  - body == intent: finish the sidecar and clear the journal;
    ///  - body == previous: the body write never happened (or was replaced back); clear the
    ///    journal and leave the body alone;
    ///  - neither: refuse. Repairing here would pick a winner between two documents, and no
    ///    caller can then say which one the service was given.
    private enum RecoveryResult {
        case none
        case recovered(ProfileBodyState)
    }

    private func recoverInterruptedCommit() throws -> RecoveryResult {
        guard let journal: ProfileBodyJournal = read(ProfileBodyJournal.self, from: journalURL) else {
            return .none
        }
        guard let storedRevision = try readStoredRevision() else {
            // The body is gone entirely under a journal: no content to attribute.
            throw ProfileBodyStoreError.untrustedBody(reason: "the journal outlived the body")
        }
        if storedRevision == journal.intentRevision {
            let state = ProfileBodyState(
                revision: journal.intentRevision,
                generation: journal.generation,
                writer: journal.writer,
                committedAt: journal.startedAt
            )
            try writeSidecar(state)
            try? fileManager.removeItem(at: journalURL)
            return .recovered(state)
        }
        if storedRevision == journal.previousRevision {
            try? fileManager.removeItem(at: journalURL)
            return .none
        }
        throw ProfileBodyStoreError.untrustedBody(
            reason: "the journal expected \(journal.intentRevision), the body is \(storedRevision)"
        )
    }

    // MARK: - Files

    private func readStoredRevision() throws -> String? {
        guard fileManager.fileExists(atPath: bodyURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: bodyURL)
        guard let body = String(data: data, encoding: .utf8) else {
            throw ProfileBodyStoreError.untrustedBody(reason: "the body is not valid UTF-8")
        }
        return ConfigurationBodyRevision.fingerprint(of: body)
    }

    private func readSidecar() throws -> ProfileBodyState? {
        guard let sidecar: ProfileBodySidecar = read(ProfileBodySidecar.self, from: sidecarURL) else {
            return nil
        }
        return ProfileBodyState(
            revision: sidecar.revision,
            generation: sidecar.generation,
            writer: sidecar.writer,
            committedAt: sidecar.committedAt
        )
    }

    private func writeSidecar(_ state: ProfileBodyState) throws {
        let sidecar = ProfileBodySidecar(
            schema: 1,
            revision: state.revision,
            generation: state.generation,
            writer: state.writer,
            committedAt: state.committedAt
        )
        try write(sidecar, to: sidecarURL)
    }

    private func bodyModificationDate() -> Date? {
        (try? fileManager.attributesOfItem(atPath: bodyURL.path))?[.modificationDate] as? Date
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
