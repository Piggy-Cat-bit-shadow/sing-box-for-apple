#!/usr/bin/env python3
"""Report platform-only API use sites that a shared target would have to compile without a guard.

# Why the import check is not enough

`hako-platform-imports` verifies that `import UIKit` sits inside a conditional. It says nothing about the
code that *uses* `UIFont`. A declaration and its import are separate facts, and an import can be guarded
while the only implementation of a function still names a type that does not exist on macOS - which is
exactly what the migration produced in `HakoFontPickerView.monospacedFamilies()`.

This walks each ported file and, for every platform-only symbol, reports the conditional-compilation depth
at the use site. Depth 0 means the compiler parses it on every platform the shared target builds for.

Usage:  python report_hako_platform_api.py [--json]
"""
from __future__ import annotations

import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")

#: Symbol -> the platform(s) whose SDK provides it.
PLATFORM_API = {
    "UIFont": "UIKit",
    "UIFontDescriptor": "UIKit",
    "UIColor": "UIKit",
    "UIImage": "UIKit",
    "UIApplication": "UIKit",
    "UIButton": "UIKit",
    "UIView": "UIKit",
    "UIViewController": "UIKit",
    "UINavigationController": "UIKit",
    "UIWindowScene": "UIKit",
    "UIViewRepresentable": "UIKit",
    "UIViewControllerRepresentable": "UIKit",
    "NSFont": "AppKit",
    "NSFontManager": "AppKit",
    "NSColor": "AppKit",
    "NSView": "AppKit",
    "NSViewRepresentable": "AppKit",
    "NSWindow": "AppKit",
    "QLPreviewController": "QuickLook",
    "QLPreviewControllerDataSource": "QuickLook",
}

#: Identifiers that are part of the project's own optional-framework surface.
OPTIONAL_API = {
    "TailsshTerminalSelectionViewController": "GhosttyTerminal",
}

#: Lines that are only a mention in prose, not a use.
COMMENT = re.compile(r"^\s*(?://|/\*|\*)")


def scan(path: str) -> list[dict]:
    text = io.open(path, encoding="utf-8").read()
    findings = []
    depth = 0
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            depth += 1
        elif stripped.startswith("#endif"):
            depth -= 1
            if depth < 0:
                depth = 0

        if COMMENT.match(line):
            continue
        code = re.sub(r"//.*$", "", line)
        for symbol, framework in {**PLATFORM_API, **OPTIONAL_API}.items():
            if re.search(rf"\b{re.escape(symbol)}\b", code):
                findings.append({
                    "line": number, "symbol": symbol, "framework": framework, "depth": depth,
                    "text": stripped[:100],
                })
    return findings


def main() -> int:
    as_json = "--json" in sys.argv
    report = {}
    unguarded = 0
    for name in sorted(os.listdir(HAKO_DIR)):
        if not name.endswith(".swift"):
            continue
        found = scan(os.path.join(HAKO_DIR, name))
        if not found:
            continue
        report[name] = found
        unguarded += sum(1 for f in found if f["depth"] == 0)

    if as_json:
        print(json.dumps({"files": report, "unguarded_use_sites": unguarded}, indent=2))
        return 0

    for name, found in report.items():
        bad = [f for f in found if f["depth"] == 0]
        if not bad:
            print(f"  [all guarded      ] {name}  ({len(found)} use site(s))")
            continue
        print(f"  [UNGUARDED        ] {name}")
        for f in bad:
            print(f"        {f['line']:4d}  {f['framework']:16s} {f['symbol']:34s} {f['text']}")
    print()
    print(f"  unguarded platform-API use sites: {unguarded}")
    return 1 if unguarded else 0


if __name__ == "__main__":
    sys.exit(main())
