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
        let showsRuntimeDuration: Bool
        let isCompact: Bool

        private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        var body: some View {
            // The reference's action: one full-width button that names what it will do, filled
            // when it will connect and destructive-toned when it will disconnect, with a
            // progress line while it is working. Ours was a compact icon button beside the
            // state text, so the card's main action was the smallest thing on it.
            Group {
                // Busy means *transitioning* - not "not switchable", which is also true of a
                // client with no tunnel at all. That mistake put "Working…" in front of a
                // reader who has nothing installed and nothing happening.
                if isStarting || profile.status == .connecting || profile.status == .disconnecting {
                    HStack(spacing: HakoTheme.Spacing.compact) {
                        ProgressView()
                        Text("Working…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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

                .onReceive(timer) { _ in
                    guard !Variant.screenshotMode else { return }
                    Task { @MainActor in
                        currentTime = Date()
                    }
                }
                .onChangeCompat(of: profile.status) { status in
                    Task { @MainActor in
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
