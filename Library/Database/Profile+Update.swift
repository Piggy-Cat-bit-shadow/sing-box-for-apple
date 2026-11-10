import Foundation
import GRDB
import Libbox

public extension Profile {
    /// Fetch this remote profile and apply everything a successful refresh carries.
    ///
    /// The decision lives in `RemoteProfileRefresh.evaluate` and the order of the side effects
    /// lives in `RemoteRefreshApplier.applyReporting`; both are pure and tested. This function
    /// supplies the real fetch, the real configuration check and the real persistence, then
    /// delegates.
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
    /// # The snapshot
    ///
    /// One value - the profile identity, the request id, the source, and the revision of the body
    /// on disk - is taken BEFORE the network is touched, and every commit point downstream compares
    /// against it. That is what makes "did I still own this when I wrote it" answerable: a later
    /// read of the same values would describe a different instant.
    ///
    /// # The apply
    ///
    /// The running tunnel is asked to apply exactly the body this update wrote, and its receipt is
    /// the confirmation. A start timestamp cannot do that job: a hot reload keeps it, and an
    /// unrelated restart moves it.
    nonisolated func updateRemoteProfileReporting() async throws -> RemoteProfileUpdateReport {
        let storedBody = try? await readAsync()
        let ticket = ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: remoteURL,
            storedBodyRevision: storedBody.map(ConfigurationBodyRevision.fingerprint(of:))
        )
        return try await refreshRemoteProfile(
            ticket: ticket,
            metadataProbe: { try await RemoteProfileFetcher.captureMetadata($0) },
            reloadService: { [ticket] body in
                try await self.applyBody(body, ticket: ticket)
            },
            // Re-read the world at each boundary instead of trusting the download-time snapshot:
            // a profile switch during the fetch must not let this attempt apply or refresh the
            // profile that is now selected.
            canApply: {
                guard await Self.isSelected(self.id) else { return false }
                return await Self.tunnelConnected()
            },
            isStillCurrent: { await Self.isSelected(self.id) },
            refreshProviders: { await Self.providerProbeIfCurrent(self.id) },
            providersOnFailure: { await Self.providerProbeIfCurrent(self.id) }
        )
    }

    /// Asks this device's tunnel to apply `body`, and returns what the extension proved.
    ///
    /// - Returns: the outcome the extension reported, or nil when it answered nothing this update
    ///   can attribute to itself. Nil is "unconfirmed", never "applied", and it never triggers a
    ///   retry: the commit point has already passed.
    nonisolated func applyBody(_ body: String, ticket: ProfileUpdateTicket) async throws -> ExtensionApplyOutcome? {
        guard let profile = try? await ExtensionProfile.load() else {
            return nil
        }
        guard await profile.status == .connected else {
            return nil
        }
        let bodyRevision = ConfigurationBodyRevision.fingerprint(of: body)
        let receipt = try await profile.reloadService(
            ExtensionProfile.StartSnapshot(
                profileID: ticket.profileID,
                requestID: ticket.requestID,
                bodyRevision: bodyRevision,
                configContent: body
            )
        )
        switch ProfileUpdateOwnership.ownership(of: receipt, ticket: ticket, expectedBodyRevision: bodyRevision) {
        case let .matches(matched):
            return matched.outcome
        case .notThisUpdate, .unconfirmed:
            // A reply this update cannot claim is not a confirmation of it. The applier reports
            // `applyUnconfirmed`; nothing here retries or rolls back.
            return nil
        }
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
    ///
    /// Local by definition: this is the NetworkExtension session this app installed. A remote daemon
    /// has no `NEVPNStatus` and no place in this question.
    nonisolated static func tunnelConnected() async -> Bool {
        guard let extensionProfile = try? await ExtensionProfile.load() else { return false }
        return await extensionProfile.status == .connected
    }

    /// Refreshes the live Box's remote providers and returns the raw JSON summary.
    ///
    /// The probe is about THIS profile's subscription, and it is a write against a daemon: it is
    /// pinned to this device's tunnel so a remote session can never receive it as a management
    /// operation the user did not ask for. The read scope is not "whatever the session is on".
    nonisolated static func probeProviderRefresh() async -> RemoteProviderRefreshProbe {
        await BlockingIO.run {
            guard let client = try? CommandTarget.standaloneClient(scope: .localTunnel) else {
                return .notRunning
            }
            do {
                // gomobile imports a Go `(T, error)` method as a throwing non-optional, so there
                // is no "empty response" case to guard: a failed call throws, and a successful one
                // carries its box.
                let box = try client.refreshRemoteProviders("", timeoutMilliseconds: 15_000)
                return .response(box.value)
            } catch {
                // A kernel without the RPC answers with `{"supported":false}` as a successful
                // document, which `RemoteProviderRefreshParser` classifies as `.unsupported`. This
                // check only covers a daemon that predates that translation and still returns
                // gRPC's Unimplemented - whose code does not survive gomobile's error wrapping, so
                // it is a fallback rather than the contract.
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
    ///
    /// - Parameter ticket: the update's identity. `nil` builds one from this profile's current
    ///   state, which is what a caller that has no request of its own (an import, a script) means.
    nonisolated func refreshRemoteProfile(
        ticket: ProfileUpdateTicket? = nil,
        fetch: @escaping (String) async throws -> RemoteProfileResponse = { try await RemoteProfileFetcher.fetch($0) },
        validate: @escaping (String) async throws -> Void = { try await Profile.validateConfiguration($0) },
        metadataProbe: ((String) async throws -> SubscriptionInfoCapture)? = nil,
        persist: ((Profile) async throws -> Void)? = nil,
        reloadService: ((String) async throws -> ExtensionApplyOutcome?)? = nil,
        canApply: (() async -> Bool)? = nil,
        isStillCurrent: (() async -> Bool)? = nil,
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
        let storedBodyRevision = currentBody.map(ConfigurationBodyRevision.fingerprint(of:))
        let effectiveTicket = ticket ?? ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: url,
            storedBodyRevision: storedBodyRevision
        )
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
        let persistProfile = persist ?? { profile in
            // The metadata commit re-checks the source inside the database transaction: this update
            // resolved a URL, downloaded from it, and its figures describe THAT subscription.
            try await ProfileManager.update(profile, ticket: effectiveTicket)
        }
        do {
            return try await RemoteRefreshApplier.applyReporting(
                outcome,
                applyMetadata: {
                    subscriptionInfo = outcome.subscriptionInfo
                    subscriptionInfoUpdatedAt = outcome.subscriptionInfoUpdatedAt
                    // `lastUpdated` keeps its own meaning: the configuration refreshed
                    // successfully. It is not the quota's timestamp, and a refresh that captured no
                    // quota still legitimately advances it.
                    lastUpdated = now
                },
                persist: { try await persistProfile(self) },
                writeBody: { try await self.writeAsync($0) },
                storedBodyRevision: { (try? await self.readAsync()).map(ConfigurationBodyRevision.fingerprint(of:)) },
                expectedBodyRevision: effectiveTicket.storedBodyRevision,
                storedBody: { try? await self.readAsync() },
                reloadService: reloadService ?? { body in
                    try await self.applyBody(body, ticket: effectiveTicket)
                },
                canApply: canApply,
                isStillCurrent: isStillCurrent,
                refreshProviders: refreshProviders ?? { .notActive }
            )
        } catch let error as ProfileSupersededError {
            // Losing to a newer update is a result, not a failure: the caller must not show it as
            // an error and must not retry it.
            _ = error
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: await (providersOnFailure ?? { .notActive })().summary
            )
        }
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

    /// Applies the profile as it is currently stored.
    ///
    /// This is the editor's path: the user changed the body and asked for it to take effect, so the
    /// snapshot is taken from the store rather than from a request. The receipt is not reported to
    /// the editor - it has its own error handling - but it is still required, because the old path's
    /// "the send returned" was not evidence that the document took effect.
    nonisolated func onProfileUpdated() async throws {
        guard await SharedPreferences.selectedProfileID.get() == id else {
            return
        }
        guard let profile = try? await ExtensionProfile.load() else {
            return
        }
        guard await profile.status == .connected else {
            return
        }
        let content = try await readAsync()
        let ticket = ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: remoteURL,
            storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: content)
        )
        switch try await applyBody(content, ticket: ticket) {
        case .none:
            // No receipt this update can attribute to itself: `sendProviderMessage` answers nil both
            // when the message was lost and when the extension predates the envelope, so the editor
            // is told the apply was not confirmed rather than that it failed.
            throw ExtensionApplyError(message: String(localized: "the extension did not confirm the configuration"))
        case let .some(outcome):
            // One implementation of "this is not an applied document", shared with the legacy
            // reload entry: a recovery and an interruption must read the same from both.
            try ExtensionProfile.confirmApplied(outcome)
        }
    }
}
