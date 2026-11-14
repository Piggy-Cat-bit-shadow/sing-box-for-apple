import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public final class EditProfileViewModel: BaseViewModel {
    @Published public var isChanged = false
    @Published public var shareLinkPresented = false
    @Published public var shareLinkText: String?

    public func markAsChanged() {
        isChanged = true
    }

    public func updateProfile(_ profile: Profile, environments: ExtensionEnvironments) async {
        defer {
            isLoading = false
        }
        do {
            try await Task.sleep(nanoseconds: UInt64(100 * Double(NSEC_PER_MSEC)))
            let report = try await profile.updateRemoteProfileReporting()
            environments.profileUpdate.send()
            if report.isFailure {
                alert = AlertState(action: "update remote profile", error: RemoteProfileUpdateAlertError(report: report))
            } else if report.needsAttention {
                alert = AlertState(
                    title: String(localized: "Update"),
                    message: "\(profile.name): \(report.localizedDescription)"
                )
            }
        } catch {
            alert = AlertState(action: "update remote profile", error: error)
        }
    }

    public func deleteProfile(_ profile: Profile, environments: ExtensionEnvironments, dismiss: DismissAction) async {
        do {
            try await ProfileManager.delete(profile)
        } catch {
            alert = AlertState(action: "delete profile", error: error)
            return
        }
        environments.profileUpdate.send()
        dismiss()
    }

    /// Saves the edited profile, then does the two things that follow it.
    ///
    /// # Why this is three steps and not one `do/catch`
    ///
    /// The form is disabled by `isLoading`, and the *caller* raises that flag before starting this
    /// task - so every exit has to lower it. It used to be lowered only on the success path: a
    /// failure set the alert and `return`ed with the flag still up, and `.disabled(viewModel.isLoading)`
    /// then left the fields dead for the rest of the page's life. The save button stayed enabled
    /// because it is gated on `isChanged`, so pressing it again re-entered the same dead end. That is
    /// the "editor is stuck after a failed save" report.
    ///
    /// The three steps are also three different facts and are reported as such:
    ///
    ///   * `ProfileManager.update` stores the body. Only this failing is "the save failed".
    ///   * scheduling the background refresh is bookkeeping and cannot un-save anything. Reporting it
    ///     as a failed save is what made a stored edit look lost, and it invites a retry that writes
    ///     the same body again.
    ///   * `onProfileUpdated` asks the running service to apply the new body. The save succeeded; the
    ///     apply did not, and the message says exactly that rather than "failed to save profile".
    public func saveProfile(_ profile: Profile, environments: ExtensionEnvironments) async {
        defer {
            isLoading = false
        }
        do {
            _ = try await ProfileManager.update(profile)
        } catch {
            alert = AlertState(action: "save profile", error: error)
            return
        }
        // Saved. Everything below is reported against the step that produced it.
        do {
            #if os(iOS) || os(tvOS)
                try UIProfileUpdateTask.configure()
            #else
                try await ProfileUpdateTask.configure()
            #endif
        } catch {
            alert = AlertState(action: "schedule the profile update", error: error)
        }
        do {
            try await profile.onProfileUpdated()
        } catch {
            alert = AlertState(action: "apply the saved profile", error: error)
        }
        isChanged = false
        environments.profileUpdate.send()
    }
}
