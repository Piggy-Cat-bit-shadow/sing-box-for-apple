# Jiejiebox Apple knowledge base

**Knowledge Baseline + Git Delta = Current AI Context.** This directory is a
high-cost reconstruction cache, not a substitute for source. Source, project settings and
Git override it whenever they disagree.

## Read order

1. `BASELINE.md` — **first, and completely.** It states which line this knowledge
   describes and how far the live product line has moved past it.
2. `PROJECT.md`, `ARCHITECTURE.md`, `INVARIANTS.md` — scope, ownership, non-negotiables.
3. Then **only** the modules whose ownership domain the task touches.
4. `ACCEPTANCE.md` before asserting any test, device or release outcome.
5. `COMMIT-INDEX.md` only to find a specific change; it is navigation, not evidence.

## The delta loop — and its trap

```bash
git log  --oneline f4a9859..HEAD      # 3 commits, docs only — this LINE's delta
git log  --oneline HEAD..origin/main  # 63 commits — the PRODUCT's delta
git diff --stat  HEAD..origin/main
```

Both are needed. The first says whether *this knowledge* is stale; the second says
whether *the product* is. Reading only the first is the trap this knowledge base was
written to close: it makes a 63-commit-behind audit line look current.

## Module map

| Module | Owns |
|---|---|
| `modules/platform-ownership.md` | the idiom gate, and which presentation each platform gets |
| `modules/hako-ui.md` | Hako provenance, the two design references, and the generator hazard |
| `modules/shared-business-layer.md` | what the phone and the official UI genuinely share |
| `modules/network-extension.md` | provider lifecycle, serialization, teardown fencing |
| `modules/screen-state.md` | the device axis: policy, fencing, and the known red case |
| `modules/networking.md` | the three `NWPathMonitor` owners and interface startup |
| `modules/subscription-profile.md` | profiles, imports, subscription metadata |
| `modules/localization-branding.md` | the string catalog vs visible name vs release identity |
| `modules/build-signing-testflight.md` | targets, entitlements, xcframework, release lanes |
| `modules/tests-audits.md` | what each gate proves, how to run it, and what is red |
| `modules/repository-history.md` | ref roles and the document-classification table |

## Evidence vocabulary

Use exactly these, and never promote one to another:

```text
VERIFIED_SOURCE   read directly in source at the stated revision
VERIFIED_GIT      proved by a diff, tree or ref
VERIFIED_STATIC   an executable audit/script produced this result
VERIFIED_UNIT     the unit suite was actually executed
VERIFIED_BUILD    a recorded successful xcodebuild
VERIFIED_SIMULATOR
VERIFIED_DEVICE   a physical device produced this result — name the device
INFERRED          deduced; say from what
UNVERIFIED        asserted but not checked
UNKNOWN           could not be determined; say what is missing
BLOCKED_BY_ENVIRONMENT
NEEDS_DEVICE
EXTERNAL_CHECK_REQUIRED
```

Forbidden inferences: source inspection ≠ compilation; a build ≠ runtime behaviour;
static token/byte parity ≠ pixel parity; a simulator ≠ a physical device; an iPhone PASS
≠ iPad or macOS.

## Rules

- Normal feature work **must not** refresh this directory. Refresh it only in an
  explicit Knowledge Refresh task.
- **Explicit Knowledge Refresh / Re-baseline only:** run `REFRESH.md`. Normal
  development does not update this directory in real time.
- Do not add a file per finding. Correct and compress first; add a file only when an
  existing structure cannot express a subsystem.
- Every SHA, path and claim added here must cite where it was verified.
- **Never run `git fetch --prune` / `git remote prune` / aggressive `git gc` in this
  clone.** Several fork lines survive only as local `origin/*` refs. Use
  `git fetch --tags origin`; the `archive/*` tags are the remote-preserved copies.
- `KNOWLEDGE_STAGE1_REPORT.md` and `KNOWLEDGE_STAGE2_REINFORCEMENT_REPORT.md` describe how
  this base was built. They are history, not current truth.
