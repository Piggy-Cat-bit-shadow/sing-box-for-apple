# Round 9 — remaining known failures

Written at the end of the round so the next one starts from the real state rather than a green summary.
**Nothing here is a build result**: there is no Swift toolchain, no Xcode and no device in this environment.
Every item is a source-level fact about a declaration, a use, or a condition.

## Everything that was fixable in this round is fixed

`port_tools_and_more.py`, `port_hako_pages.py` and `port_hako_components.py` no longer overwrite an existing
differing target without an explicit per-target, per-blob authorization (`fd27efe`); the phone root observes
the tunnel's status again (`6a9d7eb`); the audit's two detector holes are closed and it now walks the whole
shared target (`116ae6f`); two ported types that had lost their only caller are wired up again (`116ae6f`);
`hako-type-has-caller` is registered and distinguishes an orphan the port introduced from one the frozen
original shipped (`116ae6f`); the parity audit no longer counts a missing file as compared (`116ae6f`); and
four smaller guard and tool defects are repaired (`932bf1c`). All of it is described in
`HAKO-ROUND9-HANDOFF.md`.

`audit_apple_ui_boundary.py --upstream-ref 089d35e6… --strict` reports **PASS 19 FAIL 0 UNKNOWN 0
UNDECIDABLE 0** — 19 checks, where round 8 ran 18 and one of them was not registered. Every suite is green
except the two tvOS tools below.

## 1. `check_hako_macos_parse.py --platform tvos` and `gate_hako_platform_imports.py --check` — red, and accepted

Both report 61 `NOT VERIFIED` entries of one shape: a symbol used inside a region the tvOS slice never
compiles, which the tools cannot prove is excluded.

```
[NOT VERIFIED ] HakoGroupItemView.swift:101  nsColor - compiled-or-not is undecided on tvos
[NOT VERIFIED ] HakoSurface.swift:236        nsColor - compiled-or-not is undecided on tvos
[NOT VERIFIED ] guard pair HakoTaildropView.swift:180 -> TaildropQuickLookView: undecided on tvos
checked=54 errors=0 undecidable=61 not_covered=0
```

The cause is one thing, and it is not a Swift defect: `swift_directives.PLATFORMS` has **no `tvos` entry**, so
`evaluate` refuses *every* condition for that platform — including `os(iOS)`, which is answered by the
meaning of the comparison rather than by any fact about the tvOS SDK. Every one of the 61 sits inside a
region tvOS provably never compiles: `HakoTaildropView.swift` is wrapped in a file-level `#if !os(tvOS)` at
`:21`, closed at `:454`, with the `canImport(QuickLook)` and `canImport(UIKit)` imports nested inside it.

**This is accepted rather than fixed, because tvOS is out of scope** — the user's decision, recorded in
`HAKO-ROUND9-HANDOFF.md` §3. A repair that registered tvOS as a platform was written, verified green
(`undecidable=0` on all three platforms with `errors=0` and `checked=54`), and then reverted on instruction;
the patch is at `_work/r8/scratch/tvos-work-REVERTED.patch`.

The honest repairs, if the goal ever becomes a fully green suite, in order of preference:

1. **Narrow these two tools' platform set** to the platforms this project actually ships. `ApplicationLibrary`
   declares `appletvos` in `SUPPORTED_PLATFORMS` (`project.pbxproj:2288`/`:2330`), which is why the tools ask
   about tvOS at all, but the user does not build a tvOS interface. This is a change of *scope*, stated
   plainly in the tool and the document — not a weakened assertion.
2. **Teach the condition model what a platform's identity is**, independently of the module table: an entry
   for tvOS that states `os: "tvos"` and the `targetEnvironment` facts already carrying evidence, with **no**
   `can_import` table, so every unproven `canImport` still refuses. This is what the reverted patch did, and
   it is correct engineering; it was reverted for priority reasons, not because it was wrong.

The refusal itself must stay either way: an unproven condition remains `NOT VERIFIED` and non-zero rather
than becoming a guess or a silent pass, on both the text and the `--json` path.

## 2. Nothing else is red

| Command | Result |
|---|---|
| `audit_apple_ui_boundary.py --upstream-ref 089d35e6… --strict` | `PASS 18  FAIL 0  UNKNOWN 0  UNDECIDABLE 0`, exit 0 |
| `test_audit_apple_ui_boundary.py` | pass, known-open list empty |
| `test_audit_reverse_routing.py` | pass, every case as designed |
| `audit_hako_lossless_parity.py` | 6/6 pages, design system 9 of 9 byte-identical, lost tokens 0 |
| `test_fail_closed_exit_codes.py` | 2 passed, 0 failed |
| `test_migrate_secondary_page.py` | 12 passed, 0 failed |
| `test_platform_gates.py` | 0 failing of 19 |
| `test_port_script_authorization.py` | 0 failing of 6 |
| `check_hako_macos_parse.py --platform ios` / `macos` | PASS, `checked=54 errors=0 undecidable=0` |
| `wrap_hako_platform_declarations.py --check` | nothing to wrap, nothing refused |
| `check_swift_structure.py` | both targets balanced |
| `check_platform_structure.py` | every ported file carries its original's structure |
| `check_generated_headers.py` | 33 of 33 headers resolve at the pin |

## 3. Open findings from the red-team audit, which are not failures of a command

These do not make any command red, and each needs a decision or a Mac rather than a fix:

* **`hako-type-has-caller` cannot see an orphan whose upstream twin is called from the same file that
  declares it** — `hako-ui`'s `ConnectionListView.swift` declares `ConnectionMenuButton` at :99 in one
  platform arm and calls it at :19 in another. The check asks the narrower question and reports three such
  declarations as inherited rather than failing on them; closing it needs arm-level analysis.
* **None of round 9's Swift changes has been compiled.** There is no Xcode, no Swift toolchain and no device
  here. `6a9d7eb`'s status observer and the four restored guards have runtime meaning; whether they behave as
  intended needs a Mac.
* **The audit's negative-case harness acts on the real repository's git index** because a
  `shutil.copytree` copies a worktree's `.git` **file**, which points at the shared git directory. Both
  `test_audit_apple_ui_boundary.py` and `test_fail_closed_exit_codes.py` reset a copy.
* **`jiejiebox-integrated` has 23 staged deletions and 50 staged modifications, uncommitted.** All the
  deleted files are in `HEAD`, so nothing is lost.
* **The 66-page census was not verified bucket by bucket** — only the page count and two of the six refusal
  codes.

## 4. Two findings that are not defects

Recorded so a later round does not "fix" them:

* `HakoSettingView.allSettingsKeys` omits `.sponsors` while `settingsKey` spells it. The frozen original's
  list omits it too — the two lists disagree upstream, and the port is faithful.
* `dup_module_scope.py` exits 1 with 18 name-only duplicates on a correct tree. They are legal code
  (`private extension URL` in two files, `extension View` by design), which is why the enforced
  `shared-declaration-duplicates` passes on the same tree.

## 5. What is not a concern, stated so a red gate is not read as a broken port

* **iPad and macOS isolation**: `ipad-mac-ui-gate`, `tablet-and-mac-entry` and `phone-entry` all `PASS`.
  `MAINVIEW_IPAD` never enters the Hako UI.
* **The four frozen originals**: the parity audit reports the six first-level pages `SOURCE_EQUIVALENT`, nine
  of nine design-system files byte-identical, verified independently against both the git object and the
  `up-hako` worktree.
* **Any Apple build, run or pixel comparison**: those need a Mac and remain `UNVERIFIED`. The schemes that
  exist are `SFI`, `SFM`, `SFM.System`, `SFT` and `JailbreakDaemon`, read from
  `sing-box.xcodeproj/xcshareddata/xcschemes/` rather than guessed.
* **`6a9d7eb` in particular has never been compiled.** It is a lifecycle hook on the phone's path; the checks
  that passed on it are structural and audit-level. Whether it fires on a device needs a Mac.
