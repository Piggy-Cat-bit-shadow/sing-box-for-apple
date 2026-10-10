# Round 8 — remaining known failures

Written at the end of the round so the next one starts from the real state rather than from a green
summary. **Nothing here is a build result**: there is no Swift toolchain, no Xcode and no device in this
environment. Every item is a source-level fact about a declaration, a use, or a condition.

## Everything that was fixable in this round is fixed

`platform-guard-agreement` went from **29 findings across 10 files** to **PASS**: 28 conditional imports and
113 uses each sit inside a condition that matches where the symbol exists.
`audit_apple_ui_boundary.py --strict` reports **PASS 18, FAIL 0, UNKNOWN 0, UNDECIDABLE 0**, and the
boundary suite's known-open list is empty again.

## 1. `gate_hako_platform_imports.py --check` and `check_hako_macos_parse.py --platform tvos` — red, and not because of a Swift defect

They report `NOT VERIFIED` for symbols used inside `#if canImport(AppKit)` blocks:

```
[NOT VERIFIED] HakoGroupItemView.swift:101  whether nsColor is compiled on tvos could not be decided
[NOT VERIFIED] HakoSurface.swift:236        whether nsColor is compiled on tvos could not be decided
[NOT VERIFIED] HakoLogView.swift:604        whether NSViewRepresentable is compiled on tvos could not be decided
[NOT VERIFIED] HakoTaildropView.swift:423   whether QLPreviewController is compiled on tvos could not be decided
```

The cause is a gap in the tools, not in the tree: they evaluate `os(...)` conditions and know the
repository's own facts, but they do not treat `canImport(AppKit)` as **implying** `os(macOS)`, so a use
inside a `canImport(AppKit)` block reads as "condition unknown" instead of "macOS only, and this is
therefore fine on tvOS because the block is excluded there".

Two correct repairs, either of which closes it:

* teach the condition model the one implication, `canImport(AppKit) ⟹ os(macOS)` and
  `canImport(UIKit) ⟹ os(iOS) || os(tvOS)` (both are Apple facts, not repository facts), or
* route the `NSColor` / `NSView` / `QLPreviewController` availability questions through the
  `symbol_availability()` that `scripts/dev/hako_platform_facts.py:351` already exposes, which knows
  `NSColor` is macOS-only and has evidence for it.

The refusal itself is correct behaviour and must stay: nobody has proven a `canImport(QuickLook)` answer for
tvOS, and the tools say `NOT VERIFIED` rather than guessing. The audit exits non-zero, in the text and the
`--json` form alike.

## 2. Nothing else

No other check, test or gate is red:

| Command | Result |
|---|---|
| `audit_apple_ui_boundary.py --upstream-ref 089d35e6… --strict` | `PASS 18  FAIL 0  UNKNOWN 0  UNDECIDABLE 0`, exit 0 |
| `test_audit_apple_ui_boundary.py` | pass, known-open list empty |
| `test_audit_reverse_routing.py` | 30 cases, all as designed |
| `audit_hako_lossless_parity.py` | 6/6 pages, design system 9 of 9 byte-identical + 1 by tokens, lost tokens 0 |
| `test_fail_closed_exit_codes.py` | 2 passed, 0 failed |
| `test_migrate_secondary_page.py` | 12 passed, 0 failed |
| `test_platform_gates.py` | 0 failing of 19 |
| `check_hako_macos_parse.py --platform ios` / `macos` | PASS, `checked=54 errors=0 undecidable=0 not_covered=0` |
| `wrap_hako_platform_declarations.py --check` | nothing to wrap, nothing refused |
| `check_swift_structure.py` (`HakoStyle/` + `SFI/`) | every file balanced |
| `check_platform_structure.py` | every ported file carries its original's structure |
| `check_generated_headers.py` | 33 of 33 headers resolve at the pin |

## What is not a concern, stated so a red gate is not read as a broken port

* **iPad and macOS isolation**: `ipad-mac-ui-gate`, `tablet-and-mac-entry` and `phone-entry` all `PASS`.
  `MAINVIEW_IPAD` never enters the Hako UI.
* **The iPhone's own UI**: seventeen of the eighteen checks pass; the eighteenth is item 1, which is a
  tooling gap in the tvOS column, not a defect in the phone's path.
* **The four frozen originals**: the parity audit reports the six first-level pages `SOURCE_EQUIVALENT`, nine
  of nine design-system files byte-identical, and one compared by tokens with its divergence documented.
* **Any Apple build, run or pixel comparison**: those need a Mac and remain `UNVERIFIED`. The schemes that
  exist in the project are `SFI`, `SFM`, `SFM.System`, `SFT` and `JailbreakDaemon`, read from
  `sing-box.xcodeproj/xcshareddata/xcschemes/` rather than guessed.
