# The secondary-page migration safety contract

`scripts/dev/migrate_secondary_page.py` moves one page from the pinned upstream commit into
`ApplicationLibrary/Views/HakoStyle/` and redirects the phone's own call sites at the copy. This document
is the contract it now obeys, the reason each clause exists, and the exact conditions under which it
refuses. It is written to be read by whoever next wants to run the tool, and by whoever next wants to
change it.

The one-sentence version: **the tool plans by default, it refuses far more often than it proceeds, and no
file is ever left half-written.**

---

## 1. What went wrong, in one paragraph

The previous revision regenerated the target file from upstream and wrote it over whatever was on disk,
with exit status 0 and no comparison against what it was replacing. The rename map is derived from the
single source file being migrated, so any reference to a type that a *different* upstream file declares
came back under its upstream spelling. Three repaired report list files lost their
`Hako…ReportDetailView(report:)` call that way, and three report detail files lost
`HakoReportZipDocument` / `HakoReportFileContentView` / `HakoReportSharePopup` the same way — six files,
one `--write` each, all silent. The same write path also rewrote the tool's own provenance header through
the call-site pattern, so 30 of the 33 committed `HakoStyle/Hako*.swift` files currently state a source
path that does not exist at the pinned commit.

---

## 2. The CLI

```
python scripts/dev/migrate_secondary_page.py --list
python scripts/dev/migrate_secondary_page.py --page <path>              # plan, write nothing (default)
python scripts/dev/migrate_secondary_page.py --page <path> --check      # same, explicitly
python scripts/dev/migrate_secondary_page.py --page <path> --dry-run    # same, explicitly
python scripts/dev/migrate_secondary_page.py --page <path> --emit       # also print the candidate bytes
python scripts/dev/migrate_secondary_page.py --page <path> --json       # machine-readable plan
python scripts/dev/migrate_secondary_page.py --page <path> --write      # the only writing invocation
```

| flag | meaning |
| --- | --- |
| `--platform-gate shared` | **default.** Keeps every `#if`/`#elseif`/`#else`/`#endif` chain and refuses if any platform condition cannot be decided. Required for anything written into `ApplicationLibrary/`, which one Xcode synchronized source group compiles into the iOS, macOS and tvOS targets. |
| `--platform-gate resolved` | The older collapsing gate. Its behaviour is unchanged, byte for byte, and it is kept so the audits that consume it keep measuring what they measured. |
| `--fork-ref <ref>` | The pinned upstream commit. Defaults to `c1935cff…` (`origin/hako-ui`). An environment variable `DSH_FORK_REF` sets the same thing. |
| `--replace <path>` | Authorizes replacing **exactly one** existing target. Requires `--expect-sha256`. |
| `--expect-sha256 <hex>` | The blob `--replace` is authorized to replace. If the file on disk is not that blob the run refuses anyway. |

There is no `--force`, no `--force-all`, no `--yes` and no `--all`. `test_migrate_secondary_page.py`
asserts each of those is rejected as an unknown option, because "we documented that there is no override"
is not a check.

### Environment

| variable | meaning |
| --- | --- |
| `DSH_REPO` | The repository the pinned commit is read from (`git -C $DSH_REPO show <ref>:<path>`). Defaults to `<parent of the checkout>/sing-box-for-apple`. |
| `DSH_GIT` | The `git` executable. Defaults to `git` on `PATH`. |
| `DSH_FORK_REF` | Default for `--fork-ref`. |
| `DSH_SAFETY_FAULT_AT` | Test-only. Makes the *n*-th swap of a commit fail, so the rollback path can be aimed at an exact step. It can only ever prevent a write and force a rollback; it never permits one, and a run that uses it always ends non-zero. |

### Exit codes

| code | meaning |
| --- | --- |
| `0` | The plan is clean, or the write committed and a second run reports no changes. |
| `1` | **Refused.** Every reason is printed; nothing at all was written. |
| `2` | Environment or usage error: the pinned ref does not resolve, the page does not exist at that commit, `git` is unusable, or the flags contradict each other. |

---

## 3. The refusal conditions

Each has a stable code, printed with the refusal, and each is exercised by a case in
`test_migrate_secondary_page.py`.

| code | when | why it is a refusal and not a warning |
| --- | --- | --- |
| `REF_UNRESOLVED` / source absent | The pinned commit does not resolve in `DSH_REPO`, or `git show <ref>:<path>` fails. | No candidate text can be produced and no provenance can be stated. Exit 2. |
| `UNDECIDABLE_CONDITION` | Any `#if`/`#elseif` condition in the source that `swift_directives.evaluate` cannot decide, including conditions nested inside a branch the platform excludes. | Guessing picks a branch; deleting the directive changes which platforms compile the body. |
| `RENAME_MAP_EMPTY` | The page declares no module-scope type. | The run would write a file with nothing renamed in it, or report success while doing nothing. |
| `RENAME_UNMATCHED` | A name in the rename map matched nowhere in the gated text. | The map no longer describes the file. |
| `NESTED_NAME_COLLISION` | A nested type in the file has the same name as a module-scope one. | The whole-word rename cannot tell the two apart, and renaming both is not correct. |
| `STRUCTURE` | Braces, parens or `#if` directives do not balance in the candidate; a nested declaration never closes; an alias marker did not survive. | The output would not parse. |
| `DOUBLE_PREFIX` | The candidate contains a `HakoHako…` identifier. | A rename was applied to text that had already been renamed. |
| `HAKO_SYMBOL_LOSS` | Writing a file would remove a `Hako…` identifier from it. | **This is the reverse regression, as an invariant.** A repaired call to an already-migrated type is about to be turned back into the upstream spelling. |
| `PORTED_UNWIRED` | No Hako-owned or phone-owned file names any of the page's `Hako` types **in code**. | The copy would exist and be unreachable. A mention inside a doc comment does not count; the previous revision accepted one. |
| `SHARED_TYPE_SPLIT` | The run would rewrite a phone-owned file to call `Hako<Name>` while `<Name>` is still named in code by a shared file the iPad and macOS roots load. | The copy is a different type. `SFI/HakoPhoneRootView.swift:47` is the worked example: `@State private var selection: NavigationPage` is initialised from a closure that does `let page = NavigationPage(snapshotValue:)` and `return page`, so pointing the constructor at `HakoNavigationPage` leaves a `HakoNavigationPage` being returned where a `NavigationPage` is required. Without a compiler, refusing is the only honest answer. |
| `REVERSE_DEPENDENCY` | The write set contains anything outside `ApplicationLibrary/Views/HakoStyle/*.swift` and the two phone-owned files. | Moving a shared page onto a Hako type is the boundary violation the audit exists to prevent. |
| `NOT_IDEMPOTENT` | A second pass over the text this run would leave behind changes something. | Idempotence is a property of the output, so it is checked before the output exists. |
| `TARGET_DIFFERS` | The target exists and differs from the freshly generated candidate. | See below. |
| `REPLACE_UNAUTHORIZED` | `--replace` names another path, `--expect-sha256` is missing, or it does not match the blob on disk. | One authorization covers one path and one blob. |
| staging / commit / verification failure | Any I/O error, including a read-only target. | See §5. |

### `TARGET_DIFFERS` in full

An existing target that differs from the candidate is the most dangerous thing the tool can meet: the file
on disk is the product of every earlier run *and* of every human repair, and the candidate is a fresh
function of upstream. The refusal prints the target path, the SHA-256 on disk, the candidate's SHA-256, the
unified diff, and the exact command that would authorize the replacement:

```
TARGET_DIFFERS: ApplicationLibrary/Views/HakoStyle/HakoCrashReportListView.swift already exists and differs
from the freshly generated candidate (on disk de5438c9…, candidate 60ffb332…). Nothing was written.
Overwriting it would discard every repair made to that file since it was generated. To proceed
deliberately: --write --replace ApplicationLibrary/Views/HakoStyle/HakoCrashReportListView.swift
--expect-sha256 de5438c9…
```

Even with that command the run refuses if the blob on disk changed in the meantime, and every *other*
refusal in §3 still applies — `--replace` authorizes an overwrite, it does not waive the invariants. In the
current tree the three report list pages and the three report detail pages refuse under `HAKO_SYMBOL_LOSS`
with or without an authorization.

---

## 4. Validation order: nothing is written until everything has been decided

The plan is built entirely in memory and is a pure function of the pinned upstream text plus the tree:

1. Resolve the pinned ref; read the original with `git show <ref>:<path>`.
2. Gate the platform conditionals (`shared` by default; a refusal if any condition is undecidable).
3. Derive the rename map from the module-scope declarations (brace depth 0, non-`private`).
4. Replace nested declarations the shared tree spells `Enclosing.Nested` with `public typealias`.
5. Rename every module-scope name; require every rename to have matched.
6. Rename module-scope extension members that would duplicate a shared declaration.
7. Build the candidate, then check: braces, parens, `#if` balance, no `HakoHako`, no nested-name collision.
8. Compute the target state: `CREATE`, `UNCHANGED` or `DIFFER`.
9. Work out, in memory, every phone-owned and Hako-owned file `retarget` would rewrite, and require the
   page to be reachable from code.
10. Check `HAKO_SYMBOL_LOSS` over every file the run would rewrite.
11. Check that a second pass over the resulting text is a no-op.
12. Check that the write set is inside the two allowed directories.
13. Only then: stage every byte to a temporary file, swap, verify, and roll back on any failure.

A refusal at step 2 returns immediately; a refusal at any later step still returns before a single byte is
staged.

---

## 5. Atomicity

`_safety_gate.StagedWrites` is the only write path.

1. Read the pre-image of every target into memory.
2. Write every new byte to a `.dsh-stage-*.tmp` file in the target's own directory, `fsync`ed. A failure
   here leaves every target untouched, and every temp file is removed.
3. `os.replace` each temp onto its target. If one fails, the ones already swapped are restored from their
   pre-images, created files are deleted, and the remaining temp files are removed.
4. Verify every target's SHA-256 against the staged bytes. A mismatch triggers the same rollback.

A `PORTED_UNWIRED` outcome cannot leave a created file behind, because reachability is decided at step 9 —
before anything is staged. The previous revision wrote the destination first and reported
`PORTED_UNWIRED` afterwards, so a run that reported failure had already rewritten 259 lines of
`HakoStyle/HakoGroupView.swift`.

`test_migrate_secondary_page.py` exercises three fault modes over a seven-file plan: an injected fault at
step 4, an injected fault at step 1, and a real read-only target at the last step in commit order. In all
three, every file under `ApplicationLibrary/` and `SFI/` must be byte-identical to before the run,
including the absence of the file the run would have created.

---

## 6. Name scoping

* Only types declared at **brace depth 0** are renamed. Indentation is not nesting: `TaildropView.swift`
  wraps its whole body in `#if !os(tvOS)`, so its declaration is indented and still module scope, and it is
  renamed. `NewProfileView.ImportRequest` is genuinely nested, cannot collide with a module-scope name, and
  is not renamed.
* A nested type the variant **does** need to name is not renamed and not re-declared. When the shared tree
  spells `Enclosing.Nested` — read out of the tree, not assumed — the nested declaration is replaced by
  `public typealias Nested = Enclosing.Nested` inside the renamed copy, so the copy's own callers and the
  shared signature name one type. `NewProfileViewModel.init` is
  `init(importRequest: NewProfileView.ImportRequest? = nil, localImportRequest: NewProfileView.LocalImportRequest? = nil)`,
  and `HakoNewProfileView` must therefore carry
  `public typealias ImportRequest = NewProfileView.ImportRequest`.
  The previous revision renamed the nested types outright and then emitted
  `public typealias ImportRequest = HakoImportRequest` — an alias wearing a name nobody spells, so
  `HakoNewProfileMenuView`, which spells `HakoNewProfileView.ImportRequest`, still had no such member.
* A mention is only ever rewritten in **code**. Comments and string literals are masked first
  (`_safety_gate.mask_noncode`), which is what stops the tool rewriting its own provenance header and what
  stops a doc comment from counting as a call site.

---

## 7. No reverse dependency

`retarget` may rewrite only `ApplicationLibrary/Views/HakoStyle/*.swift` and
`SFI/HakoPhoneRootView.swift` / `SFI/HakoPageContent.swift`. A type named in code by a shared file is
reported as `BLOCKED_SHARED_CALLSITE` with `file:line` and left alone.

**Deliberate interpretation, stated so it can be argued with.** A shared mention is a *report*, not a
refusal, exactly as the tool's original contract said ("a mention in a shared file stays
`BLOCKED_SHARED_CALLSITE`"). Almost every page has one — `ToolsView.swift` names every report list type —
and refusing on all of them would stop the tool reporting on most of the tree. What *is* a refusal is the
narrower, evidence-backed case where the run would move a phone-owned file onto the Hako twin of a type a
shared file still names, because that is a type split with a demonstrated failure mode
(`SHARED_TYPE_SPLIT`, §3).

---

## 8. Platform conditions

`ApplicationLibrary` is one Xcode synchronized source group feeding the iOS, macOS **and** tvOS targets, so
every file under `HakoStyle/` is compiled for all three. A guard the original had is a guard the copy
needs.

* `preserve(text, platform)` — the shared gate. Deletes nothing, keeps the whole conditional chain, and
  requires every condition to be decidable.
* `resolve(text, platform)` — the legacy gate. Unchanged, byte for byte, and verified so: over all 176
  Swift files in the pinned upstream tree, `resolve()` produces byte-identical output before and after this
  work for both `ios` and `macos` (352/352 comparisons identical).
* `PLATFORMS` is the registry of platforms the evaluator will decide anything for. A platform absent from
  it is refused **before the condition is even parsed**, including for a bare `os(...)` comparison —
  `os(tvOS)` compares a name against the argument, so with `platform="tvos"` it used to answer `True`
  without anyone having established a single fact about tvOS.
* **`tvos` is deliberately not in `PLATFORMS`.** The repository does build `ApplicationLibrary` for tvOS
  (`SFT`, `TVExtension`; `HakoConnectionListView.swift:30` hand-writes `#if canImport(UIKit) && !os(tvOS)`),
  so a tvOS table is genuinely wanted — and it cannot be written from evidence available here.
  `os(tvOS)` branches are everywhere; a `canImport` answer for tvOS is nowhere. `canImport(Charts)`,
  `canImport(ActivityKit)`, `canImport(StoreKit)` and the rest are facts about the tvOS SDK, not about
  `sing-box.xcodeproj`, and there is no tvOS build in this environment to establish them from. Inventing
  `True` keeps a block that will not compile; inventing `False` silently deletes UI. Both are worse than
  refusing. `TARGET_ENVIRONMENT` has the same gap for tvOS.

---

## 9. What this tool deliberately does not do

* It does not type-check, and it does not claim to. `SHARED_TYPE_SPLIT` is the boundary of what it can
  decide statically; past that it refuses.
* It does not fix the tree. Thirty committed `HakoStyle/Hako*.swift` headers still name a source path that
  does not exist at the pin, and `HakoFontPickerView.swift` still carries the collapsed platform structure
  the legacy gate produced. Both are *reported* by the plan and neither is rewritten, because rewriting
  thirty files is a decision for a human with the diff in front of them.
* It does not migrate a page by itself. Every `--write` on an existing target refuses; the tool's value is
  the plan and the invariants, and the deliberate replacement path exists for the day someone wants it.
* It does not delete anything. `stage_delete` exists in `_safety_gate` for callers that need it; this tool
  never stages a deletion.

---

## 10. Running the tests

```
python scripts/dev/test_migrate_secondary_page.py
```

Twelve cases, each against a temporary copy of the checkout that is removed afterwards. The suite asserts
at the end of every case that the checkout it copied from is byte-identical, because a suite that grades a
tree must not be able to write to it.

`DSH_MIGRATE_TOOL_DIR=<dir>` swaps the tool under test for a snapshot of another revision, which is how
the before/after exit codes were recorded: `1` (0 passed, 12 failed) against the revision at `e1cefe6`,
`0` (12 passed, 0 failed) against this one.
