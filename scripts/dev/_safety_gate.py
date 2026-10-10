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


def count_in_code(text: str, pattern: str) -> int:
    return len(find_in_code(text, pattern))


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
