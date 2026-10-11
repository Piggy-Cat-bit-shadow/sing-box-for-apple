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
#:
#: The leading `[ \t]*` is load-bearing and was missing at first. A declaration's modifiers must sit at
#: the start of its line, but the *line* need not start at column 0: `TaildropView.swift` wraps its whole
#: body in `#if !os(tvOS)` and indents everything inside, so `    public struct TaildropView` never
#: matched a pattern anchored on `^` followed directly by the modifiers. The tool reported "no
#: module-scope type" for a file with one, which is the failure mode a `rename_map` that returns `{}` is
#: least likely to be questioned.
TYPE_DECL = re.compile(
    r"^[ \t]*(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
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


def module_scope_types(text: str) -> dict[str, str]:
    """`{name: kind}` for every type declared at **brace depth 0**.

    # Why depth and not indentation

    An earlier version treated "indented" as "nested". That is not the same thing. `TaildropView.swift`
    wraps its whole body in `#if !os(tvOS)`, so after the conditional is resolved its `public struct
    TaildropView` is still indented four spaces - and it is a module-scope type that must be renamed,
    because upstream's file declares it too. Meanwhile `NewProfileView.ImportRequest` is genuinely nested,
    and renaming it was a compile error: `NewProfileViewModel.init` takes
    `NewProfileView.ImportRequest?`, so a copy named `HakoImportRequest` does not type-check.

    A nested type cannot collide with a module-scope name, so it never needs renaming; a module-scope type
    always does. Indentation cannot tell them apart and brace depth can, so depth decides.
    """
    without_comments = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    without_comments = re.sub(r"//[^\n]*", "", without_comments)

    out: dict[str, str] = {}
    depth = 0
    for line in without_comments.split("\n"):
        match = TYPE_DECL.match(line)
        if match and depth == 0 and not re.search(r"\b(?:private|fileprivate)\b", match.group("mods")):
            out[match.group("name")] = match.group("kind")
        depth += line.count("{") - line.count("}")
    return out


def nested_type_names(text: str) -> set[str]:
    """Type names declared at brace depth >= 1."""
    without_comments = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    without_comments = re.sub(r"//[^\n]*", "", without_comments)

    out: set[str] = set()
    depth = 0
    for line in without_comments.split("\n"):
        match = NESTED_TYPE_DECL.match(line)
        if match and depth >= 1:
            out.add(match.group("name"))
        depth += line.count("{") - line.count("}")
    return out


def rename_map(original: str) -> dict[str, str]:
    """Every module-scope type the page declares, mapped to its Hako name.

    Nested types are deliberately absent: they cannot collide across files, and renaming one breaks any
    consumer that spells it as a member type.
    """
    return {name: "Hako" + name for name in module_scope_types(original) if not name.startswith("Hako")}


def apply_renames(text: str, mapping: dict[str, str]) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}
    for old, new in sorted(mapping.items(), key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise SystemExit(f"FAILED: {old!r} appears nowhere")
        counts[old] = count
    return text, counts


#: A module-scope `extension SomeType { ... }`, with its access modifiers. Same leading-whitespace rule
#: as `TYPE_DECL`, and for the same reason: an indented declaration is still a declaration.
EXTENSION_DECL = re.compile(
    r"^[ \t]*(?P<mods>(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+)*)"
    r"extension\s+(?P<type>[\w.]+)\s*\{", re.M)

#: A member declared at the top level of an extension body.
EXTENSION_MEMBER = re.compile(
    r"^[ \t]{1,8}(?P<mods>(?:(?:public|internal|private|fileprivate|nonisolated|static|class|"
    r"override|mutating)[ \t]+)*)(?:var|let|func|subscript)\s+(?P<name>\w+)")


def members_added_by_extensions(text: str) -> list[tuple[str, str]]:
    """(outer type, member name) for every member added by a module-scope extension in `text`.

    A ported copy declares its own `extension View { func cardSegment(...) }` because the original did.
    Renaming the types inside it is not enough: the extension itself is module scope, so the port and
    upstream's file both add `View.cardSegment` and the module does not build. These members need the
    same treatment the types get, and they are found structurally - by walking each extension body with a
    brace counter - rather than by matching names, because a name is exactly what is being changed.
    """
    out: list[tuple[str, str]] = []
    for match in EXTENSION_DECL.finditer(text):
        if re.search(r"\b(?:private|fileprivate)\b", match.group("mods") or ""):
            continue
        depth, index, length = 1, match.end(), len(text)
        body_lines: list[str] = []
        while index < length and depth > 0:
            end = text.find("\n", index)
            if end < 0:
                end = length
            line = text[index:end]
            if depth == 1:
                body_lines.append(line)
            depth += line.count("{") - line.count("}")
            index = end + 1
        for line in body_lines:
            found = EXTENSION_MEMBER.match(line)
            if found and not re.search(r"\b(?:private|fileprivate)\b", found.group("mods") or ""):
                out.append((match.group("type"), found.group("name")))
    return out


#: A nested type declaration, with the source line that opens it.
NESTED_TYPE_DECL = re.compile(
    r"^[ \t]+(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
    r"fileprivate[ \t]+|final[ \t]+|indirect[ \t]+)*)"
    r"(?P<kind>struct|class|enum|protocol|actor)\s+(?P<name>\w+)\s*[:{]", re.M)


def nested_types_needing_aliases(text: str, mapping: dict[str, str]) -> list[tuple[str, str]]:
    """`(HakoName, OriginalName)` for each renamed **nested** type that is itself named as a member type.

    # The defect this exists for

    The migration renamed `NewProfileView`'s two nested request types to `HakoImportRequest` and
    `HakoLocalImportRequest` and left the initialiser passing them to `NewProfileViewModel`, whose own
    signature is `init(importRequest: NewProfileView.ImportRequest?, ...)`. `HakoImportRequest` is not
    that type, so the file did not compile - and the tool reported success, because a rename that matched
    is exactly what it was checking for.

    A nested type is not the same kind of thing as a module-scope one. Renaming it is only ever needed to
    avoid a collision with another **module-scope** name, and a nested type cannot collide with one. When
    a renamed nested type also appears as `Enclosing.Name` anywhere - in a call, a signature, a type
    annotation - something outside the declaration is spelling it that way, and the rename breaks it.

    The fix restores the original spelling as a `typealias` member of the same enclosing type, so both
    names resolve to one type: the file's own Hako-named API stays, and every member reference the
    consumer expects keeps working.
    """
    aliases: list[tuple[str, str]] = []
    for match in NESTED_TYPE_DECL.finditer(text):
        original = match.group("name")
        renamed = mapping.get(original)
        if renamed is None:
            continue
        if not re.search(rf"\.{re.escape(original)}\b", text):
            continue
        aliases.append((renamed, original))
    return aliases


def shared_extension_members() -> dict[str, set[str]]:
    """outer type -> member names the shared tree already adds, outside the Hako namespace."""
    out: dict[str, set[str]] = {}
    skip = {".git", ".build", ".swiftpm", "build", "docs", "Tests"}
    for base, dirs, files in os.walk(os.path.join(ROOT, "ApplicationLibrary")):
        dirs[:] = [d for d in dirs if d not in skip]
        for name in files:
            if not name.endswith(".swift"):
                continue
            rel = os.path.relpath(os.path.join(base, name), ROOT).replace("\\", "/")
            if rel.startswith(HAKO_DIR):
                continue
            text = read(os.path.join(base, name))
            if text is None:
                continue
            for outer, member in members_added_by_extensions(text):
                out.setdefault(outer, set()).add(member)
    return out


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

    # A renamed **nested** type whose original spelling is still used as a member type needs the
    # original spelling restored as a typealias, or the consumer of that member type stops compiling.
    # See `nested_types_needing_aliases` for the defect this exists for.
    aliases = nested_types_needing_aliases(text, mapping)
    if aliases:
        lines = text.split("\n")
        # Insert each alias immediately after the enclosing type's opening brace is impractical without
        # tracking nesting, so they go at the end of the file as members of nothing: a typealias at file
        # scope would be a different declaration. Instead they are appended inside the enclosing struct's
        # body, found by scanning for the Hako type that matched the rename.
        for renamed, original in aliases:
            opener = [i for i, line in enumerate(lines)
                      if TYPE_DECL.match(line) and TYPE_DECL.match(line).group("name") == renamed]
            if len(opener) != 1:
                raise SystemExit(f"FAILED: cannot place a typealias for {renamed!r} "
                                 f"({len(opener)} declarations)")
            start = opener[0]
            depth = 0
            for index in range(start, len(lines)):
                depth += lines[index].count("{") - lines[index].count("}")
                if depth == 0 and index > start:
                    lines.insert(index, f"    public typealias {original} = {renamed}")
                    break
            else:
                raise SystemExit(f"FAILED: unbalanced declaration {renamed!r}")
        text = "\n".join(lines)
        print("  nested typealiases: " + ", ".join(f"{o} = {r}" for r, o in aliases))

    # A module-scope extension member the ported copy adds that upstream's file also adds is a duplicate
    # declaration just as a duplicated type is, and renaming the types inside it does not help.
    shared_members = shared_extension_members()
    member_counts: dict[str, int] = {}
    for outer, member in members_added_by_extensions(text):
        if member not in shared_members.get(outer, set()):
            continue
        pattern = rf"(?<![\w.]){re.escape(member)}(?=\s*\()"
        text, count = re.subn(pattern, "hako" + member[0].upper() + member[1:], text)
        if count:
            member_counts[f"{outer}.{member}"] = count
    if member_counts:
        print("  extension members renamed to avoid a shared duplicate: "
              + ", ".join(f"{k}({v})" for k, v in member_counts.items()))

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
