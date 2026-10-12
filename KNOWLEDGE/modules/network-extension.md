# NetworkExtension lifecycle

## Scope

All three `PacketTunnelProvider` classes are four-line subclasses of one shared type, so
every lifecycle rule lives in `Library/Network/ExtensionProvider.swift` (575 lines):

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
core's monitor install — and **not** across the macOS `locationManager` block that follows,
which touches no shared resource and would only widen the region:

```swift
serviceLifecycleLock.lock()
defer { serviceLifecycleLock.unlock() }
guard let commandServer else {
    throw ExtensionStartupError("(packet-tunnel) error: command server is not running")
}
```

The `guard`, not `commandServer!`, is deliberate and the header names both reachable paths:
`stopTunnel` nils the property while `tunnelOptions` survives, and `startTunnel` sets
`tunnelOptions` before it creates the server. A force-unwrap there would turn an ordinary
"the server is gone" into a process-killing trap — which on device is indistinguishable from
"the tunnel stopped working".

`stopService()` takes the same lock and is single-entry:

```swift
func stopService() {
    serviceLifecycleLock.lock()
    defer { serviceLifecycleLock.unlock() }
    do { try commandServer?.closeService() } catch { writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)") }
    platformInterface.reset()
}
```

Why the lock exists at all — the header states the reachability explicitly: the core
reaches `stopService()` **synchronously from a gRPC handler goroutine**, not from a
NetworkExtension entry point, because `ExtensionPlatformInterface.serviceStop()` calls
`tunnel.stopService()` on whatever thread runs the handler. Nothing serialised that against
`stopTunnel`'s own call, and `stopService()` ends in `platformInterface.reset()`, which
cancels and nils the monitor a concurrent start has just installed and is still waiting on.

`reloadService()` is a re-start inside the same server (`reasserting = true`,
`try await startService()`), and it **must not** re-register the screen-state observer:
doing so would leave the previous tokens behind and hand the core a second, independent
device axis.

`handleAppMessage` is the app→extension reload channel: decode → `applyStartOptions` →
`persistStartOptions` → `await reloadService()`, returning the error description as
UTF-8 on failure.

## The start transaction: a failure unwinds what it created

`startTunnel` now wraps everything after the command server exists in a `do/catch`, and the
catch calls `unwindFailedStart()`:

```swift
do {
    try await startTunnel0()          // start server, resume XPC, startService, start observer
    ...
} catch {
    #if os(macOS)
        if Variant.useSystemExtension { xpcService.markServiceNotReady(error) }
    #endif
    unwindFailedStart()
    throw error
}
```

`unwindFailedStart()` releases in **`stopTunnel`'s order**, and clears `commandServer` last so
the closing calls can still reach it:

```swift
private func unwindFailedStart() {
    #if os(iOS)
        stopScreenStateObserver()
    #endif
    stopService()
    commandServer?.close()
    commandServer = nil
}
```

This closed a real leak rather than a theoretical one: previously every failure below the
server's creation threw **without releasing anything**, leaving `commandServer` created and
listening on `command.pb`, the Go-side power-report worker and OOM recorder running with
nothing to stop them, and on macOS an already-resumed XPC listener pointing at a server whose
service never started. `8d06a99` fixed it; `f8f978c` absorbed the companion runtime fixes.

The `do/catch` is used rather than `defer` plus a flag because the successful path must not
unwind, and a `catch` says that in the shape of the code rather than in a boolean.

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
    if serverIsStillCurrent {
        commandServer = nil
        #if os(macOS)
            if Variant.useSystemExtension { /* markServiceNotReady, invalidate listener, clear registry */ }
        #endif
    } else {
        Self.logger.info("stopTunnel: a new command server was installed during the stop; releasing the previous one only")
    }
}
```

A `startTunnel` completing inside that window installs a **new** server on the same
property. An unconditional `commandServer = nil` would then drop the only reference to
the new, healthy server and leave the tunnel running with a server nobody owns. The
comparison is made **after** the sleep because a check before it proves nothing about
this window.

The macOS XPC teardown is now **inside** the same `if serverIsStillCurrent` branch, for the
same reason: `xpcListener.invalidate()`, `xpcService = nil` and the registry clear are all
"tear down the surface I owned", so they may only run when the server this call captured is
still the current one. An earlier comment claimed the ordering was safe for macOS *because*
the stop runs first; that is only true when nothing started in between.

`f4a9859` fixed this and a companion race (a reload cancelling its own live monitor).
"Simplifying" either back to the unconditional form reopens the fault.

## `pause()` / `wake()` and the observer's resume hook

```swift
override open func sleep() async { if let commandServer { commandServer.pause() } }

override open func wake() {
    if let commandServer { commandServer.wake() }
    #if os(iOS)
        screenStateObserver?.resync()
    #endif
}
```

`pause()` publishes the sleep EDGE and then the LEVEL. `wake()` is an EDGE only on iOS: the
platform resumes the extension for every push and background task, and letting a resume lift
the device pause would release health checks, probes and statistics for a phone in a pocket.
`resync()` is the other half of `wake()` — a resume is the one moment the process knows it was
suspended, and Darwin notifications are not delivered to a suspended process.

The observer is created once per tunnel process in `startTunnel` (via `startTunnel0`) and torn
down once in `stopTunnel`. `startScreenStateObserver()` guards on `screenStateObserver == nil`
and **reports** a registration failure rather than swallowing it, because without the
notifications the device axis falls back to sleep/wake alone, which on iOS enters the pause and
never lifts it.

## AI cautions

- The identity check after the sleep is not defensive coding; it is the fix. Do not
  "simplify" it, and do not move the macOS XPC teardown back out of that branch.
- Do not replace the `guard let commandServer` in `startService()` with a force-unwrap.
- `pause()` and `wake()` **bypass** `serviceLifecycleLock` — they call
  `commandServer.pause()` / `wake()` directly. The lock's docstring talks about
  serializing "the service lifecycle", so a reader reasonably assumes it covers them.
  It does not. Decide deliberately before extending the lock.
- Reload must not create a second screen observer.
- Do not treat a `reset()` landing during a start as harmless: that is the race the
  lock exists for, and the file header describes the resulting
  "nwMonitor not started" state with nothing to repair it.
- The first-path wait in the default-interface monitor is now **bounded** (2 s) and
  generation-guarded — see `networking.md`. Do not reintroduce an unbounded wait.
- A failed start must unwind. Adding a new `throw` inside `startTunnel0` is safe; adding one
  *outside* the `do/catch` is not.

## Evidence

`VERIFIED_SOURCE` for all code above, re-read at `5cab4ec`.
`VERIFIED_SOURCE` for the diffs of `f4a9859`, `8d06a99` and `f8f978c`.
`NEEDS_DEVICE`: a real tunnel start/stop, sleep/wake, no-path recovery, and
signed-extension behaviour. This checkout cannot build (no `Libbox.xcframework`), so
even `VERIFIED_BUILD` is unavailable.
