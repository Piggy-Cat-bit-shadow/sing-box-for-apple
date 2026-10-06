import Library
import NetworkExtension
import SwiftUI

@MainActor
public struct StartStopButton: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    private let showsRuntimeDuration: Bool

    public init(showsRuntimeDuration: Bool = false) {
        self.showsRuntimeDuration = showsRuntimeDuration
    }

    public var body: some View {
        Group {
            if let profile = environments.extensionProfile {
                ToggleConnectionButton(showsRuntimeDuration: showsRuntimeDuration)
                    .environmentObject(profile)
            } else {
                Button {} label: {
                    #if os(tvOS)
                        Image(systemName: "play.fill")
                    #else
                        Label("Start", systemImage: "play.fill")
                    #endif
                }
                .labelStyle(.iconOnly)
                .disabled(true)
            }
        }
        .disabled(environments.emptyProfiles)
    }

    private struct ToggleConnectionButton: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @EnvironmentObject private var profile: ExtensionProfile
        @State private var alert: AlertState?
        @State private var currentTime = Date()
        @State private var isStarting = false
        let showsRuntimeDuration: Bool

        private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        var body: some View {
            // The reference's action: one full-width button that names what it will do, filled
            // when it will connect and destructive-toned when it will disconnect, with a
            // progress line while it is working. Ours was a compact icon button beside the
            // state text, so the card's main action was the smallest thing on it.
            Group {
                if isStarting || !profile.status.isSwitchable {
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
                            if profile.status.isConnectedStrict, let duration = runtimeDuration {
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
                            .frame(maxWidth: .infinity)
                        }
                    }
                    #if os(iOS)
                        .hakoConnectionActionButtonStyle(isDestructive: profile.status.isConnected)
                    #endif
                    .controlSize(.large)
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

#if os(iOS)
    private struct PrimaryTintModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *), !Variant.debugNoIOS26 {
                content.tint(.primary)
            } else {
                content
            }
        }
    }
#endif
