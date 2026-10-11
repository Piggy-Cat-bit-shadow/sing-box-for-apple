#!/usr/bin/env python3
"""Guard platform-only SwiftUI modifiers with the condition the frozen original used.

# The class

`keyboardType` takes a `UIKeyboardType`, and `navigationBarTitleDisplayMode` is a UIKit-backed modifier. In a
shared target - `ApplicationLibrary` builds for iOS, macOS and tvOS - a bare call to either is a compile error
on macOS. The frozen original guards every one of them:

    EditProfileView.swift:45-48
        TextField(...)
            .multilineTextAlignment(.trailing)
        #if !os(macOS)
            .keyboardType(.URL)
        #endif

and the same shape appears in `NewProfileView.swift:118`, `OnDemandRulesView.swift:769` and
`STUNTestView.swift:60`. This restores that shape, one modifier at a time, with the condition taken from the
table below rather than chosen per site.

# Why a modifier and not the enclosing declaration

The whole-declaration wrapper in `wrap_hako_platform_declarations.py` is the wrong unit here: these modifiers
sit in the middle of a long `TextField`/`Form` chain inside a body that must exist on every platform. Guarding
the enclosing declaration would remove the field, not the keyboard hint. The original guards the modifier, so
this does too.

`#if !os(macOS)` is the condition because that is exactly the original's: `UIKeyboardType` is available on iOS
**and** tvOS, so `!os(macOS)` keeps both, where an `os(iOS)`-only guard would silently drop the modifier on
tvOS. `wrap_hako_platform_declarations.py` deliberately does not handle these for the same reason - it would
have wrapped the declaration.

Usage:  python guard_hako_platform_modifiers.py [--check]
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")

#: Modifier -> the condition that makes it available, taken from the frozen original's own guards.
MODIFIERS = {
    "keyboardType": "!os(macOS)",
    "textInputAutocapitalization": "!os(macOS)",
    "navigationBarTitleDisplayMode": "!os(macOS)",
    "submitLabel": "!os(macOS)",
}

MODIFIER_USE = re.compile(r"^([ \t]*)\.(?:" + "|".join(MODIFIERS) + r")\(")


def main() -> int:
    check_only = "--check" in sys.argv
    changed: list[tuple[str, int, str]] = []

    for name in sorted(os.listdir(HAKO_DIR)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(HAKO_DIR, name)
        lines = io.open(path, encoding="utf-8").read().split("\n")

        depth = 0
        out: list[str] = []
        touched: list[tuple[int, str]] = []
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith("#if"):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1

            match = MODIFIER_USE.match(line)
            if depth == 0 and match:
                modifier = re.match(r"[ \t]*\.(\w+)", line).group(1)
                condition = MODIFIERS[modifier]
                indent = match.group(1)
                out.append(f"{indent}#if {condition}")
                out.append(line)
                out.append(f"{indent}#endif")
                touched.append((number, modifier))
                continue
            out.append(line)

        if touched:
            changed.append((name, len(touched), ", ".join(sorted({m for _, m in touched}))))
            if not check_only:
                io.open(path, "w", encoding="utf-8", newline="").write("\n".join(out))

    for name, count, modifiers in changed:
        print(f"  {'would guard' if check_only else 'guarded'} {name}: {count} site(s) [{modifiers}]")
    print(f"\n  {len(changed)} file(s) {'to change' if check_only else 'changed'}")
    return 1 if (check_only and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
