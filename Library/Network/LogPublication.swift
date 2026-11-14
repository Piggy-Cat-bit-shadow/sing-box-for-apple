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
///   caller's separate concern, and it is handled where the flag is set, not here.
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

/// How many log pages are on screen.
///
/// A counter rather than a flag because "visible" is not one view's property: a second window on the
/// Mac, or a page that reappears before the previous instance's `onDisappear` runs, would otherwise
/// turn the announcement off while something is still drawing. Leaving is never allowed to take the
/// count below zero - a view can be torn down twice (a tab switch and a navigation pop in the same
/// turn), and that must not make the store believe a page is still there.
public struct LogPageVisibility: Equatable, Sendable {
    private var visiblePages = 0

    public init() {}

    /// Whether at least one log page is on screen.
    public var isVisible: Bool {
        visiblePages > 0
    }

    /// How many log pages are on screen. Exposed for the tests and for assertions; nothing decides
    /// on it.
    public var pageCount: Int {
        visiblePages
    }

    /// Records one page appearing or leaving.
    ///
    /// - Returns: whether this changed whether anything is visible.
    @discardableResult
    public mutating func setVisible(_ visible: Bool) -> Bool {
        let wasVisible = isVisible
        if visible {
            visiblePages += 1
        } else if visiblePages > 0 {
            visiblePages -= 1
        }
        return wasVisible != isVisible
    }
}
