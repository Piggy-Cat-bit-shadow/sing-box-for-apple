import Foundation

/// Whether a provider refresh may still be attributed to the instance an update confirmed.
///
/// `RefreshRemoteProviders` carries no instance argument. The only binding available is the
/// daemon's per-Box `startedAt`, captured before the operation: a profile id alone is not enough
/// because A -> B -> A returns to the same id, and a stopped/restarted Box is a new instance with
/// the same profile. An unknown expected or current timestamp is `superseded`, never "ok".
public enum ProviderTargetDecision: Equatable, Sendable {
    case ok
    case notActive
    case notRunning
    case superseded
}

public func providerTargetDecision(
    selected: Bool,
    connected: Bool,
    expectedStartedAt: Int64?,
    currentStartedAt: Int64?
) -> ProviderTargetDecision {
    if !selected { return .notActive }
    if !connected { return .notRunning }
    guard let expectedStartedAt, let currentStartedAt, expectedStartedAt == currentStartedAt else {
        return .superseded
    }
    return .ok
}
