import Policy
import XCTest

/// When a log batch is worth announcing, who counts as looking, and which page is looking.
///
/// The defect these pin: the window is cheap to fill and expensive to render, and the page that
/// renders it is kept alive by the tab shell after a tab switch. Publishing on every batch therefore
/// ran the page's filter and a text view's re-render for a page that was not on screen. The two
/// decisions - keep filling, announce only for someone - are separate, and these tests hold them
/// separate.
///
/// The second half is the one the first version got wrong: the app builds one `LogStore` per process
/// and injects it into every window, so "is a page visible" is a question about a set of pages, not a
/// count of reports. A count cannot tell a page that is on screen from one that never was, and it
/// let a hidden window's `setPageVisible(false)` take a visible window's place.
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

    // MARK: - One page's own state is idempotent

    func testAFreshPageIsNotVisibleAndReportsNothing() {
        var presence = LogPagePresence()
        XCTAssertFalse(presence.isVisible)
        XCTAssertFalse(
            presence.setVisible(false),
            "a page that was never visible reporting that it is not visible is not a transition"
        )
        XCTAssertFalse(presence.isVisible)
    }

    func testAPageReportsOnlyARealTransition() {
        var presence = LogPagePresence()
        XCTAssertTrue(presence.setVisible(true))
        XCTAssertFalse(presence.setVisible(true), "a repeated onAppear is not a second appearance")
        XCTAssertTrue(presence.setVisible(false))
        XCTAssertFalse(presence.setVisible(false), "a repeated onDisappear is not a second departure")
    }

    func testAPagesIdentityIsStableAcrossItsReports() {
        var presence = LogPagePresence()
        let id = presence.id
        presence.setVisible(true)
        presence.setVisible(false)
        XCTAssertEqual(presence.id, id)
        XCTAssertNotEqual(LogPagePresence().id, id, "two pages are two identities")
    }

    // MARK: - The store's set of pages

    func testAFreshSetHasNoPagesOnScreen() {
        let visibility = LogPageVisibility()
        XCTAssertFalse(visibility.isVisible)
        XCTAssertEqual(visibility.pageCount, 0)
    }

    /// The case the counter got wrong: a window whose Logs page was created but is not the selected
    /// one must not be able to take the visible window's presence away.
    func testAPageThatWasNeverVisibleCannotTakeAnotherPagesPresence() {
        var visibility = LogPageVisibility()
        let visiblePage = UUID()
        let createdButNotSelected = UUID()

        XCTAssertEqual(visibility.setVisible(true, for: visiblePage), .becameVisible)
        XCTAssertEqual(
            visibility.setVisible(false, for: createdButNotSelected),
            .none,
            "removing a page that is not a member is not a change"
        )
        XCTAssertTrue(visibility.isVisible, "the visible page is still visible")
        XCTAssertEqual(visibility.pageCount, 1)
    }

    func testARepeatedReportIsNotAChange() {
        var visibility = LogPageVisibility()
        let page = UUID()
        XCTAssertEqual(visibility.setVisible(true, for: page), .becameVisible)
        XCTAssertEqual(visibility.setVisible(true, for: page), .none)
        XCTAssertEqual(visibility.pageCount, 1)

        XCTAssertEqual(visibility.setVisible(false, for: page), .left)
        XCTAssertEqual(visibility.setVisible(false, for: page), .none)
        XCTAssertEqual(visibility.pageCount, 0)
    }

    func testOneWindowHidingLeavesAnotherVisible() {
        var visibility = LogPageVisibility()
        let first = UUID()
        let second = UUID()
        visibility.setVisible(true, for: first)
        visibility.setVisible(true, for: second)
        XCTAssertEqual(visibility.pageCount, 2)

        XCTAssertEqual(visibility.setVisible(false, for: second), .left)
        XCTAssertTrue(visibility.isVisible, "the first window is still showing logs")

        XCTAssertEqual(visibility.setVisible(false, for: first), .left)
        XCTAssertFalse(visibility.isVisible)
    }

    /// A page that appears while another is already visible still needs its own announcement: it has
    /// rendered nothing while it was hidden, so the window has to be drawn for it.
    func testANewPageAppearingWhileAnotherIsVisibleStillReportsBecameVisible() {
        var visibility = LogPageVisibility()
        let first = UUID()
        let second = UUID()
        visibility.setVisible(true, for: first)

        XCTAssertEqual(
            visibility.setVisible(true, for: second),
            .becameVisible,
            "the second window has to be announced to, or it opens on an empty page"
        )
        XCTAssertEqual(visibility.pageCount, 2)
    }

    /// The review's scenario, end to end at the level the two types own: a window that is created
    /// but not selected reports `false` (which its own presence refuses to forward), another window
    /// stays visible, and the second window's eventual appearance still asks for a render.
    func testASecondWindowOpeningLogsDoesNotDisturbTheVisibleOneAndStillGetsItsRender() {
        var store = LogPageVisibility()
        var firstWindow = LogPagePresence()
        var secondWindow = LogPagePresence()

        // Window A shows logs.
        XCTAssertTrue(firstWindow.setVisible(true))
        XCTAssertEqual(store.setVisible(firstWindow.isVisible, for: firstWindow.id), .becameVisible)

        // Window B is built but its Logs page is not the selected page: its onAppear reports false,
        // which is not a transition, so nothing is reported at all.
        XCTAssertFalse(secondWindow.setVisible(false))
        XCTAssertTrue(
            store.isVisible,
            "window A must keep being announced to while it is on screen"
        )

        // Window B selects Logs: one real transition, and the store owes it a render even though
        // window A is already visible.
        XCTAssertTrue(secondWindow.setVisible(true))
        XCTAssertEqual(store.setVisible(secondWindow.isVisible, for: secondWindow.id), .becameVisible)
        XCTAssertEqual(store.pageCount, 2)

        // Window A hides: window B is still there.
        XCTAssertTrue(firstWindow.setVisible(false))
        XCTAssertEqual(store.setVisible(firstWindow.isVisible, for: firstWindow.id), .left)
        XCTAssertTrue(store.isVisible)
    }
}
