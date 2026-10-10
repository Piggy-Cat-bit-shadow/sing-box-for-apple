#!/usr/bin/env python3
"""A check that cannot fail is worthless; a check that cannot *report* is worse.

The audits in this directory all answer a question about a tree. Each of them has a second, quieter
question underneath it: **did the check actually run?** An audit that skipped its comparison because it
could not find its reference, or because it could not decide a file, and then exited 0 has told its caller
the same thing a clean result tells it. That shape has shipped here twice:

  * `check_hako_macos_parse.py` printed `0 file(s) would not parse` and returned 0 while nine files were
    `[undecidable]` and had never been looked at;
  * `audit_hako_lossless_parity.py` printed `UNKNOWN: … the original cannot be compared` and returned **0**
    - so a run that compared nothing was indistinguishable, by exit code, from a lossless port.

Both are fixed. This file is what keeps them fixed. It runs the real commands, in a tree where the
reference genuinely cannot be found, and asserts the exit status and the payload agree with each other and
with the text: a fail-closed audit exits non-zero, on the text path and on `--json`, and the `--json`
payload carries the reason.

# Why the negative tree is built the way it is

`audit_hako_lossless_parity.py` searches for the pinned original in `DSH_REPO`, then in the tree the
scripts live in, then in that tree's worktrees. To make the reference genuinely unreachable the copy is
placed in a **fresh temporary directory with no git ancestry at all**, and the scripts are copied *with*
their sibling modules so the import of `swift_directives` still resolves. If that copy were placed inside
the repository - or in a directory whose parent happened to be a checkout - the search would succeed and
the negative case would silently become a positive one. The case asserts that it did not: the "cannot be
found" text has to appear, otherwise the case fails rather than passing vacuously.

Run:

    python scripts/dev/test_fail_closed_exit_codes.py

Exit status is 0 when every case behaved as designed.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

#: The pinned original-UI commit, mirrored from the audit. A negative case needs to know what the audit was
#: looking for so it can assert the audit named it.
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"


def default_root() -> str:
    return os.path.dirname(os.path.dirname(HERE))


def find_git() -> str | None:
    for candidate in (os.environ.get("DSH_GIT"), "git"):
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


def isolated_scripts_copy() -> str:
    """A copy of `scripts/dev` in a directory with no git ancestry anywhere above it."""
    base = tempfile.mkdtemp(prefix="jiejiebox-fail-closed-")
    destination = os.path.join(base, "scripts", "dev")
    os.makedirs(destination)
    for name in os.listdir(HERE):
        if name.endswith(".py"):
            shutil.copy2(os.path.join(HERE, name), os.path.join(destination, name))
    return destination


def run(script: str, root: str, *extra: str, dsh_repo: str | None = None) -> tuple[int, str]:
    env = dict(os.environ)
    # Make the reference deliberately unreachable: `DSH_REPO` is honoured first by the audit, and it is
    # pointed at a directory that is not a checkout. The child gets a copy of the environment, never the
    # parent's, so one case cannot change the conditions the next case runs under.
    if dsh_repo is not None:
        env["DSH_REPO"] = dsh_repo
    env.pop("DSH_FORK_REF", None)
    git = find_git()
    if git:
        env["DSH_GIT"] = git
    proc = subprocess.run([sys.executable, script, "--root", root, *extra],
                          capture_output=True, env=env)
    return proc.returncode, (proc.stdout + proc.stderr).decode("utf-8", "replace")


class Case:
    def __init__(self, name: str) -> None:
        self.name = name

    def check(self, ok: bool, detail: str) -> bool:
        print(f"[ {'ok ' if ok else 'FAIL'} ] {self.name}: {detail}")
        return ok


def case_lossless_missing_original(script: str, root: str, unreachable: str) -> bool:
    """`UNKNOWN` must be a non-zero result, on both output paths, and must say what it tried."""
    case = Case("lossless-missing-original")
    ok = True

    code, text = run(script, root, dsh_repo=unreachable)
    ok &= case.check("UNKNOWN" in text,
                     "the audit reports it cannot compare the original (text path)")
    ok &= case.check(code != 0,
                     f"the text path exits non-zero rather than 0 (exit {code})")
    ok &= case.check("tried " in text,
                     "it names the paths it looked in, so a missing reference is diagnosable")

    code_json, text_json = run(script, root, "--json", dsh_repo=unreachable)
    ok &= case.check(code_json != 0,
                     f"the --json path exits non-zero too (exit {code_json})")
    try:
        payload = json.loads(text_json)
    except ValueError as error:
        return case.check(False, f"--json did not emit JSON: {error}")
    ok &= case.check(payload.get("status") == "UNKNOWN",
                     "--json says status=UNKNOWN rather than reporting zero differences")
    ok &= case.check(payload.get("reference") == FORK_REF,
                     "the payload names the commit it could not read")
    ok &= case.check(bool(payload.get("tried")),
                     "--json lists what it tried")
    ok &= case.check(code == code_json,
                     f"the two output paths agree about the same tree ({code} vs {code_json})")
    return bool(ok)


def case_lossless_positive(script: str, root: str) -> bool:
    """The healthy tree must still pass, or the negative case above proves nothing."""
    case = Case("lossless-positive")
    env = dict(os.environ)
    git = find_git()
    if git:
        env["DSH_GIT"] = git
    proc = subprocess.run([sys.executable, script, "--root", root, "--json"],
                          capture_output=True, env=env)
    text = (proc.stdout + proc.stderr).decode("utf-8", "replace")
    try:
        payload = json.loads(text)
    except ValueError as error:
        return case.check(False, f"the audit did not emit JSON on the healthy tree: {error}")
    coverage = payload.get("coverage") or {}
    ok = True
    ok &= case.check(proc.returncode == 0,
                     f"the healthy tree passes (exit {proc.returncode})")
    ok &= case.check(coverage.get("pages_compared") == coverage.get("pages_expected") != 0,
                     f"every page was compared, not skipped "
                     f"({coverage.get('pages_compared')} of {coverage.get('pages_expected')})")
    ok &= case.check(payload.get("lost_tokens") == 0,
                     f"no UI token was lost (lost_tokens={payload.get('lost_tokens')})")
    design = payload.get("design_system") or {}
    ok &= case.check(design.get("checked") == design.get("expected") != 0,
                     f"the whole design system was compared byte for byte "
                     f"({design.get('checked')} of {design.get('expected')})")
    return bool(ok)


def main() -> int:
    root = default_root()
    scripts = isolated_scripts_copy()
    print(f"checkout:        {root}")
    print(f"isolated copy:   {scripts}")
    print()

    lossless = os.path.join(scripts, "audit_hako_lossless_parity.py")
    if not os.path.exists(lossless):
        print("FAIL: the copy is missing audit_hako_lossless_parity.py")
        return 1

    results = [
        case_lossless_missing_original(lossless, root, os.path.dirname(os.path.dirname(scripts))),
        case_lossless_positive(os.path.join(HERE, "audit_hako_lossless_parity.py"), root),
    ]

    print()
    failed = results.count(False)
    print(f"{len(results) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
