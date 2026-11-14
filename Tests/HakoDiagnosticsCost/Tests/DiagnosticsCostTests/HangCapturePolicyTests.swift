import Policy
import XCTest

/// What a hang report may cost, pinned per build configuration.
///
/// The defect these pin is not a wrong number in one constant - it is that Debug had a *second copy*
/// of the constants with the observation made as expensive as it can be: a one-second threshold, a
/// five-second cooldown and no per-process cap. A Debug build launched from the home screen therefore
/// reacted to the ordinary stalls of an unoptimised build with a thread suspension, an
/// all-goroutine dump and an archive rewrite, indefinitely. Release's numbers are part of the
/// contract too, and so is the absence of an unbounded profile.
final class HangCapturePolicyTests: XCTestCase {
    // MARK: - Release is untouched

    func testReleaseKeepsTheNumbersItAlwaysUsed() {
        let policy = HangCapturePolicy.resolve(isDebugBuild: false, captureRequested: false)
        XCTAssertEqual(policy, HangCapturePolicy.release)
        XCTAssertEqual(policy.reportThreshold, 2)
        XCTAssertEqual(policy.reportCooldown, 5 * 60)
        XCTAssertEqual(policy.maxReportsPerProcess, 3)
    }

    /// A flag in the environment is a Debug switch. A Release build cannot be opted into a more
    /// expensive observation path, because the launch that sets the switch is not the launch a user
    /// runs.
    func testReleaseIgnoresAnOptIn() {
        XCTAssertEqual(
            HangCapturePolicy.resolve(isDebugBuild: false, captureRequested: true),
            HangCapturePolicy.release
        )
    }

    // MARK: - Debug's routine profile

    func testDebugWithoutAnOptInIsTheRoutineProfile() {
        let policy = HangCapturePolicy.resolve(isDebugBuild: true, captureRequested: false)
        XCTAssertEqual(policy, HangCapturePolicy.debugRoutine)
        XCTAssertEqual(
            policy.reportThreshold,
            HangCapturePolicy.release.reportThreshold,
            "a Debug build still reports a genuinely stuck main thread at Release's threshold"
        )
    }

    /// The three numbers that were removed, stated as the thing that must not come back.
    func testDebugNoLongerUsesOneSecondFiveSecondsAndNoCap() {
        let policy = HangCapturePolicy.resolve(isDebugBuild: true, captureRequested: false)
        XCTAssertNotEqual(policy.reportThreshold, 1)
        XCTAssertNotEqual(policy.reportCooldown, 5)
        XCTAssertLessThan(
            policy.maxReportsPerProcess,
            Int.max,
            "no profile may be unbounded; that is the self-exciting loop, not a rate"
        )
    }

    // MARK: - Debug's capture profile

    func testDebugCaptureLowersTheThreshold() {
        let policy = HangCapturePolicy.resolve(isDebugBuild: true, captureRequested: true)
        XCTAssertEqual(policy, HangCapturePolicy.debugCapture)
        XCTAssertEqual(policy.reportThreshold, 1)
    }

    /// Asking for a lower threshold is not asking for an unbounded number of reports.
    func testDebugCaptureIsStillBounded() {
        let routine = HangCapturePolicy.debugRoutine
        let capture = HangCapturePolicy.debugCapture
        XCTAssertEqual(capture.maxReportsPerProcess, routine.maxReportsPerProcess)
        XCTAssertLessThanOrEqual(capture.reportCooldown, routine.reportCooldown)
        XCTAssertGreaterThanOrEqual(
            capture.reportCooldown,
            30,
            "the capture profile may be more eager than routine, not a storm"
        )
    }

    // MARK: - Every profile is bounded

    func testNoProfileIsUnboundedOrDegenerate() {
        for policy in [HangCapturePolicy.release, .debugRoutine, .debugCapture] {
            XCTAssertGreaterThan(policy.reportThreshold, 0)
            XCTAssertGreaterThan(policy.reportCooldown, 0)
            XCTAssertGreaterThan(policy.maxReportsPerProcess, 0)
            XCTAssertLessThan(policy.maxReportsPerProcess, Int.max)
        }
    }

    /// The worst case a profile can reach is its cap, and reaching it takes at least
    /// `(cap - 1) cooldowns`. The second number is what a cooldown is for; the first is what makes
    /// the cooldown sufficient on its own.
    func testTheCapAndTheCooldownBoundTheSameThing() {
        for policy in [HangCapturePolicy.release, .debugRoutine, .debugCapture] {
            let shortestTimeToExhaustTheCap = Double(policy.maxReportsPerProcess - 1) * policy.reportCooldown
            XCTAssertGreaterThanOrEqual(
                shortestTimeToExhaustTheCap,
                60,
                "a process must not be able to spend its whole budget inside a minute"
            )
        }
    }

    /// The policy is what the report records about itself, so it has to be a value a report can name.
    func testTheProfilesAreDistinguishable() {
        XCTAssertNotEqual(HangCapturePolicy.release, HangCapturePolicy.debugRoutine)
        XCTAssertNotEqual(HangCapturePolicy.debugRoutine, HangCapturePolicy.debugCapture)
    }

    // MARK: - Where the opt-in can come from

    func testTheEnvironmentVariableAsksForCapture() {
        for value in ["1", "true", "TRUE", "yes", " 1 "] {
            XCTAssertTrue(
                HangCapturePolicy.isCaptureRequested(
                    environment: [HangCapturePolicy.captureRequestEnvironmentVariable: value],
                    defaultsFlag: false
                ),
                "\(value.debugDescription) is a spelling a person types"
            )
        }
    }

    func testAnAbsentOrFalseEnvironmentValueDoesNotAskForCapture() {
        for value in ["", "0", "false", "no", "on"] {
            XCTAssertFalse(
                HangCapturePolicy.isCaptureRequested(
                    environment: [HangCapturePolicy.captureRequestEnvironmentVariable: value],
                    defaultsFlag: false
                ),
                "\(value.debugDescription) must not arm the capture profile"
            )
        }
        XCTAssertFalse(HangCapturePolicy.isCaptureRequested(environment: [:], defaultsFlag: false))
    }

    /// The persisted switch is the one that survives a launch the app did not start, which is the
    /// launch the watchdog is meant to observe.
    func testThePersistedFlagAsksForCaptureWithNoEnvironmentAtAll() {
        XCTAssertTrue(HangCapturePolicy.isCaptureRequested(environment: [:], defaultsFlag: true))
    }

    /// Both names are documented in the closeout report and on the type, so they are part of the
    /// interface rather than a detail a rename may move silently.
    func testTheSwitchNamesAreStable() {
        XCTAssertEqual(HangCapturePolicy.captureRequestEnvironmentVariable, "ENABLE_HANG_WATCHDOG")
        XCTAssertEqual(HangCapturePolicy.captureRequestDefaultsKey, "hako.debug.hang_watchdog")
    }
}
