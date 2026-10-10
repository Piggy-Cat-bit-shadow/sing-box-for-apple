#!/usr/bin/env python3
"""Rebuild two ported files from their originals' own bytes, changing only the names.

Both files lost a **file-level** platform guard and, with it, the impression that they are a port at all:

  * `HakoStyle/HakoThemePickerView.swift` - the original is wrapped in
    `#if canImport(GhosttyTerminal)` (line 1) and imports `GhosttyTheme` inside it. That module carries
    `platformFilters = (ios, macos, )` in the project file, so it is not linked for tvOS; the port declares
    `GhosttyThemeDefinition`-typed stored properties with no condition around them, in a file
    `ApplicationLibrary` compiles for tvOS.
  * `HakoStyle/HakoFontPickerView.swift` - the original is wrapped in `#if !os(tvOS)` (line 1) and wraps a
    group of `@State` properties, one of them `ImportedFontStore.shared`, in `#if os(iOS)`. `ImportedFontStore`
    is declared inside `#if os(iOS)` (`Library/Shared/ImportedFontStore.swift:1-151`), so the port declares a
    stored property whose type macOS does not have. The original cannot hit this: `FontPickerView.init`
    assigns `_selected` and nothing else.

Editing the guards back into the resolved copies is what produced a nested duplicate `#if` and a wrongly
indented block the last time it was tried, so this goes the other way, as
`restore_terminal_guards.py` does: take the original exactly as `hako-ui` wrote it - guards, indentation and
all - and apply only the renames.
"""
from __future__ import annotations

import difflib
import io
import os
import subprocess
import sys

GIT = os.environ.get("DSH_GIT") or r"C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe"
UPSTREAM_TREE = r"C:\Deepseek\IOS客户端\_work\refs\up-hako"
ROOT = r"C:\Deepseek\IOS客户端\_work\r8\w-main"

JOBS = (
    {
        "source": "ApplicationLibrary/Views/Terminal/ThemePickerView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoThemePickerView.swift",
        "renames": (("ThemePickerView", "HakoThemePickerView"),),
        "why": (
            "The file-level `#if canImport(GhosttyTerminal)` is the original's and is load-bearing: "
            "`GhosttyTheme` carries `platformFilters = (ios, macos, )` in `sing-box.xcodeproj/project.pbxproj`, "
            "so it is not linked for tvOS, and this file declares `GhosttyThemeDefinition`-typed stored "
            "properties in a target `ApplicationLibrary` builds for tvOS as well."
        ),
        "applier": "scripts/dev/restore_theme_picker_guards.py",
    },
    {
        "source": "ApplicationLibrary/Views/Setting/FontPickerView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoFontPickerView.swift",
        "renames": (("FontPickerView", "HakoFontPickerView"),),
        "why": (
            "The file-level `#if !os(tvOS)` is the original's, and inside it the `#if os(iOS)` around the "
            "`@State` group is load-bearing too: `ImportedFontStore` is declared inside `#if os(iOS)` "
            "(`Library/Shared/ImportedFontStore.swift:1-151`), so a port that keeps "
            "`@StateObject private var fontStore = ImportedFontStore.shared` outside that block asks the "
            "macOS compiler to resolve a type macOS does not declare. The original cannot hit this - its "
            "`init` assigns `_selected` and nothing else."
        ),
        "applier": "scripts/dev/restore_font_picker_guards.py",
    },
)


def main() -> int:
    apply = "--apply" in sys.argv
    checked = 0
    for job in JOBS:
        proc = subprocess.run([GIT, "-C", UPSTREAM_TREE, "show", f"HEAD:{job['source']}"],
                              capture_output=True)
        if proc.returncode != 0:
            sys.exit(f"cannot read {job['source']}: {proc.stderr.decode('utf-8', 'replace')}")
        original = proc.stdout.decode("utf-8")
        text = original
        for old, new in sorted(job["renames"], key=lambda pair: -len(pair[0])):
            text = text.replace(old, new)
        # The design system's names are the only other spelling the port needs.
        text = text.replace("HakoProductPalette", "HakoProductPalette")
        if job["renames"][0][1] not in text:
            sys.exit(f"FAILED: the rename did not apply for {job['destination']}")

        header = (
            f"//\n//  {os.path.basename(job['destination'])}\n//  ApplicationLibrary\n//\n"
            f"//  The phone's copy of `{job['source']}`, from `hako-ui` @ `c1935cf`.\n//\n"
            f"//  {job['why']}\n//\n"
            f"//  Derived from that original by `{job['applier']}`, which applies the rename and nothing\n"
            f"//  else - the guards, the indentation and the body are the original's own bytes.\n//\n"
        )
        out = header + "\n" + text
        if not out.endswith("\n"):
            out += "\n"

        full = os.path.join(ROOT, job["destination"].replace("/", os.sep))
        previous = io.open(full, encoding="utf-8").read()
        differs = previous != out
        print(f"== {job['destination']}")
        print(f"   changes: {differs}")
        if differs:
            added = [l for l in difflib.unified_diff(previous.splitlines(), out.splitlines(),
                                                     lineterm="", n=0) if l.startswith("+")
                     and not l.startswith("+++")]
            removed = [l for l in difflib.unified_diff(previous.splitlines(), out.splitlines(),
                                                       lineterm="", n=0) if l.startswith("-")
                       and not l.startswith("---")]
            print(f"   +{len(added)} -{len(removed)}")
            for line in added[:4]:
                print(f"     {line[:110]}")
            if apply:
                io.open(full, "w", encoding="utf-8", newline="").write(out)
                checked += 1
        print()
    print(f"{checked} file(s) {('written' if apply else 'would be written')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
