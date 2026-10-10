#!/usr/bin/env python3
"""Wrap both `exportProfile` functions in `HakoProfilePickerSheet.swift` in `#if !os(tvOS)`.

Two identical functions live in two inner types, which is why matching the text once failed: the insert has
to be positional. Each is wrapped from its own `private func exportProfile(type: ExportItemType) {` line to
the `}` that closes it, and the insertions are applied **bottom-up** so the line numbers of the earlier one
do not move while the later one is handled.

The first attempt walked the file top-down and re-found the function it had just wrapped, which is an
infinite loop; that process was killed before it wrote, and the file was restored from HEAD. This one
asserts the count it expects before touching anything, and refuses rather than guessing.
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
APPLY = "--apply" in sys.argv
FILE = "ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift"

SIGNATURE = re.compile(r"^([ \t]*)private func exportProfile\(type: ExportItemType\) \{\s*$")
REASON = (
    "{indent}// `#if !os(tvOS)`, as the original has it (`up-hako@c1935cf\n"
    "{indent}// .../Dashboard/Cards/ProfilePickerSheet.swift:942-1036`): this function exists to build a\n"
    "{indent}// `ProfileAnyExportDocument`, which is declared under that condition, and it writes the state\n"
    "{indent}// pair guarded the same way above it."
)


def find_functions(lines: list[str]) -> list[tuple[int, int, str]]:
    """(start, end, indent) for each `exportProfile` declaration, end being its closing brace."""
    found = []
    for index, line in enumerate(lines):
        match = SIGNATURE.match(line)
        if not match:
            continue
        indent, depth, end = match.group(1), 0, index
        for probe in range(index, len(lines)):
            depth += lines[probe].count("{") - lines[probe].count("}")
            if depth == 0 and probe > index:
                end = probe
                break
        found.append((index, end, indent))
    return found


def main() -> int:
    path = os.path.join(ROOT, FILE.replace("/", os.sep))
    lines = io.open(path, encoding="utf-8").read().split("\n")

    functions = find_functions(lines)
    print(f"  `exportProfile` declarations found: {len(functions)} "
          f"(at {', '.join(str(start + 1) for start, _, _ in functions)})")
    if len(functions) != 2:
        print(f"  REFUSING: expected 2 declarations, found {len(functions)}")
        return 1

    for start, end, indent in sorted(functions, reverse=True):
        guard = [line.replace("{indent}", indent) for line in REASON.split("\n")]
        lines = (lines[:start]
                 + guard
                 + [f"{indent}#if !os(tvOS)"]
                 + lines[start:end + 1]
                 + [f"{indent}#endif"]
                 + lines[end + 1:])

    after = find_functions(lines)
    guarded = sum(1 for start, _, _ in after
                  if "#if !os(tvOS)" in "\n".join(lines[max(0, start - 6):start]))
    print(f"  declarations wrapped: {guarded} of {len(after)}")
    if guarded != 2:
        print("  REFUSING: an insertion did not land where it was meant to")
        return 1

    if APPLY:
        io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
        print("  applied")
    else:
        print("  dry run - pass --apply to write")
    return 0


if __name__ == "__main__":
    sys.exit(main())
