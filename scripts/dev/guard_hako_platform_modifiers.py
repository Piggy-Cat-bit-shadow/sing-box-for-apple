#!/usr/bin/env python3
"""Guard platform-only SwiftUI modifiers with the condition the frozen original used.

# The class

`keyboardType` takes a `UIKeyboardType` and `navigationBarTitleDisplayMode` is a UIKit-backed modifier. In a
shared target - `ApplicationLibrary` builds for iOS, macOS and tvOS - a bare call to either is a compile
error on macOS. The frozen original guards every one of them:

    EditProfileView.swift:45-48
        TextField(...)
            .multilineTextAlignment(.trailing)
        #if !os(macOS)
            .keyboardType(.URL)
        #endif

and the same shape appears in `NewProfileView.swift:118`, `OnDemandRulesView.swift:769` and
`STUNTestView.swift:60`. This restores that shape, one modifier at a time, with the condition taken from the
table below rather than chosen per site.

# Why a modifier and not the enclosing declaration

The whole-declaration wrapper in `wrap_hako_platform_declarations.py` is the wrong unit here: these modifiers
sit in the middle of a long `TextField`/`Form` chain inside a body that must exist on every platform.
Guarding the enclosing declaration would remove the field, not the keyboard hint. The original guards the
modifier, so this does too.

`#if !os(macOS)` is the condition because that is exactly the original's: `UIKeyboardType` is available on
iOS **and** tvOS, so `!os(macOS)` keeps both, where an `os(iOS)`-only guard would silently drop the modifier
on tvOS.

# Fail-closed

A modifier call this tool cannot place - because the conditional-compilation structure around it does not
balance, or because the line is a continuation whose indentation would put the `#if` in the wrong scope -
is **refused**, not skipped, and a refusal makes the run non-zero in `--check` and in write mode. Every
action and refusal names `file:line`, the summary states `checked`, `errors`, `undecidable` and
`not_covered`, and `--json` uses the same exit code as the text path.

Usage:  python guard_hako_platform_modifiers.py [--check] [--json] [--root DIR]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import swift_directives  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join("ApplicationLibrary", "Views", "HakoStyle")

#: Modifier -> the condition that makes it available, taken from the frozen original's own guards.
MODIFIERS = {
    "keyboardType": "!os(macOS)",
    "textInputAutocapitalization": "!os(macOS)",
    "navigationBarTitleDisplayMode": "!os(macOS)",
    "submitLabel": "!os(macOS)",
}

MODIFIER_USE = re.compile(r"^([ \t]*)\.(?:" + "|".join(MODIFIERS) + r")\(")
DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b")


def process(path: str, check_only: bool) -> list[dict]:
    name = os.path.basename(path)
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")

    # A refused file is one whose directive structure cannot be trusted, so "is this modifier already
    # inside a condition" cannot be answered either.
    try:
        swift_directives.assert_balanced(lines)
    except swift_directives.DirectiveError as error:
        return [{"kind": "refused", "line": 1, "detail":
                 f"conditional-compilation structure cannot be trusted ({error}); whether a modifier "
                 f"already sits inside a guard is unknown, so none is touched"}]

    depth = 0
    out: list[str] = []
    actions: list[dict] = []
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        match = DIRECTIVE.match(line)
        if match:
            if match.group(2) == "if":
                depth += 1
            elif match.group(2) == "endif":
                depth -= 1
                if depth < 0:
                    return [{"kind": "refused", "line": number, "detail":
                             "#endif without #if; the file's guard structure is broken"}]

        use = MODIFIER_USE.match(line)
        if depth == 0 and use:
            modifier = re.match(r"[ \t]*\.(\w+)", line).group(1)
            condition = MODIFIERS[modifier]
            indent = use.group(1)
            if indent == "":
                actions.append({"kind": "refused", "line": number, "detail":
                                f".{modifier} is at column 0; the enclosing scope cannot be determined "
                                f"from indentation, so no guard is inserted"})
                out.append(line)
                continue
            out.append(f"{indent}#if {condition}")
            out.append(line)
            out.append(f"{indent}#endif")
            actions.append({"kind": "guard", "line": number,
                            "detail": f"guard .{modifier} with #if {condition}"})
            continue
        out.append(line)

    if any(action["kind"] == "guard" for action in actions) and not check_only:
        io.open(path, "w", encoding="utf-8", newline="").write("\n".join(out))
    return actions


def evaluate(root: str, check_only: bool) -> dict:
    directory = os.path.join(root, HAKO_DIR)
    result: dict = {"root": root, "scope": directory, "mode": "check" if check_only else "write",
                    "files": {}, "tool_errors": [], "skipped": []}
    if not os.path.isdir(directory):
        result["tool_errors"].append(f"scope directory does not exist: {directory}")
        return _finalise(result, 0)

    entries = sorted(os.listdir(directory))
    swift_files = [name for name in entries if name.endswith(".swift")]
    result["skipped"] = [{"file": name, "reason": "not a .swift file; not a member of the Swift compile "
                                                  "unit"}
                         for name in entries if not name.endswith(".swift")]
    if not swift_files:
        result["tool_errors"].append(
            f"no .swift file found under {directory}; a run that evaluated nothing is not a pass")

    for name in swift_files:
        try:
            result["files"][name] = process(os.path.join(directory, name), check_only)
        except (OSError, UnicodeDecodeError) as error:
            result["tool_errors"].append(f"{name}: could not read the file: {error}")
    return _finalise(result, len(swift_files))


def _finalise(result: dict, swift_total: int) -> dict:
    actions = [action for entry in result["files"].values() for action in entry]
    guards = [action for action in actions if action["kind"] == "guard"]
    refusals = [action for action in actions if action["kind"] == "refused"]
    counts = {
        "checked": len(result["files"]),
        "errors": len(refusals),
        "undecidable": len(refusals),
        "not_covered": max(swift_total - len(result["files"]), 0),
        "files_discovered": swift_total + len(result["skipped"]),
        "files_evaluated": len(result["files"]),
        "would_guard": len(guards),
        "symbols": len(guards),
    }
    result["counts"] = counts
    ok = (not refusals and not result["tool_errors"] and counts["checked"] > 0
          and counts["not_covered"] == 0
          and (counts["would_guard"] == 0 if result["mode"] == "check" else True))
    result["ok"] = ok
    result["exit_code"] = 0 if ok else (2 if result["tool_errors"] else 1)
    return result


def render_text(result: dict) -> None:
    print(f"  scope: {result['scope']}  (mode: {result['mode']})")
    for gap in result["tool_errors"]:
        print(f"  [TOOL ERROR   ] {gap}")
    for name, actions in result["files"].items():
        for action in actions:
            label = "would guard " if action["kind"] == "guard" else "REFUSED     "
            print(f"  [{label}] {name}:{action['line']}  {action['detail']}")
    for entry in result["skipped"]:
        print(f"  [not in scope ] {entry['file']}: {entry['reason']}")
    counts = result["counts"]
    print()
    print(f"  checked={counts['checked']} errors={counts['errors']} "
          f"undecidable={counts['undecidable']} not_covered={counts['not_covered']} "
          f"would_guard={counts['would_guard']} (discovered={counts['files_discovered']}, "
          f"evaluated={counts['files_evaluated']})")
    print("  PASS: every platform-only modifier is already inside its condition"
          if result["ok"] else "  FAIL: this run is not a pass; the counts above say why")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="report instead of writing; non-zero when anything needs changing")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    parser.add_argument("--root", default=ROOT, help="checkout to inspect (for fault-injection copies)")
    args = parser.parse_args()

    result = evaluate(os.path.abspath(args.root), args.check)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        render_text(result)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
