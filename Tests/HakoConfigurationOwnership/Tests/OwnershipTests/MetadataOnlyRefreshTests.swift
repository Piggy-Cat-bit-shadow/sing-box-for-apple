import XCTest

@testable import Contract

/// The metadata-only branch of `RemoteRefreshApplier` - the path a "body did not change" refresh takes.
///
/// It used to call `refreshProviders()` for BOTH outcomes it can produce, so a refresh whose profile
/// had stopped being current still probed the running instance's providers. The positive case matters
/// just as much: a metadata-only refresh of the CURRENT profile is a successful update and must keep
/// refreshing, which is why this file asserts both directions.
final class MetadataOnlyRefreshTests: XCTestCase {
    private func metadataOnly() -> RemoteRefreshOutcome {
        RemoteRefreshOutcome(
            subscriptionInfo: nil,
            subscriptionInfoUpdatedAt: nil,
            capture: .missing,
            usedMetadataProbe: false,
            writeBody: false,
            reloadService: false,
            bodyToWrite: nil
        )
    }

    func testASupersededMetadataOnlyRefreshDoesNotRefreshProviders() async throws {
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            metadataOnly(),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in
                XCTFail("a metadata-only refresh must not commit a body")
                return .superseded(storedRevision: nil)
            },
            reloadService: { _ in
                XCTFail("a metadata-only refresh must not reload")
                return nil
            },
            isStillCurrent: { false },
            refreshProviders: {
                probes += 1
                return .notActive
            }
        )
        XCTAssertEqual(report.config, .superseded)
        XCTAssertEqual(probes, 0, "a lost claim owes the running instance no provider refresh")
        XCTAssertEqual(report.providers.status, .skipped)
        XCTAssertEqual(report.providers.detail, ProviderRefreshSkip.superseded.rawValue)
    }

    func testACurrentMetadataOnlyRefreshStillRefreshesProviders() async throws {
        var probes = 0
        let report = try await RemoteRefreshApplier.applyReporting(
            metadataOnly(),
            applyMetadata: {},
            persist: {},
            commitBody: { _ in
                XCTFail("a metadata-only refresh must not commit a body")
                return .superseded(storedRevision: nil)
            },
            reloadService: { _ in
                XCTFail("a metadata-only refresh must not reload")
                return nil
            },
            isStillCurrent: { true },
            refreshProviders: {
                probes += 1
                return .response(#"{"results":[{"tag":"p","status":"unchanged"}]}"#)
            }
        )
        XCTAssertEqual(report.config, .unchanged)
        XCTAssertEqual(probes, 1, "the running instance is this profile, so its providers are this update's")
        XCTAssertNotEqual(report.providers.status, .skipped)
    }
}
