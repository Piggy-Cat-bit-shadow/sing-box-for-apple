import Foundation

/// What the macOS subscription-quota caption should state for one profile.
///
/// The decision is kept out of the SwiftUI view on purpose: it is the part that can be wrong in a
/// way the user pays for (which figure is shown, whether a date is already past, whether the quota
/// is old enough that claiming freshness would mislead), and it is Foundation-only so it can be
/// compiled and asserted where no SwiftUI is available. The view renders what this returns.
///
/// It reads the existing model and changes nothing about it: a missing upload/download is still
/// indistinguishable from a reported zero, which is why `used` is only offered when it is positive.
enum SubscriptionQuotaCaption {
    /// The usage half of the caption.
    enum Usage: Equatable {
        /// A positive total: the remaining bytes and the total they are out of.
        case remaining(Int64, Int64)
        /// No total was reported, but a positive used amount proves the panel said something.
        case used(Int64)
    }

    /// The expiry half of the caption.
    struct Expiry: Equatable {
        let date: Date
        let expired: Bool
    }

    /// Everything the caption may render. An empty content means "show nothing at all", which is
    /// what keeps a profile without a quota from adding height to the card.
    struct Content: Equatable {
        let usage: Usage?
        let expiry: Expiry?
        /// The quota's own capture time, present only when it differs from the configuration
        /// refresh time. Without that difference the nearby "2 hours ago" already describes it.
        let capturedAt: Date?

        var isEmpty: Bool { usage == nil && expiry == nil }
    }

    /// The last instant this caption presents as a date: 9999-12-31T23:59:59Z.
    ///
    /// A panel that reports milliseconds by mistake, or a hostile value, would otherwise render a
    /// year in the tens of thousands. The caption hides it instead of printing a date nobody can
    /// act on; the value is still on the server.
    static let expiryLimit: Int64 = 253_402_300_799

    /// One second of tolerance between the two timestamps: both are written from one refresh, so
    /// anything inside a second is the same event rather than an older capture.
    private static let captureTolerance: TimeInterval = 1

    /// The caption content for one profile, or nil when there is nothing reliable to say.
    static func content(
        isRemote: Bool,
        info: SubscriptionInfo?,
        capturedAt: Date?,
        lastUpdated: Date?,
        now: Date
    ) -> Content? {
        guard isRemote, let info else { return nil }

        let usage: Usage?
        if let remaining = info.remainingBytes {
            usage = .remaining(remaining, info.total)
        } else if info.usedBytes > 0 {
            // `remainingBytes` is nil exactly when the total is not positive. A zero here may be
            // "the panel reported zero" or "the panel reported no upload/download at all", and the
            // stored model cannot tell them apart - so only a positive used amount is shown.
            usage = .used(info.usedBytes)
        } else {
            usage = nil
        }

        var expiry: Expiry?
        if info.expire > 0, info.expire <= expiryLimit {
            let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
            expiry = Expiry(date: date, expired: now >= date)
        }

        let content = Content(
            usage: usage,
            expiry: expiry,
            capturedAt: staleCapture(capturedAt: capturedAt, lastUpdated: lastUpdated)
        )
        return content.isEmpty ? nil : content
    }

    /// The quota capture time when it is meaningfully older than the configuration refresh.
    private static func staleCapture(capturedAt: Date?, lastUpdated: Date?) -> Date? {
        guard let capturedAt, let lastUpdated,
              abs(lastUpdated.timeIntervalSince(capturedAt)) >= captureTolerance
        else { return nil }
        return capturedAt
    }
}
