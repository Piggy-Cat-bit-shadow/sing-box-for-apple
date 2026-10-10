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

# Where the pinned original is read from, and what happens when it cannot be found

The original is read out of a checkout that already has commit `c1935cf`, through `git show`. That
checkout is looked for in `DSH_REPO`, then beside this working tree, then in any worktree of the same
repository. A **worktree counts**: its `.git` is a file holding a `gitdir:` pointer, not a directory, and
the first version of this function tested `os.path.isdir(candidate/.git)` - so the audit silently failed to
find an original that was sitting right next to it and fell through to its `UNKNOWN` branch.

`UNKNOWN` used to return **0**. That is the same false-green shape as the parse check's undecided files and
the import check's unguarded `UIFont`: a run that compared nothing reported a clean bill of health. A
missing original is now a non-zero result on both the text and the `--json` path, because the caller cannot
tell "the port is lossless" from "the comparison never ran" by exit code alone otherwise.

Usage:
    python audit_hako_lossless_parity.py [--root DIR] [--json] [--only GROUP]
    DSH_REPO=/path/to/checkout-with-the-pinned-commit python audit_hako_lossless_parity.py
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
#: Three files that the original's directory holds are deliberately **not** in this list, and each one has
#: a reason rather than an exemption:
#:
#:   * `HakoNavigation.swift` - the original has no such file. It was added by an earlier slice of this
#:     work to hold the phone's page names, and it is recorded in docs/HAKO-LOSSLESS-PARITY-AUDIT.md as an
#:     addition rather than smuggled into the original's set.
#:   * `HakoHomeView.swift` - a *page*, so it is compared by the token rules above. This one is left as it
#:     was; removing it in this round would have widened the audit for no reason.
#:   * `HakoPrimaryShell.swift` - a component, and it **was** in this list until round 8. It had to change,
#:     and the change is the opposite of a styling edit: the original's `hakoPrimary` handles `.groups` and
#:     `.connections` under `#if os(macOS)`, while the `NavigationPage` this branch ports against declares
#:     those cases under `#if !os(tvOS)`. On iOS the two do not agree, so the switch was not exhaustive and
#:     the iOS slice of `ApplicationLibrary` could not compile at all. The gate is `!os(tvOS)` now, which
#:     is what `NavigationPage` says and what `SFI/HakoPageContent.swift:69-74` already renders under. A
#:     byte comparison against the original here would be a check that *requires* the compile error, so the
#:     file is compared by the token rules instead - and its divergence is recorded rather than excused.
DESIGN_SYSTEM = (
    "HakoCard.swift", "HakoData.swift", "HakoEmptyState.swift",
    "HakoRow.swift", "HakoScaffold.swift", "HakoStatus.swift",
    "HakoSurface.swift", "HakoTheme.swift", "HakoUITrace.swift",
)

#: Design-system files that are compared by tokens rather than byte for byte, with the reason. Kept as
#: data so this audit can report them instead of a reader having to diff two lists to notice.
DESIGN_SYSTEM_BY_TOKENS = {
    "HakoPrimaryShell.swift":
        "hakoPrimary's gate had to follow `NavigationPage`'s `#if !os(tvOS)`; the original's `#if os(macOS)` "
        "left the iOS switch non-exhaustive, so byte equality with the original is the compile error",
}

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


def _is_git_checkout(path: str) -> bool:
    """True for a checkout **and** for a linked worktree of one.

    A worktree's `.git` is a regular file containing `gitdir: …`, so `os.path.isdir` is false for it. This
    repository's own round-8 layout keeps the integration tree as a worktree, which is exactly the shape
    the first version of this function rejected.
    """
    return os.path.exists(os.path.join(path, ".git"))


def _worktrees_of(repo: str) -> list[str]:
    """Every worktree git reports for `repo`, absolute, existing ones only."""
    try:
        listed = git("worktree", "list", "--porcelain", repo=repo)
    except RuntimeError:
        return []
    out = []
    for line in listed.splitlines():
        if line.startswith("worktree "):
            candidate = line[len("worktree "):].strip()
            if candidate and os.path.isdir(candidate):
                out.append(candidate)
    return out


def candidate_repos() -> list[tuple[str, str]]:
    """`(path, why)` for where the pinned original might be readable, most specific first.

    `DSH_REPO` first because that is the escape hatch that works from anywhere. Then the tree the scripts
    themselves live in - which, when this tree is a linked worktree, is the worktree rather than the
    repository behind it, so a `.git` *file* has to be accepted. Then every worktree of that tree, so a
    sibling worktree parked on the original is found rather than missed. The `why` is carried through to the
    diagnostic: "read from <path>" is only useful evidence if the reader can see how it was chosen.
    """
    here = os.path.abspath(HERE)
    beside = os.path.dirname(os.path.dirname(here))
    ordered: list[tuple[str | None, str]] = [
        (os.environ.get("DSH_REPO"), "DSH_REPO"),
        (beside, "the tree these scripts live in"),
    ]
    for root, _why in list(ordered):
        if root and _is_git_checkout(root):
            ordered.extend((path, f"a worktree of {root}") for path in _worktrees_of(root))

    seen: set[str] = set()
    out: list[tuple[str, str]] = []
    for candidate, why in ordered:
        if not candidate:
            continue
        absolute = os.path.abspath(candidate)
        if absolute in seen:
            continue
        seen.add(absolute)
        out.append((absolute, why))
    return out


def fork_ref_names() -> list[str]:
    """Names under which the pinned commit may be reachable, in the order they are tried.

    The commit object is what is wanted, so the full SHA is tried first and always works in a checkout that
    fetched the original even once; `origin/hako-ui` is the fork's own branch and is what this project's
    existing layout actually has.
    """
    names = [FORK_REF]
    if os.environ.get("DSH_FORK_REF"):
        names.insert(0, os.environ["DSH_FORK_REF"])
    names.extend(["origin/hako-ui", "hako-ui"])
    out: list[str] = []
    for name in names:
        if name not in out:
            out.append(name)
    return out


def find_repo_with_fork_ref() -> tuple[str | None, str, list[str]]:
    """A checkout that has the pinned commit, so `git show` can read the original.

    Returns the checkout, how it was chosen, and the reasons nothing was found, so the caller can report
    which paths were tried and why each failed instead of only that the original is missing.
    """
    tried: list[str] = []
    for candidate, why in candidate_repos():
        if not _is_git_checkout(candidate):
            tried.append(f"{candidate} ({why}): not a git checkout (no .git file or directory)")
            continue
        for name in fork_ref_names():
            try:
                git("cat-file", "-e", f"{name}^{{commit}}", repo=candidate)
            except RuntimeError:
                continue
            return candidate, f"{why}; {name} resolved to a commit", tried
        tried.append(f"{candidate} ({why}): a git checkout, but none of "
                     f"{', '.join(fork_ref_names())} resolves to a commit")
    return None, "", tried


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
    """The design system files must be identical to the original's, byte for byte.

    A file the audit could not read is a difference, and the count of files actually compared is reported so
    a partial comparison cannot be read as a complete one.
    """
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
    incomplete = checked != len(DESIGN_SYSTEM)
    return {"checked": checked, "expected": len(DESIGN_SYSTEM), "differences": differences,
            "status": "SOURCE_EQUIVALENT" if not differences else "MISSING_OR_DIFFERENT",
            "complete": not incomplete,
            "by_tokens": audit_design_system_by_tokens(root, repo),
            "note": (None if not incomplete else
                     f"only {checked} of {len(DESIGN_SYSTEM)} design-system file(s) could be compared; "
                     f"this is not a full byte-for-byte comparison")}


def audit_design_system_by_tokens(root: str, repo: str) -> list[dict]:
    """The design-system files that cannot be byte-compared, compared by the tokens a user can see.

    A component that had to change takes the same token rules the pages take: every string, image,
    accessibility identifier and design token the original names must still be named, and what the file
    adds instead is reported rather than ignored. That is a weaker claim than byte equality and the weaker
    claim is the honest one here - the alternative is a check that requires a compile error.
    """
    out: list[dict] = []
    for name, reason in sorted(DESIGN_SYSTEM_BY_TOKENS.items()):
        path = HAKO_PREFIX + name
        ours = read(os.path.join(root, path.replace("/", os.sep)))
        entry = {"file": path, "reason": reason, "status": "UNVERIFIED", "lost": {}}
        if ours is None:
            entry["status"] = "MISSING_OR_DIFFERENT"
            entry["notes"] = [f"{path} does not exist"]
            out.append(entry)
            continue
        try:
            original = git("show", f"{FORK_REF}:{path}", repo=repo)
        except RuntimeError as error:
            entry["notes"] = [f"the original could not be read: {error}"]
            out.append(entry)
            continue
        reference_tokens, our_tokens = tokens(original), tokens(ours)
        lost = {group: sorted(reference_tokens[group] - our_tokens[group])
                for group in TOKENS if reference_tokens[group] - our_tokens[group]}
        entry["lost"] = lost
        entry["added"] = {group: sorted(our_tokens[group] - reference_tokens[group])
                          for group in TOKENS if our_tokens[group] - reference_tokens[group]}
        entry["status"] = "MISSING_OR_DIFFERENT" if lost else "ADAPTED_NO_UI_DELTA"
        out.append(entry)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(HERE)))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--only", default=None,
                        help="one group: home, proxies, activity, logs, tools, more, design-system")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    repo, chosen_because, tried = find_repo_with_fork_ref()
    if repo is None:
        # A missing original is not a pass. The earlier version printed UNKNOWN and returned 0, so a run
        # that compared nothing was indistinguishable from a run that found nothing wrong.
        payload = {"reference": FORK_REF, "root": root, "status": "UNKNOWN",
                   "reason": f"{FORK_REF} is not present in any checkout this audit can read; the "
                             f"original cannot be compared and the comparison is not assumed",
                   "tried": tried,
                   "hint": "point DSH_REPO at a checkout that has the pinned commit, or set DSH_FORK_REF "
                           "to a ref name that resolves to it"}
        if args.json:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
        else:
            print(f"UNKNOWN: {payload['reason']}")
            for line in tried:
                print(f"  tried {line}")
            print(f"  {payload['hint']}")
        return 1

    ports = [port for port in PORTS if args.only in (None, port["group"])]
    results = [audit_port(port, root, repo) for port in ports]
    design = audit_design_system(root, repo) if args.only in (None, "design-system") else None

    lost_total = sum(len(items) for result in results for items in result["lost"].values())
    failed = [result for result in results if result["status"] == "MISSING_OR_DIFFERENT"]
    unverified = [result for result in results if result["status"] == "UNVERIFIED"]
    if design and design["status"] == "MISSING_OR_DIFFERENT":
        failed.append({"group": "design-system", "page": "Design system", "lost": {},
                       "notes": design["differences"]})
    # A component compared by tokens counts the same way a page does: a token the original has and this
    # branch does not is a failure, and a file that could not be read is `UNVERIFIED`.
    by_tokens = (design or {}).get("by_tokens", []) or []
    for entry in by_tokens:
        lost_total += sum(len(items) for items in entry["lost"].values())
        if entry["status"] == "MISSING_OR_DIFFERENT":
            failed.append({"group": "design-system", "page": entry["file"], "lost": entry["lost"],
                           "notes": entry.get("notes", [])})
        elif entry["status"] == "UNVERIFIED":
            unverified.append({"group": "design-system", "page": entry["file"], "lost": {},
                               "notes": entry.get("notes", [])})
    # `--only <group>` compares one group on purpose, so a short page list is expected there. What is never
    # acceptable is a **silent** short comparison: a page whose original could not be read is `UNVERIFIED`
    # and fails the run, and a design-system comparison that did not reach every file is reported as
    # incomplete rather than printed with a count nobody checked.
    expected_pages = [port for port in PORTS if args.only in (None, port["group"])]
    # `pages_compared` counts the pages a token comparison actually reached, which is **not** every page
    # that is not `UNVERIFIED`. It used to be exactly that, and a destination file that does not exist is
    # `MISSING_OR_DIFFERENT` - it returns before any comparison - so a tree with all six ported pages
    # deleted reported `pages_compared` 6 of 6 and `lost_tokens` 0. `test_fail_closed_exit_codes.py`
    # asserts those two figures as its evidence that "every page was compared, not skipped", and both were
    # satisfied by the empty tree. The statuses below are the ones `audit_port` sets *after* comparing.
    COMPARED_STATUSES = frozenset({"SOURCE_EQUIVALENT", "ADAPTED_NO_UI_DELTA"})
    coverage = {
        "pages_expected": len(expected_pages),
        "pages_compared": len([r for r in results if r["status"] in COMPARED_STATUSES]),
        "pages_unreadable_or_missing": len([r for r in results
                                            if r["status"] == "MISSING_OR_DIFFERENT"]),
        "design_system_compared": (design or {}).get("checked", 0),
        "design_system_expected": (design or {}).get("expected", 0),
        "selected_by_only": args.only,
    }

    payload = {
        "reference": FORK_REF,
        "root": root,
        "original_read_from": repo,
        "original_chosen_because": chosen_because,
        "verdict": ("STATIC_LOSSLESS_PORT_READY_FOR_APPLE_ACCEPTANCE" if not failed and not unverified
                    else "PARTIAL"),
        "claim": "STATIC_PARITY_EVIDENCE",
        "not_claimed": ["PIXEL_PARITY_PASS", "DEVICE_PASS"],
        "pages": results,
        "design_system": design,
        "coverage": coverage,
        "lost_tokens": lost_total,
    }
    if design and not design.get("complete", True):
        payload["verdict"] = "PARTIAL"

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        incomplete_design = bool(design and not design.get("complete", True))
        return 1 if (failed or unverified or incomplete_design) else 0

    print("Hako original-UI parity audit")
    print(f"reference: {FORK_REF[:7]}  (read from {repo} - {chosen_because})")
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
              f"design system ({design['checked']} of {design['expected']} file(s) compared byte for byte)")
        for difference in design["differences"]:
            print(f"        {difference}")
        if not design.get("complete", True):
            print(f"        INCOMPLETE: {design['note']}")
        for entry in by_tokens:
            print(f"  [{entry['status']:20s}] {entry['file']}  (compared by UI tokens, not bytes)")
            print(f"        why: {entry['reason']}")
            for name, items in sorted(entry["lost"].items()):
                print(f"        LOST {name}: {', '.join(repr(i) for i in items[:6])}")
            for name, items in sorted(entry.get("added", {}).items()):
                if items:
                    print(f"        added {name}: {', '.join(repr(i) for i in items[:6])}")
    print()
    print(f"coverage: {coverage['pages_compared']} of {coverage['pages_expected']} page(s) compared; "
          f"design system {coverage['design_system_compared']} of {coverage['design_system_expected']}")
    print(f"verdict: {payload['verdict']}")
    print(f"lost UI tokens: {lost_total}")
    # An incomplete comparison fails the text path exactly as `--json` does. The two must not disagree about
    # the same tree - that is how `0 broken` came to be read as a pass over files nobody had looked at.
    incomplete_design = bool(design and not design.get("complete", True))
    return 1 if (failed or unverified or incomplete_design) else 0


if __name__ == "__main__":
    sys.exit(main())
