#!/usr/bin/env python3
"""Emit ORIGINAL_TYPE_NAMES - the module-scope type names the frozen original declares.

Used by `hako-type-has-caller` to tell a migrated page from a helper this fork wrote: a `HakoFoo` whose
original `Foo` exists is a migrated type, and if nothing constructs it then something else is being shown in
its place. `HakoEntryRow`, `HakoInlineNotice` and `HakoMetricText` have no original equivalent and are
helpers, where being unused is untidy rather than a lost design.

Generated from the pinned commit rather than hand-listed, and embeds the SHA so a reader can tell which
original it describes. Re-run with:

    python scripts/dev/gen_original_type_names.py
"""
from __future__ import annotations

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


def main() -> int:
    if not REPO:
        raise SystemExit("set DSH_REPO to the fork clone")
    listing = subprocess.run([GIT, "-C", REPO, "ls-tree", "-r", "--name-only", FORK_REF,
                              "ApplicationLibrary/Views"],
                             capture_output=True).stdout.decode("utf-8", "replace")
    paths = [p for p in listing.split("\n") if p.endswith(".swift")]

    names: set[str] = set()
    for path in paths:
        blob = subprocess.run([GIT, "-C", REPO, "show", f"{FORK_REF}:{path}"],
                              capture_output=True).stdout.decode("utf-8", "replace")
        blob = re.sub(r"/\*.*?\*/", "", blob, flags=re.S)
        blob = re.sub(r"//[^\n]*", "", blob)
        names.update(TYPE_DECL.findall(blob))

    body = "\n".join(f'    "{name}",' for name in sorted(names))
    io.open(OUT, "w", encoding="utf-8", newline="").write(
        '"""Module-scope type names declared by the frozen original. Generated - do not edit by hand.\n\n'
        f"Source: `{FORK_REF}` (`ApplicationLibrary/Views`), {len(names)} names, from {len(paths)} files.\n"
        f"Regenerate with `python scripts/dev/gen_original_type_names.py`.\n"
        '"""\n\n'
        "ORIGINAL_TYPE_NAMES = frozenset({\n" + body + "\n})\n"
    )
    print(f"  wrote {OUT}: {len(names)} names from {len(paths)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
