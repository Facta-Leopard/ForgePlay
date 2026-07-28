// SPDX-FileCopyrightText: 2026 Facta-Leopard
// SPDX-License-Identifier: GPL-3.0-only
//
// ForgePlay Game Mode
// Original source: https://github.com/Facta-Leopard/ForgePlay

import Darwin
import Foundation

enum GameModeLaunchTarget: Hashable, Sendable {
    case hostCapabilityProbe
    case steamApplication(applicationIdentifier: UInt32)
}

extension GameModeLaunchTarget: Codable {
    private enum Kind: String, Codable {
        case hostCapabilityProbe
        case steamApplication
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case steamApplicationIdentifier = "steam_application_identifier"
    }

    init(from decoder: Decoder) throws {
        try GameModeJSONShape.requireOnlyKeys(
            CodingKeys.self,
            from: decoder,
            context: "launch_target"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hostCapabilityProbe:
            guard !container.contains(.steamApplicationIdentifier) else {
                throw GameModeSchemaValidationError.unexpectedFields(
                    "host_capability_probe_target"
                )
            }
            self = .hostCapabilityProbe
        case .steamApplication:
            let identifier = try container.decode(
                UInt32.self,
                forKey: .steamApplicationIdentifier
            )
            guard identifier > 0 else {
                throw GameModeSchemaValidationError.invalidIdentifier(
                    CodingKeys.steamApplicationIdentifier.rawValue
                )
            }
            self = .steamApplication(applicationIdentifier: identifier)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostCapabilityProbe:
            try container.encode(Kind.hostCapabilityProbe, forKey: .kind)
        case .steamApplication(let applicationIdentifier):
            guard applicationIdentifier > 0 else {
                throw GameModeSchemaValidationError.invalidIdentifier(
                    CodingKeys.steamApplicationIdentifier.rawValue
                )
            }
            try container.encode(Kind.steamApplication, forKey: .kind)
            try container.encode(
                applicationIdentifier,
                forKey: .steamApplicationIdentifier
            )
        }
    }
}

struct GameModeLaunchRequest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumLifetime: TimeInterval = 10 * 60

    let schemaVersion: Int
    let runIdentifier: GameModeRunIdentifier
    let requestNonce: GameModeRequestNonce
    let createdAt: Date
    let expiresAt: Date
    let prefixIdentifier: String
    let prefixGenerationIdentifier: GameModePrefixGenerationIdentifier
    let runtimeBuildFingerprint: GameModeRuntimeBuildFingerprint
    let target: GameModeLaunchTarget

    // Deliberately absent from this contract: credentials, arbitrary
    // environment, command arguments, working directories, and executable
    // paths. The coordinator and host resolve and revalidate those locally.

    init(
        runIdentifier: GameModeRunIdentifier = GameModeRunIdentifier(),
        requestNonce: GameModeRequestNonce = GameModeRequestNonce(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        prefixIdentifier: String,
        prefixGenerationIdentifier: GameModePrefixGenerationIdentifier,
        runtimeBuildFingerprint: GameModeRuntimeBuildFingerprint,
        target: GameModeLaunchTarget
    ) throws {
        let normalizedCreatedAt = try GameModeTimestampContract.normalized(
            createdAt,
            field: "created_at_unix_milliseconds"
        )
        let normalizedExpiresAt = try GameModeTimestampContract.normalized(
            expiresAt ?? normalizedCreatedAt.addingTimeInterval(2 * 60),
            field: "expires_at_unix_milliseconds"
        )
        guard Self.isValidPrefixIdentifier(prefixIdentifier) else {
            throw GameModeSchemaValidationError.invalidIdentifier("prefix_identifier")
        }
        if case .steamApplication(let applicationIdentifier) = target,
           applicationIdentifier == 0 {
            throw GameModeSchemaValidationError.invalidIdentifier(
                "steam_application_identifier"
            )
        }
        let lifetime = normalizedExpiresAt.timeIntervalSince(normalizedCreatedAt)
        guard lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw GameModeSchemaValidationError.invalidRequestLifetime
        }

        schemaVersion = Self.currentSchemaVersion
        self.runIdentifier = runIdentifier
        self.requestNonce = requestNonce
        self.createdAt = normalizedCreatedAt
        self.expiresAt = normalizedExpiresAt
        self.prefixIdentifier = prefixIdentifier
        self.prefixGenerationIdentifier = prefixGenerationIdentifier
        self.runtimeBuildFingerprint = runtimeBuildFingerprint
        self.target = target
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case runIdentifier = "run_identifier"
        case requestNonce = "request_nonce"
        case createdAtUnixMilliseconds = "created_at_unix_milliseconds"
        case expiresAtUnixMilliseconds = "expires_at_unix_milliseconds"
        case prefixIdentifier = "prefix_identifier"
        case prefixGenerationIdentifier = "prefix_generation_identifier"
        case runtimeBuildFingerprint = "runtime_build_fingerprint"
        case target
    }

    init(from decoder: Decoder) throws {
        try GameModeJSONShape.requireOnlyKeys(
            CodingKeys.self,
            from: decoder,
            context: "launch_request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GameModeSchemaValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try self.init(
            runIdentifier: container.decode(GameModeRunIdentifier.self, forKey: .runIdentifier),
            requestNonce: container.decode(GameModeRequestNonce.self, forKey: .requestNonce),
            createdAt: GameModeTimestampContract.date(
                fromUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .createdAtUnixMilliseconds
                ),
                field: CodingKeys.createdAtUnixMilliseconds.rawValue
            ),
            expiresAt: GameModeTimestampContract.date(
                fromUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .expiresAtUnixMilliseconds
                ),
                field: CodingKeys.expiresAtUnixMilliseconds.rawValue
            ),
            prefixIdentifier: container.decode(String.self, forKey: .prefixIdentifier),
            prefixGenerationIdentifier: container.decode(
                GameModePrefixGenerationIdentifier.self,
                forKey: .prefixGenerationIdentifier
            ),
            runtimeBuildFingerprint: container.decode(
                GameModeRuntimeBuildFingerprint.self,
                forKey: .runtimeBuildFingerprint
            ),
            target: container.decode(GameModeLaunchTarget.self, forKey: .target)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runIdentifier, forKey: .runIdentifier)
        try container.encode(requestNonce, forKey: .requestNonce)
        try container.encode(
            GameModeTimestampContract.unixMilliseconds(
                createdAt,
                field: CodingKeys.createdAtUnixMilliseconds.rawValue
            ),
            forKey: .createdAtUnixMilliseconds
        )
        try container.encode(
            GameModeTimestampContract.unixMilliseconds(
                expiresAt,
                field: CodingKeys.expiresAtUnixMilliseconds.rawValue
            ),
            forKey: .expiresAtUnixMilliseconds
        )
        try container.encode(prefixIdentifier, forKey: .prefixIdentifier)
        try container.encode(prefixGenerationIdentifier, forKey: .prefixGenerationIdentifier)
        try container.encode(runtimeBuildFingerprint, forKey: .runtimeBuildFingerprint)
        try container.encode(target, forKey: .target)
    }

    private static func isValidPrefixIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...96).contains(bytes.count),
              bytes.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                      (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ||
                      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                      byte == UInt8(ascii: ".") ||
                      byte == UInt8(ascii: "_") ||
                      byte == UInt8(ascii: "-")
              }),
              let first = bytes.first else {
            return false
        }
        return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) ||
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) ||
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
    }
}

struct GameModeLaunchClaim: Hashable, Sendable {
    let request: GameModeLaunchRequest
    let claimedAt: Date
}

struct GameModeLaunchAcknowledgement: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runIdentifier: GameModeRunIdentifier
    let requestNonce: GameModeRequestNonce
    let acknowledgedAt: Date
    let requestExpiresAt: Date
    let hostDarwinProcess: GameModeDarwinProcessIdentity

    init(
        runIdentifier: GameModeRunIdentifier,
        requestNonce: GameModeRequestNonce,
        acknowledgedAt: Date,
        requestExpiresAt: Date,
        hostDarwinProcess: GameModeDarwinProcessIdentity
    ) throws {
        let normalizedAcknowledgedAt = try GameModeTimestampContract.normalized(
            acknowledgedAt,
            field: "acknowledged_at_unix_milliseconds"
        )
        let normalizedRequestExpiresAt = try GameModeTimestampContract.normalized(
            requestExpiresAt,
            field: "request_expires_at_unix_milliseconds"
        )
        guard normalizedAcknowledgedAt < normalizedRequestExpiresAt else {
            throw GameModeSchemaValidationError.invalidAcknowledgementLifetime
        }
        schemaVersion = Self.currentSchemaVersion
        self.runIdentifier = runIdentifier
        self.requestNonce = requestNonce
        self.acknowledgedAt = normalizedAcknowledgedAt
        self.requestExpiresAt = normalizedRequestExpiresAt
        self.hostDarwinProcess = hostDarwinProcess
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case runIdentifier = "run_identifier"
        case requestNonce = "request_nonce"
        case acknowledgedAtUnixMilliseconds = "acknowledged_at_unix_milliseconds"
        case requestExpiresAtUnixMilliseconds = "request_expires_at_unix_milliseconds"
        case hostDarwinProcess = "host_darwin_process"
    }

    init(from decoder: Decoder) throws {
        try GameModeJSONShape.requireOnlyKeys(
            CodingKeys.self,
            from: decoder,
            context: "launch_acknowledgement"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GameModeSchemaValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try self.init(
            runIdentifier: container.decode(GameModeRunIdentifier.self, forKey: .runIdentifier),
            requestNonce: container.decode(GameModeRequestNonce.self, forKey: .requestNonce),
            acknowledgedAt: GameModeTimestampContract.date(
                fromUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .acknowledgedAtUnixMilliseconds
                ),
                field: CodingKeys.acknowledgedAtUnixMilliseconds.rawValue
            ),
            requestExpiresAt: GameModeTimestampContract.date(
                fromUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .requestExpiresAtUnixMilliseconds
                ),
                field: CodingKeys.requestExpiresAtUnixMilliseconds.rawValue
            ),
            hostDarwinProcess: container.decode(
                GameModeDarwinProcessIdentity.self,
                forKey: .hostDarwinProcess
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runIdentifier, forKey: .runIdentifier)
        try container.encode(requestNonce, forKey: .requestNonce)
        try container.encode(
            GameModeTimestampContract.unixMilliseconds(
                acknowledgedAt,
                field: CodingKeys.acknowledgedAtUnixMilliseconds.rawValue
            ),
            forKey: .acknowledgedAtUnixMilliseconds
        )
        try container.encode(
            GameModeTimestampContract.unixMilliseconds(
                requestExpiresAt,
                field: CodingKeys.requestExpiresAtUnixMilliseconds.rawValue
            ),
            forKey: .requestExpiresAtUnixMilliseconds
        )
        try container.encode(hostDarwinProcess, forKey: .hostDarwinProcess)
    }
}

enum GameModeLaunchRequestState: String, Hashable, Sendable {
    case absent
    case pending
    case claimed
    case acknowledged
}

enum GameModeLaunchRequestStoreError: LocalizedError, Equatable {
    case unsafeStorePath(URL)
    case storeIOFailed(URL, Int32)
    case documentTooLarge(URL, Int64)
    case invalidDocument(URL)
    case artifactAlreadyExists(URL)
    case requestNotClaimed(GameModeRunIdentifier)
    case nonceMismatch(GameModeRunIdentifier)
    case requestExpired(GameModeRunIdentifier)
    case inconsistentState(GameModeRunIdentifier)

    var errorDescription: String? {
        switch self {
        case .unsafeStorePath(let url):
            "Game Mode request store path is not a safe local item: \(url.path)"
        case .storeIOFailed(let url, let code):
            "Game Mode request store I/O failed at \(url.path): \(Self.message(for: code))"
        case .documentTooLarge(let url, let byteCount):
            "Game Mode request document is too large: \(url.path) (\(byteCount) bytes)"
        case .invalidDocument(let url):
            "Game Mode request document does not match the bounded schema: \(url.path)"
        case .artifactAlreadyExists(let url):
            "Game Mode request artifact already exists: \(url.path)"
        case .requestNotClaimed(let runIdentifier):
            "Game Mode request has not been claimed: \(runIdentifier.rawValue)"
        case .nonceMismatch(let runIdentifier):
            "Game Mode request nonce does not match: \(runIdentifier.rawValue)"
        case .requestExpired(let runIdentifier):
            "Game Mode request has expired: \(runIdentifier.rawValue)"
        case .inconsistentState(let runIdentifier):
            "Game Mode request artifacts are inconsistent: \(runIdentifier.rawValue)"
        }
    }

    private static func message(for errorCode: Int32) -> String {
        String(cString: strerror(errorCode))
    }
}

/// Cross-process request queue rooted at a caller-injected, dedicated app-group
/// directory. Every state transition is serialized by `flock` and published by
/// an exclusive same-directory rename, so readers never observe partial JSON.
final class GameModeLaunchRequestStore: @unchecked Sendable {
    static let maximumDocumentBytes = 16 * 1_024
    static let maximumClockSkew: TimeInterval = 5

    let rootURL: URL

    private let fileManager: FileManager
    private let pendingDirectoryName = "pending"
    private let claimedDirectoryName = "claimed"
    private let acknowledgementDirectoryName = "acknowledgements"
    private let lockFileName = ".game-mode-launch-request.lock"
    private let requestFileSuffix = ".request.json"
    private let acknowledgementFileSuffix = ".acknowledgement.json"

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Atomically publishes a new request. Existing artifacts for the run ID are
    /// never overwritten.
    func publish(_ request: GameModeLaunchRequest) throws {
        let data = try encodeDocument(request, destination: pendingURL(for: request.runIdentifier))
        try withExclusiveStoreLock {
            let artifacts = artifactURLs(for: request.runIdentifier)
            guard try !artifactExists(artifacts.pending),
                  try !artifactExists(artifacts.claimed),
                  try !artifactExists(artifacts.acknowledgement) else {
                throw GameModeLaunchRequestStoreError.inconsistentState(request.runIdentifier)
            }
            try writeAtomicallyExclusive(data, to: artifacts.pending)
        }
    }

    /// Claims the oldest non-expired request. Concurrent store instances can
    /// return this request from at most one call.
    func claimOldest(at date: Date = Date()) throws -> GameModeLaunchClaim? {
        let claimDate = try GameModeTimestampContract.normalized(
            date,
            field: "claimed_at_unix_milliseconds"
        )
        return try withExclusiveStoreLock {
            _ = try cleanupExpiredLocked(at: claimDate)
            let candidates = try requestDocuments(in: pendingDirectoryURL)
                .filter {
                    $0.request.createdAt <= claimDate.addingTimeInterval(Self.maximumClockSkew)
                }
                .sorted { first, second in
                    if first.request.createdAt == second.request.createdAt {
                        return first.request.runIdentifier.rawValue
                            < second.request.runIdentifier.rawValue
                    }
                    return first.request.createdAt < second.request.createdAt
                }

            for candidate in candidates {
                let destination = claimedURL(for: candidate.request.runIdentifier)
                if try artifactExists(destination) ||
                    artifactExists(acknowledgementURL(for: candidate.request.runIdentifier)) {
                    throw GameModeLaunchRequestStoreError.inconsistentState(
                        candidate.request.runIdentifier
                    )
                }
                try renameExclusive(candidate.url, to: destination)
                return GameModeLaunchClaim(request: candidate.request, claimedAt: claimDate)
            }
            return nil
        }
    }

    /// Records the claiming host's Darwin identity before the Windows process is
    /// started. Windows PID observations belong in `GameModeEvidence`.
    func acknowledgeCurrentHostProcess(
        _ claim: GameModeLaunchClaim,
        hostStartTimeUnixMilliseconds: Int64? = nil,
        at date: Date = Date()
    ) throws -> GameModeLaunchAcknowledgement {
        try acknowledge(
            claim,
            hostDarwinProcess: GameModeDarwinProcessIdentity(
                processIdentifier: getpid(),
                startTimeUnixMilliseconds: hostStartTimeUnixMilliseconds
            ),
            at: date
        )
    }

    /// Lower-level acknowledgement entry point for a caller that has already
    /// verified the host process identity independently.
    func acknowledge(
        _ claim: GameModeLaunchClaim,
        hostDarwinProcess: GameModeDarwinProcessIdentity,
        at date: Date = Date()
    ) throws -> GameModeLaunchAcknowledgement {
        let acknowledgementDate = try GameModeTimestampContract.normalized(
            date,
            field: "acknowledged_at_unix_milliseconds"
        )
        return try withExclusiveStoreLock {
            let requestURL = claimedURL(for: claim.request.runIdentifier)
            guard let storedRequest: GameModeLaunchRequest = try readDocumentIfPresent(
                from: requestURL
            ) else {
                throw GameModeLaunchRequestStoreError.requestNotClaimed(
                    claim.request.runIdentifier
                )
            }
            try validate(storedRequest, at: requestURL, expected: claim.request.runIdentifier)
            guard storedRequest.requestNonce == claim.request.requestNonce else {
                throw GameModeLaunchRequestStoreError.nonceMismatch(
                    claim.request.runIdentifier
                )
            }
            guard storedRequest == claim.request else {
                throw GameModeLaunchRequestStoreError.inconsistentState(
                    claim.request.runIdentifier
                )
            }
            guard acknowledgementDate >= storedRequest.createdAt,
                  storedRequest.expiresAt > acknowledgementDate else {
                throw GameModeLaunchRequestStoreError.requestExpired(
                    claim.request.runIdentifier
                )
            }

            let acknowledgement = try GameModeLaunchAcknowledgement(
                runIdentifier: storedRequest.runIdentifier,
                requestNonce: storedRequest.requestNonce,
                acknowledgedAt: acknowledgementDate,
                requestExpiresAt: storedRequest.expiresAt,
                hostDarwinProcess: hostDarwinProcess
            )
            let destination = acknowledgementURL(for: storedRequest.runIdentifier)
            if let existing: GameModeLaunchAcknowledgement = try readDocumentIfPresent(
                from: destination
            ) {
                try validate(
                    existing,
                    at: destination,
                    expected: storedRequest.runIdentifier
                )
                try validate(existing, matches: storedRequest, at: destination)
                guard existing.hostDarwinProcess == acknowledgement.hostDarwinProcess else {
                    throw GameModeLaunchRequestStoreError.artifactAlreadyExists(destination)
                }
                return existing
            }
            try writeAtomicallyExclusive(
                encodeDocument(acknowledgement, destination: destination),
                to: destination
            )
            return acknowledgement
        }
    }

    /// Polls an acknowledgement while binding the result to the original nonce.
    func acknowledgement(
        for runIdentifier: GameModeRunIdentifier,
        nonce: GameModeRequestNonce
    ) throws -> GameModeLaunchAcknowledgement? {
        try withExclusiveStoreLock {
            let url = acknowledgementURL(for: runIdentifier)
            guard let acknowledgement: GameModeLaunchAcknowledgement = try readDocumentIfPresent(
                from: url
            ) else {
                return nil
            }
            try validate(acknowledgement, at: url, expected: runIdentifier)
            guard acknowledgement.requestNonce == nonce else {
                throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
            }
            if let claimed: GameModeLaunchRequest = try readDocumentIfPresent(
                from: claimedURL(for: runIdentifier)
            ) {
                try validate(claimed, at: claimedURL(for: runIdentifier), expected: runIdentifier)
                try validate(acknowledgement, matches: claimed, at: url)
            }
            return acknowledgement
        }
    }

    func state(
        for runIdentifier: GameModeRunIdentifier,
        nonce: GameModeRequestNonce
    ) throws -> GameModeLaunchRequestState {
        try withExclusiveStoreLock {
            let artifacts = artifactURLs(for: runIdentifier)
            let pendingExists = try artifactExists(artifacts.pending)
            let claimedExists = try artifactExists(artifacts.claimed)
            let acknowledgementExists = try artifactExists(artifacts.acknowledgement)
            guard !(pendingExists && claimedExists),
                  !(pendingExists && acknowledgementExists) else {
                throw GameModeLaunchRequestStoreError.inconsistentState(runIdentifier)
            }

            if acknowledgementExists {
                let acknowledgement: GameModeLaunchAcknowledgement = try readDocument(
                    from: artifacts.acknowledgement
                )
                try validate(
                    acknowledgement,
                    at: artifacts.acknowledgement,
                    expected: runIdentifier
                )
                guard acknowledgement.requestNonce == nonce else {
                    throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
                }
                if claimedExists {
                    let request: GameModeLaunchRequest = try readDocument(from: artifacts.claimed)
                    try validate(request, at: artifacts.claimed, expected: runIdentifier)
                    try validate(
                        acknowledgement,
                        matches: request,
                        at: artifacts.acknowledgement
                    )
                }
                return .acknowledged
            }
            if claimedExists {
                let request: GameModeLaunchRequest = try readDocument(from: artifacts.claimed)
                try validate(request, at: artifacts.claimed, expected: runIdentifier)
                guard request.requestNonce == nonce else {
                    throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
                }
                return .claimed
            }
            if pendingExists {
                let request: GameModeLaunchRequest = try readDocument(from: artifacts.pending)
                try validate(request, at: artifacts.pending, expected: runIdentifier)
                guard request.requestNonce == nonce else {
                    throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
                }
                return .pending
            }
            return .absent
        }
    }

    /// Removes only the exact run artifacts after their nonce has been verified.
    @discardableResult
    func cleanup(
        runIdentifier: GameModeRunIdentifier,
        nonce: GameModeRequestNonce
    ) throws -> Bool {
        try withExclusiveStoreLock {
            let artifacts = artifactURLs(for: runIdentifier)
            let pending: GameModeLaunchRequest? = try readDocumentIfPresent(from: artifacts.pending)
            let claimed: GameModeLaunchRequest? = try readDocumentIfPresent(from: artifacts.claimed)
            let acknowledgement: GameModeLaunchAcknowledgement? = try readDocumentIfPresent(
                from: artifacts.acknowledgement
            )
            guard !(pending != nil && claimed != nil),
                  !(pending != nil && acknowledgement != nil) else {
                throw GameModeLaunchRequestStoreError.inconsistentState(runIdentifier)
            }
            guard pending != nil || claimed != nil || acknowledgement != nil else {
                return false
            }
            if let pending {
                try validate(pending, at: artifacts.pending, expected: runIdentifier)
                guard pending.requestNonce == nonce else {
                    throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
                }
            }
            if let claimed {
                try validate(claimed, at: artifacts.claimed, expected: runIdentifier)
                guard claimed.requestNonce == nonce else {
                    throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
                }
            }
            if let acknowledgement {
                try validate(
                    acknowledgement,
                    at: artifacts.acknowledgement,
                    expected: runIdentifier
                )
                guard acknowledgement.requestNonce == nonce else {
                    throw GameModeLaunchRequestStoreError.nonceMismatch(runIdentifier)
                }
            }
            if let claimed, let acknowledgement {
                try validate(
                    acknowledgement,
                    matches: claimed,
                    at: artifacts.acknowledgement
                )
            }

            try unlinkIfPresent(artifacts.acknowledgement)
            try unlinkIfPresent(artifacts.claimed)
            try unlinkIfPresent(artifacts.pending)
            return true
        }
    }

    @discardableResult
    func cleanupExpired(at date: Date = Date()) throws -> [GameModeRunIdentifier] {
        let cleanupDate = try GameModeTimestampContract.normalized(
            date,
            field: "cleanup_at_unix_milliseconds"
        )
        return try withExclusiveStoreLock {
            try cleanupExpiredLocked(at: cleanupDate)
        }
    }

    private var pendingDirectoryURL: URL {
        rootURL.appending(path: pendingDirectoryName, directoryHint: .isDirectory)
    }

    private var claimedDirectoryURL: URL {
        rootURL.appending(path: claimedDirectoryName, directoryHint: .isDirectory)
    }

    private var acknowledgementDirectoryURL: URL {
        rootURL.appending(path: acknowledgementDirectoryName, directoryHint: .isDirectory)
    }

    private var lockURL: URL {
        rootURL.appending(path: lockFileName, directoryHint: .notDirectory)
    }

    private func pendingURL(for runIdentifier: GameModeRunIdentifier) -> URL {
        pendingDirectoryURL.appending(
            path: runIdentifier.rawValue + requestFileSuffix,
            directoryHint: .notDirectory
        )
    }

    private func claimedURL(for runIdentifier: GameModeRunIdentifier) -> URL {
        claimedDirectoryURL.appending(
            path: runIdentifier.rawValue + requestFileSuffix,
            directoryHint: .notDirectory
        )
    }

    private func acknowledgementURL(for runIdentifier: GameModeRunIdentifier) -> URL {
        acknowledgementDirectoryURL.appending(
            path: runIdentifier.rawValue + acknowledgementFileSuffix,
            directoryHint: .notDirectory
        )
    }

    private func artifactURLs(
        for runIdentifier: GameModeRunIdentifier
    ) -> (pending: URL, claimed: URL, acknowledgement: URL) {
        (
            pending: pendingURL(for: runIdentifier),
            claimed: claimedURL(for: runIdentifier),
            acknowledgement: acknowledgementURL(for: runIdentifier)
        )
    }

    private func withExclusiveStoreLock<T>(_ body: () throws -> T) throws -> T {
        try prepareLayout()
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw GameModeLaunchRequestStoreError.unsafeStorePath(lockURL)
            }
            throw GameModeLaunchRequestStoreError.storeIOFailed(lockURL, code)
        }
        defer { Darwin.close(descriptor) }
        try requireSafeRegularFile(descriptor: descriptor, url: lockURL)

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw GameModeLaunchRequestStoreError.storeIOFailed(lockURL, code)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        try requireSafeDirectory(rootURL)
        try requireSafeDirectory(pendingDirectoryURL)
        try requireSafeDirectory(claimedDirectoryURL)
        try requireSafeDirectory(acknowledgementDirectoryURL)
        return try body()
    }

    private func prepareLayout() throws {
        if try !artifactExists(rootURL) {
            do {
                try fileManager.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw GameModeLaunchRequestStoreError.storeIOFailed(rootURL, errnoOrIOError())
            }
        }
        try requireSafeDirectory(rootURL)
        for directory in [
            pendingDirectoryURL,
            claimedDirectoryURL,
            acknowledgementDirectoryURL
        ] {
            let result = directory.path.withCString { Darwin.mkdir($0, 0o700) }
            if result != 0, errno != EEXIST {
                throw GameModeLaunchRequestStoreError.storeIOFailed(directory, errno)
            }
            try requireSafeDirectory(directory)
        }
    }

    private func cleanupExpiredLocked(at date: Date) throws -> [GameModeRunIdentifier] {
        var requestsByRun: [GameModeRunIdentifier: (request: GameModeLaunchRequest, url: URL)] = [:]
        for directory in [pendingDirectoryURL, claimedDirectoryURL] {
            for document in try requestDocuments(in: directory) {
                if requestsByRun.updateValue(
                    (document.request, document.url),
                    forKey: document.request.runIdentifier
                ) != nil {
                    throw GameModeLaunchRequestStoreError.inconsistentState(
                        document.request.runIdentifier
                    )
                }
            }
        }

        var removed = Set<GameModeRunIdentifier>()
        for (runIdentifier, document) in requestsByRun where document.request.expiresAt <= date {
            let acknowledgementURL = acknowledgementURL(for: runIdentifier)
            if let acknowledgement: GameModeLaunchAcknowledgement = try readDocumentIfPresent(
                from: acknowledgementURL
            ) {
                try validate(acknowledgement, at: acknowledgementURL, expected: runIdentifier)
                guard acknowledgement.requestNonce == document.request.requestNonce,
                      acknowledgement.requestExpiresAt == document.request.expiresAt else {
                    throw GameModeLaunchRequestStoreError.inconsistentState(runIdentifier)
                }
                try unlinkIfPresent(acknowledgementURL)
            }
            try unlinkIfPresent(document.url)
            removed.insert(runIdentifier)
        }

        for document in try acknowledgementDocuments()
        where document.acknowledgement.requestExpiresAt <= date {
            let runIdentifier = document.acknowledgement.runIdentifier
            guard requestsByRun[runIdentifier] == nil else { continue }
            try unlinkIfPresent(document.url)
            removed.insert(runIdentifier)
        }
        return removed.sorted { $0.rawValue < $1.rawValue }
    }

    private func requestDocuments(
        in directory: URL
    ) throws -> [(request: GameModeLaunchRequest, url: URL)] {
        try requireSafeDirectory(directory)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw GameModeLaunchRequestStoreError.storeIOFailed(directory, errnoOrIOError())
        }
        return try names.compactMap { name in
            guard let runIdentifier = try runIdentifier(
                from: name,
                suffix: requestFileSuffix
            ) else {
                return nil
            }
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            let request: GameModeLaunchRequest = try readDocument(from: url)
            try validate(request, at: url, expected: runIdentifier)
            return (request, url)
        }
    }

    private func acknowledgementDocuments(
    ) throws -> [(acknowledgement: GameModeLaunchAcknowledgement, url: URL)] {
        try requireSafeDirectory(acknowledgementDirectoryURL)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: acknowledgementDirectoryURL.path)
        } catch {
            throw GameModeLaunchRequestStoreError.storeIOFailed(
                acknowledgementDirectoryURL,
                errnoOrIOError()
            )
        }
        return try names.compactMap { name in
            guard let runIdentifier = try runIdentifier(
                from: name,
                suffix: acknowledgementFileSuffix
            ) else {
                return nil
            }
            let url = acknowledgementDirectoryURL.appending(
                path: name,
                directoryHint: .notDirectory
            )
            let acknowledgement: GameModeLaunchAcknowledgement = try readDocument(from: url)
            try validate(acknowledgement, at: url, expected: runIdentifier)
            return (acknowledgement, url)
        }
    }

    private func runIdentifier(
        from fileName: String,
        suffix: String
    ) throws -> GameModeRunIdentifier? {
        guard fileName.hasSuffix(suffix) else { return nil }
        let rawIdentifier = String(fileName.dropLast(suffix.count))
        do {
            return try GameModeRunIdentifier(validating: rawIdentifier)
        } catch {
            let url = rootURL.appending(path: fileName, directoryHint: .notDirectory)
            throw GameModeLaunchRequestStoreError.invalidDocument(url)
        }
    }

    private func validate(
        _ request: GameModeLaunchRequest,
        at url: URL,
        expected runIdentifier: GameModeRunIdentifier
    ) throws {
        guard request.runIdentifier == runIdentifier else {
            throw GameModeLaunchRequestStoreError.invalidDocument(url)
        }
    }

    private func validate(
        _ acknowledgement: GameModeLaunchAcknowledgement,
        at url: URL,
        expected runIdentifier: GameModeRunIdentifier
    ) throws {
        guard acknowledgement.runIdentifier == runIdentifier else {
            throw GameModeLaunchRequestStoreError.invalidDocument(url)
        }
    }

    private func validate(
        _ acknowledgement: GameModeLaunchAcknowledgement,
        matches request: GameModeLaunchRequest,
        at url: URL
    ) throws {
        guard acknowledgement.runIdentifier == request.runIdentifier,
              acknowledgement.requestNonce == request.requestNonce,
              acknowledgement.requestExpiresAt == request.expiresAt,
              acknowledgement.acknowledgedAt >= request.createdAt else {
            throw GameModeLaunchRequestStoreError.invalidDocument(url)
        }
    }

    private func encodeDocument<T: Encodable>(_ document: T, destination: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            var encoded = try encoder.encode(document)
            encoded.append(contentsOf: "\n".utf8)
            data = encoded
        } catch {
            throw GameModeLaunchRequestStoreError.invalidDocument(destination)
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw GameModeLaunchRequestStoreError.documentTooLarge(
                destination,
                Int64(data.count)
            )
        }
        return data
    }

    private func readDocument<T: Decodable>(from url: URL) throws -> T {
        guard let document: T = try readDocumentIfPresent(from: url) else {
            throw GameModeLaunchRequestStoreError.storeIOFailed(url, ENOENT)
        }
        return document
    }

    private func readDocumentIfPresent<T: Decodable>(from url: URL) throws -> T? {
        guard let data = try readDataIfPresent(from: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GameModeLaunchRequestStoreError.invalidDocument(url)
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private func readDataIfPresent(from url: URL) throws -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw GameModeLaunchRequestStoreError.unsafeStorePath(url)
            }
            throw GameModeLaunchRequestStoreError.storeIOFailed(url, code)
        }
        defer { Darwin.close(descriptor) }

        let initialIdentity = try fileIdentity(descriptor: descriptor, url: url)
        guard initialIdentity.byteCount <= Int64(Self.maximumDocumentBytes) else {
            throw GameModeLaunchRequestStoreError.documentTooLarge(
                url,
                initialIdentity.byteCount
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= Self.maximumDocumentBytes else {
                    throw GameModeLaunchRequestStoreError.documentTooLarge(
                        url,
                        Int64(data.count)
                    )
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw GameModeLaunchRequestStoreError.storeIOFailed(url, errno)
            }
        }
        guard try fileIdentity(descriptor: descriptor, url: url) == initialIdentity else {
            throw GameModeLaunchRequestStoreError.unsafeStorePath(url)
        }
        return data
    }

    private func writeAtomicallyExclusive(_ data: Data, to destination: URL) throws {
        guard data.count <= Self.maximumDocumentBytes else {
            throw GameModeLaunchRequestStoreError.documentTooLarge(
                destination,
                Int64(data.count)
            )
        }
        let directory = destination.deletingLastPathComponent()
        try requireSafeDirectory(directory)
        let temporaryURL = directory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp",
            directoryHint: .notDirectory
        )
        var removeTemporary = true
        defer {
            if removeTemporary {
                _ = temporaryURL.path.withCString { Darwin.unlink($0) }
            }
        }

        let descriptor = temporaryURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw GameModeLaunchRequestStoreError.unsafeStorePath(temporaryURL)
            }
            throw GameModeLaunchRequestStoreError.storeIOFailed(temporaryURL, code)
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
        }
        try requireSafeRegularFile(descriptor: descriptor, url: temporaryURL)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw GameModeLaunchRequestStoreError.storeIOFailed(temporaryURL, errno)
                }
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw GameModeLaunchRequestStoreError.storeIOFailed(temporaryURL, errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw GameModeLaunchRequestStoreError.storeIOFailed(temporaryURL, errno)
        }
        descriptorIsOpen = false

        try requireSafeDirectory(directory)
        try renameExclusive(temporaryURL, to: destination)
        removeTemporary = false
    }

    private func renameExclusive(_ source: URL, to destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                throw GameModeLaunchRequestStoreError.artifactAlreadyExists(destination)
            }
            throw GameModeLaunchRequestStoreError.storeIOFailed(destination, code)
        }
    }

    private func unlinkIfPresent(_ url: URL) throws {
        guard let descriptor = try openRegularFileIfPresent(url) else { return }
        Darwin.close(descriptor)
        let result = url.path.withCString { Darwin.unlink($0) }
        guard result == 0 || errno == ENOENT else {
            throw GameModeLaunchRequestStoreError.storeIOFailed(url, errno)
        }
    }

    private func openRegularFileIfPresent(_ url: URL) throws -> Int32? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw GameModeLaunchRequestStoreError.unsafeStorePath(url)
            }
            throw GameModeLaunchRequestStoreError.storeIOFailed(url, code)
        }
        do {
            try requireSafeRegularFile(descriptor: descriptor, url: url)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func artifactExists(_ url: URL) throws -> Bool {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw GameModeLaunchRequestStoreError.storeIOFailed(url, code)
    }

    private func requireSafeDirectory(_ url: URL) throws {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw GameModeLaunchRequestStoreError.unsafeStorePath(url)
        }
    }

    private func requireSafeRegularFile(descriptor: Int32, url: URL) throws {
        _ = try fileIdentity(descriptor: descriptor, url: url)
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw GameModeLaunchRequestStoreError.unsafeStorePath(url)
        }
    }

    private func fileIdentity(descriptor: Int32, url: URL) throws -> FileIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw GameModeLaunchRequestStoreError.unsafeStorePath(url)
        }
        return FileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private func errnoOrIOError() -> Int32 {
        errno == 0 ? EIO : errno
    }
}
