// swift-tools-version:5.7
import PackageDescription

// The interface-monitor startup policy's tests.
//
// Why this package exists: `InterfaceMonitorStartup` decides whether the VPN's startup can block
// forever waiting for a first path update, and that decision is what airplane mode exposed - with no
// network there is no path transition, so the update need not arrive at all. The decisions are pure
// (a bound, a staleness comparison, and what a timeout means) and they are where the defect was.
//
// So the file that decides is compiled here, against the same `DispatchSemaphore` the shipping code
// uses, and every failure path is driven directly.
// `Sources/Policy/InterfaceMonitorStartup.swift` is a **symlink** to
// `Library/Network/InterfaceMonitorStartup.swift` (placed by `scripts/link-test-sources.sh`), so this
// tests the file that ships rather than a copy.
//
// What is deliberately not here:
//
//   * `NWPathMonitor`. It exists only on the Apple platforms the app targets, and a substitute would
//     test the substitute. `startDefaultInterfaceMonitor` is the thin adapter - it starts a real
//     monitor, seeds from `currentPath` and waits with a bound - and the part of it that can be wrong
//     is expressed in this policy, which is here. The adapter's own shape is asserted by
//     `scripts/run-interface-startup-tests.sh`.
//   * `LibboxInterfaceUpdateListenerProtocol`. The callback's effect on the listener is
//     `onUpdateDefaultInterface`, which is about describing a path rather than about whether startup
//     can hang.
let package = Package(
    name: "HakoInterfaceStartup",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Policy", path: "Sources/Policy"),
        .testTarget(name: "InterfaceStartupTests", dependencies: ["Policy"], path: "Tests/InterfaceStartupTests"),
    ]
)
