#!/usr/bin/env python3
"""A structural check for Swift files that masks strings first, then counts.

The naive version of this - strip `//` to end of line, strip `/* */`, count braces - reported every file in
the tree as unbalanced, including the originals at the pin, because a `//` inside a **string literal**
(a URL, most often) starts what looks like a comment and swallows the rest of the line, taking its braces
with it. Both the original `CoreView.swift` and its port reported "braces 94/95", which is how the artifact
was caught: a check that fails on the reference implementation is measuring itself.

This one walks the file once, tracking whether it is inside a string, a multi-line string, a character, or a
comment, and counts delimiters only in code. It also checks that every `#if` has a matching `#endif` and that
no `#else` follows an `#else`, which is what a bad conditional edit actually breaks.
"""
from __future__ import annotations

import io
import os
import sys


def scan(text: str) -> dict:
    """Return the delimiter counts in code, plus structure problems."""
    brace = paren = bracket = 0
    directive_depth = 0
    seen_else = []          # one flag per open `#if`
    problems: list[str] = []
    line = 1
    index = 0
    length = len(text)
    in_line_comment = False
    in_block_comment = 0
    in_string = False
    in_multiline_string = False
    raw_hashes = 0

    while index < length:
        char = text[index]
        nxt = text[index + 1] if index + 1 < length else ""

        if char == "\n":
            line += 1
            in_line_comment = False
            if not in_multiline_string and not in_string:
                # a directive is only recognised at the start of a line's code
                pass
            index += 1
            continue

        if in_line_comment:
            index += 1
            continue
        if in_block_comment:
            if char == "*" and nxt == "/":
                in_block_comment -= 1
                index += 2
                continue
            if char == "/" and nxt == "*":
                in_block_comment += 1
                index += 2
                continue
            index += 1
            continue
        if in_multiline_string:
            if char == '"' and text.startswith('"""' + "#" * raw_hashes, index):
                in_multiline_string = False
                index += 3 + raw_hashes
                continue
            index += 1
            continue
        if in_string:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_string = False
            index += 1
            continue

        # Not inside anything: recognise the starts.
        if char == "/" and nxt == "/":
            in_line_comment = True
            index += 2
            continue
        if char == "/" and nxt == "*":
            in_block_comment += 1
            index += 2
            continue
        if text.startswith('"""', index):
            in_multiline_string = True
            index += 3
            continue
        if char == '"':
            in_string = True
            index += 1
            continue
        if char == "#":
            # `#"..."#` raw strings, and `#if` directives.
            hashes = 0
            probe = index
            while probe < length and text[probe] == "#":
                hashes += 1
                probe += 1
            if text.startswith('"', probe):
                raw_hashes = hashes
                in_string = True
                index = probe + 1
                continue
            # A directive at the start of the line's code.
            before = text[text.rfind("\n", 0, index) + 1:index]
            word_end = probe
            while word_end < length and (text[word_end].isalnum() or text[word_end] == "_"):
                word_end += 1
            keyword = text[probe:word_end]
            if before.strip() == "" and keyword in ("if", "elseif", "else", "endif"):
                if keyword == "if":
                    directive_depth += 1
                    seen_else.append(False)
                elif keyword == "elseif":
                    if directive_depth == 0:
                        problems.append(f"line {line}: #elseif with no #if")
                    elif seen_else[-1]:
                        problems.append(f"line {line}: #elseif after #else")
                elif keyword == "else":
                    if directive_depth == 0:
                        problems.append(f"line {line}: #else with no #if")
                    elif seen_else[-1]:
                        problems.append(f"line {line}: #else after #else")
                    else:
                        seen_else[-1] = True
                else:
                    if directive_depth == 0:
                        problems.append(f"line {line}: #endif with no #if")
                    else:
                        directive_depth -= 1
                        seen_else.pop()
            index = probe
            continue

        if char == "{":
            brace += 1
        elif char == "}":
            brace -= 1
            if brace < 0:
                problems.append(f"line {line}: `}}` closes nothing")
        elif char == "(":
            paren += 1
        elif char == ")":
            paren -= 1
            if paren < 0:
                problems.append(f"line {line}: `)` closes nothing")
        elif char == "[":
            bracket += 1
        elif char == "]":
            bracket -= 1
        index += 1

    if brace:
        problems.append(f"{brace:+d} unbalanced `{{`/`}}`")
    if paren:
        problems.append(f"{paren:+d} unbalanced `(`/`)`")
    if bracket:
        problems.append(f"{bracket:+d} unbalanced `[`/`]`")
    if directive_depth:
        problems.append(f"{directive_depth} unterminated `#if` block(s)")
    if in_block_comment:
        problems.append("unterminated block comment")
    if in_string or in_multiline_string:
        problems.append("unterminated string literal")
    return {"problems": problems, "brace": brace, "paren": paren, "bracket": bracket}


def main() -> int:
    targets = sys.argv[1:]
    if not targets:
        print(__doc__)
        return 1
    bad = 0
    for target in targets:
        if os.path.isdir(target):
            files = []
            for base, dirs, names in os.walk(target):
                dirs[:] = [d for d in dirs if d not in {".git", ".build"}]
                files.extend(os.path.join(base, n) for n in names if n.endswith(".swift"))
        else:
            files = [target]
        for path in sorted(files):
            result = scan(io.open(path, encoding="utf-8").read())
            if result["problems"]:
                bad += 1
                print(f"UNBALANCED {path}")
                for problem in result["problems"]:
                    print(f"    {problem}")
    print(f"{bad} file(s) with structural problems" if bad else
          f"all {len(targets)} target(s) structurally balanced")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
