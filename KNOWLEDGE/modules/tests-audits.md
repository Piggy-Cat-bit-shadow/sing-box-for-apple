# Tests, gates and what they actually prove

## The one command that matters

```bash
python scripts/dev/audit_apple_ui_boundary.py \
  --root <worktree> \
  --upstream-ref 089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85 \
  --strict
```

### Two flags are load-bearing

- **`--upstream-ref` is optional and defaults to none.** Without it the
  `upstream-files-untouched` check reports `UNKNOWN` and the summary still reads
  `PASS n FAIL 0 UNKNOWN 1 …`, **exit 0**. A run without this flag did not compare
  upstream.
- **`--strict` promotes `UNKNOWN` to a failure.** Without it `UNKNOWN` folds into a pass;
  the script's own header says `UNKNOWN` "does not by itself fail the run".

**`--root` defaults to the script's own repo root.** In a worktree or a copy, omitting it
audits the wrong tree and says nothing about yours.

Result at this refresh (2026-10-12, tree at `331a676`): **`PASS 20 FAIL 0 UNKNOWN 0
UNDECIDABLE 0`**, exit 0. The check count was **19** at the previous baseline; one check has
been added since. Read the count from the run, not from this file.

The 20 checks, in the order the tool prints them: `phone-entry`, `tablet-and-mac-entry`,
`shared-pages-are-clean`, `no-reverse-dependency`, `reverse-routing-contract`,
`reverse-routing-derived`, `shared-declaration-duplicates`, `hako-symbol-completeness`,
`hako-platform-imports`, `platform-guard-agreement`, `hako-page-coverage`,
`hako-feature-preservation`, `hako-type-has-caller`, `form-pages-are-not-embedded`,
`ipad-mac-ui-gate`, `upstream-files-untouched`, `project-membership`, `branding`,
`subscription-feature`, `repository-hygiene`.

## The gate set, with status re-measured at this refresh

| Gate | Establishes | Status at this baseline |
|---|---|---|
| `audit_apple_ui_boundary.py` (20 checks) | routing, isolation, upstream byte-parity, project membership, branding, subscription chain, hygiene | **green** — `PASS 20` with `--upstream-ref` + `--strict` |
| `audit_hako_lossless_parity.py` | designated UI tokens per page; 9 design-system files byte-for-byte | **RED** — `coverage: 4 of 6 page(s)`, `lost UI tokens: 2`, verdict `PARTIAL`, exit 1. **Read the explanation below before treating this as a UI regression** |
| `check_hako_macos_parse.py --platform ios` | every ported file's platform conditions decided for iOS | **green** — `checked=54 errors=0 undecidable=0` |
| `check_hako_macos_parse.py --platform tvos` | the same for tvOS | **RED BY DECISION** — `swift_directives.PLATFORMS` has no `tvos` entry; 54 files `NOT CHECKED` |
| `report_hako_platform_api.py --check`, `gate_hako_platform_imports.py --check` | guard/use agreement | **RED BY DECISION** — **62** `undecidable on tvos` (was 61), same cause |
| `check_platform_structure.py` | every ported file still carries the platform structure its original had | green |
| `check_swift_structure.py <dir>` | delimiter/`#if` balance in code, not in strings or comments | green on `ApplicationLibrary/Views/HakoStyle` (takes a **positional** path, not `--root`) |
| `check_generated_headers.py` | every generated header names a path that exists at the pin | green — 33 portable headers, 0 naming a missing path |
| `check_localization.py` | the fork's own UI strings resolve to a catalog key with en + zh-Hans | **FALSE GREEN ON WINDOWS** — reports `PASS` over **0 files**. See below |
| `check_swift_test_sources.py` | the declaration surface of the test packages | **RED** — 5 findings, all heuristic false positives. See below |
| `dup_module_scope.py` | candidate duplicate module-scope names | **green now** — exits 0, `module-scope names declared in the shared tree: 0`. The previous baseline recorded this as a 18-finding false red; whatever produced those is gone |
| `check_commit_messages.py` | UTF-8 BOM in commit subjects | **exit 0 having scanned 0 commits** — see below |
| `test_fail_closed_exit_codes.py` | the gates fail closed | green — 3 passed |
| `test_platform_gates.py` | the platform gates' own behaviour | green — 0 failing of 19 cases |
| `test_audit_reverse_routing.py` | the audit catches reverse-routing and guard defects | green — 29 cases, all failed as designed |
| `guard_hako_platform_modifiers.py`, `gate_hako_platform_imports.py` **without** `--check` | — | **these WRITE the tree.** Never run them bare |

### AI caution: a gate that scanned nothing reports PASS

Three of the gates above are environment-sensitive in a way that produces a **green result
with no coverage**, which is worse than a red one because it reads as evidence.

- **`check_localization.py`** resolves its root from `__file__` and then filters by
  `path.startswith("ApplicationLibrary/Views/HakoStyle/")` / `"SFI/Hako"`. On Windows
  `os.path.relpath` returns **backslashes**, so neither prefix matches, `repo_paths()` returns
  an empty list, and the tool prints
  `PASS: 0 visible string(s) across 0 fork-owned file(s)` with exit 0. Measured directly:
  **0 of 56** fork-owned files are scanned on Windows; on a POSIX host the same tree yields
  **56** (54 `HakoStyle/*.swift` + 2 `SFI/Hako*.swift`). The gate is *correct* on macOS/Linux
  and *vacuous* on Windows. **Read its file count, not its exit status.**
- **`check_commit_messages.py`** prints `commits in --root:` (empty) and then
  "no subject begins with a UTF-8 BOM", exit 0. It found no commits to inspect, so it proves
  nothing here. Whether it works in a normal checkout is `EXTERNAL_CHECK_REQUIRED`.
- **`check_swift_test_sources.py`** matches every capitalised identifier against declarations
  found in the repository, so it reports `DispatchSemaphore` and `Thread` (stdlib) and
  `FAKE_BLIND_*` (fixture constants) as "declared nowhere in this repository". The 5 findings
  are **heuristic false positives**, not defects. It also cannot see the symlinked policy
  source, which it correctly labels a "symlink placeholder (not Swift source)".

Do not "fix" any of these by editing the gates' inputs, and do not delete the exemption
mechanisms. Record them as evidence boundaries.

### The parity audit's red is a token-set artifact, not a lost UI

`audit_hako_lossless_parity.py` exits 1 at this baseline with 2 "lost" localized strings:
`'Remote control'` (Home) and `'Out of Memory Report'` (Tools). Both were **renamed to
upstream's spelling on purpose** by `467f8ea`:

```text
HakoHomeView:           "Remote control"       -> "Remote Control"      (upstream key, has zh-Hans 远程控制)
HakoOOMReportListView:  "Out of Memory Report" -> "OOM Report"          (upstream key, 内存不足报告)
```

The defect being fixed was that `String(localized:)` **answers a miss by returning the key**,
so a near-miss variant compiles, runs, and renders English in every locale — the zh-Hans
interface was half English. Verified present at this baseline:
`HakoStyle/HakoHomeView.swift` now calls `String(localized: "Remote Control")`.

The audit compares literal substrings as an **unordered set** per page and knows nothing about
a key rename, so an intentional rename is indistinguishable from a removal to it. This is the
audit's documented limitation working as designed, not a regression. It also flags
`HakoData.swift` (952 lines vs the original's 920) and `HakoRow.swift` (874 vs 855) in the
byte comparison of 9 design-system files, and compares `HakoPrimaryShell.swift` by tokens with
a recorded reason.

**Do not "restore" the old strings to make this gate green.** That would re-break localization.

### The parity audit compares token **sets**

`audit_hako_lossless_parity.py` captures regex-matched literal substrings and compares
them as **unordered sets** per page, plus a byte `!=` over 9 design-system files. Guards,
modifier order, removed hooks, spacing and broken call sites are all token-set-invariant.

The repository proved this on itself: with every `#if !os(tvOS)` guard deleted and
several types respelled back to upstream, the parity audit exits **0** with
`STATIC_LOSSLESS_PORT_READY_FOR_APPLE_ACCEPTANCE, lost_tokens=0, 6/6, 9/9`, while the
boundary audit exits **1 with four FAILs** on the same bytes.

`HAKO-LOSSLESS-PARITY-AUDIT.md` says "10/10 byte-identical"; the tool compares **9**
byte-for-byte and one file by tokens (byte equality there *is* the compile error). The
tool's own output, `HAKO-ROUND8-FINAL-DEBUG.md` and `HAKO-ROUND8-REMAINING-FAILURES.md`
all say 9 + 1.

## What each gate cannot prove

| Gate | Cannot prove |
|---|---|
| the UI boundary audit | compilation, rendering, device behaviour |
| the parity audit | pixel parity **or structural equivalence**; it also cannot tell a key rename from a string removal |
| the platform parse checks | a real compile for any platform |
| the negative suites | anything about the app |
| any of them | that a *future* revision keeps the same properties |

## Hazards when running the negative suites

`test_audit_apple_ui_boundary.py` and `test_fail_closed_exit_codes.py` **act on the real
repository's git index**: they copy the tree, and the copied `.git` *file* points at the
shared git directory, after which the harness runs `git reset` / `git checkout -- .`
against it. Do not run them in a dirty or read-only worktree.

Some scripts default to paths that do not exist on every host (`check_commit_messages.py`
and others fall back to a sibling checkout). Set `DSH_REPO` / `DSH_GIT`, or pass `--root`
where the script accepts it — note that `check_localization.py`, `check_platform_structure.py`
and `check_swift_structure.py` do **not** accept `--root`.

## Swift test packages — three, not two

| Package | Sources | Blind spot |
|---|---|---|
| `Tests/HakoScreenState` | `Sources/Policy/ScreenStateObserver.swift` is a **symlink** to the shipping policy file | the `#if os(iOS)` Darwin adapter is compiled by nothing, so the `notify` call sites are validated only by an iOS build. `37798ea` made the suite buildable; `c58b1f7` closed the fake's blind spots; `ee428f7` reports 33 of 33 |
| `Tests/HakoInterfaceStartup` | `Sources/Policy/InterfaceMonitorStartup.swift` is a **symlink** to the shipping file | **new since the previous baseline.** Covers the decisions the interface monitor's callback feeds, not `NWPathMonitor` itself — a substitute would test the substitute |
| `Tests/HakoSubscriptionUsage` | 9 symlinked real sources + a GRDB stub + a Libbox stub + profile stubs | "persistence" there is the stub's; it was committed **unexecuted** |

All 11 test-package source files that should be symlinks are git symlinks (mode `120000`).
Editing one edits the shipped file — that is the intent — and `check_swift_test_sources.py`
polices the declaration surface. The symlinks are also why the packages cannot be built here:
on a checkout without symlink support they materialise as one-line text files.

## The UI suites are not evidence about the data path

`SFIUITests/HakoNavigationUITests.swift` (55 assertions / 18 tests) and
`HakoSnapshotUITests.swift` (46 assertions / 28 tests / 36 `snapshot()` calls) launch the app
with `-FASTLANE_SNAPSHOT YES`. That flag is `Variant.screenshotMode`, read in 23 in-tree
files, and it **substitutes data**, not just window geometry — group counts, connection
state and profile availability are all forced. The suite itself explains why: without the
fixture the client has no profiles and the pages under test do not exist.

`d331977`, `26ff51a`, `d6f5d99`, `492f61d` and `543da17` gave the fixture **per-case states**
and reached 28 of 28, which makes the suite more meaningful than it was — the fixture is now a
named state per case rather than one global substitution. It is still a fixture, and
`SnapshotHelper.swift` additionally **throws on physical hardware**
(`cannotRunOnPhysicalDevice`), so the snapshot machinery is structurally simulator-only.
Four `SnapshotTests.swift` files contain zero assertions.

## Not gated at all

`UITests/*.swift` are a synchronised root group attached to **no** target — verified at this
baseline by locating `3A63135E2F0CEF190060A550` in `project.pbxproj`: it appears as a
`PBXFileSystemSynchronizedRootGroup` definition and as a child of the **root navigator group**,
never inside a target's `fileSystemSynchronizedGroups`. They compile into nothing. The
`Makefile` has no test target and `fastlane` has no test lane. There is no CI in this
repository at all — no `.github/` directory exists.
