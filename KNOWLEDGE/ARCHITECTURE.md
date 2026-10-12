# Architecture

`SFI/Application.swift` resolves the real device idiom. `.phone` reaches `SFI/HakoPhoneRootView.swift` and `SFI/HakoPageContent.swift`; other idioms retain the official `SFI/MainView.swift` path. Size class is only a layout input inside the official UI and never decides product ownership. The environment wiring hangs off the `Group` above both arms, so the shared model objects are created once.

`ApplicationLibrary/Views/HakoStyle/` owns phone presentation — 54 Swift files. `ApplicationLibrary`, `Library`, and Libbox-facing code remain shared unless a narrowly evidenced fork extension exists. `Extension/PacketTunnelProvider.swift`, `SystemExtension/PacketTunnelProvider.swift`, and `TVExtension/PacketTunnelProvider.swift` are thin target providers over `Library/Network/ExtensionProvider.swift`.

The shared path is roughly UI -> `ExtensionProfile` / `CommandClient` -> command server / Libbox -> packet-tunnel service. Profile import, remote refresh and subscription metadata live in `Library/Database` and `Library/Network`; they are not duplicated in Hako pages.

## `Library/Network/` holds the two subsystems this fork owns

Everything else in the network layer is upstream-inherited. These are not:

```text
ExtensionProvider.swift            the lifecycle, the start transaction, the teardown fence
ExtensionPlatformInterface.swift   the Libbox platform interface + the default-interface monitor
InterfaceMonitorStartup.swift      the monitor's decisions, with no NetworkExtension import
ScreenStateObserver.swift          the device axis: policy, rules, fencing
ScreenStateObserverDarwin.swift    the #if os(iOS) notify adapter
```

The split that repeats three times, and is the file layout's real organising idea: **decisions
live in a Foundation-only type, platform calls live in a thin adapter.** `ScreenStateObserver`'s
policy is separated from its Darwin adapter, and `InterfaceMonitorStartup` is separated from
`NWPathMonitor`, for the same reason — the failure paths become drivable in a test instead of only
arguable. `Tests/HakoScreenState` and `Tests/HakoInterfaceStartup` each symlink the decision file
rather than a copy.

`ExtensionPlatformInterface` owns the tunnel's default-interface monitor, while the Tools UI has its own `NWPathMonitor`; these are separate ownership domains — there are three monitors in three processes in total (`modules/networking.md`).

Display branding is likewise separate from target/protocol identity: project display-name settings are not authorization to change `Variant.applicationName`, bundle identifiers, or entitlement identifiers. The brand overlay is 4 configurations reading `Jiejiebox`; 8 still read `sing-box`, and the audit verifies `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` and `BASE_PACKAGE_IDENTIFIER` are byte-identical to the upstream pin.
