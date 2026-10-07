import Libbox
import Library
import SwiftUI

@MainActor
public struct DashboardView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var coordinator = DashboardViewModel()
    @StateObject private var cardConfiguration = DashboardCardConfiguration()
    /// Persisted, so the install flow takes the screen once and never again.

    #if os(iOS)
    #endif

    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
        @Environment(\.cardConfigurationVersion) private var cardConfigurationVersion
    #endif

    public init() {}

    public var body: some View {
        content
            .alert($coordinator.alert)
            .onAppear {
                coordinator.setEnvironments(environments)
                #if os(macOS)
                    Task { await coordinator.reload() }
                #endif
            }
        // The home's top-right control moved to the tools page whole, on the review's
        // instruction: the home is the tunnel's page, and a second-level management menu does not
        // belong on it. Its remote-server state went with it.
        #if os(tvOS)
            .navigationDestination(item: $environments.pendingImportRemoteProfile) { request in
                NewProfileView(.init(name: request.name, url: request.url))
                    .environmentObject(environments)
                    .onDisappear {
                        environments.profileUpdate.send()
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            BackButton()
                        }
                    }
        }
        #else
        .sheet(item: $environments.pendingImportRemoteProfile) { request in
                    importRemoteProfileSheet(for: request)
                }
        #endif
        #if os(macOS)
            .onChangeCompat(of: controlActiveState) { state in
                guard state != .inactive, Variant.useSystemExtension, !coordinator.isLoading else { return }
                Task { await coordinator.reload() }
        }
        .onChangeCompat(of: cardConfigurationVersion) { _ in
            Task { await cardConfiguration.reload() }
        }
        #endif
    }

    private func importRemoteProfileSheet(for request: ImportRemoteProfileRequest) -> some View {
        NavigationSheet(title: "Import Profile", onDismiss: {
            environments.profileUpdate.send()
        }, content: {
            NewProfileView(.init(name: request.name, url: request.url))
                .environmentObject(environments)
        })
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
            if Variant.useSystemExtension, !coordinator.systemExtensionInstalled {
                FormView {
                    InstallSystemExtensionButton {
                        await coordinator.reload()
                    }
                }
            } else {
                mainContent
            }
        #else
            mainContent
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        if environments.remoteServer != nil {
            RemoteDashboardView(commandClient: environments.commandClient, cardConfiguration: cardConfiguration)
        } else if environments.extensionProfileLoading {
            ProgressView()
        } else {
            // The home draws whether or not there is a tunnel to drive, which is what the
            // reference does: it provisions a bundled profile on first run so the page is never
            // replaced, and here the page reports the missing extension itself and offers to
            // install it. What used to be here was an install page *instead of* the home, so a
            // new reader saw a button where the product should have been.
            let profile = environments.extensionProfile ?? ExtensionProfile.notInstalled
            activeDashboardView
                .environmentObject(profile)
                .onChangeCompat(of: profile.status) { status in
                    #if os(macOS)
                        if Variant.useSystemExtension, status == .connected {
                            UserServiceEndpointPublisher.shared.refreshEndpointRegistration()
                            UserServiceEndpointPublisher.shared.checkExtensionRequirements()
                        }
                    #endif
                }
                // The one-time "Install Network Extension" page lived here, and the review
                // removed it: it existed to hold a button that did what the home's own install
                // button already does, so it asked the reader to press install twice. The
                // install itself is unchanged and still lives on the home.
        }
    }

    private var activeDashboardView: some View {
        ActiveDashboardView(coordinator: coordinator, cardConfiguration: cardConfiguration)
    }
}
