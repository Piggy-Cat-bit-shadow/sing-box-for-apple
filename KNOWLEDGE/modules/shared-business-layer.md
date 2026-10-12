# Shared business layer

`Library/Database`, `Library/Network`, `Library/Shared`, `ApplicationLibrary`, and Libbox bindings are shared-first. Hako presents those services; it should not own a second profile, network, or lifecycle implementation.

The fork extends subscription/remote-profile work through `RemoteProfileFetcher`, `RemoteProfileUpdatePolicy`, `RemoteRefreshApplier`, `SubscriptionInfo`, and profile persistence. Those extensions are `FORK-OWNED` where their commits/source show it; the surrounding application behavior remains `UPSTREAM-INHERITED` unless an audited diff says otherwise.

The boundary that most often gets this wrong is the **file**, not the type. `2f0024c` is the
recorded case: a shared file named a phone page, and `audit_apple_ui_boundary.py`'s
`no-reverse-dependency` check caught it. At this baseline that check reports all **319** Swift
files outside the Hako namespace free of Hako symbols, with 54 files inside the namespace to be
divided from.

`upstream-files-untouched` is the other half of the same contract: **434 of 458** upstream files
are byte-identical to `089d35e6`, and the **24** modified ones are each on the reviewed list with
a printed reason. When a shared change is proposed, that list is where its cost shows up.

Future changes: classify whether behavior must apply on all Apple platforms. If yes, make the smallest shared edit and review upstream impact; if phone presentation only, keep it in Hako. Tests with stubs do not prove real Libbox/NE behavior.

`Library/Network/` is where the two subsystems this fork owns live — the extension lifecycle
(`ExtensionProvider`, `ExtensionPlatformInterface`) and the device axis
(`ScreenStateObserver`, `ScreenStateObserverDarwin`, `InterfaceMonitorStartup`). Read
`modules/network-extension.md`, `modules/screen-state.md` and `modules/networking.md` before
changing anything there; each of the three has a guard whose reason is not visible from the call
site.
