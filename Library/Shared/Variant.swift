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

    /// Whether the screenshot fixture keeps the system appearance.
    ///
    /// The fixture forces dark because the marketing captures are dark. A capture that is
    /// being compared against another app has to be able to be light, or the comparison is
    /// of two colour schemes rather than of two layouts.
    public static var screenshotKeepsSystemAppearance: Bool {
        ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] == "light"
    }

    /// The tunnel state the screenshot fixture starts in.
    ///
    /// `SCREENSHOT_STATE=disconnected` makes Home capture the stopped state. Anything
    /// else - including nothing - leaves the fixture connected, which is what every other
    /// page wants.
    public static var screenshotDisconnectedTunnel: Bool {
        ProcessInfo.processInfo.environment["SCREENSHOT_STATE"] == "disconnected"
    }
}
