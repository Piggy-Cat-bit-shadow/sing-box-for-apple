#!/usr/bin/env python3
"""Wrap whole declarations that use a platform-only symbol in the condition that provides it.

# Why the imports are not enough, and neither is a per-symbol edit

Migration resolved the platform conditionals in each ported file for one platform and kept the branch
bodies. That is right for code that *chooses* between a phone and a desktop variant, and wrong for code
that is the only implementation and merely happens to use one platform's API: the guard around it is not a
variant selector, it is what makes the file legal for the other two platforms `ApplicationLibrary` builds
for.

`gate_hako_platform_imports.py` fixed the `import` lines. That was insufficient on its own: `import UIKit`
can sit inside `#if canImport(UIKit)` while the struct that conforms to `UIViewRepresentable` sits outside
it, and it is the struct the compiler chokes on.

# What this does

Finds the **smallest enclosing declaration** - `struct`/`class`/`enum`/`extension`/`func`/`var`/`let` -
whose extent contains a use of a symbol unavailable on some platform, and wraps that declaration in the
condition that provides it. The smallest enclosing declaration is the right unit because it is the smallest
thing that can be excluded without splitting a type across a conditional, which Swift does not allow for a
conforming type's members.

# Fail-closed, which is what the exit code is for

Wrapping is **refused**, rather than guessed, when:

  * the use site is already inside a conditional - then it is someone else's decision;
  * more than one framework would be needed and they are not all available together;
  * the declaration cannot be located unambiguously by brace matching;
  * a use site is not inside any declaration the reader can identify.

A refusal is a **decision the tool could not make**, so it makes the run non-zero in `--check` *and* in
write mode: a writer that silently skips what it cannot read reports success over a file it did not change.
Every action and every refusal names `file:line`. `--json` carries the same counts and the same exit code as
the text path.

Usage:  python wrap_hako_platform_declarations.py [--check] [--file NAME.swift] [--json] [--root DIR]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hako_platform_facts as facts  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join("ApplicationLibrary", "Views", "HakoStyle")

#: Frameworks that do not exist on every platform the shared target builds for, and so force a guard. A
#: framework whose availability is not proven everywhere is included: an unproven platform is not a
#: platform that can be assumed to have it.
NOT_UNIVERSAL = {
    framework for framework in set(facts.SYMBOL_FRAMEWORK.values())
    if any(facts.MODULE_FACTS.get(framework, {}).get(platform) is not True
           for platform in facts.PLATFORM_ORDER)
}

#: A declaration that introduces a scope and can therefore be wrapped whole.
DECL = re.compile(
    r"^[ \t]*(?P<indent>[ \t]*)"
    r"(?P<mods>(?:(?:@\w+(?:\([^)]*\))?|public|internal|private|fileprivate|final|indirect|static|"
    r"nonisolated|open|override)[ \t]+)*)"
    r"(?P<kind>struct|class|enum|extension|actor|func|var|let)\s+(?P<name>\w+)"
)

#: Files whose whole body the original wrapped in one combined condition, with that condition.
#:
#: `UINavigationController`, `UIApplication` and `UIWindowScene` need UIKit, and
#: `TailsshTerminalSelectionViewController` belongs to the optional Ghostty framework, so the union is not a
#: single `canImport` and the reader refuses - correctly, because it will not invent a platform decision.
#: But the original already made it: `TerminalSessionContainerView.swift:1` is
#: `#if canImport(GhosttyTerminal) && os(iOS)` and everything to `:132` is inside. Restoring the author's own
#: condition is not inventing one, so it is recorded here explicitly rather than inferred.
FILE_CONDITION = {
    "HakoTerminalSessionContainerView.swift": "canImport(GhosttyTerminal) && os(iOS)",
}

COMMENT = re.compile(r"^\s*(?://|/\*|\*)")
LINE_COMMENT = re.compile(r"//[^\n]*")
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def code_only(text: str) -> str:
    """Comments **and string literals** blanked, line count preserved.

    Braces and `//` inside a string are not code: a URL like `"https://host/path}"` otherwise swallowed the
    rest of its line and left the file looking unbalanced, which made this tool refuse three files it had
    no reason to refuse. Blanking rather than deleting keeps every line number true.
    """
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)

    def blank(match: re.Match) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    out = []
    for line in text.split("\n"):
        line = STRING_LITERAL.sub(blank, line)
        out.append(" " * len(line) if COMMENT.match(line) else LINE_COMMENT.sub("", line))
    return "\n".join(out)


def line_depths(text: str) -> list[int]:
    """Conditional-compilation depth *before* each line, 0-based by line index."""
    depths = []
    depth = 0
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#endif"):
            depth -= 1
        depths.append(max(depth, 0))
        if stripped.startswith("#if"):
            depth += 1
    return depths


def brace_balance(text: str) -> int:
    """Net `{` minus `}` over code only. Non-zero means spans cannot be trusted."""
    return sum(line.count("{") - line.count("}") for line in code_only(text).split("\n"))


def declaration_spans(text: str) -> list[tuple[int, int, str, str]]:
    """(first_line, last_line, kind, name) for every brace-delimited declaration, 0-based.

    Declarations are collected at **every** nesting level, not only at file scope: the smallest unit that
    can be wrapped is what the docstring promises, and for a use inside a computed property that unit is
    the property, not the type around it. Wrapping the type would delete a macOS view the original keeps.
    """
    lines = code_only(text).split("\n")
    spans: list[tuple[int, int, str, str]] = []
    stack: list[tuple[int, str, str, int]] = []
    depth = 0
    for index, line in enumerate(lines):
        match = DECL.match(line)
        opens, closes = line.count("{"), line.count("}")
        if match and opens > 0:
            stack.append((index, match.group("kind"), match.group("name"), depth))
        depth += opens - closes
        while stack and depth <= stack[-1][3]:
            start, kind, name, _ = stack.pop()
            spans.append((start, index, kind, name))
    return spans


def process(path: str, check_only: bool) -> list[dict]:
    """The actions and refusals for one file. Never guesses and never stays silent about either."""
    name = os.path.basename(path)
    original = io.open(path, encoding="utf-8").read()
    text = original
    depths = line_depths(text)
    body = strip_comments(text)
    body_lines = body.split("\n")

    if brace_balance(text) != 0:
        return [{"kind": "refused", "line": 1, "name": name,
                 "detail": "braces do not balance; declaration extents cannot be located, so no "
                           "declaration is safe to wrap"}]

    file_condition = FILE_CONDITION.get(name)

    # Which lines use a symbol that some platform lacks, and which framework does each need?
    needs: dict[int, set[str]] = {}
    for index, line in enumerate(body_lines):
        if COMMENT.match(line):
            continue
        for symbol, framework in facts.SYMBOL_FRAMEWORK.items():
            if framework not in NOT_UNIVERSAL:
                continue
            if re.search(rf"\b{re.escape(symbol)}\b", line):
                needs.setdefault(index, set()).add(framework)

    unguarded = {index: frameworks for index, frameworks in needs.items() if depths[index] == 0}
    if not unguarded:
        return []

    spans = declaration_spans(text)
    lines = text.split("\n")
    actions: list[dict] = []

    orphans = [index for index in unguarded
               if not any(first <= index <= last for first, last, _, _ in spans)]
    for index in sorted(orphans):
        actions.append({"kind": "refused", "line": index + 1, "name": name,
                        "detail": f"{sorted(unguarded[index])} is used here and no declaration extent "
                                  f"contains this line, so wrapping it would move code the reader has "
                                  f"not identified"})

    # A file whose original wrapped everything in one combined condition: wrap the outermost declaration
    # that contains any use, once, and stop.
    if file_condition:
        outermost = None
        for first, last, kind, decl_name in spans:
            if any(first <= index <= last for index in unguarded):
                if outermost is None or first < outermost[0]:
                    outermost = (first, last, kind, decl_name)
        if outermost is None:
            return actions + [{"kind": "refused", "line": 1, "name": name,
                               "detail": "no declaration contains the use sites"}]
        first, last, kind, decl_name = outermost
        indent = re.match(r"[ \t]*", lines[first]).group(0)
        lines.insert(last + 1, f"{indent}#endif")
        lines.insert(first, f"{indent}#if {file_condition}")
        if not check_only:
            io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
        return actions + [{"kind": "wrap", "line": first + 1, "name": name,
                           "detail": f"wrapped the file's outer {kind} {decl_name} in "
                                     f"#if {file_condition} (the original's own condition)"}]

    # Work bottom-up so earlier insertions do not shift later indices.
    for first, last, kind, decl_name in sorted(spans, key=lambda span: -span[0]):
        inside = [index for index in unguarded if first <= index <= last]
        if not inside:
            continue
        frameworks: set[str] = set()
        for index in inside:
            frameworks |= unguarded[index]
        if len(frameworks) != 1:
            actions.append({"kind": "refused", "line": first + 1, "name": name,
                            "detail": f"{decl_name} needs {sorted(frameworks)} at once; there is no single "
                                      f"condition that provides all of them on every platform"})
            unguarded = {i: f for i, f in unguarded.items() if not (first <= i <= last)}
            continue
        condition = f"canImport({frameworks.pop()})"
        indent = re.match(r"[ \t]*", lines[first]).group(0)
        lines.insert(last + 1, f"{indent}#endif")
        lines.insert(first, f"{indent}#if {condition}")
        actions.append({"kind": "wrap", "line": first + 1, "name": name,
                        "detail": f"wrapped {kind} {decl_name} in #if {condition}"})
        unguarded = {i: f for i, f in unguarded.items() if not (first <= i <= last)}

    if any(action["kind"] == "wrap" for action in actions) and not check_only:
        io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
    return actions


def evaluate(root: str, check_only: bool, target: str | None) -> dict:
    directory = os.path.join(root, HAKO_DIR)
    result: dict = {"root": root, "scope": directory, "mode": "check" if check_only else "write",
                    "files": {}, "tool_errors": [],
                    "not_universal_frameworks": sorted(NOT_UNIVERSAL),
                    "skipped": []}
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
    if target and target not in swift_files:
        result["tool_errors"].append(f"--file {target} is not a .swift file in {directory}")

    for name in swift_files:
        if target and name != target:
            continue
        try:
            result["files"][name] = process(os.path.join(directory, name), check_only)
        except (OSError, UnicodeDecodeError) as error:
            result["tool_errors"].append(f"{name}: could not read the file: {error}")
    return _finalise(result, len(swift_files) if not target else len(result["files"]))


def _finalise(result: dict, swift_total: int) -> dict:
    actions = [action for entry in result["files"].values() for action in entry]
    wraps = [action for action in actions if action["kind"] == "wrap"]
    refusals = [action for action in actions if action["kind"] == "refused"]
    counts = {
        "checked": len(result["files"]),
        "errors": len(refusals),
        "undecidable": len(refusals),
        "not_covered": max(swift_total - len(result["files"]), 0),
        "files_discovered": swift_total + len(result["skipped"]),
        "files_evaluated": len(result["files"]),
        "would_wrap": len(wraps),
        "symbols": len(wraps),
    }
    result["counts"] = counts
    ok = (not refusals and not result["tool_errors"]
          and (counts["would_wrap"] == 0 if result["mode"] == "check" else True)
          and counts["checked"] > 0 and counts["not_covered"] == 0)
    result["ok"] = ok
    result["exit_code"] = 0 if ok else (2 if result["tool_errors"] else 1)
    return result


def render_text(result: dict) -> None:
    print(f"  scope: {result['scope']}  (mode: {result['mode']})")
    print(f"  frameworks that force a guard: {', '.join(result['not_universal_frameworks'])}")
    for gap in result["tool_errors"]:
        print(f"  [TOOL ERROR   ] {gap}")
    for name, actions in result["files"].items():
        for action in actions:
            label = "would wrap " if action["kind"] == "wrap" else "REFUSED     "
            print(f"  [{label}] {name}:{action['line']}  {action['detail']}")
    for entry in result["skipped"]:
        print(f"  [not in scope ] {entry['file']}: {entry['reason']}")
    counts = result["counts"]
    print()
    print(f"  checked={counts['checked']} errors={counts['errors']} "
          f"undecidable={counts['undecidable']} not_covered={counts['not_covered']} "
          f"would_wrap={counts['would_wrap']} (discovered={counts['files_discovered']}, "
          f"evaluated={counts['files_evaluated']})")
    if result["ok"]:
        print("  PASS: nothing to wrap and nothing refused")
    else:
        print("  FAIL: this run is not a pass; the counts above say why")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="report instead of writing; non-zero when anything needs changing")
    parser.add_argument("--file", default=None, help="only this file name")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    parser.add_argument("--root", default=ROOT, help="checkout to inspect (for fault-injection copies)")
    args = parser.parse_args()

    result = evaluate(os.path.abspath(args.root), args.check, args.file)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        render_text(result)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
