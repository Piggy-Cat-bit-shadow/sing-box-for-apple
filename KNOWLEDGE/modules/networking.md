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

The surrounding network implementation is upstream-inherited. The tunnel monitor's startup
path is the one place this fork owns lifecycle work around it, and it has been rewritten
since the previous baseline — see below.

## The tunnel monitor: seed, bound, generation

`startDefaultInterfaceMonitor` no longer blocks indefinitely. Its current shape, re-read at
`5cab4ec`:

```swift
let monitor = NWPathMonitor()
nwMonitor = monitor
let generation = nwMonitorGeneration.next()

monitor.pathUpdateHandler = { path in
    guard InterfaceMonitorStartup.disposition(callback: generation,
                                              current: self.nwMonitorGeneration) == .publish
    else { return }
    self.onUpdateDefaultInterface(listener, path)
    semaphore.signal()
}
monitor.start(queue: DispatchQueue.global())

onUpdateDefaultInterface(listener, monitor.currentPath)        // seed FIRST

let signalled = semaphore.wait(timeout: .now() + InterfaceMonitorStartup.firstUpdateTimeout) == .success
_ = InterfaceMonitorStartup.outcome(signalled: signalled)
```

Four things to hold onto, because each replaced something that was wrong:

1. **Seed first.** `NWPathMonitor` populates `currentPath` before `start` returns, and it is
   `.unsatisfied` rather than invalid when there is no usable path — which is exactly the
   airplane-mode state, and one `getInterfaces()` already knows how to express (empty list for
   `.unsatisfied`). So the ordinary case does not wait at all.
2. **The wait is bounded** at `InterfaceMonitorStartup.firstUpdateTimeout` = **2 seconds**.
3. **The outcome is deliberately not acted on.** Whether the update arrived or the wait timed
   out, the listener has a state and startup proceeds.
4. **One closure for the monitor's whole life.** The previous revision replaced the handler
   from inside the first callback to avoid re-signalling the semaphore; the generation check
   does that without mutating the handler from the queue it runs on.

The decisions live in `Library/Network/InterfaceMonitorStartup.swift` — a Foundation-only type
with no `NetworkExtension` import and no `NWPathMonitor`, which is the same separation that
makes `ScreenStateObserver`'s policy testable. It holds:

```text
firstUpdateTimeout     .seconds(2)
Generation             value type; next() bumps on assign, retire() bumps on clear
Outcome                .updated | .seededWithoutUpdate
Disposition            .publish | .drop
disposition(callback:current:)   publish iff the current generation owns the callback
outcome(signalled:)              maps the wait's result onto an Outcome
```

`Generation` exists because a **bounded** first wait means a monitor can be superseded while
its first callback is still queued — by a `reset()` from a reload, or by the next start. A
callback that published after that would hand the *new* listener the *old* interface.
`closeDefaultInterfaceMonitor` and `reset()` both call `retire()`, and `reset()` is the one
reached from `stopService()`, i.e. on the core's gRPC goroutine, concurrently with a start.

### This replaced a recorded defect, and the fix is why the shape is now more complex

The previous baseline recorded: *"`semaphore.wait()` has no timeout, and there are no
generation guards"*, reached from `startService()` while `serviceLifecycleLock` was held, so a
monitor that never delivered blocked the install **indefinitely** and every subsequent
`stopService()` queued behind it. Airplane mode at startup was the concrete trigger.

Fixed by `15d3a72` ("bound the first interface-path wait, so airplane mode cannot hang
startup") plus `628644d`, which gave the bound an off-device test seam
(`Tests/HakoInterfaceStartup`, whose policy source is a symlink to the shipping
`InterfaceMonitorStartup.swift`).

**Do not read "no timeout" out of an older report and act on it.** And do not add a second,
differently-shaped timeout: the bound is defined in one place.

### The query path is unchanged

`getInterfaces()` reads `nwMonitor.currentPath`, returns an empty interface array when
`status == .unsatisfied`, and throws `"NWMonitor not started"` when no monitor exists. A legal
no-path state — including airplane mode — is an interface result, not evidence that the
service has crashed. Both the live-update path and the query path return an empty result
rather than failing.

Cancellation: `closeDefaultInterfaceMonitor(_:)` (called by the core) and `reset()`.

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
- The seed-then-bounded-wait order is load-bearing. Reading `currentPath` *after* the wait
  reintroduces the hang on the path where no update ever arrives.
- Do not bump `nwMonitorGeneration` anywhere except through `next()` / `retire()`; the
  "bump on assign and on clear" rule is one function so it cannot drift.

## Evidence

`VERIFIED_SOURCE` for the three-monitor census, the seed/bound/generation shape, the
`currentPath` seeding and the cancellation paths, re-read at `5cab4ec`.
`VERIFIED_SOURCE` for the diffs of `15d3a72` and `628644d`.
`VERIFIED_STATIC` is **not** claimed for the bound's behaviour: the seam exists, but the
package cannot be built on this host (symlinked sources — see `modules/tests-audits.md`).
`NEEDS_DEVICE`: real `NWPathMonitor` delivery, airplane-mode recovery, "airplane mode then
Wi-Fi on", and packet-tunnel behaviour on a signed device.
