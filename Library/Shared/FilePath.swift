import Foundation

public enum FilePath {
    public static let packageName = AppConfiguration.packageName
    public static let groupName = AppConfiguration.appGroupID

    /// Whether this process is running WITHOUT the App Group container.
    ///
    /// Only the Packet Tunnel needs the group, because it has to read the profiles the GUI
    /// writes. Everything else - the window, settings, profile management, the log - works in a
    /// process-local directory. So an unavailable group degrades the product instead of ending
    /// it, and this flag is the fact a diagnostic screen can show.
    public private(set) static var isUsingProcessLocalDirectory = false

    /// Resolves the directory shared between the app and its extensions.
    ///
    /// # Why this is not a force-unwrapped containerURL any more
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns a URL only when the
    /// process's code signature carries an `application-groups` entitlement containing exactly
    /// `groupName`, i.e. when the build was signed with a provisioning profile that grants that
    /// group. A build signed by a third-party signing service with its own profile commonly does
    /// not grant it, and the call then returns nil.
    ///
    /// The previous implementation stored that nil in a `URL!` and unwrapped it at the first
    /// access. The first access happens during launch - opening the profile database - so a
    /// re-signed build terminated before it could draw anything, which reads to the user as "the
    /// app installs and will not open". The GUI does not need the group; returning a valid local
    /// directory keeps the product usable and confines the failure to the tunnel, where it can be
    /// reported as a tunnel error instead of a process death.
    ///
    /// The fallback is deliberately PER PROCESS and named so: two processes with different
    /// containers must not believe they share state, and a tunnel that silently wrote to a
    /// private copy would be worse than one that refuses to start.
    private static func resolveSharedDirectory() -> URL {
        for identifier in candidateGroupIdentifiers() {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                if identifier != groupName {
                    // A re-signed build: the identifier baked into Info.plist is not what the
                    // signature grants, and the profile is what told us which one it does.
                    NSLog("[JiejieBox] using granted App Group '%@' instead of '%@'", identifier, groupName)
                }
                return container
            }
        }
        isUsingProcessLocalDirectory = true
        NSLog(
            "[JiejieBox] no App Group is available to this process (candidates: \(candidateGroupIdentifiers().count)); " +
                "falling back to a private container. The GUI keeps working; logs and statistics need the shared container."
        )
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("JiejieBox-Shared", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[JiejieBox] could not create the fallback directory %@: %@", directory.path, String(describing: error))
        }
        return directory
    }

    /// The App Group identifiers this build might have been granted, most specific first.
    ///
    /// # Why the baked identifier is not enough
    ///
    /// `AppGroupIdentifier` in Info.plist is written at build time. A re-signing service replaces
    /// the entitlements and the embedded profile with its own, granting groups it owns - in the
    /// build this was written for, `group.<team-hash>.1` through `.5` - and it does not rewrite a
    /// custom Info.plist key. The app then asked for a group nobody had granted, got nil, and both
    /// processes fell back to private containers: the tunnel started and the interface showed it as
    /// connected, while every log line, statistic and connection stayed empty, because the command
    /// socket lives in the extension's container.
    ///
    /// The profile inside the bundle is the authority on what this signature grants, so it is read
    /// here. Both the app and the extension read the same profile and probe the same identifiers in
    /// the same order, so they choose the same container without knowing about each other.
    private static func candidateGroupIdentifiers() -> [String] {
        var identifiers: [String] = []
        for identifier in [groupName] + grantedGroupIdentifiers() where !identifier.isEmpty && !identifiers.contains(identifier) {
            identifiers.append(identifier)
        }
        return identifiers
    }

    /// Every `group.*` string in the embedded provisioning profile.
    ///
    /// The profile is a CMS envelope around an XML plist; the payload is readable as text even
    /// though the envelope is not. Each candidate is only a candidate - `containerURL` is what
    /// decides - so a string the signature does not grant costs one failed lookup.
    private static func grantedGroupIdentifiers() -> [String] {
        #if os(macOS)
            // A macOS build has no embedded profile; its entitlements are the signature itself.
            return []
        #else
            // An app extension's own bundle may carry no profile; the containing app's does. Walk
            // up a few levels so both processes read a profile, and dedupe across them.
            var identifiers: [String] = []
            var roots = [Bundle.main.bundleURL]
            var current = Bundle.main.bundleURL
            for _ in 0 ..< 3 {
                current = current.deletingLastPathComponent()
                roots.append(current)
                if current.pathExtension == "app" { break }
            }
            for root in roots {
                let profile = root.appendingPathComponent("embedded.mobileprovision")
                guard let data = try? Data(contentsOf: profile) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                for chunk in text.components(separatedBy: "<string>").dropFirst() {
                    guard let value = chunk.components(separatedBy: "</string>").first else { continue }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("group."), !identifiers.contains(trimmed) else { continue }
                    identifiers.append(trimmed)
                }
            }
            return identifiers
        #endif
    }


    #if os(tvOS)
        public static let sharedDirectory = resolveSharedDirectory()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    #else
        public static let sharedDirectory = resolveSharedDirectory()
    #endif

    #if os(iOS)
        public static let cacheDirectory = sharedDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    #elseif os(tvOS)
        public static let cacheDirectory = sharedDirectory
    #elseif os(macOS)
        public static var cacheDirectory: URL {
            sharedDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
        }
    #endif

    #if os(macOS)
        public static var workingDirectory: URL {
            cacheDirectory.appendingPathComponent("Working", isDirectory: true)
        }
    #else
        public static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)

    #endif

    public static var iCloudDirectory = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true) ?? URL(string: "stub")!
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}
