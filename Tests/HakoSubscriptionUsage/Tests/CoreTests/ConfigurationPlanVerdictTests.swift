import Foundation
import XCTest

@testable import Core

/// The preview verdict, from the kernel's own `PreviewServiceChange` output.
///
/// The fixtures are captured (daemon/service_change.go, throwaway in-package capture), not written
/// by hand: `started` means a Box is running now, and a hand-written fixture is how the inverted
/// reading - "started means it will start one" - was first written down as if it were correct.
final class ConfigurationPlanVerdictTests: XCTestCase {
    private func plan(_ json: String) throws -> ConfigurationPlan {
        let document = try classifyConfigurationDocument(json, as: ConfigurationPlan.self)
        guard case let .document(plan) = document else {
            throw XCTSkip("expected a plan document")
        }
        return plan
    }

    // started=false: no Box is running, so applying starts one.
    private let firstStart = """
        {"started":false,"targetRevision":"a28eeff6b2d5077a","unchanged":false,"liveOnly":false,
         "restartRequired":false,"changedDocument":false,
         "mode":{"domain":"mode","supported":false,"restartRequired":false},
         "dns":{"domain":"dns","supported":false,"restartRequired":false},
         "rule":{"domain":"rule","supported":false,"restartRequired":false},
         "provider":{"domain":"provider","supported":true,
                     "liveRefreshReason":"the document changed; provider declarations are rebuilt with it",
                     "targetRevision":"a28eeff6b2d5077a"}}
        """

    // started=true, live only: the running Box absorbs the mode change.
    private let liveOnly = """
        {"started":true,"currentRevision":"5cdda4a0c6c03666","targetRevision":"8082aed150b32c3e",
         "unchanged":false,"liveOnly":true,"restartRequired":false,"changedDocument":true,
         "mode":{"domain":"mode","supported":true,"restartRequired":false,
                 "changes":[{"kind":"mode","from":"Global","to":"Direct"}],
                 "currentRevision":"5cdda4a0c6c03666","targetRevision":"8082aed150b32c3e"},
         "dns":{"domain":"dns","supported":true,"restartRequired":false,
                "currentRevision":"5cdda4a0c6c03666","targetRevision":"8082aed150b32c3e"},
         "rule":{"domain":"rule","supported":true,"restartRequired":false,
                 "currentRevision":"5cdda4a0c6c03666","targetRevision":"8082aed150b32c3e"},
         "provider":{"domain":"provider","supported":true,
                     "liveRefreshReason":"the document changed; provider declarations are rebuilt with it",
                     "currentRevision":"5cdda4a0c6c03666","targetRevision":"8082aed150b32c3e"}}
        """

    // started=true, restart required: the log level has no live owner.
    private let restart = """
        {"started":true,"currentRevision":"a28eeff6b2d5077a","targetRevision":"e8d96760b5608ebc",
         "unchanged":false,"liveOnly":false,"restartRequired":true,"changedDocument":true,
         "changedSections":["log"],
         "mode":{"domain":"mode","supported":false,
                 "unsupportedReason":"the running configuration has no clash_api owner",
                 "restartRequired":false,"currentRevision":"a28eeff6b2d5077a",
                 "targetRevision":"e8d96760b5608ebc"},
         "dns":{"domain":"dns","supported":true,"restartRequired":false,
                "currentRevision":"a28eeff6b2d5077a","targetRevision":"e8d96760b5608ebc"},
         "rule":{"domain":"rule","supported":true,"restartRequired":false,
                 "currentRevision":"a28eeff6b2d5077a","targetRevision":"e8d96760b5608ebc"},
         "provider":{"domain":"provider","supported":true,
                     "liveRefreshReason":"the document changed; provider declarations are rebuilt with it",
                     "currentRevision":"a28eeff6b2d5077a","targetRevision":"e8d96760b5608ebc"}}
        """

    // started=true, unchanged: the running document is the one previewed.
    private let unchanged = """
        {"started":true,"currentRevision":"a28eeff6b2d5077a","targetRevision":"a28eeff6b2d5077a",
         "unchanged":true,"liveOnly":false,"restartRequired":false,"changedDocument":false,
         "mode":{"domain":"mode","supported":false,
                 "unsupportedReason":"the running configuration has no clash_api owner",
                 "restartRequired":false,"currentRevision":"a28eeff6b2d5077a",
                 "targetRevision":"a28eeff6b2d5077a"},
         "dns":{"domain":"dns","supported":true,"restartRequired":false,
                "currentRevision":"a28eeff6b2d5077a","targetRevision":"a28eeff6b2d5077a"},
         "rule":{"domain":"rule","supported":true,"restartRequired":false,
                 "currentRevision":"a28eeff6b2d5077a","targetRevision":"a28eeff6b2d5077a"},
         "provider":{"domain":"provider","supported":true,
                     "liveRefreshReason":"the document declares no remote provider",
                     "currentRevision":"a28eeff6b2d5077a","targetRevision":"a28eeff6b2d5077a"}}
        """

    func testFirstStartIsTheOnlyPlanWithoutARunningBox() throws {
        XCTAssertEqual(try plan(firstStart).verdict, .firstStart(targetRevision: "a28eeff6b2d5077a"))
    }

    func testALiveOnlyChangeAppliesToTheRunningBox() throws {
        XCTAssertEqual(
            try plan(liveOnly).verdict,
            .liveApply(currentRevision: "5cdda4a0c6c03666", targetRevision: "8082aed150b32c3e")
        )
    }

    func testARestartNamesTheSectionThatForcesIt() throws {
        let verdict = try plan(restart).verdict
        guard case let .restartRequired(current, target, reasons) = verdict else {
            return XCTFail("expected a restart verdict, got \(verdict)")
        }
        XCTAssertEqual(current, "a28eeff6b2d5077a")
        XCTAssertEqual(target, "e8d96760b5608ebc")
        XCTAssertEqual(reasons, ["log"])
    }

    func testAnUnchangedRunningDocumentIsNotAStart() throws {
        XCTAssertEqual(try plan(unchanged).verdict, .unchanged(targetRevision: "a28eeff6b2d5077a"))
    }

    func testAStalePlanIsRefusedBeforeAnythingElse() throws {
        // `stale` is report-only, so the fixture is the restart plan of a report that lost its base.
        let stale = restart.replacingOccurrences(
            of: "\"restartRequired\":true",
            with: "\"restartRequired\":true,\"stale\":true"
        )
        XCTAssertEqual(try plan(stale).verdict, .stale)
    }

    func testARevisionLabelIsShortenedAndAnAbsentOneIsEmpty() {
        XCTAssertEqual(configurationRevisionLabel("0123456789abcdef0123456789abcdef"), "0123456789ab")
        XCTAssertEqual(configurationRevisionLabel("rev-7"), "rev-7")
        XCTAssertEqual(configurationRevisionLabel(nil), "")
        XCTAssertEqual(configurationRevisionLabel(""), "")
    }

    func testRestartReasonsPreferNamedSectionsAndFallBackToTheDocument() throws {
        let fallback = """
            {"started":true,"unchanged":false,"liveOnly":false,"restartRequired":true,
             "changedDocument":true}
            """
        guard case let .restartRequired(_, _, reasons) = try plan(fallback).verdict else {
            return XCTFail("expected a restart verdict")
        }
        XCTAssertEqual(reasons, ["the document differs outside the live domains"])
    }
}
