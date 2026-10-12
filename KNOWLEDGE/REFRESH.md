# sing-box-for-apple Knowledge Refresh Protocol

> Repository: `Piggy-Cat-bit-shadow/sing-box-for-apple`
>
> Intended destination: `KNOWLEDGE/REFRESH.md`
>
> Purpose: define the long-term procedure for refreshing the Apple client's AI knowledge base while correctly handling live product lines, frozen audit lines, upstream references, Hako design provenance, NetworkExtension lifecycle, device evidence, and branch/tag history.

---

# 1. Why Apple refresh is special

This repository may contain multiple conceptually different lines:

```text
live product line
frozen audit/knowledge line
upstream reference line
historical integration lines
archive tags
Hako design/reference lines
```

Therefore a simple:

```bash
git log <baseline>..HEAD
```

is **not enough**.

A knowledge refresh must first answer:

```text
Which line is the shipping product?
Which line does the existing knowledge describe?
Which refs are historical only?
Which design/reference SHAs are not product ancestry?
```

Only after that may the knowledge baseline move.

---

# 2. Knowledge model

Use:

```text
Knowledge Baseline + Product-Line Git Delta = Current AI Context
```

The knowledge base is allowed to be stale.

It must never pretend to describe live `main` if it does not.

Normal feature work does not require updating `KNOWLEDGE/`.

---

# 3. Source-of-truth hierarchy

Use:

```text
1. Current source / Xcode project / entitlements
2. Git refs / branch topology / diffs / tags
3. Executable tests and audit scripts
4. Build / simulator / device / TestFlight evidence
5. Upstream Apple source where relevant
6. KNOWLEDGE/
7. Historical reports / pending docs / archived notes
```

Source and Git override stale docs.

---

# 4. First determine the product line

Before reading modules, determine dynamically:

```text
remote default branch
current origin/main
current origin/dev
all remote heads
important archive tags
current checked-out line
knowledge Production Baseline line
```

Recommended commands:

```bash
git remote -v
git ls-remote --symref origin HEAD
git ls-remote --heads origin
git show-ref --tags
git branch -a --contains <baseline>
```

Do not rely on hardcoded "63 commits ahead" or old branch names.

Those are snapshots.

The refresh protocol must derive current values.

---

# 5. Distinguish five different baselines

Apple knowledge may need all of these:

```text
Production implementation baseline
Knowledge line HEAD
Live product line HEAD
Upstream Apple baseline
Hako design/reference baseline
```

They are not interchangeable.

Also keep separate:

```text
parent/core gitlink
libbox/core artifact identity
Runestone gitlink
release/TestFlight state
```

---

# 6. Delta calculation: two dimensions

Always calculate:

## A. Knowledge-line delta

```bash
git log --oneline <production-baseline>..HEAD
git diff --stat <production-baseline>..HEAD
```

This tells whether the line carrying the knowledge moved.

## B. Product-line delta

If the knowledge line is not the live product line:

```bash
git log --oneline HEAD..origin/main
git diff --stat HEAD..origin/main
```

or compare the exact relevant refs.

The most dangerous failure mode is:

```text
knowledge-line delta = docs only
therefore assume product is current
```

This is invalid if live `main` advanced elsewhere.

---

# 7. Re-baseline vs refresh

These are different operations.

## Refresh on same product line

Use when knowledge already describes the live product line and only newer commits need to be absorbed.

## Re-baseline

Use when knowledge describes a frozen/historical line but the shipping product is another line.

Re-baselining requires:

```text
lineage audit
product ownership audit
commit/diff reconciliation
fix absorption review
tests/evidence review
new Production Baseline
```

Do not "re-baseline" by changing only a SHA in `BASELINE.md`.

---

# 8. Apple change taxonomy

Use semantic types:

```text
FEATURE
FIX
HARDENING
UI
DESIGN-PRESERVATION
LIFECYCLE
NETWORK
NETWORK-EXTENSION
SCREEN-STATE
SUBSCRIPTION
PROFILE
IMPORT
LOCALIZATION
BRANDING
COMPAT
PERF
TEST
AUDIT
CI
BUILD
SIGNING
TESTFLIGHT
RELEASE
DOC
REPOSITORY-HYGIENE
```

Provenance:

```text
FORK-OWNED
UPSTREAM-INHERITED
UPSTREAM-ABSORBED
DESIGN-BASELINE-DERIVED
ADAPTED
CORE-COORDINATED
SUPERSEDED
ARCHIVE-ONLY
UNKNOWN
```

---

# 9. Commit organization

Do not document Apple history as a flat commit list.

Group by evolution theme:

```md
## Screen-state delivery semantics

Initial problem:
...

Evolution:
- ...
- ...
- ...

Rejected/superseded attempts:
...

Final behavior:
...

Why:
...

Device/test evidence:
...

AI caution:
...
```

Apple has many iterative fixes; semantic consolidation is essential.

---

# 10. Product ownership refresh rules

Re-verify:

```text
iPhone UI ownership
iPad UI ownership
macOS UI ownership
shared business layer
NetworkExtension ownership
tvOS/out-of-scope
```

Do not infer product ownership from size class.

Verify the actual routing gate.

If the product policy is still:

```text
iPhone -> Hako
iPad/macOS -> upstream UI
```

record the exact ownership mechanism and evidence.

---

# 11. Hako refresh rules

Distinguish:

```text
shipping Hako implementation
Hako design baseline
old Hako freeze tag
migration/generated files
fork-owned adapters
upstream UI
```

Do not treat historical freeze tags as "must equal" baselines unless current product policy explicitly says so.

For changed Hako code determine:

```text
visual/design change
bug fix preserving design
migration regeneration
localization change
navigation/presentation fix
shared-layer change
```

Do not let bug fixes become accidental redesigns.

---

# 12. Hako provenance refresh rules

For each important Hako area record:

```text
original design source
fork port/reference SHA
current shipping file
whether generated/mechanically ported
whether manually maintained
parity evidence
```

Do not claim pixel parity from static token/byte parity.

Evidence levels must remain explicit.

---

# 13. Shared business layer refresh rules

For changes under shared libraries/business logic, determine:

```text
used by iPhone?
used by iPad?
used by macOS?
upstream-owned?
fork-modified?
```

Avoid accidentally documenting a phone-only assumption as cross-platform truth.

---

# 14. NetworkExtension refresh rules

Inspect:

```text
ExtensionProvider
PacketTunnelProvider
start/stop/reload
command server
failed-start unwind
teardown fencing
identity checks
serialization
locks
monitor lifecycle
```

Questions:

```text
Who owns lifecycle?
What can run concurrently?
Where are suspension points?
What state can be superseded?
What stale callback paths exist?
```

Document why each guard exists.

---

# 15. ScreenState refresh rules

This is a high-risk subsystem.

Always inspect:

```text
event vs snapshot
edge vs level
screen state
lock state
sleep anchor
resume
resync
generation
registration/cancel
stale callback
observer restart
```

Do not collapse:

```text
snapshot
event
level
edge
```

into one concept.

If a change affects core entry points, inspect the corresponding sing-box core contract.

---

# 16. ScreenState evidence rules

Separate:

```text
pure policy unit test
Darwin adapter test
static audit
simulator
physical iPhone
physical iPad
physical Mac
```

A physical iPhone PASS does not prove iPad/macOS behavior.

If a historical fix was rejected by device evidence, preserve the rejection as an AI caution if future engineers might repeat it.

---

# 17. NWPathMonitor / networking refresh rules

Inspect:

```text
monitor creation
currentPath seed
first update
timeout/bound
generation
reset
late callback
airplane mode
Wi-Fi/cellular recovery
interface publication
```

Distinguish:

```text
legal no-network state
startup failure
delayed update
stale callback
```

Never reintroduce an unbounded wait.

---

# 18. Import / profile refresh rules

Inspect:

```text
manual create
file import
QR import
Form/FormView nesting
navigation destination
sheet presentation
success routing
profile persistence
```

Preserve presentation rules that prevent SwiftUI form embedding bugs.

Do not document generic SwiftUI structure unless it encodes a known product trap.

---

# 19. Subscription refresh rules

Inspect:

```text
subscription fetch
usage metadata
remaining traffic
expiry
refresh
profile linkage
shared behavior across platforms
```

Separate UI display from underlying data semantics.

---

# 20. Localization refresh rules

For changed strings verify:

```text
catalog key exists
exact key spelling
upstream reusable key
fork-only key
supported locales
shouldTranslate=false
```

Do not create duplicate translations when an upstream key already exists.

Do not remove locales from a shared catalog merely because one product only supports a subset.

---

# 21. Branding refresh rules

Separate:

```text
visible app name
bundle identifier
App Group
entitlements
release identity
icon/assets
UI wording
```

A branding overlay must not silently alter signing identity.

---

# 22. Xcode target refresh rules

When project settings change, inspect:

```text
SFI
SFM
PacketTunnel
SystemExtension
widgets/extensions
shared frameworks
Runestone
deployment targets
build phases
package/plugin validation
```

Record only changes with long-term architectural/release impact.

---

# 23. Signing / entitlement refresh rules

Treat as high-risk.

Verify:

```text
bundle IDs
App Groups
entitlements
provisioning assumptions
system extension identifiers
packet tunnel identifiers
```

Do not change these during a knowledge refresh.

Knowledge refresh only records current contracts.

---

# 24. Parent/core linkage refresh rules

If the parent sing-box repository pins Apple source or verified SHA:

```text
Apple repo SHA
parent gitlink
VERIFIED_APPLE_SHA
libbox/core revision
```

may all differ conceptually.

Never collapse them.

If current parent state cannot be checked from this repository:

```text
EXTERNAL_CHECK_REQUIRED
```

---

# 25. Runestone / submodule refresh rules

Track:

```text
gitlink SHA
whether initialized
whether product source depends on exact version
```

Do not infer submodule content if not initialized.

---

# 26. Build evidence levels

Use:

```text
VERIFIED_SOURCE
VERIFIED_STATIC
VERIFIED_UNIT
VERIFIED_BUILD
VERIFIED_SIMULATOR
VERIFIED_DEVICE
VERIFIED_GIT
VERIFIED_CI
VERIFIED_ARTIFACT
INFERRED
UNVERIFIED
UNKNOWN
BLOCKED_BY_ENVIRONMENT
NEEDS_DEVICE
EXTERNAL_CHECK_REQUIRED
```

Never promote:

```text
build -> runtime
simulator -> device
static parity -> visual parity
iPhone -> iPad/macOS
```

---

# 27. Test/audit refresh rules

For every important audit script record:

```text
what it checks
what it does not check
negative control
environment requirements
failure meaning
```

Do not trust report summaries if the script contract says something narrower.

---

# 28. Device acceptance refresh rules

When device evidence changes, record:

```text
device model
OS version
test scenario
duration
result
which subsystem it proves
```

Avoid vague:

```text
"tested on device"
```

---

# 29. TestFlight refresh rules

Separate:

```text
archive success
export success
upload success
processing success
internal TestFlight availability
external/public testing review
public link availability
```

Do not infer public testing approval from successful upload.

---

# 30. Branch/tag/archive refresh rules

Apple history can be complex.

For each refresh determine:

```text
canonical product branch
upstream reference branch
active development branches
archive tags
design tags
historical integration tags
```

Use tags as historical/provenance anchors, not automatically as current product truth.

---

# 31. Never prune historical refs casually

If current repository history depends on local/archive refs:

```text
git fetch --prune
git remote prune
aggressive git gc
```

may remove useful archaeology pointers.

Before changing this policy, verify which refs are preserved remotely by tags.

Do not encode an old clone-specific warning forever if the repository topology later changes; re-audit it during refresh.

---

# 32. Historical docs classification

Classify:

```text
KEEP
ABSORB
ARCHIVE
DELETE
```

Especially review:

```text
round reports
handoff reports
device acceptance
branch inventory
convergence reports
pending docs
migration reports
```

Historical evidence should not compete with current KNOWLEDGE.

---

# 33. Hard invariant refresh

Keep an invariant only if it is supported by:

```text
product ownership
platform constraint
signing/entitlement contract
verified lifecycle/concurrency defect
design freeze/preservation contract
ABI/pin requirement
release integrity
```

Otherwise downgrade to convention.

---

# 34. AI cautions

Preserve high-value warnings such as:

```text
Do not use size class as product ownership.
Do not treat a snapshot as a sleep edge.
Do not wait indefinitely for NWPathMonitor's first update.
Do not treat static Hako parity as pixel parity.
Do not assume iPhone evidence proves iPad/macOS.
Do not alter shared localization catalogs as if they were phone-only.
Do not confuse design baseline, shipping source, parent pin, and upstream pin.
```

---

# 35. COMMIT-INDEX refresh

Include commits that explain:

```text
shipping product behavior
major lifecycle fixes
design-preservation decisions
critical UI migration
platform ownership
build/signing/release contracts
tests that protect invariants
```

Do not index every docs/report commit.

---

# 36. ACCEPTANCE refresh

Every important requirement should include:

```text
Requirement
Platform
Subsystem
Evidence level
Current status
Re-check command
Device/environment requirement
```

---

# 37. BASELINE refresh

If refreshing the live product line:

```text
new Production Baseline = newest production SHA fully described
```

If re-baselining from a frozen audit line to live `main`, explicitly rewrite baseline semantics and product-line mapping.

Do not simply replace one SHA.

---

# 38. README / AGENTS refresh

Keep `AGENTS.md` short.

It should direct AI to:

```text
KNOWLEDGE/README.md
KNOWLEDGE/BASELINE.md
KNOWLEDGE/REFRESH.md
```

Avoid duplicating volatile ahead/behind counts or exact live branch SHAs in many places.

Prefer dynamic commands.

---

# 39. Small same-line refresh

For a few product commits:

```text
1. Read BASELINE
2. Verify current product line
3. Inspect baseline..product HEAD
4. Map changed modules
5. Read only affected source/history/tests
6. Update modules
7. Update acceptance/invariants/index
8. Move baseline
```

---

# 40. Full re-baseline workflow

Use when current knowledge is on a frozen line but live product moved elsewhere.

Recommended multi-agent roles:

```text
A. Branch/ref topology
B. Platform ownership
C. Hako/design provenance
D. Shared business layer
E. NetworkExtension
F. ScreenState
G. Networking/NWPath
H. Subscription/profile/import
I. Localization/branding
J. Xcode/signing/TestFlight
K. Tests/audits/device evidence
L. Historical docs
M. Knowledge critic
```

Master agent must reconcile:

```text
old knowledge
old line
live product
upstream
design references
```

before moving baseline.

---

# 41. When NOT to move baseline

Do not move if:

```text
shipping product line is ambiguous
major platform ownership is unresolved
ScreenState/NE behavior conflicts with tests
important device evidence is falsely claimed
parent/core linkage is unresolved where required
cross-file consistency fails
```

Keep the old baseline and mark refresh incomplete.

---

# 42. Final refresh report

Produce one report containing:

```text
Old Production Baseline
New Production Baseline
Knowledge line
Live product line
Upstream baseline
Hako/design baseline
Parent/core linkage status
Changed subsystems
Commits coarse-scanned
Commits deep-read
Modules updated
Invariants changed
Evidence changes
Device gaps
Historical docs disposition
```

End with:

```text
KNOWLEDGE_REFRESH = COMPLETE / INCOMPLETE

OLD_PRODUCTION_BASELINE = <sha>
NEW_PRODUCTION_BASELINE = <sha>

LIVE_PRODUCT_LINE_VERIFIED = YES / NO
UPSTREAM_RELATIONSHIP_VERIFIED = YES / NO
HAKO_PROVENANCE_VERIFIED = YES / NO
PLATFORM_OWNERSHIP_REAUDITED = YES / NO
NETWORK_EXTENSION_REAUDITED = YES / NO
SCREEN_STATE_REAUDITED = YES / NO
ACCEPTANCE_UPDATED = YES / NO
INVARIANTS_REAUDITED = YES / NO
CROSS_FILE_CONSISTENCY = PASS / FAIL
FUTURE_AI_INCREMENTAL_READ = PASS / FAIL

PRODUCTION_CODE_CHANGED_BY_REFRESH = NO
UI_CHANGED_BY_REFRESH = NO
RUNTIME_BEHAVIOR_CHANGED_BY_REFRESH = NO
GIT_HISTORY_REWRITTEN = NO
```

---

# 43. Final principle

The Apple knowledge base must preserve:

> **which line actually ships, which UI each platform owns, how Hako relates to upstream and design baselines, why NE/ScreenState guards exist, what evidence truly proves, and how to avoid confusing historical audit lines with current product reality.**

Everything else belongs in source and Git.
