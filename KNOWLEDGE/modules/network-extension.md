# NetworkExtension lifecycle

## Scope

Target `PacketTunnelProvider` classes delegate to shared `ExtensionProvider`. It creates/owns the command server, applies/persists start options, starts or reloads service, and tears down service and platform interfaces.

## Hard boundaries

`serviceLifecycleLock` serializes start/reload with `stopService`; do not await while holding it. Reload reuses the command server and must not create a second screen observer. Teardown cancels the observer before service/server release so callbacks cannot publish into a dying server.

`f4a9859` fixes two non-obvious races: a delayed stop must not null a newly installed command server, and a reload must not cancel its own live monitor. The identity check after the suspension window is load-bearing. “Simplifying” it to unconditional `commandServer = nil`, or treating reset as harmless during start, reopens the fault.

## Evidence

Final source plus commit diff are `VERIFIED_SOURCE`. Real tunnel, sleep/wake, no-path, and signed-extension evidence is `NEEDS_DEVICE`.
