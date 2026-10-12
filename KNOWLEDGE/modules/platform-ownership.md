# Platform ownership

## Scope and current design

iPhone is fork-owned Hako. iPad and macOS are intentionally official/upstream UI. tvOS is out of custom-product scope. `SFIUIFamily.resolve(idiom:)` is the ownership gate; narrow iPad windows remain iPad.

## Provenance and cautions

`SFI/HakoPhoneRootView.swift` and `SFI/HakoPageContent.swift` are fork-owned routing adapters. The official iPad root and Mac paths are deliberately preserved. Do not replace upstream files with copies, and do not make shared views inspect `UIDevice` or horizontal size class to select Hako.

## Verification

`audit_apple_ui_boundary.py --upstream-ref 089d35e` checks declared boundary contracts; its negative suite proves selected audit failures are caught. Both are `VERIFIED_STATIC` when run, not UI/device proof. Exact historical pass counts in reports are snapshots, not evergreen truth.
