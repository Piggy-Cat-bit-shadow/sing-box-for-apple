import ApplicationLibrary
import Foundation
import Library
import SwiftUI

/// Which iOS design family the app is running.
///
/// Resolved from the device idiom and nothing else. Size class is deliberately not consulted here:
/// an iPad in Split View, Slide Over, Stage Manager or a narrow window is still an iPad and must
/// keep upstream's presentation rather than collapsing into the phone's shell. How the iPad lays
/// out once it is there is upstream's own business, via `SidebarLayout.isEnabled`.
enum SFIUIFamily: Equatable {
    /// iPhone: Hako's validated presentation.
    case hakoPhone
    /// iPad: upstream's presentation, unmodified.
    case upstreamPad

    /// Pure, so the rule can be stated and checked without a device.
    static func resolve(idiom: UIUserInterfaceIdiom) -> SFIUIFamily {
        switch idiom {
        case .pad:
            return .upstreamPad
        default:
            return .hakoPhone
        }
    }

    static var current: SFIUIFamily {
        resolve(idiom: UIDevice.current.userInterfaceIdiom)
    }
}

@main
struct Application: App {
    @UIApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
    @StateObject private var environments = ExtensionEnvironments()
    @StateObject private var peerStore = TailscaleSSHPeerStore()
    @StateObject private var tailscaleViewModel = TailscaleStatusViewModel()
    @StateObject private var taildropSendManager = TaildropSendManager()
    @StateObject private var taildropInbox = TaildropInboxViewModel()

    init() {
        Task { @MainActor in
            ImportedFontStore.shared.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
            // The one place the design family is chosen, and it sits above both roots rather than
            // inside either of them. `MainView` stays upstream's iPad root; `HakoPhoneRootView`
            // stays Hako's phone presentation; neither has to know the other exists.
            //
            // Every modifier hangs off the `Group`, so both families receive identical environment
            // wiring and share one set of model objects. Presentation differs; state does not.
            Group {
                switch SFIUIFamily.current {
                case .hakoPhone:
                    HakoPhoneRootView()
                case .upstreamPad:
                    MainView()
                }
            }
            .tailscaleStatusSubscription(tailscaleViewModel, environments: environments, peerStore: peerStore)
            .environmentObject(environments)
            .environmentObject(peerStore)
            .environmentObject(tailscaleViewModel)
            .environmentObject(taildropSendManager)
            .environmentObject(taildropInbox)
        }
    }
}
