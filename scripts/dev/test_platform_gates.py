#!/usr/bin/env python3
"""Negative cases for the platform gates. A guard that cannot fail is not a guard.

Every case builds a disposable copy of the evaluated tree, breaks exactly one invariant, runs one gate, and
asserts that the gate **reports that specific thing** - not merely that it exits non-zero, because "something
failed" is also what a crashed script does. Each case also asserts the *restored* copy is green, so a case
cannot pass by leaving the tool permanently red.

# Why the cases are shaped the way they are

The three false-green shapes this round exists to close are all here as cases, because each of them was
observed in this repository rather than imagined:

  * `json-truthful` - `--json` returned 0 while its own payload listed failures. The rule is now that one
    result object produces both renderings and both exit codes, and this case fails if they diverge.
  * `import-guard-is-not-a-fix` - `#if canImport(UIKit)` around `import UIKit` while the `UIViewRepresentable`
    that needed it sits outside. The old import gate reported PASS over exactly this, so the case asserts
    the *use side* is what turns it red.
  * `skipped-is-not-clean` - a file the evaluator could not decide must be counted as not checked. The case
    that covers it (`span-scope`) is also the regression test for a bug this suite found in the new code:
    a directive-span reader that mistook `#endif` for a non-directive blanked the rest of a file, so a real
    break went unreported on tvOS while the file was listed `[checked]`.

`agreement` is not a mutation: it asserts the line-preserving resolver in `hako_platform_facts` returns the
same surviving lines as `swift_directives.resolve` on every evaluated file and platform, so the line numbers
reported here cannot drift away from the resolver's decisions.

Run:  python scripts/dev/test_platform_gates.py [--scratch DIR]

Exit status is 0 when every case behaved as designed.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import hako_platform_facts as facts  # noqa: E402
import swift_directives  # noqa: E402

PYTHON = sys.executable
HAKO = os.path.join("ApplicationLibrary", "Views", "HakoStyle")
RESTORE_ME = None  # set by main: the pristine tree copied into the scratch


def gate(name: str, scratch: str, *arguments: str) -> tuple[int, str]:
    result = subprocess.run([PYTHON, os.path.join(HERE, name), "--root", scratch, *arguments],
                            capture_output=True)
    return result.returncode, (result.stdout + result.stderr).decode("utf-8", "replace")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def reset(scratch: str) -> None:
    """Restore the evaluated tree from the pristine copy, and assert the restore worked.

    The removal is verified rather than ignored. `rmtree(..., ignore_errors=True)` followed by a
    `copytree` into the same path turned a failed removal into `FileExistsError` from the *copy* - a crash
    two frames away from the cause, and one that only happens when two runs share the scratch directory.
    The default scratch is unique per run for that reason; this makes a shared one fail with the truth.
    """
    target = os.path.join(scratch, HAKO)
    if os.path.isdir(target):
        shutil.rmtree(target)
    if os.path.exists(target):
        raise AssertionError(f"the evaluated tree could not be removed from the scratch: {target}. Two "
                             f"runs sharing one scratch directory is the usual cause; pass --scratch")
    shutil.copytree(os.path.join(RESTORE_ME, HAKO), target)
    assert os.path.isdir(target)


def file_in(scratch: str, name: str) -> str:
    return os.path.join(scratch, HAKO, name)


# --------------------------------------------------------------------------------------------------
# Mutations. Each one edits the copy only.
# --------------------------------------------------------------------------------------------------

def mutate_unguard_uiFont(scratch: str) -> str:
    """A platform symbol the platform's SDK does not have, at file scope with no condition."""
    path = file_in(scratch, "HakoCard.swift")
    text = read(path)
    assert "\n" in text
    write(path, text.rstrip("\n") + "\n\nlet hakoTestProbeFont = UIFont.systemFont(ofSize: 12)\n")
    return "appended `let hakoTestProbeFont = UIFont.systemFont(ofSize: 12)` to HakoCard.swift"


def mutate_unknown_canimport(scratch: str) -> str:
    """A condition this checkout has no proven fact for, wrapped around real code."""
    path = file_in(scratch, "HakoCard.swift")
    text = read(path)
    write(path, text.rstrip("\n") + "\n\n#if canImport(DeviceDiscoveryUI)\n"
                                  "let hakoTestProbeView = 1\n#endif\n")
    return "appended `#if canImport(DeviceDiscoveryUI)` around a binding"


def mutate_self_guarded_import_only(scratch: str) -> str:
    """`#if canImport(M) import M #endif` and nothing else: legal whichever way it goes."""
    path = file_in(scratch, "HakoCard.swift")
    text = read(path)
    write(path, text.rstrip("\n") + "\n\n#if canImport(DeviceDiscoveryUI)\n"
                                  "    import DeviceDiscoveryUI\n#endif\n")
    return "appended a self-guarded import with no proven fact"


def mutate_self_guarded_import_with_use(scratch: str) -> str:
    """The same condition, but the region now *uses* something: no longer decided by shape."""
    path = file_in(scratch, "HakoCard.swift")
    text = read(path)
    write(path, text.rstrip("\n") + "\n\n#if canImport(DeviceDiscoveryUI)\n"
                                  "    import DeviceDiscoveryUI\n"
                                  "    let hakoTestProbeDevice = DDDevicePickerViewController()\n"
                                  "#endif\n")
    return "appended `#if canImport(DeviceDiscoveryUI)` containing a use"


def mutate_import_only_guard(scratch: str) -> str:
    """The shape the old import gate accepted: guarded import, unguarded UIKit type usage."""
    path = file_in(scratch, "HakoCard.swift")
    text = read(path)
    write(path, text.rstrip("\n") + "\n\n#if canImport(UIKit)\n    import UIKit\n#endif\n\n"
                                  "struct HakoTestProbeRepresentable: UIViewRepresentable {\n"
                                  "    func makeUIView(context _: Context) -> UIView { UIView() }\n"
                                  "    func updateUIView(_: UIView, context _: Context) {}\n}\n")
    return "added a guarded `import UIKit` plus an unguarded `UIViewRepresentable`"


def mutate_ungated_import(scratch: str) -> str:
    path = file_in(scratch, "HakoCard.swift")
    write(path, read(path).rstrip("\n") + "\n\nimport UIKit\n")
    return "added a bare `import UIKit` at file scope"


def mutate_guard_pair(scratch: str) -> str:
    """A declaration removed by a condition while a reference to it is not."""
    path = file_in(scratch, "HakoCard.swift")
    text = read(path)
    write(path, text.rstrip("\n")
          + "\n\n#if canImport(UIKit)\nstruct HakoTestProbeDeclared: View { var body: some View { EmptyView() } }\n#endif\n"
          + "\nstruct HakoTestProbeCaller: View { var body: some View { HakoTestProbeDeclared() } }\n")
    return "declared `HakoTestProbeDeclared` inside `#if canImport(UIKit)` and referenced it outside"


def mutate_unbalanced_braces(scratch: str) -> str:
    path = file_in(scratch, "HakoCard.swift")
    write(path, read(path).rstrip("\n") + "\n\nstruct HakoTestProbeUnclosed {\n")
    return "opened a brace that never closes"


def mutate_empty_scope(scratch: str) -> str:
    target = os.path.join(scratch, HAKO)
    for name in os.listdir(target):
        os.remove(os.path.join(target, name))
    write(os.path.join(target, "notes.txt"), "no Swift here\n")
    return "removed every Swift file from the scope directory"


def mutate_missing_scope(scratch: str) -> str:
    shutil.rmtree(os.path.join(scratch, HAKO))
    return "deleted the scope directory"


def mutate_modifier_unguarded(scratch: str) -> str:
    path = file_in(scratch, "HakoCard.swift")
    write(path, read(path).rstrip("\n")
          + "\n\nstruct HakoTestProbeModifier: View {\n"
            "    @State private var text = \"\"\n"
            "    var body: some View {\n"
            "        TextField(\"x\", text: $text)\n"
            "            .keyboardType(.URL)\n"
            "    }\n}\n")
    return "added an unguarded `.keyboardType(.URL)`"


CASES = (
    # name, mutation (None = the pristine copy), assertions
    #
    # `baseline` asserts only what must hold of *any* tree this suite is run against: the two output paths
    # agree, the four counts are stated, and every discovered Swift file was evaluated. It deliberately does
    # not assert a defect count. It used to, and that made the suite fail when it was run from the
    # integration tree, where the defects it was written against have since been fixed - a test that only
    # passes on the author's tree is a test that will be deleted rather than fixed. The specific red cases
    # below are all built by the suite itself and are therefore independent of the tree.
    ("baseline",
     None,
     [("check_hako_macos_parse.py", ("--platform", "ios"), None, "checked="),
      ("report_hako_platform_api.py", (), None, "checked="),
      ("guard_hako_platform_modifiers.py", ("--check",), None, "checked="),
      ("wrap_hako_platform_declarations.py", ("--check",), None, "checked="),
      ("gate_hako_platform_imports.py", ("--check",), None, "checked=")]),
    # A bare `import UIKit` is legal on iOS - UIKit is there - so the parse checker is right to pass it and
    # the *import* gate is the one that must fail. Keeping both assertions documents which tool owns which
    # question, and the `ungated import` needle is what makes the red side specific rather than incidental.
    ("mutation-ungated-import",
     mutate_ungated_import,
     [("gate_hako_platform_imports.py", ("--check",), 1, "ungated import"),
      ("gate_hako_platform_imports.py", ("--check",), 1, "HakoCard.swift:"),
      ("check_hako_macos_parse.py", ("--platform", "ios"), 0, "PASS")]),
    # `UIFont` breaks macOS, where UIKit is proven absent, and is fine on iOS and tvOS. The needle is the
    # probe's own name, which exists only in the mutated tree: the pristine tree is already red on macOS for
    # reasons of its own, so "exited 1" on its own would prove nothing about this mutation.
    ("mutation-unguarded-api",
     mutate_unguard_uiFont,
     [("check_hako_macos_parse.py", ("--platform", "macos"), 1, "hakoTestProbeFont"),
      ("gate_hako_platform_imports.py", ("--check",), 1, "unguarded use"),
      ("report_hako_platform_api.py", (), 1, "broken on macos"),
      ("check_hako_macos_parse.py", ("--platform", "ios"), 0, "PASS")]),
    ("mutation-unknown-canimport",
     mutate_unknown_canimport,
     [("check_hako_macos_parse.py", ("--platform", "ios"), 1, "NOT VERIFIED"),
      ("check_hako_macos_parse.py", ("--platform", "ios"), 1, "DeviceDiscoveryUI"),
      ("check_hako_macos_parse.py", ("--platform", "ios"), 1, "HakoCard.swift:")]),
    # The `#if canImport(M) import M` shape is decided without a fact; adding one *use* inside it must stop
    # being decided by shape, which is what makes the rule narrow rather than a loophole.
    ("mutation-self-guarded-import-with-use",
     mutate_self_guarded_import_with_use,
     [("check_hako_macos_parse.py", ("--platform", "ios"), 1, "HakoCard.swift:"),
      ("check_hako_macos_parse.py", ("--platform", "ios"), 1, "DeviceDiscoveryUI")]),
    # The shape the old import gate accepted and reported PASS over: the import is guarded, the type that
    # needed it is not. Neither assertion may be satisfied by the import check alone.
    ("mutation-import-guard-is-not-a-fix",
     mutate_import_only_guard,
     [("gate_hako_platform_imports.py", ("--check",), 1, "unguarded use"),
      ("gate_hako_platform_imports.py", ("--check",), 1, "UIViewRepresentable"),
      ("gate_hako_platform_imports.py", ("--check",), 1, "HakoCard.swift:")]),
    ("mutation-guard-pair",
     mutate_guard_pair,
     [("report_hako_platform_api.py", (), 1, "HakoTestProbeDeclared"),
      ("report_hako_platform_api.py", (), 1, "HakoCard.swift:"),
      ("gate_hako_platform_imports.py", ("--check",), 1, "HakoTestProbeDeclared")]),
    ("mutation-unbalanced-braces",
     mutate_unbalanced_braces,
     [("wrap_hako_platform_declarations.py", ("--check",), 1, "REFUSED")]),
    ("mutation-modifier-unguarded",
     mutate_modifier_unguarded,
     [("guard_hako_platform_modifiers.py", ("--check",), 1, "would guard")]),
    ("mutation-empty-scope",
     mutate_empty_scope,
     [("check_hako_macos_parse.py", ("--platform", "ios"), 2, "evaluated nothing is not a pass"),
      ("report_hako_platform_api.py", (), 2, "evaluated nothing is not a pass")]),
    ("mutation-missing-scope",
     mutate_missing_scope,
     [("check_hako_macos_parse.py", ("--platform", "ios"), 2, "does not exist"),
      ("gate_hako_platform_imports.py", ("--check",), 2, "does not exist")]),
)


def run_case(name: str, mutation, assertions, scratch: str) -> tuple[bool, list[str]]:
    notes: list[str] = []
    reset(scratch)
    described = "the pristine tree"
    if mutation is not None:
        described = mutation(scratch)

    ok = True
    for tool, arguments, expected_exit, needle in assertions:
        code, output = gate(tool, scratch, *arguments)
        # `None` means "this tool must run and report a summary, whichever verdict it reaches". A case may
        # only pin a verdict it built itself: pinning one that depends on which defects the tree happens to
        # carry makes the suite pass on the author's checkout and fail on the integration tree.
        if expected_exit is None:
            if code not in (0, 1):
                ok = False
                notes.append(f"{tool} {' '.join(arguments)} exited {code}, which is a tool error, not a "
                             f"verdict")
            elif needle not in output:
                ok = False
                notes.append(f"{tool} {' '.join(arguments)} did not report a summary ({needle!r} absent)")
            else:
                notes.append(f"{tool} {' '.join(arguments)} -> exit {code}, summary present")
            continue
        if code != expected_exit:
            ok = False
            notes.append(f"{tool} {' '.join(arguments)} exited {code}, expected {expected_exit}")
        elif needle not in output:
            ok = False
            notes.append(f"{tool} {' '.join(arguments)} exited {code} but did not report {needle!r}")
        else:
            notes.append(f"{tool} {' '.join(arguments)} -> exit {code}, reported {needle!r}")
    return ok, [f"{described}:"] + [f"    {note}" for note in notes]


def case_json_truthful(scratch: str) -> tuple[bool, list[str]]:
    """The text path and `--json` must agree, on the counts and on the exit code.

    `--json` used to return 0 unconditionally while its own payload listed failures, so the agreement is
    asserted on a tree that must **pass** and on trees that must not: a rule that only checks the red side
    would not have caught it.
    """
    notes: list[str] = []
    ok = True
    runs = (("pristine, must pass", None), ("unguarded `UIFont`", mutate_unguard_uiFont),
            ("no proven fact for `DeviceDiscoveryUI`", mutate_unknown_canimport))
    for label, mutation in runs:
        reset(scratch)
        if mutation is not None:
            mutation(scratch)
        for platform in ("ios", "macos", "tvos"):
            text_code, text_out = gate("check_hako_macos_parse.py", scratch, "--platform", platform)
            json_code, json_out = gate("check_hako_macos_parse.py", scratch, "--platform", platform,
                                       "--json")
            try:
                payload = json.loads(json_out[json_out.index("{"):])
            except (ValueError, json.JSONDecodeError):
                ok = False
                notes.append(f"{label}/{platform}: --json did not emit a JSON object")
                continue
            counts = payload["counts"]
            if text_code != json_code or json_code != payload["exit_code"]:
                ok = False
                notes.append(f"{label}/{platform}: text exit {text_code}, json exit {json_code}, "
                             f"payload says {payload['exit_code']}")
            elif text_code != 0 and "FAIL: this run is not a pass" not in text_out:
                ok = False
                notes.append(f"{label}/{platform}: exit {text_code} without saying the run is not a pass")
            if payload["ok"] != (payload["exit_code"] == 0):
                ok = False
                notes.append(f"{label}/{platform}: payload ok={payload['ok']} disagrees with its own "
                             f"exit_code={payload['exit_code']}")
            for key in ("checked", "errors", "undecidable", "not_covered"):
                if f"{key}=" not in text_out:
                    ok = False
                    notes.append(f"{label}/{platform}: the text summary does not state {key}=")
                if key not in counts:
                    ok = False
                    notes.append(f"{label}/{platform}: the json summary does not state {key}")
            if f"checked={counts['checked']}" not in text_out:
                ok = False
                notes.append(f"{label}/{platform}: text and json disagree on checked "
                             f"({counts['checked']})")
            if mutation is None and platform == "ios" and not payload["ok"]:
                ok = False
                notes.append(f"{label}/{platform}: the pristine tree should pass")
    notes.append("text/json exit codes, counts and ok flags agree, on a passing tree and on two failing ones")
    reset(scratch)
    return ok, notes


def case_self_guarded_import_is_decided(scratch: str) -> tuple[bool, list[str]]:
    """The shape-only rule must decide `#if canImport(M) import M`, and only that shape."""
    notes: list[str] = []
    ok = True
    reset(scratch)
    mutate_self_guarded_import_only(scratch)
    code, output = gate("check_hako_macos_parse.py", scratch, "--platform", "ios")
    if code != 0 or "self-guarded import(s) decided by shape" not in output:
        ok = False
        notes.append(f"a self-guarded import alone should be decided without a fact; exit {code}")
    else:
        notes.append("`#if canImport(DeviceDiscoveryUI)` around only its own import -> exit 0")
    reset(scratch)
    return ok, notes


def mutate_span_probe(scratch: str) -> str:
    """A self-guarded import followed, later in the same file, by a symbol that is absent on tvOS.

    This is the shape that a broken span reader hid: it mistook `#endif` for ordinary text, so the span
    opened by the import never closed and everything after it was blanked - and the file was reported
    `[checked]` while three of its lines named types that do not exist on tvOS. Built here rather than read
    from a known defect, so the case holds whichever tree the suite is run against.
    """
    path = file_in(scratch, "HakoCard.swift")
    write(path, read(path).rstrip("\n")
          + "\n\n#if canImport(DeviceDiscoveryUI)\n"
            "    import DeviceDiscoveryUI\n"
            "#endif\n"
            "\nlet hakoSpanProbe = TerminalWrapperViewModel.self\n")
    return ("appended a self-guarded `canImport(DeviceDiscoveryUI)` import followed by an unguarded "
            "`TerminalWrapperViewModel`")


def case_span_scope(scratch: str) -> tuple[bool, list[str]]:
    """Regression: a self-guarded import must not blank the rest of the file."""
    notes: list[str] = []
    ok = True
    reset(scratch)
    mutate_span_probe(scratch)
    code, output = gate("check_hako_macos_parse.py", scratch, "--platform", "tvos")
    if code != 1 or "hakoSpanProbe" not in output:
        ok = False
        notes.append("the break after a self-guarded import in the same file was not reported on tvos")
    elif "HakoCard.swift:" not in output:
        ok = False
        notes.append("the tvos break was reported without a file:line")
    else:
        notes.append("a self-guarded import earlier in the file does not hide a later break, and the "
                     "break is reported with file:line")
    reset(scratch)
    return ok, notes


def case_resolver_agreement(scratch: str) -> tuple[bool, list[str]]:
    """The line-preserving resolver must agree with `swift_directives.resolve` line for line."""
    notes: list[str] = []
    ok = True
    reset(scratch)
    facts.install_into(swift_directives)
    directory = os.path.join(scratch, HAKO)
    compared = 0
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        text = read(os.path.join(directory, name))
        for platform in facts.PLATFORM_ORDER:
            try:
                mine = [line for _, line in facts.resolve_lines(text, platform, swift_directives)]
            except swift_directives.DirectiveError:
                continue
            theirs = swift_directives.resolve(text, platform).split("\n")
            mine_nonblank = [line for line in mine if line.strip()]
            theirs_nonblank = [line for line in theirs if line.strip()]
            compared += 1
            if mine_nonblank != theirs_nonblank:
                ok = False
                notes.append(f"{name} on {platform}: the two resolvers disagree on the surviving lines")
                break
    reset(scratch)
    notes.append(f"the two resolvers agree on {compared} file/platform combination(s)")
    return ok, notes


def case_restored_is_green(scratch: str) -> tuple[bool, list[str]]:
    """The restored tree must be reported honestly, whichever way it comes out.

    A case cannot pass by leaving the tool permanently red, so this asserts the *shape* of the answer rather
    than a fixed verdict: a zero exit must say every file in scope was decided, a non-zero one must name the
    files, and the scope report must account for every discovered file. The suite is meant to run from any
    checkout - including one where the defects it was written against are already fixed - so a hardcoded
    verdict here would fail on the integration tree for the wrong reason.
    """
    notes: list[str] = []
    ok = True
    reset(scratch)
    code, output = gate("check_hako_macos_parse.py", scratch, "--platform", "ios")
    if code == 0:
        if "PASS: every file in scope was decided for ios" not in output:
            ok = False
            notes.append("exit 0 without saying every file in scope was decided")
        elif "not_covered=0" not in output:
            ok = False
            notes.append("the pass did not state not_covered=0")
        else:
            notes.append("restored tree: `--platform ios` exit 0, every file in scope decided")
    elif code == 1:
        if "NOT CHECKED:" not in output and "BROKEN:" not in output:
            ok = False
            notes.append("exit 1 without naming a file that was not checked or is broken")
        else:
            notes.append("restored tree: `--platform ios` exit 1 and names the files; honest either way")
    else:
        ok = False
        notes.append(f"restored tree: `--platform ios` exit {code}, which is a tool error, not a verdict")

    code, output = gate("report_hako_platform_api.py", scratch)
    counts = json.loads(gate("report_hako_platform_api.py", scratch, "--json")[1]
                        [gate("report_hako_platform_api.py", scratch, "--json")[1].index("{"):])["counts"]
    if counts["files_evaluated"] != counts["files_discovered"] or counts["not_covered"]:
        ok = False
        notes.append(f"the scope report accounts for {counts['files_evaluated']} of "
                     f"{counts['files_discovered']} discovered Swift files")
    else:
        notes.append(f"scope report covers {counts['files_evaluated']} of "
                     f"{counts['files_discovered']} discovered Swift files")
    reset(scratch)
    return ok, notes


def case_baseline_invariants(scratch: str) -> tuple[bool, list[str]]:
    """Whatever this tree contains, the tool's own report must add up.

    Run from any checkout, a pass must mean every discovered Swift file was evaluated, the four counts must
    be stated in both modes, and the two modes must agree. Nothing here depends on which defects the tree
    happens to have.
    """
    notes: list[str] = []
    ok = True
    reset(scratch)
    for platform in ("ios", "macos", "tvos"):
        text_code, text_out = gate("check_hako_macos_parse.py", scratch, "--platform", platform)
        json_code, json_out = gate("check_hako_macos_parse.py", scratch, "--platform", platform, "--json")
        payload = json.loads(json_out[json_out.index("{"):])
        counts = payload["counts"]
        if text_code != json_code:
            ok = False
            notes.append(f"{platform}: text exit {text_code} != json exit {json_code}")
            continue
        if counts["files_evaluated"] != counts["files_discovered"]:
            ok = False
            notes.append(f"{platform}: {counts['files_discovered']} discovered but only "
                         f"{counts['files_evaluated']} evaluated, and this run did not say so")
        total = counts["checked"] + counts["errors"] + counts["undecidable"]
        if total != counts["files_evaluated"]:
            ok = False
            notes.append(f"{platform}: checked+errors+undecidable={total} != evaluated="
                         f"{counts['files_evaluated']}: a file was neither checked nor reported")
        for key in ("checked", "errors", "undecidable", "not_covered"):
            if f"{key}=" not in text_out:
                ok = False
                notes.append(f"{platform}: the text summary omits {key}=")
        if counts["not_covered"] and not payload["ok"] and json_code == 0:
            ok = False
            notes.append(f"{platform}: uncovered files with a zero exit")
        notes.append(f"{platform}: {counts['files_evaluated']}/{counts['files_discovered']} evaluated, "
                     f"checked={counts['checked']} errors={counts['errors']} "
                     f"undecidable={counts['undecidable']} not_covered={counts['not_covered']}, "
                     f"text exit {text_code} == json exit {json_code}")
    reset(scratch)
    return ok, notes


def case_exit_agreement(scratch: str) -> tuple[bool, list[str]]:
    """Regression: the text path and `--json` must not disagree about the same tree.

    The revision this replaces did exactly that on tvOS - the text path returned 1 with nine files
    `[undecidable]`, the `--json` path returned **0** while its payload carried `"undecidable": 9`. A gate
    script runs the JSON form, so the lie was the one that got used. The tree is built here rather than
    assumed, so the case holds on any checkout: an unguarded `UIFont` makes macOS red and leaves iOS and
    tvOS green, and both output paths must say so identically.
    """
    notes: list[str] = []
    ok = True
    for label, mutation in (("pristine", None), ("unguarded `UIFont` on macOS", mutate_unguard_uiFont)):
        reset(scratch)
        if mutation is not None:
            mutation(scratch)
        for platform in ("ios", "macos", "tvos"):
            text_code, text_out = gate("check_hako_macos_parse.py", scratch, "--platform", platform)
            json_code, json_out = gate("check_hako_macos_parse.py", scratch, "--platform", platform,
                                       "--json")
            payload = json.loads(json_out[json_out.index("{"):])
            if text_code != json_code:
                ok = False
                notes.append(f"{label}/{platform}: text exit {text_code} but json exit {json_code}")
                continue
            if payload["exit_code"] != json_code or payload["ok"] != (json_code == 0):
                ok = False
                notes.append(f"{label}/{platform}: the payload's own exit_code/ok disagree with the "
                             f"process exit")
                continue
            if mutation is not None and platform == "macos" and json_code == 0:
                ok = False
                notes.append(f"{label}/{platform}: reported a pass over an unguarded `UIFont`")
                continue
            if json_code != 0 and "FAIL: this run is not a pass" not in text_out:
                ok = False
                notes.append(f"{label}/{platform}: exit {json_code} without saying the run is not a pass")
                continue
            notes.append(f"{label}/{platform}: text exit {text_code} == json exit {json_code} "
                         f"(errors={payload['counts']['errors']}, "
                         f"undecidable={payload['counts']['undecidable']}, "
                         f"not_covered={payload['counts']['not_covered']})")
    reset(scratch)
    return ok, notes


def case_nothing_checked_is_a_refusal(scratch: str) -> tuple[bool, list[str]]:
    """A scope with no Swift file, and a scope that is gone, must both refuse in both forms."""
    notes: list[str] = []
    ok = True
    for label, mutation in (("empty scope", mutate_empty_scope),
                            ("scope deleted", mutate_missing_scope)):
        reset(scratch)
        mutation(scratch)
        for mode in ((), ("--json",)):
            code, output = gate("check_hako_macos_parse.py", scratch, "--platform", "tvos", *mode)
            if code != 2:
                ok = False
                notes.append(f"{label} {' '.join(mode)}: exit {code}, expected 2")
                continue
            if mode and not json.loads(output[output.index("{"):])["nothing_checked"]:
                ok = False
                notes.append(f"{label} --json: payload does not say nothing was checked")
            if not mode and "NOTHING WAS CHECKED" not in output:
                ok = False
                notes.append(f"{label}: the text report does not say nothing was checked")
        notes.append(f"{label}: exit 2 in both forms, with an explicit nothing-checked report")
    reset(scratch)
    return ok, notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--scratch", default=os.environ.get(
        "DSH_SCRATCH", os.path.join(tempfile.gettempdir(),
                                    f"hako-platform-gates-{os.getpid()}")),
        help="disposable directory the fault injection runs in; nothing outside it is written. "
             "Unique per process by default, so two concurrent runs cannot share one and crash each "
             "other; pass a path to reuse one deliberately")
    parser.add_argument("--keep", action="store_true", help="leave the scratch directory in place")
    args = parser.parse_args()

    global RESTORE_ME
    scratch = os.path.abspath(args.scratch)
    if os.path.isdir(scratch) and not args.keep:
        shutil.rmtree(scratch)
    os.makedirs(scratch, exist_ok=True)

    RESTORE_ME = os.path.join(scratch, "_pristine")
    shutil.rmtree(RESTORE_ME, ignore_errors=True)
    os.makedirs(os.path.join(RESTORE_ME, HAKO))
    shutil.copytree(os.path.join(ROOT, HAKO), os.path.join(RESTORE_ME, HAKO), dirs_exist_ok=True)

    print(f"  scratch: {scratch}")
    print(f"  pristine tree taken from {ROOT}")
    print()

    failures = 0
    for name, mutation, assertions in CASES:
        ok, notes = run_case(name, mutation, assertions, scratch)
        print(f"  [{'ok  ' if ok else 'FAIL'}] {name}")
        for note in notes:
            print(f"      {note}")
        failures += 0 if ok else 1

    for name, function in (("baseline-invariants", case_baseline_invariants),
                           ("json-truthful", case_json_truthful),
                           ("exit-agreement", case_exit_agreement),
                           ("nothing-checked-is-a-refusal", case_nothing_checked_is_a_refusal),
                           ("self-guarded-import-is-decided", case_self_guarded_import_is_decided),
                           ("span-scope", case_span_scope),
                           ("restored-tree-is-reported-honestly", case_restored_is_green),
                           ("resolver-agreement", case_resolver_agreement)):
        ok, notes = function(scratch)
        print(f"  [{'ok  ' if ok else 'FAIL'}] {name}")
        for note in notes:
            print(f"      {note}")
        failures += 0 if ok else 1

    reset(scratch)
    print()
    print(f"  {failures} failing case(s) of {len(CASES) + 8}")
    if not args.keep:
        shutil.rmtree(RESTORE_ME, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
