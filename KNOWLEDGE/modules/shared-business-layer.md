# Shared business layer

`Library/Database`, `Library/Network`, `Library/Shared`, `ApplicationLibrary`, and Libbox bindings are shared-first. Hako presents those services; it should not own a second profile, network, or lifecycle implementation.

The fork extends subscription/remote-profile work through `RemoteProfileFetcher`, `RemoteProfileUpdatePolicy`, `RemoteRefreshApplier`, `SubscriptionInfo`, and profile persistence. Those extensions are `FORK-OWNED` where their commits/source show it; the surrounding application behavior remains `UPSTREAM-INHERITED` unless an audited diff says otherwise.

Future changes: classify whether behavior must apply on all Apple platforms. If yes, make the smallest shared edit and review upstream impact; if phone presentation only, keep it in Hako. Tests with stubs do not prove real Libbox/NE behavior.
