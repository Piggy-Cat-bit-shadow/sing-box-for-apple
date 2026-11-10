import Foundation

// What one successful remote refresh resolved to.
//
// It lives in its own file because it is the ONE type the refresh result and the commit sequence
// share: `RemoteProfileRefresh.evaluate` produces it and `RemoteRefreshApplier` consumes it, in a
// different target entirely when the applier's sequence is tested. Keeping it next to the evaluation
// would drag the fetch types (and therefore `URLSession`) into a package that has no network.

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
