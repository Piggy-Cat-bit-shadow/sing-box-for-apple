#!/usr/bin/env python3
"""The negative suite for the two phone-UI gates.

`check_hako_profile_switch.py` and `check_compact_mode_picker.py` each assert a property
of source text. A check like that has one characteristic failure: it keeps printing PASS
after the code it describes has moved, because the pattern it searches for is still
somewhere - in a comment, in the other branch, or in a string. The way to know it still
measures anything is to feed it the defect it exists to catch and watch it fail.

So every case here takes the shipped file, puts one defect back, and requires the gate to
report it. A mutation that no longer applies is an error, not a skip: a case that silently
stopped mutating would make this suite vacuous in exactly the way it is here to rule out.

Usage:
    python test_hako_ui_gates.py [--root DIR]
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile


class CaseFailure(RuntimeError):
    pass


#: The files `check_hako_profile_switch.py` reads. A scratch root holds them at their real
#: relative paths so the gate can be run against a *mutated* tree - which is the only way
#: to prove the compiled cases catch a behavioural regression rather than only describing
#: the shipped code.
SWITCH_GATE_FILES = (
    "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift",
    "ApplicationLibrary/Views/HakoStyle/HakoProfileSwitchQueue.swift",
    "ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift",
    "ApplicationLibrary/Views/HakoStyle/HakoTaildropView.swift",
    "SFI/HakoPhoneRootView.swift",
)


def scratch_tree(files: dict[str, str]) -> str:
    """A directory holding `relative path -> text`, nothing else."""
    root = tempfile.mkdtemp(prefix="hako-gate-tree-")
    for relative, text in files.items():
        path = os.path.join(root, relative.replace("/", os.sep))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    return root


def run_gate(root: str, script: str, tree: str) -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, os.path.join(root, "scripts", "dev", script), "--root", tree],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.returncode, result.stdout + result.stderr


def run_switch_gate(root: str, tree: str) -> tuple[int, str]:
    return run_gate(root, "check_hako_profile_switch.py", tree)


def load(path: str, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CaseFailure("cannot load %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read(root: str, relative: str) -> str:
    with open(os.path.join(root, relative), "r", encoding="utf-8") as handle:
        return handle.read()


def mutate(source: str, old: str, new: str, description: str) -> str:
    """`source` with one defect restored, or an error if the defect no longer applies.

    `old` may be a list of alternatives; each must appear exactly once.
    """
    if old not in source:
        raise CaseFailure(
            "%s: the text this mutation replaces is gone, so the case no longer proves "
            "anything - update it against the new source" % description
        )
    return source.replace(old, new, 1)


def expect_reported(gate, sources: dict, cases: list, description: str) -> list:
    problems = gate.wiring_problems(sources["view"], sources["picker"], sources["root"])
    hits = [problem for problem in problems if any(marker in problem for marker in cases)]
    if not hits:
        raise CaseFailure(
            "%s: the gate reported nothing. All it said was: %s" % (description, problems)
        )
    return hits


def expect_taildrop_reported(gate, source: str, cases: list, description: str) -> list:
    """The same, for the Taildrop page's alert check (a pure function over its source)."""
    problems = gate.taildrop_alert_problems(gate.code_only(source))
    hits = [problem for problem in problems if any(marker in problem for marker in cases)]
    if not hits:
        raise CaseFailure(
            "%s: the gate reported nothing. All it said was: %s" % (description, problems)
        )
    return hits


def run(root: str) -> list[str]:
    ran: list[str] = []

    switch_gate = load(os.path.join(root, "scripts/dev/check_hako_profile_switch.py"), "switch_gate")
    mode_gate = load(os.path.join(root, "scripts/dev/check_compact_mode_picker.py"), "mode_gate")

    view = read(root, "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift")
    picker = read(root, "ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift")
    taildrop = read(root, "ApplicationLibrary/Views/HakoStyle/HakoTaildropView.swift")
    phone_root = read(root, "SFI/HakoPhoneRootView.swift")
    shipped = {"view": view, "picker": picker, "root": phone_root}

    # The shipped tree must be clean, or every case below is measuring a tree that is
    # already failing for an unrelated reason.
    problems = switch_gate.wiring_problems(view, picker, phone_root)
    if problems:
        raise CaseFailure("the shipped tree already fails the switch gate: %s" % problems)
    problems = switch_gate.taildrop_alert_problems(switch_gate.code_only(taildrop))
    if problems:
        raise CaseFailure("the shipped Taildrop page already fails the alert check: %s" % problems)
    problems = mode_gate.check_view_contract(view)
    if problems:
        raise CaseFailure("the shipped tree already fails the mode gate: %s" % problems)
    ran.append("shipped tree is clean")

    # 1. The defect the P0 change exists for: the plain binding into the centre.
    mutant = mutate(
        view,
        "selectedProfileID: profileSelection",
        "selectedProfileID: $selectedProfileID",
        "plain binding into the configuration centre",
    )
    expect_reported(switch_gate, {**shipped, "view": mutant},
                    ["$selectedProfileID"], "plain binding into the centre")
    ran.append("plain binding is caught")

    # 2. A setter that accepts the choice and does nothing with it.
    mutant = mutate(view, "selectProfile($0)", "_ in }", "inert binding setter")
    expect_reported(switch_gate, {**shipped, "view": mutant},
                    ["no longer calls `selectProfile`"], "inert binding setter")
    ran.append("inert setter is caught")

    # 3. A second switch implementation instead of the official one.
    mutant = mutate(
        view,
        "await coordinator.switchProfile(next, profile: profile, environments: environments)",
        "await SharedPreferences.selectedProfileID.set(next)",
        "own persistence instead of the official switch",
    )
    expect_reported(switch_gate, {**shipped, "view": mutant},
                    ["nothing calls `OverviewViewModel.switchProfile`"],
                    "own persistence instead of the official switch")
    ran.append("second switch implementation is caught")

    # 4. The feedback loop the page must not create: broadcasting the official event from
    #    its own observation of the selected identifier.
    mutant = mutate(
        view,
        "coordinator.reasserting = true",
        "coordinator.reasserting = true\n        environments.selectedProfileUpdate.send()",
        "the page broadcasting selectedProfileUpdate itself",
    )
    expect_reported(switch_gate, {**shipped, "view": mutant},
                    ["sends `selectedProfileUpdate`"], "the page broadcasting the official event")
    ran.append("broadcast feedback loop is caught")

    # 5. The stacking defect both phone files had: two `.alert` modifiers on one view.
    mutant = mutate(
        phone_root,
        ".alert(pageAlert)",
        ".alert($alert)\n            .alert($dashboard.alert)",
        "stacked alerts on the phone root",
    )
    expect_reported(switch_gate, {**shipped, "root": mutant},
                    ["stacks two `.alert` modifiers"], "stacked alerts on the phone root")
    ran.append("stacked alerts are caught")

    # 6. One of the centre's selection sites stops writing the binding.
    mutant = mutate(
        picker,
        "selectedProfileID = profile.id",
        "dismiss()",
        "one selection site stops writing the binding",
    )
    expect_reported(switch_gate, {**shipped, "picker": mutant},
                    ["does not write the binding"], "a dead selection site")
    ran.append("dead selection site is caught")

    # 7. The old shape rule, back in the view.
    mutant = mutate(
        view,
        "HakoClashModeLayout.shape(titles: modes.map(modeTitle)) == .compactRow",
        "conventionalModes(in: modes) != nil",
        "the three-English-words rule restored",
    )
    reported = mode_gate.check_view_contract(mutant)
    if not any("no longer asks `HakoClashModeLayout`" in problem for problem in reported):
        raise CaseFailure("the old shape rule is back and the gate did not say so: %s" % reported)
    ran.append("old shape rule is caught")

    # 8. The mode list read through the nested observable again.
    mutant = mutate(
        view,
        "let modes = modeList",
        "let modes = environments.commandClient.clashModeList",
        "the mode list read through the nested observable",
    )
    reported = mode_gate.check_view_contract(mutant)
    if not any("taking `environments.commandClient.clashModeList`" in problem
               or "takes `environments.commandClient.clashModeList`" in problem
               for problem in reported):
        raise CaseFailure("the nested read is back and the gate did not say so: %s" % reported)
    ran.append("nested read is caught")

    # 9. The mirror subscription removed, so the list can never change on screen.
    mutant = mutate(
        view,
        ".onReceive(environments.commandClient.$clashModeList)",
        ".onAppear",
        "the mode list's mirror subscription removed",
    )
    reported = mode_gate.check_view_contract(mutant)
    if not any("$clashModeList" in problem for problem in reported):
        raise CaseFailure("the mirror subscription is gone and the gate did not say so: %s" % reported)
    ran.append("missing mirror subscription is caught")

    # 10-11. The compiled cases, against a mutated tree. These are the two properties the
    #        queue exists for, so each is put back and the gate is required to fail.
    queue = read(root, "ApplicationLibrary/Views/HakoStyle/HakoProfileSwitchQueue.swift")
    shipped_files = {
        "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift": view,
        "ApplicationLibrary/Views/HakoStyle/HakoProfileSwitchQueue.swift": queue,
        "ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift": picker,
        "ApplicationLibrary/Views/HakoStyle/HakoTaildropView.swift": taildrop,
        "SFI/HakoPhoneRootView.swift": phone_root,
    }

    unguarded = mutate(
        view,
        "coordinator.reasserting = true\n                await coordinator.switchProfile(",
        "await coordinator.switchProfile(",
        "the busy gate raised once around the loop instead of per switch",
    )
    tree = scratch_tree({**shipped_files,
                         "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift": unguarded})
    try:
        code, output = run_switch_gate(root, tree)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    if code == 0 or "the gate is up for both switches" not in output:
        raise CaseFailure(
            "a per-loop busy gate was not caught by the compiled cases; the gate said: %s" % output
        )
    ran.append("per-loop busy gate is caught")

    unserialised = mutate(
        queue,
        "guard !isDraining else {",
        "guard false else {",
        "the queue accepting a second switch while one is in flight",
    )
    tree = scratch_tree({**shipped_files,
                         "ApplicationLibrary/Views/HakoStyle/HakoProfileSwitchQueue.swift": unserialised})
    try:
        code, output = run_switch_gate(root, tree)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    if code == 0:
        raise CaseFailure(
            "an unserialised queue passed the compiled cases; the gate said: %s" % output
        )
    ran.append("unserialised queue is caught")

    # 12. The platform guard that the migration dropped from the phone's tunnel page. The gate is
    #     a source scan, so the *file* is mutated in a scratch tree and the gate is required to
    #     report the use it leaves unprotected.
    tunnel = read(root, "ApplicationLibrary/Views/HakoStyle/HakoPacketTunnelView.swift")
    preferences = read(root, "Library/Database/SharedPreferences.swift")
    unguarded = mutate(
        tunnel,
        "        Group {\n            #if !os(tvOS)\n                settingSection(",
        "        Group {\n                settingSection(",
        "the `#if !os(tvOS)` guard around the phone's tunnel routing switches",
    )
    tree = scratch_tree({
        "Library/Database/SharedPreferences.swift": preferences,
        "ApplicationLibrary/Views/HakoStyle/HakoPacketTunnelView.swift": unguarded,
    })
    try:
        code, output = run_gate(root, "check_hako_platform_symbols.py", tree)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    if code == 0 or "SharedPreferences.includeAllNetworks" not in output:
        raise CaseFailure(
            "an unguarded tvOS-absent symbol passed the platform gate; the gate said: %s" % output
        )
    ran.append("missing platform guard is caught")

    # 13. The localization gate must see a bare literal at all. It was vacuous on Windows twice
    #     over - the path prefixes never matched, and the literal extractor was off by one, so only
    #     `String(localized:)` was ever checked. This case runs the shipped gate against a scratch
    #     tree that carries the real catalog and one page with a literal the catalog has never
    #     contained, and requires it to fail; the same tree with a key that does exist must pass, so
    #     the case cannot be satisfied by a gate that fails on everything.
    catalog_text = read(root, "Localizable.xcstrings")
    localization_script = read(root, "scripts/dev/check_localization.py")
    missing_literal = (
        "import SwiftUI\n"
        "struct ProbeView: View {\n"
        "    var body: some View {\n"
        '        Text("A phrase the catalog has never contained")\n'
        "    }\n"
        "}\n"
    )
    known_literal = missing_literal.replace(
        "A phrase the catalog has never contained", "Back")
    for name, page, expected_code, expected_text in (
        ("a bare literal with no catalog key", missing_literal, 1,
         "A phrase the catalog has never contained"),
        ("a literal that resolves", known_literal, 0, "PASS"),
    ):
        tree = scratch_tree({
            "Localizable.xcstrings": catalog_text,
            "scripts/dev/check_localization.py": localization_script,
            "ApplicationLibrary/Views/HakoStyle/ProbeView.swift": page,
        })
        try:
            result = subprocess.run(
                [sys.executable, os.path.join(tree, "scripts", "dev", "check_localization.py")],
                capture_output=True, text=True, encoding="utf-8", errors="replace")
        finally:
            shutil.rmtree(tree, ignore_errors=True)
        output = result.stdout + result.stderr
        if result.returncode != expected_code or expected_text not in output:
            raise CaseFailure(
                "the localization gate did not treat %s as expected (exit %d, wanted %d): %s"
                % (name, result.returncode, expected_code, output[-400:])
            )
    ran.append("localization gate sees bare literals")

    # 14. A key that is a URL must stay a URL where it is localized. The settings page builds its
    #     manual link as `URL(string: String(localized: "https://…"))!`, so a translator who writes
    #     prose there turns the force unwrap into a crash. The gate holds the catalog, so it can
    #     refuse; this case breaks one locale and requires the refusal.
    url_page = (
        "import SwiftUI\n"
        "struct ProbeLink: View {\n"
        "    var body: some View {\n"
        '        Link(destination: URL(string: String(localized: "https://sing-box.sagernet.org/"))!) {\n'
        '            Text("Back")\n'
        "        }\n"
        "    }\n"
        "}\n"
    )
    broken_catalog = catalog_text.replace(
        '"value" : "https://sing-box.sagernet.org/zh/"', '"value" : "文档"', 1)
    if broken_catalog == catalog_text:
        raise CaseFailure(
            "the catalog no longer carries the localized docs URL, so the URL case proves nothing - "
            "update it against the catalog"
        )
    for name, text, expected_code, expected_text in (
        ("a localized URL kept as a URL", catalog_text, 0, "PASS"),
        ("a localized URL turned into prose", broken_catalog, 1, "not a URL"),
    ):
        tree = scratch_tree({
            "Localizable.xcstrings": text,
            "scripts/dev/check_localization.py": localization_script,
            "ApplicationLibrary/Views/HakoStyle/ProbeLink.swift": url_page,
        })
        try:
            result = subprocess.run(
                [sys.executable, os.path.join(tree, "scripts", "dev", "check_localization.py")],
                capture_output=True, text=True, encoding="utf-8", errors="replace")
        finally:
            shutil.rmtree(tree, ignore_errors=True)
        output = result.stdout + result.stderr
        if result.returncode != expected_code or expected_text not in output:
            raise CaseFailure(
                "the localization gate did not treat %s as expected (exit %d, wanted %d): %s"
                % (name, result.returncode, expected_code, output[-400:])
            )
    ran.append("broken localized URL is caught")

    # 15. F-13's silent path. The crash menu used to be `try? LibboxNewStandaloneCommandClient()?…`,
    #     and an optional chain over a nil client does not throw - it skips the call. The gate for
    #     that shape is a source scan, so the original line is put back in a scratch tree and the
    #     gate is required to report it.
    crash_page = read(root, "ApplicationLibrary/Views/HakoStyle/HakoCrashReportListView.swift")
    optional_chained = mutate(
        crash_page,
        "trigger { try $0.triggerGoCrash() }",
        "try? LibboxNewStandaloneCommandClient()?.triggerGoCrash()",
        "the optional-chained crash trigger",
    )
    tree = scratch_tree({
        "ApplicationLibrary/Views/HakoStyle/HakoCrashReportListView.swift": optional_chained,
    })
    try:
        code, output = run_gate(root, "check_hako_command_channel.py", tree)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    if code == 0 or "optional-chained command client" not in output:
        raise CaseFailure(
            "an optional-chained command client passed the gate; it said: %s" % output
        )
    ran.append("optional-chained command client is caught")

    # 16. The configuration centre's rows, back on the system glass. This is the P0 surface
    #     defect itself: `cardStyle()` draws `glassEffect` on the 26 releases, so a tree that
    #     put it back would still build, still pass every other gate, and still look wrong.
    #     The gate is a source scan, so the shipped row's own call is replaced in memory.
    glass_row = mutate(
        picker,
        ".profileRowCardSurface()",
        ".cardStyle()",
        "the configuration row back on the system glass",
    )
    expect_reported(switch_gate, {**shipped, "picker": glass_row},
                    ["system glass"], "the configuration row back on the system glass")
    ran.append("configuration row's glass surface is caught")

    # 17. A page-level glass call instead of the row's own surface, which the file-level arm
    #     of the check exists to catch even when the row still calls the surface.
    direct_glass = mutate(
        picker,
        ".profileRowCardSurface()",
        ".glassEffect(.regular, in: .rect(cornerRadius: 16))",
        "a direct `glassEffect` on the configuration row",
    )
    expect_reported(switch_gate, {**shipped, "picker": direct_glass},
                    ["glassEffect"], "a direct `glassEffect` on the configuration row")
    ran.append("direct glass effect is caught")

    # 18. The Mac's arm handed the phone's fill. The file is shared, and the desktop's picker
    #     is upstream's presentation: scoping the change is part of the decision, not a detail.
    mac_arm = mutate(
        picker,
        "content.cardStyle()",
        "content.background(HakoProductPalette.system.fill(for: .secondaryPageCard))",
        "the Mac's arm handed the phone's grouped fill",
    )
    expect_reported(switch_gate, {**shipped, "picker": mac_arm},
                    ["Mac's arm"], "the Mac's arm handed the phone's grouped fill")
    ran.append("Mac losing its own surface is caught")

    # 19. The row's shape moved with its material. `cardStyle()` draws 16; the theme's card
    #     radius is 26 on the same releases, so adopting the token would resize every row.
    resized = mutate(
        picker,
        "static let cornerRadius: CGFloat = 16",
        "static let cornerRadius: CGFloat = HakoTheme.Radius.card",
        "the row's radius read from the 26-release card token",
    )
    expect_reported(switch_gate, {**shipped, "picker": resized},
                    ["16-point radius"], "the row's radius read from the 26-release card token")
    ran.append("row resized by the theme token is caught")

    # 20. The hairline dropped from the grouped fill. In dark mode that is a barely visible
    #     difference; in light mode the fill and the sheet are both white and the card has no
    #     edge at all, which is the shape of "fixed one appearance, broke the other".
    unedged = mutate(
        picker,
        "separator: HakoProductPalette.system.separator",
        "separator: .clear",
        "the grouped card's hairline removed",
    )
    expect_reported(switch_gate, {**shipped, "picker": unedged},
                    ["hairline"], "the grouped card's hairline removed")
    ran.append("card hairline removal is caught")

    # 21. The Taildrop page's inbox alert restored beside its own. This is the pair upstream
    #     ships on one view; only the outer presentation is made, so the inbox's failures -
    #     delete, cancel, subscribe - were raised into a binding nothing displayed. The mutant
    #     puts the dead pair back, which is what a re-port from upstream would do.
    stacked_alerts = mutate(
        taildrop,
        ".alert(pageAlert)",
        ".alert($inbox.alert)\n                .alert(pageAlert)",
        "the Taildrop page's inbox alert restored beside its own",
    )
    expect_taildrop_reported(switch_gate, stacked_alerts,
                             ["stacks 2 `.alert` modifiers"],
                             "the Taildrop page's second presentation")
    ran.append("Taildrop's stacked alert is caught")

    # 22. One presentation, but not the folded one: the inbox's failures are silently dropped
    #     again, this time with nothing visibly doubled.
    unfolded = mutate(
        taildrop,
        ".alert(pageAlert)",
        ".alert($alert)",
        "the Taildrop page presenting only its own alert",
    )
    expect_taildrop_reported(switch_gate, unfolded,
                             ["does not present `.alert(pageAlert)`"],
                             "the Taildrop page's unfolded presentation")
    ran.append("Taildrop's unfolded alert is caught")

    # 23. A fold that reads both sources but clears one. A dismissal would leave the other set,
    #     and the page would present the alert it just dismissed on the next redraw.
    leaking = mutate(
        taildrop,
        "                        inbox.alert = nil\n",
        "",
        "the Taildrop fold that never clears the inbox's alert",
    )
    expect_taildrop_reported(switch_gate, leaking,
                             ["clearing the inbox's alert"],
                             "the Taildrop fold's missing clear")
    ran.append("Taildrop's leaking fold is caught")

    # 24. The picker generator's own refusal. `--regenerate` is the one command that can put
    #     the glass back *and* drop the file's platform guards, so the generator refuses while
    #     the row's manual repair is present; discarding it takes a second, explicit flag. The
    #     decision is a pure function because the generator cannot read its input on this host.
    generator = load(os.path.join(root, "scripts/dev/make_hako_profile_picker.py"), "picker_generator")
    repairs = generator.manual_repair_problems(picker)
    if len(repairs) != 1 or "ProfileRowCardSurface" not in repairs[0]:
        raise CaseFailure(
            "the generator no longer recognises the row's manual repair; it reported: %s" % repairs
        )
    if generator.regeneration_refusal(picker, True):
        raise CaseFailure("`--allow-manual-repairs` is meant to discard the repair, but it refused")
    stripped = picker.replace("ProfileRowCardSurface", "GeneratedRowSurface")
    if generator.regeneration_refusal(stripped, False):
        raise CaseFailure(
            "a file without the manual repair was still refused: %s"
            % generator.regeneration_refusal(stripped, False)
        )
    ran.append("picker generator refuses to drop the row's surface")

    return ran


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getcwd(), help="repository root")
    options = parser.parse_args()
    try:
        ran = run(options.root)
    except CaseFailure as failure:
        print("FAIL: %s" % failure)
        return 1
    for name in ran:
        print("  [ok] " + name)
    print("  hako UI gate mutants: %d case(s) PASS" % len(ran))
    return 0


if __name__ == "__main__":
    sys.exit(main())
