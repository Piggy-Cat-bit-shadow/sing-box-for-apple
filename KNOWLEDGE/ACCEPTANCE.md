# Acceptance and evidence

## Read this before any evidence claim

This knowledge base describes a **frozen audit line**. Every result below is a result
about that line, not about the shipping product. The fork's default branch
`origin/main` is 63 commits ahead and has fixed defects still present here — see
`BASELINE.md`.

Gate counts quoted in `docs/*` are historical and differ for the same command
(9 → 12 → 15 → 18 → 19 across this history; `HAKO-ROUND9-HANDOFF.md` says 19 in one
place and 18 in another). Trust `FAIL` and `UNKNOWN`, not `PASS n`, and never edit code
to make a count match a document.

## Environment

| Capability | Status here |
|---|---|
| Xcode / macOS | absent — no build, archive or export |
| Physical iPhone / iPad / Mac | **absent — every device claim is `NEEDS_DEVICE`** |
| `Libbox.xcframework` | absent and gitignored (`.gitignore:2`) — **nothing can link** |
| Signing identities / profiles | absent |
| CI | **none** — there is no `.github/` in this repository at all |
| Python | a working CPython 3.12 is available through the harness runtime; `python` on `PATH` is a 0-byte Windows Store stub that exits 9009 |
| Swift | a 6.3.3 toolchain is installed on this host, but see below |

The Stage-1 report's statement that "`python` is unavailable" is a **misdiagnosis of the
PATH stub**, not a property of the machine: the documented static gate runs and passes —
see the executed results below.

SwiftPM packages are **not** runnable here regardless of toolchain: 10 of the test-package
sources are git symlinks (mode `120000`) which materialise as one-line text files on a
checkout without symlink support, so `swift test` fails at compile.
`scripts/link-test-sources.sh` would fix that but needs `bash`, `ln` and a POSIX Python.

## Executed at this review (2026-10-12)

| Command | Result | Level |
|---|---|---|
| `audit_apple_ui_boundary.py --root <repo> --upstream-ref 089d35e6…` | `PASS 19 FAIL 0 UNKNOWN 0 UNDECIDABLE 0`, exit 0 | `VERIFIED_STATIC` |
| `audit_hako_lossless_parity.py --root <repo>` | 6 of 6 pages compared, design system 9 of 9, lost UI tokens 0, verdict `STATIC_LOSSLESS_PORT_READY_FOR_APPLE_ACCEPTANCE`, exit 0 | `VERIFIED_STATIC` |
| `test_fail_closed_exit_codes.py` | 3 passed, 0 failed | `VERIFIED_STATIC` |
| `test_platform_gates.py` | 0 failing cases of 19 | `VERIFIED_STATIC` |
| `test_audit_reverse_routing.py` | 29 cases executed, 1 skipped, every case failed the audit as designed | `VERIFIED_STATIC` |
| `check_generated_headers.py`, `check_platform_structure.py`, `check_swift_structure.py`, `check_hako_macos_parse.py --platform ios`, `check_swift_test_sources.py`, `dup_module_scope.py`, `check_commit_messages.py` | see `modules/tests-audits.md` | `VERIFIED_STATIC` |

Re-run recipes and the caveats that make a run meaningless are in
`modules/tests-audits.md`.

## Required before any claim of release readiness

Run the documented audits **with `--strict` and `--upstream-ref`**; build each relevant
target with the correct Libbox artifact and signing on macOS; exercise iPhone, iPad and
macOS **separately**; validate tunnel lifecycle on hardware; perform archive/export/upload
under authorized credentials.

Upload success does not establish public TestFlight review approval, and **no release
baseline exists**: no archive or upload has been run or verified on this line.

## Claims that must not be upgraded

| Claim | Correct status |
|---|---|
| Swift compilation of any target | `BLOCKED_BY_ENVIRONMENT` — no `Libbox.xcframework` |
| iPhone Hako UI looks/behaves correctly | `NEEDS_DEVICE` — and no device is named anywhere in the repo |
| iPad official UI, incl. Split View / Slide Over / Stage Manager | `NEEDS_DEVICE` |
| macOS official UI | `NEEDS_DEVICE` |
| NetworkExtension tunnel lifecycle on hardware | `NEEDS_DEVICE` |
| ScreenState sleep/resume against real Darwin notifications | `NEEDS_DEVICE` — the two notification names are non-public API and delivery per iOS release is `EXTERNAL_CHECK_REQUIRED` |
| "Static parity" ⇒ pixel parity | **never** — the parity audit compares token sets and 9 byte-identical files |
| A green UI test run ⇒ correct data path | **never** — the suites launch with a screenshot-mode fixture that substitutes data in 23 files |
| `ScreenStatePolicyTests` is green | **false at this baseline** — 8 of 9; see `modules/screen-state.md` |
| iPad/macOS builds pass | `BLOCKED_BY_ENVIRONMENT` |
