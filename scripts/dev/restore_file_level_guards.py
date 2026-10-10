#!/usr/bin/env python3
"""Restore, in general, the file-level platform condition a ported page lost.

Twenty-nine findings said the same thing in ten files: a ported file reads a symbol the shared target only
declares under a condition, with no condition around the read. Most of them are one shape - the original
wraps the whole page in a file-level `#if`, the migration resolved `os(...)` for iOS, and *some* of the arms
inside survived while the outer condition did not.

Fixing those one file at a time is how this became a whack-a-mole: fixing `HakoTaildropView` made
`HakoToolsView`'s use of it unguarded, and so on down the callers. This does the general thing instead.

For each ported file with a readable original:

  1. read the original's **file-level** condition - the `#if` whose matching `#endif` is the last directive
     in the file, found by brace depth so a nested block's `#endif` is never mistaken for it;
  2. if the port does not already carry that condition, wrap the port's body in it;
  3. if the original has no file-level condition, do nothing - the port's use sites have to be fixed
     individually and the report says so.

Calibration is part of the design: the original must itself be balanced inside that condition, or the
condition was not the file-level one and the script refuses rather than guessing.
"""
from __future__ import annotations

import io
import os
import re
import subprocess
import sys

GIT = os.environ.get("DSH_GIT") or r"C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe"
REPO = os.environ.get("DSH_REPO") or r"C:\Deepseek\IOS客户端\sing-box-for-apple"
REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
APPLY = "--apply" in sys.argv

DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")
PLATFORM = re.compile(r"\b(?:os|canImport|targetEnvironment)\s*\(")
HEADER_PATH = re.compile(r"copy of `([^`]+)`")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


DECL = re.compile(r"^[ \t]*(?:(?:public|internal|final|indirect|@\w+)[ \t]+)*"
                  r"(?:struct|class|enum|actor|extension)\s+\w+")


def file_level_condition(text: str) -> tuple[str, int, int] | None:
    """`(condition, open_line, close_line)` for the condition that wraps the file's declarations.

    The discriminator is not "the first `#if`" and not "the one whose body is brace-balanced" - both picked
    plausible-looking inner guards. A file-level condition is one that **contains the first type
    declaration**, because the point of wrapping a page is to wrap its declarations. `#if os(tvOS)` sitting
    above a `public struct` in the original is an inner variant of one property, and wrapping a whole port
    in it would delete the page everywhere but tvOS.
    """
    stripped = strip_comments(text)
    lines = stripped.split("\n")
    first_declaration = next((i for i, line in enumerate(lines) if DECL.match(line)), None)
    if first_declaration is None:
        return None

    stack: list[tuple[str, int]] = []
    for index, line in enumerate(lines):
        match = DIRECTIVE.match(line)
        if not match:
            continue
        keyword, condition = match.group(2), (match.group(3) or "").strip()
        if keyword == "if":
            stack.append((condition, index))
        elif keyword == "endif" and stack:
            opened, open_index = stack.pop()
            if open_index < first_declaration <= index and PLATFORM.search(opened):
                return opened, open_index, index
    return None


def body_is_balanced(text: str, open_index: int, close_index: int) -> bool:
    lines = strip_comments(text).split("\n")
    depth = 0
    for line in lines[open_index + 1:close_index]:
        depth += line.count("{") - line.count("}")
    return depth == 0


def already_guarded(lines: list[str], condition: str) -> bool:
    return any(re.match(rf"^[ \t]*#if[ \t]+{re.escape(condition)}[ \t]*$", line) for line in lines)


def main() -> int:
    directory = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")
    calibrated, changed, skipped = 0, 0, []

    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        full = os.path.join(directory, name)
        text = io.open(full, encoding="utf-8").read()
        stated = HEADER_PATH.search(text)
        if not stated:
            continue
        source = stated.group(1)
        proc = subprocess.run([GIT, "-C", REPO, "show", f"{REF}:{source}"], capture_output=True)
        if proc.returncode != 0:
            skipped.append((name, "header names a path absent at the pin"))
            continue
        original = proc.stdout.decode("utf-8", "replace")

        found = file_level_condition(original)
        if found is None:
            skipped.append((name, "the original has no file-level platform condition"))
            continue
        condition, open_index, close_index = found
        if not body_is_balanced(original, open_index, close_index):
            skipped.append((name, f"the original's `#if {condition}` body is not balanced; refusing"))
            continue
        calibrated += 1

        lines = text.split("\n")
        if already_guarded(lines, condition):
            continue
        start = 0
        while start < len(lines) and (lines[start].startswith("//") or lines[start].strip() == ""):
            start += 1
        header, body = lines[:start], lines[start:]
        out = (header
               + [f"//  The original wraps this page in `#if {condition}` "
                  f"(`{source}`: line {open_index + 1}, closed at `{close_index + 1}`), and the symbols it",
                  "//  reads are declared under that same condition. Restored by",
                  "//  `scripts/dev/restore_file_level_guards.py`, which reads the condition out of the",
                  "//  original rather than keeping a list; the body is the port's own and is re-indented",
                  "//  once, not rewritten.", "//", f"#if {condition}"]
               + ["    " + line if line.strip() else line for line in body]
               + ["#endif", ""])
        result = "\n".join(out)
        print(f"  {name}: +`#if {condition}` … `#endif`   "
              f"(original: {source}:{open_index + 1})")
        changed += 1
        if APPLY:
            io.open(full, "w", encoding="utf-8", newline="").write(result)

    print()
    print(f"originals with a readable file-level condition: {calibrated}")
    print(f"ported files {'changed' if APPLY else 'to change'}: {changed}")
    for name, why in skipped:
        print(f"  not applicable  {name}: {why}")
    print()
    print("applied" if APPLY else "dry run - pass --apply to write")
    return 0


if __name__ == "__main__":
    sys.exit(main())
