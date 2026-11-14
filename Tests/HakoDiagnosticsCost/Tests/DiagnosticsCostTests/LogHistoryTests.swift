import Policy
import XCTest

/// What the log window retains and what an append means.
///
/// The defect these pin is downstream of the retention rule but reads through it: the Logs page
/// computes the number of new lines as `totalCount - lastProcessedTotal`, so the drop count has to be
/// cumulative across the whole subscription for a saturated window to keep appending correctly rather
/// than re-filtering the window every batch. And an append that changed nothing must say so, because
/// the store publishes only on change - a publish here invalidates the one page that observes it.
final class LogHistoryTests: XCTestCase {
    private func entry(_ message: String) -> LogEntry {
        LogEntry(level: 4, message: message)
    }

    // MARK: - Appending

    func testAppendingKeepsOrderAndCount() {
        var history = LogHistory(maxLines: 10)
        XCTAssertTrue(history.append(contentsOf: [entry("a"), entry("b")]))
        XCTAssertEqual(history.buffer.entries.map(\.message), ["a", "b"])
        XCTAssertEqual(history.buffer.droppedCount, 0)
        XCTAssertEqual(history.buffer.totalCount, 2)
    }

    /// An empty batch is not a change, and the store uses this answer to decide whether a publish
    /// would be a no-op.
    func testAnEmptyAppendIsNotAChange() {
        var history = LogHistory(maxLines: 10)
        XCTAssertFalse(history.append(contentsOf: []))
        XCTAssertTrue(history.buffer.entries.isEmpty)

        history.append(contentsOf: [entry("a")])
        XCTAssertFalse(history.append(contentsOf: []), "still not a change with a window present")
        XCTAssertEqual(history.buffer.entries.count, 1)
    }

    // MARK: - The bound

    func testAWindowAtExactlyTheBoundDropsNothing() {
        var history = LogHistory(maxLines: 3)
        history.append(contentsOf: [entry("a"), entry("b"), entry("c")])
        XCTAssertEqual(history.buffer.entries.map(\.message), ["a", "b", "c"])
        XCTAssertEqual(history.buffer.droppedCount, 0)
    }

    func testTheWindowKeepsTheNewestLinesAndCountsWhatItDropped() {
        var history = LogHistory(maxLines: 3)
        history.append(contentsOf: [entry("a"), entry("b"), entry("c"), entry("d"), entry("e")])
        XCTAssertEqual(
            history.buffer.entries.map(\.message), ["c", "d", "e"],
            "the window is the tail, in order"
        )
        XCTAssertEqual(history.buffer.droppedCount, 2)
        XCTAssertEqual(history.buffer.totalCount, 5)
    }

    /// The consumer's contract: `totalCount` is monotonic across appends, including after the window
    /// saturates, so `newCount = totalCount - lastProcessedTotal` is the number of lines it has not
    /// seen.
    func testTotalCountGrowsByTheNumberOfLinesAppendedAfterSaturation() {
        var history = LogHistory(maxLines: 2)
        var lastTotal = history.buffer.totalCount
        for batch in [["a"], ["b"], ["c"], ["d", "e"], ["f"]] {
            history.append(contentsOf: batch.map(entry))
            XCTAssertEqual(
                history.buffer.totalCount - lastTotal, batch.count,
                "a saturated window must still report every new line exactly once"
            )
            lastTotal = history.buffer.totalCount
        }
        XCTAssertEqual(history.buffer.entries.map(\.message), ["e", "f"])
    }

    func testTheDroppedCountIsCumulativeAcrossBatches() {
        var history = LogHistory(maxLines: 1)
        history.append(contentsOf: [entry("a"), entry("b")])
        XCTAssertEqual(history.buffer.droppedCount, 1)
        history.append(contentsOf: [entry("c")])
        XCTAssertEqual(history.buffer.droppedCount, 2)
        XCTAssertEqual(history.buffer.entries.map(\.message), ["c"])
    }

    // MARK: - Clearing

    func testClearEmptiesTheWindowAndForgetsTheDropCount() {
        var history = LogHistory(maxLines: 2)
        history.append(contentsOf: [entry("a"), entry("b"), entry("c")])
        XCTAssertTrue(history.clear())
        XCTAssertTrue(history.buffer.entries.isEmpty)
        XCTAssertEqual(history.buffer.droppedCount, 0)
        XCTAssertEqual(history.buffer.totalCount, 0)
    }

    func testClearingAnEmptyWindowIsNotAChange() {
        var history = LogHistory(maxLines: 2)
        XCTAssertFalse(history.clear(), "nothing to clear is nothing to publish")
    }

    /// A cleared window starts again from zero, which is what a new subscription's backlog expects.
    func testTheWindowIsUsableAfterClearing() {
        var history = LogHistory(maxLines: 2)
        history.append(contentsOf: [entry("a"), entry("b"), entry("c")])
        history.clear()
        history.append(contentsOf: [entry("d")])
        XCTAssertEqual(history.buffer.entries.map(\.message), ["d"])
        XCTAssertEqual(history.buffer.droppedCount, 0)
        XCTAssertEqual(history.buffer.totalCount, 1)
    }

    // MARK: - The default window

    /// The environment's client keeps a window large enough to scroll back through; the value is a
    /// bound, not the fix, so it stays where it was.
    func testTheDefaultWindowIsTheOneTheAppUses() {
        let history = LogHistory()
        XCTAssertEqual(history.maxLines, 3000)
        XCTAssertTrue(history.buffer.entries.isEmpty)
    }
}
