# Jiejiebox Apple knowledge base

**Knowledge Baseline + Git Delta = Current AI Context.** This directory is a
high-cost reconstruction cache, not a substitute for source. Source, project settings and
Git override it whenever they disagree.

This base **describes the live product line** as of the 2026-10-12 refresh. It previously
described a frozen audit line; that framing was retired because the two lines were merged.
See `BASELINE.md` — it is the file that states which line this is, and it is the one to
read when the two disagree.

## Read order

1. `BASELINE.md` — **first, and completely.** It states which line this knowledge
   describes, the five baselines, and what the last refresh absorbed.
2. `PROJECT.md`, `ARCHITECTURE.md`, `INVARIANTS.md` — scope, ownership, non-negotiables.
3. Then **only** the modules whose ownership domain the task touches.
4. `ACCEPTANCE.md` before asserting any test, device or release outcome.
5. `COMMIT-INDEX.md` only to find a specific change; it is navigation, not evidence.
6. `REFRESH.md` only when running an explicit Knowledge Refresh / Re-baseline. It is the
   procedure, not part of the current picture.

## The delta loop

```bash
git log  --oneline 5cab4ec..HEAD       # this LINE's delta — 0 commits at the last refresh
git log  --oneline HEAD..origin/main   # the PRODUCT's delta — also 0, same line
git diff --stat  HEAD..origin/main
```

Both are still worth running, and for the reason the trap was written about: the first says
whether *this knowledge* has been left behind, the second says whether *the product* has. At
the last refresh they were the **same line**, so both were empty — but that is a measurement,
not a durable property, and the next refresh must re-derive it rather than assume it.

The historical trap was the reverse: a knowledge base on a frozen branch reported its own
3-commit docs delta while the product had moved 63 commits elsewhere. **Do not hardcode
either number.** Recompute the product line first (`git ls-remote --symref origin HEAD`).

## Module map

| Module | Owns |
|---|---|
| `modules/platform-ownership.md` | the idiom gate, and which presentation each platform gets |
| `modules/hako-ui.md` | Hako provenance, the two design references, and the generator hazard |
| `modules/shared-business-layer.md` | what the phone and the official UI genuinely share |
| `modules/network-extension.md` | provider lifecycle, serialization, the start transaction, teardown fencing |
| `modules/screen-state.md` | the device axis: policy rules, edge vs level, fencing, evidence boundary |
| `modules/networking.md` | the three `NWPathMonitor` owners, the startup bound, interface recovery |
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

**A gate that scanned nothing is not a green gate.** One gate in this repository reports
`PASS` on Windows while examining zero files — see `modules/tests-audits.md`. Read the count
a gate prints, not only its exit status.

## Rules

- Normal feature work **must not** refresh this directory. Refresh it only in an
  explicit Knowledge Refresh task.
- **Explicit Knowledge Refresh / Re-baseline only:** run `REFRESH.md`. Normal
  development does not update this directory in real time.
- Do not add a file per finding. Correct and compress first; add a file only when an
  existing structure cannot express a subsystem.
- Every SHA, path and claim added here must cite where it was verified.
- **Never run `git fetch --prune` / `git remote prune` / aggressive `git gc` in this
  clone.** `main` is the only remote branch; the other fork lines survive only locally or
  as tags. Use `git fetch --tags origin`; the `archive/*` tags are the remote-preserved
  copies. Re-audited 2026-10-12 — the reason narrowed, the rule did not.
- `KNOWLEDGE_STAGE1_REPORT.md` and `KNOWLEDGE_STAGE2_REINFORCEMENT_REPORT.md` describe how
  this base was built **against the old frozen line**. They are history, not current truth,
  and their "this baseline" statements are superseded.
