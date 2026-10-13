import Foundation
import GRDB
import Libbox

public extension Profile {
    /// Fetch this remote profile and apply everything a successful refresh carries.
    ///
    /// The decision lives in `RemoteProfileRefresh.evaluate` and the order of the side effects
    /// lives in `RemoteRefreshApplier.apply`; both are pure and tested. This function supplies the
    /// real fetch, the real configuration check and the real persistence, then delegates.
    ///
    /// A failed fetch, a non-2xx status, an unreadable body or a body that fails
    /// `LibboxCheckConfig` all throw before the metadata is committed, so a refresh that did not
    /// actually succeed cannot touch what is stored.
    nonisolated func updateRemoteProfile() async throws {
        // The real path supplies the real metadata probe. It is not a default of
        // `refreshRemoteProfile` because that would put a live network request on the tests'
        // path, which inject a canned response and must stay offline.
        try await refreshRemoteProfile(metadataProbe: { try await RemoteProfileFetcher.captureMetadata($0) })
    }

    /// The refresh above, with the fetch, the configuration check, the metadata probe and the
    /// persistence call injectable.
    ///
    /// The real entry point passes the real implementations; the tests pass a canned response and a
    /// recording store. Everything that decides what happens - the merge, the body comparison and
    /// the order of the effects - is the same code in both, which is the point: the rule that a
    /// metadata-only refresh must not reach the reload path is verified against the shipping
    /// sequence rather than against a re-implementation of it.
    nonisolated func refreshRemoteProfile(
        fetch: @escaping (String) async throws -> RemoteProfileResponse = { try await RemoteProfileFetcher.fetch($0) },
        validate: @escaping (String) async throws -> Void = { try await Profile.validateConfiguration($0) },
        metadataProbe: ((String) async throws -> SubscriptionInfoCapture)? = nil,
        persist: ((Profile) async throws -> Void)? = nil
    ) async throws {
        if type != .remote {
            return
        }
        let url = remoteURL
        // Value and capture time are read and passed together, so a refresh that captures nothing
        // carries the stored capture time forward instead of silently losing it.
        let previous = SubscriptionSnapshot(info: subscriptionInfo, capturedAt: subscriptionInfoUpdatedAt)
        let currentBody = try? await readAsync()
        // One instant for both facts this refresh may write, so `lastUpdated` and the quota's
        // capture time cannot disagree about when "now" was.
        let now = Date()
        let outcome = try await RemoteProfileRefresh.evaluate(
            remoteURL: url,
            previous: previous,
            currentBody: currentBody,
            now: now,
            fetch: fetch,
            validate: validate,
            metadataProbe: metadataProbe
        )
        let persist = persist ?? { try await ProfileManager.update($0) }
        try await RemoteRefreshApplier.apply(
            outcome,
            applyMetadata: {
                subscriptionInfo = outcome.subscriptionInfo
                subscriptionInfoUpdatedAt = outcome.subscriptionInfoUpdatedAt
                // `lastUpdated` keeps its own meaning: the configuration refreshed successfully.
                // It is not the quota's timestamp, and a refresh that captured no quota still
                // legitimately advances it.
                lastUpdated = now
            },
            persist: { try await persist(self) },
            writeBody: { try await writeAsync($0) },
            reloadService: { try await onProfileUpdated() }
        )
    }

    /// Whether a fetched body is a configuration the kernel can load.
    nonisolated static func validateConfiguration(_ content: String) async throws {
        try await BlockingIO.run {
            var error: NSError?
            LibboxCheckConfig(content, &error)
            if let error {
                throw error
            }
        }
    }

    /// Drop metadata that describes a subscription this profile no longer points at.
    ///
    /// Called from the persistence path rather than from a view's save button, because the remote
    /// URL can be changed from more than one place. Without it, pointing a profile at panel B
    /// would keep showing panel A's remaining traffic until B's first successful refresh, which
    /// reads as a working quota and is wrong.
    ///
    /// Only the metadata is cleared. Whether B has answered yet is not this function's business,
    /// and no placeholder zeros are invented: `subscriptionInfo` stays `nil` until B reports real
    /// figures. The configuration body and `lastUpdated` are left alone as well, so the profile
    /// keeps working off its last known good configuration while the new URL is unreachable.
    func normalizeRemoteSourceChange(previousURL: String?) {
        guard type == .remote else {
            return
        }
        guard previousURL != remoteURL else {
            return
        }
        subscriptionInfo = nil
        // Cleared with the value. A capture time without a quota would be a freshness claim about
        // nothing, and it is the pairing - not either field alone - that the UI reads.
        subscriptionInfoUpdatedAt = nil
    }

    nonisolated func onProfileUpdated() async throws {
        if await SharedPreferences.selectedProfileID.get() == id {
            if let profile = try? await ExtensionProfile.load() {
                if await profile.status == .connected {
                    try await profile.reloadService()
                }
            }
        }
    }
}
