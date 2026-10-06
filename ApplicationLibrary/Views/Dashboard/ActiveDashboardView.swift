import Foundation
import Libbox
import Library
import SwiftUI

@MainActor public struct ActiveDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @ObservedObject private var coordinator: DashboardViewModel
    @ObservedObject private var cardConfiguration: DashboardCardConfiguration
    #if os(tvOS)
        @State private var showCardManagement = false
        @State private var showGroups = false
        @State private var showConnections = false
        @State private var buttonState = ButtonVisibilityState()
    #endif

    public init(coordinator: DashboardViewModel, cardConfiguration: DashboardCardConfiguration) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _cardConfiguration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        viewContent
    }

    @ViewBuilder private var viewContent: some View {
        if coordinator.isLoading {
            ProgressView()
            #if os(iOS) || os(tvOS)
                .onAppear {
                    Task {
                        await coordinator.reload()
                    }
                }
            #endif
        } else {
            content.onAppear {
                guard !Variant.screenshotMode, profile.status.isConnected else {
                    return
                }
                Task {
                    await coordinator.reloadSystemProxy()
                }
            }.onChangeCompat(of: profile.status) { status in
                guard !Variant.screenshotMode, status == .connected else {
                    return
                }
                Task {
                    await coordinator.reloadSystemProxy()
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            overviewPage
        }
        #if os(tvOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                navigationButtons
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showCardManagement = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                StartStopButton()
            }
        }
        .navigationDestination(isPresented: $showGroups) {
            GroupListView()
                .navigationTitle("Groups")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        BackButton()
                    }
                }
        }
        .navigationDestination(isPresented: $showConnections) {
            ConnectionListView()
                .navigationTitle("Connections")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        BackButton()
                    }
                }
        }
        .navigationDestination(isPresented: $showCardManagement) {
            CardManagementView(onDisappear: {
                Task { await cardConfiguration.reload() }
            })
            .navigationTitle("Dashboard Items")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    BackButton()
                }
            }
        }
        #endif
        .onAppear {
            environments.connect()
        }.onChangeCompat(of: scenePhase) { phase in
            guard phase == .active else {
                return
            }
            environments.connect()
        }.onChangeCompat(of: profile.status) { status in
            guard status.isConnected else {
                return
            }
            environments.connect()
        }.onReceive(environments.profileUpdate) { _ in
            Task {
                await coordinator.reload()
            }
        }.onReceive(environments.selectedProfileUpdate) { _ in
            Task {
                await coordinator.updateSelectedProfile()
                if profile.status.isConnected {
                    await coordinator.reloadSystemProxy()
                }
            }
        }
        #if os(tvOS)
        .onReceive(environments.commandClient.$groups) { _ in
            Task { @MainActor in
                updateButtonVisibility()
            }
        }.onReceive(profile.$status) { _ in
            Task { @MainActor in
                updateButtonVisibility()
            }
        }.onAppear {
            updateButtonVisibility()
        }
        #endif
    }

    /// The dashboard's content.
    ///
    /// Every platform except the focus one presents the HAKO/Clash home: the same
    /// cards, in the same order, on the same canvas. The desktop used to keep the
    /// original card grid, which meant the Mac's first page and the phone's first page
    /// were two different products sharing a data layer - the exact split this
    /// migration exists to close. The focus platform keeps the grid, which is the right
    /// shape for a television and out of scope here.
    @ViewBuilder
    private var overviewPage: some View {
        #if os(tvOS)
            OverviewView(
                $coordinator.profileList,
                $coordinator.selectedProfileID,
                $coordinator.systemProxyAvailable,
                $coordinator.systemProxyEnabled,
                cardConfiguration: cardConfiguration
            )
        #else
            HakoHomeView(
                profileList: $coordinator.profileList,
                selectedProfileID: $coordinator.selectedProfileID,
                systemProxyAvailable: $coordinator.systemProxyAvailable,
                systemProxyEnabled: $coordinator.systemProxyEnabled,
                tunnelIsInstalled: environments.extensionProfile != nil,
                installTunnel: {
                    try? await ExtensionProfile.install()
                    await environments.reload()
                },
                profileLoadFailure: coordinator.profileLoadError,
                retryProfileLoad: {
                    await coordinator.reload()
                },
                cardConfiguration: cardConfiguration
            )
        #endif
    }

    #if os(tvOS)
        private func updateButtonVisibility() {
            var newState = buttonState
            newState.update(profile: profile, commandClient: environments.commandClient)
            if newState != buttonState {
                buttonState = newState
            }
        }

        private var navigationButtons: some View {
            NavigationButtonsView(
                showGroupsButton: buttonState.showGroupsButton,
                showConnectionsButton: buttonState.showConnectionsButton,
                groupsCount: buttonState.groupsCount,
                connectionsCount: buttonState.connectionsCount,
                onGroupsTap: {
                    showGroups = true
                },
                onConnectionsTap: {
                    showConnections = true
                }
            )
        }
    #endif
}
