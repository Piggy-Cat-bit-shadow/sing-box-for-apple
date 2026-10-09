// Primary-route mapping regression check.
//
// The shell decides twice where a page lives: what a primary renders as its root, and what
// it pushes on top. Both decisions are pure functions of the selection, extracted for
// exactly this reason - the Apple project has no unit-test target and this machine has no
// simulator runtime, so a decision that only exists inside a View cannot be checked at all.
//
// Run against the built macOS framework:
//
//   scripts/dev/check-hako-primary-route.sh
//
// It links ApplicationLibrary and exercises the mapping and the child-arming state machine.
// A failure exits non-zero with the case that broke.

import ApplicationLibrary
import Foundation

// Compiled together with the production sources, so the checks live in a type with an explicit
// entry point rather than at the top level: swiftc only allows top-level code in a file named
// main.swift, and naming this one that would hide what it is.
@main
enum HakoPrimaryRouteCheck {
    static func main() {

    var failures = 0

    func check(_ condition: Bool, _ label: String) {
        if condition {
            print("ok   \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    // MARK: - Where a page lives

    check(HakoPrimaryRoute(.dashboard).primary == .home, "dashboard belongs to Home")
    check(HakoPrimaryRoute(.dashboard).child == nil, "dashboard is a root, not a child")

    check(HakoPrimaryRoute(.tools).primary == .tools, "tools belongs to Tools")
    check(HakoPrimaryRoute(.tools).child == nil, "tools is a root")

    check(HakoPrimaryRoute(.logs).primary == .tools, "logs belongs to Tools")
    check(HakoPrimaryRoute(.logs).child == .logs, "logs is a child of Tools")
    check(HakoPrimaryRoute(.logs).root == .tools, "logs renders the Tools root beneath it")
    check(HakoPrimaryRoute(.logs).hasChild, "logs reports that it has a child")

    check(HakoPrimaryRoute(.settings).primary == .more, "settings belongs to More")
    check(HakoPrimaryRoute(.settings).child == nil, "settings is a root")

    // Every page must have a primary, and only the root of that primary may be a root page.
    for page in NavigationPage.allCases {
        let route = HakoPrimaryRoute(page)
        check(route.primary.rootPage == route.root, "\(page) resolves to a primary root")
        if let child = route.child {
            check(child.hakoPrimary == route.primary, "\(child) is a child of its own primary")
            check(!child.isHakoPrimaryRoot, "\(child) is not the primary's root")
        }
    }

    // MARK: - Arming the child push

    // Launch: the client starts on a child page, before anything has rendered.
    let launched = HakoPrimaryChildArmer.next(pushed: [:], selection: .logs)
    check(launched == [.tools: .logs], "a launch on logs arms the push for Tools")

    // The user opens logs while Home is on screen: the Tools tab arms, Home is untouched.
    let opened = HakoPrimaryChildArmer.next(pushed: [:], selection: .logs)
    check(opened[.home] == nil, "arming a child does not push anything on another primary")

    // Selecting the primary's own root clears that primary's push.
    let popped = HakoPrimaryChildArmer.next(pushed: [.tools: .logs], selection: .tools)
    check(popped[.tools] == nil, "selecting the root clears the push")

    // A primary that is not selected keeps what it had: SwiftUI keeps the tab's stack alive, so
    // leaving Logs and returning to Tools must return to Logs.
    //
    // Applied as `applying(arming:selection:)` rather than `next(...)`, because that is the rule the
    // shell uses: a column only arms when it owns the selection. Asserting `next(...)` here is what
    // previously let this pass while the shell popped the page - the broken implementation and the
    // assertion shared the same wrong assumption, so the check could not see the defect.
    let kept = HakoPrimaryChildArmer.applying(arming: .home, pushed: [.tools: .logs], selection: .dashboard)
    check(kept[.tools] == .some(.logs), "leaving a primary keeps its pushed child")
    check(kept[.home] == nil, "and the newly selected primary stays on its root")

    // The regression itself, in the smallest form: Tools holds Logs and the selection moves to the
    // Tools root, so Tools must drop its child - but the Home column observing the same change must
    // not be the one that does it. Before the fix the armer wrote the entry keyed on the *new*
    // selection's primary, so a column being left drove its own page to nil and "return to Tools"
    // showed the root instead of Logs.
    let leftTools = HakoPrimaryChildArmer.applying(arming: .home, pushed: [.tools: .logs], selection: .tools)
    check(leftTools[.tools] == .some(.logs),
          "a column that does not own the selection cannot clear another primary's child")

    // The tap itself is modelled, because it is half the rule and the half that was wrong:
    // `primarySelection`'s setter returns early when the tapped primary already owns the selection,
    // and otherwise moves to the page that primary was last left on - its pushed child if it has
    // one, its root if not. Tapping a tab must not discard a stack the tab still holds.
    //
    // Each column then arms only if the selection actually changed, because that is what
    // `onChangeCompat(of: selection)` does - running the armer on an unchanged selection would be a
    // stricter test than the shell, and would report a bug the shell cannot have.
    func tabTap(_ primary: HakoPrimaryTab, selection previous: NavigationPage, pushed: [HakoPrimaryTab: NavigationPage])
        -> (selection: NavigationPage, pushed: [HakoPrimaryTab: NavigationPage])
    {
        guard primary != previous.hakoPrimary else {
            return (previous, pushed)
        }
        var selection = pushed[primary] ?? primary.rootPage
        var pushed = pushed
        for column in HakoPrimaryTab.allCases {
            let before = pushed[column]
            pushed = HakoPrimaryChildArmer.applying(arming: column, pushed: pushed, selection: selection)
            if column != selection.hakoPrimary {
                check(pushed[column] == before, "\(column) is untouched while \(selection) is selected")
            }
        }
        selection = pushed[selection.hakoPrimary] ?? selection.hakoPrimary.rootPage
        return (selection, pushed)
    }

    // Logs open on Tools; tap Home; tap Tools again. The push must still be there.
    var replay: [HakoPrimaryTab: NavigationPage] = [:]
    var replaySelection: NavigationPage = .dashboard
    replay = HakoPrimaryChildArmer.applying(arming: .tools, pushed: replay, selection: .logs)
    replaySelection = .logs
    print("     replay: open logs        -> \(replay.sorted { $0.key.rawValue < $1.key.rawValue })")

    (replaySelection, replay) = tabTap(.home, selection: replaySelection, pushed: replay)
    check(replay[.tools] == .some(.logs), "leaving Tools for Home keeps the push")
    print("     replay: tap Home         -> \(replay.sorted { $0.key.rawValue < $1.key.rawValue })")

    (replaySelection, replay) = tabTap(.tools, selection: replaySelection, pushed: replay)
    check(replaySelection == .logs, "tapping Tools while viewing its child does not reset to the root")
    check(replay[.tools] == .some(.logs), "a push survives tab switches")

    (replaySelection, replay) = tabTap(.home, selection: replaySelection, pushed: replay)
    (replaySelection, replay) = tabTap(.more, selection: replaySelection, pushed: replay)
    check(replay[.tools] == .some(.logs), "and survives a longer detour through More")
    print("     replay: Home then More   -> \(replay.sorted { $0.key.rawValue < $1.key.rawValue })")

    check(replay[.home] == nil, "and Home is still untouched")

    // Selecting a different child of the same primary replaces the push rather than stacking.
    let replaced = HakoPrimaryChildArmer.next(pushed: [.tools: .logs], selection: .tools)
    check(replaced[.tools] == nil, "returning to the root replaces the child")

    // Idempotence: applying the same selection twice must not change the state, or a view update
    // that re-runs the arming would push the page twice.
    let once = HakoPrimaryChildArmer.next(pushed: [:], selection: .logs)
    let twice = HakoPrimaryChildArmer.next(pushed: once, selection: .logs)
    check(once == twice, "arming is idempotent")

    // Every child page of every primary arms exactly one push, on its own primary.
    for page in NavigationPage.allCases where !page.isHakoPrimaryRoot {
        let armed = HakoPrimaryChildArmer.next(pushed: [:], selection: page)
        check(armed.count == 1, "\(page) arms exactly one push")
        check(armed[page.hakoPrimary] == page, "\(page) arms on \(page.hakoPrimary)")
    }

    // MARK: - The settings page request

    // The root records a requested settings page because the page that pushes it may not exist
    // yet; these are the cases that decide whether the request is honoured, dropped or repeated.
    check(HakoSettingsPush.decide(requested: .remoteControl, isRemoteControlPresented: false)
        == HakoSettingsPush.Decision(pushRemoteControl: true, clearRequest: true),
        "a pending remote-control request pushes once")
    check(HakoSettingsPush.decide(requested: .remoteControl, isRemoteControlPresented: true)
        == HakoSettingsPush.Decision(pushRemoteControl: false, clearRequest: true),
        "a request that arrives while the page is open is satisfied, not repeated")
    check(HakoSettingsPush.decide(requested: nil, isRemoteControlPresented: false)
        == HakoSettingsPush.Decision(pushRemoteControl: false, clearRequest: false),
        "no request does nothing")
    check(HakoSettingsPush.decide(requested: .app, isRemoteControlPresented: false)
        == HakoSettingsPush.Decision(pushRemoteControl: false, clearRequest: false),
        "a page the settings root does not push keeps its request")

    // Applying the same request twice must be the same as applying it once: the root clears it, and
    // the rule above is what makes clearing safe.
    var applied = HakoSettingsPush.decide(requested: .remoteControl, isRemoteControlPresented: false)
    check(applied.pushRemoteControl, "the first application pushes")
    var isPresented = true
    if applied.clearRequest {
        applied = HakoSettingsPush.decide(requested: nil, isRemoteControlPresented: isPresented)
    }
    check(!applied.pushRemoteControl, "and the cleared request cannot push again")

    print("")
    if failures == 0 {
        print("PASS: primary route mapping")
    } else {
        print("FAILED: \(failures) check(s)")
    }
    exit(failures == 0 ? 0 : 1)
    }
}