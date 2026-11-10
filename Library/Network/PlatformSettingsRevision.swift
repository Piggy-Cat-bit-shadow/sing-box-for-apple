import Foundation

// The platform settings that shape the tunnel the system actually installed.
//
// # Why a document comparison cannot see these
//
// A profile's document says what the core should do with packets. It says nothing about how the
// tunnel is presented to iOS: which routes are included and excluded, whether the APNs range is
// excluded from the tunnel, whether the system proxy is enabled, whether the utun MTU is clamped for
// a hotspot. Those are applied by the NetworkExtension itself, in `openTun`, when the core asks the
// platform to open a TUN - and they are installed by the SYSTEM for that session.
//
// So a user who only flips "Exclude APNs route" sends a body that is byte-identical to the running
// one. The core's own entry answers "already runs this document" - truthfully, for the document -
// and can even satisfy the reload by refreshing a remote provider in place. `openTun` is never
// called, the new route list is never installed, and the switch appears to do nothing. The same
// shape applies to every setting below.
//
// # What this file is for
//
// One comparable value over exactly those settings, and the decision the extension needs: this
// change is invisible to the document, so it needs a rebuild - or it is the one setting the platform
// can re-apply without re-opening the TUN.
//
// Foundation-only and value-typed on purpose: the decision is testable without NetworkExtension, and
// the extension only has to hold one of these.

/// The settings the NetworkExtension applies to the installed tunnel.
///
/// Each field is one that reaches `NEPacketTunnelNetworkSettings` or `NETunnelProviderProtocol` in
/// `openTun`/`applyProtocolConfiguration`. Fields that only affect the core belong in the profile
/// document, not here.
public struct PlatformSettingsSnapshot: Equatable, Sendable {
    /// From `NETunnelProviderProtocol`: iOS routes Personal Hotspot clients into this utun in this
    /// mode, and the MTU is clamped for it.
    public var includeAllNetworks: Bool
    /// From `NETunnelProviderProtocol`.
    public var excludeLocalNetworks: Bool
    /// From `NETunnelProviderProtocol`.
    public var enforceRoutes: Bool
    /// From `NETunnelProviderProtocol` (iOS 16.4+): Apple's services stay off this tunnel.
    public var excludeAPNs: Bool
    /// From `NETunnelProviderProtocol` (iOS 16.4+).
    public var excludeCellularServices: Bool
    /// From `NETunnelProviderProtocol` (iOS 17.4+).
    public var excludeDeviceCommunication: Bool
    /// Shapes the proxy settings installed with the tunnel.
    public var systemProxyEnabled: Bool
    /// Adds an exclude route for the whole IPv4/IPv6 space.
    public var excludeDefaultRoute: Bool
    /// Chooses the sub-range route shape instead of a default route.
    public var autoRouteUseSubRangesByDefault: Bool
    /// Adds an exclude route for `17.0.0.0/8` (and a proxy bypass domain).
    public var excludeAPNsRoute: Bool
    /// Adds a host route for the local signing loopback address (iOS only).
    public var localSigningLoopback: Bool

    public init(
        includeAllNetworks: Bool = false,
        excludeLocalNetworks: Bool = false,
        enforceRoutes: Bool = false,
        excludeAPNs: Bool = false,
        excludeCellularServices: Bool = false,
        excludeDeviceCommunication: Bool = false,
        systemProxyEnabled: Bool = true,
        excludeDefaultRoute: Bool = false,
        autoRouteUseSubRangesByDefault: Bool = false,
        excludeAPNsRoute: Bool = false,
        localSigningLoopback: Bool = false
    ) {
        self.includeAllNetworks = includeAllNetworks
        self.excludeLocalNetworks = excludeLocalNetworks
        self.enforceRoutes = enforceRoutes
        self.excludeAPNs = excludeAPNs
        self.excludeCellularServices = excludeCellularServices
        self.excludeDeviceCommunication = excludeDeviceCommunication
        self.systemProxyEnabled = systemProxyEnabled
        self.excludeDefaultRoute = excludeDefaultRoute
        self.autoRouteUseSubRangesByDefault = autoRouteUseSubRangesByDefault
        self.excludeAPNsRoute = excludeAPNsRoute
        self.localSigningLoopback = localSigningLoopback
    }

    /// The settings whose change only a rebuild can install, as stable keys.
    ///
    /// Ordered as declared, so a report's reason list is deterministic. The proxy is deliberately
    /// absent: it is the one setting the platform can re-apply to the installed settings without
    /// re-opening the TUN, and forcing a rebuild there would drop the user's connections for a
    /// switch that did not need it.
    public var installedSettingsKeys: [String] {
        var keys: [String] = []
        if includeAllNetworks { keys.append("includeAllNetworks") }
        if excludeLocalNetworks { keys.append("excludeLocalNetworks") }
        if enforceRoutes { keys.append("enforceRoutes") }
        if excludeAPNs { keys.append("excludeAPNs") }
        if excludeCellularServices { keys.append("excludeCellularServices") }
        if excludeDeviceCommunication { keys.append("excludeDeviceCommunication") }
        if excludeDefaultRoute { keys.append("excludeDefaultRoute") }
        if autoRouteUseSubRangesByDefault { keys.append("autoRouteUseSubRangesByDefault") }
        if excludeAPNsRoute { keys.append("excludeAPNsRoute") }
        if localSigningLoopback { keys.append("localSigningLoopback") }
        return keys
    }

    /// A stable fingerprint of the settings above, for a report that must not carry a list.
    public var revision: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for key in installedSettingsKeys {
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            // A separator, so two adjacent keys cannot concatenate into a third one.
            hash ^= 0xff
            hash = hash &* 0x0000_0100_0000_01b3
        }
        if systemProxyEnabled {
            hash ^= 0x01
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // The zero value of a fingerprint is reserved for "no settings recorded".
        return hash == 0 ? 1 : hash
    }
}

/// What a candidate set of platform settings means for the running tunnel.
public enum PlatformSettingsChange: Equatable, Sendable {
    /// Nothing the platform installed moved.
    case unchanged
    /// Only the proxy switch moved: the platform can re-apply it to the installed settings.
    case proxyOnly
    /// A setting that shapes the installed network settings moved. Only a rebuild reinstalls it,
    /// and `keys` names which ones (never their values).
    case needsRebuild(keys: [String])
}

public enum PlatformSettingsPolicy {
    /// Compares what the system installed against what the caller is about to ask for.
    ///
    /// - Parameters:
    ///   - applied: the settings the running tunnel was configured with, or nil when this process
    ///     does not know them - a fresh start, or a reload before the first apply. Nil is
    ///     `unchanged`, deliberately: the settings of a tunnel that just started ARE the ones it
    ///     started with, and claiming a rebuild there would replace every tunnel on every reload.
    ///   - candidate: the settings this apply would install.
    public static func change(from applied: PlatformSettingsSnapshot?, to candidate: PlatformSettingsSnapshot) -> PlatformSettingsChange {
        guard let applied else {
            return .unchanged
        }
        if applied == candidate {
            return .unchanged
        }
        var changedKeys: [String] = []
        for (key, lhs, rhs) in [
            ("includeAllNetworks", applied.includeAllNetworks, candidate.includeAllNetworks),
            ("excludeLocalNetworks", applied.excludeLocalNetworks, candidate.excludeLocalNetworks),
            ("enforceRoutes", applied.enforceRoutes, candidate.enforceRoutes),
            ("excludeAPNs", applied.excludeAPNs, candidate.excludeAPNs),
            ("excludeCellularServices", applied.excludeCellularServices, candidate.excludeCellularServices),
            ("excludeDeviceCommunication", applied.excludeDeviceCommunication, candidate.excludeDeviceCommunication),
            ("excludeDefaultRoute", applied.excludeDefaultRoute, candidate.excludeDefaultRoute),
            ("autoRouteUseSubRangesByDefault", applied.autoRouteUseSubRangesByDefault, candidate.autoRouteUseSubRangesByDefault),
            ("excludeAPNsRoute", applied.excludeAPNsRoute, candidate.excludeAPNsRoute),
            ("localSigningLoopback", applied.localSigningLoopback, candidate.localSigningLoopback),
        ] where lhs != rhs {
            changedKeys.append(key)
        }
        if changedKeys.isEmpty {
            // The proxy switch is the only difference left.
            return .proxyOnly
        }
        return .needsRebuild(keys: changedKeys)
    }
}
