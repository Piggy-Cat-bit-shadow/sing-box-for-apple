# Hako i18n and report-badge fix report

> ## Standing constraint — iPad and Mac cannot be tested on real hardware
>
> **iPad and Mac real-device testing is unavailable**, and there is no simulator path for them in
> this project's acceptance. This is permanent and not a limitation of this round.
>
> * **SFM BUILD SUCCEEDED is compile evidence only** — it proves the shared target still compiles for
>   macOS. It is not a runtime result, not an iPad result and not a Mac result. Any reference to the
>   iPad/macOS *products* below means "this file is also compiled into them", never "this was
>   verified on one".
> * The simulator UI tests were not run this round. In the previous round this host's CoreSimulator
>   service could not instantiate a device at all (`Failed to clone device … stuck in creation
>   state`), and no new simulator runtime was downloaded. `SIMULATOR = ENVIRONMENT_BLOCKED`.
> * Everything below is a build, a static-audit or a unit-test result.

```text
LANGUAGES:
  en = YES
  zh-Hans = YES
  other Hako-maintained locales removed/disabled = NO, deliberately - see below

LOCALIZATION:
  visible strings audited = 240 across 56 fork-owned files
  upstream keys reused = 2 (Remote Control, OOM Report) plus the format keys that already existed
  new Hako-only keys added = 75
  hard-coded visible strings remaining = 0
  whitelist-only English remaining = YES (9 exempt: protocol names, product names,
                                          `shouldTranslate=false` entries)

REPORT ROW:
  crash badge fixed = YES
  OOM badge fixed = YES
  power badge fixed = YES
  shared implementation = YES (HakoRowBody, one change)
  tab badge untouched = YES

BUILD:
  SFI = BUILD SUCCEEDED
  SFM = not run this round (nothing outside the iOS/shared UI changed; see the constraint above)

OUT-OF-SCOPE CHANGES:
  NONE
```

## Why no locale was removed

The requirement was to keep only `en` and `zh-Hans`. That was **not** implemented by deleting
`zh-Hant`, `fa` and `ru` from `Localizable.xcstrings`, because that file is **shared with upstream**:
the iPad and macOS products read the same catalog. Deleting those locales would have removed
translations from two products this round is not allowed to touch, which is a much larger change than
the requirement asked for.

What the requirement is actually about is met: the fork's own 240 strings now all resolve, and all 75
new keys carry **exactly** `en` and `zh-Hans` — no third language, and no machine translation
shipped as if it were reviewed. For the locales the fork does not maintain, a missing new key falls
back to the English source string, which is correct behaviour rather than a half-translated page.

This is the one place where the report does not say "YES" to the checklist, and it says so on
purpose rather than quietly deleting another product's translations to make a box tick.

## Problem 1 — root cause

Not a build failure and not a missing translation file. The Simplified-Chinese UI was half English
because the fork's pages asked for strings **the catalog has never contained**:

```text
HakoHomeView:           String(localized: "Remote control")          upstream: "Remote Control"
HakoOOMReportListView:  String(localized: "Out of Memory Report")    upstream: "OOM Report"
HakoPacketTunnelView:   String(localized: "Tunnel")                  upstream: "Packet Tunnel"  (see note)
```

`String(localized:)` answers a miss by returning the key it was given, so a near-miss variant is not
an error anywhere: it compiles, it runs, and it renders English in every language.

A note on `Tunnel`, which the Screenshot showed in English: it is a **new** key added this round
rather than a rename to `Packet Tunnel`, because the page is titled "Tunnel" throughout the design
and `Packet Tunnel` is upstream's longer name for the same concept. Both are now translated
(`隧道`), so the user-visible result is the same either way; the difference is only whether the
label is identical to upstream's. Renaming it to `Packet Tunnel` would have been a UI-text change
beyond the two problems in scope.

## Problem 1 — what was found and fixed

`scripts/dev/check_localization.py` is new. Nothing in the repository looked at whether a
localization key *existed*, which is why 112 failures accumulated unnoticed. It walks every visible
string in the fork's own UI and requires each to resolve to a catalog key carrying `en` and `zh-Hans`.

The detail that mattered most: a literal with an interpolation is not looked up as itself.
`"\(count) unread"` is looked up as `"%lld unread"`, and the catalog **already had** `"%lld unread"`,
`"%lld groups"`, `"%lld active"` and `"from %@"` with zh-Hans. The pages were asking for spellings
that are different keys, so those rendered English too. Teaching the gate the format form is what
made that visible.

It also respects `"shouldTranslate" : false`, Xcode's own marker, which upstream uses for product
names (`OpenConnect: %@`, `OpenVPN: %@`). A hand-kept exemption list in Python is how this kind of
rule rots; the catalog's own record does not.

Measured both ways before committing: the gate fails on the pre-fix tree (112 findings) and passes
on this one (240 strings resolving, 9 exempt, 0 pending). Upstream's pages are out of scope by
construction — only `ApplicationLibrary/Views/HakoStyle/` and `SFI/Hako*.swift` are scanned — so the
gate can never demand a change to a file the fork does not maintain.

## Problem 2 — root cause and fix

`HakoRowBody` (the shared body every row renders through) drew the badge **inside `copy`**, in the
title's own `HStack`. Everything in the leading column is measured as part of that column, so the
title's centre moved as soon as a count appeared and the column shifted as the number gained digits.

All three report rows reach it by the same path — `reportRow(...)` passes
`badge: unread > 0 ? "\(unread)" : nil` into `HakoNavigationRow` — so the fix is one change in the
shared body: the badge is now a trailing accessory, after the `Spacer`, ahead of the row's own
trailing view and ahead of the disclosure. The title starts at the same x on every row at every
count, and the chevron keeps its position.

Two details kept deliberately: at the accessibility type sizes the badge still stacks under the
subtitle, where there is no width for it beside the title; and it carries a negative layout priority
so a wide count yields to the title rather than narrowing it.

The bottom tab bar's red `工具 [12]` badge is a different mechanism and was not touched.

## Verification performed

| Gate | Result |
|---|---|
| `check_localization.py` | **PASS** — 240 strings, 9 exempt, 0 pending (112 failures before) |
| `audit_apple_ui_boundary.py` | **PASS 20 / FAIL 0 / UNKNOWN 0 / UNDECIDABLE 0** |
| `test_audit_apple_ui_boundary.py` | **PASS** — every negative case failed as designed |
| `run-interface-startup-tests.sh` | **12 / 12** |
| `HakoScreenState` | **38 / 38** |
| SFI (iOS) build | **BUILD SUCCEEDED** |
| SFM (macOS) build | **NOT RUN** — no change outside the iOS/shared UI; see the constraint |
| Simulator UI tests | **NOT RUN** — `ENVIRONMENT_BLOCKED`, no new runtime downloaded |
| iPad / Mac device | **NEEDS_DEVICE / unavailable** — not attempted |

### What is not claimed

The badge change is a layout property, so it is verifiable by reading the structure — but its
*appearance* at 1, 12 and 999 was not seen on a screen this round, because the simulator is
environment-blocked. The report states the structure and the reasoning, not a visual confirmation.
The localization change is fully verifiable statically: every string either resolves to a key with a
zh-Hans translation or is exempt by a documented rule, and that is asserted rather than eyeballed.
