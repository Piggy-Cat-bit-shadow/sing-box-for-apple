#!/usr/bin/env python3
"""Fail-closed gate for platform framework **imports and their use sites** in the ported files.

# The defect this gate was born from

`swift_directives.resolve` removes platform conditionals and keeps the selected branch's body. For most
code that is right. For imports it is not: the original wrote

    #if !os(tvOS)
        import UniformTypeIdentifiers
        #if canImport(UIKit)
            import UIKit
        #elseif canImport(AppKit)
            import AppKit
        #endif
    #endif

and the resolver, evaluating for iOS, kept `import UniformTypeIdentifiers` and `import UIKit` while dropping
the guards. Those files live in `ApplicationLibrary`, a **shared** target that compiles for iOS, macOS and
tvOS, so an ungated `import UIKit` is a compile error on macOS.

# The second defect, which made the first fix insufficient

Wrapping the `import` line was not a fix on its own, and this gate used to accept that shape. A file could
read

    #if canImport(UIKit)
        import UIKit
    #endif

    struct Foo: UIViewRepresentable { ... }        <- still parsed on macOS

and the gate reported PASS, because it only ever looked at `import` lines. The import and the code that
needs it are two separate facts, and this gate now checks both:

  1. **the import side** - no platform framework is imported outside a condition;
  2. **the use side** - no symbol belonging to such a framework is compiled on a platform where the
     framework is proven absent.

Both are fail-closed. A file this gate cannot read, a condition it cannot decide, an unproven framework
fact, an ungated import or a broken use site all make the run non-zero and name the `file:line`. The
summary states `checked`, `errors`, `undecidable` and `not_covered` in both output modes, and `--json` uses
the same exit code as the text path.

Usage:  python gate_hako_platform_imports.py [--check] [--json] [--root DIR]
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
import report_hako_platform_api as use_side  # noqa: E402
import swift_directives  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join("ApplicationLibrary", "Views", "HakoStyle")

#: Framework -> the condition that makes it available. Written as `canImport` rather than `os(...)`
#: because that matches the original and stays correct if a framework's availability changes.
GATE = {
    "UIKit": "canImport(UIKit)",
    "AppKit": "canImport(AppKit)",
    "Cocoa": "canImport(AppKit)",
    "QuickLook": "canImport(QuickLook)",
    "GhosttyTerminal": "canImport(GhosttyTerminal)",
    "DeviceDiscoveryUI": "canImport(DeviceDiscoveryUI)",
}

DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")
COMMENT = re.compile(r"^\s*(?://|/\*|\*)")


def top_level_import(line: str) -> str | None:
    """The framework name if `line` is exactly a top-level import, else None."""
    stripped = line.strip()
    if not stripped.startswith("import "):
        return None
    framework = stripped[len("import "):].strip()
    if not framework or not framework.replace("_", "").isalnum():
        return None
    return framework


def ungated_imports(text: str) -> tuple[list[dict], list[dict]]:
    """(findings, undecidable) for `import <framework>` of a platform framework with no condition.

    A framework whose availability the facts do not prove on some platform is `undecidable` rather than
    clean: the gate cannot say whether the guard is needed, so it refuses instead of passing the file.
    """
    findings: list[dict] = []
    undecidable: list[dict] = []
    depth = 0
    problems: list[str] = []
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        match = DIRECTIVE.match(line)
        if match:
            keyword = match.group(2)
            if keyword == "if":
                depth += 1
            elif keyword == "endif":
                depth -= 1
                if depth < 0:
                    problems.append(f"line {number}: #endif without #if")
                    depth = 0

        framework = top_level_import(line)
        if framework is None or framework not in GATE:
            continue
        if depth > 0:
            continue
        unknown = [platform for platform in facts.PLATFORM_ORDER
                   if facts.MODULE_FACTS.get(framework, {}).get(platform) is None]
        record = {"line": number, "framework": framework, "condition": GATE[framework],
                  "unproven_on": unknown, "text": stripped}
        if unknown:
            undecidable.append(record)
        else:
            findings.append(record)
    for problem in problems:
        undecidable.append({"line": 0, "framework": "?", "condition": "?", "text": problem})
    return findings, undecidable


def gate_text(text: str, platform_agnostic: bool = True) -> str:
    """The text with every ungated platform import wrapped in its condition (write mode)."""
    out: list[str] = []
    depth = 0
    for line in text.split("\n"):
        stripped = line.strip()
        match = DIRECTIVE.match(line)
        if match:
            if match.group(2) == "if":
                depth += 1
            elif match.group(2) == "endif":
                depth -= 1
        framework = top_level_import(line)
        if depth == 0 and framework in GATE:
            out.append(f"#if {GATE[framework]}")
            out.append(f"    {stripped}")
            out.append("#endif")
            continue
        out.append(line)
    return "\n".join(out)


def evaluate(root: str, check_only: bool) -> dict:
    directory = os.path.join(root, HAKO_DIR)
    result: dict = {"root": root, "scope": directory, "mode": "check" if check_only else "write",
                    "files": {}, "tool_errors": [], "skipped": []}
    if not os.path.isdir(directory):
        result["tool_errors"].append(f"scope directory does not exist: {directory}")
        return _finalise(result, 0)

    entries = sorted(os.listdir(directory))
    swift_files = [name for name in entries if name.endswith(".swift")]
    result["skipped"] = [{"file": name, "reason": "not a .swift file; not a member of the Swift "
                                                  "compile unit"}
                         for name in entries if not name.endswith(".swift")]
    if not swift_files:
        result["tool_errors"].append(
            f"no .swift file found under {directory}; a run that evaluated nothing is not a pass")

    for name in swift_files:
        path = os.path.join(directory, name)
        try:
            text = io.open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError) as error:
            result["tool_errors"].append(f"{name}: could not read the file: {error}")
            continue
        imports, undecided = ungated_imports(text)
        # The use side is the half that made the first fix insufficient: an import can be inside
        # `canImport` while the type that needed it is not.
        uses = [use for use in use_side.api_use_sites(text)
                if use["broken_on"] and use["framework"] in GATE]
        risky = [use for use in use_side.api_use_sites(text) if use["risky_on"]]
        result["files"][name] = {"ungated_imports": imports, "undecidable_imports": undecided,
                                 "unguarded_uses": uses, "risky_uses": risky}
        if not check_only and imports:
            text = gate_text(text)
            io.open(path, "w", encoding="utf-8", newline="").write(text)

    # The third shape, and the reason the use-side check above is not the whole use side: a *declaration*
    # wrapped in a condition while a reference to it is not. Either side can move without the other.
    texts = {}
    for name in result["files"]:
        try:
            texts[name] = io.open(os.path.join(directory, name), encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
    defects, unverified = use_side.guard_pairs(texts)
    result["guard_pair_defects"] = defects
    result["guard_pairs_unverified"] = unverified

    return _finalise(result, len(swift_files))


def _finalise(result: dict, swift_total: int) -> dict:
    files = result["files"]
    errors = sum(len(entry["ungated_imports"]) + len(entry["unguarded_uses"])
                 for entry in files.values()) + len(result.get("guard_pair_defects", []))
    undecidable = (sum(len(entry["undecidable_imports"]) + len(entry["risky_uses"])
                       for entry in files.values())
                   + len(result.get("guard_pairs_unverified", [])))
    counts = {
        "checked": len(files),
        "errors": errors,
        "undecidable": undecidable,
        "not_covered": max(swift_total - len(files), 0),
        "files_discovered": swift_total + len(result["skipped"]),
        "files_evaluated": len(files),
        "symbols": errors,
    }
    result["counts"] = counts
    ok = (errors == 0 and undecidable == 0 and counts["not_covered"] == 0 and counts["checked"] > 0
          and not result["tool_errors"])
    result["ok"] = ok
    result["exit_code"] = 0 if ok else (2 if result["tool_errors"] else 1)
    return result


def render_text(result: dict) -> None:
    print(f"  scope: {result['scope']}  (mode: {result['mode']})")
    for gap in result["tool_errors"]:
        print(f"  [TOOL ERROR   ] {gap}")
    for name, entry in result["files"].items():
        for finding in entry["ungated_imports"]:
            print(f"  [ungated import] {name}:{finding['line']}  `{finding['text']}` needs "
                  f"#if {finding['condition']}")
        for finding in entry["undecidable_imports"]:
            print(f"  [NOT VERIFIED ] {name}:{finding['line']}  cannot decide whether "
                  f"`{finding['text']}` needs a guard: no proven fact for "
                  f"{', '.join(finding['unproven_on']) or 'this line'}")
        for use in entry["unguarded_uses"]:
            print(f"  [unguarded use] {name}:{use['line']}  {use['framework']} {use['symbol']} is "
                  f"compiled on {', '.join(use['broken_on'])}, where the framework is proven absent "
                  f"- an import guard does not cover this line")
        for use in entry["risky_uses"]:
            print(f"  [NOT VERIFIED ] {name}:{use['line']}  whether {use['symbol']} is compiled on "
                  f"{', '.join(use['risky_on'])} could not be decided")
    for entry in result["skipped"]:
        print(f"  [not in scope ] {entry['file']}: {entry['reason']}")
    for defect in result.get("guard_pair_defects", []):
        print(f"  [declaration ] {defect['reference']} references {defect['symbol']}, declared at "
              f"{defect['declaration']} inside a condition that excludes it on "
              f"{', '.join(defect['platforms'])}")
    for pair in result.get("guard_pairs_unverified", []):
        print(f"  [NOT VERIFIED ] guard pair {pair['reference']} -> {pair['symbol']}: undecided on "
              f"{', '.join(pair['platforms'])}")
    counts = result["counts"]
    print()
    print(f"  checked={counts['checked']} errors={counts['errors']} "
          f"undecidable={counts['undecidable']} not_covered={counts['not_covered']} "
          f"(discovered={counts['files_discovered']}, evaluated={counts['files_evaluated']})")
    if result["mode"] == "check":
        print("  PASS: every platform import is inside its condition and no framework symbol is used "
              "outside one" if result["ok"] else
              "  FAIL: this run is not a pass; the counts above say why")
    else:
        print("  each ungated import was wrapped in its condition"
              if result["ok"] else "  FAIL: something could not be decided; nothing was written")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="report instead of writing; non-zero when anything needs changing")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    parser.add_argument("--root", default=ROOT, help="checkout to inspect (for fault-injection copies)")
    args = parser.parse_args()

    facts.install_into(swift_directives)
    result = evaluate(os.path.abspath(args.root), args.check)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        render_text(result)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
