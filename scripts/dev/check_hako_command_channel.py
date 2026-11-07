#!/usr/bin/env python3
"""A command client may not be optional-chained: a nil client must be reportable, not skipped.

`LibboxNewStandaloneCommandClient()` returns an **Optional**. `try? LibboxNewStandaloneCommandClient()?.trigger…()`
therefore has three outcomes, and two of them look identical to the reader:

  * the client exists and the command is sent (fine);
  * the client exists and the command throws (reported, once `do/catch` is there);
  * the client is **nil** - and an optional chain over nil does not throw. It skips the call. No
    alert, no state change, nothing.

The third is the one this gate exists for. It reached the crash-report menu and the OOM report page
as "press the trigger, nothing happens": indistinguishable from a crash that ran and produced no
report. Both now `guard let` the client and report the nil answer with the key the Logs page already
uses for it ("Status Channel Unavailable"), which is also why the pattern is forbidden rather than
merely discouraged - the fix is one line and the failure mode is silent.

What the gate accepts instead:

    guard let client = LibboxNewStandaloneCommandClient() else { report(); return }
    try client.trigger…

    try CommandTarget.standaloneClient().…          # non-optional: throws in remote mode, traps locally

Usage:
    python check_hako_command_channel.py [--root DIR]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

#: The pattern. `\s*` because the chain may be wrapped.
OPTIONAL_CHAIN = re.compile(r"LibboxNewStandaloneCommandClient\(\)\s*\?")

#: The phone presentation files, plus the two phone-root files that talk to the client.
GLOBS = ("ApplicationLibrary/Views/HakoStyle", "SFI")


def is_comment(line: str) -> bool:
    """A `///` or `//` line is prose. A call site is not, and the fix's own explanation names the
    forbidden pattern, so a gate that read comments would fail on its own documentation."""
    stripped = line.strip()
    return stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*")


def swift_files(root: str) -> list[str]:
    found: list[str] = []
    for relative in GLOBS:
        base = os.path.join(root, relative)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            if name.endswith(".swift") and (relative != "SFI" or name.startswith("Hako")):
                found.append(os.path.join(base, name))
    return found


def find_optional_chains(root: str) -> list[tuple[str, int, str]]:
    problems: list[tuple[str, int, str]] = []
    for path in swift_files(root):
        relative = os.path.relpath(path, root).replace(os.sep, "/")
        with open(path, "r", encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                if is_comment(line):
                    continue
                if OPTIONAL_CHAIN.search(line):
                    problems.append((relative, number, line.strip()))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getcwd(), help="repository root")
    options = parser.parse_args()

    files = swift_files(options.root)
    if not files:
        # A gate that scanned nothing is not a green gate.
        print("FAIL: no Hako source file was found under %s - the scan covered nothing"
              % ", ".join(GLOBS))
        return 1

    problems = find_optional_chains(options.root)
    if problems:
        print("%d optional-chained command client(s); a nil client would skip the call silently:"
              % len(problems))
        for relative, number, line in problems:
            print("  %s:%d  %s" % (relative, number, line))
        print("\nUnwrap it first - `guard let client = LibboxNewStandaloneCommandClient() else { "
              "report(); return }` - so the nil answer reaches the reader instead of being skipped.")
        return 1

    print("PASS: %d phone file(s) checked; every command client is unwrapped before use, so a nil "
          "answer can be reported" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
