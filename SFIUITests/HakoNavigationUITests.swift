//
//  HakoNavigationUITests.swift
//  UI tests for the HAKO shell's navigation.
//
//  # Why it lives in SFIUITests/ and nowhere else
//
//  `SFIUITests` is a PBXFileSystemSynchronizedRootGroup, so every file under `SFIUITests/` is a
//  member of the SFIUITests UI-testing bundle with no `project.pbxproj` edit. That is the whole
//  membership mechanism, and it is why this file must be here rather than under a source directory:
//  a file placed under `SFI/` or `ApplicationLibrary/` would join the *app* target, where
//  `import XCTest` fails the build.
//
//  It was previously kept under `scripts/dev/`, on the mistaken belief that the target had to be
//  added to `project.pbxproj` by hand first. `scripts/dev/` belongs to no synchronized group, so the
//  file was never compiled: `build-for-testing` reported success while the class was absent from the
//  built bundle. Verified by symbol - `strings SFIUITests | grep HakoNavigationUITests` was 0 from
//  scripts/dev and is non-zero from here.
//
//  # What these assert
//
//  The visible consequence, never the trace: after each interaction the tab that must be selected is
//  selected, and a pushed child is present or absent as the navigation state says it should be. A
//  back button is the observable form of "a child is pushed", because the tab is already the current
//  one, which is exactly the failure this shell was written to avoid.
//
//  Each test corresponds to a row of the state table in docs/fork/APPLE-UI-RUNTIME-DEBUG.md.
//

import XCTest

final class HakoNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // The deterministic fixture, and the reason the first run of this suite measured
        // nothing: without it the client has no profiles, so Home presents "Install
        // Network Extension" and none of the pages these tests address exist. The manual
        // asks for a fixed screenshot fixture for exactly this reason - a suite whose data
        // depends on what the device happens to have installed is not a suite.
        app.launchArguments += ["-FASTLANE_SNAPSHOT", "YES"]
        // And a fixed language. The simulator's locale on this host is Chinese, so the one
        // assertion that reads a row's label was comparing an English expectation against
        // a Chinese label. Identifiers are language-independent; labels are not, and any
        // test that reads one has to pin the language it is reading.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private var tabBar: XCUIElement { app.tabBars.firstMatch }

    /// The tab bar's buttons, in the shell's own order: Home, Tools, More.
    private static let tabOrder = ["hako.tab.home", "hako.tab.tools", "hako.tab.more"]

    /// A tab, by identifier where the platform exposes one and by position where it does
    /// not.
    ///
    /// The fallback is not a convenience: `tabItem` identifiers are honoured by some
    /// SwiftUI releases and dropped by others, and a test that addressed a tab only by its
    /// identifier silently addressed nothing - all fifteen of these tests failed at
    /// "No matches found for `hako.tab.more`" the first time they were ever allowed to run.
    /// Position is locale-independent, which is what an identifier was for, and the order
    /// is asserted in `testRootTabOrderIsStable`.
    private func tab(_ identifier: String) -> XCUIElement {
        let byIdentifier = tabBar.buttons[identifier]
        if byIdentifier.exists {
            return byIdentifier
        }
        guard let index = Self.tabOrder.firstIndex(of: identifier) else {
            return byIdentifier
        }
        return tabBar.buttons.element(boundBy: index)
    }

    /// The shell's tabs are Home, Tools, More, in that order, in every language.
    func testRootTabOrderIsStable() {
        XCTAssertEqual(tabBar.buttons.count, 3, "the shell has exactly three roots")
        XCTAssertTrue(tab("hako.tab.home").isSelected, "and the first of them is Home")
    }

    /// The child page is present exactly when the enclosing stack has something to go back to.
    ///
    /// Addressed by the shared control's identifier rather than by position: position "0"
    /// is any button in the bar, and the Home page has a trailing menu button, so the
    /// positional form reported a pushed child on a cold launch. That was a defect in the
    /// test, not in the shell.
    private var isChildPushed: Bool {
        app.navigationBars.buttons["hako.nav.back"].exists
    }

    /// The same question, waited for.
    ///
    /// A push animates, so asking immediately after a tap is a race - and a race that
    /// shows up as an arbitrary iteration of a loop failing rather than as the page that
    /// is actually slow. Every assertion about a page having appeared goes through here.
    @discardableResult
    private func waitForChildPushed(_ timeout: TimeInterval = 15) -> Bool {
        app.navigationBars.buttons["hako.nav.back"].waitForExistence(timeout: timeout)
    }

    /// The same question in the other direction, also waited for.
    @discardableResult
    private func waitForChildDismissed(_ timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.navigationBars.buttons["hako.nav.back"].exists {
                return true
            }
            usleep(150_000)
        }
        return false
    }

    private func goBack() {
        app.navigationBars.buttons["hako.nav.back"].tap()
    }

    private var isRootTabReachable: Bool {
        tab("hako.tab.home").isHittable
    }

    // MARK: - Rows 1-3

    func testColdLaunchLandsOnHomeWithoutAChild() {
        XCTAssertTrue(tab("hako.tab.home").isSelected, "a cold launch must land on Home")
        XCTAssertTrue(waitForChildDismissed(), "Home must not launch with a pushed child")
    }

    func testHomeToLogsPushesAndBackReturnsToTools() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()

        XCTAssertTrue(waitForChildPushed(), "Logs must be pushed, so the stack must have a back button")
        XCTAssertFalse(
            tab("hako.tab.home").isHittable,
            "and the root tab bar must not be on screen while it is"
        )

        goBack()

        XCTAssertTrue(tab("hako.tab.tools").isSelected, "a pop must leave the selection on Tools")
        XCTAssertTrue(waitForChildDismissed(), "and must leave nothing pushed")
    }

    // MARK: - Row 4: a tab keeps its stack

    /// A page that was popped stays popped.
    ///
    /// This used to assert the opposite - that Logs was still on the Tools stack after a
    /// visit to Home - which is no longer reachable through the interface: the root tab bar
    /// is hidden while a detail page is up, so a tab cannot be switched without popping
    /// first. The shell still keeps a tab's stack for the programmatic paths (a settings
    /// notification arriving from another tab), and the invariant a user can observe is
    /// that going back and returning does not resurrect the page.
    func testAPoppedPageDoesNotComeBack() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()
        XCTAssertTrue(waitForChildPushed())

        goBack()
        XCTAssertTrue(waitForChildDismissed())

        tab("hako.tab.home").tap()
        tab("hako.tab.tools").tap()

        XCTAssertTrue(waitForChildDismissed(), "a popped page must not be restored by a tab switch")
        XCTAssertTrue(isRootTabReachable, "and the Tools root must be reachable")
    }

    // MARK: - Rows 6-8: nothing double-pushes

    func testSelectingAChildTwicePushesOnce() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()
        XCTAssertTrue(waitForChildPushed())
        goBack()
        XCTAssertTrue(waitForChildDismissed())

        // Open it again and take one step back. A single push returns to the Tools root; a second,
        // unrequested push would leave the child on screen and this is what catches it - counting
        // back buttons does not, because a stack shows only its top bar either way.
        //
        // Back on Home first: popping Logs leaves the app on the Tools root, where the Home
        // page's own shortcut does not exist. The test used to tap it from there.
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()
        XCTAssertTrue(waitForChildPushed())
        goBack()
        XCTAssertTrue(waitForChildDismissed(), "one back must reach the root, so exactly one push happened")
    }

    func testTappingTheCurrentTabPushesNothing() {
        tab("hako.tab.tools").tap()
        tab("hako.tab.tools").tap()

        XCTAssertTrue(waitForChildDismissed(), "tapping the root's own tab must not push a page")
        XCTAssertTrue(isRootTabReachable, "and must leave the root tab bar reachable")
    }

    // MARK: - Row 9: rapid switching ends where the last tap said

    func testRapidTabSwitchingEndsOnTheLastTab() {
        for identifier in ["hako.tab.tools", "hako.tab.more", "hako.tab.home", "hako.tab.more"] {
            tab(identifier).tap()
        }
        XCTAssertTrue(tab("hako.tab.more").isSelected, "the last tap decides the visible page")
    }

    // MARK: - Rows 11-12: state that arrives before its page exists

    func testDeepLinkToLogsBeforeToolsWasEverShown() {
        // A cold launch on Home, then a deep link straight to a child of a tab that has never
        // appeared. The shell arms the push when the primary's root appears, which is the ordering
        // this case exists to prove.
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()

        XCTAssertTrue(waitForChildPushed(), "the child must be pushed onto a primary that had never appeared")
        XCTAssertFalse(
            tab("hako.tab.tools").isHittable,
            "and it must belong to Tools, whose tab bar is hidden while the child is up"
        )
    }

    // MARK: - Sheets

    func testGroupsAndConnectionsSheetsOpenAndClose() {
        tab("hako.tab.home").tap()

        let open = app.buttons["hako.home.connections"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), "Home must offer the Connections workspace")

        // Asserted through the workspace's own search field rather than through
        // `app.sheets`: on this release a SwiftUI sheet is not reported as a `Sheet`
        // element at all, so `app.sheets.firstMatch` never exists and the old form of this
        // test could only ever fail. The page's content is the observable consequence
        // anyway, and it is what a user sees.
        // The workspace is a sheet, so it draws its own field rather than using the system's.
        let search = app.textFields["hako.activity.search"]
        open.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 30), "the Connections workspace must appear")

        app.navigationBars.buttons["hako.nav.close"].tap()
        // A dismissal is animated, and a suite that is running case after case gives it less
        // room than a single run does: ten seconds passed in isolation and timed out under the
        // full suite. The assertion is about the outcome, not about how quickly it arrives.
        XCTAssertFalse(search.waitForExistence(timeout: 30), "and must dismiss")
    }

    // MARK: - The root tab belongs to the roots

    /// The presentation policy's first rule, and the one the previous round broke: the tab
    /// bar is on Home, Tools and More, and nowhere else.
    ///
    /// It is asserted as hittability rather than existence on purpose. SwiftUI may keep the
    /// tab bar's view in the hierarchy while its content is not on screen, and "present but
    /// not reachable" is the defect a user experiences; "exists" would pass either way.
    func testRootTabIsReachableOnEveryRoot() {
        for identifier in ["hako.tab.home", "hako.tab.tools", "hako.tab.more"] {
            tab(identifier).tap()
            XCTAssertTrue(
                tab(identifier).isHittable,
                "\(identifier) must be reachable on its own root page"
            )
        }
    }

    /// Pushing a page hides the tab bar, and popping restores it.
    ///
    /// Both halves matter. A shell that hid the bar and never restored it would pass a
    /// one-directional test and leave the user with no navigation at all.
    func testPushingADetailHidesTheRootTabAndPoppingRestoresIt() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()

        XCTAssertTrue(waitForChildPushed(), "Logs must be pushed")
        XCTAssertFalse(
            tab("hako.tab.home").isHittable,
            "a pushed page must not leave the root tab bar reachable"
        )

        goBack()

        XCTAssertTrue(waitForChildDismissed(), "the pop must reach the Tools root")
        XCTAssertTrue(
            tab("hako.tab.home").isHittable,
            "popping must restore the root tab bar"
        )
    }

    // MARK: - The workspaces

    /// The proxy workspace has the search field the manual requires of a workspace, and
    /// the search actually filters.
    ///
    /// The screenshot mode fixture reports two groups, `my_group` and `Auto`, so a query
    /// that matches one of them must leave one and only one. Asserting the count rather
    /// than a row's presence is what makes this a discriminating test: a filter that
    /// returned everything would still show the row that was typed.
    func testProxyWorkspaceSearches() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.groups"].tap()

        // The proxy workspace is presented as a sheet, and a sheet has no bottom bar for a
        // system search field, so the page draws its own capsule - which is what the
        // reference shows on its proxy sheet. A drawn field is a text field with an
        // identifier; the pushed Activity page's is the system's and is a search field.
        let search = app.textFields["hako.proxies.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the proxy workspace must offer a search field")

        let firstGroup = app.staticTexts["my_group"]
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 5), "the fixture's first group must be on screen")

        // `Tokyo` is a member of the second group only, so it is a term exactly one group
        // can satisfy. `Auto` is not: the first group contains a member called `auto`, and
        // a filter that kept it would be right.
        search.tap()
        search.typeText("Tokyo")

        XCTAssertTrue(
            app.staticTexts["Auto"].waitForExistence(timeout: 3),
            "the group whose member matched must still be listed"
        )
        XCTAssertFalse(
            app.staticTexts["my_group"].exists,
            "a filtered list must not still contain a group that did not match"
        )

        // And the filter must not have changed what the core reported.
        app.buttons["hako.search.clear"].tap()
        XCTAssertTrue(
            app.staticTexts["my_group"].waitForExistence(timeout: 3),
            "clearing the search must restore every group, so the filter never mutated the data"
        )
    }

    /// The activity workspace offers search too, and its filter is scoped to it.
    func testActivityWorkspaceOffersSearch() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.connections"].tap()

        XCTAssertTrue(
            app.textFields["hako.activity.search"].waitForExistence(timeout: 20),
            "the activity workspace must offer a search field"
        )
    }

    // MARK: - Raw property names are not in the user interface

    /// The tunnel page's titles are the NetworkExtension property names in the source and
    /// must not be in the interface.
    ///
    /// This is the manual's own example of a discriminative test, and it is written as a
    /// pair: the raw key must be absent *and* the user-facing title must be present. An
    /// assertion on absence alone would pass on a page that failed to load at all.
    func testTunnelPageShowsUserTitlesAndNoRawPropertyNames() {
        tab("hako.tab.more").tap()

        let tunnel = app.buttons["hako.more.packetTunnel"]
        XCTAssertTrue(tunnel.waitForExistence(timeout: 5), "the More page must offer the tunnel page")
        tunnel.tap()

        // Each row is one combined accessibility element, so its title is its *label*. That
        // is what makes this discriminating: the label is what a VoiceOver user hears, so a
        // raw property name in it is a real defect and not a rendering detail.
        let includeAll = app.descendants(matching: .any)
            .matching(identifier: "hako.tunnel.includeAllNetworks")
            .firstMatch
        XCTAssertTrue(
            includeAll.waitForExistence(timeout: 5),
            "the tunnel page must offer the include-all-networks option"
        )
        let label = includeAll.label
        XCTAssertTrue(
            label.contains("Include All Networks"),
            "the option must be named in the user's terms; its label was: \(label)"
        )
        for rawKey in ["includeAllNetworks", "excludeAPNs", "excludeLocalNetworks", "enforceRoutes"] {
            XCTAssertFalse(
                label.contains(rawKey),
                "\(rawKey) is a framework property name and must not be in the row's label"
            )
        }
    }

    /// Every row that offers to go somewhere goes somewhere, and there is a way back.
    ///
    /// This is the automatable core of the manual's "every button works" gate item, and it is
    /// aimed at the failure the manual names first: a hierarchy where a row looks navigable
    /// and is not, or opens something and strands the reader. The list is written out rather
    /// than discovered, so it also documents the client's navigation surface in one place -
    /// a row added to a root without being added here is a row nobody has walked.
    func testEveryNavigableRowOpensSomething() {
        // Home's destinations: two sheets and a push into the Tools primary.
        tab("hako.tab.home").tap()
        for identifier in ["hako.home.groups", "hako.home.connections"] {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "\(identifier) must be on Home")
            row.tap()
            XCTAssertTrue(
                app.buttons["hako.nav.close"].waitForExistence(timeout: 20),
                "\(identifier) must open a sheet with a close control"
            )
            app.buttons["hako.nav.close"].tap()
            XCTAssertTrue(
                waitForCloseDismissed(),
                "\(identifier) must close again"
            )
            tab("hako.tab.home").tap()
        }

        // Tools' destinations: five pushes. Logs was the sixth until the review removed it: the
        // home already offers that page, and the tools page was the second door to it.
        tab("hako.tab.tools").tap()
        for identifier in [
            "hako.tools.networkQuality",
            "hako.tools.stun",
            "hako.tools.crashReports",
            "hako.tools.oomReports",
            "hako.tools.powerReports",
        ] {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "\(identifier) must be on Tools")
            row.tap()
            XCTAssertTrue(waitForChildPushed(), "\(identifier) must open a page")
            goBack()
            XCTAssertTrue(waitForChildDismissed(), "\(identifier) must come back")
        }

        // More's destinations, each of which already had its own case: this asserts the part
        // that case does not - that the row is enabled and hittable, not merely present.
        tab("hako.tab.more").tap()
        for key in ["onDemandRules", "packetTunnel", "profileOverride", "app", "core", "remoteControl"] {
            let row = app.buttons["hako.more.\(key)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "hako.more.\(key) must be on More")
            XCTAssertTrue(row.isEnabled, "hako.more.\(key) must be enabled")
            // Reachable, which for the last rows means scrolling to them first. Asserting
            // `isHittable` straight away failed on the sponsorship row for the honest reason
            // that it is below the fold - the assertion had not controlled its precondition.
            XCTAssertTrue(
                scrollIntoView(row),
                "hako.more.\(key) must be reachable"
            )
            // Back to the top, so the next row is looked for from where it starts.
            for _ in 0 ..< 8 {
                app.swipeDown()
            }
        }
    }

    /// Bring an element into view, as a reader would, and say whether it got there.
    @discardableResult
    private func scrollIntoView(_ element: XCUIElement, swipes: Int = 8) -> Bool {
        for _ in 0 ..< swipes {
            if element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.isHittable
    }

    /// The sheet's close control has been tapped, and the sheet is gone.
    @discardableResult
    private func waitForCloseDismissed(_ timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.buttons["hako.nav.close"].exists {
                return true
            }
            usleep(150_000)
        }
        return false
    }

    /// No page shows an internal identifier to the user.
    ///
    /// The manual's completion gate lists "no raw internal keys" and "no unrelated brand
    /// residue" as separate conditions, and neither can be established by reading the source:
    /// a framework property name reaches a row's label through a title that was never
    /// rewritten, and a stale catalogue entry keeps its text alive after every call site has
    /// moved on. So this walks the pages and reads what is actually on them.
    ///
    /// The pattern is a single unspaced token in camelCase (`excludeAPNs`) or an internal
    /// target name (`SFI`, `SFM`, `SFMExtension`). Uppercase core vocabulary such as the
    /// `URLTEST` a group header shows is matched deliberately: it is the core's word for the
    /// object and the page is quoting it, not leaking it.
    private func assertNoRawInternalKeys(on page: String) {
        let camelCase = try! NSRegularExpression(pattern: "^[a-z][A-Za-z]*[A-Z][A-Za-z]*$")
        let internalNames: Set<String> = ["SFI", "SFM", "SFMExtension", "ApplicationLibrary"]

        for element in app.staticTexts.allElementsBoundByIndex {
            guard element.exists else { continue }
            let text = element.label
            guard !text.isEmpty, !text.contains(" ") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if camelCase.firstMatch(in: text, range: range) != nil || internalNames.contains(text) {
                XCTFail("\(page) shows an internal identifier to the user: \(text)")
            }
        }
    }

    /// The sweep, over every page a root can reach.
    func testNoRawInternalKeysOnAnyPage() {
        for identifier in ["hako.tab.home", "hako.tab.tools", "hako.tab.more"] {
            tab(identifier).tap()
            sleep(1)
            assertNoRawInternalKeys(on: identifier)
        }

        // Every More destination, one at a time.
        tab("hako.tab.more").tap()
        for key in ["onDemandRules", "packetTunnel", "profileOverride", "app", "core", "remoteControl"] {
            let row = app.buttons["hako.more.\(key)"]
            guard row.waitForExistence(timeout: 5) else {
                XCTFail("hako.more.\(key) must be listed on the More page")
                continue
            }
            row.tap()
            XCTAssertTrue(waitForChildPushed(), "\(key) must open as a page")
            sleep(1)
            assertNoRawInternalKeys(on: key)
            goBack()
            _ = waitForChildDismissed()
        }
    }

    /// Every page the More tab lists is reachable, and each one opens as a page rather
    /// than replacing the shell.
    func testEveryMoreDestinationOpens() {
        tab("hako.tab.more").tap()

        for key in ["onDemandRules", "packetTunnel", "profileOverride", "app", "core"] {
            let row = app.buttons["hako.more.\(key)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(key) must be listed on the More page")
            row.tap()
            // Waited for, not sampled. This is the slowest page in the loop - it loads
            // settings, checks the helper service and sizes a cache before it renders - so
            // an immediate check failed here and nowhere else, which looked like "the App
            // page has no back control" and was in fact "the App page had not been pushed
            // yet when it was asked".
            XCTAssertTrue(
                waitForChildPushed(),
                "\(key) must open as a pushed page with a way back"
            )
            XCTAssertFalse(
                tab("hako.tab.home").isHittable,
                "\(key) is a detail page, so the root tab bar must not be reachable on it"
            )
            goBack()
            // Back on the More root before the next destination is tapped. Without this the
            // next tap can land while the pop is still animating, and the loop then fails on
            // an arbitrary row rather than on the one that is actually wrong.
            XCTAssertTrue(
                app.buttons["hako.more.core"].waitForExistence(timeout: 15),
                "the More root must be back before the next destination is opened"
            )
        }
    }

    // MARK: - One disclosure indicator per navigable row

    /// A navigable row may draw one chevron and no more.
    ///
    /// Counting them is the only way to catch `>>` from a UI test, because both chevrons
    /// are decorative and carry no label. The More root is the page to count on: every row
    /// on it is navigable, and it used to be the page where a `NavigationLink` inside a
    /// `Form` drew the platform's indicator underneath the row's own.
    func testNavigableRowsDrawExactlyOneIndicator() {
        tab("hako.tab.more").tap()

        let row = app.buttons["hako.more.core"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // The row is a combined accessibility element, so its own children are not
        // separate elements to count. What can be counted is the row's element count for
        // the disclosure glyph the component draws: exactly one image.
        // The row is a combined accessibility element, so its own glyphs are the countable
        // children: the icon well, and exactly one disclosure indicator. The `>>` this
        // guards against is a third image, and that is the whole assertion.
        XCTAssertEqual(
            row.images.count,
            2,
            "a navigable row draws its icon well and exactly one disclosure indicator"
        )
    }
}
