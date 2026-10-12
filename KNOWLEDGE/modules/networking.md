# Networking and default-interface monitoring

## Scope and ownership

`Library/Network/ExtensionPlatformInterface.swift` owns the packet-tunnel platform interface and its default-interface monitor. `ExtensionProvider` owns the service lifecycle that calls it. `ApplicationLibrary/Views/Tools/NetworkQualityViewModel.swift` has a separate UI-quality monitor; do not conflate it with the tunnel monitor.

The surrounding network implementation is `UPSTREAM-INHERITED` unless a final fork diff identifies an exception. The `f4a9859` serialization change is `FORK-OWNED` lifecycle hardening around that interface, not a rewrite of networking policy.

## Current design and hard boundaries

`startDefaultInterfaceMonitor` installs `NWPathMonitor`, stores it in `nwMonitor`, and waits for its first handler invocation. `reset()` cancels and clears that monitor. A legal no-path state (including airplane mode) is an interface result, not proof that the service has crashed.

The first-path wait has no timeout at this baseline. Do not add an unbounded second wait, remove the existing synchronization, or let a concurrent reset cancel a monitor that a start/reload has just installed. `ExtensionProvider.serviceLifecycleLock` exists specifically to serialize that start/reload/reset surface; see `network-extension.md` and `f4a9859`.

## Evidence and limits

Source locations: `Library/Network/ExtensionPlatformInterface.swift` (`startDefaultInterfaceMonitor`, `reset`) and `Library/Network/ExtensionProvider.swift` (`startService`, `stopService`). This is `VERIFIED_SOURCE`. It is not proof that `NWPathMonitor` delivery, no-path recovery, or packet-tunnel behavior works on a signed device; those remain `NEEDS_DEVICE`.

## AI cautions

Do not interpret a static audit, a fake monitor, or a simulator path callback as physical radio/airplane-mode evidence. Before changing monitor lifetime, inspect the full start/reload/stop sequence and verify on device.
