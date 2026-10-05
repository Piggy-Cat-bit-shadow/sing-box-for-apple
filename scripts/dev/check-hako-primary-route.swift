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
let kept = HakoPrimaryChildArmer.next(pushed: [.tools: .logs], selection: .dashboard)
check(kept[.tools] == .logs, "leaving a primary keeps its pushed child")
check(kept[.home] == nil, "and the newly selected primary stays on its root")

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

print("")
if failures == 0 {
    print("PASS: primary route mapping")
} else {
    print("FAILED: \(failures) check(s)")
}
exit(failures == 0 ? 0 : 1)
