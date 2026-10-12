# Acceptance and evidence

## Read this before any evidence claim

This knowledge base now describes the **live product line** (`main` @ `5cab4ec`), not a frozen
audit line. The previous revision of this file opened with the opposite warning; the lines were
merged and the warning is retired — see `BASELINE.md`.

Everything below was re-measured at this refresh on **2026-10-12**, against the working tree at
`331a676`. Where a result is unchanged from the previous baseline it is marked so, because
"unchanged" and "re-run" are different facts.

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

SwiftPM packages are **not** runnable here regardless of toolchain: the test-package sources are
git symlinks (mode `120000`, 11 of them) which materialise as one-line text files on a checkout
without symlink support, so `swift test` fails at compile. `scripts/link-test-sources.sh` would fix
that but needs `bash`, `ln` and a POSIX Python.

## Executed at this refresh (2026-10-12)

| Command | Result | Level |
|---|---|---|
| `audit_apple_ui_boundary.py --root <repo> --upstream-ref 089d35e6… --strict` | **`PASS 20 FAIL 0 UNKNOWN 0 UNDECIDABLE 0`**, exit 0 | `VERIFIED_STATIC` |
| `audit_hako_lossless_parity.py --root <repo>` | `coverage: 4 of 6 page(s)`, design system 9 of 9, **`lost UI tokens: 2`**, verdict `PARTIAL`, exit 1 | `VERIFIED_STATIC` — **red, and the reason is an intentional key rename, not a lost UI.** See `modules/tests-audits.md` |
| `check_hako_macos_parse.py --platform ios` | `checked=54 errors=0 undecidable=0`, exit 0 | `VERIFIED_STATIC` |
| `check_hako_macos_parse.py --platform tvos` | 54 files `NOT CHECKED`, exit 1 | `VERIFIED_STATIC` — red by decision, no tvOS condition table |
| `gate_hako_platform_imports.py --check` | `checked=54 errors=0 undecidable=62`, exit 1 | `VERIFIED_STATIC` — red by decision (was 61) |
| `report_hako_platform_api.py --check` | same counts, exit 1 | `VERIFIED_STATIC` — red by decision |
| `check_platform_structure.py` | exit 0 | `VERIFIED_STATIC` |
| `check_swift_structure.py ApplicationLibrary/Views/HakoStyle` | "all 1 target(s) structurally balanced", exit 0 | `VERIFIED_STATIC` |
| `check_generated_headers.py` | 33 portable headers, 0 naming a missing path, exit 0 | `VERIFIED_STATIC` |
| `dup_module_scope.py` | exit 0, 0 module-scope names in the shared tree | `VERIFIED_STATIC` — the previous baseline's 18-finding false red is gone |
| `check_commit_messages.py` | exit 0 **having scanned 0 commits** | **`BLOCKED_BY_ENVIRONMENT`** — proves nothing |
| `check_localization.py` | printed `PASS` over **0 of 56** files | **`BLOCKED_BY_ENVIRONMENT`** — a Windows false green |
| `test_fail_closed_exit_codes.py` | 3 passed | `VERIFIED_STATIC` |
| `test_platform_gates.py` | 0 failing of 19 cases | `VERIFIED_STATIC` |
| `test_audit_reverse_routing.py` | 29 cases, every case failed the audit as designed | `VERIFIED_STATIC` |

Re-run recipes and the caveats that make a run meaningless are in
`modules/tests-audits.md`. Two of the rows above **printed a pass while examining nothing**; read
the counts, not the exit status.

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
| **Airplane-mode startup no longer hangs** | `NEEDS_DEVICE` — the bound is `VERIFIED_SOURCE`, its *effect* is not. The off-device seam cannot be built here |
| **The screen-state policy is correct** | `VERIFIED_SOURCE` for the six rules. The suite reports 33 of 33 historically, but it **cannot be executed here** — do not quote it as `VERIFIED_UNIT` |
| ScreenState sleep/resume against real Darwin notifications | `NEEDS_DEVICE` — the two notification names are non-public API and delivery per iOS release is `EXTERNAL_CHECK_REQUIRED` |
| "Static parity" ⇒ pixel parity | **never** — the parity audit compares token sets and 9 byte-identical files |
| **The parity audit being red ⇒ the UI lost something** | **never** — at this baseline its 2 "lost tokens" are an intentional rename to upstream keys. See `modules/tests-audits.md` |
| A green gate ⇒ it checked anything | **never** — `check_localization.py` prints `PASS` over 0 files on Windows |
| A green UI test run ⇒ correct data path | **never** — the suites launch with a screenshot-mode fixture that substitutes data |
| iPad/macOS builds pass | `BLOCKED_BY_ENVIRONMENT` |

## What changed in this column, and what did not

Three rows moved because the underlying defect was fixed, and the previous revision's "must not be
upgraded" list would now be misleading if left alone:

- `ScreenStatePolicyTests` was **false (8 of 9)** and is now reported **33 of 33**; the policy class
  itself is 9 of 9 (`891c6cb`). *The claim that moves is the test result; the evidence level is
  still not `VERIFIED_UNIT`, because the suite cannot run here.*
- The unbounded interface wait is now **bounded** (`15d3a72`). *The level moves from "known defect"
  to `NEEDS_DEVICE` for the behaviour.*
- A failed `startTunnel` now **unwinds** (`8d06a99`). *The liveness outcome moves from
  `EXTERNAL_CHECK_REQUIRED` to `VERIFIED_SOURCE` for the code path; the runtime outcome is
  `NEEDS_DEVICE`.*
