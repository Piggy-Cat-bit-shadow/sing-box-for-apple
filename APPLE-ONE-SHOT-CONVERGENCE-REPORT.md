# Apple one-shot convergence report

One pass: audit the outstanding increments, absorb the ones that carry real semantics, verify,
advance `main` by fast-forward, and delete every construction branch.

```text
old main SHA:    bb5309b4a6c5b06382e1277a6e7ac0fbeadc9a72
final main SHA:  7e8fc397d3f90ed1bc40f6b356cab58d0798548f  -> then this report's commit
```

> The final value is **the tip of `main`**, i.e. the commit that carries this text. A report is a
> commit on the branch it describes, so a literal here is one commit stale as soon as it is
> committed. The authority is `git rev-parse origin/main`; see §15.

```text
tail-cleanup:
  merged = YES   (fast-forward, all 3 commits, no squash, no rewrite)

e15ec22:
  absorbed = YES
  method   = cherry-pick (clean, additions only)

83127c20:
  absorbed = YES
  final ScreenState count = 38 tests, 0 failures

f4a98590:
  branch not merged
  useful semantics accounted for = YES

Subscription:    PASS - 24 tests, 0 failures
Boundary audit:  PASS - 19 checks, FAIL 0 / UNKNOWN 0 / UNDECIDABLE 0
Boundary harness: PASS - every negative case failed as designed, positive case passed
Primary route:   PASS - 55 cases, 0 failures
SFI build:       BUILD SUCCEEDED
SFM build:       BUILD SUCCEEDED

Runtime:
  NOT RUN - SIGNING_BLOCKED

Remote branches after cleanup:
  main
  dev

FINAL_APPLE_SHA:
  git rev-parse origin/main
```

---

## 1. What was absorbed, and what was deliberately not

```text
main
  + tail-cleanup 5794092, 441b289, 7e8fc39   fast-forward
  + e15ec22  serviceLifecycleLock            cherry-pick, 43 insertions, 0 deletions
  + 83127c20 ScreenState test hardening      cherry-pick, tests only
  -> verified -> fast-forwarded to main -> temporary branches deleted
```

**No WIP branch was merged.** Neither `jiejiebox/hako-ui-migration-wip` nor
`jiejiebox/ne-p3-code-closure` was merged or cherry-picked as a range. Both carry retired
migration history, old UI state, script deletions and superseded docs, and merging either would
have re-polluted a `main` that had already been consolidated.

The shape of the final merge confirms it. Five commits, nine files:

```text
 APPLE-TAIL-CLEANUP-REPORT.md                       | 270 +++++
 Library/Network/ExtensionProvider.swift            |  43 +++
 OLD-WORKTREE-AUDIT.md                              | 211 +++++
 REPOSITORY-CONSOLIDATION-REPORT.md                 |  42 +-
 Tests/.../ScreenStateObserverTests.swift           | 366 +++++++++-
 scripts/dev/audit_apple_ui_boundary.py             |  72 +-
 scripts/dev/check-hako-primary-route.sh            |  34 +-
 scripts/dev/check-hako-primary-route.swift         |  20 +-
 scripts/dev/test_audit_apple_ui_boundary.py        |  62 +-
```

and the STOP conditions were each checked and are each absent:

| STOP condition | Measured |
|---|---|
| large-scale `HakoStyle` rollback | **0 files touched** under `ApplicationLibrary/Views/HakoStyle` |
| migration scripts mass deletion | **0 files touched** matching `scripts/dev/port_*` or `scripts/dev/migrate_*` |
| old UI ownership restored | not present — the only product file changed is `ExtensionProvider.swift`, +43/−0 |
| old docs rolled back | **0 files touched** under `docs/` |
| any file deleted at all | **none** — `--diff-filter=D` matches nothing |

The only deletions in the whole diff are line-level edits inside five already-modified files, and
each is an edit to text the same commit replaces.

## 2. `e15ec22` — the service-lifecycle lock

**Target:** `Library/Network/ExtensionProvider.swift`. One file, 43 insertions, no deletions.

**What it adds.** A single `NSLock` that `startService()` and `stopService()` both take, so a
teardown cannot land inside a start. `stopService()` ends in `platformInterface.reset()`, which
cancels and nils `nwMonitor`; a reload's `startService()` installs a fresh monitor in
`startDefaultInterfaceMonitor`, and that call blocks on a semaphore until the monitor's first path
update — so the window between "the new monitor is assigned" and "the new monitor has delivered"
is not short. A `reset()` landing in it cancels the live monitor and the next `getInterfaces()`
throws `NWMonitor not started` with nothing able to repair it. Two concurrent `stopService()`
calls also ran `reset()` twice over the same four unsynchronised statements.

The lock is held across `startOrReloadService` and the monitor install it triggers, both
synchronous, so nothing suspends while it is held and there is no deadlock surface against
`stopService()`, which takes the same lock directly. It is not held across the macOS
`locationManager` block.

**Method: cherry-pick, and it applied cleanly.** No conflict, which is the outcome §5 permits to
be taken directly. Verified rather than assumed:

```text
deletions in the cherry-pick          0        (additions only, so nothing was reverted)
serviceLifecycleLock.lock()           2
serviceLifecycleLock.unlock()         2        (balanced)
unwindFailedStart                     2        (preserved)
guard let commandServer               2        (preserved)
serverIsStillCurrent                  2        (preserved)
stopScreenStateObserver               4        (preserved)
```

The four constructs §5 requires `main` to keep are all still present after the pick. The lock
guards `startService` (`:415`) and `stopService` (`:449`).

The one remaining `commandServer!` in the file is inside a comment that records what the
force-unwrap used to be; `main`'s actual call site is `commandServer.needWIFIState()` inside the
`guard let` introduced by `ff849cc`, so it is unreachable with nil.

## 3. `83127c20` — ScreenState test hardening

**Target:** `Tests/HakoScreenState/Tests/ScreenStateTests/ScreenStateObserverTests.swift`. Tests
only — the commit touches no product file, so no product ScreenState behaviour changed.

**Result: 38 tests, 0 failures** — the §7 target was `>= 38`.

Before this commit the suite was 35/35, so the hardening adds three cases plus the fake
improvements it was written for: registration history, duplicate-registration accounting,
`INVALID_TOKEN` modelling, stale-callback-owns-original-token, a post-cancel positive control,
restart-callback strengthening, and blind-spot mutation tests.

**Two earlier corrections were re-checked after the auto-merge, because the incoming file
predates them:**

| Must survive | Status |
|---|---|
| rule-5 unlock guard in the **product** observer (`if fact == .unlocked, lastObserved != 1`) | **present** — `Library/Network/ScreenStateObserver.swift:255` |
| the truth table's `XCTAssertEqual(last, 1, …)` unlock arm | **present** — `ScreenStateObserverTests.swift:570` |

The pick auto-merged that one file; the product observer was not in the commit at all, which is
why the guard could not have been touched.

## 4. `f4a98590` — cross-evidence only, branch not merged

`jiejiebox/ne-p3-code-closure` was **not** merged and **not** cherry-picked. `f4a98590` was read as
evidence, and it corroborates this round two ways:

1. It fixes the same `stopTunnel` identity problem that `main` already carries from `ff849cc`,
   including the macOS XPC teardown. **Already in `main`** — `serverIsStillCurrent` is present.
2. It fixes the same interface-monitor cancellation, with the same derivation (the core reaches
   `stopService()` synchronously on its gRPC handler goroutine via
   `ExtensionPlatformInterface.serviceStop()` → `tunnel.stopService()`, which is an independent
   thread by construction). **Absorbed this round as `e15ec22`.** The two commits derive the same
   defect from the same call path, which is the agreement the prompt asked for.

`f4a98590`'s own message carries the finding that matters: it was first written against
`jiejiebox/hako-ui-migration-wip`, because that branch already had the identity check and the
observer guards, while the commit the core then pinned (`2a189686`) had none of them — no
`serverIsStillCurrent`, no `guard let commandServer`, no `unwindFailedStart`, and an observer
calling `wakeNow()` unconditionally. `main` has since superseded `2a189686` on every one of those
points:

```text
unwindFailedStart      present
guard let commandServer present
serverIsStillCurrent   present
ScreenState resync()   present   (dev's observer is a stub with no resync at all)
```

Status: **SEMANTICALLY_ABSORBED.** The branch's unique line descends from a baseline `main` has
moved past.

## 5. Gates

| Gate | Command | Result |
|---|---|---|
| ScreenState | `cd Tests/HakoScreenState && swift test` | **38 tests, 0 failures** |
| Subscription | `./scripts/run-subscription-usage-tests.sh` | **24 tests, 0 failures** |
| Boundary harness | `python3 scripts/dev/test_audit_apple_ui_boundary.py` | **PASS** — every negative case failed as designed, positive case passed |
| Boundary audit | `python3 scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e` | **PASS 19 / FAIL 0 / UNKNOWN 0 / UNDECIDABLE 0** |
| Primary route | `scripts/dev/check-hako-primary-route.sh` | **PASS** — 55 cases, 0 failures |
| SFI (iOS) | `xcodebuild -scheme SFI -destination 'generic/platform=iOS'` | **`** BUILD SUCCEEDED **`** |
| SFM (macOS) | `xcodebuild -scheme SFM -destination 'generic/platform=macOS'` | **`** BUILD SUCCEEDED **`** |

The builds were required because a real product source file changed
(`Library/Network/ExtensionProvider.swift`).

### A build-method note worth recording

The first attempt ran the two `xcodebuild` invocations **in parallel**, and they collided in the
shared DerivedData `SourcePackages` directory — `unable to write file …/GRDB.swift/.git/modules/…`
and `Could not resolve package dependencies`. That is a defect in how the builds were driven, not
in the tree. Run sequentially, SFM succeeded, and SFI was then given its own
`-derivedDataPath /tmp/dd-conv-ios` and also succeeded. Both successes are from this worktree:
the SFM build log references `sing-box-apple-final-convergence` paths.

## 6. Runtime and devices

```text
BUILD = REQUIRED   -> done, both products
RUN   = NOT REQUIRED
DEVICE = NEEDS_DEVICE / SIGNING_BLOCKED
```

The app was **not** run, and **Mac and iPad real-device testing is unavailable**, with no
simulator path for this project's acceptance either. No signing, entitlement, bundle-identifier or
provisioning setting was changed in order to make anything run — `CODE_SIGNING_ALLOWED=NO` is a
build flag, not a configuration change, and the diff contains no plist, entitlement or project
setting edit. Device acceptance remains with release acceptance, and **nothing in this report is a
device result.**

## 7. What remains

Nothing on the Apple side. Two items are outside this round by instruction:

1. **The parent repository was not modified.** Apple `main` has advanced, so every older Apple pin
   in the parent is now stale. The value the parent must pin is `git rev-parse origin/main` on the
   Apple repository, and `scripts/ci/check-libbox-abi.sh`'s `VERIFIED_APPLE_SHA` must move with it.
   That is the next round's work.
2. **Core hardening consolidation** — still the core repository's own audit, untouched.

## 8. Pushing and cleanup

`main` was advanced by **fast-forward only**:

```bash
git merge-base --is-ancestor "$OLD_MAIN" "$FINAL_SHA"   # required before pushing
git push origin HEAD:main                                # no force, no force-with-lease
git fetch origin && git rev-parse origin/main            # must equal FINAL_SHA
```

No `--force` and no `--force-with-lease` was used or needed: the convergence branch is a direct
descendant of `main`, so the push is linear by construction.

Every temporary branch was then deleted — `jiejiebox/apple-tail-cleanup`,
`jiejiebox/hako-ui-migration-wip`, `jiejiebox/ne-p3-code-closure`, and
`jiejiebox/apple-final-convergence` — each preceded by a `--cherry-pick` reachability check to
confirm no still-unabsorbed semantics would be dropped. `main` and `dev` remain, and nothing else.
