#!/usr/bin/env python3
"""Which of the ported files would fail to **compile for a target platform** as they stand?

This is a coverage measurement, not a compile. There is no Swift toolchain in this checkout and this tool
does not pretend to be one: it resolves each file's conditional compilation for one platform using the
proven facts in `hako_platform_facts.py`, reports which platform-exclusive symbols remain in the surviving
text, and reports what it could **not** decide. It cannot see generics, overload resolution or `@available`.

# Why this question and not "how many guards were lost"

Guard counts are a proxy and a misleading one. A file can lose twenty guards and still compile if the code
inside them was platform-neutral; it can keep every guard and still fail if one use site sits outside.

# The exit contract, which is the point of this tool

A run is a pass only when it decided **every** file in scope. Concretely, exit status is 0 if and only if

    errors == 0 and undecidable == 0 and not_covered == 0 and checked > 0 and no tool error

and the same rule is applied to `--json`, which historically returned 0 while failures were listed in its
own payload. The summary states `checked`, `errors`, `undecidable` and `not_covered` explicitly in both
modes, and the two modes are rendered from one result object so they cannot disagree.

  * `errors` - a file the platform's compiler would be asked to parse and could not: a symbol whose module
    is **proven** absent there.
  * `undecidable` - a file that was **not** checked: a condition this checkout has no proven fact for, or a
    surviving symbol whose module's availability is unknown. A run that skipped files is not a pass, and
    the tool says which fact was missing rather than counting the file as clean.
  * `not_covered` - a file in scope that was not evaluated at all. Always printed, never assumed empty.

# Inputs

The scope is `ApplicationLibrary/Views/HakoStyle/`, a directory belonging to the `ApplicationLibrary`
target, whose `SUPPORTED_PLATFORMS` includes `appletvos`, `iphoneos` and `macosx`
(`sing-box.xcodeproj/project.pbxproj:2288`). Every file in that directory therefore has to compile for all
three. `--root` points the tool at a copy of the checkout, which is how the fault-injection tests run it.

Usage:
    python check_hako_macos_parse.py [--platform ios|macos|tvos] [--json] [--root DIR] [--explain]
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

COMMENT_ONLY = re.compile(r"^\s*(?://|/\*|\*)")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")


def blank_comments(text: str) -> str:
    """Comments replaced by blanks, line count preserved so line numbers stay true."""
    text = BLOCK_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
    return "\n".join(
        " " * len(line) if COMMENT_ONLY.match(line) else LINE_COMMENT.sub("", line)
        for line in text.split("\n")
    )


def evaluate_file(path: str, platform: str) -> dict:
    """One file's outcome: checked, error or undecidable, with the detail either way."""
    try:
        text = io.open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as error:
        return {"status": "undecidable", "reason": f"could not read the file: {error}", "kind": "read"}

    try:
        lines, safe_imports = facts.reachable_regions(text, platform, swift_directives)
    except DirectiveError as error:
        return {"status": "undecidable", "reason": str(error), "kind": "condition"}

    body = blank_comments("\n".join(line for _, line in lines))
    numbered = list(zip((number for number, _ in lines), body.split("\n")))

    findings = []
    unresolved = []
    for number, line in numbered:
        code = LINE_COMMENT.sub("", line)
        if COMMENT_ONLY.match(line):
            continue
        # One table, in `hako_platform_facts`, holds every platform-exclusive token - type names and the
        # toolkit-colour `Color` initialisers alike - so this tool and the import gate cannot disagree
        # about what counts.
        for symbol in sorted(facts.SYMBOL_FRAMEWORK):
            if not re.search(rf"\b{re.escape(symbol)}\b", code):
                continue
            available, framework, evidence = facts.symbol_availability(symbol, platform)
            record = {"line": number, "symbol": symbol, "framework": framework,
                      "text": line.strip()[:100], "evidence": evidence}
            if available is False:
                findings.append(record)
            elif available is None:
                unresolved.append(record)

    result = {"safe_imports": sorted(safe_imports.items())}
    if findings:
        result.update(status="error", findings=findings)
    elif unresolved:
        result.update(status="undecidable", kind="symbol", unresolved=unresolved,
                      reason="a surviving symbol's module has no proven availability for this platform")
    else:
        result["status"] = "checked"
    return result


def evaluate(root: str, platform: str) -> dict:
    directory = os.path.join(root, HAKO_DIR)
    result: dict = {
        "platform": platform,
        "root": root,
        "scope": directory,
        "target": facts.SHARED_TARGET,
        "target_platforms": list(facts.PLATFORM_ORDER),
        "facts": _fact_rows(platform),
        "fact_gaps": [reason for key, reason in facts.UNPROVEN.items()],
        "files": {},
        "tool_errors": [],
    }

    if not os.path.isdir(directory):
        result["tool_errors"].append(f"scope directory does not exist: {directory}")
        return _finalise(result, directory, [])

    entries = sorted(os.listdir(directory))
    swift_files = [name for name in entries if name.endswith(".swift")]
    skipped = [{"file": name, "reason": "not a .swift file; not a member of the Swift compile unit"}
               for name in entries if not name.endswith(".swift")]

    if not swift_files:
        result["tool_errors"].append(
            f"no .swift file found under {directory}; a run that evaluated nothing is not a pass")

    for name in swift_files:
        outcome = evaluate_file(os.path.join(directory, name), platform)
        result["files"][name] = outcome
        if outcome["status"] == "undecidable" and outcome.get("kind") == "read":
            result["tool_errors"].append(f"{name}: {outcome['reason']}")

    return _finalise(result, directory, skipped)


def _fact_rows(platform: str) -> list[dict]:
    """Every proven fact this tool resolves conditions with, plus its evidence, for the report."""
    rows: list[dict] = []
    for namespace, table in (("canImport", facts.MODULE_FACTS),
                             ("targetEnvironment", facts.TARGET_ENVIRONMENT_FACTS)):
        for name in sorted(table):
            fact = table[name].get(platform)
            if fact is not None:
                rows.append({"fact": f"{namespace}({name})", "platform": platform,
                             "value": fact.value, "evidence": list(fact.evidence)})
    return rows


def _finalise(result: dict, directory: str, skipped: list[dict]) -> dict:
    statuses = {name: data["status"] for name, data in result["files"].items()}
    checked = sorted(name for name, status in statuses.items() if status == "checked")
    errors = sorted(name for name, status in statuses.items() if status == "error")
    undecidable = sorted(name for name, status in statuses.items() if status == "undecidable")
    evaluated = set(statuses)
    discovered = [entry["file"] for entry in skipped] + sorted(evaluated)
    not_covered = sorted(
        name for name in (entry["file"] for entry in skipped) if name.endswith(".swift")
    )

    counts = {
        "checked": len(checked),
        "errors": len(errors),
        "undecidable": len(undecidable),
        "not_covered": len(not_covered),
        "files_discovered": len(discovered),
        "files_evaluated": len(evaluated),
        "skipped_not_swift": len(skipped),
        "symbols": sum(len(data.get("findings", [])) for data in result["files"].values()),
    }
    result.update(
        counts=counts,
        evaluated=checked + errors + undecidable,
        checked_files=checked,
        error_files=errors,
        undecidable_files=undecidable,
        skipped=skipped,
        not_covered_files=not_covered,
    )
    ok = (counts["errors"] == 0 and counts["undecidable"] == 0 and counts["not_covered"] == 0
          and counts["checked"] > 0 and not result["tool_errors"])
    result["nothing_checked"] = counts["checked"] == 0
    result["ok"] = ok
    result["exit_code"] = 0 if ok else (2 if result["tool_errors"] else 1)
    return result


def render_text(result: dict) -> None:
    platform = result["platform"]
    print(f"  scope: {result['scope']}")
    print(f"  target: {result['target']} (builds for {', '.join(result['target_platforms'])})")
    for gap in result["tool_errors"]:
        print(f"  [TOOL ERROR   ] {gap}")
    for name, data in result["files"].items():
        if data["status"] == "checked":
            if data.get("safe_imports"):
                modules = ", ".join(sorted({module for _, module in data["safe_imports"]}))
                print(f"  [checked      ] {name}  (self-guarded import(s) decided by shape: {modules})")
            else:
                print(f"  [checked      ] {name}")
        elif data["status"] == "error":
            print(f"  [BROKEN {platform:4s}] {name}  "
                  f"({len(data['findings'])} symbol(s) the SDK does not have)")
            for hit in data["findings"]:
                print(f"        {name}:{hit['line']}  {hit['framework']:16s} {hit['symbol']:34s} "
                      f"{hit['text']}")
        else:
            print(f"  [NOT VERIFIED ] {name}: {data['reason']}")
            for hit in data.get("unresolved", []):
                print(f"        {name}:{hit['line']}  {hit['framework']:16s} {hit['symbol']:34s} "
                      f"{hit['text']}")

    for entry in result["skipped"]:
        print(f"  [not in scope ] {entry['file']}: {entry['reason']}")

    counts = result["counts"]
    print()
    print(f"  {platform}: checked={counts['checked']} errors={counts['errors']} "
          f"undecidable={counts['undecidable']} not_covered={counts['not_covered']} "
          f"symbols={counts['symbols']} "
          f"(discovered={counts['files_discovered']}, evaluated={counts['files_evaluated']}, "
          f"non-Swift skipped={counts['skipped_not_swift']})")
    if result.get("nothing_checked"):
        print(f"  NOTHING WAS CHECKED for {platform}: no file in scope was evaluated, which is a refusal "
              f"and not an empty pass")
    for name in result["undecidable_files"]:
        print(f"  NOT CHECKED: {name}: {result['files'][name]['reason']}")
    for name in result["not_covered_files"]:
        print(f"  NOT COVERED: {name}")
    for name in result["error_files"]:
        print(f"  BROKEN: {name}")
    if result["ok"]:
        print(f"  PASS: every file in scope was decided for {platform} and no platform-exclusive "
              f"symbol survives")
    else:
        print("  FAIL: this run is not a pass; the counts above say why")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--platform", choices=list(facts.PLATFORM_ORDER), default="macos")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    parser.add_argument("--root", default=ROOT, help="checkout to inspect (for fault-injection copies)")
    parser.add_argument("--explain", action="store_true",
                        help="print the proven facts and the deliberately unproven ones")
    args = parser.parse_args()

    facts.install_into(swift_directives)

    result = evaluate(os.path.abspath(args.root), args.platform)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if args.explain:
            print("  proven facts for this platform:")
            for fact in result["facts"]:
                print(f"    {fact['fact']} = {fact['value']}")
                for evidence in fact["evidence"]:
                    print(f"        evidence: {evidence}")
            print("  deliberately unproven (a file needing one is NOT VERIFIED):")
            for key, reasons in facts.UNPROVEN.items():
                print(f"    {key}")
                for reason in reasons:
                    print(f"        {reason}")
            print()
        render_text(result)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
