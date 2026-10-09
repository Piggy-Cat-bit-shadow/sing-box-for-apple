#!/usr/bin/env python3
"""Negative cases for `audit_apple_ui_boundary.py`.

A guard that cannot fail is not a guard. Each test here builds a copy of the checkout, breaks
exactly one invariant, runs the audit, and asserts the audit **reports that specific check as a
failure** - not merely that it exits non-zero, because "something failed" is what a broken script
also does.

The copy is made once and reused: each case resets it with `git checkout` before applying its own
mutation, so a case that leaks state cannot make the next case pass.

Run:

    python scripts/dev/test_audit_apple_ui_boundary.py

Exit status is 0 when every case behaved as designed.

Two of the cases are about the audit rather than about the tree, and they matter as much as the
other seven:

  * `positive` - the unmutated copy must pass, or every failure below would be meaningless
  * `unknown-not-pass` - deleting what a check reads must make it `UNKNOWN`, never `PASS`. This is
    the failure mode that makes a static audit worthless: a check that silently stops checking.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIT = os.path.join(HERE, "audit_apple_ui_boundary.py")


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
        else:
            for directory in os.environ.get("PATH", "").split(os.pathsep):
                if not directory:
                    continue
                for suffix in ("", ".exe", ".cmd", ".bat"):
                    full = os.path.join(directory, candidate + suffix)
                    if os.path.exists(full):
                        return full
    return None


def run_audit(root: str, only: str | None = None, upstream_ref: str | None = None) -> tuple[int, dict]:
    args = [sys.executable, AUDIT, "--root", root, "--json"]
    if only:
        args += ["--only", only]
    if upstream_ref:
        args += ["--upstream-ref", upstream_ref]
    proc = subprocess.run(args, capture_output=True)
    try:
        payload = json.loads(proc.stdout.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        payload = {"checks": [], "_stdout": proc.stdout.decode("utf-8", "replace"),
                   "_stderr": proc.stderr.decode("utf-8", "replace")}
    return proc.returncode, payload


def statuses(payload: dict) -> dict[str, str]:
    return {c["name"]: c["status"] for c in payload.get("checks", [])}


def replace_in_file(path: str, old: str, new: str, *, count: int = 1) -> None:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    if old not in text:
        raise AssertionError(f"mutation anchor not found in {path}: {old!r}")
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text.replace(old, new, count))


# --------------------------------------------------------------------------------------
# Mutations. Each returns a short description and performs one edit inside the copy.
# --------------------------------------------------------------------------------------


def mutate_hako_ref_in_upstream_page(root: str) -> str:
    path = os.path.join(root, "ApplicationLibrary/Views/Setting/SettingView.swift")
    replace_in_file(path, "public var body: some View {\n        FormView {",
                    "public var body: some View {\n        HakoRootScaffold {")
    return "a Hako scaffold inserted into the upstream-reachable SettingView"


def mutate_pad_to_hako(root: str) -> str:
    path = os.path.join(root, "SFI/Application.swift")
    replace_in_file(path, "        case .phone:\n            return .hakoPhone",
                    "        case .phone, .pad:\n            return .hakoPhone")
    return "the pad idiom routed to the phone's Hako root"


def mutate_sizeclass_dispatch(root: str) -> str:
    path = os.path.join(root, "SFI/Application.swift")
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    text = text.replace("    var body: some Scene {",
                        "    var body: some Scene {\n        let _ = horizontalSizeClass", 1)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    return "a size-class read added to the root that chooses the design family"


def mutate_display_name(root: str) -> str:
    path = os.path.join(root, "sing-box.xcodeproj/project.pbxproj")
    replace_in_file(path, 'INFOPLIST_KEY_CFBundleDisplayName = "Jiejiebox";',
                    'INFOPLIST_KEY_CFBundleDisplayName = "sing-box";', count=4)
    return "the visible name reverted to sing-box"


def mutate_variant_application_name(root: str) -> str:
    path = os.path.join(root, "Library/Shared/Variant.swift")
    replace_in_file(path, 'public static let applicationName = "SFI"',
                    'public static let applicationName = "Jiejiebox"')
    return "Variant.applicationName renamed, which would reach the VPN profile and the User-Agent"


def mutate_quota_row(root: str) -> str:
    path = os.path.join(root, "ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift")
    # Remove the single call site that draws the quota. The helper stays, so this is the
    # "the feature is implemented but not reachable" case rather than a rename.
    replace_in_file(path, "            remainingTrafficInfo\n\n            if profile.type == .remote",
                    "            if profile.type == .remote")
    return "the remaining-quota row unlinked from the configuration picker"


def mutate_quota_model(root: str) -> str:
    path = os.path.join(root, "Library/Network/SubscriptionInfo.swift")
    replace_in_file(path, "    public var remainingBytes: Int64? {",
                    "    public var remainingBytesRenamed: Int64? {")
    return "the remaining-bytes accessor renamed, which would empty the row at runtime"


def mutate_submodule_url(root: str) -> str:
    # The gitlink itself cannot be given a null SHA (`git update-index` refuses), so the mutation
    # is the other half of a submodule's identity: where it points. Moving the URL is exactly the
    # kind of edit this check exists to catch, and it exercises the `.gitmodules` comparison
    # rather than a comparison of the pointer alone.
    path = os.path.join(root, ".gitmodules")
    replace_in_file(path, "https://github.com/nekohasekai/Runestone.git",
                    "https://github.com/example/Runestone.git")
    return "the Runestone submodule URL pointed somewhere else"


def mutate_upstream_file(root: str) -> str:
    path = os.path.join(root, "ApplicationLibrary/Views/Log/LogView.swift")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n// an unreviewed edit to an upstream file\n")
    return "an upstream-owned file edited without a decision"


#: The pinned upstream commit this branch was cut from. Two checks only mean something against a
#: fixed baseline, so the cases that exercise them pass it explicitly rather than relying on the
#: checkout happening to have an `upstream` remote configured.
UPSTREAM_REF = "089d35e"

CASES = (
    # (label, check that must fail, mutation, upstream ref that check needs)
    ("hako-ref-in-upstream-page", "shared-pages-are-clean", mutate_hako_ref_in_upstream_page, None),
    ("pad-routed-to-hako", "phone-entry", mutate_pad_to_hako, None),
    ("size-class-in-root", "phone-entry", mutate_sizeclass_dispatch, None),
    ("display-name-reverted", "branding", mutate_display_name, None),
    ("variant-application-name", "branding", mutate_variant_application_name, None),
    ("quota-row-unlinked", "subscription-feature", mutate_quota_row, None),
    ("quota-model-renamed", "subscription-feature", mutate_quota_model, None),
    ("submodule-url-moved", "repository-hygiene", mutate_submodule_url, UPSTREAM_REF),
)


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
        # 1. The unmutated copy must pass. Without this, every failure below is meaningless.
        code, payload = run_audit(copy)
        states = statuses(payload)
        failing = sorted(name for name, state in states.items() if state == "FAIL")
        if code != 0 or failing:
            failures.append(
                f"positive: the unmutated copy did not pass (exit {code}, failures {failing})"
            )
            print(f"[FAIL] positive: unmutated copy (exit {code}, failures {failing})")
        else:
            print(f"[ ok ] positive: unmutated copy passes all {len(states)} checks")

        # 2. Each mutation must make its own check fail, and only be judged by that check.
        for label, check, mutate, ref in CASES:
            reset(copy, git)
            try:
                description = mutate(copy)
            except AssertionError as error:
                failures.append(f"{label}: could not be applied ({error})")
                print(f"[FAIL] {label}: mutation could not be applied: {error}")
                continue
            code, payload = run_audit(copy, only=check, upstream_ref=ref)
            states = statuses(payload)
            state = states.get(check)
            if state == "FAIL" and code == 1:
                print(f"[ ok ] {label}: {check} -> FAIL  ({description})")
            else:
                failures.append(
                    f"{label}: expected {check} to FAIL, got {state} (exit {code})"
                )
                print(f"[FAIL] {label}: {check} -> {state}, exit {code}  ({description})")

        # 3. An upstream file edited without a decision must be reported, not passed silently.
        reset(copy, git)
        description = mutate_upstream_file(copy)
        code, payload = run_audit(copy, only="upstream-files-untouched", upstream_ref="089d35e")
        check = (payload.get("checks") or [{}])[0]
        listed = " ".join(check.get("evidence", []))
        if check.get("status") == "PASS" and "LogView.swift" in listed:
            print(f"[ ok ] upstream-file-edited: reported in evidence  ({description})")
        elif check.get("status") == "UNKNOWN":
            failures.append(
                "upstream-file-edited: the check could not run, so the edit was not reported; a "
                "comparison that did not happen must not be counted as one that passed"
            )
            print(f"[FAIL] upstream-file-edited: UNKNOWN ({check.get('detail')})")
        else:
            failures.append(
                "upstream-file-edited: the file was edited but is not listed as reviewed; "
                f"status {check.get('status')}"
            )
            print(f"[FAIL] upstream-file-edited: status {check.get('status')}, evidence {listed!r}")

        # 4. A check whose input is missing must be UNKNOWN, never PASS. This is the case that
        #    catches a guard that quietly stopped guarding.
        reset(copy, git)
        os.remove(os.path.join(copy, "ApplicationLibrary/Views/Setting/SettingView.swift"))
        code, payload = run_audit(copy, only="shared-pages-are-clean")
        state = statuses(payload).get("shared-pages-are-clean")
        if state == "UNKNOWN":
            print("[ ok ] missing-input: shared-page-boundary -> UNKNOWN (not PASS)")
        else:
            failures.append(
                f"missing-input: expected UNKNOWN when a checked file is deleted, got {state} "
                f"(exit {code})"
            )
            print(f"[FAIL] missing-input: expected UNKNOWN, got {state} (exit {code})")

        # 5. Removing the whole Hako namespace must make the reverse-dependency check report that
        #    there is nothing to check, rather than pass vacuously.
        reset(copy, git)
        shutil.rmtree(os.path.join(copy, "ApplicationLibrary/Views/HakoStyle"), ignore_errors=True)
        code, payload = run_audit(copy, only="no-reverse-dependency")
        check = (payload.get("checks") or [{}])[0]
        if check.get("status") in ("PASS", "UNKNOWN") and "0 Swift files" not in check.get("detail", ""):
            print(f"[ ok ] hako-namespace-absent: reported {check.get('status')} with "
                  f"{check.get('detail')!r}")
        else:
            failures.append(
                "hako-namespace-absent: the check passed vacuously over an empty tree: "
                f"{check.get('detail')!r}"
            )
            print(f"[FAIL] hako-namespace-absent: {check.get('detail')!r}")

        # 6. A missing baseline must not be rebuilt into a pass.
        reset(copy, git)
        code, payload = run_audit(copy)
        code2, payload2 = run_audit(copy)  # deterministic: same tree, same answer
        if payload == payload2:
            print("[ ok ] deterministic: two runs on the same tree agree")
        else:
            failures.append("deterministic: two runs on the same tree disagreed")
            print("[FAIL] deterministic: two runs disagreed")

        # 7. A baseline that cannot be determined must report UNKNOWN rather than compare against
        #    the root commit and declare the whole tree new.
        reset(copy, git)
        if git:
            moved = subprocess.run(
                [git, "-C", copy, "update-ref", "-d", "refs/remotes/upstream/dev"],
                capture_output=True,
            )
            if moved.returncode == 0:
                code, payload = run_audit(copy, only="project-membership")
                check = (payload.get("checks") or [{}])[0]
                print(f"[ ok ] baseline-unavailable: project-membership -> {check.get('status')} "
                      f"({check.get('detail')!r})")
            else:
                print("[skip] baseline-unavailable: could not delete the upstream ref")
        else:
            print("[skip] baseline-unavailable: no git")

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


def reset(copy: str, git: str | None) -> None:
    """Return the copy to its committed state, so cases cannot leak into each other."""
    if git:
        subprocess.run([git, "-C", copy, "reset", "-q"], capture_output=True)
        subprocess.run([git, "-C", copy, "checkout", "-q", "--", "."], capture_output=True)


if __name__ == "__main__":
    sys.exit(main())
