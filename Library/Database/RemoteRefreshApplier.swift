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
    ///   - persist: commits the profile. Always called exactly once, and before any body write.
    ///   - writeBody: rewrites the configuration file. Called only when the body changed.
    ///   - storedBodyRevision: reads the revision of the body currently stored. Called once, before
    ///     the write, and is the test-and-set read.
    ///   - expectedBodyRevision: the revision the caller read when it decided to update. `nil` means
    ///     "there was no body"; it is not a wildcard.
    ///   - reloadService: asks the running service to apply `body` and returns what the extension
    ///     proved about the attempt, or nil when the extension answered nothing usable.
    ///   - refreshProviders: the provider half, which is a separate failure domain from the body.
    public static func applyReporting(
        _ outcome: RemoteRefreshOutcome,
        applyMetadata: () -> Void,
        persist: () async throws -> Void,
        writeBody: (String) async throws -> Void,
        storedBodyRevision: (() async -> String?)? = nil,
        expectedBodyRevision: String? = nil,
        storedBody: (() async -> String?)? = nil,
        reloadService: (String) async throws -> ExtensionApplyOutcome?,
        canApply: (() async -> Bool)? = nil,
        isStillCurrent: (() async -> Bool)? = nil,
        confirmStartedAt: (() async -> Bool)? = nil,
        refreshProviders: () async -> RemoteProviderRefreshProbe
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
                providers: await refreshProviders().summary
            )
        }
        // The test-and-set, immediately before the write and with nothing between them: the value
        // this update read when it decided to update must still be the stored one. A slower update
        // of the same profile loses here instead of overwriting a newer body and then reading its
        // own bytes back as proof that it won.
        if let storedBodyRevision, await storedBodyRevision() != expectedBodyRevision {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: await refreshProviders().summary
            )
        }
        try await writeBody(body)
        // A writer that replaced the body between the check above and the daemon call would still
        // make this report a claim about someone else's document, so the stored body is compared
        // once more before the daemon is touched.
        if let storedBody, await storedBody() != body {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: await refreshProviders().summary
            )
        }
        // The body is saved whether or not this profile is the running one; a profile that is not
        // selected (or a disconnected tunnel) must not pretend to have applied it.
        if let canApply, await canApply() == false {
            return RemoteProfileUpdateReport(
                config: .saved,
                providers: await refreshProviders().summary
            )
        }
        // Last boundary before touching the daemon: a switch that landed while the body was being
        // written must not turn into a reload of the new selection.
        if let isStillCurrent, await isStillCurrent() == false {
            return RemoteProfileUpdateReport(
                config: .superseded,
                providers: await refreshProviders().summary
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
            } else if let confirmStartedAt {
                // The legacy confirmation: an extension that answers nothing usable leaves only the
                // daemon's start timestamp, which cannot tell a hot reload from an unrelated
                // restart. It is kept for that case and never preferred to a receipt.
                config = await confirmStartedAt() ? .applied : .applyUnconfirmed
            } else {
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
        return RemoteProfileUpdateReport(
            config: config,
            providers: await refreshProviders().summary
        )
    }
}
