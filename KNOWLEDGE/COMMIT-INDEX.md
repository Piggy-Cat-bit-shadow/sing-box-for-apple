# Commit index (navigation, not a replacement for diffs)

The baseline is 86 commits ahead of `upstream/dev@089d35e` by ancestry. Inspect diffs and final source before reusing a conclusion.

| Commit / range | Area | Classification / provenance |
|---|---|---|
| `f2064a8`, `90cc579`, documentation series | baseline and ownership | DOC, REPOSITORY-HYGIENE, FORK-OWNED |
| `c13e852` through Hako migration/fix series | Hako phone UI | UI, DESIGN-PRESERVATION, FORK-OWNED / DESIGN-BASELINE-DERIVED |
| `0297c8e`, `a4752b5`…`e8e197a` | device routing and six primary pages | FEATURE, UI, FORK-OWNED |
| `f77289f`, `996c8b7`, screen-state tests | lock/sleep semantics | FIX, LIFECYCLE, FORK-OWNED / UPSTREAM-ABSORBED context |
| `2608bd5`, `8cc4005` | subscription usage | FEATURE, SUBSCRIPTION, TEST, FORK-OWNED |
| `7271382`, `61b4c44`, audit/generator series | boundary and migration gates | AUDIT, TEST, HARDENING, FORK-OWNED |
| `a4af88f`, `66b273a`, `fc15efd` | round-8 merge consolidation | merge commits; read meaningful children and conflict result |
| `f4a9859` | command-server teardown/reload race | FIX, NETWORK-EXTENSION, LIFECYCLE, FORK-OWNED |

`UPSTREAM-INHERITED` means retained official implementation, not unexamined. `UPSTREAM-ABSORBED` must name evidence in the affected module; no patch-equivalence claim is made here without comparison.
