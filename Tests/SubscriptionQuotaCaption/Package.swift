// swift-tools-version:5.7
import PackageDescription

// The macOS quota caption's decision table, compiled from the app's own files.
//
// The two sources under test are symlinks into `Library/Network`, the same convention the other
// test packages in this repository use: a change to either file is a change to what these tests
// compile, and no copy can drift. Both files are Foundation-only on purpose, so this package runs
// with `swift test` on any platform - no SwiftUI, no Xcode, no GRDB stub, no Libbox.
let package = Package(
    name: "SubscriptionQuotaCaption",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Caption", path: "Sources/Caption"),
        .testTarget(name: "CaptionTests", dependencies: ["Caption"], path: "Tests/CaptionTests"),
    ]
)
