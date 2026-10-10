# Round 8 — remaining known failures

Written at the end of the round so the next one starts from the real state rather than from a green
summary. **Nothing here is a build result**: there is no Swift toolchain, no Xcode, no device in this
environment. Every item is a source-level fact about a declaration, a use, or a condition.

## 1. `platform-guard-agreement` — 12 uses across 5 files (was 29 across 10)

The check (added this round by agent B) finds a declaration or import that is behind a condition while a
*use* of it is not. `ApplicationLibrary` is one framework target built for `iphoneos`, `macosx` and
`appletvos` (`sing-box.xcodeproj/project.pbxproj:2288` Debug, `:2330` Release), so each finding is a
per-platform compile break. Seventeen of the original twenty-nine were fixed this round; these are the rest.
Each is a port whose **original guards the use site rather than the file**, so the fix is a per-file reading
of `up-hako@c1935cf`, not a mechanical wrap.

| File | Symbol | Where the original guards it |
|---|---|---|
| `HakoProfilePickerSheet.swift` ×8 | `ProfileAnyExportDocument` | declared under `#if !os(tvOS)` at `Library/Database/Profile+Transferable.swift:280`; upstream guards the state at `.../Dashboard/Cards/ProfilePickerSheet.swift:549-552`, the menu row at `:891-893`, and the two `exportProfile` bodies at `:942-1036`. The port has **no conditional compilation at all** in that file |
| `HakoFontPickerView.swift:180` | `ImportedFont` | declared under `#if os(iOS)` at `Library/Shared/ImportedFontStore.swift:143`; the use needs `#if os(iOS)` inside the file-level `#if !os(tvOS)` that is already restored |
| `HakoGhosttyConfigurationView.swift:146` | `HakoThemePickerView` | now declared under `#if canImport(GhosttyTerminal)`; the use sits under `#if !os(tvOS)`, which does not imply it |
| `HakoLogView.swift:346` | `RemoteControlMenuItems` | declared under `os(iOS) && os(macOS)` at `.../RemoteControl/RemoteControlMenuItems.swift:5` |
| `HakoNewProfileMenuView.swift:85` | `QRScannerView` | declared under `#if !os(tvOS)` at `.../Scanner/QRScannerView.swift:12` |

`test_audit_apple_ui_boundary.py`'s positive case names this check as known-open rather than tolerating any
failure: it still fails if a check outside that one-entry list goes red. The audit exits non-zero while the
check is red, in both the text and the `--json` form.

## 2. `test_audit_reverse_routing.py` — one negative case needs updating

`guard-caller-guard-deleted` applies its mutation by finding a unique `'        #endif\n'` in
`HakoToolsView.swift`. That file now carries six `#endif` lines, because this round restored the guards its
original has, so the mutation cannot be applied and the suite reports it rather than passing. The fix is to
anchor the mutation on the guard it means to delete (the one around the Taildrop construction) instead of on
the count of a generic line.

This is the test doing exactly what it should - refusing to run a mutation it cannot apply - and it is
recorded rather than silenced.

## 3. `gate_hako_platform_imports.py --check` and `check_hako_macos_parse.py --platform tvos` are red

Both are red **because of item 1**: the uses listed above are exactly the unguarded ones the gates inspect.
They exited 0 before agent B's check landed and before the extra file-level guards were restored, because
neither tool was looking at both sides of the pairing. They exit 1 now and say which `file:line` is at
fault, which is the truthful state.

## What is *not* in this list, and why

* `MAINVIEW_IPAD` — the iPad root takes upstream's presentation and no Hako symbol reaches it.
  `ipad-mac-ui-gate`, `tablet-and-mac-entry` and `phone-entry` all `PASS`.
* The iPhone's own UI — 17 of the 18 checks `PASS`, and the eighteenth is item 1 above.
* The four frozen originals: the parity audit reports `SOURCE_EQUIVALENT` for all six first-level pages,
  nine of nine design-system files byte-identical, one compared by tokens with its divergence documented,
  and `lost UI tokens: 0`.
* Any Apple build, run or pixel comparison. Those need a Mac and remain `UNVERIFIED`; the schemes that exist
  in the project are `SFI`, `SFM`, `SFM.System`, `SFT` and `JailbreakDaemon`, read from
  `sing-box.xcodeproj/xcshareddata/xcschemes/` rather than guessed.
