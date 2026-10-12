# Build, signing and TestFlight

`sing-box.xcodeproj` defines app targets (SFI/iOS, SFM/macOS, SFT/tvOS), packet/system extensions, ApplicationLibrary/Library/MacLibrary, UI tests and auxiliary Action/Share/FileProvider/Intents/Widget/Helper targets. `Libbox.xcframework` is project-referenced but absent in this checkout; its source/pin must be verified with the parent/core repository.

Entitlements, `BASE_PACKAGE_IDENTIFIER`, derived bundle IDs, App Groups and signing are identity contracts. The visible Jiejiebox name overlay must not mutate those values. Runestone is a gitlink, not vendored source.

Fastlane/Makefile may describe operational steps, but no archive/export/upload was run here. A signed build is `VERIFIED_BUILD`; upload is distinct from public TestFlight review; neither is established at this baseline.
