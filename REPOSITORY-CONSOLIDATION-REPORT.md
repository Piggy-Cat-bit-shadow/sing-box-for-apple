# Repository Consolidation Report — Apple client

Round: repository consolidation / branch merge / commit tidy-up.
Date of the round: 2026-10-11.
Scope executed in this round: **the Apple repository** (`Piggy-Cat-bit-shadow/sing-box-for-apple`)
and the parent repository's Apple pin. The **core** repository is out of scope by instruction and
is recorded in §11 rather than modified.

---

## 1. Executive Summary

| | |
|---|---|
| **Apple canonical branch** | `main` |
| **Apple final SHA** | `2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a` |
| **Apple default branch** | `main` (was `dev`) |
| **Apple remaining branches** | `main`, `dev` |
| **Core canonical branch** | `testing` (not modified this round — see §11) |
| **Core final SHA** | `origin/testing` = `d4241e1685f2139eee9680791a7be16e7fbe4430`, unmodified by this round |
| **Parent Apple pin** | `clients/apple` = `2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a` (**MATCH = YES**) |
| **Old branches deleted** | 15 remote branches |
| **Archive tags created** | 7 |
| **Commits added** | Apple: `f8f978c` (hardening port), `39e30a4` (branch roles / README / metadata), `48bd4b7` (this report). Parent: `414295fe7` |

**Result: the Apple repository now has exactly one product line (`main`), one upstream reference
line (`dev`), and no construction branches.** All historical lines are preserved as tags, and no
unique fix was discarded: the one commit on the entire remote that was genuinely absent from the
product line was ported in full and its content verified file-by-file.

---

## 2. Before / After

### Before — real remote state, measured after `fetch --all --tags --prune`

```text
sing-box-for-apple
├── main                     ab33c3f08   (old product line, 1 non-equivalent commit)
├── dev                      d1224bb50   (GitHub default branch)
├── stable                   0b84ea472
├── hako-ui                  d5b2c31e7
├── ipad-upstream-ui         816600ab3
├── fix/apple-notify-unknown dd9114d9a
├── fix/libbox-stringbox-callsites  2b23330d4
├── jiejiebox/integrated     3a550d0de   (the de-facto product line)
├── jiejiebox/v0.1.6-hardening      ff849cc21
├── jiejiebox/hako-ui-migration-wip 052f06b19
├── r8/a-generator           cca3ee446
├── r8/b-boundary            3e354edf5
├── r8/c-platform            80eec7eac
├── r8/d-reach               e1cefe648
└── r8/main                  2a189686a
```

Tags before this round: `iphone-hako-ui-freeze-v1`, `libbox-stringbox-abi-1`,
`libbox-stringbox-abi-2`.

### After

```text
sing-box-for-apple
├── main    2298d2c9c   (JiejieBox Apple product line; GitHub default branch)
│           Reached as f8f978c (hardening port) -> 39e30a4 (branch roles, README, metadata)
│           -> a09194e -> 48bd4b7 -> 1f94cdbd8 -> 2298d2c9c (the report itself). See §8,
│           "Reading the pinned SHA": a literal here is a snapshot, the commands are authority.
└── dev     d1224bb50   (upstream synchronisation / reference; read-only)
```

Archive tags after this round:

```text
archive/hako-design-v1                          c1935cff7
archive/old-main-2026-10-11                     ab33c3f08
archive/pre-consolidation-2026-10-11            3a550d0de
archive/ipad-upstream-port-final                816600ab3
archive/r8-final                                2a189686a
archive/hardening-wip-2026-10-11                052f06b19
archive/apple-consolidated-candidate-2026-10-11 2298d2c9c
```

`archive/apple-consolidated-candidate-2026-10-11` was first cut at `39e30a4fe` and moved forward to
the final `2298d2c9c` once this report was added, so it names the validated end state rather than
an intermediate one.

---

## 3. Apple hardening absorption

`origin/jiejiebox/v0.1.6-hardening` diverged from the product line by exactly one commit:

```text
merge-base(consolidation/apple-main, hardening) = 220785214284e32d7075f42f33bc49bc18e626d1
hardening tip = ff849cc214203b38ce449550aab014374c52c648 = (merge-base + 1)
canonical was 47 commits ahead of the merge-base
git cherry -v → a single '+': ff849cc
git patch-id --stable → b4081456126677e670c814f6c127dc580583c7f8
```

### The four questions

**Q1. Does this patch already exist on the product line under a different SHA?**
**No.** No commit on the canonical line carries an equivalent patch. `git patch-id` matches nothing
there, and a content comparison confirmed the canonical tree was missing every one of the four
files' changes.

**Q2. Is the patch-id equivalent?**
**No.** `ff849cc`'s patch-id (`b4081456…`) matches nothing on the canonical line. It is not a
rebased duplicate — it is genuinely absent.

**Q3. If not patch-equivalent, is the fix already covered by a later implementation?**
**No, and this is the finding that mattered.** The canonical line had independently absorbed
*part* of one file (an unlock rule), but:
- `Library/Network/ExtensionProvider.swift` — **entirely absent.** Canonical still had both
  `commandServer!` force-unwraps and no start-transaction rollback.
- `Library/Network/ScreenStateObserver.swift` — the generation/token critical-section fix absent.
- the test fixture repairs — largely absent.
- `docs/SCREEN-STATE-FACTS.md` — unchanged since the merge-base.

**Q4. Do the regression tests exist and pass on the canonical line?**
Before the port, **no**: the two cases that exercise the defects
(`testCancelDuringStartDoesNotLeaveAStartedButDeadObserver`,
`testACallbackQueuedBeforeACancelDoesNotPublishAfterARestart`) did not exist. After the port they
do, and the suite is 35/35.

### Disposition

**Ported in full**, as commit `f8f978c`, into `main`.

Verification that nothing was lost (diff of each `ff849cc` file between hardening and `main`
after the port):

| File | Result |
|---|---|
| `Library/Network/ExtensionProvider.swift` | **IDENTICAL** to hardening |
| `docs/SCREEN-STATE-FACTS.md` | **IDENTICAL** to hardening |
| `Library/Network/ScreenStateObserver.swift` | hardening + **9 added lines**, **0 removed** |
| `Tests/…/ScreenStateObserverTests.swift` | hardening + 17 added, −6, all accounted for below |

Not a wholesale cherry-pick. Two deliberate reconciliation edits were made, and both are
documented in the commit:

1. **`ScreenStatePolicy.decide`** — the canonical line had added a rule-5 guard
   (`if fact == .unlocked, lastObserved != 1 { refuse }`) that hardening's branch predates.
   Hardening's truth table therefore asserted that an unlock with no prior read *may* publish.
   The guard is the correct semantics (`.unlocked` is the fact that lifts the device pause, and a
   `0` from an axis whose prior value is unknown is indistinguishable from the never-set `0` that
   rule 4 already refuses on a snapshot), so the **guard was kept** and hardening's truth-table
   arm was rewritten to `last == 1` — the form the canonical line already used. The hardening
   implementation was taken with **zero lines lost** (639 → 648 = +9 guard lines only).
2. **`testDisplayOnNeverReachesAWakeEntryPoint`** — hardening's version delivered a lone
   display-on; the canonical version drove display-off *then* display-on, which is strictly
   stronger because it asserts the resume *edge*. The stronger form was kept and adapted to
   hardening's new `setState` fixture API.

No test that existed before the port was dropped, and **no test lost an assertion** (verified by
comparing assertion counts per test body between the pre-port and post-port files).

---

## 4. Core hardening absorption

**Not executed in this round** — the core repository is handled separately by the operator, by
explicit instruction. What this round measured for the record:

```text
origin/testing              d4241e1685f2139eee9680791a7be16e7fbe4430
origin/jiejiebox/v0.1.6-hardening  8d6a326d25f1d21da34854b3a07f83f1afb6dabe
```

The hardening branch exists on the core remote and is untouched by this round. The audit the
prompt specifies (`git cherry`, `git patch-id`, `CORE-HARDENING-UNIQUE.md`, subsystem-grouped
absorption, `go test ./...`) remains **open work** and is listed in §10.

One core observation **was** made, because it blocked an Apple gate and is unrelated to Apple:
`scripts/ci/check-libbox-abi.sh` reports two layer-4 (client sweep) violations in `clients/android`
— `Wrappers.kt:49` and `PlatformInterfaceWrapper.kt` read the migrated `StringBox` without its
accessor. These reproduce on the unmodified tree, are Android-only, and were left alone.

---

## 5. Apple branch disposition

| Branch | Final action | Why |
|---|---|---|
| `jiejiebox/v0.1.6-hardening` | **PORTED → DELETE** | Sole non-equivalent commit `ff849cc`; ported as `f8f978c` with 0 lines of its content lost |
| `jiejiebox/integrated` | **DELETE** | Contained in `main`; `nonEq = 0`. Archived as `archive/pre-consolidation-2026-10-11` |
| `jiejiebox/hako-ui-migration-wip` | **DELETE** | `nonEq = 2`: `ff849cc` (ported) and `052f06b`, which is a **regression** against `main` (10 733 deletions vs 1 832 insertions — it removes migration tooling and adds nothing `main` lacks). Its tip contains the hardening tip, so one tag covers both |
| `origin/main` (old) | **FORCE-UPDATE to `main`** | Archived first as `archive/old-main-2026-10-11`; moved with `--force-with-lease`, never bare `--force` |
| `fix/apple-notify-unknown` | **DELETE** | `dd9114d` was already absorbed as `f77289f` (proven an ancestor of `main`). `d1224bb` is an upstream version bump. `f8ad6d0` is an **upstream SagerNet commit**, superseded by the fork's own rewrite |
| `fix/libbox-stringbox-callsites` | **DELETE** | Its StringBox accessor fixes are present in `main` (`ExtensionPlatformInterface.swift` reads `.value` at every call site, and the app compiles and links against the real framework). `main`'s copy is a different lineage. Final state retained by the pre-existing `libbox-stringbox-abi-2` tag |
| `hako-ui` | **TAG + DELETE** | `nonEq = 98`, but it is `upstream/dev`-era history re-created on the canonical line. Its unique value is iPhone **design truth**, which `archive/hako-design-v1` @ `c1935cf` now carries — and which `main`'s `HakoStyle/` files already cite as their source |
| `ipad-upstream-ui` | **DELETE** | All five claimed artifacts verified present in `main`: `SFI/MainView.swift` and `MacLibrary/MainView.swift` are **blob-identical to `upstream/dev`**, and `SFIUIFamily.resolve(idiom:)` is present and idiom-only (no size class), so a compact iPad cannot fall into the Hako shell. Retained as `archive/ipad-upstream-port-final` |
| `r8/a-generator` | **DELETE** | `git merge-base --is-ancestor` → **ancestor of `main`**. `SAFE_TO_DELETE` |
| `r8/b-boundary` | **DELETE** | ancestor of `main` |
| `r8/c-platform` | **DELETE** | ancestor of `main` |
| `r8/d-reach` | **DELETE** | ancestor of `main` |
| `r8/main` | **DELETE** | ancestor of `main`; covers all four `r8/*` phase branches, which are ancestors of it. Retained as `archive/r8-final` |
| `stable` | **DELETE** | ancestor of `main` (274 behind). No release script, workflow or README references it as a branch |
| `dev` | **KEEP** | Upstream synchronisation / reference line. Also the pre-round default branch |
| `main` | **KEEP** | The canonical product line |

### Deletion gate

Per the prompt, every candidate was re-checked against `main` immediately before deletion with
`git log --left-right --cherry-pick --oneline`. Six branches still showed `+` lines after
patch-equivalence filtering (`hako-ui` 98, `fix/libbox-stringbox-callsites` 94, `ipad-upstream-ui`
91, `fix/apple-notify-unknown` 3, `jiejiebox/hako-ui-migration-wip` 2, `jiejiebox/v0.1.6-hardening`
1) and **none of them was deleted on the strength of that count**. Each was audited individually
and the evidence is the column above. The remaining nine were `nonEq = 0` and provably safe.

Deletions were issued in five small batches rather than one command, after
`git fetch --all --tags --prune` and a clean-worktree check, so each is traceable.

---

## 6. Archive Tags

| Tag | Commit | Purpose |
|---|---|---|
| `archive/hako-design-v1` | `c1935cff7` | iPhone Hako design baseline; the frozen design truth the phone UI is built from. Replaces the `hako-ui` branch |
| `archive/old-main-2026-10-11` | `ab33c3f08` | Apple `main` immediately before this consolidation |
| `archive/pre-consolidation-2026-10-11` | `3a550d0de` | The `jiejiebox/integrated` product line at the moment of consolidation |
| `archive/ipad-upstream-port-final` | `816600ab3` | iPad upstream port line final tip |
| `archive/r8-final` | `2a189686a` | Round-8 construction line final tip; covers `r8/a-generator`, `r8/b-boundary`, `r8/c-platform`, `r8/d-reach` (all ancestors of it) |
| `archive/hardening-wip-2026-10-11` | `052f06b19` | The parked Hako-migration WIP tip, which **contains** the hardening tip `ff849cc` |
| `archive/apple-consolidated-candidate-2026-10-11` | `2298d2c9c` | The validated canonical candidate. **Not a release tag** |

All seven verified pushed with `git ls-remote --tags origin`.

### A retention dependency that had to be found, not assumed

The three tags that already existed before this round are **not** ancestors of `main`, and all
three are reachable *only* from branches this round deletes:

```text
libbox-stringbox-abi-1   (8599039f6)  origin/fix/libbox-stringbox-callsites, origin/hako-ui
libbox-stringbox-abi-2   (2b23330d4)  origin/fix/libbox-stringbox-callsites, origin/hako-ui
iphone-hako-ui-freeze-v1 (fc7f77b82)  origin/fix/libbox-stringbox-callsites, origin/hako-ui,
                                      origin/ipad-upstream-ui
```

Had they been deleted with the branches, or had the branches been pruned with `--prune` against a
remote that dropped tags, that content would have been orphaned. They were enumerated and their
targets resolved **before** any deletion.

---

## 7. Final build / test matrix

All results below were produced on this host in this round. Nothing is carried over from an
earlier report.

### Apple

| Check | Command | Result |
|---|---|---|
| SFI (iOS) build | `xcodebuild -scheme SFI -destination 'generic/platform=iOS'` | **`** BUILD SUCCEEDED **`** |
| SFM (macOS) build | `xcodebuild -scheme SFM -destination 'generic/platform=macOS'` | **`** BUILD SUCCEEDED **`** |
| `HakoScreenState` tests | `swift test` in `Tests/HakoScreenState` | **35 tests, 0 failures** (33 before the port; +2 from `ff849cc`) |
| `HakoSubscriptionUsage` tests | `./scripts/run-subscription-usage-tests.sh` | **24 tests, 0 failures** |
| UI boundary audit | `python3 scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e` | **PASS 19 / FAIL 0 / UNKNOWN 0 / UNDECIDABLE 0** |
| iPhone simulator | `simctl` + `SFIUITests` | **NOT RUN — `ENVIRONMENT_BLOCKED`** |
| iPad simulator | — | **NOT RUN — `NEEDS_DEVICE`** |
| macOS runtime | — | **NOT RUN — `NEEDS_DEVICE`** |
| Device / NetworkExtension | — | **NOT RUN — `NEEDS_DEVICE`** |

Both build commands require `-skipPackagePluginValidation`: `SwiftLintPlugin` is a transitive
dependency and `swiftlint` is not installed on this host, so Xcode fails at *plugin validation*
with `Validate plug-in "SwiftLint"` before the `DISABLE_SWIFTLINT` gate inside the plugin can run.
This is a host fact, not a code defect.

### Per-platform routing (verified statically, not on a device)

```text
SFI/Application.swift
└── SFIUIFamily.resolve(idiom:)     reads the idiom and nothing else
    ├── .phone  → HakoPhoneRootView   iPhone  → Hako
    └── default → MainView            iPad, macOS → upstream
```

`resolve` is a pure function of `UIUserInterfaceIdiom`; `horizontalSizeClass` is never consulted,
so Split View / Slide Over / Stage Manager / a narrow window cannot move an iPad into the phone
shell. `SFI/MainView.swift` and `MacLibrary/MainView.swift` are blob-identical to `upstream/dev`.

### Non-green checks, and why neither is a regression

| Check | Status | Assessment |
|---|---|---|
| `scripts/dev/test_audit_apple_ui_boundary.py` | 1 case red: `upstream-file-edited: expected FAIL naming the file, got PASS` | **Pre-existing.** Reproduces identically at `f8f978c`, whose only delta from the pre-round canonical tip is the four `ff849cc` files — none of which is a UI file or an audit script. `ff849cc`'s message reports the same `fix(audit)` symptom independently |
| `scripts/dev/check-hako-primary-route.sh` | `error: cannot find 'HakoSettingsPush' in scope` | **Pre-existing.** The script and the tree are identical at `3a550d0`; `HakoSettingsPush` is declared in `HakoSettingView.swift` and is simply not resolvable by this standalone check |

Neither was silenced, and no assertion or test was skipped to obtain a green result.

### Core

Not run this round (§4).

---

## 8. Parent pin verification

```text
parent clients/apple gitlink:  2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a
Apple main:                    2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a
MATCH = YES
```

Independently confirmed through the repository's own tooling rather than by eye:

```text
$ scripts/ci/apple-client-source.sh sha ios
2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a
$ scripts/ci/apple-client-source.sh sha macos
2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a
$ scripts/ci/apple-client-source.sh assert-shared-source
PASS: iOS and macOS share Apple source 2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a
```

**Source selection is still one repository / one SHA / two products.** No per-platform Apple SHA
was reintroduced. `scripts/ci/check-libbox-abi.sh` layer 5 now reports
`PASS: apple gitlink is the verified revision (2298d2c9c87c)`.

The parent's submodule checkout was aligned to the new pin; the parent working tree carries no
tracked modification to `clients/apple`.

### A correction made during this round

`git add clients/apple` **re-stages the submodule's currently checked-out SHA**, silently undoing
an `git update-index --cacheinfo` performed first. The first attempt therefore committed the *old*
revision while its message described the new one. Caught by re-reading the commit with
`git ls-tree HEAD clients/apple`, and fixed by re-running `update-index` and amending with
`git commit --amend` **without** a trailing `git add`. The recorded pin is now `2298d2c9c87c`, as
the message states.

### Why the pin was restated more than once

This report is itself a commit on `main`, so writing it moved `main` and invalidated the pin that
had just been set — and moving the pin moves the parent commit that records it. The sequence was:
pin to `39e30a4fe`, add the report (`a09194e`), re-pin and move the candidate tag, correct the SHA
values it quoted (`48bd4b7`), re-pin again, correct them once more (`2298d2c9c`). The values quoted
in §1, §6 and §8 are the state after the last of those steps.

The dependency chain is worth stating plainly, because it is the thing that makes this kind of
round error-prone:

```text
Apple main changes  ->  parent clients/apple gitlink must change
                    ->  check-libbox-abi.sh VERIFIED_APPLE_SHA must change with it
                    ->  editing either file is a NEW PARENT COMMIT, not a new Apple commit
```

An Apple-side *documentation* commit therefore costs three coordinated updates, and a report that
quotes the branch tip it is itself part of can never be finished by rewriting it — each rewrite
moves the tip.

### Reading the pinned SHA

Because of that recursion, **a literal SHA in this report is a snapshot, not the authority.** The
authority is the repository state, and it is one command away:

```bash
# the Apple revision the parent builds, and the only authority for it
git -C /Users/jie/Desktop/其他文件/sing-box ls-tree HEAD clients/apple

# the same value through the repository's own tooling - these must agree
cd /Users/jie/Desktop/其他文件/sing-box
scripts/ci/apple-client-source.sh sha ios
scripts/ci/apple-client-source.sh sha macos
scripts/ci/apple-client-source.sh assert-shared-source

# the value the ABI contract asserts, which must equal the two above
grep '^VERIFIED_APPLE_SHA=' scripts/ci/check-libbox-abi.sh
```

At the time of writing, the values are:

```text
Apple main / parents clients/apple gitlink / VERIFIED_APPLE_SHA
  = 2298d2c9c87c2f74aaa689b3bcc5e593dcbc5e1a
  = the commit that carries this report, i.e. the tip of main
```

If a later commit is added to `main`, that literal becomes stale while everything above stays
true — which is exactly why the commands, not the literal, are what a reader should trust.

An Apple-side *documentation* commit therefore costs three coordinated updates, and the last step
of this round is a pin update carrying no further Apple content.

---

## 9. README / metadata changes

| File | Change |
|---|---|
| `README.md` | Branch roles rewritten (`main` product, `dev` reference); the seven-branch construction table replaced by the archive tags that now carry that content; every `hako-ui` reference repointed to `archive/hako-design-v1` + SHA; **Build and Validation Status rewritten** from "maintained on Windows, Xcode and `swift test` impossible" to the measured results above, with `NEEDS_DEVICE` for the device axis; "known incomplete" list corrected (the Hako page migration and the StringBox question are both closed); build commands now carry `-skipPackagePluginValidation` with the reason |
| `BRANCH-INVENTORY.md` | **New.** Every remote branch with head, date, ancestry, ahead/behind, patch-equivalence count and disposition; the tag retention dependency; the method used |
| `release/apple-client-refs.env` | `APPLE_CLIENT_BRANCH` `jiejiebox/integrated` → `main`. `IOS_APPLE_BRANCH=hako-ui` **deleted** and replaced by `HAKO_DESIGN_BASELINE_TAG=archive/hako-design-v1`. The variable was already dead — `platform_branch` answers with `APPLE_CLIENT_BRANCH` for both platforms and deliberately does not fall back to it |
| `scripts/ci/check-libbox-abi.sh` | `VERIFIED_APPLE_SHA` `2a189686ae38` → `2298d2c9c87c`, so layer 5 asserts agreement with the pin this round set |
| `docs/SCREEN-STATE-FACTS.md` | Updated by the ported `ff849cc` content (§4.4 verdict corrected, §4.5 rewritten) |

### Stale-reference sweep

```bash
git grep -n "jiejiebox/integrated|hako-ui|ipad-upstream-ui|r8/|v0.1.6-hardening|\
fix/libbox-stringbox-callsites|fix/apple-notify-unknown"
```

Classified, and only stale prose was changed:

- **runtime / build dependency** — none. No code path reads any of these names.
- **historical documentation, left intact** — `docs/HAKO-ROUND8-FINAL-DEBUG.md`,
  `docs/APPLE-ARCHITECTURE-AUDIT.md`, `docs/APPLE-REFACTOR-BASELINES.md`,
  `APPLE-UI-MAC-VERIFICATION-REPORT.md`, `docs/pending/*`. These are the historical record of
  what was done on those branches; rewriting them would destroy evidence. `README.md` now labels
  `docs/APPLE-REFACTOR-BASELINES.md` as a historical record whose listed branches no longer exist,
  so a future reader cannot mistake it for an active branch list.
- **stale prose, corrected** — `README.md` and `release/apple-client-refs.env`, as above.

---

## 10. Remaining manual actions

1. **Push the parent commit.** `414295fe7` is committed locally on the parent's `testing` branch
   and is **not pushed** (the parent is `2` commits ahead of `origin/testing`; the other is
   `837b14923`, pre-existing). Left for the operator because the core/parent push is being handled
   separately.
2. **Core hardening consolidation is entirely open** (§4): audit
   `origin/jiejiebox/v0.1.6-hardening` against `origin/testing`, produce
   `CORE-HARDENING-UNIQUE.md`, absorb per subsystem, run `go test ./...` and the repo's gates,
   then delete the hardening branch behind
   `archive/core-hardening-pre-consolidation-2026-10-11`.
3. **Two pre-existing Android ABI violations** in `check-libbox-abi.sh` layer 4
   (`Wrappers.kt:49`, `PlatformInterfaceWrapper.kt`). Android-owned; untouched.
4. **Two pre-existing red Apple checks** (§7): the `upstream-file-edited` negative case and
   `check-hako-primary-route.sh`. Both reproduce before this round's changes.
5. **Device-axis acceptance remains unperformed by nature**, not by omission: iPhone simulator UI
   tests are blocked by this host's CoreSimulator store (several devices carry `isDeleted = true`,
   so `simctl boot` answers `Unable to boot deleted device`), and **iPad and macOS cannot be tested
   on real hardware at all**. Nothing in this report should be read as a device result.
6. No branch protection was configured; none was configured before either.

---

## 11. Core repository — recorded, not executed

Measured for the record only:

```text
Piggy-Cat-bit-shadow/sing-box
  origin/testing                      d4241e1685f2139eee9680791a7be16e7fbe4430
  origin/jiejiebox/v0.1.6-hardening   8d6a326d25f1d21da34854b3a07f83f1afb6dabe
```

The two lines have diverged and the hardening branch is still present on the remote. No core
branch was created, merged, or deleted by this round, and no `go test` was run. The core's own
README currently describes the default branch as `testing`; that remains accurate.

The only core-side edits made were those required to complete the **Apple** pin, and they are
listed in §9: one gitlink, one release metadata file, one ABI constant.

---

## 12. Success criteria

```text
[x] Apple hardening unique fixes audited
[x] ff849cc proven present on the product line (ported; 0 lines of its content lost)
[x] Apple canonical build / tests pass          SFI + SFM BUILD SUCCEEDED; 35/35 + 24/24; audit PASS 19/FAIL 0
[x] Apple main points at the final validated SHA
[x] Apple default branch = main
[x] Hako design baseline tagged                  archive/hako-design-v1 @ c1935cf
[x] old main has an archive tag                  archive/old-main-2026-10-11
[x] WIP / r8 / fix / hako-ui / ipad branches cleaned per evidence
[x] dev kept as the upstream reference

[ ] Core hardening unique commits audited        §4 — deferred by instruction, still open
[ ] required fixes into testing                  §4 — deferred by instruction
[ ] core testing gates pass                      §4 — deferred by instruction
[ ] core hardening branch safe to delete         §4 — deferred by instruction

[x] parent clients/apple pin == Apple main final SHA
[x] source selection still one repo / one SHA / two products   assert-shared-source PASS
[x] release metadata no longer depends on a deleted branch

[x] both repositories have clean tracked state   parent: submodule aligned; Apple: 0 changes
[x] all archive tags pushed                      7/7 confirmed via ls-remote
[x] no unexplained unique remote commit deleted  every deletion has audited evidence in §5
```

The four unchecked items are the core repository, excluded from this round's scope by the
operator. **They are the only reason this report does not declare `REPOSITORY CONSOLIDATION
COMPLETE`.** The Apple objective — one product line, one upstream reference, no construction
branches, no lost fix — is met and verified.
