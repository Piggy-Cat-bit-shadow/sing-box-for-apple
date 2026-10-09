//
//  Application.swift
//  SFI
//
//  The one place the client's design family is chosen.
//
//  # What the family is
//
//  `SFIUIFamily` answers one question - which design system owns this launch - and it
//  answers it from the device idiom, never from a size class. That distinction is the
//  whole point of this file: an iPad in Split View, Slide Over, Stage Manager or a
//  narrow window is still an iPad, and the upstream presentation is what it must keep.
//  Size class is upstream's own business *inside* its presentation, through
//  `SidebarLayout.isEnabled`, and is deliberately not consulted here.
//
//  # Where the two routes lead
//
//    .hakoPhone   -> `HakoPhoneRootView` (fork-owned: the Hako shell and its pages)
//    .upstreamPad -> `MainView`           (upstream-owned, byte-for-byte)
//
//  Neither route knows the other exists. The environment wiring hangs off the `Group`
//  above both, so the model objects, the command client and the subscription are
//  created once and shared - presentation differs, state does not.
//
//  See `docs/APPLE-ARCHITECTURE-AUDIT.md` for the evidence and
//  `docs/APPLE-UI-ROUTING.md` for the reachability rules the static audit enforces.
//

import ApplicationLibrary
import Foundation
import Library
import SwiftUI

/// Which design system owns this launch.
enum SFIUIFamily: Equatable {
    /// iPhone: the fork's Hako presentation.
    case hakoPhone
    /// iPad (and anything that is not an iPhone): upstream's presentation, unmodified.
    case upstreamPad

    /// The rule, as a pure function so it can be stated and tested without a device.
    ///
    /// **Exactly one idiom selects the Hako shell: `.phone`.** Everything else keeps the
    /// upstream presentation, and each "everything else" is a deliberate decision rather
    /// than a fallthrough:
    ///
    ///   - `.pad` - the product requirement. iPadOS always gets the official UI, whichever
    ///     window environment it is in.
    ///   - `.unspecified` - the conservative answer. `UIDevice.userInterfaceIdiom` is
    ///     `.unspecified` when the idiom has not been resolved, which happens in some
    ///     extension, preview and test contexts. Guessing "phone" there would hand the Hako
    ///     shell to something that is not known to be a phone.
    ///   - `.mac` (Mac Catalyst) - the iOS app target can be built for Catalyst, where the
    ///     idiom is `.pad` anyway. It is not a shipping configuration for this fork.
    ///   - `.tv` - the tvOS target has its own scene (`SFT/Application.swift`) and never
    ///     runs this code, so this arm is unreachable here. tvOS is explicitly out of scope
    ///     for this refactor.
    ///   - `.carPlay` - not a configuration this client ships.
    ///
    /// The single positive arm plus a `default` is written this way on purpose. Naming every
    /// negative case means naming SDK cases that do not exist on every platform this file is
    /// compiled for, which is a compile error rather than a safety net; and an `@unknown
    /// default`-only switch over an imported enum is not exhaustive. A rule with one arm that
    /// grants the fork's presentation is also the rule a static audit can check.
    static func resolve(idiom: UIUserInterfaceIdiom) -> SFIUIFamily {
        switch idiom {
        case .phone:
            return .hakoPhone
        default:
            return .upstreamPad
        }
    }

    /// The family for the running device.
    ///
    /// `UIDevice.current` is main-actor isolated on iOS, so this is too.
    @MainActor
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
            await ImportedFontStore.shared.bootstrap()
        }
    }

    var body: some Scene {
        WindowGroup {
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
