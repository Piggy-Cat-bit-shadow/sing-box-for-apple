#!/usr/bin/env python3
"""Shared safety primitives for the `scripts/dev` generators: refusal, hashing, code masking, commit.

# Why this module exists

`migrate_secondary_page.py` shipped a write path that regenerated a target file from upstream and
overwrote whatever was on disk, and a retarget step whose "call site" pattern also matched doc comments.
Between them they (a) turned a repaired `HakoCrashReportDetailView(report:)` back into
`CrashReportDetailView(report:)` with exit status 0, and (b) rewrote the tool's own provenance header so
that 30 of the 33 committed `HakoStyle/Hako*.swift` files claim a source path that does not exist in the
pinned upstream commit. Both failures share one shape: **a write that was never validated against what it
was about to replace**. This module is where that validation lives, so the next generator does not have to
reinvent it.

# The four pieces

  * `Refusal` - every contract violation is a `Refusal`, and a `Refusal` carries *all* its reasons so one
    run reports the whole list rather than the first problem. A caller that catches it writes nothing.
  * `sha256_file` / `sha256_text` - the identity of a target before and after, which is what makes
    "nothing was written" a checkable statement rather than a promise.
  * `mask_noncode` / `sub_in_code` / `find_in_code` - a Swift-aware comment and string-literal mask, of the
    same length as its input, so a pattern can be matched and a replacement spliced at identical offsets.
    Rewriting a *mention* is only ever correct in code; a mention in prose or in a user-visible string is
    not a call site, and pretending it is is how a tool reports success while wiring nothing.
  * `StagedWrites` - collect the intended end state of every file, write every byte to a temporary file
    first, and only then swap them into place. If any step fails, every target is restored to the bytes it
    had before the run started. A partial migration is not a state this tool is allowed to leave behind.

# What this module deliberately does not do

It does not decide anything about Swift semantics, and it does not know what a "page" is. It has no
`--force`. `StagedWrites.commit` either puts every staged byte on disk or leaves every target byte-identical
to how it found it; there is no third outcome and no argument that produces one.
"""
from __future__ import annotations

import hashlib
import os
import re
import sys
import tempfile

#: Set to a 1-based step index to make the *n*-th swap in a commit fail, for the fault-injection case in
#: `test_migrate_secondary_page.py`. It can only ever prevent a write and trigger a rollback, never permit
#: one, and a run that uses it always ends non-zero. Real I/O faults (a read-only target) are used as well;
#: this exists so the failure can be aimed at an exact step rather than at whichever file happens to be
#: read-only.
FAULT_ENV = "DSH_SAFETY_FAULT_AT"


class Refusal(Exception):
    """A contract refusal. `reasons` is the complete list; nothing may be written when this is raised."""

    def __init__(self, reasons):
        if isinstance(reasons, str):
            reasons = [reasons]
        self.reasons = [str(reason) for reason in reasons]
        super().__init__("; ".join(self.reasons))


# --------------------------------------------------------------------------------------------------
# Identity
# --------------------------------------------------------------------------------------------------


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    return sha256_bytes(text.encode("utf-8"))


def read_bytes(path: str) -> bytes | None:
    """The file's bytes, or `None` when it does not exist. Any other OS error propagates."""
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def read_text(path: str) -> str | None:
    data = read_bytes(path)
    return None if data is None else data.decode("utf-8")


def sha256_file(path: str) -> str | None:
    """The file's SHA-256, or `None` when it does not exist. Absence is a value here, not an error:
    "the target was not there" is exactly what a create-once check has to compare."""
    data = read_bytes(path)
    return None if data is None else sha256_bytes(data)


# --------------------------------------------------------------------------------------------------
# Overwrite authorization
# --------------------------------------------------------------------------------------------------


class OverwriteAuthorization:
    """`--replace <path> --expect-sha256 <hex>`: permission to overwrite exactly one file, one blob.

    # Why this is here rather than in each generator

    `migrate_secondary_page.py` learnt it needed this the hard way, and the three `port_*.py` scripts
    beside it never did. They each read

        if os.path.exists(destination) and not regenerate:
            ... report a difference and exit 1 ...
        io.open(destination, "w", ...).write(text)

    so `--regenerate` did not merely *allow* an overwrite, it **skipped the comparison that would have
    reported one**. Measured on a copy of this tree, `port_tools_and_more.py --regenerate` rewrites
    `HakoToolsView.swift`, `HakoLogView.swift` and `HakoSettingView.swift` to their upstream shape: every
    `#if !os(tvOS)` guard the round restored is gone, and `HakoCoreView()`, `HakoAppView()`,
    `HakoRemoteControlView()`, `HakoPacketTunnelView()`, `HakoProfileOverrideView()` and
    `HakoOnDemandRulesView()` are spelled with their upstream names again - exactly the reverse-dependency
    regression the round exists to prevent, written with exit status 0. `audit_apple_ui_boundary.py
    --strict` goes FAIL on four checks; `audit_hako_lossless_parity.py` stays green, because it compares
    token sets and the token set does not change when a guard is deleted.

    A generator cannot see those repairs: its candidate is a fresh function of the pinned upstream text,
    and the file on disk is the product of the last run *plus* every human repair since. So the rule is the
    same one `migrate_secondary_page.py` states: **an existing target is compared, never assumed
    replaceable**, and replacing one is a deliberate act that names the exact blob it is discarding.

    # Usage

        guard = OverwriteAuthorization(sys.argv)
        wanted = guard.authorize(destination, text, label="Tools")
        if wanted is not None:
            text = wanted      # authorized: the caller may keep the repairs it already made

    `authorize` returns `None` when the destination may be written as computed, the existing text when the
    caller is authorized to overwrite (and should merge rather than discard), and raises `Refusal` with the
    complete reason list otherwise. A create is not an overwrite and needs no authorization; deleting a
    guard must not be a way to skip the check, so the flag is read from `argv` and cannot be defaulted.
    """

    #: `--replace=path` authorizes one target. `--expect-sha256=hex` names the blob. Both accept a
    #: separate-value spelling as well, so a reader who types the flags out of habit still gets an
    #: authorization rather than a silent no-op; the `=` spelling is what `authorization_commands` prints,
    #: because it is the one that stays unambiguous when a run has to authorize several targets.
    REPLACE_PREFIX = "--replace"
    EXPECT_PREFIX = "--expect-sha256"

    def __init__(self, argv) -> None:
        self.replacements = self._values(argv, self.REPLACE_PREFIX)
        self.expectations = self._values(argv, self.EXPECT_PREFIX)
        #: Every refusal this run produced, so a caller can report all of them at once.
        self.reasons: list[str] = []
        #: Targets this run was authorized to overwrite, for the report.
        self.authorized: list[str] = []

    @classmethod
    def _values(cls, argv, flag: str) -> list[str]:
        """Every value given for `flag`, in argv order, in both `--flag=v` and `--flag v` spellings."""
        found: list[str] = []
        index = 0
        while index < len(argv):
            argument = argv[index]
            if argument.startswith(flag + "="):
                found.append(argument.split("=", 1)[1])
                index += 1
            elif argument == flag:
                if index + 1 >= len(argv):
                    raise Refusal([f"{flag} requires a value"])
                found.append(argv[index + 1])
                index += 2
            else:
                index += 1
        return found

    def refuse(self, reason: str) -> None:
        self.reasons.append(reason)

    def report(self, stream=None) -> None:
        """Print every refusal, one per line. A run that refused wrote nothing."""
        stream = stream or sys.stderr
        for reason in self.reasons:
            print(f"REFUSED: {reason}", file=stream)

    def authorization_commands(self, script: str) -> list[str]:
        """One complete command line authorizing every target this run would have overwritten.

        One authorization covers one target, so a generator with three differing pages needs three pairs.
        The whole set is printed as a single command because that is the run a reader actually wants, and
        none of it is executed here: authorizing is a deliberate act, and this method's job is to make the
        deliberate act a copy-and-paste rather than a guess.
        """
        pairs: list[str] = []
        marker = "To proceed deliberately: "
        for reason in self.reasons:
            if marker not in reason:
                continue
            # The reason reads `... To proceed deliberately: --replace <path> --expect-sha256 <hex>`, so
            # the literal flag has to come off before the pair is re-spelled in its `=` form. Leaving it on
            # produced `--replace=--replace <path>`, which is not an authorization for anything - and a
            # refusal whose own suggested command does not work is worse than one that suggests nothing.
            target, _, expected = reason.split(marker, 1)[1].strip().partition(" --expect-sha256 ")
            target = target.strip()
            if target.startswith(self.REPLACE_PREFIX):
                target = target[len(self.REPLACE_PREFIX):].strip()
            pairs.append(f"{self.REPLACE_PREFIX}={target} {self.EXPECT_PREFIX}={expected.strip()}")
        if not pairs:
            return []
        return [f"python scripts/dev/{script} --regenerate " + " ".join(pairs)]

    def check(self, path: str, candidate: str, label: str = "") -> str | None:
        """`None` when the target may be written as computed; otherwise the reason to refuse.

        Every reason is *also* appended to `self.reasons`, so a caller that keeps planning reports all of
        them at once. This never raises, because the caller has to distinguish "this target needs an
        authorization" from "this target is fine": raising would abandon the rest of the plan, and
        reporting only the first of three unauthorized targets turns a one-line fix into three runs.
        """
        existing = read_text(path)
        if existing is None:
            return None  # a create is not an overwrite
        if existing == candidate:
            return None  # byte-identical: writing it changes nothing
        relative = os.path.relpath(path).replace("\\", "/")
        on_disk = sha256_text(existing)
        candidate_sha = sha256_text(candidate)
        prefix = f"[{label}] " if label else ""
        named = [self._normalize(item) for item in self.replacements]
        if not self.replacements:
            return self._note(
                f"{prefix}TARGET_DIFFERS: {relative} already exists and differs from the freshly "
                f"generated candidate (on disk {on_disk}, candidate {candidate_sha}). Nothing was "
                f"written. Overwriting it would discard every repair made to that file since it was "
                f"generated - including the platform guards and the renamed call sites this round "
                f"restored, which a regenerated copy spells the upstream way again. To proceed "
                f"deliberately: --replace {relative} --expect-sha256 {on_disk}")
        if relative not in named:
            self._note(
                f"{prefix}REPLACE_UNAUTHORIZED: --replace names {', '.join(named)}, which does not include "
                f"this run's target {relative}. One authorization covers one target, and it has to name "
                f"the one being replaced")
            return self.reasons[-1]
        if on_disk not in [item.strip().lower() for item in self.expectations]:
            if not self.expectations:
                self._note(f"{prefix}REPLACE_UNAUTHORIZED: --replace requires --expect-sha256 naming the "
                           f"blob it is authorized to replace")
            else:
                self._note(
                    f"{prefix}REPLACE_UNAUTHORIZED: no --expect-sha256 matches {relative} on disk "
                    f"({on_disk}); this run was given {', '.join(self.expectations)}. The authorization "
                    f"does not describe the tree it was given")
            return self.reasons[-1]
        return None

    @staticmethod
    def _normalize(path: str) -> str:
        """A path as it will be compared: relative to the working directory, forward slashes."""
        if os.path.isabs(path):
            try:
                path = os.path.relpath(path)
            except ValueError:
                # A different drive: it cannot be this run's target, and keeping the absolute spelling
                # makes the refusal say which path was named.
                pass
        return path.replace("\\", "/")

    def _note(self, reason: str) -> str:
        self.reasons.append(reason)
        return reason

    def authorize(self, path: str, candidate: str, label: str = "") -> str | None:
        """`None` to write `candidate`; the existing text when overwriting is authorized.

        Raises `Refusal` naming every reason collected so far when the destination exists, differs from
        the candidate, and this run does not carry a matching authorization. A caller that wants to
        report every target's reason at once should use `check` in a planning pass and this in the
        writing pass, rather than catching the first refusal.
        """
        reason = self.check(path, candidate, label)
        if reason is None:
            existing = read_text(path)
            if existing is not None and existing != candidate:
                self.authorized.append(os.path.relpath(path).replace("\\", "/"))
            return existing
        raise Refusal(self.reasons)


def plan_writes(guard: OverwriteAuthorization, items, script: str, plan_only: bool = False,
                regenerate: bool = False):
    """Decide every target before writing any, and report the whole set of refusals at once.

    `items` is an iterable of `(label, absolute_path, candidate_text)`. For each target:

      * `plan_only` - stop at the candidate, decide nothing, write nothing. This is `--check`.
      * the file does not exist, or is byte-identical - nothing to authorize.
      * the file differs and this run carries a matching `--replace`/`--expect-sha256` - approved.
      * the file differs and it does not - recorded on `guard` as a refusal.

    Returns `(approved, None)` when every target was approved, and `(None, exit_code)` when at least one
    refusal was recorded - after printing every reason and one command line that authorizes the whole set.
    The caller writes only the approved list, so a run that refuses anything writes nothing anywhere: a
    partial regeneration is not a state these generators are allowed to leave behind, and reporting one
    unauthorized target at a time would turn a one-line fix into three runs.

    This lives here, rather than in each `port_*.py`, because three scripts had the same three lines -
    `if os.path.exists(destination) and not regenerate: ... else: write` - and the same hole in them.
    """
    approved: list[tuple] = []
    for label, path, text in items:
        if plan_only:
            continue
        if os.path.exists(path):
            current = read_text(path)
            if current == text:
                # Byte-identical: writing it would touch the file's mtime and change nothing else, and
                # `port_hako_components.py` reaches here on the healthy tree. A file that reports as
                # written while its bytes do not move is a claim the caller cannot check.
                print(f"    unchanged ({len(text.splitlines())} lines)")
                continue
            if not regenerate:
                print("    differs from what this script would write; pass --regenerate", file=sys.stderr)
                return None, 1
        if guard.check(path, text, label=label) is not None:
            continue
        approved.append((label, path, text))

    if guard.reasons:
        guard.report()
        for command in guard.authorization_commands(script):
            print(f"REFUSED: to authorize every target above, deliberately:\n    {command}", file=sys.stderr)
        print(f"REFUSED: {len(guard.reasons)} target(s) need an authorization that this run does not "
              f"carry; nothing was written", file=sys.stderr)
        return None, 1

    for _label, path, text in approved:
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        print(f"    wrote {os.path.relpath(path)}: {len(text.splitlines())} lines")
    return approved, None


# --------------------------------------------------------------------------------------------------
# Code, as opposed to prose
# --------------------------------------------------------------------------------------------------


def _blank(out: list[str], text: str, start: int, end: int) -> None:
    for index in range(start, min(end, len(out))):
        if text[index] != "\n":
            out[index] = " "


def _end_of_raw_string(text: str, quote: int, hashes: int) -> int:
    """Index just past a `#"..."#` literal whose opening quote is at `quote` with `hashes` `#`s."""
    closing = '"' + "#" * hashes
    index = quote + 1
    length = len(text)
    while index < length:
        if text[index] == "\\" and text.startswith("#" * hashes, index + 1):
            index += 1 + hashes + 1
        elif text.startswith(closing, index):
            return index + len(closing)
        else:
            index += 1
    return length


def mask_noncode(text: str) -> str:
    """`text` with every comment and every string literal blanked to spaces, same length, newlines kept.

    Offsets in the result are offsets in the input, which is the property that makes `sub_in_code` safe:
    a match found in the mask can be cut out of the original without re-deriving any position.

    Swift block comments nest, so `/* a /* b */ c */` is one comment and not a comment followed by code -
    the depth counter is not decoration. Raw strings (`#"..."#`) are handled because
    `String(localized: #"..."#)` occurs in this tree; a `#` that does not introduce a string (as in `#if`,
    `#available`, `#Preview`) is left alone.
    """
    out = list(text)
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "/" and index + 1 < length and text[index + 1] == "/":
            end = text.find("\n", index)
            end = length if end < 0 else end
            _blank(out, text, index, end)
            index = end
        elif char == "/" and index + 1 < length and text[index + 1] == "*":
            depth = 1
            end = index + 2
            while end < length and depth:
                if text.startswith("/*", end):
                    depth += 1
                    end += 2
                elif text.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            _blank(out, text, index, end)
            index = end
        elif char == "#":
            hashes = 0
            while index + hashes < length and text[index + hashes] == "#":
                hashes += 1
            quote = index + hashes
            if quote < length and text[quote] == '"':
                end = _end_of_raw_string(text, quote, hashes)
                _blank(out, text, index, end)
                index = end
            else:
                index += 1
        elif char == '"':
            if text.startswith('"""', index):
                end = index + 3
                while end < length and not text.startswith('"""', end):
                    end += 2 if text[end] == "\\" else 1
                end = min(end + 3, length)
            else:
                end = index + 1
                while end < length:
                    if text[end] == "\\":
                        end += 2
                    elif text[end] == '"':
                        end += 1
                        break
                    elif text[end] == "\n":
                        break
                    else:
                        end += 1
            _blank(out, text, index, end)
            index = end
        else:
            index += 1
    return "".join(out)


def find_in_code(text: str, pattern: str) -> list[re.Match]:
    """Every match of `pattern` that lies in code rather than in a comment or a string literal."""
    return list(re.finditer(pattern, mask_noncode(text)))


def sub_in_code(text: str, pattern: str, replacement: str) -> tuple[str, int]:
    """`re.subn(pattern, replacement, text)` restricted to code. Returns `(new_text, count)`.

    The substitution is spliced at the offsets the mask produced, so a group reference in `replacement`
    expands against the original characters - the mask only ever decides *where* a match is, never what it
    contains.
    """
    pieces: list[str] = []
    last = 0
    matches = find_in_code(text, pattern)
    for match in matches:
        pieces.append(text[last:match.start()])
        pieces.append(match.expand(replacement))
        last = match.end()
    pieces.append(text[last:])
    return "".join(pieces), len(matches)


def hako_symbols(text: str) -> set[str]:
    """Every `Hako...` identifier mentioned in *code* in `text`."""
    return set(re.findall(r"\bHako\w+", mask_noncode(text)))


# --------------------------------------------------------------------------------------------------
# All-or-nothing commit
# --------------------------------------------------------------------------------------------------


def _remove_quietly(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


class StagedWrites:
    """The intended end state of every file a run would touch, committed together or not at all.

    The order is: read every pre-image, write every new byte to a temporary file beside its target, then
    swap. Nothing a target can observe changes until the first swap, and if a swap fails the ones already
    done are restored from the pre-images held in memory.
    """

    def __init__(self) -> None:
        self._entries: list[tuple[str, bytes | None]] = []

    def __len__(self) -> int:
        return len(self._entries)

    @property
    def paths(self) -> list[str]:
        return [path for path, _ in self._entries]

    def stage_text(self, path: str, text: str) -> None:
        self._entries.append((os.path.abspath(path), text.encode("utf-8")))

    def stage_delete(self, path: str) -> None:
        self._entries.append((os.path.abspath(path), None))

    def pre_image_hashes(self) -> dict[str, str | None]:
        return {path: sha256_file(path) for path in self.paths}

    def commit(self) -> list[str]:
        """Put every staged byte on disk. Returns one log line per target.

        Raises `Refusal` - with every target restored - if staging, a swap, or the post-swap verification
        fails. A `Refusal` from here means the tree is exactly as it was.
        """
        pre: dict[str, bytes | None] = {}
        for path, _ in self._entries:
            pre[path] = read_bytes(path)

        faults_after = 0
        raw_fault = os.environ.get(FAULT_ENV)
        if raw_fault:
            try:
                faults_after = int(raw_fault)
            except ValueError:
                raise Refusal([f"{FAULT_ENV}={raw_fault!r} is not an integer"])

        temps: dict[str, str] = {}
        try:
            for path, data in self._entries:
                if data is None:
                    continue
                handle, temporary = tempfile.mkstemp(dir=os.path.dirname(path),
                                                     prefix=".dsh-stage-", suffix=".tmp")
                with os.fdopen(handle, "wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                temps[path] = temporary
        except OSError as error:
            for temporary in temps.values():
                _remove_quietly(temporary)
            raise Refusal([f"staging failed, so no target was touched: "
                           f"{type(error).__name__}: {error}"])

        swapped: list[str] = []
        step = 0
        try:
            for path, data in self._entries:
                step += 1
                if faults_after and step >= faults_after:
                    raise OSError(f"injected fault at step {step} ({FAULT_ENV}={faults_after})")
                if data is None:
                    if os.path.exists(path):
                        os.remove(path)
                else:
                    # The temp is popped only *after* the swap succeeds. Popping it as an argument to
                    # `os.replace` looks the same and is not: a failing replace then leaves the temp out
                    # of `temps`, so the cleanup below cannot see it and a `.dsh-stage-*.tmp` file is left
                    # in the output directory. The fault-injection case caught exactly that.
                    temporary = temps[path]
                    os.replace(temporary, path)
                    del temps[path]
                swapped.append(path)
        except OSError as error:
            problems = _roll_back(swapped, pre)
            for temporary in temps.values():
                _remove_quietly(temporary)
            raise Refusal([f"commit failed at step {step} on {path}: "
                           f"{type(error).__name__}: {error}"] + problems)

        wrong = [path for path, data in self._entries
                 if sha256_file(path) != (None if data is None else sha256_bytes(data))]
        if wrong:
            problems = _roll_back(swapped, pre)
            raise Refusal(["post-commit verification failed for " + ", ".join(sorted(wrong))]
                          + problems)

        return [f"{'create' if pre[path] is None else 'update'} {os.path.basename(path)}"
                for path, _ in self._entries]


def _roll_back(swapped: list[str], pre: dict[str, bytes | None]) -> list[str]:
    """Restore every path in `swapped` to its pre-image. Returns a line per path it could not restore."""
    problems: list[str] = []
    for path in reversed(swapped):
        before = pre[path]
        try:
            if before is None:
                if os.path.exists(path):
                    os.remove(path)
            else:
                with open(path, "wb") as handle:
                    handle.write(before)
                    handle.flush()
                    os.fsync(handle.fileno())
        except OSError as error:
            problems.append(f"ROLLBACK FAILED for {path}: {type(error).__name__}: {error}")
    return problems
