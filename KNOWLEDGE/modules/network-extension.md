# NetworkExtension lifecycle

## Scope

All three `PacketTunnelProvider` classes are four-line subclasses of one shared type, so
every lifecycle rule lives in `Library/Network/ExtensionProvider.swift`:

| Target file | Declaration |
|---|---|
| `Extension/PacketTunnelProvider.swift` | `class PacketTunnelProvider: ExtensionProvider {}` |
| `SystemExtension/PacketTunnelProvider.swift` | identical |
| `TVExtension/PacketTunnelProvider.swift` | identical |

`SystemExtension/main.swift` sets `Variant.useSystemExtension = true` and then calls
`NEProvider.startSystemExtensionMode()`.

`ExtensionProvider` creates and owns the command server, applies and persists start
options, starts or reloads the service, and tears down the service and the platform
interfaces.

## Serialization: one lock, taken across the core call

```swift
private let serviceLifecycleLock = NSLock()
```

`startService()` holds it across `startOrReloadService(...)` — which is what triggers the
core's monitor install:

```swift
serviceLifecycleLock.lock()
defer { serviceLifecycleLock.unlock() }
guard let commandServer else {
    throw ExtensionStartupError("(packet-tunnel) error: command server is not running")
}
```

The `guard`, not `commandServer!`, is deliberate: the property is reachable as `nil`
when a stop ran between the caller's read and this line, and a force-unwrap would turn
that into a process-killing trap instead of a message the caller already knows how to
surface.

`stopService()` takes the same lock and is single-entry:

```swift
func stopService() {
    serviceLifecycleLock.lock()
    defer { serviceLifecycleLock.unlock() }
    do { try commandServer?.closeService() } catch { writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)") }
    platformInterface.reset()
}
```

Why this lock exists at all — the header states the reachability explicitly: the core
reaches `stopService()` **synchronously from a gRPC handler goroutine**, not from a
NetworkExtension entry point, because `ExtensionPlatformInterface.serviceStop()` calls
`tunnel.stopService()` on whatever thread runs the handler.

`reloadService()` is a re-start inside the same server (`reasserting = true`,
`try await startService()`), and it **must not** re-register the screen-state observer:
doing so would leave the previous tokens behind and hand the core a second, independent
device axis.

`handleAppMessage` is the app→extension reload channel: decode → `applyStartOptions` →
`persistStartOptions` → `await reloadService()`, returning the error description as
UTF-8 on failure.

## Teardown: fence the observer before releasing the server

```swift
override open func stopTunnel(with reason: NEProviderStopReason) async {
    writeMessage("(packet-tunnel) stopping, reason: \(reason)")
    #if os(iOS)
        // Before the command server, and before `stopService()`.
        stopScreenStateObserver()
    #endif
    stopService()
    ...
}
```

The observer's own fence advances the generation **before** cancelling the tokens, and a
callback rejects itself on the generation, so a callback queued before `cancel()` and
run after it publishes nothing. The publisher additionally holds the command server
weakly.

## The identity check that is load-bearing

The teardown sleeps, and the sleep is a suspension point:

```swift
if let server = commandServer {
    try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
    let serverIsStillCurrent = commandServer === server
    server.close()
    if serverIsStillCurrent { commandServer = nil }
    else { Self.logger.info("stopTunnel: a new command server was installed during the stop; releasing the previous one only") }
}
```

A `startTunnel` completing inside that window installs a **new** server on the same
property. An unconditional `commandServer = nil` would then drop the only reference to
the new, healthy server and leave the tunnel running with a server nobody owns. The
comparison is made **after** the sleep because a check before it proves nothing about
this window.

The macOS XPC teardown mirrors the rule: it invalidates the listener and clears the XPC
service only when `commandServer == nil`, i.e. only when no new server landed.

`f4a9859` fixed this and a companion race (a reload cancelling its own live monitor).
"Simplifying" either back to the unconditional form reopens the fault.

## Failed start: an unresolved edge

`startTunnel` resolves paths, resolves and applies start options, builds
`LibboxSetupOptions`, calls `LibboxSetup`, creates and starts the command server, then:

```swift
do { try await startService() }
catch {
    #if os(macOS)
        if Variant.useSystemExtension { xpcService.markServiceNotReady(error) }
    #endif
    throw error
}
```

The failure path rethrows **without** closing the command server it just created and
started, and without calling `platformInterface.reset()`. Whether NetworkExtension
invokes `stopTunnel` afterwards — which would perform that cleanup — cannot be
established from this checkout.

```text
code shape        VERIFIED_SOURCE
liveness outcome  UNKNOWN -> EXTERNAL_CHECK_REQUIRED
                  (NEPacketTunnelProvider.startTunnel failure contract)
```

## AI cautions

- The identity check after the sleep is not defensive coding; it is the fix. Do not
  "simplify" it.
- `pause()` and `wake()` **bypass** `serviceLifecycleLock` — they call
  `commandServer.pause()` / `wake()` directly. The lock's docstring talks about
  serializing "the service lifecycle", so a reader reasonably assumes it covers them.
  It does not. Decide deliberately before extending the lock.
- Reload must not create a second screen observer.
- Do not treat a `reset()` landing during a start as harmless: that is the race the
  lock exists for, and the file header describes the resulting
  "nwMonitor not started" state with nothing to repair it.
- The first-path wait in the default-interface monitor has **no timeout** and runs while
  this lock is held — see `networking.md`.

## Evidence

`VERIFIED_SOURCE` for all code above and for the diff of `f4a9859`.
`NEEDS_DEVICE`: a real tunnel start/stop, sleep/wake, no-path recovery, and
signed-extension behaviour. This checkout cannot build (no `Libbox.xcframework`), so
even `VERIFIED_BUILD` is unavailable.
