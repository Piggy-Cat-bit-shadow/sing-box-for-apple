#!/usr/bin/env python3
"""Compile and run the phone's profile switch, and assert how the page wires it.

The switch itself is upstream's: `OverviewViewModel.switchProfile` persists the chosen
identifier, broadcasts it, and reloads a running tunnel. This gate is not about that
method - it is about the two things the phone page adds around it, neither of which any
other gate can see:

  1. **Order.** Two selections must not produce two interleaved switches. The rule lives
     in `HakoProfileSwitchQueue`, a Foundation-only file, and this gate compiles that
     file **as it ships** and drives the page's own `selectProfile` - extracted verbatim
     from `HakoHomeView.swift` - through the interleavings: a second tap while the first
     switch is in flight, a burst, a burst that returns to the first choice, and a switch
     that fails.

  2. **Wiring.** The configuration centre must reach that function. A binding written by
     hand in each of the sheet's four selection sites would be four chances to miss one,
     in a file that is regenerated from upstream, so the page hands the sheet one
     side-effecting `Binding` - the shape upstream's own `OverviewView` uses. That is a
     structural property, and it is asserted on the source text with the comments
     stripped.

  3. **Surface.** The centre's rows draw `ProfileRowCardSurface`, not `cardStyle()`. On the 26
     releases `cardStyle()` is the system's glass, and a list of identical rows over the sheet's
     black background read as panes of glass rather than as the settings-style list the centre
     is. The check also holds the rest of the decision together: the 16-point shape, the fill
     (the sheet's grouping step, `tertiarySystemGroupedBackground` - not the grouped page's
     `secondarySystemGroupedBackground`, which equals this sheet's light canvas), the row's hit
     area and selection/menu, and the Mac's own `cardStyle()` arm. A row that kept the fill but
     lost the shape, or took the grouped page's fill, is the same defect wearing a different
     surface.

It also asserts the page's single alert presentation. Two `.alert` modifiers on one view
are one presentation and the outer one wins, which is how a failed switch came to report
nothing; the profile switch's failure is raised through exactly that presentation. The same
rule is checked in the phone's Taildrop page, which ported upstream's pair of `.alert`
modifiers onto one view unchanged - the inbox's failures were never presented - and now folds
them into its own `pageAlert` (see `taildrop_alert_problems`).

Usage:
    python check_hako_profile_switch.py [--root DIR] [--explain]
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

VIEW_FILE = os.path.join("ApplicationLibrary", "Views", "HakoStyle", "HakoHomeView.swift")
QUEUE_FILE = os.path.join("ApplicationLibrary", "Views", "HakoStyle", "HakoProfileSwitchQueue.swift")
PICKER_FILE = os.path.join("ApplicationLibrary", "Views", "HakoStyle", "HakoProfilePickerSheet.swift")
TAILDROP_FILE = os.path.join("ApplicationLibrary", "Views", "HakoStyle", "HakoTaildropView.swift")
PHONE_ROOT_FILE = os.path.join("SFI", "HakoPhoneRootView.swift")

REQUIRED_METHOD = "selectProfile"


class ExtractionError(RuntimeError):
    pass


def code_only(text: str) -> str:
    """`text` with comments removed and string literals kept.

    The same state machine `check_swift_structure.py` walks, and for the same reason: a `//`
    inside a string literal (a URL, most often) is not a comment. Comments become a space so
    a pattern cannot be assembled across one.

    Needed because the view's doc comments name the calls these checks forbid ("this page
    used to hand the centre `$selectedProfileID`"), so searching the raw text would fail on
    the explanation instead of on the code.
    """
    out: list[str] = []
    index = 0
    length = len(text)
    in_line = False
    in_block = 0
    in_string = False
    in_multiline = False
    raw_hashes = 0

    while index < length:
        char = text[index]
        nxt = text[index + 1] if index + 1 < length else ""

        if char == "\n":
            in_line = False
            out.append(char)
            index += 1
            continue
        if in_line:
            index += 1
            continue
        if in_block:
            if char == "*" and nxt == "/":
                in_block -= 1
                index += 2
                continue
            if char == "/" and nxt == "*":
                in_block += 1
                index += 2
                continue
            index += 1
            continue
        if in_multiline:
            out.append(char)
            if char == '"' and text.startswith('"""' + "#" * raw_hashes, index):
                out.extend('""' + "#" * raw_hashes)
                in_multiline = False
                index += 3 + raw_hashes
                continue
            index += 1
            continue
        if in_string:
            out.append(char)
            if char == "\\":
                if index + 1 < length:
                    out.append(text[index + 1])
                index += 2
                continue
            if char == '"':
                in_string = False
            index += 1
            continue

        if char == "/" and nxt == "/":
            in_line = True
            index += 2
            out.append(" ")
            continue
        if char == "/" and nxt == "*":
            in_block += 1
            index += 2
            out.append(" ")
            continue
        if text.startswith('"""', index):
            in_multiline = True
            out.extend('"""')
            index += 3
            continue
        if char == '"':
            in_string = True
            out.append(char)
            index += 1
            continue
        if char == "#":
            hashes = 0
            probe = index
            while probe < length and text[probe] == "#":
                hashes += 1
                probe += 1
            if probe < length and text[probe] == '"':
                raw_hashes = hashes
                in_string = True
                out.extend(text[index:probe + 1])
                index = probe + 1
                continue
        out.append(char)
        index += 1
    return "".join(out)


def extract_method(source: str, name: str, path: str) -> str:
    """The full text of the `private func <name>(...)` declaration, body included.

    Braces inside string literals and comments are counted like any other brace - wrong in
    general, right here, because this declaration's strings contain no braces. Balance is
    checked, so a mis-parse is an error rather than a truncated function.
    """
    match = re.search(r"^[ \t]*private func %s\b" % re.escape(name), source, re.MULTILINE)
    if match is None:
        raise ExtractionError(
            "%s: no `private func %s` - the page's switch wiring has moved, and this gate is "
            "no longer testing the shipped code" % (path, name)
        )
    depth = 0
    index = source.index("{", match.start())
    for position in range(index, len(source)):
        character = source[position]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():position + 1]
    raise ExtractionError("%s: `%s` never closes" % (path, name))


def opened(method: str) -> str:
    """The declaration with `private` dropped from its own `func` line.

    Not a semantic change: inside `HakoHomeView` the method is reachable from the view's
    whole file, which is what `private` means on a member of a type, and `Probe` stands in
    for that file. Widening the declaration is what lets the harness call it without a
    second copy of the body.
    """
    return re.sub(r"^(\s*)private func ", r"\1func ", method, count=1)


HARNESS_HEADER = """\
// Generated by scripts/dev/check_hako_profile_switch.py. Not a source file.
//
// `Extracted.selectProfile` below is the verbatim text of `HakoHomeView.selectProfile`,
// lifted out of the view. `HakoProfileSwitchQueue` is compiled from the shipped file
// beside this one. `Coordinator` is the smallest stand-in for `OverviewViewModel` that can
// answer the questions the queue exists to settle: what was applied, in what order, and
// whether the page's busy gate was up while it happened.
import Foundation

struct Profile {}

struct Environments {}

/// Stands in for `OverviewViewModel`: the official switch's observable state, and a
/// recorder for the calls the page makes through it.
@MainActor
final class Coordinator {
    /// `OverviewViewModel.reasserting` - the page's own busy gate.
    var reasserting = false

    /// The identifiers the page asked for, in the order it asked.
    var applied: [Int64] = []

    /// `reasserting` as each switch *started*: the gate must have been up for every one.
    var reassertingAtStart: [Bool] = []

    /// How many switches are running at once, and the worst that ever got.
    var running = 0
    var maxRunning = 0

    /// How long a switch takes. The interleavings this gate drives need the first one to
    /// still be in flight when the next selection arrives.
    var nanoseconds = 0

    func switchProfile(_ profileID: Int64, profile: Profile, environments: Environments) async {
        applied.append(profileID)
        reassertingAtStart.append(reasserting)
        running += 1
        maxRunning = max(maxRunning, running)
        if nanoseconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
        }
        running -= 1
        // The official method's last line, and the reason the page must raise the gate per
        // switch rather than once around its loop: `switchProfile` always clears it.
        reasserting = false
    }
}

/// The stand-in the extracted method body is compiled inside. It is a member of
/// `HakoHomeView` and reads its state unqualified - the queue, the coordinator and the two
/// environments objects - so this class supplies exactly those names.
@MainActor
class Extracted {
    var profileSwitchQueue = HakoProfileSwitchQueue<Int64>()
    let coordinator = Coordinator()
    let profile = Profile()
    let environments = Environments()
"""


HARNESS_FOOTER = """\
}

@MainActor
final class Probe: Extracted {
    /// `HakoHomeView` hands the configuration centre a `Binding(get:set:)` whose setter is
    /// this call, which is what the sheet's four selection sites write through.
    func select(_ profileID: Int64) {
        selectProfile(profileID)
    }

    var isBusy: Bool {
        profileSwitchQueue.isDraining
    }
}
"""


CHECK_MAIN = r"""
// MARK: - The cases this change has to hold

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ description: String) throws {
    if !condition { throw CheckFailure(description: description) }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String) throws {
    if actual != expected {
        throw CheckFailure(description: "\(description): expected \(expected), got \(actual)")
    }
}

/// The drain runs in a `Task`, so what it applied is only observable after the main actor
/// has run it. Polling the queue's own state is what says when there is nothing left.
@MainActor
func settle(_ probe: Probe) async {
    for _ in 0 ..< 400 {
        await Task.yield()
        if !probe.isBusy {
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    fatalError("the drain never finished")
}

@MainActor
func runChecks() async throws -> [String] {
    var ran: [String] = []

    // 1. One selection, one switch, and the gate comes back down.
    do {
        let probe = Probe()
        probe.select(7)
        try expectEqual(probe.coordinator.reasserting, true, "the gate is up as soon as a choice is accepted")
        await settle(probe)
        try expectEqual(probe.coordinator.applied, [7], "the choice reaches the official switch, once")
        try expectEqual(probe.coordinator.reasserting, false, "the gate comes back down when the queue is empty")
        try expectEqual(probe.coordinator.reassertingAtStart, [true], "no switch runs behind a lowered gate")
        try expectEqual(probe.coordinator.maxRunning, 1, "one switch at a time")
        ran.append("single selection")
    }

    // 2. A second tap while the first switch is in flight: both are applied, in the order
    //    they were accepted, and the page ends on the second.
    do {
        let probe = Probe()
        probe.coordinator.nanoseconds = 40_000_000
        probe.select(1)
        await Task.yield()
        probe.select(2)
        await settle(probe)
        try expectEqual(probe.coordinator.applied, [1, 2], "the second choice is applied after the first")
        try expectEqual(probe.coordinator.applied.last, 2, "the page ends on the last accepted choice")
        try expectEqual(probe.coordinator.maxRunning, 1, "the two switches never overlap")
        try expectEqual(probe.coordinator.reassertingAtStart, [true, true],
                        "the gate is up for both switches - `switchProfile` clears it on the way out")
        try expectEqual(probe.coordinator.reasserting, false, "the gate comes back down")
        ran.append("second tap while in flight")
    }

    // 3. A burst is coalesced to the last choice: the intermediate value is a choice the
    //    reader had already replaced, and applying it would reload the tunnel for it.
    do {
        let probe = Probe()
        probe.coordinator.nanoseconds = 40_000_000
        probe.select(1)
        await Task.yield()
        probe.select(2)
        probe.select(3)
        await settle(probe)
        try expectEqual(probe.coordinator.applied, [1, 3], "the burst ends on 3 and 2 is coalesced away")
        try expectEqual(probe.coordinator.reassertingAtStart, [true, true],
                        "both applied switches ran behind a raised gate")
        try expectEqual(probe.coordinator.reasserting, false, "the gate comes back down")
        ran.append("burst coalesces")
    }

    // 4. A burst that returns to the first choice ends there. The choice is re-applied -
    //    this is not a no-op queue - but it is applied *last*, which is the whole contract.
    do {
        let probe = Probe()
        probe.coordinator.nanoseconds = 40_000_000
        probe.select(1)
        await Task.yield()
        probe.select(2)
        probe.select(1)
        await settle(probe)
        try expectEqual(probe.coordinator.applied, [1, 1], "A -> B -> A ends on A")
        try expectEqual(probe.coordinator.applied.last, 1, "and A is the last thing applied")
        try expectEqual(probe.coordinator.maxRunning, 1, "still one switch at a time")
        ran.append("returns to the first choice")
    }

    // 5. The queue is reusable: an idle queue accepts the next choice and drains again.
    do {
        let probe = Probe()
        probe.select(1)
        await settle(probe)
        probe.select(2)
        await settle(probe)
        try expectEqual(probe.coordinator.applied, [1, 2], "a second selection after an idle moment is applied")
        try expectEqual(probe.isBusy, false, "and the queue is idle again")
        ran.append("reusable queue")
    }

    // 6. A switch that cannot complete still releases the gate. `OverviewViewModel`
    //    swallows the reload error into its alert and returns, so the page's own guarantee
    //    is that it does not leave itself disabled: the alert is the report, the gate is not
    //    the failure state.
    do {
        let probe = Probe()
        probe.coordinator.nanoseconds = 10_000_000
        probe.select(3)
        await settle(probe)
        try expectEqual(probe.coordinator.applied, [3], "the failed switch was still attempted")
        try expectEqual(probe.coordinator.reasserting, false, "a failed switch does not leave the page disabled")
        ran.append("failed switch releases the gate")
    }

    return ran
}

let ran = try await runChecks()
for name in ran { print("  [ok] " + name) }
print("  profile switch ordering: \(ran.count) case(s) PASS")
"""


def braced_block(text: str, start: int) -> str:
    """`text` from the first `{` at or after `start` to the brace that closes it.

    Comments are already stripped by `code_only`; a `{` in a string literal would confuse
    this, and the two blocks read here (the row's content and the surface modifier) hold
    none.
    """
    open_at = text.find("{", start)
    if open_at < 0:
        raise ExtractionError("no opening brace after offset %d" % start)
    depth = 0
    for index in range(open_at, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:index + 1]
    raise ExtractionError("the block opened at offset %d is never closed" % open_at)


#: What the configuration row draws on. Named once so the checks below and a reader of the
#: failure agree on the thing being described.
ROW_SURFACE_TYPE = "ProfileRowCardSurface"
ROW_SURFACE_CALL = ".profileRowCardSurface()"
#: `cardStyle()`'s radius on this row. The theme's card radius is the 26-release value, and
#: changing it would move the card's corners as well as its fill.
ROW_SURFACE_RADIUS = "static let cornerRadius: CGFloat = 16"


def surface_problems(picker_code: str) -> list[str]:
    """The configuration centre's rows draw `HakoCardSurface` with the sheet's grouping fill.

    This lives beside the switch checks because this is the one gate that already reads
    `HakoProfilePickerSheet.swift` as a whole, and the property has the same shape as the
    ones above: a structural fact of that file that a regeneration from upstream, or a
    hand edit in the wrong place, can silently reverse without breaking the build. On the
    26 releases `cardStyle()` draws `glassEffect`, so "the build is green" says nothing.

    The fill is part of the decision, not a detail: the row sits on a `List(.plain)` whose
    canvas is `systemBackground`, so `secondarySystemGroupedBackground` - the grouped page's
    card fill - is the same white in the light appearance. `tertiarySystemGroupedBackground`
    differs from the canvas in both appearances. The check holds the tertiary fill and names
    the grouped-page fill as the wrong one, because a silent revert to it is exactly the
    defect this row was fixed for.

    `picker_code` is the source with comments stripped: the row's own documentation names
    both `cardStyle()` and the fills it does not use.
    """
    problems: list[str] = []

    # The whole file: the only surface the rows take is the one below, and a second one at
    # page level would be the same defect in another place.
    if "glassEffect" in picker_code:
        problems.append(
            "`glassEffect` is back in the configuration centre: its rows (and anything else "
            "it draws) take the grouped surface, never the system's glass"
        )

    try:
        row = braced_block(picker_code, picker_code.index("private var rowContent: some View"))
    except (ValueError, ExtractionError) as error:
        problems.append("cannot read the configuration row's `rowContent`: %s" % error)
        row = ""

    if row:
        if ROW_SURFACE_CALL not in row:
            problems.append(
                "the configuration row no longer calls `%s`: it is back on the global "
                "`cardStyle()`, which draws the system glass on the 26 releases - the exact "
                "material this page must not use" % ROW_SURFACE_CALL
            )
        if "cardStyle()" in row:
            problems.append(
                "the configuration row calls `cardStyle()` again: on the 26 releases that is "
                "`glassEffect`, the system glass this page replaced with the grouped surface"
            )
        # The material is the only thing this decision may move. These are the row's shape
        # and its two interactive ends; a surface that kept the fill but dropped one of them
        # would be a different defect with the same screenshot.
        for token, description in (
            (".padding(HakoTheme.Spacing.standard)", "`HakoTheme.Spacing.standard` padding"),
            (".contentShape(Rectangle())", "`contentShape(Rectangle())` hit area"),
            ("HakoIconWell", "configuration-type icon well"),
            ("selectionMark", "selection mark"),
            ("rowMenu", "more-actions menu"),
            ("profileInfo", "quota/update/expiry subtitle"),
        ):
            if token not in row:
                problems.append("the configuration row lost its %s" % description)

    surface_at = picker_code.find("struct " + ROW_SURFACE_TYPE)
    if surface_at < 0:
        problems.append(
            "`%s` is gone: nothing declares the grouped surface the configuration rows draw on"
            % ROW_SURFACE_TYPE
        )
        return problems

    try:
        surface = braced_block(picker_code, surface_at)
    except ExtractionError as error:
        problems.append("cannot read `%s`: %s" % (ROW_SURFACE_TYPE, error))
        return problems

    if ROW_SURFACE_RADIUS not in surface:
        problems.append(
            "`%s` no longer pins the row's 16-point radius: `cardStyle()` has always drawn this "
            "row at 16, and the theme's card radius is the 26-release value, so this is a shape "
            "change rather than the material-only change it is meant to be" % ROW_SURFACE_TYPE
        )
    if "cornerRadius: Self.cornerRadius" not in surface:
        problems.append("`%s` no longer builds its shape from that radius" % ROW_SURFACE_TYPE)

    if_at = surface.find("#if os(iOS)")
    else_at = surface.find("#else", if_at + 1) if if_at >= 0 else -1
    endif_at = surface.find("#endif", else_at + 1) if else_at >= 0 else -1
    if if_at < 0 or else_at < 0 or endif_at < 0:
        problems.append(
            "`%s` is no longer a two-arm `#if os(iOS)` / `#else`: the Mac compiles this file "
            "too and presents upstream's picker, so the phone's surface must stay scoped to "
            "the phone" % ROW_SURFACE_TYPE
        )
        return problems

    phone_arm = surface[if_at:else_at]
    mac_arm = surface[else_at:endif_at]

    if "HakoCardSurface(" not in phone_arm:
        problems.append(
            "the phone's arm no longer draws `HakoCardSurface`, the card component the client's "
            "other painted surfaces use: the row has been given a surface of its own again, "
            "which is how the list stops matching the cards around it"
        )
    if "fill: Color(uiColor: .tertiarySystemGroupedBackground)" not in phone_arm:
        problems.append(
            "the phone's arm no longer fills the card with "
            "`Color(uiColor: .tertiarySystemGroupedBackground)`: this list's canvas is "
            "`systemBackground`, so the secondary grouped fill is the same colour as it in the "
            "light appearance and the row stops reading as a card"
        )
    # The grouped-page card fill is the one this row must not take: on a `List(.plain)` in a
    # sheet it equals the light canvas. Written as a separate arm so a revert is reported as a
    # revert rather than only as a missing tertiary fill.
    for wrong in (".secondaryPageCard", "secondarySystemGroupedBackground"):
        if wrong in phone_arm:
            problems.append(
                "the phone's arm fills the card from `%s`: that is the grouped-page card fill, "
                "which equals this sheet's light canvas - the wrong-fill regression this check "
                "exists for" % wrong
            )
    # `HakoCardSurface` draws its hairline from this argument. Not decoration: in the light
    # appearance the fill and the sheet's background are both white, so a card without it has no
    # boundary at all.
    if "separator: HakoProductPalette.system.separator" not in phone_arm:
        problems.append(
            "the phone's arm no longer gives the card its separator, so `HakoCardSurface` draws "
            "no hairline: in the light appearance the grouped fill and the sheet's own background "
            "are both white, and the card would have no edge"
        )
    if "cardStyle()" in phone_arm:
        problems.append(
            "the phone's arm calls `cardStyle()` again: that is the system glass this surface "
            "replaced, on the platform whose screenshot the change exists for"
        )
    if "cardStyle()" not in mac_arm:
        problems.append(
            "the Mac's arm no longer calls `cardStyle()`: the picker is upstream's presentation "
            "on the desktop, and the grouped surface is the phone's decision alone"
        )
    # `Color(uiColor:)` is allowed here because the fill is a UIKit *semantic* colour; what the
    # surface may never name is a fixed colour, which would stop following the appearance.
    for literal in ("Color(red:", "Color(white:", "Color.black", "Color.white", "#colorLiteral"):
        if literal in phone_arm:
            problems.append(
                "the phone's arm names `%s`: the surface must stay a dynamic system colour"
                % literal
            )

    return problems


def single_presentation_problems(name: str, code: str, binding: str) -> list[str]:
    """`name` presents one alert, and it is the presentation that folds every source.

    Two `.alert` modifiers attached to one view are one presentation and the outer one wins,
    so a view that anchors a second one has a failure source nothing displays. `binding` is
    the call the presentation must be (for example `.alert(pageAlert)`); `code` is
    comment-stripped, because the file's own documentation names both modifiers.
    """
    problems: list[str] = []
    calls = [line.strip() for line in code.splitlines() if line.strip().startswith(".alert(")]
    if not calls:
        problems.append("%s presents no alert at all" % name)
        return problems
    if len(calls) > 1:
        problems.append(
            "%s stacks %d `.alert` modifiers (%s): two presentations on one view are one "
            "presentation and the outer one wins, so the inner source's failures are never "
            "shown" % (name, len(calls), ", ".join(calls))
        )
    if binding not in calls:
        problems.append(
            "%s does not present `%s`, so its alert sources are not folded into the single "
            "presentation this client can make" % (name, binding)
        )
    return problems


def taildrop_alert_problems(code: str) -> list[str]:
    """The phone's Taildrop page presents one alert, and it folds the inbox's into its own.

    Upstream anchors `$inbox.alert` and the view's own `$alert` to the same view, and this
    page ported that pair unchanged: every inbox failure - subscribing the inbox, cancelling
    a receive, deleting a received file - was raised into a binding nothing displayed. The
    phone's copy folds them into `pageAlert`; the check also holds the fold's two halves,
    because a getter without its setter would present the dismissed source again.
    """
    problems = single_presentation_problems("HakoTaildropView", code, ".alert(pageAlert)")
    if problems:
        return problems

    try:
        folded = braced_block(code, code.index("private var pageAlert: Binding<AlertState?>"))
    except (ValueError, ExtractionError) as error:
        return ["cannot read `HakoTaildropView.pageAlert`: %s" % error]

    for required, description in (
        ("alert ?? inbox.alert", "both sources in its getter"),
        ("alert = nil", "clearing the view's own alert on dismissal"),
        ("inbox.alert = nil", "clearing the inbox's alert on dismissal"),
    ):
        if required not in folded:
            problems.append(
                "`HakoTaildropView.pageAlert` no longer folds %s: the dismissed source would "
                "stay set and the page would present it again" % description
            )
    return problems


def wiring_problems(view: str, picker: str, root: str) -> list[str]:
    """The page's wiring, asserted on the source text with comments stripped."""
    problems: list[str] = []
    view_code = code_only(view)
    picker_code = code_only(picker)
    root_code = code_only(root)

    # The sheet must be handed the side-effecting binding, never the plain one.
    if "selectedProfileID: profileSelection" not in view_code:
        problems.append(
            "the configuration centre is not handed `profileSelection`: the sheet's writes are "
            "back to being stored in `DashboardViewModel` instead of driving a switch"
        )
    if "selectedProfileID: $selectedProfileID" in view_code:
        problems.append(
            "the configuration centre is handed `$selectedProfileID` somewhere - that binding "
            "only moves a `@Published` field, so the choice is never persisted and a running "
            "tunnel keeps its previous configuration"
        )
    if "selectProfile($0)" not in view_code:
        problems.append(
            "`profileSelection`'s setter no longer calls `selectProfile`, so the accepted choice "
            "does not reach the official switch"
        )
    if "await coordinator.switchProfile(" not in view_code:
        problems.append(
            "nothing calls `OverviewViewModel.switchProfile` - the page has grown its own switch "
            "instead of routing through the existing one"
        )
    if "selectedProfileUpdate" in view_code:
        problems.append(
            "the page sends `selectedProfileUpdate` itself. That event is the official switch's "
            "broadcast; sending it from an observation of `selectedProfileID` is the feedback "
            "loop that turns one choice into repeated switches"
        )
    if "HakoProfileSwitchQueue<Int64>()" not in view_code:
        problems.append("the page no longer serialises its switches through `HakoProfileSwitchQueue`")

    # The centre itself must not grow a second switch.
    if "switchProfile" in picker_code:
        problems.append(
            "`HakoProfilePickerSheet` calls `switchProfile` itself - the switch belongs in the "
            "page's one binding, not in four generated selection sites"
        )
    for forbidden in ("SharedPreferences", "reloadService"):
        if forbidden in picker_code:
            problems.append(
                "`HakoProfilePickerSheet` names `%s`: the sheet is presentation, and a second "
                "persistence/reload implementation in it is a second source of truth" % forbidden
            )
    for match in re.finditer(r"onSelect: \{", picker_code):
        block = picker_code[match.end(): match.end() + 240]
        if "selectedProfileID = profile.id" not in block:
            problems.append(
                "a selection site in `HakoProfilePickerSheet` does not write the binding "
                "(offset %d) - that entry point would do nothing" % match.end()
            )

    # One alert presentation per view. Two `.alert` modifiers attached to the same view are
    # one presentation and the outer one wins, which is how a failed switch came to report
    # nothing at all.
    for name, code in (("HakoHomeView", view_code), ("HakoPhoneRootView", root_code)):
        if ".alert(pageAlert)" not in code:
            problems.append("%s no longer presents the single `pageAlert` binding" % name)
        previous = None
        for number, line in enumerate(code.splitlines(), 1):
            stripped = line.strip()
            if not stripped:
                previous = None
                continue
            if stripped.startswith(".alert("):
                if previous is not None:
                    problems.append(
                        "%s stacks two `.alert` modifiers (lines %d and %d): the outer one wins and "
                        "the inner one's failures are never shown" % (name, previous, number)
                    )
                previous = number
            else:
                previous = None

    problems.extend(surface_problems(picker_code))

    return problems


def find_swiftc(explicit: str | None) -> str:
    if explicit:
        return explicit
    found = shutil.which("swiftc")
    if found:
        return found
    candidates = [
        r"C:\Users\Jie\AppData\Local\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin\swiftc.exe",
    ]
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    raise SystemExit("swiftc not found; pass --swiftc PATH")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getcwd(), help="repository root")
    parser.add_argument("--swiftc", default=None, help="the compiler to use")
    parser.add_argument("--explain", action="store_true", help="print the extracted source and stop")
    options = parser.parse_args()

    paths = {}
    for key, relative in (
        ("view", VIEW_FILE),
        ("queue", QUEUE_FILE),
        ("picker", PICKER_FILE),
        ("taildrop", TAILDROP_FILE),
        ("root", PHONE_ROOT_FILE),
    ):
        path = os.path.join(options.root, relative)
        if not os.path.exists(path):
            print("FAIL: %s does not exist" % path)
            return 2
        paths[key] = path

    with open(paths["view"], "r", encoding="utf-8") as handle:
        view_source = handle.read()
    try:
        method = extract_method(view_source, REQUIRED_METHOD, paths["view"])
    except ExtractionError as error:
        print("FAIL: %s" % error)
        return 1

    harness = (
        HARNESS_HEADER
        + "\n"
        + "\n".join("    " + line.strip() if line.strip() else "" for line in opened(method).splitlines())
        + "\n"
        + HARNESS_FOOTER
        + CHECK_MAIN
    )
    if options.explain:
        print(harness)
        return 0

    swiftc = find_swiftc(options.swiftc)
    with tempfile.TemporaryDirectory(prefix="hako-profile-switch-") as scratch:
        # `main.swift`, not a free name: this is compiled beside the shipped queue file, and
        # Swift only allows top-level code in a file with that name when a build has more than
        # one input.
        harness_path = os.path.join(scratch, "main.swift")
        with open(harness_path, "w", encoding="utf-8") as handle:
            handle.write(harness)

        binary = os.path.join(scratch, "harness.exe" if os.name == "nt" else "harness")
        compile_result = subprocess.run(
            [swiftc, "-O", "-o", binary, harness_path, paths["queue"]],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if compile_result.returncode != 0:
            print("FAIL: the extracted wiring and the shipped queue do not compile")
            print(compile_result.stdout)
            print(compile_result.stderr)
            return 1

        run_result = subprocess.run(
            [binary],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        sys.stdout.write(run_result.stdout)
        if run_result.returncode != 0:
            sys.stderr.write(run_result.stderr)
            print("FAIL: a case did not hold")
            return 1

    with open(paths["picker"], "r", encoding="utf-8") as handle:
        picker_source = handle.read()
    with open(paths["taildrop"], "r", encoding="utf-8") as handle:
        taildrop_source = handle.read()
    with open(paths["root"], "r", encoding="utf-8") as handle:
        root_source = handle.read()

    problems = wiring_problems(view_source, picker_source, root_source)
    problems.extend(taildrop_alert_problems(code_only(taildrop_source)))
    for problem in problems:
        print("  [FAIL] " + problem)
    if problems:
        print("FAIL: the phone views' structural properties do not hold")
        return 1
    print("  [ok] wiring: the centre's binding drives the official switch through one queue")
    print("  [ok] alert presentation: one presentation per phone view (Home, root, Taildrop)")
    print("  [ok] surface: the centre's rows draw the sheet's grouping fill, and the Mac keeps `cardStyle()`")

    return 0


if __name__ == "__main__":
    sys.exit(main())
