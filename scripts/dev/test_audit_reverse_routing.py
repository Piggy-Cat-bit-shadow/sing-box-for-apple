#!/usr/bin/env python3
"""Fault-injection cases for the reverse-routing and platform-guard contracts.

What this covers that `test_audit_apple_ui_boundary.py` does not
----------------------------------------------------------------
`audit_apple_ui_boundary.py` gained three checks in round 8:

  * `reverse-routing-contract` - the six user paths where the phone's own page must build the fork's
    view rather than upstream's, written out as a table whose every row cites the original's own file
    and line as evidence;
  * `reverse-routing-derived` - the same error found from the tree instead of from a list: a page
    inside the namespace naming an upstream `View` whose `Hako…` port exists;
  * `platform-guard-agreement` - a condition on an import or on a declaration is not a guard for its
    uses.

Each case breaks exactly one invariant in a **temporary copy**, runs the audit against the copy, and
asserts on the audit's own output: the check must report `FAIL` (or `UNDECIDABLE`), the new finding
must name the file and the line that was broken, reverting the mutation must restore the exact
baseline, and the text path must exit with the same non-zero code as the `--json` path. A case that
only asserted "the run exited non-zero" would pass for a script that crashes.

Expectations name a *file and a symbol*, matched against the audit's `path:line: …` output by pattern,
never by a pinned line number: the line numbers in this tree move whenever a neighbouring file is
edited, and a case that fails because a line moved teaches nothing.

Two deliberate differences from the older module
------------------------------------------------
  * **no git inside the copy.** `.git` is skipped when copying. In a linked worktree `.git` is a *file*
    that names the real git directory, so `git -C <copy> reset` would rewrite the real worktree's index
    - a negative test must not be able to touch the tree it is testing. Nothing here needs git.
  * **junctions and symlinks are skipped when copying, and one case proves the audit skips them too.**
    A junction inside the audited tree points at another checkout; descending into one made every
    check that walks the filesystem report the other repository's files.

Run:

    python scripts/dev/test_audit_reverse_routing.py

Exit status is 0 when every case behaved as designed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIT = os.path.join(HERE, "audit_apple_ui_boundary.py")

HAKO = "ApplicationLibrary/Views/HakoStyle/"

CONTRACT = "reverse-routing-contract"
DERIVED = "reverse-routing-derived"
GUARD = "platform-guard-agreement"

#: Checks that only read the filesystem, used by the junction case. `no-reverse-dependency` is the one
#: that goes red loudest when a walk descends into another checkout: the Hako files behind the junction
#: are no longer under `HAKO_PREFIX`, so every symbol they declare reads as a boundary violation.
FILESYSTEM_CHECKS = (CONTRACT, DERIVED, GUARD, "no-reverse-dependency", "shared-pages-are-clean")


def default_root() -> str:
    return os.path.dirname(os.path.dirname(HERE))


def reference_tree(source: str) -> str:
    """The un-ported original the contracts were derived from, as the round's layout puts it.

    Tried beside the tree under test first - that is where it is when this module audits a worktree - and
    then beside this module's own checkout, which is where it is when `--root` names an extracted tree
    somewhere else.
    """
    for base in (source, default_root()):
        candidate = os.path.normpath(os.path.join(base, os.pardir, os.pardir, "refs", "up-hako"))
        if os.path.isdir(candidate):
            return candidate
    return os.path.normpath(os.path.join(source, os.pardir, os.pardir, "refs", "up-hako"))


def is_reparse_point(path: str) -> bool:
    """Whether a directory is a junction or a symlink rather than a real directory.

    `os.path.islink` is False for a Windows junction, and `shutil.copytree` would copy whatever is
    behind one - a junction inside a worktree points at another checkout, so copying it would put a
    second, different, copy of the tree inside the copy under test.
    """
    try:
        attributes = os.lstat(path).st_file_attributes
    except (OSError, AttributeError):
        return False
    return bool(attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def ignore_links(directory: str, names: list[str]) -> set[str]:
    ignored = {"__pycache__", ".git"}
    for name in names:
        if name in ignored:
            continue
        if is_reparse_point(os.path.join(directory, name)):
            ignored.add(name)
    return ignored


def make_junction(link: str, target: str) -> str:
    """Create a directory junction, or return why it could not be created.

    A junction rather than a symlink on purpose: junctions need no privilege on Windows, and they are
    exactly the shape that was found in this round's worktrees - `os.path.islink` says False for them,
    so a walk that guards on `islink` alone still descends into one.
    """
    if os.path.exists(link):
        return "the link already exists"
    if os.name == "nt":
        proc = subprocess.run(["cmd", "/c", "mklink", "/J", link, target], capture_output=True)
        if proc.returncode == 0 and os.path.isdir(link):
            return ""
        return f"mklink failed: {proc.stdout.decode('utf-8', 'replace').strip()}"
    try:
        os.symlink(target, link, target_is_directory=True)
    except OSError as error:
        return f"symlink failed: {error}"
    return ""


def run_audit(root: str, only: str, as_json: bool = True,
              script_root: str | None = None) -> tuple[int, dict]:
    """Run this checkout's audit against `root`.

    The script is taken from the module's own directory, not from the tree under test: the tree under
    test is a *copy* that this module mutates, and a tree that does not carry the round-8 checks (the
    un-ported original, or `r8/main` before this branch is merged) must still be auditable by them.
    """
    base = script_root or default_root()
    args = [sys.executable, os.path.join(base, "scripts/dev/audit_apple_ui_boundary.py"),
            "--root", root, "--only", only]
    if as_json:
        args.append("--json")
    proc = subprocess.run(args, capture_output=True)
    if as_json:
        try:
            return proc.returncode, json.loads(proc.stdout.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            return proc.returncode, {"checks": []}
    return proc.returncode, {"text": proc.stdout.decode("utf-8", "replace")}


def check_of(payload: dict, name: str) -> dict:
    for check in payload.get("checks", []):
        if check.get("name") == name:
            return check
    return {}


def evidence(payload: dict, name: str) -> list[str]:
    return list(check_of(payload, name).get("evidence", []))


def status(payload: dict, name: str) -> str:
    return check_of(payload, name).get("status", "<missing>")


def detail(payload: dict, name: str) -> str:
    return check_of(payload, name).get("detail", "")


def named(payload: dict, name: str, path: str, symbol: str) -> list[str]:
    """Findings for one check that name this file, on a numbered line, and this symbol.

    The `:\\d+:` is the point of the case: the audit has to say *where*, not only *what*.
    """
    pattern = re.compile(rf"^{re.escape(path)}:\d+: .*{re.escape(symbol)}")
    return sorted(item for item in evidence(payload, name) if pattern.search(item))


def findings_in_file(payload: dict, name: str, path: str) -> list[str]:
    return sorted(item for item in evidence(payload, name) if item.startswith(path + ":"))


def read(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


class Copy:
    """A disposable copy of the checkout, with per-file restore."""

    def __init__(self, source: str, workspace: str):
        self.source = source
        self.workspace = workspace
        self.root = os.path.join(workspace, "checkout")
        self.saved: dict[str, bytes] = {}
        shutil.copytree(source, self.root, symlinks=True, ignore=ignore_links)

    def path(self, relative: str) -> str:
        return os.path.join(self.root, relative.replace("/", os.sep))

    def save(self, relative: str) -> None:
        if relative not in self.saved:
            with open(self.path(relative), "rb") as handle:
                self.saved[relative] = handle.read()

    def restore(self, relative: str) -> None:
        if relative in self.saved:
            with open(self.path(relative), "wb") as handle:
                handle.write(self.saved[relative])

    def restore_all(self) -> None:
        for relative in list(self.saved):
            self.restore(relative)

    def different_files(self) -> list[str]:
        """Files in the copy whose bytes differ from the source, ignoring link targets and caches."""
        out = []
        for base, dirs, files in os.walk(self.root):
            dirs[:] = [d for d in dirs if not is_reparse_point(os.path.join(base, d))]
            for name in files:
                full = os.path.join(base, name)
                relative = os.path.relpath(full, self.root)
                if "__pycache__" in relative.split(os.sep):
                    continue
                counterpart = os.path.join(self.source, relative)
                if not os.path.exists(counterpart):
                    out.append(relative + " (not in the source)")
                    continue
                with open(full, "rb") as handle:
                    mine = hashlib.sha256(handle.read()).digest()
                with open(counterpart, "rb") as handle:
                    theirs = hashlib.sha256(handle.read()).digest()
                if mine != theirs:
                    out.append(relative)
        return sorted(out)


# --------------------------------------------------------------------------------------
# Mutations: each breaks one line, and each asserts its anchor so a rename cannot make a
# case silently un-appliable
# --------------------------------------------------------------------------------------


def edit(copy: Copy, relative: str, old: str, new: str, count: int = 1) -> None:
    path = copy.path(relative)
    copy.save(relative)
    text = read(path)
    found = text.count(old)
    if found != count:
        raise AssertionError(f"{relative}: {old!r} appears {found} time(s), expected {count}")
    write(path, text.replace(old, new, count))


def insert_after(copy: Copy, relative: str, anchor: str, inserted: str) -> None:
    edit(copy, relative, anchor, anchor + inserted)


def append(copy: Copy, relative: str, text: str) -> None:
    path = copy.path(relative)
    copy.save(relative)
    with open(path, "a", encoding="utf-8", newline="") as handle:
        handle.write(text)


# -- the six contracts -------------------------------------------------------------------

def contract_crash_detail(copy: Copy) -> str:
    edit(copy, HAKO + "HakoCrashReportListView.swift",
         "HakoCrashReportDetailView(report: report)", "CrashReportDetailView(report: report)")
    return "the Crash list builds upstream's CrashReportDetailView"


def contract_oom_detail(copy: Copy) -> str:
    edit(copy, HAKO + "HakoOOMReportListView.swift",
         "HakoOOMReportDetailView(report: report)", "OOMReportDetailView(report: report)")
    return "the OOM list builds upstream's OOMReportDetailView"


def contract_power_detail(copy: Copy) -> str:
    edit(copy, HAKO + "HakoPowerReportListView.swift",
         "HakoPowerReportDetailView(report: report)", "PowerReportDetailView(report: report)")
    return "the Power list builds upstream's PowerReportDetailView"


def contract_report_list_link(copy: Copy) -> str:
    edit(copy, HAKO + "HakoToolsView.swift", "HakoCrashReportListView()", "CrashReportListView()")
    return "the Tools page links to upstream's CrashReportListView"


def contract_member_row(copy: Copy) -> str:
    edit(copy, HAKO + "HakoGroupView.swift", "HakoGroupItemView(", "GroupItemView(")
    return "the Proxies group content builds upstream's GroupItemView"


def contract_network_sections(copy: Copy) -> str:
    edit(copy, HAKO + "HakoNetworkQualityView.swift",
         "HakoRemoteToolOutboundSection(commandClient:", "RemoteToolOutboundSection(commandClient:")
    edit(copy, HAKO + "HakoNetworkQualityView.swift",
         "HakoToolOutboundSection(profile:", "ToolOutboundSection(profile:")
    return "Network Quality presents upstream's two outbound sections"


def contract_stun_sections(copy: Copy) -> str:
    edit(copy, HAKO + "HakoSTUNTestView.swift",
         "HakoRemoteToolOutboundSection(commandClient:", "RemoteToolOutboundSection(commandClient:")
    edit(copy, HAKO + "HakoSTUNTestView.swift",
         "HakoToolOutboundSection(profile:", "ToolOutboundSection(profile:")
    return "STUN presents upstream's two outbound sections"


def contract_editor_phone_loses_restyle(copy: Copy) -> str:
    edit(copy, "SFI/HakoPhoneRootView.swift",
         "isEditable: isEditable, restyled: true))", "isEditable: isEditable))")
    return "the phone root stops asking for the restyled editor toolbar"


def contract_editor_tablet_gains_restyle(copy: Copy) -> str:
    edit(copy, "SFI/MainView.swift",
         "isEditable: isEditable))", "isEditable: isEditable, restyled: true))")
    return "the iPad root asks for the phone's editor toolbar"


def contract_editor_default_flipped(copy: Copy) -> str:
    edit(copy, "SFI/ProfileEditorWrapperView.swift", "var restyled: Bool = false",
         "var restyled: Bool = true")
    return "the wrapper defaults to the phone's toolbar, so every caller that says nothing gets it"


def contract_profile_menu(copy: Copy) -> str:
    edit(copy, HAKO + "HakoSheetContent.swift", "HakoNewProfileMenuView()", "NewProfileMenuView()")
    return "Add Configuration presents upstream's NewProfileMenuView"


def contract_profile_shared_navigation(copy: Copy) -> str:
    edit(copy, HAKO + "HakoProfilePickerSheet.swift", "HakoNewProfileSheetContent()",
         "ProfileCard.NewProfileNavigationView()")
    return "the picker is wired back to the shared ProfileCard.NewProfileNavigationView"


def contract_profile_edit(copy: Copy) -> str:
    # The row exists twice in the picker - the iOS 26 list and the one below it - and both are the same
    # page's, so the mutation covers both.
    edit(copy, HAKO + "HakoProfilePickerSheet.swift", "HakoEditProfileView()", "EditProfileView()",
         count=2)
    return "the profile rows open upstream's EditProfileView"


def contract_profile_qr(copy: Copy) -> str:
    edit(copy, HAKO + "HakoProfilePickerSheet.swift", "HakoQRSSheet(profileName:",
         "QRSSheet(profileName:", count=2)
    return "the QR share sheets are upstream's QRSSheet"


def contract_terminal_content(copy: Copy) -> str:
    edit(copy, HAKO + "HakoTerminalSessionContainerView.swift",
         "HakoTerminalSessionContentView(", "TerminalSessionContentView(")
    return "the phone's terminal container builds upstream's content view"


def contract_terminal_container(copy: Copy) -> str:
    edit(copy, HAKO + "HakoToolsView.swift",
         "HakoTerminalSessionContainerView(presented)", "TerminalSessionContainerView(presented)")
    return "the Tools page presents upstream's terminal container"


def derived_bypasses_a_page_the_table_does_not_list(copy: Copy) -> str:
    edit(copy, HAKO + "HakoSettingView.swift", "HakoPacketTunnelView()", "PacketTunnelView()")
    return "the More page opens upstream's PacketTunnelView (no contract row covers it)"


def derived_ignores_a_legitimately_shared_page(copy: Copy) -> str:
    # `MetadataFormView` is a page the original never restyled and has no `Hako…` port, so building it is
    # correct. This is a check on the checker: a rule that fired here would report every unported page in
    # the namespace and would have to be switched off.
    if os.path.exists(copy.path(HAKO + "HakoMetadataFormView.swift")):
        raise AssertionError("this case needs a shared page with no Hako twin")
    append(copy, HAKO + "HakoSettingView.swift", """

/// A page the original never restyled, so the official view is the correct one to build.
struct HakoSharedPageProbe: View {
    var body: some View {
        MetadataFormView(url: URL(fileURLWithPath: "/dev/null"), title: "Probe")
    }
}
""")
    return "a Hako page builds the shared, unported MetadataFormView on purpose"


def guard_definition_guard_deleted(copy: Copy) -> str:
    relative = HAKO + "HakoTerminalSessionContainerView.swift"
    edit(copy, relative, "    #if canImport(GhosttyTerminal) && os(iOS)\n", "")
    edit(copy, relative, "    #endif\n", "")
    return "the terminal container's own guard deleted while its body keeps the guarded types"


def guard_caller_guard_deleted(copy: Copy) -> str:
    """Delete the `#if os(iOS)` that guards the terminal call site, leaving the declaration's guard.

    The mutation used to name the generic lines `"        #if os(iOS)\\n"` and `"        #endif\\n"`. That
    held while the file had exactly one of each; it now has several, because this round restored the
    platform guards `HakoToolsView`'s original has (`up-hako@c1935cf .../Tools/ToolsView.swift:22-29`,
    `:58-103`, `:152-158`, `:160-162`, `:404-458`). A mutation anchored on a line count is not a mutation -
    it is a coincidence that stops holding - so this is anchored on the region it means to change: the guard
    immediately above the `.sheet(item: $sshPresentedSession)` that constructs
    `HakoTerminalSessionContainerView`, together with the `#endif` that closes it.
    """
    relative = HAKO + "HakoToolsView.swift"
    edit(copy, relative,
         "        #if os(iOS)\n        .sheet(item: $sshPresentedSession) { presented in\n"
         "            NavigationStackCompat {\n                HakoTerminalSessionContainerView(presented)\n"
         "            }\n        }\n        #endif\n",
         "        .sheet(item: $sshPresentedSession) { presented in\n"
         "            NavigationStackCompat {\n                HakoTerminalSessionContainerView(presented)\n"
         "            }\n        }\n")
    return "the terminal call site's guard deleted while the declaration keeps its own"


def guard_conditional_import_unguarded_use(copy: Copy) -> str:
    insert_after(copy, HAKO + "HakoSurface.swift",
                 "#if canImport(AppKit)\n    import AppKit\n#endif\n",
                 "let hakoSurfaceAccentSample = NSColor.controlAccentColor\n")
    return ("an AppKit symbol used at file scope although AppKit is imported behind `canImport(AppKit)` "
            "- a conditional import is not a usage guard")


def guard_table_missing(copy: Copy) -> str:
    append(copy, HAKO + "HakoSurface.swift",
           "\n#if canImport(SomeUnknownUIFramework)\nimport SomeUnknownUIFramework\n#endif\n")
    return "a conditional import of a framework the condition table does not know"


def guard_directives_unbalanced(copy: Copy) -> str:
    append(copy, HAKO + "HakoSurface.swift", "\n#if os(iOS)\n")
    return "an `#if` with no `#endif`, so no line's condition can be computed"


def guard_terminal_content_guard_restored(copy: Copy) -> str:
    """Wrap the terminal content view in the file-scope guard its original has.

    The original (`hako-ui` `Terminal/TerminalSessionContentView.swift:1-118`) wraps the whole file; the
    ported copy kept only the import guard. The case is the "green after" proof for that finding, and it
    reports an already-repaired file as repaired rather than failing: `r8/main` fixed this one file, and
    a case that insists on the defect being present would go red on the branch of record.
    """
    relative = HAKO + "HakoTerminalSessionContentView.swift"
    text = read(copy.path(relative))
    if text.count("#if canImport(GhosttyTerminal)") > 1:
        return "already repaired: the file-scope guard is present, and the finding is gone"
    edit(copy, relative, "\n    @MainActor\n    struct HakoTerminalSessionContentView: View {",
         "\n#if canImport(GhosttyTerminal)\n    @MainActor\n    struct HakoTerminalSessionContentView: View {")
    append(copy, relative, "\n#endif\n")
    return "the terminal content view wrapped in the file-scope `canImport(GhosttyTerminal)` it lost"


#: (label, check, mutation, path, symbol the new finding must name)
CASES = (
    ("contract-crash-detail", CONTRACT, contract_crash_detail,
     HAKO + "HakoCrashReportListView.swift", "CrashReportDetailView"),
    ("contract-oom-detail", CONTRACT, contract_oom_detail,
     HAKO + "HakoOOMReportListView.swift", "OOMReportDetailView"),
    ("contract-power-detail", CONTRACT, contract_power_detail,
     HAKO + "HakoPowerReportListView.swift", "PowerReportDetailView"),
    ("contract-report-list-link", CONTRACT, contract_report_list_link,
     HAKO + "HakoToolsView.swift", "CrashReportListView"),
    ("contract-proxies-member-row", CONTRACT, contract_member_row,
     HAKO + "HakoGroupView.swift", "GroupItemView"),
    ("contract-network-sections", CONTRACT, contract_network_sections,
     HAKO + "HakoNetworkQualityView.swift", "RemoteToolOutboundSection"),
    ("contract-stun-sections", CONTRACT, contract_stun_sections,
     HAKO + "HakoSTUNTestView.swift", "RemoteToolOutboundSection"),
    ("contract-editor-phone-loses-restyle", CONTRACT, contract_editor_phone_loses_restyle,
     "SFI/HakoPhoneRootView.swift", "restyled: true"),
    ("contract-editor-tablet-gains-restyle", CONTRACT, contract_editor_tablet_gains_restyle,
     "SFI/MainView.swift", "restyled: true"),
    ("contract-editor-default-flipped", CONTRACT, contract_editor_default_flipped,
     "SFI/ProfileEditorWrapperView.swift", "restyled"),
    ("contract-profile-menu", CONTRACT, contract_profile_menu,
     HAKO + "HakoSheetContent.swift", "NewProfileMenuView"),
    ("contract-profile-shared-navigation", CONTRACT, contract_profile_shared_navigation,
     HAKO + "HakoProfilePickerSheet.swift", "NewProfileNavigationView"),
    ("contract-profile-edit", CONTRACT, contract_profile_edit,
     HAKO + "HakoProfilePickerSheet.swift", "EditProfileView"),
    ("contract-profile-qr", CONTRACT, contract_profile_qr,
     HAKO + "HakoProfilePickerSheet.swift", "QRSSheet"),
    ("contract-terminal-content", CONTRACT, contract_terminal_content,
     HAKO + "HakoTerminalSessionContainerView.swift", "TerminalSessionContentView"),
    ("contract-terminal-container", CONTRACT, contract_terminal_container,
     HAKO + "HakoToolsView.swift", "TerminalSessionContainerView"),
    ("derived-bypass-not-in-the-table", DERIVED, derived_bypasses_a_page_the_table_does_not_list,
     HAKO + "HakoSettingView.swift", "PacketTunnelView"),
    ("guard-definition-guard-deleted", GUARD, guard_definition_guard_deleted,
     HAKO + "HakoTerminalSessionContainerView.swift", "TerminalSessionManager"),
    ("guard-caller-guard-deleted", GUARD, guard_caller_guard_deleted,
     HAKO + "HakoToolsView.swift", "HakoTerminalSessionContainerView"),
    ("guard-conditional-import-unguarded-use", GUARD, guard_conditional_import_unguarded_use,
     HAKO + "HakoSurface.swift", "NSColor"),
    ("guard-table-missing", GUARD, guard_table_missing, "", "SomeUnknownUIFramework"),
    ("guard-directives-unbalanced", GUARD, guard_directives_unbalanced, "", "do not balance"),
)

#: Cases whose expectation is `UNDECIDABLE`, matched against the check's detail: the tree did not let
#: the predicate be evaluated, and the run must say so and exit non-zero rather than pass.
UNDECIDABLE_CASES = ("guard-table-missing", "guard-directives-unbalanced")

CONTRACTS = ("editor-toolbar", "profile-add", "proxies-member-row", "terminal-session",
             "tools-network-section", "tools-reports")

#: Spot checks for the defects the guard check reports on an unguarded tree. Each names the file, a
#: symbol a finding mentions, the guard the original has, and how many times that guard line appears once
#: the file is repaired: `repaired == reported` is a disagreement, so the case asserts the check agrees
#: with what is in the file. `r8/main` has already repaired some of these, and a case that insisted on
#: the defect being present would go red on the branch of record.
#:
#: Only files whose repair is *one file-scope guard* are listed. `HakoLogView.swift` is not: its repair is
#: two block guards inside the file, and a count of `#if canImport(UIKit)` lines cannot tell three from
#: four - a proxy that can be wrong is not a check.
LIVE_GUARD_CHECKS = (
    (HAKO + "HakoTerminalSessionContentView.swift", "TerminalWrapperViewModel",
     "#if canImport(GhosttyTerminal)", 2),
    (HAKO + "HakoTaildropView.swift", "SendingSession", "#if !os(tvOS)", 1),
    (HAKO + "HakoCrashReportDetailView.swift", "ReportShareAction", "#if !os(tvOS)", 1),
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None, help="checkout to copy and mutate")
    parser.add_argument("--keep", action="store_true", help="keep the copy for inspection")
    args = parser.parse_args()

    # The audit's details quote source lines, which are read with `errors="replace"`, so a console whose
    # code page cannot encode the result must not turn a sentence into a traceback.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError, ValueError):
            pass

    source = os.path.abspath(args.root or default_root())
    original = reference_tree(source)
    failures: list[str] = []
    skipped: list[str] = []
    executed = 0

    print(f"source checkout: {source}")
    print(f"audit:           {AUDIT}")
    print()

    workspace = tempfile.mkdtemp(prefix="jiejiebox-reverse-routing-")
    try:
        print("copying the checkout (links and .git skipped) ...")
        copy = Copy(source, workspace)
        print(f"copied to {copy.root}")
        print()

        # 1. Positive: the six contracts hold on the unmodified tree, and the general form agrees.
        executed += 1
        code, payload = run_audit(copy.root, CONTRACT)
        chains = evidence(payload, CONTRACT)
        missing = [name for name in CONTRACTS if not any(name in chain for chain in chains)]
        if code == 0 and status(payload, CONTRACT) == "PASS" and not missing:
            print(f"[ ok ] positive-contract: {CONTRACT} -> PASS, exit 0")
            for chain in chains:
                print(f"         {chain.split(':')[0]}: {len(chain.split(' -> '))} link(s) verified")
        else:
            failures.append(f"positive-contract: expected PASS with all six chains, got "
                            f"{status(payload, CONTRACT)} (exit {code}, missing {missing})")
            print(f"[FAIL] positive-contract: {status(payload, CONTRACT)}, exit {code}, "
                  f"missing {missing}")

        executed += 1
        code, payload = run_audit(copy.root, DERIVED)
        if code == 0 and status(payload, DERIVED) == "PASS":
            print(f"[ ok ] positive-derived: {DERIVED} -> PASS, exit 0  "
                  f"({detail(payload, DERIVED)[:64]})")
        else:
            failures.append(f"positive-derived: expected PASS, got {status(payload, DERIVED)} "
                            f"(exit {code})")
            print(f"[FAIL] positive-derived: {status(payload, DERIVED)}, exit {code}")

        # 2. The derived rule must not report a legitimately shared page.
        executed += 1
        description = derived_ignores_a_legitimately_shared_page(copy)
        code, payload = run_audit(copy.root, DERIVED)
        mentions = [item for item in evidence(payload, DERIVED) if "MetadataFormView" in item]
        if code == 0 and status(payload, DERIVED) == "PASS" and not mentions:
            print(f"[ ok ] derived-ignores-shared-page: still PASS  ({description})")
        else:
            failures.append(f"derived-ignores-shared-page: expected PASS with no finding, got "
                            f"{status(payload, DERIVED)} (exit {code}, mentions {mentions})")
            print(f"[FAIL] derived-ignores-shared-page: {status(payload, DERIVED)}, exit {code}, "
                  f"mentions {mentions}")
        copy.restore_all()

        # 3. The guard check must agree with the tree about the defects that are in it.
        executed += 1
        code, payload = run_audit(copy.root, GUARD)
        guard_state = status(payload, GUARD)
        disagreements = []
        for path, symbol, guard_line, repaired_count in LIVE_GUARD_CHECKS:
            repaired = read(copy.path(path)).count(guard_line) >= repaired_count
            reported = bool(findings_in_file(payload, GUARD, path))
            if repaired != reported:
                continue
            disagreements.append(f"{path}: guard x{read(copy.path(path)).count(guard_line)} "
                                 f"(repaired={repaired}) but reported={reported} for {symbol}")
        expect_fail = any(read(copy.path(path)).count(guard_line) < repaired_count
                          for path, symbol, guard_line, repaired_count in LIVE_GUARD_CHECKS)
        want = "FAIL" if expect_fail else "PASS"
        if guard_state == want and not disagreements:
            print(f"[ ok ] guard-agrees-with-tree: {GUARD} -> {guard_state}, exit {code}; "
                  f"{len(evidence(payload, GUARD))} finding(s)")
        else:
            failures.append(f"guard-agrees-with-tree: expected {want}, got {guard_state} "
                            f"(exit {code}); {disagreements}")
            print(f"[FAIL] guard-agrees-with-tree: expected {want}, got {guard_state}, exit {code}; "
                  f"{disagreements}")

        # 4. The repair the finding asks for must make it go away: the "green after" half.
        executed += 1
        baseline = findings_in_file(payload, GUARD, HAKO + "HakoTerminalSessionContentView.swift")
        description = guard_terminal_content_guard_restored(copy)
        _, repaired = run_audit(copy.root, GUARD)
        remaining = findings_in_file(repaired, GUARD, HAKO + "HakoTerminalSessionContentView.swift")
        if not remaining:
            print(f"[ ok ] guard-repair-clears-findings: {len(baseline)} finding(s) in that file -> 0, "
                  f"{len(evidence(repaired, GUARD))} remain elsewhere  ({description})")
        else:
            failures.append(f"guard-repair-clears-findings: expected 0 findings for that file, "
                            f"had {len(baseline)}, left {len(remaining)}")
            print(f"[FAIL] guard-repair-clears-findings: {len(baseline)} -> {len(remaining)}")
        copy.restore_all()

        # 5. A junction inside the tree must not change any verdict. The walk has to skip it: behind one
        #    is another checkout, and this round's `project-membership` reported ~600 files of it as
        #    untracked Swift sources before the walk was fixed.
        executed += 1
        before = {}
        for name in FILESYSTEM_CHECKS:
            _, payload = run_audit(copy.root, name)
            before[name] = status(payload, name)
        link = copy.path("linked-checkout")
        problem = make_junction(link, source)
        if problem:
            executed -= 1
            skipped.append(f"junction-is-not-descended-into ({problem})")
            print(f"[skip] junction-is-not-descended-into: {problem}")
        else:
            changed = []
            for name in FILESYSTEM_CHECKS:
                _, payload = run_audit(copy.root, name)
                if status(payload, name) != before[name]:
                    changed.append(f"{name}: {before[name]} -> {status(payload, name)}")
                if any("linked-checkout" in item for item in evidence(payload, name)):
                    changed.append(f"{name}: a finding names a file behind the junction")
            os.rmdir(link)
            if changed:
                failures.append(f"junction-is-not-descended-into: {changed}")
                print(f"[FAIL] junction-is-not-descended-into: {changed}")
            else:
                print(f"[ ok ] junction-is-not-descended-into: {len(FILESYSTEM_CHECKS)} check(s) "
                      f"unchanged with a junction to another checkout in the tree")

        # 6. One broken line at a time. The baseline is what the check reports before the mutation, so a
        #    case proves the injection caused the new finding and the restore removed it.
        for label, name, mutate, path, symbol in CASES:
            executed += 1
            try:
                copy.restore_all()
                _, before_payload = run_audit(copy.root, name)
                before_findings = evidence(before_payload, name)
                before_state = status(before_payload, name)
                description = mutate(copy)
            except AssertionError as error:
                failures.append(f"{label}: mutation could not be applied ({error})")
                print(f"[FAIL] {label}: mutation could not be applied: {error}")
                continue

            code, after_payload = run_audit(copy.root, name)
            new = [item for item in evidence(after_payload, name) if item not in before_findings]
            after_state = status(after_payload, name)
            want_state = "UNDECIDABLE" if label in UNDECIDABLE_CASES else "FAIL"
            if label in UNDECIDABLE_CASES:
                wanted = [detail(after_payload, name)] if symbol in detail(after_payload, name) else []
            else:
                wanted = named(after_payload, name, path, symbol)

            if code == 1 and after_state == want_state and wanted:
                text_code, _ = run_audit(copy.root, name, as_json=False)
                if text_code != code:
                    failures.append(f"{label}: --json exit {code} but the text path exited {text_code}")
                    print(f"[FAIL] {label}: exit codes disagree (json {code}, text {text_code})")
                else:
                    where = wanted[0].split(": ")[0]
                    print(f"[ ok ] {label}: {name} -> {after_state}, exit {code} on both paths, "
                          f"naming {where}  ({description})")
            else:
                failures.append(f"{label}: expected {want_state} naming {path or symbol!r}, got "
                                f"{after_state} (exit {code}, {len(new)} new finding(s))")
                print(f"[FAIL] {label}: {after_state}, exit {code}; expected {want_state} naming "
                      f"{path or symbol!r}; new findings: {[item[:110] for item in new[:2]]}")

            copy.restore_all()
            _, restored = run_audit(copy.root, name)
            if evidence(restored, name) != before_findings or status(restored, name) != before_state:
                failures.append(f"{label}: the copy did not return to its baseline after the restore")
                print(f"[FAIL] {label}: baseline not restored")

        # 7. The predicate must pass on the tree the fork started from, or it is describing the porting
        #    step rather than a boundary the original respected.
        if os.path.isdir(original):
            executed += 1
            results = {}
            for name in (DERIVED, GUARD):
                code, payload = run_audit(os.path.abspath(original), name, script_root=source)
                results[name] = (status(payload, name), code)
            bad = {name: value for name, value in results.items() if value != ("PASS", 0)}
            if not bad:
                print(f"[ ok ] original-tree-passes: both new predicates PASS, exit 0 on "
                      f"{os.path.abspath(original)}")
            else:
                failures.append(f"original-tree-passes: {bad}")
                print(f"[FAIL] original-tree-passes: {bad}")
        else:
            skipped.append(f"original-tree-passes ({original} is not present)")
            print(f"[skip] original-tree-passes: {original} is not present")

        # 8. Isolation: the copy is byte-identical to the source, so nothing leaked either way.
        executed += 1
        different = copy.different_files()
        if not different:
            print("[ ok ] isolation: the copy is byte-identical to the source after every case")
        else:
            failures.append(f"isolation: {len(different)} file(s) differ from the source: "
                            f"{different[:5]}")
            print(f"[FAIL] isolation: {different[:5]}")
    finally:
        if args.keep:
            print(f"\ncopy kept at {workspace}")
        else:
            shutil.rmtree(workspace, ignore_errors=True)

    print()
    print(f"{executed} case(s) executed" + (f", {len(skipped)} skipped" if skipped else ""))
    for item in skipped:
        print(f"  skipped: {item}")
    if failures:
        print(f"{len(failures)} case(s) did not behave as designed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("every case failed the audit as designed, and every positive case passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
