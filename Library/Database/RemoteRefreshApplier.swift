import Foundation

/// Applies one refresh outcome to a profile.
///
/// This is the shipping sequence, extracted so that the *order* of the side effects can be tested
/// without a network, a database or a running tunnel. Everything here is injected: the caller
/// supplies what "store the metadata" and "reload the service" mean.
///
/// The order is the whole point, and it is the difference between a panel's traffic figures
/// surviving a refresh and being thrown away:
///
/// 1. `persist` runs **always**, before the body is compared with anything;
/// 2. the body is written, and the service reloaded, **only** when the body actually changed.
///
/// A panel's YAML commonly stays byte-identical for days while its usage counter moves on every
/// request, so the metadata must not live behind the "did the body change" test. Conversely, a
/// metadata-only refresh must not reach the write or the reload: remaining traffic is not a kernel
/// configuration change, and reloading a running tunnel for it would drop the user's connections
/// for a number in a card.
///
/// # The commit is a test-and-set, and the confirmation is a receipt
///
/// Two checks surround the write, and neither is the old "read the body back after writing it":
///
///   - BEFORE the write, `storedBodyRevision` is read and compared with `expectedBodyRevision`. If
///     another writer replaced the body, this update no longer owns the profile and does not write.
///   - AFTER the reload, the extension's receipt says which document it applied. A receipt that is
///     missing, unreadable or about another request is `applyUnconfirmed`, never "applied".
///
/// Reading the body back could not do the first job: an update that wrote and then read would always
/// find its own bytes. And a start timestamp could not do the second: a hot reload keeps the
/// timestamp, and an unrelated restart moves it without applying this document.
public enum RemoteRefreshApplier {
    /// The plain sequence: metadata always, body only when it changed.
    ///
    /// Used where there is no running service to report to (an import, or a profile that is not the
    /// selected one). The reporting variant below is the same order with the commit checks and the
    /// receipt attached.
    public static func apply(
        _ outcome: RemoteRefreshOutcome,
        applyMetadata: () -> Void,
        persist: () async throws -> Void,
        writeBody: (String) async throws -> Void,
        reloadService: () async throws -> Void
    ) async throws {
        applyMetadata()
        try await persist()
        guard outcome.writeBody, let body = outcome.bodyToWrite else {
            return
        }
        try await writeBody(body)
        try await reloadService()
    }

    /// - Parameters:
    ///   - outcome: the decision produced by `RemoteProfileRefresh.evaluate`.
    ///   - applyMetadata: stores the merged metadata on the profile. Always called exactly once.
    ///   - persist: commits the profile. Always called exactly once, and before any body commit.
    ///   - commitBody: performs the whole test-and-set for the body - read the currently stored
    ///     revision, compare it with the one this update read, write atomically only if it matches -
    ///     in ONE operation. It is a single closure on purpose: a separate "read the revision" and
    ///     "write the body" pair leaves the comparison and the write apart, which is where a slower
    ///     update overwrites a newer body.
    ///   - storedBody: reads the body as it is stored now. Used for the supersede check that sits
    ///     immediately before the daemon is touched.
    ///   - reloadService: asks the running service to apply `body` and returns what the extension
    ///     proved about the attempt, or nil when the extension answered nothing usable.
    ///   - refreshProviders: the provider half, which is a separate failure domain from the body.
    public static func applyReporting(
        _ outcome: RemoteRefreshOutcome,
        applyMetadata: () -> Void,
        persist: () async throws -> Void,
        commitBody: (String) async throws -> ProfileBodyCommit,
        storedBody: (() async -> String?)? = nil,
        reloadService: (String) async throws -> ExtensionApplyOutcome?,
        canApply: (() async -> Bool)? = nil,
        isStillCurrent: (() async -> Bool)? = nil,
        refreshProviders: () async -> RemoteProviderRefreshProbe
    ) async throws -> RemoteProfileUpdateReport {
        applyMetadata()
        try await persist()
        guard outcome.writeBody, let body = outcome.bodyToWrite else {
            // Metadata-only refresh: no reload, but the running instance's providers may still be
            // refreshed by the same user action. If the profile stopped being current, the answer
            // belongs to whoever is current now, so it is not reported as this profile's update - and
            // a superseded answer owes the instance nothing, including the provider half.
            //
            // The two outcomes share `ProviderRefreshPolicy` with every other branch, so this path
            // cannot drift back into refreshing on a lost claim: `.unchanged` refreshes because the
            // running instance IS this profile, `.superseded` skips.
            let current = await isStillCurrent?() ?? true
            let config: RemoteConfigUpdateOutcome = current ? .unchanged : .superseded
            let providers: RemoteProviderRefreshProbe
            if let skipped = ProviderRefreshPolicy.skippedProbe(for: config) {
                providers = skipped
            } else {
                providers = await refreshProviders()
            }
            return RemoteProfileUpdateReport(config: config, providers: providers.summary)
        }
        // The test-and-set, as ONE operation: it reads the stored revision, compares it with the one
        // this update read, and writes - inside the caller's own critical section. A comparison here
        // and a write later is how a slower update replaces a newer body and then reads its own bytes
        // back as proof that it won.
        guard case .committed = try await commitBody(body) else {
            // A superseded request has NO side effects on the live instance - including the provider
            // half. The update that won owns the refresh, and refreshing here would publish another
            // profile's nodes for a request that lost its claim.
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: RemoteProviderRefreshProbe.skipped(.superseded).summary
            )
        }
        // The body is saved whether or not this profile is the running one; a profile that is not
        // selected (or a disconnected tunnel) must not pretend to have applied it.
        if let canApply, await canApply() == false {
            // Saved, not applied. The running instance is serving a different profile, so its
            // providers are not this update's to refresh.
            return RemoteProfileUpdateReport(
                config: .saved,
                providers: RemoteProviderRefreshProbe.skipped(.notRunningThisProfile).summary
            )
        }
        // Last boundary before touching the daemon: a switch that landed while the body was being
        // written must not turn into a reload of the new selection.
        if let isStillCurrent, await isStillCurrent() == false {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: RemoteProviderRefreshProbe.skipped(.superseded).summary
            )
        }
        // ... and the stored-body comparison belongs HERE, immediately before the send, not earlier.
        //
        // It used to run right after the write, which left two awaits between the check and the
        // commit: another writer could replace the body in that gap and this operation would then
        // apply the older one while both updates report a coherent story. The check cannot be atomic
        // with the send (the send is the commit, and it crosses a process), but putting it as late as
        // it can be is what keeps the residual window to the send itself.
        if let storedBody, await storedBody() != body {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: RemoteProviderRefreshProbe.skipped(.superseded).summary
            )
        }
        var config: RemoteConfigUpdateOutcome
        do {
            // The body this operation wrote is what is sent, not a re-read of the selection: a
            // switch between the write and the reload must not apply the new profile's body while
            // this attempt reports the old one's.
            let receipt = try await reloadService(body)
            if let isStillCurrent, await isStillCurrent() == false {
                config = .superseded
            } else if let storedBody, await storedBody() != body {
                // A newer body replaced ours while the daemon was reloading; the Box may be serving
                // either one, so this operation cannot claim the apply.
                config = .superseded
            } else if let receipt {
                // The extension named the document it applied. What it says is the answer, and it
                // distinguishes a recovery and an interruption from a failure.
                config = receipt.configOutcome
            } else {
                // No receipt this update can attribute to itself. That is "unconfirmed" - not a
                // failure, and not a reason to retry or roll back: the commit point has passed.
                //
                // There is deliberately no fallback to the daemon's `startedAt`: a hot reload keeps
                // it, and an unrelated restart moves it, so it cannot answer "is MY document
                // running". It could only ever turn "unknown" into a guess.
                config = .applyUnconfirmed
            }
        } catch {
            // A failed reload of an operation that no longer owns the selection is not evidence
            // about the profile that does; it is a superseded result.
            if let isStillCurrent, await isStillCurrent() == false {
                config = .superseded
            } else {
                config = .applyFailed(error.localizedDescription)
            }
        }
        // The provider half runs only when this update's document reached the running service; the
        // rule itself is `ProviderRefreshPolicy`, so the profile path's failure branches cannot spell
        // it differently.
        let providers: RemoteProviderRefreshProbe
        if let skipped = ProviderRefreshPolicy.skippedProbe(for: config) {
            providers = skipped
        } else {
            providers = await refreshProviders()
        }
        return RemoteProfileUpdateReport(config: config, providers: providers.summary)
    }
}
