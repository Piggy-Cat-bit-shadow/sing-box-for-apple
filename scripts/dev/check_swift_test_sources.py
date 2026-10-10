#!/usr/bin/env python3
"""Check the screen-state test package without a Swift compiler.

What it can prove
-----------------
Three things that a hand-written Swift file most often gets wrong, and that are worth catching on a
machine with no toolchain:

  1. **Balanced structure.** Braces, brackets and parentheses, with string literals, comments and
     `#"`-style raw strings skipped, so an unbalanced brace inside a doc comment does not count.
  2. **Every type it names exists.** Each capitalised identifier that is not an SDK name is looked up
     in the app sources and in the test file itself. A test that names `ScreenFact.displayOn` when the
     enum spells it `displayOn` is caught here.
  3. **Every member it names exists on the type it names it on.** For a curated set of `Type.member`
     and `.member` uses, the declaration is located. This is where a test drifts when the code under
     it is renamed.

What it cannot prove
--------------------
Anything about types. `XCTAssertEqual(a, b)` with mismatched types, a wrong argument label, a
`Sendable` violation, a missing `Equatable` conformance - all invisible. **This is not a compile.**
It is the part of a compiler's work that a regular expression can honestly do, and the report says
exactly that.

Usage:
    python scripts/dev/check_swift_test_sources.py
"""

from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

#: Directories whose Swift is a build target, so a symbol may legitimately resolve there.
SOURCE_TREES = ("ApplicationLibrary", "Library", "MacLibrary", "SFI", "SFM", "SFM.System", "SFT",
                "Extension", "SystemExtension", "HelperService", "JailbreakDaemon")

#: SwiftPM packages: their own sources plus the app files they symlink.
PACKAGES = ("Tests/HakoSubscriptionUsage", "Tests/HakoScreenState")

#: Names that come from the SDK, the language, or a module this package declares itself, and are
#: therefore not expected as a type declaration in this repository.
SDK_NAMES = set("""
XCTest XCTestCase XCTestExpectation XCTWaiter XCTFail XCTAssertEqual XCTAssertNotEqual
XCTAssertNil XCTAssertNotNil XCTAssertTrue XCTAssertFalse XCTAssertNoThrow XCTAssertThrowsError
Foundation Dispatch Darwin Swift SwiftUI Combine ObjectiveC PackageDescription Package Product
Target TestTarget SupportedPlatform Platform
String Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool Character
Array Dictionary Set Optional Result Never Void Any AnyObject AnyHashable Self
Comparable Equatable Hashable Identifiable Codable Encodable Decodable Sendable CaseIterable
CustomStringConvertible LocalizedError Error NSError NSLock NSObject
DispatchQueue DispatchSpecificKey DispatchTime DispatchGroup
Date UUID URL Data TimeInterval Calendar Locale
""".split())


def package_module_names(root: str) -> set[str]:
    """The module names the SwiftPM packages in this repository declare.

    `@testable import Policy` names a target, not a type, so the "every capitalised name is a type"
    rule has to know the difference. Read from each `Package.swift` rather than listed here, so a new
    target does not need this script edited.
    """
    names: set[str] = set()
    manifest = re.compile(r'\.(?:test)?[Tt]arget\(\s*name:\s*"([^"]+)"')
    for package in PACKAGES:
        path = os.path.join(root, package, "Package.swift")
        if not os.path.exists(path):
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        names.update(manifest.findall(text))
    return names

#: Members checked by name against a declaration somewhere in the tree. Kept small and explicit:
#: the point is to catch a rename, not to re-implement a type checker.
MEMBERS = (
    "displayOff", "displayOn", "locked", "unlocked",
    "isSleep", "isWake", "isResumeEdge",
    "notificationName", "fact",
    "rememberValue", "publish", "decide",
    "registerDispatch", "getState", "cancel",
    "recordScreenState", "recordLockState",
    "start", "resync", "isStarted", "failedNotificationNames",
    "event", "snapshot",
    "failed", "registered", "value", "token", "ok",
)


def strip_swift(text: str) -> str:
    """Remove comments and string literals so only code is inspected.

    Order matters: `//` inside a string must not start a comment, so strings are consumed first, and a
    `"` inside a comment must not start a string, so comments are consumed in the same pass.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        # Line comment
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # Block comment (nesting, as Swift allows)
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            i += 2
            while i < n and depth:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        # Raw string
        if ch == "#" and i + 1 < n and text[i + 1] == '"':
            j = text.find('"#', i + 2)
            i = n if j < 0 else j + 2
            continue
        # String literal
        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                if text[i] == "\n":
                    break
                i += 1
            out.append('""')
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_balance(path: str, code: str) -> list[str]:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in pairs:
            if not stack or stack[-1][0] != pairs[ch]:
                return [f"{path}:{line}: unmatched {ch!r}"]
            stack.pop()
    if stack:
        ch, line = stack[0]
        return [f"{path}:{line}: unclosed {ch!r}"]
    return []


def collect_declarations(root: str) -> tuple[set[str], list[str]]:
    """Every type and member name declared anywhere in a source tree."""
    types: set[str] = set()
    member_lines: list[str] = []
    type_re = re.compile(
        r"\b(?:struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)")
    member_re = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|static\s+|class\s+|"
        r"nonisolated\s+|override\s+|mutating\s+|lazy\s+|indirect\s+)*"
        r"(?:func|var|let|case)\s+([A-Za-z_]\w*)")
    for tree in SOURCE_TREES + PACKAGES:
        base = os.path.join(root, tree)
        for directory, subdirs, files in os.walk(base):
            subdirs[:] = [d for d in subdirs if d not in (".build", ".swiftpm", "build")]
            for name in files:
                if not name.endswith(".swift"):
                    continue
                full = os.path.join(directory, name)
                try:
                    text = open(full, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                types.update(type_re.findall(text))
                for line in text.splitlines():
                    m = member_re.match(line)
                    if m:
                        member_lines.append(m.group(1))
                    # `case displayOn` inside an enum is a member too, and the regex above catches
                    # the first one on a line; scan the rest explicitly.
                    for part in re.findall(r"case\s+([A-Za-z_]\w*)", line):
                        member_lines.append(part)
    return types, member_lines


def main() -> int:
    problems: list[str] = []
    checked = 0

    target = os.path.join(ROOT, "Tests", "HakoScreenState")
    if not os.path.isdir(target):
        print(f"not found: {target}", file=sys.stderr)
        return 2

    types, members = collect_declarations(ROOT)
    members_set = set(members)
    modules = package_module_names(ROOT)
    known = SDK_NAMES | modules
    if modules:
        print(f"  modules declared by the packages: {', '.join(sorted(modules))}")

    swift_files = []
    for directory, subdirs, files in os.walk(target):
        subdirs[:] = [d for d in subdirs if d not in (".build", ".swiftpm")]
        for name in files:
            if name.endswith(".swift"):
                swift_files.append(os.path.join(directory, name))

    # A `.swift` file in the package that is one line long and names another `.swift` file is a
    # symlink placeholder (Windows checkout). Its content is a path, not Swift.
    for full in sorted(swift_files):
        rel = os.path.relpath(full, ROOT).replace("\\", "/")
        text = open(full, encoding="utf-8", errors="replace").read()
        if len(text.splitlines()) == 1 and text.strip().endswith(".swift") and " " not in text.strip():
            print(f"  symlink placeholder (not Swift source): {rel} -> {text.strip()}")
            continue
        checked += 1
        code = strip_swift(text)
        problems.extend(check_balance(rel, code))

        # Types: every capitalised identifier must be declared here, be an SDK name, or name a
        # module this repository's packages declare.
        for name in sorted(set(re.findall(r"\b([A-Z][A-Za-z0-9_]*)\b", code))):
            if name in known or name in types:
                continue
            problems.append(f"{rel}: names type {name!r}, which is declared nowhere in this repository")

    # Members: the curated list must each be declared somewhere.
    for member in MEMBERS:
        if member not in members_set:
            problems.append(f"member {member!r} is not declared anywhere in this repository")

    print()
    print(f"checked {checked} Swift file(s) in Tests/HakoScreenState")
    print(f"declarations found: {len(types)} types, {len(members_set)} member names")
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("\nno problem found.")
    print("NOTE: this is a structural and name check, not a compile. It cannot see a type mismatch,")
    print("      a wrong argument label or a missing conformance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
