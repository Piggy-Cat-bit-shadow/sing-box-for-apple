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

They report 61 `NOT VERIFIED` entries, all of one shape: a symbol used **inside a region the tvOS slice
never compiles**, which the tools cannot prove is excluded.

```
[NOT VERIFIED] HakoGroupItemView.swift:101  whether nsColor is compiled on tvos could not be decided
[NOT VERIFIED] HakoSurface.swift:236        whether nsColor is compiled on tvos could not be decided
[NOT VERIFIED] guard pair HakoTaildropView.swift:180 -> TaildropQuickLookView: undecided on tvos
checked=54 errors=0 undecidable=61 not_covered=0
```

`HakoTaildropView.swift` is the clearest instance. Its shape is the original's — a file-level
`#if !os(tvOS)` at `:21` closed at `:454`, with `#if canImport(QuickLook)` (`:29-31`) and
`#if canImport(UIKit)` (`:32-34`) inside it for the imports. On tvOS the outer condition is false, so
nothing in the file is compiled there and every inner question is moot. `analyse()` in
`report_hako_platform_api.py` does not short-circuit on that: it records `state["tvos"] = None` for anything
whose *inner* condition it cannot evaluate, and `api_use_sites` (`:262-267`) then reports every such line as
`risky_on: [tvos]`. The outer guard is decided; it is simply not consulted before the inner one.

Two repairs, either of which closes it, in order of preference:

1. **Short-circuit the analysis on an enclosing condition that is already false for the platform.** If a
   line is inside `#if !os(tvOS)` and the platform is tvOS, the line is not compiled and no inner condition
   needs deciding. This is the general fix and it removes all 61 at once, because all 61 are inside such a
   region. It also makes the tools faster and less wrong in every other case.
2. **Prove `canImport(QuickLook)` for macOS and tvOS.** `QuickLook` is a `MODULE_FACTS` entry with only an
   `ios` row today, deliberately: `UNPROVEN` records that the repository's own evidence for it is the frozen
   original importing it under `#if os(iOS)`, and that the pbxproj does not name it. QuickLook does ship on
   macOS and does not exist on tvOS, but those are Apple facts rather than repository facts, and this
   round's rule was not to fill the table with values it cannot cite. Adding them needs a deliberate
   decision about where platform facts are allowed to come from — the same decision that would let
   `canImport(AppKit) ⟹ os(macOS)` be recorded rather than re-derived.

Option 1 is the honest one: it needs no new fact, and the shape it fixes — "the whole file is excluded on
this platform" — is the common one.

The refusal itself is correct and must stay. An unproven condition must remain `NOT VERIFIED` and non-zero
rather than becoming a guess or a silent pass, and both tools already do that on the text and the `--json`
path alike.

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
