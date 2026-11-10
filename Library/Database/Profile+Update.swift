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
        //
        // The report is CONSUMED here, not dropped: this is the wrapper the shortcut calls, and it
        // can only answer "throw or not". A structured failure reported as success is the one mistake
        // this entry can make that the user cannot see - so every outcome that is not a clean apply
        // throws, with the report's own sentence as the message. `.saved` and `.superseded` are not
        // exceptions to that: the shortcut asked for an update, and neither means "the running
        // service is now using the new configuration".
        let report = try await updateRemoteProfileReporting()
        guard report.isLegacyFailure else {
            // The three outcomes the shortcut asked for: the document runs, the document already ran,
            // or the profile was saved for a service that is running something else. `.saved` is a
            // real result for a non-selected profile, not an error.
            return
        }
        // Everything else means the shortcut's promise - "your update took effect" - is not what
        // happened, so it must not answer `true`. The report's own sentence is the user-readable
        // message; `ProfileUpdateFailure` is the framework's own type, because this wrapper lives
        // in the framework and cannot see the app's presentation layer.
        throw ProfileUpdateFailure(report: report)
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
        // The metadata half's compare-and-set uses the timestamps AS STORED, with NULL preserved.
        // `Profile.lastUpdated` is a DISPLAY default (`init(row:)` substitutes `Date()` for a NULL), so
        // two reads of an untouched row differ and the comparison would refuse every refresh of a
        // profile that has never been refreshed.
        let storedTimestamps = try? await storedMetadataTimestamps()
        let ticket = ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: remoteURL,
            storedBodyRevision: storedBody.map(ConfigurationBodyRevision.fingerprint(of:)),
            expectedLastUpdated: storedTimestamps?.lastUpdated,
            expectedCapturedAt: storedTimestamps?.capturedAt
        )
        // The instance this download starts against. The same id can come back after A -> B -> A on
        // a new Box, so the id alone cannot say which instance may receive this body.
        let selectedAtStart = await Self.isSelected(id)
        let runningAtStart = selectedAtStart ? await Self.tunnelConnected() : false
        var before: Int64?
        if runningAtStart {
            before = await Self.tunnelStartedAt()
        }
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
                guard await Self.isSelected(self.id), await Self.tunnelConnected() else { return false }
                // The same id can come back after A -> B -> A on a new Box. The download started
                // against `before`; only that instance may receive this body.
                guard let before, await Self.tunnelStartedAt() == before else { return false }
                return true
            },
            isStillCurrent: { await Self.isSelected(self.id) },
            confirmStartedAt: {
                guard await Self.isSelected(self.id) else { return nil }
                // This is not the apply's confirmation - the receipt is (see `applyBody`). It only
                // has to name the instance the receipt's document landed on, so the provider half
                // cannot fall back to "whichever Box is current now". A restart moves the timestamp
                // and that new instance is the answer; a hot reload keeps it, and nil means "the
                // instance this operation started against", which is `before`.
                guard let before, let after = await Self.tunnelStartedAt(), after > before else { return nil }
                return after
            },
            refreshProviders: { confirmed in
                await Self.providerProbeIfCurrent(self.id, expectedStartedAt: confirmed ?? before)
            }
        )
    }

    /// Saves a fetched body without touching the live Box or its providers.
    ///
    /// This is the first half of a batch: every subscription can be downloaded and persisted
    /// independently, while the single provider refresh belongs to whichever profile is selected
    /// after the batch. It returns the body it stored, so the second half can prove that another
    /// writer did not replace it in between.
    nonisolated func prepareRemoteProfileReporting() async throws -> PreparedRemoteProfileUpdate {
        var storedBody: String?
        let report = try await refreshRemoteProfile(
            metadataProbe: { try await RemoteProfileFetcher.captureMetadata($0) },
            // Prepare records only download/validate/save. Selection and running state belong to
            // the apply step; an unchanged body in a profile that is not selected is still
            // `.unchanged`, not `.superseded`.
            canApply: { false },
            refreshProviders: { _ in .notActive },
            onStoredBody: { storedBody = $0 }
        )
        let startedAtAtPrepare: Int64?
        if await Self.isSelected(id), await Self.tunnelConnected() {
            startedAtAtPrepare = await Self.tunnelStartedAt()
        } else {
            startedAtAtPrepare = nil
        }
        return PreparedRemoteProfileUpdate(
            report: report,
            body: storedBody,
            startedAtAtPrepare: startedAtAtPrepare
        )
    }

    /// Applies the body [prepareRemoteProfileReporting] saved, once, to the current instance.
    ///
    /// The prepared body is compared with what is stored now; a newer write wins and this batch
    /// reports `superseded` instead of reloading someone else's document. For an unchanged body
    /// only the provider half runs. The reload is confirmed by the extension's receipt, and the
    /// provider refresh is pinned to the instance that received it, so it cannot fall back to
    /// "whichever Box is current now".
    nonisolated func applyPreparedRemoteProfileReporting(
        _ prepared: PreparedRemoteProfileUpdate
    ) async throws -> RemoteProfileUpdateReport {
        switch prepared.report.config {
        case .downloadFailed, .invalidConfig:
            // The configuration half failed, so nothing this update downloaded reached the running
            // service. `ProviderRefreshPolicy` owns that answer: there is no provider refresh. What
            // is still this step's to report is why - the failure belongs to the instance prepare
            // saw, and a Box started after prepare is a replacement that must not inherit it.
            let providers: RemoteProviderRefreshProbe
            if !(await Self.isSelected(id)) {
                providers = .notActive
            } else if !(await Self.tunnelConnected()) {
                providers = .notRunning
            } else if let before = prepared.startedAtAtPrepare,
                      (await Self.tunnelStartedAt()) == before,
                      let skipped = ProviderRefreshPolicy.skippedProbe(for: prepared.report.config) {
                // The same instance is still serving, but the document never reached it, so the
                // policy's reason is `.notApplied` rather than a lost claim. No probe runs: the
                // instance is not serving anything this update produced.
                providers = skipped
            } else {
                providers = .superseded
            }
            return RemoteProfileUpdateReport(
                config: prepared.report.config,
                providers: providers.summary
            )
        case .applyFailed, .applyUnconfirmed, .superseded:
            return prepared.report
        case .saved, .unchanged, .applied:
            break
        }
        guard await Self.isSelected(id) else {
            return RemoteProfileUpdateReport(config: .saved, providers: RemoteProviderRefreshProbe.notActive.summary)
        }
        guard await Self.tunnelConnected(), let before = await Self.tunnelStartedAt() else {
            return RemoteProfileUpdateReport(config: .saved, providers: RemoteProviderRefreshProbe.notRunning.summary)
        }
        if prepared.report.config == .unchanged {
            // The body prepare observed is still the stored one, or the profile has no stored body
            // at all: either way there is nothing to reload, only providers to refresh. A newer body
            // means the provider half belongs to the update that wrote it.
            let stored = try? await readAsync()
            guard stored == prepared.body else {
                return RemoteProfileUpdateReport(
                    config: .superseded,
                    providers: RemoteProviderRefreshProbe.skipped(.superseded).summary
                )
            }
            let providers = await Self.providerProbeIfCurrent(id, expectedStartedAt: before)
            return RemoteProfileUpdateReport(config: .unchanged, providers: providers.summary)
        }
        guard let stored = try? await readAsync(), let preparedBody = prepared.body else {
            let config = RemoteConfigUpdateOutcome.applyFailed("stored body unavailable")
            return RemoteProfileUpdateReport(
                config: config,
                providers: ProviderRefreshPolicy.skippedProbe(for: config) ?? .skipped(.notApplied)
            )
        }
        guard stored == preparedBody else {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: RemoteProviderRefreshProbe.skipped(.superseded).summary
            )
        }
        var config: RemoteConfigUpdateOutcome
        do {
            // The body is already on disk: this half only commits it to the running service, and
            // the receipt - not the send returning - is what says it landed.
            config = try await applyPreparedBody(preparedBody)
        } catch {
            config = .applyFailed(error.localizedDescription)
        }
        if await Self.isSelected(id) == false {
            // The selection moved while the apply was in flight; the answer is not this profile's.
            config = .superseded
        } else if (try? await readAsync()) != preparedBody {
            // A newer body replaced ours while the daemon was applying; the Box may be serving
            // either one, so this update cannot claim the apply.
            config = .superseded
        }
        // The provider half runs once per batch, for the profile that is selected after it, and only
        // when this update's document reached the running service (`ProviderRefreshPolicy`). The
        // instance is the one the receipt's reload landed on, not "whichever Box is current now".
        let providers: RemoteProviderRefreshProbe
        if let skipped = ProviderRefreshPolicy.skippedProbe(for: config) {
            providers = skipped
        } else {
            let confirmed = await Self.tunnelStartedAt()
            providers = await Self.providerProbeIfCurrent(id, expectedStartedAt: confirmed)
        }
        return RemoteProfileUpdateReport(config: config, providers: providers.summary)
    }

    /// Sends the body the prepare half committed, and reports what the receipt proved.
    ///
    /// There is deliberately no body comparison here: the apply step already established that the
    /// stored bytes are the prepared ones. The ticket is built from the body being sent and the
    /// metadata as stored now, so the receipt is attributed to THIS send and not to an overlapping
    /// update of the same profile.
    private nonisolated func applyPreparedBody(_ body: String) async throws -> RemoteConfigUpdateOutcome {
        let storedTimestamps = try? await storedMetadataTimestamps()
        let ticket = ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: remoteURL,
            storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: body),
            expectedLastUpdated: storedTimestamps?.lastUpdated,
            expectedCapturedAt: storedTimestamps?.capturedAt
        )
        guard let outcome = try await applyBody(body, ticket: ticket) else {
            // No receipt this update can attribute to itself: unconfirmed, never applied, and
            // nothing to retry or roll back - the commit point has passed.
            return .applyUnconfirmed
        }
        return outcome.configOutcome
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

    /// Commits one body against the revision this update read, as a single operation.
    ///
    /// # Why the lock and the single blocking section are both needed
    ///
    /// `BlockingIO` runs its blocks on a CONCURRENT queue, so "read the revision" and "write the body"
    /// as two calls can interleave with another update's calls: both read the old revision, both
    /// decide they own the profile, and the later write wins - which is the race this exists to
    /// remove. One blocking section plus one in-process lock (`BodyCommitLock.shared`, shared with the
    /// editor's save) is the smallest implementation that makes the read and the write indivisible
    /// here. (Cross-process writers - the Intents extension - are a separate boundary; the design for
    /// closing that is recorded in the handoff.)
    ///
    /// The file is the authority for the body: the profile row records metadata, not content.
    nonisolated func commitBody(_ body: String, ticket: ProfileUpdateTicket) async throws -> ProfileBodyCommit {
        try await BlockingIO.run {
            try BodyCommitLock.shared.withLock {
                let stored = try? self.read()
                let storedRevision = stored.map(ConfigurationBodyRevision.fingerprint(of:))
                guard storedRevision == ticket.storedBodyRevision else {
                    return ProfileBodyCommit.superseded(storedRevision: storedRevision)
                }
                try self.write(body)
                return ProfileBodyCommit.committed(newRevision: ConfigurationBodyRevision.fingerprint(of: body))
            }
        }
    }

    /// The metadata timestamps exactly as stored, with NULL preserved.
    ///
    /// One row, two columns, read through the writer so it sees committed state - and read WITHOUT
    /// `Profile.init(row:)`, whose `Date()` default for a NULL `lastUpdated` turns an untouched row into
    /// a moving value. Both sides of the compare-and-set come from here: the ticket before the update,
    /// and `ProfileManager.update(_:ticket:)` inside its write transaction.
    nonisolated func storedMetadataTimestamps() async throws -> StoredMetadataTimestamps? {
        guard let id else {
            return nil
        }
        return try await Database.sharedWriter.read { db in
            try StoredMetadataTimestamps.fetchOne(
                db,
                sql: "SELECT lastUpdated, subscriptionInfoUpdatedAt FROM profiles WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Writes a body this process authored - an editor save - under the same lock as a remote commit.
    ///
    /// Unconditional on purpose: a save is the user's decision, so it does not compare revisions. What
    /// it must not do is land BETWEEN a refresh's comparison and its write, because then the refresh
    /// discards the save while both operations report success. Taking the lock puts the two in a
    /// defined order: either the save lands first (the refresh sees it and supersedes) or the refresh
    /// commits first and the save then wins, which is what the user asked for.
    nonisolated func saveBody(_ content: String) async throws {
        try await BlockingIO.run {
            try BodyCommitLock.shared.withLock {
                try self.write(content)
            }
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
    nonisolated static func providerProbeIfCurrent(
        _ id: Int64?,
        expectedStartedAt: Int64?
    ) async -> RemoteProviderRefreshProbe {
        let selected = await isSelected(id)
        let connected = await tunnelConnected()
        let current = connected ? await tunnelStartedAt() : nil
        switch providerTargetDecision(
            selected: selected,
            connected: connected,
            expectedStartedAt: expectedStartedAt,
            currentStartedAt: current
        ) {
        case .notActive:
            return .notActive
        case .notRunning:
            return .notRunning
        case .superseded:
            return .superseded
        case .ok:
            break
        }
        let probe = await probeProviderRefresh()
        let stillCurrent = await tunnelStartedAt()
        guard providerTargetDecision(
            selected: await isSelected(id),
            connected: await tunnelConnected(),
            expectedStartedAt: expectedStartedAt,
            currentStartedAt: stillCurrent
        ) == .ok else {
            return .superseded
        }
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

    /// The daemon's per-Box start timestamp, or nil when no Box is reachable.
    ///
    /// Pinned to this device's tunnel for the same reason the provider probe is: it identifies the
    /// instance a local profile update is talking about, and a remote session has no place in that
    /// question.
    nonisolated static func tunnelStartedAt() async -> Int64? {
        await BlockingIO.run {
            guard let client = try? CommandTarget.standaloneClient(scope: .localTunnel) else { return nil }
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
        confirmStartedAt: (() async -> Int64?)? = nil,
        refreshProviders: ((Int64?) async -> RemoteProviderRefreshProbe)? = nil,
        onStoredBody: ((String?) -> Void)? = nil
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
        let storedTimestamps = try? await storedMetadataTimestamps()
        let effectiveTicket = ticket ?? ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: url,
            storedBodyRevision: storedBodyRevision,
            expectedLastUpdated: storedTimestamps?.lastUpdated,
            expectedCapturedAt: storedTimestamps?.capturedAt
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
                // No refresh: the running instance is not serving anything this update produced. The
                // rule is the same one the applier uses, so the two paths cannot drift.
                providers: ProviderRefreshPolicy.skippedProbe(for: .invalidConfig(error.localizedDescription))?.summary
                    ?? RemoteProviderRefreshProbe.notActive.summary
            )
        } catch {
            return RemoteProfileUpdateReport(
                config: .downloadFailed(error.localizedDescription),
                providers: ProviderRefreshPolicy.skippedProbe(for: .downloadFailed(error.localizedDescription))?.summary
                    ?? RemoteProviderRefreshProbe.notActive.summary
            )
        }
        let persistProfile = persist ?? { profile in
            // The metadata commit re-checks the source inside the database transaction: this update
            // resolved a URL, downloaded from it, and its figures describe THAT subscription.
            try await ProfileManager.update(profile, ticket: effectiveTicket)
        }
        if !outcome.writeBody {
            // The document this refresh observed is the unchanged current body. Record the exact
            // value read here; the batch's apply step compares it with storage before reloading.
            onStoredBody?(currentBody)
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
                commitBody: { body in
                    // ONE critical section: read, compare, write. The comparison and the write must
                    // not be separated by an await, or another update can install a newer body in
                    // between and this one overwrites it.
                    try await self.commitBody(body, ticket: effectiveTicket)
                },
                storedBody: { try? await self.readAsync() },
                onBodyStored: { body in onStoredBody?(body) },
                reloadService: reloadService ?? { body in
                    try await self.applyBody(body, ticket: effectiveTicket)
                },
                canApply: canApply,
                isStillCurrent: isStillCurrent,
                confirmStartedAt: confirmStartedAt,
                refreshProviders: refreshProviders ?? { _ in .notActive }
            )
        } catch let error as ProfileSupersededError {
            // Losing to a newer update is a result, not a failure: the caller must not show it as
            // an error and must not retry it.
            _ = error
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: ProviderRefreshPolicy.skippedProbe(for: .superseded)?.summary
                    ?? RemoteProviderRefreshProbe.notActive.summary
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
        let storedTimestamps = try? await storedMetadataTimestamps()
        let ticket = ProfileUpdateTicket(
            profileID: id ?? 0,
            requestID: UUID().uuidString,
            remoteURL: remoteURL,
            storedBodyRevision: ConfigurationBodyRevision.fingerprint(of: content),
            expectedLastUpdated: storedTimestamps?.lastUpdated,
            expectedCapturedAt: storedTimestamps?.capturedAt
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
