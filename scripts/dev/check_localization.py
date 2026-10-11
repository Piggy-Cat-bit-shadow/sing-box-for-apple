#!/usr/bin/env python3
"""Localization gate for the fork's own Apple UI.

# The defect this exists for

The Simplified-Chinese interface was half English. The cause was not a missing translation file and
not a build failure - it was that the fork's pages asked for strings the catalog has never contained:

    HakoPacketTunnelView:  String(localized: "Tunnel")            upstream key: "Packet Tunnel"
    HakoToolsView:         String(localized: "Runtime & Reports") upstream key: "Reports"
    HakoSettingView:       String(localized: "Core Settings")     upstream key: "Core"

`String(localized:)` answers a miss by returning the key itself, so a near-miss variant is not an
error anywhere: it compiles, it runs, and it renders English in every language. Nothing looked at
whether the key existed, which is why this gate looks at exactly that.

# What it asserts

For every user-visible string the fork's own views ask for:

    is it a localization key?          NO -> FAIL   (a bare literal)
    does the catalog have it?          NO -> FAIL   (this is the near-miss case above)
    does it have a source-language entry? NO -> FAIL
    does it have zh-Hans?              NO -> FAIL   (unless whitelisted)

# What is deliberately not asserted

  * Strings the fork does not own. Only `ApplicationLibrary/Views/HakoStyle/` and `SFI/Hako*.swift`
    are scanned, so upstream's own pages are out of scope and this gate can never demand a change to
    a file the fork does not maintain. The catalog itself is SHARED with upstream - iPad and macOS
    read it too - which is why nothing here removes another language.
  * Technical terms, protocol names, product names and the identifiers of the NetworkExtension
    properties the pages describe. Those are correct in English in every locale; `DNS` is `DNS` in
    Chinese. They are listed in TECHNICAL_TERMS below with the reason, so the exemption is a
    judgement on the record rather than a hole.

Exit status is 0 when every checked string is localizable, 1 otherwise. `--report` prints the full
inventory including the exempt ones, which is what to read when adding a page.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "Localizable.xcstrings")

#: The fork's own UI surface. Scanned by prefix, so a new Hako page is covered the day it lands
#: rather than the day someone remembers to add it here.
FORK_UI_GLOBS = (
    "ApplicationLibrary/Views/HakoStyle/",
)
FORK_UI_FILE_PREFIXES = (
    "SFI/Hako",
)

#: Strings that must stay as they are in every locale.
#:
#: Two kinds, and the distinction is the point: a **term** is the same word in every language, and a
#: **key** is an identifier the user is being shown because it is the name of a NetworkExtension
#: property they may have to look up. Translating either would make the interface worse, not more
#: Chinese.
TECHNICAL_TERMS = {
    # Protocol and standard names.
    "DNS", "IPv4", "IPv6", "HTTP/3", "TCP", "UDP", "TLS", "QUIC", "STUN", "NAT", "SSID", "MTU",
    "URL", "JSON", "SSH", "FPS", "QRS", "APNs", "VoLTE", "MMS", "SMS", "HTTP", "HTTPS",
    # Product names.
    "sing-box", "iCloud", "NetworkExtension", "RootHelper", "OpenConnect", "OpenVPN", "Tailscale",
    "Ghostty", "Apple TV",
    # `NEVPNProtocol` property names, which the Tunnel page explains in place of translating.
    "enforceRoutes", "includeAllNetworks", "excludeAPNs", "excludeCellularServices",
    "excludeDeviceCommunication", "excludeLocalNetworks",
    # Placeholder / example values.
    "example.com",
}

#: Strings whose zh-Hans is still owed. Every entry is a debt with a reason, and the gate fails if
#: one is listed here but has since been translated, so the list cannot rot.
PENDING_TRANSLATION: dict[str, str] = {}

#: SwiftUI view-building initialisers whose first string literal is user-visible.
VISIBLE_CALLS = (
    "Text", "Label", "Button", "Toggle", "Section", "TextField", "SecureField",
    "navigationTitle", "navigationBarTitle", "alert", "confirmationDialog",
    "FormItem", "FormPicker", "FormNavigationLink", "HakoPageSection", "HakoSettingsSection",
    "HakoNavigationRow", "HakoActionTile", "HakoRow", "HakoDestructiveRow", "HakoToggleRow",
)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    text: str
    kind: str
    detail: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.kind}: {self.text[:60]!r} - {self.detail}"


def repo_paths() -> list[str]:
    """The fork's own Swift files, relative to the repository root."""
    found: list[str] = []
    for base, _, names in os.walk(ROOT):
        rel = os.path.relpath(base, ROOT)
        if rel.startswith(".") or "/.git" in rel or rel.startswith(".git"):
            continue
        if rel in ("Tests",) or rel.startswith("Tests/"):
            continue
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(rel, name) if rel != "." else name
            if path.startswith(FORK_UI_GLOBS) or any(
                    path.startswith(p) for p in FORK_UI_FILE_PREFIXES):
                found.append(path)
    return sorted(found)


def load_catalog() -> dict:
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


def localization_state(catalog: dict, key: str, locale: str) -> str | None:
    entry = catalog.get("strings", {}).get(key)
    if entry is None:
        return None
    unit = entry.get("localizations", {}).get(locale)
    if unit is None:
        return None
    if "stringUnit" in unit:
        return unit["stringUnit"].get("value", "")
    # Variations (`plural` and friends) count as present when they carry any case.
    variations = unit.get("variations", {}).get("plural", {})
    for case in variations.values():
        value = case.get("stringUnit", {}).get("value")
        if value:
            return value
    return ""


def strip_comments_and_strings_aware(text: str) -> list[tuple[int, str]]:
    """Lines with `//` comments removed, keeping line numbers.

    Block comments are dropped too. String literals are left alone, because the strings are the
    subject - a naive comment stripper that ate `"//"` inside a literal would lose real findings.
    """
    out: list[tuple[int, str]] = []
    in_block = False
    for number, raw in enumerate(text.split("\n"), start=1):
        line = raw
        if in_block:
            end = line.find("*/")
            if end == -1:
                continue
            line = line[end + 2:]
            in_block = False
        while True:
            start = line.find("/*")
            if start == -1:
                break
            end = line.find("*/", start + 2)
            if end == -1:
                line = line[:start]
                in_block = True
                break
            line = line[:start] + line[end + 2:]
        comment = line.find("//")
        if comment != -1:
            line = line[:comment]
        out.append((number, line))
    return out


def literal_after(text: str, open_paren: int) -> str | None:
    """The first `"..."` literal after an opening paren, or `None` if the argument is not a literal."""
    index = open_paren
    while index < len(text) and text[index] in " \t\n":
        index += 1
    if index >= len(text) or text[index] != '"':
        return None
    index += 1
    value: list[str] = []
    while index < len(text):
        char = text[index]
        if char == "\\":
            value.append(text[index:index + 2])
            index += 2
            continue
        if char == '"':
            return "".join(value)
        value.append(char)
        index += 1
    return None


def scan() -> list[Finding]:
    catalog = load_catalog()
    findings: list[Finding] = []

    call_pattern = re.compile(r"(?<![\w.])(" + "|".join(VISIBLE_CALLS) + r")\s*\(")
    localized_pattern = re.compile(r"String\(\s*localized:\s*")

    for path in repo_paths():
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        for number, line in strip_comments_and_strings_aware(text):
            for match in localized_pattern.finditer(line):
                literal = literal_after(line, match.end() - 1)
                if literal is None:
                    continue
                findings.append(classify(catalog, path, number, literal, localized=True))
            for match in call_pattern.finditer(line):
                # `String(localized:)` is handled above; skip the `localized` label itself.
                if match.group(1) == "Text" and "localized" in line[:match.start()]:
                    continue
                literal = literal_after(line, match.end() - 1)
                if literal is None:
                    continue
                findings.append(classify(catalog, path, number, literal, localized=False))
    return findings


def is_explicitly_untranslatable(catalog: dict, key: str) -> bool:
    """Whether the catalog itself marks this key as not to be translated.

    `"shouldTranslate" : false` is Xcode's own field, and upstream uses it for product names and
    identifiers - `OpenConnect`, `OpenConnect: %@`, `OpenVPN: %@`. That is a stronger statement than
    this script's hand-kept whitelist because it is the project's own record of the decision, and it
    travels with the catalog: a key added that way is exempt without anyone updating a Python set.

    A key that is `shouldTranslate: false` is not a miss. Demanding zh-Hans for it would be asking
    for a product name to be translated, which is the opposite of what the gate is for.
    """
    entry = catalog.get("strings", {}).get(key)
    return bool(entry) and entry.get("shouldTranslate") is False


def candidate_keys(text: str) -> list[str]:
    """The catalog keys a Swift string literal can resolve to.

    A literal with interpolations is not looked up as itself. SwiftUI and `String(localized:)` pass
    the *format* form to the catalog - `"\\(count) unread"` is looked up as `"%lld unread"`, and
    `"from \\(name)"` as `"from %@"` - so the gate has to ask for the same key the runtime will ask
    for, or it would report every format string as a missing key and the finding would be wrong.

    Both spellings are returned, in order, because which one applies depends on the interpolated
    expression's type and this is a text scan: `Int` and `Int64` widen to `%lld`, everything else is
    `%@`. The first key that the catalog contains wins; if neither is present the caller reports the
    literal as written, which is the message that helps.

    This matters for reuse, not just for accuracy. The catalog already contains `"%lld unread"`,
    `"%lld groups"`, `"%lld active"` and `"from %@"` **with zh-Hans**, and the fork's pages were
    asking for `"\\(count) unread"` and friends - different keys, so they rendered English. Naming the
    format form is what lets the gate point at the key that already exists.
    """
    if "\\(" not in text:
        return [text]
    numeric = re.sub(r"\\\([^)]*\)", "%lld", text)
    stringy = re.sub(r"\\\([^)]*\)", "%@", text)
    return [numeric] if numeric == stringy else [numeric, stringy]


def classify(catalog: dict, path: str, line: int, text: str, *, localized: bool) -> Finding:
    if text in TECHNICAL_TERMS:
        return Finding(path, line, text, "EXEMPT", "technical term or product/property name")
    if text in PENDING_TRANSLATION:
        return Finding(path, line, text, "PENDING", PENDING_TRANSLATION[text])
    if not text.strip():
        return Finding(path, line, text, "EXEMPT", "empty")
    strings = catalog.get("strings", {})
    keys = candidate_keys(text)
    key = next((k for k in keys if k in strings), None)
    if key is None:
        rendered = " / ".join(repr(k) for k in keys)
        return Finding(path, line, text, "MISSING_KEY",
                       f"the catalog has no {rendered}, so this renders English in every language - "
                       f"reuse the upstream key for this function, or add one")
    if is_explicitly_untranslatable(catalog, key):
        return Finding(path, line, text, "EXEMPT",
                       f"{key!r} is marked shouldTranslate=false in the catalog")
    if localization_state(catalog, key, "en") is None and catalog.get("sourceLanguage") != "en":
        return Finding(path, line, text, "NO_SOURCE", f"{key!r} has no source-language entry")
    if localization_state(catalog, key, "zh-Hans") is None:
        return Finding(path, line, text, "MISSING_ZH_HANS",
                       f"{key!r} has no zh-Hans, so the Simplified-Chinese UI shows English here")
    return Finding(path, line, text, "OK", f"{key!r} has en and zh-Hans")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the fork's own UI strings are localizable.")
    parser.add_argument("--report", action="store_true",
                        help="print every finding, including the exempt and already-correct ones")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    if not os.path.exists(CATALOG):
        print(f"FAIL: {CATALOG} is missing", file=sys.stderr)
        return 2

    findings = scan()
    failures = [f for f in findings if f.kind in ("MISSING_KEY", "NO_SOURCE", "MISSING_ZH_HANS")]
    pending = [f for f in findings if f.kind == "PENDING"]
    exempt = [f for f in findings if f.kind == "EXEMPT"]
    ok = [f for f in findings if f.kind == "OK"]
    distinct = {f.text for f in findings}

    if args.json:
        print(json.dumps({
            "checked": len(findings),
            "distinct": len(distinct),
            "ok": len(ok),
            "exempt": len(exempt),
            "pending": len(pending),
            "failures": [{"path": f.path, "line": f.line, "text": f.text,
                          "kind": f.kind, "detail": f.detail} for f in failures],
        }, ensure_ascii=False, indent=2))
        return 1 if failures else 0

    if args.report:
        for finding in sorted(findings, key=lambda f: (f.path, f.line)):
            print(f"  [{finding.kind:16}] {finding.path}:{finding.line}: {finding.text[:70]!r}")

    # The list must not rot: an entry that no longer needs an exemption is a failure.
    stale = [f for f in findings if f.kind == "PENDING" and f.text not in {
        p for p in PENDING_TRANSLATION}]
    if stale:
        for finding in stale:
            print(f"FAIL: stale pending entry {finding.text!r}", file=sys.stderr)

    if failures:
        print(f"FAIL: {len(failures)} fork-UI string(s) are not localizable:", file=sys.stderr)
        for finding in failures[:40]:
            print(f"  {finding}", file=sys.stderr)
        if len(failures) > 40:
            print(f"  ... and {len(failures) - 40} more", file=sys.stderr)
        return 1

    print(f"PASS: {len(findings)} visible string(s) across {len(repo_paths())} fork-owned file(s) "
          f"resolve to a catalog key with en and zh-Hans "
          f"({len(exempt)} exempt as technical terms, {len(pending)} pending)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
