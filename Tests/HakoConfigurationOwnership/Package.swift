// swift-tools-version:5.7
import PackageDescription

// The configuration-ownership contract's tests.
//
// What this package is for: the pure decisions the Apple client's local-profile path is built from,
// each of which used to be an implicit assumption spread over a view, a bridge and a daemon.
//
//   * `CommandScope.swift` - which daemon a local profile may be shown to, and how a reply is
//     attributed to the target it came from.
//   * `ExtensionApplyReceipt.swift` - what the extension's answer proves: applied, recovered,
//     interrupted, failed, or nothing attributable at all.
//   * `ProfileUpdateOwnership.swift` - when an update still owns the body it is about to write, and
//     what a content-addressed revision is.
//   * `PlatformSettingsRevision.swift` - the platform settings a document cannot see, and when a
//     change to them needs a rebuild.
//
// Every source under `Sources/Core` is a symlink to the file that ships (placed by
// `scripts/link-test-sources.sh`), so these tests compile the shipping code rather than a copy of
// it. `RemoteRefreshApplier` is here as well: it is the file the ownership rules are wired into, and
// its tests exercise the sequence the app really runs.
//
// What is deliberately NOT here: `ExtensionProvider` and `ExtensionProfile`, which need
// NetworkExtension; `Profile+Update`, which needs the GRDB-backed profile record (that chain lives in
// `HakoSubscriptionUsage`); and any network. The decisions under test are pure values.
let package = Package(
    name: "HakoConfigurationOwnership",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Contract", path: "Sources/Contract"),
        .testTarget(name: "OwnershipTests", dependencies: ["Contract"], path: "Tests/OwnershipTests"),
    ]
)
