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
            writeBody: { _ in events.append("write") },
            reloadService: { events.append("reload") },
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
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: { events.append("metadata") },
            persist: { events.append("persist") },
            writeBody: { _ in events.append("write") },
            reloadService: { events.append("reload") },
            confirmStartedAt: {
                events.append("confirm")
                return Int64(1)
            },
            refreshProviders: { _ in
                events.append("providers")
                return .response(#"{"results":[{"tag":"pp","status":"published"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .applied)
        XCTAssertEqual(report.providers.status, .published)
        XCTAssertEqual(events, ["metadata", "persist", "write", "reload", "confirm", "providers"])
    }

    func testARefusedReloadStillProbesTheOldInstance() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in },
            reloadService: { throw NSError(domain: "test", code: 1) },
            refreshProviders: { _ in .notRunning }
        )
        XCTAssertEqual(report.config, .applyFailed("The operation couldn’t be completed. (test error 1.)"))
        XCTAssertEqual(report.providers.status, .notRunning)
    }

    func testAProfileThatIsNotRunningSavesTheBodyAndDoesNotReload() async throws {
        var reloaded = false
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in },
            reloadService: { reloaded = true },
            canApply: { false },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .saved)
        XCTAssertEqual(report.providers.status, .notActive)
        XCTAssertFalse(reloaded)
    }

    func testAnUnconfirmedReloadIsNotReportedAsApplied() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in },
            reloadService: {},
            confirmStartedAt: { nil },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .applyUnconfirmed)
    }

    func testASwitchBeforeReloadIsSupersededAndDoesNotReload() async throws {
        var reloads = 0
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in },
            reloadService: { reloads += 1 },
            isStillCurrent: { false },
            refreshProviders: { _ in
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(report.providers.status, .notActive)
    }

    func testASwitchDuringReloadIsSupersededNotApplied() async throws {
        var checks = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in },
            reloadService: {},
            isStillCurrent: {
                checks += 1
                return checks == 1
            },
            confirmStartedAt: { Int64(1) },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .superseded)
    }

    func testMetadataOnlySwitchDoesNotProbeTheNewInstance() async throws {
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: false),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in XCTFail("must not write") },
            reloadService: { XCTFail("must not reload") },
            isStillCurrent: { false },
            refreshProviders: { _ in
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(report.providers.status, .notActive)
        XCTAssertEqual(probes, 1)
    }

    func testAReplacedBodyIsNotReloadedOrReportedAsApplied() async throws {
        let report = try await RemoteRefreshApplier.applyReporting(
            outcome(bodyChanged: true),
            applyMetadata: {},
            persist: {},
            writeBody: { _ in },
            storedBody: { "a newer body" },
            reloadService: { XCTFail("must not reload a replaced body") },
            refreshProviders: { _ in .notActive }
        )
        XCTAssertEqual(report.config, .superseded)
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
