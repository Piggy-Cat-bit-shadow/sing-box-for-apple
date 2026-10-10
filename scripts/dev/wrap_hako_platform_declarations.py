#!/usr/bin/env python3
"""Wrap whole declarations that use a platform-only symbol in the condition that provides it.

# Why the imports are not enough, and neither is a per-symbol edit

Migration resolved the platform conditionals in each ported file for iOS and kept the branch bodies. That
is right for code that *chooses* between a phone and a desktop variant, and wrong for code that is the only
implementation and merely happens to use one platform's API: the guard around it is not a variant selector,
it is what makes the file legal for the other two platforms `ApplicationLibrary` builds for.

`gate_hako_platform_imports.py` fixed the `import` lines. That was insufficient on its own and the
independent review said so: `import UIKit` can sit inside `#if canImport(UIKit)` while the struct that
conforms to `UIViewRepresentable` sits outside it, and it is the struct the compiler chokes on.

# What this does

Finds the **smallest enclosing declaration** - `struct`/`class`/`enum`/`extension`/`func`/`var`/`let` - whose
extent contains a use of a symbol unavailable on some platform, and wraps that declaration in the union of
the frameworks it needs. The smallest enclosing declaration is the right unit because it is the smallest
thing that can be excluded without splitting a type across a conditional, which Swift does not allow for a
conforming type's members.

Wrapping is refused, rather than guessed, when:
  * the use site is already inside a conditional - then it is someone else's decision;
  * more than one framework would be needed and they are not all available together on every platform the
    target builds for;
  * the declaration cannot be located unambiguously by brace matching.

Usage:  python wrap_hako_platform_declarations.py [--check] [--file NAME.swift]
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")

#: Symbol -> framework. A declaration using any of these must not compile where the framework is absent.
SYMBOL_FRAMEWORK = {
    "UIFont": "UIKit", "UIFontDescriptor": "UIKit", "UIColor": "UIKit", "UIImage": "UIKit",
    "UIApplication": "UIKit", "UIButton": "UIKit", "UIView": "UIKit", "UIViewController": "UIKit",
    "UINavigationController": "UIKit", "UIWindowScene": "UIKit", "UIViewRepresentable": "UIKit",
    "UIViewControllerRepresentable": "UIKit", "UIActivityViewController": "UIKit",
    "NSFont": "AppKit", "NSFontManager": "AppKit", "NSColor": "AppKit", "NSView": "AppKit",
    "NSViewRepresentable": "AppKit", "NSWindow": "AppKit", "NSViewController": "AppKit",
    "QLPreviewController": "QuickLook", "QLPreviewControllerDataSource": "QuickLook",
    "QLPreviewItem": "QuickLook",
    "TailsshTerminalSelectionViewController": "GhosttyTerminal",
}

#: Frameworks that do not exist on every platform the shared target builds for, and so force a guard.
NOT_UNIVERSAL = {"UIKit", "AppKit", "GhosttyTerminal"}

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


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def line_depths(text: str) -> list[int]:
    """Conditional-compilation depth *before* each line, 1-based by line index."""
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


def declaration_spans(text: str) -> list[tuple[int, int, str, str]]:
    """(first_line, last_line, kind, name) for every brace-delimited declaration, 0-based."""
    lines = text.split("\n")
    spans = []
    depth = 0
    open_at: tuple[int, str, str] | None = None
    for index, line in enumerate(lines):
        if depth == 0:
            match = DECL.match(line)
            if match and "{" in line:
                open_at = (index, match.group("kind"), match.group("name"))
        depth += line.count("{") - line.count("}")
        if depth == 0 and open_at is not None:
            spans.append((open_at[0], index, open_at[1], open_at[2]))
            open_at = None
    return spans


def process(path: str, check_only: bool) -> list[str]:
    original = io.open(path, encoding="utf-8").read()
    text = original
    depths = line_depths(text)
    body = strip_comments(text)
    body_lines = body.split("\n")

    file_condition = FILE_CONDITION.get(os.path.basename(path))

    # Which lines use a symbol that some platform lacks, and which frameworks they need?
    needs: dict[int, set[str]] = {}
    for index, line in enumerate(body_lines):
        if COMMENT.match(line):
            continue
        for symbol, framework in SYMBOL_FRAMEWORK.items():
            if framework not in NOT_UNIVERSAL:
                continue
            if re.search(rf"\b{re.escape(symbol)}\b", line):
                needs.setdefault(index, set()).add(framework)

    unguarded = {index: frameworks for index, frameworks in needs.items() if depths[index] == 0}
    if not unguarded:
        return []

    spans = declaration_spans(text)
    lines = text.split("\n")
    inserted: list[str] = []

    # A file whose original wrapped everything in one combined condition: wrap the outermost declaration
    # that contains any use, once, and stop. `HakoTerminalSessionContainerView` is the whole file, which is
    # what its original does.
    if file_condition:
        outermost = None
        for first, last, kind, name in spans:
            if any(first <= index <= last for index in unguarded):
                if outermost is None or first < outermost[0]:
                    outermost = (first, last, kind, name)
        if outermost is None:
            return [f"REFUSED: no declaration contains the use sites"]
        first, last, kind, name = outermost
        indent = re.match(r"[ \t]*", lines[first]).group(0)
        lines.insert(last + 1, f"{indent}#endif")
        lines.insert(first, f"{indent}#if {file_condition}")
        if not check_only:
            io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
        return [f"wrapped the file's outer {kind} {name} in #if {file_condition} (the original's condition)"]

    # Work bottom-up so earlier insertions do not shift later indices.
    for first, last, kind, name in sorted(spans, key=lambda s: -s[0]):
        inside = [i for i in unguarded if first <= i <= last]
        if not inside:
            continue
        frameworks: set[str] = set()
        for index in inside:
            frameworks |= unguarded[index]
        if len(frameworks) != 1:
            inserted.append(f"REFUSED {name}: needs {sorted(frameworks)} at once")
            continue
        condition = f"canImport({frameworks.pop()})"
        indent = re.match(r"[ \t]*", lines[first]).group(0)
        lines.insert(last + 1, f"{indent}#endif")
        lines.insert(first, f"{indent}#if {condition}")
        inserted.append(f"wrapped {kind} {name} in #if {condition}")
        unguarded = {i: f for i, f in unguarded.items() if not (first <= i <= last)}

    if inserted and not check_only:
        io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
    return inserted


def main() -> int:
    check_only = "--check" in sys.argv
    target = None
    if "--file" in sys.argv:
        target = sys.argv[sys.argv.index("--file") + 1]

    changed = 0
    for name in sorted(os.listdir(HAKO_DIR)):
        if not name.endswith(".swift"):
            continue
        if target and name != target:
            continue
        result = process(os.path.join(HAKO_DIR, name), check_only)
        if not result:
            continue
        print(f"  {'would change' if check_only else 'changed'} {name}")
        for line in result:
            print(f"      {line}")
        changed += 1
    print(f"\n  {changed} file(s) {'to change' if check_only else 'changed'}")
    return 1 if (check_only and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
