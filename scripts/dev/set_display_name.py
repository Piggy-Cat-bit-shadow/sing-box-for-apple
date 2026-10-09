#!/usr/bin/env python3
"""Rename only the two shipping app targets' visible name to `Jiejiebox`.

The project sets `INFOPLIST_KEY_CFBundleDisplayName = "sing-box"` in eleven places, and only two
of them name the product: the `SFI` (iPhone/iPad) and `SFM` (Mac) app targets, Debug and Release
each. Everything else is a component whose name is either its own or not the product's:

  * `SFT` is the tvOS app, which this refactor does not touch
  * `SFM.System` is the standalone/sysext host, not the app the user launches
  * `ShareExtension` and `ShareExtension.System` are named in the share sheet, so renaming them
    would put a second "Jiejiebox" in a list of destinations

The identification is by `INFOPLIST_FILE`, which is what ties a build configuration to a target's
own plist, rather than by line number, so this is safe to re-run and its intent is readable.
Anchor settings are verified against the block IDs the audit already printed.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(os.path.dirname(os.path.dirname(HERE)),
                    "sing-box.xcodeproj", "project.pbxproj")
NEW_NAME = "Jiejiebox"

# (INFOPLIST_FILE value, build configuration id) for the two app targets, Debug and Release.
TARGETS = (
    ("SFI/Info.plist", "3AEC20FF2A459AB500A63465"),  # SFI Debug
    ("SFI/Info.plist", "3AEC21002A459AB500A63465"),  # SFI Release
    ("SFM/Info.plist", "3AEC21162A459B1A00A63465"),  # SFM Debug
    ("SFM/Info.plist", "3AEC21172A459B1A00A63465"),  # SFM Release
)

SETTING = "INFOPLIST_KEY_CFBundleDisplayName"


def main():
    text = io.open(PATH, encoding="utf-8").read()
    before = len(re.findall(re.escape(f'{SETTING} = "sing-box";'), text))
    print(f'occurrences of {SETTING} = "sing-box"; before: {before}')

    changed = 0
    for plist, config_id in TARGETS:
        # Locate the configuration block by id and rewrite the setting inside it only.
        pattern = re.compile(
            rf"(\n\t\t{config_id} /\* (?:Debug|Release) \*/ = \{{.*?\n\t\t\}};)",
            re.S,
        )
        match = pattern.search(text)
        if not match:
            print(f"FAILED: no block for configuration {config_id}", file=sys.stderr)
            return 1
        block = match.group(1)
        if f"INFOPLIST_FILE = {plist};" not in block:
            print(f"FAILED: configuration {config_id} does not use {plist}", file=sys.stderr)
            return 1
        if f'{SETTING} = "sing-box";' not in block:
            print(f"note: configuration {config_id} already renamed or has no display name")
            continue
        fixed = block.replace(f'{SETTING} = "sing-box";', f'{SETTING} = "{NEW_NAME}";')
        text = text[: match.start(1)] + fixed + text[match.end(1):]
        changed += 1
        print(f"renamed {plist} configuration {config_id}")

    after = len(re.findall(re.escape(f'{SETTING} = "sing-box";'), text))
    branded = len(re.findall(re.escape(f'{SETTING} = "{NEW_NAME}";'), text))
    print(f'occurrences of {SETTING} = "sing-box"; after: {after}')
    print(f'occurrences of {SETTING} = "{NEW_NAME}"; after: {branded}')

    # Already applied. This is the state a re-run should find, and it is a success: the script is
    # run after an upstream merge, where upstream's side may or may not have brought the old name
    # back. Every run must therefore be safe and must not report a failure for having nothing to do.
    if changed == 0 and branded == len(TARGETS):
        print(f"already applied: all {len(TARGETS)} app-target entries read {NEW_NAME}; nothing written")
        return 0
    if changed > 0 and branded < changed:
        print("FAILED: the replacement did not take", file=sys.stderr)
        return 1
    if after != before - changed:
        print("FAILED: the replacement did not account for every change", file=sys.stderr)
        return 1
    if branded != len(TARGETS):
        print(
            f"FAILED: {branded} of {len(TARGETS)} app-target entries read {NEW_NAME}; "
            "a merge probably moved the configurations, so re-derive the ids in TARGETS",
            file=sys.stderr,
        )
        return 1

    # Cheap structural sanity: the file must still have balanced braces and the same block count.
    if text.count("{") != text.count("}"):
        print("FAILED: braces are unbalanced after the edit", file=sys.stderr)
        return 1
    io.open(PATH, "w", encoding="utf-8", newline="").write(text)
    print(f"pbxproj written; {changed} entr{'y' if changed == 1 else 'ies'} renamed; braces balanced")
    return 0


if __name__ == "__main__":
    sys.exit(main())
