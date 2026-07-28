// SPDX-FileCopyrightText: 2026 Facta-Leopard
// SPDX-License-Identifier: GPL-3.0-only
//
// ForgePlay Game Mode
// Original source: https://github.com/Facta-Leopard/ForgePlay

import Foundation

enum GameModeSchemaValidationError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case invalidFingerprint(String)
    case invalidProcessIdentifier(String)
    case invalidTimestamp(String)
    case invalidRequestLifetime
    case invalidAcknowledgementLifetime
    case unsupportedSchemaVersion(Int)
    case unexpectedFields(String)
    case inconsistentEvidenceState
    case documentTooLarge(maximumBytes: Int, actualBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let field):
            "Game Mode schema identifier is invalid: \(field)"
        case .invalidFingerprint(let field):
            "Game Mode schema fingerprint is invalid: \(field)"
        case .invalidProcessIdentifier(let namespace):
            "Game Mode \(namespace) process identifier is invalid."
        case .invalidTimestamp(let field):
            "Game Mode schema timestamp is invalid: \(field)"
        case .invalidRequestLifetime:
            "Game Mode launch request lifetime is invalid."
        case .invalidAcknowledgementLifetime:
            "Game Mode launch acknowledgement is outside the request lifetime."
        case .unsupportedSchemaVersion(let version):
            "Game Mode schema version is unsupported: \(version)"
        case .unexpectedFields(let context):
            "Game Mode JSON contains fields outside the \(context) contract."
        case .inconsistentEvidenceState:
            "Game Mode evidence fields do not support the recorded assessment."
        case .documentTooLarge(let maximumBytes, let actualBytes):
            "Game Mode JSON exceeds its size limit (\(actualBytes)/\(maximumBytes) bytes)."
        }
    }
}

struct GameModeRunIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init() {
        rawValue = UUID().uuidString.lowercased()
    }

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }

    init(validating rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue),
              rawValue == uuid.uuidString.lowercased() else {
            throw GameModeSchemaValidationError.invalidIdentifier("run_identifier")
        }
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(validating: container.decode(String.self))
        } catch let error as GameModeSchemaValidationError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct GameModeRequestNonce: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init() {
        rawValue = UUID().uuidString.lowercased()
    }

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }

    init(validating rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue),
              rawValue == uuid.uuidString.lowercased() else {
            throw GameModeSchemaValidationError.invalidIdentifier("request_nonce")
        }
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(validating: container.decode(String.self))
        } catch let error as GameModeSchemaValidationError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct GameModePrefixGenerationIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }

    init(validating rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue) else {
            throw GameModeSchemaValidationError.invalidIdentifier(
                "prefix_generation_identifier"
            )
        }
        self.rawValue = uuid.uuidString.lowercased()
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(validating: container.decode(String.self))
        } catch let error as GameModeSchemaValidationError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct GameModeRuntimeBuildFingerprint: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(validating rawValue: String) throws {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw GameModeSchemaValidationError.invalidFingerprint(
                "runtime_build_fingerprint"
            )
        }
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(validating: container.decode(String.self))
        } catch let error as GameModeSchemaValidationError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct GameModeDarwinProcessIdentity: Codable, Hashable, Sendable {
    /// A PID in the Darwin process namespace. It must never be populated with a
    /// Windows process identifier even when both numeric values happen to match.
    let processIdentifier: Int32
    let startTimeUnixMilliseconds: Int64?

    init(processIdentifier: Int32, startTimeUnixMilliseconds: Int64? = nil) throws {
        guard processIdentifier > 0 else {
            throw GameModeSchemaValidationError.invalidProcessIdentifier("Darwin")
        }
        if let startTimeUnixMilliseconds, startTimeUnixMilliseconds <= 0 {
            throw GameModeSchemaValidationError.invalidTimestamp(
                "darwin_process.start_time_unix_milliseconds"
            )
        }
        self.processIdentifier = processIdentifier
        self.startTimeUnixMilliseconds = startTimeUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processIdentifier = "process_identifier"
        case startTimeUnixMilliseconds = "start_time_unix_milliseconds"
    }

    init(from decoder: Decoder) throws {
        try GameModeJSONShape.requireOnlyKeys(
            CodingKeys.self,
            from: decoder,
            context: "darwin_process"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            processIdentifier: container.decode(Int32.self, forKey: .processIdentifier),
            startTimeUnixMilliseconds: container.decodeIfPresent(
                Int64.self,
                forKey: .startTimeUnixMilliseconds
            )
        )
    }
}

struct GameModeWindowsProcessIdentity: Codable, Hashable, Sendable {
    /// A PID in the emulated Windows process namespace, intentionally distinct
    /// from `GameModeDarwinProcessIdentity` at the type level.
    let processIdentifier: UInt32

    init(processIdentifier: UInt32) throws {
        guard processIdentifier > 0 else {
            throw GameModeSchemaValidationError.invalidProcessIdentifier("Windows")
        }
        self.processIdentifier = processIdentifier
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processIdentifier = "process_identifier"
    }

    init(from decoder: Decoder) throws {
        try GameModeJSONShape.requireOnlyKeys(
            CodingKeys.self,
            from: decoder,
            context: "windows_process"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(processIdentifier: container.decode(UInt32.self, forKey: .processIdentifier))
    }
}

enum GameModeEvidenceCheckState: String, Codable, Hashable, Sendable {
    case notObserved
    case verified
    case failed
}

enum GameModeUserVerificationState: String, Codable, Hashable, Sendable {
    case notRequested
    case userVerifiedActive
    case userVerifiedDisabled
    case inconclusive
}

enum GameModeEvidenceAssessment: String, Codable, Hashable, Sendable {
    case hostIdentityVerified
    case nativeFullscreenVerified
    case gameModeUserVerifiedActive
    case blockedUserDisabled
    case inconclusiveSystemPolicy
    case unsupportedSteamRelaunch
    case failedHostIdentity
}

struct GameModeEvidence: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumDocumentBytes = 32 * 1_024

    let schemaVersion: Int
    let runIdentifier: GameModeRunIdentifier
    let requestNonce: GameModeRequestNonce
    let sequenceNumber: UInt32
    let recordedAt: Date
    let assessment: GameModeEvidenceAssessment
    let hostIdentityCheck: GameModeEvidenceCheckState
    let nativeFullscreenCheck: GameModeEvidenceCheckState
    let userVerification: GameModeUserVerificationState
    let hostDarwinProcess: GameModeDarwinProcessIdentity?
    let windowOwnerDarwinProcess: GameModeDarwinProcessIdentity?
    let gameWindowsProcess: GameModeWindowsProcessIdentity?

    init(
        runIdentifier: GameModeRunIdentifier,
        requestNonce: GameModeRequestNonce,
        sequenceNumber: UInt32,
        recordedAt: Date,
        assessment: GameModeEvidenceAssessment,
        hostIdentityCheck: GameModeEvidenceCheckState,
        nativeFullscreenCheck: GameModeEvidenceCheckState,
        userVerification: GameModeUserVerificationState,
        hostDarwinProcess: GameModeDarwinProcessIdentity? = nil,
        windowOwnerDarwinProcess: GameModeDarwinProcessIdentity? = nil,
        gameWindowsProcess: GameModeWindowsProcessIdentity? = nil
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.runIdentifier = runIdentifier
        self.requestNonce = requestNonce
        self.sequenceNumber = sequenceNumber
        self.recordedAt = try GameModeTimestampContract.normalized(
            recordedAt,
            field: "recorded_at_unix_milliseconds"
        )
        self.assessment = assessment
        self.hostIdentityCheck = hostIdentityCheck
        self.nativeFullscreenCheck = nativeFullscreenCheck
        self.userVerification = userVerification
        self.hostDarwinProcess = hostDarwinProcess
        self.windowOwnerDarwinProcess = windowOwnerDarwinProcess
        self.gameWindowsProcess = gameWindowsProcess
        try validateConsistency()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case runIdentifier = "run_identifier"
        case requestNonce = "request_nonce"
        case sequenceNumber = "sequence_number"
        case recordedAtUnixMilliseconds = "recorded_at_unix_milliseconds"
        case assessment
        case hostIdentityCheck = "host_identity_check"
        case nativeFullscreenCheck = "native_fullscreen_check"
        case userVerification = "user_verification"
        case hostDarwinProcess = "host_darwin_process"
        case windowOwnerDarwinProcess = "window_owner_darwin_process"
        case gameWindowsProcess = "game_windows_process"
    }

    init(from decoder: Decoder) throws {
        try GameModeJSONShape.requireOnlyKeys(
            CodingKeys.self,
            from: decoder,
            context: "game_mode_evidence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GameModeSchemaValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try self.init(
            runIdentifier: container.decode(GameModeRunIdentifier.self, forKey: .runIdentifier),
            requestNonce: container.decode(GameModeRequestNonce.self, forKey: .requestNonce),
            sequenceNumber: container.decode(UInt32.self, forKey: .sequenceNumber),
            recordedAt: GameModeTimestampContract.date(
                fromUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .recordedAtUnixMilliseconds
                ),
                field: CodingKeys.recordedAtUnixMilliseconds.rawValue
            ),
            assessment: container.decode(GameModeEvidenceAssessment.self, forKey: .assessment),
            hostIdentityCheck: container.decode(
                GameModeEvidenceCheckState.self,
                forKey: .hostIdentityCheck
            ),
            nativeFullscreenCheck: container.decode(
                GameModeEvidenceCheckState.self,
                forKey: .nativeFullscreenCheck
            ),
            userVerification: container.decode(
                GameModeUserVerificationState.self,
                forKey: .userVerification
            ),
            hostDarwinProcess: container.decodeIfPresent(
                GameModeDarwinProcessIdentity.self,
                forKey: .hostDarwinProcess
            ),
            windowOwnerDarwinProcess: container.decodeIfPresent(
                GameModeDarwinProcessIdentity.self,
                forKey: .windowOwnerDarwinProcess
            ),
            gameWindowsProcess: container.decodeIfPresent(
                GameModeWindowsProcessIdentity.self,
                forKey: .gameWindowsProcess
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runIdentifier, forKey: .runIdentifier)
        try container.encode(requestNonce, forKey: .requestNonce)
        try container.encode(sequenceNumber, forKey: .sequenceNumber)
        try container.encode(
            GameModeTimestampContract.unixMilliseconds(
                recordedAt,
                field: CodingKeys.recordedAtUnixMilliseconds.rawValue
            ),
            forKey: .recordedAtUnixMilliseconds
        )
        try container.encode(assessment, forKey: .assessment)
        try container.encode(hostIdentityCheck, forKey: .hostIdentityCheck)
        try container.encode(nativeFullscreenCheck, forKey: .nativeFullscreenCheck)
        try container.encode(userVerification, forKey: .userVerification)
        try container.encodeIfPresent(hostDarwinProcess, forKey: .hostDarwinProcess)
        try container.encodeIfPresent(windowOwnerDarwinProcess, forKey: .windowOwnerDarwinProcess)
        try container.encodeIfPresent(gameWindowsProcess, forKey: .gameWindowsProcess)
    }

    /// Encodes the bounded evidence contract. This does not infer that Game Mode
    /// is active; only `.gameModeUserVerifiedActive` records that user finding.
    static func encodeJSON(_ evidence: GameModeEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(evidence)
        data.append(contentsOf: "\n".utf8)
        guard data.count <= maximumDocumentBytes else {
            throw GameModeSchemaValidationError.documentTooLarge(
                maximumBytes: maximumDocumentBytes,
                actualBytes: data.count
            )
        }
        return data
    }

    static func decodeJSON(_ data: Data) throws -> GameModeEvidence {
        guard data.count <= maximumDocumentBytes else {
            throw GameModeSchemaValidationError.documentTooLarge(
                maximumBytes: maximumDocumentBytes,
                actualBytes: data.count
            )
        }
        return try JSONDecoder().decode(GameModeEvidence.self, from: data)
    }

    private func validateConsistency() throws {
        if nativeFullscreenCheck == .verified {
            guard hostIdentityCheck == .verified,
                  let hostDarwinProcess,
                  let windowOwnerDarwinProcess,
                  hostDarwinProcess.processIdentifier == windowOwnerDarwinProcess.processIdentifier else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        }

        switch assessment {
        case .hostIdentityVerified:
            guard hostIdentityCheck == .verified, hostDarwinProcess != nil else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        case .nativeFullscreenVerified:
            guard nativeFullscreenCheck == .verified else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        case .gameModeUserVerifiedActive:
            guard hostIdentityCheck == .verified,
                  nativeFullscreenCheck == .verified,
                  userVerification == .userVerifiedActive else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        case .blockedUserDisabled:
            guard userVerification == .userVerifiedDisabled else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        case .inconclusiveSystemPolicy:
            guard hostIdentityCheck == .verified,
                  nativeFullscreenCheck == .verified,
                  userVerification == .inconclusive else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        case .unsupportedSteamRelaunch:
            break
        case .failedHostIdentity:
            guard hostIdentityCheck == .failed else {
                throw GameModeSchemaValidationError.inconsistentEvidenceState
            }
        }
    }
}

enum GameModeTimestampContract {
    static func normalized(_ date: Date, field: String) throws -> Date {
        try self.date(fromUnixMilliseconds: unixMilliseconds(date, field: field), field: field)
    }

    static func unixMilliseconds(_ date: Date, field: String) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= Double(Int64.max) else {
            throw GameModeSchemaValidationError.invalidTimestamp(field)
        }
        return Int64(milliseconds.rounded(.towardZero))
    }

    static func date(fromUnixMilliseconds milliseconds: Int64, field: String) throws -> Date {
        guard milliseconds > 0 else {
            throw GameModeSchemaValidationError.invalidTimestamp(field)
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

enum GameModeJSONShape {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func requireOnlyKeys<Key: CodingKey & CaseIterable>(
        _ keyType: Key.Type,
        from decoder: Decoder,
        context: String
    ) throws where Key.AllCases: Sequence {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let present = Set(container.allKeys.map(\.stringValue))
        guard present.isSubset(of: allowed) else {
            throw GameModeSchemaValidationError.unexpectedFields(context)
        }
    }
}
