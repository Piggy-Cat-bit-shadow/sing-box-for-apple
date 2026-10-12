# Hard invariants and conventions

Re-audited at the 2026-10-12 refresh against `REFRESH.md` §33. An invariant is kept only if
violating it would break one of: product ownership, a platform constraint, a signing/entitlement
contract, a **verified** lifecycle/concurrency defect, a design freeze/preservation contract, an
ABI/pin requirement, or release integrity. Everything else was downgraded to a convention, and two
entries moved in this pass.

## Hard invariants

Each names the mechanism that would break, not just the rule.

| # | Invariant | What a violation breaks |
|---|---|---|
| 1 | **Device idiom — not `#if os(iOS)` and not size class — selects the phone experience.** `.phone` is the only arm that grants Hako. | Product ownership. `SFI/Application.swift`; enforced by `phone-entry` and `ipad-mac-ui-gate`. An iPad in Split View is still an iPad |
| 2 | **Hako is reachable only through the dedicated phone route; upstream-reachable shared pages may not depend on Hako symbols.** | Product ownership, and one direction of the dependency graph. Enforced by `no-reverse-dependency` (319 files) and `ipad-mac-ui-gate`. `2f0024c` is the recorded near-miss |
| 3 | **The one shared model/environment injection serves both presentation routes.** State is created once above the routing switch. | Product ownership. Forking state to change visual ownership would make the phone and the iPad disagree about the tunnel |
| 4 | **Bundle identifiers, App Groups, entitlements, signing, URL/UTI identity, `Variant.applicationName`, the Runestone gitlink, and the Libbox ABI/source are release contracts.** Branding is a visible overlay only. | Release integrity and signing. Verified unchanged from `089d35e6` at this baseline |
| 5 | **The extension's service lifecycle is serialised, and a failed start unwinds what it created.** | A verified concurrency defect: the core reaches `stopService()` from a gRPC goroutine, and `reset()` cancels a monitor a concurrent start is still waiting on. `8d06a99`, `f4a9859`. See `modules/network-extension.md` |
| 6 | **The observer outlives a reload and is created exactly once per tunnel process.** `reloadService()` must not re-register it. | A verified lifecycle defect: a second registration hands the core a second, independent device axis and leaks the first token set |
| 7 | **Observer callbacks are fenced at teardown, on both sides of the read.** | A verified lifecycle defect: a callback queued before `cancel()` and run after it would publish into a closed server |
| 8 | **A snapshot may never be delivered through an edge verb.** | A verified lifecycle defect (the P1-C regression). Publishing a re-read as an edge re-anchors the measurement a resume just published. `987134b` |
| 9 | **An unlock requires an observed lock.** | A verified lifecycle defect: `.unlocked` is the only fact that lifts the device pause, and `notify_get_state` answers `0` for a name whose state was never set. `891c6cb` |
| 10 | **The interface monitor's first wait is bounded, and its callbacks are generation-guarded.** | A verified startup-hang defect (airplane mode) plus a stale-callback defect. `15d3a72`, `628644d`. **This invariant is new in this pass** — the previous baseline recorded the opposite as a known defect |
| 11 | **A localization key must exist; a near-miss is silent.** `String(localized:)` returns its key on a miss. | Release quality, and it was a real shipped defect (half-English zh-Hans UI). `467f8ea`, `8fe8e79` |
| 12 | **The Hako freeze tag is provenance, not a license to overwrite later adapted source.** Generated/ported files require the migration authorization checks. | A design freeze/preservation contract. See `modules/hako-ui.md` for the generator hazard that makes this concrete |

Invariants 1–4 and 12 were carried forward unchanged and re-verified. 5–9 were carried forward and
re-verified **against the fixed code**, not against the reports. 10 and 11 are new.

### Two entries that moved

- The interface-monitor invariant moved **from "known defect" to "invariant"**: an unbounded wait
  was the recorded state, a bounded one is now the contract. A future reader who consults the old
  baseline will find the opposite statement — `REFRESH.md` §31's warning about carrying a stale
  clone-specific note applies here.
- `ScreenStatePolicy`'s rule count moved **from 4 (+1 missing) to 6**. The invariant is stated as
  the *rule*, not the count, so it survived the change; the count is in
  `modules/screen-state.md`.

## Current conventions

These are deliberate choices, not contracts. Violating one is a review conversation, not a defect.

- Make narrow shared changes when behavior must be common; make phone-only changes inside Hako-owned paths.
- Keep upstream UI byte-identical where the audit names it, and register/review any intentional shared upstream deviation. The reviewed list is currently **24 of 458** files.
- Prefer `migrate_secondary_page.py` (which uses `preserve()`) over the port generators that call `resolve()`.
- Treat `docs/pending/` and round handoffs as frozen evidence, not instructions for current edits.
- Keep `KNOWLEDGE/` out of ordinary feature work.
- Do not prune this clone; fetch with `--tags` and no `--prune`.

## AI cautions

- **Do not restate a fixed defect as current.** Three of the previous baseline's "known defect"
  sections are now historical: the missing screen-state rule 5, the unbounded interface wait, and
  the failed-start leak. Their text is retained in `modules/*` **as history, labelled as such**.
- **Do not downgrade an invariant because a gate is red.** The parity audit is red at this baseline
  for a reason that has nothing to do with the invariants above.
- **Do not promote `VERIFIED_SOURCE` to `VERIFIED_UNIT`.** The screen-state and interface-startup
  packages cannot be built on this host.
