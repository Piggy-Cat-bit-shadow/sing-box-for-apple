import Foundation
import Library

public enum ProfileUpdateTask {
    static let minUpdateInterval: TimeInterval = 15 * 60
    static let defaultUpdateInterval: TimeInterval = 60 * 60

    private static var timer: Timer?

    public static func configure() async throws {
        timer?.invalidate()
        timer = nil
        let profiles = try await ProfileManager.listAutoUpdateEnabled()
        if profiles.isEmpty {
            return
        }
        var updateInterval = profiles.map { it in
            it.autoUpdateIntervalOrDefault
        }.min()!
        if updateInterval < minUpdateInterval {
            updateInterval = minUpdateInterval
        }
        let newTimer = Timer(fire: calculateEarliestBeginDate(profiles), interval: updateInterval, repeats: true) { _ in
            Task {
                await getAndupdateProfiles()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    static func calculateEarliestBeginDate(_ profiles: [Profile]) -> Date {
        let nowTime = Date.now
        var earliestBeginDate = profiles.map { it in
            it.lastUpdated!.addingTimeInterval(it.autoUpdateIntervalOrDefault)
        }.min()!
        if earliestBeginDate <= nowTime {
            earliestBeginDate = nowTime
        }
        return earliestBeginDate
    }

    private nonisolated static func getAndupdateProfiles() async {
        do {
            _ = try await updateProfiles(ProfileManager.listAutoUpdateEnabled())
            NSLog("profile update task succeed")
        } catch {
            NSLog("profile update task failed: \(error.localizedDescription)")
        }
    }

    static func updateProfiles(_ profiles: [Profile]) async -> Bool {
        var success = true
        var prepared: [(profile: Profile, value: PreparedRemoteProfileUpdate?)] = []
        for profile in profiles {
            let profileName = profile.name
            if profile.lastUpdated! > Date(timeIntervalSinceNow: -profile.autoUpdateIntervalOrDefault) {
                continue
            }
            do {
                // Save each due profile independently. Applying and refreshing belongs to the one
                // profile that is selected after the whole batch; doing it inside this loop is what
                // let a switch during the batch refresh more than one Box.
                let value = try await profile.prepareRemoteProfileReporting()
                prepared.append((profile, value))
                NSLog("Prepared profile %@: %@", profileName, value.report.localizedDescription)
                if value.report.isFailure {
                    success = false
                }
            } catch {
                NSLog("Update profile %@ failed: %@", profileName, error.localizedDescription)
                success = false
            }
        }
        let selected = await SharedPreferences.selectedProfileID.get()
        if let final = prepared.first(where: { $0.profile.id == selected }), let value = final.value {
            do {
                let report = try await final.profile.applyPreparedRemoteProfileReporting(value)
                NSLog("Applied profile %@: %@", final.profile.name, report.localizedDescription)
                if report.isFailure {
                    success = false
                }
            } catch {
                NSLog("Apply prepared profile %@ failed: %@", final.profile.name, error.localizedDescription)
                success = false
            }
        }
        return success
    }
}

extension Profile {
    var autoUpdateIntervalOrDefault: TimeInterval {
        if autoUpdateInterval > 0 {
            return TimeInterval(autoUpdateInterval * 60)
        } else {
            return ProfileUpdateTask.defaultUpdateInterval
        }
    }
}
