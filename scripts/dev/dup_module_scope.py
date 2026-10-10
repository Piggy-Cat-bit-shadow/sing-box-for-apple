#!/usr/bin/env python3
"""Independent duplicate-declaration scan: same module-scope name in `HakoStyle/` and the shared tree.

`ApplicationLibrary` is one target, so a module-scope declaration that exists twice in it does not build.
The migration renamed the *types* a page declares but could not touch free functions, extensions or
properties, so this looks for every module-scope declaration name that appears both under
`ApplicationLibrary/Views/HakoStyle/` and outside it.

This is a deliberately simple brace-depth scan rather than a Swift parser: it reports candidates with
their file and line, and a human decides. It is used here as evidence, not as a gate.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
HAKO = "ApplicationLibrary/Views/HakoStyle"

DECL = re.compile(
    r"^(?P<indent>[ \t]*)(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
    r"fileprivate[ \t]+|final[ \t]+|static[ \t]+|class[ \t]+|nonisolated[ \t]+)*)"
    r"(?P<kind>struct|class|enum|protocol|actor|func|var|let|typealias|extension)[ \t]+"
    r"(?P<name>[A-Za-z_]\w*)")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def module_scope_decls(path: str) -> list[tuple[str, str, int]]:
    """(kind, name, line) for declarations at brace depth 0 that are not private/fileprivate."""
    try:
        raw = open(path, encoding="utf-8").read()
    except OSError:
        return []
    text = strip_comments(raw)
    out = []
    depth = 0
    for number, line in enumerate(text.split("\n"), 1):
        match = DECL.match(line)
        if match and depth == 0 and not re.search(r"\b(?:private|fileprivate)\b", match.group("mods")):
            out.append((match.group("kind"), match.group("name"), number))
        depth += line.count("{") - line.count("}")
    return out


def swift_files(base: str) -> list[str]:
    out = []
    for directory, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in {".git", "build", ".build"}]
        for name in files:
            if name.endswith(".swift"):
                out.append(os.path.join(directory, name))
    return out


def main() -> int:
    application = os.path.join(ROOT, "ApplicationLibrary")
    hako_dir = os.path.join(application, "Views", "HakoStyle")

    shared: dict[str, list[str]] = {}
    for path in swift_files(application):
        if os.path.normcase(path).startswith(os.path.normcase(hako_dir)):
            continue
        for kind, name, line in module_scope_decls(path):
            rel = os.path.relpath(path, ROOT).replace("\\", "/")
            shared.setdefault(name, []).append(f"{rel}:{line} ({kind})")

    duplicates = []
    for path in swift_files(hako_dir):
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        for kind, name, line in module_scope_decls(path):
            if name in shared:
                duplicates.append((rel, line, kind, name, shared[name]))

    print(f"module-scope names declared in the shared tree: {len(shared)}")
    if not duplicates:
        print("no module-scope name is declared both in HakoStyle/ and outside it")
        return 0
    print(f"{len(duplicates)} module-scope declaration(s) exist twice in the same target:")
    for rel, line, kind, name, where in sorted(duplicates):
        print(f"  {rel}:{line}  {kind} {name}")
        for site in where:
            print(f"      also at {site}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
