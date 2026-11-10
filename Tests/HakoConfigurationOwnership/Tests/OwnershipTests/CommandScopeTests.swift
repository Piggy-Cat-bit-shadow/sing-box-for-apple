import XCTest

@testable import Contract

/// The command-target rules: which daemon a local profile may be shown to.
final class CommandScopeTests: XCTestCase {
    func testASessionWithNoRemoteIsTheLocalTunnel() {
        let token = CommandTargetPolicy.token(remote: nil)
        XCTAssertEqual(token, .localTunnel)
        XCTAssertTrue(token.isLocalTunnel)
        XCTAssertEqual(token.generation, 0)
    }

    func testASessionWithARemoteCarriesItsGenerationAndLabel() {
        let token = CommandTargetPolicy.token(remote: (label: "panel", generation: 7))
        XCTAssertEqual(token.kind, .remoteSession)
        XCTAssertEqual(token.generation, 7)
        XCTAssertEqual(token.remoteLabel, "panel")
        XCTAssertFalse(token.isLocalTunnel)
    }

    func testALocalProfileIsPermittedOnTheLocalTunnel() {
        guard case let .permitted(token) = CommandTargetPolicy.localProfileDecision(.localTunnel) else {
            return XCTFail("the local tunnel must permit a local profile operation")
        }
        XCTAssertEqual(token, .localTunnel)
    }

    /// The defect: with remote control on, the preview read the stored profile and sent it to the
    /// remote daemon. The decision is taken before the read, so it must refuse here.
    func testALocalProfileIsRefusedOnARemoteSession() {
        let remote = CommandTargetPolicy.token(remote: (label: "panel", generation: 3))
        guard case let .refused(token, reason) = CommandTargetPolicy.localProfileDecision(remote) else {
            return XCTFail("a remote session must refuse a local profile operation")
        }
        XCTAssertEqual(token, remote)
        XCTAssertTrue(reason.contains("panel"), "the reason names the target: \(reason)")
        XCTAssertTrue(reason.contains("this device"), "the reason says what the page can still describe: \(reason)")
    }

    func testAPinnedLocalOperationSurvivesTheSessionMovingToRemote() {
        let now = CommandTargetPolicy.token(remote: (label: "panel", generation: 9))
        XCTAssertTrue(
            CommandTargetPolicy.stillOwns(.localTunnel, now: now),
            "a local operation's target is this process's tunnel; the user's remote selection cannot move it"
        )
    }

    func testASessionOperationDoesNotSurviveAnotherSelection() {
        let captured = CommandTargetPolicy.token(remote: (label: "panel", generation: 1))
        let secondServer = CommandTargetPolicy.token(remote: (label: "other", generation: 2))
        let backToLocal = CommandTargetPolicy.token(remote: nil)
        XCTAssertFalse(CommandTargetPolicy.stillOwns(captured, now: secondServer))
        XCTAssertFalse(CommandTargetPolicy.stillOwns(captured, now: backToLocal))
        XCTAssertTrue(CommandTargetPolicy.stillOwns(captured, now: captured))
    }

    func testTheSameGenerationWithAnotherServerIsNotTheSameTarget() {
        let captured = CommandTargetPolicy.token(remote: (label: "panel", generation: 4))
        let impostor = CommandTargetPolicy.token(remote: (label: "other", generation: 4))
        XCTAssertFalse(CommandTargetPolicy.stillOwns(captured, now: impostor))
    }
}
