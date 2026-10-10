import Foundation
import Libbox

public enum Variant {
    #if os(macOS)
        public static var useSystemExtension = false
    #else
        public static let useSystemExtension = false
    #endif

    #if os(iOS)
        public static let applicationName = "SFI"
    #elseif os(macOS)
        public static let applicationName = "SFM"
    #elseif os(tvOS)
        public static let applicationName = "SFT"
    #endif

    public static let isBeta = LibboxVersion().contains("-")

    #if DEBUG
        public static let inDebug = true
    #else
        public static let inDebug = false
    #endif

    #if os(iOS)
        public static var debugNoIOS26 = false
        public static var debugNoIOS18 = false
    #endif

    public static let screenshotMode = ProcessInfo.processInfo.arguments.contains("-FASTLANE_SNAPSHOT")

    /// The per-case state a UI test asked for, or `nil` when no test asked for one.
    ///
    /// # Why this is a second selection and not a change to `screenshotMode`
    ///
    /// `screenshotMode` is one bit, read by 40 call sites across 23 files, and it means "a UI test
    /// is driving this launch, so use the fixture data" - `-FASTLANE_SNAPSHOT` is added by
    /// `SnapshotHelper.setupSnapshot`, which every suite runs. That bit cannot also answer *which*
    /// fixture: two cases need the same launch to differ, and one of them needs part of the
    /// fixture data to be absent. `test14OutboundModeIsAbsentByDefault` asserts that a
    /// configuration defining no outbound modes shows no mode control, so the three modes
    /// `setupMockData` hardcodes must not be installed for it - while `test14b` needs them.
    ///
    /// # The gate
    ///
    /// Both halves are required: `-ui_testing` (which only a UI-test launch carries) **and** an
    /// explicit `SCREENSHOT_STATE`. A production launch carries neither, so this is `nil` there and
    /// every default path is unchanged. A UI-test launch that names no state also gets `nil`, which
    /// is what keeps the twenty-three snapshot cases that rely on the whole fixture working exactly
    /// as they did.
    ///
    /// The state arrives in `launchEnvironment`, which is the channel `launch(state:)` already
    /// writes; a name that is absent by default needs no sentinel value.
    public static var uiTestFixtureState: String? {
        guard ProcessInfo.processInfo.arguments.contains("-ui_testing") else {
            return nil
        }
        guard let state = ProcessInfo.processInfo.environment["SCREENSHOT_STATE"], !state.isEmpty else {
            return nil
        }
        return state
    }

    /// Whether a UI test asked for a specific fixture state. See `uiTestFixtureState`.
    ///
    /// Distinct from `screenshotMode`, which is true for every UI-test launch. Use this to decide
    /// *what* the fixture contains; keep using `screenshotMode` to decide whether fixture data is
    /// wanted at all.
    public static var hasUITestFixtureState: Bool {
        uiTestFixtureState != nil
    }

    /// Whether the fixture should present a registered, connected tunnel profile.
    ///
    /// True for every UI-test launch except one that asked for `notInstalled`, which needs the
    /// page a new reader sees. This is separate from `screenshotMode` on purpose: that bit gates
    /// *whether* fixture data is used, and `ExtensionEnvironments.reload()` returns early on it -
    /// so keying the profile on the same bit would make "the tunnel is not installed" unreachable,
    /// because the early return is what stops the real profile from being looked up either way.
    public static var usesMockTunnelProfile: Bool {
        uiTestFixtureState != "notInstalled"
    }
}
