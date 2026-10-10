# Phase 2 status

Running record of what the second phase has actually done, so progress does not have to be
reconstructed from a commit log or a chat.

**Last updated:** at `c18d712`.

---

## Where the branch is

| | |
|---|---|
| Branch | `jiejiebox/integrated` |
| Upstream baseline | `upstream/dev` @ `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| Hako reference | `hako-ui` @ `c1935cff77246f97498400f5a0a7f430cfabbd55` |
| Push | ordinary push to `origin/jiejiebox/integrated`, verified local == remote by three readings |

---

## Tracks

### Track S — screen state (P0) — **closed**

| Item | Result |
|---|---|
| Phase 1's attribution of upstream's behaviour | **corrected.** Upstream never calls `recordLockState`; the defect is `wakeNow()` on display-on. See `docs/SCREEN-STATE-FACTS.md` |
| The kernel contract this client must satisfy | **read from source**, both kernels, at the two repositories. Recorded in the same file |
| Partial registration | fail-closed, and the reason is written down rather than assumed |
| Missed unlock | recoverable by `resync()`; the residual case is `NEEDS_DEVICE` |
| Cancel race | **`NO_BUG_FOUND`, with the argument.** The fence and the publish are serialised on one queue, and `cancel()` also clears the registration the publish needs |
| Implementation changes | **none.** The code already matches the contract |
| Tests | `Tests/HakoScreenState`, 33 cases over the pure policy and the observer, written and **not executed** (no Swift toolchain) |

### Track U — the phone's pages — **complete, 6 of 6**

| Page | Status |
|---|---|
| Home | **MIGRATED** — `HakoStyle/HakoHomeView.swift` |
| Logs | **MIGRATED** — `HakoStyle/HakoLogView.swift`, a wrapper over upstream's `LogViewContent` |
| Proxies | **MIGRATED** — `HakoStyle/HakoGroupListView.swift` |
| Activity | **MIGRATED** — `HakoStyle/HakoConnectionListView.swift` |
| Tools | **MIGRATED** — `HakoStyle/HakoToolsView.swift` |
| More | **MIGRATED** — `HakoStyle/HakoSettingView.swift` |

The per-page detail, the reference diffs to read and the rule for adding a page are in
`docs/HAKO-UI-MIGRATION-MATRIX.md`.

### Track Q — audit, docs, guards — **current**

| Item | Status |
|---|---|
| `hako-page-coverage` | added. **Fails** while the migration is incomplete; `--allow-partial` reports `UNKNOWN` instead |
| `hako-feature-preservation` | added. Requires each feature to be wired — an opener and a consumer |
| `ipad-mac-ui-gate` | added. The official picker must be upstream's bytes **and** contain none of the phone's row content |
| `branding` | strengthened. Every display name attributed to its target; identity settings compared to the pinned commit |
| `subscription-feature` | inverted to match the move, and strengthened to require the row to *draw* |
| Negative suite | rewritten, 16 cases, all behaving as designed |
| `docs/SCREEN-STATE-FACTS.md`, `docs/HAKO-UI-MIGRATION-MATRIX.md`, this file | written |

---

## The one thing phase 2 changed in the product, and why

The remaining-quota row moved out of
`ApplicationLibrary/Views/Dashboard/Cards/ProfilePickerSheet.swift` and into
`ApplicationLibrary/Views/HakoStyle/HakoProfilePickerSheet.swift`, and the official picker is restored
to upstream's blob byte for byte.

Phase 1 put the row in the official picker and recorded the file as a reviewed modification with a
reason. The reason was true and the result was still wrong: `#if os(iOS)` covers iPad, the row's
insertion was unconditional, and an iPad therefore showed something upstream's picker does not. A
whitelist can say "this file was changed on purpose". It cannot say "this file shows the user
something upstream's does not", and that is the property the product requires.

`ipad-mac-ui-gate` now asserts both, so the same mistake cannot be recorded as reviewed and pass.

---

## What is verified here, and what is not

Run on this machine, on the current commit:

```
python scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e
    PASS 12  FAIL 0  UNKNOWN 0

python scripts/dev/test_audit_apple_ui_boundary.py
    16/16 cases as designed
```

The one `UNKNOWN` is `hako-page-coverage`, which is the honest count: 2 of 6 pages migrated. Without
`--allow-partial` that check is a `FAIL`, deliberately, so the incomplete state cannot be read as a
finished one.

**Superseded.** The six first-level pages are now all migrated: the audit reports `PASS 12  FAIL 0
UNKNOWN 0` and `hako-page-coverage` no longer needs the flag. See *The next concrete step* below.

**Not verified, and not claimed:**

| | |
|---|---|
| Swift compilation | `UNVERIFIED: no Xcode, no macOS, no Libbox.xcframework` |
| `Tests/HakoScreenState` and `Tests/HakoSubscriptionUsage` | written, `UNVERIFIED: no Swift toolchain` |
| Device and simulator behaviour | `DEFERRED` — see `docs/APPLE-DEVICE-ACCEPTANCE.md` |

---

## The next concrete step

Logs is done and settled the pattern: apply the fork's presentation to upstream's content by raising
the content's visibility, rather than copying the page. The next four are expected to need the same,
and each such change belongs on `REVIEWED_UPSTREAM_MODIFICATIONS` with its reason.

Next: **Proxies** and **Activity** (+273/-30 and +207/-34), then **Tools** and **More**
(+304/-237 and +427/-191).

For each: create `HakoStyle/Hako…View.swift`, point the arm in `SFI/HakoPageContent.swift` at it, set
the entry in `HAKO_PAGE_ROUTING`, add any new wiring to `hako-feature-preservation`, run both scripts,
and update `docs/HAKO-UI-MIGRATION-MATRIX.md`.

## Environment blockers, recorded rather than worked around

| Blocker | What it stops | What would close it |
|---|---|---|
| No `Libbox.xcframework` | every Apple build, and the `StringBox` ABI question | the parent repository's kernel build products |
| No Swift toolchain | the two test packages | a Swift toolchain; the packages have no Apple dependency |
| No Apple device | every visual and lifecycle check | a Mac and a device |
