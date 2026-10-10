#!/usr/bin/env python3
"""Port a page from the fork's reference branch into the Hako namespace.

Reads the reference from a **clone of the fork** (the one with an `origin/hako-ui` remote) and writes
into **this checkout**. Both are needed and they are different repositories:

  * `DSH_REPO` - the fork clone the reference is read from through `git show`. Defaults to the sibling
    directory this work is laid out in.
  * `ROOT` - this checkout, which is two levels up from `scripts/dev`.

Set `DSH_GIT` if `git` is not on PATH.

Re-run this after an upstream sync rather than editing the generated pages, or the next port will
disagree with them.
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GIT = os.environ.get("DSH_GIT") or "git"
REPO = os.environ.get("DSH_REPO") or os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "sing-box-for-apple")
ROOT = os.path.dirname(os.path.dirname(HERE))

HEADER = '''//
//  {name}.swift
//  ApplicationLibrary
//
//  The phone's {page} page, from `hako-ui` @ `c1935cf`.
//
//  # Why this is a copy rather than a wrapper
//
//  The reference's change is a rewrite of the page rather than a decoration of it: `{upstream_name}.swift`
//  is {upstream_lines} lines upstream and {fork_lines} in the reference, and the reference version is the
//  page. A wrapper would have had to reimplement it anyway.
//
//  So the page lives here, in the fork's own namespace, reachable only from the phone. Upstream's
//  `{upstream_path}` stays upstream's, which is
//  what keeps an iPad and a Mac on upstream's presentation.
//
//  # What is deliberately not here
//
//  The pages this one leads to. Every one of them is still upstream's: the reference's change to each
//  is a single modifier or a single row, and the page a user lands on is what this slice delivers.
//  The list, with what each needs, is in `docs/HAKO-UI-MIGRATION-MATRIX.md`.
//
//  Generated from `origin/hako-ui` by `scripts/dev/port_tools_and_more.py`. Re-run that after a sync
//  rather than editing here, or the next port will disagree with this file.
//

'''

PAGES = (
    {
        "label": "Tools",
        "page": "Tools",
        "source": "ApplicationLibrary/Views/Tools/ToolsView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoToolsView.swift",
        "renames": (("ToolsView", "HakoToolsView"),),
        "upstream_name": "ToolsView",
    },
    {
        "label": "More",
        "page": "More",
        "source": "ApplicationLibrary/Views/Setting/SettingView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoSettingView.swift",
        "renames": (
            ("SettingView", "HakoSettingView"),
            ("HakoSettingsPush", "HakoSettingsRoute"),
            ("PendingSettingsPageKey", "HakoPendingSettingsPageKey"),
            ("SettingsGroup", "HakoSettingsSectionGroup"),
            ("Destination", "HakoSettingsDestination"),
            ("Decision", "HakoSettingsPushDecision"),
        ),
        "upstream_name": "SettingView",
    },
)


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: "
                         f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def port(page: dict) -> str:
    source = git("show", f"origin/hako-ui:{page['source']}")
    upstream = git("show", f"jiejiebox/integrated:{page['source']}")

    text = source
    for old, new in sorted(page["renames"], key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise SystemExit(f"FAILED [{page['label']}]: {old!r} appears nowhere in the source")
        print(f"    {old} -> {new} ({count})")

    text = re.sub(r"\A(?://[^\n]*\n)+", "", text)
    text = HEADER.format(
        name=os.path.basename(page["destination"])[:-len(".swift")],
        page=page["page"],
        upstream_name=page["upstream_name"],
        upstream_lines=len(upstream.splitlines()),
        fork_lines=len(source.splitlines()),
        upstream_path=page["source"],
    ) + text

    if text.count("{") != text.count("}"):
        raise SystemExit(f"FAILED [{page['label']}]: braces unbalanced")
    if text.count("(") != text.count(")"):
        raise SystemExit(f"FAILED [{page['label']}]: parentheses unbalanced")
    return text


def main() -> int:
    regenerate = "--regenerate" in sys.argv
    for page in PAGES:
        print(f"  [{page['label']}]")
        destination = os.path.join(ROOT, page["destination"].replace("/", os.sep))
        text = port(page)
        if os.path.exists(destination) and not regenerate:
            if io.open(destination, encoding="utf-8").read() != text:
                print("    differs from what this script would write; pass --regenerate",
                      file=sys.stderr)
                return 1
            print(f"    unchanged ({len(text.splitlines())} lines)")
            continue
        io.open(destination, "w", encoding="utf-8", newline="").write(text)
        print(f"    wrote {os.path.relpath(destination, ROOT)}: {len(text.splitlines())} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
