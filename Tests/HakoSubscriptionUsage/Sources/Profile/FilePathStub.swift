import Foundation

// The two directories `Library/Database/Profile+RW.swift` reads and writes. In the app these point
// at the shared app-group container; here they are ordinary process-wide values the tests set to a
// temporary directory, so the read/write half of a refresh is exercised against real files.

public enum FilePath {
    public static var sharedDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hako-subscription-info-tests", isDirectory: true)
    public static var iCloudDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hako-subscription-info-tests-icloud", isDirectory: true)
}
