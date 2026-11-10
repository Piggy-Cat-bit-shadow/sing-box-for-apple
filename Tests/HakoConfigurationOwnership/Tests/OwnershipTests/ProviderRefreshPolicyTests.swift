import XCTest

@testable import Contract

/// One rule for "may this update touch the running instance's providers", used by every branch that
/// can answer that question.
///
/// The defect this replaces: the applier stopped refreshing on failure, and the profile path kept
/// refreshing on its own three failure branches - the same side effect, reached around the guard. A
/// policy function is only worth having if the mapping itself is pinned, which is what this file does.
final class ProviderRefreshPolicyTests: XCTestCase {
    func testOnlyAnAppliedUpdateRefreshes() {
        XCTAssertEqual(ProviderRefreshPolicy.decision(for: .applied), .refresh)
        XCTAssertNil(ProviderRefreshPolicy.skippedProbe(for: .applied))
    }

    func testASupersededUpdateSaysSo() {
        XCTAssertEqual(ProviderRefreshPolicy.decision(for: .superseded), .skip(.superseded))
        XCTAssertEqual(ProviderRefreshPolicy.skippedProbe(for: .superseded), .skipped(.superseded))
    }

    func testASavedProfileNamesTheRunningInstance() {
        XCTAssertEqual(ProviderRefreshPolicy.decision(for: .saved), .skip(.notRunningThisProfile))
        XCTAssertEqual(ProviderRefreshPolicy.skippedProbe(for: .saved), .skipped(.notRunningThisProfile))
    }

    func testEveryOutcomeWhereTheDocumentDidNotReachTheServiceIsNotApplied() {
        let configs: [RemoteConfigUpdateOutcome] = [
            .applyFailed("refused"),
            .invalidConfig("bad"),
            .downloadFailed("timeout"),
            .recovered(activeRevision: "old"),
            .interrupted(reason: nil),
            .applyUnconfirmed,
        ]
        for config in configs {
            XCTAssertEqual(ProviderRefreshPolicy.decision(for: config), .skip(.notApplied),
                           "\(config) must not refresh the instance's providers")
            XCTAssertEqual(ProviderRefreshPolicy.skippedProbe(for: config), .skipped(.notApplied))
        }
    }
}
