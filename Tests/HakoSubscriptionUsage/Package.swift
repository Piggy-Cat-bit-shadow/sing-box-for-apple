// swift-tools-version:5.7
import PackageDescription

// The subscription-usage data chain's tests.
//
// This package exists because the app project has no unit-test target - its `SFIUITests`,
// `SFTUITests` and `SFMUITests` are UI-test bundles that drive a booted app through a simulator,
// which cannot reach parser, merge, ordering or record-encoding logic deterministically. A real
// Xcode unit-test target would mean surgery on `sing-box.xcodeproj`; a package costs nothing and
// runs with `swift test`.
//
// The sources under test are the app's own files, reached through symlinks placed by
// `scripts/link-test-sources.sh`. They are not copies: a change to `SubscriptionInfo.swift` is a
// change to what these tests compile.
//
// `GRDB` here is a stub, deliberately not the real thing: the app project resolves GRDB through
// SwiftPM, and these tests must run with no network. The stub implements only the surface
// `Profile.swift` uses, so compiling that file proves its `encode(to:)`/`init(row:)` agree with
// the `add_subscription_info` migration's column names - the contract that decides whether
// metadata survives a round trip.
let package = Package(
    name: "HakoSubscriptionUsage",
    platforms: [.macOS(.v13)],
    targets: [
        // Stand-ins for the two app symbols the fetch path needs. See the file's own note.
        .target(name: "AppStubs", path: "Sources/AppStubs"),
        // A minimal GRDB 7 surface. Module name must be `GRDB` because that is what the app
        // sources import.
        .target(name: "GRDB", path: "Sources/GRDB"),
        // The one Libbox symbol the refresh file names.
        .target(name: "Libbox", path: "Sources/Libbox"),
        // The real subscription-usage sources.
        .target(name: "Core", dependencies: ["AppStubs"], path: "Sources/Core"),
        // The real profile record, compiled against the GRDB stub. `AppStubs` arrives through
        // `Core`, so only one module re-exports it and the symbols are unambiguous.
        .target(
            name: "ProfileUnderTest",
            dependencies: ["Core", "GRDB", "Libbox"],
            path: "Sources/Profile"
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests/CoreTests"),
        .testTarget(
            name: "ProfilePersistenceTests",
            dependencies: ["ProfileUnderTest", "Core", "GRDB", "Libbox"],
            path: "Tests/ProfilePersistenceTests"
        ),
    ]
)
