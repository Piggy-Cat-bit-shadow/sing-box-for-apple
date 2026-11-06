//
//  HakoProfileSwitchQueue.swift
//  ApplicationLibrary
//
//  The one-slot queue behind the phone's profile switch.
//
//  # The defect this exists to prevent
//
//  A configuration-centre selection is not a stored value - it is an operation. Upstream's
//  `OverviewViewModel.switchProfile` persists the identifier, broadcasts it
//  (`environments.selectedProfileUpdate`), and reloads the running tunnel when one is up. It
//  is asynchronous on all three counts.
//
//  Two taps therefore produce two operations in flight. Each one persists the identifier it
//  was handed, and each one clears the page's busy gate when *it* finishes. Whichever task
//  the scheduler completes last is then the persisted one, which is not necessarily the one
//  the reader chose last, and the gate drops while the other is still running.
//
//  # What "the last accepted choice" means here
//
//  One slot, one drainer. While a switch is in flight, a new choice *replaces* the pending
//  one instead of starting a second operation; the drainer applies whatever is pending when
//  it gets there. So:
//
//    * every accepted choice is persisted by the same task, in the order it was accepted;
//    * the last choice to be accepted is the last one applied - a burst of A, B, C ends on C
//      and never on A or B arriving late;
//    * the page's busy gate is released by the drainer reaching the end of the queue, not by
//      an individual switch finishing, so it cannot drop under a switch still in flight.
//
//  Choices in the middle of a burst are deliberately *coalesced*: persisting B and then C
//  back to back would reload the tunnel twice for a choice the reader had already replaced.
//  Ending on what the reader chose last is the contract; replaying every intermediate value
//  was never one.
//
//  # Why it is a Foundation-only type
//
//  The order of the operations is the whole content of this file, and it is exactly what
//  cannot be observed on a device without one. Keeping the state machine here - out of the
//  SwiftUI view that drives it - is what lets
//  `scripts/dev/check_hako_profile_switch.py` compile this file and drive it through the
//  interleavings, on a host with no Xcode.
//

import Foundation

/// Serialises the phone's profile switches and gives "the last accepted choice" a meaning.
///
/// See the file header for the operations it orders and what it guarantees about them.
struct HakoProfileSwitchQueue<Choice> {
    /// The choice waiting to be applied, if any.
    private var pending: Choice?

    /// Whether a switch is in flight - i.e. whether a drainer has started and not yet seen
    /// the queue empty.
    private(set) var isDraining = false

    /// An empty queue, with no switch in flight.
    ///
    /// Declared rather than left to the compiler: the stored properties are `private`, so the
    /// synthesized initialisers are private too, and the page that owns one of these is a
    /// different file.
    init() {}

    /// Records `choice` and answers whether this call must start the drain.
    ///
    /// `true` means "nothing is being applied right now, start one". `false` means "one is
    /// already in flight; it will pick this up", and the caller must not start a second.
    mutating func request(_ choice: Choice) -> Bool {
        pending = choice
        guard !isDraining else {
            return false
        }
        isDraining = true
        return true
    }

    /// The next choice to apply, or `nil` when there is none left.
    ///
    /// A `nil` answer ends the drain: the queue is idle again and the page's busy gate may be
    /// released. That is why this clears `isDraining` itself rather than exposing a separate
    /// `finish()` - a drainer that stops must be able to say so in one call, and a caller that
    /// forgot the second call would leave the page disabled for ever.
    mutating func take() -> Choice? {
        guard let choice = pending else {
            isDraining = false
            return nil
        }
        pending = nil
        return choice
    }
}
