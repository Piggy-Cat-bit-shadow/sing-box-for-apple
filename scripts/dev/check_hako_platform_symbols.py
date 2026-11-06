#!/usr/bin/env python3
"""Hako files must not use a shared symbol outside the platform condition that declares it.

`SharedPreferences` declares six tunnel settings inside `#if !os(tvOS)`
(`Library/Database/SharedPreferences.swift:31-39`) because the properties they write belong to a
`NETunnelProviderProtocol`, which tvOS does not have. `ApplicationLibrary` is compiled for
`appletvos` as well as iOS and macOS, so a Hako file that reads one of them outside that condition
is a compile error on the tvOS slice - and nothing else in this repository catches it:

  * `check_hako_macos_parse.py` decides iOS, and has no tvOS condition table by decision;
  * `gate_hako_platform_imports.py` / `report_hako_platform_api.py` agree about *imports* and
    about the symbols in `hako_platform_facts.py`, which does not know these six;
  * `check_platform_structure.py` compares the conditions *dominating* the first type declaration
    and file-scope imports, and says in its own header why inner conditions are not compared;
  * `audit_apple_ui_boundary.py`'s `platform-guard-agreement` reads the same facts file.

That combination is how `HakoPacketTunnelView` came to read all six with no guard while the
pinned original guards every one of them. This gate asks the only question that matters for a
*use*: is the platform where the declaration is absent excluded by the conditions the use sits
inside?

It is deliberately narrow - `SharedPreferences` is the file where the platform-gated global
preferences live - and the model of a condition is small: `os(...)` / `!os(...)` joined by `&&`
and `||`. A condition it cannot read (`canImport`, `targetEnvironment`, `#available`) excludes
nothing, which is the conservative direction: an unreadable guard never counts as protection, so
this can over-report but cannot hide a defect.

Usage:
    python check_hako_platform_symbols.py [--root DIR]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

DECLARATIONS_FILE = os.path.join("Library", "Database", "SharedPreferences.swift")

#: The files that belong to the phone presentation. Both are compiled by `ApplicationLibrary`,
#: which is built for appletvos as well as iOS and macOS.
HAKO_GLOB_DIRS = (
    os.path.join("ApplicationLibrary", "Views", "HakoStyle"),
    os.path.join("SFI", ),
)

DIRECTIVE = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")
STATIC_LET = re.compile(r"^[ \t]*(?:public\s+)?static\s+let\s+(\w+)\s*=")
OS_CONDITION = re.compile(r"^(!)?\s*os\(([^)]*)\)$")

ALL_PLATFORMS = frozenset({"iOS", "macOS", "tvOS", "watchOS"})


class ConditionError(RuntimeError):
    pass


def excluded_platforms(condition: str) -> frozenset[str]:
    """The platforms a condition rules out.

    `!os(tvOS)` rules out tvOS; `os(macOS)` rules out everything else. `||` intersects (each arm
    has to rule a platform out) and `&&` unions. A term this does not understand contributes
    nothing, which can only make the answer *less* protective.
    """
    condition = condition.strip()
    if "||" in condition:
        arms = [excluded_platforms(arm) for arm in condition.split("||")]
        result = set(arms[0])
        for arm in arms[1:]:
            result &= arm
        return frozenset(result)

    result: set[str] = set()
    for term in condition.split("&&"):
        match = OS_CONDITION.match(term.strip())
        if not match:
            continue
        platforms = frozenset(part.strip() for part in match.group(2).split(",") if part.strip())
        if match.group(1):
            result |= platforms
        else:
            result |= ALL_PLATFORMS - platforms
    return frozenset(result)


ELSE_PREFIX = "else of "


def frame_exclusion(condition: str) -> frozenset[str]:
    """The platforms a `#if` frame is *not* compiled for.

    For `#if C` that is `C`'s own exclusion set. `#else` is recorded as `else of C` and is
    compiled exactly where `C` is: its exclusion set is therefore the set of platforms `C` allows.
    The identity that makes the two callers below share one function: a frame's exclusion set is
    also the set of platforms on which something declared inside it does not exist.
    """
    if condition.startswith(ELSE_PREFIX):
        return ALL_PLATFORMS - excluded_platforms(condition[len(ELSE_PREFIX):])
    return excluded_platforms(condition)


def gated_declarations(root: str) -> dict[str, list[list[str]]]:
    """`member -> one frame list per declaration of it`.

    Only declarations that sit inside a platform condition are recorded; a member declared
    outside any of them is not in the map and is never reported. A member declared twice - one
    arm per platform, which `SharedPreferences` does for the terminal font size - keeps *both*
    frame lists: it exists on every platform one of its arms is compiled for, so the second arm
    must not make the first one look like the whole declaration.
    """
    path = os.path.join(root, DECLARATIONS_FILE)
    if not os.path.exists(path):
        raise ConditionError("%s does not exist" % path)
    members: dict[str, list[list[str]]] = {}
    stack: list[str] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            match = DIRECTIVE.match(line)
            if match:
                keyword, condition = match.group(1), match.group(2)
                if keyword == "if":
                    stack.append(condition)
                elif keyword == "elseif":
                    if stack:
                        stack[-1] = condition
                elif keyword == "else":
                    if stack:
                        stack[-1] = ELSE_PREFIX + stack[-1]
                else:
                    if stack:
                        stack.pop()
                continue
            declaration = STATIC_LET.match(line)
            if declaration:
                members.setdefault(declaration.group(1), []).append(
                    [entry for entry in stack if frame_exclusion(entry)]
                )
    return members


def swift_files(root: str) -> list[str]:
    found: list[str] = []
    for relative in HAKO_GLOB_DIRS:
        base = os.path.join(root, relative)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            if name.endswith(".swift") and name.startswith("Hako"):
                found.append(os.path.join(base, name))
    return found


def unguarded_uses(root: str) -> list[tuple[str, int, str, str]]:
    """(relative path, line, member, the declaration's condition) for every unprotected use."""
    gated = gated_declarations(root)
    problems: list[tuple[str, int, str, str]] = []

    # Where each member does not exist, over *all* of its declarations: a platform is a home for
    # the member if any declaration is compiled there, so the absent set is the intersection.
    absent: dict[str, frozenset[str]] = {}
    conditions_of: dict[str, str] = {}
    for member, declarations in gated.items():
        intersection: set[str] | None = None
        for frames in declarations:
            excluded_by_declaration: set[str] = set()
            for frame in frames:
                excluded_by_declaration |= frame_exclusion(frame)
            intersection = set(excluded_by_declaration) if intersection is None else (
                intersection & excluded_by_declaration)
        absent[member] = frozenset(intersection or ())
        conditions_of[member] = ", ".join("#if " + frame for frame in declarations[0]) or "(none)"

    for path in swift_files(root):
        relative = os.path.relpath(path, root).replace(os.sep, "/")
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()

        for number, line in enumerate(lines, 1):
            for member, absent_on in absent.items():
                if not absent_on:
                    continue
                if not re.search(r"\bSharedPreferences\.%s\b" % re.escape(member), line):
                    continue
                # The use is protected when the frames it sits inside exclude every platform the
                # member is absent from.
                closed_here: set[str] = set()
                for frame in _open_conditions(lines, number - 1):
                    closed_here |= frame_exclusion(frame)
                if not absent_on <= closed_here:
                    problems.append((relative, number, member, conditions_of[member]))
    return problems


def _open_conditions(lines: list[str], stop: int) -> list[str]:
    """The `#if` conditions open at the given line index."""
    stack: list[str] = []
    for index in range(stop):
        match = DIRECTIVE.match(lines[index])
        if not match:
            continue
        keyword, condition = match.group(1), match.group(2)
        if keyword == "if":
            stack.append(condition)
        elif keyword == "elseif":
            if stack:
                stack[-1] = condition
        elif keyword == "else":
            if stack:
                stack[-1] = ELSE_PREFIX + stack[-1]
        else:
            if stack:
                stack.pop()
    return stack


def gated_member_count(root: str) -> int:
    """How many members exist on fewer than every platform - the set this gate can report on."""
    count = 0
    for declarations in gated_declarations(root).values():
        intersection: set[str] | None = None
        for frames in declarations:
            excluded_by_declaration: set[str] = set()
            for frame in frames:
                excluded_by_declaration |= frame_exclusion(frame)
            intersection = set(excluded_by_declaration) if intersection is None else (
                intersection & excluded_by_declaration)
        if intersection:
            count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getcwd(), help="repository root")
    options = parser.parse_args()

    try:
        problems = unguarded_uses(options.root)
        gated_members = gated_member_count(options.root)
    except ConditionError as error:
        print("FAIL: %s" % error)
        return 2

    files = swift_files(options.root)
    if not files:
        # A gate that scanned nothing is not a green gate.
        print("FAIL: no Hako file was found under %s - the scan covered nothing"
              % ", ".join(HAKO_GLOB_DIRS))
        return 1

    if problems:
        print("%d use(s) of a platform-gated SharedPreferences member outside its condition:"
              % len(problems))
        for relative, number, member, condition in problems:
            print("  %s:%d  SharedPreferences.%s  (declared under `#if %s`)"
                  % (relative, number, member, condition))
        print("\n`ApplicationLibrary` is compiled for appletvos, where these members do not exist. "
              "Guard the use with the same condition the declaration has.")
        return 1

    print("PASS: %d Hako file(s) checked; %d platform-gated SharedPreferences member(s), every use "
          "inside its condition" % (len(files), gated_members))
    if not gated_members:
        print("note: `SharedPreferences` declares no platform-gated member - the check had nothing "
              "to compare against")
    return 0


if __name__ == "__main__":
    sys.exit(main())
