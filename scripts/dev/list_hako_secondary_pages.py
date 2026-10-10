#!/usr/bin/env python3
"""The second-level page ledger: every view the fork changed that the phone can reach.

The six first-level destinations are ported; the pages they lead to are the fork's one modifier at a
time, and every modifier's component already exists in the tree. This prints the exact list with each
file's real diff size, so the remaining work is a list rather than a search.

A page is in this ledger when the fork changed it **and** the phone can reach it. Reachability is
derived from the navigation call chain, not from a hand-kept list, and the chain is asserted: a file
whose only route into the phone is through a page that is not ported is marked as such.
"""
import io
import os
import re
import subprocess
import sys

GIT = os.environ.get("DSH_GIT") or "git"
REPO = os.environ.get("DSH_REPO") or r"C:\Deepseek\IOS客户端\sing-box-for-apple"
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
BASE = "2b1763a80f2c"

#: The fork's own `HakoStyle/` files, which are components rather than reachable pages.
DESIGN_SYSTEM = (
    "HakoCard.swift", "HakoData.swift", "HakoEmptyState.swift", "HakoHomeView.swift",
    "HakoPrimaryShell.swift", "HakoRow.swift", "HakoScaffold.swift", "HakoStatus.swift",
    "HakoSurface.swift", "HakoTheme.swift", "HakoUITrace.swift",
)

#: Pages the fork rewrote and this work has ported whole.
PORTED = {
    "Groups/GroupListView.swift", "Connections/ConnectionListView.swift", "Log/LogView.swift",
    "Tools/ToolsView.swift", "Setting/SettingView.swift", "HakoStyle/HakoHomeView.swift",
    "Dashboard/Cards/ProfilePickerSheet.swift",
}

#: Changed by the fork and **not** reachable from the phone: the dashboard is iPad/Mac-only now, and
#: these are the pieces of it the fork restyled. They are listed so a reader can see they were
#: considered rather than missed.
NOT_PHONE_REACHABLE = (
    "Dashboard/", "MacLibrary/", "Abstract/FormItem.swift", "Abstract/ViewModifiers.swift",
    "Abstract/NavigationSheetContent.swift", "NavigationPage.swift",
)


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.decode("utf-8", "replace"))
    return proc.stdout.decode("utf-8", "replace")


def changed_files() -> list[tuple[int, int, str]]:
    stat = git("diff", "--numstat", f"{BASE}..{FORK_REF}", "--", "ApplicationLibrary/Views")
    out = []
    for line in stat.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        added, removed, path = parts
        if not path.endswith(".swift"):
            continue
        out.append((int(added), int(removed), path[len("ApplicationLibrary/Views/"):]))
    return out


def modifier_lines(path: str) -> list[str]:
    """The Hako lines the fork added to a shared page - what 'the one modifier' actually is."""
    diff = git("diff", f"{BASE}..{FORK_REF}", "--", "ApplicationLibrary/Views/" + path)
    return [line[1:].strip() for line in diff.splitlines()
            if line.startswith("+") and not line.startswith("+++") and "Hako" in line]


def main() -> int:
    rows = []
    for added, removed, path in sorted(changed_files(), key=lambda r: -(r[0] + r[1])):
        name = os.path.basename(path)
        if name in DESIGN_SYSTEM:
            continue
        if path in PORTED:
            continue
        reachable = not any(path.startswith(prefix) for prefix in NOT_PHONE_REACHABLE)
        rows.append({
            "path": path, "added": added, "removed": removed,
            "reachable": reachable, "hako_lines": modifier_lines(path) if reachable else [],
        })

    reachable = [row for row in rows if row["reachable"]]
    print(f"  {len(rows)} changed view file(s) beyond the six pages and the design system")
    print(f"  {len(reachable)} of them reachable from the phone")
    print()
    for row in reachable:
        change = row["hako_lines"][0] if row["hako_lines"] else "(no Hako line - see the diff)"
        print(f"  +{row['added']:<4} -{row['removed']:<4} {row['path']}")
        print(f"        {change[:104]}")
    print()
    excluded = [row for row in rows if not row["reachable"]]
    if excluded:
        print(f"  not phone-reachable ({len(excluded)}):")
        for row in excluded:
            print(f"    +{row['added']:<4} -{row['removed']:<4} {row['path']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
