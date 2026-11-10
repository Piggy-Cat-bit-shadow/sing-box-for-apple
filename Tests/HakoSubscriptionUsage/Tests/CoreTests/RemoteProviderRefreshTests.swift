import Foundation
import XCTest

@testable import Core

/// The provider half of a remote-profile update, decoded from what the pinned core actually sends.
///
/// `CommandClient.RefreshRemoteProviders` marshals the protobuf response with Go's `encoding/json`,
/// so the wire names are `pending_tags` / `restart_required` / `box_changed` and every zero value is
/// OMITTED. Both facts are load-bearing: a decoder that required the fields fails the whole report,
/// and one that only knew camelCase silently drops the partial-application fields.
final class RemoteProviderRefreshTests: XCTestCase {
    func testDecodesTheSnakeCaseShapeWithOmittedZeroValues() {
        let summary = RemoteProviderRefreshParser.summarize(json: """
        {"results":[{"tag":"pp","status":"published","pending_tags":["a","b"],"restart_required":true}],
         "box_changed":true}
        """)
        XCTAssertEqual(summary.status, .boxChanged)
    }

    func testAPartlyAppliedDocumentIsNotACleanPublish() {
        let summary = RemoteProviderRefreshParser.summarize(json: """
        {"results":[{"tag":"pp","status":"published","pending_tags":["node-a","node-b"],"restart_required":true}]}
        """)
        XCTAssertEqual(summary.status, .partial)
        XCTAssertEqual(summary.counts.pendingTags, 2)
        XCTAssertEqual(summary.counts.restartRequired, 1)
        XCTAssertEqual(summary.counts.published, 1)
    }

    func testOmittedFlagsDefaultToFalseInsteadOfFailingTheReport() {
        let summary = RemoteProviderRefreshParser.summarize(json: """
        {"results":[{"tag":"pp","status":"unchanged"}]}
        """)
        XCTAssertEqual(summary.status, .unchanged)
        XCTAssertEqual(summary.counts.total, 1)
    }

    func testCancellationAndEmptyResponseAreDistinct() {
        let cancelled = RemoteProviderRefreshParser.summarize(json: #"{"results":[],"cancelled":true}"#)
        XCTAssertEqual(cancelled.status, .cancelled)
        let empty = RemoteProviderRefreshParser.summarize(json: #"{"results":[]}"#)
        XCTAssertEqual(empty.status, .none)
    }

    func testMalformedOrAbsentPayloadIsUnavailableNotAnEmptySuccess() {
        XCTAssertEqual(RemoteProviderRefreshParser.summarize(json: nil).status, .unavailable)
        XCTAssertEqual(RemoteProviderRefreshParser.summarize(json: "").status, .unavailable)
        XCTAssertEqual(RemoteProviderRefreshParser.summarize(json: "not json").status, .unavailable)
    }

    func testUnknownStatusFailsInsteadOfClaimingSuccess() {
        let summary = RemoteProviderRefreshParser.summarize(json: """
        {"results":[{"tag":"pp","status":"future-status"}]}
        """)
        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.counts.total, 1)
    }

    // MARK: - the applier

    private func outcome(bodyChanged: Bool) -> RemoteRefreshOutcome {
        RemoteRefreshOutcome(
            subscriptionInfo: nil,
            subscriptionInfoUpdatedAt: nil,
            capture: .missing,
            usedMetadataProbe: false,
            writeBody: bodyChanged,
            reloadService: bodyChanged,
            bodyToWrite: bodyChanged ? "{}" : nil
        )
    }

    func testAnUnchangedBodyRefreshesProvidersWithoutReloading() async throws {
        var events: [String] = []
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: false),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            commitBody: { _ in
                XCTFail("a metadata-only refresh must not commit a body")
                return .superseded(storedRevision: nil)
            },
            reloadService: { _ in
                XCTFail("a metadata-only refresh must not reload")
                return nil
            },
            refreshProviders: { _ in
                events.append("providers")
                return .response(#"{"results":[{"tag":"pp","status":"unchanged"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .unchanged)
        XCTAssertEqual(report.providers.status, .unchanged)
        XCTAssertEqual(events, ["metadata", "persist", "providers"])
    }

    func testAChangedBodyIsWrittenReloadedAndConfirmedBeforeProviders() async throws {
        var events: [String] = []
        var confirmedInstance: Int64?
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            commitBody: { body in
                events.append("write")
                XCTAssertEqual(body, "{}", "the reload must be given the body this operation committed")
                return .committed(newRevision: "test")
            },
            reloadService: { body in
                events.append("reload")
                XCTAssertEqual(body, "{}", "the reload must be given the body this operation committed")
                return .applied(.restarted, activeRevision: "active")
            },
            confirmStartedAt: {
                events.append("confirm")
                return Int64(1)
            },
            refreshProviders: { instance in
                events.append("providers")
                confirmedInstance = instance
                return .response(#"{"results":[{"tag":"pp","status":"published"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(report.providers.status, .published)
        XCTAssertEqual(events, ["metadata", "persist", "write", "reload", "confirm", "providers"],
                       "the provider half is probed after the apply, and the receipt is the confirmation")
        XCTAssertEqual(confirmedInstance, Int64(1),
                       "the provider refresh is bound to the instance the apply confirmed")
    }

    /// A refused reload leaves the provider half alone.
    ///
    /// The older version of this test asserted the opposite - that a failed apply still probed the
    /// running instance's providers - which attached a live side effect (HTTP to each provider, nodes
    /// published) to an update that never reached the service.
    func testARefusedReloadLeavesTheProvidersAlone() async throws {
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "test") },
            reloadService: { _ in throw NSError(domain: "test", code: 1) },
            refreshProviders: { _ in
                probes += 1
                return .notRunning
            }
        )
        guard case let .applyFailed(reason) = report.config else {
            return XCTFail("a refused reload is a failure, got \(report.config)")
        }
        XCTAssertTrue(reason?.contains("test error 1") ?? false, "the cause survives: \(reason ?? "nil")")
        XCTAssertEqual(probes, 0, "the instance is not serving this update's document")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.notApplied.rawValue)
    }

    func testAProfileThatIsNotRunningSavesTheBodyAndDoesNotReload() async throws {
        var reloaded = false
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "test") },
            reloadService: { _ in reloaded = true; return nil },
            canApply: { false },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .saved)
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.notRunningThisProfile.rawValue,
                       "the running instance serves another profile; its providers are not this update's")
        XCTAssertFalse(reloaded)
    }

    func testAnUnconfirmedReloadIsNotReportedAsApplied() async throws {
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "test") },
            reloadService: { _ in nil },
            confirmStartedAt: { nil },
            refreshProviders: { _ in
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .applyUnconfirmed,
                       "no receipt is unconfirmed - a start timestamp is not the confirmation")
        XCTAssertEqual(probes, 0, "an unconfirmed apply did not reach the service, so no provider refresh")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.notApplied.rawValue)
    }

    func testASwitchBeforeReloadIsSupersededAndDoesNotReload() async throws {
        var reloads = 0
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "test") },
            reloadService: { _ in reloads += 1; return nil },
            isStillCurrent: { false },
            refreshProviders: { _ in
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(probes, 0, "a superseded request leaves no side effect on the instance")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.superseded.rawValue)
    }

    func testASwitchDuringReloadIsSupersededNotApplied() async throws {
        var checks = 0
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "test") },
            reloadService: { _ in .applied(.appliedLive, activeRevision: "active") },
            isStillCurrent: {
                checks += 1
                return checks == 1
            },
            confirmStartedAt: { Int64(1) },
            refreshProviders: { _ in
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(probes, 0, "the selection moved while the daemon was applying, so no provider refresh")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.superseded.rawValue)
    }

    /// A metadata-only refresh that lost the profile must not probe anything.
    ///
    /// The older version of this test asserted one probe with `.notActive`: the request had already
    /// stopped being current, and it still attached a live side effect (HTTP to each provider, nodes
    /// published) to the instance it no longer owned. The rule is the same one every other branch
    /// uses (`ProviderRefreshPolicy`): a superseded request refreshes nothing.
    func testMetadataOnlySwitchDoesNotProbeAnyInstance() async throws {
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: false),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in XCTFail("must not commit"); return .superseded(storedRevision: nil) },
            reloadService: { _ in XCTFail("must not reload"); return nil },
            isStillCurrent: { false },
            refreshProviders: { _ in
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(probes, 0, "a lost claim owes the running instance no provider refresh")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.superseded.rawValue)
    }

    func testAReplacedBodyIsNotReloadedOrReportedAsApplied() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in .committed(newRevision: "test") },
            storedBody: { "a newer body" },
            reloadService: { _ in XCTFail("must not reload a replaced body"); return nil },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.superseded.rawValue)
    }

    func testLegacyEntryTreatsDownloadAndSupersededAsFailures() {
        let download = RemoteProfileUpdateReport(
            config: .downloadFailed("offline"),
            providers: RemoteProviderRefreshProbe.notActive.summary
        )
        XCTAssertTrue(download.isLegacyFailure)
        XCTAssertNotNil(RemoteProfileUpdateError(download).errorDescription)

        let superseded = RemoteProfileUpdateReport(
            config: .superseded,
            providers: RemoteProviderRefreshProbe.notActive.summary
        )
        XCTAssertTrue(superseded.isLegacyFailure)

        let applied = RemoteProfileUpdateReport(
            config: .applied,
            providers: RemoteProviderRefreshProbe.notActive.summary
        )
        XCTAssertFalse(applied.isLegacyFailure)
    }

    func testProviderTargetNeedsTheSameConfirmedInstance() {
        XCTAssertEqual(
            providerTargetDecision(selected: true, connected: true, expectedStartedAt: nil, currentStartedAt: 9),
            .superseded
        )
        XCTAssertEqual(
            providerTargetDecision(selected: true, connected: true, expectedStartedAt: 1, currentStartedAt: 2),
            .superseded
        )
        XCTAssertEqual(
            providerTargetDecision(selected: true, connected: true, expectedStartedAt: 1, currentStartedAt: 1),
            .ok
        )
        XCTAssertEqual(
            providerTargetDecision(selected: false, connected: true, expectedStartedAt: 1, currentStartedAt: 1),
            .notActive
        )
        XCTAssertEqual(
            providerTargetDecision(selected: true, connected: false, expectedStartedAt: 1, currentStartedAt: nil),
            .notRunning
        )
    }
}
