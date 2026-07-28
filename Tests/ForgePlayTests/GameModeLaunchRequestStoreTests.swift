// SPDX-FileCopyrightText: 2026 Facta-Leopard
// SPDX-License-Identifier: GPL-3.0-only
//
// ForgePlay Game Mode
// Original source: https://github.com/Facta-Leopard/ForgePlay

import Darwin
import XCTest
@testable import ForgePlay

final class GameModeLaunchRequestStoreTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayGameModeRequestStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    override func tearDown() {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        super.tearDown()
    }

    func testPublishAndClaimOldestUseBoundedAtomicArtifacts() throws {
        let store = GameModeLaunchRequestStore(rootURL: rootURL)
        let older = try makeRequest(createdAt: baseDate)
        let newer = try makeRequest(createdAt: baseDate.addingTimeInterval(1))

        try store.publish(newer)
        try store.publish(older)

        XCTAssertEqual(
            try store.state(for: older.runIdentifier, nonce: older.requestNonce),
            .pending
        )
        let claim = try XCTUnwrap(store.claimOldest(at: baseDate.addingTimeInterval(2)))
        XCTAssertEqual(claim.request, older)
        XCTAssertEqual(
            try store.state(for: older.runIdentifier, nonce: older.requestNonce),
            .claimed
        )
        XCTAssertEqual(
            try store.state(for: newer.runIdentifier, nonce: newer.requestNonce),
            .pending
        )

        let claimedURL = rootURL
            .appending(path: "claimed", directoryHint: .isDirectory)
            .appending(path: "\(older.runIdentifier.rawValue).request.json")
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: claimedURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o077, 0)
        XCTAssertFalse(try allArtifactNames().contains { $0.hasSuffix(".tmp") })
    }

    func testConcurrentClaimReturnsARequestToExactlyOneStoreInstance() throws {
        let publisher = GameModeLaunchRequestStore(rootURL: rootURL)
        let request = try makeRequest(createdAt: baseDate)
        try publisher.publish(request)
        let results = LockedClaimResults()
        let concurrentRootURL = try XCTUnwrap(rootURL)
        let claimDate = baseDate.addingTimeInterval(1)

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let store = GameModeLaunchRequestStore(rootURL: concurrentRootURL)
            do {
                let claim = try store.claimOldest(at: claimDate)
                results.append(claim: claim)
            } catch {
                results.append(error: error)
            }
        }

        XCTAssertTrue(results.errors.isEmpty, "Unexpected claim errors: \(results.errors)")
        XCTAssertEqual(results.claims.compactMap { $0?.request }.count, 1)
        XCTAssertEqual(results.claims.compactMap { $0?.request }.first, request)
        XCTAssertEqual(
            try publisher.state(for: request.runIdentifier, nonce: request.requestNonce),
            .claimed
        )
    }

    func testAcknowledgementBindsNonceAndDarwinProcessIdentity() throws {
        let store = GameModeLaunchRequestStore(rootURL: rootURL)
        let request = try makeRequest(createdAt: baseDate)
        try store.publish(request)
        let claim = try XCTUnwrap(store.claimOldest(at: baseDate.addingTimeInterval(1)))
        let hostProcess = try GameModeDarwinProcessIdentity(
            processIdentifier: getpid(),
            startTimeUnixMilliseconds: 1_800_000_000_000
        )

        let acknowledgement = try store.acknowledgeCurrentHostProcess(
            claim,
            hostStartTimeUnixMilliseconds: hostProcess.startTimeUnixMilliseconds,
            at: baseDate.addingTimeInterval(2)
        )

        XCTAssertEqual(acknowledgement.hostDarwinProcess, hostProcess)
        XCTAssertEqual(
            try store.acknowledgeCurrentHostProcess(
                claim,
                hostStartTimeUnixMilliseconds: hostProcess.startTimeUnixMilliseconds,
                at: baseDate.addingTimeInterval(3)
            ),
            acknowledgement
        )
        XCTAssertEqual(
            try store.state(for: request.runIdentifier, nonce: request.requestNonce),
            .acknowledged
        )
        XCTAssertEqual(
            try store.acknowledgement(
                for: request.runIdentifier,
                nonce: request.requestNonce
            ),
            acknowledgement
        )

        XCTAssertThrowsError(
            try store.acknowledgement(
                for: request.runIdentifier,
                nonce: GameModeRequestNonce()
            )
        ) { error in
            XCTAssertEqual(
                error as? GameModeLaunchRequestStoreError,
                .nonceMismatch(request.runIdentifier)
            )
        }
    }

    func testCleanupRequiresNonceAndPreservesOtherRuns() throws {
        let store = GameModeLaunchRequestStore(rootURL: rootURL)
        let first = try makeRequest(createdAt: baseDate)
        let second = try makeRequest(createdAt: baseDate.addingTimeInterval(1))
        try store.publish(first)
        try store.publish(second)
        let claim = try XCTUnwrap(store.claimOldest(at: baseDate.addingTimeInterval(2)))
        _ = try store.acknowledge(
            claim,
            hostDarwinProcess: GameModeDarwinProcessIdentity(processIdentifier: getpid()),
            at: baseDate.addingTimeInterval(3)
        )

        XCTAssertThrowsError(
            try store.cleanup(
                runIdentifier: first.runIdentifier,
                nonce: GameModeRequestNonce()
            )
        )
        XCTAssertEqual(
            try store.state(for: first.runIdentifier, nonce: first.requestNonce),
            .acknowledged
        )

        XCTAssertTrue(
            try store.cleanup(
                runIdentifier: first.runIdentifier,
                nonce: first.requestNonce
            )
        )
        XCTAssertEqual(
            try store.state(for: first.runIdentifier, nonce: first.requestNonce),
            .absent
        )
        XCTAssertEqual(
            try store.state(for: second.runIdentifier, nonce: second.requestNonce),
            .pending
        )
    }

    func testCleanupExpiredRemovesOnlyExpiredRunArtifacts() throws {
        let store = GameModeLaunchRequestStore(rootURL: rootURL)
        let expired = try makeRequest(
            createdAt: baseDate,
            expiresAt: baseDate.addingTimeInterval(2)
        )
        let active = try makeRequest(
            createdAt: baseDate,
            expiresAt: baseDate.addingTimeInterval(200)
        )
        try store.publish(expired)
        try store.publish(active)

        let removed = try store.cleanupExpired(at: baseDate.addingTimeInterval(3))

        XCTAssertEqual(removed, [expired.runIdentifier])
        XCTAssertEqual(
            try store.state(for: expired.runIdentifier, nonce: expired.requestNonce),
            .absent
        )
        XCTAssertEqual(
            try store.state(for: active.runIdentifier, nonce: active.requestNonce),
            .pending
        )
    }

    func testStrictRequestSchemaRejectsArbitraryEnvironmentAndCredentialFields() throws {
        let store = GameModeLaunchRequestStore(rootURL: rootURL)
        let request = try makeRequest(createdAt: baseDate)
        try store.publish(request)
        let requestURL = pendingURL(for: request.runIdentifier)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: Any]
        )

        XCTAssertNil(object["environment"])
        XCTAssertNil(object["arguments"])
        XCTAssertNil(object["credential"])
        object["environment"] = ["UNBOUNDED_KEY": "value"]
        object["credential"] = "value"
        let altered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try altered.write(to: requestURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: requestURL.path
        )

        XCTAssertThrowsError(
            try store.claimOldest(at: baseDate.addingTimeInterval(1))
        ) { error in
            XCTAssertEqual(
                error as? GameModeLaunchRequestStoreError,
                .invalidDocument(requestURL)
            )
        }
    }

    func testRequestStoreRejectsOversizedDocumentBeforeDecoding() throws {
        let store = GameModeLaunchRequestStore(rootURL: rootURL)
        let request = try makeRequest(createdAt: baseDate)
        try store.publish(request)
        let requestURL = pendingURL(for: request.runIdentifier)
        let oversized = Data(
            repeating: 0x20,
            count: GameModeLaunchRequestStore.maximumDocumentBytes + 1
        )
        try oversized.write(to: requestURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: requestURL.path
        )

        XCTAssertThrowsError(
            try store.claimOldest(at: baseDate.addingTimeInterval(1))
        ) { error in
            guard case GameModeLaunchRequestStoreError.documentTooLarge(
                let url,
                let byteCount
            ) = error else {
                return XCTFail("Expected documentTooLarge, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL, requestURL.standardizedFileURL)
            XCTAssertEqual(
                byteCount,
                Int64(GameModeLaunchRequestStore.maximumDocumentBytes + 1)
            )
        }
    }

    func testInjectedRootRejectsSymbolicLink() throws {
        let external = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayGameModeRequestStoreExternal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: rootURL, withDestinationURL: external)
        let store = GameModeLaunchRequestStore(rootURL: rootURL)

        XCTAssertThrowsError(try store.publish(makeRequest(createdAt: baseDate))) { error in
            XCTAssertEqual(
                error as? GameModeLaunchRequestStoreError,
                .unsafeStorePath(self.rootURL)
            )
        }
    }

    private func makeRequest(
        createdAt: Date,
        expiresAt: Date? = nil
    ) throws -> GameModeLaunchRequest {
        try GameModeLaunchRequest(
            createdAt: createdAt,
            expiresAt: expiresAt ?? createdAt.addingTimeInterval(120),
            prefixIdentifier: "prefix-steam-shared",
            prefixGenerationIdentifier: GameModePrefixGenerationIdentifier(UUID()),
            runtimeBuildFingerprint: GameModeRuntimeBuildFingerprint(
                validating: String(repeating: "a", count: 64)
            ),
            target: .steamApplication(applicationIdentifier: 123_456)
        )
    }

    private func pendingURL(for runIdentifier: GameModeRunIdentifier) -> URL {
        rootURL
            .appending(path: "pending", directoryHint: .isDirectory)
            .appending(path: "\(runIdentifier.rawValue).request.json")
    }

    private func allArtifactNames() throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        )
        return enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
    }
}

final class GameModeEvidenceTests: XCTestCase {
    func testUserVerifiedEvidenceKeepsDarwinAndWindowsProcessNamespacesDistinct() throws {
        let runIdentifier = GameModeRunIdentifier()
        let nonce = GameModeRequestNonce()
        let host = try GameModeDarwinProcessIdentity(
            processIdentifier: 321,
            startTimeUnixMilliseconds: 1_800_000_000_000
        )
        let windowsGame = try GameModeWindowsProcessIdentity(processIdentifier: 321)
        let evidence = try GameModeEvidence(
            runIdentifier: runIdentifier,
            requestNonce: nonce,
            sequenceNumber: 3,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            assessment: .gameModeUserVerifiedActive,
            hostIdentityCheck: .verified,
            nativeFullscreenCheck: .verified,
            userVerification: .userVerifiedActive,
            hostDarwinProcess: host,
            windowOwnerDarwinProcess: host,
            gameWindowsProcess: windowsGame
        )

        let data = try GameModeEvidence.encodeJSON(evidence)
        let decoded = try GameModeEvidence.decodeJSON(data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(decoded, evidence)
        XCTAssertEqual(decoded.hostDarwinProcess?.processIdentifier, 321)
        XCTAssertEqual(decoded.gameWindowsProcess?.processIdentifier, 321)
        XCTAssertNotNil(object["host_darwin_process"])
        XCTAssertNotNil(object["game_windows_process"])
        XCTAssertNil(object["process_identifier"])
    }

    func testInconclusiveSystemPolicyRequiresVerifiedPrerequisites() throws {
        let host = try GameModeDarwinProcessIdentity(processIdentifier: 401)
        let evidence = try GameModeEvidence(
            runIdentifier: GameModeRunIdentifier(),
            requestNonce: GameModeRequestNonce(),
            sequenceNumber: 4,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            assessment: .inconclusiveSystemPolicy,
            hostIdentityCheck: .verified,
            nativeFullscreenCheck: .verified,
            userVerification: .inconclusive,
            hostDarwinProcess: host,
            windowOwnerDarwinProcess: host
        )

        XCTAssertEqual(evidence.userVerification, .inconclusive)
        XCTAssertEqual(evidence.assessment, .inconclusiveSystemPolicy)
        XCTAssertThrowsError(
            try GameModeEvidence(
                runIdentifier: GameModeRunIdentifier(),
                requestNonce: GameModeRequestNonce(),
                sequenceNumber: 1,
                recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
                assessment: .inconclusiveSystemPolicy,
                hostIdentityCheck: .notObserved,
                nativeFullscreenCheck: .notObserved,
                userVerification: .inconclusive
            )
        ) { error in
            XCTAssertEqual(
                error as? GameModeSchemaValidationError,
                .inconsistentEvidenceState
            )
        }
    }

    func testEvidenceDecoderRejectsUnknownFields() throws {
        let host = try GameModeDarwinProcessIdentity(processIdentifier: 501)
        let evidence = try GameModeEvidence(
            runIdentifier: GameModeRunIdentifier(),
            requestNonce: GameModeRequestNonce(),
            sequenceNumber: 1,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            assessment: .hostIdentityVerified,
            hostIdentityCheck: .verified,
            nativeFullscreenCheck: .notObserved,
            userVerification: .notRequested,
            hostDarwinProcess: host
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: GameModeEvidence.encodeJSON(evidence))
                as? [String: Any]
        )
        object["unbounded_context"] = ["key": "value"]

        XCTAssertThrowsError(
            try GameModeEvidence.decodeJSON(
                JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        )
    }
}

private final class LockedClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClaims: [GameModeLaunchClaim?] = []
    private var storedErrors: [String] = []

    var claims: [GameModeLaunchClaim?] {
        lock.withLock { storedClaims }
    }

    var errors: [String] {
        lock.withLock { storedErrors }
    }

    func append(claim: GameModeLaunchClaim?) {
        lock.withLock { storedClaims.append(claim) }
    }

    func append(error: Error) {
        lock.withLock { storedErrors.append(String(describing: error)) }
    }
}
