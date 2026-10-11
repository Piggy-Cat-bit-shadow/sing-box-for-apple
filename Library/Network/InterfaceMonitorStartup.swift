import Foundation

/// How the first interface path is obtained, and what happens when it does not arrive.
///
/// # The hang this exists to make impossible
///
/// `startDefaultInterfaceMonitor` installs a handler on a fresh `NWPathMonitor`, starts it, and waits
/// for the first path update so the listener can be seeded with the current path. The wait had no
/// timeout. In airplane mode there is no path *transition* to observe, so the update need not arrive
/// at all: `startService` blocked on a semaphore nobody would signal, before the tunnel ever started,
/// and the UI showed Working with no success and no failure.
///
/// No default network is a legal state, not a failure to start - a device in airplane mode whose
/// Wi-Fi the user has not yet re-enabled, a device with no SIM, a momentary outage and a network
/// switch are all ordinary. So the rule cannot be "airplane mode fails to start". It has to be:
/// startup completes within a bounded time, in a state that says there is no default interface.
///
/// # What is here, and what is not
///
/// This type holds the parts that are decisions rather than platform calls - the bound, the staleness
/// comparison, and what a timeout means. It has no `NetworkExtension` import and no `NWPathMonitor`,
/// so the failure paths can be driven directly rather than only reasoned about, which is the same
/// reason `ScreenStateObserver`'s policy is separate from its Darwin adapter.
///
/// The monitor itself is not fakeable here and is not faked: `NWPathMonitor` only exists on the
/// Apple platforms this target builds for, and a substitute would test the substitute. What is
/// testable is every decision the monitor's callback feeds, and that is what `HakoInterfaceStartup`
/// covers.
public enum InterfaceMonitorStartup {
    /// How long the first update is waited for before the seeded path is used as the answer.
    ///
    /// Chosen to be unambiguous rather than tight. An update that is going to arrive does so in
    /// milliseconds; waiting longer only delays startup in a state that has no network to use anyway,
    /// and waiting less risks discarding a path that was about to arrive.
    public static let firstUpdateTimeout: DispatchTimeInterval = .seconds(2)

    /// Identifies the monitor a callback belongs to.
    ///
    /// A bounded first wait means a monitor can be superseded while its first callback is still
    /// queued - by a `reset()` from a reload, or by the next start. A callback that published after
    /// that would hand the *new* listener the *old* interface, so every callback carries the
    /// generation it was installed under and is dropped when that generation has moved on.
    ///
    /// A value type with an explicit `next()`, so the "bump on assign and on clear" rule is one
    /// function rather than four hand-written increments that can drift apart.
    public struct Generation: Equatable, Comparable {
        public private(set) var value: UInt64

        public init(value: UInt64 = 0) {
            self.value = value
        }

        /// The generation a monitor installed now belongs to.
        public mutating func next() -> Generation {
            value &+= 1
            return self
        }

        /// Retires the current monitor without installing another.
        ///
        /// The clearing half of the rule, and the one that matters for a late callback: a monitor
        /// cancelled while its first update is still queued must stop being the current one *before*
        /// the cancel, or that callback can still publish. `closeDefaultInterfaceMonitor` and
        /// `reset()` both call this; `reset()` is the one reached from `stopService()`, i.e. on the
        /// core's gRPC goroutine, concurrently with a start.
        public mutating func retire() {
            value &+= 1
        }

        /// Whether a callback captured under `other` is still the current monitor's.
        public func owns(_ other: Generation) -> Bool {
            self == other
        }

        public static func < (lhs: Generation, rhs: Generation) -> Bool {
            lhs.value < rhs.value
        }
    }

    /// How the first update ended.
    public enum Outcome: Equatable {
        /// A real path update arrived inside the bound; the listener already has it.
        case updated
        /// Nothing arrived in time, so the seeded path is the answer and startup continues.
        ///
        /// Not a failure. The listener holds `.unsatisfied` (or whatever `currentPath` said), which
        /// `getInterfaces()` already answers with an empty list, and a later update still reaches
        /// `onUpdateDefaultInterface` if a path appears.
        case seededWithoutUpdate
    }

    /// What to do with a path update that may belong to a superseded monitor.
    public enum Disposition: Equatable {
        case publish
        case drop
    }

    /// Whether a callback installed under `callback` may still publish to the current listener.
    public static func disposition(callback: Generation, current: Generation) -> Disposition {
        current.owns(callback) ? .publish : .drop
    }

    /// Maps the bounded wait's result onto an outcome.
    ///
    /// The caller passes whether the semaphore was signalled; the arithmetic lives here so the two
    /// call sites that have to agree - the wait and the comment that explains it - are one function.
    public static func outcome(signalled: Bool) -> Outcome {
        signalled ? .updated : .seededWithoutUpdate
    }
}
