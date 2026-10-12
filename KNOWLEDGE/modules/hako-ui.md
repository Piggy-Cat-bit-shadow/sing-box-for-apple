# Hako UI, design provenance and the generator hazard

## Ownership

`ApplicationLibrary/Views/HakoStyle/` is the iPhone-only presentation boundary — 54
Swift files. `HakoPageContent` is the primary route seam, and
`SFI/HakoPhoneRootView.swift` is the only entry point. The whole Hako presentation is
reachable from exactly one call site, the page switch in `HakoPageContent`.

`hakoTitle` and `hakoPrimary` live in two small extensions inside the namespace rather
than in the shared `NavigationPage`, so that the iPad sidebar, the iPad tab bar and the
Mac sidebar keep upstream's vocabulary.

## Three provenance references that are not interchangeable

| Reference | SHA | What it is | Resolvable here? |
|---|---|---|---|
| `hako-ui` | `c1935cff77246f97498400f5a0a7f430cfabbd55` | the fork's own **port reference line**; what the parity/migration audits compare against | yes |
| `Hako-Client` (GPL-3.0, `TokenPLS/Hako-Client`) | `62aa2f2fedffd46c245d5a87d2258c24bef3cd82` | the **original visual design source** the design system was extracted from | **no** — different repository |
| `iphone-hako-ui-freeze-v1` | annotated tag → `fc7f77b82a7ca432294addfa001fcacfd5776223` | a reviewed freeze of the *old* phone surface | yes, but see below |

Files whose headers name `Hako-Client`/`62aa2f2f` — i.e. files carrying **extracted
design**, not ported structure: `HakoTheme`, `HakoSurface`, `HakoRow`, `HakoCard`,
`HakoStatus`, `HakoEmptyState`, `HakoHomeView`, `HakoPrimaryShell`, `HakoData`.

Files whose provenance is recorded against `hako-ui@c1935cf`: the migration and parity
tooling (`audit_hako_lossless_parity.py`, `check_generated_headers.py`,
`check_platform_structure.py`, `original_type_names.py`).

### AI caution: the freeze tag is not a regression baseline

`iphone-hako-ui-freeze-v1` points at a commit on the abandoned `hako-ui` line and is
**not an ancestor of HEAD**. The product branch was re-founded from `upstream/dev`
(`089d35e6`) and deliberately diverges from the tag — for example `SFI/MainView.swift`
at HEAD is byte-identical to upstream's and differs from the tag's version (`0297c8e`).
The tag's own guard script path does not exist at HEAD, and its `FIXED_UPSTREAM_SHA`
(`3cc0835f…`) is absent from this object store, so the guard cannot run here at all.

Use the tag as provenance for a **superseded** surface. Never as a "current code must
equal this" comparison.

## The generator hazard — read this before running any migration script

The largest single source of churn in this repository's history is one defect class:
**the migration generators collapse platform conditionals.** Roughly two dozen commits
in the history say "restore the guards" for this reason.

Mechanism, verified at HEAD:

- `scripts/dev/swift_directives.py` `resolve()` deletes `#if`/`#endif` pairs and keeps
  one branch.
- `port_hako_components.py`, `port_hako_secondary.py`, `port_tools_and_more.py` **all
  still call `resolve()` at HEAD**.
- The shared-target gate that prevents this — `swift_directives.py` `preserve()` — is
  used by **only one** generator (`migrate_secondary_page.py`).

Consequences that have actually happened, and are recorded in the repository:

- `MIGRATION-SAFETY-CONTRACT.md` documents that `port_tools_and_more.py --regenerate`
  reverted every restored `#if !os(tvOS)` guard and reintroduced ungated
  `import UIKit`, **with exit status 0**.
- Until `fd27efe`, the generators silently overwrote files rather than refusing.

So a generator can return success while making the tree less correct. The rules that
follow:

1. **Never re-run a generator over a file that has been manually repaired** without
   first diffing the generator's output against the current file.
2. A generated candidate is a *candidate*. The explicit replacement/hash authorization
   in the tooling exists to stop a regeneration from reversing later manual repairs.
3. `#if` guards in `HakoStyle/*.swift` are not decoration. `ApplicationLibrary` is built
   for tvOS as well, so all 54 Hako files must compile on a platform that never routes
   to them. That is why the platform-guard gates exist.
4. Prefer `migrate_secondary_page.py` (which uses `preserve()`) over the other port
   scripts when regenerating, and never regenerate a whole directory.

## Generated vs hand-written

About 32 of the 54 files carry a header naming
`scripts/dev/migrate_secondary_page.py` and saying "re-run that rather than editing
here". Other headers name `restore_file_level_guards.py`, `port_tools_and_more.py`,
`port_hako_pages.py`, `port_hako_components.py`, `restore_picker_guards.py`,
`make_hako_profile_picker.py`.

One header names `scripts/dev/restore_terminal_guards.py`, **which does not exist** in
the checkout. That file's provenance line cannot be re-run. Treat it as hand-maintained.

`check_generated_headers.py` verifies that every generated header names a source path
that exists at the pinned original; run it after any regeneration.

## Evidence boundary

| Tool | Establishes | Does not establish |
|---|---|---|
| `audit_hako_lossless_parity.py` | designated UI tokens and byte-parity for the 9 design-system files; 6 of 6 pages compared | pixel parity, layout, touch behaviour |
| `audit_apple_ui_boundary.py` | routing, isolation, upstream-file parity, project membership, branding | compilation, rendering |
| `check_hako_macos_parse.py` / `gate_hako_platform_imports.py` | platform-guard decisions for **ios and macos** | anything about tvOS (no condition table) |
| `dup_module_scope.py` | candidate duplicate module-scope names | whether they are defects — see the caution below |

### AI caution: a non-zero exit is not automatically a defect

Two gates are red at HEAD **by decision**, not by regression:

- `check_hako_macos_parse.py --platform tvos` — exits 1 with 54 files `NOT CHECKED`,
  because `swift_directives.PLATFORMS` has no `tvos` entry.
- `report_hako_platform_api.py --check` / `gate_hako_platform_imports.py --check` —
  exit 1 with 61 `undecidable on tvos` entries for the same reason.

Every one of the 61 sits inside a region tvOS provably never compiles. This is
**accepted because the tvOS *UI* is out of scope**, and it is recorded in
`docs/HAKO-ROUND9-REMAINING-FAILURES.md`. `--platform ios` is green
(`checked=54 errors=0 undecidable=0`). Do not "fix" these by registering tvOS as a
platform unless the scope decision changes.

Separately, `dup_module_scope.py` returns 1 and prints 18 "duplicate" declarations that
are **all legal** — `private extension URL { func formattedSize }` in two files,
`extension View` by design, and extensions of shared types. Its own docstring says it is
"evidence, not a gate". The enforced gate on the same tree
(`audit_apple_ui_boundary.py` check `shared-declaration-duplicates`) **passes**. A future
reader who greps for a non-zero exit will find a phantom defect here.

`docs/APPLE-HAKO-VISUAL-ACCEPTANCE.md` holds the hardware checklist and remains
`NEEDS_DEVICE`.
