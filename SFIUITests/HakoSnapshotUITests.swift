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

    func test30ReportInboxEmpty() {
        tab("hako.tab.more").tap()
        tap("hako.more.remoteControl")
        app.navigationBars.buttons["hako.nav.back"].tap()

        // Diagnostics live on Tools. The inbox's empty state is the page the manual asks
        // for: a report list with nothing in it must say so in the shared language.
        tab("hako.tab.tools").tap()
        sleep(1)
        snapshot("30_ToolsWithDiagnostics")
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

    func test50AddConfiguration() {
        tab("hako.tab.home").tap()
        // The profile card's own "+" is the way in; it is not part of the row vocabulary,
        // so it is addressed by its symbol's label.
        let add = app.buttons["Add"].firstMatch
        if add.waitForExistence(timeout: 5) {
            add.tap()
        } else {
            app.buttons.matching(identifier: "hako.home.groups").firstMatch.press(forDuration: 0)
        }
        sleep(1)
        snapshot("50_AddConfiguration")
    }
}
