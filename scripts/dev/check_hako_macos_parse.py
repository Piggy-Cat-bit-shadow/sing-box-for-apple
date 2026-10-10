#!/usr/bin/env python3
"""Which of the ported files would fail to **compile for macOS** as they stand?

# Why this question and not "how many guards were lost"

Guard counts are a proxy and a misleading one. What matters is whether the compiler, building this shared
target for macOS or tvOS, is asked to parse something those SDKs do not have. A file can lose twenty guards
and still compile if the code inside them was platform-neutral; it can keep every guard and still fail if one
use site sits outside.

So this resolves each ported file's conditionals for a target platform - reusing `swift_directives`, the same
evaluator the migration used - and then reports which platform-only symbols remain in the surviving text. A
symbol still present after resolving for macOS is one the macOS compiler would have to know.

This is a coverage measurement, not a compile. It cannot see generics, overload resolution or `@available`,
and it only knows the symbols listed below.

Usage:  python check_hako_macos_parse.py [--platform macos|ios|tvos] [--json]
"""
from __future__ import annotations

import io
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from swift_directives import DirectiveError, resolve  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")

#: Symbols that exist only in one platform's SDK, plus the project's optional frameworks.
ONLY_ON = {
    "UIFont": "UIKit", "UIFontDescriptor": "UIKit", "UIColor": "UIKit", "UIImage": "UIKit",
    "UIApplication": "UIKit", "UIButton": "UIKit", "UIView": "UIKit", "UIViewController": "UIKit",
    "UINavigationController": "UIKit", "UIWindowScene": "UIKit", "UIViewRepresentable": "UIKit",
    "UIViewControllerRepresentable": "UIKit", "UIBlurEffect": "UIKit", "UIVisualEffectView": "UIKit",
    "NSFont": "AppKit", "NSFontManager": "AppKit", "NSColor": "AppKit", "NSView": "AppKit",
    "NSViewRepresentable": "AppKit", "NSWindow": "AppKit", "NSViewController": "AppKit",
    "QLPreviewController": "QuickLook", "QLPreviewControllerDataSource": "QuickLook",
    "QLPreviewItem": "QuickLook",
    "TailsshTerminalSelectionViewController": "GhosttyTerminal",
}

#: Which of those a given platform provides.
AVAILABLE_ON = {
    "ios": {"UIKit", "QuickLook", "GhosttyTerminal"},
    "macos": {"AppKit", "QuickLook"},
    "tvos": {"UIKit"},
}


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def main() -> int:
    as_json = "--json" in sys.argv
    platform = "macos"
    if "--platform" in sys.argv:
        platform = sys.argv[sys.argv.index("--platform") + 1]
    available = AVAILABLE_ON[platform]

    report = {}
    total = 0
    for name in sorted(os.listdir(HAKO_DIR)):
        if not name.endswith(".swift"):
            continue
        text = io.open(os.path.join(HAKO_DIR, name), encoding="utf-8").read()
        try:
            resolved = resolve(text, platform)
        except DirectiveError as error:
            report[name] = {"error": str(error)}
            continue
        body = strip_comments(resolved)
        hits = []
        for number, line in enumerate(body.split("\n"), 1):
            for symbol, framework in ONLY_ON.items():
                if framework in available:
                    continue
                if re.search(rf"\b{re.escape(symbol)}\b", line):
                    hits.append({"line": number, "symbol": symbol, "framework": framework,
                                 "text": line.strip()[:90]})
        if hits:
            report[name] = {"hits": hits}
            total += len(hits)

    if as_json:
        print(json.dumps({"platform": platform, "files": report, "failures": total}, indent=2))
        return 0

    for name, data in report.items():
        if "error" in data:
            print(f"  [undecidable  ] {name}: {data['error']}")
            continue
        print(f"  [BROKEN {platform}] {name}  ({len(data['hits'])} symbol(s) the SDK does not have)")
        for hit in data["hits"]:
            print(f"        {hit['line']:4d}  {hit['framework']:16s} {hit['symbol']:34s} {hit['text']}")
    print()
    print(f"  {platform}: {len([v for v in report.values() if 'hits' in v])} file(s) would not parse, "
          f"{total} symbol(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
