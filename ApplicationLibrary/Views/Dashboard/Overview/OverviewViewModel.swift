import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public final class OverviewViewModel: BaseViewModel {
    @Published public var reasserting = false

    /// Applies the selection, then tells the running tunnel about it.
    ///
    /// # Why the failure path now puts the selection back
    ///
    /// The selection is persisted *before* the reload on purpose: `ExtensionProfile.reloadService()`
    /// reads the selected profile out of the preferences, so persisting it afterwards would reload
    /// the configuration the reader just left. The cost of that order is the state this function has
    /// to clean up - a selection that was saved but whose apply was refused.
    ///
    /// It did not clean it up. The apply's error was reported and the selection stayed saved, so the
    /// page named one configuration while the tunnel kept running another, which is the "fake
    /// switch" this path exists to prevent. Restoring the previous identifier is the honest repair:
    /// the tunnel is the truth, and the reader can choose again.
    ///
    /// The restore is guarded by **ownership**, not by "this call failed": it happens only while the
    /// persisted value is still the one this call wrote. A reader who has already chosen C while B's
    /// apply was failing must not be moved back to A by B finishing late; the last accepted
    /// selection wins, which is the contract the page's one-slot queue maintains.
    public func switchProfile(_ profileID: Int64, profile: ExtensionProfile, environments: ExtensionEnvironments) async {
        let previousProfileID = await SharedPreferences.selectedProfileID.get()
        await SharedPreferences.selectedProfileID.set(profileID)
        environments.selectedProfileUpdate.send()

        // Nothing to apply: either the tunnel is not running (the selection is the next start's
        // input, and it is already saved), or the reader re-selected what was already selected.
        guard previousProfileID != profileID, profile.status.isConnected else {
            reasserting = false
            return
        }
        do {
            try await profile.reloadService()
        } catch {
            await restoreSelection(written: profileID, to: previousProfileID, environments: environments)
            alert = AlertState(action: "reload service", error: error)
        }
        reasserting = false
    }

    /// Puts the selection back only while this call's write is still the persisted one.
    private func restoreSelection(written: Int64, to previous: Int64, environments: ExtensionEnvironments) async {
        guard previous != 0 else {
            return
        }
        let current = await SharedPreferences.selectedProfileID.get()
        guard current == written else {
            return
        }
        await SharedPreferences.selectedProfileID.set(previous)
        environments.selectedProfileUpdate.send()
    }

    /// Turns the system HTTP proxy on or off.
    ///
    /// # Why the preference is written first, and put back on failure
    ///
    /// Turning the proxy **off** cannot be sent to a live daemon: the proxy is installed by the
    /// platform layer as the tunnel starts, so the only way to remove it is to restart the service -
    /// and that restart reads `systemProxyEnabled` from the preferences to decide what to install.
    /// The preference therefore has to be written first.
    ///
    /// That order is what made the failure invisible. The preference said "off", the tunnel still
    /// had the proxy installed, and the switch showed the new value because the page draws it
    /// optimistically. Putting the preference back when the apply fails makes the durable record stop
    /// disagreeing with the tunnel, and gives the caller something true to re-read.
    ///
    /// The command client's force-unwrap is gone. `nil` there is the ordinary "no command socket"
    /// condition, not a programming error, and trapping would crash the app on the one path that is
    /// trying to *turn something off*.
    public nonisolated func setSystemProxyEnabled(_ enabled: Bool, profile: ExtensionProfile) async {
        let previous = await SharedPreferences.systemProxyEnabled.get()
        guard previous != enabled else {
            return
        }
        await SharedPreferences.systemProxyEnabled.set(enabled)
        do {
            if enabled {
                guard let client = LibboxNewStandaloneCommandClient() else {
                    throw NSError(domain: "OverviewViewModel", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The command service is not available"),
                    ])
                }
                try client.setSystemProxyEnabled(true)
            } else {
                await MainActor.run { reasserting = true }
                try await profile.restart()
            }
            await MainActor.run { reasserting = false }
        } catch {
            await SharedPreferences.systemProxyEnabled.set(previous)
            // `reasserting` is cleared on EVERY exit, not only the successful one. It gates the
            // phone's home page, so leaving it raised on the failure path turned one refused toggle
            // into a page that could never be used again - the flag had no other writer that could
            // bring it down.
            await MainActor.run { [weak self] in
                self?.reasserting = false
                self?.alert = AlertState(action: "update system proxy settings", error: error)
            }
        }
    }
}
