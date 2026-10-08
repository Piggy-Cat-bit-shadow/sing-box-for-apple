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
}
