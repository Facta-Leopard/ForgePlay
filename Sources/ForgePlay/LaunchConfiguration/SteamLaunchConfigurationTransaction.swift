import Foundation

enum SteamLaunchConfigurationTransactionState: String, Codable, Hashable, Sendable {
    case requested
    case resolved
    case applied
    case restored
}

enum SteamLaunchConfigurationRestorationState: String, Codable, Hashable, Sendable {
    case notRequired
    case pending
    case succeeded
    case failed
}

enum SteamLaunchConfigurationTransactionError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidTransactionID
    case invalidDigest(field: String)
    case invalidFailureCode
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "지원하지 않는 Steam 실행 트랜잭션 버전입니다: \(version)"
        case .invalidTransactionID:
            "Steam 실행 트랜잭션 ID가 올바르지 않습니다."
        case .invalidDigest(let field):
            "Steam 실행 트랜잭션 다이제스트가 올바르지 않습니다: \(field)"
        case .invalidFailureCode:
            "Steam 실행 트랜잭션 실패 코드가 올바르지 않습니다."
        case .invalidState(let reason):
            "Steam 실행 트랜잭션 상태가 올바르지 않습니다: \(reason)"
        }
    }
}

struct SteamLaunchConfigurationTransactionJournal: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    private static let zeroTransactionID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    let schemaVersion: Int
    let transactionID: UUID
    private(set) var state: SteamLaunchConfigurationTransactionState
    let requestedDigest: String
    private(set) var resolvedDigest: String?
    private(set) var appliedDigest: String?
    private(set) var capturedBaselineDigest: String?
    private(set) var restoredBaselineDigest: String?
    private(set) var restorationState: SteamLaunchConfigurationRestorationState
    private(set) var restoreAttemptCount: Int
    private(set) var failureCode: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        transactionID: UUID = UUID(),
        requestedDigest: String
    ) throws {
        try self.init(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            state: .requested,
            requestedDigest: requestedDigest,
            resolvedDigest: nil,
            appliedDigest: nil,
            capturedBaselineDigest: nil,
            restoredBaselineDigest: nil,
            restorationState: .notRequired,
            restoreAttemptCount: 0,
            failureCode: nil
        )
    }

    mutating func resolve(resolvedDigest: String) throws {
        try validate()
        try Self.validateDigest(resolvedDigest, field: "resolved")
        guard state == .requested else {
            throw SteamLaunchConfigurationTransactionError.invalidState("resolve-requires-requested")
        }

        var prospective = self
        prospective.state = .resolved
        prospective.resolvedDigest = resolvedDigest
        try prospective.validate()
        self = prospective
    }

    mutating func apply(
        appliedDigest: String,
        capturedBaselineDigest: String
    ) throws {
        try validate()
        try Self.validateDigest(appliedDigest, field: "applied")
        try Self.validateDigest(capturedBaselineDigest, field: "captured-baseline")
        guard state == .resolved else {
            throw SteamLaunchConfigurationTransactionError.invalidState("apply-requires-resolved")
        }
        guard appliedDigest == resolvedDigest else {
            throw SteamLaunchConfigurationTransactionError.invalidState("applied-resolved-mismatch")
        }

        var prospective = self
        prospective.state = .applied
        prospective.appliedDigest = appliedDigest
        prospective.capturedBaselineDigest = capturedBaselineDigest
        prospective.restorationState = .pending
        try prospective.validate()
        self = prospective
    }

    mutating func markRestoreFailed(failureCode: String) throws {
        try validate()
        guard SteamLaunchIdentifierValidation.isValid(failureCode, maximumUTF8Bytes: 128) else {
            throw SteamLaunchConfigurationTransactionError.invalidFailureCode
        }
        guard state == .applied,
              restorationState == .pending || restorationState == .failed else {
            throw SteamLaunchConfigurationTransactionError.invalidState(
                "restore-failure-requires-applied"
            )
        }
        guard restoreAttemptCount < 2 else {
            throw SteamLaunchConfigurationTransactionError.invalidState(
                "restore-attempt-limit"
            )
        }

        var prospective = self
        prospective.restorationState = .failed
        prospective.restoreAttemptCount += 1
        prospective.failureCode = failureCode
        try prospective.validate()
        self = prospective
    }

    mutating func markRestored(restoredBaselineDigest: String) throws {
        try validate()
        try Self.validateDigest(restoredBaselineDigest, field: "restored-baseline")
        guard state == .applied,
              restorationState == .pending || restorationState == .failed else {
            throw SteamLaunchConfigurationTransactionError.invalidState(
                "restore-success-requires-applied"
            )
        }
        guard restoredBaselineDigest == capturedBaselineDigest else {
            throw SteamLaunchConfigurationTransactionError.invalidState(
                "restored-captured-baseline-mismatch"
            )
        }

        var prospective = self
        prospective.state = .restored
        prospective.restoredBaselineDigest = restoredBaselineDigest
        prospective.restorationState = .succeeded
        prospective.failureCode = nil
        try prospective.validate()
        self = prospective
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SteamLaunchConfigurationTransactionError.unsupportedSchemaVersion(schemaVersion)
        }
        guard transactionID != Self.zeroTransactionID else {
            throw SteamLaunchConfigurationTransactionError.invalidTransactionID
        }
        try Self.validateDigest(requestedDigest, field: "requested")
        try Self.validateOptionalDigest(resolvedDigest, field: "resolved")
        try Self.validateOptionalDigest(appliedDigest, field: "applied")
        try Self.validateOptionalDigest(capturedBaselineDigest, field: "captured-baseline")
        try Self.validateOptionalDigest(restoredBaselineDigest, field: "restored-baseline")
        if let failureCode,
           !SteamLaunchIdentifierValidation.isValid(failureCode, maximumUTF8Bytes: 128) {
            throw SteamLaunchConfigurationTransactionError.invalidFailureCode
        }

        switch state {
        case .requested:
            guard resolvedDigest == nil,
                  appliedDigest == nil,
                  capturedBaselineDigest == nil,
                  restoredBaselineDigest == nil,
                  restorationState == .notRequired,
                  restoreAttemptCount == 0,
                  failureCode == nil else {
                throw SteamLaunchConfigurationTransactionError.invalidState(
                    "requested-invariant"
                )
            }
        case .resolved:
            guard resolvedDigest != nil,
                  appliedDigest == nil,
                  capturedBaselineDigest == nil,
                  restoredBaselineDigest == nil,
                  restorationState == .notRequired,
                  restoreAttemptCount == 0,
                  failureCode == nil else {
                throw SteamLaunchConfigurationTransactionError.invalidState(
                    "resolved-invariant"
                )
            }
        case .applied:
            guard let resolvedDigest,
                  let appliedDigest,
                  capturedBaselineDigest != nil,
                  appliedDigest == resolvedDigest,
                  restoredBaselineDigest == nil else {
                throw SteamLaunchConfigurationTransactionError.invalidState(
                    "applied-digest-invariant"
                )
            }
            switch restorationState {
            case .pending:
                guard restoreAttemptCount == 0, failureCode == nil else {
                    throw SteamLaunchConfigurationTransactionError.invalidState(
                        "pending-restoration-invariant"
                    )
                }
            case .failed:
                guard (1 ... 2).contains(restoreAttemptCount), failureCode != nil else {
                    throw SteamLaunchConfigurationTransactionError.invalidState(
                        "failed-restoration-invariant"
                    )
                }
            case .notRequired, .succeeded:
                throw SteamLaunchConfigurationTransactionError.invalidState(
                    "applied-restoration-state"
                )
            }
        case .restored:
            guard let resolvedDigest,
                  let appliedDigest,
                  let capturedBaselineDigest,
                  let restoredBaselineDigest,
                  appliedDigest == resolvedDigest,
                  restoredBaselineDigest == capturedBaselineDigest,
                  restorationState == .succeeded,
                  (0 ... 2).contains(restoreAttemptCount),
                  failureCode == nil else {
                throw SteamLaunchConfigurationTransactionError.invalidState(
                    "restored-invariant"
                )
            }
        }
    }

    private init(
        schemaVersion: Int,
        transactionID: UUID,
        state: SteamLaunchConfigurationTransactionState,
        requestedDigest: String,
        resolvedDigest: String?,
        appliedDigest: String?,
        capturedBaselineDigest: String?,
        restoredBaselineDigest: String?,
        restorationState: SteamLaunchConfigurationRestorationState,
        restoreAttemptCount: Int,
        failureCode: String?
    ) throws {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.state = state
        self.requestedDigest = requestedDigest
        self.resolvedDigest = resolvedDigest
        self.appliedDigest = appliedDigest
        self.capturedBaselineDigest = capturedBaselineDigest
        self.restoredBaselineDigest = restoredBaselineDigest
        self.restorationState = restorationState
        self.restoreAttemptCount = restoreAttemptCount
        self.failureCode = failureCode
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case transactionID
        case state
        case requestedDigest
        case resolvedDigest
        case appliedDigest
        case capturedBaselineDigest
        case restoredBaselineDigest
        case restorationState
        case restoreAttemptCount
        case failureCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transactionIDText = try container.decode(String.self, forKey: .transactionID)
        guard transactionIDText.utf8.count == 36,
              transactionIDText == transactionIDText.lowercased(),
              let transactionID = UUID(uuidString: transactionIDText),
              transactionID.uuidString.lowercased() == transactionIDText else {
            throw SteamLaunchConfigurationTransactionError.invalidTransactionID
        }
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            transactionID: transactionID,
            state: container.decode(
                SteamLaunchConfigurationTransactionState.self,
                forKey: .state
            ),
            requestedDigest: container.decode(String.self, forKey: .requestedDigest),
            resolvedDigest: container.decodeIfPresent(String.self, forKey: .resolvedDigest),
            appliedDigest: container.decodeIfPresent(String.self, forKey: .appliedDigest),
            capturedBaselineDigest: container.decodeIfPresent(
                String.self,
                forKey: .capturedBaselineDigest
            ),
            restoredBaselineDigest: container.decodeIfPresent(
                String.self,
                forKey: .restoredBaselineDigest
            ),
            restorationState: container.decode(
                SteamLaunchConfigurationRestorationState.self,
                forKey: .restorationState
            ),
            restoreAttemptCount: container.decode(Int.self, forKey: .restoreAttemptCount),
            failureCode: container.decodeIfPresent(String.self, forKey: .failureCode)
        )
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(transactionID.uuidString.lowercased(), forKey: .transactionID)
        try container.encode(state, forKey: .state)
        try container.encode(requestedDigest, forKey: .requestedDigest)
        try container.encodeIfPresent(resolvedDigest, forKey: .resolvedDigest)
        try container.encodeIfPresent(appliedDigest, forKey: .appliedDigest)
        try container.encodeIfPresent(capturedBaselineDigest, forKey: .capturedBaselineDigest)
        try container.encodeIfPresent(restoredBaselineDigest, forKey: .restoredBaselineDigest)
        try container.encode(restorationState, forKey: .restorationState)
        try container.encode(restoreAttemptCount, forKey: .restoreAttemptCount)
        try container.encodeIfPresent(failureCode, forKey: .failureCode)
    }

    private static func validateDigest(_ digest: String, field: String) throws {
        guard SteamLaunchIdentifierValidation.isValidLowercaseSHA256(digest) else {
            throw SteamLaunchConfigurationTransactionError.invalidDigest(field: field)
        }
    }

    private static func validateOptionalDigest(_ digest: String?, field: String) throws {
        guard let digest else { return }
        try validateDigest(digest, field: field)
    }
}
