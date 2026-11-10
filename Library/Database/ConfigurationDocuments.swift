import Foundation

// The daemon's configuration documents, as the kernel marshals them.
//
// `PreviewServiceChange`, `GetLastServiceChange` and `GetLastConfigRecovery` each answer with a
// `daemon.JSONDocument` whose `json` field is `encoding/json` output over a Go struct. The tags on
// those structs are camelCase (`targetRevision`, `changedSections`, `restartRequired`), so this
// decoder is camelCase - unlike the provider-refresh report, which is protojson output and
// therefore snake_case. Mixing the two shapes is the failure that makes a whole report undecodable.
//
// The files here are Foundation-only on purpose: they are linked into the SwiftPM test package
// (`scripts/link-test-sources.sh`), so the classification below is testable without Libbox, Xcode
// or a device.

/// One value a plan would change. Mirrors `daemon.DomainChange`.
public struct ConfigurationChange: Decodable, Equatable, Sendable {
    public var kind: String
    public var from: String?
    public var to: String?
    public var detail: String?
}

/// What one live-owned domain would do. Mirrors `daemon.DomainPlan`.
public struct ConfigurationDomainPlan: Decodable, Equatable, Sendable {
    public var domain: String
    public var supported: Bool
    public var unsupportedReason: String?
    public var restartRequired: Bool
    public var changes: [ConfigurationChange]?
    public var currentRevision: String?
    public var targetRevision: String?
}

/// The provider domain's plan. Mirrors `daemon.ProviderDomainPlan`.
public struct ConfigurationProviderPlan: Decodable, Equatable, Sendable {
    public var domain: String
    public var supported: Bool
    public var unsupportedReason: String?
    public var tags: [String]?
    public var liveRefresh: Bool?
    public var liveRefreshReason: String?
    public var currentRevision: String?
    public var targetRevision: String?
}

/// What applying a document would mean. Mirrors `daemon.ServiceChangePlan`.
public struct ConfigurationPlan: Decodable, Equatable, Sendable {
    public var started: Bool
    public var currentRevision: String?
    public var targetRevision: String?
    public var unchanged: Bool
    public var liveOnly: Bool
    public var restartRequired: Bool
    public var changedDocument: Bool
    public var stale: Bool?
    public var changedSections: [String]?
    public var mode: ConfigurationDomainPlan?
    public var dns: ConfigurationDomainPlan?
    public var rule: ConfigurationDomainPlan?
    public var provider: ConfigurationProviderPlan?
}

/// One provider's refresh result inside a report. Mirrors `daemon.ProviderRefreshResult`.
public struct ConfigurationProviderResult: Decodable, Equatable, Sendable {
    public var tag: String
    public var status: String
    public var requestedRevision: UInt64?
    public var appliedRevision: UInt64?
    public var pendingTags: [String]?
    public var restartRequired: Bool?
    public var reason: String?
}

/// What the provider domain actually did. Mirrors `daemon.ProviderDomainReport`.
public struct ConfigurationProviderReport: Decodable, Equatable, Sendable {
    public var domain: String
    public var status: String
    public var results: [ConfigurationProviderResult]?
    public var restartRequired: Bool
    public var reason: String?
    public var revision: String?
}

/// What the last apply attempt planned and did. Mirrors `daemon.ServiceChangeReport`.
public struct ConfigurationReport: Decodable, Equatable, Sendable {
    public var plan: ConfigurationPlan
    public var status: String
    public var restartRequired: Bool
    public var retained: Bool
    public var activeRevision: String?
    public var persistence: String?
    public var persistenceWarning: String?
    public var reason: String?
    public var time: String
    public var applied: [ConfigurationChange]?
    public var provider: ConfigurationProviderReport?
}

/// The last recovery from a failed start. Mirrors `daemon.ConfigRecoveryInfo`.
public struct ConfigurationRecovery: Decodable, Equatable, Sendable {
    public var time: String
    public var failedRevision: String
    public var activeRevision: String
    public var error: String
}

/// A configuration document, or the reason there is none.
///
/// `absent` and `unsupported` are different facts and must never be collapsed into one `nil`:
/// the first is "this instance has no record yet", the second is "this kernel cannot answer".
public enum ConfigurationDocument<Value: Sendable>: Sendable {
    case document(Value)
    /// The JSON literal `null`: the daemon has no record of this kind yet.
    case absent
    /// The bridge answered with an empty string, or the RPC answered `Unimplemented`.
    case unsupported
}

public enum ConfigurationDocumentError: Error, Equatable {
    /// The payload parsed but is not an object - not a document this contract can read.
    case notAnObject
}

/// What applying a document would mean, decided once so both presentations agree with the kernel.
///
/// `ServiceChangePlan.Started` means a Box is RUNNING right now; `started: false` is the first
/// start. Reading it as an inverted "will start" flag hides the live, restart and stale branches
/// behind one wrong sentence, which is the P1 this type exists to make impossible: the decision is
/// here, on the model, and both the phone and the shell only render it.
public enum ConfigurationPlanVerdict: Equatable, Sendable {
    /// The running Box already runs this document.
    case unchanged(targetRevision: String?)
    /// The plan lost its base; it must be recomputed before anything is applied.
    case stale
    /// There is no running Box: this is the first start.
    case firstStart(targetRevision: String?)
    /// A running Box must be rebuilt, and these are the reasons in the caller's own vocabulary.
    case restartRequired(currentRevision: String?, targetRevision: String?, reasons: [String])
    /// The running Box absorbs the change in place.
    case liveApply(currentRevision: String?, targetRevision: String?)
    /// A running document that differs, but nothing about the difference needs a restart.
    case needsNoRestart(currentRevision: String?, targetRevision: String?)
}

public extension ConfigurationPlan {
    /// The restart reasons, preferring the kernel's changed sections to the generic sentence.
    var restartReasons: [String] {
        var reasons: [String] = []
        if let changedSections, !changedSections.isEmpty {
            reasons.append(contentsOf: changedSections)
        } else if changedDocument {
            reasons.append("the document differs outside the live domains")
        }
        for domain in [mode, dns, rule] {
            guard let domain, domain.restartRequired, let changes = domain.changes, !changes.isEmpty else {
                continue
            }
            reasons.append("\(domain.domain): \(changes.map(\.kind).joined(separator: ", "))")
        }
        return reasons
    }

    /// The order is the contract: unchanged, stale, first start, restart, live, no restart.
    var verdict: ConfigurationPlanVerdict {
        if unchanged {
            return .unchanged(targetRevision: targetRevision)
        }
        if stale == true {
            return .stale
        }
        if !started {
            return .firstStart(targetRevision: targetRevision)
        }
        if restartRequired {
            return .restartRequired(
                currentRevision: currentRevision,
                targetRevision: targetRevision,
                reasons: restartReasons
            )
        }
        if liveOnly {
            return .liveApply(currentRevision: currentRevision, targetRevision: targetRevision)
        }
        return .needsNoRestart(currentRevision: currentRevision, targetRevision: targetRevision)
    }
}

/// A revision as a person compares it: the first twelve characters, and nothing for an absent one.
public func configurationRevisionLabel(_ revision: String?) -> String {
    guard let revision, !revision.isEmpty else {
        return ""
    }
    return revision.count > 12 ? String(revision.prefix(12)) : revision
}

/// Classifies the JSON payload of a `JSONDocument` response.
///
/// The libbox bridge answers an older kernel with the empty string, and the daemon answers "no
/// record" with the JSON literal `null`; both arrive here as strings, so the caller has to tell
/// them apart before decoding. Unknown fields are ignored rather than rejected: the kernel may add
/// one before this client knows it, and a strict decoder would turn a compatible daemon into a
/// broken one.
public func classifyConfigurationDocument<Value: Decodable & Sendable>(
    _ json: String,
    as _: Value.Type = Value.self
) throws -> ConfigurationDocument<Value> {
    if json.isEmpty {
        return .unsupported
    }
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "null" {
        return .absent
    }
    guard trimmed.hasPrefix("{") else {
        throw ConfigurationDocumentError.notAnObject
    }
    let value = try JSONDecoder().decode(Value.self, from: Data(trimmed.utf8))
    return .document(value)
}
