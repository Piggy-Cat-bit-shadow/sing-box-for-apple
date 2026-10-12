# Build, signing and TestFlight

`sing-box.xcodeproj` defines app targets (SFI/iOS, SFM/macOS, SFT/tvOS), packet/system extensions, ApplicationLibrary/Library/MacLibrary, UI tests and auxiliary Action/Share/FileProvider/Intents/Widget/Helper targets. `Libbox.xcframework` is project-referenced but absent in this checkout; its source/pin must be verified with the parent/core repository — see `BASELINE.md`, where the core linkage is recorded as `EXTERNAL_CHECK_REQUIRED` and the linked-core identity as genuinely unknown.

Entitlements, `BASE_PACKAGE_IDENTIFIER`, derived bundle IDs, App Groups and signing are identity contracts. The visible `Jiejiebox` name overlay must not mutate those values. Runestone is a gitlink, not vendored source.

## Verified at this refresh

The boundary audit's `branding` and `repository-hygiene` checks confirm the identity contracts are
**unchanged from upstream**:

```text
PRODUCT_NAME                  42 occurrence(s), identical to 089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85
PRODUCT_BUNDLE_IDENTIFIER     42 occurrence(s), identical to 089d35e6…
BASE_PACKAGE_IDENTIFIER        2 occurrence(s), identical to 089d35e6…
.gitmodules blob              8117bd3f1eed (identical to 089d35e6…)
Frameworks/Runestone gitlink  baeb3cbf8332 (identical to 089d35e6…)
git diff --check              clean
```

That is the strongest statement this knowledge base can make about signing without a macOS host:
**nothing about identity has moved.** It is `VERIFIED_STATIC`, not `VERIFIED_BUILD`.

One build-visible change since the previous baseline: toolbar placement now **requires iOS 16**
(`d052491`). The delta contains **no deletions and no renames at all** — every changed path is a
modification or an addition (`git diff --name-status --diff-filter=ADR f4a9859..main` lists no
`D`/`R` rows). The new files are `Library/Network/InterfaceMonitorStartup.swift`,
`Library/Shared/ScreenshotFixtureGroups.swift`, the `Tests/HakoInterfaceStartup` package,
`scripts/dev/check_localization.py`, `scripts/run-interface-startup-tests.sh`,
`docs/SNAPSHOT-FIXTURE-CONTRACT.md`, `docs/P1C-IPHONE-DEVICE-CLOSURE-REPORT.md` and this
`KNOWLEDGE/` tree itself.

## What is not established

Fastlane/Makefile may describe operational steps, but **no archive/export/upload was run here**.

```text
archive success                UNVERIFIED
export success                 UNVERIFIED
upload success                 UNVERIFIED
processing success             UNVERIFIED
internal TestFlight availability  UNVERIFIED
external/public testing review    UNVERIFIED
public link availability          UNVERIFIED
```

Do not infer a later stage from an earlier one. A signed build would be `VERIFIED_BUILD`; upload is
distinct from public TestFlight review; **no release baseline exists** on this line. Every row
above stays `UNVERIFIED` until a macOS host with signing identity and a `Libbox.xcframework`
actually produces the artifact.
