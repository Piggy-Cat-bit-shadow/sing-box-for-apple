// swift-tools-version:5.7
import PackageDescription

// The cost of the diagnostics path, tested where a compiler is available.
//
// # Why this package exists
//
// The three things this round changed are all "how much work does the app do by default", and all
// three are decisions rather than plumbing:
//
//   * `HangCapturePolicy` - how long a main-thread stall has to last before a Debug build suspends
//     the thread, dumps every goroutine and rewrites an archive, how often it may repeat that, and
//     how many times per process. The Debug branch was one second, five seconds and no cap.
//   * `ReportRefreshGate` - how many report-archive rounds a foreground return may start, given that
//     the root asks for one from two places that fire together.
//   * `LogHistory` - what the log window retains, what it drops, and whether an append changed
//     anything. Retention is what the store publishes; the boundary that stopped a log line from
//     invalidating the dashboard is in `LogStore`, which needs Combine and cannot be compiled here.
//
// Each of those is Foundation-only on purpose, so this package compiles the file that ships rather
// than a re-implementation of it: `Sources/Policy/*.swift` are **symlinks** to the app's own files
// (placed by `scripts/link-test-sources.sh`).
//
// What is deliberately not here:
//
//   * `HangWatchdog` itself, which reads `P_TRACED`, Mach thread info and the run loop, and calls
//     `LibboxGoroutineDump()`. What can be wrong about *how expensive* a report may be is the
//     policy, and that is here.
//   * `LogStore`, which is an `ObservableObject` and needs Combine. Its decision - what is retained,
//     and what a batch contains - is `LogHistory`, and that is here.
//   * The report managers, which are `@MainActor` and read the file system. What can be wrong about
//     *how many rounds run* is the gate, and that is here.
let package = Package(
    name: "HakoDiagnosticsCost",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Policy", path: "Sources/Policy"),
        .testTarget(
            name: "DiagnosticsCostTests",
            dependencies: ["Policy"],
            path: "Tests/DiagnosticsCostTests"
        ),
    ]
)
