# Baseline

## Read this first: the knowledge base describes a frozen audit line, not live `main`

The single most important fact in this file. Verified 2026-10-12 with a live
`git ls-remote` and a non-destructive `git fetch --tags origin`.

```text
upstream/dev @ 089d35e6   (SagerNet/sing-box-for-apple, 2026-10-09)
      |
      `-- 2a18968        (r8/main, 2026-10-10 — the common base)
             |
             +-- f4a9859 -> ... -> HEAD of jiejiebox/ne-p3-code-closure   <- THIS knowledge base
             |   (4 commits: the production fix + stage-1, stage-1 clarification, stage-2)
             |
             +-- 3a550d0                            <- 37 commits (archive/pre-consolidation-2026-10-11)
             |   (was jiejiebox/integrated)            the previous integration line
             |
             `-- d0524912                           <- 63 commits  (LIVE origin/main, default branch)
                 (fork main)                            contains the Hako product AND newer fixes
```

At the Stage-2 review point (production baseline + 3 docs commits):

| Comparison | Ahead | Behind |
|---|---|---|
| `HEAD` vs `upstream/dev@089d35e6` | 88 | 0 |
| `HEAD` vs `3a550d0` (*integrated* line) | 3 | **37** |
| `HEAD` vs `d0524912` (**live `main`**) | 3 | **63** |
| `HEAD` vs `upstream/main@e232aaf2` | 91 | 0 |

The fork remote's **default branch is `main`**, not `dev`, and `main` **is** the Hako
product: it carries all 54 `ApplicationLibrary/Views/HakoStyle/*.swift` files and
`SFI/HakoPhoneRootView.swift`. It does **not** carry `KNOWLEDGE/` or `AGENTS.md` — the
knowledge base and the live product line are different lines.

**Consequence for any reader:** behaviour read out of this baseline is the behaviour of
a frozen audit line, not of the shipping product. Before asserting anything about
current behaviour, run:

```bash
git log --oneline HEAD..origin/main            # 63 commits at Stage 2
git diff --stat  HEAD..origin/main
```

### Defects that this baseline has and live `main` has already fixed

Found by this review and confirmed against `origin/main`. Do not re-derive these; do not
report baseline behaviour as the product's.

| Baseline defect | Evidence here | Fixed on `origin/main` by |
|---|---|---|
| `ScreenStatePolicy.decide` publishes `.unlocked` from an unknown lock state, which lifts the device pause. The baseline's **own test fails** (`ScreenStatePolicyTests.testTheWholeTruthTable`, "an unlock was published without a transition"). | `ScreenStateObserver.swift:233-250` has rules 1–4 only; test at `ScreenStateObserverTests.swift:242` requires `last == 1` | `891c6cb` (rule 5) — **verified present**: `git show origin/main:Library/Network/ScreenStateObserver.swift` contains `if fact == .unlocked, lastObserved != 1`. Also `987134b` "deliver a current-state read as a level, never a sleep edge" |
| `startDefaultInterfaceMonitor` waits on a `DispatchSemaphore` with **no timeout**, while the service lifecycle lock is held — airplane mode can hang startup indefinitely. | `ExtensionPlatformInterface.swift` `semaphore.wait()` | `15d3a72` "bound the first interface-path wait, so airplane mode cannot hang startup" (+ `628644d`, its off-device test seam) |
| Three localization keys the phone asks for (`%lld groups`, `%lld active`, `%lld unread`) are missing from `Localizable.xcstrings`, so those labels ship English. | `Localizable.xcstrings` at HEAD | `467f8ea` "reuse upstream localization for Hako UI" — key present on `origin/main` |
| A failed `startTunnel` rethrows without closing the command server it just created. | `ExtensionProvider.swift` `catch` block | `8d06a99` "serialise the service lifecycle, so a teardown cannot land inside a start" adds `unwindFailedStart()` — **verified present on `origin/main`** |

The baseline's `ExtensionProvider.swift` is 23,254 bytes; `origin/main`'s is 27,192.

## Four different things that must not be confused

| Field | Value | How to re-verify |
|---|---|---|
| **Production implementation baseline** | `f4a98590e9edaefc4a231b7f30d5b81a30917b66` | `git log -1 f4a9859` — "fix(ne): the stop window could drop a live command server, and a reload could cancel its own monitor". The last commit on this line whose diff is production code |
| Knowledge document revision | **deliberately not recorded as a constant.** Run `git log -1 --format='%h %ad' --date=short -- KNOWLEDGE/` | docs only; **not** a product SHA. A hardcoded value here is stale the moment the knowledge base is committed — which is exactly the failure this file exists to prevent |
| Branch carrying both | `jiejiebox/ne-p3-code-closure` | `git rev-parse --abbrev-ref HEAD` |
| Working tree at Stage-2 review | clean at review start | `git status --porcelain` |

```text
f4a9859  production baseline
   |-- 82c9807  docs(apple): add stage 1 knowledge baseline
   |-- aa1e982  docs(apple): clarify knowledge evidence boundaries
   `-- (stage 2) docs(apple): reinforce the knowledge base for stage 2
```

**Do not chase the knowledge base's own commit SHA.** A docs-only commit after the
baseline does not move it and is not a runtime change. The stage-2 commit is
deliberately not quoted by hash for that reason: re-derive it with
`git log --oneline f4a9859..HEAD`.

**Release baseline: none recorded.** No archive/export/upload has been run or verified on
this line. `origin/main` carries newer work but is itself unreviewed by this knowledge
base. See `ACCEPTANCE.md`.

## The product line was re-founded, not continued

- `git merge-base HEAD upstream/dev` = `089d35e6…`, which **is** the tip of
  `upstream/dev`, not merely an older common ancestor. The fork point is exactly
  upstream's tip; there is **no divergence** (`HEAD..upstream/dev` = 0).
- The older Hako lines — `hako-ui` (tip `d5b2c31e`), the freeze tag's commit `fc7f77b`,
  and `2b23330d` — fork from `2b1763a8` (2026-09-14) and are **not ancestors of HEAD**:
  `git merge-base --is-ancestor fc7f77b HEAD` → exit 1. They are **source material**.

## Ref and pin inventory

| Field | Value | Evidence |
|---|---|---|
| Repository | `Piggy-Cat-bit-shadow/sing-box-for-apple` | `origin` remote |
| **Live default branch** | `origin/main` → `d052491215144f209b4726bbcf374649881defa3` | `git ls-remote --symref origin HEAD` |
| Live remote heads | `dev` → `d1224bb`; `jiejiebox/ne-p3-code-closure` → `aa1e982`; `main` → `d0524912` | `git ls-remote --heads origin` |
| Upstream | `SagerNet/sing-box-for-apple` | remote |
| **Upstream product reference pin** | `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` | tip of `upstream/dev`; the fork point |
| Runestone gitlink | `baeb3cbf8332d26b4f7b4c175a01f288ebbf3e7f` | `git ls-tree HEAD Frameworks/Runestone` (submodule not initialized) |
| Hako freeze tag | `iphone-hako-ui-freeze-v1` → `fc7f77b` | annotated tag `b7d830ea`; **not an ancestor of HEAD** |

### Archive tags are the recovery path for deleted branches

Branches that once existed are **gone from the remote**. Their content survives only as
remote tags and as local remote-tracking refs. Verified mapping:

| Tag | Commit | What it preserves |
|---|---|---|
| `archive/hako-design-v1` | `c1935cf` | **the port reference pin** (this is how `c1935cf` stays reachable) |
| `archive/pre-consolidation-2026-10-11` | `3a550d0` | the *integrated* line (37 commits past `2a18968`) |
| `archive/r8-final` | `2a18968` | the round-8 merge line |
| `archive/hardening-wip-2026-10-11` | `052f06b` | the Hako migration WIP |
| `archive/ipad-upstream-port-final` | `816600a` | the iPad upstream UI line |
| `archive/old-main-2026-10-11` | `ab33c3f` | the fork's previous `main` |
| `archive/apple-consolidated-candidate-2026-10-11` | `bb5309b4` | a consolidated candidate |

### AI caution: never prune this clone

`git fetch --prune`, `git remote prune` and an aggressive `git gc` would delete the
local `origin/*` refs that are the **only** remaining pointers to several lines; the
remote no longer has those branches. Fetch with `git fetch --tags origin` (the
`archive/*` tags are the remote-preserved copies), never with `--prune`.

## Parent/core linkage: three recorded values, and one genuine unknown

The parent repository `Piggy-Cat-bit-shadow/sing-box` carries `clients/apple` as a
gitlink. Three different values are recorded in-repo:

| Recorded in | Value | Date |
|---|---|---|
| `f4a9859` commit message | `2a189686ae382d860f643ec53b64cbdb6cca562e` — "the gitlink is unchanged at `2a189686`" | 2026-10-11 |
| `docs/HAKO-ROUND8-HANDOFF.md:16` | `2b23330d489b9f6b45e98f903f458842e8961594` | round 8 |
| `docs/pending/HAKO-OWNERSHIP.md:41` | `5911580a6366da78e6b4b5b4459596e5a2cf1eb4` | earlier; the file itself flags a discrepancy with the submodule worktree |

The **most recent and locally checkable** value is `2a189686`, which is exactly the
`r8/main` tip / `archive/r8-final` — i.e. the commit this branch descends from. The
parent-side current value is therefore `EXTERNAL_CHECK_REQUIRED`, but it is **not**
unrecorded.

What *is* genuinely unknown is different and more important: **nothing in this
repository records which core/libbox build an Apple build links.** `Libbox.xcframework`
is project-referenced, absent, and gitignored (`.gitignore:2`); no core SHA, branch or
version appears anywhere in the tracked tree. This is the sharpest structural difference
from the Android sibling repository, which pins its core in
`version.properties:coreCommit` and verifies the pin against the shipped binary. See
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
migration and parity tooling, plus the ~30 ported/generated files.

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
