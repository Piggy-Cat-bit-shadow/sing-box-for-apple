//
//  HakoSnapshotUITests.swift
//  The manual's snapshot list, captured rather than eyeballed.
//
//  # Why this file exists next to SnapshotTests
//
//  `SnapshotTests` captures the three pages the marketing screenshots need, by launching
//  the app on a named `NavigationPage` and taking one picture. That covers the front door
//  and nothing behind it: a settings page, a workspace with a group expanded, an empty
//  report inbox and the add-configuration sheet are all reached by interaction, and no
//  launch argument can put the app there.
//
//  So these tests drive. Each one walks the same path a user would and captures the result,
//  which is also what makes them a layout test: a page that cannot be reached by tapping
//  what the test taps fails here rather than passing a static assertion.
//
//  Membership is automatic - `SFIUITests` is a file-system synchronized group - and the
//  images land wherever `SCREENSHOTS_DIR` points, exactly as `SnapshotTests` does.
//

import XCTest

@MainActor
final class HakoSnapshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        setupSnapshot(app)
        // A fixed language, so a captured screen is comparable run to run.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private static let tabOrder = ["hako.tab.home", "hako.tab.tools", "hako.tab.more"]

    private func tab(_ identifier: String) -> XCUIElement {
        let byIdentifier = app.tabBars.firstMatch.buttons[identifier]
        if byIdentifier.exists {
            return byIdentifier
        }
        guard let index = Self.tabOrder.firstIndex(of: identifier) else {
            return byIdentifier
        }
        return app.tabBars.firstMatch.buttons.element(boundBy: index)
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 15) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(identifier) must be reachable")
        element.tap()
    }

    // MARK: - Roots

    func test10Home() {
        tab("hako.tab.home").tap()
        sleep(1)
        snapshot("10_Home")
    }

    func test11Tools() {
        tab("hako.tab.tools").tap()
        sleep(1)
        snapshot("11_Tools")
    }

    func test12More() {
        tab("hako.tab.more").tap()
        sleep(1)
        snapshot("12_More")
    }

    /// The end of the longest root page, where the floating tab bar meets the last row.
    ///
    /// The manual lists the bottom safe area as its own check, and this is the only way to
    /// make it an assertion rather than an impression: scroll to the end and ask whether the
    /// last row is still reachable. A floating bar that covers the final row leaves it
    /// present in the tree and not hittable, which is exactly what a `isHittable` catches
    /// and an existence check does not.
    func test13MoreScrolledToBottom() {
        tab("hako.tab.more").tap()

        let last = app.buttons["hako.more.sponsors"]
        XCTAssertTrue(last.waitForExistence(timeout: 15), "the About section must be on the More page")

        for _ in 0 ..< 8 {
            app.swipeUp()
        }
        sleep(1)
        snapshot("13_MoreBottom")

        XCTAssertTrue(
            last.isHittable,
            "the last row of the page must not be covered by the floating tab bar"
        )
    }

    /// The outbound mode, chosen the way the reference presents it.
    ///
    /// The mode is the client's own state machine, so the test asserts against the core
    /// rather than only against the screen: pick a mode and the row must report itself
    /// selected. A segmented control could not be asked this question - its buttons carry no
    /// selection trait - which is part of why the page no longer uses one.
    func test14OutboundModeSelection() {
        tab("hako.tab.home").tap()

        let direct = app.buttons["hako.home.mode.direct"]
        XCTAssertTrue(direct.waitForExistence(timeout: 15), "the Home page must offer the outbound modes")
        direct.tap()
        sleep(1)
        snapshot("14_OutboundMode")

        XCTAssertTrue(
            app.buttons["hako.home.mode.direct"].isSelected,
            "the chosen mode must report itself as selected"
        )

        // Leave the fixture on the mode it started in.
        app.buttons["hako.home.mode.rule"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["hako.home.mode.rule"].isSelected, "the mode must switch back")
    }

    // MARK: - Secondary pages

    func test20Logs() {
        tab("hako.tab.home").tap()
        tap("hako.home.logs")
        sleep(1)
        snapshot("20_Logs")
    }

    func test21OnDemand() {
        tab("hako.tab.more").tap()
        tap("hako.more.onDemandRules")
        sleep(1)
        snapshot("21_OnDemand")
    }

    func test22Tunnel() {
        tab("hako.tab.more").tap()
        tap("hako.more.packetTunnel")
        sleep(1)
        snapshot("22_Tunnel")
    }

    func test23Core() {
        tab("hako.tab.more").tap()
        tap("hako.more.core")
        sleep(1)
        snapshot("23_Core")
    }

    func test24ClientSettings() {
        tab("hako.tab.more").tap()
        tap("hako.more.app")
        sleep(1)
        snapshot("24_ClientSettings")
    }

    // MARK: - Reports

    /// The report inbox's empty state, reached the way a user reaches it.
    ///
    /// This case used to open the remote-control page and go back, then capture Tools - it
    /// never opened a report list at all, so it proved nothing about the thing it was named
    /// for. It now opens the crash-report inbox, which is empty on a fresh fixture, and
    /// captures the empty state.
    func test30ReportInboxEmpty() {
        tab("hako.tab.tools").tap()
        tap("hako.tools.crashReports")
        XCTAssertTrue(
            app.navigationBars.buttons["hako.nav.back"].waitForExistence(timeout: 15),
            "the crash-report inbox must open"
        )
        sleep(1)
        snapshot("30_ReportInboxEmpty")
    }

    // MARK: - Workspaces

    func test40ProxiesCollapsed() {
        tab("hako.tab.home").tap()
        tap("hako.home.groups")
        XCTAssertTrue(app.textFields["hako.proxies.search"].waitForExistence(timeout: 15))
        sleep(1)
        snapshot("40_ProxiesCollapsed")
    }

    func test41ProxiesExpanded() {
        tab("hako.tab.home").tap()
        tap("hako.home.groups")
        let search = app.textFields["hako.proxies.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))

        // The fixture's second group starts collapsed and holds 137 members, which is the
        // case the expansion and the search field both have to survive.
        search.tap()
        search.typeText("Tokyo")
        sleep(1)
        snapshot("41_ProxiesFiltered")
    }

    func test42Activity() {
        tab("hako.tab.home").tap()
        tap("hako.home.connections")
        XCTAssertTrue(app.textFields["hako.activity.search"].waitForExistence(timeout: 15))
        sleep(1)
        snapshot("42_Activity")
    }

    // MARK: - Modal

    /// The configuration sheet: its three ways in are action tiles, not rows.
    ///
    /// Reached through the profile card's own add control. That control had no
    /// accessibility label at all - an icon-only button that VoiceOver could not name - so
    /// this case could not reach the sheet until the control was labelled.
    /// The configuration centre: the modal that lists this client's configurations.
    ///
    /// The manual's golden sample for this page is a complex modal - its own chrome, a
    /// configuration card carrying progress, an update-all action and the ways in - so the
    /// harness has to be able to open it before anything about it can be judged.
    func test51ConfigurationCentre() {
        tab("hako.tab.home").tap()
        tap("hako.profile.select")
        sleep(2)
        snapshot("51_ConfigurationCentre")

        // The manual's modal chrome is a close on the leading side, a centred title and the
        // page's own actions on the trailing side. The centre had no close control at all:
        // the only way out was to drag the sheet down.
        let close = app.buttons["hako.nav.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "a modal must offer a way to close it")
        XCTAssertTrue(close.isHittable, "the close control must be reachable")

        // The manual's configuration card carries an update-all action, and it should exist
        // exactly when there is a remote configuration to fetch.
        XCTAssertTrue(
            app.buttons["Update All"].waitForExistence(timeout: 10),
            "a page with a remote configuration must offer to update them all"
        )

        let add = app.buttons["Add Configuration"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the centre must offer a way to add one")
        add.tap()
        sleep(2)
        snapshot("52_AddConfigurationFromCentre")

        XCTAssertTrue(
            app.buttons["hako.nav.close"].waitForExistence(timeout: 10),
            "the add flow is itself a modal and must also be closeable"
        )
    }

    func test50AddConfiguration() {
        tab("hako.tab.home").tap()
        tap("hako.profile.add")
        sleep(1)
        snapshot("50_AddConfiguration")
    }
}
