# Round 9 → Round 10 handoff

Written for a fresh window with no memory of round 9. **This file is the whole handoff.** Its predecessor,
`HAKO-ROUND8-HANDOFF.md`, is still accurate about the environment, the worktrees and the rules, and is not
repeated here except where round 9 changed it.

## 1. Where round 9 ended

| | |
|---|---|
| Repository | `https://github.com/Piggy-Cat-bit-shadow/sing-box-for-apple` |
| Integration branch | `jiejiebox/integrated` |
| **Final SHA, on both branches** | **`2335251`** |
| Round 9 start | `2207852` |
| iPhone UI gold standard | `hako-ui@c1935cff77246f97498400f5a0a7f430cfabbd55` |
| Upstream comparison baseline | `SagerNet/sing-box-for-apple dev@089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| Remote `refs/heads/r8/main` | `2335251` |
| Remote `refs/heads/jiejiebox/integrated` | `2335251` — fast-forwarded from `2207852` |

Round 9 pushed `r8/main` first (`2d5dca3`, then `2335251`), and then fast-forwarded
`jiejiebox/integrated` from `2207852` to `2335251`. That second push is a **fast-forward, not a rewrite**:
`2207852` is an ancestor of `2335251`, and `2335251..2207852` is empty, so the branch's old tip is fully
contained in the new one and nothing was discarded.

**What was deliberately not pushed is the content of the `jiejiebox-integrated` working tree.** That
checkout had 73 entries staged that were never committed, and they are the **pre-repair** state, not work in
progress: its `Hako*.swift` files are byte-identical (SHA-256) to all five round-8 sibling branches
`_work/r8/w-a`…`w-e`, and against `r8/main` it is 80 files changed, **+1,903 / −12,658** — it deletes all 26
tooling and document files and reverts round 8's platform guards. Pushing it would have undone verified
work, so the branch was advanced to the verified commit instead, and the stale working tree was left exactly
as it was found for its owner to deal with. See §6.

Round 9 pushed alongside the four `r8/a`…`r8/d` branches round 8 already had on the remote. No force push,
no rebase of pushed history, and the `Frameworks/Runestone` gitlink is unchanged. This repository has no
`.github/workflows` at all, so no push can have started a CI run.

```text
IPHONE_HAKO_UI=STATIC_VERIFIED
IPAD_MAC_OFFICIAL_ISOLATION=PASS_STATIC
GENERATOR_SAFETY=PASS
INDEPENDENT_DEBUG=COMPLETED              <- round 8's missing deliverable, done in round 9
AUDIT_DETECTOR=WIDENED_AND_REGISTERED
APPLE_BUILD_DEVICE_PIXEL=UNVERIFIED
TVOS=OUT_OF_SCOPE                        <- the user's decision, see §3
```

Set the environment up exactly as `HAKO-ROUND8-HANDOFF.md` §1 says. `python` and `git` are still not on
`PATH`, and `DSH_REPO` / `DSH_GIT` still have to be set in every command.

`_work/r8/scratch/run-suite.ps1` runs the whole 16-command suite and prints one line per command. **It has a
UTF-8 BOM on purpose** — without it PowerShell 7 reads the Chinese path in it as GBK and every command
fails with a path error. Copy that habit for any script containing a non-ASCII path.

### `116ae6f`, `d8240eb`, `932bf1c` — the rest of the red-team findings that a Mac is not needed for

**The audit's own detector had two holes**, both proved by injection before they were closed.

`platform-guard-agreement` decided a use site from a **set of atoms**, and an atom set cannot represent
`#else` or tell `&&` from `||`. So a use inside the `#else` of `#if !os(tvOS)` was judged to be inside
`!os(tvOS)` — the one place it definitely is not — and a declaration under
`#if os(iOS) && canImport(GhosttyTerminal)` could be satisfied by a use under `#if os(macOS)`. A condition
is now evaluated per platform into a three-valued state and a branch is built from the **negation of the
branches before it**. It also walked `HakoStyle/` alone while the target is one synchronized group that
compiles for `appletvos` too, so the same unguarded use was FAIL there and PASS one directory away; it now
walks all of `ApplicationLibrary` — **224 files, 168 conditional imports, 696 use sites**, where it was 54,
28 and 113.

Three bugs inside that new model were found by measuring rather than by reading it, and they are the reason
the negative cases exist: the state was recorded *before* the directive was applied, so `#else` reported its
parent's state; the `#if` branch was never recorded in its own frame's `taken` list, so the `#else` unioned
in an empty history; and an occurrence count came to count files instead of matches, which nearly reported
`HakoBackButton` and `HakoQRSDisplayView` — both live — as orphans.

**Two ported types had lost their only caller**, the same defect class round 8 repaired in five other
places. `HakoReportLabel` was declared and never called because the three report list views lost the
`#if os(tvOS)` arm that called it; `HakoReportShareAction` had no caller because the three report detail
views spelled the shared `ReportShareAction` while `HakoReportZipDocument` and `HakoReportSharePopup` beside
them are spelled with their Hako names. Both are wired up now. Neither was visible to
`audit_hako_lossless_parity.py` — no token changed — and neither was reported by any *enforced* check,
because `hako-type-has-caller` was written in round 8 and left out of `CHECKS`.

**`hako-type-has-caller` is registered**, so it runs. It distinguishes an orphan the **port** introduced
from one the **frozen original** shipped — `hako-ui` declares `ConnectionMenuButton`, `ConnectionMenuView`
and `PrimaryTintModifier` and names each exactly once, at its own declaration — and fails only on the first
kind. The audit is now **PASS 19 FAIL 0**, where it was PASS 18.

**`audit_hako_lossless_parity.py` counted a missing file as "compared"**: `pages_compared` was every page
that was not `UNVERIFIED`, and a page whose file does not exist returns before any token comparison, so a
tree with all six ported pages deleted reported 6 of 6 and `lost_tokens` 0 — exactly the two figures
`test_fail_closed_exit_codes.py` asserts as its evidence that every page was compared. A new case deletes
the six pages and requires 0 compared and 6 accounted for as missing.

Plus four smaller repairs: `HakoNewProfileView.ownsDismiss` was the constant `true` where the original's tvOS
arm returns `onSuccess == nil`; the phone root's `selectedProfileUpdate` handler did not refresh the proxy
snapshot, the last of the original's three `reloadSystemProxy` sites; `check_swift_structure.py` returned 1
for a usage error as well as for a structural one; and `test_platform_gates.py` defaulted to one fixed
scratch path, so two concurrent runs crashed each other with a `FileExistsError` two frames from its cause.

**Two findings are not defects**, and are recorded as such rather than "fixed":
`HakoSettingView.allSettingsKeys` omits `.sponsors` while `settingsKey` spells it — the frozen original's
list omits it too, so the two lists disagree upstream and the port is faithful;
and `dup_module_scope.py`'s 18 name-only duplicates are legal code (file-private extensions, `extension
View` by design), which is why the enforced `shared-declaration-duplicates` passes on the same tree.

## 2. What round 9 changed

Two commits, both verified, neither a build result.

### `fd27efe` — the three `port_*.py` generators no longer overwrite silently

`port_tools_and_more.py`, `port_hako_pages.py` and `port_hako_components.py` each read

```python
if os.path.exists(destination) and not regenerate:
    ... report a difference and exit 1 ...
io.open(destination, "w", ...).write(text)
```

so `--regenerate` did not permit an overwrite, it **skipped the comparison that would have reported one**.
Measured: `port_tools_and_more.py --regenerate` rewrites `HakoLogView.swift`, `HakoToolsView.swift` and
`HakoSettingView.swift` to their upstream shape — every `#if !os(tvOS)` guard gone, unguarded
`import UIKit` back, six destination views on the More page spelled with their upstream names — with exit
status 0. `audit_apple_ui_boundary.py --strict` then fails four checks, while
`audit_hako_lossless_parity.py` **stays green on those same bytes**, because deleting a guard does not change
the set of UI tokens. That blind spot is the reason this was worth a commit of its own.

All three now go through `_safety_gate.plan_writes` and `_safety_gate.OverwriteAuthorization`:
`--replace=<path> --expect-sha256=<hex>`, one authorization per target and per blob; every target is decided
before any is written; all refusals are reported together with one command line that authorizes the whole
set; a target whose bytes already match is not rewritten; and a run that refuses anything writes nothing
anywhere. `scripts/dev/test_port_script_authorization.py` is the negative case, and it was proved to go red:
with the authorization check disabled, 4 of its 6 cases fail and five files are overwritten with no
authorization.

### `6a9d7eb` — the phone root observes the tunnel's status again

`up-hako@c1935cf ActiveDashboardView.swift` opened the command client and refreshed the system-proxy
snapshot from four places: `onAppear`, `scenePhase → .active`, `selection == .logs`, and a
`profile.status` observation. The port carried the first three. The fourth had been written as
`.onReceive(environments.$extensionProfile)`, which observes the wrong thing: `$extensionProfile` publishes
when the *profile object* is replaced, and `ExtensionEnvironments.reload()`
(`Library/Network/ExtensionEnvironments.swift:291`) replaces it only while it is `nil` or `.invalid`. A
status change does not replace the object, so **a tunnel started after launch never ran the handler** — the
command client stayed disconnected and the Home page's system-proxy card kept the state from before the
tunnel existed. The original could not have that hole because it held the profile as an `@EnvironmentObject`
and observed it directly; the iPad and Mac roots still do, through `DashboardView.swift:147`.

The fix is `ProfileStatusObserver`, a nested view attached as a `.background` — the shape this repository
already uses in `GlobalChecksModifier.swift:291` and `ConnectionLifecycleObserver.swift:41`. A `View`
holding the profile in an `@ObservedObject` is re-evaluated when `@Published status` changes, which a closure
on the root cannot be. The guard is the original's `status?.isConnected == true`.

**This is the one change in round 9 that touches a shipped code path, and it has never been compiled.**

## 3. Decisions taken in round 9, so they are not re-litigated

* **tvOS is out of scope.** The user's words: *"不用管tvos，我从未想过为他设计和准备界面"* — tvOS was never a
  target they intended to design or prepare an interface for. A repair that registered tvOS as a platform in
  `swift_directives.PLATFORMS` was written, verified green, and then **reverted at the user's instruction**;
  the patch is kept at `_work/r8/scratch/tvos-work-REVERTED.patch` if it is ever wanted. **Do not re-open
  the tvOS column as a "repair" without asking.** The two red tools below are red because of it and that is
  the accepted state.
* **The phone keeps the `Hako` UI and iPad/macOS keep upstream's.** Unchanged from round 8.

## 4. The two red commands, and why they are accepted

| Command | Result |
|---|---|
| `check_hako_macos_parse.py --platform tvos` | red, 61 `NOT VERIFIED` |
| `gate_hako_platform_imports.py --check` | red, same 61 |

They are red because `swift_directives.PLATFORMS` has no `tvos` entry, so *every* condition on tvOS answers
"no condition table" — including `os(iOS)`, which needs no SDK fact to answer. All 61 are inside a region
tvOS provably never compiles (mostly a file-level `#if !os(tvOS)`), so this is a gap in the tool, not a
defect in the source. **It is accepted, not fixed, because tvOS is out of scope.** If the goal is ever to
make the suite fully green, the honest repair is to narrow these two tools' platform set, not to weaken an
assertion — and that is a deliberate decision, not a cleanup.

Everything else is green: `audit_apple_ui_boundary.py --strict` **PASS 18 FAIL 0 UNKNOWN 0 UNDECIDABLE 0**,
plus `test_audit_apple_ui_boundary.py`, `test_audit_reverse_routing.py`,
`audit_hako_lossless_parity.py`, `test_fail_closed_exit_codes.py`, `test_migrate_secondary_page.py` (12/12),
`test_platform_gates.py` (0 of 19), `test_port_script_authorization.py` (0 of 6),
`check_swift_structure.py`, `check_platform_structure.py`, `check_generated_headers.py`.

## 5. The independent red-team audit, which round 8 owed and round 9 delivered

`_work/r8/redteam/REDTEAM-REPORT.md` and `REDTEAM-FINDINGS.json`. 23 findings: **5 high, 7 medium, 11 low, 0
critical.** The agent did not participate in writing the code, was given the SHA, the baselines and a
challenge list rather than anyone's conclusions, and measured against a frozen 621-file snapshot with
per-file SHA-256 (`redteam/snapshot-manifest.txt`) because the tree was being edited while it worked.

### What it could not break, which is worth as much as what it found

All four named checks go red on real injected faults with byte-identical restores; all four fail-closed
exit-code paths behave; `test_fail_closed_exit_codes.py` itself goes red when the historical `return 0` is
restored; `migrate_secondary_page.py --write` refuses all six report pages and an authorization does **not**
waive `HAKO_SYMBOL_LOSS`; the nine design-system files are byte-identical against both the git object and the
`up-hako` worktree, and that list plus its two documented exceptions is exactly the fork's 11-file
`HakoStyle/`; a conjunction-aware conditional-compilation model written specifically to beat the audit's
atom-set logic found **no sixth tvOS cascade**; no stash anywhere, no untracked file left in any of 15
repositories.

### The findings that are still open, in the order I would take them

Everything the red team found that can be settled in this environment has been settled; the list below is
what is left, and each one needs a decision, a Mac, or both.

1. **The audit's `hako-type-has-caller` cannot see an orphan whose upstream twin is called from the *same
   file* that declares it.** `hako-ui`'s `ConnectionListView.swift` declares `ConnectionMenuButton` at :99
   inside one platform arm and calls it at :19 inside another, so "is the upstream name still used" cannot
   be answered without deciding which arm. The check deliberately asks the narrower question — is the
   upstream name named by a file that does not declare it — and reports the three such declarations as
   inherited rather than failing on them. Closing this needs arm-level analysis.
2. **Needs a Mac: whether any of round 9's Swift changes behave as intended.** None of them has been
   compiled. `6a9d7eb` (the status observer) and the four guards in `932bf1c` are the ones with runtime
   meaning; the rest are wiring and structure.
3. **The audit's negative-case harness writes to the shared git directory.** Both
   `test_audit_apple_ui_boundary.py:446-447` and the copy it makes run `git reset` and
   `git checkout -- .`, and every worktree here has a **`.git` file** pointing at
   `sing-box-for-apple/.git/worktrees/<name>` (verified in round 9), so the copy's git commands act on the
   real repository's index and reflog. That is where the repeated `reset: moving to HEAD` reflog entries come
   from. The copy should get its own `.git` directory, or none at all. **Round 9 did not prove this caused
   the `jiejiebox-integrated` damage in §6; both are recorded as observed facts.**
4. **`jiejiebox-integrated` has a large staged, uncommitted changeset**, see §6.
5. **The six-bucket 66-page census was never independently verified** — only the page count and two of the
   six refusal codes were confirmed firing.
6. **GitHub Actions is unreadable from here** (`github.com` resolves to a non-public IP), but this
   repository has no `.github/workflows` at all, so no push from it can have triggered a run.

## 6. Two things in the workspace that a fresh window must not mistake for its own mess

### `jiejiebox-integrated`'s working tree is the **pre-repair** state, and is stale

`git status` there shows **23 `D` and 50 `M`, with no unstaged diff** — the index and the working tree agree,
so the files really are absent from disk. Its HEAD is `2207852`, which *is* an ancestor of today's
`r8/main`, so this is a checkout whose files were overwritten with older content and then staged.

The evidence that it is old content rather than work in progress:

* its `Hako*.swift` files are **byte-identical by SHA-256** to all five round-8 sibling branches
  `_work/r8/w-a` … `w-e` (checked `HakoCrashReportListView.swift`; every one matched);
* against `r8/main` it is **80 files changed, +1,903 / −12,658** — every file is a strict subset, nothing is
  newer;
* the "added" lines are the *older* text: it removes the `#if os(tvOS)` arm this round restored in the three
  report list views, removes the `ownsDismiss` two-arm condition again, and rewrites provenance headers to
  paths that do not exist (`Tools/HakoCrashReportListView.swift` for `Tools/CrashReportListView.swift`);
* it deletes all 26 tooling and document files, including every check this round's work depends on.

So it would have been a 12,658-line regression had it been committed and pushed. **Round 9 did not touch it
and did not commit it.** The *branch* was advanced to the verified `2335251` instead, and whoever owns this
checkout should decide what to do with the working tree — `git checkout -- .` restores it to its own HEAD,
and `git checkout 2335251 -- .` or a fresh worktree brings it to the verified state.

### The reflog

`git reflog` in `_work/r8/w-main` shows many `reset: moving to HEAD` entries that no human ran. See finding 4
above for the mechanism. They are harmless to the working tree (`reset` without `--hard` moves only the
index) but they are not a sign that someone force-reset anything, so do not go looking for a lost commit.

## 7. Rules that must not be relaxed

Round 8's §5 list still holds in full. Round 9 adds:

7. **A generator that cannot see a repair may not overwrite it.** The candidate is a fresh function of the
   pinned upstream text; the file on disk is the product of the last run *plus every human repair since*. Any
   new generator writes through `_safety_gate.plan_writes`, and any new write path gets a negative case that
   proves it refuses.
8. **A guard whose escape hatch does not work gets worked around.** `test_port_script_authorization.py`
   asserts that the command a refusal prints actually runs and writes. Keep that assertion when touching the
   authorization code — during round 9 the first printed command was malformed (`--replace=--replace …`) and
   only the round-trip test caught it.
9. **Do not put scratch files under `scripts/dev/`.** A stray untracked `.py` there makes
   `test_audit_apple_ui_boundary.py` fail, because its `reset` cannot remove untracked files. Round 9 hit this
   with two probe scripts. Scratch belongs in `_work/r8/scratch/`. Commit support scripts or keep them out.
10. **`audit_hako_lossless_parity.py` going green is not evidence that a ported page is intact.** It compares
    token sets, so it cannot see a deleted `#if` guard, a changed modifier order or a removed hook. Round 9's
    two most serious findings were both invisible to it.
