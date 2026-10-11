# Apple tail cleanup report

The last three loose ends after the Apple consolidation: the uncommitted remains in the two
retired worktrees, the two checks that had been red for several rounds, and a wrong number in
the consolidation report.

Worked on the isolated branch `jiejiebox/apple-tail-cleanup`, created from `origin/main`.
**No product source changed. No architecture changed. No archive tag moved.**

---

## A. Old worktree audit

Two Apple worktrees carried uncommitted changes. An archive tag protects committed history and
nothing else, so each dirty file was classified individually. Full evidence, including the
main-side blob comparison for every file, is in
[`OLD-WORKTREE-AUDIT.md`](OLD-WORKTREE-AUDIT.md).

| Worktree | Branch | HEAD | Dirty files | Untracked | Classifications | Removed |
|---|---|---|---|---:|---|---|
| `sing-box-apple-hakoui` | `hako-ui` | `d5b2c31e7` | 4 (staged) | none | A ×3, B ×1 | **yes** |
| `sing-box-apple-worktree` | `libbox-stringbox-result-frame` | `5911580a6` | 5 (unstaged) | none | A ×5 | **yes** |

**No `D. UNIQUE_AND_STILL_NEEDED` was found, so nothing was ported and no
`fix(apple): preserve the last uncommitted client fix` commit exists.** That is the outcome the
prompt's §16 anticipated as conditional, and the condition was not met.

### Per-file classification

| File | Worktree | Classification | Evidence |
|---|---|---|---|
| `Library/Network/ExtensionPlatformInterface.swift` | B | **A** | `main` reads `.value` at all 8 sites, same line numbers; `main` has 11 `.value` lines vs the worktree's 10, and the extra one is `nameBox.value = tunName` — the `BridgeServiceSession` implementer, which the worktree lacks |
| `ApplicationLibrary/Views/Abstract/GlobalChecksModifier.swift` | B | **A** | 3 `.value` lines in both; zero `.value` lines differ between `main` and the worktree |
| `HelperService/RootHelperService.swift` | B | **A** | 2 in both; zero differ |
| `JailbreakDaemon/IOSRootHelperService.swift` | B | **A** | 2 in both; zero differ |
| `Library/Network/BridgeTunTracker.swift` | B | **A** | `main`'s blob is byte-identical to the worktree's dirty file |
| `README.md` | A | **A** (main is better) | The staged blob is byte-identical to `upstream/dev` — it *removes* the product README that `main` carries |
| `docs/APPLE-UI-ROUTING.md` | A | **A** | Exists only on the `hako-ui` line; the staged copy is a *trimmed* variant describing the pre-migration single-shell layout. Untrimmed original survives in `archive/hako-design-v1` |
| `docs/IPAD-UPSTREAM-PORT.md` | A | **A** | Same situation |
| `ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift` | A | **B** | Superseded — see below |

### The one real change, and why it was not ported

`ProfilePickerSheet.swift` on `main` is byte-identical to `upstream/dev` and uses the plain
`relativeFormat` property. The `hako-ui` variant is a different, longer file with its own nested
`relativeFormat(forPickerRow:)`, and the staged edit points one call site at it.

What the old patch fixed: `RelativeDateTimeFormatter` defaults to `Locale.current`, not to the
locale the view is rendered in, so a row can render in the wrong language.

How `main` covers it: the iPhone does not use that file. It uses the migrated
`ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift`, which **already contains both
the locale-aware method and the call** (`:778` and `:1188`), and a `grep` for `forPickerRow` over
`main` matches only those two lines — the fix exists exactly once, in the file the phone renders.

Regression evidence on `main`: `HakoScreenState` 35/35, `HakoSubscriptionUsage` 24/24, boundary
audit PASS 19 / FAIL 0, and both SFI and SFM build. Adding the method to
`Dashboard/Cards/ProfilePickerSheet.swift` would change a file `main` deliberately keeps
byte-identical to upstream, for a presentation that does not use it, and would need `locale` in
scope at three call sites that do not have it.

### Removal, and a reachability trap that was not in the audit

`git worktree remove` **refused both**, with

```text
fatal: working trees containing submodules cannot be moved or removed
```

— not because of the dirty files but because `Frameworks/Runestone` lives inside the Apple
working tree, so every Apple worktree hits this. `--force` was used only after the evidence above
was written down.

Removing a worktree also releases its **branch**, which the dirty-file audit says nothing about.
Two of the three branches were therefore checked separately, and one of them needed action:

| Branch | Tip | Reachable from a tag? | Action |
|---|---|---|---|
| `libbox-stringbox-result-frame` | `5911580a6` | Yes — six tags | deleted |
| `hako-ui` | `d5b2c31e7` | **No.** Not from any tag, remote branch long deleted | **tagged first**, then deleted |
| `jiejiebox/integrated` | `3a550d0de` | Yes — `archive/pre-consolidation-2026-10-11` | deleted |

`archive/hako-design-v1` points at `c1935cf`, **16 commits behind** the `hako-ui` tip, and 98
commits of that line are not in `main`. Deleting the branch would have left them reachable from
nothing, i.e. reclaimable by the next `git gc`. The tip was tagged before deletion:

```text
archive/hako-ui-line-local-d5b2c31 -> d5b2c31e79b83f15995bac5040ddef195a5ed98c
```

**That tag is LOCAL ONLY and deliberately not pushed** — this round may write only its own branch,
and the published `archive/*` set is frozen. It exists so a local `gc` cannot orphan the line; it
is not part of the published archive set and must not be read as one.

### Final worktree state

```text
sing-box/.git/modules/clients/apple    bb5309b (detached HEAD)  the parent's submodule checkout
sing-box-apple-consolidation           bb5309b [main]           clean
sing-box-apple-tail-cleanup            bb5309b [jiejiebox/apple-tail-cleanup]  this round
```

Both audited worktrees are gone and none was retained, so there is no "why it could not be
cleaned" entry to write. Local branches after cleanup: `main`, `dev`,
`jiejiebox/apple-tail-cleanup`.

---

## B. Red harness fixes

Both checks had been carried as `PRE_EXISTING RED` for several rounds. Both were defects in the
checking apparatus, not in the product. One of the two recorded diagnoses was also wrong, and is
corrected.

### B1. `scripts/dev/test_audit_apple_ui_boundary.py`

**Before:** `upstream-file-edited: expected FAIL naming the file, got PASS` — and, on a tree with
any untracked file present, the suite died earlier still in `reset()`.

**Root causes — two, independent:**

1. `reset()` asserted an **empty** `git status` for its sandbox copy. That copy is a `copytree` of
   the working checkout, so it inherits whatever untracked file the developer has lying around.
   The suite then reported on the developer's working directory rather than on a leaked mutation.
   `OLD-WORKTREE-AUDIT.md`, written earlier in this same round, was enough to crash it.
2. `upstream-files-untouched` compared `git ls-tree HEAD` against upstream. That reads the last
   **commit**, so a modification present on disk but not yet committed compared equal to upstream
   and was reported unmodified. The check was structurally blind to the exact edit its own negative
   case injects.

Cause 2 is a genuine audit blind spot, not merely a test defect: the audit's own contract is *"the
working tree is read directly for the tree under audit"* (module docstring), and this was the one
check that read a commit instead.

**Fix:**

- `reset()` now takes the untracked set the copy was made with and reports only paths that appeared
  *afterwards*. A leak is still a leak; a pre-existing file is not.
- `upstream-files-untouched` hashes the **worktree** file with a git-compatible blob hash that
  treats a symlink as its link-target string. `git hash-object <path>` follows the link and hashes
  the target's contents, which is what previously made `SFM.System/Resources/LICENSE` report as
  modified with an identical mode and identical blob on both sides. The submodule gitlink is no
  longer compared here; `repository-hygiene` owns it.

**False-positive measurement before committing:** 0 unreviewed upstream files differ on disk from
`upstream/dev` on this tree. The two comparison counts moved 459→458 and 435→434, and the single
path that changed is the `Frameworks/Runestone` gitlink — deliberate, as above.

**After:** the suite reports `every negative case failed the audit as designed, and the positive
case passed`, 24 checks, exit 0. The mutated edit now yields
`FAIL … 1 upstream-owned file(s) were modified without being on the reviewed list:
ApplicationLibrary/Views/Groups/GroupListView.swift`, naming the file as the case requires.

### B2. `scripts/dev/check-hako-primary-route.sh`

**Before:** `error: cannot find 'HakoSettingsPush' in scope`.

**Root cause:** the type genuinely **does not exist** in the tree. The Hako migration renamed
`HakoSettingsPush` → `HakoSettingsRoute` and its nested `Decision` →
`HakoSettingsRoute.HakoSettingsPushDecision`. The harness was never updated, so its settings-push
cases had never been compiled. The previously recorded explanation — that the type "is declared in
`HakoSettingView.swift` and is simply not resolvable by this standalone check" — was wrong, and the
consolidation report has been corrected.

**Fix, in the harness only:** the current type names. Nothing was copied into the script, no check
was deleted, and no `PASS` was hardcoded.

**A second stale claim, in the script's own header.** It declared `BLOCKED_BY_ENVIRONMENT` because
`Library.framework` re-exports PLCrashReporter as a framework Clang module whose umbrella header
cannot resolve outside the build. That describes a real property of the dependency — but it is the
property the `CrashReporter.framework` shim in the same script exists to neutralise, and the shim
works. What the header was really recording was a missing prerequisite described with the wrong
cause: `libbox` is resolved **relative to the repository root**, so a checkout that has never had
`Libbox.xcframework` installed fails the prerequisite loop with exit 2 before `swiftc` runs at all.
The header now says `WORKS`, gives the install command, and notes that exit 2 is the prerequisite
check rather than a compile failure.

**After:** the harness compiles and executes — **55 cases pass, 0 fail**, exit 0. Its final line is
`PASS: primary route mapping`.

The copy at `docs/pending/check-hako-primary-route.swift` is deliberately **left unchanged**: that
directory's own README states nothing in it is compiled, linked or run, so editing it would rewrite
the historical record instead of fixing a check.

---

## C. Consolidation report correction

```text
Old branches deleted:  15  ->  13
```

Fifteen remote branches existed; `main` and `dev` were kept; thirteen were deleted. The executive
summary row now states the count and the arithmetic. The same report's §7 gained the resolution
status of both red checks, and its §10 open item is struck through rather than deleted.

---

## D. SHA authority policy

The report is a commit on the branch it describes, so a SHA written into it is one commit stale the
moment it is committed, and correcting it moves the branch again. That loop is over: **documents
are snapshots; git refs and scripts are the authority.**

```bash
git rev-parse origin/main                                   # the Apple product line, current
git ls-tree <parent> clients/apple                          # the revision the parent builds
scripts/ci/apple-client-source.sh sha ios                   # must equal that gitlink
scripts/ci/apple-client-source.sh sha macos                 # must equal it too
scripts/ci/apple-client-source.sh assert-shared-source      # must PASS
grep '^VERIFIED_APPLE_SHA=' scripts/ci/check-libbox-abi.sh  # must equal it
```

The consolidation report's executive summary now says this in those words. Historical SHAs
(`3a550d0`, `ff849cc`, `f8f978c`, …) remain as evidence and are untouched — the rule is only that
"the current final HEAD" must not be a self-referencing field.

---

## E. Final gate

| Gate | Result |
|---|---|
| `scripts/dev/test_audit_apple_ui_boundary.py` | **PASS** — every negative case failed as designed, positive case passed; exit 0 |
| `scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e` | **PASS 19 / FAIL 0 / UNKNOWN 0 / UNDECIDABLE 0** |
| `scripts/dev/check-hako-primary-route.sh` | **PASS** — 55 cases, 0 fail; exit 0 |
| `./scripts/run-subscription-usage-tests.sh` | **24 tests, 0 failures** |
| `Tests/HakoScreenState` `swift test` | **35 tests, 0 failures** |
| SFI (iOS) / SFM (macOS) rebuild | **NOT RUN — and not implied.** No product source changed |

### Why no rebuild (§18)

Every changed path is under `scripts/dev/`, and the one changed `.swift` file
(`check-hako-primary-route.swift`) is a standalone harness that appears **nowhere** in
`sing-box.xcodeproj`. So:

```text
NO PRODUCT SOURCE CHANGED
```

The compile evidence for the shipped products is unchanged from the consolidation round, which
built SFI and SFM successfully from Apple commit `bb5309b` — the same commit this branch is based
on.

### Device testing

**Mac and iPad real-device testing is unavailable**, and iPad/macOS have no simulator path for this
project's acceptance. Nothing in this report is a device result. Everything above is a static
analysis, a harness execution on the host, or a unit test. Whether the Hako shell renders as
designed and whether the device pause latches remain `NEEDS_DEVICE` and are not inferred here.

---

## Remaining work

Only two items, and neither reopens Apple development:

1. **Core hardening consolidation** — still open, still the core repository's own audit, untouched
   by this round.
2. **Known non-Apple and Apple-remote items:**
   - Two pre-existing Android ABI violations in `check-libbox-abi.sh` layer 4. Android-owned.
   - `scripts/ci/build-apple-libbox.sh` still defaults its framework **source** to the repository
     root while `cmd/internal/build_libbox` writes to `_libbox_build/`. Recorded in the previous
     round; independent of the pin; not fixed here.
   - `docs/pending/check-hako-primary-route.swift` still names the pre-migration types. It is a
     frozen holding-area copy that nothing compiles, and it is left as the historical record.

**Apple is now frozen for maintenance.** The branch `jiejiebox/apple-tail-cleanup` carries two
commits on top of `main` and is pushed for the operator to merge or cherry-pick; `main` itself was
not touched.
