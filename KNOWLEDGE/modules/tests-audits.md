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
  `PASS 18 FAIL 0 UNKNOWN 1 …`, **exit 0**. A run without this flag did not compare
  upstream.
- **`--strict` promotes `UNKNOWN` to a failure.** Without it `UNKNOWN` folds into a pass;
  the script's own header says `UNKNOWN` "does not by itself fail the run".

**`--root` defaults to the script's own repo root.** In a worktree or a copy, omitting it
audits the wrong tree and says nothing about yours.

Baseline result at this review (2026-10-12): `PASS 19 FAIL 0 UNKNOWN 0 UNDECIDABLE 0`,
exit 0.

## The gate set, with status

| Gate | Establishes | Status at this baseline |
|---|---|---|
| `audit_apple_ui_boundary.py` (19 checks) | routing, isolation, upstream byte-parity, project membership, branding, subscription chain, hygiene | **green** (with `--upstream-ref` + `--strict`) |
| `audit_hako_lossless_parity.py` | designated UI tokens per page; 9 design-system files byte-for-byte | **green** — 6/6 pages, 9/9 bytes, 0 tokens lost |
| `check_hako_macos_parse.py --platform ios` | every ported file's platform conditions decided for iOS | **green** — `checked=54 errors=0 undecidable=0` |
| `check_hako_macos_parse.py --platform tvos` | the same for tvOS | **RED BY DECISION** — `swift_directives.PLATFORMS` has no `tvos` entry; 54 files `NOT CHECKED` |
| `report_hako_platform_api.py --check`, `gate_hako_platform_imports.py --check` | guard/use agreement | **RED BY DECISION** — 61 `undecidable on tvos`, same cause |
| `check_platform_structure.py`, `check_swift_structure.py`, `check_generated_headers.py`, `check_swift_test_sources.py` | structural / provenance / declaration checks | green |
| `dup_module_scope.py` | candidate duplicate module-scope names | **FALSE RED** — exits 1 with 18 findings that are all legal code |
| `check_commit_messages.py` | UTF-8 BOM in commit subjects | green |
| `test_fail_closed_exit_codes.py` | the gates fail closed | green — 3 passed |
| `test_platform_gates.py` | the platform gates' own behaviour | green — 0 failing of 19 cases |
| `test_audit_reverse_routing.py` | the audit catches reverse-routing and guard defects | green — 29 cases, all failed as designed |
| `guard_hako_platform_modifiers.py`, `gate_hako_platform_imports.py` **without** `--check` | — | **these WRITE the tree.** Never run them bare |

The two tvOS reds and the `dup_module_scope` false red are explained in
`modules/hako-ui.md`; do not "fix" any of them without changing the scope decision they
encode. `check-iphone-hako-freeze.sh` is **not** a live gate: it exists only at
`docs/pending/`, its upstream pin is absent from this clone, and it was retired on
purpose — see `modules/hako-ui.md`.

## What each gate cannot prove

| Gate | Cannot prove |
|---|---|
| the UI boundary audit | compilation, rendering, device behaviour |
| the parity audit | pixel parity **or structural equivalence** |
| the platform parse checks | a real compile for any platform |
| the negative suites | anything about the app |
| any of them | that live `main` has the same properties |

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

## Hazards when running the negative suites

`test_audit_apple_ui_boundary.py` and `test_fail_closed_exit_codes.py` **act on the real
repository's git index**: they copy the tree, and the copied `.git` *file* points at the
shared git directory, after which the harness runs `git reset` / `git checkout -- .`
against it. Do not run them in a dirty or read-only worktree.

Some scripts default to paths that do not exist on every host (`check_commit_messages.py`
and others fall back to a sibling checkout). Set `DSH_REPO` / `DSH_GIT`, or pass `--root`.

## Swift test packages

| Package | Compiles | Blind spot |
|---|---|---|
| `Tests/HakoScreenState` | a **symlink** to the shipping `ScreenStateObserver.swift` — the real policy file | the `#if os(iOS)` Darwin adapter is compiled by nothing, so the `notify` call sites are validated only by an iOS build; its own manifest says the only way to test that is on a device. **The policy class is 8 of 9 at this baseline** — see `modules/screen-state.md` |
| `Tests/HakoSubscriptionUsage` | 9 symlinked real sources + a GRDB stub + a Libbox stub | "persistence" there is the stub's; it was committed **unexecuted** |

All test sources are git symlinks (mode `120000`). Editing one edits the shipped file —
that is the intent — and `check_swift_test_sources.py` polices the declaration surface.
The symlinks are also why the packages cannot be built here: on a checkout without
symlink support they materialise as one-line text files.

## The UI suites are not evidence about the data path

`SFIUITests/HakoNavigationUITests.swift` (55 assertions / 18 tests) and
`HakoSnapshotUITests.swift` (46 / 28 / 35 `snapshot()` calls) launch the app with
`-FASTLANE_SNAPSHOT YES`. That flag is `Variant.screenshotMode`, read in 23 in-tree
files, and it **substitutes data**, not just window geometry — group counts, connection
state and profile availability are all forced. The suite itself explains why: without the
fixture the client has no profiles and the pages under test do not exist.

`SnapshotHelper.swift` additionally **throws on physical hardware**
(`cannotRunOnPhysicalDevice`), so the snapshot machinery is structurally simulator-only.
Four `SnapshotTests.swift` files contain zero assertions.

## Not gated at all

`UITests/*.swift` are a synchronised root group attached to **no** target — they compile
into nothing. The `Makefile` has no test target and `fastlane` has no test lane. There is
no CI in this repository.
