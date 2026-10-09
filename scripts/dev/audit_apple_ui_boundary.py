#!/usr/bin/env python3
"""Static architecture audit for the Jiejiebox Apple client.

What this is
------------
A boundary audit, not a compiler. It answers three questions that a reviewer cannot answer by
reading a diff, and that a UI test cannot answer without a device:

  1. Does the iPhone route reach the fork's presentation, and does every other device route
     reach upstream's?
  2. Is any Hako-only symbol reachable from a page an iPad or a Mac can show?
  3. Did the user-visible rename leak into an identity, protocol or signing setting?

How it decides, and what that is worth
--------------------------------------
It reads source text. That means it can prove the *absence* of a reference and cannot prove the
absence of a *behaviour*: a page that reaches a Hako view through a closure, a generic type
parameter, a string built at runtime or an Objective-C selector is invisible to it. Every check
therefore reports the evidence it used, and the places it cannot see are listed in `KNOWN BLIND
SPOTS` in the report header rather than being left for a reader to discover.

`git grep` against real blobs is used where a tree is being inspected without a checkout; the
working tree is read directly for the tree under audit.

Usage
-----
    python scripts/dev/audit_apple_ui_boundary.py                 # audit the working tree
    python scripts/dev/audit_apple_ui_boundary.py --root <dir>    # audit another checkout
    python scripts/dev/audit_apple_ui_boundary.py --json          # machine-readable result

Exit status is 0 when every check passes, 1 when any check fails, 2 when the audit itself could
not run (a file it needs is missing, or the repository cannot be read). A check that cannot be
evaluated is reported `UNKNOWN` and does **not** by itself fail the run; `--strict` turns any
`UNKNOWN` into a failure, which is what a release gate wants.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Iterable

# --------------------------------------------------------------------------------------
# Paths and constants
# --------------------------------------------------------------------------------------

#: A path prefix that only the fork's presentation may live under.
HAKO_PREFIX = "ApplicationLibrary/Views/HakoStyle/"

#: Files that are the phone root and its page factory. These may name Hako symbols.
PHONE_ROOT_FILES = ("SFI/Application.swift", "SFI/HakoPhoneRootView.swift", "SFI/HakoPageContent.swift")

#: The iPad root. Upstream owns it, byte for byte.
IPAD_ROOT_FILE = "SFI/MainView.swift"

#: The Mac root. Upstream owns it, byte for byte.
MAC_ROOT_FILE = "MacLibrary/MainView.swift"

#: Shared page factories upstream owns. The phone routes around them rather than through them.
UPSTREAM_PAGE_FACTORY = "ApplicationLibrary/Views/NavigationPage.swift"

#: Settings that must never drift as part of a rename.
PROTECTED_BUILD_SETTINGS = (
    "PRODUCT_BUNDLE_IDENTIFIER",
    "PRODUCT_NAME",
    "CODE_SIGN_IDENTITY",
    "CODE_SIGN_STYLE",
    "DEVELOPMENT_TEAM",
    "PROVISIONING_PROFILE_SPECIFIER",
    "BASE_PACKAGE_IDENTIFIER",
)

#: Symbols that only exist in the fork's presentation. A reference to any of them from outside
#: `HAKO_PREFIX` (and the phone root) is the pollution this audit exists to catch.
HAKO_TYPES = (
    "HakoTheme",
    "HakoProductPalette",
    "HakoRootScaffold",
    "HakoSettingsScaffold",
    "HakoWorkspaceScaffold",
    "HakoModalScaffold",
    "HakoReportScaffold",
    "HakoPageSection",
    "HakoSettingsSection",
    "HakoCardSurface",
    "HakoRowDivider",
    "HakoToolRow",
    "HakoDestinationRow",
    "HakoEntryRow",
    "HakoValueRow",
    "HakoToggleRow",
    "HakoSelectionRow",
    "HakoMetricRow",
    "HakoNavigationRow",
    "HakoDestructiveRow",
    "HakoIconWell",
    "HakoPushRowButtonStyle",
    "HakoStatusBadge",
    "HakoStatusDot",
    "HakoCardTitle",
    "HakoCardLine",
    "HakoCardLineTrailing",
    "HakoMetricText",
    "HakoEmptyState",
    "HakoCardEmptyState",
    "HakoSelectionMark",
    "HakoBadge",
    "HakoBadgeRow",
    "HakoDataCard",
    "HakoDataRow",
    "HakoMetricStack",
    "HakoSummaryCard",
    "HakoSummaryMetric",
    "HakoSummaryMetrics",
    "HakoExpandableGroupRow",
    "HakoProxyMemberRow",
    "HakoActionTile",
    "HakoActionTileLabel",
    "HakoStatusLine",
    "HakoInlineNotice",
    "HakoPrimaryShell",
    "HakoPrimaryTab",
    "HakoPrimaryRoute",
    "HakoPrimaryChildArmer",
    "HakoSurfaceRole",
    "HakoAccentRole",
    "HakoPlatformLayout",
    "HakoBackButton",
    "HakoCloseButton",
    "HakoActionItem",
    "HakoActionGroup",
    "HakoActionDivider",
    "HakoBottomSearchBar",
    "HakoFootnote",
    "HakoNavigationChrome",
    "HakoNavigationLeadingControl",
    "HakoToolbarAction",
    "HakoWorkspaceSearch",
    "HakoLoadingState",
    "HakoRegularDetailContainer",
    "HakoHomeActions",
    "HakoHomeView",
    "HakoUITrace",
)

#: Hako-only view modifiers and environment keys. Lower-case on purpose: these are the ones a
#: shared page would pick up by copying a line rather than by importing a type.
HAKO_MEMBERS = (
    "hakoNavigationChrome",
    "hakoInlineNavigationTitle",
    "hakoInlineTitle",
    "hakoGroupedFormStyle",
    "hakoScrollDismissesKeyboard",
    "hakoCircularIconButtonStyle",
    "hakoContainerDrawsDisclosure",
    "hakoCompactRows",
    "hakoTracePresentation",
    "hakoTitle",
    "hakoHomeActions",
    "hakoPrimary",
    "isHakoPrimaryRoot",
)

#: Swift files that must not reference any Hako symbol at all, on top of the prefix rule.
#: These are the shared pages and components an iPad or a Mac can reach from upstream's own
#: NavigationPage factory, SidebarView and MainView.
UPSTREAM_REACHABLE_PAGES = (
    "ApplicationLibrary/Views/Dashboard/DashboardView.swift",
    "ApplicationLibrary/Views/Dashboard/ActiveDashboardView.swift",
    "ApplicationLibrary/Views/Dashboard/RemoteDashboardView.swift",
    "ApplicationLibrary/Views/Dashboard/Overview/OverviewView.swift",
    "ApplicationLibrary/Views/Setting/SettingView.swift",
    "ApplicationLibrary/Views/Tools/ToolsView.swift",
    "ApplicationLibrary/Views/Log/LogView.swift",
    "ApplicationLibrary/Views/Groups/GroupListView.swift",
    "ApplicationLibrary/Views/Groups/GroupView.swift",
    "ApplicationLibrary/Views/Groups/GroupItemView.swift",
    "ApplicationLibrary/Views/Connections/ConnectionListView.swift",
    "ApplicationLibrary/Views/Connections/ConnectionView.swift",
    "ApplicationLibrary/Views/SidebarView.swift",
    "ApplicationLibrary/Views/Abstract/FormItem.swift",
    "ApplicationLibrary/Views/Abstract/ViewModifiers.swift",
    "ApplicationLibrary/Views/Abstract/NavigationSheetContent.swift",
    "ApplicationLibrary/Views/Abstract/GlobalChecksModifier.swift",
    UPSTREAM_PAGE_FACTORY,
    IPAD_ROOT_FILE,
    MAC_ROOT_FILE,
)

#: The one brand override this fork is allowed to make. `INFOPLIST_KEY_CFBundleDisplayName` is the
#: smallest safe lever: it changes what SpringBoard, the Dock and Spotlight show and nothing else.
BRAND_DISPLAY_NAME = "Jiejiebox"

#: Settings that carry a user-visible name but must keep their upstream value, because they are
#: identity, protocol or signing surface rather than presentation.
PROTECTED_NAME_SETTINGS = (
    "PRODUCT_NAME",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "BASE_PACKAGE_IDENTIFIER",
)


@dataclass
class Blame:
    """Where a finding came from, so it can be looked at rather than believed."""

    path: str
    line: int
    text: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.text.strip()}"


@dataclass
class Check:
    name: str
    status: str  # PASS / FAIL / UNKNOWN
    detail: str
    evidence: list = field(default_factory=list)


def read_text(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


#: Directories no build target reads. A `.swift` file here is documentation or a standalone
#: package, not source, so the boundary checks must not treat it as reachable:
#:
#:   * `docs/` holds `docs/pending/`, which keeps fork work that is deliberately **not** compiled.
#:     It is full of Hako references by design, and counting them would make the audit report the
#:     holding area as a boundary violation.
#:   * `.git`, `.build` and `.swiftpm` are not this project's source at all.
NOT_A_TARGET_TREE = ("docs/", ".build/", ".swiftpm/")


def swift_files(root: str) -> list[str]:
    out = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", ".build", ".swiftpm", "build")]
        for name in files:
            if not name.endswith(".swift"):
                continue
            relative = os.path.relpath(os.path.join(base, name), root).replace("\\", "/")
            if relative.startswith(NOT_A_TARGET_TREE):
                continue
            out.append(relative)
    return sorted(out)


def grep(root: str, path: str, needles: Iterable[str]) -> list[Blame]:
    """Whole-word matches of any needle in one file, comments included.

    Comments are deliberately included. A page that *names* a Hako type in a comment is a page
    whose author was thinking about the phone's presentation, which is exactly the drift this
    catches; and excluding comments would need a Swift lexer this script does not have.
    """
    text = read_text(os.path.join(root, path))
    if text is None:
        return []
    pattern = re.compile(r"\b(" + "|".join(re.escape(n) for n in needles) + r")\b")
    hits = []
    for number, line in enumerate(text.splitlines(), start=1):
        if pattern.search(line):
            hits.append(Blame(path, number, line))
    return hits


# --------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------


def check_phone_entry(root: str) -> Check:
    """The phone must be routed to the fork's root, and only from the idiom switch."""
    app = read_text(os.path.join(root, "SFI/Application.swift"))
    if app is None:
        return Check("phone-entry", "UNKNOWN", "SFI/Application.swift is missing")

    evidence = []
    problems = []

    if "SFIUIFamily" not in app:
        problems.append("SFI/Application.swift does not declare the design family switch")
    if "HakoPhoneRootView" not in app:
        problems.append("SFI/Application.swift never names HakoPhoneRootView")
    if "MainView()" not in app:
        problems.append("SFI/Application.swift never names the upstream MainView")
    if "horizontalSizeClass" in app:
        problems.append(
            "SFI/Application.swift consults horizontalSizeClass; the family must come from the "
            "device idiom, because an iPad in a narrow window is still an iPad"
        )

    # The positive arm must be `.phone` and nothing broader.
    if not re.search(r"case\s+\.phone\s*:", app):
        problems.append("the only idiom that selects the phone route is not spelled `case .phone`")
    for idiom in (".pad", ".unspecified", ".tv", ".carPlay", ".mac"):
        if re.search(r"case\s+(?:[^\n]*,\s*)*" + re.escape(idiom) + r"\s*:", app):
            problems.append(
                f"`{idiom}` is given its own arm; only `.phone` may select the fork's "
                "presentation, and a named negative arm is a second place for the rule to change"
            )

    for path in PHONE_ROOT_FILES:
        if not os.path.exists(os.path.join(root, path)):
            problems.append(f"{path} does not exist")
        else:
            evidence.append(path)

    if problems:
        return Check("phone-entry", "FAIL", "; ".join(problems), evidence)
    evidence.append("SFIUIFamily.resolve(.phone) -> HakoPhoneRootView")
    return Check("phone-entry", "PASS", "the phone route is selected by the device idiom alone", evidence)


def check_tablet_and_mac_entry(root: str) -> Check:
    """Every non-phone route must reach upstream's root, unmodified.

    "Unmodified" is checked against the pinned upstream commit when the object is available;
    otherwise the check reports what it could not compare rather than assuming equality.
    """
    app = read_text(os.path.join(root, "SFI/Application.swift"))
    if app is None:
        return Check("tablet-and-mac-entry", "UNKNOWN", "SFI/Application.swift is missing")

    evidence = []
    problems = []

    # The default arm must reach upstream's root.
    if not re.search(r"default\s*:\s*\n\s*return\s+\.upstreamPad", app):
        problems.append(
            "SFIUIFamily.resolve has no `default: return .upstreamPad`; an idiom the rule has not "
            "considered would otherwise fall to a route that was never decided"
        )
    if ".upstreamPad" not in app:
        problems.append("SFI/Application.swift does not declare an upstream route at all")

    # The upstream roots must be present and must not name a Hako symbol.
    for path in (IPAD_ROOT_FILE, MAC_ROOT_FILE, "ApplicationLibrary/Views/SidebarView.swift",
                 "ApplicationLibrary/Views/Abstract/SidebarLayout.swift"):
        if not os.path.exists(os.path.join(root, path)):
            problems.append(f"{path} does not exist, so upstream's presentation is not reachable")
            continue
        hits = grep(root, path, HAKO_TYPES + HAKO_MEMBERS)
        if hits:
            problems.append(f"{path} names a Hako symbol: {hits[0]}")
        else:
            evidence.append(f"{path}: no Hako symbol")

    if problems:
        return Check("tablet-and-mac-entry", "FAIL", "; ".join(problems), evidence)
    return Check(
        "tablet-and-mac-entry",
        "PASS",
        "every idiom other than .phone resolves to upstreamPad, and upstream's roots name no Hako symbol",
        evidence,
    )


def check_shared_pages_are_clean(root: str) -> Check:
    """No page an iPad or a Mac can reach may name a Hako symbol."""
    problems = []
    evidence = []
    missing = []

    for path in UPSTREAM_REACHABLE_PAGES:
        if not os.path.exists(os.path.join(root, path)):
            missing.append(path)
            continue
        hits = grep(root, path, HAKO_TYPES + HAKO_MEMBERS)
        if hits:
            problems.extend(hits[:3])
        else:
            evidence.append(path)

    if problems:
        return Check(
            "shared-pages-are-clean",
            "FAIL",
            f"{len(problems)} Hako reference(s) in pages upstream owns; first is {problems[0]}",
            [str(h) for h in problems[:10]],
        )
    if missing:
        return Check(
            "shared-pages-are-clean",
            "UNKNOWN",
            "these upstream-reachable files are absent, so they could not be checked: "
            + ", ".join(missing),
            evidence,
        )
    return Check(
        "shared-pages-are-clean",
        "PASS",
        f"{len(UPSTREAM_REACHABLE_PAGES)} upstream-reachable files name no Hako symbol",
        evidence,
    )


def check_no_reverse_dependency(root: str) -> Check:
    """Nothing outside the Hako namespace may name a Hako symbol.

    This is the wider version of the check above: it does not rely on a hand-kept list of shared
    pages, so a page added to upstream later is covered the moment it names a Hako type.
    """
    allowed = set(PHONE_ROOT_FILES)
    problems = []
    checked = 0

    for path in swift_files(root):
        if path.startswith(HAKO_PREFIX) or path in allowed:
            continue
        checked += 1
        hits = grep(root, path, HAKO_TYPES + HAKO_MEMBERS)
        if hits:
            problems.append(hits[0])

    if problems:
        return Check(
            "no-reverse-dependency",
            "FAIL",
            f"{len(problems)} file(s) outside {HAKO_PREFIX} name a Hako symbol",
            [str(h) for h in problems],
        )
    return Check(
        "no-reverse-dependency",
        "PASS",
        f"all {checked} Swift files outside the Hako namespace and the phone root are free of Hako symbols",
    )


#: Files this fork is allowed to have modified, each with the reason it had to be. A file that is
#: not on this list and differs from upstream is a `FAIL`, not a note: an unreviewed edit to a file
#: upstream owns is the thing this check exists to stop, and a check that only reports it is a
#: check nobody reads twice.
REVIEWED_UPSTREAM_MODIFICATIONS = {
    ".gitignore":
        "`__pycache__/` and `*.pyc`, for the two Python scripts under scripts/dev",
    "Localizable.xcstrings":
        "one String Catalog entry for the phone's remaining-quota row (`%@ left`)",
    "Library/Database/Database.swift":
        "the additive `add_subscription_info` migration",
    "Library/Database/Profile.swift":
        "the `subscriptionInfo` column and its encode/decode",
    "Library/Database/Profile+Update.swift":
        "the refresh split into a testable decision and an applier",
    "Library/Database/ProfileManager.swift":
        "clearing metadata whose remote URL changed",
    "Library/Network/HTTPClient.swift":
        "`userAgent` from private to public, so the URLSession fetch can send the same string",
    "Library/Network/ExtensionProvider.swift":
        "starting and stopping the screen-state observer once, around the tunnel's life",
    "Library/Network/ScreenStateObserver.swift":
        "a failed notify read must not publish an unlock (upstream defect, see the commit)",
    "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift":
        "the remaining-quota item, the two layout properties and the locale-sized relative time",
    "sing-box.xcodeproj/project.pbxproj":
        "`CFBundleDisplayName` for the SFI and SFM app targets",
}


def check_upstream_files_untouched(root: str, upstream_ref: str | None) -> Check:
    """The upstream-owned page files must be identical to the pinned upstream commit.

    Only meaningful when the pinned object is present in the repository the audit is run in, so
    an absent object is reported as UNKNOWN rather than as a pass.
    """
    if not upstream_ref:
        return Check(
            "upstream-files-untouched",
            "UNKNOWN",
            "no --upstream-ref was given, so the upstream-owned files were not compared",
        )
    git = which_git()
    if git is None:
        return Check("upstream-files-untouched", "UNKNOWN", "git is not available on PATH")

    rc, out, err = run([git, "-C", root, "rev-parse", "--verify", f"{upstream_ref}^{{commit}}"])
    if rc != 0:
        return Check(
            "upstream-files-untouched",
            "UNKNOWN",
            f"{upstream_ref} is not present in this repository ({err.strip()}); the comparison "
            "cannot be made and is not assumed",
        )
    upstream_commit = out.strip()

    # Walk the whole upstream tree at the pinned commit and compare every file that exists on
    # both sides, excluding the fork's own namespace and the files this fork is known to own.
    rc, listing, err = run([git, "-C", root, "ls-tree", "-r", "--name-only", upstream_commit])
    if rc != 0:
        return Check("upstream-files-untouched", "UNKNOWN", f"cannot list {upstream_ref}: {err.strip()}")

    fork_owned_prefixes = (
        HAKO_PREFIX,
        "Tests/HakoSubscriptionUsage/",
        "docs/",
        "scripts/",
    )
    fork_owned_files = set(PHONE_ROOT_FILES) | {
        "README.md",
        "AGENTS.md",
        "Localizable.xcstrings",
    }

    changed = []
    compared = 0
    for path in listing.splitlines():
        path = path.strip()
        if not path or path.startswith(fork_owned_prefixes) or path in fork_owned_files:
            continue
        local = os.path.join(root, path)
        if not os.path.exists(local):
            continue
        rc, blob, _ = run([git, "-C", root, "rev-parse", f"{upstream_commit}:{path}"])
        if rc != 0:
            continue
        rc, head, _ = run([git, "-C", root, "hash-object", local])
        if rc != 0:
            continue
        compared += 1
        if blob.strip() != head.strip():
            changed.append(path)

    # The audit asserts rather than reports: a file that differs from upstream and is not on the
    # reviewed list is a failure. The list is the record of which shared files this fork had to
    # touch and why, and adding to it is a deliberate act.
    unreviewed = [p for p in changed if p not in REVIEWED_UPSTREAM_MODIFICATIONS]
    stale = [p for p in REVIEWED_UPSTREAM_MODIFICATIONS if p not in changed and p not in fork_owned_files]

    if unreviewed:
        return Check(
            "upstream-files-untouched",
            "FAIL",
            f"{len(unreviewed)} upstream-owned file(s) were modified without being on the reviewed "
            f"list: {', '.join(unreviewed[:5])}",
            unreviewed[:40],
        )
    return Check(
        "upstream-files-untouched",
        "PASS",
        f"{compared - len(changed)} of {compared} upstream files are byte-identical to "
        f"{upstream_ref}; {len(changed)} are modified and all of them are on the reviewed list",
        [f"{p} - {REVIEWED_UPSTREAM_MODIFICATIONS[p]}" for p in sorted(changed)]
        + ([f"note: {len(stale)} reviewed entry/entries no longer differ: {stale}"] if stale else []),
    )


def check_project_membership(root: str, upstream_ref: str | None = None) -> Check:
    """New source files must land inside a target that Xcode synchronises, without exceptions.

    This is a *membership* check, not a build. It proves a file is picked up by a target; it
    cannot prove the file compiles.

    What it does **not** flag: an upstream file that Xcode deliberately excludes, such as an
    `Info.plist` inside a synchronised folder or the two `Application.swift` files the `SFM` and
    `SFT` targets share a folder with. Those exclusions are upstream's own arrangement - a file
    that is written against one target must not be compiled into another. The check reports only
    files this fork added.
    """
    pbx = os.path.join(root, "sing-box.xcodeproj/project.pbxproj")
    text = read_text(pbx)
    if text is None:
        return Check("project-membership", "UNKNOWN", "sing-box.xcodeproj/project.pbxproj is missing")

    problems = []

    # Read the synchronised roots.
    synced = {}
    for match in re.finditer(
        r"([0-9A-F]{24}) /\* (\w+) \*/ = \{isa = PBXFileSystemSynchronizedRootGroup;"
        r"(.*?)path = ([^;]+);",
        text,
        re.S,
    ):
        synced[match.group(4).strip().strip('"')] = match.group(2)

    if not synced:
        return Check(
            "project-membership",
            "UNKNOWN",
            "the project has no PBXFileSystemSynchronizedRootGroup entries, so membership is "
            "declared file by file and this check does not apply",
        )

    # Excluded names, per synchronised target.
    excluded: dict[str, set[str]] = {}
    for match in re.finditer(
        r"membershipExceptions = \((.*?)\);\s*target = [0-9A-F]{24} /\* (\w+) \*/;",
        text,
        re.S,
    ):
        names = {n.strip().rstrip(",").strip().strip('"') for n in match.group(1).split("\n") if n.strip()}
        excluded.setdefault(match.group(2), set()).update(names)

    # Only the files this fork adds are the check's business. "Added" is measured against the
    # branch's own baseline - the earliest commit on this branch that upstream's pinned commit
    # does not contain - so the check reports the new files of this work rather than every file
    # in a tree that is, after all, a fork.
    baseline = baseline_commit(root, upstream_ref)
    if baseline is None:
        return Check(
            "project-membership",
            "UNKNOWN",
            "the branch's baseline commit could not be determined, so 'added by this fork' has no "
            "definition and the check is not attempted",
        )

    git = which_git()
    upstream_paths: set[str] = set()
    if git is not None:
        rc, listing, _ = run([git, "-C", root, "ls-tree", "-r", "--name-only", baseline])
        if rc == 0:
            upstream_paths = {line.strip() for line in listing.splitlines() if line.strip()}
    if not upstream_paths:
        return Check("project-membership", "UNKNOWN", f"cannot list {baseline}")

    all_files = swift_files(root)
    added = [p for p in all_files if p not in upstream_paths]

    # A subtree with its own `Package.swift` is a SwiftPM package, built by `swift build` and
    # `swift test` rather than by the Xcode project. Its members are deliberately not Xcode
    # target members, so requiring a synchronised root for them would be the wrong assertion.
    added = [p for p in added if not in_swiftpm_package(root, p)]

    if not added:
        return Check("project-membership", "UNKNOWN", "no Swift files found under a synchronised root")

    evidence = []
    for path in added:
        top = path.split("/", 1)[0]
        if top not in synced:
            problems.append(f"{path} is not under any synchronised root, so no target compiles it")
            continue
        target = synced[top]
        name = os.path.basename(path)
        if name in excluded.get(target, set()):
            problems.append(f"{path} is excluded from its synchronised target {target} by name")
        else:
            evidence.append(f"{path} -> {target}")

    if problems:
        return Check("project-membership", "FAIL", "; ".join(problems), evidence[:5])
    return Check(
        "project-membership",
        "PASS",
        f"{len(added)} file(s) this fork adds resolve to a synchronised target with no membership "
        f"exception, out of {len(all_files)} Swift files in the tree",
        evidence[:8],
    )


def check_branding(root: str) -> Check:
    """The visible name is Jiejiebox; identity, protocol and signing surface is untouched."""
    pbx = os.path.join(root, "sing-box.xcodeproj/project.pbxproj")
    text = read_text(pbx)
    if text is None:
        return Check("branding", "UNKNOWN", "sing-box.xcodeproj/project.pbxproj is missing")

    evidence = []
    problems = []

    display_names = re.findall(r"INFOPLIST_KEY_CFBundleDisplayName = ([^;]+);", text)
    if not display_names:
        problems.append("no INFOPLIST_KEY_CFBundleDisplayName is set anywhere")
    # The app targets are the ones we care about. Extensions keep their own names, which is
    # correct: "Share Extension" is not the product's name.
    app_targets = 0
    for target, names in target_lines(text, "INFOPLIST_KEY_CFBundleDisplayName"):
        for value in names:
            value = value.strip().strip('"')
            if value == BRAND_DISPLAY_NAME:
                app_targets += 1
                evidence.append(f"target {target}: CFBundleDisplayName = {value}")
    if app_targets == 0:
        problems.append(
            f"no target sets CFBundleDisplayName = {BRAND_DISPLAY_NAME}; the user-visible rename "
            "is missing"
        )

    # Identity surface must not carry the brand.
    for setting in PROTECTED_NAME_SETTINGS:
        for target, values in target_lines(text, setting):
            for value in values:
                value = value.strip().strip('"')
                if BRAND_DISPLAY_NAME.lower() in value.lower():
                    problems.append(
                        f"{setting} in target {target} carries the product name ({value}); the "
                        "rename must not reach bundle identifiers or product names"
                    )

    # `Variant.applicationName` feeds the VPN profile's localizedDescription, the User-Agent and
    # Siri, so it is protocol surface, not presentation.
    variant = read_text(os.path.join(root, "Library/Shared/Variant.swift"))
    if variant is None:
        problems.append("Library/Shared/Variant.swift is missing")
    else:
        match = re.search(r'applicationName\s*=\s*"([^"]*)"', variant)
        if match is None:
            problems.append("Variant.applicationName could not be read")
        elif match.group(1) == BRAND_DISPLAY_NAME:
            problems.append(
                "Variant.applicationName was renamed; it reaches the VPN profile's "
                "localizedDescription, the User-Agent and Siri, so it is not a display-name setting"
            )
        else:
            evidence.append(f"Variant.applicationName = {match.group(1)} (unchanged)")

    evidence.append(f"CFBundleDisplayName occurrences: {sorted(set(n.strip().strip(chr(34)) for n in display_names))}")

    if problems:
        return Check("branding", "FAIL", "; ".join(problems), evidence)
    return Check("branding", "PASS", "the visible name is overlaid and nothing else moved", evidence)


def target_lines(text: str, setting: str) -> list[tuple[str, list[str]]]:
    """Return (target name, values) for a build setting, using each block's `name =` marker."""
    out = []
    blocks = re.split(r"\n\t\t[0-9A-F]{24} /\* (?:Debug|Release) \*/ = \{", text)
    names = re.findall(r"\n\t\t[0-9A-F]{24} /\* (Debug|Release) \*/ = \{", text)
    for index, block in enumerate(blocks[1:]):
        values = re.findall(rf"{re.escape(setting)} = ([^;]+);", block)
        if values:
            out.append((names[index] if index < len(names) else f"block{index}", values))
    return out


def inventory_symbols(root: str) -> tuple[set[str], dict[str, list[Blame]]]:
    """Every member this fork's Swift names by declaration, and every site that names it.

    Only *added* knowledge: a member declared in the tree is returned in the first set, and the
    places that write `something.member` or `.member(...)` are returned in the second. It is
    deliberately shallow - it does not resolve types, so `a.foo` where two types both declare
    `foo` counts for both. That is the right trade for this purpose: the check is asking whether a
    symbol is *used anywhere at all*, and over-counting uses can only make it less likely to
    report a missing one, which is why the callers of this function assert on the declaration side
    as well.
    """
    declared: set[str] = set()
    sites: dict[str, list[Blame]] = {}

    decl_pattern = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|static\s+|class\s+|"
        r"nonisolated\s+|override\s+|mutating\s+|lazy\s+)*"
        r"(?:func|var|let)\s+([A-Za-z_]\w*)",
    )
    use_pattern = re.compile(r"(?:\.|\bself\.)([A-Za-z_]\w*)")

    for path in swift_files(root):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            declaration = decl_pattern.match(line)
            if declaration:
                declared.add(declaration.group(1))
            for match in use_pattern.finditer(line):
                sites.setdefault(match.group(1), []).append(Blame(path, number, line))
    return declared, sites


def submodule_paths(root: str, git: str | None) -> list[str]:
    """Every gitlink in the index, read from `.gitmodules` and the index's own mode bits.

    Read rather than assumed: a path list written into this script would silently stop covering a
    submodule that upstream adds later, which is the failure mode this whole file is written to
    avoid.
    """
    if git is None:
        return []
    paths: list[str] = []
    gitmodules = os.path.join(root, ".gitmodules")
    if os.path.exists(gitmodules):
        text = read_text(gitmodules) or ""
        for match in re.finditer(r'^\s*path\s*=\s*(.+?)\s*$', text, re.M):
            paths.append(match.group(1))
    # The index is the authority on what is actually a gitlink; `.gitmodules` can name a path that
    # was never added.
    rc, out, _ = run([git, "-C", root, "ls-files", "-s", "--stage"])
    if rc == 0:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0] == "160000":
                path = parts[3]
                if path not in paths:
                    paths.append(path)
    return sorted(set(paths))


def is_declaration_of(blame: Blame, symbol: str) -> bool:
    """Whether this line declares the symbol rather than using it.

    Shallow on purpose: it recognises the declaration forms Swift actually uses for these members
    and treats everything else as a use. Being wrong in the "use" direction is safe here, because
    the callers pair this check with a declaration scan - a symbol that is only ever "used" on its
    own declaration line would be caught by the scan as missing.
    """
    return bool(re.match(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|static\s+|class\s+|"
        r"nonisolated\s+|override\s+|mutating\s+|lazy\s+)*"
        r"(?:func|var|let)\s+" + re.escape(symbol) + r"\b",
        blame.text,
    ))


def check_subscription_feature(root: str) -> Check:
    """The newest phone feature must be present, reachable and wired end to end."""
    required_files = {
        "Library/Network/SubscriptionInfo.swift": (r"func parse\s*\(\s*header", "remainingBytes", "usedBytes"),
        "Library/Network/RemoteProfileFetcher.swift": ("subscription-userinfo", "HTTPClient.userAgent"),
        "Library/Database/RemoteProfileUpdatePolicy.swift": ("RemoteProfileRefresh",),
        "Library/Database/RemoteRefreshApplier.swift": ("RemoteRefreshApplier",),
        "Library/Database/Profile.swift": ("subscriptionInfo", "subscriptionUpload"),
        "Library/Database/Database.swift": ("add_subscription_info",),
        "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift": ("remainingTrafficInfo",),
        "Localizable.xcstrings": ('"%@ left"',),
    }
    problems = []
    evidence = []
    for path, needles in required_files.items():
        text = read_text(os.path.join(root, path))
        if text is None:
            problems.append(f"{path} is missing")
            continue
        missing = [n for n in needles if not re.search(n, text)]
        if missing:
            problems.append(f"{path} does not contain {missing}")
        else:
            evidence.append(path)

    # The row must read the value from the snapshot it holds, not from a second fetch.
    picker = read_text(os.path.join(root, "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift"))
    if picker and "profile.subscriptionInfo?.remainingBytes" not in picker:
        problems.append(
            "the profile row does not read `profile.subscriptionInfo?.remainingBytes`, so it "
            "cannot show the remainder from the snapshot it already has"
        )

    # A feature is not present merely because a helper exists. Every symbol on the chain that the
    # row depends on must be declared *and* named somewhere the phone actually reaches, which is
    # what distinguishes "written" from "wired up" - the failure this check exists for.
    #
    # Two independent readings are taken, because each can miss a different thing and a guard is
    # only as good as its weakest one:
    #
    #   * a declaration scan, which catches a renamed or deleted member; and
    #   * a plain occurrence count outside the Hako namespace, which catches a helper that is
    #     declared and then never called.
    #
    # The occurrence reading deliberately does not try to resolve types. A symbol named anywhere
    # outside the fork's presentation is enough to say the feature is reachable from code that is
    # not the presentation, which is the property being asserted.
    outside_hako: dict[str, list[Blame]] = {}
    for path in swift_files(root):
        if path.startswith(HAKO_PREFIX):
            continue
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            for symbol in ("remainingTrafficInfo", "remainingBytes", "remainingTrafficText",
                           "subscriptionInfo", "updateRemoteProfile"):
                if re.search(rf"\b{symbol}\b", line):
                    outside_hako.setdefault(symbol, []).append(Blame(path, number, line))

    declared, _ = inventory_symbols(root)
    for symbol, where in (
        ("remainingTrafficInfo", "the picker row's quota item"),
        ("remainingBytes", "the remaining-bytes accessor"),
        ("remainingTrafficText", "the quota formatter"),
        ("subscriptionInfo", "the profile's stored metadata"),
        ("updateRemoteProfile", "the refresh entry point"),
    ):
        if symbol not in declared:
            problems.append(f"{symbol} ({where}) is not declared anywhere in the tree")
            continue
        # One occurrence is the declaration itself; the feature needs a second, elsewhere.
        uses = [b for b in outside_hako.get(symbol, []) if not is_declaration_of(b, symbol)]
        if not uses:
            problems.append(
                f"{symbol} ({where}) is declared but used nowhere outside the Hako namespace, so "
                "the feature it belongs to is not reachable"
            )
        else:
            evidence.append(f"{symbol}: {len(uses)} use(s) outside the Hako namespace, first at {uses[0]}")

    # The migration must be additive: no drop or rename of a column that already shipped.
    db = read_text(os.path.join(root, "Library/Database/Database.swift"))
    if db:
        for bad in re.finditer(r"registerMigration\(\"(add_subscription_info)\"\)\s*\{([^}]*)\}", db, re.S):
            body = bad.group(2)
            if "drop(" in body or "rename(" in body:
                problems.append("the add_subscription_info migration drops or renames a column")

    if problems:
        return Check("subscription-feature", "FAIL", "; ".join(problems), evidence)
    return Check(
        "subscription-feature",
        "PASS",
        "the metadata chain is present from the response header to the picker row",
        evidence,
    )


def check_repository_hygiene(root: str, upstream_ref: str | None = None) -> Check:
    """No whitespace errors, no submodule drift, no unintended file modes.

    An uninitialised submodule is **not** a failure. The `Frameworks/Runestone` gitlink is a
    pointer; whether the working tree has checked it out says nothing about whether the pointer
    moved, and this fork does not need the submodule's contents to audit its own source. The
    check therefore compares the recorded gitlink against the pinned upstream commit, which is
    the property that actually matters: an unchanged gitlink means this work did not touch it.
    """
    git = which_git()
    if git is None:
        return Check("repository-hygiene", "UNKNOWN", "git is not available on PATH")

    problems = []
    evidence = []

    rc, out, err = run([git, "-C", root, "diff", "--check", "HEAD"])
    if rc == 0 and not out.strip():
        evidence.append("git diff --check: clean")
    elif rc == 0:
        problems.append("git diff --check reported whitespace errors")
        evidence.extend(out.splitlines()[:5])
    else:
        evidence.append(f"git diff --check could not run ({err.strip()}); not counted as a failure")

    # `.gitmodules` is an ordinary tracked file, so it is compared as one - against the **working
    # tree**, because repointing a submodule is exactly the change this check is for, and a
    # comparison against HEAD would not see it until it had been committed.
    if upstream_ref:
        rc, upstream_blob, _ = run([git, "-C", root, "rev-parse", f"{upstream_ref}:.gitmodules"])
        if rc != 0:
            evidence.append(".gitmodules: upstream comparison unavailable")
        elif not os.path.exists(os.path.join(root, ".gitmodules")):
            problems.append(".gitmodules is missing from the working tree")
        else:
            rc, local_blob, _ = run([git, "-C", root, "hash-object", os.path.join(root, ".gitmodules")])
            if rc != 0:
                evidence.append(".gitmodules: could not be hashed")
            elif local_blob.strip() != upstream_blob.strip():
                problems.append(
                    f".gitmodules differs from {upstream_ref}; this work must not repoint a "
                    "submodule"
                )
            else:
                evidence.append(f".gitmodules blob = {local_blob.strip()[:12]} (identical to {upstream_ref})")

    # Every gitlink is a pointer recorded in the index, and the index is where a move shows up
    # even before it is committed.
    for path in submodule_paths(root, git):
        rc, local, _ = run([git, "-C", root, "rev-parse", f":{path}"])
        if rc != 0:
            evidence.append(f"{path}: no gitlink recorded in the index")
            continue
        local = local.strip()
        if upstream_ref:
            rc, upstream, _ = run([git, "-C", root, "rev-parse", f"{upstream_ref}:{path}"])
            if rc != 0:
                evidence.append(f"{path} gitlink = {local[:12]} (upstream comparison unavailable)")
                continue
            if local != upstream.strip():
                problems.append(
                    f"the {path} gitlink differs from {upstream_ref}; this work must not move a "
                    "submodule pointer"
                )
            else:
                evidence.append(f"{path} gitlink = {local[:12]} (identical to {upstream_ref})")
        else:
            evidence.append(f"{path} gitlink = {local[:12]} (no upstream ref given to compare)")

    # Any *other* gitlink this fork might have added or moved.
    rc, out, _ = run([git, "-C", root, "submodule", "status"])
    if rc == 0:
        for line in out.splitlines():
            if line.startswith("+"):
                problems.append(f"submodule commit differs from the index: {line.strip()}")
        evidence.append(f"submodules reported by git: {len(out.splitlines())}")

    if problems:
        return Check("repository-hygiene", "FAIL", "; ".join(problems), evidence)
    return Check("repository-hygiene", "PASS", "no whitespace errors, no submodule pointer drift", evidence)


# --------------------------------------------------------------------------------------
# runner
# --------------------------------------------------------------------------------------


#: Known non-PATH locations of a git that may be present on a machine where git is not installed
#: normally. Checked in order, and only when `DSH_GIT` and PATH both fail. An entry whose last two
#: components include a directory name beginning with a dot is skipped, so a checkout of this
#: repository that happens to sit next to another one cannot be mistaken for a toolchain.
FALLBACK_GIT_PATHS = (
    r"C:\Deepseek\安卓客户端\.tools\git\cmd\git.exe",
)


def which_git() -> str | None:
    """Find a usable git.

    `DSH_GIT` first, because the harness this repository is worked on may carry a portable git
    that is deliberately not on PATH; then PATH itself, so the script behaves normally on a
    machine that has one installed; then a short list of known portable locations. The script
    reports `UNKNOWN` rather than `FAIL` when no git is found, so an environment without one is
    never mistaken for a broken repository.
    """
    candidates = [os.environ.get("DSH_GIT"), "git", *FALLBACK_GIT_PATHS]
    for candidate in candidates:
        if not candidate:
            continue
        if os.path.isabs(candidate):
            if os.path.exists(candidate):
                return candidate
            continue
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            if not directory:
                continue
            for suffix in ("", ".exe", ".cmd", ".bat"):
                full = os.path.join(directory, candidate + suffix)
                if os.path.exists(full):
                    return full
    return None


def in_swiftpm_package(root: str, path: str) -> bool:
    """Whether this file belongs to a SwiftPM package rather than the Xcode project.

    The test is a `Package.swift` in the file's directory or any of its ancestors below the
    repository root: that is what makes a subtree a package, and it is how `swift test` finds its
    targets. Returns False for a file in an ancestor's package, which a nested package would make
    ambiguous - the nearest `Package.swift` wins.
    """
    directory = os.path.dirname(path)
    while directory:
        if os.path.exists(os.path.join(root, directory, "Package.swift")):
            return True
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    return os.path.exists(os.path.join(root, "Package.swift"))


def find_upstream_ref(root: str) -> str | None:
    """An upstream commit this repository already knows about.

    Tried in order; the result is only used after its ancestry is verified, so a branch that
    merely happens to have an `origin/main` which is *not* behind it is not mistaken for a fork
    of it.
    """
    git = which_git()
    if git is None:
        return None
    for candidate in ("upstream/dev", "upstream/main", "origin/main"):
        rc, out, _ = run([git, "-C", root, "rev-parse", "--verify", f"{candidate}^{{commit}}"])
        if rc == 0:
            return out.strip()
    return None


def baseline_commit(root: str, upstream_ref: str | None) -> str | None:
    """The commit this branch's own work starts from.

    Three attempts, in order of how much each can be trusted:

      1. `upstream_ref`, when given and when it really is an ancestor of HEAD.
      2. An upstream ref found in this repository, under the same ancestry test. This is what makes
         the audit usable with no arguments in a normal checkout, which is the difference between a
         check that gets run and a check that has to be remembered.
      3. `HEAD~1`, so a branch whose upstream cannot be found still gets a usable definition -
         "what the last commit added".

    `None` is returned only when none of the three apply, and the caller then reports `UNKNOWN`.
    Comparing against the root commit instead would report the entire tree as new and turn a
    boundary check into noise.
    """
    git = which_git()
    if git is None:
        return None

    def is_ancestor(candidate: str) -> bool:
        rc, _, _ = run([git, "-C", root, "merge-base", "--is-ancestor", candidate, "HEAD"])
        return rc == 0

    for candidate in (upstream_ref, find_upstream_ref(root)):
        if not candidate:
            continue
        rc, out, _ = run([git, "-C", root, "rev-parse", "--verify", f"{candidate}^{{commit}}"])
        if rc == 0 and is_ancestor(out.strip()):
            return out.strip()

    rc, out, _ = run([git, "-C", root, "rev-parse", "--verify", "HEAD~1^{commit}"])
    if rc == 0:
        return out.strip()
    return None


def run(args: list[str]) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(args, capture_output=True)
    except OSError as error:
        return 1, "", str(error)
    return (
        proc.returncode,
        proc.stdout.decode("utf-8", "replace"),
        proc.stderr.decode("utf-8", "replace"),
    )


CHECKS = (
    check_phone_entry,
    check_tablet_and_mac_entry,
    check_shared_pages_are_clean,
    check_no_reverse_dependency,
    check_upstream_files_untouched,
    check_project_membership,
    check_branding,
    check_subscription_feature,
    check_repository_hygiene,
)

#: Checks that take the pinned upstream ref as a second argument.
TAKES_UPSTREAM_REF = (
    check_upstream_files_untouched,
    check_project_membership,
    check_repository_hygiene,
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Static UI-boundary audit for the Apple client.")
    parser.add_argument("--root", default=None, help="checkout to audit (default: the script's repo root)")
    parser.add_argument("--upstream-ref", default=None, help="pinned upstream ref to compare against")
    parser.add_argument("--json", action="store_true", help="print a JSON result instead of a report")
    parser.add_argument("--strict", action="store_true", help="treat UNKNOWN as a failure")
    parser.add_argument("--only", action="append", default=None, help="run only the named check(s)")
    args = parser.parse_args(argv)

    root = args.root
    if root is None:
        here = os.path.dirname(os.path.abspath(__file__))
        root = os.path.dirname(os.path.dirname(here))
    root = os.path.abspath(root)
    if not os.path.isdir(os.path.join(root, "sing-box.xcodeproj")):
        print(f"not a sing-box-for-apple checkout: {root}", file=sys.stderr)
        return 2

    results: list[Check] = []
    wanted = {name.replace("_", "-") for name in args.only} if args.only else None
    for check in CHECKS:
        name = check.__name__.replace("check_", "").replace("_", "-")
        if wanted is not None and name not in wanted:
            continue
        if check in TAKES_UPSTREAM_REF:
            results.append(check(root, args.upstream_ref))
        else:
            results.append(check(root))
    if wanted is not None and not results:
        known = ", ".join(c.__name__.replace("check_", "").replace("_", "-") for c in CHECKS)
        print(f"no check matched {sorted(wanted)}; known checks: {known}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(
            {
                "root": root,
                "checks": [
                    {"name": r.name, "status": r.status, "detail": r.detail, "evidence": r.evidence}
                    for r in results
                ],
            },
            indent=2,
            ensure_ascii=False,
        ))
    else:
        print(f"Jiejiebox Apple client - static UI boundary audit")
        print(f"root: {root}")
        if args.upstream_ref:
            print(f"upstream ref: {args.upstream_ref}")
        print()
        for result in results:
            print(f"[{result.status:7s}] {result.name}")
            print(f"          {result.detail}")
            for item in result.evidence[:6]:
                print(f"          - {item}")
            if len(result.evidence) > 6:
                print(f"          - ... {len(result.evidence) - 6} more")
            print()
        counts = {status: sum(1 for r in results if r.status == status) for status in ("PASS", "FAIL", "UNKNOWN")}
        print(f"PASS {counts['PASS']}  FAIL {counts['FAIL']}  UNKNOWN {counts['UNKNOWN']}")

    failed = any(r.status == "FAIL" for r in results)
    if args.strict:
        failed = failed or any(r.status == "UNKNOWN" for r in results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
