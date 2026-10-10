#!/usr/bin/env python3
"""Report any commit subject in a range whose raw bytes begin with a UTF-8 BOM.

A BOM in a commit subject is invisible in most terminals but travels into `git log --oneline`, into
changelogs and into anything that greps the subject. PowerShell's `Set-Content -Encoding UTF8` writes one,
which is how it got in here; writing with an explicit BOM-less encoder is the fix on the writing side and
this is the check on the reading side.
"""
from __future__ import annotations

import os
import subprocess
import sys

GIT = os.environ.get("DSH_GIT") or r"C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe"
REPO = os.environ.get("DSH_REPO") or r"C:\Deepseek\IOS客户端\sing-box-for-apple"
REV = sys.argv[1] if len(sys.argv) > 1 else "e1cefe6..HEAD"

proc = subprocess.run([GIT, "-C", REPO, "log", "--format=%H%x00%s%x00%b", REV],
                      capture_output=True)
raw = proc.stdout
records = raw.split(b"\x00")
bad = []
# `%H%x00%s%x00%b` gives hash, subject, body, then a newline before the next record.
for index in range(0, len(records) - 2, 3):
    sha = records[index].strip().decode("utf-8", "replace")
    subject = records[index + 1]
    body = records[index + 2]
    if subject.startswith(b"\xef\xbb\xbf") or body.startswith(b"\xef\xbb\xbf"):
        bad.append((sha, subject.decode("utf-8", "replace")))

count = subprocess.run([GIT, "-C", REPO, "rev-list", "--count", REV],
                       capture_output=True).stdout.decode().strip()
print(f"commits in {REV}: {count}")
if bad:
    print(f"subjects beginning with a UTF-8 BOM: {len(bad)}")
    for sha, subject in bad:
        print(f"  {sha[:12]}  {subject!r}")
    sys.exit(1)
print("no subject begins with a UTF-8 BOM")
