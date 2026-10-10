# Jiejiebox Apple client

The iOS and macOS client for this fork of [sing-box](https://github.com/SagerNet/sing-box).
It is a fork of [SagerNet/sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple)
that runs a custom iPhone presentation while leaving Apple's own presentation in charge on iPad
and macOS.

## Presentation ownership

| Surface | UI | Where it lives |
| --- | --- | --- |
| iPhone | Custom **Hako** UI | `ApplicationLibrary/Views/HakoStyle/`, `SFI/HakoPhoneRootView.swift` |
| iPad | **Upstream** adaptive UI | `SFI/MainView.swift` — byte-identical to upstream |
| macOS | **Upstream** UI | `MacLibrary/MainView.swift` |

The family is decided once, in `SFI/Application.swift`, from the device idiom —
`UIDevice.current.userInterfaceIdiom` and nothing else:

```
SFI/Application.swift
└── SFIUIFamily.current              (idiom; never size class)
    ├── .hakoPhone  -> HakoPhoneRootView    iPhone
    └── .upstreamPad -> MainView            iPad, at every width
```

An iPad in Split View, Slide Over, Stage Manager or a narrow window is still an iPad and keeps
upstream's presentation; how it lays that out is upstream's own business, via
`SidebarLayout.isEnabled`. Size class never selects the family.

The two families share one set of application and core objects — one `ExtensionEnvironments`,
one profile store, one `CommandClient` — injected above both roots. Presentation differs; state
does not.

Product branding is separate from presentation ownership: the display name is `Jiejiebox` on
iPhone, iPad and macOS, while the UI follows the table above.

## Libbox

The app links **Libbox.xcframework**, compiled from this fork's core:
[`Piggy-Cat-bit-shadow/sing-box`](https://github.com/Piggy-Cat-bit-shadow/sing-box). Nothing is
downloaded from an upstream release.

Build it from the parent checkout and install it here:

```bash
# in the parent repository
./scripts/ci/gomobile-toolchain.sh install apple
./scripts/ci/build-apple-libbox.sh both      # builds ios + macos, installs into clients/apple
```

`Libbox.xcframework` is generated and git-ignored; it is not part of this repository.

## Which revision to build

The **parent repository's gitlink is the authoritative iOS revision**. A branch name in this
repository is not:

```bash
# in the parent repository
git ls-tree HEAD clients/apple     # <- the Apple revision that ships
```

Build the revision the parent pins, not a branch tip. `scripts/ci/check-libbox-abi.sh` in the
parent asserts that the gitlink points at a client revision carrying the current Libbox ABI,
which is what stops a green core build from shipping with a client that no longer compiles.

## Documentation

* [docs/HAKO-OWNERSHIP.md](docs/HAKO-OWNERSHIP.md) — who owns every file, and the two ownership
  axes (presentation and branding)
* [docs/APPLE-UI-ROUTING.md](docs/APPLE-UI-ROUTING.md) — the iOS entry graph and root ownership
* [docs/IPAD-UPSTREAM-PORT.md](docs/IPAD-UPSTREAM-PORT.md) — how iPad and macOS keep upstream's
  presentation

## Development

```bash
# subscription-usage unit tests (SwiftPM, no simulator needed)
./scripts/run-subscription-usage-tests.sh

# the frozen iPhone UI must not drift
./scripts/dev/check-iphone-hako-freeze.sh
./scripts/dev/test-iphone-hako-freeze.sh

# build the iOS app
DISABLE_SWIFTLINT=1 xcodebuild -project sing-box.xcodeproj -scheme SFI \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The iPhone UI tests in `SFIUITests/` drive the Hako shell and address its tab bar, so they are
iPhone-presentation tests: run them on an iPhone simulator. They are not expected to pass on an
iPad, where the app presents upstream's UI and there is no Hako tab bar.

## Upstream

[SFI](https://sing-box.sagernet.org/installation/clients/sfi/) |
[SFM](https://sing-box.sagernet.org/installation/clients/sfm/)

## License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```
