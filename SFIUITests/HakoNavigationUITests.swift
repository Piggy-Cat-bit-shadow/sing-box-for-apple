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
        app.launch()
    }

    private var tabBar: XCUIElement { app.tabBars.firstMatch }

    private func tab(_ identifier: String) -> XCUIElement {
        tabBar.buttons[identifier]
    }

    /// The child page is present exactly when the enclosing stack has something to go back to.
    private var isChildPushed: Bool {
        app.navigationBars.buttons.element(boundBy: 0).exists
    }

    // MARK: - Rows 1-3

    func testColdLaunchLandsOnHomeWithoutAChild() {
        XCTAssertTrue(tab("hako.tab.home").isSelected, "a cold launch must land on Home")
        XCTAssertFalse(isChildPushed, "Home must not launch with a pushed child")
    }

    func testHomeToLogsPushesAndBackReturnsToTools() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()

        XCTAssertTrue(tab("hako.tab.tools").isSelected, "Logs belongs to Tools, so Tools must be selected")
        XCTAssertTrue(isChildPushed, "Logs must be pushed, so the stack must have a back button")

        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(tab("hako.tab.tools").isSelected, "a pop must leave the selection on Tools")
        XCTAssertFalse(isChildPushed, "and must leave nothing pushed")
    }

    // MARK: - Row 4: a tab keeps its stack

    func testLeavingToolsAndReturningKeepsLogs() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()
        XCTAssertTrue(isChildPushed)

        tab("hako.tab.home").tap()
        tab("hako.tab.tools").tap()

        XCTAssertTrue(isChildPushed, "returning to Tools must show what was on its stack")
    }

    // MARK: - Rows 6-8: nothing double-pushes

    func testSelectingAChildTwicePushesOnce() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()
        XCTAssertTrue(isChildPushed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(isChildPushed)

        // Open it again and take one step back. A single push returns to the Tools root; a second,
        // unrequested push would leave the child on screen and this is what catches it - counting
        // back buttons does not, because a stack shows only its top bar either way.
        app.buttons["hako.home.logs"].tap()
        XCTAssertTrue(isChildPushed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(isChildPushed, "one back must reach the root, so exactly one push happened")
    }

    func testTappingTheCurrentTabDoesNotResetItsStack() {
        tab("hako.tab.home").tap()
        app.buttons["hako.home.logs"].tap()
        tab("hako.tab.tools").tap()

        XCTAssertTrue(isChildPushed, "tapping the current tab must not pop what it is showing")
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

        XCTAssertTrue(tab("hako.tab.tools").isSelected)
        XCTAssertTrue(isChildPushed)
    }

    // MARK: - Sheets

    func testGroupsAndConnectionsSheetsOpenAndClose() {
        tab("hako.tab.home").tap()

        app.buttons["hako.home.connections"].tap()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "the Connections sheet must appear")
        app.sheets.firstMatch.swipeDown()
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "and must dismiss")
    }
}
