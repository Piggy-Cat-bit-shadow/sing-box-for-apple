import Foundation

/// How expensive one hang report may be, and how many of them a process may take.
///
/// # What this decides
///
/// `HangWatchdog` detects a stalled main thread and then suspends that thread to read its native
/// stack, asks the Go runtime for an all-goroutine dump, and rewrites an archived report on disk at
/// each of its snapshot offsets. Every one of those steps runs *while the thread it is measuring is
/// already late*, so the report is not free observation: it lengthens the stall it recorded and
/// makes the next one more likely. That is tolerable when it happens once and it is not tolerable
/// when the same process can do it every five seconds for as long as the app is open.
///
/// Those three numbers - the threshold, the cooldown and the per-process cap - were previously
/// written twice, once per build configuration, with the debug branch set to one second, five
/// seconds and no cap at all. A desktop-launched Debug build therefore armed its most expensive
/// observation path on the stalls `-Onone` produces constantly, and the report list that resulted
/// was then scanned again on every return to the foreground. The debug branch is what this type
/// replaces: a named, bounded profile per situation instead of a second copy of the constants.
///
/// # Why the cap is on every profile
///
/// A cooldown alone is not a bound - it is a rate. A process left open for an hour at a one-minute
/// cooldown can still write sixty reports, and sixty archive rewrites is the self-exciting loop this
/// exists to stop. `maxReportsPerProcess` is what makes the worst case finite, so every profile has
/// one, including the opt-in capture profile. There is deliberately no profile with `Int.max`.
///
/// # Debug capture is opt-in, and opt-in is still bounded
///
/// Debug's routine profile is Release's threshold with a shorter cooldown: it still reports a
/// genuinely stuck main thread, without treating the ordinary cost of an unoptimised build as a
/// hang. Lowering the threshold to a second is useful when someone is hunting a specific hitch, and
/// it is asked for explicitly - by `ENABLE_HANG_WATCHDOG=1` in the environment, or by the persisted
/// `hako.debug.hang_watchdog` flag - rather than being what every Debug launch gets. See
/// `isCaptureRequested(environment:defaultsFlag:)` for where each of those can actually be set.
///
/// Foundation only, and free of every platform API, so the file that decides the cost is the file
/// the tests compile.
public struct HangCapturePolicy: Equatable, Sendable {
    /// How long the main thread must fail to make progress before a report is begun.
    public let reportThreshold: TimeInterval

    /// The shortest interval between two reports, measured from the start of each.
    public let reportCooldown: TimeInterval

    /// The number of reports one process may write. Finite in every profile.
    public let maxReportsPerProcess: Int

    public init(reportThreshold: TimeInterval, reportCooldown: TimeInterval, maxReportsPerProcess: Int) {
        self.reportThreshold = reportThreshold
        self.reportCooldown = reportCooldown
        self.maxReportsPerProcess = maxReportsPerProcess
    }

    /// A Release build. These are the numbers Release has always used, unchanged.
    public static let release = HangCapturePolicy(
        reportThreshold: 2,
        reportCooldown: 5 * 60,
        maxReportsPerProcess: 3
    )

    /// A Debug build that did not ask for capture.
    ///
    /// The same threshold Release uses, because "two seconds with no main-thread progress" is a
    /// stall in an unoptimised build too - and a shorter cooldown, because a Debug session is short
    /// and the interesting stall is likely to be the one being reproduced right now.
    public static let debugRoutine = HangCapturePolicy(
        reportThreshold: 2,
        reportCooldown: 60,
        maxReportsPerProcess: 3
    )

    /// A Debug build that asked for capture: the one-second threshold, so that a hitch shorter than
    /// the routine profile's is still recorded. The cooldown and the cap are not relaxed - asking
    /// for a lower threshold is not asking for an unbounded number of reports.
    public static let debugCapture = HangCapturePolicy(
        reportThreshold: 1,
        reportCooldown: 30,
        maxReportsPerProcess: 3
    )

    /// The policy a build of this kind runs with.
    ///
    /// - Parameters:
    ///   - isDebugBuild: whether this is a Debug build.
    ///   - captureRequested: whether a Debug build explicitly asked for capture. Ignored by Release,
    ///     which cannot be opted out of.
    public static func resolve(isDebugBuild: Bool, captureRequested: Bool) -> HangCapturePolicy {
        guard isDebugBuild else {
            return .release
        }
        return captureRequested ? .debugCapture : .debugRoutine
    }

    /// The environment variable that asks a Debug build for `debugCapture`.
    public static let captureRequestEnvironmentVariable = "ENABLE_HANG_WATCHDOG"

    /// The persisted flag that asks a Debug build for `debugCapture`.
    ///
    /// # Why there are two switches
    ///
    /// The environment variable is the one that works while a Debug build is launched by something
    /// that can set its environment - `xcrun devicectl device process launch --environment-variables`
    /// launches the app on a device *without* attaching a debugger, which is exactly the situation
    /// the watchdog is meant to observe. It does not work for the launch the report described: a
    /// Debug build tapped on the home screen inherits no environment, so a scheme-only variable
    /// would have been a switch that cannot be flipped in the case that matters.
    ///
    /// This key is the second switch: it is read from `UserDefaults` at launch, so it survives the
    /// app being started from the home screen. It is spelled out here rather than hidden in the
    /// watchdog so that setting it is a documented, reproducible act - `defaults write` on a
    /// simulator or a Mac, or the same key written by a debug build tool - and so that the value
    /// Release reads (`resolve(isDebugBuild: false, ...)`) is irrelevant rather than load-bearing.
    public static let captureRequestDefaultsKey = "hako.debug.hang_watchdog"

    /// Whether a Debug build asked for `debugCapture`.
    ///
    /// - Parameters:
    ///   - environment: the process environment, so the caller decides which process it is asking.
    ///   - defaultsFlag: the persisted flag's value; the caller reads it because this type holds no
    ///     storage.
    /// - Returns: `true` when either switch asks for capture. Both accept the spellings a person
    ///   types (`1`, `true`, `YES`) for the environment half; the persisted half is a `Bool`.
    public static func isCaptureRequested(environment: [String: String], defaultsFlag: Bool) -> Bool {
        if defaultsFlag {
            return true
        }
        guard let value = environment[captureRequestEnvironmentVariable] else {
            return false
        }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}
