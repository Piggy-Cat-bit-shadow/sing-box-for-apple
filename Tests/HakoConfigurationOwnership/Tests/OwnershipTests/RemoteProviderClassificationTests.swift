import XCTest

@testable import Contract

/// The provider report's ordering: a status this client cannot interpret is a failure, even when
/// the same report also carries pending tags/restart flags from statuses it does understand.
final class RemoteProviderClassificationTests: XCTestCase {
    func testUnknownStatusIsNotHiddenByPendingTags() {
        let summary = RemoteProviderRefreshParser.summarize(json: """
        {"results":[{"tag":"pp","status":"future-status","pending_tags":["node-a"],"restart_required":true}]}
        """)
        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.counts.pendingTags, 1)
        XCTAssertEqual(summary.counts.restartRequired, 1)
        XCTAssertNotNil(summary.detail)
    }

    func testPendingTagsAloneStayPartial() {
        let summary = RemoteProviderRefreshParser.summarize(json: """
        {"results":[{"tag":"pp","status":"published","pending_tags":["node-a"]}]}
        """)
        XCTAssertEqual(summary.status, .partial)
        XCTAssertEqual(summary.counts.pendingTags, 1)
    }
}
