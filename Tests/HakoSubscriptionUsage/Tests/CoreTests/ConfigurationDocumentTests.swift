import Foundation
import XCTest

@testable import Core

/// The daemon's configuration documents, decoded from what the kernel actually marshals.
///
/// `PreviewServiceChange`, `GetLastServiceChange` and `GetLastConfigRecovery` answer with
/// `encoding/json` output over Go structs whose tags are camelCase (`targetRevision`,
/// `restartRequired`, `pendingTags`), and every omitted value is simply absent. A decoder that
/// required the optional fields would fail every plan, and one that treated the JSON literal `null`
/// as an empty document would report "nothing happened" for a kernel that cannot answer at all.
final class ConfigurationDocumentTests: XCTestCase {
    func testDecodesAPlanAndKeepsFieldsThisClientDoesNotKnow() throws {
        let document = try classifyConfigurationDocument(
            """
            {"started":false,"unchanged":false,"liveOnly":true,"restartRequired":false,
             "changedDocument":false,"currentRevision":"aaaaaaaaaaaa",
             "targetRevision":"bbbbbbbbbbbb","futureDomain":{"status":"published"}}
            """,
            as: ConfigurationPlan.self
        )
        guard case let .document(plan) = document else {
            return XCTFail("expected a document, got \(document)")
        }
        XCTAssertTrue(plan.liveOnly)
        XCTAssertEqual(plan.targetRevision, "bbbbbbbbbbbb")
        XCTAssertFalse(plan.restartRequired)
    }

    func testKeepsNoRecordSeparateFromAnOlderKernel() throws {
        let absent = try classifyConfigurationDocument("null", as: ConfigurationReport.self)
        if case .absent = absent {
        } else {
            XCTFail("null must classify as absent")
        }
        // The libbox bridge answers an older kernel with the empty string.
        let unsupported = try classifyConfigurationDocument("", as: ConfigurationReport.self)
        if case .unsupported = unsupported {
        } else {
            XCTFail("the empty string must classify as unsupported")
        }
    }

    func testRefusesADocumentThatIsNotAnObject() {
        XCTAssertThrowsError(try classifyConfigurationDocument("[]", as: ConfigurationPlan.self)) {
            XCTAssertEqual($0 as? ConfigurationDocumentError, .notAnObject)
        }
        XCTAssertThrowsError(try classifyConfigurationDocument("\"text\"", as: ConfigurationPlan.self))
    }

    func testDecodesAReportWithARetainedDocumentAndPerProviderResults() throws {
        let document = try classifyConfigurationDocument(
            """
            {"plan":{"started":false,"unchanged":false,"liveOnly":true,"restartRequired":false,
                     "changedDocument":false,"targetRevision":"bbbb"},
             "status":"failed","restartRequired":false,"retained":true,
             "activeRevision":"aaaa","persistence":"degraded",
             "persistenceWarning":"cannot keep the previous document",
             "time":"2026-11-10T00:00:00Z",
             "provider":{"domain":"provider","status":"partial","restartRequired":true,
                         "results":[{"tag":"remote-a","status":"published",
                                     "pendingTags":["node-1","node-2"],"restartRequired":true,
                                     "reason":"group refused"},
                                    {"tag":"local-b","status":"skipped"}]}}
            """,
            as: ConfigurationReport.self
        )
        guard case let .document(report) = document else {
            return XCTFail("expected a document, got \(document)")
        }
        XCTAssertTrue(report.retained)
        XCTAssertEqual(report.persistence, "degraded")
        XCTAssertEqual(report.provider?.results?.count, 2)
        XCTAssertEqual(report.provider?.results?.first?.pendingTags, ["node-1", "node-2"])
        XCTAssertEqual(report.provider?.results?.last?.status, "skipped")
    }

    func testDecodesARecovery() throws {
        let document = try classifyConfigurationDocument(
            """
            {"time":"2026-11-10T00:00:00Z","failedRevision":"ffff","activeRevision":"cccc",
             "error":"duplicate inbound tag"}
            """,
            as: ConfigurationRecovery.self
        )
        guard case let .document(recovery) = document else {
            return XCTFail("expected a document, got \(document)")
        }
        XCTAssertEqual(recovery.failedRevision, "ffff")
        XCTAssertEqual(recovery.error, "duplicate inbound tag")
    }
}
