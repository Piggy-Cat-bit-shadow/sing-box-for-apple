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
        _ = try await updateRemoteProfileReporting()
    }

    /// The same refresh, returning both halves of the result.
    ///
    /// Whether the body applies, and whether the providers were refreshed, are two independent
    /// facts. A profile that is not the selected/connected one still saves its new body (`.saved`)
    /// and must not touch the running instance's providers; the selected one confirms the reload
    /// with the daemon's per-Box `startedAt` rather than assuming the RPC returned means applied.
    nonisolated func updateRemoteProfileReporting() async throws -> RemoteProfileUpdateReport {
        let selectedAtStart = await Self.isSelected(id)
        let runningAtStart = selectedAtStart ? await Self.tunnelConnected() : false
        var before: Int64?
        if runningAtStart {
            before = await Self.tunnelStartedAt()
        }
        return try await refreshRemoteProfile(
            metadataProbe: { try await RemoteProfileFetcher.captureMetadata($0) },
            reloadService: { try await self.onProfileUpdated() },
            // Re-read the world at each boundary instead of trusting the download-time snapshot:
            // a profile switch during the fetch must not let this attempt apply or refresh the
            // profile that is now selected.
            canApply: {
                guard await Self.isSelected(self.id) else { return false }
                return await Self.tunnelConnected()
            },
            isStillCurrent: { await Self.isSelected(self.id) },
            confirmStartedAt: {
                guard await Self.isSelected(self.id) else { return false }
                guard let before, let after = await Self.tunnelStartedAt() else { return false }
                return after > before
            },
            refreshProviders: { await Self.providerProbeIfCurrent(self.id) },
            providersOnFailure: { await Self.providerProbeIfCurrent(self.id) }
        )
    }

    /// Whether [id] is still the profile the UI has selected.
    nonisolated static func isSelected(_ id: Int64?) async -> Bool {
        await SharedPreferences.selectedProfileID.get() == id
    }

    /// Probes the live Box only while [id] is still the selected, connected profile.
    ///
    /// Re-checked after the probe as well: if the selection moved while the RPC was in flight,
    /// the answer belongs to another instance and is reported as `notActive` instead of being
    /// attributed to this profile.
    nonisolated static func providerProbeIfCurrent(_ id: Int64?) async -> RemoteProviderRefreshProbe {
        guard await isSelected(id) else { return .notActive }
        guard await tunnelConnected() else { return .notRunning }
        let probe = await probeProviderRefresh()
        guard await isSelected(id) else { return .notActive }
        return probe
    }

    /// Whether the tunnel is connected right now.
    nonisolated static func tunnelConnected() async -> Bool {
        guard let extensionProfile = try? await ExtensionProfile.load() else { return false }
        return await extensionProfile.status == .connected
    }

    /// The daemon's per-Box start timestamp, or nil when no Box is reachable.
    nonisolated static func tunnelStartedAt() async -> Int64? {
        await BlockingIO.run {
            guard let client = try? CommandTarget.standaloneClient() else { return nil }
            var value: Int64 = 0
            do {
                try client.getStartedAt(&value)
            } catch {
                return nil
            }
            return value > 0 ? value : nil
        }
    }

    /// Refreshes the live Box's remote providers and returns the raw JSON summary.
    nonisolated static func probeProviderRefresh() async -> RemoteProviderRefreshProbe {
        await BlockingIO.run {
            guard let client = try? CommandTarget.standaloneClient() else {
                return .notRunning
            }
            do {
                // gomobile imports a Go `(T, error)` method as a throwing non-optional, so there
                // is no "empty response" case to guard: a failed call throws, and a successful one
                // carries its box.
                let box = try client.refreshRemoteProviders("", timeoutMilliseconds: 15_000)
                return .response(box.value)
            } catch {
                // gRPC's Unimplemented is code 12. An older kernel answers this way, and it is a
                // capability gap, not a failed refresh of a live Box.
                if (error as NSError).code == 12 {
                    return .unsupported
                }
                return .failed(error.localizedDescription)
            }
        }
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
        persist: ((Profile) async throws -> Void)? = nil,
        reloadService: (() async throws -> Void)? = nil,
        canApply: (() async -> Bool)? = nil,
        isStillCurrent: (() async -> Bool)? = nil,
        confirmStartedAt: (() async -> Bool)? = nil,
        refreshProviders: (() async -> RemoteProviderRefreshProbe)? = nil,
        providersOnFailure: (() async -> RemoteProviderRefreshProbe)? = nil
    ) async throws -> RemoteProfileUpdateReport {
        if type != .remote {
            return RemoteProfileUpdateReport(
                config: .saved,
                providers: RemoteProviderRefreshProbe.notActive.summary
            )
        }
        let url = remoteURL
        // Value and capture time are read and passed together, so a refresh that captures nothing
        // carries the stored capture time forward instead of silently losing it.
        let previous = SubscriptionSnapshot(info: subscriptionInfo, capturedAt: subscriptionInfoUpdatedAt)
        let currentBody = try? await readAsync()
        // One instant for both facts this refresh may write, so `lastUpdated` and the quota's
        // capture time cannot disagree about when "now" was.
        let now = Date()
        let outcome: RemoteRefreshOutcome
        do {
            outcome = try await RemoteProfileRefresh.evaluate(
                remoteURL: url,
                previous: previous,
                currentBody: currentBody,
                now: now,
                fetch: fetch,
                validate: validate,
                metadataProbe: metadataProbe
            )
        } catch let error as RemoteRefreshValidationError {
            // The body downloaded but the core would not load it. The stored body is untouched,
            // and the old instance's providers are still a separate fact worth reporting when this
            // profile is still the selected, connected one.
            return RemoteProfileUpdateReport(
                config: .invalidConfig(error.localizedDescription),
                providers: await (providersOnFailure ?? { .notActive })().summary
            )
        } catch {
            return RemoteProfileUpdateReport(
                config: .downloadFailed(error.localizedDescription),
                providers: await (providersOnFailure ?? { .notActive })().summary
            )
        }
        let persist = persist ?? { try await ProfileManager.update($0) }
        return try await RemoteRefreshApplier.applyReporting(
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
            writeBody: { try await self.writeAsync($0) },
            storedBody: { try? await self.readAsync() },
            reloadService: reloadService ?? { try await self.onProfileUpdated() },
            canApply: canApply,
            isStillCurrent: isStillCurrent,
            confirmStartedAt: confirmStartedAt,
            refreshProviders: refreshProviders ?? { .notActive }
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
