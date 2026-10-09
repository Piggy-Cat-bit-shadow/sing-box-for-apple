import Foundation

/// What one successful remote refresh resolved to.
///
/// This is deliberately a pure value derived from the response and the profile's current state.
/// Keeping it out of `Profile.updateRemoteProfile()` is what makes the refresh rules testable
/// without a network, a database or a running tunnel, and it also makes the order of the two
/// side effects explicit: the metadata is always persisted, the configuration body only when it
/// actually changed.
public struct RemoteRefreshOutcome: Equatable, Sendable {
    /// The metadata to persist: the freshly parsed values, or the previously stored ones when this
    /// response carried none.
    public let subscriptionInfo: SubscriptionInfo?
    /// Whether the configuration body should be written to disk.
    public let writeBody: Bool
    /// Whether the running service should be asked to reload. Implied by `writeBody`; never true
    /// for a metadata-only refresh.
    public let reloadService: Bool
    /// The body to write, present exactly when `writeBody` is true.
    public let bodyToWrite: String?

    public init(subscriptionInfo: SubscriptionInfo?, writeBody: Bool, reloadService: Bool, bodyToWrite: String?) {
        self.subscriptionInfo = subscriptionInfo
        self.writeBody = writeBody
        self.reloadService = reloadService
        self.bodyToWrite = bodyToWrite
    }
}

/// A refresh that did not produce a usable configuration.
///
/// Defined here rather than throwing the validator's own error so that the decision below stays
/// free of Libbox, and therefore testable.
public struct RemoteRefreshValidationError: LocalizedError {
    public let underlying: Error

    public init(_ underlying: Error) {
        self.underlying = underlying
    }

    public var errorDescription: String? {
        underlying.localizedDescription
    }
}

public enum RemoteProfileRefresh {
    /// Fetch, validate, merge and decide, without performing any of the side effects.
    ///
    /// The order is the point, and it is the difference between a panel's traffic figures surviving
    /// a refresh and being thrown away:
    ///
    /// 1. fetch the body **and** the `subscription-userinfo` header;
    /// 2. validate the body as a sing-box configuration, throwing before anything is returned;
    /// 3. merge the metadata - a response with no header, or one that does not parse, keeps the
    ///    stored values;
    /// 4. compare the body against what is on disk.
    ///
    /// A panel's YAML commonly stays byte-identical for days while its usage counter moves on every
    /// request, so the metadata must not live behind the "did the body change" test. Conversely a
    /// metadata-only change must not reach the write and the service reload: remaining traffic is
    /// not a kernel configuration change, and reloading a running tunnel for it would drop the
    /// user's connections for a number in a card.
    ///
    /// - Parameters:
    ///   - remoteURL: the URL to fetch, or `nil` when the profile has none.
    ///   - previous: the metadata already stored for this profile.
    ///   - currentBody: the configuration body currently on disk, or `nil` when it could not be read.
    ///   - fetch: performs the request. Returns the body and the raw header, if any.
    ///   - validate: checks the body is a usable configuration, throwing when it is not.
    ///
    /// A fetch failure, a non-2xx status or a validation failure all throw from here, so a refresh
    /// that did not actually succeed cannot reach the caller's persistence step and cannot touch
    /// the stored metadata.
    public static func evaluate(
        remoteURL: String?,
        previous: SubscriptionInfo?,
        currentBody: String?,
        fetch: (String) async throws -> RemoteProfileResponse,
        validate: (String) async throws -> Void
    ) async throws -> RemoteRefreshOutcome {
        guard let remoteURL else {
            throw RemoteProfileFetchError.missingURL
        }
        let response = try await fetch(remoteURL)
        do {
            try await validate(response.content)
        } catch {
            throw RemoteRefreshValidationError(error)
        }
        let parsed = response.subscriptionUserInfo.flatMap { SubscriptionInfo.parse(header: $0) }
        let bodyChanged = currentBody != response.content
        return RemoteRefreshOutcome(
            subscriptionInfo: parsed ?? previous,
            writeBody: bodyChanged,
            reloadService: bodyChanged,
            bodyToWrite: bodyChanged ? response.content : nil
        )
    }
}
