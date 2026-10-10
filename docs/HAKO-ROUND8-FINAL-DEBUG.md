# Round 8 — final integration debug record

The record of what was found and fixed in this round, by whom, with the evidence that each fix works and an
honest list of what still needs a Mac.

**This document does not claim an Apple build.** There is no Xcode, no Swift toolchain, no
`Libbox.xcframework`, no `GhosttyTerminal` framework and no iPhone, iPad or Mac in the environment these
fixes were made in. Every statement below is a source-level fact - a duplicated declaration, an unhandled
enum case, a missing call, an unguarded platform-only API, a check that could not fail - and every place
where a real build or a device would be needed says `UNVERIFIED`.

## Start and end state

| | |
|---|---|
| Start SHA | `e1cefe6484be9aff120600af449a7c45c3e030bc` (`jiejiebox/integrated`) |
| Local HEAD at start, verified against the remote | equal to `origin/jiejiebox/integrated`, working tree clean |
| Original iPhone UI baseline | `hako-ui@c1935cff77246f97498400f5a0a7f430cfabbd55` |
| Upstream comparison baseline | `SagerNet/sing-box-for-apple dev@089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| iPad reference | `ipad-upstream-ui@816600ab3f2823ab5de1da66e36433ef3a21fc10` (protected, not worked on) |
| Working branches | `r8/main` (integration), `r8/a-generator`, `r8/b-boundary`, `r8/c-platform`, `r8/d-reach`, `r8/e-redteam` |
| Isolation | one git worktree per worker, `_work/r8/w-*`, plus read-only reference worktrees under `_work/refs/` |

### An incident, recorded because it changed the environment

Partway through the round the main repository's `.git` directory at
`C:\Deepseek\IOS客户端\sing-box-for-apple` was destroyed: a recursive directory delete traversed a junction
(`_work/r8/w-*/sing-box-for-apple`, created so the tools' default `REPO` path could find the original) and
removed the shared git directory. The junction made a delete of a scratch directory reach into an unrelated
tree - the same class of mistake as following a symlink while walking a source tree, which is one of the
defects fixed below.

What was recovered, and how:

* the working trees of all 12 worktrees were untouched - only the shared `.git` and the per-worktree
  administrative directories, indexes and branch refs were gone;
* `.git` was rebuilt by `git init` plus a fetch of every ref from `origin` **and** `upstream`; nothing had
  been pushed, and no local commit was ahead of the remote, so no commit was lost;
* each surviving worktree was re-registered by writing its `gitdir`, `commondir` and `HEAD`, then verified
  by `git worktree repair` and a `rev-parse`/`status` per tree; indexes were rebuilt with `read-tree`;
* the two commits `r8/main` had at that moment were re-created from the files on disk, which were intact.

After the recovery, `git worktree list` reports all 12 trees, every branch head equals its worktree's HEAD,
and each tree's status shows exactly the files its owner changed. The junctions were removed rather than
recreated, and `scripts/dev/audit_apple_ui_boundary.py` now skips reparse points so the shape cannot recur
silently.

## Who did what

| Agent | Scope | Branch |
|---|---|---|
| main | integration, the four source-level P0 fixes, the platform-guard restorations, `audit_hako_lossless_parity.py`, the docs, the git and push | `r8/main` |
| A | generator safety: reproduce, root-cause, and rebuild `migrate_secondary_page.py` / `swift_directives.py` as a fail-closed, read-only-by-default tool | `r8/a-generator` |
| B | boundary audit: a reverse-routing contract that can go red, plus the negative cases that prove it | `r8/b-boundary` |
| C | cross-target truthfulness: platform gates, and the `--json`/text exit-code divergence | `r8/c-platform` |
| D | independent read-only reachability and runtime review of the final source | `r8/d-reach` |
| E | independent red-team debug of the final integrated SHA | `r8/e-redteam` |

D and E read the sources themselves and were given the baselines and SHAs, not the authors' conclusions. D
found four of the six source defects recorded below, including one that no static check in this repository
was looking for.

## Findings and fixes

### P0-1 — the iOS slice of `ApplicationLibrary` could not compile

`HakoStyle/HakoPrimaryShell.swift:96`. `NavigationPage` declares `.groups` and `.connections` under
`#if !os(tvOS)` (`ApplicationLibrary/Views/NavigationPage.swift:11-14`); `hakoPrimary` handled them under
`#if os(macOS)`. On iOS the cases exist and the switch does not handle them:

```
error: switch must be exhaustive
```

Gate changed to `#if !os(tvOS)`, which is also what `SFI/HakoPageContent.swift:69-74` already renders both
pages under. Fixed in `bce950c`; found by D.

This is the one change to a file the parity audit compared byte for byte, so that audit no longer
byte-compares `HakoPrimaryShell.swift`: a check that *requires* the compile error is not a check. It is
compared by the UI-token rules instead, with the divergence recorded in `DESIGN_SYSTEM_BY_TOKENS` and its
reason printed on every run.

### P0-2 — invalid redeclaration, on iOS *and* macOS

`HakoStyle/HakoReportShared.swift:118` and `:240`. `createReportZip(reportID:fileURL:cacheSubdirectory:
includeConfig:includeLog:encrypt:)` and `presentShareSheet(_:)` are module-scope free functions, so the
rename of the file's *types* into the Hako namespace could not touch them, and upstream's
`Tools/ReportShared.swift:108` and `:235` declare the same signatures under conditions that are live when
the Hako copies are:

```
error: invalid redeclaration of 'createReportZip(reportID:fileURL:cacheSubdirectory:includeConfig:includeLog:encrypt:)'
```

Both copies removed in `bce950c`; every caller already spelled the bare name. Found by D. An independent
brace-depth scan (`dup_module_scope.py`, run by the main agent) then confirmed the remaining module-scope
overlaps are all legitimate: fifteen `extension View` / `extension EnvironmentValues` / `extension
NavigationPage` pairs, which extend rather than redeclare, and one `private extension URL` pair, whose
members are file-scoped.

### P0-3 — the phone never connected the command client

`SFI/HakoPhoneRootView.swift`. The original opened the client from three places
(`up-hako@c1935cf ApplicationLibrary/Views/Dashboard/ActiveDashboardView.swift:105-116`: on appear, on
becoming active, and when the tunnel reported itself connected). Only the third had survived, attached to
the logs-selection hook. On a cold launch with a running tunnel the client was never connected, so
`HakoHomeView`'s Proxies row (`:572-574`, gated on a live `commandClient.groups`) and its outbound-mode card
(`:584-605`, gated on a live `clashMode`) both vanished - there was **no route from Home to Proxies at
all**, and `HakoGroupListView` cannot compensate because its own `connect()` passes no host and only seeds
the fixture list. Restored at all three sites in `bce950c`; found by D. This is the finding most likely to
have been visible to a user.

### P0-4 — Home's only action in the no-tunnel state was inert

`SFI/HakoPageContent.swift:114`. `installTunnel` was `{ await environments.reload() }`, and `reload()` only
*loads* an already-installed extension - `ExtensionProfile.load()` returns nil when there is no manager.
`ExtensionProfile.install()` had no caller anywhere on the phone's path, so the notice's Install action ran,
changed nothing and repainted: a refused system authorisation looked exactly like a press that had not
registered. The original's action restored with the error it reported
(`up-hako@ActiveDashboardView.swift:172-181`) in `bce950c`; found by D.

### P0-5 — `HakoLogView` named two types macOS does not declare

`HakoStyle/HakoLogView.swift`. Two separate references had lost the original's condition while the
declarations kept theirs:

* `:150` named `HakoLogMenuButton`, declared at `:178` inside `#if canImport(UIKit)`;
* `:514` named `HakoShareViewController`, declared at `:560` inside `#if canImport(UIKit)`, and the
  original's macOS arm had been dropped along with the reference's guard.

Fixed in `22c263c`. The macOS `HakoShareView: NSViewRepresentable` was restored rather than the reference
being guarded alone, because a guarded reference with no macOS arm compiles and presents an **empty** sheet,
which is not the original's behaviour and is exactly the kind of empty stand-in this round's rules rule out.
Found by C, verified against the original by the main agent.

### P0-6 — the generator silently overwrote hand-repaired pages

`scripts/dev/migrate_secondary_page.py`. Reproduced in isolation by A, and the reproduction is the
historical regression exactly: six report pages, six `--write` runs, six silent rewrites, **every exit code
0**. The list files lost their migrated detail constructor and the detail files lost their references to the
three types `Tools/ReportShared.swift` owns.

A's root cause is stated as a property, not a regex, and it corrects the main agent's first attribution:

> the tool regenerated the destination file purely from upstream text plus a rename map derived from that
> one source file, and wrote it over whatever was on disk unconditionally, with no comparison against the
> pre-image and no routing through any refusal. Any reference in that page to a type declared in a
> **different** upstream file therefore came back under its upstream spelling, because a page-local rename
> map cannot know that `Tools/ReportShared.swift` was migrated too.

The ordered blame is the unconditional overwrite, enabled by a per-page rename map. `retarget` is not
implicated - it only ever prepends `Hako`, and A demonstrated empirically that run over the repaired tree it
matched nothing at all in any of the 55 Hako files. A also recorded what was **not** the mechanism:
non-idempotence and double-prefixing were both checked and neither reproduces.

Two reproductions extend the blast radius well past the six files. A bulk re-run over all 66 pages left 33
modified files, 25 newly created files and a net `-682` lines, including new files that had deliberately
never been migrated, and rewrote the phone's own root file into `HakoNavigationPage(snapshotValue:)` /
`HakoDashboardViewModel()` - both type errors, because the phone's root must keep the shared
`NavigationPage` and `DashboardViewModel`. And `PORTED_UNWIRED` left a created target behind while reporting
failure, while a page whose only "caller" was a doc comment exited **0**.

Fixed by A on `r8/a-generator` (see the branch and the contract document for the exact contract).

### P1-1 — the profile-list failure was silent

`SFI/HakoPhoneRootView.swift:169`. `DashboardViewModel.reload()` records a failed read on its own `alert`
(`:72`); the iPad presents that alert (`DashboardView.swift:26`), and the phone bound its own state, which
only ever held URL-import failures. Home said "No profile selected" with no explanation and no retry. Both
alerts are presented now (`bce950c`); found by D.

### P1-2 — the New/Edit Server modal had no way out

`HakoStyle/HakoRemoteControlView.swift:121`. `ProfileSheetHelpers.swift` is official bytes again and its
`NavigationSheet` no longer grows a button an iPad would compile, so every phone modal carries
`.hakoModalClose()` itself. This was the one of five `NavigationSheet` sites on the phone path missing it -
More → Remote Control → "+" or a server row opened a sheet with no close. Fixed in `bce950c`; found by D.

### P1-3 — three ported files had lost a guard their original had

`ApplicationLibrary` is one framework target built for `appletvos`, `iphoneos` and `macosx`, and every file
under `Views/HakoStyle/` is a member of it through the synchronized root group. The migration resolved the
original's `os(...)`/`canImport(...)` conditions and kept the iOS arm:

| File | Was | Now |
|---|---|---|
| `HakoTerminalSessionContentView.swift` | no file-level `#if canImport(GhosttyTerminal)`, and `Color(uiColor:)` as the only colour arm | rebuilt from the original's own bytes: the guard is back, and the `#if os(iOS) / #elseif os(macOS)` split with it. The guard is load-bearing - the declaration reads `TailsshTerminalSurfaceView` and `TerminalWrapperViewModel`, both themselves behind it |
| `HakoGroupItemView.swift:94` | no conditional compilation at all, `Color(uiColor:)` the only arm | the original's three-way split restored |
| `HakoEditProfileView.swift:108` | `.navigationBarTrailing` unguarded | `#if os(iOS)` restored from the original |

Fixed in `bce950c`; found by D. `HakoSurface.swift` was checked and is **not** a case of this: its
`Color(uiColor:)` sits in the `#else` of `#if os(macOS) / #elseif os(tvOS) / #else`, so macOS never compiles
it, and a check that flags it would be wrong.

### P1-4 — the parity audit could not fail when it could not look

`scripts/dev/audit_hako_lossless_parity.py`. It searched for a checkout holding the pinned commit with
`os.path.isdir(os.path.join(candidate, ".git"))`. A linked worktree's `.git` is a **file** holding a
`gitdir:` pointer, so every worktree was rejected - including this round's own integration tree. The search
then fell through to its `UNKNOWN` branch, which printed "the original cannot be compared" and returned
**0**: a run that compared nothing exited exactly like a run that found a lossless port, and the
design-system byte comparison silently never happened. Fixed in `bcf7402`:

* worktrees are accepted, and every worktree of the tree the scripts live in is a candidate;
* the pinned commit is accepted by SHA as well as by the fork's branch names;
* `UNKNOWN` returns non-zero on both the text and `--json` paths, and both list what was tried and why each
  candidate was chosen;
* the run reports `coverage` - pages compared against expected, design-system files compared against
  expected - and an incomplete comparison fails.

`scripts/dev/test_fail_closed_exit_codes.py` pins it against the pre-fix script: five assertions red before,
all green after, with the healthy tree still passing at 6/6 pages and 9/9 + 1 design-system files.

### P1-5 — `--json` and text disagreed about the same tree

`scripts/dev/check_hako_macos_parse.py:97` was `return 0` inside the `if as_json:` branch, unconditionally,
while the text path computed `return 1 if (total or undecidable) else 0`. Reproduced by the main agent and
handed to C with the evidence:

```
--platform tvos         -> 9 file(s) could not be decided, EXIT=1
--platform tvos --json  -> {"failures": 0, "undecidable": 9}, EXIT=0     <-- false green
```

The JSON payload was honest; only the exit code lied. Fixed by C on `r8/c-platform`.

### P1-6 — the generated provenance headers named paths that do not exist

`retarget`'s pattern matches `Name.` as well as `Name(`, so running the generator over one page rewrote the
tool's own comment in other files: `ApplicationLibrary/Views/Tools/CrashReportListView.swift` became
`…/Tools/HakoCrashReportListView.swift`. Measured, not estimated: of the 33 `HakoStyle/Hako*.swift` files
carrying such a header, **29 named a path that does not exist** at the pin. A generated file that lies about
its own provenance cannot be checked against its original later, which matters in a round whose whole
subject is provenance.

Fixed in `0ea456b`: 29 files, one comment line each, verified to be comment-only (`29 insertions(+), 29
deletions(-)`, every added line a comment). The true source was not read back out of the header - it was
identified by content and confirmed structurally, by requiring the port's first declared `Hako…` type to be
`Hako` plus the original's first module-scope type. Two scripts come with it:
`scripts/dev/check_generated_headers.py` (fails if any header names a path absent at the pin) and
`scripts/dev/repair_generated_headers.py` (dry-run by default). All 33 headers now resolve. Found by A.

### What was checked and found sound

Recorded so the matrix cites real evidence rather than an absence of findings:

* Round 7's Home repairs are intact - `HakoHomeView.swift:124/208/217`, and the system-proxy path through the
  retained `OverviewViewModel` at `:490-492`;
* `restyled: true` is phone-only: `SFI/HakoPhoneRootView.swift:74` sets it, `SFI/MainView.swift:33-35` does
  not and the default is declared at `SFI/ProfileEditorWrapperView.swift:22`;
* all three report chains route to the correct report type, at both the construction site and the
  destination's own `let report:` read;
* exactly one close affordance on the configuration centre, the editor and the report share;
* `ProfileSheetHelpers.swift` and `NavigationSheetContent.swift` are official bytes again, with the phone's
  differences living in `HakoStyle/HakoSheetContent.swift`;
* the Proxies and Activity sheets are constructed correctly with one title owner;
* Logs' back control is single and its connect hook is present;
* Activity's never-clearing spinner is repaired in the right (shared) layer;
* SSH session exit and re-entry are sound;
* `.reportReceived`'s row-scoped receiver matches upstream's shape - parity, not drift;
* the config centre's selection not persisting to the running tunnel is **the original's behaviour**, not
  migration drift: `up-hako/…/Dashboard/Cards/ProfilePickerSheet.swift:138-141` is identical and up-hako
  never calls `switchProfile` outside tvOS. It is recorded as an oddity the iPad path does not share, not as
  a regression.

### Script false-greens closed

| Script | Was | Now |
|---|---|---|
| `audit_hako_lossless_parity.py` | exit 0 on `UNKNOWN`; rejected worktrees; no coverage report; an incomplete design-system comparison printed a count nobody checked | non-zero on both paths, worktree-aware, `coverage` reported, incomplete comparison fails |
| `audit_apple_ui_boundary.py` | walked into NTFS reparse points, so a junction inside the tree made `project-membership` enumerate another repository and report ~600 bogus failures | reparse points are skipped, with a negative case (agent B's scope; see B's report for the exact diff) |
| `check_hako_macos_parse.py` | `--json` always exit 0; unknown platform raised `KeyError`; no coverage statement | C's fix; tvOS stays `undecidable` and is reported as not verified |
| `migrate_secondary_page.py` | `--write` unconditionally, no pre-image comparison, no atomicity, `PORTED_UNWIRED` left a file behind | A's contract: read-only by default, refuse a differing target, stage-and-verify, refuse before writing |

## Commands and results

Run from the integration tree at the SHA named in the table. Every one was run through the bundled Python
3.12 with portable Git 2.50; full transcripts are in `_work/r8/evidence/`.

| Command | Result |
|---|---|
| `audit_apple_ui_boundary.py --upstream-ref 089d35e6… --strict` | `PASS 15  FAIL 0  UNKNOWN 0`, exit 0 |
| `audit_hako_lossless_parity.py` | verdict `STATIC_LOSSLESS_PORT_READY_FOR_APPLE_ACCEPTANCE`, lost UI tokens 0, 6 of 6 pages compared, 9 of 9 design-system files byte-identical plus 1 compared by tokens, exit 0 |
| `test_fail_closed_exit_codes.py` | 2 cases passed, 0 failed, exit 0 |
| `test_audit_apple_ui_boundary.py` | every negative case failed the audit as designed and the positive case passed, exit 0 |
| `check_hako_macos_parse.py --platform ios` | 0 unparseable, 0 undecidable, exit 0 |
| `check_hako_macos_parse.py --platform macos` | 0 unparseable, 0 undecidable, exit 0 |
| `check_hako_macos_parse.py --platform tvos` | 9 files **not checked** - no `canImport` table for tvOS - exit non-zero. Reported as not verified, never as a pass |
| `gate_hako_platform_imports.py --check` | 0 files to change, exit 0 |
| `wrap_hako_platform_declarations.py --check` | 0 files to change, exit 0 |
| `check_generated_headers.py` | 33 of 33 headers name a path that exists at the pin, exit 0 |
| `git diff --check` | clean |

### The fifteen checks, by name

`phone-entry`, `tablet-and-mac-entry`, `shared-pages-are-clean`, `no-reverse-dependency`,
`shared-declaration-duplicates`, `hako-symbol-completeness`, `hako-platform-imports`, `hako-page-coverage`,
`hako-feature-preservation`, `ipad-mac-ui-gate`, `upstream-files-untouched`, `project-membership`,
`branding`, `subscription-feature`, `repository-hygiene` - all `PASS`.

Two checks the handoff named as broken are **not** in the enforced set and were not silently switched on:
`hako-annotation-agreement` and `hako-type-has-caller`. `shared-declaration-duplicates` carries the
annotation-agreement class of defect and does catch it. See agent B's report for the disposition of each.

### Protected upstream files

`upstream-files-untouched`: **447 of 458** upstream files are byte-identical to
`089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85`. The 11 modified are all on the reviewed list and each carries
its reason, among them `ApplicationLibrary/Views/Connections/ConnectionListViewModel.swift` (a
cross-platform behaviour fix, with the argument for why it belongs in the shared view model rather than a
phone-only copy), `ApplicationLibrary/Views/Groups/GroupListViewModel.swift` (the additive `testingItems`),
and the additive subscription-info database migration.

`repository-hygiene`: `git diff --check` clean, `.gitmodules` blob `8117bd3f1eed` identical to upstream,
`Frameworks/Runestone` gitlink `baeb3cbf8332` identical to upstream, one submodule reported.

### The four frozen originals and the design system

The original UI is read from `hako-ui@c1935cff` by `git show`, and the audit names the checkout it read from
and why it chose it. The design system is compared two ways, with the split recorded rather than silent:

* **byte for byte, 9 of 9**: `HakoCard`, `HakoData`, `HakoEmptyState`, `HakoRow`, `HakoScaffold`,
  `HakoStatus`, `HakoSurface`, `HakoTheme`, `HakoUITrace`;
* **by UI tokens, 1**: `HakoPrimaryShell`, because `hakoPrimary`'s gate had to follow `NavigationPage`'s
  `#if !os(tvOS)` and byte equality with the original *is* the compile error (P0-1). Its token sets are
  compared, none is lost, and the one addition (`HakoPageContent` named in a comment) is reported on every
  run.

`hako-ui`'s `Views/HakoStyle/` listing also holds `HakoNavigation.swift` (added by this fork, not in the
original) and `HakoHomeView.swift` (a page, compared by tokens); both are documented in the audit beside the
list rather than being quietly absent from it.

## Still unverified

`UNVERIFIED` - needs Apple tooling, which does not exist here:

1. that `SFI` builds for `iphoneos` and for the iPad, and `SFM` for `macosx`. Schemes found in
   `sing-box.xcodeproj/xcshareddata/xcschemes/`: `SFI`, `SFM`, `SFM.System`, `SFT`, `JailbreakDaemon`;
   targets in the project: `SFI`, `SFM`, `SFM.System`, `SFT`, `SFIUITests`, `SFMUITests`, `SFTUITests`,
   `ShareExtension`, `ShareExtension.System`;
2. that `ApplicationLibrary` compiles for each of `iphoneos`, `macosx` and `appletvos` - the platform where
   every restored guard in this round matters;
3. that the pages draw, that navigation pushes as
   [`HAKO-REAL-REACHABILITY-MATRIX.md`](HAKO-REAL-REACHABILITY-MATRIX.md) says, and that the pixels match
   `hako-ui@c1935cf`;
4. whether `canImport(GhosttyTerminal)` is true for a given slice. The guards are correct either way; which
   way it resolves decides whether the terminal UI is present at all;
5. `.navigationBarTrailing`'s macOS availability, whether `canImport(GhosttyTerminal)` holds for the macOS
   slice, whether P0-3 bites on every launch or only some, and `NavigationLink(isActive:)` inside a
   `ScrollView` on iOS 15/16 - recorded by D as explicit `UNKNOWN`s with what would decide each.

The exact commands a Mac would run are in
[`APPLE-DEVICE-ACCEPTANCE.md`](APPLE-DEVICE-ACCEPTANCE.md); the schemes above are the ones that exist in the
project, read from it rather than guessed.
