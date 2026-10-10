#!/usr/bin/env python3
"""Negative cases for the `port_*.py` overwrite authorization. A guard that cannot fail is not a guard.

# The hole these cases exist to close

Three generators - `port_tools_and_more.py`, `port_hako_pages.py`, `port_hako_components.py` - each read

    if os.path.exists(destination) and not regenerate:
        ... report a difference and exit 1 ...
    io.open(destination, "w", ...).write(text)

so `--regenerate` did not merely permit an overwrite, it **skipped the comparison that would have reported
one**. Measured: `port_tools_and_more.py --regenerate` rewrites `HakoLogView.swift`, `HakoToolsView.swift`
and `HakoSettingView.swift` to their upstream shape - every `#if !os(tvOS)` guard gone, unguarded
`import UIKit` back, and `HakoCoreView()` / `HakoAppView()` / `HakoRemoteControlView()` /
`HakoPacketTunnelView()` / `HakoProfileOverrideView()` / `HakoOnDemandRulesView()` spelled the upstream way
again on the phone's More page. That is the reverse-dependency regression the boundary audit exists to
prevent, written with exit status 0. `audit_apple_ui_boundary.py --strict` goes FAIL on four checks, and
`audit_hako_lossless_parity.py` stays green on those same bytes, because deleting a guard does not change
the set of UI tokens.

The candidate a generator computes is a fresh function of the pinned upstream text; the file on disk is the
product of the last run **plus every human repair since**. A generator cannot see the difference, so it may
not decide it. The rule is `migrate_secondary_page.py`'s: an existing target is compared, never assumed
replaceable, and replacing one names the exact blob it discards.

# What each case asserts

Every case works in a disposable copy - the source checkout is never written to, and the suite proves it at
the end by re-hashing what it copied. The cases are:

  * `unauthorized-regenerate-refuses` - a differing target plus `--regenerate` and no authorization is
    exit 1, every target is named, and **not one byte moved**.
  * `authorization-covers-one-blob` - a wrong `--expect-sha256` is exit 1 and writes nothing, so an
    authorization is a fact about the blob rather than a permission to write.
  * `authorization-writes-when-it-matches` - the same run with the blob that is actually on disk exits 0
    and does write. Without this the guard would be indistinguishable from a broken generator, and every
    case above would pass.
  * `plain-and-check-never-write` - the non-writing invocations still do not write, whatever they report.

Run:  python scripts/dev/test_port_script_authorization.py [--scratch DIR]

Exit status is 0 when every case behaved as designed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PYTHON = sys.executable

#: The three generators that overwrite a target, and the page each one would rewrite first. The label is
#: what the generator prints for that target; `None` means the current tree's candidate already matches the
#: file on disk, so the case has to create the divergence itself.
SCRIPTS = (
    ("port_tools_and_more.py", "ApplicationLibrary/Views/HakoStyle/HakoToolsView.swift"),
    ("port_hako_pages.py", "ApplicationLibrary/Views/HakoStyle/HakoConnectionListView.swift"),
    ("port_hako_components.py", "ApplicationLibrary/Views/HakoStyle/HakoStartStopButton.swift"),
)

#: Directories a generator reads or writes. Copied whole, because a generator resolves names against the
#: **entire shared tree**, not just the pages it writes: `port_tools_and_more.py` has to find
#: `SettingsPage` and `Notification.Name.navigateToSettingsPage` in `shared_tree_names()`, and copying only
#: `HakoStyle/` makes it fail with `FAILED [More]: 'SettingsPage' is not declared in the shared tree`. That
#: is the generator correctly refusing to remove the only definition of a name, so a harness that copies
#: less than this does not test the guard - it tests a broken copy.
COPIED = ("scripts", "ApplicationLibrary", "SFI")

HAKO = os.path.join("ApplicationLibrary", "Views", "HakoStyle")

#: Two copies, because one case deliberately rewrites its targets. `readonly` is never written to and
#: carries the three refusal cases; `writable` is thrown away after the authorized-write case, so a case can
#: never inherit another case's mutation.
READONLY = "copy-readonly"
WRITABLE = "copy-writable"


def sha256_file(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def hashes(directory: str) -> dict[str, str]:
    return {name: sha256_file(os.path.join(directory, name))
            for name in sorted(os.listdir(directory)) if name.endswith(".swift")}


def run(scratch: str, script: str, *arguments: str) -> tuple[int, str, str]:
    result = subprocess.run([PYTHON, os.path.join("scripts", "dev", script), *arguments],
                            cwd=scratch, capture_output=True)
    return (result.returncode,
            result.stdout.decode("utf-8", "replace"),
            result.stderr.decode("utf-8", "replace"))


def make_copy(scratch: str) -> str:
    """A disposable copy of the generator, the whole shared tree and the phone's own files.

    No git is copied: the generators read the pinned upstream blobs through `git -C $DSH_REPO show`, so the
    copy needs the scripts and the tree they resolve names against, and nothing else.
    """
    if os.path.isdir(scratch):
        shutil.rmtree(scratch)
    for relative in COPIED:
        source = os.path.join(ROOT, relative)
        if not os.path.isdir(source):
            continue
        shutil.copytree(source, os.path.join(scratch, relative),
                        ignore=shutil.ignore_patterns("__pycache__"))
    return scratch


def authorize_arguments(script: str, relative: str, blob: str) -> list[str]:
    return [f"--replace={relative}", f"--expect-sha256={blob}"]


def suggested_arguments(stderr: str, script: str) -> list[str] | None:
    """The argument list from the command the refusal printed, or `None` if it printed none.

    The test drives the generator's *own* suggestion rather than assembling authorizations itself. A guard
    whose printed escape hatch does not work is a guard that will be worked around, so the suggestion is
    part of the contract and is checked as one. The `--replace=`/`--expect-sha256=` spelling is what
    `authorization_commands` prints, and this parses exactly that.
    """
    marker = f"python scripts/dev/{script} --regenerate "
    for line in stderr.splitlines():
        stripped = line.strip()
        if stripped.startswith(marker):
            arguments = stripped[len(marker):].split()
            if arguments and all(a.startswith(("--replace=", "--expect-sha256=")) for a in arguments):
                return arguments
    return None


def case_unauthorized_regenerate_refuses(scratch: str) -> tuple[bool, list[str]]:
    """A differing target plus `--regenerate` and no authorization: exit 1, named, nothing written."""
    notes: list[str] = []
    ok = True
    before = hashes(os.path.join(scratch, HAKO))
    refused = 0
    for script, _relative in SCRIPTS:
        code, out, err = run(scratch, script, "--regenerate")
        wrote = [line for line in out.splitlines() if "wrote" in line]
        if wrote:
            ok = False
            notes.append(f"{script} --regenerate WROTE with no authorization: {wrote[:2]}")
            continue
        if code == 0:
            # Honest only when there was genuinely nothing to overwrite, and said plainly so that a
            # generator which silently stopped finding its targets cannot hide behind this branch.
            notes.append(f"{script} --regenerate -> exit 0 with nothing written (every candidate already "
                         f"matched the file on disk)")
            continue
        if code != 1:
            ok = False
            notes.append(f"{script} --regenerate exited {code}, expected 0-as-a-no-op or a refusal of 1")
            continue
        refused += 1
        named = [line for line in err.splitlines() if "TARGET_DIFFERS" in line]
        if not named:
            ok = False
            notes.append(f"{script} refused without naming which target differs")
        elif suggested_arguments(err, script) is None:
            ok = False
            notes.append(f"{script} refused without printing a usable authorization command")
        else:
            notes.append(f"{script} --regenerate -> exit 1, named {len(named)} differing target(s) and "
                         f"printed an authorization command")
    after = hashes(os.path.join(scratch, HAKO))
    if before != after:
        moved = [name for name in before if before[name] != after.get(name)]
        ok = False
        notes.append(f"a refused run still moved {len(moved)} file(s): {', '.join(moved[:4])}")
    else:
        notes.append(f"all {len(before)} HakoStyle file(s) byte-identical after every refused run")
    if refused == 0:
        ok = False
        notes.append("no generator had a differing target, so this case did not exercise the refusal")
    return ok, notes


def case_authorization_covers_one_blob(scratch: str) -> tuple[bool, list[str]]:
    """An `--expect-sha256` that names no blob on disk is a refusal, not a permission."""
    notes: list[str] = []
    ok = True
    before = hashes(os.path.join(scratch, HAKO))
    wrong = "0" * 64
    exercised = 0
    for script, relative in SCRIPTS:
        code, out, err = run(scratch, script, "--regenerate",
                             *authorize_arguments(script, relative, wrong))
        wrote = [line for line in out.splitlines() if "wrote" in line]
        if wrote:
            ok = False
            notes.append(f"{script} wrote while holding only an authorization for {wrong[:8]}…: "
                         f"{wrote[:2]}")
            continue
        if code == 0:
            notes.append(f"{script}: nothing differed, so the wrong blob was never consulted")
            continue
        exercised += 1
        if "REPLACE_UNAUTHORIZED" not in err:
            ok = False
            notes.append(f"{script} refused for a reason other than the mismatched blob: "
                         f"{err.strip().splitlines()[:1]}")
        else:
            notes.append(f"{script} -> exit {code}, refused an authorization that does not match the blob")
    after = hashes(os.path.join(scratch, HAKO))
    if before != after:
        ok = False
        notes.append("a wrong-blob authorization still moved a file")
    else:
        notes.append("no file moved under a mismatched authorization")
    if exercised == 0:
        ok = False
        notes.append("no generator had a differing target, so this case did not exercise the check")
    return ok, notes


def case_authorization_writes_when_it_matches(scratch: str) -> tuple[bool, list[str]]:
    """The printed command has to *work*. A guard whose escape hatch is broken gets worked around.

    This is the case that keeps the refusal cases from being satisfied by a generator that is simply dead:
    it takes the argument list the refusal itself suggested - the whole set, one pair per target - runs it,
    and requires that every target the run named is actually replaced and the exit status is 0.
    """
    notes: list[str] = []
    ok = True
    exercised = 0
    for script, relative in SCRIPTS:
        code, out, err = run(scratch, script, "--regenerate")
        if code == 0 and "wrote" not in out:
            notes.append(f"{script}: nothing differed, so its authorization path was not exercised")
            continue
        if code != 1:
            ok = False
            notes.append(f"{script} exited {code} on the unauthorized run, so this case cannot proceed")
            continue
        arguments = suggested_arguments(err, script)
        if arguments is None:
            ok = False
            notes.append(f"{script} printed no usable authorization command")
            continue
        targets = {argument.split("=", 1)[1] for argument in arguments
                   if argument.startswith("--replace=")}
        path = os.path.join(scratch, HAKO, os.path.basename(relative))
        blob = sha256_file(path)
        code, out, err2 = run(scratch, script, "--regenerate", *arguments)
        wrote = [line for line in out.splitlines() if "wrote" in line]
        if code != 0:
            ok = False
            notes.append(f"{script} refused its own suggested command (exit {code}): "
                         f"{err2.strip().splitlines()[:1]}")
        elif not wrote:
            ok = False
            notes.append(f"{script} exited 0 on its own suggested command but wrote nothing")
        elif sha256_file(path) == blob:
            ok = False
            notes.append(f"{script} reported a write but {os.path.basename(relative)} did not change")
        else:
            exercised += 1
            notes.append(f"{script}: its own suggested command replaced {os.path.basename(relative)} and "
                         f"{len(wrote)} file(s) in total, exit 0")
        if relative.replace("/", os.sep) not in targets and os.path.basename(relative) not in {
                os.path.basename(t) for t in targets}:
            ok = False
            notes.append(f"{script}: the suggested command does not authorize its own first target")
    if exercised == 0:
        ok = False
        notes.append("no generator's suggested command was exercised, so this case proves nothing about "
                     "the escape hatch")
    else:
        notes.append(f"{exercised} generator(s) wrote through the command they printed themselves")
    return ok, notes


def case_authorization_is_not_a_licence_for_the_others(scratch: str) -> tuple[bool, list[str]]:
    """Authorizing target A must not authorize target B: one authorization covers one target.

    `port_tools_and_more.py` writes three pages, so this is where "one `--replace`" either means what it
    says or is decorative. It is given the blob of one target and nothing else; if the others were replaced
    anyway, the authorization is a blanket override wearing a per-target spelling.
    """
    notes: list[str] = []
    ok = True
    script, relative = SCRIPTS[0]
    before = hashes(os.path.join(scratch, HAKO))
    blob = sha256_file(os.path.join(scratch, HAKO, os.path.basename(relative)))
    code, out, err = run(scratch, script, "--regenerate",
                         *authorize_arguments(script, relative, blob))
    wrote = [line for line in out.splitlines() if "wrote" in line]
    if code == 0 and not wrote:
        notes.append(f"{script}: nothing differed at all, so this case could not be exercised")
        return ok, notes
    if code != 1:
        ok = False
        notes.append(f"{script} exited {code} while authorized for one target of several; a partial "
                     f"regeneration is exactly the state this guard exists to prevent")
    elif "REFUSED" not in err:
        ok = False
        notes.append(f"{script} exited 1 without a REFUSED reason")
    else:
        notes.append(f"{script} -> exit 1: an authorization for one target did not carry the others")
    after = hashes(os.path.join(scratch, HAKO))
    moved = [name for name in before if before[name] != after.get(name)]
    if moved:
        ok = False
        notes.append(f"a partially authorized run moved {len(moved)} file(s): {', '.join(moved[:4])}")
    else:
        notes.append("nothing was written, so the refusal was all-or-nothing rather than partial")
    return ok, notes


def case_plain_and_check_never_write(scratch: str) -> tuple[bool, list[str]]:
    """The reporting invocations stay reporting invocations."""
    notes: list[str] = []
    ok = True
    before = hashes(os.path.join(scratch, HAKO))
    for script, _relative in SCRIPTS:
        for arguments in ((), ("--check",)):
            code, _out, _err = run(scratch, script, *arguments)
            if code not in (0, 1):
                ok = False
                notes.append(f"{script} {' '.join(arguments)}: exit {code} is a crash, not a verdict")
    after = hashes(os.path.join(scratch, HAKO))
    if before != after:
        ok = False
        notes.append("a compare-or-check run wrote to the tree")
    else:
        notes.append("neither a bare run nor `--check` moved a byte, on any of the three generators")
    return ok, notes


CASES = (
    ("unauthorized-regenerate-refuses", case_unauthorized_regenerate_refuses, READONLY),
    ("authorization-covers-one-blob", case_authorization_covers_one_blob, READONLY),
    ("authorization-is-not-a-licence-for-the-others",
     case_authorization_is_not_a_licence_for_the_others, READONLY),
    ("authorization-writes-when-it-matches", case_authorization_writes_when_it_matches, WRITABLE),
    ("plain-and-check-never-write", case_plain_and_check_never_write, READONLY),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--scratch", default=os.environ.get(
        "DSH_PORT_SCRATCH", os.path.join(tempfile.gettempdir(), "hako-port-authorization")),
        help="disposable directory the cases run in; nothing outside it is written")
    parser.add_argument("--keep", action="store_true", help="leave the scratch directory in place")
    args = parser.parse_args()

    # The source checkout is read, never written. Hashing it here and again at the end is what makes that
    # a checkable statement: a case that leaked into the tree would otherwise look like a passing case.
    source_before = hashes(os.path.join(ROOT, HAKO))

    scratch = os.path.abspath(args.scratch)
    if os.path.isdir(scratch):
        shutil.rmtree(scratch)
    os.makedirs(scratch)

    print(f"  scratch: {scratch}")
    print(f"  generators copied from {ROOT}")
    print()

    failures = 0
    for name, function, copy_name in CASES:
        # Fresh copy per case. `authorization-writes-when-it-matches` deliberately rewrites its targets, so
        # it gets its own copy and the read-only cases can never inherit a mutation from each other.
        copy = make_copy(os.path.join(scratch, copy_name))
        ok, notes = function(copy)
        print(f"  [{'ok  ' if ok else 'FAIL'}] {name}")
        for note in notes:
            print(f"      {note}")
        failures += 0 if ok else 1

    source_after = hashes(os.path.join(ROOT, HAKO))
    if source_before != source_after:
        print("  [FAIL] source-checkout-untouched")
        moved = [name for name in source_before if source_before[name] != source_after.get(name)]
        print(f"      the suite moved {len(moved)} file(s) in the checkout it read from: {moved[:4]}")
        failures += 1
    else:
        print("  [ok  ] source-checkout-untouched")
        print(f"      all {len(source_before)} file(s) under {HAKO} are byte-identical to before the run")

    print()
    print(f"  {failures} failing case(s) of {len(CASES) + 1}")
    if not args.keep:
        shutil.rmtree(scratch, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
