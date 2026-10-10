# Snapshot fixture contract

What the app's screenshot fixture reads, what each input does, and what cannot be driven from a
test. This exists because the fixture had **no single owner**: the same state was written at the
point of use in several places, tests asked for states through a variable the app never read, and
the result was four snapshot cases asserting against launches that had never happened.

Read this before adding anything to the fixture, and put it where the other fixture state lives.

---

## The complete set of inputs

There are four, and nothing else. Verified by sweeping the whole source tree:

```bash
grep -rn "ProcessInfo.processInfo.arguments\|ProcessInfo.processInfo.environment" \
  --include=*.swift Library/ ApplicationLibrary/ SFI/ MacLibrary/ SFT/
```

The same sweep, run over the whole tree, also finds `SSH_AUTH_SOCK` in
`Library/Network/UserServiceEndpointPublisher.swift`. That is not a fixture input — it is how a
remote profile finds the user's SSH agent — and it is named here so the next reader does not
mistake a hit for a fifth variable.

| Input | Who sets it | Where it is read | What it selects |
| --- | --- | --- | --- |
| `-FASTLANE_SNAPSHOT` | `SnapshotHelper.setupSnapshot`, added to **every** UI-test launch | `Variant.screenshotMode` | use fixture data at all |
| `SCREENSHOT_PAGE` | `SFIUITests/SnapshotTests.swift:10`, `SFMUITests:18`, `SFTUITests:12` | `SFI/HakoPhoneRootView.swift:50`, `SFI/MainView.swift:15`, `MacLibrary/MainView.swift:33`, `SFT/MainView.swift:12,46` | which page the app opens on |
| `SCREENSHOT_LANGUAGE` | `SFMUITests/SnapshotTests.swift:43`, `SFTUITests:37` (iOS leaves it to fastlane) | `Library/Shared/ScreenshotLocalization.swift:18` | the fixture's language |
| `SCREENSHOT_LOCALE` | external — nothing here sets it | `Library/Shared/ScreenshotLocalization.swift:25` | the fixture's locale |

Two of these are worth stating precisely, because assuming a uniform mechanism is how the fixture
went wrong in the first place:

* `SnapshotHelper.setLanguage` does **not** set `SCREENSHOT_LANGUAGE`. It passes
  `-AppleLanguages` as a launch argument. The environment variable is a separate, optional
  override that only the macOS and tvOS suites set in this tree, and that fastlane sets when it
  drives the iOS suite. An iOS run without fastlane gets fixture data in the simulator's language.
* `SnapshotHelper.setLocale` sets **nothing** on the app at all — it only reads `locale.txt` into a
  static. `SCREENSHOT_LOCALE` reaches the app when something outside this tree supplies it.

### Not inputs, despite appearing in test files

* **`SCREENSHOT_STATE`** — read by nothing in the app. It is the *carrier* for a per-case state, but
  it is interpreted in exactly one place: `Variant.uiTestFixtureState`.
* **`SCREENSHOT_APPEARANCE`** — read by nothing. A capture's light appearance comes from the
  simulator's own setting, not from this variable.

Asking for a state through a variable the app does not read is the failure mode this document
exists to prevent, and it is silent: the launch succeeds, the test runs, and the assertions
describe a screen the app was never asked for.

---

## The two selections, and why there are two

```
Variant.screenshotMode        "is a UI test driving this launch"   - one bit, 40 call sites
Variant.uiTestFixtureState    "which fixture did it ask for"       - gated,    opt-in
```

`screenshotMode` cannot answer the second question, because `-FASTLANE_SNAPSHOT` is present for
every suite. Two cases need the same launch to differ:

* `test14OutboundModeIsAbsentByDefault` asserts that a configuration defining no outbound modes
  shows no mode control, so the fixture's three Clash modes must **not** be installed.
* `test14bOutboundModeWhenTheConfigurationDefinesIt` drives those three modes and asserts selection,
  so they must be.

### The gate

```swift
guard ProcessInfo.processInfo.arguments.contains("-ui_testing") else { return nil }
guard let state = ProcessInfo.processInfo.environment["SCREENSHOT_STATE"], !state.isEmpty else { return nil }
```

**Both halves are required**, and the gate is evaluated in one place. A production launch carries
neither, so the result is `nil` and every default path is unchanged. A UI-test launch that names no
state also gets `nil`, which is what keeps the cases that use the whole fixture working as before.

Switches that read this state go through `uiTestFixtureState` rather than reading
`SCREENSHOT_STATE` themselves — see `Variant.usesMockTunnelProfile` — so the name has exactly one
interpreter and a new switch cannot become a second one by accident.

---

## States

| State | What it changes | Consumer |
| --- | --- | --- |
| *(none)* | nothing — the full fixture | every case that needs no variation |
| `noClashModes` | `setupMockData()` installs an empty `clashModeList` instead of `rule`/`global`/`direct` | `test14` |
| `notInstalled` | `ExtensionEnvironments.reload()` presents no tunnel profile (`usesMockTunnelProfile`) | `test18` |
| `profileError` | sets `profileLoadFailure`, so the page draws its "could not read the configuration" line — with the tunnel **installed**, because that is the only state in which the page reports a failed read | `test15` |
| `activity` | seeds four high-density connection rows at the display layer (`ConnectionDataModel.seedDataDensityFixture()`) | `test43` |

**Three states are implemented**, and the whole list of places any is read is:

```
$ grep -rn 'uiTestFixtureState' --include=*.swift Library/ ApplicationLibrary/ SFI/
Library/Network/CommandClient.swift:181                  != "noClashModes"
Library/Network/ExtensionEnvironments.swift:273          == "profileError"
ApplicationLibrary/Views/Connections/ConnectionListViewModel.swift  == "activity"
```

### Names the tests pass that nothing implements

Two cases call `launch(state:)` with a name this project does not act on. That is **not** an
error in itself — a launch with an unrecognised state is simply a launch with no state, which is
the full default fixture — but it is worth knowing which cases are relying on that rather than on
a state:

| Name | Asked by | What actually happens |
| --- | --- | --- |
| `clashModes` | `test14b` | the default fixture, which already installs the three modes. The name documents the intent; the default is what satisfies it |
| `remote` | `test16` | the default fixture. The case passes on the remote-control shape the default already draws |

So a name in this table is a **comment**, not a contract. If a case ever needs its name to mean
something, it has to be added above and read in exactly one place.

`notInstalled` needs its own switch rather than a narrowing of `screenshotMode` for a specific
reason: the branch it guards is the **early return** that also stops the real profile lookup from
running, so keying the profile on the same bit is what made "the tunnel is not installed"
unreachable in the first place.

The fixture's groups are defined **once**, in `Library/Shared/ScreenshotFixtureGroups.swift`, and
published by `CommandClient.setupMockData()` so that the sheet (which seeds its view model from the
same call) and Home (which reads `CommandClient.groups`) count the same groups. They used to be
written twice, once per consumer, and only one copy was installed — which is why
`test17HomeAgreesWithTheProxySheet` was reading a fixture-invented `2` against a live `0`.

---

## What cannot be driven from a test

Two states look like fixture gaps and are not:

* **A failed profile load, on the real path.** `ExtensionProfile.load()`'s error is discarded by
  `try?` in `reload()`, so a genuine failure still renders as "no tunnel is installed". The
  `profileError` state above makes the page's own line *reachable and assertable*, but it does not
  make the product populate it: that needs `reload()` to keep the reason and a decision about the
  sentence a user reads. The plumbing exists (`ExtensionEnvironments.profileLoadFailure`,
  supplied by `HakoPageContent`); only the fixture sets it today.
* **Connection rows, on the real path.** `ConnectionListViewModel` fills `connections` from
  `commandClient.$connections`, a `[LibboxConnection]` — and `LibboxConnection` is a Go-bound type
  with **no Swift initializer**, so no test can construct one. `test43` is satisfied by seeding
  `Connection` (this client's own struct) at the display layer instead, which is where the values
  are laid out anyway. Nothing about the production path changed.

---

## What reports are *not* fixture-backed

`test34OutOfMemoryReportListAndDetail` and `test36PowerReportListAndDetail` assert that a report
"must appear in the list", and no fixture seeds one. The managers write real files into the working
directory's `oom_reports` and `power_reports`, so those two cases depend on **simulator state** and
can drift between runs on a simulator that has been driven repeatedly. They failed on a later full
run of the same suite and passed on an earlier one; the change under test was removed and they
failed identically, which is how they were shown not to be a regression.

---

## Adding a state

1. Add the name to the table above.
2. Read it through `uiTestFixtureState`, never `SCREENSHOT_STATE` directly.
3. Put the state's data in one place that every consumer reads — not one copy per view.
4. Ask it from the case with `launch(state:)` in `SFIUITests/HakoSnapshotUITests.swift`.
5. Prefer the smallest change that makes the case mean something. A fixture that hardcodes what a
   case asserts is a case asserting on nothing; that is the defect this whole document describes.

## Running it

```bash
xcodebuild test -project sing-box.xcodeproj -scheme SFI -configuration Debug \
  -destination 'platform=iOS Simulator,id=<sim>' -derivedDataPath /tmp/dd-ios-signed \
  -parallel-testing-enabled NO -only-testing:SFIUITests/HakoSnapshotUITests \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  APP_GROUP_IDENTIFIER=group.io.nekohasekai.sfamt BASE_PACKAGE_IDENTIFIER=io.nekohasekai.sfamt
```

`-parallel-testing-enabled NO` matters: the cases share one simulator and one app instance.
