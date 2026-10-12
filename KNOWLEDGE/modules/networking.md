# Networking and default-interface monitoring

## Ownership — three monitors, not two

An earlier revision said there were two ownership domains. That was incomplete.
Exhaustive search finds **three**, in three different processes:

| # | Location | Process | Owner |
|---|---|---|---|
| 1 | `Library/Network/ExtensionPlatformInterface.swift` | the **tunnel** extension | `ExtensionProvider` via `platformInterface` |
| 2 | `ApplicationLibrary/Views/Tools/NetworkQualityViewModel.swift` | the **app UI** | a one-shot local monitor inside `checkMeteredNetwork()` |
| 3 | `HelperService/RootHelperService.swift` | the macOS **root helper** | `RootHelperService`, cancelled in `closeNeighborMonitorInternal()` |

They must not be conflated. In particular, do not "unify" the tunnel monitor with the
Tools-UI monitor: different processes, different questions.

The surrounding network implementation is upstream-inherited except for the `f4a9859`
serialization hardening, which is fork-owned lifecycle work around the interface, not a
rewrite of networking policy.

## The tunnel monitor

`startDefaultInterfaceMonitor` installs an `NWPathMonitor`, stores it in `nwMonitor`,
and blocks on a `DispatchSemaphore` until the first handler invocation. The handler
re-arms itself after that first delivery so the semaphore is signalled exactly once.

- **First-update bound: there is none.** `semaphore.wait()` has no timeout.
- The **install** path does not read `currentPath`; the **query** path does —
  `getInterfaces()` reads `nwMonitor.currentPath`, returns an empty interface array when
  `status == .unsatisfied`, and throws `"NWMonitor not started"` when no monitor exists.
- **Generation guards: none.** No token, no epoch. The only protection is
  `ExtensionProvider.serviceLifecycleLock` plus `reset()`.
- Cancellation: `closeDefaultInterfaceMonitor(_:)` (called by the core) and `reset()`,
  which cancels and clears `nwMonitor`.

A legal no-path state — including airplane mode — is an interface result, not evidence
that the service has crashed. Both the live-update path and the query path return an
empty result rather than failing.

### KNOWN DEFECT AT THIS BASELINE: the wait is unbounded

`startDefaultInterfaceMonitor` is reached from `startService()` while
`serviceLifecycleLock` is held. A monitor that never delivers therefore blocks the
install **indefinitely**, and every subsequent `stopService()` (reachable from the
core's gRPC handler goroutine) and `reloadService()` queues behind it. Airplane mode at
startup is the concrete trigger: no path update is delivered, so startup hangs.

```text
code shape                    VERIFIED_SOURCE
liveness consequence          INFERRED from the code shape (not observed on a device)
```

**Already fixed on the live product line, not here.** `origin/main` carries `15d3a72`
"bound the first interface-path wait, so airplane mode cannot hang startup" plus
`628644d`, which gives the bound an off-device test seam. Verified by reading
`origin/main`'s `ExtensionProvider.swift`.

Do not add a timeout here as a freelance "small fix" — the bound exists upstream of this
baseline, and adding a second, differently-shaped one would fight it. Do not add a
*second* unbounded wait either, and do not let a concurrent `reset()` cancel a monitor
that a start/reload has just installed — that is the race the lock exists for.

## The Tools-UI monitor

Self-cancelling, and therefore needs no generation guard: it cancels itself inside the
handler and resumes its continuation exactly once, returning whether the path is
expensive or cellular.

## AI cautions

- A static audit, a fake monitor, or a simulator path callback is **not** physical radio
  or airplane-mode evidence.
- Before changing monitor lifetime, read the whole start/reload/stop sequence in
  `network-extension.md`.
- Do not interpret absence of a path as a lifecycle crash.

## Evidence

`VERIFIED_SOURCE` for the three-monitor census, the unbounded wait, the `currentPath`
seeding and the cancellation paths, re-read at `aa1e982`.
`NEEDS_DEVICE`: real `NWPathMonitor` delivery, no-path recovery, and packet-tunnel
behaviour on a signed device.
