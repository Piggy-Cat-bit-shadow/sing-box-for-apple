# Round 9 → Round 10 handoff

Written for a fresh window with no memory of round 9. **This file is the whole handoff.** Its predecessor,
`HAKO-ROUND8-HANDOFF.md`, is still accurate about the environment, the worktrees and the rules, and is not
repeated here except where round 9 changed it.

## 1. Where round 9 ended

| | |
|---|---|
| Repository | `https://github.com/Piggy-Cat-bit-shadow/sing-box-for-apple` |
| Integration branch | `jiejiebox/integrated` |
| **Final SHA on `r8/main`** | **`6a9d7eb`** (round 9 made `fd27efe` and `6a9d7eb`) |
| Round 9 start | `2207852` (which is what `jiejiebox/integrated` and the remote both still point at) |
| iPhone UI gold standard | `hako-ui@c1935cff77246f97498400f5a0a7f430cfabbd55` |
| Upstream comparison baseline | `SagerNet/sing-box-for-apple dev@089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| `r8/main` on the remote? | **No.** `fd27efe` and `6a9d7eb` are local only; pushing was not requested. |

```text
IPHONE_HAKO_UI=STATIC_VERIFIED
IPAD_MAC_OFFICIAL_ISOLATION=PASS_STATIC
GENERATOR_SAFETY=PASS
INDEPENDENT_DEBUG=COMPLETED              <- round 8's missing deliverable, done in round 9
APPLE_BUILD_DEVICE_PIXEL=UNVERIFIED
TVOS=OUT_OF_SCOPE                        <- the user's decision, see §3
```

Set the environment up exactly as `HAKO-ROUND8-HANDOFF.md` §1 says. `python` and `git` are still not on
`PATH`, and `DSH_REPO` / `DSH_GIT` still have to be set in every command.

`_work/r8/scratch/run-suite.ps1` runs the whole 16-command suite and prints one line per command. **It has a
UTF-8 BOM on purpose** — without it PowerShell 7 reads the Chinese path in it as GBK and every command
fails with a path error. Copy that habit for any script containing a non-ASCII path.

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

1. **HIGH — the audit's detector has two holes** (`audit_apple_ui_boundary.py:1349`, `:1367`, `:1280-1284`).
   `platform-guard-agreement` inspects uses only inside `ApplicationLibrary/Views/HakoStyle/`, although all of
   `ApplicationLibrary` compiles for tvOS; and `:1280-1284` unions an `#if`'s atoms into its `#else` arm, so a
   use inside the `#else` of the `#if` that declares it is PASS. **Proven by injection, no live instance
   found.** Both are worth closing because a detector hole is what let the `port_*.py` regression hide.
2. **MEDIUM — `hako-type-has-caller`'s exclusion is not justified.** It reports five findings on a correct
   tree, and the red team checked all five: they are true. Five unused private ported types are untracked by
   any check. Round 8 kept the check out of the enforced set; the evidence says it should be brought in, or
   the five types removed.
3. **MEDIUM — the phone root has no `onAppear`-equivalent for `connect()` when the app is already active**
   and the tunnel arrives by another route; related to §2's fix, worth a second look now that the status
   observation exists.
4. **LOW/MEDIUM — the audit's negative-case harness writes to the shared git directory.**
   `test_audit_apple_ui_boundary.py:369-370` runs `git reset` and `git checkout -- .` inside a
   `shutil.copytree`, and every worktree here has a **`.git` file** pointing at
   `sing-box-for-apple/.git/worktrees/<name>` (verified in round 9), so the copy's git commands act on the
   real repository's index and reflog. That is where the repeated `reset: moving to HEAD` reflog entries come
   from. The copy should get its own `.git` directory or none at all. **Round 9 did not prove this caused the
   `jiejiebox-integrated` damage in §6; both are recorded as observed facts.**
5. **LOW — `jiejiebox-integrated` has an uncommitted staged changeset**, see §6.
6. **LOW — the six-bucket 66-page census was not independently verified.** Only the page count and two of the
   six refusal codes were confirmed firing.

## 6. Two things in the workspace that a fresh window must not mistake for its own mess

### `jiejiebox-integrated` has a large staged, uncommitted changeset

`git status` there shows **23 `D` and 50 `M`, with no unstaged diff** — the index and the working tree agree,
so the files really are absent from disk. The deletions are 19 files under `scripts/dev/` (including
`_safety_gate.py`, `test_platform_gates.py`, `test_migrate_secondary_page.py`,
`MIGRATION-SAFETY-CONTRACT.md`) and the four round-8 documents under `docs/`. **All of them are in `HEAD`**,
so this is recoverable with a checkout, not data loss. It looks like a deliberate "ship the app, not the dev
scaffolding" preparation that was never committed. **Round 9 did not touch it and did not commit it** — that
is a decision for whoever owns the integration branch. `r8/main` is unaffected.

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
