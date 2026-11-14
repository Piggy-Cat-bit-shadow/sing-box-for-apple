//
//  HakoStartStopButton.swift
//  ApplicationLibrary
//
//  The phone's connect/stop control, from `hako-ui` @ `c1935cf`.
//
//  # Why this is a copy and not upstream's component
//
//  Upstream's `StartStopButton` is the tunnel's state machine and an iPad and a Mac use it, so it is
//  not the place to put the phone's metrics. It has also drifted from the one the phone's design was
//  built on: it no longer takes `isCompact` - the capsule sized to its own label that the phone's
//  header needs, because a full-width action beside the configuration's name pushes the name off the
//  row - and it no longer takes the `install` closure that makes the button the page's action in the
//  one state that exists to be fixed.
//
//  So the phone gets its own copy. This is deliberate duplication: two implementations of one state
//  machine, kept apart so that neither platform's design has to be renegotiated to change the other's.
//  `docs/HAKO-LOSSLESS-PARITY-AUDIT.md` records it.
//
//  Generated from `c1935cf` by `scripts/dev/port_hako_components.py`. Re-run that rather than
//  editing here.
//
//  HAND-REPAIRED, 2026-11-14 (stability pass): the busy branch keeps a Disconnect action that appears
//  once a transition has stopped moving, so a tunnel stuck in `.connecting`/`.disconnecting` can
//  still be stopped. The original design replaced the control with a spinner, which removed the only
//  way out. Re-applying this file from the generator WILL lose that repair - it is not carried in the
//  script. See `docs/audits/2026-11-14-apple-ui-stability-closeout.md` §9.
//

import Library
import NetworkExtension
import SwiftUI

@MainActor
public struct HakoStartStopButton: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    private let showsRuntimeDuration: Bool

    /// What to do when there is no tunnel profile yet.
    ///
    /// The card's action is the page's action in every state, so with nothing installed it is
    /// the install - the reference's "Repair and connect". It used to be a disabled icon-only
    /// play triangle, which is the one thing a card's primary action must not be.
    private let install: () async -> Void
    /// Sized to its label rather than to the card. The home's operation row puts the action beside
    /// the configuration it acts on, and a full-width button there would push the name off the row.
    private let isCompact: Bool

    public init(
        showsRuntimeDuration: Bool = false,
        isCompact: Bool = false,
        install: @escaping () async -> Void = {}
    ) {
        self.showsRuntimeDuration = showsRuntimeDuration
        self.isCompact = isCompact
        self.install = install
    }

    public var body: some View {
        Group {
            if let profile = environments.extensionProfile {
                // Starting needs a profile; installing does not. The `.disabled` below used to
                // wrap both branches, so a client with no profiles disabled the very action
                // that would give it one - a grey button, looking broken, in the one state that
                // exists to be fixed.
                HakoToggleConnectionButton(
                    showsRuntimeDuration: showsRuntimeDuration,
                    isCompact: isCompact
                )
                    .environmentObject(profile)
                    .disabled(environments.emptyProfiles)
            } else {
                Button {
                    Task {
                        await install()
                    }
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                        // The compact form is the home's capsule, and a capsule that spans the
                        // page is not the same control as the connect/stop one beside it: the
                        // review asked for one visual scale for all three states. The full-width
                        // form remains for the pages that use the button as a page action.
                        .frame(maxWidth: isCompact ? nil : .infinity)
                }
                .hakoConnectionActionButtonStyle(isDestructive: false)
                .controlSize(isCompact ? .regular : .large)
                .accessibilityIdentifier("hako.home.connection.action")
            }
        }
    }

    private struct HakoToggleConnectionButton: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @EnvironmentObject private var profile: ExtensionProfile
        @State private var alert: AlertState?
        @State private var currentTime = Date()
        @State private var isStarting = false
        /// When the current transition began, or nil when the tunnel is not moving.
        ///
        /// Used only to tell "still making progress" from "stopped moving". A healthy start or stop
        /// finishes in a second or two, so the emergency control stays invisible for those; it is
        /// not a timeout that fails the operation, just the point at which the reader is offered the
        /// exit that the old code removed exactly when it was needed.
        @State private var busySince: Date?
        /// A stop request this control has already submitted and not yet seen return.
        @State private var isStopping = false
        let showsRuntimeDuration: Bool
        let isCompact: Bool

        /// Whether this button draws a running time at all.
        ///
        /// The same three conditions the label uses when it decides to show the duration, kept in
        /// one place because the tick below is gated on exactly them.
        private var showsRuntimeClock: Bool {
            showsRuntimeDuration && !isCompact && profile.status.isConnectedStrict && !Variant.screenshotMode
        }

        /// How long a transition may look like progress before the exit is offered.
        ///
        /// Chosen above every normal transition and below the point where a reader concludes the app
        /// has hung. It is not a timeout: the operation is not failed, cancelled or retried at this
        /// point - only the button that can end it is shown.
        private static let emergencyGracePeriod: TimeInterval = 6

        /// The transition the tunnel is in, if it is in one.
        private var isBusy: Bool {
            isStarting || profile.status == .connecting || profile.status == .disconnecting
        }

        /// Whether the transition has stopped looking like progress.
        ///
        /// `currentTime` is the one-second tick this view already runs for the session duration, so
        /// this re-evaluates without adding a second timer. In screenshot mode the tick is frozen on
        /// purpose, and a fixture has no tunnel to be stuck in, so the control stays in its normal
        /// shape there.
        private var isTransitionStalled: Bool {
            guard isBusy, !Variant.screenshotMode, let busySince else {
                return false
            }
            return currentTime.timeIntervalSince(busySince) >= Self.emergencyGracePeriod
        }

        var body: some View {
            // The reference's action: one full-width button that names what it will do, filled
            // when it will connect and destructive-toned when it will disconnect, with a
            // progress line while it is working. Ours was a compact icon button beside the
            // state text, so the card's main action was the smallest thing on it.
            Group {
                // Busy means *transitioning* - not "not switchable", which is also true of a
                // client with no tunnel at all. That mistake put "Working…" in front of a
                // reader who has nothing installed and nothing happening.
                if isBusy {
                    VStack(spacing: HakoTheme.Spacing.compact) {
                        HStack(spacing: HakoTheme.Spacing.compact) {
                            ProgressView()
                            Text("Working…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        // The exit, once the transition has stopped moving.
                        //
                        // This is the whole reason the busy branch is not just a spinner. A tunnel
                        // that stays in `.connecting` or `.disconnecting` - a stop request the
                        // system has not acted on, a kernel that never answered - used to replace
                        // the only control that could end it, so the page offered no way out at
                        // all. The action is always `stop()`: never the start/stop toggle, because
                        // a toggle evaluated in `.disconnecting` reads "not connected" and would
                        // *start* the tunnel the reader is trying to leave.
                        if isTransitionStalled {
                            Button {
                                Task {
                                    await requestStop()
                                }
                            } label: {
                                Label("Disconnect", systemImage: "power")
                            }
                            .hakoConnectionActionButtonStyle(isDestructive: true)
                            .controlSize(isCompact ? .regular : .large)
                            .modifier(HakoCapsuleBorderShape())
                            .tint(.green)
                            .disabled(isStopping)
                            .accessibilityIdentifier("hako.home.connection.stopOverride")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: HakoTheme.Control.minimumHitTarget)
                } else {
                    Button {
                        Task {
                            await switchProfile(!profile.status.isConnected)
                        }
                    } label: {
                        HStack(spacing: HakoTheme.Spacing.compact) {
                            // Only where the row has space for it. In the operation row the
                            // action sits beside the configuration's name, and the running time
                            // pushed the label onto a second line.
                            if showsRuntimeDuration, !isCompact,
                               profile.status.isConnectedStrict, let duration = runtimeDuration
                            {
                                Text(duration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .fixedSize()
                            }
                            Label(
                                profile.status.isConnected
                                    ? String(localized: "Disconnect")
                                    : String(localized: "Connect"),
                                systemImage: "power"
                            )
                            // Only the primary action spans the card. A secondary one sized to
                            // its own label stops reading as the page's subject.
                            .frame(
                                maxWidth: profile.status.isConnected || isCompact ? nil : .infinity
                            )
                        }
                    }

                        .hakoConnectionActionButtonStyle(isDestructive: profile.status.isConnected)
                        // The reference's home capsule: `buttonBorderShape(.capsule)`, tinted by
                        // what the action will do - green to disconnect a running tunnel, the
                        // accent otherwise. Its size is set by the header, which fixes it at the
                        // reference's 104pt by the control's minimum hit target.
                        //
                        // `.capsule` is macOS 14 and `ApplicationLibrary` builds for 13, so the
                        // shape goes through a modifier that skips it below 14 rather than through
                        // `#available` here: a modifier chain cannot be branched, and dropping the
                        // line would silently change the control's shape on the OS that has it.
                        .modifier(HakoCapsuleBorderShape())
                        .tint(profile.status.isConnected ? .green : .accentColor)

                    .controlSize(isCompact ? .regular : .large)
                    .accessibilityIdentifier("hako.home.connection.action")
                }
            }
            .alert($alert)

                // The running time's clock, and only its clock.
                //
                // This used to be `Timer.publish(every: 1, ...).autoconnect()` subscribed
                // unconditionally: the timer woke the main run loop once a second for the whole
                // session even on the home page, which passes `showsRuntimeDuration: false` - so
                // the tick's only effect was to write a `@State` and re-evaluate this body once a
                // second for a label that never draws the value. `task(id:)` cancels the work the
                // moment the condition stops holding and starts it again when it holds, so a page
                // that shows no running time schedules nothing at all.
                //
                // `Task.sleep` is what makes the loop cancellable: it throws on cancellation, and
                // the task returns then. `currentTime` is read from the clock when the status
                // changes (below), so the first second after connecting shows the true elapsed
                // time rather than a value left over from an earlier session.
                .task(id: showsRuntimeClock) {
                    guard showsRuntimeClock else { return }
                    while !Task.isCancelled {
                        currentTime = Date()
                        do {
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        } catch {
                            return
                        }
                    }
                }
                // The clock starts and stops with the transition itself, so the grace period is
                // measured from the attempt rather than from the last status notification.
                .onChangeCompat(of: isBusy) { busy in
                    Task { @MainActor in
                        busySince = busy ? Date() : nil
                    }
                }
                .onChangeCompat(of: profile.status) { status in
                    Task { @MainActor in
                        // The time is drawn from this value and the clock above only runs while the
                        // tunnel is up, so the transition into that state is when the value has to
                        // become the clock again.
                        currentTime = Date()
                        if isStarting {
                            if status == .disconnected {
                                isStarting = false
                                if #available(iOS 16.0, macOS 13.0, tvOS 17.0, *) {
                                    await checkStartupError()
                                }
                            } else if status.isConnectedStrict {
                                isStarting = false
                                environments.commandClient.connect()
                            }
                        }
                    }
                }
        }

        private var runtimeDuration: String? {
            guard let connectedDate = profile.connectedDate else { return nil }
            let interval: TimeInterval
            if Variant.screenshotMode {
                interval = 3600
            } else {
                interval = currentTime.timeIntervalSince(connectedDate)
            }
            guard interval >= 0 else { return nil }

            let hours = Int(interval) / 3600
            let minutes = Int(interval) / 60 % 60
            let seconds = Int(interval) % 60

            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                return String(format: "%d:%02d", minutes, seconds)
            }
        }

        @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
        private func checkStartupError() async {
            if let alertState = await profile.checkLastDisconnectError() {
                alert = alertState
            }
        }

        private nonisolated func switchProfile(_ isEnabled: Bool) async {
            do {
                if isEnabled {
                    await MainActor.run { isStarting = true }
                    try await profile.start()
                } else {
                    try await profile.stop()
                }
            } catch {
                await MainActor.run {
                    isStarting = false
                    let action = isEnabled ? "start service" : "stop service"
                    alert = AlertState(action: action, error: error)
                }
            }
        }

        /// Submit the stop request for a transition that has stopped moving.
        ///
        /// Deliberately `stop()` and never the toggle: in `.disconnecting` the toggle's
        /// `!profile.status.isConnected` is false, so a toggle would *start* the tunnel. The flag
        /// only stops this control from re-entering while the request is being submitted;
        /// `ExtensionProfile.stop()` is itself safe to call more than once and returns as soon as
        /// the system request is out, so a second press is not a second teardown.
        private nonisolated func requestStop() async {
            await MainActor.run {
                isStopping = true
            }
            do {
                try await profile.stop()
            } catch {
                await MainActor.run {
                    alert = AlertState(action: "stop service", error: error)
                }
            }
            await MainActor.run {
                isStopping = false
            }
        }
    }
}


    // The original wraps this modifier in `#if os(iOS)` (its lines 134-144), and the reason is
    // `Variant.debugNoIOS26`: that flag is declared under `#if os(iOS)` in
    // `Library/Shared/Variant.swift:27-30`, so naming it on the Mac is a symbol macOS does not
    // have. Its one use site is already inside an iOS branch at the top of this file.
    #if os(iOS)
    private struct HakoPrimaryTintModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *), !Variant.debugNoIOS26 {
                content.tint(.primary)
            } else {
                content
            }
        }
    }
    #endif


/// `buttonBorderShape(.capsule)` where the platform has it.
///
/// The shape is iOS 15 / tvOS 15 / macOS **14**, and this target builds for macOS 13. A view
/// modifier chain cannot be branched inside itself, and removing the line outright would change
/// the control's shape on every OS that does have it - so the condition lives in a modifier that
/// applies the shape only where it exists and passes the content through unchanged otherwise.
private struct HakoCapsuleBorderShape: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
            content.buttonBorderShape(.capsule)
        } else {
            content
        }
    }
}
