#!/usr/bin/env python3
"""Negative and positive cases for `migrate_secondary_page.py`.

A check that cannot fail is worthless. Every case here was written against a defect that was reproduced
first, or against a contract clause that has a way to be violated - and each one was run against the
**pre-fix** tool as well, where it fails. `DSH_MIGRATE_TOOL_DIR=<dir>` swaps the tool under test for a
snapshot of another revision, which is how the before/after exit codes were recorded.

# What the cases are about

  1. nested-import-request-not-renamed   - `NewProfileView.ImportRequest` keeps its identity, and the
                                           alias the copy emits is the one the *shared* initialiser's
                                           signature names. The signature is read out of
                                           `NewProfileViewModel.swift`; the case never tests the
                                           generator against its own predicate.
  2. indented-module-scope-taildrop      - an indented declaration inside `#if !os(tvOS)` is still module
                                           scope and is still renamed.
  3. report-list-keeps-hako-detail       - re-running the generator over the three report list pages never
                                           turns `Hako...ReportDetailView(report:)` back into the upstream
                                           spelling, and never rewrites the provenance header into a path
                                           that does not exist upstream.
  4. terminal-container-keeps-outer-guard- the shared gate keeps `#if canImport(GhosttyTerminal) && os(iOS)`;
                                           the legacy gate still collapses it, unchanged.
  5. font-picker-keeps-dual-platform     - the `#if !os(tvOS)` + `canImport(AppKit)/#elseif canImport(UIKit)`
                                           chain survives the shared gate.
  6. two-runs-identical                  - a `--write` then a second `--write` leaves every byte alone.
  7. differing-target-refused            - an existing target that differs from the candidate, and every
                                           way of trying to authorize its replacement.
  8. fault-injection-all-or-nothing      - a failure part-way through a seven-file write leaves all seven
                                           byte-identical, including deleting the file it had created.
  9. refusal cases                       - the pinned ref does not resolve; a platform condition is
                                           undecidable; the rename map would be empty.

# The copy

Every case runs in a temporary copy of the checkout, made under the system temp directory and removed
afterwards. `git` is only ever asked read-only questions there, and the pinned upstream commit is read
from the *source* checkout's object store (`git rev-parse --git-common-dir`), never from a worktree that
could be pruned underneath the run.

Run:

    python scripts/dev/test_migrate_secondary_page.py

Exit status is 0 when every case behaved as designed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL_NAME = "migrate_secondary_page.py"
TOOL = os.path.join(HERE, TOOL_NAME)

#: The commit every page's provenance is stated against. Quoted rather than imported so a case cannot pass
#: by agreeing with the tool about which commit it is looking at.
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
FORK_REF_NAME = "origin/hako-ui"

#: The two phone-owned files, listed here rather than imported: a case that asked the tool which files it
#: may edit would not notice the tool answering wrongly.
PHONE_FILES = ("SFI/HakoPhoneRootView.swift", "SFI/HakoPageContent.swift")

#: The six report pages and the references each one's migrated copy must keep, with the anchor as the
#: *committed* line - the state `e1cefe6` repaired by hand, or the state a later human repair reached.
#: A run that regenerates the file from upstream replaces those bytes with the upstream spellings.
#:
#: The three list files are the historical regression. The three detail files are the same defect one
#: level out: `ReportZipDocument`, `ReportFileContentView` and `ReportSharePopup` are declared in
#: `Tools/ReportShared.swift`, which is a *different* upstream file from the detail page, so a page-local
#: rename map never prefixes them and the regenerated copy calls the upstream types.
REPORT_FILES = (
    ("ApplicationLibrary/Views/Tools/CrashReportListView.swift",
     "ApplicationLibrary/Views/HakoStyle/HakoCrashReportListView.swift",
     ("HakoCrashReportDetailView(report: report)",)),
    ("ApplicationLibrary/Views/Tools/OOMReportListView.swift",
     "ApplicationLibrary/Views/HakoStyle/HakoOOMReportListView.swift",
     ("HakoOOMReportDetailView(report: report)",)),
    ("ApplicationLibrary/Views/Tools/PowerReportListView.swift",
     "ApplicationLibrary/Views/HakoStyle/HakoPowerReportListView.swift",
     ("HakoPowerReportDetailView(report: report)",)),
    ("ApplicationLibrary/Views/Tools/CrashReportDetailView.swift",
     "ApplicationLibrary/Views/HakoStyle/HakoCrashReportDetailView.swift",
     ("HakoReportZipDocument", "HakoReportFileContentView", "HakoReportSharePopup")),
    ("ApplicationLibrary/Views/Tools/OOMReportDetailView.swift",
     "ApplicationLibrary/Views/HakoStyle/HakoOOMReportDetailView.swift",
     ("HakoReportZipDocument", "HakoReportFileContentView", "HakoReportSharePopup")),
    ("ApplicationLibrary/Views/Tools/PowerReportDetailView.swift",
     "ApplicationLibrary/Views/HakoStyle/HakoPowerReportDetailView.swift",
     ("HakoReportZipDocument", "HakoReportFileContentView", "HakoReportSharePopup")),
)

#: Platform guards named as load-bearing by the integration owner, plus the two the task calls out. Each
#: literal is asserted to be present in the pinned upstream source *before* it is asserted to survive
#: generation, so a stale literal fails loudly instead of testing nothing.
PLATFORM_GOLDEN = (
    ("ApplicationLibrary/Views/Terminal/TerminalSessionContainerView.swift",
     ("#if canImport(GhosttyTerminal) && os(iOS)",)),
    ("ApplicationLibrary/Views/Terminal/TerminalSessionContentView.swift",
     ("#if canImport(GhosttyTerminal)",)),
    ("ApplicationLibrary/Views/Profile/EditProfileView.swift",
     ("#if os(iOS)",)),
    ("ApplicationLibrary/Views/Groups/GroupItemView.swift",
     ("#if os(iOS)", "#elseif os(macOS)", "#else")),
    ("ApplicationLibrary/Views/Setting/FontPickerView.swift",
     ("#if !os(tvOS)", "#if canImport(AppKit)", "#elseif canImport(UIKit)")),
)

#: Literals quoted from the pinned upstream sources. Each is asserted to be present in the upstream file
#: before it is asserted to survive generation, so a stale literal fails loudly instead of silently
#: testing nothing.
GOLDEN = {
    "ApplicationLibrary/Views/Terminal/TerminalSessionContainerView.swift":
        "#if canImport(GhosttyTerminal) && os(iOS)",
    "ApplicationLibrary/Views/Setting/FontPickerView.swift":
        "#if !os(tvOS)",
}
FONT_PICKER_CHAIN = ("#if canImport(AppKit)", "#elseif canImport(UIKit)")


def find_git() -> str:
    for candidate in (os.environ.get("DSH_GIT"), "git"):
        if not candidate:
            continue
        if os.path.isabs(candidate):
            if os.path.exists(candidate):
                return candidate
            continue
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            for suffix in ("", ".exe", ".cmd", ".bat"):
                full = os.path.join(directory, candidate + suffix)
                if os.path.exists(full):
                    return full
    raise AssertionError("no git could be found; set DSH_GIT")


def sha256_file(path: str) -> str | None:
    try:
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except FileNotFoundError:
        return None


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def tree_hashes(root: str) -> dict[str, str]:
    """SHA-256 of every file under `ApplicationLibrary/` and `SFI/`, keyed by relative path."""
    out: dict[str, str] = {}
    for part in ("ApplicationLibrary", "SFI"):
        for base, dirs, files in os.walk(os.path.join(root, part)):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for name in sorted(files):
                full = os.path.join(base, name)
                out[os.path.relpath(full, root).replace("\\", "/")] = sha256_file(full) or ""
    return out


class Harness:
    """One pristine copy of the checkout, and a work copy reset from it before every case."""

    def __init__(self, root: str, keep: bool) -> None:
        self.root = os.path.abspath(root)
        self.git = find_git()
        self.keep = keep
        self.workspace = tempfile.mkdtemp(prefix="jiejiebox-migrate-")
        self.pristine = os.path.join(self.workspace, "pristine")
        self.copy = os.path.join(self.workspace, "work")
        self.sandbox = os.path.join(self.workspace, "sandbox-repo")
        self.tool_dir = os.environ.get("DSH_MIGRATE_TOOL_DIR")

        # The tool under test is the copy's, never the source checkout's. Resolving it from `HERE` looked
        # harmless and was not: the tool derives its root from its own location, so a case that ran the
        # source checkout's copy wrote into the source checkout. `source_hashes` below is the check that
        # catches that, and it exists because it happened.
        self.source_hashes = tree_hashes(self.root)
        self.tool = os.path.join(self.pristine, "scripts", "dev", TOOL_NAME)

        for part in ("ApplicationLibrary", "SFI", "scripts"):
            shutil.copytree(os.path.join(self.root, part), os.path.join(self.pristine, part),
                            ignore=shutil.ignore_patterns("__pycache__"))
        if self.tool_dir:
            for name in os.listdir(self.tool_dir):
                if name.endswith(".py"):
                    shutil.copy2(os.path.join(self.tool_dir, name),
                                 os.path.join(self.pristine, "scripts", "dev", name))
        self.snapshot = None
        self.reset()
        self.tool = os.path.join(self.copy, "scripts", "dev", TOOL_NAME)

        common = subprocess.run(
            [self.git, "-C", self.root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True)
        if common.returncode != 0:
            raise AssertionError("the source checkout is not a git repository; the cases need the pinned "
                                 "upstream commit to read the originals from")
        self.repo = common.stdout.decode("utf-8", "replace").strip()

        self.env = dict(os.environ)
        self.env["DSH_REPO"] = self.repo
        self.env["DSH_GIT"] = self.git
        self.env["PYTHONIOENCODING"] = "utf-8"
        self.env.pop("DSH_SAFETY_FAULT_AT", None)

    def assert_source_untouched(self) -> None:
        """The checkout the copy was made from must be byte-identical. Nothing in this suite may write to
        the tree it is grading."""
        after = tree_hashes(self.root)
        if after != self.source_hashes:
            created = sorted(set(after) - set(self.source_hashes))
            removed = sorted(set(self.source_hashes) - set(after))
            edited = sorted(rel for rel in set(after) & set(self.source_hashes)
                            if after[rel] != self.source_hashes[rel])
            raise AssertionError(f"the source checkout was modified: created={created} removed={removed} "
                                 f"edited={edited}")

    # -- reset -------------------------------------------------------------------------------------

    def reset(self) -> None:
        if os.path.isdir(self.copy):
            shutil.rmtree(self.copy)
        shutil.copytree(self.pristine, self.copy)
        self.snapshot = None

    def take_snapshot(self) -> dict[str, str]:
        self.snapshot = tree_hashes(self.copy)
        return self.snapshot

    def assert_snapshot_unchanged(self, why: str) -> None:
        after = tree_hashes(self.copy)
        if after != self.snapshot:
            changed = sorted(set(after) ^ set(self.snapshot))
            edited = sorted(rel for rel in set(after) & set(self.snapshot)
                            if after[rel] != self.snapshot[rel])
            raise AssertionError(f"{why}: the tree changed. created/removed={changed} edited={edited}")

    # -- subprocess --------------------------------------------------------------------------------

    def run(self, *args: str, env_extra: dict | None = None, repo: str | None = None) -> tuple[int, str, str]:
        """Run the tool under test - the copy's, so the tree it writes to is the copy."""
        env = dict(self.env)
        if repo:
            env["DSH_REPO"] = repo
        if env_extra:
            env.update(env_extra)
        if not os.path.abspath(self.tool).startswith(os.path.abspath(self.copy)):
            raise AssertionError(f"the tool under test resolves to {self.tool}, outside the copy")
        proc = subprocess.run([sys.executable, self.tool, *args], capture_output=True, env=env,
                              cwd=self.workspace)
        return (proc.returncode,
                proc.stdout.decode("utf-8", "replace"),
                proc.stderr.decode("utf-8", "replace"))

    def plan(self, page: str, *extra: str, gate: str | None = None) -> tuple[int, dict, str, str]:
        args = ["--page", page, "--json"]
        if gate:
            args += ["--platform-gate", gate]
        code, out, err = self.run(*args, *extra)
        try:
            return code, json.loads(out), out, err
        except json.JSONDecodeError:
            return code, {}, out, err

    def candidate(self, page: str, gate: str = "shared") -> str:
        code, out, err = self.run("--page", page, "--emit", "--platform-gate", gate)
        if "----- BEGIN CANDIDATE -----" not in out:
            raise AssertionError(f"no candidate was emitted for {page} (exit {code})\n{out[-1200:]}\n{err}")
        return out.split("----- BEGIN CANDIDATE -----", 1)[1].split("----- END CANDIDATE -----", 1)[0]

    def upstream(self, path: str) -> str:
        proc = subprocess.run([self.git, "-C", self.repo, "show", f"{FORK_REF}:{path}"],
                              capture_output=True)
        if proc.returncode != 0:
            raise AssertionError(f"{path} is not at {FORK_REF} in {self.repo}")
        return proc.stdout.decode("utf-8", "replace")

    def path(self, rel: str) -> str:
        return os.path.join(self.copy, rel.replace("/", os.sep))

    # -- a synthetic upstream repository -----------------------------------------------------------

    def synthetic_repo(self, page: str, text: str) -> tuple[str, str]:
        """A throwaway repository holding one page, and the commit that introduces it.

        Used for conditions no page in the real fork carries. It is a real `git init` in the test's own
        temporary directory, so nothing outside the test is written and no ref in any real repository is
        touched.
        """
        os.makedirs(self.sandbox, exist_ok=True)
        identity = ["-c", "user.email=test@example.invalid", "-c", "user.name=migration test"]
        subprocess.run([self.git, "-C", self.sandbox, "init", "-q"], capture_output=True)
        target = os.path.join(self.sandbox, page.replace("/", os.sep))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        write(target, text)
        subprocess.run([self.git, "-C", self.sandbox, "add", "-A"], capture_output=True)
        subprocess.run([self.git, "-C", self.sandbox, *identity, "commit", "-q", "-m", "synthetic"],
                       capture_output=True)
        commit = subprocess.run([self.git, "-C", self.sandbox, "rev-parse", "HEAD"],
                                capture_output=True).stdout.decode().strip()
        if not commit:
            raise AssertionError("the synthetic repository could not be committed to")
        return self.sandbox, commit


# --------------------------------------------------------------------------------------------------
# Cases
# --------------------------------------------------------------------------------------------------


def case_nested_import_request(h: Harness) -> str:
    """1. Nested types keep their identity, and the alias names what the shared signature names."""
    view_model = read(h.path("ApplicationLibrary/Views/Profile/NewProfileViewModel.swift"))
    signature = [line.strip() for line in view_model.split("\n") if "init(importRequest:" in line]
    if len(signature) != 1:
        raise AssertionError(f"expected exactly one `init(importRequest:` line in NewProfileViewModel.swift, "
                             f"found {len(signature)}")
    signature = signature[0]
    # The golden reference, quoted from the shared source rather than from the generator.
    for qualified in ("NewProfileView.ImportRequest", "NewProfileView.LocalImportRequest"):
        if qualified not in signature:
            raise AssertionError(f"the shared signature does not name {qualified}: {signature}")

    code, out, err = h.run("--page", "ApplicationLibrary/Views/Profile/NewProfileView.swift", "--emit")
    if code != 0:
        raise AssertionError(f"the NewProfileView plan was refused (exit {code})\n{out[-1500:]}\n{err}")
    candidate = out.split("----- BEGIN CANDIDATE -----", 1)[1].split("----- END CANDIDATE -----", 1)[0]

    for wrong in ("HakoImportRequest", "HakoLocalImportRequest"):
        if wrong in candidate:
            raise AssertionError(f"the candidate renames a nested type into the module namespace: {wrong}")

    for nested in ("ImportRequest", "LocalImportRequest"):
        alias = f"public typealias {nested} = NewProfileView.{nested}"
        if alias not in candidate:
            raise AssertionError(f"the candidate does not emit `{alias}`, so the copy's "
                                 f"`{nested}` is not the type the shared initialiser takes")
    if "NewProfileViewModel(importRequest: importRequest, localImportRequest: localImportRequest)" \
            not in candidate:
        raise AssertionError("the candidate does not call the shared initialiser with the two requests, so "
                             "the alias is not the thing being checked")
    upstream = h.upstream("ApplicationLibrary/Views/Profile/NewProfileView.swift")
    if "public struct ImportRequest" not in upstream or "public struct LocalImportRequest" not in upstream:
        raise AssertionError("the upstream page no longer declares the two nested request types")
    if "struct HakoImportRequest" in candidate or "struct HakoLocalImportRequest" in candidate:
        raise AssertionError("the candidate still re-declares the nested request types")
    return (f"nested types unrenamed; aliases match `{signature[:70]}...`")


def case_indented_module_scope(h: Harness) -> str:
    """2. An indented declaration inside `#if !os(tvOS)` is module scope and is renamed."""
    upstream = h.upstream("ApplicationLibrary/Views/Tools/TaildropView.swift")
    declaration = [line for line in upstream.split("\n") if "struct TaildropView" in line]
    if len(declaration) != 1 or not re.match(r"^[ \t]+public struct TaildropView", declaration[0]):
        raise AssertionError(f"TaildropView is no longer an indented declaration upstream: {declaration}")
    code, plan, out, err = h.plan("ApplicationLibrary/Views/Tools/TaildropView.swift")
    # The rename is what this case is about. The plan may also be refused for an unrelated reason
    # (`HakoTaildropView` currently calls `HakoCoordinator`, which a regenerated copy would spell the
    # upstream way, so the symbol-loss guard fires) - that refusal is a *pass* for case 3, not this one,
    # and `--emit` prints the candidate either way.
    if code not in (0, 1):
        raise AssertionError(f"the TaildropView run failed outright (exit {code})\n{out[-1200:]}")
    if not any("TaildropView -> HakoTaildropView" in entry for entry in plan.get("renames", [])):
        raise AssertionError(f"the indented module-scope type was not renamed: {plan.get('renames')}")
    candidate = h.candidate("ApplicationLibrary/Views/Tools/TaildropView.swift")
    if "public struct HakoTaildropView" not in candidate:
        raise AssertionError("the candidate does not declare HakoTaildropView")
    if "#if !os(tvOS)" not in candidate:
        raise AssertionError("the shared gate dropped the original's outer guard")
    return "indented module-scope TaildropView renamed, outer guard kept"


def case_report_files_keep_hako_references(h: Harness) -> str:
    """3. The reverse regression never happens again, and the provenance header stays true.

    The `--write` and the anchor assertion come first, and deliberately so: those two lines are the whole
    of the pre-fix failure. A revision that regenerates the target from upstream returns 0 and leaves
    `CrashReportDetailView(report: report)` where `HakoCrashReportDetailView(report: report)` was, so this
    case fails against it on the invariant rather than on an unknown command-line flag.

    It covers all six report pages: the three list files are the historical regression, and the three
    detail files are the same defect one level out, where the reference is to a type that
    `Tools/ReportShared.swift` owns rather than to one the page itself declares.
    """
    h.take_snapshot()
    details = []
    for page, target, anchors in REPORT_FILES:
        before = read(h.path(target))
        for anchor in anchors:
            if anchor not in before:
                raise AssertionError(f"the golden anchor `{anchor}` is not in {target} at {h.root}")
        code, out, err = h.run("--page", page, "--write")
        after = read(h.path(target))
        for anchor in anchors:
            if anchor not in after:
                raise AssertionError(
                    f"{page}: --write removed the golden anchor `{anchor}` from {target}. This is the "
                    f"reverse regression: the target is regenerated from upstream, and a type declared in "
                    f"a different upstream file comes back spelled the upstream way.\n{out[-800:]}")
        if code != 1:
            raise AssertionError(f"{page}: --write over an existing, differing target returned {code}, "
                                 f"not 1\n{out[-800:]}")
        details.append(f"{target.split('/')[-1]}:{anchors[0]}")

        # A refusal has to *name* the symbol it would have lost, or the operator cannot tell which of
        # twenty-two pages is being reported.
        code, plan, out, err = h.plan(page)
        reasons = " ".join(plan.get("refusals", []))
        if code != 1 or "HAKO_SYMBOL_LOSS" not in reasons:
            raise AssertionError(f"{page}: the refusal does not report HAKO_SYMBOL_LOSS (exit {code}): "
                                 f"{reasons[:200] or out[-300:]}")
        for anchor in anchors:
            symbol = re.match(r"\w+", anchor).group(0)
            if symbol not in reasons:
                raise AssertionError(f"{page}: the refusal does not name {symbol}: {reasons[:200]}")

        # The candidate's provenance header names the real upstream path. The committed file's header
        # does not - the pre-fix tool rewrote its own header through the same pattern it used for call
        # sites, so 30 of the 33 committed files claim a path that does not exist at the pin.
        candidate = h.candidate(page)
        if f"The phone's copy of `{page}`" not in candidate:
            raise AssertionError(f"the candidate's header does not state its source as `{page}`")
        header = candidate.split("\n")[4]
        if "/Hako" in header:
            raise AssertionError(f"the candidate's header names the Hako-prefixed path: {header}")
    h.assert_snapshot_unchanged("case 3 wrote something")
    return f"{len(details)} anchors held across six files, nothing written, headers true"


def case_named_platform_guards(h: Harness) -> str:
    """4b. The guards the integration owner named as load-bearing survive the shared gate.

    These are the ones whose loss is not cosmetic. `TerminalSessionContentView` reads two types that are
    themselves behind `canImport(GhosttyTerminal)`, so dropping the file-level guard compiles a body that
    cannot compile; `GroupItemView`'s `itemBackground` is a three-way iOS/macOS/other split, which the
    collapsing gate reduces to its iOS arm and leaves macOS with no body at all.
    """
    checked = []
    for page, literals in PLATFORM_GOLDEN:
        if page in GOLDEN:
            continue  # cases 4 and 5 cover their own pages, including the legacy-gate negative
        upstream = h.upstream(page)
        for literal in literals:
            if literal not in upstream:
                raise AssertionError(f"{page} no longer contains `{literal}` upstream; the golden is stale")
        shared = h.candidate(page, "shared")
        for literal in literals:
            if literal not in shared:
                raise AssertionError(f"the shared gate dropped `{literal}` from {page}")
        if shared.count("#if") != shared.count("#endif"):
            raise AssertionError(f"the shared-gate candidate for {page} has unbalanced directives")
        resolved = h.candidate(page, "resolved")
        if literals[0] in resolved:
            raise AssertionError(f"the legacy gate kept `{literals[0]}` in {page}; its semantics changed")
        checked.append(f"{page.split('/')[-1]}({len(literals)})")
    return "preserved by the shared gate, still collapsed by the legacy gate: " + ", ".join(checked)


def case_terminal_outer_guard(h: Harness) -> str:
    """4. The shared gate keeps the original's outer platform guard; the legacy gate still collapses."""
    page = "ApplicationLibrary/Views/Terminal/TerminalSessionContainerView.swift"
    upstream = h.upstream(page)
    golden = GOLDEN[page]
    if not upstream.startswith(golden):
        raise AssertionError(f"{page} no longer opens with `{golden}` upstream; the golden is stale")
    shared = h.candidate(page, "shared")
    if golden not in shared:
        raise AssertionError(f"the shared gate dropped `{golden}`")
    if shared.count("#if") != shared.count("#endif"):
        raise AssertionError("the shared-gate candidate has unbalanced directives")
    resolved = h.candidate(page, "resolved")
    if golden in resolved:
        raise AssertionError("the resolved gate kept the platform conditional; its semantics changed")
    return f"`{golden}` kept by the shared gate, collapsed by the legacy gate"


def case_font_picker_dual_platform(h: Harness) -> str:
    """5. The `#if !os(tvOS)` + AppKit/UIKit chain survives the shared gate."""
    page = "ApplicationLibrary/Views/Setting/FontPickerView.swift"
    upstream = h.upstream(page)
    for literal in (GOLDEN[page],) + FONT_PICKER_CHAIN:
        if literal not in upstream:
            raise AssertionError(f"{page} no longer contains `{literal}` upstream; the golden is stale")
    shared = h.candidate(page, "shared")
    for literal in (GOLDEN[page],) + FONT_PICKER_CHAIN:
        if literal not in shared:
            raise AssertionError(f"the shared gate dropped `{literal}` from the copy")
    if "public struct HakoFontPickerView" not in shared:
        raise AssertionError("the module-scope type was not renamed")
    resolved = h.candidate(page, "resolved")
    if GOLDEN[page] in resolved or "#elseif canImport(UIKit)" in resolved:
        raise AssertionError("the resolved gate kept a conditional it used to collapse")
    return "`#if !os(tvOS)` and the AppKit/UIKit chain preserved by the shared gate"


def case_two_runs_identical(h: Harness) -> str:
    """6. Determinism: two checks print the same bytes, and a second write changes nothing."""
    page = "ApplicationLibrary/Views/Abstract/FormItem.swift"
    first_code, first_out, _ = h.run("--page", page, "--json")
    second_code, second_out, _ = h.run("--page", page, "--json")
    if (first_code, first_out) != (second_code, second_out):
        raise AssertionError("two consecutive checks on the same tree disagreed")
    plan = json.loads(first_out)
    if first_code != 0 or not plan.get("would_write"):
        raise AssertionError(f"the determinism case needs a page that would write; got exit {first_code} "
                             f"and {plan.get('would_write')}")

    code, out, err = h.run("--page", page, "--write")
    if code != 0:
        raise AssertionError(f"the first --write returned {code}\n{out[-1500:]}\n{err}")
    outputs = plan["would_write"]
    after_first = {rel: sha256_file(h.path(rel)) for rel in outputs}
    if any(value is None for value in after_first.values()):
        raise AssertionError("a file the plan said it would write is not on disk")

    code, out, err = h.run("--page", page, "--write")
    if code != 0:
        raise AssertionError(f"the second --write returned {code}\n{out[-1500:]}\n{err}")
    if "nothing to write" not in out:
        raise AssertionError(f"the second --write did not report a no-op:\n{out[-800:]}")
    after_second = {rel: sha256_file(h.path(rel)) for rel in outputs}
    if after_first != after_second:
        differing = [rel for rel in outputs if after_first[rel] != after_second[rel]]
        raise AssertionError(f"the second run changed {differing}")
    return f"{len(outputs)} outputs identical across two runs; second run a no-op"


def case_differing_target_refused(h: Harness) -> str:
    """7. An existing, differing target is never overwritten without a matching authorization."""
    page = "ApplicationLibrary/Views/Connections/ConnectionView.swift"
    code, plan, out, err = h.plan(page)
    if code != 0 or plan.get("target_state") != "DIFFER":
        raise AssertionError(f"this case needs a page whose target differs; {page} is "
                             f"{plan.get('target_state')!r} with exit {code}")
    target = plan["target"]
    target_sha = plan["target_sha256"]

    h.take_snapshot()
    code, out, err = h.run("--page", page, "--write")
    if code != 1:
        raise AssertionError(f"--write over a differing target returned {code}, not 1\n{out[-800:]}")
    if "TARGET_DIFFERS" not in out:
        raise AssertionError("the refusal does not say TARGET_DIFFERS")
    for needed in (target, target_sha):
        if needed not in out:
            raise AssertionError(f"the refusal does not state {needed!r}")
    h.assert_snapshot_unchanged("an unauthorized --write touched the tree")

    code, out, err = h.run("--page", page, "--write", "--replace", target,
                           "--expect-sha256", "0" * 64)
    if code != 1 or "REPLACE_UNAUTHORIZED" not in out:
        raise AssertionError(f"a wrong --expect-sha256 was not refused (exit {code})")

    code, out, err = h.run("--page", page, "--write", "--replace",
                           "ApplicationLibrary/Views/HakoStyle/HakoSomewhereElse.swift",
                           "--expect-sha256", target_sha)
    if code != 1 or "REPLACE_UNAUTHORIZED" not in out:
        raise AssertionError(f"an authorization naming another path was not refused (exit {code})")

    code, out, err = h.run("--page", page, "--write", "--replace", target)
    if code != 1 or "REPLACE_UNAUTHORIZED" not in out:
        raise AssertionError(f"--replace without --expect-sha256 was not refused (exit {code})")

    code, out, err = h.run("--replace", target, "--expect-sha256", target_sha)
    if code != 2:
        raise AssertionError(f"--replace without --write was not a usage error (exit {code})")

    # There is no blanket override, and the way to check that is to try to use one: `--help` prose
    # mentioning the word would make a text search pass or fail for the wrong reason.
    for forbidden in ("--force", "--force-all", "--yes", "--all", "--force-write"):
        code, out, err = h.run("--page", page, "--write", forbidden)
        if code != 2 or "unrecognized arguments" not in err:
            raise AssertionError(f"{forbidden} was not rejected as an unknown option (exit {code}, "
                                 f"{err.strip()[-200:]!r})")
    h.assert_snapshot_unchanged("a refused replacement touched the tree")
    return "four refusal paths, no override flag, tree byte-identical"


def case_fault_injection(h: Harness) -> str:
    """8. A failure part-way through a multi-file write leaves every target byte-identical."""
    page = "ApplicationLibrary/Views/Abstract/FormItem.swift"
    code, plan, out, err = h.plan(page)
    if code != 0:
        raise AssertionError(f"the fault-injection case needs a writable plan; {page} gave exit {code}\n"
                             f"{out[-1200:]}")
    outputs = plan["would_write"]
    if len(outputs) < 3:
        raise AssertionError(f"the fault-injection case needs a multi-file write; got {outputs}")
    created = [rel for rel in outputs if sha256_file(h.path(rel)) is None]
    if not created:
        raise AssertionError("the case needs at least one file the run would create")

    # (a) a deterministic failure aimed at a middle step
    h.take_snapshot()
    code, out, err = h.run("--page", page, "--write", env_extra={"DSH_SAFETY_FAULT_AT": "4"})
    if code != 1:
        raise AssertionError(f"an injected fault returned {code}, not 1\n{out[-800:]}")
    if "REFUSED" not in out:
        raise AssertionError("an injected fault did not report a refusal")
    h.assert_snapshot_unchanged("an injected fault left a partial write")

    # (b) a real I/O fault: the last target in commit order is read-only, so its swap fails after the
    #     earlier ones have already been put in place.
    h.reset()
    h.take_snapshot()
    last = sorted(outputs)[-1]
    os.chmod(h.path(last), 0o444)
    try:
        code, out, err = h.run("--page", page, "--write")
    finally:
        os.chmod(h.path(last), 0o666)
    if code != 1:
        raise AssertionError(f"a read-only target returned {code}, not 1\n{out[-800:]}")
    h.assert_snapshot_unchanged("a read-only target left a partial write")

    # (c) the injected fault on the *first* step, so nothing had been swapped yet
    h.reset()
    h.take_snapshot()
    code, out, err = h.run("--page", page, "--write", env_extra={"DSH_SAFETY_FAULT_AT": "1"})
    if code != 1:
        raise AssertionError(f"a first-step fault returned {code}, not 1")
    h.assert_snapshot_unchanged("a first-step fault touched the tree")
    return f"{len(outputs)} targets ({len(created)} created) byte-identical after three fault modes"


def case_ref_unresolved(h: Harness) -> str:
    """9a. The pinned ref not resolving is an environment refusal, not a guess."""
    h.take_snapshot()
    code, out, err = h.run("--page", "ApplicationLibrary/Views/Tools/CrashReportListView.swift",
                           "--fork-ref", "0" * 40)
    if code != 2:
        raise AssertionError(f"an unresolvable --fork-ref returned {code}, not 2\n{out[-600:]}\n{err[-600:]}")
    if "does not resolve" not in err:
        raise AssertionError(f"the diagnostic does not say the ref did not resolve: {err[-400:]}")
    h.assert_snapshot_unchanged("an unresolvable ref touched the tree")

    # A page the pinned commit does not contain is an environment error too - the fork deleted it, so it
    # appears in the fork's own diff while existing only in the tree.
    code, out, err = h.run("--page",
                           "ApplicationLibrary/Views/Dashboard/Components/InstallProfileButton.swift")
    if code != 2 or "does not exist at" not in err:
        raise AssertionError(f"a page absent upstream returned {code}: {err[-400:]}")
    return "unresolvable ref and absent page are both environment refusals, exit 2"


def case_undecidable_condition(h: Harness) -> str:
    """9b. A condition the evaluator cannot decide stops the run instead of picking a branch."""
    sys.path.insert(0, os.path.join(h.pristine, "scripts", "dev"))
    import swift_directives as directives  # noqa: PLC0415

    cases = (
        ("#if canImport(SpriteKit)\nlet x = 1\n#endif\n", "ios", "preserve"),
        ("#if canImport(SpriteKit)\nlet x = 1\n#endif\n", "ios", "resolve"),
        ("#if os(tvOS)\nlet x = 1\n#endif\n", "tvos", "preserve"),
        ("#if os(tvOS)\nlet x = 1\n#endif\n", "tvos", "resolve"),
        ("#if targetEnvironment(macCatalyst)\nlet x = 1\n#endif\n", "tvos", "preserve"),
    )
    for text, platform, gate in cases:
        function = directives.preserve if gate == "preserve" else directives.resolve
        try:
            function(text, platform)
        except directives.DirectiveError:
            continue
        raise AssertionError(f"{gate}(..., {platform!r}) decided `{text.splitlines()[0]}` instead of "
                             f"refusing")

    # The two platforms that do have tables must still be decided, or the refusal above would be a
    # refusal to do anything at all.
    if directives.evaluate("canImport(UIKit)", "ios") is not True:
        raise AssertionError("canImport(UIKit) is not True for ios")
    if directives.evaluate("canImport(AppKit)", "ios") is not False:
        raise AssertionError("canImport(AppKit) is not False for ios")
    if directives.resolve("#if os(tvOS)\nx()\n#endif\n", "ios").strip() != "":
        raise AssertionError("an os(tvOS) branch was not dropped when resolving for ios")

    # And the same refusal through the CLI, against a page that really carries the condition.
    page = "ApplicationLibrary/Views/Setting/SyntheticUndecidable.swift"
    synthetic = "#if canImport(SpriteKit)\npublic struct SyntheticUndecidable: View {}\n#endif\n"
    sandbox, commit = h.synthetic_repo(page, synthetic)
    h.take_snapshot()
    code, out, err = h.run("--page", page, "--json", "--fork-ref", commit, repo=sandbox)
    if code != 1:
        raise AssertionError(f"the CLI did not refuse an undecidable condition (exit {code})\n{out[-600:]}")
    if "UNDECIDABLE_CONDITION" not in out:
        raise AssertionError(f"the CLI refusal is not UNDECIDABLE_CONDITION: {out[-600:]}")
    h.assert_snapshot_unchanged("an undecidable condition touched the tree")
    return "5 evaluator conditions refused, 3 decidable ones still decided, CLI refuses too"


def case_rename_map_empty(h: Harness) -> str:
    """9c. A page with no module-scope type is refused, not reported as a success."""
    h.take_snapshot()
    page = "ApplicationLibrary/Views/EnvironmentValues.swift"
    code, plan, out, err = h.plan(page)
    if code != 1:
        raise AssertionError(f"a page with no module-scope type returned {code}, not 1\n{out[-800:]}")
    if "RENAME_MAP_EMPTY" not in " ".join(plan.get("refusals", [])):
        raise AssertionError(f"the refusal is not RENAME_MAP_EMPTY: {plan.get('refusals')}")
    code, out, err = h.run("--page", page, "--write")
    if code != 1:
        raise AssertionError(f"--write on an empty rename map returned {code}, not 1")
    h.assert_snapshot_unchanged("an empty rename map touched the tree")
    return "empty rename map refused in check and in write, tree untouched"


CASES = (
    ("nested-import-request-not-renamed", case_nested_import_request),
    ("indented-module-scope-taildrop", case_indented_module_scope),
    ("report-files-keep-hako-references", case_report_files_keep_hako_references),
    ("terminal-container-keeps-outer-guard", case_terminal_outer_guard),
    ("font-picker-keeps-dual-platform", case_font_picker_dual_platform),
    ("named-platform-guards-preserved", case_named_platform_guards),
    ("two-runs-identical", case_two_runs_identical),
    ("differing-target-refused", case_differing_target_refused),
    ("fault-injection-all-or-nothing", case_fault_injection),
    ("ref-unresolved", case_ref_unresolved),
    ("undecidable-condition", case_undecidable_condition),
    ("rename-map-empty", case_rename_map_empty),
)


def default_root() -> str:
    return os.path.dirname(os.path.dirname(HERE))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None, help="checkout to copy and run against")
    parser.add_argument("--keep", action="store_true", help="keep the temporary copies")
    parser.add_argument("--only", default=None, help="run one case by name")
    args = parser.parse_args()

    root = os.path.abspath(args.root or default_root())
    print(f"source checkout: {root}")
    print(f"tool under test: {os.path.join(HERE, TOOL_NAME)}")
    if os.environ.get("DSH_MIGRATE_TOOL_DIR"):
        print(f"overridden by  : {os.environ['DSH_MIGRATE_TOOL_DIR']}")
    print()

    try:
        harness = Harness(root, args.keep)
    except AssertionError as error:
        print(f"FAIL harness: {error}")
        return 1
    print(f"copy           : {harness.copy}")
    print(f"tool used      : {harness.tool}")
    print(f"upstream repo  : {harness.repo}")
    print()

    passed = 0
    failures: list[str] = []
    try:
        for label, case in CASES:
            if args.only and args.only != label:
                continue
            try:
                harness.reset()
                detail = case(harness)
                harness.assert_source_untouched()
            except AssertionError as error:
                failures.append(f"{label}: {error}")
                print(f"FAIL {label}: {error}")
                continue
            except Exception as error:  # noqa: BLE001 - a crashed case is a failed case, and the label
                failures.append(f"{label}: {type(error).__name__}: {error}")
                print(f"FAIL {label}: {type(error).__name__}: {error}")
                continue
            passed += 1
            print(f"PASS {label}: {detail}")
    finally:
        if args.keep:
            print(f"\ntemporary copies kept at {harness.workspace}")
        else:
            shutil.rmtree(harness.workspace, ignore_errors=True)

    print()
    print(f"{passed} passed, {len(failures)} failed")
    if failures:
        for failure in failures:
            print(f"  - {failure}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
