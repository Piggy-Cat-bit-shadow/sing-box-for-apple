// swift-tools-version:5.7
import PackageDescription

// The screen-state observer's tests.
//
// Why this package exists: `ScreenStateObserver.swift` decides when the device pause is entered and
// when it is lifted, and it does that from two undocumented Darwin notifications whose delivery
// cannot be reproduced on a simulator, let alone on the Windows machine this repository is edited
// on. But the *decisions* - which fact a value maps to, what a failed read means, whether a repeat
// is an edge, what a snapshot may publish, and whether a callback may publish after `cancel()`
// returned - are pure, and they are where the defects were.
//
// So the file that decides is compiled here, against fakes, and every failure path is driven
// directly. `Sources/Policy/ScreenStateObserver.swift` is a **symlink** to
// `Library/Network/ScreenStateObserver.swift` (placed by `scripts/link-test-sources.sh`), so this
// tests the file that ships rather than a copy.
//
// What is deliberately not here:
//
//   * `ScreenStateObserverDarwin.swift` imports `notify` and `Libbox`, so it only builds for iOS.
//     It is the thin adapter - it calls the C functions and checks their status - and the only way
//     to test it is on a device. Its correctness is argued from the SDK signature, and the part
//     that can be wrong (interpreting the status) is expressed in `NotifyStateRead`, which is here.
//   * `LibboxCommandServer`. `ScreenStatePublishing` stands in for it; the test asserts which
//     methods were called and with what, which is the observable behaviour a device would show.
let package = Package(
    name: "HakoScreenState",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Policy", path: "Sources/Policy"),
        .testTarget(name: "ScreenStateTests", dependencies: ["Policy"], path: "Tests/ScreenStateTests"),
    ]
)
