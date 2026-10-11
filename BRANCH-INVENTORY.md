# Apple repository — branch inventory

Generated during the repository consolidation round, from a `git fetch --all --tags --prune`
against `Piggy-Cat-bit-shadow/sing-box-for-apple`.

**Canonical branch under construction:** `consolidation/apple-main`, created from
`origin/jiejiebox/integrated` @ `3a550d0de30e113c2dd11dcb92150ca08550d11c`.

All SHAs, dates, ahead/behind counts and patch-equivalence results below were measured on this
host; none are copied from an earlier report. `git rev-parse` was run for every row.

## Method

For each remote branch, against the canonical tip:

```bash
git merge-base --is-ancestor <branch> <canonical>   # ancestry
git rev-list --left-right --count  <canonical>...<branch>
git log --left-right --cherry-pick --oneline <canonical>...<branch>   # '>' = unique to branch
git cherry -v <canonical> <branch>                  # '+'  = unique, un-patch-equivalent
git show <sha> --pretty=email | git patch-id --stable
```

`nonEq` below is the count of `>` lines from `--cherry-pick`, i.e. commits on the branch that are
**not** patch-equivalent to anything on the canonical line. A branch with `nonEq = 0` contributes
no unique change and needs no port before deletion.

## Inventory

| Branch | Head | Commit date | Relation to canonical | Behind | Ahead | nonEq | Action |
|---|---|---|---|---|---|---|---|
| `origin/jiejiebox/integrated` | `3a550d0de` | 2026-10-11 06:48 | — (is canonical) | 0 | 0 | — | **Superseded by `main`** |
| `origin/jiejiebox/v0.1.6-hardening` | `ff849ccc2` | 2026-10-11 07:18 | diverged | 47 | 1 | **1** | **MERGED (content ported) → delete** |
| `origin/jiejiebox/hako-ui-migration-wip` | `052f06b19` | 2026-10-11 16:59 | diverged | 47 | 2 | **2** | **REVIEW → delete** |
| `origin/main` | `ab33c3f08` | 2026-10-02 19:01 | diverged | 151 | 16 | **1** | **TAG + FORCE-UPDATE to canonical** |
| `origin/dev` | `d1224bb50` | 2026-10-02 19:25 | diverged | 151 | 19 | **2** | **KEEP** (upstream reference) |
| `origin/fix/apple-notify-unknown` | `dd9114d9a` | 2026-10-09 21:10 | diverged | 151 | 20 | **3** | **ABSORBED (as `f77289f`) → delete** |
| `origin/fix/libbox-stringbox-callsites` | `2b23330d4` | 2026-10-09 15:19 | diverged | 175 | 94 | **94** | **PARTIALLY ABSORBED → tag + delete** |
| `origin/hako-ui` | `d5b2c31e7` | 2026-10-10 22:54 | diverged | 175 | 98 | **98** | **TAG + DELETE** (design archaeology) |
| `origin/ipad-upstream-ui` | `816600ab3` | 2026-10-09 14:03 | diverged | 175 | 91 | **91** | **ABSORBED → delete** |
| `origin/r8/a-generator` | `cca3ee446` | 2026-10-10 15:17 | **ancestor of canonical** | 66 | 0 | 0 | **SAFE_TO_DELETE** |
| `origin/r8/b-boundary` | `3e354edf5` | 2026-10-10 15:20 | **ancestor of canonical** | 67 | 0 | 0 | **SAFE_TO_DELETE** |
| `origin/r8/c-platform` | `80eec7eac` | 2026-10-10 15:40 | **ancestor of canonical** | 67 | 0 | 0 | **SAFE_TO_DELETE** |
| `origin/r8/d-reach` | `e1cefe648` | 2026-10-10 14:33 | **ancestor of canonical** | 68 | 0 | 0 | **SAFE_TO_DELETE** |
| `origin/r8/main` | `2a189686a` | 2026-10-10 20:45 | **ancestor of canonical** | 37 | 0 | 0 | **SAFE_TO_DELETE** |
| `origin/stable` | `0b84ea472` | 2026-08-30 17:55 | **ancestor of canonical** | 274 | 0 | 0 | **SAFE_TO_DELETE** |

`origin/HEAD` and the bare `origin` row resolve to `origin/dev` (`d1224bb50`).

## Reading the four large divergences

`hako-ui` (98), `ipad-upstream-ui` (91) and `fix/libbox-stringbox-callsites` (94) each carry a
large number of commits that are not patch-equivalent, and none of them is an ancestor of the
canonical line. They are **not** therefore "unmerged work": all three branch from around
`upstream/dev` @ `2b1763a` and were largely re-created on the canonical line under different
SHAs during the migration rounds, which is exactly the case
`git log --left-right --cherry-pick` cannot see through. What matters for each is whether its
**distinctive** change is present in the canonical tree, which was answered per branch in
Phase E of this round and is recorded in `REPOSITORY-CONSOLIDATION-REPORT.md` §5.

`r8/*` and `stable` need no such reasoning at all: `git merge-base --is-ancestor` proves every
one of them is already contained in the canonical line, so deleting them removes no commit that
is not reachable from the branch that replaces them.

## Tags present before this round

| Tag | Points at | Subject | Ancestor of canonical? |
|---|---|---|---|
| `iphone-hako-ui-freeze-v1` | `fc7f77b82` | Freeze validated iPhone Hako UI before iPad upstream UI integration. | **NO** |
| `libbox-stringbox-abi-1` | `8599039f6` | fix(ui): read the migrated libbox accessors through their Value property | **NO** |
| `libbox-stringbox-abi-2` | `2b23330d4` | fix(ui): install the screen-state observer the device axis needs | **NO** |

**This is a retention dependency, not a footnote.** None of the three is reachable from the
canonical line, and all three are reachable *only* from branches this round retires:

```text
libbox-stringbox-abi-1        origin/fix/libbox-stringbox-callsites, origin/hako-ui
libbox-stringbox-abi-2        origin/fix/libbox-stringbox-callsites, origin/hako-ui
iphone-hako-ui-freeze-v1      origin/fix/libbox-stringbox-callsites, origin/hako-ui,
                              origin/ipad-upstream-ui
```

`libbox-stringbox-abi-2` pins the tip of `fix/libbox-stringbox-callsites`
(`2b23330d489b9f6b45e98f903f458842e8961594`) exactly, so that branch's final state survives in a
tag independently. `libbox-stringbox-abi-1` (`8599039f6`) and `iphone-hako-ui-freeze-v1`
(`fc7f77b82`) are separate commits that exist nowhere on the canonical line. Deleting the three
branches without these tags would orphan their content, which is why the tag set was enumerated
and verified **before** any deletion rather than assumed.
