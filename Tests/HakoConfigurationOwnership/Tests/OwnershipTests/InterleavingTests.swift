import XCTest

@testable import Contract

/// B — the commit points, driven as interleavings rather than as two strings.
///
/// Each case fixes the order at a real boundary of `RemoteRefreshApplier` (the pre-write revision
/// read, the write, the reload) and then asserts what the loser of the race did NOT do. The point is
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

    /// A1 starts, blocks; A2 downloads, saves and applies; A1 is released. The stored revision A1
    /// read is no longer the stored one, so A1 must not write, must not reload, and must not claim
    /// the apply.
    func testALateUpdateCannotOverwriteTheOneThatWon() async throws {
        var wrote: [String] = []
        var reloads = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: olderBody),
            applyMetadata: {},
            persist: {},
            writeBody: { wrote.append($0) },
            storedBodyRevision: { ConfigurationBodyRevision.fingerprint(of: self.newerBody) },
            expectedBodyRevision: ConfigurationBodyRevision.fingerprint(of: olderBody),
            reloadService: { _ in
                reloads += 1
                return .applied(.restarted, activeRevision: "newer")
            },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertTrue(wrote.isEmpty, "the loser must not touch the body the winner wrote")
        XCTAssertEqual(reloads, 0, "and must not reload the winner's instance")
    }

    /// The same race, seen from the other side: the newer update commits normally. Together the two
    /// cases say one of the two commits and the other has no effect - not "both reported success".
    func testTheWinnerOfTheSameRaceCommits() async throws {
        var wrote: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: {},
            persist: {},
            writeBody: { wrote.append($0) },
            storedBodyRevision: { ConfigurationBodyRevision.fingerprint(of: self.olderBody) },
            expectedBodyRevision: ConfigurationBodyRevision.fingerprint(of: self.olderBody),
            storedBody: { self.newerBody },
            reloadService: { _ in .applied(.restarted, activeRevision: "newer") },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(wrote, [newerBody])
    }

    /// The stored-body check is the LAST thing before the send, not the first thing after the write.
    ///
    /// That ordering is the whole narrowing: with the check right after the write there were two
    /// awaits (`canApply`, `isStillCurrent`) between the proof and the commit, and another writer
    /// replacing the body in that gap made this operation apply the older document while both
    /// updates reported a coherent story. The check cannot be atomic with the send - the send is the
    /// commit and it crosses a process - but it can be adjacent to it.
    func testTheStoredBodyIsCheckedImmediatelyBeforeTheSend() async throws {
        var events: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            writeBody: { _ in events.append("write") },
            storedBodyRevision: {
                events.append("revision")
                return ConfigurationBodyRevision.fingerprint(of: self.olderBody)
            },
            expectedBodyRevision: ConfigurationBodyRevision.fingerprint(of: olderBody),
            storedBody: {
                events.append("storedBody")
                return self.newerBody
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
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(
            events,
            ["metadata", "persist", "revision", "write", "canApply", "isStillCurrent", "storedBody", "reload",
             "isStillCurrent", "storedBody"],
            "the stored-body proof sits between the last cheap check and the send, and is repeated afterwards"
        )
    }

    /// A failed apply must not roll the body back. The new body is what the user asked for and what
    /// is on disk; the failure is about the running instance, and the daemon's own report says
    /// whether the previous document is still serving. There is no restore path here, and a second
    /// write would be one.
    func testAFailedApplyDoesNotRollTheBodyBack() async throws {
        var wrote: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: {},
            persist: {},
            writeBody: { wrote.append($0) },
            storedBodyRevision: { ConfigurationBodyRevision.fingerprint(of: self.olderBody) },
            expectedBodyRevision: ConfigurationBodyRevision.fingerprint(of: self.olderBody),
            storedBody: { self.newerBody },
            reloadService: { _ in throw NSError(domain: "test", code: 7) },
            refreshProviders: { .notActive }
        )
        guard case .applyFailed = report.config else {
            return XCTFail("a refused reload is a failure, got \(report.config)")
        }
        XCTAssertEqual(wrote, [newerBody], "exactly one write: the user's body, never a rollback")
    }

    /// A recovery is not a rollback either: the daemon recovered to the stored last-good document,
    /// the body on disk is still the one this update wrote, and nothing rewrites it.
    func testARecoveryDoesNotRewriteTheBody() async throws {
        var wrote: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: newerBody),
            applyMetadata: {},
            persist: {},
            writeBody: { wrote.append($0) },
            storedBodyRevision: { ConfigurationBodyRevision.fingerprint(of: self.olderBody) },
            expectedBodyRevision: ConfigurationBodyRevision.fingerprint(of: self.olderBody),
            storedBody: { self.newerBody },
            reloadService: { _ in .recovered(activeRevision: "stored-1") },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .recovered(activeRevision: "stored-1"))
        XCTAssertEqual(wrote, [newerBody], "the recovery is the daemon's, not a rewrite by this update")
    }
}
