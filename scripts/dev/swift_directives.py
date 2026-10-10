#!/usr/bin/env python3
"""Resolve a Swift file's conditional compilation for one platform, preserving build-flag branches.

# Two kinds of condition, and only one of them may be decided here

  * **Platform conditions** - `os(...)`, `canImport(...)` - are decided. The phone's page is built for
    iOS, so `#if os(macOS)` is dead code, and copying dead code is how `SettingsPage` and
    `navigateToSettingsPage` came to exist twice at module scope: the fork's `SettingView.swift`
    predates upstream adding the same file, so its copy of the shared declarations travelled into the
    Hako namespace with it.
  * **Build-configuration conditions** - `JAILBREAK`, `DEBUG` - are **preserved verbatim, with their
    branches**. They do not select a platform; they select a build, and the iPhone target is built both
    ways. Resolving `JAILBREAK` to either value would silently delete or add a visible row
    (`JailbreakView`) depending on which value was guessed. The whole `#if JAILBREAK / #elseif DEBUG /
    #else` chain is carried across as it stands for the compiler to decide.

# Why the resolver decides a branch as a unit

Deleting the `#if os(macOS)` line leaves its `#else` body dangling, which is a syntax error in the
generated file and can silently promote the wrong branch. So the directive structure is asserted before
anything is decided, and a condition the evaluator does not understand is a **failure** rather than a
guess: guessing picks a branch, and picking the wrong branch changes the UI.

# Two gates, and which one a generator must use

  * `resolve(text, platform)` - the **resolved** gate. Decides every platform condition and deletes the
    directives, leaving what the file looks like on one platform. Correct for a file that only ever builds
    for that platform. Its behaviour is unchanged and the audits that consume it still measure the same
    thing.
  * `preserve(text, platform)` - the **shared** gate. Deletes nothing, keeps every `#if`/`#elseif`/`#else`
    chain, and refuses if any condition cannot be decided. Required for anything written into
    `ApplicationLibrary/`, which is one synchronized source group feeding the iOS, macOS **and** tvOS
    targets, so a guard the original had is a guard the copy needs.

A platform the evaluator has no table for is refused by `evaluate` itself, before any condition is even
parsed - see `PLATFORMS` for why `tvos` is deliberately absent rather than guessed.
"""
from __future__ import annotations

import re

#: `canImport` answers for the platform being resolved. A module that is genuinely absent must be listed
#: as False rather than defaulted: a wrong True keeps a block that will not compile, a wrong False drops
#: UI. A module that is not in the table raises, so it is added deliberately.
#:
#: `GhosttyTerminal` is an optional xcframework under `Frameworks/`, and the shared tree guards every
#: terminal file with `canImport(GhosttyTerminal)`. Several of those guards also require `os(iOS)` -
#: `TerminalSessionContainerView`, `TerminalSessionManager`, `TerminalSessionMenuButton` - so on iOS the
#: framework is expected to be present and `canImport` answers true. Answering False would silently drop
#: the terminal UI from every ported copy, which is the failure this table's "add it deliberately" rule
#: exists to force someone to look at.
CAN_IMPORT = {
    "ios": {"UIKit": True, "AppKit": False, "Cocoa": False, "SwiftUI": True, "Combine": True,
            "NetworkExtension": True, "WidgetKit": True, "ActivityKit": True, "Charts": True,
            "AVFoundation": True, "CoreImage": True, "Security": True, "QuickLook": True,
            "UniformTypeIdentifiers": True, "OSLog": True, "StoreKit": True},
    "macos": {"UIKit": False, "AppKit": True, "Cocoa": True, "SwiftUI": True, "Combine": True,
              "NetworkExtension": True, "WidgetKit": True, "ActivityKit": False, "Charts": True,
              "AVFoundation": True, "CoreImage": True, "Security": True, "QuickLook": True,
              "UniformTypeIdentifiers": True, "OSLog": True, "StoreKit": True},
}

#: Modules whose presence depends on an optional xcframework rather than on the platform. Kept separate
#: from `CAN_IMPORT` because the answer is a fact about this project's `Frameworks/` directory, not about
#: the platform, and a reader checking one should not have to read the other.
OPTIONAL_MODULES = {"GhosttyTerminal": True}

#: Environment conditions the evaluator can decide, with the answer for each platform.
#:
#: `targetEnvironment(macCatalyst)` is False for both: this project ships native iOS and native macOS
#: targets and no Catalyst target - `TerminalSessionContainerView.swift` guards its own Catalyst branch
#: with `#if !targetEnvironment(macCatalyst)`, and `SFI`/`SFM` are separate app targets rather than one
#: Catalyst binary. The resolver refused it before this entry existed, which is the behaviour it is
#: supposed to have: an undecidable condition stops the run rather than picking a branch.
TARGET_ENVIRONMENT = {
    "ios": {"macCatalyst": False, "simulator": False},
    "macos": {"macCatalyst": False, "simulator": False},
}

for _platform in CAN_IMPORT:
    CAN_IMPORT[_platform].update(OPTIONAL_MODULES)

#: The operating systems `os(...)` may name. A name outside this set is refused rather than answered
#: `False`, because `False` for a misspelling is indistinguishable from `False` for a real platform.
OS_VOCABULARY = frozenset({"ios", "macos", "tvos", "watchos", "visionos"})

#: The platforms this evaluator will decide **anything** for. A platform absent here is refused outright,
#: including for a bare `os(...)` comparison - see `evaluate`.
#:
#: # Why `tvos` is absent, and why that is the honest answer rather than an omission
#:
#: This repository *does* build `ApplicationLibrary` for tvOS (the `SFT` target, `TVExtension`; see
#: `guard_hako_platform_modifiers.py`, which states that `ApplicationLibrary` "builds for iOS, macOS and
#: tvOS", and `HakoConnectionListView.swift:30`, which hand-writes `#if canImport(UIKit) && !os(tvOS)`).
#: So a tvOS table is genuinely *needed* by anyone who wants to resolve a shared file for tvOS - and it
#: cannot be written from evidence available in this repository. `os(tvOS)` branches are everywhere; a
#: `canImport` answer for tvOS is nowhere. `canImport(Charts)`, `canImport(ActivityKit)`,
#: `canImport(StoreKit)` and the rest are facts about the tvOS SDK, not about `sing-box.xcodeproj`, and
#: there is no tvOS build in this environment to establish them from. Inventing `True` for a module the
#: tvOS SDK lacks keeps a block that will not compile; inventing `False` for one it has silently deletes
#: UI. Both are worse than refusing, so `tvos` is refused until someone adds the table from evidence.
#:
#: Adding one also has to answer a question this file cannot: `TARGET_ENVIRONMENT` is a fact about
#: *targets*, and there is no Catalyst or simulator fact recorded for tvOS here either.
PLATFORMS: dict[str, dict] = {
    "ios": {"os": "ios", "can_import": CAN_IMPORT["ios"],
            "target_environment": TARGET_ENVIRONMENT["ios"]},
    "macos": {"os": "macos", "can_import": CAN_IMPORT["macos"],
              "target_environment": TARGET_ENVIRONMENT["macos"]},
}

#: Conditions that select a *build* rather than a platform. A branch guarded by one of these is copied
#: with its directive, and nothing inside it is evaluated or rewritten.
BUILD_FLAGS = ("DEBUG", "JAILBREAK", "RELEASE", "TESTFLIGHT")

DIRECTIVE = re.compile(r"^([ \t]*)#(if|elseif|else|endif)\b[ \t]*(.*?)[ \t]*$")


class DirectiveError(Exception):
    pass


def _mentions_build_flag(condition: str) -> bool:
    return any(re.search(rf"\b{flag}\b", condition) for flag in BUILD_FLAGS)


def evaluate(condition: str, platform: str) -> bool:
    """Decide one platform condition for `platform`, or raise if it cannot be decided.

    # Why an unknown platform is refused before anything is looked at

    `os(tvOS)` compares a name against the *argument*, so it used to answer for any string at all: with
    `platform="tvos"` it returned True without anyone having established a single fact about tvOS. That is
    the same failure the `canImport` table's "add it deliberately" rule exists to prevent, one level up -
    a decision that looks like a decision and is actually a spelling comparison. A platform the registry
    does not carry is now refused up front, whatever the condition says.
    """
    if platform not in PLATFORMS:
        raise DirectiveError(
            f"no condition table for platform {platform!r}; known platforms: "
            f"{', '.join(sorted(PLATFORMS))}. Add one deliberately - deciding `os(...)` for an unknown "
            f"platform is a comparison against the argument, not a fact about the platform")

    text = condition.strip()
    if not text:
        raise DirectiveError("empty condition")

    or_parts = re.split(r"\s*\|\|\s*", text)
    if len(or_parts) > 1:
        return any(evaluate(part, platform) for part in or_parts)
    and_parts = re.split(r"\s*&&\s*", text)
    if len(and_parts) > 1:
        return all(evaluate(part, platform) for part in and_parts)

    if text.startswith("!"):
        return not evaluate(text[1:], platform)
    if text in ("true", "false"):
        return text == "true"

    match = re.fullmatch(r"os\((\w+)\)", text)
    if match:
        name = match.group(1).lower()
        if name not in OS_VOCABULARY:
            raise DirectiveError(f"{match.group(0)!r} names an operating system this evaluator does not "
                                 f"know; refusing rather than answering False")
        return name == PLATFORMS[platform]["os"]

    match = re.fullmatch(r"canImport\((\w+)\)", text)
    if match:
        table = PLATFORMS[platform].get("can_import")
        if table is None:
            raise DirectiveError(f"no canImport table for platform {platform!r}")
        if match.group(1) not in table:
            raise DirectiveError(
                f"canImport({match.group(1)}) is not in the table for {platform}; "
                f"add it deliberately rather than defaulting")
        return table[match.group(1)]

    if re.fullmatch(r"(swift|compiler)\(>=([\d.]+)\)", text):
        return True  # The project's tools version is 5.7 and every declaration here is older.

    match = re.fullmatch(r"targetEnvironment\((\w+)\)", text)
    if match:
        table = PLATFORMS[platform].get("target_environment")
        if table is None or match.group(1) not in table:
            raise DirectiveError(
                f"targetEnvironment({match.group(1)}) is not in the table for {platform}; "
                f"add it deliberately rather than defaulting")
        return table[match.group(1)]

    raise DirectiveError(f"cannot decide condition: {text!r}")


def assert_balanced(lines: list[str]) -> None:
    depth = 0
    seen_else: list[bool] = []
    for index, line in enumerate(lines):
        match = DIRECTIVE.match(line)
        if not match:
            continue
        keyword = match.group(2)
        if keyword == "if":
            depth += 1
            seen_else.append(False)
        elif keyword in ("elseif", "else"):
            if depth == 0:
                raise DirectiveError(f"line {index + 1}: #{keyword} without #if")
            if seen_else[-1]:
                raise DirectiveError(f"line {index + 1}: #{keyword} after #else")
            if keyword == "else":
                seen_else[-1] = True
        else:
            if depth == 0:
                raise DirectiveError(f"line {index + 1}: #endif without #if")
            depth -= 1
            seen_else.pop()
    if depth != 0:
        raise DirectiveError(f"{depth} unterminated #if block(s)")


def resolve(text: str, platform: str) -> str:
    """Return `text` with platform conditionals resolved and build-flag conditionals preserved."""
    lines = text.split("\n")
    assert_balanced(lines)

    # One frame per `#if`. `taken` is whether a branch at this level has already been selected;
    # `active` is whether *this* branch is the selected one; `verbatim` marks a build-flag block whose
    # branches are all copied with their directives.
    #
    # The stack is maintained for **every** directive, including ones inside a branch that will be
    # dropped. Tracking only the directives in live branches was wrong: a skipped branch's `#endif`
    # then closed the wrong frame, and the frame below it stayed open for the rest of the file, so
    # everything after it was dropped and the braces came out unbalanced.
    stack: list[dict] = []
    out: list[str] = []

    def emitting() -> bool:
        # A build-flag frame is emitting by definition: all of its branches are copied.
        return all(frame["active"] or frame["verbatim"] for frame in stack)

    for line in lines:
        match = DIRECTIVE.match(line)
        if not match:
            out.append(line if emitting() else "")
            continue

        keyword, condition = match.group(2), match.group(3)
        keep_directive = False
        # Whether the region this directive sits in is live, *before* the directive is applied. A
        # directive inside a region that is already dead must not be evaluated at all: an inner
        # `#if os(iOS)` inside a dropped `#elseif os(macOS)` branch evaluates true, and treating that
        # as live re-opened a branch the platform had already excluded - which silently dropped the
        # whole iOS half of the file.
        enclosing_live = all(f["active"] or f["verbatim"] for f in stack)

        if keyword == "if":
            if not enclosing_live:
                frame = {"taken": False, "active": False, "verbatim": False, "dead": True}
            elif _mentions_build_flag(condition):
                frame = {"taken": True, "active": False, "verbatim": True, "dead": False}
            else:
                decided = evaluate(condition, platform)
                frame = {"taken": decided, "active": decided, "verbatim": False, "dead": False}
            stack.append(frame)
            keep_directive = frame["verbatim"] and enclosing_live
        elif keyword == "elseif":
            frame = stack[-1]
            if not frame["dead"] and not frame["verbatim"]:
                decided = (not frame["taken"]) and evaluate(condition, platform)
                frame["active"] = decided
                frame["taken"] = frame["taken"] or decided
            keep_directive = frame["verbatim"] and enclosing_live
        elif keyword == "else":
            frame = stack[-1]
            if not frame["dead"] and not frame["verbatim"]:
                frame["active"] = not frame["taken"]
                frame["taken"] = True
            keep_directive = frame["verbatim"] and enclosing_live
        else:  # endif
            # The frame is popped *after* its verbatim flag is read: deciding whether to keep this
            # `#endif` from the stack after the pop silently dropped it, leaving an unbalanced `#if`.
            frame = stack.pop()
            keep_directive = frame["verbatim"] and enclosing_live

        out.append(line if keep_directive else "")

    collapsed: list[str] = []
    blanks = 0
    for line in out:
        if line.strip() == "":
            blanks += 1
            if blanks > 2:
                continue
        else:
            blanks = 0
        collapsed.append(line)
    return "\n".join(collapsed)


def scan_conditions(text: str, platform: str) -> list[dict]:
    """Every platform condition in `text`, with the value the evaluator gives it.

    Every condition is evaluated, **including ones nested inside a branch the platform excludes**. That is
    deliberate and it is stricter than `resolve`, which never evaluates a directive in a region that is
    already dead because an inner `#if os(iOS)` inside a dropped `#elseif os(macOS)` branch would evaluate
    true and re-open it. The shared gate keeps every branch, so a condition inside one is still a
    condition the copy will carry and the reader will have to believe; "cannot decide it" therefore has to
    be a refusal wherever it appears, not only on the live path.

    Build flags (`DEBUG`, `JAILBREAK`, ...) are skipped: they select a build rather than a platform, and
    both gates carry their branches verbatim.

    Raises `DirectiveError` naming **every** condition it could not decide, not just the first: a refusal
    that reports one problem at a time turns a one-line fix into three runs.
    """
    lines = text.split("\n")
    assert_balanced(lines)

    found: list[dict] = []
    undecided: list[str] = []
    for index, line in enumerate(lines):
        match = DIRECTIVE.match(line)
        if not match:
            continue
        keyword, condition = match.group(2), match.group(3)
        if keyword in ("else", "endif") or _mentions_build_flag(condition):
            continue
        try:
            value = evaluate(condition, platform)
        except DirectiveError as error:
            undecided.append(f"line {index + 1}: {condition!r} ({error})")
            continue
        found.append({"line": index + 1, "keyword": keyword, "condition": condition, "value": value})
    if undecided:
        raise DirectiveError(f"{len(undecided)} condition(s) cannot be decided for {platform!r}: "
                             + "; ".join(undecided))
    return found


def preserve(text: str, platform: str) -> str:
    """The shared-target gate: keep the platform structure, decide only whether it *can* be decided.

    # Why this exists next to `resolve`

    `resolve` answers the question "what does this file look like on iOS", and for a file that only ever
    builds for iOS that is the right question. The ported copies do not only build for iOS.
    `ApplicationLibrary` is one Xcode synchronized source group feeding the iOS, macOS and tvOS targets,
    so `ApplicationLibrary/Views/HakoStyle/Hako*.swift` is compiled for all three. Collapsing the
    original's `#if !os(tvOS)` away does not make the copy smaller, it makes it wrong: the body that was
    guarded now compiles on tvOS, and `#if canImport(AppKit) / #elseif canImport(UIKit)` becomes a single
    branch chosen for a platform the copy no longer declares. That is exactly what happened to
    `HakoStyle/HakoFontPickerView.swift`, whose upstream original opens with `#if !os(tvOS)` and carries
    the AppKit/UIKit chain, and neither survives in the committed copy.

    So this gate deletes nothing. It keeps the whole `#if`/`#elseif`/`#else`/`#endif` chain, and the
    caller renames identifiers inside every branch by running its rename over the returned text.

    # What it does refuse

    Every platform condition in the file, including ones inside branches the platform excludes, must be
    decidable by `evaluate` (build flags are exempt: they select a build, not a platform, and their
    branches are carried verbatim by both gates alike). A condition this evaluator cannot decide is a
    branch whose contents it cannot reason about, and the tool's job is to rename module-scope types
    without changing what the file means. Refusing is the only honest answer; picking a branch changes the
    UI, and removing the directive changes which platforms compile the body.
    """
    scan_conditions(text, platform)
    return text


#: A module-scope binding that, declared twice in one module, is a compile error. The `public`/`internal`
#: modifiers are optional; a bare `enum Foo` is module-scope too.
MODULE_SCOPE = re.compile(
    r"^(?:public[ \t]+|internal[ \t]+)?(?:struct|class|enum|protocol)\s+(\w+)", re.M)

EXTENSION = re.compile(r"^(?:public[ \t]+)?extension\s+(\w+)\s*\{", re.M)

#: `extension Foo { var bar: ... }` adds a member to a type; adding the same member twice is also an
#: error. Only the extension's *own* member names are collected, one level in.
EXTENSION_MEMBER = re.compile(
    r"^(?:public[ \t]+)?extension\s+(\w+)\s*\{(.*?)^\}", re.M | re.S)

MEMBER = re.compile(r"^[ \t]{1,4}(?:public[ \t]+|internal[ \t]+)?(?:var|func|static[ \t]+var|"
                    r"static[ \t]+let|static[ \t]+func)\s+(\w+)", re.M)


def module_scope_names(text: str) -> set[str]:
    """Every name that a second declaration of would break the module build."""
    names = set(MODULE_SCOPE.findall(text)) | set(EXTENSION.findall(text))
    for type_name, body in EXTENSION_MEMBER.findall(text):
        for member in MEMBER.findall(body):
            names.add(f"{type_name}.{member}")
    return names
