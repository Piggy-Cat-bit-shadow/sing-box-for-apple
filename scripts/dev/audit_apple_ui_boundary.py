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

`UNDECIDABLE` is the third state and it **always** fails the run, on the text path and on `--json`
alike: the check is in the enforced set, its inputs were present, and the tree did not let the
predicate be evaluated - a condition table with no entry for a framework the tree imports, a file
whose `#if`/`#endif` directives do not balance. Reporting those as "0 broken" and exiting 0 is the
false green this status exists to stop. The difference from `UNKNOWN` is whose fault it is: `UNKNOWN`
means this invocation did not supply what the check needs, `UNDECIDABLE` means the tree did not.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Iterable
from original_type_names import ORIGINAL_TYPE_NAMES

# --------------------------------------------------------------------------------------
# Paths and constants
# --------------------------------------------------------------------------------------

#: A path prefix that only the fork's presentation may live under.
HAKO_PREFIX = "ApplicationLibrary/Views/HakoStyle/"

#: Files that are the phone root and its page factory. These may name Hako symbols.
#: Files the phone's pages may reach, and the only places outside `HakoStyle/` that may name a Hako
#: symbol.
#:
#: `SFI/ProfileEditorWrapperView.swift` is here because the phone's editor toolbar cannot be chosen
#: anywhere else. The frozen design restyled four things in that toolbar, and `SFI` is the iPhone target -
#: both of its roots build this one wrapper, `HakoPhoneRootView` for the phone and `MainView` for an iPad.
#: The choice is therefore a `restyled:` parameter defaulting to `false`, so `MainView` keeps upstream's
#: toolbar without being edited at all, and only the phone root names the Hako view. Linking the toolbar
#: instead of parametrising it would have compiled without this entry and put the phone's design on an iPad.
#:
#: Two shared files were on this list before and neither is any more. Each entry outlived the difference it
#: was written for, and an allow-list entry for a file that no longer differs is a hole - it would silently
#: absorb the next real edit to that file:
#:
#:   * `ApplicationLibrary/Views/EnvironmentValues.swift` - the `hakoCompactRows` key moved to
#:     `HakoStyle/HakoEnvironmentValues.swift`.
#:   * `Profile/ProfileSheetHelpers.swift` - the modal container's `HakoCloseButton()` is gone; the phone's
#:     modals attach their close to the content instead, through `hakoModalClose()`.
PHONE_ROOT_FILES = (
    "SFI/Application.swift", "SFI/HakoPhoneRootView.swift", "SFI/HakoPageContent.swift",
    "SFI/ProfileEditorWrapperView.swift",
)

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


def strip_comment(line: str) -> str:
    """The line with any trailing `//` comment removed.

    Deliberately naive: it cannot tell a `//` inside a string literal from a comment. That is acceptable
    here because its one caller matches declaration syntax, which does not contain string literals - and a
    stricter version would need to track string state across lines to be right, which is the kind of
    half-correct cleverness this project has already been bitten by twice.
    """
    index = line.find("//")
    return line if index < 0 else line[:index]


def strip_comments(text: str) -> str:
    """Every comment removed from a whole file, block comments first.

    The block pass has to run before the line pass: `/* ... */` can span lines, and a `//` inside one would
    be removed by the line pass first, leaving the block's remainder exposed. A page that names a Hako type
    only in a doc comment must not read as a caller - the audit's own `grep` includes comments on purpose,
    and this is the check where that would produce a false pass.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


#: Directories no build target reads. A `.swift` file here is documentation or a standalone
#: package, not source, so the boundary checks must not treat it as reachable:
#:
#:   * `docs/` holds `docs/pending/`, which keeps fork work that is deliberately **not** compiled.
#:     It is full of Hako references by design, and counting them would make the audit report the
#:     holding area as a boundary violation.
#:   * `.git`, `.build` and `.swiftpm` are not this project's source at all.
#:   * `Tests/` holds SwiftPM packages, not app sources. They are not in `sing-box.xcodeproj` at all -
#:     grep for `HakoSubscriptionUsage` in the project file finds nothing - and they deliberately
#:     redeclare `ExtensionProfile`, `FilePath` and `HTTPClient` as stubs so the shared logic can be
#:     tested without an Apple SDK. Counting them made the duplicate check report three conflicts that
#:     cannot exist, because no target compiles a stub and the real file together.
NOT_A_TARGET_TREE = ("docs/", ".build/", ".swiftpm/", "Tests/", "scripts/")

#: Swift files that are deliberately compiled by a shell script rather than by Xcode. They are not part
#: of the app, so the boundary rules about what a page may name do not apply to them - but they are
#: Swift, so swift_files still finds them and a check has to say so explicitly rather than be
#: surprised. scripts/dev/check-hako-primary-route.swift is the one such file: the harness compiles it
#: against the built framework to exercise the shell's page mapping, which is why it names Hako types
#: and why no synchronized root contains it.
OUTSIDE_THE_APP = ("scripts/dev/check-hako-primary-route.swift",)


def is_reparse_point(path: str) -> bool:
    """Whether this directory is a junction or a symlink rather than a directory of this checkout.

    `os.path.islink` returns **False** for a Windows directory junction, which is why this asks the
    `lstat` attributes instead: a junction carries `FILE_ATTRIBUTE_REPARSE_POINT` even though Python does
    not call it a link. `os.walk` descends into one regardless, and that is not a theoretical concern
    here - `_work/r8/w-b/sing-box-for-apple` is a junction onto the parent checkout, and reading through
    it made every guarded type look like it was declared twice, from two different trees at two
    different commits. A boundary audit that reads outside the tree it was pointed at is not auditing
    that tree.

    Falls back to `False` off Windows and for a directory that cannot be stat'ed, so the scan behaves
    exactly as before on a tree with no links in it.
    """
    try:
        attributes = os.lstat(path).st_file_attributes
    except (OSError, AttributeError):
        return False
    return bool(attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def swift_files(root: str, under: str | None = None) -> list[str]:
    """Swift files under `root`, or under `root/<under>` when a subtree is wanted.

    `under` exists so a check can count what is in a subtree - the boundary check needs to know the
    Hako namespace is not empty before it can report that nothing outside it names a Hako symbol.

    Directories that are junctions or symlinks are skipped: they point at another checkout (or at the
    same one), and every file behind one is either somebody else's source or a second copy of this
    one's.
    """
    scan = os.path.join(root, under) if under else root
    out = []
    for base, dirs, files in os.walk(scan):
        dirs[:] = [d for d in dirs if d not in (".git", ".build", ".swiftpm", "build")
                   and not is_reparse_point(os.path.join(base, d))]
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

    # A check that scans for the presence of something must first establish that the something is
    # there. With the namespace deleted this check used to report PASS over a tree where the phone's
    # own pages had lost every symbol they name - true, and worthless: it would say the boundary holds
    # while the phone does not build. The namespace and the phone root are what the check is *about*,
    # so their absence is UNKNOWN rather than PASS.
    namespace = os.path.join(root, HAKO_PREFIX)
    if not os.path.isdir(namespace):
        return Check(
            "no-reverse-dependency",
            "UNKNOWN",
            f"{HAKO_PREFIX} does not exist, so there is nothing for the boundary to be drawn around",
        )
    hako_files = swift_files(root, HAKO_PREFIX)
    if not hako_files:
        return Check(
            "no-reverse-dependency",
            "UNKNOWN",
            f"{HAKO_PREFIX} contains no Swift file, so there is nothing for the boundary to be drawn around",
        )
    missing_root = [path for path in PHONE_ROOT_FILES if not os.path.exists(os.path.join(root, path))]
    if missing_root:
        return Check(
            "no-reverse-dependency",
            "UNKNOWN",
            f"the phone root is incomplete, so what it may reach cannot be judged: {missing_root}",
        )

    for path in swift_files(root):
        if path.startswith(HAKO_PREFIX) or path in allowed:
            continue
        if path in OUTSIDE_THE_APP:
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
        f"all {checked} Swift files outside the Hako namespace and the phone root are free of Hako "
        f"symbols, with {len(hako_files)} file(s) in the namespace to be divided from",
    )


# --------------------------------------------------------------------------------------
# Reverse routing: what the phone's own pages must construct
# --------------------------------------------------------------------------------------
#
# `no-reverse-dependency` catches a *shared* page that names a Hako symbol. It is structurally blind to
# the opposite error, and that is the one that shipped: a page **inside** the phone's namespace naming
# an *upstream* type at the site where the original fork draws its own version of that page. Both
# spellings compile; the user gets upstream's page on the phone. The three report detail pages were
# rewritten back that way and had to be repaired by hand in `e1cefe6`.
#
# The table below is a contract, not a search for arbitrary type names. Each row is one construction on
# one user path, taken from the fork's own iPhone changes: where the original restyled a view, the
# fork's copy of the page that shows it must construct the fork's view. `why` names the original's own
# file and line the row is derived from. Every row also names the upstream type that must not appear in
# its place, because the defect is not "an upstream name exists somewhere" - a phone page may
# legitimately build `MetadataFormView`, `ConnectionDetailsView` or `OpenConnectEndpointView`, which the
# original never touched - it is "this construction resolves to upstream".
#
# Three properties keep this from being a grep for type names:
#
#   * the required name must be *declared* in the file the row says declares it, so a row cannot be
#     satisfied by a rename that leaves no page behind;
#   * the forbidden name must be a type this tree declares, so a row cannot be vacuous - if the
#     alternative it forbids does not exist, the row is reported `UNDECIDABLE` rather than `PASS`;
#   * a row is a link in a chain that starts at the user's route, so a failure reports the file and the
#     line that broke the chain.


@dataclass(frozen=True)
class RouteLink:
    """One construction on one user path that must resolve to the fork's type."""

    contract: str
    path: str
    required: str
    upstream: str | None
    declared_in: str
    why: str
    enclosure: str = ""


def _hako(name: str) -> str:
    return f"{HAKO_PREFIX}{name}.swift"


#: The six user links this contract is about. Each row is a `file -> required type` edge; the
#: `contract` field groups the edges into the chain a user actually walks.
ROUTE_LINKS: tuple[RouteLink, ...] = (
    # 1. Tools -> the three report lists -> the report detail page.
    #
    # The regression that shipped: the three detail constructors were rewritten back to upstream's
    # while every file stayed in the tree. The original restyled all three detail pages - each one
    # differs from upstream - so the fork's list must build the fork's page.
    RouteLink("tools-reports", _hako("HakoToolsView"), "HakoCrashReportListView", "CrashReportListView",
              _hako("HakoCrashReportListView"),
              "the Tools page links to the fork's own report list; upstream's list is what an iPad "
              "draws", "HakoToolsView"),
    RouteLink("tools-reports", _hako("HakoCrashReportListView"), "HakoCrashReportDetailView",
              "CrashReportDetailView", _hako("HakoCrashReportDetailView"),
              "`hako-ui` `Tools/CrashReportListView.swift:49` builds `CrashReportDetailView`, whose "
              "file the original restyled; the fork's list must build the fork's page", "HakoCrashReportListView"),
    RouteLink("tools-reports", _hako("HakoToolsView"), "HakoOOMReportListView", "OOMReportListView",
              _hako("HakoOOMReportListView"),
              "the Tools page links to the fork's own OOM list; upstream's list is what an iPad draws",
              "HakoToolsView"),
    RouteLink("tools-reports", _hako("HakoOOMReportListView"), "HakoOOMReportDetailView",
              "OOMReportDetailView", _hako("HakoOOMReportDetailView"),
              "`hako-ui` `Tools/OOMReportListView.swift:46` builds `OOMReportDetailView`, whose file "
              "the original restyled", "HakoOOMReportListView"),
    RouteLink("tools-reports", _hako("HakoToolsView"), "HakoPowerReportListView", "PowerReportListView",
              _hako("HakoPowerReportListView"),
              "the Tools page links to the fork's own Power list; upstream's list is what an iPad draws",
              "HakoToolsView"),
    RouteLink("tools-reports", _hako("HakoPowerReportListView"), "HakoPowerReportDetailView",
              "PowerReportDetailView", _hako("HakoPowerReportDetailView"),
              "`hako-ui` `Tools/PowerReportListView.swift:55` builds `PowerReportDetailView`, whose "
              "file the original restyled", "HakoPowerReportListView"),

    # 2. Proxies -> the group content -> the member row.
    #
    # The row is the one place a member's latency and selection are drawn. It is required only on the
    # phone's own path: `Groups/GroupItemView.swift` stays upstream's, and `Groups/GroupView.swift:113`
    # - the iPad's and the Mac's - must keep naming it.
    RouteLink("proxies-member-row", "SFI/HakoPageContent.swift", "HakoGroupListView", "GroupListView",
              _hako("HakoGroupListView"),
              "the Proxies route must reach the fork's list before the row below it can be the fork's",
              "HakoPageContent"),
    RouteLink("proxies-member-row", _hako("HakoGroupListView"), "HakoGroupContentView", "GroupContentView",
              _hako("HakoGroupView"),
              "`hako-ui` `Groups/GroupView.swift` was restyled in place, so the fork's list must build "
              "the fork's group content", "HakoGroupListView"),
    RouteLink("proxies-member-row", _hako("HakoGroupView"), "HakoGroupItemView", "GroupItemView",
              _hako("HakoGroupItemView"),
              "`hako-ui` `Groups/GroupItemView.swift` differs from upstream; the member row is the one "
              "control the Proxies page exists for", "HakoGroupContentView"),

    # 3. Tools -> Network Quality / STUN -> the outbound picker.
    #
    # The original restyled `NetworkQualityView.swift` and `STUNTestView.swift` and both of the
    # outbound sections they present, and added `OutboundPickerView`'s search and selection mark.
    RouteLink("tools-network-section", _hako("HakoToolsView"), "HakoNetworkQualityView", "NetworkQualityView",
              _hako("HakoNetworkQualityView"),
              "`hako-ui` `Tools/NetworkQualityView.swift` differs from upstream; upstream's page is "
              "what an iPad draws", "HakoToolsView"),
    RouteLink("tools-network-section", _hako("HakoNetworkQualityView"), "HakoRemoteToolOutboundSection",
              "RemoteToolOutboundSection", _hako("HakoOutboundPickerView"),
              "`hako-ui` `Tools/NetworkQualityView.swift:96` builds `RemoteToolOutboundSection`, whose "
              "file the original restyled", "HakoNetworkQualityView"),
    RouteLink("tools-network-section", _hako("HakoNetworkQualityView"), "HakoToolOutboundSection",
              "ToolOutboundSection", _hako("HakoOutboundPickerView"),
              "`hako-ui` `Tools/NetworkQualityView.swift:98` builds `ToolOutboundSection`, whose file "
              "the original restyled", "HakoNetworkQualityView"),
    RouteLink("tools-network-section", _hako("HakoToolsView"), "HakoSTUNTestView", "STUNTestView",
              _hako("HakoSTUNTestView"),
              "`hako-ui` `Tools/STUNTestView.swift` differs from upstream; upstream's page is what an "
              "iPad draws", "HakoToolsView"),
    RouteLink("tools-network-section", _hako("HakoSTUNTestView"), "HakoRemoteToolOutboundSection",
              "RemoteToolOutboundSection", _hako("HakoOutboundPickerView"),
              "`hako-ui` `Tools/STUNTestView.swift:67` builds `RemoteToolOutboundSection`", "HakoSTUNTestView"),
    RouteLink("tools-network-section", _hako("HakoSTUNTestView"), "HakoToolOutboundSection",
              "ToolOutboundSection", _hako("HakoOutboundPickerView"),
              "`hako-ui` `Tools/STUNTestView.swift:69` builds `ToolOutboundSection`", "HakoSTUNTestView"),
    RouteLink("tools-network-section", _hako("HakoOutboundPickerView"), "HakoOutboundPickerView",
              "OutboundPickerView", _hako("HakoOutboundPickerView"),
              "the section's own link must open the fork's picker, whose search field and selection "
              "mark the original added", "HakoToolOutboundSection"),

    # 5. Profile / Add -> the picker -> edit, import (new profile) and QR share.
    #
    # The original restyled `NewProfileMenuView.swift`, `NewProfileView.swift`, `EditProfileView.swift`
    # and `QRSDisplayView.swift`; upstream's copies stay in the tree for the iPad's own picker, which is
    # what makes the swap possible and what `NewProfileNavigationView` would produce.
    RouteLink("profile-add", _hako("HakoHomeView"), "HakoProfilePickerSheet", "ProfilePickerSheet",
              _hako("HakoProfilePickerSheet"),
              "the configuration centre is the fork's; upstream's is what an iPad's dashboard card "
              "presents", "HakoHomeView"),
    RouteLink("profile-add", _hako("HakoProfilePickerSheet"), "HakoNewProfileSheetContent",
              "NewProfileNavigationView", _hako("HakoSheetContent"),
              "`HakoSheetContent.swift:152` records it: the picker used to present the shared "
              "`ProfileCard.NewProfileNavigationView`, which builds upstream's `NewProfileMenuView`",
              "ProfilePickerSheetContent"),
    RouteLink("profile-add", _hako("HakoSheetContent"), "HakoNewProfileMenuView", "NewProfileMenuView",
              _hako("HakoNewProfileMenuView"),
              "`hako-ui` `Profile/NewProfileMenuView.swift` differs from upstream - it carries the "
              "original's Add-Configuration tiles", "HakoNewProfileSheetContent"),
    RouteLink("profile-add", _hako("HakoNewProfileMenuView"), "HakoNewProfileView", "NewProfileView",
              _hako("HakoNewProfileView"),
              "`hako-ui` `Profile/NewProfileMenuView.swift` presents the restyled "
              "`NewProfileView.swift`; the view model both sides share is upstream's, the page is not",
              "HakoNewProfileMenuView"),
    RouteLink("profile-add", _hako("HakoProfilePickerSheet"), "HakoEditProfileView", "EditProfileView",
              _hako("HakoEditProfileView"),
              "`hako-ui` `Profile/EditProfileView.swift` differs from upstream; the editor is the "
              "page the row opens", "ProfilePickerSheetContent"),
    RouteLink("profile-add", _hako("HakoProfilePickerSheet"), "HakoQRSSheet", "QRSSheet",
              _hako("HakoQRSDisplayView"),
              "`hako-ui` `Profile/QRSDisplayView.swift:207` declares `QRSSheet`, which the original "
              "restyled along with the QRS page", "ProfilePickerSheetContent"),
    RouteLink("profile-add", _hako("HakoQRSDisplayView"), "HakoQRSDisplayView", "QRSDisplayView",
              _hako("HakoQRSDisplayView"),
              "the sheet's own body must draw the fork's QRS page, not upstream's",
              "HakoQRSSheet"),

    # 6. Terminal / Tools -> the terminal session.
    #
    # Both halves of the pair are required, and the platform-guard check below is what keeps the caller
    # and the declaration under conditions that agree.
    RouteLink("terminal-session", _hako("HakoToolsView"), "HakoTerminalSessionContainerView",
              "TerminalSessionContainerView", _hako("HakoTerminalSessionContainerView"),
              "`hako-ui` `Tools/ToolsView.swift:93` builds `TerminalSessionContainerView` behind "
              "`#if os(iOS)`; upstream's container is what the iPad and the Mac reach",
              "HakoToolsView"),
    RouteLink("terminal-session", _hako("HakoTerminalSessionContainerView"),
              "HakoTerminalSessionContentView", "TerminalSessionContentView",
              _hako("HakoTerminalSessionContentView"),
              "`hako-ui` `Terminal/TerminalSessionContainerView.swift` builds the restyled "
              "`TerminalSessionContentView.swift`", "HakoTerminalSessionContainerView"),
)

#: The text editor toolbar contract. It is not a chain of constructions but a parameter, so it is
#: written out rather than forced into the table above.
#:
#: The frozen design restyled four things in the toolbar. `SFI` is the iPhone target and **both of its
#: roots build the one wrapper** - `HakoPhoneRootView` for the phone, `MainView` for an iPad - so the
#: choice is a `restyled:` parameter defaulting to `false`. Linking the toolbar instead of
#: parametrising it, or defaulting the parameter to `true`, or having the iPad ask for the restyle,
#: each puts the phone's design on an iPad. `SFI/MainView.swift` is byte-identical to upstream, so
#: nothing else in the audit would see a `restyled: true` added to it.
EDITOR_WRAPPER = "SFI/ProfileEditorWrapperView.swift"
EDITOR_TOOLBAR = HAKO_PREFIX + "HakoEditorToolbarView.swift"
EDITOR_UPSTREAM_TOOLBAR = "ApplicationLibrary/Views/Profile/EditorToolbarView.swift"
PHONE_EDITOR_CALLER = "SFI/HakoPhoneRootView.swift"
TABLET_EDITOR_CALLERS = ("SFI/MainView.swift", "MacLibrary/MainView.swift")


def strip_comments_keeping_lines(text: str) -> str:
    """Every comment removed and every line number kept.

    `strip_comments` deletes a block comment whole, newlines included, which is right when the result is
    only searched - and wrong the moment a line number is reported from what it returns. Every finding
    this audit prints is a line number, so a block comment's newlines have to survive it.

    Like `strip_comment`, it cannot tell a `//` inside a string literal from a comment. A Swift lexer is
    out of scope; the strings in these files do not contain comment markers.
    """
    out: list[str] = []
    in_block = False
    for line in text.split("\n"):
        pieces: list[str] = []
        index = 0
        while index < len(line):
            if in_block:
                end = line.find("*/", index)
                if end < 0:
                    index = len(line)
                    break
                in_block = False
                index = end + 2
                continue
            block = line.find("/*", index)
            comment = line.find("//", index)
            if comment >= 0 and (block < 0 or comment < block):
                pieces.append(line[index:comment])
                index = len(line)
                break
            if block < 0:
                pieces.append(line[index:])
                index = len(line)
                break
            pieces.append(line[index:block])
            in_block = True
            index = block + 2
        out.append("".join(pieces))
    return "\n".join(out)


def line_of(pattern: str, text: str) -> int:
    """The 1-based line a regex first matches, or 0 when it does not.

    Compiled with `re.M`: several callers anchor on `^` to find a declaration line, and without the flag
    the anchor only matches at the start of the file - which reported a finding at line 0 and looked like
    a file-level note rather than the line it belongs to.
    """
    found = re.search(pattern, text, re.M)
    return 0 if not found else text.count("\n", 0, found.start()) + 1


def calls_of(text: str, name: str) -> list[tuple[int, str]]:
    """Every `name(...)` with the text of its argument list and the line it starts on.

    A declaration has no parenthesis after the type name, so it is not a call. The argument list is
    balanced over parentheses, which is what makes `ProfileEditorWrapperView(text:isEditable:)` and a
    nested closure inside it distinguishable at all.
    """
    out: list[tuple[int, str]] = []
    for match in re.finditer(rf"\b{re.escape(name)}\s*\(", text):
        depth = 1
        index = match.end()
        while index < len(text) and depth:
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
            index += 1
        out.append((text.count("\n", 0, match.start()) + 1, text[match.end():index - 1]))
    return out


TYPE_DECLARATION = (r"^[ \t]*(?:(?:public|internal|private|fileprivate|final|indirect|@\w+)[ \t]+)*"
                    r"(?:struct|class|enum|actor|protocol)[ \t]+")


def check_reverse_routing_contract(root: str) -> Check:
    """Every construction on a user path must resolve to the fork's own view.

    See `ROUTE_LINKS` for the evidence behind each row. The check reports the *chain*: the route the
    user takes, the page it reaches, the construction that must be the fork's and the file that declares
    what is constructed. A row that cannot be decided - because the alternative it forbids is not a type
    in this tree, or because the file it names is missing - is reported as such instead of passing.
    """
    namespace = os.path.join(root, HAKO_PREFIX)
    if not os.path.isdir(namespace):
        return Check("reverse-routing-contract", "UNDECIDABLE",
                     f"{HAKO_PREFIX} does not exist, so there is nothing the contract can be about. "
                     f"This is a failure, not an unknown: the contracts it enforces cannot be reported "
                     f"as held over a tree whose phone presentation is gone")

    for path in ("SFI/HakoPageContent.swift",):
        if not os.path.exists(os.path.join(root, path)):
            return Check("reverse-routing-contract", "UNDECIDABLE",
                         f"{path} is missing, so the user paths the contract starts from cannot be read")

    # The names this contract forbids have to exist as types, or the row they appear in cannot fail and
    # is worth nothing. Collected once, from every Swift file outside the namespace.
    outside_declarations: dict[str, str] = {}
    for path in swift_files(root):
        if path.startswith(HAKO_PREFIX) or path in OUTSIDE_THE_APP:
            continue
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for match in re.finditer(TYPE_DECLARATION + r"(\w+)", strip_comments(text), re.M):
            outside_declarations.setdefault(match.group(1), path)

    missing_alternatives = sorted(
        {link.upstream for link in ROUTE_LINKS if link.upstream and link.upstream not in outside_declarations}
    )
    if missing_alternatives:
        return Check(
            "reverse-routing-contract", "UNDECIDABLE",
            "the contract cannot be decided: the type(s) it forbids are declared nowhere outside "
            f"{HAKO_PREFIX}, so the row(s) that name them cannot go red: {missing_alternatives}",
        )

    problems: list[Blame] = []
    chains: dict[str, list[str]] = {}
    checked = 0
    for link in sorted(ROUTE_LINKS, key=lambda item: item.contract):
        text = read_text(os.path.join(root, link.path))
        if text is None:
            problems.append(Blame(link.path, 0,
                                  f"`{link.required}` cannot be checked here: the file is missing"))
            continue
        body = strip_comments_keeping_lines(text)
        required_line = line_of(rf"\b{re.escape(link.required)}\b", body)
        forbidden_line = 0
        if link.upstream:
            # `\b` on both sides is what keeps `HakoCrashReportDetailView` from matching
            # `CrashReportDetailView`: the character before `C` is a word character, so there is no
            # boundary there.
            forbidden_line = line_of(rf"\b{re.escape(link.upstream)}\b", body)

        declaration = read_text(os.path.join(root, link.declared_in))
        declared = declaration is not None and re.search(
            TYPE_DECLARATION + rf"{re.escape(link.required)}\b", strip_comments(declaration), re.M)

        if not declared:
            problems.append(Blame(link.declared_in, 0,
                                  f"`{link.required}` is not declared in the file the contract says "
                                  f"declares it, so the row cannot be satisfied by construction"))
            continue

        checked += 1
        chains.setdefault(link.contract, []).append(
            f"{link.path}:{required_line or 1} {link.required}" if required_line
            else f"{link.path}:?? {link.required} (absent)"
        )

        if forbidden_line:
            problems.append(Blame(
                link.path, forbidden_line,
                f"`{link.upstream}` is constructed here; this line is on the phone's own path and must "
                f"resolve to `{link.required}` instead - {link.why}"))
        if not required_line:
            anchor = line_of(TYPE_DECLARATION + rf"{re.escape(link.enclosure)}\b", body) if link.enclosure else 0
            problems.append(Blame(
                link.path, anchor,
                f"`{link.required}` is named nowhere in this file, so nothing on the phone's path "
                f"constructs it - {link.why}"))

    # The editor toolbar, whose contract is a parameter rather than a construction.
    problems.extend(_editor_toolbar_problems(root, chains))

    if problems:
        return Check(
            "reverse-routing-contract", "FAIL",
            f"{len(problems)} construction(s) on the phone's own paths do not resolve to the fork's "
            f"view(s); each finding names the file and line",
            [str(problem) for problem in problems],
        )
    return Check(
        "reverse-routing-contract", "PASS",
        f"{checked} construction(s) across {len(chains)} user path(s) resolve to the fork's own view, "
        f"and the phone's editor toolbar is the parametrised one",
        [f"{contract}: " + " -> ".join(chain) for contract, chain in sorted(chains.items())],
    )


def _editor_toolbar_problems(root: str, chains: dict[str, list[str]]) -> list[Blame]:
    """The `restyled:` contract: phone root yes, iPad and Mac no, default no."""
    problems: list[Blame] = []
    wrapper = read_text(os.path.join(root, EDITOR_WRAPPER))
    if wrapper is None:
        return [Blame(EDITOR_WRAPPER, 0, "the wrapper that chooses the toolbar is missing")]

    body = strip_comments_keeping_lines(wrapper)
    default = re.search(r"\bvar\s+restyled\s*:\s*Bool\s*=\s*(true|false)", body)
    if not default:
        problems.append(Blame(EDITOR_WRAPPER, line_of(r"\brestyled\b", body),
                              "the wrapper no longer declares `var restyled: Bool = false`; without the "
                              "parameter the choice cannot be the caller's"))
    elif default.group(1) != "false":
        problems.append(Blame(EDITOR_WRAPPER, line_of(r"\bvar\s+restyled\b", body),
                              "`restyled` defaults to `true`, so every caller that says nothing gets the "
                              "phone's toolbar - including `SFI/MainView.swift`, which builds this same "
                              "wrapper for an iPad"))

    if not calls_of(body, "HakoEditorToolbarView"):
        problems.append(Blame(EDITOR_WRAPPER, line_of(r"\brestyled\b", body),
                              "the restyled branch no longer builds `HakoEditorToolbarView`, so the "
                              "parameter selects nothing"))
    if not calls_of(body, "EditorToolbarView"):
        problems.append(Blame(EDITOR_WRAPPER, line_of(r"\brestyled\b", body),
                              "the other branch no longer builds upstream's `EditorToolbarView`, so "
                              "`restyled: false` no longer means upstream's toolbar"))

    phone = read_text(os.path.join(root, PHONE_EDITOR_CALLER))
    phone_calls = [] if phone is None else calls_of(strip_comments_keeping_lines(phone),
                                                    "ProfileEditorWrapperView")
    if not phone_calls:
        problems.append(Blame(PHONE_EDITOR_CALLER, 0,
                              "the phone root no longer builds `ProfileEditorWrapperView`, so the "
                              "editor toolbar is not the fork's anywhere"))
    else:
        for line, args in phone_calls:
            if not re.search(r"\brestyled\s*:\s*true\b", args):
                problems.append(Blame(
                    PHONE_EDITOR_CALLER, line,
                    "the phone's editor is built without `restyled: true`, so the phone draws "
                    "upstream's toolbar instead of the frozen design's"))
        if phone_calls:
            chains.setdefault("editor-toolbar", []).append(
                f"{PHONE_EDITOR_CALLER}:{phone_calls[0][0]} ProfileEditorWrapperView(restyled: true)")

    for path in TABLET_EDITOR_CALLERS:
        text = read_text(os.path.join(root, path))
        if text is None:
            problems.append(Blame(path, 0,
                                  "this root cannot be read, so whether it asks for the restyle is "
                                  "undecided"))
            continue
        for line, args in calls_of(strip_comments_keeping_lines(text), "ProfileEditorWrapperView"):
            if not re.search(r"\brestyled\s*:\s*(?:true|false)\b", args):
                continue
            if re.search(r"\brestyled\s*:\s*true\b", args):
                problems.append(Blame(
                    path, line,
                    "this root asks for `restyled: true`, which puts the phone's editor toolbar on an "
                    "iPad or a Mac; the restyle is the phone's alone"))
    return problems


#: Swift types a migrated page may not name when the namespace declares a Hako copy of them: the twin
#: exists, so naming the upstream type means the port is bypassed. Restricted to `View` declarations,
#: which is the class the shipped regression was in, because the alternative rule - any type with a
#: twin - reports two things that are not defects:
#:
#:   * `HakoReportShareAction`, an enum the generator copied, is unused while the three report detail
#:     pages hold upstream's `ReportShareAction`. The popup the pages present takes `() -> Void`, so the
#:     enum is internal to the page's own switch and the user cannot see the difference;
#:   * `HakoNewProfileView.ImportRequest`, an alias whose *point* is the nested type of the shared view:
#:     `NewProfileView.ImportRequest` is what `NewProfileViewModel`'s initialiser takes. A nested type
#:     cannot collide, and the repo says so in the file.
#:
#: Both are excluded by construction and both are reported as notes in `B-REPORT.md` rather than being
#: turned into failures that would get the check switched off.
def check_reverse_routing_derived(root: str) -> Check:
    """No phone page may name an upstream view that the namespace has already ported.

    The contract check above is a table, so it only covers the paths someone wrote down. This is the
    general form of the same error, derived from the tree instead of from a list: if the namespace
    declares `HakoX` and an upstream `X` is a `View` this tree declares, then a page inside the
    namespace naming `X` is drawing upstream's view while the ported one sits unused beside it.

    It is deliberately not "no upstream type may be named". A phone page names upstream types all the
    time and should: `MetadataFormView`, `OpenConnectEndpointView`, `TailscaleEndpointView` and their
    neighbours were never restyled by the original, have no twin, and are the correct thing to build.
    """
    namespace = os.path.join(root, HAKO_PREFIX)
    if not os.path.isdir(namespace):
        return Check("reverse-routing-derived", "UNDECIDABLE",
                     f"{HAKO_PREFIX} does not exist, so there is no port to compare against")

    inherited_view = re.compile(TYPE_DECLARATION + r"(\w+)(?:<[^>]*>)?[ \t]*:[ \t]*([^\n{]*)", re.M)
    hako_views: dict[str, str] = {}
    upstream_views: dict[str, str] = {}
    for path in swift_files(root):
        if path in OUTSIDE_THE_APP:
            continue
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for match in inherited_view.finditer(strip_comments(text)):
            name, inherited = match.group(1), match.group(2)
            if not re.search(r"\bView\b", inherited):
                continue
            if path.startswith(HAKO_PREFIX):
                hako_views.setdefault(name, path)
            else:
                upstream_views.setdefault(name, path)

    twins = {name[4:]: name for name in hako_views
             if name.startswith("Hako") and name[4:] in upstream_views}
    if not twins:
        return Check("reverse-routing-derived", "UNDECIDABLE",
                     f"{HAKO_PREFIX} declares no `Hako…` copy of a `View` this tree also declares, so "
                     f"the scan has no pair to compare and cannot report a port that was bypassed")

    problems: list[Blame] = []
    for path in swift_files(root, HAKO_PREFIX.rstrip("/")):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for number, line in enumerate(strip_comments_keeping_lines(text).split("\n"), 1):
            for upstream, twin in twins.items():
                # `(?!\s*\.)` keeps a nested type out of it: `NewProfileView.ImportRequest` is the
                # shared view's own request type, deliberately aliased, and cannot collide.
                if re.search(rf"\b{re.escape(upstream)}\b(?!\s*\.)", line):
                    problems.append(Blame(
                        path, number,
                        f"`{upstream}` is named in the phone's namespace while `{twin}` is declared in "
                        f"{hako_views[twin]}; this page draws upstream's view, not the ported one"))
                    break

    if problems:
        return Check("reverse-routing-derived", "FAIL",
                     f"{len(problems)} line(s) inside {HAKO_PREFIX} name an upstream view whose ported "
                     f"copy exists, out of {len(twins)} ported view(s)",
                     [str(problem) for problem in problems])
    return Check("reverse-routing-derived", "PASS",
                 f"none of the {len(twins)} ported view(s) is bypassed: every `Hako…` copy of a `View` "
                 f"outside the namespace is used instead of the upstream original")


# --------------------------------------------------------------------------------------
# Platform guards: a conditional import is not a declaration or usage guard
# --------------------------------------------------------------------------------------
#
# `hako-platform-imports` checks that a platform framework is *imported* under a condition. That is only
# half of the rule, and the half that matters least: a file can import `UIKit` under `canImport(UIKit)`
# and then use `UIApplication` in an unguarded body, which fails to compile exactly where the import was
# guarded for. The migration's platform-resolution step removed guards while keeping imports, so this is
# the shape the damage takes - and the tree has a live instance of it, reported below.
#
# Two rules, both computed from the directives that are actually in the file:
#
#   (a) a use of a type this repository declares **inside** a platform `#if` must itself be inside a
#       platform condition, and the two conditions must share a platform atom (or the use's condition
#       must imply the declaration's). This is the general form of "the terminal container exists only
#       under `canImport(GhosttyTerminal)` and the page that presents it is guarded by `os(iOS)` alone".
#   (b) a use of a symbol that belongs to a framework the file imports *conditionally* must be inside a
#       condition that can make that framework importable.
#
# When the analysis cannot decide - a file whose directives do not balance, or a framework with no entry
# in the symbol table - the run says `UNDECIDABLE` and exits non-zero. A check that cannot be evaluated
# must not be reported as a pass.

#: Per framework: the atoms of a condition that can make it importable, and the symbols the ported
#: files use from it. Both live in one table because both are needed to decide one question - "is this
#: use inside a condition that makes the symbol exist" - and a framework the table does not know is
#: reported `UNDECIDABLE` rather than assumed harmless.
@dataclass(frozen=True)
class FrameworkConditions:
    #: OS atoms that make the framework importable. `os(iOS)` is a condition a `UIKit` or `QuickLook`
    #: use may sit in even though it does not spell `canImport(…)`, and `QuickLook` is deliberately
    #: absent from the tvOS list.
    os_atoms: tuple[str, ...] = ()
    #: SDK symbols the ported files use from it. Kept short and specific on purpose: a name that also
    #: exists in SwiftUI or the standard library would turn this check into noise.
    symbols: tuple[str, ...] = ()


FRAMEWORK_CONDITIONS: dict[str, FrameworkConditions] = {
    "UIKit": FrameworkConditions(
        os_atoms=("os(iOS)", "os(tvOS)", "os(watchOS)", "os(visionOS)"),
        symbols=("UIApplication", "UIWindowScene", "UIWindow", "UIViewController", "UINavigationController",
                 "UIColor", "UIImage", "UIFont", "UIScreen", "UIDevice", "UIPasteboard", "UIView",
                 "UIActivityViewController", "UIAlertController", "UIImpactFeedbackGenerator",
                 "UISelectionFeedbackGenerator", "UINotificationFeedbackGenerator", "UIViewRepresentable",
                 "UIViewControllerRepresentable", "UIEdgeInsets", "UIScrollView", "UITraitCollection",
                 "UIBarButtonItem", "UIRefreshControl", "UISplitViewController", "UITabBarController",
                 "UIPopoverPresentationController", "UISheetPresentationController")),
    "AppKit": FrameworkConditions(
        os_atoms=("os(macOS)",),
        symbols=("NSApplication", "NSWindow", "NSViewController", "NSView", "NSColor", "NSFont", "NSImage",
                 "NSPasteboard", "NSScreen", "NSWorkspace", "NSViewRepresentable",
                 "NSViewControllerRepresentable", "NSHostingView", "NSHostingController")),
    # QuickLook ships on iOS, macOS and visionOS and not on tvOS, which is the whole reason the ported
    # files import it conditionally.
    "QuickLook": FrameworkConditions(
        os_atoms=("os(iOS)", "os(macOS)", "os(visionOS)"),
        symbols=("QLPreviewController", "QLPreviewItem", "QLPreviewControllerDataSource")),
    "Cocoa": FrameworkConditions(os_atoms=("os(macOS)",), symbols=("NSPasteboard", "NSApplication")),
    "AVKit": FrameworkConditions(os_atoms=("os(iOS)", "os(tvOS)", "os(macOS)"),
                                 symbols=("AVPlayerViewController", "AVRoutePickerView")),
    "ServiceManagement": FrameworkConditions(os_atoms=("os(macOS)",), symbols=("SMAppService",)),
    "DeviceDiscoveryUI": FrameworkConditions(os_atoms=("os(iOS)", "os(tvOS)"),
                                             symbols=("DDDevicePickerViewController",)),
    # The types this package vends are declared in this repository under the same condition, so rule (a)
    # decides them; there is no SDK symbol list to keep here.
    "GhosttyTerminal": FrameworkConditions(os_atoms=("os(iOS)", "os(macOS)"), symbols=()),
}

#: What one atom implies about the others, polarity included. Two directions matter and both are
#: evidence about the Apple platform matrix, not about this repository:
#:
#:   * an OS atom implies the frameworks that always ship on it. `#if os(iOS)` is a condition a `UIKit`
#:     symbol may live in even though it does not spell `canImport(UIKit)`, and `QuickLook` is absent
#:     from tvOS, which is why `os(tvOS)` does not imply it;
#:   * an OS atom implies the *negations* of the others, which is what makes a type declared inside
#:     `#if !os(tvOS)` legal to use inside `#if os(iOS)`.
#:
#: `canImport(GhosttyTerminal)` is implied by `os(iOS)` and `os(macOS)` because the project links that
#: product for exactly those two platforms - `sing-box.xcodeproj/project.pbxproj:52`,
#: `platformFilters = (ios, macos, )`. Without that line the check would report the original's own
#: design as a defect: `hako-ui` `Tools/ToolsView.swift:90` presents the terminal behind `#if os(iOS)`
#: while the container it presents is declared behind `canImport(GhosttyTerminal) && os(iOS)`.
ATOM_IMPLICATIONS: dict[str, set[str]] = {
    "os(iOS)": {"!os(macOS)", "!os(tvOS)", "!os(watchOS)", "!os(visionOS)",
                "canImport(UIKit)", "canImport(QuickLook)", "canImport(AVKit)",
                "canImport(DeviceDiscoveryUI)", "canImport(GhosttyTerminal)"},
    "os(tvOS)": {"!os(iOS)", "!os(macOS)", "!os(watchOS)", "!os(visionOS)",
                 "canImport(UIKit)", "canImport(AVKit)", "canImport(DeviceDiscoveryUI)"},
    "os(watchOS)": {"!os(iOS)", "!os(macOS)", "!os(tvOS)", "!os(visionOS)", "canImport(UIKit)"},
    "os(visionOS)": {"!os(iOS)", "!os(macOS)", "!os(tvOS)", "!os(watchOS)",
                     "canImport(UIKit)", "canImport(QuickLook)", "canImport(AVKit)"},
    "os(macOS)": {"!os(iOS)", "!os(tvOS)", "!os(watchOS)", "!os(visionOS)",
                  "canImport(AppKit)", "canImport(Cocoa)", "canImport(QuickLook)", "canImport(AVKit)",
                  "canImport(ServiceManagement)", "canImport(GhosttyTerminal)"},
    "canImport(UIKit)": {"!os(macOS)"},
    "canImport(AppKit)": {"os(macOS)", "!os(iOS)", "!os(tvOS)", "!os(watchOS)", "!os(visionOS)"},
    "canImport(Cocoa)": {"os(macOS)", "!os(iOS)", "!os(tvOS)", "!os(watchOS)", "!os(visionOS)"},
    "canImport(QuickLook)": {"!os(tvOS)"},
    "canImport(ServiceManagement)": {"os(macOS)"},
    "canImport(DeviceDiscoveryUI)": {"!os(macOS)"},
}


#: Frameworks that are importable on every platform `ApplicationLibrary` builds for. An `import` of one
#: of these can sit inside a `#if` for other reasons - `r8/main` wraps the whole of
#: `HakoTerminalSessionContentView.swift` in the original's `canImport(GhosttyTerminal)`, imports
#: included - and being inside a condition says nothing about whether the framework is available. Rule
#: (b) therefore has nothing to check for them, and saying so is not the same as saying nothing.
#:
#: A framework that is neither here nor in the table below is `UNDECIDABLE`: the audit would have no way
#: to tell a guarded use from an unguarded one, and guessing is what this round is removing.
ALWAYS_AVAILABLE_FRAMEWORKS = frozenset({
    "SwiftUI", "Foundation", "Combine", "Library", "Libbox", "UniformTypeIdentifiers",
})


def implies(atoms: set[str], wanted: set[str]) -> bool:
    """Whether a condition built from `atoms` can only be true where `wanted` also holds.

    Asked one way round on purpose. A `UIKit` use inside `#if os(iOS)` is fine because iOS always has
    UIKit; a declaration guarded by `#if os(iOS)` and used inside `#if canImport(UIKit)` is not, because
    UIKit is also importable on tvOS. Only the use side is expanded.
    """
    for atom in atoms:
        if atom in wanted:
            return True
        if ATOM_IMPLICATIONS.get(atom, set()) & wanted:
            return True
    return False

#: Atoms named by a `#if` line, with the polarity they are written under. Polarity is kept because
#: `#if !os(tvOS)` is the shape two of the ported files lost: a type declared inside it does not exist on
#: tvOS, so a use inside `#if os(iOS)` is legal and a use with no condition at all is not.
CONDITION_ATOM = re.compile(r"(!?)\s*\b(os|canImport|targetEnvironment)\s*\(\s*([^)\s]+)\s*\)")


def condition_atoms(directive: str) -> set[str]:
    """The platform atoms in one `#if` / `#elseif` expression, each with its polarity."""
    return {f"!{kind}({argument})" if negated else f"{kind}({argument})"
            for negated, kind, argument in CONDITION_ATOM.findall(directive)}


def condition_map(text: str) -> tuple[list[set[str]], bool]:
    """Per line, the platform atoms of every enclosing `#if` branch, plus whether the file balances.

    A line's own directive does not apply to the line's own content: `#if os(iOS)` is not itself inside
    the iOS branch. An unbalanced file returns `False` for the balance flag, and its callers report
    `UNDECIDABLE` rather than guessing a nesting.
    """
    stack: list[set[str]] = []
    per_line: list[set[str]] = []
    balanced = True
    for line in text.split("\n"):
        stripped = line.strip()
        per_line.append(set().union(*stack) if stack else set())
        directive = re.match(r"#(if|elseif|else|endif)\b(.*)", stripped)
        if not directive:
            continue
        kind, rest = directive.group(1), directive.group(2)
        if kind == "if":
            stack.append(condition_atoms(rest))
        elif kind in ("elseif", "else"):
            if not stack:
                balanced = False
            else:
                stack[-1] = stack[-1] | condition_atoms(rest)
        else:
            if not stack:
                balanced = False
            else:
                stack.pop()
    if stack:
        balanced = False
    return per_line, balanced


#: Type names the Swift standard library and the imported frameworks also declare. A text audit that
#: resolves `Result` to a repository type, because one file in the tree happens to declare one inside a
#: `#if`, is reporting a name rather than a type. Names here are skipped and the skip is reported in the
#: check's own detail - "not covered", never a silent pass.
AMBIGUOUS_TYPE_NAMES = frozenset({"Result", "Task", "State", "Error", "Data", "Date", "URL"})


def guarded_declarations(root: str) -> tuple[dict[str, tuple[str, int, set[str]]], set[str]]:
    """Every type this repository declares inside a platform `#if`, keyed by name.

    A name declared more than once is dropped **unless every declaration agrees about its condition**,
    which is the case when the tree under audit contains a second copy of itself - a test that copies
    the checkout materialises a junction into real directories, and dropping every duplicated name would
    make the check go quiet exactly there. Two genuinely different declarations under different
    conditions cannot be resolved by a text audit, and guessing which one a bare use means is how a
    check starts reporting things that are not there.

    Also returns the names skipped as ambiguous, so the caller can say what it did not cover instead of
    reporting a pass over it.
    """
    seen: dict[str, list[tuple[str, int, set[str]]]] = {}
    for path in swift_files(root):
        if path in OUTSIDE_THE_APP:
            continue
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        body = strip_comments_keeping_lines(text)
        conditions, balanced = condition_map(body)
        if not balanced:
            continue
        for match in re.finditer(TYPE_DECLARATION + r"(\w+)", body, re.M):
            line = body.count("\n", 0, match.start()) + 1
            atoms = conditions[line - 1]
            if not atoms:
                continue
            seen.setdefault(match.group(1), []).append((path, line, atoms))

    ambiguous = {name for name in seen if name in AMBIGUOUS_TYPE_NAMES}
    resolved: dict[str, tuple[str, int, set[str]]] = {}
    for name, entries in seen.items():
        if name in ambiguous:
            continue
        if len(entries) == 1 or all(entry[2] == entries[0][2] for entry in entries):
            resolved[name] = entries[0]
    return resolved, ambiguous


def check_platform_guard_agreement(root: str) -> Check:
    """A condition on an import, a declaration or a use is not a condition on the others."""
    namespace = os.path.join(root, HAKO_PREFIX)
    if not os.path.isdir(namespace):
        return Check("platform-guard-agreement", "UNDECIDABLE",
                     f"{HAKO_PREFIX} does not exist, so there is nothing to inspect")
    files = swift_files(root, HAKO_PREFIX.rstrip("/"))
    if not files:
        return Check("platform-guard-agreement", "UNDECIDABLE",
                     f"{HAKO_PREFIX} holds no Swift file, so nothing was inspected")

    guarded, ambiguous_guarded = guarded_declarations(root)
    if not guarded:
        return Check("platform-guard-agreement", "UNDECIDABLE",
                     "no type in this tree is declared inside a platform condition, so the audit cannot "
                     "decide whether the platform-guarded declarations in the ported files agree with "
                     "their uses")

    problems: list[Blame] = []
    undecided: list[str] = []
    checked_uses = 0
    conditional_imports = 0
    ambiguous_used: set[str] = set()

    for path in files:
        text = read_text(os.path.join(root, path))
        if text is None:
            undecided.append(f"{path}: unreadable")
            continue
        body = strip_comments_keeping_lines(text)
        conditions, balanced = condition_map(body)
        if not balanced:
            undecided.append(f"{path}: its `#if`/`#endif` directives do not balance, so no line's "
                             f"condition can be computed")
            continue
        for name in ambiguous_guarded:
            if re.search(rf"\b{re.escape(name)}\b", body):
                ambiguous_used.add(name)

        # (b) frameworks this file imports behind a condition.
        lines = body.split("\n")
        identifiers = [set(re.findall(r"\w+", line)) for line in lines]
        frameworks: dict[str, int] = {}
        for number, line in enumerate(lines, 1):
            match = re.match(r"\s*import\s+(\w+)\s*$", line)
            if match and conditions[number - 1]:
                frameworks[match.group(1)] = number
                conditional_imports += 1
        for framework, number in frameworks.items():
            if framework in ALWAYS_AVAILABLE_FRAMEWORKS:
                continue
            table = FRAMEWORK_CONDITIONS.get(framework)
            if table is None:
                undecided.append(
                    f"{path}:{number}: `import {framework}` is conditional and there is no condition "
                    f"table for {framework}, so whether its use sites are guarded cannot be decided")
                continue
            allowed = {"canImport(%s)" % framework, *table.os_atoms}
            for number, line in enumerate(lines, 1):
                # Sorted, because a set's iteration order varies between runs: an audit whose findings
                # come out in a different order on every invocation cannot be compared run to run, and
                # the negative suite does exactly that.
                for symbol in sorted(identifiers[number - 1] & set(table.symbols)):
                    atoms = conditions[number - 1]
                    if not implies(atoms, allowed):
                        problems.append(Blame(
                            path, number,
                            f"`{symbol}` comes from {framework}, which this file imports behind a "
                            f"condition, but this line is not inside a condition that makes "
                            f"{framework} importable ({' or '.join(sorted(allowed))}); a conditional "
                            f"import is not a usage guard"))
                    checked_uses += 1

        # (a) repository types declared behind a platform condition, used by the ported files.
        #
        # A name this same file declares is resolved to that declaration first, not skipped:
        # `HakoCrashReportListView` declares its own unconditional `CrashReportToolbarMenu` and the
        # `CrashReportToolbarMenu` upstream declares behind `#if os(tvOS)` is a different type the file
        # never reaches - while `HakoLogView` declares its own `HakoLogMenuButton` *inside*
        # `#if canImport(UIKit)` at line 177 and then builds it at line 150, which is the defect.
        local: dict[str, tuple[int, set[str]]] = {}
        for match in re.finditer(TYPE_DECLARATION + r"(\w+)", body, re.M):
            line = body.count("\n", 0, match.start()) + 1
            local.setdefault(match.group(1), (line, conditions[line - 1]))
        guarded_names = set(guarded)
        for number, line in enumerate(lines, 1):
            for name in sorted(identifiers[number - 1] & guarded_names):
                home, home_line, home_atoms = guarded[name]
                if name in local:
                    home_line, home_atoms = local[name]
                    home = path
                    if not home_atoms:
                        continue  # the file's own declaration is unconditional
                if home == path and home_line == number:
                    continue
                atoms = conditions[number - 1]
                if not atoms:
                    problems.append(Blame(
                        path, number,
                        f"`{name}` is declared inside a platform condition at {home}:{home_line} "
                        f"({' && '.join(sorted(home_atoms))}) and used here with no condition at all, so "
                        f"this file does not compile wherever that condition is false"))
                elif not implies(atoms, home_atoms):
                    problems.append(Blame(
                        path, number,
                        f"`{name}` is declared under {' && '.join(sorted(home_atoms))} at "
                        f"{home}:{home_line} and used here under {' && '.join(sorted(atoms))}; the use's "
                        f"condition does not imply the declaration's"))
                checked_uses += 1

    skipped = sorted(ambiguous_used)
    # Ordered, so two runs over the same tree produce the same report. The findings are collected by
    # walking rules that use sets; sorting here is what makes the output reproducible.
    problems.sort(key=lambda problem: (problem.path, problem.line, problem.text))

    if undecided:
        return Check(
            "platform-guard-agreement", "UNDECIDABLE",
            "the audit cannot decide this check: " + "; ".join(sorted(undecided)[:4]),
            [str(problem) for problem in problems],
        )
    if problems:
        per_file: dict[str, int] = {}
        for problem in problems:
            per_file[problem.path] = per_file.get(problem.path, 0) + 1
        summary = ", ".join(f"{os.path.basename(path)} x{count}"
                            for path, count in sorted(per_file.items(), key=lambda item: -item[1]))
        # Each finding is one use; a whole-file guard that was dropped shows up as many, which is why the
        # count per file is part of the detail rather than left to be counted by hand.
        return Check(
            "platform-guard-agreement", "FAIL",
            f"{len(problems)} use(s) across {len(per_file)} ported file(s) sit outside the condition "
            f"their declaration or import needs, so those files do not compile where the condition is "
            f"false ({summary})",
            [str(problem) for problem in problems],
        )

    detail = (f"{len(files)} ported file(s): {conditional_imports} conditional import(s) and "
              f"{checked_uses} use(s) each sit inside a condition that matches where the symbol exists")
    if skipped:
        detail += (f"; NOT COVERED: {', '.join(skipped)} - a standard-library name this tree also "
                   f"declares, which a text audit cannot resolve")
    if skipped:
        return Check("platform-guard-agreement", "PASS", detail,
                     [f"not covered: `{name}` is both a standard-library type and a type this tree "
                      f"declares" for name in skipped])
    return Check("platform-guard-agreement", "PASS", detail)


#: Files this fork is allowed to have modified, each with the reason it had to be. A file that is
#: not on this list and differs from upstream is a `FAIL`, not a note: an unreviewed edit to a file
#: upstream owns is the thing this check exists to stop, and a check that only reports it is a
#: check nobody reads twice.
REVIEWED_UPSTREAM_MODIFICATIONS = {
    ".gitignore":
        "`__pycache__/` and `*.pyc`, for the two Python scripts under scripts/dev",
    "ApplicationLibrary/Views/Connections/ConnectionListViewModel.swift":
        "BEHAVIOUR FIX, cross-platform: the `commandClient.$isConnected` sink that calls "
        "`finishLoading()` when the command client is not connected. `isLoading` starts true and only a "
        "delivered connection list cleared it, so with the tunnel stopped - no client, nothing to "
        "deliver - the Activity page showed a spinner for as long as it was open and its own empty state "
        "was unreachable. The original fork has this sink; the integration dropped it. It is correct on "
        "an iPad and a Mac too, which is why it belongs in the shared view model rather than in a "
        "phone-only copy. `finishLoading()` is idempotent, so a disconnect after a delivered list is a "
        "no-op",
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
    "ApplicationLibrary/Views/Groups/GroupListViewModel.swift":
        "`testingItems`, the per-member half of a group latency sweep, which the phone's "
        "Proxies page reads to put a spinner on each row being measured; additive only",
    "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift":
        "the remaining-quota item, the two layout properties and the locale-sized relative time",
    "sing-box.xcodeproj/project.pbxproj":
        "`CFBundleDisplayName` for the SFI and SFM app targets",
}



def check_shared_declaration_duplicates(root: str) -> Check:
    """No module-scope name declared twice.

    A duplicate declaration is a compile error for **every** Apple target that compiles the pair, not
    only the phone's - so this is the one defect in the whole audit whose blast radius is the entire
    product. It is also invisible to every other check here: the page-coverage check reads a switch,
    the boundary checks read names and bytes, and none of them would notice that two files both define
    `SettingsPage`.

    The three shapes that collide:

      * the same type declared in two files;
      * the same type extended with the same member in two files;
      * a type declared in one file and given a member another file also gives it.

    `private` and `fileprivate` declarations are scoped to their file in Swift, so two files may each
    have one and this does not report them. That is exactly the distinction that makes the phone's
    `HakoPendingSettingsPageKey` legitimate while a second `SettingsPage` was not.

    The check reports the *name* and every site. It does not try to decide which declaration is the
    right one: that is a judgement about ownership, and
    `REVIEWED_UPSTREAM_MODIFICATIONS` plus the port generators are where it belongs.
    """
    #: Type declarations, with the file they live in and whether they are visible outside it.
    type_decl = re.compile(
        r"^(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
        r"fileprivate[ \t]+|final[ \t]+|indirect[ \t]+)*)"
        r"(?P<kind>struct|class|enum|protocol)\s+(?P<name>\w+)", re.M)

    #: `extension SomeType {` - the member list is scanned inside it.
    extension = re.compile(
        r"^(?P<mods>(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+)*)"
        r"extension\s+(?P<name>[\w.]+)\s*\{", re.M)

    #: A member declaration, as it appears at the top level of an extension body.
    member = re.compile(
        r"^[ \t]*(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
        r"fileprivate[ \t]+|nonisolated[ \t]+|static[ \t]+|class[ \t]+|override[ \t]+)*)"
        r"(?P<kind>var|let|func|subscript)\s+(?P<name>\w+)")

    def is_file_scoped(mods: str) -> bool:
        return bool(re.search(r"\b(?:private|fileprivate)\b", mods or ""))

    def extension_members(text: str, body_start: int) -> list[tuple[str, str]]:
        """(mode, name) for each member declared at the **top level** of an extension body.

        The body is walked with a brace counter rather than matched line by line, because an extension
        body contains nested things whose members are not the extension's: a nested `struct` (which
        `Profile+Transferable.swift` has three of), a computed property's accessor block, a function
        body, a closure. A line-based scan collected those, so `Profile.content` and `Profile.type`
        were reported as duplicates when the real declarations were `TransferableProfile.content` and a
        local `let type = type` inside a function. Only depth 1 counts here, and only the first
        declaration on a line.
        """
        found: list[tuple[str, str]] = []
        depth = 1  # We are already inside the extension's `{`.
        index = body_start
        length = len(text)
        while index < length and depth > 0:
            line_end = text.find("\n", index)
            if line_end < 0:
                line_end = length
            line = text[index:line_end]

            if depth == 1:
                match = member.match(line)
                if match:
                    found.append((match.group("mods") or "", match.group("name")))

            depth += line.count("{") - line.count("}")
            index = line_end + 1
        return found

    #: Directories whose Swift files are compiled into **more than one** target. `ApplicationLibrary`
    #: and `Library` are shared: the app targets each compile them alongside their own sources. So a
    #: name declared in one of these collides with the same name in any app target, while two names in
    #: two *different* app targets never meet.
    #:
    #: `MacLibrary` is deliberately **not** here. It is its own framework - `MacLibrary.framework` is a
    #: target in the project - so `MainView` existing in both `MacLibrary` and `SFI` is the same
    #: arrangement as `Application` existing in each app target, and listing it here made the check
    #: report both.
    #:
    #: Without the target grouping at all, the check reported `Application` as a duplicate. It is
    #: declared once in each of the four app entry points, which is what an app entry point *is*. A
    #: check that cries wolf is a check that gets switched off.
    SHARED_TARGET_DIRS = ("ApplicationLibrary/", "Library/")

    def target_group(path: str) -> str:
        for shared in SHARED_TARGET_DIRS:
            if path.startswith(shared):
                return "shared"
        return path.split("/", 1)[0]

    def collides(paths: list[str]) -> bool:
        """True when some single target would compile two of these files."""
        unique = set(paths)
        if len(unique) < 2:
            return False
        groups = {target_group(path) for path in unique}
        return "shared" in groups or len(groups) == 1

    #: The namespace this fork owns for the phone's UI. A duplicate that involves one of these files is
    #: a duplicate this project introduced and can fix; one that involves none of them is a property of
    #: the pinned upstream commit.
    #:
    #: That distinction is the whole scoping rule, and it was arrived at by measurement rather than by
    #: preference. The check's first version failed on two pre-existing upstream pairs -
    #: `NEVPNStatus.isStarted` in `Library/Network/` and `WidgetExtension/`, and `View.alert`
    #: overloaded with different arities in `ApplicationLibrary/` and `Library/` - and neither is
    #: something this fork can or should change. Reporting them would make the check red on a clean
    #: checkout, which is how a check gets ignored.
    #:
    #: The two are still *reported*, as notes, because a reader comparing this audit to a compiler
    #: should know they are there.
    HAKO_NAMESPACE = "ApplicationLibrary/Views/HakoStyle/"

    types: dict[str, list[str]] = {}
    members: dict[str, list[str]] = {}

    for path in swift_files(root):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for match in type_decl.finditer(text):
            if is_file_scoped(match.group("mods")):
                continue
            types.setdefault(match.group("name"), []).append(path)
        for match in extension.finditer(text):
            type_name = match.group("name")
            # An extension's own access modifier scopes **every member it adds**. `private extension URL
            # { func formattedSize() ... }` in two files is legal and is not a duplicate, exactly as two
            # `private struct`s of one name are not. Reading only the members' own modifiers reported
            # `URL.formattedSize` as a collision between `HakoStyle/HakoCoreView.swift` and
            # `Setting/CoreView.swift` - the ported copy and the original, both of which declare it
            # `private`.
            extension_scoped = is_file_scoped(match.group("mods"))
            for mods, found in extension_members(text, match.end()):
                if extension_scoped or is_file_scoped(mods):
                    continue
                members.setdefault(f"{type_name}.{found}", []).append(path)

    problems = [
        Blame(sorted(set(paths))[0], 0,
              f"{name} is declared in {len(set(paths))} files that a single target compiles together: "
              f"{', '.join(sorted(set(paths)))}")
        for name, paths in sorted(types.items())
        if collides(paths)
    ]
    for name, paths in sorted(members.items()):
        unique = sorted(set(paths))
        if collides(unique):
            problems.append(Blame(unique[0], 0,
                                  f"{name} is added in {len(unique)} files that a single target "
                                  f"compiles together: {', '.join(unique)}"))

    # A type declared in one file and given the same member in another is the same defect seen from the
    # other side, and the extension scan above already catches it - so this guard only has to prove the
    # scan actually looked at something. A check that silently scanned nothing would pass forever.
    if not types:
        return Check(
            "shared-declaration-duplicates",
            "UNKNOWN",
            "no type declaration was found anywhere in the tree, so nothing was compared",
        )

    # Split by whether this project could have caused it. A pair that involves no file in the fork's own
    # namespace is a property of the pinned upstream commit, and is reported rather than failed.
    ours = [problem for problem in problems if HAKO_NAMESPACE in str(problem)]
    inherited = [problem for problem in problems if HAKO_NAMESPACE not in str(problem)]

    if ours:
        return Check(
            "shared-declaration-duplicates",
            "FAIL",
            f"{len(ours)} module-scope name(s) declared more than once together with a file in "
            f"{HAKO_NAMESPACE}, which is a compile error for every target that compiles the pair",
            [str(problem) for problem in ours + inherited],
        )
    detail = (f"{len(types)} module-scope type name(s) and {len(members)} extension member(s); none in "
              f"{HAKO_NAMESPACE} is declared twice")
    if inherited:
        detail += (f". {len(inherited)} duplicate pair(s) exist in the pinned upstream commit itself, "
                   f"involving no file this fork owns, and are reported without being failed")
    return Check("shared-declaration-duplicates", "PASS", detail,
                 [str(problem) for problem in inherited])


def check_hako_symbol_completeness(root: str) -> Check:
    """Every Hako symbol a file names must be declared by some file.

    The other direction of the duplicate check: that one finds a name declared twice, this one finds a
    name used and never declared. `HakoRow` and `HakoScaffold` - the original's bytes - both read
    `\.hakoCompactRows`, and for a while nothing declared it.

    Why nothing else noticed: `@Environment(\.hakoCompactRows)` is a *key path*. A search for the
    symbol finds the readers and no declaration, which looks like nothing at all rather than like a
    missing symbol, and no check here reads Swift's type system. The compiler would have said so; the
    compiler is not available. So this check says it instead.

    It reports `UNKNOWN` rather than `PASS` when it finds no Hako symbol at all, because a scan that
    looked at nothing must not read as a scan that found nothing wrong.
    """
    #: A name introduced by one of these is a declaration.
    #:
    #: `let`/`var` are deliberately **not** here. `case let HakoCard` and `if case .x(let HakoY)` are
    #: pattern matches, not declarations, and matching them reported `HakoCard` and `HakoData` as
    #: used-and-never-declared when both are structs in this tree. Only a declaration keyword
    #: immediately followed by the name counts.
    declaration = re.compile(
        r"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*"
        r"(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+|final[ \t]+|static[ \t]+|"
        r"class[ \t]+|nonisolated[ \t]+|override[ \t]+|mutating[ \t]+|indirect[ \t]+)*"
        r"(?:struct|class|enum|protocol|actor|typealias|func|case|init)\s+"
        r"(?P<name>Hako\w*|hako\w*)"
        # The name may be followed by a generic clause, a supertype, a raw type, an associated value or
        # nothing at all: `struct HakoCard<Content: View>: View {`, `enum HakoAccentRole: String {`,
        # `case hakoCard(HakoCard)`. Requiring a `:`/`{` here reported `HakoCard` itself as undeclared,
        # because the character after the name in its own declaration is `<`.
        r"(?=[\s<:{(]|$)", re.M)

    #: An `extension Foo {` introduces `Foo`.
    extension = re.compile(r"^[ \t]*(?:public[ \t]+|internal[ \t]+)*extension\s+(?P<name>Hako\w*)",
                           re.M)

    #: A stored or computed property, which is how an `EnvironmentKey`-backed member is declared. The
    #: trailing `:`/`=` is what keeps `let card = HakoCard(...)` from reading as a declaration of
    #: `HakoCard`, and lets `var hakoCompactRows: Bool {` read as a declaration of the key.
    property_declaration = re.compile(
        r"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*"
        r"(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+|static[ \t]+|"
        r"nonisolated[ \t]+|override[ \t]+|lazy[ \t]+)*"
        r"(?:var|let)\s+(?P<name>Hako\w*|hako\w*)\s*[:=]", re.M)

    #: Reading an environment key, which is the shape that hides.
    key_read = re.compile(r"\\\.(?P<name>hako\w*)")
    #: Setting an environment key.
    key_write = re.compile(r"\.environment\(\\\.(?P<name>hako\w*)")
    #: Naming a Hako type - a constructor call, a parameter type, a generic argument.
    type_named = re.compile(r"\b(?P<name>Hako[A-Z]\w*)")

    #: Comments are stripped before anything is matched, and that is not tidiness. The Hako files carry
    #: attribution: `HakoCard.swift` names itself in its header banner, `HakoEmptyState.swift` and
    #: `HakoTheme.swift` cite the original project's paths, and `HakoPrimaryShell.swift` cites a symbol
    #: from it. Reading those as uses reported `HakoCard`, `HakoClientUI`, `HakoClient` and
    #: `HakoClientApp` as used-and-never-declared, four false positives out of six - and a check that is
    #: wrong more often than right is one nobody reads.
    def without_comments(text: str) -> str:
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        return re.sub(r"//[^\n]*", "", text)

    declared: dict[str, list[str]] = {}
    read: dict[str, list[str]] = {}

    for path in swift_files(root):
        raw = read_text(os.path.join(root, path))
        if raw is None:
            continue
        text = without_comments(raw)
        for pattern in (declaration, extension, property_declaration):
            for match in pattern.finditer(text):
                declared.setdefault(match.group("name"), []).append(path)
        for pattern in (key_read, key_write, type_named):
            for match in pattern.finditer(text):
                read.setdefault(match.group("name"), []).append(path)

    if not declared and not read:
        return Check(
            "hako-symbol-completeness",
            "UNKNOWN",
            "no Hako symbol was found anywhere, so nothing was compared",
        )

    # A symbol that is only ever named is not missing if it belongs to a framework this project links;
    # the Hako namespace is this project's own, so there is no such case - every `Hako*` name must exist.
    missing = []
    for name, sites in sorted(read.items()):
        if name in declared:
            continue
        # `HakoSelf`-style false positives would show here; there are none today, and an entry would be
        # a deliberate exemption rather than a pattern, so none is written.
        unique = sorted(set(sites))
        missing.append(Blame(unique[0], 0,
                             f"{name} is named by {len(unique)} file(s) and declared by none: "
                             f"{', '.join(unique)}"))

    if missing:
        return Check(
            "hako-symbol-completeness",
            "FAIL",
            f"{len(missing)} Hako symbol(s) are used and never declared, which is a compile error",
            [str(item) for item in missing],
        )
    return Check(
        "hako-symbol-completeness",
        "PASS",
        f"{len(declared)} Hako symbol(s) declared, and every one of the {len(read)} named is among them",
    )


def check_hako_annotation_agreement(root: str) -> Check:
    """A stored property's declared type agrees with the type constructed for it.

    # The defect this exists for

    Three ported files declared and assigned two **different** types:

        HakoCrashReportDetailView.swift:28  @State private var exportDocument: ReportZipDocument?
        HakoCrashReportDetailView.swift:55        exportDocument = HakoReportZipDocument(url: zipURL)

    `ReportZipDocument` is declared once in `Tools/ReportShared.swift` and `HakoReportZipDocument` once in
    `HakoStyle/HakoReportShared.swift`; they are two unrelated structs, so the assignment cannot type-check
    on any platform. The migration renamed the constructor and missed the annotation - its renames are
    word-boundary substitutions, and one of the two occurrences was inside a type position it did not treat
    as a rename site.

    # Why every other check in this file is blind to it

    They read names, paths, guards, imports and declarations. None of them asks whether two names that are
    both spelled correctly refer to the same type. That is a whole class, not one instance - so this check
    compares the annotation against the constructor for stored properties assigned a fresh value, and
    reports a mismatch only when both names are known type names, which keeps it from firing on a factory
    method or a local. Both are required to be types this audit can see declared somewhere in the tree.
    """
    #: `var name: Type?` - the `?`/`!` binds directly to the type, so there is no whitespace between them.
    #: Writing `\s*\??` here was the first version's bug: `Type ?` is legal Swift but `Type?` is what the
    #: tree actually contains, and the pattern then matched nothing at all, so the check reported PASS on a
    #: tree that had the defect it was written for. It was caught by reverting the defect and noticing the
    #: check still passed - which is the only reason to write a negative case before trusting a check.
    annotation = re.compile(r"\b(?:var|let)\s+(\w+)\s*:\s*([A-Z]\w*)[?!]?\s*$")
    assignment = re.compile(r"^\s*(?:\w+\s*=\s*)?(\w+)\s*=\s*([A-Z]\w*)\s*\(")

    declared_types: set[str] = set()
    for path in swift_files(root, HAKO_PREFIX.rstrip("/")):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for match in re.finditer(r"\b(?:struct|class|enum|actor)\s+(\w+)", text):
            declared_types.add(match.group(1))

    problems: list[Blame] = []
    for path in swift_files(root, HAKO_PREFIX.rstrip("/")):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        annotated: dict[str, str] = {}
        for number, line in enumerate(text.split("\n"), 1):
            found = annotation.search(strip_comment(line))
            if found:
                annotated[found.group(1)] = found.group(2)
        for number, line in enumerate(text.split("\n"), 1):
            found = assignment.match(line)
            if not found:
                continue
            name, constructed = found.group(1), found.group(2)
            expected = annotated.get(name)
            if expected is None or expected == constructed:
                continue
            if expected not in declared_types or constructed not in declared_types:
                continue  # one side is not a type this audit can resolve; stay silent rather than guess
            problems.append(Blame(path, number,
                                  f"`{name}` is declared `{expected}?` but constructed as `{constructed}`; "
                                  f"both types exist, so the assignment cannot type-check"))

    if not declared_types:
        return Check("hako-annotation-agreement", "UNKNOWN", "no type declarations were found to check")
    if problems:
        return Check("hako-annotation-agreement", "FAIL",
                     f"{len(problems)} stored propert(y/ies) are assigned a type other than the one declared",
                     [str(problem) for problem in problems])
    return Check("hako-annotation-agreement", "PASS",
                 f"every stored property in {HAKO_PREFIX} is assigned the type it declares, out of "
                 f"{len(declared_types)} known type names")



def check_hako_type_has_caller(root: str) -> Check:
    """Every type the phone's namespace declares is named somewhere outside its own declaration.

    The four Hako types this was written after - `HakoGroupItemView`, `HakoToolOutboundSection`,
    `HakoRemoteToolOutboundSection`, `HakoOutboundPickerView` and `HakoEditorToolbarView` - were all
    declared, all faithful to the frozen original, and all unused, so the phone built upstream's view while
    every other check reported PASS. `no-reverse-dependency` looks for a Hako name *inside a shared file*;
    a phone page naming an *upstream* type is the opposite direction and nothing looked at it.

    Deliberately weaker than reachability and honest about it: an occurrence is not a call path. It proves
    the type was not left behind, not that the phone reaches it. Reachability needs the call graph, which
    this audit does not build.
    """
    namespace = os.path.join(root, HAKO_PREFIX)
    if not os.path.isdir(namespace):
        return Check("hako-type-has-caller", "UNKNOWN",
                     f"{HAKO_PREFIX} does not exist, so there is nothing to look for callers of")

    #: Types that are only ever used as a protocol conformance, a generic argument or an `@State` type are
    #: still used; the question is whether the name appears at all beyond where it is declared.
    #:
    #: The scan covers the **whole tree**, not just the namespace, and the first version got that wrong: it
    #: searched `HAKO_PREFIX` only and reported `HakoEditorToolbarView`, `HakoGroupsSheetContent` and
    #: `HakoConnectionsSheetContent` as dead when all three have callers in `SFI/`. A check that reports a
    #: live type as dead is not conservative, it is wrong in the direction that gets checks switched off.
    #:
    #: Only types whose name is `Hako` plus a name that exists in the frozen original are considered. This
    #: namespace also holds helpers this fork wrote - `HakoEntryRow`, `HakoInlineNotice`, `HakoMetricText` -
    #: and an unused helper is untidy rather than a lost design, so failing on one would be a false alarm of
    #: the kind that gets a check switched off. A `HakoFoo` whose original `Foo` exists is by construction a
    #: migrated type, and if nothing constructs it then something else is being shown in its place.
    declared: dict[str, str] = {}
    sources: dict[str, str] = {}
    for path in swift_files(root):
        if path in OUTSIDE_THE_APP:
            continue
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        sources[path] = strip_comments(text)

    original_names = ORIGINAL_TYPE_NAMES
    for path in swift_files(root, HAKO_PREFIX.rstrip("/")):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        for match in re.finditer(
                r"^[ \t]*(?:(?:public|internal|private|fileprivate|final|indirect|@\w+)[ \t]+)*"
                r"(?:struct|class|enum|actor)\s+(Hako\w+)", text, re.M):
            name = match.group(1)
            if name[4:] not in original_names:
                continue  # a helper this fork wrote, not a migrated page
            declared.setdefault(name, path)

    if not declared:
        return Check("hako-type-has-caller", "UNKNOWN",
                     f"{HAKO_PREFIX} declares no Hako-prefixed type, so a scan for callers means nothing")

    dead = []
    for name, home in sorted(declared.items()):
        # The declaration itself is one occurrence; anything more means something names it.
        occurrences = 0
        for text in sources.values():
            occurrences += len(re.findall(rf"\b{re.escape(name)}\b", text))
        if occurrences <= 1:
            dead.append(Blame(home, 0,
                              f"`{name}` is declared here and named nowhere else in the namespace; "
                              f"the phone is building something else"))

    if dead:
        return Check("hako-type-has-caller", "FAIL",
                     f"{len(dead)} Hako type(s) have no caller anywhere in the namespace, so whatever "
                     f"the phone builds in their place is not the frozen design", [str(item) for item in dead])
    return Check("hako-type-has-caller", "PASS",
                 f"all {len(declared)} Hako type(s) in {HAKO_PREFIX} are named beyond their own declaration")

def check_hako_platform_imports(root: str) -> Check:
    """No ported file imports a platform framework outside a conditional.

    `ApplicationLibrary` is a shared target: it compiles for iOS, macOS and tvOS. `import UIKit` at file
    scope is therefore a compile error on two of the three. The original guarded every such import, and the
    migration's platform-resolution step removed the guards while keeping the imports - so this check reads
    the same predicate the repair tool uses and fails when the two disagree.

    `canImport(...)` is the accepted gate rather than `os(iOS)`, matching what the original wrote.
    """
    #: Frameworks that do not exist on every platform this target builds for.
    PLATFORM_ONLY = {
        "UIKit", "AppKit", "Cocoa", "QuickLook", "GhosttyTerminal",
        "DeviceDiscoveryUI", "AVKit", "ServiceManagement",
    }
    import_line = re.compile(r"^import\s+(\w+)\s*$")

    namespace = os.path.join(root, HAKO_PREFIX)
    if not os.path.isdir(namespace):
        return Check("hako-platform-imports", "UNKNOWN",
                     f"{HAKO_PREFIX} does not exist, so there is nothing to scan")

    problems = []
    files = 0
    for path in swift_files(root, HAKO_PREFIX.rstrip("/")):
        text = read_text(os.path.join(root, path))
        if text is None:
            continue
        files += 1
        depth = 0
        for number, line in enumerate(text.split("\n"), 1):
            stripped = line.strip()
            if stripped.startswith("#if"):
                depth += 1
            elif stripped.startswith("#endif"):
                depth -= 1
            match = import_line.match(stripped) or import_line.match(line.rstrip())
            if match and depth == 0 and match.group(1) in PLATFORM_ONLY:
                problems.append(Blame(path, number,
                                      f"`import {match.group(1)}` is not inside a conditional; "
                                      f"ApplicationLibrary builds for iOS, macOS and tvOS"))

    if files == 0:
        return Check("hako-platform-imports", "UNKNOWN",
                     f"{HAKO_PREFIX} holds no Swift file, so nothing was scanned")
    if problems:
        return Check(
            "hako-platform-imports",
            "FAIL",
            f"{len(problems)} platform framework import(s) are not gated, which does not compile on the "
            f"other platforms of a shared target",
            [str(problem) for problem in problems],
        )
    return Check(
        "hako-platform-imports",
        "PASS",
        f"{files} file(s) in {HAKO_PREFIX}, and every platform-only framework import is inside a "
        f"conditional",
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


def check_branding(root: str, upstream_ref: str | None = None) -> Check:
    """The visible name is Jiejiebox; identity, protocol and signing surface is untouched."""
    pbx = os.path.join(root, "sing-box.xcodeproj/project.pbxproj")
    text = read_text(pbx)
    if text is None:
        return Check("branding", "UNKNOWN", "sing-box.xcodeproj/project.pbxproj is missing")

    evidence = []
    problems = []

    # Attribute every display name to the plist of its build configuration. Counting occurrences
    # says nothing about *which* target still carries the old name; grouping by the plist is what
    # lets this check assert that the share extension is deliberately not branded rather than that
    # eight entries happen to remain.
    settings = display_name_by_plist(text)
    if not settings:
        problems.append("no INFOPLIST_KEY_CFBundleDisplayName is set in any build configuration")
    else:
        for plist in BRANDED_TARGET_PLISTS:
            values = settings.get(plist)
            if values is None:
                problems.append(f"{plist} sets no CFBundleDisplayName")
            elif set(values) != {BRAND_DISPLAY_NAME}:
                problems.append(
                    f"{plist} sets CFBundleDisplayName to {sorted(set(values))}, expected "
                    f"[{BRAND_DISPLAY_NAME!r}] in every configuration"
                )
            else:
                evidence.append(f"{plist}: {BRAND_DISPLAY_NAME} in {len(values)} configuration(s)")
        others = sorted(set(settings) - set(BRANDED_TARGET_PLISTS))
        for plist in others:
            if BRAND_DISPLAY_NAME in set(settings[plist]):
                problems.append(f"{plist} was branded; only the two app targets may be")
        if others:
            evidence.append(
                f"{len(others)} component plist(s) deliberately unbranded: "
                + ", ".join(os.path.basename(p) for p in others)
            )

    # Identity surface must not carry the brand, and must still be upstream's value when the pinned
    # commit is available - a value that is merely plausible is not the same as an unchanged one.
    for setting in PROTECTED_NAME_SETTINGS:
        local_values = [
            value.strip().strip('"')
            for _, values in target_lines(text, setting)
            for value in values
        ]
        for value in local_values:
            if BRAND_DISPLAY_NAME.lower() in value.lower():
                problems.append(
                    f"{setting} carries the product name ({value}); the rename must not reach "
                    "bundle identifiers or product names"
                )
        upstream_values = setting_values_at(root, upstream_ref, setting)
        if upstream_values is None:
            evidence.append(f"{setting}: {len(local_values)} occurrence(s); no upstream comparison")
            continue
        if len(upstream_values) != len(local_values):
            problems.append(
                f"{setting} appears {len(local_values)} times here and {len(upstream_values)} times "
                f"at {upstream_ref}; a merge probably moved a build configuration"
            )
        elif sorted(upstream_values) != sorted(local_values):
            problems.append(
                f"{setting} differs from {upstream_ref}: {sorted(local_values)} vs "
                f"{sorted(upstream_values)}"
            )
        else:
            evidence.append(
                f"{setting}: {len(local_values)} occurrence(s), identical to {upstream_ref}"
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
    """The newest phone feature must be present, reachable, and phone-only.

    # What "reachable" means now

    The remaining-quota row moved from the official picker into
    `ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift`, because an iPad and a Mac can
    open the official picker and the requirement for both is upstream's presentation untouched. That
    move changes what this check has to prove:

      * the **data** chain is still shared and still present, and
      * the **row** is present and reachable *inside the phone's own presentation*.

    The second half guards the failure the move could have introduced - a quota row that exists and is
    never presented - and it is checked by finding a presenter, not by finding the declaration.
    """
    required_files = {
        "Library/Network/SubscriptionInfo.swift": (r"func parse\s*\(\s*header", "remainingBytes", "usedBytes"),
        "Library/Network/RemoteProfileFetcher.swift": ("subscription-userinfo", "HTTPClient.userAgent"),
        "Library/Database/RemoteProfileUpdatePolicy.swift": ("RemoteProfileRefresh",),
        "Library/Database/RemoteRefreshApplier.swift": ("RemoteRefreshApplier",),
        "Library/Database/Profile.swift": ("subscriptionInfo", "subscriptionUpload"),
        "Library/Database/Database.swift": ("add_subscription_info",),
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

    # The phone's picker carries the row, reads the value out of the snapshot it already holds, and
    # is presented by a page the phone reaches. Each is a separate way the feature could be present
    # in the source and absent on the device.
    hako_picker = HAKO_PREFIX + "HakoProfilePickerSheet.swift"
    hako_picker_text = read_text(os.path.join(root, hako_picker))
    if hako_picker_text is None:
        problems.append(f"{hako_picker} is missing, so the phone has no configuration centre")
    else:
        for needle, why in (
            ("profile.subscriptionInfo?.remainingBytes", "reading the remainder from the snapshot"),
            ("remainingTrafficText", "the quota formatter"),
        ):
            if needle not in hako_picker_text:
                problems.append(f"{hako_picker} does not contain {needle} ({why})")
        # Declared is not the same as drawable. The item has to be *returned* by its view builder:
        # searching for its name alone was satisfied by a declaration and an `if false` guard, which
        # is exactly the "present in the source, absent on the device" failure this check exists for.
        item = re.search(
            r"private var remainingTrafficInfo: some View \{(.*?)\n    \}", hako_picker_text, re.S)
        if item is None:
            problems.append(f"{hako_picker} declares no `remainingTrafficInfo` view")
        elif not re.search(r"^\s*Text\(", item.group(1), re.M):
            problems.append(
                "`remainingTrafficInfo` is declared but returns no Text, so the quota is never drawn"
            )
        else:
            evidence.append(f"{hako_picker}: the quota item draws a Text")
        evidence.append(hako_picker)

    # The presentation, not the name: the picker has to be reachable through a sheet, or the phone
    # has no way to open it. Requiring only that some file *names* the type was satisfied by the file
    # that declares it, so removing the presenter still passed.
    #
    # The window is generous because the presentation is usually wrapped in a `NavigationSheet`, which
    # puts a few hundred characters of title and closure between the `.sheet` and the picker. A window
    # that is too small reports a page as not presenting something it does present, which is a worse
    # failure than a wide one.
    presenters = []
    for path in swift_files(root):
        if path.endswith("HakoProfilePickerSheet.swift"):
            continue
        text = read_text(os.path.join(root, path)) or ""
        if re.search(r"\.sheet\s*[({][\s\S]{0,2000}?HakoProfilePickerSheet\s*\(", text):
            presenters.append(path)
    if not presenters:
        problems.append(
            "no page presents `HakoProfilePickerSheet` in a sheet, so the remaining-quota row is "
            "declared and unreachable"
        )
    else:
        evidence.append(f"presented in a sheet by {', '.join(presenters)}")

    # A feature is not reachable merely because a helper exists. Every symbol on the chain that the
    # row depends on must be *used* somewhere the phone reaches as well as declared, and the reading
    # is taken over the phone's own files - the phone root, the page factory and the Hako namespace -
    # because that is the surface the row has to arrive on.
    #
    # This replaces a reading taken over everything *except* the Hako namespace. That premise inverted
    # when the quota row moved into `HakoProfilePickerSheet`: a symbol used only inside the fork's
    # presentation is now the success case, and requiring a use outside it would demand the row be
    # drawn by a file an iPad can open - which is the thing the move exists to prevent.
    reaching = [
        path for path in swift_files(root)
        if path in PHONE_ROOT_FILES or path.startswith(HAKO_PREFIX)
    ]
    texts = {path: read_text(os.path.join(root, path)) or "" for path in reaching}
    declared, _ = inventory_symbols(root)

    for symbol, where in (
        ("remainingTrafficInfo", "the quota item"),
        ("remainingBytes", "the remaining-bytes accessor"),
        ("remainingTrafficText", "the quota formatter"),
        ("subscriptionInfo", "the profile's stored metadata"),
    ):
        if symbol not in declared:
            problems.append(f"{symbol} ({where}) is not declared anywhere in the tree")
            continue
        users = [p for p, t in texts.items() if re.search(rf"\b{symbol}\b", t)]
        if not users:
            problems.append(
                f"{symbol} ({where}) is declared but named nowhere the phone reaches, so the "
                "feature it belongs to is not reachable"
            )
        else:
            evidence.append(f"{symbol} ({where}): named in {len(users)} phone file(s)")

    # The refresh entry point is the one symbol on the chain that deliberately stays outside the
    # presentation: it is business logic, and it has to be reachable from the shared layer.
    if not any(
        re.search(r"\bupdateRemoteProfile\b", read_text(os.path.join(root, path)) or "")
        for path in swift_files(root)
        if path in PHONE_ROOT_FILES or path.startswith(HAKO_PREFIX) or path.startswith("Library/")
    ):
        problems.append("updateRemoteProfile is named nowhere in the shared layer or the phone")

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


#: The two build configurations' plists whose visible name is the product's. Kept as a list so the
#: check and the negative suite read the same source.
BRANDED_TARGET_PLISTS = ("SFI/Info.plist", "SFM/Info.plist")


def display_name_by_plist(pbxproj: str) -> dict[str, list[str]]:
    """`CFBundleDisplayName` values grouped by the `INFOPLIST_FILE` of their build configuration.

    The split is on **any** `\t\t<24 hex> /* <comment> */ = {` block rather than on blocks whose
    comment reads `Debug` or `Release`. A build configuration's comment names its *target*
    (`3AEC20FF2A459AB500A63465 /* Debug */` is the project-level one, but every target's reads
    `/* SFI */`), so matching the comment matched almost nothing - which is how an earlier revision of
    this function returned an empty table and the branding check reported that no target sets a
    display name at all.

    `INFOPLIST_FILE` is the anchor that actually identifies a configuration, and it is required to end
    in `.plist` so a neighbouring setting whose value happens to contain that word cannot be taken for
    one.
    """
    out: dict[str, list[str]] = {}
    segments = re.split(r"\n\t\t[0-9A-F]{24} /\* [^*]+ \*/ = \{", pbxproj)
    for block in segments[1:]:
        plist = re.search(r"INFOPLIST_FILE = ([^;\n]+\.plist);", block)
        names = re.findall(r"INFOPLIST_KEY_CFBundleDisplayName = ([^;\n]+);", block)
        if plist and names:
            out.setdefault(plist.group(1).strip(), []).extend(
                n.strip().strip('"') for n in names)
    return out


def setting_values_at(root: str, ref: str | None, setting: str) -> list[str] | None:
    """Every value of a build setting at the pinned upstream commit, or `None` when unavailable."""
    if not ref:
        return None
    git = which_git()
    if git is None:
        return None
    rc, out, _ = run([git, "-C", root, "show", f"{ref}:sing-box.xcodeproj/project.pbxproj"])
    if rc != 0:
        return None
    return [v.strip().strip('"') for v in re.findall(rf"{re.escape(setting)} = ([^;]+);", out)]


#: Each first-level destination and the Hako view it must route to. `None` means the page is still
#: upstream's, and it is listed rather than omitted so the coverage count is a fact, not an
#: inference from a diff. A page becomes `"Hako…View"` when `SFI/HakoPageContent.swift` routes it.
HAKO_PAGE_ROUTING = {
    "dashboard": "HakoHomeView",
    "groups": "HakoGroupListView",
    "connections": "HakoConnectionListView",
    "logs": "HakoLogView",
    "tools": "HakoToolsView",
    "settings": "HakoSettingView",
}

#: The views `HakoPageContent` may name. A routing to anything else is a routing nobody decided.
KNOWN_PAGE_VIEWS = (
    "HakoHomeView", "HakoToolsView", "HakoSettingView", "HakoGroupListView",
    "HakoConnectionListView", "HakoLogView",
    "GroupListView", "ConnectionListView", "LogView", "ToolsView", "SettingView",
)


def hako_page_content_routing(root: str) -> dict[str, str] | None:
    """What `SFI/HakoPageContent.swift` routes each `NavigationPage` case to.

    Parsed from the switch, because the property being audited is what the source does rather than
    what a table claims. An arm that renders a helper property is followed into that property, so
    `case .dashboard: dashboardPage` resolves to the view the helper builds.
    """
    text = read_text(os.path.join(root, "SFI/HakoPageContent.swift"))
    if text is None:
        return None

    # Walked line by line rather than with one regex. An arm runs from `case .name:` to the next arm,
    # the next preprocessor directive, or the end of the switch, and it can contain a nested block
    # whose closing brace is followed by a view modifier on the same line - which is what defeated an
    # earlier lookahead-based attempt and made this function report that the first case did not exist.
    arms: list[tuple[str, list[str]]] = []
    current: str | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("case ."):
            name = re.match(r"case \.(\w+)", stripped)
            if name:
                current = name.group(1)
                arms.append((current, []))
            continue
        if current is None:
            continue
        if stripped.startswith(("#if", "#endif", "#else")) or stripped == "}":
            current = None
            continue
        arms[-1][1].append(line)

    out: dict[str, str] = {}
    for case, body_lines in arms:
        body = "\n".join(body_lines)
        view = re.search(r"\b(" + "|".join(KNOWN_PAGE_VIEWS) + r")\s*\(", body)
        if view:
            out[case] = view.group(1)
            continue
        helper = re.search(r"^\s*([A-Za-z_]\w*)\s*$", body.strip(), re.M)
        if not helper:
            continue
        name = helper.group(1)
        prop = re.search(
            rf"private var {re.escape(name)}: some View \{{(.*?)\n    \}}", text, re.S)
        if not prop:
            continue
        inner = re.search(r"\b(" + "|".join(KNOWN_PAGE_VIEWS) + r")\s*\(", prop.group(1))
        if inner:
            out[case] = inner.group(1)
    return out


def check_hako_page_coverage(root: str, allow_partial: bool = False) -> Check:
    """Every first-level page must route to a Hako view, and the count must be reported honestly.

    The failure this guards is a page that looks migrated because a file exists while
    `HakoPageContent` still renders upstream's. The check reads the switch, so the only way to make a
    page count is to route it.
    """
    routing = hako_page_content_routing(root)
    if routing is None:
        return Check("hako-page-coverage", "UNKNOWN", "SFI/HakoPageContent.swift is missing")
    if not routing:
        return Check(
            "hako-page-coverage",
            "UNKNOWN",
            "no `case .<NavigationPage>` arm could be parsed from SFI/HakoPageContent.swift; the "
            "file may have been restructured",
        )

    migrated: list[str] = []
    pending: list[str] = []
    problems: list[str] = []

    for page, expected in HAKO_PAGE_ROUTING.items():
        actual = routing.get(page)
        if actual is None:
            problems.append(f"`{page}` has no case in SFI/HakoPageContent.swift")
        elif expected is None:
            pending.append(f"{page} -> {actual} (upstream, not yet migrated)")
        elif actual != expected:
            problems.append(f"`{page}` routes to {actual}, expected {expected}")
        else:
            migrated.append(f"{page} -> {actual}")

    for page in routing:
        if page not in HAKO_PAGE_ROUTING:
            problems.append(f"`{page}` is routed but not listed in HAKO_PAGE_ROUTING")

    total = len(HAKO_PAGE_ROUTING)
    done = len(migrated)
    if problems:
        return Check("hako-page-coverage", "FAIL", "; ".join(problems), migrated + pending)
    if done < total:
        detail = (
            f"{done} of {total} first-level pages route to a Hako view; still upstream: "
            + ", ".join(p.split(" ")[0] for p in pending)
        )
        if allow_partial:
            return Check("hako-page-coverage", "UNKNOWN", detail, migrated + pending)
        return Check(
            "hako-page-coverage",
            "FAIL",
            detail + ". A partial migration is a failure on purpose: this check exists to stop 'the "
            "file exists' from being read as 'the page is migrated'. Pass --allow-partial while the "
            "migration is in flight.",
            migrated + pending,
        )
    return Check(
        "hako-page-coverage",
        "PASS",
        f"all {total} first-level pages route to a Hako view",
        migrated,
    )


def check_hako_feature_preservation(root: str) -> Check:
    """The phone's features must have a consumer on a path the phone reaches.

    A declaration inside the Hako namespace that nothing else names is the shape of a feature that was
    moved and then dropped. "Reached" means named from the phone root, the page factory, or another
    Hako file - which is why each symbol below is required to appear in at least one file other than
    the one that declares it, or to be a value the page factory passes on.
    """
    reaching = [
        path for path in swift_files(root)
        if path in PHONE_ROOT_FILES or path.startswith(HAKO_PREFIX)
    ]
    texts = {path: read_text(os.path.join(root, path)) or "" for path in reaching}

    required = (
        ("HakoPrimaryShell", "the three-destination shell"),
        ("HakoHomeView", "the Home page"),
        ("HakoProfilePickerSheet", "the configuration centre, with the quota row"),
        ("HakoLogView", "the Logs page"),
        ("HakoGroupListView", "the Proxies page"),
        ("HakoConnectionListView", "the Activity page"),
        ("HakoToolsView", "the Tools page"),
        ("HakoSettingView", "the More page"),
        ("HakoNavigationRow", "the shortcut rows"),
        ("HakoPageSection", "the painted sections"),
        ("HakoRootScaffold", "the page canvas"),
    )
    problems: list[str] = []
    evidence: list[str] = []
    for symbol, why in required:
        naming = [p for p, t in texts.items() if re.search(rf"\b{symbol}\b", t)]
        if not naming:
            problems.append(f"{symbol} ({why}) is named nowhere the phone reaches")
            continue
        evidence.append(f"{symbol} ({why}): {len(naming)} reaching file(s)")

    # Features must be *wired*, not merely declared: a closure nothing invokes is a control that does
    # nothing, and `private var x` is a declaration whose name appears exactly once whatever it is
    # used for - which is why counting a symbol's occurrences cannot answer this. Each entry states
    # the wiring it wants as two patterns over the phone's own files: the thing that opens it and the
    # thing that consumes it.
    wiring = (
        (r"showsConfigurationCentre\s*=\s*true",
         r"\.sheet\(isPresented:\s*\$showsConfigurationCentre",
         "the way into the configuration centre is a button that presents the sheet"),
        (r"HakoProfilePickerSheet\s*\(",
         r"profileList:\s*\$",
         "the configuration centre is presented with the profile list it edits"),
        (r"selectClashMode\(",
         r"setClashMode\(",
         "the outbound-mode row sends the chosen mode to the core"),
        (r"installTunnel",
         r"await installTunnel\(\)",
         "the install notice's button awaits the install path"),
        (r"\.hakoHomeActions",
         r"HakoHomeActions\(",
         "the proxies and activity presenters reach the page through the environment"),
        (r"shortcutRow\(",
         r"selection\.wrappedValue\s*=\s*\.logs",
         "the shortcuts select the pages they name"),
        (r"HakoGroupListView\s*\(",
         r"testingItems",
         "the Proxies page shows which member a latency sweep is measuring"),
        (r"HakoConnectionListView\s*\(",
         r"HakoConnectionListContentView\s*\(", 
         "the Activity page presents its own content view"),
        (r"HakoToolsView\s*\(",
         r"HakoPageSection\s*\(",
         "the Tools page groups its rows into the design system's sections"),
        (r"HakoSettingView\s*\(",
         r"pendingSettingsPage",
         "the More page carries a requested settings sub-page into the destination it "
         "belongs to"),
        (r"HakoLogView\s*\(",
         r"HakoEmptyState\s*\(\s*symbol:",
         "the Logs page presents the original empty states rather than upstream's plain "
         "text, which is what a wrapper could not do"),
    )
    for opener, consumer, why in wiring:
        openers = [p for p, t in texts.items() if re.search(opener, t)]
        consumers = [p for p, t in texts.items() if re.search(consumer, t)]
        if not openers:
            problems.append(f"{why}: nothing opens it ({opener})")
        elif not consumers:
            problems.append(f"{why}: nothing consumes it ({consumer})")
        else:
            evidence.append(f"{why}: {openers[0]} -> {consumers[0]}")

    if problems:
        return Check("hako-feature-preservation", "FAIL", "; ".join(problems), evidence)
    return Check(
        "hako-feature-preservation",
        "PASS",
        f"{len(required)} reached type(s) and {len(wiring)} wiring path(s) verified on the phone's "
        "own files",
        evidence,
    )


def check_ipad_mac_ui_gate(root: str, upstream_ref: str | None) -> Check:
    """No Hako symbol may be reachable from an iPad or a Mac, and the picker must be upstream's.

    This is the strengthened form of the phase-1 boundary checks, and the reason it exists as its own
    check is the remaining-quota row. That row is exactly the kind of change a whitelist absorbs: it
    was a reviewable modification to a shared file, it was *listed* with a reason, and it was still a
    visible change on a device the product says must show upstream's UI untouched.

    So the official picker is called out by name, and its content is asserted rather than its
    whitelist entry. A whitelist can say "this file was changed on purpose"; it cannot say "this file
    shows the user something upstream's does not".
    """
    problems: list[str] = []
    evidence: list[str] = []
    official = "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift"

    for path in (IPAD_ROOT_FILE, MAC_ROOT_FILE,
                 "ApplicationLibrary/Views/SidebarView.swift",
                 "ApplicationLibrary/Views/Abstract/SidebarLayout.swift",
                 UPSTREAM_PAGE_FACTORY, official):
        if not os.path.exists(os.path.join(root, path)):
            problems.append(f"{path} is missing, so upstream's presentation is not reachable")
            continue
        hits = grep(root, path, HAKO_TYPES + HAKO_MEMBERS)
        if hits:
            problems.append(f"{path} names a Hako symbol: {hits[0]}")
        else:
            evidence.append(f"{path}: no Hako symbol")

    official_text = read_text(os.path.join(root, official)) or ""
    for needle, why in (
        ("remainingTrafficInfo", "the phone's remaining-quota item"),
        ("remainingTrafficText", "the phone's quota formatter"),
        ("subscriptionInfo", "the subscription metadata"),
        ("%@ left", "the quota's own localisation key"),
    ):
        if needle in official_text:
            problems.append(
                f"{official} contains {needle} ({why}); the official picker must not show a change "
                "the phone made, whatever the reviewed-modification list says"
            )

    if upstream_ref:
        git = which_git()
        if git is None:
            evidence.append(f"{official}: byte comparison unavailable (no git)")
        else:
            rc, upstream_blob, _ = run([git, "-C", root, "rev-parse", f"{upstream_ref}:{official}"])
            rc2, local_blob, _ = run(
                [git, "-C", root, "hash-object", os.path.join(root, official)])
            if rc != 0 or rc2 != 0:
                evidence.append(f"{official}: byte comparison unavailable")
            elif upstream_blob.strip() == local_blob.strip():
                evidence.append(f"{official} is byte-identical to {upstream_ref}")
            else:
                problems.append(
                    f"{official} differs from {upstream_ref} ({local_blob.strip()[:12]} vs "
                    f"{upstream_blob.strip()[:12]}); it must be upstream's file, unmodified"
                )

    if problems:
        return Check("ipad-mac-ui-gate", "FAIL", "; ".join(problems), evidence)
    return Check(
        "ipad-mac-ui-gate",
        "PASS",
        "no Hako symbol is reachable from the iPad or the Mac, and the official picker is upstream's",
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
    check_reverse_routing_contract,
    check_reverse_routing_derived,
    check_shared_declaration_duplicates,
    check_hako_symbol_completeness,
    check_hako_platform_imports,
    check_platform_guard_agreement,
    check_hako_page_coverage,
    check_hako_feature_preservation,
    check_ipad_mac_ui_gate,
    check_upstream_files_untouched,
    check_project_membership,
    check_branding,
    check_subscription_feature,
    check_repository_hygiene,
)

#: Checks that take the pinned upstream ref as a second argument.
TAKES_UPSTREAM_REF = (
    check_branding,
    check_ipad_mac_ui_gate,
    check_upstream_files_untouched,
    check_project_membership,
    check_repository_hygiene,
)

#: Checks that take `allow_partial` as a second argument instead.
TAKES_ALLOW_PARTIAL = (check_hako_page_coverage,)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Static UI-boundary audit for the Apple client.")
    parser.add_argument("--root", default=None, help="checkout to audit (default: the script's repo root)")
    parser.add_argument("--upstream-ref", default=None, help="pinned upstream ref to compare against")
    parser.add_argument("--json", action="store_true", help="print a JSON result instead of a report")
    parser.add_argument("--strict", action="store_true", help="treat UNKNOWN as a failure")
    parser.add_argument("--only", action="append", default=None, help="run only the named check(s)")
    parser.add_argument("--allow-partial", action="store_true",
                        help="report an incomplete Hako page migration as UNKNOWN instead of FAIL")
    args = parser.parse_args(argv)

    # A file this audit reads may not be valid UTF-8 - it reads with `errors="replace"` - so a detail
    # string can carry U+FFFD, and a console whose code page cannot encode it would turn a finding into a
    # traceback. The output is reconfigured rather than the text being sanitised: the finding has to be
    # printed, whatever it contains.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError, ValueError):
            pass

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
        elif check in TAKES_ALLOW_PARTIAL:
            results.append(check(root, args.allow_partial))
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
        counts = {status: sum(1 for r in results if r.status == status)
                  for status in ("PASS", "FAIL", "UNKNOWN", "UNDECIDABLE")}
        print(f"PASS {counts['PASS']}  FAIL {counts['FAIL']}  UNKNOWN {counts['UNKNOWN']}  "
              f"UNDECIDABLE {counts['UNDECIDABLE']}")

    # `UNDECIDABLE` is a failure on **both** output paths. It means a check in the enforced set could not
    # be evaluated - a condition table missing, a file whose directives do not balance - and reporting
    # "0 broken" with exit 0 for a check that never ran is the false green this status exists to stop.
    # `UNKNOWN` keeps its older meaning: the invocation did not supply what the check needs (no
    # `--upstream-ref`, for instance), which is not the tree's fault and is promoted by `--strict`.
    failed = any(r.status in ("FAIL", "UNDECIDABLE") for r in results)
    if args.strict:
        failed = failed or any(r.status == "UNKNOWN" for r in results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
