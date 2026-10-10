#!/usr/bin/env python3
"""Apply the two `#if !os(tvOS)` guards to every report detail page that still needs them.

`HakoCrashReportDetailView` was done by hand first, to check the shape on one file. The other two are
byte-for-byte the same structure at slightly different lines - the `.sheet(isPresented:
$sharePopupPresented` modifier whose `onDismiss` reads `pendingAction`, and the property itself - so this
applies the same two edits and is a no-op on a file that already has them.

`ReportShareAction` is declared under `#if !os(tvOS)` in `ApplicationLibrary/Views/Tools/ReportShared.swift`
(line 135) and `ApplicationLibrary` is built for tvOS, so an unguarded read of it does not compile there.
Wrapping the *modifier* rather than the property alone is what keeps every read inside one condition, which
is the pairing the platform check requires; wrapping the whole span between the two would have hidden the
page itself on tvOS, which is not what the original does.
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
APPLY = "--apply" in sys.argv

FILES = (
    "ApplicationLibrary/Views/HakoStyle/HakoCrashReportDetailView.swift",
    "ApplicationLibrary/Views/HakoStyle/HakoOOMReportDetailView.swift",
    "ApplicationLibrary/Views/HakoStyle/HakoPowerReportDetailView.swift",
)

DECLARATION = "@State private var pendingAction: ReportShareAction?"
DECLARATION_REASON = (
    "    // `#if !os(tvOS)`, as the original has it: `ReportShareAction` is declared under that condition in\n"
    "    // `ApplicationLibrary/Views/Tools/ReportShared.swift:135`, and only the share sheet below reads\n"
    "    // this property.\n"
    "    #if !os(tvOS)\n"
    "        @State private var pendingAction: ReportShareAction?\n"
    "    #endif"
)

SHEET_REASON = (
    "            // `#if !os(tvOS)`, as the original has it. This sheet is the only reader of\n"
    "            // `pendingAction`, so the modifier and the property take the same condition - wrapping\n"
    "            // the property alone would leave the reads here outside it, and wrapping everything\n"
    "            // between them would hide the page itself on tvOS.\n"
    "            #if !os(tvOS)"
)


def main() -> int:
    changed = 0
    for relative in FILES:
        path = os.path.join(ROOT, relative.replace("/", os.sep))
        text = io.open(path, encoding="utf-8").read()
        lines = text.split("\n")
        name = os.path.basename(relative)
        if any(re.match(r"^[ \t]*#if !os\(tvOS\)\s*$", line) for line in lines):
            print(f"  already guarded  {name}")
            continue
        out, edits = [], 0
        index = 0
        while index < len(lines):
            line = lines[index]
            if line.strip() == DECLARATION:
                out.extend(DECLARATION_REASON.split("\n"))
                edits += 1
                index += 1
                continue
            if re.match(r"^[ \t]*\.sheet\(isPresented: \$sharePopupPresented", line):
                out.extend(SHEET_REASON.split("\n"))
                indent = "            "
                # copy the modifier block through its closing brace
                depth = 0
                while index < len(lines):
                    current = lines[index]
                    out.append(current)
                    depth += current.count("{") - current.count("}")
                    index += 1
                    if depth == 0 and current.strip() == "}":
                        break
                out.append(f"{indent}#endif")
                edits += 1
                continue
            out.append(line)
            index += 1
        print(f"  {name}: {edits} edit(s)")
        changed += 1
        if APPLY:
            io.open(path, "w", encoding="utf-8", newline="").write("\n".join(out))
    print()
    print(f"{changed} file(s) {'changed' if APPLY else 'to change'}")
    print("applied" if APPLY else "dry run - pass --apply to write")
    return 0


if __name__ == "__main__":
    sys.exit(main())
