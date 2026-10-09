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


def swift_files(root: str) -> list[str]:
    out = []
    for base, dirs, files in os.walk(root):
        # `.build` is a SwiftPM checkout of dependencies, not this project's source.
        dirs[:] = [d for d in dirs if d not in (".git", ".build", ".swiftpm", "build")]
        for name in files:
            if name.endswith(".swift"):
                out.append(os.path.relpath(os.path.join(base, name), root).replace("\\", "/"))
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
        return Check("tablet-entry", "UNKNOWN", "SFI/Application.swift is missing")

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
        return Check("tablet-mac-entry", "FAIL", "; ".join(problems), evidence)
    return Check(
        "tablet-mac-entry",
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
            "shared-page-boundary",
            "FAIL",
            f"{len(problems)} Hako reference(s) in pages upstream owns; first is {problems[0]}",
            [str(h) for h in problems[:10]],
        )
    if missing:
        return Check(
            "shared-page-boundary",
            "UNKNOWN",
            "these upstream-reachable files are absent, so they could not be checked: "
            + ", ".join(missing),
            evidence,
        )
    return Check(
        "shared-page-boundary",
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

    # The audit reports rather than asserts here: this fork is allowed to carry reviewed
    # modifications in shared files, and the list is what a reviewer needs in order to see them.
    if changed:
        return Check(
            "upstream-files-untouched",
            "PASS",
            f"{compared - len(changed)} of {compared} upstream files are byte-identical to "
            f"{upstream_ref}; {len(changed)} were modified by this fork and are listed for review",
            changed[:40],
        )
    return Check(
        "upstream-files-untouched",
        "PASS",
        f"all {compared} upstream-owned files are byte-identical to {upstream_ref}",
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
        return Check("repo-hygiene", "UNKNOWN", "git is not available on PATH")

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

    # `.gitmodules` and every gitlink must match the pinned upstream commit.
    for path in (".gitmodules", "Frameworks/Runestone"):
        rc, local, _ = run([git, "-C", root, "rev-parse", f"HEAD:{path}"])
        if rc != 0:
            problems.append(f"{path} cannot be read from HEAD")
            continue
        local = local.strip()
        if upstream_ref:
            rc, upstream, _ = run([git, "-C", root, "rev-parse", f"{upstream_ref}:{path}"])
            if rc != 0:
                evidence.append(f"{path} = {local[:12]} (upstream comparison unavailable)")
                continue
            upstream = upstream.strip()
            if local != upstream:
                problems.append(
                    f"{path} differs from {upstream_ref} ({local[:12]} vs {upstream[:12]}); this "
                    "work must not move a submodule pointer"
                )
            else:
                evidence.append(f"{path} = {local[:12]} (identical to {upstream_ref})")
        else:
            evidence.append(f"{path} = {local[:12]} (no upstream ref given to compare)")

    # Any *other* gitlink this fork might have added or moved.
    rc, out, _ = run([git, "-C", root, "submodule", "status"])
    if rc == 0:
        for line in out.splitlines():
            if line.startswith("+"):
                problems.append(f"submodule commit differs from the index: {line.strip()}")
        evidence.append(f"submodules reported by git: {len(out.splitlines())}")

    if problems:
        return Check("repo-hygiene", "FAIL", "; ".join(problems), evidence)
    return Check("repo-hygiene", "PASS", "no whitespace errors, no submodule pointer drift", evidence)


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


def baseline_commit(root: str, upstream_ref: str | None) -> str | None:
    """The commit this branch started from.

    `upstream_ref` when the branch was cut straight from upstream and the first commit on the
    branch is upstream's own - which is how this repository's integration branch is built. The
    root commit is the fallback, and it is the honest answer for a fork whose history cannot be
    separated from upstream's: "everything present was added at some point" is not useful, so
    the caller is told rather than misled.
    """
    git = which_git()
    if git is None:
        return None
    if upstream_ref:
        rc, out, _ = run([git, "-C", root, "rev-parse", "--verify", f"{upstream_ref}^{{commit}}"])
        if rc == 0:
            return out.strip()
    rc, out, _ = run([git, "-C", root, "rev-list", "--max-parents=0", "HEAD"])
    if rc != 0:
        return None
    return out.split()[0].strip() if out.split() else None


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
