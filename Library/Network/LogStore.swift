import Combine
import Foundation

/// The command client's log window, its coalesced announcement, and who is allowed to hear it.
///
/// # Why the log state left `CommandClient`
///
/// `CommandClient` is one `ObservableObject`, and every view that reads it through
/// `@EnvironmentObject` is invalidated by any of its `@Published` properties changing. The log
/// window was one of those properties, and it changes on a batch window, so four dashboard cards -
/// two of them drawing a `Canvas` - were re-evaluated up to ten times a second by log lines they do
/// not display and cannot display. Debug's `-Onone` bodies turn that from noticeable into the frame
/// drops this round exists to remove.
///
/// # Why the window itself is not published
///
/// A `@Published` array is copied on every announcement, because publishing a value means handing the
/// new array to every observer while the store keeps its own. Appending in place and publishing a
/// counter instead makes the steady state free of that copy: the array has exactly one owner until
/// somebody holds it - the page while it reads, or the pause snapshot - and only then does the next
/// append copy. At most one reader exists and at most one snapshot is held, so the copy happens on
/// pause, not on every batch.
///
/// # Why visibility is part of the store and not of the page
///
/// The page can stop rendering, but it cannot stop the announcement: the announcement is a
/// `@Published` decoration on this object, and a `Combine` pipeline in the page runs whenever it
/// fires - whether or not any SwiftUI view is on screen. The tab shell keeps a tab's navigation stack
/// alive, so a Logs page that was pushed and then left behind by a tab switch keeps its model, its
/// subscription and its filter. Gating the announcement here is the only place that covers all of
/// them: while no page is on screen the window still fills and trims (so opening the page shows the
/// recent backlog) and nothing is announced, which means the page's pipeline does not run at all.
///
/// # Threading
///
/// Main-queue confined, like `CommandClient` itself: the handler hops to the main queue before
/// appending, and the coalescing work item is scheduled on the main queue. Every entry point asserts
/// it in debug builds.
public final class LogStore: ObservableObject {
    /// The announcement. A reader takes `buffer` when this changes.
    @Published public private(set) var revision: UInt64 = 0

    /// The level the core reports as its default.
    ///
    /// Log state, so it lives here rather than on the client for the same reason the window does: a
    /// level report must not invalidate a view that only draws traffic.
    @Published public private(set) var defaultLogLevel = 0

    /// Whether the core has sent the backlog that follows a subscription.
    ///
    /// Until it has, an empty window means "still loading" rather than "no logs" - the core always
    /// sends the backlog, even when it is empty. Published only while a page is on screen: the flag
    /// alone is worth no view work, and the page is brought up to date when it appears.
    @Published public private(set) var initialLogsReceived = false

    /// The retained window.
    ///
    /// Deliberately not `@Published` - see the type's comment. Read it from a `revision` change, on
    /// the main queue.
    public var buffer: LogBuffer {
        history.buffer
    }

    /// The largest window the page will be asked to render.
    public var maxLines: Int {
        history.maxLines
    }

    /// Whether a log page is on screen right now.
    public var isPageVisible: Bool {
        pageVisibility.isVisible
    }

    private var history: LogHistory
    private var pageVisibility = LogPageVisibility()
    private var hasReceivedInitialBacklog = false
    private let coalescingInterval: TimeInterval
    private var publishWorkItem: DispatchWorkItem?
    private var publishGeneration: UInt64 = 0

    /// - Parameters:
    ///   - maxLines: the retention bound.
    ///   - coalescingInterval: how long a batch waits before it is announced. A window that was
    ///     empty at the time of the batch is announced immediately instead; see
    ///     `LogPublicationPolicy`.
    public init(maxLines: Int = 3000, coalescingInterval: TimeInterval = 0.25) {
        history = LogHistory(maxLines: maxLines)
        self.coalescingInterval = coalescingInterval
    }

    deinit {
        publishWorkItem?.cancel()
    }

    // MARK: - Who is looking

    /// Records one log page appearing (`true`) or leaving (`false`).
    ///
    /// - Parameters:
    ///   - visible: the state the page reported.
    ///   - page: the page's identity. A report that repeats the state that page is already in is not
    ///     a change, and a page that was never visible cannot take another page's place.
    ///
    /// A page that becomes visible is announced the window once, even if nothing arrived while it was
    /// away and even if another page has been visible the whole time: that page has rendered nothing
    /// while it was hidden, so the announcement is the only thing that will draw the backlog it
    /// missed.
    public func setPageVisible(_ visible: Bool, for page: UUID) {
        assertMainThread()
        switch pageVisibility.setVisible(visible, for: page) {
        case .none:
            return
        case .left:
            // A page that is still on screen keeps its pending announcement: one window leaving is
            // not a reason to cancel another's.
            guard !pageVisibility.isVisible else {
                return
            }
            cancelScheduledPublish()
        case .becameVisible:
            cancelScheduledPublish()
            if initialLogsReceived != hasReceivedInitialBacklog {
                initialLogsReceived = hasReceivedInitialBacklog
            }
            announce()
        }
    }

    // MARK: - The stream

    /// Adds lines to the window and decides whether that is worth announcing.
    public func append(_ entries: [LogEntry]) {
        assertMainThread()
        let bufferWasEmpty = history.buffer.entries.isEmpty
        if !entries.isEmpty {
            history.append(contentsOf: entries)
        }
        if !hasReceivedInitialBacklog {
            hasReceivedInitialBacklog = true
            if pageVisibility.isVisible, !initialLogsReceived {
                initialLogsReceived = true
            }
        }
        switch LogPublicationPolicy.decision(
            isPageVisible: pageVisibility.isVisible,
            hasNewLines: !entries.isEmpty,
            bufferWasEmpty: bufferWasEmpty
        ) {
        case .none:
            break
        case .immediately:
            cancelScheduledPublish()
            announce()
        case .coalesced:
            scheduleAnnouncement()
        }
    }

    /// The core's own default level.
    public func setDefaultLogLevel(_ level: Int) {
        assertMainThread()
        guard defaultLogLevel != level else {
            return
        }
        defaultLogLevel = level
    }

    // MARK: - Clearing

    /// Empties the window at the reader's or the core's request.
    ///
    /// The loaded-backlog flag is deliberately left alone: a page that has received its backlog and
    /// then been cleared is empty, not loading. `resetForNewConnection()` is the other case.
    public func clear() {
        assertMainThread()
        cancelScheduledPublish()
        guard history.clear() else {
            return
        }
        if pageVisibility.isVisible {
            announce()
        }
    }

    /// A new subscription replaced the previous one.
    ///
    /// The window and the drop count belong to the subscription that produced them, and the new
    /// subscription's backlog has not arrived yet - so this clears both and puts the page back into
    /// "loading" rather than leaving the previous session's lines on screen under a new connection.
    public func resetForNewConnection() {
        assertMainThread()
        cancelScheduledPublish()
        history.clear()
        hasReceivedInitialBacklog = false
        guard pageVisibility.isVisible else {
            return
        }
        if initialLogsReceived {
            initialLogsReceived = false
        }
        announce()
    }

    // MARK: - Announcement

    private func announce() {
        revision &+= 1
    }

    /// Collapses every batch inside the window into one announcement.
    ///
    /// The generation guard is what keeps an announcement from firing after the window was cleared or
    /// the page left: a scheduled item that is still queued when either happens is stale, and announcing
    /// it would make the page render a window that no longer exists.
    private func scheduleAnnouncement() {
        guard publishWorkItem == nil else {
            return
        }
        publishGeneration &+= 1
        let generation = publishGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, pageVisibility.isVisible, publishGeneration == generation else {
                return
            }
            publishWorkItem = nil
            announce()
        }
        publishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + coalescingInterval, execute: workItem)
    }

    private func cancelScheduledPublish() {
        publishWorkItem?.cancel()
        publishWorkItem = nil
        publishGeneration &+= 1
    }

    private func assertMainThread() {
        assert(Thread.isMainThread, "LogStore must be used on the main thread")
    }
}
