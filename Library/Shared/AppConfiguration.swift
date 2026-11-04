import Foundation

public enum AppConfiguration {
    /// The identifier base the targets are built with.
    ///
    /// # Why a missing key is reported instead of terminating
    ///
    /// The value is baked into Info.plist from the `BasePackageIdentifier` build setting, so a
    /// correctly built app always has it. A build whose signing or packaging pipeline rewrote or
    /// dropped custom Info.plist keys used to kill the process before the first frame. The GUI
    /// has a usable fallback - its own bundle identifier - and the tunnel will report a clear
    /// error when it cannot derive its extension identifier, which is the better failure: the
    /// user sees an app that opens and a tunnel that says why it will not.
    public static let packageName: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String, !value.isEmpty {
            return value
        }
        let fallback = Bundle.main.bundleIdentifier ?? "io.jiejiebox.app"
        NSLog("[JiejieBox] BasePackageIdentifier missing from Info.plist; using the bundle identifier %@", fallback)
        return fallback
    }()

    /// The App Group the app and its extensions share.
    ///
    /// An empty value means "none available": the shared directory then falls back to a private
    /// container (see FilePath) and capabilities that need the group report their own error.
    public static let appGroupID: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String, !value.isEmpty {
            return value
        }
        NSLog("[JiejieBox] AppGroupIdentifier missing from Info.plist; no shared container is available")
        return ""
    }()

    /// The team prefix, taken from the App Group identifier.
    ///
    /// A re-signed build may carry no App Group at all - that is the degraded mode FilePath now
    /// supports - so a missing or malformed identifier is a state to survive, not a programming
    /// error. This used to `fatalError`, which would have crashed exactly the builds the fallback
    /// exists for, and would have done it at a point unrelated to the missing group.
    ///
    /// An empty result makes the XPC requirements built from it unsatisfiable, so those
    /// connections fail closed instead of matching a wrong peer. Nothing treats "" as a team.
    public static var teamID: String {
        guard let dotIndex = appGroupID.firstIndex(of: ".") else {
            NSLog("[JiejieBox] no App Group identifier; team-scoped XPC requirements are unavailable")
            return ""
        }
        return String(appGroupID[..<dotIndex])
    }

    /// The bundle identifier of the Packet Tunnel extension to ask the system for.
    ///
    /// # Why it is discovered rather than derived
    ///
    /// This used to be `packageName + ".extension"`, with `packageName` baked into Info.plist at
    /// build time. A re-signing tool rewrites the bundle identifiers throughout the package -
    /// that is how a sideloaded build is made to match its provisioning profile - but it does
    /// not rewrite a custom Info.plist key that happens to hold the old base. The app then asked
    /// the system for a tunnel provider that no longer existed, so the VPN silently never
    /// started even though the GUI was fine.
    ///
    /// Enumerating the embedded PlugIns answers the question the system will actually ask: which
    /// packet-tunnel extension is in THIS bundle, and what is its identifier. On a normally built
    /// app that is exactly `packageName + ".extension"`, so the official build is unaffected.
    public static var extensionBundleID: String {
        if let discovered = embeddedPacketTunnelBundleID {
            return discovered
        }
        return "\(packageName).extension"
    }

    private static let embeddedPacketTunnelBundleID: String? = {
        #if os(macOS)
            return nil
        #else
            guard let pluginsURL = Bundle.main.builtInPlugInsURL,
                  let entries = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil)
            else {
                return nil
            }
            for entry in entries where entry.pathExtension == "appex" {
                guard let bundle = Bundle(url: entry),
                      let identifier = bundle.bundleIdentifier,
                      let extensionDictionary = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                      let pointIdentifier = extensionDictionary["NSExtensionPointIdentifier"] as? String,
                      pointIdentifier == "com.apple.networkextension.packet-tunnel"
                else {
                    continue
                }
                return identifier
            }
            return nil
        #endif
    }()

    public static var systemExtensionBundleID: String {
        "\(packageName).system"
    }

    #if os(macOS)
        /// After a system-extension replace, launchd keeps the previous version's per-version provider job
        /// registered and still owning the NEMachServiceName endpoint; it refuses to let the new version
        /// reclaim a fixed endpoint name, so the app reaches the dead old listener. The version suffix gives
        /// each build its own endpoint. Must equal NEMachServiceName in SystemExtension/Info.plist, which is
        /// baked from $(APP_GROUP_IDENTIFIER).system.$(MARKETING_VERSION); Bundle.version is that same value.
        public static var systemExtensionMachServiceName: String {
            "\(appGroupID).system.\(Bundle.main.version)"
        }
    #endif

    public static var packetTunnelBundleIDs: [String] {
        if extensionBundleID == systemExtensionBundleID {
            return [extensionBundleID]
        }
        return [extensionBundleID, systemExtensionBundleID]
    }

    public static var fileProviderDomainID: String {
        "\(packageName).workingdir"
    }

    public static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    public static var profileUTType: String {
        "\(packageName).profile"
    }

    public static var backgroundTaskID: String {
        "\(packageName).update_profiles"
    }

    public static var iCloudContainerID: String {
        "iCloud.\(packageName)"
    }

    #if os(macOS) || JAILBREAK
        public static var rootHelperBundleID: String {
            "\(packageName).helper"
        }

        public static var rootHelperMachService: String {
            "\(appGroupID).helper"
        }
    #endif
}
