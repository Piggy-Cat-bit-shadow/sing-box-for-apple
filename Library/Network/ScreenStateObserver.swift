import Dispatch
import Foundation

/// The outcome of one Darwin `notify` call.
///
/// `<notify.h>` declares the status codes as `#define`s, so the Clang importer brings
/// `NOTIFY_STATUS_OK` in as an `Int32` while every notify entry point returns `uint32_t` - confirmed
/// against the SDK with `xcrun swiftc -typecheck`:
///
///     notify_register_dispatch: (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?,
///                                dispatch_queue_t?, notify_handler_t?) -> UInt32
///     notify_get_state:         (Int32, UnsafeMutablePointer<UInt64>?) -> UInt32
///     notify_cancel:            (Int32) -> UInt32
///     NOTIFY_STATUS_OK:         Int32
///
/// The two types are reconciled in exactly one place, `SystemNotifyAPI`, which is also the only
/// place that calls the C functions. Everything above it works with this enum, so a call that did
/// not return `NOTIFY_STATUS_OK` cannot be mistaken for one that did: there is no raw status to
/// compare against `0` by accident.
enum NotifyOutcome: Equatable {
    case ok
    case failed(status: UInt32)
}

/// One `notify_register_dispatch` attempt.
///
/// The C API writes `out_token` only when it succeeds and leaves it untouched otherwise, so the
/// token and the status are not two independent facts. `.failed` carries no token, and a
/// registration that never happened cannot be cancelled as if it had.
enum NotifyRegistration: Equatable {
    case registered(token: Int32)
    case failed(status: UInt32)

    var token: Int32? {
        guard case let .registered(token) = self else {
            return nil
        }
        return token
    }
}

/// One `notify_get_state` attempt.
///
/// This type is what makes the original defect unrepresentable. The old code declared
/// `var state: UInt64 = 0`, ignored the return code and then read `state`, so a read that failed and
/// a read that succeeded with `0` produced the same value - and `0` on `com.apple.springboard.lockstate`
/// means "unlocked". `.failed` carries no value at all, and the only way to get one out is to write
/// the failed branch explicitly.
enum NotifyStateRead: Equatable {
    case value(UInt64)
    case failed(status: UInt32)
}

/// The three Darwin `notify` entry points the observer uses, narrowed to what it needs.
///
/// The protocol exists so the failure paths - a registration that fails, a read that fails, a
/// callback delivered after teardown - are driven deterministically by a fake instead of argued
/// about. The concrete implementation is `SystemNotifyAPI`.
protocol DarwinNotifyAPI: AnyObject {
    func registerDispatch(name: String,
                          queue: DispatchQueue,
                          handler: @escaping (Int32) -> Void) -> NotifyRegistration
    func getState(token: Int32) -> NotifyStateRead
    func cancel(token: Int32) -> NotifyOutcome
}

/// What the observer is allowed to tell the core.
///
/// A one-to-one mirror of the two `LibboxCommandServer` record methods and deliberately nothing
/// more:
///
///   * `recordScreenState(on:)` -> `CommandServer.RecordScreenState` -> `Box.ScreenStateChanged`
///   * `recordLockState(locked:)` -> `CommandServer.RecordLockState` -> `Box.LockStateChanged`
///
/// Both take a `BOOL`, so the bridge is two-valued. It cannot carry "unknown", and that is why the
/// policy for a read that failed is "publish nothing at all" rather than "publish a third value" -
/// see `ScreenStatePolicy.decide`.
///
/// `WakeNow` is deliberately absent. On the core this client targets, an unlock is the device wake
/// (`Box.LockStateChanged(false)` -> `lifecycle.woke()`, edge plus LEVEL release), while the display
/// fact is a resume EDGE that must not lift the level (`Box.ScreenStateChanged(true)` ->
/// `lifecycle.resumed()` only, because a push notification lights the lock screen). A publisher that
/// offered `wakeNow()` would be offering a way to turn a lit lock screen into a wake storm.
protocol ScreenStatePublishing: AnyObject {
    func recordScreenState(on: Bool)
    func recordLockState(locked: Bool)
}

/// The four facts the observer can establish, named for what the core does with them.
enum ScreenFact: Equatable {
    /// `com.apple.iokit.hid.displayStatus == 1`: the display is on.
    /// `lifecycle.resumed()` - a reuse EDGE, and nothing else.
    case displayOn
    /// `com.apple.iokit.hid.displayStatus == 0`: the display is off.
    /// `lifecycle.slept()` - LEVEL pause.
    case displayOff
    /// `com.apple.springboard.lockstate == 1`: the device is locked.
    /// `lifecycle.slept()` - LEVEL pause.
    case locked
    /// `com.apple.springboard.lockstate == 0`: the device is unlocked.
    /// `lifecycle.woke()` - reuse EDGE plus the LEVEL release. The only fact that lifts the pause.
    case unlocked

    /// Whether the core reads this fact as "nobody is using this device".
    var isSleep: Bool {
        switch self {
        case .displayOff, .locked:
            return true
        case .displayOn, .unlocked:
            return false
        }
    }

    /// Whether the core reads this fact as a device wake - the one LEVEL release.
    var isWake: Bool {
        self == .unlocked
    }

    /// Whether the core reads this fact as a resume edge with no level movement.
    var isResumeEdge: Bool {
        self == .displayOn
    }
}

/// The two notification names the observer follows, and the fact each value maps to.
///
/// Neither name is public API. See the availability note in the S02 report.
enum ScreenStateSource: CaseIterable {
    case display
    case lock

    var notificationName: String {
        switch self {
        case .display:
            return "com.apple.iokit.hid.displayStatus"
        case .lock:
            return "com.apple.springboard.lockstate"
        }
    }

    /// The only mapping there is: total on `0` and `1`, undefined anywhere else.
    ///
    /// The old code wrote `state == 1`, which maps every other value to `false` - and `false` on the
    /// lock source is `unlocked`, the one fact that lifts the device pause. A value that is neither
    /// `0` nor `1` is reported here as nothing at all, never as an unlock.
    func fact(for value: UInt64) -> ScreenFact? {
        switch (self, value) {
        case (.display, 0):
            return .displayOff
        case (.display, 1):
            return .displayOn
        case (.lock, 0):
            return .unlocked
        case (.lock, 1):
            return .locked
        default:
            return nil
        }
    }
}

/// Where an observation came from.
enum ScreenStateProvenance {
    /// A notification callback: a transition the system witnessed and delivered.
    case event
    /// A `notify_get_state` read taken outside a callback - at start, or on a NetworkExtension
    /// resume.
    case snapshot
}

/// What `ScreenStateObserver.start()` did.
///
/// The names that failed are carried out of `start()` rather than only logged, because whether
/// `com.apple.springboard.lockstate` and `com.apple.iokit.hid.displayStatus` are posted to a
/// sandboxed NetworkExtension differs per iOS release and cannot be established from source. A
/// device log that says which name failed to register is the only evidence that question has.
enum ScreenStateStartResult: Equatable {
    /// Both sources are registered.
    case started
    /// Both sources were already registered; `start()` did nothing.
    case alreadyStarted
    /// Neither source is registered. `sources` lists the registrations that failed.
    case failed(sources: [ScreenStateSource])

    var isStarted: Bool {
        switch self {
        case .started, .alreadyStarted:
            return true
        case .failed:
            return false
        }
    }

    /// The notification names that failed, for the log.
    var failedNotificationNames: [String] {
        guard case let .failed(sources) = self else {
            return []
        }
        return sources.map(\.notificationName)
    }
}

/// The result of one observation: what to remember, and what (if anything) to publish.
struct ScreenStateDecision: Equatable {
    /// The raw value to remember as this source's last observation, or `nil` when the read
    /// established nothing and what was known before must be kept.
    let rememberValue: UInt64?
    /// The fact to publish, or `nil` when nothing may be published. `nil` is how this code spells
    /// "unknown": the bridge has no third value to send.
    let publish: ScreenFact?
}

/// The whole policy, as a pure function, so every failure path is exercisable without a device.
enum ScreenStatePolicy {
    /// Decides what one observation means.
    ///
    /// The rules, in order:
    ///
    /// 1. A read that did not return `NOTIFY_STATUS_OK` established nothing. Nothing is published,
    ///    and the previously observed value is kept - so a later successful read of the same value
    ///    is still a repeat rather than a fresh edge, and a later successful read of a different
    ///    value is still published. A failed read can therefore never be reported as "unlocked" and
    ///    can never fabricate a transition.
    /// 2. A value that is neither `0` nor `1` established nothing either. Nothing is published.
    /// 3. A value equal to the last value this source successfully observed is a repeat. Nothing is
    ///    published, so a system that re-posts an unchanged fact cannot produce a second sleep edge,
    ///    a second wake, or a wake storm.
    /// 4. A snapshot may only establish that the device is NOT in use (`isSleep`). "Unlocked" and
    ///    "display on" are claims about a transition that a snapshot did not witness, and
    ///    `notify_get_state` answers `NOTIFY_STATUS_OK` with `0` for a name whose state was never
    ///    set - which on the lock source would read as an unlock. The value is still remembered, so
    ///    the next real transition is measured against it.
    /// 5. An unlock is a transition, so it is only published when the lock source was actually
    ///    observed locked (`1`) first. `.unlocked` is the one fact that lifts the device pause
    ///    (`lifecycle.woke()`), and a `0` from an axis whose prior value is unknown is
    ///    indistinguishable from the never-set `0` rule 4 refuses on a snapshot - so it is refused
    ///    on an event too. The value is still remembered, so the next read is measured against it
    ///    and a genuine lock-then-unlock still publishes.
    static func decide(read: NotifyStateRead,
                       source: ScreenStateSource,
                       provenance: ScreenStateProvenance,
                       lastObserved: UInt64?) -> ScreenStateDecision {
        guard case let .value(raw) = read else {
            return ScreenStateDecision(rememberValue: nil, publish: nil)
        }
        guard let fact = source.fact(for: raw) else {
            return ScreenStateDecision(rememberValue: nil, publish: nil)
        }
        if lastObserved == raw {
            return ScreenStateDecision(rememberValue: raw, publish: nil)
        }
        if provenance == .snapshot, !fact.isSleep {
            return ScreenStateDecision(rememberValue: raw, publish: nil)
        }
        if fact == .unlocked, lastObserved != 1 {
            return ScreenStateDecision(rememberValue: raw, publish: nil)
        }
        return ScreenStateDecision(rememberValue: raw, publish: fact)
    }
}

/// Watches the two Darwin notifications that describe whether a person is using the device, and
/// hands the resulting facts to the core through `ScreenStatePublishing`.
///
/// Everything this class owns is confined to one serial queue, which is also the queue the notify
/// callbacks are registered against. That single choice is what makes the rest of the design cheap:
///
///   * Registration and the snapshot read that follows it cannot interleave with a callback, so the
///     snapshot is never older than a fact the core already has and can never overwrite a newer
///     event.
///   * A teardown cannot run in the middle of an observation.
///   * The last-observed values need no lock of their own, because nothing off the queue touches
///     them.
///
/// The two lifecycle facts that are not queue-confined - the generation counter and the token table
/// - sit behind one small lock, because `cancel()` has to fence callbacks synchronously from
/// whatever thread the NetworkExtension calls it on, and `deinit` has to be able to release tokens
/// without hopping onto a queue that may already be gone.
final class ScreenStateObserver {
    private let notify: DarwinNotifyAPI
    private let publisher: ScreenStatePublishing
    private let queue: DispatchQueue
    /// Identifies `queue`, so an entry point called from a callback runs inline instead of
    /// deadlocking on itself.
    private let queueKey = DispatchSpecificKey<UInt8>()

    /// Guards `generation` and `registrations`.
    private let access = NSLock()
    /// Bumped by every `start()` and every `cancel()`. A callback may publish only while the
    /// generation it was registered under is still current.
    private var generation: UInt64 = 0
    /// The tokens that actually registered. A source is absent when its registration failed, so a
    /// failed registration is never cancelled.
    private var registrations: [ScreenStateSource: Int32] = [:]

    /// Queue-confined. The last raw value each source successfully observed, whether or not it was
    /// published.
    private var lastObserved: [ScreenStateSource: UInt64] = [:]

    init(notify: DarwinNotifyAPI,
         publisher: ScreenStatePublishing,
         queue: DispatchQueue = DispatchQueue(label: "io.nekohasekai.sfamt.screen-state")) {
        self.notify = notify
        self.publisher = publisher
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        // Last resort. The owner is expected to call `cancel()` before it closes the command
        // server; a registration that outlived the observer would keep a dead handler alive in
        // notifyd for the life of the process.
        for token in takeRegistrations() {
            _ = notify.cancel(token: token)
        }
    }

    // MARK: - Lifecycle

    /// Registers both notifications and publishes the current state.
    ///
    /// Both names are attempted even when the first one fails, so the failure is reported for every
    /// source rather than only for the first, and only the registrations that actually succeeded are
    /// cancelled on the way out.
    ///
    /// All or nothing: if either registration fails, the one that succeeded is cancelled and this
    /// reports failure. A half-registered observer would drive the device axis from whichever name
    /// happened to register, which makes the pause behaviour differ per launch for a reason nobody
    /// can see from the outside; a clean, logged failure is visible instead.
    ///
    /// Idempotent: a second `start()` while registered does nothing at all, so no token is
    /// duplicated and repeated start/stop cycles cannot leak a registration.
    ///
    /// # Ordering
    ///
    /// Registration happens first, then the snapshot read, both inside one block on the observer's
    /// serial queue - which is also the queue the registrations deliver on. No callback can run
    /// between the two, so the snapshot is never older than a fact the core already has: a
    /// transition that happens during the window is either seen by the snapshot or delivered by the
    /// callback that follows it, and the repeat rule collapses the case where both happen into one
    /// publication. The unsafe order - read first, register second - loses a transition that happens
    /// in between, and is what this replaces.
    @discardableResult
    func start() -> ScreenStateStartResult {
        syncOnQueue {
            guard !hasRegistrations else {
                return .alreadyStarted
            }
            let epoch = advanceGeneration()
            var registered: [ScreenStateSource: Int32] = [:]
            var failed: [ScreenStateSource] = []
            for source in ScreenStateSource.allCases {
                let registration = notify.registerDispatch(name: source.notificationName,
                                                           queue: queue) { [weak self] _ in
                    // The token is deliberately unused: the generation is what identifies whether
                    // this callback still belongs to a live registration.
                    self?.handleEvent(source: source, epoch: epoch)
                }
                switch registration {
                case let .registered(token):
                    registered[source] = token
                case .failed:
                    failed.append(source)
                }
            }
            guard failed.isEmpty else {
                // Clean up the registrations that did succeed. `registered` only ever holds tokens
                // the API returned, so nothing that failed is cancelled here.
                for (_, token) in registered {
                    _ = notify.cancel(token: token)
                }
                return .failed(sources: failed)
            }
            storeRegistrations(registered)
            for source in ScreenStateSource.allCases {
                observe(source: source, provenance: .snapshot, epoch: epoch)
            }
            return .started
        }
    }

    /// Stops watching, and makes every callback that is already queued a no-op.
    ///
    /// The generation is advanced synchronously, before this returns and before the tokens are
    /// cancelled. `notify_cancel` cannot un-queue a callback the notification centre has already
    /// submitted, and `ExtensionProvider` calls this immediately before it closes the command
    /// server, so a callback that ran in that window would otherwise publish into a dead server.
    /// Bumping first makes "after `cancel()` returns, nothing is published" a property of this code
    /// rather than a property of how the notification centre schedules.
    ///
    /// Idempotent, and it cancels only the tokens that actually registered.
    func cancel() {
        _ = advanceGeneration()
        for token in takeRegistrations() {
            _ = notify.cancel(token: token)
        }
    }

    /// Re-reads both sources outside a callback, and republishes only what a snapshot may establish.
    ///
    /// Darwin notifications are delivered to a running process and to nobody else: while the
    /// extension is suspended a lock or an unlock is simply not delivered, and the observer has no
    /// way to hear about it afterwards. A NetworkExtension resume is the one moment the process
    /// knows it was away, so it is the one moment a re-read is worth doing. It is not polling -
    /// nothing schedules this and no timer is involved - and because a snapshot may only publish a
    /// sleep fact, it can recover a missed "the device locked" and can never invent a wake.
    func resync() {
        syncOnQueue {
            let epoch = currentGeneration()
            for source in ScreenStateSource.allCases {
                observe(source: source, provenance: .snapshot, epoch: epoch)
            }
        }
    }

    // MARK: - Observation

    /// A notification callback. Runs on the observer's serial queue, which is the queue the
    /// registration asked for.
    private func handleEvent(source: ScreenStateSource, epoch: UInt64) {
        // A callback queued before `cancel()` and run after it must publish nothing: the command
        // server it would publish into is closed, and the core it would drive has moved on. This is
        // the whole of the "no notification may revive the core after stop" rule.
        guard isCurrent(epoch) else {
            return
        }
        observe(source: source, provenance: .event, epoch: epoch)
    }

    /// One observation of one source: read the value, decide, publish. Queue-confined.
    private func observe(source: ScreenStateSource, provenance: ScreenStateProvenance, epoch: UInt64) {
        guard isCurrent(epoch), let token = registration(for: source) else {
            return
        }
        let read = notify.getState(token: token)
        // Re-checked after the read. `cancel()` can land while the read is in flight, and a fact
        // that was read before the fence must not be published after it. The fence is checked on
        // both sides of the only call that can take time, so the observer cannot be resurrected by
        // a read that was already under way.
        guard isCurrent(epoch) else {
            return
        }
        let decision = ScreenStatePolicy.decide(read: read,
                                                source: source,
                                                provenance: provenance,
                                                lastObserved: lastObserved[source])
        if let value = decision.rememberValue {
            lastObserved[source] = value
        }
        guard let fact = decision.publish else {
            return
        }
        publish(fact)
    }

    /// The state table, in code:
    ///
    ///     locked=1   -> recordLockState(true)   -> Box.LockStateChanged(true)  -> slept()   (LEVEL pause)
    ///     unlocked=0 -> recordLockState(false)  -> Box.LockStateChanged(false) -> woke()    (LEVEL wake)
    ///     display=on -> recordScreenState(true) -> Box.ScreenStateChanged(true) -> resumed() (EDGE only)
    ///     display=off-> recordScreenState(false)-> Box.ScreenStateChanged(false)-> slept()   (LEVEL pause)
    ///
    /// There is no path to `wakeNow()`: an unlock already publishes the wake, and a display going on
    /// must not.
    private func publish(_ fact: ScreenFact) {
        switch fact {
        case .displayOn:
            publisher.recordScreenState(on: true)
        case .displayOff:
            publisher.recordScreenState(on: false)
        case .locked:
            publisher.recordLockState(locked: true)
        case .unlocked:
            publisher.recordLockState(locked: false)
        }
    }

    // MARK: - Queue and generation plumbing

    /// Runs `body` on the observer's queue, inline when already there.
    ///
    /// Every entry point goes through this, so `cancel()` and `resync()` can be called from a
    /// callback without deadlocking and every observation is serialised with every other.
    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    /// Bumps the generation and returns the new value. Safe from any thread.
    private func advanceGeneration() -> UInt64 {
        access.lock()
        defer { access.unlock() }
        generation &+= 1
        return generation
    }

    private func currentGeneration() -> UInt64 {
        access.lock()
        defer { access.unlock() }
        return generation
    }

    /// Whether `epoch` is still the generation the observer is running under.
    private func isCurrent(_ epoch: UInt64) -> Bool {
        currentGeneration() == epoch
    }

    /// Whether a registration is already in place, so `start()` can be a no-op.
    private var hasRegistrations: Bool {
        access.lock()
        defer { access.unlock() }
        return !registrations.isEmpty
    }

    private func storeRegistrations(_ registered: [ScreenStateSource: Int32]) {
        access.lock()
        defer { access.unlock() }
        registrations = registered
    }

    private func takeRegistrations() -> [Int32] {
        access.lock()
        defer { access.unlock() }
        let tokens = Array(registrations.values)
        registrations.removeAll()
        return tokens
    }

    private func registration(for source: ScreenStateSource) -> Int32? {
        access.lock()
        defer { access.unlock() }
        return registrations[source]
    }
}
