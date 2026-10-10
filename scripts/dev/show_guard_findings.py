#!/usr/bin/env python3
"""Print one check's findings out of an audit `--json` payload, grouped by file.

Written because piping the audit's JSON through the shell mangles the non-ASCII paths and the embedded
quotes. The payload is read from a file instead.
"""
from __future__ import annotations

import collections
import io
import json
import sys

CHECK = "platform-guard-agreement"


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "audit.json"
    name = sys.argv[2] if len(sys.argv) > 2 else CHECK
    payload = json.load(io.open(path, encoding="utf-8"))
    for check in payload.get("checks", []):
        if check["name"] != name:
            continue
        print(f"status: {check['status']}")
        print(f"detail: {check['detail']}")
        print()
        evidence = check.get("evidence", [])
        print(f"{len(evidence)} finding(s):")
        by_file = collections.Counter()
        for item in evidence:
            print(f"  {item}")
            by_file[item.split(":")[0].split("/")[-1]] += 1
        print()
        print("by file:")
        for filename, count in by_file.most_common():
            print(f"  {count:3d}  {filename}")
        return 0
    print(f"no check named {name!r} in the payload")
    print("checks present: " + ", ".join(c["name"] for c in payload.get("checks", [])))
    return 1


if __name__ == "__main__":
    sys.exit(main())
