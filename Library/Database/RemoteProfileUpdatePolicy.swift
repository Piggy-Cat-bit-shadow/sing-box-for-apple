import Foundation

/// The subscription metadata a profile is currently holding, value and capture time together.
///
/// The two travel as one parameter rather than as two arguments precisely so that they cannot be
/// passed inconsistently. A refresh that does not capture a new quota must carry the stored
/// capture time forward untouched; if the value and its time could be supplied separately, a
/// caller that passed only the value would silently reset a known capture time to "unknown",
/// which is the same class of bug this type exists to prevent.
public struct SubscriptionSnapshot: Equatable, Sendable {
    /// The stored quota, or `nil` when none has ever been captured.
    public let info: SubscriptionInfo?
    /// When that quota was captured, or `nil` when that is unknown - an older profile, or one
    /// whose panel has never reported a parsable quota.
    public let capturedAt: Date?

    public init(info: SubscriptionInfo?, capturedAt: Date?) {
        self.info = info
        self.capturedAt = capturedAt
    }

    /// The state of a profile that has never captured anything.
    public static let empty = SubscriptionSnapshot(info: nil, capturedAt: nil)
}

/// What one successful remote refresh resolved to.
///
/// This is deliberately a pure value derived from the response and the profile's current state.
/// Keeping it out of `Profile.updateRemoteProfile()` is what makes the refresh rules testable
/// without a network, a database or a running tunnel, and it also makes the order of the two
/// side effects explicit: the metadata is always persisted, the configuration body only when it
/// actually changed.
public struct RemoteRefreshOutcome: Equatable, Sendable {
    /// The metadata to persist: the freshly captured values, or the previously stored ones when
    /// this response captured none.
    public let subscriptionInfo: SubscriptionInfo?
    /// When the quota above was captured.
    ///
    /// Advances **only** on a capture. When `capture` is `.missing` or `.malformed` this is the
    /// stored capture time carried forward unchanged, and is `nil` when none was known. It is
    /// never `now` in those cases: that is the whole point of the field, because a retained quota
    /// stamped with the current time is indistinguishable from a fresh one.
    public let subscriptionInfoUpdatedAt: Date?
    /// What this response said about the quota, kept for observability and for tests. Collapsing
    /// the three cases into `subscriptionInfo == nil` would lose the difference between "the panel
    /// sends no header" and "the panel sends a header this client cannot read".
    public let capture: SubscriptionInfoCapture
    /// Whether the quota came from the secondary metadata probe rather than the primary response.
    /// True only when the primary response captured nothing and the probe then succeeded.
    public let usedMetadataProbe: Bool
    /// Whether the configuration body should be written to disk.
    public let writeBody: Bool
    /// Whether the running service should be asked to reload. Implied by `writeBody`; never true
    /// for a metadata-only refresh.
    public let reloadService: Bool
    /// The body to write, present exactly when `writeBody` is true.
    public let bodyToWrite: String?

    public init(
        subscriptionInfo: SubscriptionInfo?,
        subscriptionInfoUpdatedAt: Date?,
        capture: SubscriptionInfoCapture,
        usedMetadataProbe: Bool,
        writeBody: Bool,
        reloadService: Bool,
        bodyToWrite: String?
    ) {
        self.subscriptionInfo = subscriptionInfo
        self.subscriptionInfoUpdatedAt = subscriptionInfoUpdatedAt
        self.capture = capture
        self.usedMetadataProbe = usedMetadataProbe
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
    /// 3. classify the header and merge the metadata - a response that captured no quota keeps the
    ///    stored value **and its stored capture time**;
    /// 4. compare the body against what is on disk.
    ///
    /// A panel's YAML commonly stays byte-identical for days while its usage counter moves on every
    /// request, so the metadata must not live behind the "did the body change" test. Conversely a
    /// metadata-only change must not reach the write and the service reload: remaining traffic is
    /// not a kernel configuration change, and reloading a running tunnel for it would drop the
    /// user's connections for a number in a card.
    ///
    /// # Freshness
    ///
    /// The quota and its capture time move together or not at all. `now` is the capture time for a
    /// response that carried a quota; a response that did not leaves `subscriptionInfoUpdatedAt`
    /// exactly as it was. This is what stops a retained quota from being presented as freshly
    /// refreshed - the configuration body may well have refreshed just now, but the quota is a
    /// different fact with a different, older timestamp.
    ///
    /// - Parameters:
    ///   - remoteURL: the URL to fetch, or `nil` when the profile has none.
    ///   - previous: the metadata already stored for this profile, value and capture time.
    ///   - currentBody: the configuration body currently on disk, or `nil` when it could not be read.
    ///   - now: the instant to stamp a capture with. Injected so the decision is deterministic
    ///     under test; the app passes the same instant it stamps `lastUpdated` with.
    ///   - fetch: performs the request. Returns the body and the raw header, if any.
    ///   - validate: checks the body is a usable configuration, throwing when it is not.
    ///   - metadataProbe: an optional second attempt at the quota, used only when the primary
    ///     response captured nothing. It exists because the two facts are not equally available:
    ///     the body must come from the client's own transport with the client's own identity (a
    ///     panel that answers a sing-box User-Agent with a sing-box configuration must keep doing
    ///     so), while the header is only sent to clients a panel recognises as Clash-compatible.
    ///     A probe lets the header be captured without changing the request that produces the body.
    ///     Its failure is swallowed by design: a quota is not worth failing a configuration
    ///     refresh over, and the stored metadata is retained either way.
    ///
    /// A fetch failure, a non-2xx status or a validation failure all throw from here, so a refresh
    /// that did not actually succeed cannot reach the caller's persistence step and cannot touch
    /// the stored metadata.
    public static func evaluate(
        remoteURL: String?,
        previous: SubscriptionSnapshot,
        currentBody: String?,
        now: Date = Date(),
        fetch: (String) async throws -> RemoteProfileResponse,
        validate: (String) async throws -> Void,
        metadataProbe: ((String) async throws -> SubscriptionInfoCapture)? = nil
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

        var capture = SubscriptionInfo.capture(header: response.subscriptionUserInfo)
        var usedProbe = false
        if !capture.didCapture, let metadataProbe {
            if let probed = try? await metadataProbe(remoteURL) {
                if probed.didCapture {
                    capture = probed
                    usedProbe = true
                } else if case .malformed = probed, case .missing = capture {
                    // The primary saw no header at all, but the probe's response carried one this
                    // client could not read. Reporting the more specific verdict changes no write -
                    // neither case captures - but it is the difference between "this panel sends no
                    // header" and "this panel sends a header whose format changed", and those have
                    // different fixes.
                    capture = .malformed
                }
            }
        }

        let info: SubscriptionInfo?
        let capturedAt: Date?
        if case let .updated(value) = capture {
            info = value
            capturedAt = now
        } else {
            info = previous.info
            capturedAt = previous.capturedAt
        }

        let bodyChanged = currentBody != response.content
        return RemoteRefreshOutcome(
            subscriptionInfo: info,
            subscriptionInfoUpdatedAt: capturedAt,
            capture: capture,
            usedMetadataProbe: usedProbe,
            writeBody: bodyChanged,
            reloadService: bodyChanged,
            bodyToWrite: bodyChanged ? response.content : nil
        )
    }
}
