#!/usr/bin/env python3
"""Port the phone's Tools and More pages from `hako-ui` @ `c1935cf`.

# What this script is, and what it is not

It is a **migration tool**. It is not the authority on the phone's UI: `hako-ui@c1935cf` is. Everything
it writes is a mechanical transform of that commit's blobs, and every transform is in the tables below
where it can be read and argued with.

# The three things the first version got wrong

  1. **It read a moving ref.** `origin/hako-ui` is a branch; a branch moves. The input is now the
     pinned commit, asserted on every run, so a future fetch cannot silently change what is ported.
  2. **It copied the fork's platform conditionals unresolved.** The fork's files build for iPhone,
     iPad, macOS and tvOS; the phone's copies are iPhone-only, so a `#if os(macOS)` block is dead code
     in them.
  3. **It copied the fork's copies of shared declarations.** The fork's `SettingView.swift` predates
     upstream adding the same file - `2b1763a..089d35e` is 43 commits and the file was added inside
     them - so the fork's file *is* the old upstream file plus the fork's changes, and its
     `public enum SettingsPage` and `Notification.Name.navigateToSettingsPage` travelled into the Hako
     namespace beside upstream's. Two declarations of one module-scope name is a compile error.

Point 3 is why `DROP_DECLARATIONS` exists and why it is not a heuristic: the declaration is removed
**only** when the same name is independently found in the shared tree, and the script fails if the name
it was told to drop is not there. A future upstream rename makes this script stop, not silently produce
a file that declares the shared type twice again.

Usage:
    python port_tools_and_more.py --check        # report only; writes nothing
    python port_tools_and_more.py                # compare; fail if a file differs
    python port_tools_and_more.py --regenerate   # write
"""
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

#: **The** reference. A branch name is not a pin: `origin/hako-ui` can be advanced by a fetch, and a
#: port that silently changes its input is not reproducible. This is asserted on every run.
FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"

#: The phone's copies are iPhone-only, so this is the platform their conditionals are resolved for.
PLATFORM = "ios"

HEADER = '''//
//  {name}.swift
//  ApplicationLibrary
//
//  The phone's {page} page, from `hako-ui` @ `{fork_ref_short}`.
//
//  # Why this is a copy rather than a wrapper
//
//  The reference's change is a rewrite of the page rather than a decoration of it: `{upstream_name}.swift`
//  is {upstream_lines} lines upstream and {fork_lines} in the reference, and the reference version is the
//  page. A wrapper would have had to reimplement it anyway.
//
//  So the page lives here, in the fork's own namespace, reachable only from the phone. Upstream's
//  `{upstream_path}` stays upstream's, which is
//  what keeps an iPad and a Mac on upstream's presentation.
//
//  # What is deliberately not here
//
//  The pages this one leads to. Every one of them is still upstream's: the reference's change to each
//  is a single modifier or a single row, and the page a user lands on is what this slice delivers.
//  The list, with what each needs, is in `docs/HAKO-LOSSLESS-PARITY-AUDIT.md`.
//
//  Generated from `{fork_ref_short}` by `scripts/dev/port_tools_and_more.py`. That script resolves the
//  reference's platform conditionals for iPhone and drops the declarations the shared tree already
//  owns; re-run it rather than editing here, or the next run will disagree with this file.
//

'''

PAGES = (
    {
        "label": "Tools",
        "page": "Tools",
        "source": "ApplicationLibrary/Views/Tools/ToolsView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoToolsView.swift",
        "renames": (("ToolsView", "HakoToolsView"),),
        "upstream_name": "ToolsView",
        "drop_declarations": (),
    },
    {
        "label": "More",
        "page": "More",
        "source": "ApplicationLibrary/Views/Setting/SettingView.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoSettingView.swift",
        "renames": (
            ("SettingView", "HakoSettingView"),
            ("HakoSettingsPush", "HakoSettingsRoute"),
            ("PendingSettingsPageKey", "HakoPendingSettingsPageKey"),
            ("SettingsGroup", "HakoSettingsSectionGroup"),
            ("Destination", "HakoSettingsDestination"),
            ("Decision", "HakoSettingsPushDecision"),
        ),
        "upstream_name": "SettingView",
        # Each of these is declared by upstream's own `Setting/SettingView.swift`, which the phone does
        # not replace. `SettingsPage` is the shared model and the notification carries one, so keeping
        # a second copy here would make the phone observe a different type from the one posted to it -
        # and two declarations of it is a compile error either way. The fork's copies exist only because
        # its file predates upstream's.
        #
        # `settingsNavigationPath` needs no entry: it is inside `#if os(macOS)`, which the iOS
        # resolution removes before this step runs.
        "drop_declarations": (
            ("public enum SettingsPage: Hashable {", "SettingsPage"),
            ("public extension Notification.Name {", "Notification.Name.navigateToSettingsPage"),
        ),
        # Dropping the fork's enum means the ported file now switches over *upstream's*, which has one
        # case the fork's did not: `.sponsors`. A `switch` that was exhaustive over six cases is not
        # exhaustive over seven, and this one has no `default`.
        #
        # This adds an arm to an internal string mapping. It adds **no row**: the phone's destination
        # list is the fork's, and nothing constructs a `.sponsors` page from it. Whether the phone
        # should show a Sponsors row is the user's decision, not this migration's.
        "completions": (
            ("""    var settingsKey: String {
        switch self {""",
             """        case .remoteControl: "remoteControl"
        }
    }""",
             """        case .remoteControl: "remoteControl"
        case .sponsors: "sponsors"
        }
    }""",
             "the switch now covers upstream's seventh case, which the fork's enum did not have"),
        ),
    },
)


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: "
                         f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def assert_pinned_ref() -> None:
    """The input is a commit, not a branch, and it is the commit this port was written against."""
    resolved = git("rev-parse", f"{FORK_REF}^{{commit}}").strip()
    if resolved != FORK_REF:
        raise SystemExit(f"FAILED: {FORK_REF} resolved to {resolved}")
    # The branch must still be a descendant of, or equal to, the pin - otherwise this script is
    # reading a commit that the fork's own history no longer contains and something is wrong upstream.
    proc = subprocess.run([GIT, "-C", REPO, "merge-base", "--is-ancestor", FORK_REF, "origin/hako-ui"],
                          capture_output=True)
    if proc.returncode != 0:
        print(f"    NOTE: {FORK_REF[:7]} is not an ancestor of origin/hako-ui; the pin still stands")


def shared_tree_names() -> set[str]:
    """Module-scope names the shared tree already declares, so a ported copy of one is a duplicate."""
    names: set[str] = set()
    pattern = re.compile(r"^(?:public[ \t]+|internal[ \t]+)?(?:struct|class|enum|protocol)\s+(\w+)", re.M)
    extension = re.compile(r"^(?:public[ \t]+)?extension\s+([\w.]+)\s*\{", re.M)
    member = re.compile(r"^[ \t]{1,4}(?:public[ \t]+|internal[ \t]+)?static[ \t]+(?:var|let|func)\s+(\w+)", re.M)
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", ".build", ".swiftpm", "build")]
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            if "HakoStyle" in path:
                continue
            text = open(path, encoding="utf-8", errors="replace").read()
            names |= set(pattern.findall(text))
            for type_name, body in re.findall(
                    r"^(?:public[ \t]+)?extension\s+([\w.]+)\s*\{(.*?)^\}", text, re.M | re.S):
                for found in member.findall(body):
                    names.add(f"{type_name}.{found}")
    return names


def find_declaration_span(text: str, opener: str) -> tuple[int, int]:
    """Line span of a brace-balanced declaration that begins with `opener` at column 0."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if line.startswith(opener)]
    if len(starts) != 1:
        raise SystemExit(f"FAILED: {opener!r} starts {len(starts)} declarations, expected 1")
    start = starts[0]
    depth = 0
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if depth == 0 and index > start:
            return start, index
        if depth == 0 and index == start and lines[index].rstrip().endswith("}"):
            return start, index
    raise SystemExit(f"FAILED: unbalanced declaration starting at {opener!r}")


def verify_swift_parses(text: str, label: str) -> None:
    """Structural check. Not a compiler: it catches the failure modes this transform can produce."""
    if text.count("{") != text.count("}"):
        raise SystemExit(f"FAILED [{label}]: braces unbalanced")
    if text.count("(") != text.count(")"):
        raise SystemExit(f"FAILED [{label}]: parentheses unbalanced")
    depth = 0
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            depth += 1
        elif stripped.startswith("#endif"):
            depth -= 1
            if depth < 0:
                raise SystemExit(f"FAILED [{label}]: #endif without #if at line {number}")
        elif stripped.startswith(("#else", "#elseif")) and depth == 0:
            raise SystemExit(f"FAILED [{label}]: #{stripped.split()[0][1:]} outside #if at line {number}")
    if depth != 0:
        raise SystemExit(f"FAILED [{label}]: {depth} unterminated #if block(s)")


def port(page: dict, shared: set[str]) -> str:
    source = git("show", f"{FORK_REF}:{page['source']}")
    upstream = git("show", f"jiejiebox/integrated:{page['source']}")

    # 1. Resolve the reference's platform conditionals for the phone. The fork's file builds for four
    #    platforms; this copy builds for one, and a branch for another is dead code that can also carry
    #    a duplicate declaration.
    text = resolve(source, PLATFORM)
    print(f"    resolved for {PLATFORM}: {len(source.splitlines())} -> {len(text.splitlines())} lines")

    # 2. Rename, longest key first so a shorter name is not replaced inside a longer one.
    for old, new in sorted(page["renames"], key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise SystemExit(f"FAILED [{page['label']}]: {old!r} appears nowhere in the source")
        print(f"    {old} -> {new} ({count})")

    # 3. Drop declarations the shared tree owns. Removing one that is not there is a failure, because
    #    it means the reference moved and this table is stale - and a stale table is how the duplicate
    #    came back last time.
    for opener, qualified in page["drop_declarations"]:
        start, end = find_declaration_span(text, opener)
        # The name has to be one the shared tree actually declares, or the entry is a guess.
        base = qualified.split(".")[-1]
        if qualified in shared or base in shared:
            print(f"    drop {qualified}: shared tree owns it (lines {start + 1}-{end + 1})")
        else:
            raise SystemExit(
                f"FAILED [{page['label']}]: {qualified!r} is not declared in the shared tree, so "
                f"dropping it here would remove the only definition")
        lines = text.split("\n")
        del lines[start:end + 1]
        text = "\n".join(lines)

    # 4. Apply the completions. Each is a two-anchor replacement: the first anchor proves the edit is
    #    going into the declaration it was written for, the second is the exact text replaced. A
    #    completion whose anchor is absent is a failure, so the table cannot rot silently.
    for anchor, old, new, why in page.get("completions", ()):
        if anchor not in text:
            raise SystemExit(
                f"FAILED [{page['label']}]: completion anchor not found; the reference moved and this "
                f"table is stale - {anchor.splitlines()[0]!r}")
        if text.count(old) != 1:
            raise SystemExit(
                f"FAILED [{page['label']}]: completion target appears {text.count(old)} times, "
                f"expected 1")
        text = text.replace(old, new, 1)
        print(f"    completion: {why}")

    text = re.sub(r"\A(?://[^\n]*\n)+", "", text)
    text = HEADER.format(
        name=os.path.basename(page["destination"])[:-len(".swift")],
        page=page["page"],
        fork_ref_short=FORK_REF[:7],
        upstream_name=page["upstream_name"],
        upstream_lines=len(upstream.splitlines()),
        fork_lines=len(source.splitlines()),
        upstream_path=page["source"],
    ) + text

    verify_swift_parses(text, page["label"])
    return text


def main() -> int:
    check_only = "--check" in sys.argv
    regenerate = "--regenerate" in sys.argv
    assert_pinned_ref()
    shared = shared_tree_names()
    print(f"    pin {FORK_REF[:7]}; shared tree declares {len(shared)} module-scope names")

    for page in PAGES:
        print(f"  [{page['label']}]")
        destination = os.path.join(ROOT, page["destination"].replace("/", os.sep))
        text = port(page, shared)
        if check_only:
            continue
        if os.path.exists(destination) and not regenerate:
            current = io.open(destination, encoding="utf-8").read()
            if current != text:
                print("    differs from what this script would write; pass --regenerate",
                      file=sys.stderr)
                return 1
            print(f"    unchanged ({len(text.splitlines())} lines)")
            continue
        io.open(destination, "w", encoding="utf-8", newline="").write(text)
        print(f"    wrote {os.path.relpath(destination, ROOT)}: {len(text.splitlines())} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
