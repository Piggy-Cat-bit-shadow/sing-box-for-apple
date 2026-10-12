# Localization and branding

## Scope and ownership

`Localizable.xcstrings` is the shared string catalog referenced by multiple Xcode targets. Hako UI consumes localized strings but does not own a second catalog. The product-facing display-name overlay is represented in Xcode build settings (`INFOPLIST_KEY_CFBundleDisplayName`); at this baseline the relevant app configurations use `Jiejiebox`.

`Library/Shared/Variant.swift` deliberately retains target identity values such as `SFI`/`SFM`/`SFT`. `HTTPClient` derives its User-Agent from that identity and `ExtensionProfile` uses it for the tunnel manager's localized description. Therefore display branding and protocol/runtime identity are separate concerns.

## Hard invariants

Do not use a visual-name change to alter `BASE_PACKAGE_IDENTIFIER`, derived bundle identifiers, App Groups, entitlements, URL/UTI declarations, signing, or `Variant.applicationName`. These are release/compatibility contracts, not ordinary copy. Do not bulk-replace `Localizable.xcstrings`; make a scoped, reviewable key change and validate the affected targets.

## Provenance and evidence

The boundary is enforced in part by `scripts/dev/audit_apple_ui_boundary.py`, which inspects product-identity markers and branding-scope rules. The source/project evidence above is `VERIFIED_SOURCE`; an audit is `VERIFIED_STATIC` only when run against the selected ref. No localized rendering, entitlement installation, or signed-product behavior is claimed here.

## AI cautions

Old reports may call the visible overlay a "rename". Treat that wording as historical shorthand, not authority to rename protocol identity. If a task requires an identity change, it is a release/signing decision and needs explicit authorization plus macOS build and device validation.
