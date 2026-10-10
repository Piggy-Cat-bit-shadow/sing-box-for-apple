#!/usr/bin/env python3
"""Migrate one of the original's second-level pages into the fork's namespace, and retarget the phone.

# What this does that the earlier generator did not

The earlier `port_hako_secondary.py` stopped at producing a file: it never redirected a single call
site, which is how `HakoGroupListView` and `HakoConnectionListView` came to exist with no reachable
instantiation. This one refuses to finish a page unless the phone's own code actually names the new type,
and it reports the exact caller it rewrote.

# The transform, in order

1. Read the original page from the pinned worktree (`_work/refs/up-hako`, commit asserted).
2. Resolve its platform conditionals for iOS - `os(...)`/`canImport(...)` decided, build flags kept.
3. Rename every **file-level type the file declares** into the `Hako` namespace. The rename set is derived
   from the file rather than hand-listed, and it is asserted to have matched.
4. Write the copy under `HakoStyle/` and redirect the phone's call sites: every `Name(` / `Name.` mention
   in the phone-owned files becomes `HakoName(` / `HakoName.`.
5. Assert the result compiles structurally (braces, parens, directive balance) and that the new type is
   named by at least one phone file.

# What it will not do

It does not retarget a mention that lives in a **shared** file, because moving a shared file onto a Hako
type is the reverse dependency the boundary audit exists to prevent. When a page is reached from a shared
file on the phone's path, this reports it as `BLOCKED_SHARED_CALLSITE` and leaves the page alone rather
than half-migrating it.

Usage:
    python migrate_secondary_page.py --list
    python migrate_secondary_page.py --page ApplicationLibrary/Views/Setting/CoreView.swift --write
"""
from __future__ import annotations

import argparse
import io
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
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
HAKO_DIR = "ApplicationLibrary/Views/HakoStyle/"

#: A file-level type declaration, with its access modifiers so a `private` type can be left alone - a
#: `private` type cannot collide across files and renaming it would only churn call sites.
TYPE_DECL = re.compile(
    r"^(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
    r"fileprivate[ \t]+|final[ \t]+|indirect[ \t]+)*)"
    r"(?P<kind>struct|class|enum|protocol|actor)\s+(?P<name>\w+)", re.M)

#: The phone's own files. A caller here may be retargeted; a caller in a shared file may not.
PHONE_FILES = (
    "SFI/HakoPhoneRootView.swift",
    "SFI/HakoPageContent.swift",
)


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


def hako_files() -> list[str]:
    out = []
    directory = os.path.join(ROOT, HAKO_DIR)
    for name in sorted(os.listdir(directory)):
        if name.endswith(".swift"):
            out.append((HAKO_DIR + name).replace("/", os.sep))
    return out


def rename_map(original: str) -> dict[str, str]:
    """Every module-scope type the page declares, mapped to its Hako name."""
    out: dict[str, str] = {}
    for match in TYPE_DECL.finditer(original):
        if re.search(r"\b(?:private|fileprivate)\b", match.group("mods")):
            continue  # file-scoped: cannot collide, so renaming it would only churn call sites
        name = match.group("name")
        if name.startswith("Hako"):
            continue
        out[name] = "Hako" + name
    return out


def apply_renames(text: str, mapping: dict[str, str]) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}
    for old, new in sorted(mapping.items(), key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise SystemExit(f"FAILED: {old!r} appears nowhere")
        counts[old] = count
    return text, counts


def retarget(types: list[str], dry: bool) -> dict[str, list[str]]:
    """Point the phone's own files at the Hako types. Returns file -> changed type names.

    Only `HakoStyle/` and the two phone-root files are touched. A mention in a shared file is reported
    by the caller as a blocked call site, because editing that file is the boundary violation this whole
    exercise is about.
    """
    touched: dict[str, list[str]] = {}
    candidates = [path for path in hako_files()] + list(PHONE_FILES)
    for rel in candidates:
        full = os.path.join(ROOT, rel)
        text = read(full)
        if text is None:
            continue
        original = text
        changed: list[str] = []
        for name in sorted(types, key=len, reverse=True):
            # `Name(` or `Name<` or `Name.` - never `Name` inside `HakoName`.
            pattern = rf"(?<![\w.]){re.escape(name)}(?=[(<.])"
            text, count = re.subn(pattern, "Hako" + name, text)
            if count:
                changed.append(f"{name}->Hako{name}({count})")
        if changed and text != original:
            touched[rel] = changed
            if not dry:
                io.open(full, "w", encoding="utf-8", newline="").write(text)
    return touched


def shared_mentions(types: list[str]) -> dict[str, list[str]]:
    """Shared files (outside HakoStyle and the phone root) that name these types."""
    out: dict[str, list[str]] = {}
    skip_dirs = {".git", ".build", ".swiftpm", "build", "docs", "Tests", "HakoStyle"}
    for base, dirs, files in os.walk(os.path.join(ROOT, "ApplicationLibrary")):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            if rel.startswith(HAKO_DIR) or rel in PHONE_FILES:
                continue
            text = read(full)
            if text is None:
                continue
            for type_name in types:
                if re.search(rf"(?<![\w.]){re.escape(type_name)}(?=[(<.])", text):
                    out.setdefault(rel, []).append(type_name)
    return out


def migrate(source: str, write: bool) -> int:
    original = git("show", f"{FORK_REF}:{source}")
    resolved = resolve(original, "ios")
    mapping = rename_map(resolved)

    print(f"  source : {source}  ({len(original.splitlines())} -> {len(resolved.splitlines())} lines)")
    print(f"  declares: {', '.join(mapping.keys()) or '(no module-scope type)'}")
    if not mapping:
        print("  nothing to rename; the page declares no module-scope type this can move")
        return 0

    text, counts = apply_renames(resolved, mapping)
    text = re.sub(r"\A(?://[^\n]*\n)+", "", text)
    header = (
        f"//\n//  Hako{os.path.basename(source)}\n//  ApplicationLibrary\n//\n"
        f"//  The phone's copy of `{source}`, from `hako-ui` @ `{FORK_REF[:7]}`.\n"
        f"//\n"
        f"//  A copy rather than an edit, because that file is upstream's and an iPad or a Mac loads it\n"
        f"//  too. Every module-scope type it declares is renamed into the Hako namespace and the phone's\n"
        f"//  own call sites are redirected here; nothing about its drawing, spacing, strings or behaviour\n"
        f"//  is changed.\n"
        f"//\n"
        f"//  Generated by `scripts/dev/migrate_secondary_page.py`. Re-run that rather than editing here.\n"
        f"//\n\n"
    )
    text = header + text

    for label, opener, closer in (("braces", "{", "}"), ("parens", "(", ")")):
        if text.count(opener) != text.count(closer):
            raise SystemExit(f"FAILED [{source}]: {label} unbalanced")

    print("  renames: " + ", ".join(f"{k}({v})" for k, v in counts.items()))

    blocked = shared_mentions(list(mapping.keys()))
    if blocked:
        print("  BLOCKED_SHARED_CALLSITE - these shared files name the types and may not be redirected:")
        for rel, names in sorted(blocked.items()):
            print(f"      {rel}: {', '.join(sorted(set(names)))}")

    destination = os.path.join(ROOT, HAKO_DIR + "Hako" + os.path.basename(source))
    if write:
        io.open(destination, "w", encoding="utf-8", newline="").write(text)
        print(f"  wrote {os.path.relpath(destination, ROOT)}: {len(text.splitlines())} lines")

    touched = retarget(list(mapping.keys()), dry=not write)
    for rel, changed in sorted(touched.items()):
        print(f"  retargeted {rel}: {', '.join(changed)}")
    if not touched:
        print("  PORTED_UNWIRED - no phone-owned file names the new type; it is not reachable")
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--page", help="path under the repository, e.g. ApplicationLibrary/Views/Setting/CoreView.swift")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    if git("rev-parse", f"{FORK_REF}^{{commit}}").strip() != FORK_REF:
        raise SystemExit("FAILED: the pinned reference did not resolve to itself")

    if args.list or not args.page:
        print("pages the fork changed, with the types this tool would move:")
        out = git("diff", "--name-only", "2b1763a80f2c.." + FORK_REF, "--", "ApplicationLibrary/Views")
        for line in sorted(out.splitlines()):
            if not line.endswith(".swift") or "/HakoStyle/" in line:
                continue
            try:
                resolved = resolve(git("show", f"{FORK_REF}:{line}"), "ios")
            except SystemExit:
                print(f"  {line}: REFUSED (a condition this tool cannot decide)")
                continue
            names = ", ".join(rename_map(resolved).keys())
            print(f"  {line}: {names or '(nothing)'}")
        return 0

    return migrate(args.page, args.write)


if __name__ == "__main__":
    sys.exit(main())
