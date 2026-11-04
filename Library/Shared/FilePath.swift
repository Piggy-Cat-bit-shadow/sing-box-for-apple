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
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName) {
            return container
        }
        isUsingProcessLocalDirectory = true
        NSLog(
            "[JiejieBox] App Group '%@' is not available to this process; falling back to a private container. " +
                "The GUI keeps working; the Packet Tunnel needs a provisioning profile that grants this group.",
            groupName
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
