# Baseline

## Read this first: the knowledge base now describes the live product line

**Refreshed 2026-10-12** by an explicit Knowledge Refresh (`REFRESH.md`). Verified with a live
`git ls-remote` and a non-destructive fetch.

This file previously opened with the opposite statement — that the knowledge base described a
*frozen audit line* and that live `main` was a different, un-reviewed line 63 commits ahead. That
was true when it was written and is **no longer true**. The knowledge line was merged into `main`
(`5ada085`), `main` then absorbed the remaining work, and the two are now **one line**. The old
warning is retired deliberately, not by drift; the change is the single most important thing this
refresh records.

```text
upstream/dev @ 089d35e6   (SagerNet/sing-box-for-apple, 2026-10-09)   <- fixed upstream reference pin
      |
      `-- 2a18968        (r8/main; also archive/r8-final)
             |
             +-- 3a550d0                            (archive/pre-consolidation-2026-10-11)
             |                                       the previous integration line
             |
             `-- f4a9859 -> 82c9807 -> aa1e982 -> 3e9ab50      <- the OLD knowledge line + its 3 docs commits
                    |
                    `-- 5ada085  Merge branch 'jiejiebox/ne-p3-code-closure' into main
                           |
                           +-- 90a0e9a  Merge branch 'jiejiebox/p1c-iphone-device-closure' into main
                                  |
                                  +-- d052491, 5cab4ec, ...   <- LIVE origin/main, default branch
                                         (fork main: Hako product AND this knowledge base)
```

What changed in one sentence: **the knowledge baseline `f4a9859` is an ancestor of live `main`, not
a sibling of it.** `git merge-base --is-ancestor f4a9859 origin/main` exits 0. So this was a
*refresh on the same product line* (`REFRESH.md` §7), and the "different lines" framing — not the
measurements — was the stale part.

## The five baselines, and the four that are not interchangeable

| # | Baseline | Value | How to re-verify |
|---|---|---|---|
| 1 | **Production implementation baseline** | `5cab4ec5bcb405265e077f8bdb6e287101af4405` | `git log -1 5cab4ec` — "fix(ios): align network tool text colors". The newest commit on `main` whose diff is production source |
| 2 | Knowledge line HEAD | the docs commit carrying `KNOWLEDGE/` | `git log -1 --format='%h %ad' --date=short -- KNOWLEDGE/` — **deliberately not a constant**; re-derive it |
| 3 | **Live product line HEAD** | `origin/main` @ `331a67640` at this refresh | `git ls-remote --symref origin HEAD` |
| 4 | Upstream Apple baseline | `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` (tip of `upstream/dev`) | `git rev-parse upstream/dev` |
| 5 | Hako design/reference baseline | `c1935cff77246f97498400f5a0a7f430cfabbd55` (`hako-ui`, via tag `archive/hako-design-v1`) | `git rev-parse archive/hako-design-v1^{}` |

Baselines 1 and 3 differ only by docs commits at this refresh. **A docs-only commit does not move
baseline 1.** Do not chase the knowledge base's own SHA.

Also separate, and never collapse:

```text
parent/core gitlink        the parent repository's clients/apple pointer
libbox/core artifact       what an Apple build actually links (recorded nowhere — see below)
Runestone gitlink          Frameworks/Runestone
release/TestFlight state   no release baseline exists
```

## The delta this refresh absorbed

`f4a9859..main` = **69 commits, 99 files, +10643/-470** (two merges; 33 docs, 20 fix, 13 test,
1 chore).

The production-relevant part, grouped by theme rather than listed flat:

| Theme | Commits | What it settled |
|---|---|---|
| Screen-state delivery semantics | `891c6cb`, `987134b`, `c58b1f7`, `37798ea`, `ee428f7` | rule 5 (an unlock needs an observed lock); a current-state read is delivered as a **LEVEL**, never a sleep edge; the suite became buildable and reached 33 of 33 |
| NetworkExtension start transaction | `8d06a99`, `f8f978c` | the service lifecycle is serialised and a failed start **unwinds** what it created |
| Interface-monitor startup bound | `15d3a72`, `628644d` | airplane mode can no longer hang startup; the bound has an off-device seam |
| Hako ↔ upstream localization | `467f8ea`, `8fe8e79` | the zh-Hans interface stopped being half English; a new gate exists |
| Hako generated-page repairs | `9adb1f8`, `f03efe6`, `631c4fc`, `5855501`, `7b7d638`, `49a9275`, `2f0024c` | the migration's platform-condition damage, repaired |
| Import presentation | `6240a74`, `747a5d8` | the phone's profile import route left the modal form |
| iOS version / appearance | `d052491`, `48b5030`, `5cab4ec` | toolbar placement requires iOS 16; report badges and network-tool colors |
| Audit honesty | `6a1d175`, `ff24e4b`, `5794092`, `2f0024c` | a red boundary check whose default run reported green |
| UI suite closure | `3220019`, `a8ac1ea`, `d331977`, `26ff51a`, `d6f5d99`, `492f61d`, `543da17` | the snapshot suite reached 28 of 28 with per-case fixture states |

### Defects this baseline HAD and main has now fixed

These four were recorded as open defects by the previous baseline. **All four are verified fixed at
the current baseline.** The previous text is kept as the historical statement; the evidence column
is new and re-read at `5cab4ec`.

| Defect as previously recorded | Evidence at the current baseline | Commit |
|---|---|---|
| `ScreenStatePolicy.decide` published `.unlocked` from an unknown lock state, lifting the device pause; the repository's own test failed | `Library/Network/ScreenStateObserver.swift` contains `if fact == .unlocked, lastObserved != 1 {` — rule 5 present | `891c6cb` |
| `startDefaultInterfaceMonitor` waited on a `DispatchSemaphore` with **no timeout** while the service lifecycle lock was held — airplane mode could hang startup indefinitely | `ExtensionPlatformInterface.swift` now seeds from `monitor.currentPath`, then `semaphore.wait(timeout: .now() + InterfaceMonitorStartup.firstUpdateTimeout)` (= 2 s) | `15d3a72`, `628644d` |
| Three localization keys the phone asked for (`%lld groups`, `%lld active`, `%lld unread`) were missing, so those labels shipped English | all three keys present in `Localizable.xcstrings`; the real defect was wider — 112 strings, now 240 resolving with 0 pending | `8fe8e79`, `467f8ea` |
| A failed `startTunnel` rethrew without closing the command server it had just created | `startTunnel` is now a `do/catch` transaction calling `unwindFailedStart()`, which stops the observer, the service and the server in `stopTunnel`'s order | `8d06a99` |

`ScreenStateObserver.swift` is now 731 lines (was 527 at the old baseline) and
`ExtensionProvider.swift` is 575.

## Ref and pin inventory

| Field | Value | Evidence |
|---|---|---|
| Repository | `Piggy-Cat-bit-shadow/sing-box-for-apple` | `origin` remote |
| **Live default branch** | `origin/main` → `331a676404abec8340b850fa1600beed6c984963` | `git ls-remote --symref origin HEAD` |
| **Live remote heads** | `main` **only** | `git ls-remote --heads origin` |
| Upstream | `SagerNet/sing-box-for-apple` | remote |
| **Upstream product reference pin** | `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` | tip of `upstream/dev`; the fork point |
| Runestone gitlink | `baeb3cbf8332d26b4f7b4c175a01f288ebbf3e7f` | `git ls-tree HEAD Frameworks/Runestone` (submodule not initialized); confirmed identical to `089d35e6` by `audit_apple_ui_boundary.py` check `repository-hygiene` |
| Hako design pin | `c1935cff77246f97498400f5a0a7f430cfabbd55` | tag `archive/hako-design-v1` |
| Hako freeze tag | `iphone-hako-ui-freeze-v1` → `fc7f77b` | annotated tag `b7d830ea`; **not an ancestor of `main`** |

### `dev` is gone, and this knowledge base should say so

At the previous baseline the fork's remote carried `dev` as its **default branch**, alongside
`jiejiebox/*`, `r8/*` and others. All of them have been deleted. The remote now carries `main`
alone, and `main` is the default. `dev` → `d1224bb` was audited before deletion: 19 unique commits,
13 patch-identical to commits already on `main` and 6 superseded. See
`modules/repository-history.md` for the retained reasoning.

Everything previously reachable only through those branches is preserved either by ancestry on
`main` or by a tag — which is exactly what the tag table below exists to prove.

### Archive tags are the recovery path for deleted branches

| Tag | Commit | What it preserves |
|---|---|---|
| `archive/hako-design-v1` | `c1935cf` | **the port reference pin** (this is how `c1935cf` stays reachable) |
| `archive/pre-consolidation-2026-10-11` | `3a550d0` | the *integrated* line (37 commits past `2a18968`) |
| `archive/r8-final` | `2a18968` | the round-8 merge line |
| `archive/hardening-wip-2026-10-11` | `052f06b` | the Hako migration WIP |
| `archive/ipad-upstream-port-final` | `816600a` | the iPad upstream UI line |
| `archive/old-main-2026-10-11` | `ab33c3f` | the fork's previous `main`; also the only tag anchoring a `dev`-unique commit |
| `archive/apple-consolidated-candidate-2026-10-11` | `bb5309b4` | a consolidated candidate |
| `iphone-hako-ui-freeze-v1` | `fc7f77b` | a reviewed freeze of the *old* phone surface |
| `libbox-stringbox-abi-1` | `8599039` | historical ABI marker (lightweight tag) |
| `libbox-stringbox-abi-2` | `2b23330` | historical ABI marker (lightweight tag) |

Verified count at this refresh: **10 tags**, 8 annotated + 2 lightweight.

### AI caution: do not prune this clone (re-audited, still true, narrower)

`REFRESH.md` §31 requires re-auditing this warning rather than carrying it forever, because it was
written for a topology that has since changed. Re-audited **2026-10-12**:

- The remote now carries **one** branch. Every other fork line exists **only** as a local branch
  (`jiejiebox/*`, `r8/*`), a local remote-tracking ref, or a tag.
- The `archive/*` tags **are** on the remote, so the tagged commits survive a fresh clone. The
  *untagged* commits on those local lines do not.
- Local branches at this refresh: `jiejiebox/integrated`, `jiejiebox/v0.1.6-hardening`,
  `jiejiebox/hako-ui-migration-wip`, `r8/a-generator`, `r8/b-boundary`, `r8/c-platform`,
  `r8/d-reach`, `r8/e-redteam`, `r8/main`.

So the warning **survives, with a narrower reason**: `git fetch --prune` / `git remote prune` no
longer risks anything on `main`'s ancestry — `main` is the remote — but it would still drop the
local pointers to the untagged rounds whose archaeology has not been fully absorbed. Prefer
`git fetch --tags origin` (no `--prune`). Re-audit again at the next refresh; do not treat this
paragraph as permanent.

## Parent/core linkage: three recorded values, and one genuine unknown

The parent repository `Piggy-Cat-bit-shadow/sing-box` carries `clients/apple` as a gitlink. Three
values are recorded in-repo, and **none of them can be re-checked from this repository**:

| Recorded in | Value | Date |
|---|---|---|
| `f4a9859` commit message | `2a189686ae382d860f643ec53b64cbdb6cca562e` — "the gitlink is unchanged at `2a189686`" | 2026-10-11 |
| `docs/HAKO-ROUND8-HANDOFF.md:16` | `2b23330d489b9f6b45e98f903f458842e8961594` | round 8 |
| `docs/pending/HAKO-OWNERSHIP.md:41` | `5911580a6366da78e6b4b5b4459596e5a2cf1eb4` | earlier; the file itself flags a discrepancy with the submodule worktree |

The parent-side current value is `EXTERNAL_CHECK_REQUIRED`. This refresh did **not** change it: the
parent repository is not checked out here, and inventing a value would be worse than recording the
gap.

What *is* genuinely unknown, and more important: **nothing in this repository records which
core/libbox build an Apple build links.** `Libbox.xcframework` is project-referenced, absent, and
gitignored (`.gitignore:2`); no core SHA, branch or version appears anywhere in the tracked tree.
This is the sharpest structural difference from the Android sibling repository, which pins its core
in `version.properties:coreCommit` and verifies the pin against the shipped binary. See
`modules/build-signing-testflight.md`.

## Design provenance: two references that are not interchangeable

| Reference | SHA | Role | Resolvable here? |
|---|---|---|---|
| `hako-ui` | `c1935cff77246f97498400f5a0a7f430cfabbd55` | the fork's **port reference line**; what the parity and migration audits compare against. Also tag `archive/hako-design-v1` | **yes** — via the archive tag (the branch is gone) |
| `Hako-Client` (GPL-3.0, `TokenPLS/Hako-Client`) | `62aa2f2fedffd46c245d5a87d2258c24bef3cd82` | the **original visual design source** several `HakoStyle` design-system files were extracted from | **no** — `fatal: could not get object info`; it is a different repository |
| `iphone-hako-ui-freeze-v1` | annotated tag → `fc7f77b` | a reviewed freeze of the *old* phone surface | yes, but see the caution below |

Files whose headers name `Hako-Client`/`62aa2f2f`: `HakoTheme`, `HakoSurface`, `HakoRow`,
`HakoCard`, `HakoStatus`, `HakoEmptyState`, `HakoData`, `HakoHomeView`,
`HakoPrimaryShell`. Files whose provenance is recorded against `hako-ui@c1935cf`: the
migration and parity tooling, plus the ported/generated files.

### AI caution: the freeze tag cannot be used as a regression baseline

`iphone-hako-ui-freeze-v1` points at `fc7f77b`, which is on the abandoned `hako-ui` line
and is **2 commits older than the port reference** (`git rev-list --count fc7f77b..c1935cf`
= 2; the newer of the two is the remaining-quota row the fork exists to keep). It is not
an ancestor of the product branch, and the product branch deliberately diverges from it
— `SFI/MainView.swift` at HEAD is byte-identical to upstream's version and differs from
the tag's version, by design (`0297c8e`).

The tag's own guard is `docs/pending/check-iphone-hako-freeze.sh` (not
`scripts/dev/…`), its `FIXED_UPSTREAM_SHA` (`3cc0835f…`) is absent from this object
store, and `docs/pending/README.md` records why it was retired: a guard pinned to
`fc7f77b` "would require this branch to roll that feature back".

Treat the tag as **provenance for a superseded surface**, never as a "must equal"
comparison.
