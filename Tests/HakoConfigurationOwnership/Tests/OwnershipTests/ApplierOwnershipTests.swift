import XCTest

@testable import Contract

/// The applier's boundaries: a body commit that can lose, and a confirmation that has to be
/// attributable.
final class ApplierOwnershipTests: XCTestCase {
    private let body = "{\"outbounds\":[]}"

    private func outcome(body: String?) -> RemoteRefreshOutcome {
        RemoteRefreshOutcome(
            subscriptionInfo: nil,
            subscriptionInfoUpdatedAt: nil,
            capture: .missing,
            usedMetadataProbe: false,
            writeBody: body != nil,
            reloadService: body != nil,
            bodyToWrite: body
        )
    }

    /// The superseded update: the stored body is no longer the one this update read, so its commit
    /// loses and it must not reload or report the apply.
    func testABodyReplacedBeforeTheCommitLosesIt() async throws {
        var reloaded = false
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .superseded(storedRevision: "someone-else") },
            reloadService: { _ in
                reloaded = true
                return nil
            },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertFalse(reloaded)
    }

    func testAnUnchangedRevisionCommitsAndApplies() async throws {
        var events: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            commitBody: { written in
                events.append("commit")
                XCTAssertEqual(written, body)
                return .committed(newRevision: ConfigurationBodyRevision.fingerprint(of: body))
            },
            reloadService: { sent in
                events.append("reload")
                XCTAssertEqual(sent, body, "the reload must be given the body this operation committed")
                return .applied(.restarted, activeRevision: "active")
            },
            refreshProviders: {
                events.append("providers")
                return .response(#"{"results":[{"tag":"pp","status":"published"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(events, ["metadata", "persist", "commit", "reload", "providers"])
    }

    /// The receipt is the ONLY confirmation. There is no fallback to the daemon's start timestamp: a
    /// hot reload keeps it, and an unrelated restart moves it, so it cannot answer "is MY document
    /// running" - it could only turn "unknown" into a guess.
    func testTheReceiptIsTheOnlyConfirmation() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .applied(.appliedLive, activeRevision: "active") },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .applied)
    }

    func testARecoveryIsNotAnAppliedRequest() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .recovered(activeRevision: "stored") },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .recovered(activeRevision: "stored"))
        XCTAssertTrue(report.isFailure, "the service is up but it is not running what was asked for")
    }

    func testAnInterruptedApplyReportsThatNothingRuns() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .interrupted },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .interrupted(reason: nil))
        XCTAssertTrue(report.isFailure)
    }

    /// An extension that answers nothing, beside no other confirmation, is unconfirmed - never
    /// applied, and never retried by this code path.
    func testNoReceiptIsUnconfirmed() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in nil },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .applyUnconfirmed)
        XCTAssertFalse(report.isFailure, "an unconfirmed apply is not a failed one, and must not trigger a rollback")
    }

    func testAFailureThatKeptThePreviousDocumentIsAnApplyFailure() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .failed(reason: "refused", retained: true) },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .applyFailed("refused"))
    }

    func testAFailureThatTookTheServiceDownIsAnInterruption() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .failed(reason: "dropped", retained: false) },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .interrupted(reason: "dropped"))
    }

    /// A failure whose retention nobody established is a failed apply, never "the tunnel stopped".
    func testAFailureWithUnknownRetentionIsNotAnInterruption() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: body),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .failed(reason: "unknown", retained: nil) },
            refreshProviders: { .notActive }
        )
        XCTAssertEqual(report.config, .applyFailed("unknown"))
    }

    /// A metadata-only refresh still must not commit a body, and still probes the instance it belongs
    /// to.
    func testAMetadataOnlyRefreshNeverCommitsOrReloads() async throws {
        var events: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(body: nil),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            commitBody: { _ in
                events.append("commit")
                return .committed(newRevision: "rev")
            },
            storedBody: {
                events.append("storedBody")
                return nil
            },
            reloadService: { _ in
                events.append("reload")
                return nil
            },
            refreshProviders: {
                events.append("providers")
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .unchanged)
        XCTAssertEqual(events, ["metadata", "persist", "providers"])
    }
}
