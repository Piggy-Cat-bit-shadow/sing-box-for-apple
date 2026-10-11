# Old worktree audit

Evidence gathered before any worktree was removed, for the two Apple worktrees that carried
uncommitted changes. An archive tag protects **committed** history; it protects nothing that was
never committed, so every dirty file had to be accounted for individually rather than assumed
redundant.

Audited against `main` = `bb5309b4a6c5b06382e1277a6e7ac0fbeadc9a72`.

`git worktree list` before the audit:

```text
/Users/jie/Desktop/其他文件/sing-box/.git/modules/clients/apple   bb5309b (detached HEAD)   submodule checkout, not a worktree of its own
/Users/jie/Desktop/其他文件/sing-box-apple-consolidation          bb5309b [main]            clean
/Users/jie/Desktop/其他文件/sing-box-apple-hakoui                 d5b2c31 [hako-ui]         DIRTY (staged)
/Users/jie/Desktop/其他文件/sing-box-apple-tail-cleanup           bb5309b [jiejiebox/apple-tail-cleanup]  clean - this round's worktree
/Users/jie/Desktop/其他文件/sing-box-apple-worktree               5911580 [libbox-stringbox-result-frame] DIRTY (unstaged)
```

## Summary

| Worktree | Branch | HEAD | Dirty files | Staged | Untracked | Classifications | Safe to remove |
|---|---|---|---|---:|---:|---|---|
| `sing-box-apple-hakoui` | `hako-ui` | `d5b2c31e7` | 4 | yes | none | A ×3, B ×1 | **YES** |
| `sing-box-apple-worktree` | `libbox-stringbox-result-frame` | `5911580a6` | 5 | no | none | A ×5 | **YES** |

No `D. UNIQUE_AND_STILL_NEEDED` was found in either worktree, so no port was required and no
`fix(apple): preserve the last uncommitted client fix` commit exists.

---

## Worktree B — `sing-box-apple-worktree`

Branch `libbox-stringbox-result-frame` @ `5911580a6366da78e6b4b5b4459596e5a2cf1eb4`.
Five modified files, **nothing staged**, **no untracked files**. The diff is 16 insertions and 16
deletions in total — a pure type adaptation.

### What the change is

Every hunk rewrites a libbox `StringBox` accessor to read through its `.value`. This is the
StringBox ABI migration: libbox's exported methods used to return a bare `string`, which gomobile
writes into the packed `_cgo_argtype` frame and which makes the Go runtime throw
`fatal error: bulkBarrierPreWrite: unaligned arguments`. The old form does not compile against a
regenerated binding, and where it does compile it is an old-ABI call.

### Per-file classification

| File | Hunks | Classification | Main evidence |
|---|---:|---|---|
| `Library/Network/ExtensionPlatformInterface.swift` | 8 | **A. ALREADY_IN_MAIN** | `main` reads `.value` at all 8 sites; line numbers identical (63, 64, 75, 93, 119, 130, 148, 175) |
| `ApplicationLibrary/Views/Abstract/GlobalChecksModifier.swift` | 3 | **A. ALREADY_IN_MAIN** | `main` has 3 `.value` lines; zero `.value` lines differ between `main` and the worktree |
| `HelperService/RootHelperService.swift` | 2 | **A. ALREADY_IN_MAIN** | `main` has 2; zero differ |
| `JailbreakDaemon/IOSRootHelperService.swift` | 2 | **A. ALREADY_IN_MAIN** | `main` has 2; zero differ |
| `Library/Network/BridgeTunTracker.swift` | 1 | **A. ALREADY_IN_MAIN** | `main` blob is **byte-identical** to the worktree's dirty file |

### How "already in main" was established

Not by reading the diff and forming an opinion. For each file, `main`'s blob was extracted and
diffed against the worktree's working-tree file, filtering to lines mentioning `.value`:

```bash
git show "main:$f" > /tmp/m.swift
diff /tmp/m.swift "<worktree>/$f" | grep -E '^[<>].*\.value'
```

That filter returned **no lines** for the four files where the counts are equal, i.e. the
unboxing is textually present in `main`, not merely equivalent.

For `ExtensionPlatformInterface.swift` the counts differ — `main` has 11 `.value` lines, the
worktree 10 — and the difference runs in **main's favour**:

```diff
<                 nameBox.value = tunName
```

`nameBox` is the `BridgeServiceSession` implementer that re-declares `name()` with the boxed
result. The worktree is *missing* it; `main` has it. A bound Go interface is implemented on the
platform side too, and that implementation is a declaration, so it is not something the call-site
sweep can see — the ABI gate scans for it separately as layer 4b. The worktree therefore holds a
strictly older state of this file.

### Untracked files

`git ls-files --others --exclude-standard` returned nothing. No untracked content existed to
preserve or classify.

---

## Worktree A — `sing-box-apple-hakoui`

Branch `hako-ui` @ `d5b2c31e79b83f15995bac5040ddef195a5ed98c`.
Four files, all **staged** (nothing unstaged), **no untracked files**. The staged diff is
30 insertions against 225 deletions.

`hako-ui` is a **retired** branch: it was deleted from the remote during the consolidation round
and its content preserved as `archive/hako-design-v1` (`c1935cff7`). The worktree still holds the
local branch, which is why it still shows a tree.

### Per-file classification

| File | Change | Classification | Main evidence |
|---|---|---|---|
| `README.md` | −99 / +2, reverts the JiejieBox README to bare upstream | **A. ALREADY_IN_MAIN** (main is strictly better) | Staged blob `eaae019ab` is **byte-identical to `upstream/dev`**. `main`'s README (`b3e871b6c`) is the JiejieBox one, which documents the product. The staged change *removes* product documentation. |
| `docs/APPLE-UI-ROUTING.md` | −52 / trimmed | **A. ALREADY_IN_MAIN** (not a loss) | The file exists **only** on the `hako-ui` line; `main`, `dev` and `upstream/dev` do not have it. The staged version is a *trimmed* variant of the `hako-ui` original, and its content describes the pre-migration single-shell iOS layout ("There is no separate iPad root … iPad currently gets the phone design. That is the defect.") — an architecture that `main` has since replaced. The untrimmed original survives in `archive/hako-design-v1`. |
| `docs/IPAD-UPSTREAM-PORT.md` | −102 / trimmed | **A. ALREADY_IN_MAIN** (not a loss) | Same situation: `hako-ui`-only file, staged version trimmed, subject matter superseded (`main` ships the idiom router `SFIUIFamily.resolve` and a `SFI/MainView.swift` that is blob-identical to `upstream/dev`). Original survives in `archive/hako-design-v1`. |
| `ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift` | 1 line: `lastUpdated.relativeFormat` → `lastUpdated.relativeFormat(forPickerRow: locale)` | **B. SUPERSEDED_BY_BETTER_MAIN_IMPLEMENTATION** | See below |

### The one real change, and why it is superseded

`ProfilePickerSheet.swift` on `main` (`31edfb6…`) is **byte-identical to `upstream/dev`** and uses
the plain property `relativeFormat` at its three call sites (lines 1054, 1139, 1443), defined in
`Library/Database/Profile+Date.swift:10`.

The `hako-ui` variant of that file is a *different, longer* file (7 `relativeFormat` occurrences)
with its own nested `relativeFormat(forPickerRow:)`. The staged edit adds the locale-aware call to
**that** file.

What the old patch was fixing: `RelativeDateTimeFormatter` defaults to `Locale.current`, not to the
locale the view is being rendered in, so a row can render in the wrong language.

How `main` covers it: the Hako presentation does not use `Dashboard/Cards/ProfilePickerSheet.swift`
for the phone — it uses the migrated `ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift`,
which **already contains both the locale-aware method and the call**:

```text
main:ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift:778
  Text(lastUpdated.relativeFormat(forPickerRow: locale))
main:ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift:1188
  func relativeFormat(forPickerRow locale: Locale) -> String { … }
```

`grep "forPickerRow"` over `main` matches **only** those two lines, i.e. the fix exists exactly
once, in the file the iPhone actually renders.

Regression evidence on `main`: `HakoScreenState` 35/35 and `HakoSubscriptionUsage` 24/24 pass, the
UI-boundary audit is PASS 19 / FAIL 0, and SFI (iOS) and SFM (macOS) both build. The locale fix is
in the shipped Hako file rather than in a retired branch's copy of an upstream file.

**Action: nothing ported.** Adding `relativeFormat(forPickerRow:)` to `Dashboard/Cards/ProfilePickerSheet.swift`
would be a behavioural change to a file that `main` deliberately keeps blob-identical to upstream,
for a presentation that does not use it — and it would need `locale` in scope at three call sites
that do not currently have it.

### Untracked files

`git ls-files --others --exclude-standard` returned nothing.

---

## Gate

Every dirty file in both worktrees is classified `A` or `B`. No `C` (temporary/generated/debug) and
no `D` (unique and still needed) was found, so the gate in §6 is satisfied and both worktrees are
removable. `--force` was still required for both, and for a reason worth recording: Git refuses to
remove a worktree that contains a submodule at all, with

```text
fatal: working trees containing submodules cannot be moved or removed
```

irrespective of the dirty-file question. `Frameworks/Runestone` is inside `clients/apple`'s working
tree, so every Apple worktree hits this. `--force` was used only after the evidence above was
written to this file.

---

## What removing the worktrees would also have removed, and did not

Removing a worktree releases its **branch**, and the dirty-file audit above says nothing about
whether that branch's commits are reachable elsewhere. Two of the three branches were checked for
that separately, because "the worktree is removable" and "the branch is disposable" are different
claims:

| Branch | Tip | Reachable from a tag? | Action |
|---|---|---|---|
| `libbox-stringbox-result-frame` | `5911580a6` | **Yes** — six tags: `archive/hako-design-v1`, `archive/hako-ui-line-local-d5b2c31`, `archive/ipad-upstream-port-final`, `iphone-hako-ui-freeze-v1`, `libbox-stringbox-abi-1`, `libbox-stringbox-abi-2` | Deleted |
| `hako-ui` | `d5b2c31e7` | **No.** Not reachable from any tag, and its remote branch was deleted in the consolidation round, so the local branch was the only thing keeping **98 commits** (16 beyond `archive/hako-design-v1`) alive | **Tagged first, then deleted** |
| `jiejiebox/integrated` | `3a550d0de` | Yes — `archive/pre-consolidation-2026-10-11` | Deleted |

### The `hako-ui` tip needed a tag of its own

`archive/hako-design-v1` points at `c1935cf`, which is **16 commits behind** the `hako-ui` branch
tip. Those 16 commits are real content that `main` does not carry — the line's last simulator-slice
note, the macOS picker-row date fix, the presentation-split rejoin, and the screen-state and
StringBox work as it stood on that line. The tip commit itself touches only
`docs/IPAD-UPSTREAM-PORT.md`, a file that exists on that line and nowhere else in the repository.

Deleting the branch would have left those commits in the object database with nothing pointing at
them, i.e. reclaimable by the next `git gc`. So the tip was tagged **before** the branch was
deleted:

```text
archive/hako-ui-line-local-d5b2c31 -> d5b2c31e79b83f15995bac5040ddef195a5ed98c
```

**This tag is LOCAL ONLY and deliberately not pushed.** The tail-cleanup round is forbidden from
writing to the Apple remote beyond its own branch, and `archive/*` tags are frozen. It exists so
that a local `gc` cannot orphan the line; it is not part of the published archive set and should
not be confused with it. If the operator wants it published, that is a separate decision.

## Final worktree state

```text
/…/sing-box/.git/modules/clients/apple    bb5309b (detached HEAD)   the parent's submodule checkout
/…/sing-box-apple-consolidation           bb5309b [main]            clean
/…/sing-box-apple-tail-cleanup            bb5309b [jiejiebox/apple-tail-cleanup]  this round
```

Both audited worktrees are gone; no worktree was retained, so there is no "why it could not be
cleaned" entry to write. Local branches after the cleanup: `main`, `dev`, and
`jiejiebox/apple-tail-cleanup`.
