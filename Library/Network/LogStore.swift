import Combine
import Foundation

/// The command client's log window, as its own observable object.
///
/// # Why the log state left `CommandClient`
///
/// `CommandClient` is one `ObservableObject`, and every view that reads it through
/// `@EnvironmentObject` is invalidated by any of its `@Published` properties changing. The log
/// window was one of those properties, and it changes on a hundred-millisecond batch window, so
/// four dashboard cards - two of them drawing a `Canvas` - were re-evaluated up to ten times a
/// second by log lines they do not display and cannot display. Debug's `-Onone` bodies turn that
/// from noticeable into the frame drops this round exists to remove.
///
/// The fix is a boundary, not a slower rate: log lines now change an object that only the Logs page
/// observes, so a batch that alters the window cannot invalidate a card. Status and traffic stay on
/// `CommandClient`, where a one-hertz publish is what the cards are for.
///
/// # What is deliberately unchanged
///
/// The backlog still arrives and is retained whether or not the Logs page is open: the store is
/// subscribed for the life of the connection, exactly as the client was, and `first batch paints
/// immediately` is kept so a page opened a second later shows the history rather than an empty
/// frame. Only the *publish rate after the first batch* moves from 100 ms to 250 ms, which is a
/// change in how often a change is announced, not in what is kept.
///
/// # Threading
///
/// Main-queue confined, like `CommandClient` itself: the handler hops to the main queue before
/// appending, and the batch work item is scheduled on the main queue. Nothing here is public that a
/// background caller may reach.
public final class LogStore: ObservableObject {
    /// The retained window. Publishing this changes only the observers of *this* object.
    @Published public private(set) var buffer = LogBuffer()

    /// Whether the core has sent the backlog that follows a subscription.
    ///
    /// Until it has, an empty window means "still loading" rather than "no logs" - the core always
    /// sends the backlog, even when it is empty.
    @Published public private(set) var initialLogsReceived = false

    /// The largest window the page will be asked to render.
    public var maxLines: Int {
        history.maxLines
    }

    private var history: LogHistory
    private let batchInterval: TimeInterval
    private var pending: [LogEntry] = []
    private var batchWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - maxLines: the retention bound.
    ///   - batchInterval: how long a batch waits before it is published. The first batch after a
    ///     subscription is published immediately; see `append(_:)`.
    public init(maxLines: Int = 3000, batchInterval: TimeInterval = 0.25) {
        history = LogHistory(maxLines: maxLines)
        self.batchInterval = batchInterval
    }

    /// A new subscription replaced the previous one.
    ///
    /// The window and the drop count belong to the subscription that produced them, and the new
    /// subscription's backlog has not arrived yet - so this clears both and puts the page back into
    /// "loading" rather than leaving the previous session's lines on screen under a new connection.
    public func resetForNewConnection() {
        cancelBatch()
        pending.removeAll()
        history.clear()
        buffer = LogBuffer()
        initialLogsReceived = false
    }

    /// Empties the window at the reader's or the core's request.
    ///
    /// The loaded-backlog flag is deliberately left alone: a page that has received its backlog and
    /// then been cleared is empty, not loading.
    public func clear() {
        cancelBatch()
        pending.removeAll()
        guard history.clear() else {
            return
        }
        buffer = history.buffer
    }

    /// The backlog that follows a subscription arrived.
    public func reportInitialBacklogReceived() {
        guard !initialLogsReceived else {
            return
        }
        initialLogsReceived = true
    }

    /// Adds lines to the window, batching the publish.
    public func append(_ entries: [LogEntry]) {
        guard !entries.isEmpty else {
            return
        }
        pending.append(contentsOf: entries)
        guard batchWorkItem == nil else {
            return
        }
        if buffer.entries.isEmpty {
            // The first batch after connecting is the backlog, and a page opened now must not wait
            // out the batch window to show it.
            flush()
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                self?.flush()
            }
            batchWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + batchInterval, execute: workItem)
        }
    }

    private func cancelBatch() {
        batchWorkItem?.cancel()
        batchWorkItem = nil
    }

    private func flush() {
        batchWorkItem = nil
        guard !pending.isEmpty else {
            return
        }
        let incoming = pending
        pending.removeAll(keepingCapacity: true)
        guard history.append(contentsOf: incoming) else {
            return
        }
        buffer = history.buffer
    }
}
