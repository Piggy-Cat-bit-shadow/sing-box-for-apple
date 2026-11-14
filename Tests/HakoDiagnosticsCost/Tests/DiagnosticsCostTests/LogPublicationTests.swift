import Policy
import XCTest

/// When a log batch is worth announcing, and who counts as looking.
///
/// The defect these pin: the window is cheap to fill and expensive to render, and the page that
/// renders it is kept alive by the tab shell after a tab switch. Publishing on every batch therefore
/// ran the page's filter and a text view's re-render for a page that was not on screen. The two
/// decisions - keep filling, announce only for someone - are separate, and these tests hold them
/// separate.
final class LogPublicationPolicyTests: XCTestCase {
    // MARK: - Nobody is looking

    func testNoPageOnScreenMeansNoAnnouncement() {
        for bufferWasEmpty in [true, false] {
            XCTAssertEqual(
                LogPublicationPolicy.decision(
                    isPageVisible: false, hasNewLines: true, bufferWasEmpty: bufferWasEmpty
                ),
                .none,
                "the window still fills; nothing is announced to a page that is not there"
            )
        }
    }

    func testAnEmptyWindowOnAHiddenPageIsStillNotAnnounced() {
        XCTAssertEqual(
            LogPublicationPolicy.decision(isPageVisible: false, hasNewLines: false, bufferWasEmpty: true),
            .none
        )
    }

    // MARK: - Nothing changed

    func testABatchThatCarriedNoLinesIsNotAnnounced() {
        for bufferWasEmpty in [true, false] {
            XCTAssertEqual(
                LogPublicationPolicy.decision(
                    isPageVisible: true, hasNewLines: false, bufferWasEmpty: bufferWasEmpty
                ),
                .none,
                "a batch with no lines cannot change what the page draws"
            )
        }
    }

    // MARK: - Something to draw

    func testTheFirstBatchOfASubscriptionIsAnnouncedImmediately() {
        XCTAssertEqual(
            LogPublicationPolicy.decision(isPageVisible: true, hasNewLines: true, bufferWasEmpty: true),
            .immediately,
            "the backlog must paint rather than wait out a window that exists to coalesce changes"
        )
    }

    func testLaterBatchesAreCoalesced() {
        XCTAssertEqual(
            LogPublicationPolicy.decision(isPageVisible: true, hasNewLines: true, bufferWasEmpty: false),
            .coalesced
        )
    }

    // MARK: - Who is looking

    func testAFreshStoreHasNoPageOnScreen() {
        let visibility = LogPageVisibility()
        XCTAssertFalse(visibility.isVisible)
        XCTAssertEqual(visibility.pageCount, 0)
    }

    func testOnePageAppearingAndLeaving() {
        var visibility = LogPageVisibility()
        XCTAssertTrue(visibility.setVisible(true), "appearing changes the answer")
        XCTAssertTrue(visibility.isVisible)
        XCTAssertTrue(visibility.setVisible(false), "leaving changes it back")
        XCTAssertFalse(visibility.isVisible)
    }

    func testTheAnswerStaysVisibleWhileASecondPageIsStillThere() {
        var visibility = LogPageVisibility()
        visibility.setVisible(true)
        XCTAssertFalse(visibility.setVisible(true), "a second page does not change the answer")
        XCTAssertEqual(visibility.pageCount, 2)

        visibility.setVisible(false)
        XCTAssertTrue(visibility.isVisible, "one page is still on screen")

        XCTAssertTrue(visibility.setVisible(false))
        XCTAssertFalse(visibility.isVisible)
    }

    /// A view can be torn down twice in one turn - a tab switch and a navigation pop. That must not
    /// make the store believe a page is still there, or it would keep announcing forever.
    func testLeavingMoreOftenThanAppearingSaturatesAtZero() {
        var visibility = LogPageVisibility()
        XCTAssertFalse(visibility.setVisible(false))
        XCTAssertEqual(visibility.pageCount, 0)
        XCTAssertFalse(visibility.isVisible)

        visibility.setVisible(true)
        visibility.setVisible(false)
        XCTAssertFalse(visibility.setVisible(false))
        XCTAssertEqual(visibility.pageCount, 0)

        visibility.setVisible(true)
        XCTAssertTrue(visibility.isVisible, "and a later appearance still works")
    }
}
