import Foundation

// `Profile.updateRemoteProfile()` commits through `ProfileManager.update` in the app. Here that call
// is never reached by the tests - they inject `refreshRemoteProfile(persist:)` - but the symbol has
// to exist for the file to compile, and it must do nothing rather than pretend to have a database.
//
// If a test ever calls the default path by mistake, this throws instead of silently passing: a
// no-op would make "the metadata was persisted" impossible to distinguish from "nothing happened".

public enum ProfileManager {
    public struct NoDatabase: LocalizedError {
        public var errorDescription: String? {
            "The test package has no profile database; inject `persist:` instead."
        }
    }

    public static func update(_ profile: Profile) async throws {
        _ = profile
        throw NoDatabase()
    }
}
