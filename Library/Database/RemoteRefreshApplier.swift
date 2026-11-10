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
public enum RemoteRefreshApplier {
    /// - Parameters:
    ///   - outcome: the decision produced by `RemoteProfileRefresh.evaluate`.
    ///   - applyMetadata: stores the merged metadata on the profile. Always called exactly once.
    ///   - persist: commits the profile. Always called exactly once, and before any body write.
    ///   - writeBody: rewrites the configuration file. Called only when the body changed.
    ///   - reloadService: asks the running service to reload. Called only when the body changed.
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

    /// The same sequence, plus the provider half and the reload confirmation.
    ///
    /// The body half and the provider half are reported independently: a failed or unconfirmed
    /// reload still probes the live instance, because the old Box may still be serving and its
    /// remote node sources are a different failure domain. The probe is a value the caller
    /// supplies, so "not active", "not running" and "the daemon predates the RPC" stay distinct
    /// from an empty report.
    public static func applyReporting(
        _ outcome: RemoteRefreshOutcome,
        applyMetadata: () -> Void,
        persist: () async throws -> Void,
        writeBody: (String) async throws -> Void,
        storedBody: (() async -> String?)? = nil,
        reloadService: () async throws -> Void,
        canApply: (() async -> Bool)? = nil,
        isStillCurrent: (() async -> Bool)? = nil,
        confirmStartedAt: (() async -> Int64?)? = nil,
        refreshProviders: (Int64?) async -> RemoteProviderRefreshProbe
    ) async throws -> RemoteProfileUpdateReport {
        applyMetadata()
        try await persist()
        guard outcome.writeBody, let body = outcome.bodyToWrite else {
            // Metadata-only refresh: no reload, but the running instance's providers may still be
            // refreshed by the same user action. If the profile stopped being current, the answer
            // belongs to whoever is current now, so it is not reported as this profile's update.
            let current = await isStillCurrent?() ?? true
            return RemoteProfileUpdateReport(
                config: current ? .unchanged : .superseded,
                providers: await refreshProviders(nil).summary
            )
        }
        try await writeBody(body)
        // The body we just wrote must still be the stored one: another update of the same profile
        // can replace it while this operation is between the write and the daemon call. Reloading
        // then would apply someone else's document and report it as ours.
        if let storedBody, await storedBody() != body {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: await refreshProviders(nil).summary
            )
        }
        // The body is saved whether or not this profile is the running one; a profile that is not
        // selected (or a disconnected tunnel) must not pretend to have applied it.
        if let canApply, await canApply() == false {
            return RemoteProfileUpdateReport(
                config: .saved,
                providers: await refreshProviders(nil).summary
            )
        }
        // Last boundary before touching the daemon: a switch that landed while the body was being
        // written must not turn into a reload of the new selection.
        if let isStillCurrent, await isStillCurrent() == false {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: await refreshProviders(nil).summary
            )
        }
        var config: RemoteConfigUpdateOutcome
        var confirmedStartedAt: Int64?
        do {
            try await reloadService()
            if let isStillCurrent, await isStillCurrent() == false {
                config = .superseded
            } else if let storedBody, await storedBody() != body {
                // A newer body replaced ours while the daemon was reloading; the Box may be serving
                // either one, so this operation cannot claim the apply.
                config = .superseded
            } else if let confirmStartedAt {
                if let confirmed = await confirmStartedAt() {
                    confirmedStartedAt = confirmed
                    config = .applied
                } else {
                    config = .applyUnconfirmed
                }
            } else {
                config = .applied
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
        return RemoteProfileUpdateReport(
            config: config,
            providers: await refreshProviders(confirmedStartedAt).summary
        )
    }
}
