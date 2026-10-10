#!/usr/bin/env python3
"""Check that every generated header names a source path that exists at the pinned original.

`HakoStyle/Hako*.swift` files carry a header of the form

    //  The phone's copy of `<source path>`, from `hako-ui` @ `c1935cf`.

`retarget`'s pattern matches `Name.` as well as `Name(`, so running the generator over a page rewrote the
tool's own generated comment in other files - `Tools/CrashReportListView.swift` became
`Tools/HakoCrashReportListView.swift`, a path that does not exist at the pin. A generated file that lies
about its own provenance cannot be checked against its original later.
"""
from __future__ import annotations

import io
import os
import re
import subprocess
import sys

GIT = os.environ.get("DSH_GIT") or r"C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe"
REPO = os.environ.get("DSH_REPO") or r"C:\Deepseek\IOS客户端\sing-box-for-apple"
REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"

PATTERN = re.compile(r"copy of `([^`]+)`")


def main() -> int:
    directory = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")
    named, missing = [], []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        text = io.open(os.path.join(directory, name), encoding="utf-8").read()
        match = PATTERN.search(text)
        if not match:
            continue
        source = match.group(1)
        proc = subprocess.run([GIT, "-C", REPO, "cat-file", "-e", f"{REF}:{source}"],
                              capture_output=True)
        (named if proc.returncode == 0 else missing).append((name, source))

    print(f"portable headers: {len(named) + len(missing)}")
    print(f"  naming a path that exists at the pin : {len(named)}")
    print(f"  naming a path that does NOT exist     : {len(missing)}")
    for name, source in missing:
        print(f"    {name}  ->  {source}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
