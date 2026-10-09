import Foundation

/// The traffic metadata an airport panel returns alongside a subscription.
///
/// Ported from Hako-Client `apple/HakoClient/Sources/ConfigStore/Profile.swift` at
/// `62aa2f2fedffd46c245d5a87d2258c24bef3cd82`, which is the stable baseline this
/// client's UI work follows. The semantics are kept as they are upstream - in
/// particular the parser is the upstream parser, not a new one.
///
/// `expire` stays a Unix timestamp in seconds, which is how upstream stores it and
/// how it is persisted here. Turning it into a `Date` is a presentation concern and
/// belongs to the UI layer, not to the stored model.
/// `Hashable` is this client's one addition to the upstream declaration (which is
/// `Codable, Equatable`): `ProfilePreview` is `Hashable` and mirrors this value, so the conformance
/// is what keeps that snapshot usable in the lists and sheets that carry it. Nothing about the
/// stored or parsed value changes.
public struct SubscriptionInfo: Equatable, Hashable, Sendable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Int64

    public init(upload: Int64, download: Int64, total: Int64, expire: Int64) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }
}

extension SubscriptionInfo {
    /// Parse the `subscription-userinfo` response header.
    ///
    /// The header looks like `upload=123; download=456; total=107374182400; expire=1791552000`.
    /// Key order is not fixed and whitespace is allowed around keys and values.
    ///
    /// Upstream behaviour, deliberately preserved:
    /// - an unknown key is ignored rather than failing the parse;
    /// - a value that is not an integer drops that key, and `nil` from `Int64(...)` in a
    ///   dictionary subscript means "do not store", so the key falls back to the default;
    /// - a missing key defaults to `0`, so a header without `expire` still parses;
    /// - a header with no `key=value` pair at all returns `nil`, which callers must treat
    ///   as "no metadata in this response" and not as "zero usage".
    public static func parse(header: String) -> SubscriptionInfo? {
        var m: [String: Int64] = [:]
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            m[kv[0].trimmingCharacters(in: .whitespaces)] =
                Int64(kv[1].trimmingCharacters(in: .whitespaces))
        }
        guard !m.isEmpty else { return nil }
        return SubscriptionInfo(upload: m["upload"] ?? 0, download: m["download"] ?? 0,
                                total: m["total"] ?? 0, expire: m["expire"] ?? 0)
    }
}

// MARK: - Pure usage arithmetic

/// The usage figures the next round's UI reads. Kept free of SwiftUI on purpose: these are
/// model calculations, and they are the part of the upstream formatting file that this round
/// migrates. The views built on them are the next round's work.
extension SubscriptionInfo {
    /// Uploaded plus downloaded bytes.
    ///
    /// `addingReportingOverflow` rather than `+`, as upstream: two hostile values near
    /// `Int64.max` must clamp rather than trap. The clamp is to `Int64.max`, and because the
    /// result is therefore never negative, the `remainingBytes` subtraction below cannot
    /// overflow in either direction.
    public var usedBytes: Int64 {
        let (sum, overflow) = upload.addingReportingOverflow(download)
        return max(0, overflow ? Int64.max : sum)
    }

    /// Fraction of the quota consumed, or `nil` when the panel did not report a quota.
    ///
    /// `nil` for `total == 0` is meaningful to the UI: it means "unknown", which must render
    /// differently from "0% used".
    public var usageFraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(total), 0), 1)
    }

    /// Bytes still available, or `nil` when the panel did not report a quota.
    ///
    /// A used amount greater than the total yields `0`, not a negative remainder.
    public var remainingBytes: Int64? {
        guard total > 0 else { return nil }
        return max(0, total - usedBytes)
    }
}
