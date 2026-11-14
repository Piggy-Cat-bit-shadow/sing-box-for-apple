import Foundation

/// Whether a batch of log lines should be announced to the page, and how.
public enum LogPublicationDecision: Equatable, Sendable {
    /// Nothing is announced: no reader would see the difference.
    case none

    /// Announced now, without waiting out the coalescing window.
    case immediately

    /// Announced once the coalescing window closes.
    case coalesced
}

/// When the log page is told that the window changed.
///
/// # Why the announcement is separate from the window
///
/// The window has to keep filling while nobody is looking - a page opened a second later must show
/// the backlog, and dropping lines because no view was attached would make the page's history depend
/// on which tab the reader happened to be on. The *announcement*, though, is pure SwiftUI work: a
/// publish runs the page's filter over the new lines and re-renders a text view. Doing that for a page
/// that is not on screen is cost with no result, and it is what a hidden tab does when nothing gates
/// it.
///
/// So the two are separated here: the window always advances, the announcement is decided by who is
/// looking and what actually changed.
///
/// # The three answers
///
/// * no page on screen - no announcement at all, whatever arrived.
/// * no new lines - no announcement. A batch that carried only the "backlog has arrived" flag is the
///   caller's separate concern, and that flag is set where it is read, not here.
/// * the window was empty - announce immediately. This is the first batch after a subscription, and
///   the page must paint it rather than wait out a window that exists to coalesce *changes*.
/// * otherwise - announce once the window closes.
///
/// Foundation only, so the decision is compiled and driven by the tests.
public enum LogPublicationPolicy {
    public static func decision(
        isPageVisible: Bool,
        hasNewLines: Bool,
        bufferWasEmpty: Bool
    ) -> LogPublicationDecision {
        guard isPageVisible, hasNewLines else {
            return .none
        }
        return bufferWasEmpty ? .immediately : .coalesced
    }
}

/// One log page's own visibility, under the identity it is known by upstream.
///
/// The page, not the store, is the thing that knows whether it is on screen: it is the one reading
/// `\.selection` and receiving its own lifecycle. This holds that answer and the identity it is
/// reported under, so that a repeated `onAppear` or a second `onDisappear` neither double-counts nor
/// becomes indistinguishable from another page's state.
///
/// Foundation only, so the idempotence is compiled and driven by the tests.
public struct LogPagePresence: Equatable, Sendable {
    /// The identity this page is registered under. Stable for the page's lifetime.
    public let id: UUID

    /// Whether this page is on screen right now.
    public private(set) var isVisible = false

    public init(id: UUID = UUID()) {
        self.id = id
    }

    /// Records this page appearing (`true`) or leaving (`false`).
    ///
    /// - Returns: whether the page's own state changed. A page that repeats a state - an `onAppear`
    ///   that runs twice, an `onDisappear` for a page that never appeared - reports nothing, which is
    ///   what keeps it from moving another page's presence.
    @discardableResult
    public mutating func setVisible(_ visible: Bool) -> Bool {
        guard isVisible != visible else {
            return false
        }
        isVisible = visible
        return true
    }
}

/// Which log pages are on screen, by identity.
///
/// # Why identity, and not a count
///
/// This was a counter, and a counter is wrong the moment more than one window can host a Logs page.
/// The app builds `ExtensionEnvironments` once, per process, and injects it into every window, so the
/// `LogStore` - and this type - is shared. A counter learns only that *someone* reported `true` or
/// `false`, never *who*; a page that was never visible had only to report `false` once to take a
/// visible page's presence away with it, and the visible page then stopped being announced to while
/// it was on screen. Membership by identity cannot express that: removing a page that is not a member
/// is not a change.
///
/// The same identity is what makes the two other questions answerable: whether a report is a repeat
/// (so a double `onAppear` is not counted twice), and whether a page that just appeared needs the
/// window announced to it even though another page was already visible - it does, because it has
/// processed nothing while it was hidden.
///
/// Foundation only, so the membership rule is compiled and driven by the tests.
public struct LogPageVisibility: Equatable, Sendable {
    /// What a reported state meant for the set.
    public enum Change: Equatable, Sendable {
        /// The report was a repeat, or a removal of a page that was not there. Nothing to do.
        case none

        /// This page was not visible and now is. Its page has rendered nothing while it was away and
        /// needs the window announced to it, even if other pages are already visible.
        case becameVisible

        /// This page was visible and now is not.
        case left
    }

    private var visiblePages: Set<UUID> = []

    public init() {}

    /// Whether at least one log page is on screen.
    public var isVisible: Bool {
        !visiblePages.isEmpty
    }

    /// How many log pages are on screen. Exposed for the tests and for assertions; nothing decides on
    /// it.
    public var pageCount: Int {
        visiblePages.count
    }

    /// Records one page appearing or leaving.
    ///
    /// - Parameters:
    ///   - visible: the state the page reported.
    ///   - id: the page's identity.
    /// - Returns: what that meant for the set. A page that was never visible cannot take another
    ///   page's place, and a repeated report is not a change.
    @discardableResult
    public mutating func setVisible(_ visible: Bool, for id: UUID) -> Change {
        if visible {
            guard !visiblePages.contains(id) else {
                return .none
            }
            visiblePages.insert(id)
            return .becameVisible
        }
        guard visiblePages.remove(id) != nil else {
            return .none
        }
        return .left
    }
}
