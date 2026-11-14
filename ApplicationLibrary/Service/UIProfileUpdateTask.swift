import BackgroundTasks
import Foundation
import Library
import os
#if canImport(UIKit)
    import UIKit
#endif

#if os(iOS) || os(tvOS)
    private let logger = Logger(category: "UIProfileUpdateTask")

    public class UIProfileUpdateTask: BGAppRefreshTask {
        private static let taskSchedulerPermittedIdentifier = AppConfiguration.backgroundTaskID

        private static var registered = false
        public static func configure() throws {
            if !registered {
                let success = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskSchedulerPermittedIdentifier, using: nil) { task in
                    NSLog("profile update task started")
                    Task {
                        await UIProfileUpdateTask.getAndUpdateProfiles(task)
                    }
                }
                if !success {
                    throw NSError(domain: "UIProfileUpdateTask", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Register task failed")])
                }
                registered = true
            }
            Task {
                BGTaskScheduler.shared.cancelAllTaskRequests()
                let profiles = try await ProfileManager.listAutoUpdateEnabled()
                if profiles.isEmpty {
                    return
                }
                try scheduleUpdate(ProfileUpdateTask.calculateEarliestBeginDate(profiles))
            }
            Task {
                if await UIApplication.shared.backgroundRefreshStatus != .available {
                    await updateOnce()
                }
            }
        }

        private nonisolated static func updateOnce() async {
            NSLog("update profiles at start since background refresh unavailable")
            let profiles: [Profile]
            do {
                profiles = try await ProfileManager.listAutoUpdateEnabled()
            } catch {
                return
            }
            if profiles.isEmpty {
                return
            }
            _ = await ProfileUpdateTask.updateProfiles(profiles)
        }

        private nonisolated static func getAndUpdateProfiles(_ task: BGTask) async {
            // Installed BEFORE any work starts.
            //
            // This used to be set after the refresh had already finished, which means the one case
            // it exists for - the work outliving the task's time budget - was the one case it never
            // covered. A `BGTask` whose handler never runs is terminated by the system with the task
            // still uncompleted.
            task.expirationHandler = {
                try? scheduleUpdate(nil)
            }

            let profiles: [Profile]
            do {
                profiles = try await ProfileManager.listAutoUpdateEnabled()
            } catch {
                // # Every exit completes the task
                //
                // `BGTask.setTaskCompleted(success:)` must be called exactly once per task. Both
                // early returns here used to skip it, and the system charges an uncompleted task to
                // the app's background budget until refreshes stop being granted at all - so a single
                // unreadable profile list could end background updating for good. There is nothing to
                // do, which is a success, not an abandonment.
                logger.warning("profile update task: could not list profiles: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
                return
            }
            guard !profiles.isEmpty else {
                task.setTaskCompleted(success: true)
                return
            }
            let success = await ProfileUpdateTask.updateProfiles(profiles)
            try? scheduleUpdate(ProfileUpdateTask.calculateEarliestBeginDate(profiles))
            task.setTaskCompleted(success: success)
        }

        private static func scheduleUpdate(_ earliestBeginDate: Date?) throws {
            let request = BGAppRefreshTaskRequest(identifier: taskSchedulerPermittedIdentifier)
            request.earliestBeginDate = earliestBeginDate
            try BGTaskScheduler.shared.submit(request)
        }
    }
#endif
