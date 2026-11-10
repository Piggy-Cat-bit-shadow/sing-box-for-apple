import XCTest

@testable import Contract

/// The command-target rules: which daemon a local profile may be shown to.
final class CommandScopeTests: XCTestCase {
    func testASessionWithNoRemoteIsTheLocalTunnel() {
        let token = CommandTargetPolicy.token(remoteLabel: nil)
        XCTAssertEqual(token, .localTunnel)
        XCTAssertTrue(token.isLocalTunnel)
    }

    func testASessionWithARemoteCarriesItsLabel() {
        let token = CommandTargetPolicy.token(remoteLabel: "panel")
        XCTAssertEqual(token.kind, .remoteSession)
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
        let remote = CommandTargetPolicy.token(remoteLabel: "panel")
        guard case let .refused(token, reason) = CommandTargetPolicy.localProfileDecision(remote) else {
            return XCTFail("a remote session must refuse a local profile operation")
        }
        XCTAssertEqual(token, remote)
        XCTAssertTrue(reason.contains("panel"), "the reason names the target: \(reason)")
        XCTAssertTrue(reason.contains("this device"), "the reason says what the page can still describe: \(reason)")
    }

    /// Attribution is structural, not re-checked: the client is resolved from the token once per
    /// read, and `CommandTarget.setRemoteServer` drops the session's shared channel on every
    /// selection change, so a client a reader holds cannot start talking to another daemon. There is
    /// therefore no "generation" to compare - and no unused policy function pretending there is.
    func testTheTokenNamesTheTargetAndNothingElse() {
        XCTAssertNil(CommandTargetToken.localTunnel.remoteLabel)
        XCTAssertEqual(CommandTargetPolicy.token(remoteLabel: "a").remoteLabel, "a")
        XCTAssertEqual(CommandTargetPolicy.token(remoteLabel: "").kind, .remoteSession)
    }
}
