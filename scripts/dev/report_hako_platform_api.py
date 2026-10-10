#!/usr/bin/env python3
"""Platform guards, checked from **both** sides: where an API is used, and where a symbol is declared.

# The two failure shapes, which are not the same shape

1. **An unguarded use.** `import UIKit` can sit inside `#if canImport(UIKit)` while the `UIFont` that
   needed it sits outside, and it is the use the compiler chokes on. The old gate looked only at the import
   line and reported PASS over exactly this file - `HakoFontPickerView.monospacedFamilies()` was the
   instance that exposed it.
2. **A declaration removed with its callers left behind.** `#if os(iOS)` around `struct Foo` and a
   reference to `Foo` from a file, or a line, that is *not* inside a condition that implies it. The
   declaration side and the use side have to be checked separately, because either can move without the
   other, and guarding one is not a fix for the other.

`#if os(iOS)` includes iPad. It is not a synonym for "iPhone only", and this tool never treats it as one:
it compares the two conditions for **implication on each platform the shared target builds for**, which is
the only relation that decides whether the reference compiles.

# How the comparison is made

Every line carries a three-valued platform state, `{ios: True/False/None, macos: ..., tvos: ...}`: `True`
when the line is inside the compiled region on that platform, `False` when the condition excludes it, and
`None` when a condition could not be decided - `#if DEBUG`, or a `canImport` with no proven fact. A pair is
a defect when some platform has `reference is True` and `declaration is False`: there the compiler parses
the reference and has no type to bind it to. `None` on either side is reported as **not verified** rather
than assumed either way, and a run with any of those is not a pass.

The platform set is the target's own: `ApplicationLibrary` builds for `appletvos`, `iphoneos` and `macosx`
(`sing-box.xcodeproj/project.pbxproj:2288`), so all three are checked on every run.

# Scope, stated rather than implied

The corpus is `ApplicationLibrary/Views/HakoStyle/`. A reference to a Hako symbol from outside that
directory is **not** seen, and the summary says so instead of implying the file set is the whole target.
`--root` points the tool at a copy, which is how the fault-injection tests run it.

Usage:
    python report_hako_platform_api.py [--json] [--root DIR] [--explain]
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
import swift_directives  # noqa: E402
from swift_directives import DirectiveError  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join("ApplicationLibrary", "Views", "HakoStyle")

#: Lines that are only a mention in prose, not a use.
COMMENT = re.compile(r"^\s*(?://|/\*|\*)")
LINE_COMMENT = re.compile(r"//[^\n]*")

#: A declaration that a caller can name. Types and top-level functions/bindings only: a member inside a
#: type is reachable only through its type, which is already tracked.
DECL = re.compile(
    r"^[ \t]*(?:(?:@\w+(?:\([^)]*\))?|public|internal|private|fileprivate|final|indirect|static|"
    r"nonisolated|open|override)[ \t]+)*"
    r"(?:struct|class|enum|actor|protocol|extension|typealias)[ \t]+(\w+)"
    r"|^(?:public[ \t]+|internal[ \t]+)?(func|var|let)[ \t]+(\w+)"
)

DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")


def platform_states(text: str) -> tuple[list[dict[str, bool | None]], list[str]]:
    """Per line, `{platform: True/False/None}` for "is this line compiled there".

    The walk follows the same evaluation order as `swift_directives.resolve`: a branch is live on a
    platform when its own condition holds **and** no earlier branch of the same `#if` was taken there.
    That is what makes an `#elseif` correct rather than merely a second `#if`.
    """
    states: list[dict[str, bool | None]] = []
    problems: list[str] = []
    stack: list[dict] = []

    for number, line in enumerate(text.split("\n"), 1):
        match = DIRECTIVE.match(line)
        if not match:
            states.append(_combine(stack))
            continue

        keyword, condition = match.group(2), match.group(3)
        if keyword == "if":
            frame = {"conds": [condition], "taken": {p: False for p in facts.PLATFORM_ORDER},
                     "active": _eval(condition, number, problems, label=f"line {number}")}
            stack.append(frame)
        elif keyword in ("elseif", "else"):
            if not stack:
                problems.append(f"line {number}: #{keyword} without #if")
                states.append({p: None for p in facts.PLATFORM_ORDER})
                continue
            frame = stack[-1]
            taken = dict(frame["taken"])
            if keyword == "else":
                frame["conds"].append("else")
                frame["active"] = {p: (None if taken[p] is None else not taken[p])
                                   for p in facts.PLATFORM_ORDER}
            else:
                frame["conds"].append(condition)
                own = _eval(condition, number, problems, label=f"line {number}")
                frame["active"] = {
                    p: (None if (taken[p] is None or own[p] is None) else (not taken[p] and own[p]))
                    for p in facts.PLATFORM_ORDER
                }
        else:
            if not stack:
                problems.append(f"line {number}: #endif without #if")
                states.append({p: None for p in facts.PLATFORM_ORDER})
                continue
            stack.pop()
            states.append(_combine(stack))
            continue

        for platform in facts.PLATFORM_ORDER:
            if frame["active"][platform]:
                frame["taken"][platform] = True
        states.append(_combine(stack))

    if stack:
        problems.append(f"{len(stack)} unterminated #if block(s)")
    return states, problems


def _eval(condition: str, number: int, problems: list[str], label: str) -> dict[str, bool | None]:
    result: dict[str, bool | None] = {}
    for platform in facts.PLATFORM_ORDER:
        try:
            result[platform] = swift_directives.evaluate(condition, platform)
        except DirectiveError as error:
            result[platform] = None
            problems.append(f"{label}: {condition!r} is undecidable on {platform} ({error})")
    return result


def _combine(stack: list[dict]) -> dict[str, bool | None]:
    """Conjunction of every frame on the stack, per platform, with `None` as the unknown value."""
    combined: dict[str, bool | None] = {}
    for platform in facts.PLATFORM_ORDER:
        value: bool | None = True
        for frame in stack:
            active = frame["active"][platform]
            if active is False:
                value = False
                break
            if active is None:
                value = None
        combined[platform] = value
    return combined


def analyse(text: str) -> dict:
    states, problems = platform_states(text)
    return {"states": states, "problems": problems}


def declarations_and_references(texts: dict[str, str]) -> tuple[dict, dict]:
    """`{name: {platform: True/False/None}}` for declarations, and the same keys for references."""
    declared: dict[str, dict[str, bool | None]] = {}
    declared_at: dict[str, list[tuple[str, int]]] = {}
    analysed: dict[str, dict] = {}
    for name, text in texts.items():
        analysed[name] = analyse(text)
        for number, line in enumerate(text.split("\n"), 1):
            if COMMENT.match(line):
                continue
            match = DECL.match(line)
            if not match:
                continue
            identifier = match.group(1) or match.group(3)
            if not identifier:
                continue
            declared.setdefault(identifier, {p: False for p in facts.PLATFORM_ORDER})
            declared_at.setdefault(identifier, []).append((name, number))
            for platform in facts.PLATFORM_ORDER:
                declared[identifier][platform] = _or(
                    declared[identifier][platform], analysed[name]["states"][number - 1][platform])

    references: dict[str, list[tuple[str, int]]] = {}
    for name, text in texts.items():
        for number, line in enumerate(text.split("\n"), 1):
            if COMMENT.match(line):
                continue
            code = LINE_COMMENT.sub("", line)
            for identifier in declared:
                if re.search(rf"\b{re.escape(identifier)}\b", code):
                    references.setdefault(identifier, []).append((name, number))
    return declared, references, declared_at, analysed


def _or(left: bool | None, right: bool | None) -> bool | None:
    if left is True or right is True:
        return True
    if left is None or right is None:
        return None
    return False


def guard_pairs(texts: dict[str, str]) -> tuple[list[dict], list[dict]]:
    """(defects, not_verified) for every reference to a conditionally declared symbol."""
    declared, references, declared_at, analysed = declarations_and_references(texts)
    defects: list[dict] = []
    unverified: list[dict] = []

    for identifier, sites in sorted(references.items()):
        availability = declared.get(identifier)
        if availability is None:
            continue
        if all(value is True for value in availability.values()):
            continue  # declared on every platform; nothing to pair
        for name, number in sites:
            if (name, number) in declared_at.get(identifier, []):
                continue
            state = analysed[name]["states"][number - 1]
            record = {
                "symbol": identifier,
                "reference": f"{name}:{number}",
                "declaration": ", ".join(f"{f}:{l}" for f, l in declared_at[identifier]),
                "declared_on": availability,
                "reference_state": state,
            }
            broken_on = [p for p in facts.PLATFORM_ORDER
                         if state[p] is True and availability[p] is False]
            unknown_on = [p for p in facts.PLATFORM_ORDER
                          if state[p] is None or availability[p] is None]
            if broken_on:
                record["platforms"] = broken_on
                defects.append(record)
            elif unknown_on:
                record["platforms"] = unknown_on
                unverified.append(record)
    return defects, unverified


def api_use_sites(text: str) -> list[dict]:
    """Platform-only API named on a line, with the platform state of that line.

    A use site is a **defect** only on a platform where the line is compiled *and* the symbol's module is
    proven absent. `UIViewRepresentable` on a line compiled on iOS and tvOS is fine - UIKit is there on
    both - so the old "is anything unguarded" question was the wrong question: it reported the working
    files and would have passed the broken ones.
    """
    analysed = analyse(text)
    found: list[dict] = []
    for number, line in enumerate(text.split("\n"), 1):
        if COMMENT.match(line):
            continue
        code = LINE_COMMENT.sub("", line)
        for symbol in sorted(facts.SYMBOL_FRAMEWORK):
            if not re.search(rf"\b{re.escape(symbol)}\b", code):
                continue
            state = analysed["states"][number - 1]
            broken, risky = [], []
            for platform in facts.PLATFORM_ORDER:
                available, _, _ = facts.symbol_availability(symbol, platform)
                if state[platform] is True and available is False:
                    broken.append(platform)
                elif state[platform] is None and available is not True:
                    risky.append(platform)
            found.append({"line": number, "symbol": symbol,
                          "framework": facts.SYMBOL_FRAMEWORK[symbol],
                          "state": state, "broken_on": broken, "risky_on": risky,
                          "text": line.strip()[:100]})
    return found


def evaluate(root: str) -> dict:
    directory = os.path.join(root, HAKO_DIR)
    result: dict = {
        "root": root,
        "scope": directory,
        "target_platforms": list(facts.PLATFORM_ORDER),
        "scope_note": ("references to Hako symbols from outside ApplicationLibrary/Views/HakoStyle are "
                       "not seen by this run"),
        "files": {},
        "tool_errors": [],
    }
    if not os.path.isdir(directory):
        result["tool_errors"].append(f"scope directory does not exist: {directory}")
        return _finalise(result, [])

    entries = sorted(os.listdir(directory))
    swift_files = [name for name in entries if name.endswith(".swift")]
    skipped = [{"file": name, "reason": "not a .swift file; not a member of the Swift compile unit"}
               for name in entries if not name.endswith(".swift")]
    if not swift_files:
        result["tool_errors"].append(
            f"no .swift file found under {directory}; a run that evaluated nothing is not a pass")

    texts: dict[str, str] = {}
    for name in swift_files:
        try:
            texts[name] = io.open(os.path.join(directory, name), encoding="utf-8").read()
        except (OSError, UnicodeDecodeError) as error:
            result["tool_errors"].append(f"{name}: could not read the file: {error}")

    unguarded: list[dict] = []
    undecided_uses: list[dict] = []
    for name, text in texts.items():
        uses = api_use_sites(text)
        result["files"][name] = uses
        for use in uses:
            if use["broken_on"]:
                unguarded.append({**use, "file": name})
            elif use["risky_on"]:
                undecided_uses.append({**use, "file": name})

    defects, unverified = guard_pairs(texts)

    result.update(
        unguarded_use_sites=unguarded,
        undecided_use_sites=undecided_uses,
        guard_pair_defects=defects,
        guard_pairs_unverified=unverified,
        skipped=skipped,
    )
    return _finalise(result, swift_files)


def _finalise(result: dict, swift_files: list[str]) -> dict:
    counts = {
        "checked": len([name for name in result["files"] if name in swift_files]) if swift_files else 0,
        "errors": len(result.get("unguarded_use_sites", [])) + len(result.get("guard_pair_defects", [])),
        "undecidable": (len(result.get("undecided_use_sites", []))
                        + len(result.get("guard_pairs_unverified", []))),
        "not_covered": len(swift_files) - len(result["files"]),
        "files_discovered": len(swift_files) + len(result.get("skipped", [])),
        "files_evaluated": len(result["files"]),
        "symbols": len(result.get("unguarded_use_sites", [])) + len(result.get("guard_pair_defects", [])),
    }
    result["counts"] = counts
    ok = (counts["errors"] == 0 and counts["undecidable"] == 0 and counts["not_covered"] == 0
          and counts["checked"] > 0 and not result["tool_errors"])
    result["ok"] = ok
    result["exit_code"] = 0 if ok else (2 if result["tool_errors"] else 1)
    return result


def render_text(result: dict) -> None:
    print(f"  scope: {result['scope']}")
    print(f"  target platforms: {', '.join(result['target_platforms'])}")
    for gap in result["tool_errors"]:
        print(f"  [TOOL ERROR   ] {gap}")

    for use in result.get("unguarded_use_sites", []):
        print(f"  [UNGUARDED    ] {use['file']}:{use['line']}  {use['framework']:16s} {use['symbol']:34s} "
              f"broken on {', '.join(use['broken_on']):12s} {use['text']}")
    for use in result.get("undecided_use_sites", []):
        print(f"  [NOT VERIFIED ] {use['file']}:{use['line']}  {use['symbol']} - compiled-or-not is "
              f"undecided on {', '.join(use['risky_on'])}")
    for defect in result.get("guard_pair_defects", []):
        print(f"  [GUARD PAIR   ] {defect['reference']} references {defect['symbol']}, declared at "
              f"{defect['declaration']}; the reference compiles on {', '.join(defect['platforms'])} "
              f"and the declaration does not")
    for pair in result.get("guard_pairs_unverified", []):
        print(f"  [NOT VERIFIED ] guard pair {pair['reference']} -> {pair['symbol']}: undecided on "
              f"{', '.join(pair['platforms'])}")

    for entry in result.get("skipped", []):
        print(f"  [not in scope ] {entry['file']}: {entry['reason']}")

    counts = result["counts"]
    print()
    print(f"  checked={counts['checked']} errors={counts['errors']} undecidable={counts['undecidable']} "
          f"not_covered={counts['not_covered']} (discovered={counts['files_discovered']}, "
          f"evaluated={counts['files_evaluated']})")
    print(f"  scope note: {result['scope_note']}")
    if result["ok"]:
        print("  PASS: every file in scope was decided, no unguarded platform API, and every reference to "
              "a conditionally declared symbol is guarded by a condition that implies its declaration")
    else:
        print("  FAIL: this run is not a pass; the counts above say why")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    parser.add_argument("--root", default=ROOT, help="checkout to inspect (for fault-injection copies)")
    parser.add_argument("--explain", action="store_true", help="also print the per-file use-site list")
    parser.add_argument("--check", action="store_true",
                        help="accepted for symmetry with the other gates: this tool never writes, so "
                             "checking is all it does")
    args = parser.parse_args()

    facts.install_into(swift_directives)
    result = evaluate(os.path.abspath(args.root))

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if args.explain:
            for name, uses in result["files"].items():
                print(f"  {name}: {len(uses)} platform-only API use site(s)")
            print()
        render_text(result)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
