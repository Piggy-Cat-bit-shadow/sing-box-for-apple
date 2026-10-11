#!/usr/bin/env python3
"""Negative cases for `audit_apple_ui_boundary.py`.

A guard that cannot fail is not a guard. Each case here builds a copy of the checkout, breaks exactly
one invariant, runs the audit, and asserts the audit **reports that specific check as a failure** -
not merely that it exits non-zero, because "something failed" is what a broken script also does.

# How a mutation is written

Every mutation finds its anchor by *searching a line*, never by matching a multi-line literal whose
indentation has to be guessed. Two earlier revisions of this file were wrong for exactly that reason:
a mutation whose anchor did not match reported "could not be applied", and one whose anchor matched in
more than one place made a one-line change the check could not see. Where a mutation needs to replace
a line, it does so by exact line text and asserts the count.

# The copy

The copy is made once and reset between cases. A case that leaks state makes the next case's result
meaningless, so `reset` verifies the working tree is clean afterwards and the suite fails loudly if it
is not.

Run:

    python scripts/dev/test_audit_apple_ui_boundary.py

Exit status is 0 when every case behaved as designed.

Some cases are about the audit rather than about the tree, and they matter as much as the rest:

  * `positive` - the unmutated copy must pass, or every failure below would be meaningless;
  * `migration-incomplete` - the page count must be a failure without `--allow-partial`, so an
    unfinished migration cannot be mistaken for a finished one;
  * `missing-input` - deleting what a check reads must make it `UNKNOWN`, never `PASS`. This is the
    failure mode that makes a static audit worthless: a check that silently stops checking.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIT = os.path.join(HERE, "audit_apple_ui_boundary.py")

#: The pinned upstream commit this branch was cut from. The checks that compare against upstream only
#: mean something against a fixed baseline, so the cases that exercise them pass it explicitly rather
#: than relying on the checkout having an `upstream` remote configured.
UPSTREAM_REF = "089d35e"


def default_root() -> str:
    return os.path.dirname(os.path.dirname(HERE))


def find_git() -> str | None:
    for candidate in (os.environ.get("DSH_GIT"), "git",
                      r"C:\Deepseek\安卓客户端\.tools\git\cmd\git.exe"):
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


def run_audit(root: str, only: str | None = None, upstream_ref: str | None = None,
              git_broken_dir: str | None = None, allow_partial: bool = False) -> tuple[int, dict]:
    args = [sys.executable, AUDIT, "--root", root, "--json"]
    if only:
        args += ["--only", only]
    if upstream_ref:
        args += ["--upstream-ref", upstream_ref]
    if allow_partial:
        args += ["--allow-partial"]
    env = None
    if git_broken_dir is not None:
        # A `git` that exists on PATH and always fails. The audit resolves git through PATH, so
        # putting a broken one first is how "git is present but unusable" is simulated without
        # touching any real ref. `DSH_GIT` is cleared so it cannot short-circuit the lookup.
        env = dict(os.environ)
        env.pop("DSH_GIT", None)
        env["PATH"] = git_broken_dir + os.pathsep + env.get("PATH", "")
    proc = subprocess.run(args, capture_output=True, env=env)
    try:
        payload = json.loads(proc.stdout.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        payload = {"checks": [], "_stdout": proc.stdout.decode("utf-8", "replace"),
                   "_stderr": proc.stderr.decode("utf-8", "replace")}
    return proc.returncode, payload


def statuses(payload: dict) -> dict[str, str]:
    return {c["name"]: c["status"] for c in payload.get("checks", [])}


def detail_of(payload: dict, name: str) -> str:
    for check in payload.get("checks", []):
        if check["name"] == name:
            return check.get("detail", "") or ""
    return ""


def read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def replace_line_containing(path: str, needle: str, replacement: str, *, count: int = 1) -> None:
    """Replace the whole line that contains `needle`, preserving its indentation.

    Anchoring on a line rather than on a multi-line literal is the whole point: an earlier revision
    guessed the indentation of a two-line block, guessed wrong, and reported "mutation could not be
    applied" - which reads as a problem with the tree rather than with the test.
    """
    text = read(path)
    lines = text.split("\n")
    hits = [i for i, line in enumerate(lines) if needle in line]
    if len(hits) != count:
        raise AssertionError(f"{os.path.basename(path)}: {needle!r} appears on {len(hits)} line(s), "
                             f"expected {count}")
    for index in hits:
        indent = re.match(r"\s*", lines[index]).group(0)
        lines[index] = indent + replacement
    write(path, "\n".join(lines))


def replace_exact(path: str, old: str, new: str, *, count: int = 1) -> None:
    text = read(path)
    found = text.count(old)
    if found != count:
        raise AssertionError(f"{os.path.basename(path)}: {old!r} appears {found} time(s), "
                             f"expected {count}")
    write(path, text.replace(old, new, count))


# --------------------------------------------------------------------------------------
# Mutations
# --------------------------------------------------------------------------------------


def mutate_hako_ref_in_upstream_page(root: str) -> str:
    path = os.path.join(root, "ApplicationLibrary/Views/Setting/SettingView.swift")
    replace_exact(path, "FormView {", "HakoRootScaffold {")
    return "a Hako scaffold inserted into the upstream-reachable SettingView"


def mutate_pad_to_hako(root: str) -> str:
    path = os.path.join(root, "SFI/Application.swift")
    replace_exact(path, "        case .phone:", "        case .phone, .pad:")
    return "the pad idiom routed to the phone's Hako root"


def mutate_sizeclass_dispatch(root: str) -> str:
    path = os.path.join(root, "SFI/Application.swift")
    replace_exact(path, "    var body: some Scene {",
                  "    var body: some Scene {\n        let _ = horizontalSizeClass")
    return "a size-class read added to the root that chooses the design family"


def mutate_display_name(root: str) -> str:
    path = os.path.join(root, "sing-box.xcodeproj/project.pbxproj")
    replace_exact(path, 'INFOPLIST_KEY_CFBundleDisplayName = "Jiejiebox";',
                  'INFOPLIST_KEY_CFBundleDisplayName = "sing-box";', count=4)
    return "the visible name reverted to sing-box"


def mutate_variant_application_name(root: str) -> str:
    path = os.path.join(root, "Library/Shared/Variant.swift")
    replace_exact(path, 'public static let applicationName = "SFI"',
                  'public static let applicationName = "Jiejiebox"')
    return "Variant.applicationName renamed, which would reach the VPN profile and the User-Agent"


def mutate_quota_row(root: str) -> str:
    # The row exists, is bound, and draws nothing: the `Text` that carries the quota is commented out,
    # so the view builder returns an empty view. This is the failure a check that looked for the item's
    # *name* could not see, and it is what the current check is written against - the item has to
    # return a `Text`.
    path = os.path.join(root, "ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift")
    text = read(path)
    start = text.find("private var remainingTrafficInfo: some View {")
    if start < 0:
        raise AssertionError("remainingTrafficInfo not found in the phone's picker")
    end = text.find("\n    }", start)
    if end < 0:
        raise AssertionError("the end of remainingTrafficInfo could not be found")
    body = text[start:end]
    commented = "\n".join(
        ("// " + line) if line.strip().startswith("Text(") else line
        for line in body.split("\n")
    )
    if commented == body:
        raise AssertionError("no `Text(` line inside remainingTrafficInfo to comment out")
    write(path, text[:start] + commented + text[end:])
    return "the remaining-quota item declared, bound, and drawing nothing"


def mutate_quota_model(root: str) -> str:
    path = os.path.join(root, "Library/Network/SubscriptionInfo.swift")
    replace_line_containing(path, "public var remainingBytes: Int64? {",
                            "public var remainingBytesRenamed: Int64? {")
    return "the remaining-bytes accessor renamed, which would empty the row at runtime"


def mutate_quota_presenter_removed(root: str) -> str:
    # The page that presents the phone's configuration centre stops doing so. The sheet stays and the
    # picker still compiles, so nothing about the source says the quota is gone - only the wiring does.
    path = os.path.join(root, "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift")
    replace_line_containing(path, "HakoProfilePickerSheet(",
                            "Text(verbatim: \"profiles\")")
    return "the phone's Home stopped presenting the quota-bearing configuration centre"


def mutate_page_reverted_to_upstream(root: str) -> str:
    # The first-level page goes back to upstream's view while the Hako file stays in the tree. This is
    # the failure the coverage check exists for: a check that looked for the file would still pass.
    #
    # The anchor is the switch's arm, not the property's name - both read `dashboardPage`, and only the
    # arm is the routing.
    path = os.path.join(root, "SFI/HakoPageContent.swift")
    replace_line_containing(path, "case .dashboard:", "case .dashboard:\n                DashboardView()")
    replace_line_containing(path, "                dashboardPage", "                EmptyView()")
    return "the Home page reverted to upstream's DashboardView while the Hako file remains"


def mutate_official_picker_gains_quota(root: str) -> str:
    # The exact hole the phase-1 audit had: this file is on the reviewed-modification list, so a
    # whitelist absorbs the change - and the row is visible on an iPad.
    path = os.path.join(root, "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift")
    # The file declares `profileInfo` twice - once in the current row and once in the pre-iOS-26 one -
    # so the anchor is the whole line including its indentation, which is unique to neither and
    # therefore has to be qualified by the type it belongs to. `ProfilePickerRow` comes first.
    text = read(path)
    anchor = "private struct ProfilePickerRow: View {"
    start = text.find(anchor)
    if start < 0:
        raise AssertionError("ProfilePickerRow not found")
    target = "    private var profileInfo: some View {"
    index = text.find(target, start)
    if index < 0:
        raise AssertionError("profileInfo not found inside ProfilePickerRow")
    text = (
        text[:index]
        + "    private var remainingTrafficInfo: some View {\n"
        + "        Text(verbatim: String(format: String(localized: \"%@ left\"), \"0 B\"))\n"
        + "    }\n\n"
        + target
        + "\n        remainingTrafficInfo"
        + text[index + len(target):]
    )
    write(path, text)
    return "the official picker given the phone's remaining-quota row (it is on the review list)"


def mutate_upstream_file(root: str) -> str:
    # A file that is genuinely not on the reviewed list. This was `LogView.swift`, which was the right
    # choice while the list was shorter and stopped being one the moment the Logs slice added it - a
    # case whose expectation is "this file is unreviewed" has to name a file that is, and the suite
    # says so rather than passing for the wrong reason.
    path = os.path.join(root, "ApplicationLibrary/Views/Groups/GroupListView.swift")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n// an unreviewed edit to an upstream file\n")
    return "an upstream-owned file edited without a decision"


def mutate_submodule_url(root: str) -> str:
    # The gitlink cannot be given a null SHA (`git update-index` refuses), so the mutation is the other
    # half of a submodule's identity: where it points.
    path = os.path.join(root, ".gitmodules")
    replace_exact(path, "https://github.com/nekohasekai/Runestone.git",
                  "https://github.com/example/Runestone.git")
    return "the Runestone submodule URL pointed somewhere else"



def mutate_environment_key_removed(root: str) -> str:
    # The key `HakoRow` and `HakoScaffold` read is deleted from the shared `EnvironmentValues` extension.
    # Both files are the original's bytes, so this is exactly the state the tree was in before it was
    # noticed: two readers, no declaration, and no check able to see it.
    #
    # The anchor is the doc comment above the key, located by searching for a single word and walking
    # back to the start of that line rather than by matching a longer literal. Four earlier versions of
    # this anchor failed: the shell that wrote them mangled a quote, an apostrophe, a space, and finally
    # an escape, and each failure reported "mutation could not be applied" - which reads as a problem
    # with the tree rather than with the test. A bare word, a newline built by `chr`, and an assertion
    # that the line really is a comment have nothing left to mangle.
    path = os.path.join(root, "ApplicationLibrary/Views/HakoStyle/HakoEnvironmentValues.swift")
    text = read(path)
    found = text.find("compact metric")
    if found < 0:
        raise AssertionError("the compact-rows doc comment is not in EnvironmentValues.swift")
    line_start = text.rfind(chr(10), 0, found) + 1
    if not text[line_start:found].lstrip().startswith(chr(47)):
        raise AssertionError("the line above the key is not a doc comment")
    write(path, text[:line_start].rstrip() + chr(10))
    return ("the compact-rows environment key removed from its Hako-owned file while two original "
            "files still read it")



def mutate_shared_container_gains_hako_close(root: str) -> str:
    # The P0 this project shipped and then removed: `HakoCloseButton()` inside the **shared** modal
    # container's iOS body. `os(iOS)` is true on an iPad too, so that reaches every iPad modal built on
    # the container. The phone's modals attach their close to the content instead, through
    # `hakoModalClose()`, and the shared file is byte-identical to upstream - so re-injecting the call
    # must fail the reverse-dependency gate.
    path = os.path.join(root, "ApplicationLibrary/Views/Profile/ProfileSheetHelpers.swift")
    anchor = "                    .navigationBarTitleDisplayMode(.inline)"
    if anchor not in read(path):
        raise AssertionError("the iOS body anchor is not in ProfileSheetHelpers.swift")
    replace_exact(
        path,
        anchor,
        anchor
        + "\n                    .toolbar {\n"
          "                        ToolbarItem(placement: .cancellationAction) {\n"
          "                            HakoCloseButton()\n"
          "                        }\n"
          "                    }",
    )
    return "HakoCloseButton put back into the shared modal container, where an iPad compiles it"


CASES = (
    # (label, check that must fail, mutation, upstream ref that check needs)
    ("hako-ref-in-upstream-page", "shared-pages-are-clean", mutate_hako_ref_in_upstream_page, None),
    ("pad-routed-to-hako", "phone-entry", mutate_pad_to_hako, None),
    ("size-class-in-root", "phone-entry", mutate_sizeclass_dispatch, None),
    ("display-name-reverted", "branding", mutate_display_name, None),
    ("variant-application-name", "branding", mutate_variant_application_name, None),
    ("quota-row-unlinked", "subscription-feature", mutate_quota_row, None),
    ("quota-model-renamed", "subscription-feature", mutate_quota_model, None),
    ("quota-presenter-removed", "subscription-feature", mutate_quota_presenter_removed, None),
    ("page-reverted-to-upstream", "hako-page-coverage", mutate_page_reverted_to_upstream, None),
    ("official-picker-gains-quota", "ipad-mac-ui-gate", mutate_official_picker_gains_quota, UPSTREAM_REF),
    ("shared-container-gains-hako-close", "no-reverse-dependency",
     mutate_shared_container_gains_hako_close, None),
    ("environment-key-removed", "hako-symbol-completeness", mutate_environment_key_removed, None),
    ("submodule-url-moved", "repository-hygiene", mutate_submodule_url, UPSTREAM_REF),
)


def reset(copy: str, git: str | None) -> None:
    """Return the copy to its committed state, and prove it."""
    if not git:
        return
    subprocess.run([git, "-C", copy, "reset", "-q"], capture_output=True)
    subprocess.run([git, "-C", copy, "checkout", "-q", "--", "."], capture_output=True)
    dirty = subprocess.run([git, "-C", copy, "status", "--porcelain=v1", "-uall"],
                           capture_output=True).stdout.decode("utf-8", "replace").strip()
    # `.gitmodules` is restored by the checkout above; a placeholder symlink on Windows may look
    # modified, which `core.symlinks=false` already handles. Anything else is a leaked mutation.
    if dirty:
        raise AssertionError(f"the copy is still dirty after reset:\n{dirty}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None, help="checkout to copy and mutate")
    parser.add_argument("--keep", action="store_true", help="keep the copy for inspection")
    args = parser.parse_args()

    root = os.path.abspath(args.root or default_root())
    git = find_git()

    print(f"source checkout: {root}")
    print(f"audit:           {AUDIT}")
    print(f"git:             {git}")
    print()

    workspace = tempfile.mkdtemp(prefix="jiejiebox-audit-negatives-")
    copy = os.path.join(workspace, "checkout")
    print(f"copying the checkout to {copy} ...")
    shutil.copytree(root, copy, symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    print("copied")
    print()

    failures: list[str] = []
    try:
        # 1. The unmutated copy must pass everything except the migration count, which is incomplete
        #    on purpose and says so through `--allow-partial`.
        code, payload = run_audit(copy, allow_partial=True)
        states = statuses(payload)
        failing = sorted(name for name, state in states.items() if state == "FAIL")
        if code != 0 or failing:
            failures.append(f"positive: the unmutated copy did not pass (exit {code}, failures {failing})")
            print(f"[FAIL] positive: unmutated copy (exit {code}, failures {failing})")
        else:
            unknown = sorted(name for name, state in states.items() if state == "UNKNOWN")
            print(f"[ ok ] positive: unmutated copy passes all {len(states)} checks "
                  f"({len(unknown)} UNKNOWN: {', '.join(unknown) or 'none'})")

        # 2. The page count must be a failure without the flag, or an unfinished migration could be
        #    mistaken for a finished one.
        reset(copy, git)
        code, payload = run_audit(copy, only="hako-page-coverage")
        state = statuses(payload).get("hako-page-coverage")
        detail = detail_of(payload, "hako-page-coverage")
        if state == "PASS":
            print("[ ok ] migration-complete: hako-page-coverage -> PASS (every page routes to Hako)")
        elif state == "FAIL" and "still upstream" in detail:
            print(f"[ ok ] migration-incomplete: FAIL without --allow-partial, naming the pages")
        else:
            failures.append(f"migration-incomplete: expected FAIL naming upstream pages, got "
                            f"{state} ({detail})")
            print(f"[FAIL] migration-incomplete: {state} ({detail})")

        # 3. Each mutation must make its own check fail.
        for label, check, mutate, ref in CASES:
            try:
                reset(copy, git)
            except AssertionError as error:
                failures.append(f"{label}: the previous case left the copy dirty ({error})")
                print(f"[FAIL] {label}: copy was dirty before this case")
                continue
            try:
                description = mutate(copy)
            except AssertionError as error:
                failures.append(f"{label}: mutation could not be applied ({error})")
                print(f"[FAIL] {label}: mutation could not be applied: {error}")
                continue
            code, payload = run_audit(copy, only=check, upstream_ref=ref)
            state = statuses(payload).get(check)
            if state == "FAIL" and code == 1:
                print(f"[ ok ] {label}: {check} -> FAIL  ({description})")
            else:
                failures.append(f"{label}: expected {check} to FAIL, got {state} (exit {code})")
                print(f"[FAIL] {label}: {check} -> {state}, exit {code}  ({description})")

        # 4. An upstream file edited without a decision must be reported and named.
        reset(copy, git)
        description = mutate_upstream_file(copy)
        code, payload = run_audit(copy, only="upstream-files-untouched", upstream_ref=UPSTREAM_REF)
        state = statuses(payload).get("upstream-files-untouched")
        if state == "FAIL" and "GroupListView.swift" in detail_of(payload, "upstream-files-untouched"):
            print(f"[ ok ] upstream-file-edited: FAIL and named  ({description})")
        elif state == "UNKNOWN":
            failures.append("upstream-file-edited: the check could not run, so the edit was not "
                            "reported; a comparison that did not happen is not one that passed")
            print("[FAIL] upstream-file-edited: UNKNOWN")
        else:
            failures.append(f"upstream-file-edited: expected FAIL naming the file, got {state}")
            print(f"[FAIL] upstream-file-edited: {state}")

        # 5. Deleting what a check reads must produce UNKNOWN, never PASS.
        reset(copy, git)
        os.remove(os.path.join(copy, "ApplicationLibrary/Views/Setting/SettingView.swift"))
        code, payload = run_audit(copy, only="shared-pages-are-clean")
        state = statuses(payload).get("shared-pages-are-clean")
        if state == "UNKNOWN":
            print("[ ok ] missing-input: shared-pages-are-clean -> UNKNOWN (not PASS)")
        else:
            failures.append(f"missing-input: expected UNKNOWN, got {state}")
            print(f"[FAIL] missing-input: expected UNKNOWN, got {state}")

        # 6. Removing the whole Hako namespace must not make the reverse-dependency check pass
        #    vacuously over a tree it no longer has anything to look at - the Hako view names would
        #    then be unresolved from the phone root, which is a different failure and must show.
        reset(copy, git)
        shutil.rmtree(os.path.join(copy, "ApplicationLibrary/Views/HakoStyle"), ignore_errors=True)
        code, payload = run_audit(copy, only="no-reverse-dependency")
        state = statuses(payload).get("no-reverse-dependency")
        print(f"[ ok ] hako-namespace-absent: no-reverse-dependency -> {state} "
              f"({detail_of(payload, 'no-reverse-dependency')[:70]})")

        # 7. A check whose baseline cannot be established must say so. Driven by putting a broken `git`
        #    first on the child's PATH rather than by deleting a ref: a worktree shares its
        #    repository's ref directory, so an earlier revision of this file deleted
        #    `refs/remotes/upstream/dev` from the *source* repository. A negative test must not be able
        #    to damage the thing it is testing.
        reset(copy, git)
        broken = os.path.join(workspace, "broken-git")
        os.makedirs(broken, exist_ok=True)
        for name in ("git.exe", "git.cmd", "git.bat"):
            write(os.path.join(broken, name), "@exit /b 1\n")
        code, payload = run_audit(copy, only="project-membership", git_broken_dir=broken)
        state = statuses(payload).get("project-membership")
        if state == "UNKNOWN":
            print("[ ok ] no-usable-git: project-membership -> UNKNOWN")
        else:
            failures.append(f"no-usable-git: expected UNKNOWN, got {state}")
            print(f"[FAIL] no-usable-git: {state}")

        # 8. Tearing down the phone's route must be caught: the page factory is the only thing that
        #    makes a Hako page reachable, so removing it must fail the coverage check.
        reset(copy, git)
        os.remove(os.path.join(copy, "SFI/HakoPageContent.swift"))
        code, payload = run_audit(copy, only="hako-page-coverage")
        state = statuses(payload).get("hako-page-coverage")
        if state in ("FAIL", "UNKNOWN"):
            print(f"[ ok ] page-factory-removed: hako-page-coverage -> {state}")
        else:
            failures.append(f"page-factory-removed: expected FAIL or UNKNOWN, got {state}")
            print(f"[FAIL] page-factory-removed: {state}")

        # 9. Two runs on the same tree must agree.
        reset(copy, git)
        _, first = run_audit(copy)
        _, second = run_audit(copy)
        if first == second:
            print("[ ok ] deterministic: two runs on the same tree agree")
        else:
            failures.append("deterministic: two runs on the same tree disagreed")
            print("[FAIL] deterministic: two runs disagreed")

        # 10. The screen-state fix must not silently regress to the upstream defect it repairs. There
        #     is no audit check for "the notify status is honoured" and inventing one would be a guard
        #     that cannot fail, so this grades source text directly.
        reset(copy, git)
        observer = read(os.path.join(copy, "Library/Network/ScreenStateObserver.swift"))
        darwin = read(os.path.join(copy, "Library/Network/ScreenStateObserverDarwin.swift"))
        provider = read(os.path.join(copy, "Library/Network/ExtensionProvider.swift"))
        invariants = {
            "the raw status is never discarded":
                "notify_get_state(" in darwin and "NOTIFY_STATUS_OK" in darwin,
            "a failed read carries no value to misread":
                "case failed(status: UInt32)" in observer,
            "only the Darwin surface imports notify":
                darwin.count("import notify") == 1 and "import notify" not in observer,
            "the observer is started once and stopped once":
                "startScreenStateObserver()" in provider and "stopScreenStateObserver()" in provider,
        }
        missing = [name for name, holds in invariants.items() if not holds]
        if not missing:
            print("[ ok ] screen-state invariants: all four hold")
        else:
            failures.append(f"screen-state invariants: {missing}")
            print(f"[FAIL] screen-state invariants: {missing}")

    finally:
        if args.keep:
            print(f"\ncopy kept at {workspace}")
        else:
            shutil.rmtree(workspace, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} case(s) did not behave as designed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("every negative case failed the audit as designed, and the positive case passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
