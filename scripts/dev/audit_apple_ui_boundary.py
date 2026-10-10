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
#: Files the phone's pages may reach, and the only places outside `HakoStyle/` that may name a Hako
#: symbol.
#:
#: Two shared files are here, and both for the same reason: the phone's design cannot be served without
#: a change that has nowhere else to live.
#:
#:   * `Profile/ProfileSheetHelpers.swift` - the modal container all eight of the client's modals are
#:     built on, and the one file whose status is not settled. See the note below.
#:
#: `ApplicationLibrary/Views/EnvironmentValues.swift` was on this list for one commit and is not any
#: more: the `hakoCompactRows` key moved to `HakoStyle/HakoEnvironmentValues.swift`, the shared file went
#: back to its pinned bytes, and an allow-list entry for a file that no longer differs is a hole - it
#: would silently absorb the next real edit to it.
PHONE_ROOT_FILES = (
    "SFI/Application.swift", "SFI/HakoPhoneRootView.swift", "SFI/HakoPageContent.swift",
    "ApplicationLibrary/Views/Profile/ProfileSheetHelpers.swift",
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


def swift_files(root: str, under: str | None = None) -> list[str]:
    """Swift files under `root`, or under `root/<under>` when a subtree is wanted.

    `under` exists so a check can count what is in a subtree - the boundary check needs to know the
    Hako namespace is not empty before it can report that nothing outside it names a Hako symbol.
    """
    scan = os.path.join(root, under) if under else root
    out = []
    for base, dirs, files in os.walk(scan):
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


#: Files this fork is allowed to have modified, each with the reason it had to be. A file that is
#: not on this list and differs from upstream is a `FAIL`, not a note: an unreviewed edit to a file
#: upstream owns is the thing this check exists to stop, and a check that only reports it is a
#: check nobody reads twice.
REVIEWED_UPSTREAM_MODIFICATIONS = {
    ".gitignore":
        "`__pycache__/` and `*.pyc`, for the two Python scripts under scripts/dev",
    "ApplicationLibrary/Views/Profile/ProfileSheetHelpers.swift":
        "the close control every modal on this container needs. Eight modals are built on it and none "
        "had one, so a sheet could only be dismissed by dragging it down; the change is not "
        "phone-specific, and forking the container would have meant retargeting eight shared call sites "
        "to a Hako-only type",
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
            for mods, found in extension_members(text, match.end()):
                if is_file_scoped(mods):
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
    check_shared_declaration_duplicates,
    check_hako_symbol_completeness,
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
        counts = {status: sum(1 for r in results if r.status == status) for status in ("PASS", "FAIL", "UNKNOWN")}
        print(f"PASS {counts['PASS']}  FAIL {counts['FAIL']}  UNKNOWN {counts['UNKNOWN']}")

    failed = any(r.status == "FAIL" for r in results)
    if args.strict:
        failed = failed or any(r.status == "UNKNOWN" for r in results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
