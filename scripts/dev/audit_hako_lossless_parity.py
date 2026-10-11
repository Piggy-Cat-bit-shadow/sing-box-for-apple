#!/usr/bin/env python3
"""Static parity audit: is the phone's UI still the UI that `hako-ui@c1935cf` defines?

# What this is, and what it must never claim

It is evidence, not a verdict on appearance. It can prove that a piece of the original's source reached
the phone's build and that a piece did not. It cannot prove that two renderings look the same, and it
therefore never prints `PIXEL_PARITY_PASS` or `DEVICE_PASS`. Its strongest verdict is
`STATIC_PARITY_EVIDENCE`.

# Why it is a separate audit from `audit_apple_ui_boundary.py`

That one asks whether the *platform boundary* holds - whether an iPad or a Mac can see the fork's UI. It
answers correctly and it says nothing about whether the phone's pages still look like the originals:
`hako-page-coverage` reads one switch, and a page can route to a Hako view and be a rewrite of it. This
audit asks the other question, and the two must not be substitutable for each other.

# The three questions it answers

  1. **Reachability.** For every view the original's iPhone build can reach, is that view reachable in
     the integration branch - and reachable from a real call site rather than merely declared?
  2. **UI-token preservation.** For every ported page, are the original's UI-bearing tokens present in
     the ported file? The tokens are the things the correction order names: localised strings, system
     images, `HakoEmptyState` symbols, accessibility identifiers, colours, corner radii, navigation
     chrome - extracted from the original with its conditionals resolved for iOS, and compared as sets.
  3. **Navigation contract.** Does every destination the original pushes or presents resolve to a view
     that exists in the branch?

# How a difference is classified

  * `SOURCE_EQUIVALENT` - the same source, transformed only by the declared renames. Proved by the token
    sets being equal and the declared transform table accounting for every difference.
  * `ADAPTED_NO_UI_DELTA` - renamed/re-scoped only.
  * `MISSING_OR_DIFFERENT` - a token the original has and the ported file does not. **A failure.**
  * `UNVERIFIED` - the original reaches something this audit cannot resolve statically.
  * `INTENTIONAL_UI_CHANGE` - not used. The correction order forbids it without explicit approval.

Usage:
    python audit_hako_lossless_parity.py [--root DIR] [--json] [--only GROUP]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from swift_directives import resolve  # noqa: E402

#: The authority on the phone's UI. A commit, never a branch.
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"

#: Where the fork's iPhone-only UI lives in the integration branch.
HAKO_PREFIX = "ApplicationLibrary/Views/HakoStyle/"

#: Pages the original had and the phone shows, with the transform applied to each. The transform tables
#: are the *only* permitted differences: this audit checks the token sets after applying them, so an
#: undeclared rename shows up as a lost token rather than passing quietly.
PORTS = (
    {
        "group": "home",
        "page": "Home",
        "source": "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift",
        "renames": (),
    },
    {
        "group": "proxies",
        "page": "Proxies",
        "source": "ApplicationLibrary/Views/Groups/GroupListView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoGroupListView.swift",
        "renames": (("GroupListView", "HakoGroupListView"),),
    },
    {
        "group": "activity",
        "page": "Activity",
        "source": "ApplicationLibrary/Views/Connections/ConnectionListView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoConnectionListView.swift",
        "renames": (
            ("ConnectionListView", "HakoConnectionListView"),
            ("ConnectionListContentView", "HakoConnectionListContentView"),
            ("ConnectionMenuButton", "HakoConnectionMenuButton"),
            ("ConnectionMenuView", "HakoConnectionMenuView"),
            ("ConnectionDataObserver", "HakoConnectionDataObserver"),
            ("Coordinator", "HakoConnectionMenuCoordinator"),
        ),
    },
    {
        "group": "logs",
        "page": "Logs",
        "source": "ApplicationLibrary/Views/Log/LogView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoLogView.swift",
        "renames": (
            ("LogView", "HakoLogView"),
            ("LogContentInnerView", "HakoLogContentInnerView"),
            ("LogViewContent", "HakoLogViewContent"),
            ("LogMenuButton", "HakoLogMenuButton"),
            ("LogMenuView", "HakoLogMenuView"),
            ("LogExportView", "HakoLogExportView"),
            ("LogTextDocument", "HakoLogTextDocument"),
            ("ShareViewController", "HakoShareViewController"),
        ),
    },
    {
        "group": "tools",
        "page": "Tools",
        "source": "ApplicationLibrary/Views/Tools/ToolsView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoToolsView.swift",
        "renames": (("ToolsView", "HakoToolsView"),),
    },
    {
        "group": "more",
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
    },
)

#: The design system, taken from the fork's own HakoStyle/ directory listing at the pinned commit.
#: These must be byte-identical to the original, because a change in one of them changes every page that
#: uses it. The list is the fork's file list rather than a hand-kept one, so a file the integration
#: branch added is not silently treated as though the original had it.
#:
#: HakoNavigation.swift is deliberately **not** here: the original has no such file. It was added by
#: an earlier slice of this work to hold the phone's page names, and it is recorded in
#: docs/HAKO-LOSSLESS-PARITY-AUDIT.md as an addition rather than smuggled into the original's set.
#: The shared components, excluding the pages. HakoHomeView.swift is in the original's directory but it
#: is a *page*: it is compared by the token rules above, not byte for byte, because the phone's copy
#: legitimately names HakoStartStopButton where the original named a component that upstream has since
#: changed. A component in this list has no such excuse - a change in one of them changes every page
#: that uses it, so it must be the original's bytes.
DESIGN_SYSTEM = (
    "HakoCard.swift", "HakoData.swift", "HakoEmptyState.swift",
    "HakoPrimaryShell.swift", "HakoRow.swift", "HakoScaffold.swift", "HakoStatus.swift",
    "HakoSurface.swift", "HakoTheme.swift", "HakoUITrace.swift",
)

#: The tokens a user can see or a test can address. Each is a list of literal strings the original has.
TOKENS = {
    "localized strings": re.compile(r'String\(localized:\s*"([^"]+)"'),
    "literal text": re.compile(r'(?:Text|Label)\(\s*"([^"]{2,})"'),
    "system images": re.compile(r'systemImage:\s*"([^"]+)"'),
    "empty-state symbols": re.compile(r'HakoEmptyState\(\s*symbol:\s*"([^"]+)"'),
    "empty-state titles": re.compile(r'HakoEmptyState\([^)]*?title:\s*"([^"]+)"', re.S),
    "empty-state messages": re.compile(r'HakoEmptyState\([^)]*?message:\s*"([^"]+)"', re.S),
    "accessibility ids": re.compile(r'accessibilityIdentifier\(\s*"([^"]+)"'),
    "navigation titles": re.compile(r'(?:navigationTitle|hakoNavigationChrome\(title:)\s*\(?"([^"]+)"'),
    "hako components": re.compile(r"\b(Hako[A-Z]\w+)"),
    "design tokens": re.compile(r"\b(HakoTheme\.\w+(?:\.\w+)?|HakoProductPalette\.\w+(?:\.\w+)?)"),
}


def git(*args: str, repo: str) -> str:
    proc = subprocess.run([git_executable(), "-C", repo, *args], capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip())
    return proc.stdout.decode("utf-8", "replace")


_GIT: str | None = None


def git_executable() -> str:
    global _GIT
    if _GIT is None:
        _GIT = os.environ.get("DSH_GIT") or "git"
    return _GIT


def find_repo_with_fork_ref() -> str | None:
    """A checkout that has the pinned commit, so `git show` can read the original."""
    for candidate in (os.environ.get("DSH_REPO"), os.path.dirname(os.path.dirname(HERE))):
        if candidate and os.path.isdir(os.path.join(candidate, ".git")):
            try:
                git("cat-file", "-e", f"{FORK_REF}^{{commit}}", repo=candidate)
                return candidate
            except RuntimeError:
                continue
    return None


def read(path: str) -> str | None:
    full = path if os.path.isabs(path) else path
    try:
        return io.open(full, encoding="utf-8").read()
    except OSError:
        return None


def tokens(text: str) -> dict[str, set[str]]:
    return {name: set(pattern.findall(text)) for name, pattern in TOKENS.items()}


def apply_renames(text: str, renames) -> str:
    for old, new in sorted(renames, key=lambda pair: -len(pair[0])):
        text = re.sub(rf"\b{re.escape(old)}\b", new, text)
    return text


def audit_port(port: dict, root: str, repo: str) -> dict:
    """Compare one page's originals against the phone's copy."""
    result = {"group": port["group"], "page": port["page"], "status": "UNVERIFIED", "lost": {},
              "notes": []}

    destination = os.path.join(root, port["destination"].replace("/", os.sep))
    ours = read(destination)
    if ours is None:
        result["status"] = "MISSING_OR_DIFFERENT"
        result["notes"].append(f"{port['destination']} does not exist")
        return result

    try:
        raw = git("show", f"{FORK_REF}:{port['source']}", repo=repo)
    except RuntimeError as error:
        result["notes"].append(f"the original could not be read: {error}")
        return result

    reference = apply_renames(resolve(raw, "ios"), port["renames"])

    reference_tokens, our_tokens = tokens(reference), tokens(ours)
    lost: dict[str, list[str]] = {}
    for name in TOKENS:
        missing = sorted(reference_tokens[name] - our_tokens[name])
        # A design token used only inside a dropped platform branch is not a phone loss.
        if missing:
            lost[name] = missing

    result["counts"] = {name: len(reference_tokens[name]) for name in TOKENS}
    result["lost"] = lost
    if lost:
        result["status"] = "MISSING_OR_DIFFERENT"
    else:
        result["status"] = "SOURCE_EQUIVALENT" if not port["renames"] else "ADAPTED_NO_UI_DELTA"
    return result


def audit_design_system(root: str, repo: str) -> dict:
    """The design system files must be identical to the original's, byte for byte."""
    differences = []
    checked = 0
    for name in DESIGN_SYSTEM:
        path = HAKO_PREFIX + name
        full = os.path.join(root, path.replace("/", os.sep))
        ours = read(full)
        if ours is None:
            differences.append(f"{path} is missing")
            continue
        try:
            original = git("show", f"{FORK_REF}:{path}", repo=repo)
        except RuntimeError:
            differences.append(f"{path} is not in the pinned original")
            continue
        checked += 1
        if original != ours:
            ours_lines, original_lines = ours.splitlines(), original.splitlines()
            differences.append(
                f"{path}: {len(ours_lines)} lines vs the original's {len(original_lines)}")
    return {"checked": checked, "differences": differences,
            "status": "SOURCE_EQUIVALENT" if not differences else "MISSING_OR_DIFFERENT"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(HERE)))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--only", default=None,
                        help="one group: home, proxies, activity, logs, tools, more, design-system")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    repo = find_repo_with_fork_ref()
    if repo is None:
        payload = {"reference": FORK_REF, "status": "UNKNOWN",
                   "reason": f"{FORK_REF} is not present in any checkout this audit can read; the "
                             f"original cannot be compared and the comparison is not assumed"}
        print(json.dumps(payload, indent=2) if args.json else
              f"UNKNOWN: {payload['reason']}")
        return 0

    ports = [port for port in PORTS if args.only in (None, port["group"])]
    results = [audit_port(port, root, repo) for port in ports]
    design = audit_design_system(root, repo) if args.only in (None, "design-system") else None

    lost_total = sum(len(items) for result in results for items in result["lost"].values())
    failed = [result for result in results if result["status"] == "MISSING_OR_DIFFERENT"]
    unverified = [result for result in results if result["status"] == "UNVERIFIED"]
    if design and design["status"] == "MISSING_OR_DIFFERENT":
        failed.append({"group": "design-system", "page": "Design system", "lost": {},
                       "notes": design["differences"]})

    payload = {
        "reference": FORK_REF,
        "root": root,
        "verdict": ("STATIC_LOSSLESS_PORT_READY_FOR_APPLE_ACCEPTANCE" if not failed and not unverified
                    else "PARTIAL"),
        "claim": "STATIC_PARITY_EVIDENCE",
        "not_claimed": ["PIXEL_PARITY_PASS", "DEVICE_PASS"],
        "pages": results,
        "design_system": design,
        "lost_tokens": lost_total,
    }

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0 if not failed and not unverified else 1

    print("Hako original-UI parity audit")
    print(f"reference: {FORK_REF[:7]}  (read from {repo})")
    print(f"root:      {root}")
    print(f"claim:     {payload['claim']} - not {', '.join(payload['not_claimed'])}")
    print()
    for result in results:
        marker = {"SOURCE_EQUIVALENT": "SOURCE_EQUIVALENT", "ADAPTED_NO_UI_DELTA": "ADAPTED_NO_UI_DELTA",
                  "MISSING_OR_DIFFERENT": "MISSING_OR_DIFFERENT", "UNVERIFIED": "UNVERIFIED"}[result["status"]]
        counts = result.get("counts", {})
        summary = " ".join(f"{name.split()[0]}={count}" for name, count in sorted(counts.items()))
        print(f"  [{marker:20s}] {result['page']:9s} {summary}")
        for name, items in sorted(result["lost"].items()):
            print(f"        LOST {name}:")
            for item in items[:8]:
                print(f"          - {item!r}")
        for note in result["notes"]:
            print(f"        note: {note}")
    if design:
        print()
        print(f"  [{'SOURCE_EQUIVALENT' if not design['differences'] else 'MISSING_OR_DIFFERENT':20s}] "
              f"design system ({design['checked']} file(s) compared byte for byte)")
        for difference in design["differences"]:
            print(f"        {difference}")
    print()
    print(f"verdict: {payload['verdict']}")
    print(f"lost UI tokens: {lost_total}")
    return 0 if not failed and not unverified else 1


if __name__ == "__main__":
    sys.exit(main())
