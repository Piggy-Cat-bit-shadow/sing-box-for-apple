#!/usr/bin/env python3
"""Emit ORIGINAL_TYPE_NAMES - the module-scope type names the frozen original declares.

Used by `hako-type-has-caller` to tell a migrated page from a helper this fork wrote: a `HakoFoo` whose
original `Foo` exists is a migrated type, and if nothing constructs it then something else is being shown in
its place. `HakoEntryRow`, `HakoInlineNotice` and `HakoMetricText` have no original equivalent and are
helpers, where being unused is untidy rather than a lost design.

Generated from the pinned commit rather than hand-listed, and embeds the SHA so a reader can tell which
original it describes. Re-run with:

    python scripts/dev/gen_original_type_names.py

# Fail-closed, because a generator that fails quietly is worse than no generator

The previous revision ran `git` without checking its status, so a missing clone, a bad `DSH_REPO` or a
commit that was not fetched produced an empty name set, still wrote the file, and still printed success and
exited 0. Every consumer of `ORIGINAL_TYPE_NAMES` would then have been told that *no* type has an original -
a wrong answer delivered confidently, and the exact false-green shape this round is closing. So:

  * the ref is resolved first and must resolve to the pinned SHA, not merely to something;
  * every `git` call's exit status is checked;
  * the file count and the name count must be non-zero, and a name count that collapses to zero is refused;
  * the existing file is left untouched when anything fails, so a failed run cannot destroy the last good
    table;
  * the exit status is non-zero on refusal, and 0 only when the table was written.

Usage:  DSH_REPO=<fork clone> python scripts/dev/gen_original_type_names.py [--check]
        (--check compares instead of writing; non-zero when the file on disk is not what would be written)
"""
from __future__ import annotations

import argparse
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GIT = os.environ.get("DSH_GIT", "git")
REPO = os.environ.get("DSH_REPO", "")
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
OUT = os.path.join(ROOT, "scripts", "dev", "original_type_names.py")

TYPE_DECL = re.compile(
    r"^[ \t]*(?:(?:public|internal|private|fileprivate|final|indirect|@\w+(?:\([^)]*\))?)[ \t]+)*"
    r"(?:struct|class|enum|actor|protocol)\s+(\w+)", re.M)


class Refused(Exception):
    pass


def git(*arguments: str) -> str:
    result = subprocess.run([GIT, "-C", REPO, *arguments], capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise Refused(f"git {' '.join(arguments)} failed with status {result.returncode}: {detail}")
    return result.stdout.decode("utf-8", "replace")


def collect() -> tuple[set[str], int]:
    if not REPO:
        raise Refused("set DSH_REPO to the fork clone; without it there is nothing to generate from")
    if not os.path.isdir(REPO):
        raise Refused(f"DSH_REPO is not a directory: {REPO}")

    resolved = git("rev-parse", f"{FORK_REF}^{{commit}}").strip()
    if resolved != FORK_REF:
        raise Refused(f"{FORK_REF} resolves to {resolved!r}; refusing to generate from a different commit")

    listing = git("ls-tree", "-r", "--name-only", FORK_REF, "ApplicationLibrary/Views")
    paths = [path for path in listing.split("\n") if path.endswith(".swift")]
    if not paths:
        raise Refused("the pinned commit lists no Swift file under ApplicationLibrary/Views")

    names: set[str] = set()
    for path in paths:
        blob = git("show", f"{FORK_REF}:{path}")
        blob = re.sub(r"/\*.*?\*/", "", blob, flags=re.S)
        blob = re.sub(r"//[^\n]*", "", blob)
        names.update(TYPE_DECL.findall(blob))

    if not names:
        raise Refused(f"{len(paths)} file(s) were read and no type name was found in any of them; "
                      f"a generated table of nothing is not a result")
    return names, len(paths)


def render(names: set[str], file_count: int) -> str:
    body = "\n".join(f'    "{name}",' for name in sorted(names))
    return (
        '"""Module-scope type names declared by the frozen original. Generated - do not edit by hand.\n\n'
        f"Source: `{FORK_REF}` (`ApplicationLibrary/Views`), {len(names)} names, from {file_count} files.\n"
        f"Regenerate with `python scripts/dev/gen_original_type_names.py`.\n"
        '"""\n\n'
        "ORIGINAL_TYPE_NAMES = frozenset({\n" + body + "\n})\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="compare with the file on disk instead of writing; non-zero when they differ")
    args = parser.parse_args()

    try:
        names, file_count = collect()
    except Refused as error:
        print(f"  REFUSED: {error}")
        print("  the file on disk was not touched")
        return 1

    text = render(names, file_count)
    if args.check:
        if not os.path.exists(OUT):
            print(f"  {OUT} does not exist")
            return 1
        current = io.open(OUT, encoding="utf-8").read()
        if current != text:
            print(f"  {OUT} is not what the pinned commit generates; re-run without --check")
            return 1
        print(f"  {OUT} holds {len(names)} name(s) from {file_count} file(s), matching {FORK_REF}")
        return 0

    io.open(OUT, "w", encoding="utf-8", newline="").write(text)
    print(f"  wrote {OUT}: {len(names)} names from {file_count} files at {FORK_REF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
