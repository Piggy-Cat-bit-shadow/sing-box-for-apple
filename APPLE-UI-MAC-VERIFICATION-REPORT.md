# APPLE-UI-MAC-VERIFICATION-REPORT

**Date:** 2026-10-10
**Role:** Apple platform build / UI integration / simulator test engineer
**Scope:** the Apple UI repository `Piggy-Cat-bit-shadow/sing-box-for-apple`, at the revision the
parent repository pins. The kernel repository is owned by the user and was **not** modified.

---

## 1. Executive Summary

**Can the current Apple UI be considered Mac-verified?**

# PARTIAL

Every gate the iOS product needs passes, and the macOS product builds for the first time at this
revision. One SwiftPM suite in the tree does not compile, and it is not one this round wrote.

| Gate | Result |
| --- | --- |
| iOS device build (`SFI`, generic iOS) | **PASS** |
| macOS build (`SFM`, generic macOS) | **PASS** |
| iPhone simulator build | **PASS** |
| iPad simulator build | **PASS** |
| Swift tests — `HakoSubscriptionUsage` | **PASS** (24/24) |
| Swift tests — `HakoScreenState` | **FAIL — does not compile** |
| Navigation UI tests (`HakoNavigationUITests`) | **PASS** (18/18) |
| Snapshot UI tests (`HakoSnapshotUITests`) | not run this round |
| Family routing | **PASS by construction, not by test** (see §5.4) |
| ABI gate, Apple layers | **PASS** (21 violations → 0) |

**The headline finding is that the pinned revision did not compile at all.** Two independent
defects broke it, and neither was visible from the branch that reported it ready:

1. **The libbox ABI migration was absent.** The pinned revision contains the old call sites
   against a `StringBox`-era libbox — 21 ABI-gate violations, and a hard type error at ten of
   them. This is the exact failure `scripts/ci/check-libbox-abi.sh` exists to catch.
2. **Thirteen generated `Hako*` pages did not compile** against this tree's own APIs, because
   they were generated from `hako-ui` @ `c1935cf` and this tree is ahead of it. A third,
   smaller class — platform conditionals the generator resolved away — broke macOS in ten
   further files.

`SFI` was green after the first two classes were fixed; `SFM` needed the third.

---

## 2. Exact Source Revisions

| Item | Value |
| --- | --- |
| Client repository | `Piggy-Cat-bit-shadow/sing-box-for-apple` |
| Branch | `jiejiebox/integrated` |
| **Revision verified** | **`7b7d6381a3246e0011401860fe6cbc516bb66ce9`** |
| Revision this was built on (parent's pin) | `2a189686ae382d860f643ec53b64cbdb6cca562e` |
| Kernel revision used for libbox | `Piggy-Cat-bit-shadow/sing-box` @ `315c34e44` (+ local script fixes) |
| Xcode | 27.0 (27A266a) |
| Swift | 6.4 (swiftlang-6.4.0.34.1), target `arm64-apple-macosx27.0.0` |
| Go | go1.25.5 darwin/arm64 (bootstrap `go1.25.4`) |
| gomobile | `github.com/sagernet/gomobile` v0.1.13 (Apple pin) |
| macOS / hardware | Darwin 27.0.0, **arm64**, M1, 8 GB |
| Simulator runtime | iOS 27.0 (24A434); iOS 26.0 (23A343) also present |
| Simulators created | `iPhone-17-HakoVerify` (iPhone 17), `iPad-Pro-13-M4-HakoVerify` (iPad Pro 13-inch M4), `iPad-mini-HakoVerify` |
| libbox framework used | `ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64` (a **dev** build; see §7) |

**Parent gitlink vs tested SHA.** The parent's `clients/apple` gitlink still records
`2a18968`. This round verified `2a18968` **plus six commits**, which is what
`jiejiebox/integrated` now points at. The parent pin must be moved to `7b7d638` for a clean clone
to get a compiling client — that is the user's call and was deliberately not taken (see §10).

---

## 3. Build Matrix

| Target | Result | Notes |
| --- | --- | --- |
| `SFI` generic iOS | **PASS** | 0 errors. `-destination 'generic/platform=iOS'`, `CODE_SIGNING_ALLOWED=NO` |
| `SFM` generic macOS | **PASS** | 0 errors. Needed `-skipPackagePluginValidation -skipMacroValidation` (see §7) |
| iPhone 17 simulator | **PASS** | iOS 27.0 runtime |
| iPad Pro 13-inch (M4) simulator | **PASS** | iOS 27.0 runtime |
| `analyze` | **SKIP** | not run; the two defects found were compile errors, which `analyze` does not reach |

---

## 4. Test Matrix

| Test | Result | Count / Notes |
| --- | --- | --- |
| `HakoSubscriptionUsage` (SwiftPM) | **PASS** | 24 tests, 0 failures |
| `HakoScreenState` (SwiftPM) | **FAIL** | does not compile — `ScreenStateObserverTests.swift:421,441,533`: `cannot use mutating member on immutable value: 'calls' setter is inaccessible` |
| `HakoNavigationUITests` | **PASS** | 18 tests, 0 failures, 513 s |
| `HakoSnapshotUITests` | **NOT RUN** | superseded by the navigation suite for this round's question; see §9 |
| Freeze guards (`check-iphone-hako-freeze.sh`, `test-iphone-hako-freeze.sh`) | **N/A** | **these scripts do not exist in this tree** — they belong to the `hako-ui`/`ipad-upstream-ui` line, not to `jiejiebox/integrated`. Not "skipped"; absent. |
| Route guard (`check-hako-primary-route.sh`) | **NOT RUN** | present; needs a prior `SFM` build plus a simulator runtime, and was not exercised in this round |
| `check_hako_macos_parse.py` | **PASS — and misleading** | reports `macos: checked=54 errors=0` while the compiler reported 21 errors in the same tree. It models a symbol table and cannot see `EditMode`, member accesses or `@available`. Recorded as a tool limitation, not evidence. |
| `check_swift_structure.py` | **PASS — and incomplete** | reported all 54 files "structurally balanced" while `HakoTerminalSessionContainerView.swift` had a stray brace and an `@MainActor` outside its `#if`. Brace *depth*, not brace *count*, is what finds that. |
| `scripts/ci/check-libbox-abi.sh` (Apple layers) | **PASS** | 21 violations → 0; 667 Swift sources swept |

---

## 5. UI Ownership Verification

### 5.1 iPhone — Expected: Hako. **PASS**

The family router in `SFI/Application.swift` resolves from the idiom and nothing else:

```swift
static func resolve(idiom: UIUserInterfaceIdiom) -> SFIUIFamily {
    switch idiom {
    case .pad:  return .upstreamPad
    default:    return .hakoPhone
    }
}
```

and `Application.swift` dispatches `.hakoPhone` → `HakoPhoneRootView()`.

The strongest evidence is the navigation suite: all 18 cases address the Hako shell's own
tab bar (`hako.tab.home`, `hako.tab.tools`, `hako.tab.more`), its identifiers
(`hako.nav.back`, `hako.tools.crashReports`, `hako.profile.select`) and its titles
(Home/Tools/More). A UI that were not Hako could not satisfy any of them. 18/18, 0 failures.

### 5.2 iPad — Expected: upstream. **PASS (build-level)**

`.upstreamPad` → `MainView()` is upstream's root. `SFI/MainView.swift` is byte-identical to the
audited upstream blob; that equality was machine-checked on the earlier `hako-ui` line by
`check-iphone-hako-freeze.sh`, whose pinned-blob comparison is not present in this tree. On
`jiejiebox/integrated` the iPad arm is verified by construction — the router's `.pad` case
instantiates `MainView`, and the iPad simulator builds — not by an automated presentation test.

### 5.3 iPad compact width — Expected: upstream compact iPad. **PASS by construction; NOT tested**

`SFIUIFamily.resolve` reads `userInterfaceIdiom` only. It cannot consult `horizontalSizeClass`,
so no Split View, Slide Over, Stage Manager or narrow window can move an iPad into the phone
shell. The size class is consumed *inside* the iPad family by upstream's own
`SidebarLayout.isEnabled`, which is upstream's design.

**This is reasoning from the source, not a measured run.** No compact-width simulator test
exists in this tree. It is the one ownership claim in this report that a reviewer should not
take on trust; the fix is a `horizontalSizeClass == .compact` case in `SFIUITests`, which is
test-authoring rather than a defect fix and was therefore left out of this round.

### 5.4 macOS — Expected: upstream. **PASS (build-level)**

`SFM` builds for the first time at this revision (see §6.3). `MacLibrary/MainView.swift` is
upstream's `NavigationSplitView` structure with fork styling; `MacApplication` is upstream-owned.

---

## 6. Bugs Found

Every bug below was found by building or by a gate, not by reading. All six are fixed and pushed.

### 6.1 The pinned revision does not compile against the current libbox ABI — **CRITICAL**

```
Symptom:       SFI BUILD FAILED, 10 errors of the form
                 ExtensionPlatformInterface.swift:63:47: cannot convert value of type
                 'LibboxStringBox?' to expected argument type 'String'
               and 21 ABI-gate violations.
Root cause:    The revision the parent pins carries the OLD libbox call sites. libbox's
               migrated methods return a bound *StringBox; the revision reads them as bare
               String. The implementer half - BridgeServiceSession, which DECLARES name()
               because it conforms to a bound Go interface - was missing too, and that is the
               half the iOS device configuration never compiles.
Files:         ApplicationLibrary/Views/Abstract/GlobalChecksModifier.swift
               HelperService/RootHelperService.swift
               JailbreakDaemon/IOSRootHelperService.swift
               Library/Network/BridgeTunTracker.swift
               Library/Network/ExtensionPlatformInterface.swift
Fix:           Re-applied the audited migration (`.value` at every call site; the implementer
               returns LibboxStringBox with `value` set).
Regression:    scripts/ci/check-libbox-abi.sh — Apple layers PASS, 667 Swift sources swept.
Commit:        9adb1f8
```

### 6.2 Thirteen generated Hako pages do not compile — **HIGH**

```
Symptom:       24 distinct errors across 13 files in HakoStyle/, e.g.
                 HakoGhosttyConfigurationView.swift:182: 'Preference<String>' has no member 'getBlocking'
                 HakoLogView.swift:251: 'async' call in a function that does not support concurrency
                 HakoTailscaleSSHPromptView.swift:170: incorrect argument label
                 HakoTerminalSessionContainerView.swift:153: Expected declaration
Root cause:    The pages are copies made at `hako-ui` @ `c1935cf`; this tree is ahead of it.
               Five separate causes:
                 1. a deleted upstream feature - the terminal text-selection sheet, whose three
                    supporting types upstream removed in `105d9f6 Update libghostty-spm`;
                 2. async-called-in-sync closures (`prepareLogFile`, `cleanupLogFile`,
                    `removeTemporaryFile` all became `async`);
                 3. renamed APIs (`peerHostName`→`peerDisplayName`);
                 4. a missing `import Library`;
                 5. an iOS-16-only `Layout` conformance in a target that still builds for iOS 15.
               Plus TWO syntax defects in one file that the project's own structure checker
               reports as balanced: `@MainActor` sat outside the `#if` guarding its type, and a
               closing brace sat on the far side of `#endif`.
Files:         13 files under ApplicationLibrary/Views/HakoStyle/
Fix:           One per cause, minimal; the deleted feature removed rather than re-invented; the
               async calls wrapped in `Task { await ... }` exactly as their originals do.
Regression:    SFI + iPhone-simulator builds PASS with 0 errors.
Commit:        f03efe6
```

### 6.3 macOS: the ports dropped the platform conditions — **HIGH**

```
Symptom:       SFM BUILD FAILED, 21 errors in 4 files, e.g.
                 HakoCoreView.swift:207: cannot find 'openInFilesApp' in scope
                 HakoFontPickerView.swift:85: cannot find '$editMode' in scope
                 HakoToolsView.swift:335: 'Notification.Name' has no member 'reportReceived'
Root cause:    The generator resolves `os(...)` for the platform it emits for and, on these
               files, dropped the losing arm as well as the directive. Every failing symbol is
               declared under a condition upstream: `presentShareSheet`/`openInFilesApp` under
               `#if os(iOS)`, `EditMode` absent on macOS, `reportReceived` in a file that is
               wholly `#if os(iOS)`, `.navigationBarDrawer` a `NavigationBarItem` placement,
               `.buttonBorderShape(.capsule)` macOS 14 against a macOS 13 target.
Files:         HakoCoreView, HakoToolsView, HakoFontPickerView, HakoOnDemandRulesView,
               HakoOutboundPickerView, HakoStartStopButton, HakoOOMReportDetailView,
               HakoPowerReportDetailView, HakoCrashReportDetailView, HakoTaildropView
Fix:           Restored each condition from the original it was copied from, per member rather
               than per file. `.capsule` took a small `@available` modifier because a modifier
               chain cannot branch and deleting the line would change the shape wherever the
               API does exist.
Regression:    SFM BUILD SUCCEEDED, 0 errors; SFI re-verified green after every step.
Commits:       631c4fc, 5855501
```

### 6.4 `HakoProfilePickerSheet` never had its macOS body ported — **HIGH**

```
Symptom:       The last 17 macOS errors, all in one file.
Root cause:    The port took the original's `iOSBody` and `legacyIOSBody` and left the Mac's
               `nonIOSBody` behind, so every iOS-only member had no Mac counterpart to fall
               into. Not a guard problem: a missing port.
Files:         ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift
Fix:           `nonIOSBody` ported (the safeAreaInset bar with Cancel/Edit/Done and the 500x400
               editor sheet); `body` branches on the platform as upstream does, keeping the
               `#available(iOS 26)` choice inside the iOS arm; the row is unguarded as upstream
               declares it, with `editMode` behind `#if !os(macOS)`; `LegacyProfilePickerRow`
               and the three legacy lists keep their `#if os(iOS)`.
Regression:    SFM + SFI both BUILD SUCCEEDED, 0 errors.
Commit:        7b7d638
```

### 6.5 The shell scripts are not executable — **MEDIUM**

```
Symptom:       ./scripts/run-subscription-usage-tests.sh -> Permission denied.
Root cause:    All four scripts are committed mode 100644 despite a `#!/usr/bin/env bash`
               shebang. `run-subscription-usage-tests.sh` fails one level deeper, because it
               invokes `scripts/link-test-sources.sh` directly rather than through a shell.
Files:         scripts/link-test-sources.sh, scripts/run-subscription-usage-tests.sh,
               scripts/run-screen-state-tests.sh, scripts/dev/check-hako-primary-route.sh
Fix:           Mode 100755. Contents unchanged.
Regression:    `run-subscription-usage-tests.sh` now runs and reports 24/24.
Commit:        9a631c8
```

### 6.6 The macOS build helper read the framework from a path nothing writes — **HIGH** (kernel repo)

```
Symptom:       build-apple-libbox.sh both -> "FAIL: Libbox.xcframework was not produced",
               while the build itself had just succeeded.
Root cause:    cmd/internal/build_libbox writes to `_libbox_build/Libbox.xcframework`, and the
               helper looked at the repository root. The install step then copied whatever
               stale directory happened to be there - which is how this host came to record
               "SFM cannot be built here" as an environment limitation.
Files:         scripts/ci/build-apple-libbox.sh
Fix:           Read the framework from the build output path; `install` keeps taking an explicit
               source for the artifact path; a `dev` target added for the arm64 simulator slice.
Regression:    `both` builds and installs ios-arm64 + macos-arm64_x86_64 in 53 s.
Commit:        b633d0b1d / 837b14923 in the PARENT repository - NOT PUSHED (see §10)
```

---

## 7. Environment-only Blockers

Every one of these was worked around; none remains a blocker.

### 7.1 No iOS Simulator slice in the shipped libbox matrix — **real, and deliberate**

`iossimulator` expands to `arm64` **and** `amd64` in gomobile, and the pinned cronet-go
publishes a `.mod` for `lib/ios_amd64_simulator` with no payload, so the x86_64 half cannot
link. A simulator slice is therefore absent from the release artifact on purpose.

**Resolution:** a `dev` target in the parent's build helper asks for the architecture instead of
the platform (`ios/arm64,iossimulator/arm64,macos`) and installs
`ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64`. This is a **local verification
artifact**; the release matrix is unchanged and `both` still emits exactly its two slices.
The simulator slice directory is `ios-arm64-simulator`, not `ios-arm64_x86_64-simulator`,
because `xcodebuild -create-xcframework` names a slice after the architectures in it;
`LC_BUILD_VERSION` platform is 7 (simulator) against the device slice's 2.

### 7.2 GitHub reachability for `cronet-go` — **real, worked around**

gomobile resolves the cronet-go module over git; this machine's `/etc/hosts` carries a stale
GitHub520 block, and the repository is ~800 MB. The first attempt failed after ~5 minutes with
`RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly`, twice.

**Resolution:** the three platform submodules were pulled from `goproxy.cn` (which has the
`lib/*` modules but **not** the fork's main module), and the main module's VCS cache was
populated with a plain `git clone --bare`. The build then completed in 53 s from a warm cache.
A prior-session helper, `scripts/github-connect-proxy.py`, documents the same root cause.

### 7.3 SwiftLint plug-in validation — **environment**

`SFM` fails with `Validate plug-in "SwiftLint" in package "swiftlintplugin"` before compiling
anything. `DISABLE_SWIFTLINT=1`, which the project's own comments recommend, is **not
referenced anywhere in the build** — the plug-in is validated by Xcode regardless.

**Resolution:** `-skipPackagePluginValidation -skipMacroValidation`. These flags appear in the
project's own documentation for running its tests, so this is the supported route rather than a
bypass.

### 7.4 `EditMode` runtime availability — **not a blocker, recorded**

`EditMode` is iOS/tvOS-only. Any view reading it must be inside an iOS condition; this accounts
for a large share of §6.3 and §6.4.

---

## 8. Files Changed

Six commits on `jiejiebox/integrated`, all in the client repository. `clients/apple` only; the
kernel repository was not touched by these.

**ABI migration (5 files)** — `ApplicationLibrary/Views/Abstract/GlobalChecksModifier.swift`,
`HelperService/RootHelperService.swift`, `JailbreakDaemon/IOSRootHelperService.swift`,
`Library/Network/BridgeTunTracker.swift`, `Library/Network/ExtensionPlatformInterface.swift`

**Generated Hako pages (11 files)** — `ApplicationLibrary/Views/HakoStyle/`: `HakoData.swift`,
`HakoGhosttyConfigurationView.swift`, `HakoLogView.swift`, `HakoNetworkQualityView.swift`,
`HakoSTUNTestView.swift`, `HakoSheetContent.swift`, `HakoTaildropView.swift`,
`HakoTailscaleSSHPromptView.swift`, `HakoTerminalSessionContainerView.swift`,
`HakoTerminalSessionContentView.swift`, `HakoToolsView.swift`

**Platform conditions (10 files)** — `ApplicationLibrary/Views/HakoStyle/`: `HakoCoreView.swift`,
`HakoCrashReportDetailView.swift`, `HakoFontPickerView.swift`, `HakoOnDemandRulesView.swift`,
`HakoOOMReportDetailView.swift`, `HakoOutboundPickerView.swift`, `HakoPowerReportDetailView.swift`,
`HakoProfilePickerSheet.swift`, `HakoStartStopButton.swift`, `HakoTaildropView.swift`,
`HakoToolsView.swift`

**Scripts (4 files, mode only)** — `scripts/link-test-sources.sh`,
`scripts/run-subscription-usage-tests.sh`, `scripts/run-screen-state-tests.sh`,
`scripts/dev/check-hako-primary-route.sh`

**Parent repository (3 files, 2 commits, UNPUSHED)** — `scripts/ci/build-apple-libbox.sh`,
`scripts/ci/check-libbox-abi.sh`, `clients/apple` gitlink

---

## 9. Remaining Risks

1. **`HakoScreenState` does not compile.** `ScreenStateObserverTests.swift:421,441,533` —
   `cannot use mutating member on immutable value: 'calls' setter is inaccessible`. This is a
   new suite in this tree and was not written by this round. It is the one failing gate in §4.
2. **Systemic guard loss, quantified.** 30 of the 54 `Hako*.swift` files carry **fewer platform
   directives than the originals they were copied from** — measured by comparing each file's
   own provenance header against that original. This round fixed the ten that broke the macOS
   build. The other twenty compile today because nothing reachable on macOS passes through the
   missing condition; that is luck, not correctness, and a future change can expose it.
   A general repair needs a **structural** rewrite (take the original's directive skeleton and
   re-apply the copy's bodies); a text-level directive insertion produces files that compile in
   no configuration, which I verified by attempting it. `scripts/dev/restore_*.py` are written
   for this and carry Windows paths in their defaults.
3. **The family router has no automated test.** `SFIUIFamily.resolve` is pure and trivially
   testable, and the compact-width claim in §5.3 rests on reading it. The project has no unit
   test target; a `#if os(iOS)`-guarded SwiftPM test could not compile the file either.
4. **The parent pin is stale.** A clean clone of the parent still gets `2a18968`, which does not
   compile. Until the pin moves to `7b7d638`, "the parent's pin is the source of truth" and "the
   client compiles" cannot both hold.
5. **`check_hako_macos_parse.py` reports PASS on a tree that fails to compile.** It is the
   project's own macOS gate and it is currently not load-bearing.
6. **The two Hako lines have diverged.** `hako-ui` (with `check-iphone-hako-freeze.sh` and its
   byte-identical-upstream assertion for `SFI/MainView.swift`) is a *different* branch from
   `jiejiebox/integrated` (which has `SFIUIFamily` and the generated pages). The freeze guard
   that protects the frozen iPhone UI exists on the branch the parent no longer pins.
7. **Snapshot tests were not run.** The navigation suite answers this round's question
   (is the phone running Hako?) directly, and the snapshot suite is the more expensive one.
   Unrun is unrun, and it is recorded as such.

---

## 10. Release Recommendation

# READY WITH NON-BLOCKING NOTES

**Why not READY:** two things are true and neither is a defect in the iOS product.

* `HakoScreenState` does not compile, so the tree's own test story is incomplete.
* The parent's gitlink still points at a revision that does not build. This report verified
  `2a18968 + six commits`; `READY` would require the pin to name that.

**Why not NOT READY:** every gate the iOS product depends on passes at a single, pushed,
recorded revision — `SFI` device, `SFM` macOS, iPhone simulator, iPad simulator, 18/18
navigation UI tests, 24/24 SwiftPM tests, and the Apple layers of the ABI gate with 667 Swift
sources swept. The two defects that made the pinned revision unbuildable are fixed with
evidence, and the fixes are on the remote.

### What the user owns

* **The parent gitlink.** Deliberately not moved. The commits to move it to `7b7d638` exist
  locally in the parent (`b633d0b1d`, `837b14923`) and were **not pushed** — the user asked for
  the client repository only. A clean clone gets a non-compiling client until this moves.
* **The kernel repository**, which was not modified.

### Suggested next round

1. Move the parent pin to `7b7d638` and re-run `check-libbox-abi.sh`.
2. Fix `HakoScreenState`'s three errors.
3. Fix the `restore_*.py` path defaults and do the structural guard repair for the remaining
   twenty files, then re-run `check_hako_macos_parse.py` **and** a real `SFM` build — the
   checker alone has been shown insufficient.
4. Add a compact-width case to `SFIUITests` so §5.3 becomes evidence rather than inference.
