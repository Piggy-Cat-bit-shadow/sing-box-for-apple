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

# Why `--regenerate` alone no longer overwrites

The candidate this script computes is a fresh function of the pinned upstream text; the file on disk is the
product of the last run **plus every human repair since**. Regenerating over those repairs silently reverts
them - the platform guards and the renamed call sites this round restored come back spelled the upstream
way - with exit status 0, and `audit_hako_lossless_parity.py` does not notice, because a deleted guard does
not change the set of UI tokens. So an existing, differing target now has to be authorized by name and by
blob, exactly as `migrate_secondary_page.py` requires; see `_safety_gate.OverwriteAuthorization`.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from _safety_gate import OverwriteAuthorization, plan_writes  # noqa: E402

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
//  The reference's change to this page is a rewrite, not a decoration: `{upstream_name}.swift` is
//  {upstream_lines} lines upstream and {fork_lines} in the reference, and the reference version is the page. A
//  wrapper would have had to reimplement it anyway.
//
//  So the page lives here, in the fork's own namespace, and it is reachable only from the phone. The
//  upstream file at `{upstream_path}`
//  is untouched, which is what keeps an iPad and a Mac on upstream's presentation.
//
//  # What is shared
//
//  The view model, the command client and the connection model are upstream's, unchanged. The fork's
//  page reads `{view_model}` exactly as upstream's page does; nothing about the data or the command-client
//  subscription is forked.
//
//  Generated from `origin/hako-ui` by `scripts/dev/port_hako_pages.py`. Re-run that after a sync
//  rather than editing here, or the next port will disagree with this file.
//

'''

PAGES = (
    {
        "label": "Groups",
        "page": "Proxies",
        "source": "ApplicationLibrary/Views/Groups/GroupListView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoGroupListView.swift",
        "renames": (("GroupListView", "HakoGroupListView"),),
        "upstream_name": "GroupListView",
    },
    {
        "label": "Connections",
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
        "upstream_name": "ConnectionListView",
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

    # Renames, longest first, so `ConnectionListView` is not replaced inside
    # `HakoConnectionListView` by a later rule.
    text = source
    for old, new in sorted(page["renames"], key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise SystemExit(f"FAILED [{page['label']}]: {old!r} appears nowhere in the source")
        print(f"    {old} -> {new} ({count})")

    # The reference file's own header comments name the reference; the new header replaces them.
    text = re.sub(r"\A(?://[^\n]*\n)+", "", text)

    text = HEADER.format(
        name=os.path.basename(page["destination"])[:-len(".swift")],
        page=page["page"],
        upstream_name=page["upstream_name"],
        upstream_lines=len(upstream.splitlines()),
        fork_lines=len(source.splitlines()),
        upstream_path=page["source"],
        view_model=("GroupListViewModel" if page["label"] == "Groups" else "ConnectionListViewModel"),
    ) + text

    if text.count("{") != text.count("}"):
        raise SystemExit(f"FAILED [{page['label']}]: braces unbalanced")
    return text


def main() -> int:
    regenerate = "--regenerate" in sys.argv
    guard = OverwriteAuthorization(sys.argv)
    items = []
    for page in PAGES:
        destination = os.path.join(ROOT, page["destination"].replace("/", os.sep))
        print(f"  [{page['label']}]")
        items.append((page["label"], destination, port(page)))
    _approved, failure = plan_writes(guard, items, "port_hako_pages.py", regenerate=regenerate)
    return failure or 0


if __name__ == "__main__":
    sys.exit(main())
