# Repository history and document status

## Ref roles

`upstream/dev@089d35e` is the fixed official reference for this product line — the fork point, and
the pin the boundary audit compares against. **`main` is now the live product branch and the
fork's only remote branch**; `jiejiebox/integrated`, `jiejiebox/ne-p3-code-closure`,
`jiejiebox/v0.1.6-hardening`, `jiejiebox/hako-ui-migration-wip` and `r8/*` have all been **merged
into `main` or retired**, and `dev` has been **deleted**. Do not infer equivalence from
ahead/behind counts; use patch/diff analysis.

### What happened to each retired ref

| Ref | Disposition | Evidence |
|---|---|---|
| `main` | **live product branch**, default, only remote head | `git ls-remote --symref origin HEAD` |
| `jiejiebox/ne-p3-code-closure` | merged into `main` by `5ada085` | ancestor of `main` |
| `jiejiebox/integrated` | merged/absorbed into the consolidated line | `archive/pre-consolidation-2026-10-11` → `3a550d0` |
| `jiejiebox/p1c-iphone-device-closure` | merged into `main` by `90a0e9a` | ancestor of `main` |
| `jiejiebox/v0.1.6-hardening` | absorbed; preserved by tag | `archive/hardening-wip-2026-10-11` → `052f06b` |
| `jiejiebox/hako-ui-migration-wip` | absorbed; preserved by tag | same tag covers it |
| `r8/*` (5 branches) | ancestors of the consolidated line | `archive/r8-final` → `2a18968` |
| `hako-ui` | port reference line; preserved by tag | `archive/hako-design-v1` → `c1935cf` |
| `ipad-upstream-ui` | absorbed; preserved by tag | `archive/ipad-upstream-port-final` → `816600a` |
| **`dev`** | **audited and DELETED from the remote** | see below |
| `stable`, `wip` | upstream project's own branches, untouched | on the `upstream` remote |

### `dev` deletion: the retained reasoning

`dev` was the fork's GitHub default branch. It was deleted after a full audit rather than a
count-based one, because a count cannot see a cherry-pick:

- `origin/main..origin/dev` = **19** unique commits; left/right count `183 / 19`.
- `git patch-id --stable` matched **13 of the 19** against commits already on `main` — byte-identical
  patches under different SHAs (cherry-picked/rebased), each verified still present in `main`'s tree.
- The remaining **6** were each superseded, not lost: `891c6cb`/`987134b` superseded the initial
  `ScreenStateObserver`; `467f8ea` + the libghostty-spm `1.6 → 2.2` bump made two temporary
  workarounds unnecessary (one of which `main` reverted with an explicit
  `Revert "…"` naming the `dev` SHA); and two were dependency/version pins `main` had already
  moved past.
- **Zero** commits were classified "unique and must keep"; **zero** were unverifiable.
- No commit was orphaned: `archive/old-main-2026-10-11` → `ab33c3f` is the one tag anchoring a
  `dev`-unique commit, and the rest are content-preserved on `main`.

The lesson worth keeping: **`main` being ahead does not mean a diverged branch is empty, and a
branch being "the upstream reference" is not a reason to keep it** — the `upstream` remote serves
that role and is unaffected.

`iphone-hako-ui-freeze-v1` is a design-provenance tag and must not move. ABI tags
(`libbox-stringbox-abi-1`, `libbox-stringbox-abi-2`) are historical ABI markers.
Historical topic refs (`hako-ui`, `ipad-upstream-ui`, `fix/*`) are evidence, not automatic
merge targets. Ten tags exist in total; see `BASELINE.md` for the full table with commits.

## Existing documentation classification

| Material | Classification | Current use |
|---|---|---|
| README, `docs/APPLE-DEVICE-ACCEPTANCE.md`, visual acceptance, upstream playbook | KEEP | entry/checklist/procedure; verify against source |
| architecture audit, refactor baselines/final, phase status/reports, screen facts, migration/parity/reachability docs | ABSORB-INTO-KNOWLEDGE | evidence remains; this knowledge is the concise current map |
| Round 8/9 handoffs and remaining-failures docs | ARCHIVE | point-in-time forensic record |
| `docs/pending/` | ARCHIVE-ONLY | frozen unported/blocked material; never current shipping truth |
| root `APPLE-UI-MAC-VERIFICATION-REPORT.md`, `APPLE-ONE-SHOT-CONVERGENCE-REPORT.md`, `APPLE-TAIL-CLEANUP-REPORT.md`, `REPOSITORY-CONSOLIDATION-REPORT.md`, `BRANCH-INVENTORY.md`, `OLD-WORKTREE-AUDIT.md`, `NE-AIRPLANE-STARTUP-HANG-REPORT.md` | ARCHIVE | evidence snapshots, not current design source |
| `HAKO-I18N-REPORT-BADGE-FIX-REPORT.md`, `HAKO-IMPORT-UI-FIX-REPORT.md` | KEEP | they document fixes that are live, and name the exact key/route decisions |

Nothing was deleted or moved during this refresh; classification is deliberately semantic so links
and forensic evidence remain intact.

### Documents that are now factually stale — do not read them as current

These carry statements this refresh proved wrong. They were **not edited**, because the refresh
protocol forbids rewriting history to match a later state; they are listed so a future reader is
not misled.

| Document | Stale claim |
|---|---|
| `BRANCH-INVENTORY.md` | measures `origin/dev` against a canonical line (`consolidation/apple-main`) that no longer exists, and recommends `KEEP (upstream reference)` for `dev`. Both are superseded — see the deletion reasoning above |
| `KNOWLEDGE_STAGE1_REPORT.md`, `KNOWLEDGE_STAGE2_REINFORCEMENT_REPORT.md` | every "at this baseline" statement is about the old frozen line |
| `docs/APPLE-ARCHITECTURE-AUDIT.md`, `docs/APPLE-REFACTOR-BASELINES.md` | ahead/behind tables measured against `upstream/dev@3bcb8ca` and the old `main` |
| `docs/pending/HAKO-OWNERSHIP.md` | describes `main` (`ab33c3f`) as an 8-commits-behind upstream mirror; `main` is now the product line |

## Current-source override example

README contains older phase material saying that Hako page bodies had not yet migrated. That
statement conflicts with current source, where `SFI/HakoPageContent.swift` routes Hako page types
under `ApplicationLibrary/Views/HakoStyle/`. Treat the README passage as `ARCHIVE-ONLY` historical
progress, not a current shipping assertion; source and the selected-ref audit decide current
routing.
