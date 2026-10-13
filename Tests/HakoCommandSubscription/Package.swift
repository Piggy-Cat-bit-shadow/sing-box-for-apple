// swift-tools-version:5.7
import PackageDescription

// The command client's subscription-recovery policy's tests.
//
// Why this package exists: after a trip through the background, the app's status subscription can
// be dead while the client still believes it is connected. The foreground path cannot see that - it
// connects only while `!isConnected`, and the scene becomes active before the loss has been
// observed - so the rebuild has to be driven from the loss, and it has to be bounded so that a
// tunnel that is genuinely gone cannot produce a retry loop. Those are the two decisions that were
// wrong, and they are both pure.
//
// So the file that decides is compiled here, and every branch is driven directly:
// `Sources/Policy/CommandSubscriptionRecovery.swift` is a **symlink** to
// `Library/Network/CommandSubscriptionRecovery.swift` (placed by `scripts/link-test-sources.sh`),
// so this tests the file that ships rather than a copy.
//
// What is deliberately not here:
//
//   * `Libbox`, and therefore `CommandClient` itself. The client's job around these decisions is to
//     call them at the right moments and to create the connection - `startConnection()`,
//     `performConnection(token:)` - which needs the kernel's own client type. What can be wrong
//     about *whether* to rebuild is expressed in this policy, which is here.
//   * `UIApplication`'s background/foreground notifications, which are what call `suspend()` and
//     `resume()`. They exist only on the platforms the app targets.
let package = Package(
    name: "HakoCommandSubscription",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Policy", path: "Sources/Policy"),
        .testTarget(
            name: "SubscriptionRecoveryTests",
            dependencies: ["Policy"],
            path: "Tests/SubscriptionRecoveryTests"
        ),
    ]
)
