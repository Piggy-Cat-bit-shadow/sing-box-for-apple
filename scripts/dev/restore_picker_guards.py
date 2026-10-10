#!/usr/bin/env python3
"""Restore two file-level platform guards the migration resolved away in the Appearance flow.

Neither file is regenerated: both carry deliberate post-migration edits (a renamed nested enum in one, a
re-gated navigation modifier in the other), so rebuilding them from the original would throw that work away.
The guards go back in place, and nothing else is touched.

The guard is load-bearing in both cases, for the same reason stated twice: `ApplicationLibrary` is one
framework target built for `iphoneos`, `macosx` and `appletvos`, so a declaration that reads a module or a
type another platform does not provide stops that platform building.

  * `HakoThemePickerView.swift` - the original is wrapped in `#if canImport(GhosttyTerminal)`, and
    `GhosttyTheme` carries `platformFilters = (ios, macos, )` in the project file. The port declares
    `[GhosttyThemeDefinition]` and calls `GhosttyThemeCatalog.allThemes` with no condition around them.
  * `HakoFontPickerView.swift` - the original is wrapped in `#if !os(tvOS)`, and inside it the `@State`
    group is wrapped in `#if os(iOS)` because `ImportedFontStore` is declared inside `#if os(iOS)`
    (`Library/Shared/ImportedFontStore.swift:1-151`). The port kept both the property and the type
    reference with neither guard.
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
APPLY = "--apply" in sys.argv

THEME = "ApplicationLibrary/Views/HakoStyle/HakoThemePickerView.swift"
FONT = "ApplicationLibrary/Views/HakoStyle/HakoFontPickerView.swift"


def indent(block: str) -> str:
    """Indent every non-empty line of `block` by four spaces."""
    return "\n".join(("    " + line) if line.strip() else line for line in block.split("\n"))


def wrap_whole_file(text: str, condition: str, why: str) -> tuple[str, bool]:
    """Wrap everything after the header comment in `#if <condition>` … `#endif`."""
    lines = text.split("\n")
    start = 0
    while start < len(lines) and (lines[start].startswith("//") or lines[start].strip() == ""):
        start += 1
    header, body = lines[:start], lines[start:]
    if any(re.match(rf"^[ \t]*#if\s+{re.escape(condition)}\s*$", line) for line in lines):
        return text, False
    body = [line for line in body if line.strip() != ""]
    new = (header
           + [f"//  {why}", "//", f"#if {condition}"]
           + indent("\n".join(body)).split("\n")
           + ["#endif", ""])
    return "\n".join(new), True


def restore_state_block(text: str, why: str) -> tuple[str, bool]:
    """Wrap the `@State` group that reads `ImportedFontStore` in the original's `#if os(iOS)`."""
    lines = text.split("\n")
    first = next((i for i, line in enumerate(lines)
                  if "fontStore = ImportedFontStore.shared" in line), None)
    if first is None:
        return text, False
    if any(re.match(r"^[ \t]*#if os\(iOS\)\s*$", line) for line in lines[max(0, first - 6):first]):
        return text, False
    last = next((i for i in range(first, len(lines)) if "editMode: EditMode = .inactive" in lines[i]), None)
    if last is None:
        return text, False
    column = re.match(r"[ \t]*", lines[first]).group(0)
    guard = [
        f"{column}// {why}",
        f"{column}#if os(iOS)",
    ]
    closing = [f"{column}#endif"]
    added = guard + lines[first:last + 1] + closing
    new = lines[:first] + added + lines[last + 1:]
    return "\n".join(new), True


def main() -> int:
    results = []

    theme_path = os.path.join(ROOT, THEME.replace("/", os.sep))
    theme = io.open(theme_path, encoding="utf-8").read()
    theme_new, theme_changed = wrap_whole_file(
        theme, "canImport(GhosttyTerminal)",
        "The file-level `#if canImport(GhosttyTerminal)` is the original's and is load-bearing: "
        "`GhosttyTheme` carries `platformFilters = (ios, macos, )` in `sing-box.xcodeproj/project.pbxproj`, "
        "so it is not linked for tvOS, and this file reads `GhosttyThemeDefinition` and "
        "`GhosttyThemeCatalog` unconditionally. Restored by `scripts/dev/restore_picker_guards.py`; the "
        "nested enum's rename to `HakoScheme` is this fork's and is kept.")
    results.append((THEME, theme_changed))
    if APPLY and theme_changed:
        io.open(theme_path, "w", encoding="utf-8", newline="").write(theme_new)

    font_path = os.path.join(ROOT, FONT.replace("/", os.sep))
    font = io.open(font_path, encoding="utf-8").read()
    font, font_changed = wrap_whole_file(
        font, "!os(tvOS)",
        "The file-level `#if !os(tvOS)` is the original's. Inside it, the `#if os(iOS)` around the `@State` "
        "group is the original's too and is load-bearing: `ImportedFontStore` is declared inside "
        "`#if os(iOS)` (`Library/Shared/ImportedFontStore.swift:1-151`), so a port that reads it outside that "
        "block asks the macOS compiler to resolve a type macOS does not declare. The original cannot hit "
        "this - its `init` assigns `_selected` and nothing else. Restored by "
        "`scripts/dev/restore_picker_guards.py`; the `#if !os(macOS)` this fork added around "
        "`.navigationBarTitleDisplayMode` in commit 28e4c84 is kept.")
    font, state_changed = restore_state_block(
        font,
        "`ImportedFontStore` is declared inside `#if os(iOS)`; the original guarded this group for the "
        "same reason.")
    results.append((FONT, font_changed or state_changed))
    if APPLY and (font_changed or state_changed):
        io.open(font_path, "w", encoding="utf-8", newline="").write(font)

    for path, changed in results:
        print(f"  {'changed' if changed else 'already correct'}  {path}")
    print()
    print("applied" if APPLY else "dry run - pass --apply to write")
    return 0


if __name__ == "__main__":
    sys.exit(main())
