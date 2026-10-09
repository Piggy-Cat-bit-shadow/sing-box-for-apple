// In the app, `SubscriptionInfo` reaches `Profile.swift` from elsewhere in the same `Library`
// module. In this test package the profile record is compiled as its own module, so the type needs
// an import. That import cannot be added to `Profile.swift` itself - it is a symlink to the file
// that ships, and the shipping module must not name a target that does not exist there.
//
// `@_exported` re-exports the whole `Core` module into `ProfileUnderTest`, which is what makes
// `Profile.swift`'s unqualified use of `SubscriptionInfo` resolve without touching that file.

@_exported import Core
