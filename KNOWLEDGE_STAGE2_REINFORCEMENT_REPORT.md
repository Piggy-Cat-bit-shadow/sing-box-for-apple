# Knowledge Stage 2 — Reinforcement / Independent Review / Compression — Apple

Repository `Piggy-Cat-bit-shadow/sing-box-for-apple`. This report describes how the
Stage-1 knowledge base was re-audited, what was corrected, and where the evidence boundary
actually sits. It is history, not current truth.

---

## A. Baseline

| Field | Value |
|---|---|
| Repository | `Piggy-Cat-bit-shadow/sing-box-for-apple` |
| Repo kind | **APPLE** |
| Branch | `jiejiebox/ne-p3-code-closure` |
| Current HEAD | `aa1e9821bd10ca44c88c7d36b20a12e65cbfb565` (2026-10-12) |
| **Production baseline** | `f4a98590e9edaefc4a231b7f30d5b81a30917b66` (2026-10-11) |
| Knowledge revision | `aa1e982` — docs only, **not** a product SHA |
| Release baseline | **none recorded** — no archive/export/upload on this line |
| Upstream pin | `SagerNet/sing-box-for-apple`, `upstream/dev` @ `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| Fork delta vs upstream | **+88 / −0** at HEAD (+86 at the production baseline, 0 behind in both cases) |
| Core / parent pin | parent `clients/apple` gitlink last recorded as `2a189686…`; the **libbox build identity is genuinely unrecorded** |
| Design pins | port reference `hako-ui@c1935cff…`; visual source `TokenPLS/Hako-Client@62aa2f2f…` (**not in this object store**) |
| Freeze tag | `iphone-hako-ui-freeze-v1` → `fc7f77b82a7ca432294addfa001fcacfd5776223` (annotated) |
| Runestone gitlink | `baeb3cbf8332d26b4f7b4c175a01f288ebbf3e7f` |
| Stage-1 knowledge date | 2026-10-12 |
| Stage-2 review date | 2026-10-12 |
| Working tree | clean at review start |

### Repository-kind detection

Detected as APPLE from `sing-box.xcodeproj/`, `SFI/`, `ApplicationLibrary/`, `Library/`,
`Extension/`, `MacLibrary/`. No Android markers present.

### The live remote, verified during this review

`git ls-remote --symref origin HEAD` returns `ref: refs/heads/main HEAD` — **the fork's
default branch is `main`, not `dev`**, and `main` (`d0524912`) **is the Hako product**: it
carries all 54 `ApplicationLibrary/Views/HakoStyle/*.swift` files and
`SFI/HakoPhoneRootView.swift`. It does not carry `KNOWLEDGE/` or `AGENTS.md`.

Live remote heads are exactly three: `dev` (`d1224bb`), `jiejiebox/ne-p3-code-closure`
(`aa1e982`), `main` (`d0524912`). Seven `archive/*` tags preserve the branches that were
deleted. **This knowledge base describes a 3-commit audit line hanging off `2a18968`; the
live product line is 63 commits further on.**

---

## B. Parallel audit

Eight independent subagents ran, four per repository, plus the orchestrator's own
targeted verification, which included **executing the repository's own static gates**.

| Agent | Scope |
|---|---|
| **A — Source Truth** | recovered the architecture from Swift/pbxproj/Makefile/scripts/tests **without reading `KNOWLEDGE/`**: 21 native targets, 54 HakoStyle files, entitlements, bundle ids, the idiom gate, NE lifecycle, ScreenState, all `NWPathMonitor` sites |
| **B — Git Evolution** | 579 commits, refs and tags, upstream relationship, 42 supplied SHAs, merge topology, the generator root cause, `EXTERNAL_CHECK_REQUIRED` search |
| **C — Verification Truth** | gate inventory with fail-open analysis, Swift test packages, the parity audit's comparison logic, device evidence, documented-but-open failures |
| **D — Knowledge Critic** | adversarial audit of all 13 Stage-1 files: SHA/ref validation, invariant re-audit, evidence vocabulary, a 20-row cross-file conflict matrix, density, dangling references, old-doc disposition |
| **Orchestrator** | ran the gates for real (see §C); verified the device-axis defect in source **and** in the repository's own test; verified the fix on the live line; resolved every `archive/*` tag; compared the baseline against live `main` |

**Subsystems reviewed:** platform ownership and the idiom gate; Hako presentation and
design provenance; shared business layer; NetworkExtension lifecycle; ScreenState and the
device axis; `NWPathMonitor` ownership and interface startup; subscription/profile data;
localization and branding; build/signing/entitlements/xcframework; tests, gates and their
failure modes; ref/tag topology and document classification.

**Commits deep-read:** `f2064a8`, `c13e852`, `0297c8e`, `a4752b5`…`e8e197a`, `f77289f`,
`996c8b7`, `2608bd5`, `8cc4005`, `7271382`, `61b4c44`, `042af2b`, `a4af88f`, `66b273a`,
`fc15efd`, `bb78003`, `6408bcd`, `44d2bb0`, `28e4c84`, `116ae6f`, `f1322b3`, `cca3ee4`,
`3e354ed`, `80eec7e`, `0ea456b`, `2039da1`, `e1cefe6`, `6a9d7eb`, `932bf1c`, `fd27efe`,
`f4a9859`, `82c9807`, `aa1e982`, plus `891c6cb`, `15d3a72`, `8d06a99`, `467f8ea`,
`987134b` on the live line. **All 42 supplied SHAs validated; all exist.**

**Tests/audits reviewed and executed:** `audit_apple_ui_boundary.py` (19 checks),
`audit_hako_lossless_parity.py`, `check_hako_macos_parse.py` (ios and tvos),
`check_generated_headers.py`, `check_platform_structure.py`, `check_swift_structure.py`,
`check_swift_test_sources.py`, `check_commit_messages.py`, `dup_module_scope.py`,
`report_hako_platform_api.py`, and the negative suites `test_fail_closed_exit_codes.py`,
`test_platform_gates.py`, `test_audit_reverse_routing.py`.

**Docs reviewed:** `KNOWLEDGE/**` (13 files), `AGENTS.md`, `KNOWLEDGE_STAGE1_REPORT.md`,
`README.md`, and the legacy set in `docs/` and `docs/pending/`.

**External evidence:** live `git ls-remote` against the fork remote, and a
non-destructive `git fetch --tags origin` to resolve the archive tags.

---

## C. Stage-1 quality

| Metric | Count |
|---|---|
| CONFIRMED claims | ~30 (the idiom gate, shared-layer proof, teardown fencing, the generator root cause, branding boundaries, the design/provenance split) |
| CORRECTED claims | 13 (see §D) |
| MISSING knowledge added | 6 material areas, including two *defects* |
| DOWNGRADED invariants | 3 (freeze-tag invariant split; the localization/identity invariant qualified; the `docs/pending` disposition split three ways) |
| UPGRADED verified facts | the entire gate set — Stage 1 recorded **no** executed result; this round records `PASS 19 FAIL 0 UNKNOWN 0 UNDECIDABLE 0` plus four negative suites green |
| REMOVED duplication | 9 facts that appeared in 2–6 files, each given one owner |
| PROVENANCE additions | 8 supersession/refusal pairs, the branch/tag/archive topology, the generator root cause, the "63 commits ahead" discovery |
| Files added | 0 new top-level files; 1 new module (`modules/hako-ui.md` rewritten in place; no new file needed) |
| Files rewritten | 11 |

File count was held flat deliberately. Two Stage-1 modules were *emptied of duplication*
and their content redistributed to the modules that own it.

---

## D. Important corrections

### D1. The knowledge base described a frozen audit line as if it were the product — the largest correction

Stage-1 said `f4a9859` was the "Knowledge / product HEAD" and that `baseline..HEAD` was the
delta a reader should inspect. Both are true of *this line* and misleading about the
product:

| Comparison at HEAD | Ahead | Behind |
|---|---|---|
| vs `upstream/dev@089d35e6` | 88 | 0 |
| vs `3a550d0` (the *integrated* line) | 3 | **37** |
| vs `d0524912` (**live `origin/main`**) | 3 | **63** |

`baseline..HEAD` is 3 documentation commits. The product delta is 63 commits and was
invisible from the knowledge base. `BASELINE.md`, `README.md` and `AGENTS.md` now make this
the first thing a reader sees, with the exact commands.

### D2. Two live defects are in this baseline and already fixed on the live line

Both were found by this review and confirmed against `origin/main`.

**(a) The device axis can publish an unlock from an unknown state.** At this baseline
`ScreenStatePolicy.decide` implements rules 1–4 only, so

```text
decide(read: .value(0), source: .lock, provenance: .event, lastObserved: nil) -> publish .unlocked
```

`.unlocked` is the one fact that lifts the device pause
(`recordLockState(false)` → `Box.LockStateChanged(false)` → `lifecycle.woke()`). Rule 4
already refuses that same `0` on the snapshot path for exactly this reason — a notification
name whose state was never set answers `NOTIFY_STATUS_OK` with `0` — but the event path had
no equivalent guard.

**The repository's own test asserts the missing rule and therefore fails at this
baseline.** `ScreenStatePolicyTests.testTheWholeTruthTable` requires
`XCTAssertEqual(last, 1, "an unlock was published without a transition")`, an assertion
added by `996c8b7`, an ancestor of HEAD. The policy class is 8 of 9 here. The fix
(`891c6cb`, rule 5) is verified present on `origin/main`. This is recorded in
`modules/screen-state.md` with the failing assertion quoted.

**(b) The interface-startup wait is unbounded.** `startDefaultInterfaceMonitor` blocks on a
`DispatchSemaphore` with no timeout while the service lifecycle lock is held, so airplane
mode at startup hangs indefinitely. `origin/main` fixes it (`15d3a72` "bound the first
interface-path wait, so airplane mode cannot hang startup", plus `628644d`).

Stage-1's `screen-state.md` described the policy as already safe. That was the single
most consequential error in the base.

### D3. The parent/core pin is *recorded*, not external

Stage-1 said `EXTERNAL-CHECK-REQUIRED`. Three values are in fact recorded in-repo:
`f4a9859`'s message (`2a189686`, locally checkable and equal to the `r8/main` tip),
`docs/HAKO-ROUND8-HANDOFF.md:16` (`2b23330d`), and
`docs/pending/HAKO-OWNERSHIP.md:41` (`5911580a`) — the last of which flags its own
discrepancy with the submodule worktree.

What *is* genuinely unknown is narrower and more important: **which core/libbox build an
Apple build links.** `Libbox.xcframework` is project-referenced, absent and gitignored; no
core SHA, branch or version appears in the tracked tree. That is the sharpest structural
difference from the Android sibling repository, which pins and verifies its core.

### D4. Governance facts were stale against the live remote

`origin/HEAD` pointed at `dev` locally, but the remote's default is `main`; `main`'s tip
`d0524912` was not in the clone at all. Several branches the knowledge base treated as
current (`jiejiebox/integrated`, `hako-ui`, `ipad-upstream-ui`, `fix/*`, `r8/*`) **no
longer exist on the remote** — and their content survives only as `archive/*` tags and
local remote-tracking refs. `git fetch --prune` would have destroyed the only local
pointers. That is now an explicit caution in `AGENTS.md`, `KNOWLEDGE/README.md` and
`BASELINE.md`, with the resolved archive-tag table.

### D5. The design provenance was misattributed

Stage-1 called `hako-ui@c1935cf` "the original design source". Nine `HakoStyle` files
carry headers naming a **different repository and commit** —
`TokenPLS/Hako-Client @ 62aa2f2f` (GPL-3.0) — which is **not in this object store**.
There are two provenance families, and the file header decides which applies. Verified
independently; the distinction is now in `modules/hako-ui.md` and `BASELINE.md`.

Related: `c1935cf` is the tip of nothing (the `origin/hako-ui` branch moved on to
`d5b2c31e`), so the design reference was reachable only through a stale branch ref until
this review resolved it to `archive/hako-design-v1`.

### D6. The freeze tag cannot be an acceptance baseline

`fc7f77b` is **not an ancestor of HEAD**, and it is **2 commits older than the port
reference** — the newer of the two being the remaining-quota row the fork exists to keep.
The tag's own guard lives at `docs/pending/check-iphone-hako-freeze.sh` (not
`scripts/dev/`), its `FIXED_UPSTREAM_SHA` is absent from this object store, and it was
retired on purpose. Stage-1 listed it as protecting a surface.

### D7. The gate vocabulary was optimistic in two directions

**(a) The audit can look green without doing its job.** Without `--upstream-ref` the
`upstream-files-untouched` check reports `UNKNOWN` and the summary still reads
`PASS 18 FAIL 0 UNKNOWN 1 …`, **exit 0**; without `--strict`, `UNKNOWN` folds into a pass.
Stage-1 documented the command **without either flag**.

**(b) Two gates are red by decision and Stage-1 did not say so.** `check_hako_macos_parse.py
--platform tvos` (54 files `NOT CHECKED`) and `gate_hako_platform_imports.py --check`
(61 `undecidable on tvos`) are red because `swift_directives.PLATFORMS` has no `tvos`
entry, and tvOS UI is out of scope by decision. A future AI running them sees persistent
red with no explanation in the knowledge base. `--platform ios` is green
(`checked=54 errors=0 undecidable=0`).

**(c) One gate is a false red.** `dup_module_scope.py` exits 1 with 18 findings that are
all legal code (file-private extensions, extension-of-shared-type by design). Its own
docstring says it is "evidence, not a gate", and the enforced check on the same tree
passes.

All three are now stated, with the reason, in `modules/tests-audits.md` and
`modules/hako-ui.md`.

### D8. The unknown-language claim was overstated

`audit_apple_ui_boundary.py` says "the phone's copy of `<path>`, from `hako-ui` @ `c1935cf`"
and `audit_hako_lossless_parity.py` compares token sets plus 9 byte-identical files. That
establishes static port fidelity — **not** structural equivalence, and not pixel parity.
The repository proved the limit on itself: with every `#if !os(tvOS)` guard deleted, the
parity audit still exits 0 with `lost_tokens=0, 6/6, 9/9`, while the boundary audit exits 1
with four FAILs on the same bytes. Stage-1 called this "designated tokens/byte-parity",
which was accurate but easy to over-read; the limit is now stated alongside a worked
counter-example.

Also corrected: `HAKO-LOSSLESS-PARITY-AUDIT.md` claims "10/10 byte-identical" while the
tool compares **9** byte-for-byte and one file by tokens.

### D9. The generator hazard — the highest-value addition

This is the root cause of roughly two dozen "restore the guards" commits, and Stage-1
mentioned only that "migration scripts mechanically rename/resolve platform conditions".

`scripts/dev/swift_directives.py` has two entry points: `resolve()`, which **decides every
platform condition and deletes the directives**, and `preserve()`, which keeps every
`#if`/`#elseif`/`#else` chain and is documented as **required for anything written into
`ApplicationLibrary/`** — one synchronised source group feeding the iOS, macOS and tvOS
targets.

Measured at HEAD: `port_hako_components.py`, `port_hako_secondary.py` and
`port_tools_and_more.py` **all still call `resolve()`**; `preserve()` is used only by
`migrate_secondary_page.py`. The repository records that a `--regenerate` run once
"rewrote three pages to their upstream shape — every `#if !os(tvOS)` guard the round
restored was gone, unguarded `import UIKit` is back — **written with exit status 0**".

So a generator can return success while making the tree less correct. `modules/hako-ui.md`
now carries the rules: never re-run a generator over a hand-repaired file without diffing,
regeneration is a candidate not a result, and guards in `HakoStyle/*.swift` are not
decoration because all 54 files must compile for tvOS.

### D10. Missing subsystems and facts recorded for the first time

- **A third `NWPathMonitor`.** Stage-1 said two ownership domains. There are three, in
  three processes — the tunnel's, the Tools-UI quality probe, and one in the **privileged
  helper** (`RootHelperService.startNATCleaner()`) whose failure mode is invisible from the
  app and is not covered by the service lifecycle lock.
- **The screen-state operational core:** the two Darwin notification names,
  `ScreenStateStartResult.failedNotificationNames` as the only device-log evidence,
  the all-or-nothing registration decision and its asymmetric reason, the iOS "enters the
  pause and never lifts it" fallback, `wake()` as the only `resync()` call site, and the
  missed-lock-recoverable / missed-unlock-not asymmetry.
- **The UI test suites substitute data, not just geometry.** They launch with
  `-FASTLANE_SNAPSHOT YES` → `Variant.screenshotMode`, read in 23 files, which forces group
  counts, connection state and profile availability. `SnapshotHelper.swift` **throws on
  physical hardware**. A green UI run is therefore not evidence about the shipping data
  path.
- **`UITests/*.swift` compile into nothing** — a synchronised group attached to no target.
- **The negative suites mutate the real git index** (they copy the tree and the copied
  `.git` *file* points at the shared git directory), while `ACCEPTANCE.md` tells readers to
  run them.
- **`SFI/MainView.swift` is byte-identical to upstream** — the cleanest single proof that
  the iPad/Mac path stayed upstream's, and a sharper statement of the preservation
  contract than "where the audit names it".

---

## E. Commit provenance

**Newly mapped:** the re-foundation on a clean upstream base (`f2064a8`, the first product
commit, a child of `089d35e6`); the Hako migration series with `c13e852`'s deliberate
`HakoHomeView` exclusion and `a4752b5`'s reversal of it; the screen-state self-refutation
(`996c8b7` retracting phase 1's stated mechanism while keeping its change); subscription
usage (adapted from `fc7f77b`/`c1935cf`); the audit/gate series, including five audit
defects the negative suite found in the audit itself and two checks **withdrawn** because
they could not fail; the four platform-guard restoration waves; generator safety
(`f1322b3` → `a4af88f` → `fd27efe`); provenance-header inversion and repair (`0ea456b`);
reachability and "declared but never called" (`2039da1`); the NE teardown/reload race
(`f4a9859`); the post-baseline docs (`82c9807`, `aa1e982`).

**Supersession / reversal / absorption pairs recorded:** the product line supersedes
`origin/hako-ui` as a merge source; `996c8b7` refutes `f77289f`'s justification while
keeping its change; `f77289f` **adapts** (does not merge) `dd9114d`; `44d2bb0` supersedes
`bb78003`'s scope and withdraws two of its own checks; `28e4c84` rejects its own first
design; `116ae6f` supersedes `3e354ed`'s condition model and found a false pass in
`bcf7402`'s coverage fix; `932bf1c` supersedes `fe89ce8`'s claim of green; `fd27efe`
extends `f1322b3`'s gate to the three `port_*.py`; `0ea456b` corrects the generator's own
output; `e1cefe6` reverts the tool's own backwards rename and notes the audit said
`PASS 15 / FAIL 0` in **both** states.

**Merge topology:** exactly three merges in 579 commits, all tool-only, all with **no
conflict-resolution diff** — the branches were deliberately scoped to disjoint file sets.
Zero Swift files cross any merge. Only `cca3ee4`, `3e354ed`, `80eec7e` (and `cca3ee4`'s
ancestor `f1322b3`) are reachable solely through a merge.

**Corrections to how the SHA list should be read:** `0ea456b` is **not** an
`r8/a-generator` commit (the tip is `cca3ee4`); `r8/e-redteam` is a pure alias of
`r8/d-reach` with zero unique commits; most of the listed "r8 series heads" are ordinary
linear commits on `r8/main`, not heads.

**The one durable root-cause fix is outside version control.** `80eec7e` says the
requested change to `swift_directives.py` lives in
`_work/r8/c-scratch/C-REQUESTS-TO-A.md`, which is untracked. Meanwhile three of four
generators still collapse guards. Recorded as a gap, not fixed.

---

## F. Evidence quality

| Level | What holds it |
|---|---|
| **Source-only** | ownership, the idiom gate, NE fencing, ScreenState policy, monitor lifetimes, entitlements, bundle ids |
| **Static** | the gates executed this round: boundary audit `PASS 19 FAIL 0 UNKNOWN 0 UNDECIDABLE 0`; parity `6/6`, `9/9`, `0` tokens lost; `test_fail_closed_exit_codes` 3/3; `test_platform_gates` 0 failing of 19; `test_audit_reverse_routing` 29 cases all failing as designed; plus six structural checks green |
| **Unit** | **none executed.** Both SwiftPM packages are committed unexecuted and are additionally unrunnable here (git symlinks materialise as text files) |
| **CI** | **none. There is no `.github/` in this repository at all** — every "green" in every commit message is a local run |
| **Simulator** | **none.** No `xcodebuild` has been recorded |
| **Device** | **none, for any of the five areas.** No device model is named anywhere in the repository; the only device names present are *simulators* in `Snapfile`, and the snapshot helper they feed throws on real hardware |
| **Unverified** | which core an Apple build links; `Hako-Client@62aa2f2f`, the freeze guard's upstream pin, the Runestone gitlink and `TreeSitterJSON5`'s revision — all absent from this object store |
| **Needs device** | iPhone Hako UI, iPad official UI (including Split View, Slide Over, Stage Manager), macOS official UI, NE tunnel lifecycle, ScreenState sleep/resume |

### The frozen baseline is red in one place, by design, and green in another

`ScreenStatePolicyTests` is 8 of 9 at this baseline (§D2a). Everything else that was
runnable is green. Recording a red test as *known* rather than omitting it is the point:
"no result known" and "a known failing case" are different states.

---

## G. Docs disposition

Stage-1 classified four documents KEEP, nine ABSORB, four ARCHIVE and one ARCHIVE-ONLY,
and deleted nothing. **This round changes three dispositions**, on one principle: *a
document that holds the only copy of a current fact is not "absorbed" until the fact is
actually in the knowledge base.*

| Document | Stage-1 | Stage-2 | Why |
|---|---|---|---|
| `docs/SCREEN-STATE-FACTS.md` | ABSORB | **KEEP + ABSORB** | it holds the notification names, the all-or-nothing decision and its reason, the fallback consequence, the missed-unlock asymmetry and the device observations — none of which had been absorbed |
| `docs/HAKO-ROUND8-REMAINING-FAILURES.md`, `HAKO-ROUND9-REMAINING-FAILURES.md` | ARCHIVE | **CURRENT-STATE** | they state this tree's **current** red gates, the index-mutating harness, the caller-check blind spot and the `dup_module_scope` false red. Filing them ARCHIVE invited treating live red as history |
| `docs/pending/**` | ARCHIVE-ONLY (single) | **split three ways** | `docs/pending/README.md` §freeze-guard and `HAKO-OWNERSHIP.md` §gitlink are **absorbed provenance** (the retirement rationale; the gitlink-vs-blob distinction the Runestone row depends on); the asset-status sections are **stale**; the rest is archive |
| root `APPLE-UI-MAC-VERIFICATION-REPORT.md` | ARCHIVE | **not present at this baseline** | it is created on the sibling line; classifying it in a baseline table was written against a tree that is not the audited baseline |

**No document was deleted or moved.** The policy of "nothing deleted, classification is
semantic" is sound and was kept.

High-value facts absorbed this round: the device-only screen-state procedure and its two
named observations; the all-or-nothing registration reason; the four iPad window
environments as a checklist item; the `swift-api-digester` libbox-verification recipe; the
upstream-sync rule that the gitlink advances only after a device pass; and the freeze-guard
retirement rationale.

---

## H. Follow-up (production code — not fixed this round)

Item 1 is a live defect at this baseline and is **already fixed on the live product line**;
the others are gaps this review found and did not repair.

| # | Item | Where | State |
|---|---|---|---|
| 1 | `ScreenStatePolicy.decide` publishes `.unlocked` from an unknown lock state, lifting the device pause; the repository's own test fails | `Library/Network/ScreenStateObserver.swift` | **fixed on `origin/main` by `891c6cb`** — not on this line |
| 2 | `startDefaultInterfaceMonitor` waits on a semaphore with no timeout while the lifecycle lock is held; airplane mode hangs startup | `Library/Network/ExtensionPlatformInterface.swift` | **fixed on `origin/main` by `15d3a72` + `628644d`** |
| 3 | A failed `startTunnel` rethrows without closing the command server it created | `Library/Network/ExtensionProvider.swift` | **fixed on `origin/main` by `8d06a99`** (`unwindFailedStart()`) |
| 4 | Three count keys the phone asks for are absent from the string catalog | `Localizable.xcstrings` | **fixed on `origin/main` by `467f8ea`** |
| 5 | The gitlink value the parent records for `clients/apple` cannot be resolved from here, and three documents disagree | parent repo | `EXTERNAL_CHECK_REQUIRED` |
| 6 | Which core/libbox build an Apple build links is recorded nowhere | build inputs | `UNVERIFIED` — blocks an entire compat decision (`address()` vs `address()!.value`) |
| 7 | Three of four port generators still call the collapsing `resolve()`; the durable fix is requested via an **untracked** file | `scripts/dev/port_*.py` | open |
| 8 | `port_hako_pages.py` regenerates from the moving branch `origin/hako-ui` while its sibling pins and verifies `c1935cf` | `scripts/dev/port_hako_pages.py` | open |
| 9 | `port_hako_pages.py`'s design source is now reachable only through `archive/hako-design-v1` | tooling | open |
| 10 | The tvOS leg of the port is verified by no enforced gate, by decision | `swift_directives.PLATFORMS` | accepted |
| 11 | `UITests/*.swift` compile into nothing | `project.pbxproj` | open |
| 12 | An unregistered check (`check_hako_annotation_agreement`) is dead code that reads like a live check | `audit_apple_ui_boundary.py` | open |
| 13 | `HAKO-UI-MIGRATION-MATRIX.md` contradicts itself between its first- and second-level tables | `docs/` | open |
| 14 | `README.md` states 19 `HakoStyle` files (actual 54), `PASS 9` (actual 19) and a stale migration status; `APPLE-DEVICE-ACCEPTANCE.md` says Home is upstream's card grid when it is Hako's | `README.md`, `docs/` | open |
| 15 | Two shipping source files cite `Hako-Client@62aa2f2f`, which is not an object in this repository | `HakoTheme.swift`, `SubscriptionInfo.swift` | open |
| 16 | The one commit that fixes the baseline's device-axis defect sits on a line whose branch was deleted | git topology | open |

---

## I. Knowledge quality gate

No script was added, for the same reason as the Android sibling: the repository already
carries 45 files under `scripts/`, including 12 gates, 5 negative suites and a
20 KB safety contract. An eighteenth gate would be the "knowledge base becomes a build
system" failure the brief warns about. The suggested checks were run by hand and their
results are recorded.

| Check | Result |
|---|---|
| Every file `AGENTS.md` and `KNOWLEDGE/README.md` point at exists | **pass** — after this refresh. One Stage-1 dangling reference was found and fixed: `check-iphone-hako-freeze.sh` was described as a live gate while the file exists only under `docs/pending/` |
| The production baseline SHA is a valid Git object and really is the last production commit | **pass** — `82c9807` and `aa1e982` are docs-only |
| Every SHA in `COMMIT-INDEX.md` and the modules exists | **pass** — 42/42 (plus 5 correctly recorded as *absent from this object store*) |
| Module links do not dangle | **pass** |
| Status words are from the declared vocabulary | **pass** |
| No duplicate baseline declarations | **pass** — `BASELINE.md` is the sole owner of ref/pin facts; `repository-history.md` keeps only the document-classification table |
| No Stage-1 stale path | **pass** — `docs/APPLE-UI-ROUTING.md` is referenced *by source* and is absent; that is recorded as a source-side dangling pointer rather than silently fixed |

---

## J. Final state

```text
KNOWLEDGE_STAGE2 = COMPLETE

REPO_KIND = APPLE

PRODUCTION_CODE_CHANGED = NO
UI_CHANGED = NO
RUNTIME_BEHAVIOR_CHANGED = NO
GIT_HISTORY_REWRITTEN = NO

PRODUCTION_BASELINE_VALID = YES
STAGE1_CLAIMS_REAUDITED = YES
COMMIT_PROVENANCE_REINFORCED = YES
INVARIANTS_REAUDITED = YES
EVIDENCE_LEVELS_REAUDITED = YES
CROSS_FILE_CONSISTENCY = PASS
FUTURE_AI_INCREMENTAL_READ = PASS

READY_FOR_FINAL_KNOWLEDGE_REVIEW = YES
```

`READY_FOR_FINAL_KNOWLEDGE_REVIEW = YES` means source, Git, knowledge, acceptance and
evidence are mutually consistent **about this frozen audit line**, and that the line's
relationship to the live product is now stated rather than implied.

It is **not** a statement that the product is ready, and it must not be read as one. The
live `main` is 63 commits ahead; one test is knowingly red here and fixed there; no Apple
code has ever been compiled, run in a simulator, or run on a device in this environment;
and no release baseline exists.
