# Hard invariants and conventions

## Hard invariants

- iPhone Hako, iPad official UI, and macOS official UI are product ownership boundaries. Device idiom—not `#if os(iOS)` or size class—selects the phone experience.
- Hako is reachable only through the dedicated phone route; upstream-reachable shared pages may not depend on Hako symbols.
- The Hako freeze tag is provenance, not a license to overwrite later adapted source. Generated/ported files require the migration authorization checks.
- One shared model/environment injection serves both presentation routes; do not fork state just to change visual ownership.
- Bundle identifiers, App Groups, entitlements, signing, URL/UTI identity, `Variant.applicationName`, Runestone gitlink, and Libbox ABI/source are release contracts. Branding is a visible overlay only.
- Extension service start/reload/stop is serialized; observer callbacks must be fenced at teardown. See `modules/network-extension.md`.

## Current conventions

- Make narrow shared changes when behavior must be common; make phone-only changes inside Hako-owned paths.
- Keep upstream UI byte-identical where the audit names it, and register/review any intentional shared upstream deviation.
- Treat `docs/pending/` and round handoffs as frozen evidence, not instructions for current edits.
