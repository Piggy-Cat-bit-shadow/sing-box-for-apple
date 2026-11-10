import Foundation
import Libbox

/// One configuration document as the client could obtain it.
///
/// The three ways of having no document are different and are kept apart: `absent` is the daemon
/// saying "no record yet", `unsupported` is an older kernel that has no such RPC, and `unavailable`
/// is a real failure (no daemon, transport error, undecodable payload). Showing the third as the
/// second would hide a broken connection behind a compatibility message.
///
/// `notApplicable` is a fourth, and it is not a failure either: the document this page plans against
/// is the configuration stored on THIS device, and an operation attached to a remote server has no
/// document it may send. Saying so is the honest answer; reading the local profile and shipping it to
/// that server is what this case exists to prevent.
public enum ConfigurationDocumentProbe<Value: Sendable>: Sendable {
    case document(Value)
    case absent
    case unsupported
    case unavailable(String)
    /// The question does not apply to this target, and the reason says why.
    case notApplicable(String)
}

/// The plan, the last apply report and the last recovery, read together.
///
/// `source` is the target every document in this value came from. It is carried so a page that
/// switched the session while it was reading can say which daemon it is describing, instead of
/// rendering a plan from one and a report from another. `targetChanged` is the one state that says
/// the reads were NOT performed: the session moved between capturing the target and asking for its
/// client, so answering would describe a daemon the user has left.
public struct ConfigurationStatus: Sendable {
    public var source: CommandTargetToken
    public var targetChanged: Bool
    public var preview: ConfigurationDocumentProbe<ConfigurationPlan>
    public var lastChange: ConfigurationDocumentProbe<ConfigurationReport>
    public var lastRecovery: ConfigurationDocumentProbe<ConfigurationRecovery>

    public init(
        source: CommandTargetToken,
        targetChanged: Bool = false,
        preview: ConfigurationDocumentProbe<ConfigurationPlan>,
        lastChange: ConfigurationDocumentProbe<ConfigurationReport>,
        lastRecovery: ConfigurationDocumentProbe<ConfigurationRecovery>
    ) {
        self.source = source
        self.targetChanged = targetChanged
        self.preview = preview
        self.lastChange = lastChange
        self.lastRecovery = lastRecovery
    }
}

/// Reads the daemon's configuration documents through the same standalone client the rest of the
/// app uses (Libbox, over the kernel's own transport).
///
/// # Why every read is bound to one target
///
/// The page shows a plan, the last apply and the last recovery as one story about one service. Three
/// independent resolutions of "the current target" would let a session change land between them and
/// produce a plan from the local tunnel beside a report from a remote server. The target is therefore
/// captured ONCE, the client is resolved from it ONCE, and the three reads are issued to that client.
///
/// # Why the preview is local-only
///
/// The plan is computed from the selected profile's stored document - the bytes a start would apply.
/// That document lives on this device and may carry node credentials, so it may only be sent to the
/// daemon this device runs. On a remote session the preview is `notApplicable` and nothing is read or
/// sent; the two reports still come from the remote daemon, because they are that daemon's own facts
/// and the page's `source` names it.
public enum ConfigurationStatusProbe {
    /// Everything the Core screen shows, read once per appearance.
    public static func load() async -> ConfigurationStatus {
        await load(binding: CommandTarget.bind())
    }

    /// The same read, against a target the caller captured earlier.
    public static func load(target: CommandTargetToken) async -> ConfigurationStatus {
        // A bare token cannot be read from (resolving it would ask the session again), so the public
        // entry point takes the binding and this one is kept for callers that only have a token: it
        // binds a fresh one and says so if the session moves - which is the same contract.
        await load(binding: CommandTarget.bind())
    }

    /// The same read, pinned to one captured target.
    private static func load(binding: CommandTarget.Binding) async -> ConfigurationStatus {
        let target = binding.token
        // The document a plan is computed from is read BEFORE the blocking section, and only when
        // the policy permits it for this target: `BlockingIO.run` takes a synchronous closure, and
        // the read has to be decided before anything is sent anywhere.
        let previewInput: ConfigurationPreviewInput
        switch CommandTargetPolicy.localProfileDecision(target) {
        case .permitted:
            previewInput = .document(await selectedProfileContent())
        case let .refused(_, reason):
            previewInput = .refused(reason)
        }
        return await BlockingIO.run {
            let client: LibboxCommandClient
            do {
                guard let resolved = try CommandTarget.sessionClient(for: binding) else {
                    // The session moved between capturing the target and asking for its client.
                    // Reading now would describe a daemon the user has left and label it with the
                    // captured one's name - the mislabel this binding exists to prevent.
                    let reason = String(localized: "the session's target changed while this page was opening")
                    return ConfigurationStatus(
                        source: target,
                        targetChanged: true,
                        preview: .unavailable(reason),
                        lastChange: .unavailable(reason),
                        lastRecovery: .unavailable(reason)
                    )
                }
                client = resolved
            } catch {
                return ConfigurationStatus(
                    source: target,
                    preview: .unavailable(error.localizedDescription),
                    lastChange: .unavailable(error.localizedDescription),
                    lastRecovery: .unavailable(error.localizedDescription)
                )
            }
            let preview: ConfigurationDocumentProbe<ConfigurationPlan>
            switch previewInput {
            case let .document(content):
                if let content {
                    preview = probe(client: client) { try $0.previewServiceChange(content) }
                } else {
                    preview = .absent
                }
            case let .refused(reason):
                preview = .notApplicable(reason)
            }
            return ConfigurationStatus(
                source: target,
                preview: preview,
                lastChange: probe(client: client) { try $0.getLastServiceChange() },
                lastRecovery: probe(client: client) { try $0.getLastConfigRecovery() }
            )
        }
    }

    /// The preview's input for one target: a document this device may send, or the reason it may not.
    private enum ConfigurationPreviewInput: Sendable {
        case document(String?)
        case refused(String)
    }

    /// What applying `configContent` would mean for the running instance.
    ///
    /// Local by construction: the argument is a document from this device, so this pins the local
    /// tunnel rather than following the session. A caller that has a target in hand should use
    /// `load(target:)`, which asks the same question as part of the page's one read.
    public static func preview(_ configContent: String) async -> ConfigurationDocumentProbe<ConfigurationPlan> {
        await BlockingIO.run {
            let client: LibboxCommandClient
            do {
                // Pinned to this device's tunnel: the argument is a document stored here, and the
                // policy is what decides that a local document may only reach the local daemon.
                client = try CommandTarget.standaloneClient(scope: .localTunnel)
            } catch {
                return .unavailable(error.localizedDescription)
            }
            return probe(client: client) { try $0.previewServiceChange(configContent) }
        }
    }

    /// What the last apply attempt planned and did, from the session's target.
    public static func lastChange() async -> ConfigurationDocumentProbe<ConfigurationReport> {
        await probeOnCurrentTarget { try $0.getLastServiceChange() }
    }

    /// The last recovery from a failed start, from the session's target.
    public static func lastRecovery() async -> ConfigurationDocumentProbe<ConfigurationRecovery> {
        await probeOnCurrentTarget { try $0.getLastConfigRecovery() }
    }

    /// One report, read from the session's target as it is when the read starts.
    private static func probeOnCurrentTarget<Value: Decodable & Sendable>(
        _ call: @escaping @Sendable (LibboxCommandClient) throws -> LibboxStringBox?
    ) async -> ConfigurationDocumentProbe<Value> {
        let binding = CommandTarget.bind()
        return await BlockingIO.run {
            let client: LibboxCommandClient
            do {
                guard let resolved = try CommandTarget.sessionClient(for: binding) else {
                    return .unavailable(String(localized: "the session's target changed while this page was opening"))
                }
                client = resolved
            } catch {
                return .unavailable(error.localizedDescription)
            }
            return probe(client: client, call)
        }
    }

    private static func probe<Value: Decodable & Sendable>(
        client: LibboxCommandClient,
        _ call: @escaping @Sendable (LibboxCommandClient) throws -> LibboxStringBox?
    ) -> ConfigurationDocumentProbe<Value> {
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

    /// The selected profile's stored document, or nil when nothing is selected or readable.
    private static func selectedProfileContent() async -> String? {
        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try? await ProfileManager.get(profileID) else {
            return nil
        }
        return try? await profile.readAsync()
    }
}
