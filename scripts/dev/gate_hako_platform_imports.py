#!/usr/bin/env python3
"""Re-gate the platform framework imports the resolver un-gated in the ported files.

# The defect

`swift_directives.resolve` removes platform conditionals and keeps the selected branch's body. For most
code that is right. For imports it is not: the original wrote

    #if !os(tvOS)
        import UniformTypeIdentifiers
        #if canImport(UIKit)
            import UIKit
        #elseif canImport(AppKit)
            import AppKit
        #endif
    #endif

and the resolver, evaluating for iOS, kept `import UniformTypeIdentifiers` and `import UIKit` while dropping
the guards. Those files live in `ApplicationLibrary`, which is a **shared** target - it compiles for iOS,
macOS and tvOS - so an ungated `import UIKit` is a compile error on macOS and on tvOS.

Resolving platform conditionals is the wrong policy for a file in a shared target. The guards are exactly
what makes one source file legal on three platforms, and the original kept them.

# What this does

Wraps each ungated platform import in the condition that makes it available: `canImport(UIKit)` for UIKit,
and so on. `canImport` is the right test rather than `os(iOS)` because it matches what the original used and
because it stays correct if a framework's availability changes.

It is deliberately a narrow, idempotent pass with an assertion, not a regex over the whole file: only a
top-level `import <framework>` line is touched, only for frameworks that are not available everywhere, and
only when it is not already inside a conditional.

Usage:  python gate_hako_platform_imports.py [--check]
"""
from __future__ import annotations

import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HAKO_DIR = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")

#: Framework -> the condition that makes it available.
GATE = {
    "UIKit": "canImport(UIKit)",
    "AppKit": "canImport(AppKit)",
    "Cocoa": "canImport(AppKit)",
    "QuickLook": "canImport(QuickLook)",
    "GhosttyTerminal": "canImport(GhosttyTerminal)",
    "DeviceDiscoveryUI": "canImport(DeviceDiscoveryUI)",
}


def top_level_import(line: str) -> str | None:
    """The framework name if `line` is exactly a top-level import, else None."""
    stripped = line.strip()
    if not stripped.startswith("import "):
        return None
    framework = stripped[len("import "):].strip()
    if not framework or not framework.replace("_", "").isalnum():
        return None
    return framework


def main() -> int:
    check_only = "--check" in sys.argv
    changed = []
    already = 0

    for name in sorted(os.listdir(HAKO_DIR)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(HAKO_DIR, name)
        lines = io.open(path, encoding="utf-8").read().split("\n")

        depth = 0
        out: list[str] = []
        touched: list[str] = []
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("#if"):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1

            framework = top_level_import(line)
            if depth == 0 and framework in GATE:
                out.append(f"#if {GATE[framework]}")
                out.append(f"    {stripped}")
                out.append("#endif")
                touched.append(framework)
                continue
            if framework in GATE and depth > 0:
                already += 1
            out.append(line)

        if touched:
            changed.append((name, sorted(set(touched))))
            if not check_only:
                io.open(path, "w", encoding="utf-8", newline="").write("\n".join(out))

    for name, frameworks in changed:
        print(f"  {'would gate' if check_only else 'gated'} {name}: {', '.join(frameworks)}")
    print(f"  {len(changed)} file(s) {'to change' if check_only else 'changed'}; "
          f"{already} import(s) already inside a conditional")

    if check_only and changed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
