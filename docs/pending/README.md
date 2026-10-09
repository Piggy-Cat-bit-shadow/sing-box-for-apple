# Pending fork assets

Nothing in this directory is compiled, linked or run. It is a **holding area** for work from the
fork's `hako-ui` and `ipad-upstream-ui` branches that the integration branch deliberately did not
take, kept here rather than deleted so that the work is not lost and the reason it could not be
taken is written down next to it.

Read this file before using anything here. Every item below is either incomplete, unverifiable in
this environment, or anchored to a baseline that has since moved.

---

## Why these are not on the integration branch

The integration branch was cut from `upstream/dev` @ `089d35e` and the rule for taking something
from the fork is: it must be **verifiable in this environment** or **provably self-contained**.
Everything here failed one of those two tests.

---

## `HakoHomeView.swift`

The fork's Home page — the Hako-styled first screen: a header carrying the configuration's name and
the one control that starts it, then the mode card, shortcuts, traffic and runtime cards.

**Why it is here.** It is the one file in `ApplicationLibrary/Views/HakoStyle/` that is *not*
self-contained. It reads five symbols through initialisers that only exist in the fork's modified
copies of those files:

| Symbol | What `HakoHomeView` expects | What upstream has |
|---|---|---|
| `StartStopButton` | `init(showsRuntimeDuration:isCompact:)` plus a trailing closure | `init(showsRuntimeDuration: Bool = false)` — **FACT** |
| `HTTPProxyCard` | a fork initialiser | `init(systemProxyAvailable:systemProxyEnabled:onToggle:)` — **FACT** |
| `ProfilePickerSheet` | the fork's rewritten sheet | upstream's own, which does not carry the quota row |
| `ProfilePreview` | `subscriptionInfo` | present on this branch (ported) — satisfied |
| `DashboardCardConfiguration` | present | present — satisfied |

Taking it as-is would not compile. Taking the fork's versions of those five would mean replacing
five shared files — the exact pollution this refactor removed.

**What taking it would need.** For each of the five, either a Hako-owned variant under
`ApplicationLibrary/Views/HakoStyle/` (the page-factory route this branch established) or a Hako
initialiser added to a shared file with the reviewed-list entry that implies. The first is the
consistent choice and is roughly 1,200 lines of port plus the component work.

**What it costs to leave it here.** The phone's first screen is upstream's card grid instead of
Hako's page. No function is lost — every control on it is reachable — but the visual is not the
Hako one. This is named as a known gap in `docs/APPLE-ARCHITECTURE-AUDIT.md` §6.3 and in the final
report; it is not described as done.

---

## `HakoNavigationUITests.swift`, `HakoSnapshotUITests.swift`

The fork's two UI-test bundles (588 and 706 lines).

**Why they are here.** They drive the Hako page bodies through accessibility identifiers that only
exist once the page bodies are migrated. Landing them now would add a test bundle that fails on
every case for a reason unrelated to the app, which is worse than not having it: a red suite that
is expected to be red stops being read.

They are also not runnable in this environment at all — they need a booted simulator, and the
project's `SFIUITests` target already requires one.

**What taking them would need.** Migrate the page bodies first, then land these **in the same
commit**, so the identifiers they look for and the views that publish them arrive together.

---

## `check-hako-primary-route.swift`, `check-hako-primary-route.sh`

A harness that links `ApplicationLibrary` and exercises `HakoPrimaryRoute` and
`HakoPrimaryChildArmer` — the two pure types the phone shell's page mapping is built from.

**Why it is here.** The fork's own script records its status as `BLOCKED_BY_ENVIRONMENT`:

```
plcrashreporter/Resources/CrashReporter.modulemap:2:19:
  error: umbrella header 'CrashReporter.h' not found
```

It needs a built macOS framework, which needs Xcode, which needs a macOS slice of
`Libbox.xcframework` — which this repository does not contain at all (`.gitignore` excludes it).

**What is worth keeping from it.** The type under test — `HakoPrimaryRoute` /
`HakoPrimaryChildArmer` — **is** on the integration branch, extracted as pure values precisely so
it can be checked without a view. The assertions in this file are the specification for those
types and should be moved into the subscription-usage package's style (a `swift test` target with
no simulator) rather than a framework-linking harness, at which point they run anywhere Swift runs.

---

## `check-iphone-hako-freeze.sh`, `test-iphone-hako-freeze.sh`

The fork's freeze guard and its 16-scenario negative suite. The guard pins a set of HakoStyle blobs
and `SFI/HakoPhoneRootView.swift` to the tag `iphone-hako-ui-freeze-v1` (`fc7f77b`) and fails if any
of them moves.

**Why they are here.** The pin is wrong for this branch, and the reason is the one the task brief
warned about: `fc7f77b` is an **ancestor** of `c1935cf` with exactly two commits between them, and
the newer of the two is the remaining-quota row. A guard pinned to `fc7f77b` would require this
branch to roll that feature back.

**What replaced it.** A content baseline rather than a byte baseline:
`scripts/dev/audit_apple_ui_boundary.py` freezes the **boundary** — no Hako symbol reachable from
upstream's pages, upstream's files byte-identical, the reviewed exceptions listed with reasons.
That is stricter than the freeze tag for the property that matters (a page cannot quietly join the
fork's presentation) and does not fight upstream when upstream edits a shared page.

**What is worth keeping from it.** The negative suite's own two recorded self-inflicted bugs are
good evidence for how to write one: it once graded a stale copy of the guard, and one scenario's
damage poisoned the scenarios after it. `scripts/dev/test_audit_apple_ui_boundary.py` inherited
both lessons.

---

## `HAKO-OWNERSHIP.md`

The fork's 616-line ownership inventory, produced on `hako-ui` at `24bd463`.

**Why it is here.** It is a snapshot of a *different tree*. It classifies 510 paths drawn from
`hako-ui`, `ipad-upstream-ui` and `fix/libbox-stringbox-callsites`, and the integration branch has
a different file set — different `HakoStyle` contents, a different `SFI/`, and upstream's pages
restored. Its counts and its per-file ownership verdicts do not describe this branch.

It is kept because its **method** is sound and its finding about the gitlink is a real detail
(`Frameworks/Runestone` is a `160000` entry, so a blob-equality test cannot classify it — it lands
in "OTHER" because a gitlink's object id is a commit).

**Do not treat it as current architecture.** The current statement of ownership is the root
`README.md` and `docs/APPLE-ARCHITECTURE-AUDIT.md`.
