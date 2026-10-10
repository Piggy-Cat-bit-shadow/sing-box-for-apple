#!/usr/bin/env python3
"""Migrate one of the original's second-level pages into the fork's namespace, and retarget the phone.

# Default is read-only

Running this with no write flag **plans** the migration and prints it: what would be created, what would
change with a unified diff, which symbols would be redirected and where, and every reason it refuses. It
writes nothing, and two consecutive runs print byte-identical output. `--write` is the only thing that
touches the tree, and it refuses far more often than it proceeds.

# The transform, in order

1. Read the original page from the pinned upstream commit (`git show <ref>:<path>`).
2. Gate its platform conditionals. The default gate is `shared`, which keeps every `#if` and only checks
   that each condition is decidable; `--platform-gate resolved` selects the older collapsing gate, whose
   behaviour is unchanged. See `--help` and `MIGRATION-SAFETY-CONTRACT.md`.
3. Rename every **module-scope** type the file declares into the `Hako` namespace. A nested type is never
   renamed: it cannot collide with a module-scope name, and renaming one changes the identity of a member
   type the shared tree may spell as `Enclosing.Nested`. Where the shared tree does spell it that way, the
   copy gets `public typealias Nested = Enclosing.Nested` in place of the nested declaration, so both the
   copy's callers and the shared signature name one type.
4. Build the candidate text for `ApplicationLibrary/Views/HakoStyle/Hako<Page>.swift` **in memory**.
5. Work out which phone-owned files would be redirected, again in memory.
6. Validate everything - rename map non-empty, every rename matched, structure balanced, no `HakoHako`
   prefix, no nested-name collision, no `Hako... symbol lost from any file the run rewrites, the target
   either absent or authorized, the write set inside the two allowed directories, a second pass a no-op.
7. Only if nothing was refused: stage every byte to a temporary file and commit them together.

# What it will not do

  * It will not overwrite an existing, differing target. `--replace <path> --expect-sha256 <hex>` is the
    only way past that, and it names one path and one blob; if the file on disk is not that blob the run
    is refused anyway. There is no `--force`, `--all`, or `--yes`.
  * It will not rewrite a mention that is not code. A type name in a doc comment or in a string literal is
    not a call site, and the previous revision of this tool rewrote both - including its own provenance
    header, which is why 30 of the 33 committed `HakoStyle/Hako*.swift` files currently claim a source
    path that does not exist at the pinned commit.
  * It will not edit a shared file. `retarget` touches `HakoStyle/*.swift` and the two phone-owned files
    and nothing else, and any write outside that set is a refusal.
  * It will not leave a half-migrated tree. A `PORTED_UNWIRED` outcome, a validation failure and an I/O
    failure all leave every target byte-identical to how the run found it.

Usage:
    python migrate_secondary_page.py --list
    python migrate_secondary_page.py --page ApplicationLibrary/Views/Setting/CoreView.swift
    python migrate_secondary_page.py --page ... --write
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from _safety_gate import (  # noqa: E402
    Refusal,
    StagedWrites,
    hako_symbols,
    mask_noncode,
    read_text,
    sha256_file,
    sha256_text,
    sub_in_code,
)
from swift_directives import (  # noqa: E402
    DirectiveError,
    assert_balanced,
    preserve,
    resolve,
    scan_conditions,
)

GIT = os.environ.get("DSH_GIT") or "git"
ROOT = os.path.dirname(os.path.dirname(HERE))
REPO = os.environ.get("DSH_REPO") or os.path.join(
    os.path.dirname(os.path.dirname(HERE)), "sing-box-for-apple")

#: The pinned upstream commit every ported file's provenance is stated against.
FORK_REF = os.environ.get("DSH_FORK_REF") or "c1935cff77246f97498400f5a0a7f430cfabbd55"
#: The name that commit is normally reachable as. Reported next to the SHA so a reader can tell a pin that
#: resolved through a ref from one that only resolved because the object happened to be in the store.
FORK_REF_NAME = os.environ.get("DSH_FORK_REF_NAME") or "origin/hako-ui"
HAKO_DIR = "ApplicationLibrary/Views/HakoStyle/"

#: The phone's own files. A caller here may be retargeted; a caller in a shared file may not be edited,
#: and is reported instead.
PHONE_FILES = (
    "SFI/HakoPhoneRootView.swift",
    "SFI/HakoPageContent.swift",
)

#: Where a write may land: the `HakoStyle/` directory (a prefix) and the two phone-owned files (exact
#: paths). Anything else is `REVERSE_DEPENDENCY`.
WRITABLE = (HAKO_DIR,) + PHONE_FILES


def is_writable(rel: str) -> bool:
    """Whether a repository-relative, `/`-separated path is inside the write set."""
    return any(rel.startswith(prefix) if prefix.endswith("/") else rel == prefix
               for prefix in WRITABLE)

PLATFORM = "ios"

EXIT_OK = 0
EXIT_REFUSED = 1
EXIT_ENVIRONMENT = 2

#: Marks the line a nested-type alias goes on, so the alias text itself cannot be caught by the rename
#: pass that runs between removing the nested declaration and writing the alias. See `nested_aliases`.
ALIAS_MARKER = "// @dsh-nested-alias:{}"

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

#: A nested type declaration. Same shape as `TYPE_DECL`, but it has to be found by brace depth rather than
#: by indentation, for the reason `module_scope_types` gives.
NESTED_TYPE_DECL = re.compile(
    r"^[ \t]*(?P<mods>(?:@\w+(?:\([^)]*\))?[ \t]+|public[ \t]+|internal[ \t]+|private[ \t]+|"
    r"fileprivate[ \t]+|final[ \t]+|indirect[ \t]+)*)"
    r"(?P<kind>struct|class|enum|protocol|actor)\s+(?P<name>\w+)\s*[:{]", re.M)

#: A module-scope `extension SomeType { ... }`, with its access modifiers. Same leading-whitespace rule
#: as `TYPE_DECL`, and for the same reason: an indented declaration is still a declaration.
EXTENSION_DECL = re.compile(
    r"^[ \t]*(?P<mods>(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+)*)"
    r"extension\s+(?P<type>[\w.]+)\s*\{", re.M)

#: A member declared at the top level of an extension body.
EXTENSION_MEMBER = re.compile(
    r"^[ \t]{1,8}(?P<mods>(?:(?:public|internal|private|fileprivate|nonisolated|static|class|"
    r"override|mutating)[ \t]+)*)(?:var|let|func|subscript)\s+(?P<name>\w+)")


class EnvironmentError_(Exception):
    """The tool cannot run at all: git is unusable, the ref does not resolve, the page is not there."""


# --------------------------------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------------------------------


def git(*args: str) -> str:
    try:
        proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    except OSError as error:
        raise EnvironmentError_(f"cannot run {GIT!r}: {error}")
    if proc.returncode != 0:
        raise EnvironmentError_(f"git {' '.join(args)} failed in {REPO}: "
                                f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def git_soft(*args: str) -> str | None:
    """The same, but `None` instead of an exception. For questions whose answer may legitimately be no."""
    try:
        proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace")


def fork_commit(ref: str) -> tuple[str, str]:
    """`(commit, how)` for the pinned reference, or raise. `how` says which name it resolved through."""
    out = git_soft("rev-parse", "--verify", f"{ref}^{{commit}}")
    if out is None:
        raise EnvironmentError_(
            f"the pinned upstream reference {ref!r} does not resolve in {REPO}. "
            f"Fetch it (`git -C {REPO} fetch origin hako-ui`) or pass --fork-ref <sha>, which is the only "
            f"way to run this against a clone that does not carry the ref. Without it, no candidate text "
            f"can be produced and no provenance can be stated, so the run stops here.")
    commit = out.strip()
    named = git_soft("rev-parse", "--verify", f"{FORK_REF_NAME}^{{commit}}")
    if named is None:
        return commit, f"{ref!r} (the name {FORK_REF_NAME!r} is not present in this repository)"
    if named.strip() != commit:
        return commit, (f"{ref!r} (WARNING: {FORK_REF_NAME!r} is {named.strip()[:12]}, which is a "
                        f"different commit)")
    return commit, f"{FORK_REF_NAME!r}"


def show(commit: str, path: str) -> str:
    out = git_soft("show", f"{commit}:{path}")
    if out is None:
        raise EnvironmentError_(
            f"{path} does not exist at {commit[:12]}. The page list is derived from the fork's "
            f"`git diff --name-only`, which also reports files the fork *deleted*, so a name in that list "
            f"is not a promise that the file is there.")
    return out


# --------------------------------------------------------------------------------------------------
# The transform
# --------------------------------------------------------------------------------------------------


def hako_files() -> list[str]:
    directory = os.path.join(ROOT, HAKO_DIR)
    if not os.path.isdir(directory):
        return []
    return [(HAKO_DIR + name).replace("/", os.sep)
            for name in sorted(os.listdir(directory)) if name.endswith(".swift")]


def line_depths(text: str) -> list[str]:
    """The masked lines of `text`, plus `depths[i]`: the brace depth line `i` *starts* at."""
    masked = mask_noncode(text)
    depths: list[int] = []
    depth = 0
    for line in masked.split("\n"):
        depths.append(depth)
        depth += line.count("{") - line.count("}")
    return masked.split("\n"), depths


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
    masked_lines, depths = line_depths(text)
    out: dict[str, str] = {}
    for index, line in enumerate(masked_lines):
        if depths[index] != 0:
            continue
        match = TYPE_DECL.match(line)
        if match and not re.search(r"\b(?:private|fileprivate)\b", match.group("mods")):
            out[match.group("name")] = match.group("kind")
    return out


def nested_type_names(text: str) -> set[str]:
    """Type names declared at brace depth >= 1."""
    masked_lines, depths = line_depths(text)
    out: set[str] = set()
    for index, line in enumerate(masked_lines):
        if depths[index] < 1:
            continue
        match = NESTED_TYPE_DECL.match(line)
        if match:
            out.add(match.group("name"))
    return out


def rename_map(original: str) -> dict[str, str]:
    """Every module-scope type the page declares, mapped to its Hako name.

    Nested types are deliberately absent: they cannot collide across files, and renaming one breaks any
    consumer that spells it as a member type.
    """
    return {name: "Hako" + name for name in module_scope_types(original) if not name.startswith("Hako")}


def apply_renames(text: str, mapping: dict[str, str]) -> tuple[str, dict[str, int]]:
    """Whole-word rename of every module-scope name. Returns `(text, {old: count})`.

    A name that matches nothing is an error rather than a no-op. This is deliberately a *whole-word* text
    replacement and not a syntax-aware one; the collisions that makes possible (a nested type sharing a
    module-scope name) are detected and refused before this runs - see `nested_name_collisions`.
    """
    counts: dict[str, int] = {}
    for old, new in sorted(mapping.items(), key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise Refusal([f"RENAME_UNMATCHED: {old!r} appears nowhere in the gated text, so the rename "
                           f"map derived from the declarations does not describe this file"])
        counts[old] = count
    return text, counts


def nested_declaration_span(lines: list[str], start: int) -> int:
    """Index of the last line of the nested declaration whose first line is `start`.

    The body is found by brace counting from the declaration's own line. Attributes and a same-line `{`
    both work because the count starts at the declaration line rather than at a `{` the caller had to
    locate.
    """
    depth = 0
    seen_brace = False
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if "{" in lines[index]:
            seen_brace = True
        if seen_brace and depth <= 0:
            return index
    raise Refusal([f"STRUCTURE: the nested declaration starting at line {start + 1} never closes"])


def nested_aliases(lines: list[str], mapping: dict[str, str],
                   shared_reference) -> tuple[list[str], list[dict], list[str]]:
    """Replace nested declarations the shared tree spells as `Enclosing.Nested` with a `typealias`.

    # The defect this exists for, and the one the previous repair caused

    Renaming the module-scope `NewProfileView` to `HakoNewProfileView` changes the identity of its nested
    members. `NewProfileViewModel.init` is

        public init(importRequest: NewProfileView.ImportRequest? = nil,
                    localImportRequest: NewProfileView.LocalImportRequest? = nil)

    so a copy whose nested declarations came along unchanged would pass `HakoNewProfileView.ImportRequest`
    where `NewProfileView.ImportRequest` is required. The previous revision renamed the nested types
    outright (`HakoImportRequest`), which broke the same initialiser from the other side, then patched it
    with `public typealias ImportRequest = HakoImportRequest` - an alias wearing a name nobody spells, so
    `HakoNewProfileMenuView`, which spells `HakoNewProfileView.ImportRequest`, still had no such member.

    The correct answer is the one the committed copy reached by hand: leave the nested type declared where
    it is, in the shared file, and give the copy the *same* type under the name its own callers use:

        public typealias ImportRequest = NewProfileView.ImportRequest

    It is emitted only when the shared tree actually spells `Enclosing.Nested`, read out of the tree rather
    than assumed, so a nested type no shared signature mentions keeps its declaration and gets no alias.

    The alias text must survive the rename pass intact - `NewProfileView.ImportRequest` would otherwise
    become `HakoNewProfileView.ImportRequest`, which is a member of the copy rather than the shared type -
    so the alias is planted as a marker line and substituted in afterwards. Returns
    `(lines, alias_records, notes)`.
    """
    joined = "\n".join(lines)
    masked_lines, depths = line_depths(joined)

    owners: list[tuple[int, str]] = []
    for index, line in enumerate(masked_lines):
        if depths[index] != 0:
            continue
        declared = TYPE_DECL.match(line)
        if declared and declared.group("name") in mapping:
            owners.append((index, declared.group("name")))
            continue
        extended = EXTENSION_DECL.match(line)
        if extended and extended.group("type") in mapping:
            owners.append((index, extended.group("type")))

    removals: list[tuple[int, int, str, str]] = []
    for index, line in enumerate(masked_lines):
        if depths[index] < 1:
            continue
        declared = NESTED_TYPE_DECL.match(line)
        if not declared:
            continue
        enclosing = None
        for owner_index, owner_name in owners:
            if owner_index < index:
                enclosing = owner_name
            else:
                break
        if enclosing is None:
            continue
        nested = declared.group("name")
        if not shared_reference(enclosing, nested):
            continue
        end = nested_declaration_span(lines, index)
        indent = re.match(r"[ \t]*", lines[index]).group(0)
        removals.append((index, end, indent, f"{enclosing}.{nested}"))

    ordered = sorted(removals)
    records: list[dict] = []
    notes: list[str] = []
    for slot, (start, end, indent, qualified) in enumerate(ordered):
        nested = qualified.split(".", 1)[1]
        records.append({"nested": nested, "qualified": qualified,
                        "marker": ALIAS_MARKER.format(slot),
                        "alias": f"{indent}public typealias {nested} = {qualified}"})
    # Applied bottom-up: a splice near the top of the file would shift every index below it, so the last
    # declaration is replaced first and each remaining index is still the one that was measured.
    for (start, end, indent, _), record in reversed(list(zip(ordered, records))):
        lines[start:end + 1] = [indent + record["marker"]]
    for record in records:
        notes.append(f"{record['qualified']} -> {record['alias'].strip()}")
    return lines, records, notes


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


def shared_extension_members() -> dict[str, set[str]]:
    """outer type -> member names the shared tree already adds, outside the Hako namespace."""
    out: dict[str, set[str]] = {}
    for rel in shared_swift_files():
        text = read_text(os.path.join(ROOT, rel))
        if text is None:
            continue
        for outer, member in members_added_by_extensions(text):
            out.setdefault(outer, set()).add(member)
    return out


def shared_swift_files() -> list[str]:
    """Every `.swift` file under `ApplicationLibrary/` that is neither Hako-owned nor phone-owned."""
    out: list[str] = []
    skip = {".git", ".build", ".swiftpm", "build", "docs", "Tests", "HakoStyle"}
    for base, dirs, files in os.walk(os.path.join(ROOT, "ApplicationLibrary")):
        dirs[:] = sorted(d for d in dirs if d not in skip)
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            rel = os.path.relpath(os.path.join(base, name), ROOT).replace("\\", "/")
            if rel.startswith(HAKO_DIR) or rel in PHONE_FILES:
                continue
            out.append(rel)
    return out


def shared_reference_index() -> dict[str, list[tuple[str, int]]]:
    """`"Enclosing.Nested"` -> `[(file, line)]` for every shared file that spells it."""
    index: dict[str, list[tuple[str, int]]] = {}
    for rel in shared_swift_files():
        text = read_text(os.path.join(ROOT, rel))
        if text is None:
            continue
        for line_number, line in enumerate(mask_noncode(text).split("\n"), start=1):
            for qualified in re.findall(r"\b[A-Z]\w*\.[A-Z]\w*\b", line):
                index.setdefault(qualified, []).append((rel, line_number))
    return index


def retarget(types: list[str], texts: dict[str, str]) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Point the phone's own files at the Hako types. Returns `(post_texts, file -> redirections)`.

    Only `HakoStyle/` and the two phone-root files are candidates. A mention in a shared file is never
    edited; the caller reports it as a blocked call site instead.

    The substitution is restricted to **code**. The previous revision was not, and two consequences are
    still in the tree: it rewrote its own provenance header (`.../Tools/CrashReportListView.swift` became
    `.../Tools/HakoCrashReportListView.swift`, a path that does not exist upstream, in 30 of 33 files), and
    it counted those prose matches as call sites, so a page whose only "caller" was a doc comment was
    reported as reachable.
    """
    redirections: dict[str, list[str]] = {}
    for rel in [path.replace("\\", "/") for path in hako_files()] + list(PHONE_FILES):
        text = texts.get(rel)
        if text is None:
            text = read_text(os.path.join(ROOT, rel))
        if text is None:
            continue
        changed: list[str] = []
        for name in sorted(types, key=len, reverse=True):
            # `Name(` or `Name<` or `Name.` - never `Name` inside `HakoName`, which the lookbehind blocks.
            pattern = rf"(?<![\w.]){re.escape(name)}(?=[(<.])"
            text, count = sub_in_code(text, pattern, "Hako" + name)
            if count:
                changed.append(f"{name} -> Hako{name} ({count})")
        if changed:
            texts[rel] = text
            redirections[rel] = changed
    return texts, redirections


def caller_sites(types: list[str], texts: dict[str, str]) -> list[str]:
    """`file:line: snippet` for every code mention of a `Hako<type>` in a Hako-owned or phone-owned file."""
    wanted = [f"Hako{name}" for name in types]
    out: list[str] = []
    for rel in [path.replace("\\", "/") for path in hako_files()] + list(PHONE_FILES):
        text = texts.get(rel)
        if text is None:
            text = read_text(os.path.join(ROOT, rel))
        if text is None:
            continue
        mask = mask_noncode(text)
        for line_number, line in enumerate(mask.split("\n"), start=1):
            for name in wanted:
                if re.search(rf"(?<![\w.]){re.escape(name)}(?=[(<.])", line):
                    snippet = text.split("\n")[line_number - 1].strip()
                    out.append(f"{rel}:{line_number}: {snippet[:110]}")
    return out


def unified_diff(rel: str, before: str, after: str) -> list[str]:
    return list(difflib.unified_diff(before.split("\n"), after.split("\n"),
                                     fromfile=f"a/{rel}", tofile=f"b/{rel}", lineterm=""))


# --------------------------------------------------------------------------------------------------
# The plan
# --------------------------------------------------------------------------------------------------


class Plan:
    def __init__(self) -> None:
        self.source = ""
        self.commit = ""
        self.commit_how = ""
        self.gate = "shared"
        self.target_rel = ""
        self.target_abs = ""
        self.target_state = ""          # CREATE | UNCHANGED | DIFFER
        self.target_sha: str | None = None
        self.candidate_sha = ""
        self.candidate_text = ""
        self.mapping: dict[str, str] = {}
        self.rename_counts: dict[str, int] = {}
        self.aliases: list[dict] = []
        self.member_renames: list[str] = []
        self.conditions: list[dict] = []
        self.blocked: dict[str, list[str]] = {}
        self.blocked_lines: dict[str, list[str]] = {}
        self.callers: list[str] = []
        self.writes: dict[str, str] = {}    # rel -> post text
        self.redirections: dict[str, list[str]] = {}
        self.diffs: dict[str, list[str]] = {}
        self.refusals: list[str] = []
        self.notes: list[str] = []

    @property
    def refused(self) -> bool:
        return bool(self.refusals)

    @property
    def changes(self) -> list[str]:
        return [rel for rel, post in self.writes.items()
                if read_text(os.path.join(ROOT, rel)) != post]


def build_plan(source: str, gate: str, ref: str) -> Plan:
    """Everything the run would do, decided in memory. Raises `EnvironmentError_` when it cannot start."""
    plan = Plan()
    plan.source = source.replace("\\", "/")
    plan.gate = gate
    plan.commit, plan.commit_how = fork_commit(ref)

    original = show(plan.commit, plan.source)

    try:
        if gate == "shared":
            gated = preserve(original, PLATFORM)
            plan.conditions = scan_conditions(original, PLATFORM)
        else:
            gated = resolve(original, PLATFORM)
            plan.conditions = []
    except DirectiveError as error:
        plan.refusals.append(f"UNDECIDABLE_CONDITION: {error}")
        return plan

    plan.mapping = rename_map(gated)
    if not plan.mapping:
        plan.refusals.append(
            "RENAME_MAP_EMPTY: the page declares no module-scope type this tool could move, so a run would "
            "either write a file with nothing renamed in it or report success while doing nothing")
        return plan

    nested = nested_type_names(gated)
    collisions = sorted(nested & set(plan.mapping))
    if collisions:
        plan.refusals.append(
            "NESTED_NAME_COLLISION: " + ", ".join(collisions) + " - a nested type in this file has the "
            "same name as a module-scope one, and the whole-word rename cannot tell the two apart. "
            "Refusing rather than renaming both and calling the result correct")

    index = shared_reference_index()

    def shared_reference(enclosing: str, member: str) -> bool:
        return bool(index.get(f"{enclosing}.{member}"))

    try:
        lines, plan.aliases, alias_notes = nested_aliases(gated.split("\n"), plan.mapping, shared_reference)
    except Refusal as refusal:
        plan.refusals.extend(refusal.reasons)
        return plan
    plan.notes.extend(alias_notes)

    text = "\n".join(lines)
    try:
        text, plan.rename_counts = apply_renames(text, plan.mapping)
    except Refusal as refusal:
        plan.refusals.extend(refusal.reasons)
        return plan

    for record in plan.aliases:
        if text.count(record["marker"]) != 1:
            plan.refusals.append(
                f"STRUCTURE: the alias marker for {record['qualified']} survived the rename pass "
                f"{text.count(record['marker'])} times, so the alias cannot be placed safely")
            return plan
        text = text.replace(record["marker"], record["alias"])
    if ALIAS_MARKER.format(0)[:16] in text:
        plan.refusals.append("STRUCTURE: an alias marker survived into the candidate")

    shared_members = shared_extension_members()
    for outer, member in members_added_by_extensions(text):
        if member not in shared_members.get(outer, set()):
            continue
        pattern = rf"(?<![\w.]){re.escape(member)}(?=\s*\()"
        text, count = sub_in_code(text, pattern, "hako" + member[0].upper() + member[1:])
        if count:
            plan.member_renames.append(f"{outer}.{member} -> hako{member[0].upper()}{member[1:]} ({count})")

    text = re.sub(r"\A(?://[^\n]*\n)+", "", text)
    text = header(plan.source, plan.commit) + text

    for label, opener, closer in (("braces", "{", "}"), ("parens", "(", ")")):
        if text.count(opener) != text.count(closer):
            plan.refusals.append(f"STRUCTURE: {label} unbalanced in the candidate for {plan.source}")
    try:
        assert_balanced(text.split("\n"))
    except DirectiveError as error:
        plan.refusals.append(f"STRUCTURE: the generated #if structure does not balance: {error}")

    if re.search(r"\bHakoHako\w+", mask_noncode(text)):
        plan.refusals.append(
            "DOUBLE_PREFIX: the candidate contains a `HakoHako... identifier, which means a rename was "
            "applied to text that had already been renamed")

    plan.candidate_text = text
    plan.candidate_sha = sha256_text(text)
    plan.target_rel = HAKO_DIR + "Hako" + os.path.basename(plan.source)
    plan.target_abs = os.path.join(ROOT, plan.target_rel.replace("/", os.sep))
    plan.target_sha = sha256_file(plan.target_abs)
    if plan.target_sha is None:
        plan.target_state = "CREATE"
    elif plan.target_sha == plan.candidate_sha:
        plan.target_state = "UNCHANGED"
    else:
        plan.target_state = "DIFFER"

    plan.blocked = {}
    plan.blocked_lines = {}
    wanted = list(plan.mapping)
    for rel in shared_swift_files():
        shared_text = read_text(os.path.join(ROOT, rel))
        if shared_text is None:
            continue
        shared_lines = shared_text.split("\n")
        for line_number, masked_line in enumerate(mask_noncode(shared_text).split("\n"), start=1):
            for name in wanted:
                if re.search(rf"(?<![\w.]){re.escape(name)}(?=[(<.])", masked_line):
                    plan.blocked.setdefault(rel, []).append(name)
                    snippet = shared_lines[line_number - 1].strip()[:100]
                    plan.blocked_lines.setdefault(name, []).append(f"{rel}:{line_number}: {snippet}")

    texts = {plan.target_rel: text}
    texts, plan.redirections = retarget(wanted, texts)
    plan.writes = {rel: post for rel, post in texts.items()
                   if read_text(os.path.join(ROOT, rel)) != post}
    plan.callers = caller_sites(wanted, texts)

    # A type named in code by a shared file is still one type; the copy is a different one. Rewriting a
    # phone-owned file to call the copy is safe only if nothing about the original's type is on the way
    # in or out - and this tool cannot type-check to find out. `SFI/HakoPhoneRootView.swift:47` is the
    # worked example: `@State private var selection: NavigationPage` is initialised from a closure that
    # does `let page = NavigationPage(snapshotValue:)` and `return page`, so pointing the constructor at
    # `HakoNavigationPage` leaves a `HakoNavigationPage` being returned where a `NavigationPage` is
    # required. `NavigationPage` is named in code by `ApplicationLibrary/Views/SidebarView.swift`, which
    # the iPad root loads. Refusing is the only answer available without a compiler.
    for rel in sorted(plan.redirections):
        if rel not in PHONE_FILES:
            continue
        for name in wanted:
            sites = plan.blocked_lines.get(name)
            if not sites:
                continue
            plan.refusals.append(
                f"SHARED_TYPE_SPLIT: the run would rewrite {rel}, a phone-owned file, to call Hako{name} "
                f"- but {name} is still named in code by a shared file the iPad and macOS roots load: "
                + "; ".join(sites[:3])
                + f". Hako{name} is a different type, so a call whose result flows into a shared-typed "
                  f"binding or signature stops type-checking.")
            break

    # The declared page must still be named from somewhere the phone loads. `retarget` only counts code,
    # so a page whose sole "caller" is a doc comment is unreachable and says so.
    reachable = [line for line in plan.callers
                 if not line.startswith(plan.target_rel + ":")]
    if not reachable:
        plan.refusals.append(
            "PORTED_UNWIRED: no Hako-owned or phone-owned file names any of "
            + ", ".join(f"Hako{name}" for name in wanted)
            + " in code, so the copy would exist and be unreachable. The previous revision accepted a "
              "match inside a doc comment as wiring; this one does not")

    # Every `Hako... symbol a rewritten file mentions must still be there afterwards.
    for rel, post in plan.writes.items():
        before = read_text(os.path.join(ROOT, rel)) or ""
        lost = sorted(hako_symbols(before) - hako_symbols(post))
        if lost:
            plan.refusals.append(
                f"HAKO_SYMBOL_LOSS: writing {rel} would remove {', '.join(lost)} from it. This is the "
                f"reverse regression in miniature - a repaired call to an already-migrated type being "
                f"turned back into the upstream spelling")

    # A second pass over the text this run would leave behind must change nothing.
    second, second_redirections = retarget(wanted, dict(texts))
    for rel, post in texts.items():
        if second.get(rel, post) != post:
            plan.refusals.append(f"NOT_IDEMPOTENT: a second pass would rewrite {rel} again")
    del second_redirections

    for rel in plan.writes:
        if not is_writable(rel):
            plan.refusals.append(
                f"REVERSE_DEPENDENCY: the run would write {rel}, which is neither a HakoStyle/ file nor "
                f"one of the two phone-owned files. Moving a shared page onto a Hako type is the reverse "
                f"dependency the boundary audit exists to prevent")

    for rel, post in plan.writes.items():
        before = read_text(os.path.join(ROOT, rel)) or ""
        plan.diffs[rel] = unified_diff(rel, before, post)

    return plan


def header(source: str, commit: str) -> str:
    return (
        f"//\n//  Hako{os.path.basename(source)}\n//  ApplicationLibrary\n//\n"
        f"//  The phone's copy of `{source}`, from `hako-ui` @ `{commit[:7]}`.\n"
        f"//\n"
        f"//  A copy rather than an edit, because that file is upstream's and an iPad or a Mac loads it\n"
        f"//  too. Every module-scope type it declares is renamed into the Hako namespace and the phone's\n"
        f"//  own call sites are redirected here; nothing about its drawing, spacing, strings or behaviour\n"
        f"//  is changed.\n"
        f"//\n"
        f"//  Generated by `scripts/dev/migrate_secondary_page.py`. Re-run that rather than editing here.\n"
        f"//\n\n"
    )


# --------------------------------------------------------------------------------------------------
# Authorisation
# --------------------------------------------------------------------------------------------------


def authorize(plan: Plan, replace: str | None, expect: str | None) -> None:
    """Refuse an un-authorized overwrite; confirm the authorization actually matches the target.

    An existing target that differs from the candidate is the single most dangerous thing this tool can
    meet: the committed file is the result of every previous run *and* of every human repair, and the
    candidate is a fresh function of upstream. Overwriting one with the other is how three report list
    files lost their Hako detail constructor.
    """
    if plan.target_state != "DIFFER":
        if replace or expect:
            plan.notes.append("--replace/--expect-sha256 given but the target does not differ; nothing to "
                              "authorize")
        return
    if not replace:
        plan.refusals.append(
            f"TARGET_DIFFERS: {plan.target_rel} already exists and differs from the freshly generated "
            f"candidate (on disk {plan.target_sha}, candidate {plan.candidate_sha}). Nothing was written. "
            f"Overwriting it would discard every repair made to that file since it was generated. "
            f"To proceed deliberately: --write --replace {plan.target_rel} --expect-sha256 "
            f"{plan.target_sha}")
        return
    normalized = replace.replace("\\", "/")
    if normalized != plan.target_rel:
        plan.refusals.append(
            f"REPLACE_UNAUTHORIZED: --replace names {normalized}, which is not this run's target "
            f"({plan.target_rel}). One authorization covers one target")
        return
    if not expect:
        plan.refusals.append("REPLACE_UNAUTHORIZED: --replace requires --expect-sha256 naming the blob it "
                             "is authorized to replace")
        return
    if expect.strip().lower() != plan.target_sha:
        plan.refusals.append(
            f"REPLACE_UNAUTHORIZED: --expect-sha256 is {expect.strip().lower()} but {plan.target_rel} on "
            f"disk is {plan.target_sha}. The authorization does not describe the tree it was given")
        return
    plan.notes.append(f"authorized by --replace with the matching blob {plan.target_sha}")


# --------------------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------------------


def render(plan: Plan, as_json: bool) -> str:
    if as_json:
        return json.dumps({
            "source": plan.source,
            "fork_ref": plan.commit,
            "fork_ref_how": plan.commit_how,
            "platform_gate": plan.gate,
            "target": plan.target_rel,
            "target_state": plan.target_state,
            "target_sha256": plan.target_sha,
            "candidate_sha256": plan.candidate_sha,
            "renames": [f"{old} -> {new} ({plan.rename_counts.get(old, 0)})"
                        for old, new in sorted(plan.mapping.items())],
            "aliases": [record["alias"].strip() for record in plan.aliases],
            "member_renames": plan.member_renames,
            "conditions": plan.conditions,
            "blocked_shared_callsites": {rel: sorted(set(names)) for rel, names in sorted(plan.blocked.items())},
            "blocked_shared_call_lines": {name: sites for name, sites in sorted(plan.blocked_lines.items())},
            "callers": plan.callers,
            "would_write": sorted(plan.writes),
            "refusals": plan.refusals,
            "notes": plan.notes,
        }, indent=2, sort_keys=True)

    out: list[str] = []
    out.append(f"page            : {plan.source}")
    out.append(f"pinned upstream : {plan.commit}  via {plan.commit_how}")
    out.append(f"platform gate   : {plan.gate}"
               + ("  (keeps every #if chain; the copy is compiled by iOS, macOS and tvOS)"
                  if plan.gate == "shared" else "  (collapses conditionals to one platform)"))
    out.append(f"target          : {plan.target_rel}  [{plan.target_state}]")
    out.append(f"  on disk sha256: {plan.target_sha or '(absent)'}")
    out.append(f"  candidate     : {plan.candidate_sha}")
    out.append("  declares      : " + (", ".join(sorted(plan.mapping)) or "(no module-scope type)"))
    if plan.rename_counts:
        out.append("  renames       : "
                   + ", ".join(f"{old}->{new}({plan.rename_counts[old]})"
                               for old, new in sorted(plan.mapping.items())))
    if plan.member_renames:
        out.append("  extension members renamed: " + ", ".join(plan.member_renames))
    for record in plan.aliases:
        out.append(f"  nested alias  : {record['alias'].strip()}"
                   f"   (the shared tree spells {record['qualified']})")
    if plan.conditions:
        out.append("  platform conditions (all decidable): "
                   + ", ".join(f"L{item['line']} {item['condition']} = {item['value']}"
                               for item in plan.conditions))
    if plan.blocked:
        out.append("  BLOCKED_SHARED_CALLSITE - shared files name these types and are never edited:")
        for rel, names in sorted(plan.blocked.items()):
            out.append(f"      {rel}: {', '.join(sorted(set(names)))}")
        for name in sorted(plan.blocked_lines):
            for site in plan.blocked_lines[name][:3]:
                out.append(f"        {name}: {site}")
    if plan.callers:
        out.append("  callers (code, not prose):")
        for line in plan.callers[:20]:
            out.append(f"      {line}")
        if len(plan.callers) > 20:
            out.append(f"      ... and {len(plan.callers) - 20} more")
    for note in plan.notes:
        out.append(f"  note          : {note}")
    if plan.writes:
        out.append("  would write:")
        for rel in sorted(plan.writes):
            out.append(f"      {rel}")
        for rel in sorted(plan.diffs):
            out.append("")
            out.append(f"--- diff {rel} " + "-" * max(0, 60 - len(rel)))
            out.extend(plan.diffs[rel])
    else:
        out.append("  would write   : nothing (every target already holds the candidate bytes)")
    if plan.refusals:
        out.append("")
        out.append(f"REFUSED ({len(plan.refusals)} reason(s)) - nothing was written:")
        for reason in plan.refusals:
            out.append(f"  - {reason}")
        out.append("RESULT: REFUSED")
    else:
        out.append("RESULT: OK")
    return "\n".join(out)


# --------------------------------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------------------------------


def run_check(source: str, gate: str, ref: str, as_json: bool, emit: bool = False) -> int:
    plan = build_plan(source, gate, ref)
    print(render(plan, as_json))
    if emit and not as_json:
        emit_candidate(plan)
    return EXIT_REFUSED if plan.refused else EXIT_OK


def emit_candidate(plan: Plan) -> None:
    """Print the candidate text to stdout. Read-only, and the only way to see the bytes a run *would*
    write without a single file being touched - which is what a reviewer, and the test suite, need."""
    print("")
    print("----- BEGIN CANDIDATE -----")
    sys.stdout.write(plan.candidate_text)
    if not plan.candidate_text.endswith("\n"):
        sys.stdout.write("\n")
    print("----- END CANDIDATE -----")


def run_write(source: str, gate: str, ref: str, replace: str | None, expect: str | None,
              as_json: bool) -> int:
    plan = build_plan(source, gate, ref)
    authorize(plan, replace, expect)
    if plan.refused:
        print(render(plan, as_json))
        return EXIT_REFUSED

    if not plan.writes:
        print(render(plan, as_json))
        print("nothing to write: every target already holds the candidate bytes")
        return EXIT_OK

    staged = StagedWrites()
    for rel in sorted(plan.writes):
        staged.stage_text(os.path.join(ROOT, rel.replace("/", os.sep)), plan.writes[rel])
    try:
        log = staged.commit()
    except Refusal as refusal:
        print(render(plan, as_json))
        print("")
        print(f"REFUSED ({len(refusal.reasons)} reason(s)); every target is unchanged:")
        for reason in refusal.reasons:
            print(f"  - {reason}")
        return EXIT_REFUSED

    print(render(plan, as_json))
    print("")
    for line in log:
        print(f"  committed {line}")

    second = build_plan(source, gate, ref)
    if second.changes:
        print("")
        print("POST-CONDITION FAILED: a second run would still change "
              + ", ".join(sorted(second.changes)) + ". The tree is not in the state this tool promises.")
        return EXIT_REFUSED
    print(f"post-condition: a second run reports no changes ({len(second.callers)} caller line(s))")
    return EXIT_OK


def run_list(gate: str, ref: str) -> int:
    commit, how = fork_commit(ref)
    print(f"pinned upstream: {commit} via {how}")
    print("pages the fork changed, with the types this tool would move:")
    out = git_soft("diff", "--name-only", "2b1763a80f2c.." + commit, "--", "ApplicationLibrary/Views")
    if out is None:
        print("  (the fork's own base commit is not present in this repository; cannot list)")
        return EXIT_ENVIRONMENT
    for line in sorted(out.splitlines()):
        if not line.endswith(".swift") or "/HakoStyle/" in line:
            continue
        try:
            original = show(commit, line)
            if gate == "shared":
                gated = preserve(original, PLATFORM)
            else:
                gated = resolve(original, PLATFORM)
        except EnvironmentError_ as error:
            print(f"  {line}: SKIPPED ({error})")
            continue
        except DirectiveError as error:
            print(f"  {line}: REFUSED ({error})")
            continue
        names = ", ".join(sorted(rename_map(gated))) or "(no module-scope type)"
        print(f"  {line}: {names}")
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Plan, or deliberately perform, one secondary-page migration. Read-only by default.")
    parser.add_argument("--page", help="path under the repository, "
                                       "e.g. ApplicationLibrary/Views/Setting/CoreView.swift")
    parser.add_argument("--check", action="store_true",
                        help="report what would happen and write nothing (the default)")
    parser.add_argument("--dry-run", action="store_true", help="alias of --check")
    parser.add_argument("--write", action="store_true",
                        help="commit the plan; refuses far more often than it proceeds")
    parser.add_argument("--replace", metavar="PATH",
                        help="authorize replacing exactly this one existing target, which must also "
                             "match --expect-sha256. There is no --force and no blanket override")
    parser.add_argument("--expect-sha256", metavar="HEX",
                        help="the blob --replace is authorized to replace")
    parser.add_argument("--platform-gate", choices=("shared", "resolved"), default="shared",
                        help="`shared` (default) keeps every #if chain and refuses an undecidable "
                             "condition; `resolved` is the older collapsing gate, unchanged")
    parser.add_argument("--fork-ref", default=FORK_REF,
                        help=f"the pinned upstream commit (default {FORK_REF[:12]})")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--json", action="store_true", help="machine-readable plan")
    parser.add_argument("--emit", action="store_true",
                        help="also print the candidate bytes to stdout; writes nothing")
    args = parser.parse_args(argv)

    if args.write and (args.check or args.dry_run):
        print("--write and --check/--dry-run are opposites; give one", file=sys.stderr)
        return EXIT_ENVIRONMENT
    if args.replace and not args.write:
        print("--replace authorizes a write; give --write as well", file=sys.stderr)
        return EXIT_ENVIRONMENT
    if args.expect_sha256 and not args.replace:
        print("--expect-sha256 only means something with --replace", file=sys.stderr)
        return EXIT_ENVIRONMENT

    try:
        if args.list or not args.page:
            return run_list(args.platform_gate, args.fork_ref)
        if args.write:
            return run_write(args.page, args.platform_gate, args.fork_ref, args.replace,
                             args.expect_sha256, args.json)
        return run_check(args.page, args.platform_gate, args.fork_ref, args.json, args.emit)
    except EnvironmentError_ as error:
        print(f"ENVIRONMENT: {error}", file=sys.stderr)
        return EXIT_ENVIRONMENT


if __name__ == "__main__":
    sys.exit(main())
