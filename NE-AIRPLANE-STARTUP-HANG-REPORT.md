# NE airplane startup hang report

> ## Standing constraint — iPad and Mac cannot be tested on real hardware
>
> **iPad and Mac real-device testing is unavailable**, and there is no simulator path for them in
> this project's acceptance either. This applies to every report in this repository, permanently,
> and it is not a limitation of this particular round.
>
> This matters more for *this* fix than for most, because the defect it addresses is in a file the
> iPad and macOS products also compile — `ExtensionPlatformInterface.swift` is upstream SagerNet's,
> byte-identical in `upstream/dev`, so **the same hang was reachable on iPad and macOS**. That is a
> statement about the source, which is why it can be made without a device. The fix's *effect* on
> iPad and macOS is not:
>
> * **SFM BUILD SUCCEEDED is compile evidence only.** It proves the shared Swift target still
>   compiles for macOS. It is *not* a runtime result, not an iPad result and not a Mac result.
> * Whether the bound produces a good startup on an iPad or a Mac is `NEEDS_DEVICE` and is not
>   claimed anywhere below. **No iPad or Mac runtime behaviour was observed this round.**
> * Only **iPhone simulator** results appear here, and only where they are labelled as such, and
>   none of them covers airplane mode — a simulator has no radios to turn off.

```text
ROOT CAUSE:
  - `Library/Network/ExtensionPlatformInterface.swift`, `startDefaultInterfaceMonitor`, the
    `semaphore.wait()` that followed `monitor.start(queue:)`. It waited with NO timeout for the
    first `NWPathMonitor` path update.
  - Airplane mode triggers it because the wait is for a path TRANSITION, and with the radios off
    there is none: the handler is installed, the monitor starts, and no update ever arrives. So the
    semaphore is never signalled, `startDefaultInterfaceMonitor` never returns, and the chain
    `startTunnel -> startService -> core -> startDefaultInterfaceMonitor` stops before the tunnel
    starts. The UI shows Working with no success and no failure.
  - This is an UPSTREAM defect, not one this fork introduced: the function is byte-identical in
    `upstream/dev`, so iPad and macOS carried it too.

FIX:
  - File: Library/Network/ExtensionPlatformInterface.swift, plus a new
    Library/Network/InterfaceMonitorStartup.swift holding the two decisions.
  - Semantics:
      * `monitor.currentPath` seeds the listener immediately after `start()`, so the ordinary case
        waits zero time. It is `.unsatisfied` rather than invalid with no usable path, and
        `getInterfaces()` already answers `.unsatisfied` with an empty list - so "no default
        network" is an expressible state the client already handles, not a failure to start.
      * the wait that follows is bounded at two seconds and its result is classified but not acted
        on: whether an update arrived or the wait timed out, the listener has a state and startup
        proceeds.
      * the handler is installed once for the monitor's whole life instead of being replaced from
        inside its own first callback. The old shape needed that replacement to avoid re-signalling
        the semaphore; the generation check does it without mutating the handler from the queue it
        runs on.
  - timeout rule: `InterfaceMonitorStartup.firstUpdateTimeout` = 2s, finite, asserted > 0 and <= 10.
  - fallback rule: no update within the bound -> `seededWithoutUpdate` -> the seeded path stands and
    startup continues. A later update still reaches `onUpdateDefaultInterface`, which is what makes
    "airplane mode, then Wi-Fi on" recover.
  - cancellation rule: `nwMonitorGeneration` is bumped on every install AND every clear, through
    `Generation.next()` / `Generation.retire()`. A callback captures the generation it was installed
    under and is dropped when that generation has moved on.

SIMILAR UNBOUNDED WAITS FOUND:
  - Audited, in scope (VPN start/stop/reload): `Library/Network/` and `Library/Shared/BlockingIO.swift`.
  - `Extension+RunBlocking.swift` (2 sites, used by `openTun`, `setTunnelNetworkSettings` and the
    platform-interface callbacks): NONE - not a defect. The `Task.detached` body signals the
    semaphore on the success path AND in the `catch`, so it always completes. It is an async->sync
    bridge, not a wait on an external event that may never arrive.
  - `SystemExtension.swift` (3 sites), `MachServiceClient.swift` (2), `UserServiceXPC.swift` (3),
    `CommandXPC.swift` (1): OUT OF SCOPE and NOT FIXED. These wait on an XPC or
    `OSSystemExtensionRequest` reply from another process, which is a different class of risk from a
    callback that may never be scheduled at all, and none of them is on the tunnel's startup path.
    Recorded rather than changed, because widening this round to the XPC surface is exactly the
    scope creep the brief forbids. They are the same *shape* and are worth a later pass with their
    own evidence.
  - `withCheckedContinuation` (ExtensionPlatformInterface x2, BlockingIO x1): NONE - each is resumed
    from a callback that the awaited operation always runs, and none is on the startup path.

RACE SAFETY:
  - late callback: DROPPED. `disposition(callback:current:)` compares the captured generation with
    the live one; a callback from a superseded monitor returns without touching the listener or
    `lastNetworkPath`. Covered by two tests - superseded by a new start, and retired with no
    successor.
  - reset/cancel: BOTH retire the generation before cancelling, so a callback already queued when
    `cancel()` is called finds a different value. `reset()` is the one that matters: `stopService()`
    reaches it from the core's gRPC handler goroutine, which is an independent thread by
    construction, concurrently with a start.
  - serviceLifecycleLock: UNTOUCHED, and no lock was added. The policy takes no lock and waits
    unboundedly nowhere (asserted against its own source), so it cannot be held across a lifecycle
    operation and cannot deadlock against `serviceLifecycleLock`, `unwindFailedStart`, the
    `commandServer` guard or the `stopTunnel` identity check. The bound does mean the lock can be
    held for up to 2s in the no-network case, which is a latency property, not a deadlock - and it
    is strictly better than the previous behaviour, which held it forever.

VALIDATION:
  - unit/harness: 12 tests, 0 failures (`scripts/run-interface-startup-tests.sh`). Covers all five
    required scenarios: unsatisfied initial path does not block; a first callback that never arrives
    still completes; a later callback is published (recovery); a late callback from a retired or
    superseded monitor is dropped; and the policy holds no lock and never waits unboundedly. Two of
    the twelve are shape assertions about the adapter, labelled as such - without them the package
    could be green about a type nobody calls.
  - SFI: BUILD SUCCEEDED
  - SFM: BUILD SUCCEEDED   (compile evidence for the shared target only - see below)
  - simulator: ENVIRONMENT_BLOCKED, and no new runtime was downloaded. iOS 26.0 and iOS 27.0 were
    already installed on this host, so this round needed no download - but the host's CoreSimulator
    service cannot instantiate a device at all. Two attempts, both ending in
    "Failed to clone device ... Device was allocated but was stuck in creation state", the second
    against a device the user had created earlier, so this is a host defect rather than anything
    about the code. `SIMULATOR = ENVIRONMENT_BLOCKED`.
    This does not block the fix: airplane mode is a real-radio state, so a simulator could not have
    verified it in the first place - a simulator has no radios to turn off.
  - device: NEEDS_DEVICE. Airplane mode on hardware is the only way to confirm the startup state a
    real `NWPathMonitor` reports with the radios off, and a fake monitor would test the fake.
    **Mac and iPad real-device testing is unavailable**, so the upstream-side fix is compile-verified
    there and nothing more. No device result is claimed anywhere in this report.

BRANCH: fix/hako-import-editor-routing   (shared with the Hako import fix, per instruction)
HEAD:   15d3a72 (the runtime fix) - see the branch tip for the full set
PUSHED: YES
```

## What is not claimed

The bound makes an unbounded hang impossible. It does **not** prove that airplane mode now reaches
a *successful* tunnel start on a device, because that depends on what the core does with an empty
interface list - and that is a device question. What is established here is the narrower and
checkable statement the brief asks for: **startup can no longer block forever on a callback that
never arrives.**
