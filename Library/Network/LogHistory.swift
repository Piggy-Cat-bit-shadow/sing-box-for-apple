import Foundation

/// One line of kernel output, as the app holds it.
public struct LogEntry: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let level: Int
    public let message: String

    public init(level: Int, message: String) {
        self.level = level
        self.message = message
    }
}

/// A window of log lines, and how many were dropped to keep it that size.
///
/// The drop count is cumulative since the last reset, which is what lets a consumer that appends
/// incrementally work out how many lines it has not seen yet after the window has started scrolling
/// its front away.
public struct LogBuffer: Equatable, Sendable {
    public var entries: [LogEntry]
    /// Cumulative count of entries trimmed from the front since the last reset,
    /// letting consumers compute incremental deltas after the buffer saturates.
    public var droppedCount: Int

    public init(entries: [LogEntry] = [], droppedCount: Int = 0) {
        self.entries = entries
        self.droppedCount = droppedCount
    }

    public var totalCount: Int {
        droppedCount + entries.count
    }
}

/// The log window's own state: what is retained, what was dropped, and when it changed.
///
/// # Why this is separate from the store that publishes it
///
/// Nothing about retaining log lines needs a publisher, a timer or a thread - it is an array with a
/// bound. Keeping that here means the retention rule is compiled and driven by the tests on a
/// machine with no Apple SDKs, while `LogStore` is left with the two things that genuinely need
/// them: the publish, and the batch window that decides when a publish is worth making.
///
/// # Why the bound is not the fix
///
/// Lowering `maxLines` is the cheapest way to make a log page cheaper and it does not address what
/// the cost was. The window's size was never the problem - the problem was that a change *inside*
/// the window was published through the object every dashboard card observes, so a log line
/// invalidated four cards that cannot see one. That boundary is `LogStore`'s; this type only has to
/// keep the window correct.
public struct LogHistory: Equatable, Sendable {
    public private(set) var buffer: LogBuffer
    public let maxLines: Int

    public init(maxLines: Int = 3000, buffer: LogBuffer = LogBuffer()) {
        self.maxLines = maxLines
        self.buffer = buffer
    }

    /// Adds lines and trims the window back to its bound.
    ///
    /// - Returns: whether anything changed. An empty append is not a change, and callers use the
    ///   answer to decide whether a publish would be a no-op.
    @discardableResult
    public mutating func append(contentsOf entries: [LogEntry]) -> Bool {
        guard !entries.isEmpty else {
            return false
        }
        buffer.entries.append(contentsOf: entries)
        if buffer.entries.count > maxLines {
            let removeCount = buffer.entries.count - maxLines
            buffer.entries.removeFirst(removeCount)
            buffer.droppedCount += removeCount
        }
        return true
    }

    /// Empties the window and forgets the drop count, matching a fresh subscription's backlog.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func clear() -> Bool {
        guard !buffer.entries.isEmpty || buffer.droppedCount != 0 else {
            return false
        }
        buffer = LogBuffer()
        return true
    }
}
