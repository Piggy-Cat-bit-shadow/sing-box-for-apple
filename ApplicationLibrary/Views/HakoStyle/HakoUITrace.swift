//
//  HakoUITrace.swift
//  ApplicationLibrary
//
//  Development-time tracing for the UI state transitions that are hard to see.
//
//  # Why this exists
//
//  The navigation model keeps one source of truth - `NavigationPage` - and derives everything else
//  from it: which primary is selected, what each primary has pushed, which settings page a
//  notification asked for. When that derivation is wrong, the symptom is "the tab moved and the page
//  did not", which no screenshot shows and no static reading settles: it depends on the order SwiftUI
//  runs `onAppear`, `onChange` and a `NavigationLink`'s binding in, and on what the previous state was
//  at that moment.
//
//  So each transition prints one line with what it changed and where it came from. That is enough to
//  read a launch, a tab switch, a child push, a pop and a deep link out of a log, and to tell a
//  missing transition from a transition that happened twice.
//
//  # What it deliberately is not
//
//  Not telemetry: the body is compiled out of Release entirely. Not per-frame: it is called from
//  state changes and presentation events, never from `body`. Not a place to log payloads: it records
//  names, states and sources - never a profile, an address, a configuration value or anything from
//  the command client. Nothing here is a substitute for a test; it is the runtime debugger that makes
//  the test's subject visible.
//
//  # Reading it
//
//      log stream --style compact --predicate 'category == "ui"'
//
//  Each line is:  [UI] <name> <old> -> <new> source=<where>
//
//      [UI] selection dashboard -> logs source=MainView.onChange(selection)
//      [UI] primary home -> tools source=HakoPrimaryShell.primarySelection
//      [UI] child tools nil -> logs source=HakoPrimaryShell.applySelectedRoute
//      [UI] child-present tools/logs source=HakoPrimaryShell.childDestination
//      [UI] child-dismiss tools/logs source=HakoPrimaryShell.childDestination.pop
//

import SwiftUI

#if DEBUG
    import Foundation
    import os

    public enum HakoUITrace {
        /// One line per state change. `nil` renders as `nil`, so "was nothing pushed" is visible as
        /// itself rather than as an empty field.
        public static func transition(
            _ name: String,
            from old: String?,
            to new: String?,
            source: StaticString = #function
        ) {
            logger.debug(
                "[UI] \(name, privacy: .public) \(old ?? "nil", privacy: .public) -> \(new ?? "nil", privacy: .public) source=\(shortSource(source), privacy: .public)"
            )
        }

        /// A presentation event: something appeared or went away, with no state of its own.
        public static func event(
            _ event: String,
            source: StaticString = #function
        ) {
            logger.debug("[UI] \(event, privacy: .public) source=\(shortSource(source), privacy: .public)")
        }

        /// The subsystem is the running app's own identifier rather than a baked-in one, so a fork or
        /// a rename does not silently log to somebody else's stream.
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "sing-box-ui",
            category: "ui"
        )

        /// `#function` is a full signature; the file-and-function part is what a reader needs.
        private static func shortSource(_ source: StaticString) -> String {
            let text = "\(source)"
            if let parenthesis = text.firstIndex(of: "(") {
                return String(text[text.startIndex ..< parenthesis])
            }
            return text
        }
    }
#else
    /// No-op in Release: the call sites stay in the source, the work does not.
    public enum HakoUITrace {
        @inline(__always)
        public static func transition(
            _ name: String,
            from old: String?,
            to new: String?,
            source: StaticString = #function
        ) {}

        @inline(__always)
        public static func event(
            _ event: String,
            source: StaticString = #function
        ) {}
    }
#endif

/// Records a sheet's presentation binding as it changes.
///
/// A presentation is a state transition like any other, and it is the one that fails most quietly:
/// a sheet that is asked for twice, or asked for while another is up, shows as a warning and a
/// missing or doubled page rather than as a crash. Attached to the sheet's own content so the
/// binding observed is the one that actually presents it.
public extension View {
    @ViewBuilder
    func hakoTracePresentation(_ name: String, isPresented: Binding<Bool>) -> some View {
        #if DEBUG
            // `onChangeCompat` rather than the two-parameter `onChange`: the latter is macOS 14+ and
            // the desktop client still targets 13. One line per actual change is all this records.
            onChangeCompat(of: isPresented.wrappedValue) { presented in
                HakoUITrace.transition(
                    name,
                    from: presented ? "absent" : "presented",
                    to: presented ? "presented" : "absent",
                    source: "hakoTracePresentation"
                )
            }
        #else
            self
        #endif
    }
}
