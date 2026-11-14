#!/usr/bin/env python3
"""The debug-hitch fixes have to stay boundaries, not become settings someone turns back.

What this gate protects
-----------------------
Four properties hold the 2026-11-14 iOS Debug remediation together. Each one is a *structural*
property: the moment it is undone, the cost it removed comes back without any test failing, because
the cost was never an error.

  1. **The log window is not a published property of `CommandClient`.** Every view reading the client
     through `@EnvironmentObject` is invalidated when any of its `@Published` properties changes.
     The window publishes on a batch timer, so while it lived on the client it invalidated the
     dashboard's cards - two of them drawing a `Canvas` - up to ten times a second for log lines
     none of them display. It now lives on `LogStore`. The client's *level* properties are allowed
     to stay published: they change when a subscription opens or the reader picks a level.
  2. **Only the log path names `LogStore`.** If a card or a dashboard view starts observing the
     store, the boundary above has been moved rather than kept.
  3. **No hang-capture profile is unbounded, and the watchdog takes its numbers from the policy.**
     `Int.max` was the Debug cap, and a second copy of the constants is how the Debug branch drifted
     away from Release's in the first place.
  4. **The home page's mirrors, the start/stop clock and the report refresh are gated.** A mirror
     written on every publish, a one-second timer that runs for a value nothing draws, or a report
     scan started twice by two triggers that fire together are all silent - and all of them were,
     until this round.

What this gate cannot prove
---------------------------
Anything about behaviour. It reads text: it cannot know that a `guard` compares the right value, that
a timer is subscribed by a view that is on screen, or that a publish actually reaches a body. The
statements it makes are the ones a regular expression can honestly make. The retention rule, the
capture budget and the refresh gate have tests that execute them
(`Tests/HakoDiagnosticsCost`); this file is about the parts that are only wiring.

Usage:
    python scripts/dev/check_hako_diagnostics_boundaries.py [--root DIR]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

COMMAND_CLIENT = "Library/Network/CommandClient.swift"
LOG_STORE = "Library/Network/LogStore.swift"
WATCHDOG = "Library/Shared/HangWatchdog.swift"
CAPTURE_POLICY = "Library/Shared/HangCapturePolicy.swift"
ENVIRONMENTS = "Library/Network/ExtensionEnvironments.swift"
HOME = "ApplicationLibrary/Views/HakoStyle/HakoHomeView.swift"
START_STOP = "ApplicationLibrary/Views/HakoStyle/HakoStartStopButton.swift"
LOG_VIEW_MODEL = "ApplicationLibrary/Views/Log/LogViewModel.swift"

#: Files allowed to name `LogStore`. Everything else that names it is observing log state from a
#: place that does not display logs.
LOG_STORE_OBSERVERS = (COMMAND_CLIENT, LOG_STORE, LOG_VIEW_MODEL)

#: `@Published` declarations in the client for the log *window* and its loaded-backlog flag.
#:
#: The level properties (`defaultLogLevel`, `selectedLogLevel`) are deliberately not matched: they
#: change when a subscription opens or the reader picks a level, not once per batch, and the Logs
#: page reads them through the same pipeline it reads the window. The window is the one that moves
#: ten times a second.
PUBLISHED_LOG_STATE = re.compile(r"@Published[^\n]*\b(logBuffer|initialLogsReceived)\b")

#: The home page's mirrors: the two counts and the mode list.
MIRRORS = ("liveGroupCount", "liveConnectionCount", "modeList")


def read(root: str, relative: str, problems: list[str]) -> str:
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        problems.append("%s: missing; the boundary this gate describes cannot be checked" % relative)
        return ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def strip_comments(text: str) -> str:
    """Drop `//` lines and block comments so prose cannot satisfy a code check."""
    lines = []
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()
        if in_block:
            if "*/" in stripped:
                in_block = False
            continue
        if stripped.startswith("/*"):
            in_block = "*/" not in stripped
            continue
        if stripped.startswith("//"):
            continue
        lines.append(line)
    return "\n".join(lines)


def swift_files(root: str) -> list[str]:
    found: list[str] = []
    for tree in ("Library", "ApplicationLibrary", "MacLibrary", "SFI", "SFM", "SFT"):
        base = os.path.join(root, tree)
        for directory, subdirs, files in os.walk(base):
            subdirs[:] = [d for d in subdirs if d not in (".build", "build")]
            for name in files:
                if name.endswith(".swift"):
                    found.append(os.path.join(directory, name))
    return found


def on_receive_bodies(text: str) -> list[tuple[int, str]]:
    """Every `.onReceive(...) { ... }` body, with its starting line, by brace matching."""
    bodies: list[tuple[int, str]] = []
    for match in re.finditer(r"\.onReceive\(", text):
        opening = text.find("{", match.end())
        if opening < 0:
            continue
        depth = 0
        for index in range(opening, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    line = text.count("\n", 0, match.start()) + 1
                    bodies.append((line, text[opening : index + 1]))
                    break
    return bodies


def check(root: str) -> list[str]:
    problems: list[str] = []

    client = strip_comments(read(root, COMMAND_CLIENT, problems))
    policy = strip_comments(read(root, CAPTURE_POLICY, problems))
    watchdog = strip_comments(read(root, WATCHDOG, problems))
    environments = strip_comments(read(root, ENVIRONMENTS, problems))
    home = strip_comments(read(root, HOME, problems))
    start_stop = strip_comments(read(root, START_STOP, problems))

    # 1. The log window is not published by the client.
    for number, line in enumerate(client.splitlines(), 1):
        if PUBLISHED_LOG_STATE.search(line):
            problems.append(
                "%s:%d: `%s` publishes log state from the command client again - every "
                "`@EnvironmentObject` reader is invalidated by it, which is the cost this round "
                "removed" % (COMMAND_CLIENT, number, line.strip())
            )

    # 2. Only the log path observes the store.
    for path in swift_files(root):
        relative = os.path.relpath(path, root).replace(os.sep, "/")
        if relative in LOG_STORE_OBSERVERS:
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            body = strip_comments(handle.read())
        if re.search(r"\bLogStore\b", body):
            problems.append(
                "%s: names `LogStore` outside the log path; the store may only be observed by the "
                "page that renders logs" % relative
            )

    # 3. The capture budget is bounded and lives in one place.
    if re.search(r"\bInt\.max\b", policy):
        problems.append(
            "%s: contains `Int.max` - a profile without a report cap is the self-exciting loop, "
            "not a rate" % CAPTURE_POLICY
        )
    if re.search(r"\bInt\.max\b", watchdog):
        problems.append("%s: contains `Int.max`; the report cap belongs to `HangCapturePolicy`" % WATCHDOG)
    for name in ("reportThreshold", "reportCooldown", "maxReportsPerProcess"):
        if re.search(r"static\s+let\s+%s\s*[:=]" % name, watchdog):
            problems.append(
                "%s: declares `%s`; the numbers belong to `HangCapturePolicy`, and a second copy is "
                "how the Debug branch drifted" % (WATCHDOG, name)
            )
    if not re.search(r"HangCapturePolicy\.resolve\(", watchdog):
        problems.append(
            "%s: does not resolve its capture budget from `HangCapturePolicy`" % WATCHDOG
        )

    # 4a. The home page's mirrors are written only when they move.
    for line, body in on_receive_bodies(home):
        mirrors = [name for name in MIRRORS if re.search(r"\b%s\s*=" % name, body)]
        if not mirrors:
            continue
        if not re.search(r"guard\b[^\n]*!=", body):
            problems.append(
                "%s:%d: writes %s with no equality guard - a new value object carrying the same "
                "number invalidates the whole page" % (HOME, line, ", ".join(mirrors))
            )

    # 4b. The start/stop clock only exists while a time is drawn.
    if re.search(r"Timer\.publish\(", start_stop):
        problems.append(
            "%s: subscribes a timer again; the clock is `.task(id:)` so a page that draws no "
            "running time schedules nothing" % START_STOP
        )
    if not re.search(r"\.task\(id:\s*tracksTime\)", start_stop):
        problems.append("%s: the gated clock (`task(id: tracksTime)`) is gone" % START_STOP)

    # 4c. The report refresh is coalesced.
    if "reportRefreshGate.begin()" not in environments or "reportRefreshGate.end()" not in environments:
        problems.append(
            "%s: `postReload()` no longer coalesces the report scans; its two triggers fire "
            "together on the foreground path" % ENVIRONMENTS
        )
    if not re.search(r"func\s+postReload\(\)", environments):
        problems.append("%s: `postReload()` is gone" % ENVIRONMENTS)

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.getcwd(), help="repository root")
    options = parser.parse_args()

    problems = check(options.root)
    if problems:
        print("%d diagnostics-boundary problem(s):" % len(problems))
        for problem in problems:
            print("  - " + problem)
        return 1

    print("no problem found.")
    print("  the log window is on LogStore, and only the log path names it")
    print("  no capture profile is unbounded, and the watchdog's numbers come from the policy")
    print("  the home mirrors are guarded, the clock is gated, the report refresh is coalesced")
    print("NOTE: this is a structural check, not a behavioural one. See its docstring.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
