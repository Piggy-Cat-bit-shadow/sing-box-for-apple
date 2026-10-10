#!/usr/bin/env python3
"""Platform facts for the Hako platform gates, each one carrying the evidence that proves it.

# Why this file exists

`swift_directives.CAN_IMPORT` is a table with a docstring, not with provenance, and its `tvos` entry is
absent entirely. A table without provenance cannot be audited: a reader can see that
`"QuickLook": True` is written down but not *why*, and the honest answer - nobody checked - is
indistinguishable from a checked one.

So every fact here is an object with a value **and** the lines of this repository that prove it. A fact that
has not been proven is **not written down at all**, and its absence is what makes a gate refuse:

    #if canImport(QuickLook)     ->  no fact for canImport(QuickLook) on tvos
        import QuickLook             ->  the file is NOT VERIFIED on tvos, not clean

That is the whole design. There is no default, no `True`, and no "assume available". A fact is either
proven, or missing, and a missing fact is a refusal rather than a guess - which is the opposite of what a
lookup table with a default does.

# The two kinds of fact, which are not the same kind of fact

  * **`canImport(Module)`** answers "does the compiler have this module on this platform". It is what the
    resolver needs to pick a branch, and it is what a guard like `#if canImport(UIKit)` is asking.
  * **A symbol's availability** answers "does this type exist here". It is *weaker* to state and *stronger*
    to use: a module can be importable while a type in it is not (`QuickLook` on macOS imports fine;
    `QLPreviewController` is not in that SDK). This file therefore proves module facts and derives symbol
    facts from them, and it says so out loud rather than pretending the derivation is a proof. When a
    symbol's framework has no proven fact, the symbol is `UNRESOLVED` and the gate refuses.

# What is deliberately *not* here

  * `canImport(QuickLook)` on macOS and tvOS. The frozen original imports QuickLook inside `#if os(iOS)`
    only (`ApplicationLibrary/Views/Tools/TaildropView.swift:7-12`) and the tvOS link check below does not
    mention it, so this repository does not state the answer either way. Left out on purpose.
  * `targetEnvironment(simulator)`. It is a fact about which SDK slice is being built, not about the
    platform, and nothing in the evaluated tree asks for it.

Both are recorded in `UNPROVEN` below so that a reader sees the gap rather than inferring it from silence.

# The target the facts are about

`ApplicationLibrary` is a `PBXFileSystemSynchronizedRootGroup` target (`project.pbxproj:1101-1127`,
`:756`), so **every** file under `ApplicationLibrary/` - including `Views/HakoStyle/` - is a member of it,
and its `SUPPORTED_PLATFORMS` is `appletvos appletvsimulator iphoneos iphonesimulator macosx`
(`project.pbxproj:2288`, `:2330`) with `TVOS_DEPLOYMENT_TARGET = 17.0` (`:2295`, `:2336`). The shared
target really is built for tvOS, whether or not this project ships a tvOS client; that is why an unknown
tvOS fact has to be reported as unverified instead of being waved through.
"""
from __future__ import annotations

import os
import re
from typing import NamedTuple

#: The platforms the shared target declares. Order is the order reports are printed in.
PLATFORM_ORDER = ("ios", "macos", "tvos")

#: The target whose `SUPPORTED_PLATFORMS` bounds the question, and the directory whose files belong to it.
SHARED_TARGET = "ApplicationLibrary"
SHARED_TARGET_EVIDENCE = (
    "sing-box.xcodeproj/project.pbxproj:2288 SUPPORTED_PLATFORMS = "
    '"appletvos appletvsimulator iphoneos iphonesimulator macosx" (ApplicationLibrary Debug; '
    "the same at :2330 Release, with TVOS_DEPLOYMENT_TARGET = 17.0 at :2295/:2336)",
    "sing-box.xcodeproj/project.pbxproj:1115-1117 fileSystemSynchronizedGroups = (ApplicationLibrary), "
    "so every file under ApplicationLibrary/ is a member of that target",
    "sing-box.xcodeproj/project.pbxproj:609-629 the only membershipException for that group is "
    "Assets.xcassets, so no Swift file is excluded",
)


class Fact(NamedTuple):
    """One proven value, with the repository lines that prove it."""

    value: bool
    evidence: tuple[str, ...]


def F(value: bool, *evidence: str) -> Fact:
    return Fact(value, tuple(evidence))


#: Facts that were looked for and deliberately left out, with the reason. Printed by `--explain` so that a
#: reader sees a known gap instead of an empty space.
UNPROVEN: dict[str, tuple[str, ...]] = {
    "canImport(QuickLook) on macos": (
        "The frozen original imports QuickLook inside `#if os(iOS)` only "
        "(`ApplicationLibrary/Views/Tools/TaildropView.swift:7-12`, whose `#elseif os(macOS)` branch "
        "imports AppKit and not QuickLook), and no macOS-only source imports it. The repository does not "
        "state whether the module is importable there.",
    ),
    "canImport(QuickLook) on tvos": (
        "`sing-box.xcodeproj/project.pbxproj:52` filters the GhosttyTerminal/GhosttyTheme build files to "
        "(ios, macos) and QuickLook appears nowhere in the project file at all, so there is no link-level "
        "statement about tvOS. `ApplicationLibrary/Views/Tools/TaildropView.swift:14` excludes upstream's "
        "whole QuickLook page on tvOS with `#if !os(tvOS)`, which is the author declining to answer for "
        "`QLPreviewController`, not a statement about the module.",
    ),
    "targetEnvironment(simulator)": (
        "True for `iphonesimulator`/`appletvsimulator` and false for the device SDKs, and the target "
        "declares both (`project.pbxproj:2288`). It selects a build slice, not a platform, so no single "
        "value is correct; nothing in the evaluated tree asks for it.",
    ),
    "symbol availability finer than module availability": (
        "A symbol fact is derived from its module's fact. That derivation is sound for the symbols in "
        "`SYMBOL_FRAMEWORK` except where a framework is importable but a type in it is not - QuickLook on "
        "macOS is the one place that matters here, and it is why `canImport(QuickLook)` is unproven there "
        "rather than being filled in.",
    ),
}


#: `canImport(Module)` -> platform -> Fact. Only proven answers are written down.
MODULE_FACTS: dict[str, dict[str, Fact]] = {
    "UIKit": {
        "ios": F(
            True,
            "ApplicationLibrary/Views/Tools/TailscalePeerView.swift:5-6 `#if os(iOS) || os(tvOS)` then "
            "`import UIKit` - the file is a member of ApplicationLibrary, which declares iphoneos "
            "(project.pbxproj:2288)",
        ),
        "macos": F(
            False,
            "ApplicationLibrary/Views/Tools/TailscalePeerView.swift:5-9 is a two-branch statement of which "
            "toolkit each platform takes: `#if os(iOS) || os(tvOS)` / `import UIKit` / `#elseif os(macOS)` "
            "/ `import AppKit`. macOS is the AppKit branch, so UIKit is not the module there.",
            "sing-box.xcodeproj/project.pbxproj:2289 SUPPORTS_MACCATALYST = NO on the same target, and "
            "`maccatalyst` is absent from SUPPORTED_PLATFORMS (:2288), so the one way macOS could see "
            "UIKit is switched off.",
        ),
        "tvos": F(
            True,
            "ApplicationLibrary/Views/Abstract/TVToolbarButton.swift:1-12 is `#if os(tvOS)`, `import "
            "UIKit`, `struct TVToolbarButton: UIViewRepresentable`, `func makeUIView(context:) -> "
            "UIButton`. The file is a member of ApplicationLibrary, whose tvOS support is declared at "
            "project.pbxproj:2288/:2295, so the tvOS slice of that target compiles this import.",
        ),
    },
    "AppKit": {
        "ios": F(
            False,
            "ApplicationLibrary/Views/Tools/TailscalePeerView.swift:5-9 - the `#elseif canImport(AppKit)` "
            "/ `#elseif os(macOS)` branches of the project's own toolkit selection are macOS-only; iOS is "
            "the UIKit branch.",
        ),
        "macos": F(
            True,
            "ApplicationLibrary/Views/Tools/TailscalePeerView.swift:8-9 `#elseif os(macOS)` then `import "
            "AppKit`, in a member of ApplicationLibrary, which declares macosx (project.pbxproj:2288).",
        ),
        "tvos": F(
            False,
            "ApplicationLibrary/Views/Tools/TailscalePeerView.swift:5-9 pairs the branches: UIKit for "
            "`os(iOS) || os(tvOS)`, AppKit for `os(macOS)`. UIKit is proven importable on tvOS "
            "(TVToolbarButton.swift:1-12), and a `#elseif` chain is a statement that the two do not hold "
            "at once.",
            "ApplicationLibrary/Views/HakoStyle/HakoSurface.swift:234-261 splits `#if os(macOS)` from "
            "`#elseif os(tvOS)` in one expression, and the macOS arm is the one that names AppKit.",
        ),
    },
    "QuickLook": {
        "ios": F(
            True,
            "ApplicationLibrary/Views/Tools/TaildropView.swift:7-9 `#if os(iOS)` / `import QuickLook` / "
            "`import UIKit` inside the ApplicationLibrary target, and :395-428 declares and uses "
            "`QLPreviewController` in that same iOS-only region - a file the iOS slice of the target "
            "compiles.",
        ),
    },
    "GhosttyTerminal": {
        "ios": F(
            True,
            "sing-box.xcodeproj/project.pbxproj:52 `GhosttyTerminal in Frameworks ... platformFilters = "
            "(ios, macos, )`, and :784 that build file is in the ApplicationLibrary frameworks phase "
            "(:1107). A module named in the target's link inputs under a platform filter that includes "
            "`ios` is importable in the iOS build.",
        ),
        "macos": F(
            True,
            "sing-box.xcodeproj/project.pbxproj:52 - the same platform filter lists `macos`, so the macOS "
            "build of ApplicationLibrary links it too. That is why upstream's terminal pages are guarded "
            "`canImport(GhosttyTerminal) && os(iOS)`: the module is there on macOS and the *page* is not.",
        ),
        "tvos": F(
            False,
            "sing-box.xcodeproj/project.pbxproj:52 `platformFilters = (ios, macos, )` - `tvos` is absent, "
            "so the tvOS build of ApplicationLibrary (:2288) does not link this module and `import "
            "GhosttyTerminal` cannot succeed there. Assumption stated rather than hidden: an SPM product "
            "excluded from a target's link inputs by platform filter is not importable in that platform's "
            "build of it.",
            "sing-box.xcodeproj/project.pbxproj:2766/:2802 TVExtension is `appletvos appletvsimulator` "
            "only, and the GhosttyTerminal product (:4174-4177, `libghostty-spm`) is not among its inputs.",
        ),
    },
}

#: `targetEnvironment(X)` -> platform -> Fact. Only proven answers are written down.
TARGET_ENVIRONMENT_FACTS: dict[str, dict[str, Fact]] = {
    "macCatalyst": {
        "ios": F(
            False,
            "sing-box.xcodeproj/project.pbxproj:2289 SUPPORTS_MACCATALYST = NO on the ApplicationLibrary "
            "target whose iOS slice is what this fact is about; `maccatalyst` is also absent from "
            "SUPPORTED_PLATFORMS at :2288.",
        ),
        "macos": F(
            False,
            "sing-box.xcodeproj/project.pbxproj:2288 - the macOS slice is plain `macosx`; a Catalyst "
            "binary is an iOS-slice product and is switched off at :2289.",
        ),
        "tvos": F(
            False,
            "sing-box.xcodeproj/project.pbxproj:2288 - `appletvos`/`appletvsimulator` are native tvOS "
            "SDKs; Catalyst is an iOS/Mac concept and is off at :2289 regardless.",
        ),
    },
}

#: Symbol -> the module that provides it. The symbol's availability is derived from the module's proven
#: fact; see the module docstring for why that derivation is stated rather than assumed.
SYMBOL_FRAMEWORK: dict[str, str] = {
    "UIFont": "UIKit",
    "UIFontDescriptor": "UIKit",
    "UIColor": "UIKit",
    "UIImage": "UIKit",
    "UIApplication": "UIKit",
    "UIButton": "UIKit",
    "UIView": "UIKit",
    "UIViewController": "UIKit",
    "UINavigationController": "UIKit",
    "UIWindowScene": "UIKit",
    "UIViewRepresentable": "UIKit",
    "UIViewControllerRepresentable": "UIKit",
    "UIActivityViewController": "UIKit",
    "UIBlurEffect": "UIKit",
    "UIVisualEffectView": "UIKit",
    "NSFont": "AppKit",
    "NSFontManager": "AppKit",
    "NSColor": "AppKit",
    "NSView": "AppKit",
    "NSViewRepresentable": "AppKit",
    "NSWindow": "AppKit",
    "NSViewController": "AppKit",
    "QLPreviewController": "QuickLook",
    "QLPreviewControllerDataSource": "QuickLook",
    "QLPreviewItem": "QuickLook",
    "TailsshTerminalSelectionViewController": "GhosttyTerminal",
    "TailsshTerminalSurfaceView": "GhosttyTerminal",
    "TerminalWrapperViewModel": "GhosttyTerminal",
    "TerminalSessionManager": "GhosttyTerminal",
    "TerminalSessionMenuButton": "GhosttyTerminal",
    "TerminalTextSelectionRequest": "GhosttyTerminal",
    # Not type names but just as platform-exclusive: SwiftUI's `Color` initialisers that take a toolkit
    # colour object. `Color(uiColor:)` needs UIKit, `Color(nsColor:)` needs AppKit, and the frozen original
    # states the pairing itself, which is the evidence recorded below.
    "uiColor": "UIKit",
    "nsColor": "AppKit",
}

#: Evidence for a symbol whose proof is not simply its module's. A symbol's availability is derived from
#: its module's fact by default; these are the entries where the repository states something more specific.
SYMBOL_EVIDENCE: dict[str, tuple[str, ...]] = {
    "TailsshTerminalSelectionViewController": (
        "Provided by the optional GhosttyTerminal module. Every file that names it is inside "
        "`#if canImport(GhosttyTerminal) ...`, e.g. "
        "ApplicationLibrary/Views/HakoStyle/HakoTerminalSessionContainerView.swift:28.",
    ),
    "TailsshTerminalSurfaceView": (
        "Declared at ApplicationLibrary/Views/Terminal/TailsshTerminalSurfaceView.swift:1 under "
        "`#if canImport(GhosttyTerminal)`, in the same target, so the name exists exactly where that "
        "module does.",
    ),
    "TerminalWrapperViewModel": (
        "Declared at ApplicationLibrary/Views/Terminal/TerminalWrapperViewModel.swift:1 under "
        "`#if canImport(GhosttyTerminal)`, in the same target.",
    ),
    "TerminalSessionManager": (
        "Declared at ApplicationLibrary/Views/Terminal/TerminalSessionManager.swift:1 under "
        "`#if canImport(GhosttyTerminal) && os(iOS)`.",
    ),
    "TerminalSessionMenuButton": (
        "Declared at ApplicationLibrary/Views/Terminal/TerminalSessionMenuButton.swift:1 under "
        "`#if canImport(GhosttyTerminal) && os(iOS)`.",
    ),
    "TerminalTextSelectionRequest": (
        "Provided by the optional GhosttyTerminal module; its only mention in the shared target is at "
        "ApplicationLibrary/Views/HakoStyle/HakoTerminalSessionContainerView.swift:114, inside "
        "`#if canImport(GhosttyTerminal) && os(iOS)`.",
    ),
    "uiColor": (
        "up-hako@c1935cf ApplicationLibrary/Views/Terminal/TerminalSessionContentView.swift:16-22 - the "
        "original writes `#if os(iOS)` / `Color(uiColor: .systemBackground)` / `#elseif os(macOS)` / "
        "`Color(nsColor: .windowBackgroundColor)` / `#endif`, its own statement that each initialiser "
        "belongs to one toolkit. The same split appears at "
        "up-hako@c1935cf ApplicationLibrary/Views/Groups/GroupItemView.swift:84-92.",
    ),
    "nsColor": (
        "up-hako@c1935cf ApplicationLibrary/Views/Terminal/TerminalSessionContentView.swift:16-22, the "
        "macOS arm of the same `#if`.",
    ),
}

#: The namespaces `swift_directives.evaluate` consults a table for.
_DIRECTIVES_TABLE = {"canImport": MODULE_FACTS, "targetEnvironment": TARGET_ENVIRONMENT_FACTS}


class Undecidable(Exception):
    """A condition that this file has no proven fact for."""

    def __init__(self, condition: str, platform: str, reason: str) -> None:
        super().__init__(f"{condition} on {platform}: {reason}")
        self.condition = condition
        self.platform = platform
        self.reason = reason


def proven_table(namespace: str, platform: str) -> dict[str, bool]:
    """The proven `name -> value` entries for one directive namespace and platform."""
    table = _DIRECTIVES_TABLE[namespace]
    return {name: per[platform].value for name, per in table.items() if platform in per}


def evidence_for(namespace: str, name: str, platform: str) -> tuple[bool, tuple[str, ...]] | None:
    fact = _DIRECTIVES_TABLE[namespace].get(name, {}).get(platform)
    return None if fact is None else (fact.value, fact.evidence)


def install_into(directives) -> list[str]:
    """Point `swift_directives` at these facts, and report what that changed.

    The tables are **replaced**, not extended. Extending would leave the old, unproven entries in place -
    `NetworkExtension: True` written down with no evidence - and a gate that keeps an unproven entry is a
    gate that can decide something nobody checked. Replacing means an unproven `canImport` reaches
    `swift_directives.evaluate`, which raises, which is the refusal this module exists to produce.

    Returns one human-readable line per platform, for the report.
    """
    notes: list[str] = []
    for platform in PLATFORM_ORDER:
        modules = proven_table("canImport", platform)
        environments = proven_table("targetEnvironment", platform)
        directives.CAN_IMPORT[platform] = modules
        directives.TARGET_ENVIRONMENT[platform] = environments
        notes.append(
            f"{platform}: {len(modules)} canImport fact(s) ({', '.join(sorted(modules)) or 'none'}), "
            f"{len(environments)} targetEnvironment fact(s) ({', '.join(sorted(environments)) or 'none'})"
        )
    return notes


def symbol_availability(symbol: str, platform: str) -> tuple[bool | None, str, tuple[str, ...]]:
    """Whether `symbol` exists on `platform`: (True/False/None=unresolved, framework, evidence)."""
    framework = SYMBOL_FRAMEWORK.get(symbol)
    if framework is None:
        return None, "?", ()
    fact = MODULE_FACTS.get(framework, {}).get(platform)
    if fact is None:
        return None, framework, SYMBOL_EVIDENCE.get(symbol, ())
    return fact.value, framework, SYMBOL_EVIDENCE.get(symbol, fact.evidence)


#: `#if canImport(M)` / `#else` / `#endif` whose every branch body is only `import M` (or a submodule of
#: M) and comments. Such a region is legal whichever way the condition goes, so the tool does not need a
#: platform fact to answer its own question about it - and that is a proof about the *shape*, not an
#: assumption about the platform. Kept deliberately narrow: the condition must be exactly `canImport(M)`.
_SAFE_CONDITION = re.compile(r"canImport\((\w+)\)")
_SAFE_IMPORT = re.compile(r"import\s+([\w.]+)\s*$")
_SAFE_DIRECTIVE = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")


def self_guarded_import_blocks(text: str) -> dict[int, str]:
    """Line number -> module, for every `#if canImport(M) ... import M ... #endif` that is safe by shape.

    `#if canImport(M)` guarding `import M` and nothing else compiles on every platform: when the module is
    there the import happens, when it is not the branch is gone. No platform fact is required to know that,
    so a gate that reports it as an unresolved symbol would be reporting a gap in its own table as if it
    were a gap in the source.
    """
    lines = text.split("\n")
    safe: dict[int, str] = {}
    index = 0
    while index < len(lines):
        match = _SAFE_DIRECTIVE.match(lines[index])
        if not match or match.group(1) != "if":
            index += 1
            continue
        condition = _SAFE_CONDITION.fullmatch(match.group(2).strip())
        if condition is None:
            index += 1
            continue
        module = condition.group(1)
        depth = 1
        body: list[str] = []
        cursor = index + 1
        while cursor < len(lines) and depth:
            inner = _SAFE_DIRECTIVE.match(lines[cursor])
            if inner:
                if inner.group(1) == "if":
                    depth += 1
                elif inner.group(1) == "endif":
                    depth -= 1
                    if depth == 0:
                        break
                body.append(lines[cursor])
            else:
                body.append(lines[cursor])
            cursor += 1
        if depth == 0 and _block_is_only_imports_of(module, body):
            safe[index + 1] = module
        index = cursor + 1
    return safe


def _block_is_only_imports_of(module: str, body: list[str]) -> bool:
    saw_import = False
    for line in body:
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
            continue
        if _SAFE_DIRECTIVE.match(line):
            # Nested `#else`/`#endif` is fine only for a two-branch chain that does the same import; a
            # nested `#if` is not this shape, so refuse rather than reason about it.
            keyword = _SAFE_DIRECTIVE.match(line).group(1)
            if keyword in ("else", "endif", "elseif"):
                if keyword == "elseif":
                    return False
                continue
            return False
        imported = _SAFE_IMPORT.match(stripped)
        if imported is None:
            return False
        name = imported.group(1)
        if name != module and not name.startswith(module + "."):
            return False
        saw_import = True
    return saw_import


# --------------------------------------------------------------------------------------------------
# Line-preserving resolution.
#
# `swift_directives.resolve` returns text with runs of blank lines collapsed, so a line number taken from
# its output does not point at the line in the file. This resolves the same directives with the same
# semantics but keeps (original_line_number, text) pairs, and `test_platform_gates.py` asserts the two
# agree line-for-line on every evaluated file, so the mapping cannot drift unnoticed.
# --------------------------------------------------------------------------------------------------

_DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")


def _mentions_build_flag(condition: str, build_flags: tuple[str, ...]) -> bool:
    return any(re.search(rf"\b{flag}\b", condition) for flag in build_flags)


def resolve_lines(text: str, platform: str, directives) -> list[tuple[int, str]]:
    """`[(original_line_number, text)]` for the lines that survive resolution on `platform`.

    Semantics are `swift_directives.resolve`'s: platform conditions are decided with the proven facts,
    build-flag conditions are preserved verbatim with their branches, and anything undecidable raises
    `swift_directives.DirectiveError`. Blank-line collapsing is intentionally not applied.
    """
    lines = text.split("\n")
    directives.assert_balanced(lines)

    stack: list[dict] = []
    out: list[tuple[int, str]] = []

    for number, line in enumerate(lines, 1):
        match = _DIRECTIVE.match(line)
        if not match:
            if all(frame["active"] or frame["verbatim"] for frame in stack):
                out.append((number, line))
            continue

        keyword, condition = match.group(2), match.group(3)
        enclosing_live = all(frame["active"] or frame["verbatim"] for frame in stack)
        keep = False

        if keyword == "if":
            if not enclosing_live:
                frame = {"taken": False, "active": False, "verbatim": False, "dead": True}
            elif _mentions_build_flag(condition, directives.BUILD_FLAGS):
                frame = {"taken": True, "active": False, "verbatim": True, "dead": False}
            else:
                decided = directives.evaluate(condition, platform)
                frame = {"taken": decided, "active": decided, "verbatim": False, "dead": False}
            stack.append(frame)
            keep = frame["verbatim"] and enclosing_live
        elif keyword == "elseif":
            frame = stack[-1]
            if not frame["dead"] and not frame["verbatim"]:
                decided = (not frame["taken"]) and directives.evaluate(condition, platform)
                frame["active"] = decided
                frame["taken"] = frame["taken"] or decided
            keep = frame["verbatim"] and enclosing_live
        elif keyword == "else":
            frame = stack[-1]
            if not frame["dead"] and not frame["verbatim"]:
                frame["active"] = not frame["taken"]
                frame["taken"] = True
            keep = frame["verbatim"] and enclosing_live
        else:
            frame = stack.pop()
            keep = frame["verbatim"] and enclosing_live

        if keep:
            out.append((number, line))

    return out


def reachable_regions(text: str, platform: str, directives) -> tuple[list[tuple[int, str]], dict[int, str]]:
    """Resolve `text` for `platform`, treating self-guarded imports as decided.

    Returns the surviving lines and the `{line: module}` map of `#if canImport(M) import M` blocks whose
    condition had no proven fact but whose shape is unconditionally legal. Those blocks are removed from
    the surviving text: they contribute no symbol the gates look at, and leaving them in would make every
    file with an optional-framework import unverifiable on every platform where the framework has no fact.
    """
    safe = self_guarded_import_blocks(text)
    if not safe:
        return resolve_lines(text, platform, directives), {}

    # The whole span - `#if`, body and `#endif` - is blanked, not just the directive line. Blanking the
    # `#if` alone would leave a stray `#endif` and `assert_balanced` would (correctly) refuse the file.
    covered = _covered_lines(text, safe)
    lines = text.split("\n")
    blanked = ["" if number in covered else line for number, line in enumerate(lines, 1)]
    kept = resolve_lines("\n".join(blanked), platform, directives)
    return [(number, line) for number, line in kept if number not in covered], safe


def _covered_lines(text: str, safe: dict[int, str]) -> set[int]:
    lines = text.split("\n")
    covered: set[int] = set()
    for start in safe:
        depth = 0
        for number in range(start, len(lines) + 1):
            covered.add(number)
            # `_SAFE_DIRECTIVE`, not `_DIRECTIVE`: both capture the keyword, but only this one does so in
            # group 1, and reading the indent group by mistake made `#endif` look like a non-directive, so
            # the span never closed and the rest of the file was blanked. That is the shape of bug this
            # whole tool exists to catch, so it has a named regression case in `test_platform_gates.py`.
            match = _SAFE_DIRECTIVE.match(lines[number - 1])
            if match:
                if match.group(1) == "if":
                    depth += 1
                elif match.group(1) == "endif":
                    depth -= 1
                    if depth == 0:
                        break
    return covered


def hako_directories(root: str) -> list[str]:
    return [os.path.join(root, SHARED_TARGET, "Views", "HakoStyle")]
