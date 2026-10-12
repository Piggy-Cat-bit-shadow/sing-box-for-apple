# Commit index (navigation, not a replacement for diffs)

The current Production Baseline is `5cab4ec` on `main`. The absorbed delta was **69 commits**
(`f4a9859..main`; 33 docs, 20 fix, 13 test, 1 chore, 2 merges). **Only the commits that explain
surviving behaviour are indexed here** — routine docs commits are excluded on purpose
(`REFRESH.md` §35).

Inspect diffs and final source before reusing a conclusion.

## Lifecycle and concurrency

| Commit | Area | Classification / provenance |
|---|---|---|
| `f4a9859` | command-server teardown identity check + reload/monitor race | FIX, NETWORK-EXTENSION, LIFECYCLE, FORK-OWNED — *the previous Production Baseline* |
| `8d06a99` | serialise the service lifecycle; make a failed start **unwind** | FIX, NETWORK-EXTENSION, LIFECYCLE, FORK-OWNED |
| `f8f978c` | absorb the hardening line's runtime fixes into the canonical tree | FIX, LIFECYCLE, FORK-OWNED |

## Screen state

| Commit | Area | Classification / provenance |
|---|---|---|
| `f77289f` | a failed notification read is `unknown`, not an unlock | FIX, SCREEN-STATE — UPSTREAM-ABSORBED context |
| `891c6cb` | **rule 5** — an unlock needs an observed lock | FIX, SCREEN-STATE, FORK-OWNED |
| `987134b` | **rule 6 / the P1-C fix** — deliver a current-state read as a LEVEL, never a sleep edge | FIX, SCREEN-STATE, FORK-OWNED |
| `c58b1f7` | close the test fake's blind spots; make an assertion match its name | TEST, SCREEN-STATE |
| `37798ea` | the screen-state suite can be built, so its cases actually run | TEST, SCREEN-STATE |
| `ee428f7` | the observer suite is 33 of 33 | TEST, SCREEN-STATE |

## Networking and interface startup

| Commit | Area | Classification / provenance |
|---|---|---|
| `15d3a72` | **bound the first interface-path wait** — airplane mode cannot hang startup | FIX, NETWORK, LIFECYCLE, FORK-OWNED |
| `628644d` | give the bound an off-device test seam (`InterfaceMonitorStartup`) | TEST, NETWORK |

## Platform ownership, Hako UI and the migration

| Commit | Area | Classification / provenance |
|---|---|---|
| `0297c8e` | device routing; `SFI/MainView.swift` kept byte-identical to upstream | FEATURE, UI, FORK-OWNED |
| `2f0024c` | a shared file must not name the phone page — the audit was right | FIX, AUDIT, PLATFORM-OWNERSHIP |
| `9adb1f8` | the boxed libbox accessors the integrated revision dropped | FIX, Hako, CORE-COORDINATED |
| `f03efe6` | the generated phone pages against the APIs this tree actually has | FIX, Hako, DESIGN-PRESERVATION |
| `631c4fc`, `5855501` | platform branches/conditions the migration resolved away | FIX, Hako, HARDENING |
| `7b7d638` | port the profile picker's macOS body; unguard the row the Mac shares | FIX, Hako |
| `49a9275` | the page's "could not read the configuration" line can be reached at all | FIX, Hako |
| `6240a74` | **route Hako profile imports outside the modal form** | FIX, UI, IMPORT, FORK-OWNED |
| `747a5d8` | guard the form-page presentation rule | TEST, UI |

## Localization

| Commit | Area | Classification / provenance |
|---|---|---|
| `8fe8e79` | the four count strings the phone asks for but the catalog lacked | FIX, LOCALIZATION, FORK-OWNED |
| `467f8ea` | **reuse upstream localization for Hako UI**; adds `check_localization.py` | FIX, LOCALIZATION, FORK-OWNED — 112 failures → 240 resolving |

## UI and appearance

| Commit | Area | Classification / provenance |
|---|---|---|
| `d052491` | require iOS 16 for toolbar placement | FIX, UI, BUILD |
| `48b5030` | align report count badges as trailing accessories | FIX, UI |
| `5cab4ec` | align network tool text colors | FIX, UI — *the current Production Baseline* |

## Tests and audits

| Commit | Area | Classification / provenance |
|---|---|---|
| `6a1d175` | the boundary check was red and its **default run said green** | FIX, AUDIT — the reason `--strict` + `--upstream-ref` are load-bearing |
| `ff24e4b` | register the five report-fixture files with reasons | CHORE, AUDIT |
| `5794092` | close the two long-standing red UI checks | TEST, UI |
| `3220019`, `a8ac1ea`, `d331977`, `26ff51a`, `d6f5d99`, `492f61d`, `543da17` | snapshot fixture: per-case states, one source for the groups, 28 of 28 | TEST, UI |

## Repository hygiene

| Commit | Area | Classification / provenance |
|---|---|---|
| `39e30a4` | make `main` the canonical product branch | DOC, REPOSITORY-HYGIENE |
| `5ada085`, `90a0e9a` | the two merges that folded the knowledge line and the P1-C closure line into `main` | merge commits; read meaningful children and the conflict result |
| `9a631c8` | the shell scripts are executable, which their runners assume | FIX, BUILD, REPOSITORY-HYGIENE |
| `3a550d0` | (tag `archive/pre-consolidation-2026-10-11`) the previous integration line | ARCHIVE-ONLY |

## Reading the provenance column

`UPSTREAM-INHERITED` means retained official implementation, not unexamined. `UPSTREAM-ABSORBED`
must name evidence in the affected module. `FORK-OWNED` means this fork's own change. No
patch-equivalence claim is made here without comparison — the `dev` audit in
`modules/repository-history.md` is the worked example of how one is established.
