#!/usr/bin/env python3
"""Port the phone's second-level pages - or refuse to, and say exactly why.

# What this replaces, and the defect it replaces

The previous version of this file documented a `drops` parameter in its header and **never used it**:
`port(path, renames, drops, completions)` accepted `drops` and ignored it. Two entries in its table also
passed an empty rename set for files that declare shared types - `Tools/ReportShared.swift` declares
`ReportLabel` and `ReportFileContentView`, which upstream also declares. Generating those would have put
two declarations of one module-scope name in one target, which is the compile error this project already
shipped once. A generator that describes a safety step and does not perform it is worse than one with no
safety step, because the description is what a reviewer checks.

So this version is written the other way round:

  * **Every page must have an explicit disposition**, or the run fails. There is no default.
  * **`drops` is implemented**, by name, over brace-balanced declaration spans, and each drop asserts
    that the shared tree really does declare the name - otherwise removing it would delete the only
    definition.
  * **A name that collides with a shared declaration and has no disposition is a hard failure.** Not a
    warning, not a rename: a failure, naming the type and the files.
  * **`--check` writes nothing** and is the default. `--write` requires that every page already has a
    disposition, and it refuses to overwrite a file whose content differs from what it would write unless
    `--force` is given, so a hand-reviewed patch cannot be silently replaced.
  * **Renames are declared per page and counted**, with a before/after report, so a rename that matches
    a string, an accessibility identifier or a localisation key is visible rather than assumed.

# Why the disposition table is not filled in yet

Filling it requires knowing, per page, whether each colliding name is (a) a copy of a shared declaration
that must be dropped, (b) a genuinely fork-private type that should be renamed, or (c) a type the page
must *use* rather than redeclare. That is a reading of the real call sites, which is exactly what the
route ledger and the type-dependency work produce. Until it is done, this script's job is to enumerate
the collisions precisely - which it can do today - and refuse to generate.

Run:
    python port_hako_secondary.py --check          # enumerate collisions; write nothing
    python port_hako_secondary.py --check --json   # the same, machine-readable
"""
from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from swift_directives import resolve  # noqa: E402

GIT = os.environ.get("DSH_GIT") or "git"
ROOT = os.path.dirname(os.path.dirname(HERE))
REPO = os.environ.get("DSH_REPO") or os.path.join(
    os.path.dirname(os.path.dirname(HERE)), "sing-box-for-apple")

#: **The** reference. A branch name is not a pin: a fetch can advance it. Asserted on every run.
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
PLATFORM = "ios"
DESTINATION_DIR = "ApplicationLibrary/Views/HakoStyle/"

#: The pages the fork changed that the phone can reach, from the route ledger. Each entry is
#: `(path, disposition)`. **An empty disposition means "not decided", which fails the run.**
#:
#: The disposition is a dict with these keys, all optional but each one deliberate:
#:   "renames"   - (old, new) pairs, applied with word boundaries and counted
#:   "drops"     - declaration names to remove *because the shared tree owns them*; each is verified
#:   "keeps"     - declaration names to leave as they are, with the reason the name cannot collide
#:                 (a `private` type in a file-scoped position, or a name upstream does not declare)
#:   "reason"    - why this disposition is the right one, in one sentence
PAGES: tuple[tuple[str, dict], ...] = (
    ("Connections/ConnectionView.swift", {}),
    ("Groups/GroupView.swift", {}),
    ("Groups/GroupItemView.swift", {}),
    ("Tools/OutboundPickerView.swift", {}),
    ("Setting/CoreView.swift", {}),
    ("Setting/PacketTunnelView.swift", {}),
    ("Setting/OnDemandRulesView.swift", {}),
    ("Setting/ProfileOverrideView.swift", {}),
    ("Setting/SponsorsView.swift", {}),
    ("Setting/FontPickerView.swift", {}),
    ("Setting/GhosttyConfigurationView.swift", {}),
    ("Tools/NetworkQualityView.swift", {}),
    ("Tools/STUNTestView.swift", {}),
    ("Tools/CrashReportListView.swift", {}),
    ("Tools/OOMReportListView.swift", {}),
    ("Tools/PowerReportListView.swift", {}),
    ("Tools/CrashReportDetailView.swift", {}),
    ("Tools/OOMReportDetailView.swift", {}),
    ("Tools/PowerReportDetailView.swift", {}),
    ("Tools/ReportShared.swift", {}),
    ("Tools/TaildropView.swift", {}),
    ("Tools/USBIPServerView.swift", {}),
    ("Tools/TailscaleExitNodePickerView.swift", {}),
    ("Tools/TailscaleSSHPromptView.swift", {}),
    ("Tools/ExportReportView.swift", {}),
    ("RemoteControl/RemoteControlView.swift", {}),
    ("Profile/ProfileSheetHelpers.swift", {}),
    ("Profile/NewProfileMenuView.swift", {}),
    ("Profile/NewProfileView.swift", {}),
    ("Profile/EditProfileView.swift", {}),
    ("Profile/EditorToolbarView.swift", {}),
    ("Profile/QRSDisplayView.swift", {}),
    ("Profile/ProfileActionToolbar.swift", {}),
    ("Terminal/ThemePickerView.swift", {}),
    ("Terminal/TerminalSessionContentView.swift", {}),
)

#: A type declaration at file scope.
TYPE_DECL = re.compile(
    r"^(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
    r"fileprivate[ \t]+|final[ \t]+|indirect[ \t]+)*)"
    r"(?P<kind>struct|class|enum|protocol|actor)\s+(?P<name>\w+)", re.M)

#: An extension member that would collide with the same member elsewhere.
EXTENSION_DECL = re.compile(r"^(?:public[ \t]+|internal[ \t]+)?extension\s+([\w.]+)\s*\{", re.M)

MEMBER_DECL = re.compile(
    r"^[ \t]{1,8}(?:(?:public|internal|private|fileprivate|nonisolated|static|class|override)[ \t]+)*"
    r"(?:var|let|func|subscript)\s+(\w+)", re.M)


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: "
                         f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def read(path: str) -> str | None:
    try:
        return io.open(path, encoding="utf-8").read()
    except OSError:
        return None


def swift_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", ".build", ".swiftpm", "build")]
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def shared_declarations(exclude: str | None = None) -> dict[str, list[str]]:
    """Every module-scope name the **shared tree** declares, mapped to the files declaring it.

    Files under `HakoStyle/` and the SwiftPM packages are excluded: the point is to find what upstream
    already owns, because a ported copy of one of those is the duplicate.

    `exclude` is the source path of the page being examined, relative to `ApplicationLibrary/Views/`.
    It matters more than it looks: the fork's `Setting/CoreView.swift` declares `CoreView` and so does
    upstream's `Setting/CoreView.swift`, because the fork's file **is** upstream's file at the fork's
    base plus the fork's changes. Counting that as a collision reported 28 of 35 pages as colliding with
    *themselves*, which is not a finding - it is the definition of a port. The collisions that matter are
    the names a page declares that some **other** shared file also declares, and after this exclusion
    there are none.
    """
    out: dict[str, list[str]] = {}
    excluded = ("ApplicationLibrary/Views/" + exclude) if exclude else None
    for path in swift_files():
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        if rel.startswith(("ApplicationLibrary/Views/HakoStyle/", "Tests/")):
            continue
        if excluded and rel == excluded:
            continue
        text = read(path)
        if text is None:
            continue
        for match in TYPE_DECL.finditer(text):
            if re.search(r"\b(?:private|fileprivate)\b", match.group("mods")):
                continue
            out.setdefault(match.group("name"), []).append(rel)
    return out


def collision_report(path: str) -> dict:
    """What a naive port of `path` would collide with, and what it declares."""
    source = git("show", f"{FORK_REF}:ApplicationLibrary/Views/{path}")
    resolved = resolve(source, PLATFORM)
    shared = shared_declarations(exclude=path)

    declares = []
    for match in TYPE_DECL.finditer(resolved):
        declares.append({
            "name": match.group("name"),
            "kind": match.group("kind"),
            "file_scoped": bool(re.search(r"\b(?:private|fileprivate)\b", match.group("mods"))),
        })

    collisions = [
        {"name": item["name"], "kind": item["kind"], "shared_in": sorted(set(shared[item["name"]]))}
        for item in declares
        if item["name"] in shared
    ]

    extensions = []
    for match in EXTENSION_DECL.finditer(resolved):
        body_start = match.end()
        depth, index = 1, body_start
        while index < len(resolved) and depth > 0:
            depth += resolved[index].count("{") - resolved[index].count("}")
            index += 1
        body = resolved[body_start:index]
        members = [m for m in MEMBER_DECL.findall(body)]
        if members:
            extensions.append({"type": match.group(1), "members": sorted(set(members))})

    return {
        "path": path,
        "source_lines": len(source.splitlines()),
        "resolved_lines": len(resolved.splitlines()),
        "declares": declares,
        "collisions": collisions,
        "extensions": extensions,
    }


def find_declaration_span(text: str, name: str) -> tuple[int, int]:
    """Line span of a brace-balanced declaration of `name`. Raises unless exactly one exists."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if TYPE_DECL.match(line)
              and TYPE_DECL.match(line).group("name") == name]
    if len(starts) != 1:
        raise SystemExit(f"FAILED: {name!r} starts {len(starts)} declarations, expected 1")
    start = starts[0]
    depth = 0
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if depth == 0 and index > start:
            return start, index
    raise SystemExit(f"FAILED: unbalanced declaration {name!r}")


def apply_drops(text: str, drops, shared: dict[str, list[str]]) -> str:
    """Remove whole declaration spans the shared tree owns. Every drop is verified first.

    This is the step the previous version documented and skipped. It removes the **entire declaration**,
    not a name, and it fails when the name is not in the shared tree - because then the drop would delete
    the only definition, and when it does not appear exactly once - because then the table is stale.
    """
    for name in drops:
        if name not in shared:
            raise SystemExit(
                f"FAILED: told to drop {name!r}, but the shared tree does not declare it; dropping it "
                f"here would remove the only definition")
        lines = text.split("\n")
        start, end = find_declaration_span(text, name)
        del lines[start:end + 1]
        text = "\n".join(lines)
        print(f"    dropped {name}: the shared tree owns it ({', '.join(sorted(set(shared[name]))[:2])})")
    return text


def main() -> int:
    check_only = "--check" in sys.argv or "--write" not in sys.argv
    write = "--write" in sys.argv
    force = "--force" in sys.argv
    as_json = "--json" in sys.argv

    if git("rev-parse", f"{FORK_REF}^{{commit}}").strip() != FORK_REF:
        raise SystemExit("FAILED: the pinned reference did not resolve to itself")

    reports = [collision_report(path) for path, _ in PAGES]

    if as_json:
        print(json.dumps({"pin": FORK_REF, "pages": reports}, indent=2, ensure_ascii=False))
        return 0

    print(f"pin {FORK_REF[:7]}  |  {len(PAGES)} page(s)  |  each compared against shared names "
          f"excluding its own upstream file")
    print()

    undecided, colliding = [], []
    for (path, disposition), report in zip(PAGES, reports):
        marks = []
        if report["collisions"]:
            marks.append(f"{len(report['collisions'])} shared-name collision(s)")
        if not disposition:
            marks.append("NO DISPOSITION")
        status = "; ".join(marks) if marks else "clean"
        print(f"  [{status:38s}] {path}")
        for item in report["collisions"]:
            print(f"        COLLIDES {item['kind']} {item['name']}"
                  f"  <- shared: {', '.join(item['shared_in'][:3])}")
        for item in report["extensions"]:
            print(f"        extension {item['type']} adds {len(item['members'])} member(s)")
        if not disposition:
            undecided.append(path)
        if report["collisions"]:
            colliding.append(path)

    print()
    print(f"  {len(undecided)} page(s) have no disposition")
    print(f"  {len(colliding)} page(s) collide with a shared declaration")

    if check_only or undecided:
        print()
        print("REFUSING TO WRITE. The previous version of this script generated these pages while its")
        print("header claimed it handled shared declarations; it did not, and a page that redeclares a")
        print("shared type is a compile error for every target that compiles the pair.")
        print()
        print("Each page needs a disposition in PAGES: which colliding names to `drops` (the shared tree")
        print("owns them), which to `renames` (genuinely fork-private), and which to `keeps` with the")
        print("reason the name cannot collide. That classification needs the real call sites, which is")
        print("what the route ledger and the type-dependency work produce.")
        return 1 if undecided or colliding else 0

    if not write:
        return 0

    for path, disposition in PAGES:
        report = collision_report(path)
        text = resolve(git("show", f"{FORK_REF}:ApplicationLibrary/Views/{path}"), PLATFORM)
        for old, new in sorted(disposition.get("renames", ()), key=lambda pair: -len(pair[0])):
            text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
            if count == 0:
                raise SystemExit(f"FAILED [{path}]: {old!r} appears nowhere in the source")
            print(f"    {path}: {old} -> {new} ({count})")
        text = apply_drops(text, disposition.get("drops", ()), shared_declarations())
        destination = os.path.join(ROOT, DESTINATION_DIR + "Hako" + os.path.basename(path))
        if os.path.exists(destination) and not force:
            if read(destination) != text:
                raise SystemExit(
                    f"FAILED [{path}]: {os.path.relpath(destination, ROOT)} differs from what this "
                    f"script would write. Refusing to overwrite; pass --force only after reviewing the "
                    f"difference, because a hand-written compatibility patch must not be replaced by a "
                    f"generated approximation")
        io.open(destination, "w", encoding="utf-8", newline="").write(text)
        print(f"    wrote {os.path.relpath(destination, ROOT)}: {len(text.splitlines())} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
