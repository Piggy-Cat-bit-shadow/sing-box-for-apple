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


def run(root: str) -> list[str]:
    ran: list[str] = []

    switch_gate = load(os.path.join(root, "scripts/dev/check_hako_profile_switch.py"), "switch_gate")
    mode_gate = load(os.path.join(root, "scripts/dev/check_compact_mode_picker.py"), "mode_gate")

    view = read(root, "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift")
    picker = read(root, "ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift")
    phone_root = read(root, "SFI/HakoPhoneRootView.swift")
    shipped = {"view": view, "picker": picker, "root": phone_root}

    # The shipped tree must be clean, or every case below is measuring a tree that is
    # already failing for an unrelated reason.
    problems = switch_gate.wiring_problems(view, picker, phone_root)
    if problems:
        raise CaseFailure("the shipped tree already fails the switch gate: %s" % problems)
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
