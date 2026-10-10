#!/usr/bin/env python3
"""Repair the provenance line in every generated `HakoStyle/Hako*.swift` header.

`retarget`'s pattern matches `Name.` as well as `Name(`, so running the generator over one page rewrote
the *tool's own comment* in other files: the header's `ApplicationLibrary/Views/Tools/CrashReportListView.swift`
became `…/Tools/HakoCrashReportListView.swift`, a path that has never existed at the pin. 29 of the 33
headers that name a source path name a wrong one, so the comment that is supposed to let a reader check the
port against its original cannot be used for that.

The true source is not re-derived from the header (which is the thing that is wrong). It is **identified by
content**: the ported file is the original with `Hako` prefixes and the declared renames applied, so the
original is the file at the pin whose stripped token stream is the closest match. Candidates are then
confirmed by requiring that the ported file's first declared `Hako…` type is `Hako` plus the original's own
first module-scope type - which is what the rename actually does.

Only the one `copy of \`…\`` path is rewritten. Nothing else in any file is touched.
"""
from __future__ import annotations

import difflib
import io
import os
import re
import subprocess
import sys

GIT = os.environ.get("DSH_GIT") or r"C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe"
REPO = os.environ.get("DSH_REPO") or r"C:\Deepseek\IOS客户端\sing-box-for-apple"
REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
APPLY = "--apply" in sys.argv

HEADER_PATH = re.compile(r"(copy of `)([^`]+)(`)")
TYPE_DECL = re.compile(r"^[ \t]*(?:(?:public|internal|final|indirect|@\w+)[ \t]+)*"
                       r"(?:struct|class|enum|actor)\s+(\w+)", re.M)


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    return proc.stdout.decode("utf-8", "replace")


def original_paths() -> list[str]:
    """Every `.swift` file under `ApplicationLibrary/Views` at the pin."""
    out = git("ls-tree", "-r", "--name-only", REF, "--", "ApplicationLibrary/Views")
    return [line for line in out.splitlines() if line.endswith(".swift")]


def strip_noise(text: str) -> str:
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return " ".join(text.split())


def first_module_type(text: str) -> str | None:
    """The first type declared at brace depth 0, ignoring private/fileprivate declarations."""
    without = re.sub(r"//[^\n]*", "", text)
    without = re.sub(r"/\*.*?\*/", "", without, flags=re.S)
    depth = 0
    for line in without.split("\n"):
        match = TYPE_DECL.match(line)
        if match and depth == 0 and not re.search(r"\b(?:private|fileprivate)\b", line):
            return match.group(1)
        depth += line.count("{") - line.count("}")
    return None


def best_source(ported: str, candidates: list[str], cache: dict[str, str]) -> tuple[str | None, float]:
    """The original whose text, with `Hako` stripped, is most similar to the ported file."""
    target = strip_noise(ported.replace("Hako", ""))
    best, best_ratio = None, 0.0
    for path in candidates:
        if path not in cache:
            cache[path] = strip_noise(git("show", f"{REF}:{path}").replace("Hako", ""))
        ratio = difflib.SequenceMatcher(None, target, cache[path], autojunk=False).quick_ratio()
        if ratio > best_ratio:
            best, best_ratio = path, ratio
    return best, best_ratio


def main() -> int:
    directory = os.path.join(ROOT, "ApplicationLibrary", "Views", "HakoStyle")
    candidates = original_paths()
    cache: dict[str, str] = {}
    repaired, unresolved, already = [], [], []

    for name in sorted(os.listdir(directory)):
        if not name.endswith(".swift"):
            continue
        full = os.path.join(directory, name)
        text = io.open(full, encoding="utf-8").read()
        match = HEADER_PATH.search(text)
        if not match:
            continue
        stated = match.group(2)
        if subprocess.run([GIT, "-C", REPO, "cat-file", "-e", f"{REF}:{stated}"],
                          capture_output=True).returncode == 0:
            already.append((name, stated))
            continue

        best, ratio = best_source(text, candidates, cache)
        # Confirm structurally, not just by similarity: the port's first Hako type must be `Hako` plus the
        # candidate's own first module-scope type.
        declared = first_module_type(text)
        if best is None or not declared or not declared.startswith("Hako"):
            unresolved.append((name, stated, best, ratio, "no Hako type to confirm against"))
            continue
        base = declared[len("Hako"):]
        confirmed = f"{os.path.dirname(best)}/{base}.swift"
        if confirmed not in candidates:
            # The candidate whose basename matches the stripped type name is the structural answer.
            by_name = [p for p in candidates if os.path.basename(p) == f"{base}.swift"]
            if len(by_name) == 1:
                confirmed = by_name[0]
            elif ratio >= 0.95 and best not in {c[1] for c in repaired}:
                # A port whose **last** module-scope type was renamed rather than its first: the file's
                # first declaration is named after the original file, but the similarity is high enough to
                # leave no doubt, and the candidate is recorded so the same path cannot be claimed twice.
                # The two files this covers are `HakoConnectionView.swift` (0.989 vs `ConnectionView.swift`)
                # and `HakoOutboundPickerView.swift` (0.980 vs `OutboundPickerView.swift`); both name a
                # source that exists at the pin, which the header did not.
                confirmed = best
            else:
                unresolved.append((name, stated, best, ratio,
                                   f"{len(by_name)} candidate(s) named {base}.swift and similarity "
                                   f"{ratio:.3f} is below the confirmation threshold"))
                continue
        repaired.append((name, stated, confirmed, ratio))
        if APPLY:
            io.open(full, "w", encoding="utf-8", newline="").write(
                text[:match.start(2)] + confirmed + text[match.end(2):])

    print(f"headers naming a source path : {len(already) + len(repaired) + len(unresolved)}")
    print(f"  already correct            : {len(already)}")
    print(f"  corrected                  : {len(repaired)}")
    print(f"  could not be resolved      : {len(unresolved)}")
    for name, stated, confirmed, ratio in repaired:
        print(f"    {name}")
        print(f"        stated    {stated}")
        print(f"        source    {confirmed}   (similarity {ratio:.3f})")
    for name, stated, best, ratio, why in unresolved:
        print(f"    UNRESOLVED {name}: stated {stated}; best guess {best} ({ratio:.3f}); {why}")
    print()
    print("applied" if APPLY else "dry run - pass --apply to write")
    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
