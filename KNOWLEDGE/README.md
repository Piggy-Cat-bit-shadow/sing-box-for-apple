# Jiejiebox Apple knowledge base

**Knowledge Baseline + Git Delta = Current AI Context.** This is a high-cost reconstruction cache, not a substitute for source.

Baseline: `f4a98590e9edaefc4a231b7f30d5b81a30917b66` (2026-10-12). Read `BASELINE.md`, inspect `baseline..HEAD`, then use only relevant modules.

Source-of-truth order: current source/project/scripts and Git history; fixed refs/tags; this knowledge; current operational docs; historical reports and `docs/pending/` last. `VERIFIED_*` evidence never implies a stronger level.

Modules:

- `PROJECT.md`, `ARCHITECTURE.md`, `INVARIANTS.md`: scope, product boundary, and non-negotiable contracts.
- `modules/platform-ownership.md`, `hako-ui.md`: platform and visual provenance.
- `modules/shared-business-layer.md`, `network-extension.md`, `screen-state.md`, `networking.md`, `subscription-profile.md`: behavior and lifecycle.
- `modules/localization-branding.md`, `build-signing-testflight.md`, `tests-audits.md`, `repository-history.md`: identity, operational, and provenance material.
- `ACCEPTANCE.md`, `COMMIT-INDEX.md`: evidence ladder and commit navigation.

Evidence vocabulary: `VERIFIED_SOURCE`, `VERIFIED_STATIC`, `VERIFIED_UNIT`, `VERIFIED_BUILD`, `VERIFIED_SIMULATOR`, `VERIFIED_DEVICE`, `INFERRED`, `UNVERIFIED`, `UNKNOWN`, `BLOCKED_BY_ENVIRONMENT`, `NEEDS_DEVICE`, `EXTERNAL-CHECK-REQUIRED`. Static token/byte parity is not pixel parity; a build is not runtime evidence; a simulator is not a physical device.

Refresh only when asked: resolve current refs, audit the changed domains, update the baseline and affected modules, and record evidence rather than copying claims from reports.
