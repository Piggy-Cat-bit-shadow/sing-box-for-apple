#!/usr/bin/env python3
"""Find ported files whose platform structure no longer matches the original's.

`migrate_secondary_page.py` resolved `os(...)`/`canImport(...)` conditions for iOS and kept the surviving
arm. For a phone-only file that is right. For `ApplicationLibrary/Views/HakoStyle/`, which the shared target
compiles for iOS, macOS and tvOS, it silently selects one platform's arm and deletes the others - and when
the deleted arm was an *import* or a `#if os(iOS)` block of stored properties, the file that results is not
a narrower version of the original, it is a different type.

The comparison that catches it: for each ported `Hako*.swift` that has a counterpart at the pin, the
sequence of platform conditions that *dominate* the first declaration must contain the original's. A port
that lost the original's outermost `#if` - or that replaced a two-arm import condition with one arm - shows
up here as a dominating set that is a strict subset.
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

DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")
PLATFORM = re.compile(r"\b(?:os|canImport|targetEnvironment)\s*\(")
DECL = re.compile(r"^[ \t]*(?:(?:public|internal|final|indirect|@\w+)[ \t]+)*"
                  r"(?:struct|class|enum|actor)\s+(Hako\w+)")


def platform_conditions(text: str) -> list[str]:
    """Every platform-bearing condition in the file, in order, with its directive keyword."""
    out = []
    for line in text.split("\n"):
        match = DIRECTIVE.match(line)
        if match and PLATFORM.search(match.group(3) or ""):
            out.append(f"#{match.group(2)} {match.group(3).strip()}")
    return out


def first_declaration_line(text: str) -> int | None:
    """The line index of the first `Hako…` type declaration, **including indented ones**.

    The declaration pattern must not be anchored to column 0: resolving a file-level `#if` leaves its whole
    body indented, so `    public struct HakoFontPickerView: View` is the declaration and a pattern that
    required the modifiers at the start of the line would skip straight past it to the next one - and report
    that the file lost nothing, which is the opposite of the truth for the one file that lost the most.
    """
    for index, line in enumerate(text.split("\n")):
        if DECL.match(line.lstrip()) or DECL.match(line):
            return index
    return None


def dominating_conditions(text: str) -> list[str]:
    """The platform conditions open at the moment the first `Hako…` type is declared."""
    target = first_declaration_line(text)
    if target is None:
        return []
    stack: list[tuple[str, bool]] = []  # (condition, is_platform)
    for index, line in enumerate(text.split("\n")):
        if index == target:
            return [c for c, is_platform in stack if is_platform]
        match = DIRECTIVE.match(line)
        if not match:
            continue
        keyword, condition = match.group(2), match.group(3) or ""
        if keyword == "if":
            stack.append((condition.strip(), bool(PLATFORM.search(condition))))
        elif keyword == "elseif":
            if stack:
                stack[-1] = (condition.strip(), bool(PLATFORM.search(condition)))
        elif keyword == "else":
            if stack:
                stack[-1] = (f"else of {stack[-1][0]}", stack[-1][1])
        else:
            if stack:
                stack.pop()
    return []


def imports(text: str) -> list[tuple[str, bool]]:
    """(module, whether the import is inside a platform condition)."""
    out, stack = [], []
    for line in text.split("\n"):
        match = DIRECTIVE.match(line)
        if match:
            keyword, condition = match.group(2), match.group(3) or ""
            if keyword == "if":
                stack.append(bool(PLATFORM.search(condition)))
            elif keyword in ("elseif", "else"):
                if stack:
                    stack[-1] = True
            else:
                if stack:
                    stack.pop()
            continue
        found = re.match(r"^[ \t]*import\s+(\w+)", line)
        if found:
            out.append((found.group(1), any(stack)))
    return out


def inner_platform_conditions(text: str) -> list[str]:
    """Platform conditions that guard something **inside** a type, as a sorted set.

    Kept as a queryable helper but **not** used as a gate. Comparing inner conditions across a resolution
    is not sound: dropping `#if os(tvOS)` from a file built for iOS is exactly what resolving for iOS is
    *supposed* to do, so a blind set difference reports twenty-nine files that are behaving correctly -
    which is the same "a check that fires on everything gets switched off" failure this round is about.
    What a lost inner guard actually breaks is a declaration whose *type* is only declared on one platform,
    which is a question about declarations rather than about conditions. `HakoFontPickerView` is that case
    and was found by reading it; see the round-8 record.
    """
    found: set[str] = set()
    for line in text.split("\n"):
        match = DIRECTIVE.match(line)
        if match and match.group(2) == "if" and PLATFORM.search(match.group(3) or ""):
            found.add((match.group(3) or "").strip())
    return sorted(found)


def main() -> int:
    directory = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")
    listed = subprocess.run([GIT, "-C", REPO, "ls-tree", "-r", "--name-only", REF,
                             "--", "ApplicationLibrary/Views"], capture_output=True
                            ).stdout.decode("utf-8", "replace").splitlines()

    suspicious, import_notes = [], []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        ours = io.open(os.path.join(directory, name), encoding="utf-8").read()
        stated = re.search(r"copy of `([^`]+)`", ours)
        if not stated:
            continue
        source = stated.group(1)
        if source not in listed:
            suspicious.append((name, source, "header names a path absent at the pin", [], []))
            continue
        original = subprocess.run([GIT, "-C", REPO, "show", f"{REF}:{source}"],
                                  capture_output=True).stdout.decode("utf-8", "replace")

        original_dominating = dominating_conditions(original)
        our_dominating = dominating_conditions(ours)
        missing = [c for c in original_dominating if c not in our_dominating]

        # A platform-exclusive module imported unconditionally is the same defect one level down: the file
        # is compiled for the other platforms too, and the import is not there. `Library`, `SwiftUI` and the
        # rest are not reported even when the original had them inside `#if !os(tvOS)`, because leaving them
        # at file scope changes nothing on any platform that compiles the file.
        EXCLUSIVE = {"AppKit", "UIKit", "GhosttyTerminal", "GhosttyTheme", "ServiceManagement",
                     "FileProvider", "QuickLook", "NetworkExtension", "WatchKit"}
        original_imports = dict(imports(original))
        narrowed = sorted(
            module for module, guarded in imports(ours)
            if not guarded and module in EXCLUSIVE and original_imports.get(module) is True)

        if missing or narrowed:
            suspicious.append((name, source, "", missing, narrowed))

    if not suspicious:
        print("every ported file still carries the platform structure its original had")
        for note in import_notes:
            print(f"  note: {note}")
        return 0
    print(f"{len(suspicious)} ported file(s) no longer match the original's platform structure:")
    for name, source, note, missing, narrowed in suspicious:
        print(f"  {name}")
        print(f"      original  {source}")
        if note:
            print(f"      {note}")
        for condition in missing:
            print(f"      LOST dominating condition: {condition}")
        for module in narrowed:
            print(f"      LOST guard: `import {module}` is now at file scope")
    return 1


if __name__ == "__main__":
    sys.exit(main())
