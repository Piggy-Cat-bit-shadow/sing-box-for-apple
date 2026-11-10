import Foundation

/// One provider entry of `CommandClient.RefreshRemoteProviders`.
///
/// The pinned kernel marshals its protobuf response with Go's `encoding/json`, which means the
/// wire names are `pending_tags` and `restart_required` (the generated struct tags), *and* that
/// every zero value is omitted. A decoder that required the fields, or only knew the camelCase
/// spelling, would either fail the whole report or silently treat a partly applied document as a
/// clean publish. Both are the same user-visible failure: a group whose membership the live graph
/// refused is shown as published.
public struct RemoteProviderRefreshEntry: Equatable, Sendable {
    public let tag: String
    public let status: String
    public let reason: String
    public let pendingTags: [String]
    public let restartRequired: Bool

    public init(
        tag: String,
        status: String,
        reason: String = "",
        pendingTags: [String] = [],
        restartRequired: Bool = false
    ) {
        self.tag = tag
        self.status = status
        self.reason = reason
        self.pendingTags = pendingTags
        self.restartRequired = restartRequired
    }
}

/// The `RemoteProviderRefreshResponse` JSON returned by libbox.
public struct RemoteProviderRefreshResponse: Equatable, Sendable {
    public let results: [RemoteProviderRefreshEntry]
    public let cancelled: Bool
    public let boxChanged: Bool
    /// False when the kernel answered "this RPC does not exist here".
    ///
    /// The Go side translates gRPC's Unimplemented into a successful document carrying
    /// `"supported": false`, because a gomobile call that returns an error loses its value in the
    /// generated bridge. A client that only inspected the error therefore never saw the capability
    /// gap; a client that only inspects `results` would read it as "no providers", which is a
    /// different and wrong fact.
    public let supported: Bool

    public init(
        results: [RemoteProviderRefreshEntry],
        cancelled: Bool = false,
        boxChanged: Bool = false,
        supported: Bool = true
    ) {
        self.results = results
        self.cancelled = cancelled
        self.boxChanged = boxChanged
        self.supported = supported
    }
}

/// What the refresh may present, including the cases where there is no live instance at all.
public enum RemoteProviderRefreshStatus: Equatable, Sendable {
    case published
    case unchanged
    /// The core accepted the document but the live graph refused some members.
    case partial
    case failed
    case busy
    case cancelled
    /// The Box changed during the refresh: the entries describe more than one instance.
    case boxChanged
    /// The running config has no remote providers.
    case none
    /// The refreshed profile is not the running one.
    case notActive
    /// The tunnel is not connected.
    case notRunning
    /// The running kernel predates `RefreshRemoteProviders`.
    case unsupported
    /// The RPC failed for another reason.
    case unavailable
}

public struct RemoteProviderRefreshCounts: Equatable, Sendable {
    public var published = 0
    public var unchanged = 0
    public var failed = 0
    public var skipped = 0
    public var busy = 0
    public var pendingTags = 0
    public var restartRequired = 0
    public var total = 0
}

public struct RemoteProviderRefreshSummary: Equatable, Sendable {
    public let status: RemoteProviderRefreshStatus
    public let counts: RemoteProviderRefreshCounts
    public let detail: String?
}

public enum RemoteProviderRefreshParser {
    /// Decodes the raw summary and classifies it. A malformed or absent payload is `unavailable`,
    /// never an empty success: "the kernel did not answer" is not "there were no providers".
    public static func summarize(json: String?) -> RemoteProviderRefreshSummary {
        guard let json, let data = json.data(using: .utf8), !json.isEmpty else {
            return RemoteProviderRefreshSummary(status: .unavailable, counts: .init(), detail: nil)
        }
        let response: RemoteProviderRefreshResponse
        do {
            response = try decode(data)
        } catch {
            return RemoteProviderRefreshSummary(
                status: .unavailable,
                counts: .init(),
                detail: error.localizedDescription
            )
        }
        return summarize(response)
    }

    public static func summarize(_ response: RemoteProviderRefreshResponse) -> RemoteProviderRefreshSummary {
        if !response.supported {
            /// The kernel answered "this RPC does not exist here". It is not a refresh that ran and
            /// found nothing: it is a capability the running kernel does not have.
            return RemoteProviderRefreshSummary(status: .unsupported, counts: .init(), detail: nil)
        }
        if response.boxChanged {
            return RemoteProviderRefreshSummary(status: .boxChanged, counts: .init(), detail: nil)
        }
        if response.cancelled {
            return RemoteProviderRefreshSummary(status: .cancelled, counts: .init(), detail: nil)
        }
        var counts = RemoteProviderRefreshCounts()
        counts.total = response.results.count
        var unknown = 0
        for entry in response.results {
            counts.pendingTags += entry.pendingTags.count
            if entry.restartRequired {
                counts.restartRequired += 1
            }
            switch entry.status {
            case "published": counts.published += 1
            case "unchanged": counts.unchanged += 1
            case "failed": counts.failed += 1
            case "skipped": counts.skipped += 1
            case "busy": counts.busy += 1
            default: unknown += 1
            }
        }
        if counts.pendingTags > 0 || counts.restartRequired > 0 {
            return RemoteProviderRefreshSummary(status: .partial, counts: counts, detail: nil)
        }
        if counts.total == 0 {
            return RemoteProviderRefreshSummary(status: .none, counts: counts, detail: nil)
        }
        if unknown > 0 {
            return RemoteProviderRefreshSummary(
                status: .failed,
                counts: counts,
                detail: "\(unknown) unknown provider status"
            )
        }
        if counts.failed > 0 {
            return RemoteProviderRefreshSummary(status: .failed, counts: counts, detail: nil)
        }
        if counts.busy > 0 {
            return RemoteProviderRefreshSummary(status: .busy, counts: counts, detail: nil)
        }
        if counts.published > 0 {
            return RemoteProviderRefreshSummary(status: .published, counts: counts, detail: nil)
        }
        return RemoteProviderRefreshSummary(status: .unchanged, counts: counts, detail: nil)
    }

    /// Decodes the Go/encoding-json shape: snake_case names, absent zero values.
    public static func decode(_ data: Data) throws -> RemoteProviderRefreshResponse {
        let value = try JSONDecoder().decode(WireResponse.self, from: data)
        return RemoteProviderRefreshResponse(
            results: (value.results ?? []).map {
                RemoteProviderRefreshEntry(
                    tag: $0.tag ?? "",
                    status: $0.status ?? "",
                    reason: $0.reason ?? "",
                    pendingTags: $0.pendingTags ?? [],
                    restartRequired: $0.restartRequired ?? false
                )
            },
            cancelled: value.cancelled ?? false,
            boxChanged: value.boxChanged ?? false,
            supported: value.supported ?? true
        )
    }

    private struct WireResponse: Decodable {
        let results: [WireEntry]?
        let cancelled: Bool?
        let boxChanged: Bool?
        /// Absent on every kernel that has the RPC: only a kernel without it answers `false`.
        let supported: Bool?

        enum CodingKeys: String, CodingKey {
            case results
            case cancelled
            case boxChanged = "box_changed"
            case supported
        }
    }

    private struct WireEntry: Decodable {
        let tag: String?
        let status: String?
        let reason: String?
        let pendingTags: [String]?
        let restartRequired: Bool?

        enum CodingKeys: String, CodingKey {
            case tag
            case status
            case reason
            case pendingTags = "pending_tags"
            case restartRequired = "restart_required"
        }
    }
}
