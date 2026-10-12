# Localization and branding

## Scope and ownership

`Localizable.xcstrings` is the shared string catalog referenced by multiple Xcode targets. Hako UI consumes localized strings but does not own a second catalog. The product-facing display-name overlay is represented in Xcode build settings (`INFOPLIST_KEY_CFBundleDisplayName`). Measured at this baseline: **4** configurations carry the brand `Jiejiebox` (2 in `SFI`, 2 in `SFM`), **8** still carry `sing-box`, and 2 carry `Send with Taildrop` (the share extension's own affordance, not a product name). Eleven component plists are deliberately left unbranded.

Note that `Jiejiebox` is the same identity string the product uses elsewhere; it is **not** a
renamed protocol identity. See the invariant below.

`Library/Shared/Variant.swift` deliberately retains target identity values such as `SFI`/`SFM`/`SFT`. `HTTPClient` derives its User-Agent from that identity and `ExtensionProfile` uses it for the tunnel manager's localized description. Therefore display branding and protocol/runtime identity are separate concerns.

The boundary audit re-verified at this refresh that branding is an overlay and nothing else:
`PRODUCT_NAME` (42 occurrences), `PRODUCT_BUNDLE_IDENTIFIER` (42) and `BASE_PACKAGE_IDENTIFIER` (2)
are all **identical to `089d35e6`** — the upstream pin. `repository-hygiene` confirms the
Runestone gitlink is unchanged too.

## The localization defect this refresh absorbed

The previous baseline recorded three missing count strings (`%lld groups`, `%lld active`,
`%lld unread`) and "those labels ship English". The real defect was **much wider**, and the
mechanism is worth keeping because it is silent by construction:

> `String(localized:)` **answers a miss by returning the key it was given.** A near-miss variant
> is not an error anywhere: it compiles, it runs, and it renders English in every locale.

`467f8ea` found **112** such failures and fixed them in two ways:

- **Two exact-match reuses** — the fork's page asked for `"Remote control"` where the catalog has
  `"Remote Control"`, and `"Out of Memory Report"` where it has `"OOM Report"`. Both upstream keys
  already carried zh-Hans, so renaming the call site inherited the translation. *Nothing was
  translated twice.*
- **75 new keys** for strings only this fork has, each carrying **exactly** `en` (as the source
  key) and `zh-Hans` — no third language, and no machine translation shipped as if reviewed.

`OpenConnect: %@` / `OpenVPN: %@` were already marked `"shouldTranslate": false`, which is the
project's own record that a product name is not translated; the gate was taught to respect the
marker rather than carry a hand-kept exemption list.

**No locale was removed and no existing entry was edited.** `Localizable.xcstrings` is shared with
upstream — iPad and macOS read the same file — so pruning other languages to "keep only en +
zh-Hans" would have removed translations from products this work does not touch. The one place the
report says "NO" to its own checklist says so on purpose.

## The gate, and the reason not to trust its exit status here

`scripts/dev/check_localization.py` is **new** since the previous baseline. It walks every visible
string in the fork's own UI — `ApplicationLibrary/Views/HakoStyle/` and `SFI/Hako*.swift`, 56 files
— and requires each to resolve to a catalog key carrying `en` and `zh-Hans`. It knows that
`"\(count) unread"` is looked up as `"%lld unread"`, which is the detail that mattered most.

At the commit that introduced it: **240 strings resolving, 9 exempt as technical terms,
0 pending** (112 failures before).

### AI caution: on Windows this gate is a FALSE GREEN

Its root comes from `__file__`, and it filters files by
`path.startswith("ApplicationLibrary/Views/HakoStyle/")` / `"SFI/Hako"`. On Windows
`os.path.relpath` returns **backslashes**, so neither prefix matches, the file list is empty, and
the tool prints:

```text
PASS: 0 visible string(s) across 0 fork-owned file(s) resolve to a catalog key with en and zh-Hans (0 exempt as technical terms, 0 pending)
```

with **exit 0**. Measured directly on this host: **0 of 56** fork-owned files scanned. On a POSIX
host the same tree yields all **56**. The gate is correct on macOS/Linux and vacuous on Windows.

**Read the string and file counts it prints, not its exit status.** A re-run on Windows is
`BLOCKED_BY_ENVIRONMENT`, not `VERIFIED_STATIC`.

## Hard invariants

Do not use a visual-name change to alter `BASE_PACKAGE_IDENTIFIER`, derived bundle identifiers, App Groups, entitlements, URL/UTI declarations, signing, or `Variant.applicationName`. These are release/compatibility contracts, not ordinary copy. Do not bulk-replace `Localizable.xcstrings`; make a scoped, reviewable key change and validate the affected targets.

Do not remove locales from the shared catalog because one product supports a subset. The catalog
is read by iPad and macOS as well.

## Provenance and evidence

The boundary is enforced in part by `scripts/dev/audit_apple_ui_boundary.py`, which inspects product-identity markers and branding-scope rules (`branding` check). The source/project evidence above is `VERIFIED_SOURCE`; the audit result is `VERIFIED_STATIC` from a run at `331a676`. The localization gate is `VERIFIED_STATIC` **only on a host where it actually scans files**. No localized rendering, entitlement installation, or signed-product behavior is claimed here.

## AI cautions

Old reports may call the visible overlay a "rename". Treat that wording as historical shorthand, not authority to rename protocol identity. If a task requires an identity change, it is a release/signing decision and needs explicit authorization plus macOS build and device validation.

A localization near-miss is invisible in every environment that does not run the gate. If a string
appears in English inside a Chinese interface, suspect a key spelling before suspecting a missing
translation.
