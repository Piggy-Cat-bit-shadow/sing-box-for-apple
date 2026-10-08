import Core
import XCTest

/// The refresh rules: what a response merges into the profile, when the metadata is committed, and
/// when the configuration is rewritten and the service reloaded.
///
/// Every case here runs the shipping `RemoteProfileRefresh.evaluate` and
/// `RemoteRefreshApplier.apply`, with only the fetch, the validator and the two side effects
/// substituted. Nothing restates the rule: if the order in the app changes, these fail.
final class RemoteRefreshPolicyTests: XCTestCase {
    private let yamlA = "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}]}"
    private let yamlB = "{\"outbounds\":[{\"type\":\"block\",\"tag\":\"block\"}]}"

    /// What the applier was asked to do, in the order it was asked.
    private final class Recorder {
        enum Step: Equatable {
            case metadata(SubscriptionInfo?)
            case persist
            case writeBody(String)
            case reload
        }

        private(set) var steps: [Step] = []

        func record(_ step: Step) {
            steps.append(step)
        }

        var didWriteBody: Bool {
            steps.contains { if case .writeBody = $0 { return true } else { return false } }
        }

        var didReload: Bool {
            steps.contains(.reload)
        }

        var didPersist: Bool {
            steps.contains(.persist)
        }

        var persistedMetadata: SubscriptionInfo? {
            for step in steps {
                if case let .metadata(info) = step { return info }
            }
            return nil
        }

        /// `persist` must come before any body write, and the metadata must be applied before
        /// `persist` so that what was committed is what was merged.
        var metadataOrderingIsSound: Bool {
            guard let metadataIndex = steps.firstIndex(where: { if case .metadata = $0 { return true } else { return false } }),
                  let persistIndex = steps.firstIndex(of: .persist) else { return false }
            guard let writeIndex = steps.firstIndex(where: { if case .writeBody = $0 { return true } else { return false } }) else {
                return metadataIndex < persistIndex
            }
            return metadataIndex < persistIndex && persistIndex < writeIndex
        }
    }

    private struct FetchFailure: Error {}

    /// Run one refresh and report what happened.
    private func run(
        remoteURL: String? = "https://panel.example.invalid/sub",
        previous: SubscriptionInfo?,
        currentBody: String?,
        response: RemoteProfileResponse,
        validatorFails: Bool = false
    ) async throws -> (outcome: RemoteRefreshOutcome, recorder: Recorder) {
        let recorder = Recorder()
        var applied = false
        let outcome = try await RemoteProfileRefresh.evaluate(
            remoteURL: remoteURL,
            previous: previous,
            currentBody: currentBody,
            fetch: { _ in response },
            validate: { _ in if validatorFails { throw FetchFailure() } }
        )
        try await RemoteRefreshApplier.apply(
            outcome,
            applyMetadata: { recorder.record(.metadata(outcome.subscriptionInfo)) },
            persist: { recorder.record(.persist); applied = true },
            writeBody: { recorder.record(.writeBody($0)) },
            reloadService: { recorder.record(.reload) }
        )
        XCTAssertTrue(applied)
        return (outcome, recorder)
    }

    private func response(_ body: String, userInfo: String?) -> RemoteProfileResponse {
        RemoteProfileResponse(content: body, subscriptionUserInfo: userInfo)
    }

    // MARK: - CASE 6: a response with no metadata keeps what is stored

    func testMissingHeaderKeepsStoredMetadata() async throws {
        let previous = SubscriptionInfo(upload: 100, download: 200, total: 1000, expire: 5)
        for header in [nil, "", "garbage", ";;;"] as [String?] {
            let (outcome, recorder) = try await run(
                previous: previous,
                currentBody: yamlA,
                response: response(yamlA, userInfo: header)
            )
            XCTAssertEqual(outcome.subscriptionInfo, previous, "header \(header ?? "nil") erased stored metadata")
            XCTAssertEqual(recorder.persistedMetadata, previous)
        }
    }

    // MARK: - CASE 7: a response with new values replaces them

    func testNewHeaderReplacesStoredMetadata() async throws {
        let previous = SubscriptionInfo(upload: 100, download: 200, total: 1000, expire: 5)
        let expected = SubscriptionInfo(upload: 700, download: 800, total: 2000, expire: 6)
        let (outcome, recorder) = try await run(
            previous: previous,
            currentBody: yamlA,
            response: response(yamlA, userInfo: "upload=700; download=800; total=2000; expire=6")
        )
        XCTAssertEqual(outcome.subscriptionInfo, expected)
        XCTAssertEqual(recorder.persistedMetadata, expected)
    }

    // MARK: - CASE 8 and 9: the body is identical, the traffic moved
    //
    // This is the round's first acceptance item. A panel's YAML commonly does not change for days
    // while its usage counter moves on every request.

    func testUnchangedBodyWithNewMetadataIsCommittedWithoutRewritingOrReloading() async throws {
        let previous = SubscriptionInfo(upload: 100 * 1024 * 1024 * 1024, download: 0, total: 400 * 1024 * 1024 * 1024, expire: 5)
        let expected = SubscriptionInfo(upload: 150 * 1024 * 1024 * 1024, download: 0, total: 400 * 1024 * 1024 * 1024, expire: 5)
        let (outcome, recorder) = try await run(
            previous: previous,
            currentBody: yamlA,
            response: response(yamlA, userInfo: "upload=161061273600; download=0; total=429496729600; expire=5")
        )
        XCTAssertEqual(outcome.subscriptionInfo, expected)
        XCTAssertFalse(outcome.writeBody)
        XCTAssertFalse(outcome.reloadService)
        // The metadata reached the store ...
        XCTAssertTrue(recorder.didPersist)
        XCTAssertEqual(recorder.persistedMetadata, expected)
        // ... and the configuration never reached the write or the reload.
        XCTAssertFalse(recorder.didWriteBody)
        XCTAssertFalse(recorder.didReload)
        XCTAssertTrue(recorder.metadataOrderingIsSound)
    }

    // MARK: - CASE 10: the body changed, so the existing behaviour stands

    func testChangedBodyWritesAndReloads() async throws {
        let previous = SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4)
        let (outcome, recorder) = try await run(
            previous: previous,
            currentBody: yamlA,
            response: response(yamlB, userInfo: nil)
        )
        XCTAssertTrue(outcome.writeBody)
        XCTAssertTrue(outcome.reloadService)
        XCTAssertEqual(outcome.bodyToWrite, yamlB)
        XCTAssertEqual(outcome.subscriptionInfo, previous)
        XCTAssertTrue(recorder.didWriteBody)
        XCTAssertTrue(recorder.didReload)
        XCTAssertTrue(recorder.metadataOrderingIsSound)
    }

    func testFirstFetchAgainstNoStoredBodyWrites() async throws {
        let (outcome, recorder) = try await run(
            previous: nil,
            currentBody: nil,
            response: response(yamlA, userInfo: "upload=1; download=2; total=3; expire=4")
        )
        XCTAssertTrue(outcome.writeBody)
        XCTAssertTrue(recorder.didReload)
        XCTAssertEqual(outcome.subscriptionInfo, SubscriptionInfo(upload: 1, download: 2, total: 3, expire: 4))
    }

    // MARK: - Rule 4: a failed refresh must not commit metadata

    func testValidationFailureCommitsNothing() async throws {
        let previous = SubscriptionInfo(upload: 100, download: 200, total: 1000, expire: 5)
        do {
            _ = try await run(
                previous: previous,
                currentBody: yamlA,
                response: response("not a sing-box configuration", userInfo: "upload=999; download=999; total=999; expire=9"),
                validatorFails: true
            )
            XCTFail("a failed validation must throw")
        } catch {
            XCTAssertNotNil(error as? RemoteRefreshValidationError, "expected a validation error, got \(error)")
        }
    }

    func testFetchFailurePropagates() async throws {
        do {
            _ = try await RemoteProfileRefresh.evaluate(
                remoteURL: "https://panel.example.invalid/sub",
                previous: SubscriptionInfo(upload: 1, download: 1, total: 1, expire: 1),
                currentBody: yamlA,
                fetch: { _ in throw FetchFailure() },
                validate: { _ in }
            )
            XCTFail("a failed fetch must throw")
        } catch {
            XCTAssertTrue(error is FetchFailure)
        }
    }

    func testMissingRemoteURLThrows() async throws {
        do {
            _ = try await RemoteProfileRefresh.evaluate(
                remoteURL: nil,
                previous: nil,
                currentBody: nil,
                fetch: { _ in XCTFail("must not fetch without a URL"); return self.response("", userInfo: nil) },
                validate: { _ in }
            )
            XCTFail("a profile without a URL must throw")
        } catch {
            XCTAssertNotNil(error as? RemoteProfileFetchError)
        }
    }
}
