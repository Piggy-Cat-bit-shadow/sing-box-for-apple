import Foundation
import Libbox

/// One configuration document as the client could obtain it.
///
/// The three ways of having no document are different and are kept apart: `absent` is the daemon
/// saying "no record yet", `unsupported` is an older kernel that has no such RPC, and `unavailable`
/// is a real failure (no daemon, transport error, undecodable payload). Showing the third as the
/// second would hide a broken connection behind a compatibility message.
public enum ConfigurationDocumentProbe<Value: Sendable>: Sendable {
    case document(Value)
    case absent
    case unsupported
    case unavailable(String)
}

/// The plan, the last apply report and the last recovery, read together.
public struct ConfigurationStatus: Sendable {
    public var preview: ConfigurationDocumentProbe<ConfigurationPlan>
    public var lastChange: ConfigurationDocumentProbe<ConfigurationReport>
    public var lastRecovery: ConfigurationDocumentProbe<ConfigurationRecovery>

    public init(
        preview: ConfigurationDocumentProbe<ConfigurationPlan>,
        lastChange: ConfigurationDocumentProbe<ConfigurationReport>,
        lastRecovery: ConfigurationDocumentProbe<ConfigurationRecovery>
    ) {
        self.preview = preview
        self.lastChange = lastChange
        self.lastRecovery = lastRecovery
    }
}

/// Reads the daemon's configuration documents through the same standalone client the rest of the
/// app uses (Libbox, over the kernel's own transport).
///
/// The plan is previewed against the SELECTED profile's stored document because that is the
/// document a start would apply; every probe is a normal `BlockingIO` call, so none of them may run
/// on the main thread.
public enum ConfigurationStatusProbe {
    /// Everything the Core screen shows, read once per appearance.
    public static func load() async -> ConfigurationStatus {
        var plan: ConfigurationDocumentProbe<ConfigurationPlan> = .absent
        if let content = await selectedProfileContent() {
            plan = await preview(content)
        }
        return ConfigurationStatus(
            preview: plan,
            lastChange: await lastChange(),
            lastRecovery: await lastRecovery()
        )
    }

    /// What applying `configContent` would mean for the running instance.
    public static func preview(_ configContent: String) async -> ConfigurationDocumentProbe<ConfigurationPlan> {
        await probe { client in
            try client.previewServiceChange(configContent)
        }
    }

    /// What the last apply attempt planned and did.
    public static func lastChange() async -> ConfigurationDocumentProbe<ConfigurationReport> {
        await probe { client in
            try client.getLastServiceChange()
        }
    }

    /// The last recovery from a failed start.
    public static func lastRecovery() async -> ConfigurationDocumentProbe<ConfigurationRecovery> {
        await probe { client in
            try client.getLastConfigRecovery()
        }
    }

    private static func probe<Value: Decodable & Sendable>(
        _ call: @escaping @Sendable (LibboxCommandClient) throws -> LibboxStringBox?
    ) async -> ConfigurationDocumentProbe<Value> {
        await BlockingIO.run {
            let client: LibboxCommandClient
            do {
                client = try CommandTarget.standaloneClient()
            } catch {
                return .unavailable(error.localizedDescription)
            }
            do {
                guard let box = try call(client) else {
                    return .unavailable("the daemon returned no document")
                }
                switch try classifyConfigurationDocument(box.value, as: Value.self) {
                case let .document(value):
                    return .document(value)
                case .absent:
                    return .absent
                case .unsupported:
                    return .unsupported
                }
            } catch {
                // gRPC's Unimplemented is code 12: an older kernel, not a failed call. Every other
                // failure is reported as itself.
                let nsError = error as NSError
                if nsError.code == 12 {
                    return .unsupported
                }
                if let documentError = error as? ConfigurationDocumentError, documentError == .notAnObject {
                    return .unavailable("the daemon returned a document this client cannot read")
                }
                return .unavailable(error.localizedDescription)
            }
        }
    }

    /// The selected profile's stored document, or nil when nothing is selected or readable.
    private static func selectedProfileContent() async -> String? {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try? await ProfileManager.get(profileID) else {
            return nil
        }
        return try? await profile.readAsync()
    }
}
