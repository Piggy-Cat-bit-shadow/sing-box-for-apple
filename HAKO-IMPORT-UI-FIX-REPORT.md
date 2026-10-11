# Hako import UI fix report

> ## Standing constraint — iPad and Mac cannot be tested on real hardware
>
> **iPad and Mac real-device testing is unavailable**, and there is no simulator path for them in
> this project's acceptance either. This applies to every report in this repository, permanently,
> and it is not a limitation of this particular round.
>
> Consequences for what is written below, stated so that no reader has to infer them:
>
> * **SFM BUILD SUCCEEDED is compile evidence only.** It proves the shared Swift target still
>   compiles for macOS. It is *not* a runtime result, not an iPad result and not a Mac result.
> * The word "iPad" or "macOS" appearing next to a fix means **"this file is also compiled into the
>   iPad/macOS product"** — never "this was verified on an iPad/Mac".
> * Anything about iPad or macOS **behaviour** is `NEEDS_DEVICE` unless it is a static property of
>   the source. The iPad/macOS upstream UI is in the latter class here: this fix does not touch any
>   file they load, which is a fact about the diff rather than a device result.
> * Only **iPhone simulator** results appear in this report, and only where they are labelled as
>   such. No device was used.

```text
CURRENT BUG = FIXED

ROOT CAUSE:
- ApplicationLibrary/Views/HakoStyle/HakoNewProfileMenuView.swift put the complete profile editor
  inside `HakoModalScaffold`'s content for BOTH import paths.
- `HakoModalScaffold` renders its content through `HakoScaffoldBody`, which is a `Form`.
  `HakoNewProfileView`'s body is a `FormView`, which is also a `Form`. So the editor became a
  `Form` inside a `Form`: the inner one collapses to an empty group, the page renders nearly blank
  and its `Create` button is unreachable.
- Airplane mode is irrelevant here; the trigger is only "an import produced a request":
    * `Import from File` -> a `.json` sets `localImportRequest`  (the reported path)
    * `Scan QR Code`     -> a profile link sets `importRequest`   (the same defect)
- The manual `Create Manually` path was ALREADY correct - it pushed through
  `NavigationDestinationCompat` from outside the scaffold - which is why only import was broken and
  why that path was the model for the fix.

FILES CHANGED:
- ApplicationLibrary/Views/HakoStyle/HakoNewProfileMenuView.swift   (the fix)
- scripts/dev/audit_apple_ui_boundary.py                            (regression check)
- scripts/dev/test_audit_apple_ui_boundary.py                       (negative case for it)

SIMILAR BUGS FOUND:
- `HakoModalScaffold` call sites: NONE. It has exactly one call site in the tree
  (`HakoNewProfileMenuView`), which is this bug. `HakoSettingsScaffold` and `HakoReportScaffold`
  also wrap content in `HakoScaffoldBody`; all eleven of their call sites pass `Section`,
  `HakoPageSection` or card content, and the three report-detail pages navigate through
  `FormNavigationLink` - correct, not fixed.
- Sheets presenting a complete editor: NONE. `HakoProfilePickerSheet` presents
  `HakoEditProfileView` (a `FormView` body) inside `NavigationSheet` in three places;
  `NavigationSheet` (`ApplicationLibrary/Views/Profile/ProfileSheetHelpers.swift`) is a
  navigation container, not a form, so the editor's form is the outermost one. Correct.
- `NavigationLink` inside a form row: NONE new. The one instance of that class was already fixed
  before this round - the manual-create link, whose stray chevron is documented in the file.
- Scope audited: every `Hako*Scaffold` call site, every `Form`/`FormView`-bodied page in
  `HakoStyle/` (13 files) and every construction site of the two editor pages. Nothing outside
  `ApplicationLibrary/Views/HakoStyle/` was searched or changed.

VALIDATION:
- build: SFI (iOS) BUILD SUCCEEDED; SFM (macOS) BUILD SUCCEEDED
- tests: HakoInterfaceStartup 12/12, HakoScreenState 38/38, HakoSubscriptionUsage 24/24 (all 0 failures)
- static/source audit:
    * `audit_apple_ui_boundary.py` PASS 20 / FAIL 0 / UNKNOWN 0 / UNDECIDABLE 0 (was 19 checks; the
      new `form-pages-are-not-embedded` is the 20th)
    * `test_audit_apple_ui_boundary.py` - every negative case failed the audit as designed, positive
      case passed
    * the new check was verified in BOTH directions before being registered: injecting the old shape
      fails it and names the file and line; the fixed tree passes it
    * all three `HakoNewProfileView` construction sites are now preceded by
      `NavigationDestinationCompat`, and neither the `.fileImporter` nor the QR `.sheet` is attached
      to the scaffold's content any more
- simulator: ENVIRONMENT_BLOCKED, and no new runtime was downloaded. iOS 26.0 and iOS 27.0 were
  already installed, so no download was needed - but this host's CoreSimulator service cannot
  instantiate a device. Two runs, both ending in "Failed to clone device ... stuck in creation
  state", the second against a device the user had created earlier. `SIMULATOR = ENVIRONMENT_BLOCKED`.
- **What that costs, stated plainly:** no UI test was executed this round, so the import fix has no
  UI-test evidence. It would not have had any even on a working simulator: the `.fileImporter` is a
  system dialog, and **no existing UI test exercises the import path** - `SFIUITests` touches
  `hako.profile.createManually` (the manual flow, which was already correct) and never import. The
  regression protection for this fix is therefore the deterministic static check
  `form-pages-are-not-embedded`, which runs in this repository's own gate and was verified in both
  directions: it fails on the old shape and passes on the new one.
- device: NOT_APPLICABLE for the import path (it is a pure SwiftUI layout fact, not a device
  behaviour); airplane mode on hardware is the separate `NEEDS_DEVICE` item in
  NE-AIRPLANE-STARTUP-HANG-REPORT.md

RISK:
- iPhone Hako: LOW and bounded to the Add Configuration sheet. The editor, its chrome, its fields,
  its strings and its `onSuccess` are unchanged; only where it is presented moved, and it moved onto
  the path the manual-create flow already used and which was confirmed working.
- iPad upstream: NONE. `NewProfileMenuView` / `NewProfileView` are upstream's and are not touched;
  no shared file is modified.
- macOS upstream: NONE, same reason. SFM builds.
- core/libbox: NONE. No core or Libbox file is touched by this fix.

BRANCH: fix/hako-import-editor-routing   (shared with the NE airplane fix, per instruction)
HEAD:   6240a74 (this fix) - see the branch tip for the full set
PUSHED: YES
```

## What was deliberately not done

`HakoModalScaffold` was not refactored, no `wrapsInForm` / mode switch was added, and
`HakoNewProfileView` was not redesigned. The existing navigation mechanism was sufficient, which is
what the brief asked to prove before building anything new.
