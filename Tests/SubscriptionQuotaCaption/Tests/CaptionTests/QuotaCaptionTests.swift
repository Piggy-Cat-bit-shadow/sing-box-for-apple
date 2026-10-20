import Foundation
import XCTest

import Caption

/// The caption's decision table, asserted against the shipped `SubscriptionQuotaCaption` and
/// `SubscriptionInfo` sources.
///
/// The cases are the ones an operator pays for when they are wrong: a missing quota rendered as
/// "0 / 0", an exhausted quota hidden, an over-quota remainder going negative, a timestamp in
/// milliseconds rendered as a year in the tens of thousands, an expiry boundary one second off, or
/// a stale quota presented as freshly captured.
final class QuotaCaptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09
    private var week: TimeInterval { 7 * 24 * 3600 }

    private func info(upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0, expire: Int64 = 0) -> SubscriptionInfo {
        SubscriptionInfo(upload: upload, download: download, total: total, expire: expire)
    }

    private func content(_ info: SubscriptionInfo?, remote: Bool = true, capturedAt: Date? = nil,
                         lastUpdated: Date? = nil, now: Date? = nil) -> SubscriptionQuotaCaption.Content?
    {
        SubscriptionQuotaCaption.content(isRemote: remote, info: info, capturedAt: capturedAt,
                                         lastUpdated: lastUpdated, now: now ?? self.now)
    }

    func testRemainingAndUsedArithmetic() {
        XCTAssertEqual(content(info(upload: 100, download: 200, total: 1000))?.usage, .remaining(700, 1000))
        XCTAssertEqual(content(info(upload: 500, download: 500, total: 1000))?.usage, .remaining(0, 1000),
                       "an exhausted quota has a real zero remainder")
        XCTAssertEqual(content(info(upload: 900, download: 300, total: 1000))?.usage, .remaining(0, 1000),
                       "an over-quota account clamps at zero")
        XCTAssertEqual(content(info(total: 1000))?.usage, .remaining(1000, 1000))
        XCTAssertEqual(content(info(upload: 10, total: -5))?.usage, .used(10),
                       "a negative total is not a quota; a positive used amount still is")
    }

    func testOverflowingUsageClamps() {
        let overflow = info(upload: .max, download: .max, total: .max)
        XCTAssertEqual(content(overflow)?.usage, .remaining(0, .max))
        XCTAssertEqual(content(info(total: .max))?.usage, .remaining(.max, .max))
    }

    func testEmptyCasesShowNothing() {
        XCTAssertNil(content(nil), "no metadata")
        XCTAssertNil(content(info(upload: 1, download: 1, total: 100), remote: false), "a local profile")
        XCTAssertNil(content(info()), "zero figures may mean the panel said nothing")
        XCTAssertNil(content(info(total: 0, expire: 0)))
    }

    func testExpiryIsSecondsAndHidesUnusableValues() {
        let future = Int64(now.timeIntervalSince1970) + 86_400
        let expiry = content(info(total: 10, expire: future))?.expiry
        XCTAssertNotNil(expiry)
        XCTAssertEqual(expiry!.date.timeIntervalSince1970, Double(future), accuracy: 0.5)
        XCTAssertFalse(expiry!.expired)

        XCTAssertNil(content(info(total: 10, expire: 0))?.expiry, "zero is not 1970")
        XCTAssertNil(content(info(total: 10, expire: -1))?.expiry)
        XCTAssertNil(content(info(total: 10, expire: .max))?.expiry, "a value beyond the calendar is hidden")
        XCTAssertNotNil(content(info(total: 10, expire: SubscriptionQuotaCaption.expiryLimit))?.expiry)
        XCTAssertNil(content(info(total: 10, expire: SubscriptionQuotaCaption.expiryLimit + 1))?.expiry)
    }

    func testExpiryBoundaryIsInclusive() {
        let atNow = Int64(now.timeIntervalSince1970)
        XCTAssertTrue(content(info(total: 10, expire: atNow))?.expiry?.expired ?? false)
        XCTAssertTrue(content(info(total: 10, expire: atNow - 1))?.expiry?.expired ?? false)
        XCTAssertFalse(content(info(total: 10, expire: atNow + 1))?.expiry?.expired ?? true)
    }

    func testOnlyThePartsThatExistAreProduced() {
        let expiryOnly = content(info(expire: Int64(now.timeIntervalSince1970) + 86_400))
        XCTAssertNil(expiryOnly?.usage)
        XCTAssertNotNil(expiryOnly?.expiry)

        let usageOnly = content(info(total: 10))
        XCTAssertNotNil(usageOnly?.usage)
        XCTAssertNil(usageOnly?.expiry)
    }

    func testCapturedAtIsStatedOnlyWhenItDiffersFromTheRefresh() {
        XCTAssertNil(content(info(total: 10), capturedAt: now, lastUpdated: now.addingTimeInterval(0.4))?.capturedAt,
                     "the same refresh must not claim an age")
        XCTAssertEqual(content(info(total: 10), capturedAt: now.addingTimeInterval(-week), lastUpdated: now)?.capturedAt,
                       now.addingTimeInterval(-week))
        XCTAssertNil(content(info(total: 10), capturedAt: nil, lastUpdated: now)?.capturedAt,
                     "an unknown capture time is not fabricated")
        XCTAssertNil(content(info(total: 10), capturedAt: now.addingTimeInterval(-week), lastUpdated: nil)?.capturedAt)
    }

    func testContentIsEitherAbsentOrCarriesSomething() {
        for sample in [info(), info(total: 1), info(expire: Int64(now.timeIntervalSince1970) + 86_400),
                       info(total: 1, expire: Int64(now.timeIntervalSince1970) + 86_400)]
        {
            let value = content(sample)
            XCTAssertTrue(value == nil || value?.isEmpty == false,
                          "the view relies on an empty content never being produced")
        }
    }
}
