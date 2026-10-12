# Architecture

`SFI/Application.swift` resolves the real device idiom. `.phone` reaches `SFI/HakoPhoneRootView.swift` and `SFI/HakoPageContent.swift`; other idioms retain the official `SFI/MainView.swift` path. Size class is only a layout input inside the official UI and never decides product ownership.

`ApplicationLibrary/Views/HakoStyle/` owns phone presentation. `ApplicationLibrary`, `Library`, and Libbox-facing code remain shared unless a narrowly evidenced fork extension exists. `Extension/PacketTunnelProvider.swift`, `SystemExtension/PacketTunnelProvider.swift`, and `TVExtension/PacketTunnelProvider.swift` are thin target providers over `Library/Network/ExtensionProvider.swift`.

The shared path is roughly UI -> `ExtensionProfile` / `CommandClient` -> command server / Libbox -> packet-tunnel service. Profile import, remote refresh and subscription metadata live in `Library/Database` and `Library/Network`; they are not duplicated in Hako pages.
