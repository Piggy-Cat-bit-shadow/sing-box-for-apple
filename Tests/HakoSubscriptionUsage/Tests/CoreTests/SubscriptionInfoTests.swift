import Core
import XCTest

/// The parser and the pure usage arithmetic, against the upstream Hako semantics this round
/// migrates. Cases 1-5 and 13-15 of the migration brief.
final class SubscriptionInfoTests: XCTestCase {
    // MARK: - CASE 1: a standard header parses

    func testStandardHeaderParses() {
        let info = SubscriptionInfo.parse(header: "upload=100; download=200; total=1000; expire=2000000000")
        XCTAssertEqual(info, SubscriptionInfo(upload: 100, download: 200, total: 1000, expire: 2000000000))
    }

    // MARK: - CASE 2: order does not matter, whitespace is allowed

    func testDifferentOrderAndWhitespaceParses() {
        let info = SubscriptionInfo.parse(
            header: "  total = 107374182400 ;expire=1791552000;  upload=123;download=456  "
        )
        XCTAssertEqual(
            info,
            SubscriptionInfo(upload: 123, download: 456, total: 107374182400, expire: 1791552000)
        )
    }

    func testUnknownKeysAreIgnored() {
        let info = SubscriptionInfo.parse(
            header: "upload=1; download=2; total=3; expire=4; bar=abc=def; node=elsewhere"
        )
        XCTAssertEqual(info, SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4))
    }

    // MARK: - CASE 3: a header without expire still parses

    func testHeaderWithoutExpireDefaultsToZero() {
        let info = SubscriptionInfo.parse(header: "upload=1; download=2; total=3")
        XCTAssertEqual(info, SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 0))
    }

    func testHeaderWithoutTotalDefaultsToZeroSoTheFractionIsUnknown() {
        let info = SubscriptionInfo.parse(header: "upload=1; download=2")
        XCTAssertEqual(info?.total, 0)
        XCTAssertNil(info?.usageFraction)
        XCTAssertNil(info?.remainingBytes)
    }

    // MARK: - CASE 4 / CASE 5: nothing and nonsense do not crash

    func testAbsentHeaderIsNil() {
        XCTAssertNil(SubscriptionInfo.parse(header: ""))
        XCTAssertNil(SubscriptionInfo.parse(header: "   "))
    }

    func testMalformedHeaderDoesNotCrash() {
        for header in [
            "nonsense",
            ";;;;",
            "upload",
            "upload=",
            "upload=abc",
            "=5",
            "upload=notanumber; download=alsobad; total=; expire=--1",
            "upload=1; download=",
            String(repeating: "x=1;", count: 500),
        ] {
            XCTAssertNoThrow(SubscriptionInfo.parse(header: header), "crashed on \(header)")
        }
    }

    func testMalformedValuesFallBackToZero() {
        let info = SubscriptionInfo.parse(header: "upload=abc; download=200; total=1000; expire=2000000000")
        XCTAssertEqual(info?.upload, 0)
        XCTAssertEqual(info?.download, 200)
    }

    // MARK: - CASE 13: overflowing used bytes clamp instead of trapping

    func testUploadPlusDownloadOverflowClamps() {
        let info = SubscriptionInfo(upload: .max, download: .max, total: .max, expire: 0)
        XCTAssertEqual(info.usedBytes, Int64.max)
        XCTAssertEqual(info.usageFraction, 1.0)
        XCTAssertEqual(info.remainingBytes, 0)
    }

    func testUsedBytesIsUploadPlusDownload() {
        let info = SubscriptionInfo(upload: 100, download: 200, total: 1000, expire: 0)
        XCTAssertEqual(info.usedBytes, 300)
    }

    // MARK: - CASE 14: used greater than total clamps

    func testUsedBeyondTotalClampsFractionAndRemainder() {
        let info = SubscriptionInfo(upload: 800, download: 400, total: 1000, expire: 0)
        XCTAssertEqual(info.usedBytes, 1200)
        XCTAssertEqual(info.usageFraction, 1.0)
        XCTAssertEqual(info.remainingBytes, 0)
    }

    func testExactQuotaReadsAsFull() {
        let info = SubscriptionInfo(upload: 500, download: 500, total: 1000, expire: 0)
        XCTAssertEqual(info.usageFraction, 1.0)
        XCTAssertEqual(info.remainingBytes, 0)
    }

    func testOrdinaryFractionAndRemainder() {
        let info = SubscriptionInfo(upload: 100, download: 150, total: 1000, expire: 0)
        XCTAssertEqual(info.usageFraction, 0.25)
        XCTAssertEqual(info.remainingBytes, 750)
    }

    // MARK: - CASE 15: no quota reported

    func testZeroTotalMeansUnknownNotZeroPercent() {
        let info = SubscriptionInfo(upload: 100, download: 200, total: 0, expire: 0)
        XCTAssertEqual(info.usedBytes, 300)
        XCTAssertNil(info.usageFraction)
        XCTAssertNil(info.remainingBytes)
    }

    func testNegativeTotalIsTreatedAsUnknown() {
        let info = SubscriptionInfo(upload: 1, download: 1, total: -1, expire: 0)
        XCTAssertNil(info.usageFraction)
        XCTAssertNil(info.remainingBytes)
    }

    // MARK: - Expire stays the raw Unix seconds the panel sent

    func testExpireIsStoredAsRawUnixSeconds() {
        let info = SubscriptionInfo(upload: 0, download: 0, total: 0, expire: 1791552000)
        XCTAssertEqual(info.expire, 1791552000)
    }
}
