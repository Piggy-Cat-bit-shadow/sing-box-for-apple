import Foundation

/// One refresh at a time, and at most one more owed.
///
/// # The load it exists to bound
///
/// `ExtensionEnvironments.postReload()` scans the crash, OOM and power report archives and republishes
/// what it found. The phone's root calls it from two places that fire together on a cold start -
/// `onAppear` and `scenePhase` becoming active - and both are on the path back from the background,
/// which is exactly when the app is trying to draw its first frames again. Each scan is real file
/// I/O: a directory walk, a metadata read per report, and for the crash archive a content read per
/// report to decide whether two half-reports should be merged. Doing that round twice because two
/// triggers five milliseconds apart both asked for it is work with no observable result.
///
/// # What it is not
///
/// It is deliberately not a throttle with a time window. A report can be written while a scan is
/// running, and a window would silently drop the refresh that would have shown it. The second
/// request is instead *remembered*: the current round finishes, and one more round runs immediately
/// after it. Requests that arrive during that follow-up are remembered the same way, so no request
/// is ever lost - only the redundant rounds between them.
///
/// Foundation only, so the state machine is compiled and driven by the tests.
public struct ReportRefreshGate: Equatable, Sendable {
    private var isRefreshing = false
    private var isAnotherRoundWanted = false

    public init() {}

    /// Whether a refresh is running right now.
    public var isBusy: Bool {
        isRefreshing
    }

    /// Whether another round has been asked for while one was running.
    public var isAnotherRoundPending: Bool {
        isAnotherRoundWanted
    }

    /// Asks to start a round.
    ///
    /// - Returns: `true` when the caller now owns the round and should run it. `false` when one is
    ///   already running - the request is remembered, and `end()` will ask for the follow-up.
    public mutating func begin() -> Bool {
        guard !isRefreshing else {
            isAnotherRoundWanted = true
            return false
        }
        isRefreshing = true
        return true
    }

    /// Ends the round the caller owned.
    ///
    /// - Returns: `true` when a request arrived during the round, in which case the caller still
    ///   owns the work and must run one more round (and then call `end()` again).
    public mutating func end() -> Bool {
        isRefreshing = false
        guard isAnotherRoundWanted else {
            return false
        }
        isAnotherRoundWanted = false
        isRefreshing = true
        return true
    }
}
