# Round 8 → Round 9 handoff

Written for a fresh window with no memory of round 8. **This file is the whole handoff.**

## 1. What is where

| | |
|---|---|
| Repository | `https://github.com/Piggy-Cat-bit-shadow/sing-box-for-apple` |
| Integration branch | `jiejiebox/integrated` |
| **Final SHA, verified against the remote** | **`4f8c07ef4139f28820e897e26d1c7dd056415944`** |
| Round start | `e1cefe6484be9aff120600af449a7c45c3e030bc` |
| iPhone UI gold standard | `hako-ui@c1935cff77246f97498400f5a0a7f430cfabbd55` |
| Upstream comparison baseline | `SagerNet/sing-box-for-apple dev@089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| iPad reference (protected, not worked on) | `ipad-upstream-ui@816600ab3f2823ab5de1da66e36433ef3a21fc10` |
| Parent repo | `Piggy-Cat-bit-shadow/sing-box`, **not touched**; its `clients/apple` gitlink is still `2b23330d489b9f6b45e98f903f458842e8961594` |

### The environment, which is unusual and you must set up first

There is **no `git` and no `python` on `PATH`**. Both were installed for round 8:

```powershell
$env:Path    = "C:\Deepseek\IOS客户端\_tools\mingit\cmd;" + $env:Path   # portable git 2.50
$env:PYTHON  = "C:\Users\Jie\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$env:DSH_REPO = "C:\Deepseek\IOS客户端\sing-box-for-apple"              # holds origin/hako-ui = c1935cff
$env:DSH_GIT  = "C:\Deepseek\IOS客户端\_tools\mingit\cmd\git.exe"
```

`DSH_REPO` and `DSH_GIT` are read by `migrate_secondary_page.py`, `audit_hako_lossless_parity.py` and the
platform tools. **Set them in every command** — the tools' default for `REPO` is
`<parent of the worktree>/sing-box-for-apple`, which does not exist.

There is **no Xcode, no Swift toolchain, no `Libbox.xcframework`, no `GhosttyTerminal` framework** and no
device. Nothing in this repository's state is a build result.

Pushing works through a credential helper that reads the GitHub token out of the DSH profile config:

```powershell
$env:GITHELPER = '!powershell -NoProfile -ExecutionPolicy Bypass -File "C:/Deepseek/IOS客户端/_tools/ghcred.ps1"'
git -C $env:DSH_REPO -c credential.helper=$env:GITHELPER push origin <ref>
```

### Worktrees

| Path | Branch | Purpose |
|---|---|---|
| `C:\Deepseek\IOS客户端\jiejiebox-integrated` | `jiejiebox/integrated` | the integration worktree |
| `C:\Deepseek\IOS客户端\_work\r8\w-main` | `r8/main` | where round 8's commits were made |
| `_work\r8\w-a` … `w-e` | `r8/a-generator` … | per-agent isolation worktrees |
| `_work\refs\up-hako` | detached `c1935cf` | the original iPhone UI, read-only |
| `_work\refs\up-forkdev` | detached `d1224bb` | the fork's dev |
| `_work\refs\up-ipad`, `up-libbox`, `up-notify` | detached | kept for reference |

**Never delete a directory under `_work` with `Remove-Item -Recurse`.** A junction inside one was traversed
during round 8 and destroyed the main repository's `.git`; the recovery is described in
`docs/HAKO-ROUND8-FINAL-DEBUG.md`. There are no junctions left, but the hazard is real. Delete reparse
points with `[System.IO.Directory]::Delete($path, $false)`, never recursively.

## 2. Where round 8 ended

```text
IPHONE_HAKO_UI=STATIC_VERIFIED
IPAD_MAC_OFFICIAL_ISOLATION=PASS_STATIC
GENERATOR_SAFETY=PASS
INDEPENDENT_DEBUG=NOT_COMPLETED          <- the one deliverable round 8 did not do
APPLE_BUILD_DEVICE_PIXEL=UNVERIFIED
```

`audit_apple_ui_boundary.py --strict` reports **PASS 18, FAIL 0, UNKNOWN 0, UNDECIDABLE 0**.
`platform-guard-agreement` went from 29 findings across 10 files to PASS.

## 3. What to do first, in order

### (a) Run the suite and confirm the state you inherited

From `_work/r8/w-main` (or `jiejiebox-integrated` at `4f8c07e`):

```powershell
python scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85 --strict
python scripts/dev/test_audit_apple_ui_boundary.py
python scripts/dev/test_audit_reverse_routing.py
python scripts/dev/audit_hako_lossless_parity.py
python scripts/dev/test_fail_closed_exit_codes.py
python scripts/dev/test_migrate_secondary_page.py --root .
python scripts/dev/test_platform_gates.py
python scripts/dev/check_hako_macos_parse.py --platform ios
python scripts/dev/check_hako_macos_parse.py --platform macos
python scripts/dev/check_hako_macos_parse.py --platform tvos      # red, see (b)
python scripts/dev/gate_hako_platform_imports.py --check          # red, see (b)
python scripts/dev/wrap_hako_platform_declarations.py --check
python scripts/dev/check_swift_structure.py ApplicationLibrary/Views/HakoStyle SFI
python scripts/dev/check_platform_structure.py .
python scripts/dev/check_generated_headers.py .
```

Expected: everything green except the two tools in (b).

### (b) The one real repair left: `canImport(AppKit) ⟹ os(macOS)`

`gate_hako_platform_imports.py --check` and `check_hako_macos_parse.py --platform tvos` report
`NOT VERIFIED` for AppKit and QuickLook symbols used inside `#if canImport(AppKit)` blocks:

```
[NOT VERIFIED] HakoGroupItemView.swift:101  whether nsColor is compiled on tvos could not be decided
[NOT VERIFIED] HakoSurface.swift:236        whether nsColor is compiled on tvos could not be decided
```

This is a **tooling gap, not a Swift defect**. Either repair closes it:

* teach the condition model the two Apple facts — `canImport(AppKit) ⟹ os(macOS)` and
  `canImport(UIKit) ⟹ os(iOS) || os(tvOS)`; or
* route those questions through `symbol_availability()` at `scripts/dev/hako_platform_facts.py:351`, which
  already knows `NSColor` is macOS-only and carries its evidence.

The refusal itself must stay: an unproven `canImport(QuickLook)` answer for tvOS must remain `NOT VERIFIED`
and non-zero, never a guess.

### (c) The deliverable round 8 did not do: an independent red-team debug

Round 8's Wave E never ran. That is why `INDEPENDENT_DEBUG=NOT_COMPLETED` and why round 8's own checks must
not be presented as independent verification. The next window should start a **fresh subagent that did not
participate**, give it the SHA, the baselines and the challenge list below — **not** the authors'
conclusions — and have it read the source itself.

Challenge list for it, from what round 8 found and did not:

1. **Insert a fault and prove the detector catches it.** Every check added in round 8 claims it can go red;
   make it demonstrate that for `platform-guard-agreement`, `reverse-routing-contract`,
   `reverse-routing-derived`, and the fail-closed exit codes.
2. **The tvOS column.** `ApplicationLibrary` builds for `appletvos` (`project.pbxproj:2288` Debug, `:2330`
   Release — that target's own two configurations). Walk the ported files and find a declaration whose
   condition its callers do not have; round 8 fixed five cascades of exactly that shape and each was found
   only after the previous one was fixed.
3. **Lifecycle.** Round 8 repaired `environments.connect()` being absent from the phone root and an inert
   `installTunnel`. Check the rest of the phone root's lifecycle against
   `up-hako@c1935cf ApplicationLibrary/Views/Dashboard/ActiveDashboardView.swift:105-128` — the original
   hooks that were **not** restored, if any.
4. **Profile state machine.** Create / remote import / local file / QR / edit / save / failure / dismiss /
   `profileUpdate` / repeated taps. Round 8 did not examine these; agent D's review is in
   `_work/r8/d-scratch/D-REPORT.md` and its five explicit `UNKNOWN`s are worth re-opening.
5. **Generator.** `migrate_secondary_page.py` is now a checker rather than a migrator: of 66 pages, 24 `OK`,
   22 `HAKO_SYMBOL_LOSS`, 16 `PORTED_UNWIRED`, 2 `SHARED_TYPE_SPLIT`, 1 `ENVIRONMENT`, 1 `RENAME_MAP_EMPTY`.
   Verify independently that `--write` refuses each of the three report pages and cannot rewrite an existing
   differing target.
6. **The four frozen originals.** `hako-ui@c1935cf` is the authority. Check the ported pages against it for
   anything that is *not* a token — the parity audit compares token sets and cannot see a drawing change.
7. **Git and process.** `git diff --check`, `git status` in every worktree, no stash/reset/force anywhere,
   no Actions triggered, the parent repo and its gitlink untouched.

### (d) Then Apple verification, which needs a Mac

The schemes that exist, read from `sing-box.xcodeproj/xcshareddata/xcschemes/` rather than guessed: **`SFI`,
`SFM`, `SFM.System`, `SFT`, `JailbreakDaemon`**. Targets in the project: `SFI`, `SFM`, `SFM.System`, `SFT`,
`SFIUITests`, `SFMUITests`, `SFTUITests`, `ShareExtension`, `ShareExtension.System`.

Not yet done by anyone, in any round: that `SFI` builds for `iphoneos` and for iPad, that `SFM` builds for
`macosx`, that `ApplicationLibrary` compiles for each of `iphoneos`/`macosx`/`appletvos`, that the pages
draw as `docs/HAKO-REAL-REACHABILITY-MATRIX.md` says, or that the pixels match `hako-ui@c1935cf`.

## 4. The documents round 8 left

| File | What it is |
|---|---|
| `docs/HAKO-REAL-REACHABILITY-MATRIX.md` | entry → construction site → end page for every user path, with `HAKO` / `ORIGINAL_SHARED_OK` / `BROKEN` per row and the check that asserts it |
| `docs/HAKO-ROUND8-FINAL-DEBUG.md` | every finding, fix, commit and reproduction — including the `.git` incident and its recovery |
| `docs/HAKO-ROUND8-REMAINING-FAILURES.md` | the one open gate, with both honest repairs |
| `docs/HAKO-UI-MIGRATION-MATRIX.md` | corrected: stale SHA and the "second-level pages PENDING" claim now match the source |
| `scripts/dev/MIGRATION-SAFETY-CONTRACT.md` | what the generator will and will not do, and why |
| `_work/r8/A-REPORT.md`, `B-REPORT.md`, `C-REPORT.md`, `D-REPORT.md`, `D-FINDINGS.json` | the four agents' own write-ups, including what each could not evaluate |

## 5. Rules that must not be relaxed

1. **iPhone keeps the original Hako UI**; **iPad and macOS keep upstream's**. `#if os(iOS)` **includes
   iPad** and is never a synonym for "iPhone"; the isolation comes from the entry dispatch plus
   phone-private types. `ipad-mac-ui-gate`, `tablet-and-mac-entry` and `phone-entry` are the checks.
2. **No Apple result may be claimed without a Mac.** Static green is not a build.
3. **Never delete an assertion, widen an exemption, or lower an error to UNKNOWN to make a gate pass.** Two
   checks stay out of the enforced set for evidence, not convenience: `hako-annotation-agreement` passes with
   its own historical defect restored, and `hako-type-has-caller` reports five findings on a correct tree.
4. **No `git reset --hard`, `git clean -fdx`, `git stash`, force push, rebase of pushed history, or touching
   the parent repo or any gitlink.** Nothing has been force-pushed; keep it that way.
5. **Fault-injection tests run in disposable copies**, never in a real worktree. The suites already do this
   and assert byte-identity afterwards.
6. **A check that cannot fail is worthless.** If you add one, add the negative case that proves it goes red,
   and calibrate it against the pinned original first — a check that fails on the reference implementation is
   measuring itself. Round 8 hit that twice: a brace counter that treated `//` inside a URL as a comment, and
   a worktree search that rejected `.git` files.

## 6. Known traps

* `python` and `git` are not on `PATH`; set them per command as in §1.
* Write commit messages to a file and use `git commit -F`, with
  `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`.
  `Set-Content -Encoding UTF8` writes a BOM, which lands in the commit subject;
  `scripts/dev/check_commit_messages.py <range>` finds one.
* Piping a tool's `--json` through PowerShell mangles non-ASCII paths and can drop the exit code. Write it to
  a file with an explicit BOM-less encoder and read it back — `scripts/dev/show_guard_findings.py` and
  `_work/r8/bin/list_guard_findings.py` are examples.
* `Remove-Item -Recurse` traverses junctions. See §1.
* The audit's `--only <check>` filters, and `project-membership` reads the whole tree; a stray untracked
  `.py` under `scripts/dev/` makes the boundary suite's `reset` fail, because it cannot remove untracked
  files. Commit support scripts, do not leave them lying about.
