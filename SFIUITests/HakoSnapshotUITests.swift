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

    /// Relaunch the app in one of the fixture's states.
    ///
    /// The suite launches once in `setUp` with no state, and the fixture reads its state from
    /// the environment at launch, so a case that needs another state has to start the app
    /// again rather than navigate to it.
    private func launch(state: String) {
        app.terminate()
        app.launchEnvironment["SCREENSHOT_STATE"] = state
        app.launch()
    }

    /// The same patience the navigation suite gives the same step.
    ///
    /// This was 15 seconds while `HakoNavigationUITests` waited 30 for the identical
    /// operation, and the difference showed up as a flake: a full run of 35 cases on a loaded
    /// machine failed to reach a row that the navigation suite had reached moments earlier in
    /// the same run, and the case passed on its own. A test that fails under load is a defect
    /// in the test.
    private func tap(_ identifier: String, timeout: TimeInterval = 30) {
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

    /// Home when the configuration cannot be read.
    ///
    /// The condition is reported where it stands and the page still draws behind it. That is
    /// the whole point of the notice: this used to be an alert, which took the screen, hid
    /// every card, and could not be read without dismissing it first. The test therefore
    /// asserts both halves - that the notice is there, and that the page it sits on is still
    /// there with it.
    func test15ProfileLoadFailure() {
        launch(state: "profileError")
        tab("hako.tab.home").tap()

        let notice = app.otherElements["hako.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "an unreadable configuration must be reported")
        XCTAssertTrue(
            app.buttons["hako.notice.action"].exists,
            "the notice must offer a way to try again"
        )
        snapshot("15_ProfileLoadFailure")

        // The page behind the notice is still a page.
        XCTAssertTrue(
            app.buttons["hako.profile.add"].exists,
            "the notice must not take the place of the page's own content"
        )
    }

    /// Home while this client is driving another instance.
    ///
    /// That mode renders a different page entirely - the legacy card grid - so it is the one
    /// place where this client is still two products in one, and nothing could reach it until
    /// the fixture learned to start in remote control.
    func test16RemoteHome() {
        launch(state: "remote")
        tab("hako.tab.home").tap()
        sleep(3)

        // The fixture's remote server is unreachable, so entering remote control raises a
        // connection alert. Its *text* is what this asserts: the message used to carry the
        // transport's own account of the failure, which is not something a reader can act on.
        if app.buttons["Ok"].waitForExistence(timeout: 15) {
            let message = app.alerts.firstMatch.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .joined(separator: " ")
            XCTAssertTrue(
                message.contains("remote server"),
                "the alert must say what happened; it said: \(message)"
            )
            for rawDetail in ["rpc error", "tcp", "desc =", "connection reset"] {
                XCTAssertFalse(
                    message.contains(rawDetail),
                    "the transport's own account (\(rawDetail)) belongs in the log, not the alert: \(message)"
                )
            }
            app.buttons["Ok"].tap()
            sleep(2)
        }
        snapshot("16_RemoteHome")

        // Whichever page this is, it is still a page of this client: the root tab is there and
        // the destination rows lead somewhere.
        XCTAssertTrue(
            tab("hako.tab.tools").waitForExistence(timeout: 15),
            "the remote dashboard must still be inside this client's shell"
        )
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

    /// The report list and one report, which no fixture could reach before.
    ///
    /// The fixture now archives a report through the archive's real writer, so the list has a
    /// row, the read view has real files behind it, and both are exercised end to end. Until
    /// this existed the report pages were the one part of the client that built, ran, and had
    /// never been looked at.
    func test32ReportListAndDetail() {
        tab("hako.tab.tools").tap()
        tap("hako.tools.crashReports")

        // The list is no longer empty, which is the whole point of the fixture.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "hako.report."))
        XCTAssertTrue(
            rows.firstMatch.waitForExistence(timeout: 20),
            "the fixture's report must appear in the list"
        )
        snapshot("32_ReportList")

        // The empty-state footnote explains an empty page, so it must not be on this one.
        XCTAssertFalse(
            app.staticTexts["You will receive a report when a crash occurs."].exists,
            "a page with a report on it must not explain what happens when there is one"
        )

        rows.firstMatch.tap()

        // Asserted on something only the read view has. The back control is on *both* pages -
        // the list is pushed too - so asserting it proved nothing, and the first version of
        // this case passed a tap that had not navigated anywhere.
        XCTAssertTrue(
            app.staticTexts["Files"].waitForExistence(timeout: 20),
            "the report must open as a read view listing its artifacts"
        )
        sleep(1)
        snapshot("33_ReportDetail")
    }

    /// The other two report kinds, which had no writer to archive through.
    ///
    /// The crash archive could be written to and its siblings could not, so nothing but the
    /// app's own watchdog could put a report in them and their pages had never been looked at.
    /// They have a writer now, and the fixture uses it, so all three report kinds are exercised
    /// the same way rather than one of them standing in for the other two.
    func test34OutOfMemoryReportListAndDetail() {
        tab("hako.tab.tools").tap()
        tap("hako.tools.oomReports")

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "hako.report."))
        XCTAssertTrue(
            rows.firstMatch.waitForExistence(timeout: 20),
            "the fixture's out-of-memory report must appear in the list"
        )
        snapshot("34_OOMReportList")

        rows.firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Files"].waitForExistence(timeout: 20),
            "the report must open as a read view listing its artifacts"
        )
        sleep(1)
        snapshot("35_OOMReportDetail")
    }

    /// The power report, the third of the three.
    func test36PowerReportListAndDetail() {
        tab("hako.tab.tools").tap()
        tap("hako.tools.powerReports")

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "hako.report."))
        XCTAssertTrue(
            rows.firstMatch.waitForExistence(timeout: 20),
            "the fixture's power report must appear in the list"
        )
        snapshot("36_PowerReportList")

        rows.firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Files"].waitForExistence(timeout: 20),
            "the report must open as a read view listing its artifacts"
        )
        sleep(1)
        snapshot("37_PowerReportDetail")
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

        // The page has to *resolve*, which is what this case never asked before.
        //
        // It asserted only that the search field existed, so a workspace stuck on its loading
        // state passed it: the data model's loading flag was cleared while the view, which did
        // not observe the object owning it, kept rendering the spinner. With the tunnel stopped
        // the empty state below was unreachable, and a live connection list would not have
        // appeared either.
        XCTAssertTrue(
            app.staticTexts["No connections"].waitForExistence(timeout: 20),
            "the workspace must resolve out of its loading state when there is nothing to show"
        )
        XCTAssertFalse(
            app.staticTexts["Loading..."].exists,
            "the workspace must not still be loading once it has resolved"
        )
    }

    // MARK: - Modal

    /// The configuration sheet: its three ways in are action tiles, not rows.
    ///
    /// Reached through the profile card's own add control. That control had no
    /// accessibility label at all - an icon-only button that VoiceOver could not name - so
    /// this case could not reach the sheet until the control was labelled.
    /// The manual editor, the last surface a fixture can reach that had not been looked at
    /// large. It is a form of typed fields rather than a list of rows, which is why it is not
    /// covered by the settings-page pass.
    func test53ManualEditor() {
        tab("hako.tab.home").tap()
        tap("hako.profile.add")
        sleep(1)
        tap("Create Manually")
        sleep(3)
        // Captured before the assertion: when a navigation is in question, what is on the
        // screen afterwards is the evidence, and an assertion only tells you it was wrong.
        snapshot("53_AfterCreateManually")
        // A back control, not a close: the editor is *pushed inside* the modal, so the
        // platform's back control is the right one and asserting on the close was asserting
        // the wrong thing - which is what the first version of this case did.
        XCTAssertTrue(
            app.navigationBars.buttons["hako.nav.back"].waitForExistence(timeout: 20),
            "the manual editor must open as a page inside the modal"
        )
        sleep(1)
        snapshot("53_ManualEditor")
    }

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
