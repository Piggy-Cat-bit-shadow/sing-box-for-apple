import XCTest

@testable import Contract

/// The platform settings that shape the installed tunnel, and when they need a rebuild.
final class PlatformSettingsTests: XCTestCase {
    func testADefaultSnapshotHasNoInstalledSettingEnabled() {
        XCTAssertTrue(PlatformSettingsSnapshot().installedSettingsKeys.isEmpty)
        XCTAssertTrue(PlatformSettingsSnapshot().systemProxyEnabled, "the proxy defaults to on, as the app ships it")
    }

    func testTheRevisionChangesWithAnySettingAndNotOnlyWithTheKeys() {
        var candidate = PlatformSettingsSnapshot()
        let base = candidate.revision
        candidate.excludeAPNsRoute = true
        XCTAssertNotEqual(candidate.revision, base)
        // The proxy is not an "installed setting key" but it still distinguishes snapshots.
        var proxied = PlatformSettingsSnapshot()
        proxied.systemProxyEnabled = false
        XCTAssertNotEqual(proxied.revision, base)
        XCTAssertTrue(proxied.installedSettingsKeys.isEmpty, "the proxy does not force a rebuild")
        XCTAssertNotEqual(PlatformSettingsSnapshot().revision, 0, "zero is reserved for 'not recorded'")
    }

    func testTheSameSettingsAreUnchanged() {
        let settings = PlatformSettingsSnapshot(excludeAPNs: true, excludeAPNsRoute: true)
        XCTAssertEqual(PlatformSettingsPolicy.change(from: settings, to: settings), .unchanged)
    }

    /// The defect this policy exists for: the APNs switch changes nothing in the profile document,
    /// so a preview and the core both answer "no change" - and only a rebuild reinstalls the routes.
    func testAnAPNsSwitchNeedsARebuild() {
        let applied = PlatformSettingsSnapshot()
        let candidate = PlatformSettingsSnapshot(excludeAPNsRoute: true)
        XCTAssertEqual(
            PlatformSettingsPolicy.change(from: applied, to: candidate),
            .needsRebuild(keys: ["excludeAPNsRoute"]),
            "a route switch is invisible to the document, so the platform has to rebuild"
        )
        XCTAssertEqual(
            PlatformSettingsPolicy.change(from: applied, to: PlatformSettingsSnapshot(excludeAPNs: true)),
            .needsRebuild(keys: ["excludeAPNs"])
        )
        XCTAssertEqual(
            PlatformSettingsPolicy.change(from: applied, to: PlatformSettingsSnapshot(includeAllNetworks: true)),
            .needsRebuild(keys: ["includeAllNetworks"]),
            "include_all_networks clamps the MTU, which only a new TUN install can change"
        )
    }

    func testTheProxyAloneIsReappliableWithoutARebuild() {
        let applied = PlatformSettingsSnapshot()
        var candidate = applied
        candidate.systemProxyEnabled = false
        XCTAssertEqual(
            PlatformSettingsPolicy.change(from: applied, to: candidate),
            .proxyOnly,
            "the proxy can be re-applied to the installed settings; a rebuild would drop connections for nothing"
        )
    }

    func testAChangedInstalledSettingIsNotHiddenByAChangedProxy() {
        let applied = PlatformSettingsSnapshot()
        let candidate = PlatformSettingsSnapshot(systemProxyEnabled: false, excludeDefaultRoute: true)
        XCTAssertEqual(
            PlatformSettingsPolicy.change(from: applied, to: candidate),
            .needsRebuild(keys: ["excludeDefaultRoute"])
        )
    }

    /// A tunnel that just started was configured with exactly the settings it started with. Nil
    /// means "this process does not know them yet", and manufacturing a rebuild there would replace
    /// every tunnel on every reload.
    func testUnknownAppliedSettingsDoNotManufactureARebuild() {
        XCTAssertEqual(
            PlatformSettingsPolicy.change(from: nil, to: PlatformSettingsSnapshot(excludeAPNs: true)),
            .unchanged
        )
    }

    func testTheReasonNamesKeysAndNeverValues() {
        guard case let .needsRebuild(keys) = PlatformSettingsPolicy.change(
            from: PlatformSettingsSnapshot(),
            to: PlatformSettingsSnapshot(excludeAPNs: true, localSigningLoopback: true)
        ) else {
            return XCTFail("two route settings changed")
        }
        XCTAssertEqual(keys, ["excludeAPNs", "localSigningLoopback"], "the order is the declaration order")
        for key in keys {
            XCTAssertFalse(key.contains("true"), "a report names the key, not its value: \(key)")
        }
    }
}
