import XCTest

@testable import Contract

/// What a consumer is allowed to do with the update report, and what a superseded request is allowed
/// to touch.
///
/// The provider half is not decoration: refreshing providers is a live side effect (HTTP to each
/// provider, nodes published). A request that lost its claim must leave none of it behind, and a
/// failure must not attach that side effect to a claim it does not own.
final class UpdateOutcomeConsumptionTests: XCTestCase {
    private let body = "{\"outbounds\":[]}"

    private func outcome(writeBody: Bool = true) -> RemoteRefreshOutcome {
        RemoteRefreshOutcome(
            subscriptionInfo: nil,
            subscriptionInfoUpdatedAt: nil,
            capture: .missing,
            usedMetadataProbe: false,
            writeBody: writeBody,
            reloadService: writeBody,
            bodyToWrite: writeBody ? body : nil
        )
    }

    private final class RefreshCounter {
        var count = 0
    }

    func testASupersededUpdateDoesNotRefreshProviders() async throws {
        let counter = RefreshCounter()
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .superseded(storedRevision: "newer") },
            reloadService: { _ in XCTFail("a superseded update must not reach the daemon"); return nil },
            refreshProviders: {
                counter.count += 1
                return .response(#"{"results":[{"tag":"p","status":"published"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(counter.count, 0, "the winner owns the provider refresh")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.superseded.rawValue)
    }

    func testAFailedApplyDoesNotRefreshProviders() async throws {
        let counter = RefreshCounter()
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            storedBody: { self.body },
            reloadService: { _ in .failed(reason: "refused", retained: true) },
            refreshProviders: {
                counter.count += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .applyFailed("refused"))
        XCTAssertEqual(counter.count, 0,
                       "the instance is not serving this update's document, so its providers are not its to refresh")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.notApplied.rawValue)
    }

    func testASavedProfileDoesNotRefreshTheRunningInstancesProviders() async throws {
        let counter = RefreshCounter()
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            reloadService: { _ in .applied(.restarted, activeRevision: "x") },
            canApply: { false },
            refreshProviders: {
                counter.count += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .saved)
        XCTAssertEqual(counter.count, 0, "the running instance serves another profile")
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.notRunningThisProfile.rawValue)
    }

    func testAnAppliedUpdateRefreshesProvidersOnce() async throws {
        let counter = RefreshCounter()
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "rev") },
            storedBody: { self.body },
            reloadService: { _ in .applied(.restarted, activeRevision: "x") },
            refreshProviders: {
                counter.count += 1
                return .response(#"{"results":[{"tag":"p","status":"published"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(report.providers.status, .published)
    }

    /// The wrapper the shortcuts call can only say "throw or not", so the mapping from an outcome to
    /// an error is what decides whether a structured failure is hidden behind `true`.
    func testEveryNonAppliedOutcomeProducesAUserReadableError() {
        let failures: [RemoteConfigUpdateOutcome] = [
            .applyFailed("refused"),
            .invalidConfig(nil),
            .downloadFailed("timeout"),
            .recovered(activeRevision: "abc"),
            .interrupted(reason: nil),
            .superseded,
            .applyUnconfirmed,
        ]
        for config in failures {
            let error = ProfileUpdateFailure(report: .init(config: config, providers: .init(status: .skipped, counts: .init(), detail: nil)))
            let message = error.errorDescription
            XCTAssertNotNil(message, "\(config) must be explainable to the user")
            XCTAssertFalse(message?.isEmpty ?? true, "\(config) must not produce an empty sentence")
        }
        for config in [RemoteConfigUpdateOutcome.applied, .unchanged, .saved] {
            let error = ProfileUpdateFailure(report: .init(config: config, providers: .init(status: .skipped, counts: .init(), detail: nil)))
            XCTAssertNil(error.errorDescription, "\(config) is a success and must not describe an error")
        }
    }
}
