// ForgePlay-authored clean-room output.
// Distribution remains blocked until explicit project license assignment.
//
// This standalone host control module owns only ForgePlay authority state,
// framing, proofs, and lifecycle-facing records. It does not implement or
// interpret Wine private requests, HANDLEs, file objects, PE mapping, SCM
// internals, loader continuity, or product routing.

import Darwin
import Foundation

// MARK: - AuthorityMutationScopeV3

enum WindowsAuthorityState: UInt8, CaseIterable, Codable, Sendable {
    case prepared = 1
    case bound = 2
    case activationPending = 3
    case processCommitted = 4
    case releasePending = 5
    case released = 6
    case processCleanupPending = 7
    case aborting = 8
    case invalidated = 9
}

enum WindowsAuthorityOwnershipClass: UInt8, CaseIterable, Codable, Sendable {
    case sessionTransient = 0
    case guestPersistent = 1
}

enum WindowsAuthorityProcessOwnership: UInt8, CaseIterable, Codable, Sendable {
    case none = 0
    case supervisorOwnedNoStart = 1
    case processStarted = 2
}

enum WindowsAuthorityCleanupState: UInt8, CaseIterable, Codable, Sendable {
    case none = 0
    case commitAmbiguousCleanup = 1
    case compensating = 2
    case cleanupFailed = 3
}

enum WindowsAuthoritySessionDisposition: UInt8, Codable, Sendable {
    case active = 0
    case invalidated = 1
}

enum WindowsAuthorityMutationOperation: UInt8, CaseIterable, Codable, Sendable {
    case bindVerifiedRejection = 1
    case commitAmbiguityTargetMutation = 2
    case authoritySessionInvalidationReconciliation = 3
    case syntheticMaintenanceReservation = 4
}

enum WindowsAuthorityTargetMembershipMode: String, Codable, Sendable {
    case requiredAffected
    case requiredUnaffectedAnchor
}

struct WindowsAuthorityMutationRegistrationV3: Hashable, Sendable {
    let operation: WindowsAuthorityMutationOperation
    let minimumUniverseRecordCount: Int
    let minimumAffectedRecordCount: Int
    let maximumAffectedRecordCount: Int
    let targetMembershipMode: WindowsAuthorityTargetMembershipMode
    let sessionDisposition: WindowsAuthoritySessionDisposition

    static let all: [Self] = [
        Self(
            operation: .bindVerifiedRejection,
            minimumUniverseRecordCount: 1,
            minimumAffectedRecordCount: 1,
            maximumAffectedRecordCount: 1,
            targetMembershipMode: .requiredAffected,
            sessionDisposition: .active
        ),
        Self(
            operation: .commitAmbiguityTargetMutation,
            minimumUniverseRecordCount: 1,
            minimumAffectedRecordCount: 1,
            maximumAffectedRecordCount: 1,
            targetMembershipMode: .requiredAffected,
            sessionDisposition: .active
        ),
        Self(
            operation: .authoritySessionInvalidationReconciliation,
            minimumUniverseRecordCount: 1,
            minimumAffectedRecordCount: 0,
            maximumAffectedRecordCount: 127,
            targetMembershipMode: .requiredUnaffectedAnchor,
            sessionDisposition: .invalidated
        ),
        Self(
            operation: .syntheticMaintenanceReservation,
            minimumUniverseRecordCount: 1,
            minimumAffectedRecordCount: 1,
            maximumAffectedRecordCount: 1,
            targetMembershipMode: .requiredAffected,
            sessionDisposition: .active
        ),
    ]

    static func registration(
        for operation: WindowsAuthorityMutationOperation
    ) -> Self {
        // The array is a closed versioned registry and every enum case appears
        // exactly once. Avoid a caller-extensible dictionary.
        switch operation {
        case .bindVerifiedRejection:
            return all[0]
        case .commitAmbiguityTargetMutation:
            return all[1]
        case .authoritySessionInvalidationReconciliation:
            return all[2]
        case .syntheticMaintenanceReservation:
            return all[3]
        }
    }
}

struct WindowsAuthorityRecordV3: Hashable, Sendable {
    static let projectionDomain = Data("FPAUTHREC3".utf8)

    let recordKeySHA256: WindowsExecutionSHA256
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let bindingAttemptSequence: UInt64
    let ownershipClass: WindowsAuthorityOwnershipClass
    var authorityState: WindowsAuthorityState
    var processOwnership: WindowsAuthorityProcessOwnership
    var cleanupState: WindowsAuthorityCleanupState

    init(
        recordKeySHA256: WindowsExecutionSHA256,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        bindingAttemptSequence: UInt64,
        ownershipClass: WindowsAuthorityOwnershipClass,
        authorityState: WindowsAuthorityState,
        processOwnership: WindowsAuthorityProcessOwnership,
        cleanupState: WindowsAuthorityCleanupState
    ) throws {
        guard !recordKeySHA256.isZero,
              !servicesInstanceID.isZero,
              bindingAttemptSequence != 0 else {
            throw WindowsAuthorityMutationError.invalidRecord(
                "record key, services instance, and binding attempt are nonzero"
            )
        }
        self.recordKeySHA256 = recordKeySHA256
        self.servicesInstanceID = servicesInstanceID
        self.bindingAttemptSequence = bindingAttemptSequence
        self.ownershipClass = ownershipClass
        self.authorityState = authorityState
        self.processOwnership = processOwnership
        self.cleanupState = cleanupState
        try validateCombination()
    }

    func validateCombination() throws {
        switch authorityState {
        case .prepared, .bound, .released, .invalidated:
            guard processOwnership == .none,
                  cleanupState == .none else {
                throw WindowsAuthorityMutationError.invalidRecord(
                    "\(authorityState) requires processOwnership none and cleanup none"
                )
            }
        case .activationPending:
            guard cleanupState == .none else {
                throw WindowsAuthorityMutationError.invalidRecord(
                    "activationPending has cleanup none"
                )
            }
        case .processCommitted:
            guard processOwnership != .none,
                  cleanupState == .none else {
                throw WindowsAuthorityMutationError.invalidRecord(
                    "processCommitted owns a process and has cleanup none"
                )
            }
        case .releasePending, .aborting:
            guard processOwnership == .none,
                  cleanupState == .compensating else {
                throw WindowsAuthorityMutationError.invalidRecord(
                    "\(authorityState) is process-free compensating state"
                )
            }
        case .processCleanupPending:
            guard processOwnership != .none,
                  cleanupState == .commitAmbiguousCleanup ||
                    cleanupState == .cleanupFailed else {
                throw WindowsAuthorityMutationError.invalidRecord(
                    "processCleanupPending retains process ownership and cleanup"
                )
            }
        }
    }

    func projectionPayload() -> Data {
        var data = Data(recordKeySHA256.bytes)
        data.append(authorityState.rawValue)
        data.append(ownershipClass.rawValue)
        data.append(processOwnership.rawValue)
        data.append(cleanupState.rawValue)
        WindowsExecutionBinaryCodec.appendUInt64(
            bindingAttemptSequence,
            to: &data
        )
        return data
    }

    var projectionSHA256: WindowsExecutionSHA256 {
        var data = Self.projectionDomain
        data.append(projectionPayload())
        return .hash(data)
    }
}

enum WindowsAuthorityRecordIdentityV3 {
    static let namespaceDomain = Data("FPAUTHNS2".utf8)
    static let recordKeyDomain = Data("FPAUTHKEY2".utf8)

    static func namespaceSHA256(
        preparedSessionBootstrapSHA256: WindowsExecutionSHA256,
        prefixScopeSHA256: WindowsExecutionSHA256
    ) -> WindowsExecutionSHA256 {
        var data = namespaceDomain
        data.append(contentsOf: preparedSessionBootstrapSHA256.bytes)
        data.append(contentsOf: prefixScopeSHA256.bytes)
        return .hash(data)
    }

    static func recordKeySHA256(
        namespaceSHA256: WindowsExecutionSHA256,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        bindingAttemptSequence: UInt64
    ) throws -> WindowsExecutionSHA256 {
        guard !namespaceSHA256.isZero,
              !servicesInstanceID.isZero,
              bindingAttemptSequence != 0 else {
            throw WindowsAuthorityMutationError.invalidRecord(
                "record-key sources are validated and nonzero"
            )
        }
        var data = recordKeyDomain
        data.append(contentsOf: namespaceSHA256.bytes)
        data.append(contentsOf: servicesInstanceID.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(
            bindingAttemptSequence,
            to: &data
        )
        return .hash(data)
    }
}

struct WindowsAuthorityCanonicalSetV3: Hashable, Sendable {
    static let domain = Data("FPAUTHSET3".utf8)
    static let maximumRecordCount = 128

    let records: [WindowsAuthorityRecordV3]

    init(records: [WindowsAuthorityRecordV3]) throws {
        guard records.count <= Self.maximumRecordCount else {
            throw WindowsAuthorityMutationError.resourceOverflow(
                "canonical set exceeds 128 records"
            )
        }
        let sorted = records.sorted {
            $0.recordKeySHA256 < $1.recordKeySHA256
        }
        guard Set(sorted.map(\.recordKeySHA256)).count == sorted.count else {
            throw WindowsAuthorityMutationError.duplicateRecordKey
        }
        self.records = sorted
    }

    func payload() -> Data {
        var data = Data()
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(records.count),
            to: &data
        )
        for record in records {
            data.append(contentsOf: record.recordKeySHA256.bytes)
            data.append(contentsOf: record.projectionSHA256.bytes)
        }
        return data
    }

    var sha256: WindowsExecutionSHA256 {
        var data = Self.domain
        data.append(payload())
        return .hash(data)
    }
}

struct WindowsAuthorityMutationDescriptorV3: Hashable, Sendable {
    static let version: UInt16 = 3
    static let domain = Data("FPAUTHMUT3".utf8)
    static let minimumPayloadBytes = 246
    static let maximumPayloadBytes = 4_342

    let operation: WindowsAuthorityMutationOperation
    let sessionDisposition: WindowsAuthoritySessionDisposition
    let mutationEventSequence: UInt64
    let targetBindingAttemptSequence: UInt64
    let targetRecordKeySHA256: WindowsExecutionSHA256
    let affectedRecordKeySHA256s: [WindowsExecutionSHA256]
    let targetRecordBeforeSHA256: WindowsExecutionSHA256
    let targetRecordAfterSHA256: WindowsExecutionSHA256
    let unaffectedSetBeforeSHA256: WindowsExecutionSHA256
    let unaffectedSetAfterSHA256: WindowsExecutionSHA256
    let registryBeforeSHA256: WindowsExecutionSHA256
    let registryAfterSHA256: WindowsExecutionSHA256

    init(
        operation: WindowsAuthorityMutationOperation,
        sessionDisposition: WindowsAuthoritySessionDisposition,
        mutationEventSequence: UInt64,
        targetBindingAttemptSequence: UInt64,
        targetRecordKeySHA256: WindowsExecutionSHA256,
        affectedRecordKeySHA256s: [WindowsExecutionSHA256],
        targetRecordBeforeSHA256: WindowsExecutionSHA256,
        targetRecordAfterSHA256: WindowsExecutionSHA256,
        unaffectedSetBeforeSHA256: WindowsExecutionSHA256,
        unaffectedSetAfterSHA256: WindowsExecutionSHA256,
        registryBeforeSHA256: WindowsExecutionSHA256,
        registryAfterSHA256: WindowsExecutionSHA256
    ) throws {
        let registration = WindowsAuthorityMutationRegistrationV3.registration(
            for: operation
        )
        let sorted = affectedRecordKeySHA256s.sorted()
        guard mutationEventSequence != 0,
              targetBindingAttemptSequence != 0,
              !targetRecordKeySHA256.isZero,
              sorted == affectedRecordKeySHA256s,
              Set(sorted).count == sorted.count,
              sorted.count >= registration.minimumAffectedRecordCount,
              sorted.count <= registration.maximumAffectedRecordCount else {
            throw WindowsAuthorityMutationError.invalidDescriptor(
                "descriptor sequence, key order, or cardinality is invalid"
            )
        }
        switch registration.targetMembershipMode {
        case .requiredAffected:
            guard sorted.contains(targetRecordKeySHA256) else {
                throw WindowsAuthorityMutationError.invalidDescriptor(
                    "required affected target is absent"
                )
            }
        case .requiredUnaffectedAnchor:
            guard !sorted.contains(targetRecordKeySHA256),
                  targetRecordBeforeSHA256.isAuthenticatedEqual(
                      to: targetRecordAfterSHA256
                  ) else {
                throw WindowsAuthorityMutationError.invalidDescriptor(
                    "required unaffected target is changed or affected"
                )
            }
        }
        self.operation = operation
        self.sessionDisposition = sessionDisposition
        self.mutationEventSequence = mutationEventSequence
        self.targetBindingAttemptSequence = targetBindingAttemptSequence
        self.targetRecordKeySHA256 = targetRecordKeySHA256
        self.affectedRecordKeySHA256s = sorted
        self.targetRecordBeforeSHA256 = targetRecordBeforeSHA256
        self.targetRecordAfterSHA256 = targetRecordAfterSHA256
        self.unaffectedSetBeforeSHA256 = unaffectedSetBeforeSHA256
        self.unaffectedSetAfterSHA256 = unaffectedSetAfterSHA256
        self.registryBeforeSHA256 = registryBeforeSHA256
        self.registryAfterSHA256 = registryAfterSHA256
    }

    func payload() -> Data {
        var data = Data()
        WindowsExecutionBinaryCodec.appendUInt16(Self.version, to: &data)
        data.append(operation.rawValue)
        data.append(sessionDisposition.rawValue)
        WindowsExecutionBinaryCodec.appendUInt64(
            mutationEventSequence,
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt64(
            targetBindingAttemptSequence,
            to: &data
        )
        data.append(contentsOf: targetRecordKeySHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(affectedRecordKeySHA256s.count),
            to: &data
        )
        for key in affectedRecordKeySHA256s {
            data.append(contentsOf: key.bytes)
        }
        data.append(contentsOf: targetRecordBeforeSHA256.bytes)
        data.append(contentsOf: targetRecordAfterSHA256.bytes)
        data.append(contentsOf: unaffectedSetBeforeSHA256.bytes)
        data.append(contentsOf: unaffectedSetAfterSHA256.bytes)
        data.append(contentsOf: registryBeforeSHA256.bytes)
        data.append(contentsOf: registryAfterSHA256.bytes)
        return data
    }

    var sha256: WindowsExecutionSHA256 {
        var data = Self.domain
        data.append(payload())
        return .hash(data)
    }

    static func decode(_ data: Data) throws -> Self {
        guard (minimumPayloadBytes...maximumPayloadBytes).contains(data.count) else {
            throw WindowsAuthorityMutationError.invalidDescriptor(
                "mutation descriptor length is outside its bound"
            )
        }
        var reader = WindowsExecutionByteReader(data)
        guard try reader.readUInt16() == version,
              let operation = WindowsAuthorityMutationOperation(
                  rawValue: try reader.readUInt8()
              ),
              let disposition = WindowsAuthoritySessionDisposition(
                  rawValue: try reader.readUInt8()
              ) else {
            throw WindowsAuthorityMutationError.invalidDescriptor(
                "mutation descriptor version or code is unknown"
            )
        }
        let eventSequence = try reader.readUInt64()
        let bindingSequence = try reader.readUInt64()
        let targetKey = try WindowsExecutionSHA256(
            bytes: reader.readBytes(count: 32)
        )
        let affectedCount = Int(try reader.readUInt16())
        let expectedLength = minimumPayloadBytes.addingReportingOverflow(
            affectedCount * WindowsExecutionSHA256.byteCount
        )
        guard !expectedLength.overflow,
              expectedLength.partialValue == data.count else {
            throw WindowsAuthorityMutationError.invalidDescriptor(
                "affected count does not match exact descriptor length"
            )
        }
        var affected: [WindowsExecutionSHA256] = []
        affected.reserveCapacity(affectedCount)
        for _ in 0..<affectedCount {
            affected.append(
                try WindowsExecutionSHA256(
                    bytes: reader.readBytes(count: 32)
                )
            )
        }
        let value = try Self(
            operation: operation,
            sessionDisposition: disposition,
            mutationEventSequence: eventSequence,
            targetBindingAttemptSequence: bindingSequence,
            targetRecordKeySHA256: targetKey,
            affectedRecordKeySHA256s: affected,
            targetRecordBeforeSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            targetRecordAfterSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            unaffectedSetBeforeSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            unaffectedSetAfterSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            registryBeforeSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            ),
            registryAfterSHA256: WindowsExecutionSHA256(
                bytes: reader.readBytes(count: 32)
            )
        )
        try reader.requireEnd()
        return value
    }
}

enum WindowsAuthorityMutationInjection: Hashable, Sendable {
    case none
    case attemptedUnlistedWrite(recordKeySHA256: WindowsExecutionSHA256)
    case postStateProofFailure
}

struct WindowsAuthorityMutationResultV3: Hashable, Sendable {
    let descriptor: WindowsAuthorityMutationDescriptorV3
    let orderedTargetStates: [WindowsAuthorityState]
    let ephemeralProofBytes: Int
    let registryPassCount: Int
}

enum WindowsAuthorityMutationError: LocalizedError, Equatable, Sendable {
    case invalidRecord(String)
    case duplicateRecordKey
    case missingTarget
    case invalidOperationPrecondition(String)
    case invalidDescriptor(String)
    case attemptedUnlistedWrite
    case proofMismatch
    case resourceOverflow(String)
    case mutationEventSequenceExhausted
    case sessionInvalidated

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let detail):
            return "invalid authority record: \(detail)"
        case .duplicateRecordKey:
            return "duplicate authority record key"
        case .missingTarget:
            return "authority mutation target is missing"
        case .invalidOperationPrecondition(let detail):
            return "authority mutation precondition failed: \(detail)"
        case .invalidDescriptor(let detail):
            return "authority mutation descriptor is invalid: \(detail)"
        case .attemptedUnlistedWrite:
            return "authority transaction attempted an unlisted semantic write"
        case .proofMismatch:
            return "authority mutation proof did not preserve its unaffected set"
        case .resourceOverflow(let detail):
            return "authority mutation resource overflow: \(detail)"
        case .mutationEventSequenceExhausted:
            return "authority mutation event sequence exhausted"
        case .sessionInvalidated:
            return "authority session is invalidated"
        }
    }
}

final class WindowsAuthorityMutationScopeV3: @unchecked Sendable {
    static let maximumAuthorityRecords = 128
    static let maximumEphemeralProofBytes = 32_768

    private struct Storage {
        var records: [WindowsExecutionSHA256: WindowsAuthorityRecordV3] = [:]
        var nextMutationEventSequence: UInt64 = 1
        var sessionDisposition = WindowsAuthoritySessionDisposition.active
    }

    private let lock = NSLock()
    private var storage = Storage()

    func insert(_ record: WindowsAuthorityRecordV3) throws {
        try lock.withLock {
            guard storage.sessionDisposition == .active else {
                throw WindowsAuthorityMutationError.sessionInvalidated
            }
            guard storage.records.count < Self.maximumAuthorityRecords else {
                throw WindowsAuthorityMutationError.resourceOverflow(
                    "record universe is already at 128"
                )
            }
            guard storage.records[record.recordKeySHA256] == nil else {
                throw WindowsAuthorityMutationError.duplicateRecordKey
            }
            storage.records[record.recordKeySHA256] = record
        }
    }

    func record(
        for key: WindowsExecutionSHA256
    ) -> WindowsAuthorityRecordV3? {
        lock.withLock { storage.records[key] }
    }

    var recordsInCanonicalOrder: [WindowsAuthorityRecordV3] {
        lock.withLock {
            storage.records.values.sorted {
                $0.recordKeySHA256 < $1.recordKeySHA256
            }
        }
    }

    var nextMutationEventSequence: UInt64 {
        lock.withLock { storage.nextMutationEventSequence }
    }

    var sessionDisposition: WindowsAuthoritySessionDisposition {
        lock.withLock { storage.sessionDisposition }
    }

    /// Applies only a retained-base state-machine transition. These transitions
    /// remain protected by the complete base lifecycle/resource suites and do
    /// not create an AuthorityMutationScopeV3 descriptor.
    func applyRetainedBaseTransition(
        recordKeySHA256: WindowsExecutionSHA256,
        expectedState: WindowsAuthorityState,
        newState: WindowsAuthorityState,
        processOwnership: WindowsAuthorityProcessOwnership,
        cleanupState: WindowsAuthorityCleanupState
    ) throws {
        try lock.withLock {
            guard storage.sessionDisposition == .active else {
                throw WindowsAuthorityMutationError.sessionInvalidated
            }
            guard var record = storage.records[recordKeySHA256] else {
                throw WindowsAuthorityMutationError.missingTarget
            }
            guard record.authorityState == expectedState,
                  Self.isRetainedBaseTransition(
                      from: expectedState,
                      to: newState
                  ) else {
                throw WindowsAuthorityMutationError
                    .invalidOperationPrecondition(
                        "retained-base transition is not admitted"
                    )
            }
            record.authorityState = newState
            record.processOwnership = processOwnership
            record.cleanupState = cleanupState
            try record.validateCombination()
            storage.records[recordKeySHA256] = record
        }
    }

    func invalidateProcessFreeRecords() throws {
        try lock.withLock {
            guard storage.sessionDisposition == .active else { return }
            for key in storage.records.keys {
                guard var record = storage.records[key] else { continue }
                switch (
                    record.authorityState,
                    record.processOwnership
                ) {
                case (.prepared, .none),
                     (.bound, .none),
                     (.activationPending, .none),
                     (.aborting, .none),
                     (.releasePending, .none):
                    record.authorityState = .invalidated
                    record.processOwnership = .none
                    record.cleanupState = .none
                    try record.validateCombination()
                    storage.records[key] = record
                default:
                    continue
                }
            }
            storage.sessionDisposition = .invalidated
        }
    }

    func setNextMutationEventSequenceForBoundaryTest(_ value: UInt64) throws {
        try lock.withLock {
            guard value != 0 else {
                throw WindowsAuthorityMutationError.invalidDescriptor(
                    "next mutation event sequence cannot be zero"
                )
            }
            storage.nextMutationEventSequence = value
        }
    }

    func execute(
        operation: WindowsAuthorityMutationOperation,
        targetRecordKeySHA256: WindowsExecutionSHA256,
        injection: WindowsAuthorityMutationInjection = .none
    ) throws -> WindowsAuthorityMutationResultV3 {
        try lock.withLock {
            guard storage.sessionDisposition == .active else {
                throw WindowsAuthorityMutationError.sessionInvalidated
            }
            let registration =
                WindowsAuthorityMutationRegistrationV3.registration(
                    for: operation
                )
            guard storage.records.count >=
                    registration.minimumUniverseRecordCount,
                  storage.records.count <= Self.maximumAuthorityRecords,
                  let targetBefore =
                    storage.records[targetRecordKeySHA256] else {
                throw WindowsAuthorityMutationError.missingTarget
            }

            // Reservation is intentionally after operation/target preconditions
            // and before the registry-before snapshot.
            try validatePrecondition(operation, target: targetBefore)
            guard storage.nextMutationEventSequence != UInt64.max else {
                storage.sessionDisposition = .invalidated
                throw WindowsAuthorityMutationError
                    .mutationEventSequenceExhausted
            }
            let reservedEventSequence =
                storage.nextMutationEventSequence
            storage.nextMutationEventSequence += 1

            let before = storage.records
            let registryBefore = try canonicalSet(before.values).sha256
            var candidate = before
            var orderedTargetStates: [WindowsAuthorityState] = [
                targetBefore.authorityState
            ]

            switch operation {
            case .bindVerifiedRejection:
                var target = targetBefore
                orderedTargetStates.append(.releasePending)
                target.authorityState = .released
                target.processOwnership = .none
                target.cleanupState = .none
                try target.validateCombination()
                candidate[targetRecordKeySHA256] = target
                orderedTargetStates.append(.released)
            case .commitAmbiguityTargetMutation:
                var target = targetBefore
                target.authorityState = .processCleanupPending
                target.cleanupState = .commitAmbiguousCleanup
                try target.validateCombination()
                candidate[targetRecordKeySHA256] = target
                orderedTargetStates.append(.processCleanupPending)
            case .authoritySessionInvalidationReconciliation:
                for key in candidate.keys where key != targetRecordKeySHA256 {
                    guard var record = candidate[key] else { continue }
                    switch (
                        record.authorityState,
                        record.processOwnership,
                        record.cleanupState
                    ) {
                    case (.prepared, .none, .none),
                         (.bound, .none, .none),
                         (.activationPending, .none, .none):
                        record.authorityState = .invalidated
                        record.cleanupState = .none
                    case (.aborting, .none, .compensating),
                         (.releasePending, .none, .compensating):
                        record.authorityState = .invalidated
                        record.cleanupState = .none
                    case (.activationPending, .supervisorOwnedNoStart, .none),
                         (.activationPending, .processStarted, .none),
                         (.processCommitted, .supervisorOwnedNoStart, .none),
                         (.processCommitted, .processStarted, .none):
                        record.authorityState = .processCleanupPending
                        record.cleanupState = .commitAmbiguousCleanup
                    default:
                        continue
                    }
                    try record.validateCombination()
                    candidate[key] = record
                }
                orderedTargetStates.append(targetBefore.authorityState)
            case .syntheticMaintenanceReservation:
                var target = targetBefore
                target.authorityState = .activationPending
                target.processOwnership = .none
                target.cleanupState = .none
                try target.validateCombination()
                candidate[targetRecordKeySHA256] = target
                orderedTargetStates.append(.activationPending)
            }

            let affected = candidate.keys.filter {
                guard let old = before[$0], let new = candidate[$0] else {
                    return true
                }
                return old.projectionSHA256 != new.projectionSHA256
            }.sorted()

            if case let .attemptedUnlistedWrite(key) = injection {
                guard !affected.contains(key), var record = candidate[key] else {
                    throw WindowsAuthorityMutationError.attemptedUnlistedWrite
                }
                record.cleanupState = .cleanupFailed
                candidate[key] = record
            }

            let targetAfter = candidate[targetRecordKeySHA256] ?? targetBefore
            let unaffectedKeys = Set(before.keys).subtracting(affected)
            let unaffectedBefore = try canonicalSet(
                unaffectedKeys.compactMap { before[$0] }
            )
            let unaffectedAfter = try canonicalSet(
                unaffectedKeys.compactMap { candidate[$0] }
            )
            let registryAfter = try canonicalSet(candidate.values).sha256

            let exactAffectedAfterInjection = candidate.keys.filter {
                before[$0]?.projectionSHA256 != candidate[$0]?.projectionSHA256
            }.sorted()
            guard exactAffectedAfterInjection == affected,
                  unaffectedBefore.sha256.isAuthenticatedEqual(
                      to: unaffectedAfter.sha256
                  ),
                  injection != .postStateProofFailure else {
                throw WindowsAuthorityMutationError.proofMismatch
            }

            guard affected.count >=
                    registration.minimumAffectedRecordCount,
                  affected.count <=
                    registration.maximumAffectedRecordCount else {
                throw WindowsAuthorityMutationError.invalidDescriptor(
                    "operation affected cardinality differs from registration"
                )
            }
            switch registration.targetMembershipMode {
            case .requiredAffected:
                guard affected == [targetRecordKeySHA256] else {
                    throw WindowsAuthorityMutationError.invalidDescriptor(
                        "operation did not affect only its target"
                    )
                }
            case .requiredUnaffectedAnchor:
                guard !affected.contains(targetRecordKeySHA256),
                      targetBefore.projectionSHA256 ==
                        targetAfter.projectionSHA256 else {
                    throw WindowsAuthorityMutationError.invalidDescriptor(
                        "reconciliation changed its required anchor"
                    )
                }
            }

            let descriptor = try WindowsAuthorityMutationDescriptorV3(
                operation: operation,
                sessionDisposition: registration.sessionDisposition,
                mutationEventSequence: reservedEventSequence,
                targetBindingAttemptSequence:
                    targetBefore.bindingAttemptSequence,
                targetRecordKeySHA256: targetRecordKeySHA256,
                affectedRecordKeySHA256s: affected,
                targetRecordBeforeSHA256: targetBefore.projectionSHA256,
                targetRecordAfterSHA256: targetAfter.projectionSHA256,
                unaffectedSetBeforeSHA256: unaffectedBefore.sha256,
                unaffectedSetAfterSHA256: unaffectedAfter.sha256,
                registryBeforeSHA256: registryBefore,
                registryAfterSHA256: registryAfter
            )
            let reparsed = try WindowsAuthorityMutationDescriptorV3.decode(
                descriptor.payload()
            )
            guard reparsed == descriptor else {
                throw WindowsAuthorityMutationError.proofMismatch
            }

            let universeCount = before.count
            let affectedCount = affected.count
            let ephemeralBytes =
                (2 + universeCount * 64) +
                (2 + affectedCount * 32) +
                universeCount * 44 +
                universeCount * 44 +
                descriptor.payload().count +
                1_024
            guard ephemeralBytes <= Self.maximumEphemeralProofBytes else {
                throw WindowsAuthorityMutationError.resourceOverflow(
                    "ephemeral proof exceeds 32768 bytes"
                )
            }
            storage.records = candidate
            if registration.sessionDisposition == .invalidated {
                storage.sessionDisposition = .invalidated
            }
            return WindowsAuthorityMutationResultV3(
                descriptor: descriptor,
                orderedTargetStates: orderedTargetStates,
                ephemeralProofBytes: ephemeralBytes,
                registryPassCount: 2
            )
        }
    }

    private func validatePrecondition(
        _ operation: WindowsAuthorityMutationOperation,
        target: WindowsAuthorityRecordV3
    ) throws {
        switch operation {
        case .bindVerifiedRejection:
            guard target.authorityState == .prepared,
                  target.processOwnership == .none,
                  target.cleanupState == .none else {
                throw WindowsAuthorityMutationError.invalidOperationPrecondition(
                    "BIND rejection target is exact prepared process-free record"
                )
            }
        case .commitAmbiguityTargetMutation:
            guard target.authorityState == .activationPending ||
                    target.authorityState == .processCommitted,
                  target.processOwnership != .none,
                  target.cleanupState == .none else {
                throw WindowsAuthorityMutationError.invalidOperationPrecondition(
                    "COMMIT ambiguity target owns exact process state"
                )
            }
        case .authoritySessionInvalidationReconciliation:
            guard target.authorityState == .processCleanupPending,
                  target.processOwnership != .none,
                  target.cleanupState == .commitAmbiguousCleanup else {
                throw WindowsAuthorityMutationError.invalidOperationPrecondition(
                    "reconciliation target is unchanged cleanup anchor"
                )
            }
        case .syntheticMaintenanceReservation:
            guard target.authorityState == .bound,
                  target.processOwnership == .none,
                  target.cleanupState == .none else {
                throw WindowsAuthorityMutationError.invalidOperationPrecondition(
                    "synthetic maintenance target is exact bound record"
                )
            }
        }
    }

    private static func isRetainedBaseTransition(
        from: WindowsAuthorityState,
        to: WindowsAuthorityState
    ) -> Bool {
        switch (from, to) {
        case (.prepared, .bound),
             (.prepared, .releasePending),
             (.releasePending, .released),
             (.bound, .activationPending),
             (.activationPending, .processCommitted),
             (.activationPending, .aborting),
             (.aborting, .released),
             (.bound, .releasePending),
             (.processCommitted, .releasePending),
             (.processCleanupPending, .releasePending):
            return true
        default:
            return false
        }
    }

    private func canonicalSet<S: Sequence>(
        _ values: S
    ) throws -> WindowsAuthorityCanonicalSetV3
        where S.Element == WindowsAuthorityRecordV3 {
        try WindowsAuthorityCanonicalSetV3(records: Array(values))
    }
}

// MARK: - Descriptor-free bounded stream framing

struct WindowsExecutionAuthorityFrame: Hashable, Sendable {
    let header: WindowsExecutionAuthorityHeaderV1
    let payload: Data

    init(
        header: WindowsExecutionAuthorityHeaderV1,
        payload: Data
    ) throws {
        guard payload.count == Int(header.payloadBytes) else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .authority,
                detail: "authority payload length differs from its header"
            )
        }
        self.header = header
        self.payload = payload
    }

    func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }
}

final class WindowsExecutionAuthorityStreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var expectedFrameBytes: Int?
    private var failed = false

    func ingest(
        _ bytes: Data,
        ancillaryDataPresent: Bool,
        messageControlTruncated: Bool
    ) throws -> WindowsExecutionAuthorityFrame? {
        try lock.withLock {
            guard !failed else {
                throw streamError("authority stream decoder is terminal")
            }
            guard !ancillaryDataPresent, !messageControlTruncated else {
                failed = true
                buffer.removeAll(keepingCapacity: false)
                throw streamError(
                    "authority stream carried ancillary data or MSG_CTRUNC"
                )
            }
            let newCount = buffer.count.addingReportingOverflow(bytes.count)
            guard !newCount.overflow,
                  newCount.partialValue <=
                    WindowsExecutionAuthorityHeaderV1.maximumFrameBytes else {
                failed = true
                buffer.removeAll(keepingCapacity: false)
                throw streamError("authority frame exceeds 65600 bytes")
            }
            buffer.append(bytes)
            if expectedFrameBytes == nil,
               buffer.count >= WindowsExecutionAuthorityHeaderV1.byteCount {
                let headerData = Data(
                    buffer.prefix(
                        WindowsExecutionAuthorityHeaderV1.byteCount
                    )
                )
                let header = try WindowsExecutionAuthorityHeaderV1.decode(
                    headerData
                )
                expectedFrameBytes =
                    WindowsExecutionAuthorityHeaderV1.byteCount +
                    Int(header.payloadBytes)
            }
            guard let expectedFrameBytes,
                  buffer.count >= expectedFrameBytes else {
                return nil
            }
            guard buffer.count == expectedFrameBytes else {
                failed = true
                buffer.removeAll(keepingCapacity: false)
                throw streamError("authority stream supplied trailing frame bytes")
            }
            let header = try WindowsExecutionAuthorityHeaderV1.decode(
                Data(buffer.prefix(WindowsExecutionAuthorityHeaderV1.byteCount))
            )
            let payload = Data(
                buffer.dropFirst(WindowsExecutionAuthorityHeaderV1.byteCount)
            )
            buffer.removeAll(keepingCapacity: false)
            self.expectedFrameBytes = nil
            return try WindowsExecutionAuthorityFrame(
                header: header,
                payload: payload
            )
        }
    }

    func signalEOF() throws {
        try lock.withLock {
            guard buffer.isEmpty, expectedFrameBytes == nil else {
                failed = true
                buffer.removeAll(keepingCapacity: false)
                throw streamError("EOF arrived before a complete authority frame")
            }
        }
    }

    private func streamError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .bridgeProtocolInvalid,
            stage: .authority,
            detail: detail
        )
    }
}

final class WindowsExecutionAuthorityEndpointPair: @unchecked Sendable {
    let hostDescriptor: Int32
    let runtimeDescriptor: Int32

    private let lock = NSLock()
    private var closed = false

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw WindowsExecutionContractError(
                reason: .bridgeAuthorityUnavailable,
                stage: .authority,
                detail: "AF_UNIX SOCK_STREAM socketpair creation failed"
            )
        }
        hostDescriptor = descriptors[0]
        runtimeDescriptor = descriptors[1]
        guard fcntl(hostDescriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(runtimeDescriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(hostDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(hostDescriptor)
            Darwin.close(runtimeDescriptor)
            throw WindowsExecutionContractError(
                reason: .bridgeAuthorityUnavailable,
                stage: .authority,
                detail: "authority endpoint flag configuration failed"
            )
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(hostDescriptor)
            Darwin.close(runtimeDescriptor)
        }
    }

    deinit {
        close()
    }
}

// MARK: - Handshake and retained-base lease actor

struct WindowsExecutionRegistryPayloadV1: Hashable, Sendable {
    let runtimeFingerprintSHA256: WindowsExecutionSHA256
    let rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256
    let projection: WindowsRendererNeutralEnvironmentProjection

    func encoded() -> Data {
        var data = Data([1])
        data.append(contentsOf: [UInt8](repeating: 0, count: 7))
        data.append(contentsOf: runtimeFingerprintSHA256.bytes)
        data.append(contentsOf: rendererCapabilityFingerprintSHA256.bytes)
        data.append(contentsOf: projection.catalog.catalogSHA256.bytes)
        data.append(contentsOf: projection.baseProjectionSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(projection.catalog.entries.count),
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt16(
            UInt16(projection.entries.count),
            to: &data
        )
        for entry in projection.catalog.entries {
            data.append(entry.encoded())
        }
        for entry in projection.entries {
            data.append(entry.encoded())
        }
        return data
    }
}

struct WindowsExecutionAuthorityErrorPayloadV1: Hashable, Sendable {
    let reasonCode: UInt16
    let offendingMessageType: WindowsExecutionAuthorityMessageType
    let detailCode: UInt32

    func encoded() -> Data {
        var data = Data()
        WindowsExecutionBinaryCodec.appendUInt16(reasonCode, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(
            offendingMessageType.rawValue,
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt32(detailCode, to: &data)
        WindowsExecutionBinaryCodec.appendUInt64(0, to: &data)
        return data
    }
}

enum WindowsExecutionAuthorityHandshakeOutcome: Sendable {
    case silentClose
    case error(WindowsExecutionAuthorityFrame)
    case registry(
        frame: WindowsExecutionAuthorityFrame,
        authoritySessionIdentitySHA256: WindowsExecutionSHA256
    )
}

struct WindowsServicesRecipientAssociationProof: Hashable, Sendable {
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let prefixScopeSHA256: WindowsExecutionSHA256
    let preparedSessionBootstrapSHA256: WindowsExecutionSHA256
    let listenerGeneration: UInt64
    let wineserverBootIdentity: WindowsExecutionSHA256
    let currentSystemProcessValidated: Bool
    let listenerAndPipeIdentityValidated: Bool

    init(
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        prefixScopeSHA256: WindowsExecutionSHA256,
        preparedSessionBootstrapSHA256: WindowsExecutionSHA256,
        listenerGeneration: UInt64,
        wineserverBootIdentity: WindowsExecutionSHA256,
        currentSystemProcessValidated: Bool,
        listenerAndPipeIdentityValidated: Bool
    ) throws {
        guard !servicesInstanceID.isZero,
              !prefixScopeSHA256.isZero,
              !preparedSessionBootstrapSHA256.isZero,
              listenerGeneration != 0,
              !wineserverBootIdentity.isZero,
              currentSystemProcessValidated,
              listenerAndPipeIdentityValidated else {
            throw WindowsExecutionContractError(
                reason: .bridgeCallerLineageInvalid,
                stage: .authority,
                detail: "services recipient association proof is incomplete"
            )
        }
        self.servicesInstanceID = servicesInstanceID
        self.prefixScopeSHA256 = prefixScopeSHA256
        self.preparedSessionBootstrapSHA256 =
            preparedSessionBootstrapSHA256
        self.listenerGeneration = listenerGeneration
        self.wineserverBootIdentity = wineserverBootIdentity
        self.currentSystemProcessValidated = currentSystemProcessValidated
        self.listenerAndPipeIdentityValidated =
            listenerAndPipeIdentityValidated
    }
}

struct WindowsServicesRecipientRegistration: Hashable, Sendable {
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let registrationGeneration: UInt64
    let listenerGeneration: UInt64
    let wineserverBootIdentity: WindowsExecutionSHA256
    let authoritySessionIdentitySHA256: WindowsExecutionSHA256
}

struct WindowsAuthorityAcquireRequestV1: Hashable, Sendable {
    let requestID: WindowsExecutionAuthorityIdentifier
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let serviceIdentityDigestSHA256: WindowsExecutionSHA256
    let serviceCreationNonce: WindowsExecutionSHA256
    let configGeneration: UInt64
    let bindingAttemptSequence: UInt64
    let servicePersistence: WindowsServicePersistence
    let admissionProjectionSHA256: WindowsExecutionSHA256
    let runtimeBindingFactsSHA256: WindowsExecutionSHA256
    let existingServiceRebind: Bool

    func payload() -> Data {
        var data = Data(serviceIdentityDigestSHA256.bytes)
        data.append(contentsOf: serviceCreationNonce.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(configGeneration, to: &data)
        WindowsExecutionBinaryCodec.appendUInt64(
            bindingAttemptSequence,
            to: &data
        )
        data.append(servicePersistence.rawValue)
        data.append(contentsOf: [UInt8](repeating: 0, count: 7))
        data.append(contentsOf: admissionProjectionSHA256.bytes)
        data.append(contentsOf: runtimeBindingFactsSHA256.bytes)
        return data
    }
}

struct WindowsAuthorityAcquireResponseV1: Hashable, Sendable {
    let leaseID: WindowsExecutionSHA256
    let authorityBindingRecordSHA256: WindowsExecutionSHA256
    let expirationMonotonicNanoseconds: UInt64
    let configGeneration: UInt64
    let serviceCreationNonce: WindowsExecutionSHA256

    func payload() -> Data {
        var data = Data(leaseID.bytes)
        data.append(contentsOf: authorityBindingRecordSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(
            expirationMonotonicNanoseconds,
            to: &data
        )
        WindowsExecutionBinaryCodec.appendUInt64(configGeneration, to: &data)
        data.append(contentsOf: serviceCreationNonce.bytes)
        return data
    }
}

struct WindowsAuthorityLeaseV1: Hashable, Sendable {
    let leaseID: WindowsExecutionSHA256
    let recordKeySHA256: WindowsExecutionSHA256
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let runtimeBindingFactsSHA256: WindowsExecutionSHA256
    let authorityBindingRecordSHA256: WindowsExecutionSHA256
    let serviceIdentityDigestSHA256: WindowsExecutionSHA256
    let serviceCreationNonce: WindowsExecutionSHA256
    let configGeneration: UInt64
    let bindingAttemptSequence: UInt64
    let expirationMonotonicNanoseconds: UInt64
    let ownershipClass: WindowsAuthorityOwnershipClass
    let existingServiceRebind: Bool
}

enum WindowsAuthorityEvidenceKind: UInt16, Codable, Sendable {
    case bindingRecommitted = 1
    case persistentServicePreserved = 2
}

enum WindowsExecutionAuthorityState: Hashable, Sendable {
    case awaitingHello
    case registryAwaitingCollection(
        requestID: WindowsExecutionAuthorityIdentifier,
        frameSHA256: WindowsExecutionSHA256
    )
    case ready
    case invalidated
}

actor WindowsExecutionCapabilityAuthority {
    static let maximumRequests = 4_096
    static let maximumServicesInstances = 16
    static let maximumPreparedOrBoundLeases = 64
    static let maximumEvidenceJournalRecords = 128
    static let exactRuntimeResponseCapacity = 65_600
    static let leaseLifetimeNanoseconds: UInt64 = 5_000_000_000

    let bootstrap: WindowsPreparedSessionBootstrapV2
    let providerRegistry: WindowsExecutionProviderRegistry
    let rendererSnapshot: WindowsRendererCapabilitySnapshotV1
    let neutralEnvironmentProjection:
        WindowsRendererNeutralEnvironmentProjection
    let rendererNeutralBaseEnvironment: [String: String]
    let registryBinding: WindowsRendererRegistryBinding
    let mutationScope: WindowsAuthorityMutationScopeV3

    private(set) var state = WindowsExecutionAuthorityState.awaitingHello
    private(set) var authoritySessionIdentitySHA256: WindowsExecutionSHA256?
    private var requestIDs = Set<WindowsExecutionAuthorityIdentifier>()
    private var registrations:
        [WindowsExecutionAuthorityIdentifier: WindowsServicesRecipientRegistration] = [:]
    private var leases: [WindowsExecutionSHA256: WindowsAuthorityLeaseV1] = [:]
    private var ambiguousCommitLeaseIDs = Set<WindowsExecutionSHA256>()
    private var evidenceJournal = Set<String>()
    private var nextRegistrationGeneration: UInt64 = 1

    init(
        records: WindowsExecutionValidatedCapabilityRecords,
        providerRegistry: WindowsExecutionProviderRegistry,
        neutralEnvironmentProjection:
            WindowsRendererNeutralEnvironmentProjection,
        rendererNeutralBaseEnvironment: [String: String]
    ) throws {
        try providerRegistry.validateFrozenFingerprint()
        let binding = WindowsRendererRegistryBinding(
            snapshot: records.rendererSnapshot,
            projection: neutralEnvironmentProjection
        )
        guard binding.authenticate(
            snapshot: records.rendererSnapshot,
            projection: neutralEnvironmentProjection
        ),
        try WindowsRendererNeutralEnvironmentProjection.capture(
            catalog: neutralEnvironmentProjection.catalog,
            environment: rendererNeutralBaseEnvironment
        ).baseProjectionSHA256.isAuthenticatedEqual(
            to: neutralEnvironmentProjection.baseProjectionSHA256
        ) else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .authority,
                detail: "REGISTRY renderer/catalog/base binding failed"
            )
        }
        bootstrap = records.bootstrap
        self.providerRegistry = providerRegistry
        rendererSnapshot = records.rendererSnapshot
        self.neutralEnvironmentProjection = neutralEnvironmentProjection
        self.rendererNeutralBaseEnvironment = rendererNeutralBaseEnvironment
        registryBinding = binding
        mutationScope = WindowsAuthorityMutationScopeV3()
    }

    func acceptHello(
        headerData: Data,
        payloadData: Data,
        ancillaryDataPresent: Bool = false,
        messageControlTruncated: Bool = false
    ) -> WindowsExecutionAuthorityHandshakeOutcome {
        guard state == .awaitingHello,
              !ancillaryDataPresent,
              !messageControlTruncated else {
            state = .invalidated
            return .silentClose
        }
        switch WindowsExecutionAuthorityHeaderV1.admitHello(headerData) {
        case .silentClose:
            state = .invalidated
            return .silentClose
        case .trustedSemanticRejection(let requestID):
            state = .invalidated
            guard let frame = helloErrorFrame(
                requestID: requestID,
                reason: .bridgeProtocolInvalid,
                detailCode: 1
            ) else {
                return .silentClose
            }
            return .error(frame)
        case .trusted(let header):
            guard payloadData.count == Int(header.payloadBytes) else {
                state = .invalidated
                return .silentClose
            }
            do {
                try reserveRequestID(header.requestID)
                let hello = try WindowsExecutionHelloPayloadV1
                    .decodeStructurally(payloadData)
                let identity = try hello.authenticate(
                    expectedBootstrap: bootstrap,
                    expectedRegistry: providerRegistry
                )
                let payload = WindowsExecutionRegistryPayloadV1(
                    runtimeFingerprintSHA256:
                        bootstrap.runtimeFingerprintSHA256,
                    rendererCapabilityFingerprintSHA256:
                        rendererSnapshot.recordSHA256,
                    projection: neutralEnvironmentProjection
                ).encoded()
                let responseHeader = try WindowsExecutionAuthorityHeaderV1(
                    messageType: .registry,
                    flags: [.isResponse, .neutralBaseProjection],
                    payloadBytes: UInt32(payload.count),
                    requestID: header.requestID,
                    servicesInstanceID: .zero
                )
                let frame = try WindowsExecutionAuthorityFrame(
                    header: responseHeader,
                    payload: payload
                )
                authoritySessionIdentitySHA256 = identity
                state = .registryAwaitingCollection(
                    requestID: header.requestID,
                    frameSHA256: .hash(frame.encoded())
                )
                return .registry(
                    frame: frame,
                    authoritySessionIdentitySHA256: identity
                )
            } catch let error as WindowsExecutionContractError {
                state = .invalidated
                guard let frame = helloErrorFrame(
                    requestID: header.requestID,
                    reason: error.reason,
                    detailCode: 2
                ) else {
                    return .silentClose
                }
                return .error(frame)
            } catch {
                state = .invalidated
                guard let frame = helloErrorFrame(
                    requestID: header.requestID,
                    reason: .bridgeProtocolInvalid,
                    detailCode: 3
                ) else {
                    return .silentClose
                }
                return .error(frame)
            }
        }
    }

    func confirmRegistryCollected(
        requestID: WindowsExecutionAuthorityIdentifier,
        responseCapacity: Int,
        collectedFrameSHA256: WindowsExecutionSHA256
    ) throws {
        guard case let .registryAwaitingCollection(
            expectedRequestID,
            expectedFrameSHA256
        ) = state,
        responseCapacity == Self.exactRuntimeResponseCapacity,
        requestID == expectedRequestID,
        collectedFrameSHA256.isAuthenticatedEqual(
            to: expectedFrameSHA256
        ) else {
            state = .invalidated
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .authority,
                detail: "REGISTRY readiness collection is not exact"
            )
        }
        state = .ready
    }

    func registerServicesRecipient(
        _ proof: WindowsServicesRecipientAssociationProof
    ) throws -> WindowsServicesRecipientRegistration {
        try requireReady()
        guard registrations.count < Self.maximumServicesInstances,
              registrations[proof.servicesInstanceID] == nil,
              proof.prefixScopeSHA256.isAuthenticatedEqual(
                  to: bootstrap.prefixScopeSHA256
              ),
              proof.preparedSessionBootstrapSHA256.isAuthenticatedEqual(
                  to: bootstrap.sha256
              ),
              let authoritySessionIdentitySHA256,
              nextRegistrationGeneration != UInt64.max else {
            throw WindowsExecutionContractError(
                reason: .bridgeCallerLineageInvalid,
                stage: .authority,
                detail: "services recipient association is stale, replayed, or full"
            )
        }
        let registration = WindowsServicesRecipientRegistration(
            servicesInstanceID: proof.servicesInstanceID,
            registrationGeneration: nextRegistrationGeneration,
            listenerGeneration: proof.listenerGeneration,
            wineserverBootIdentity: proof.wineserverBootIdentity,
            authoritySessionIdentitySHA256:
                authoritySessionIdentitySHA256
        )
        nextRegistrationGeneration += 1
        registrations[proof.servicesInstanceID] = registration
        return registration
    }

    func acquire(
        _ request: WindowsAuthorityAcquireRequestV1,
        nowMonotonicNanoseconds: UInt64
    ) throws -> WindowsAuthorityAcquireResponseV1 {
        try requireReady()
        try reserveRequestID(request.requestID)
        guard registrations[request.servicesInstanceID] != nil,
              request.payload().count == 152,
              !request.serviceIdentityDigestSHA256.isZero,
              !request.serviceCreationNonce.isZero,
              request.configGeneration != 0,
              request.bindingAttemptSequence != 0,
              request.servicePersistence != .notApplicable,
              !request.admissionProjectionSHA256.isZero,
              !request.runtimeBindingFactsSHA256.isZero,
              leases.values.filter({
                  mutationScope.record(for: $0.recordKeySHA256)
                    .map {
                        $0.authorityState == .prepared ||
                            $0.authorityState == .bound
                    } ?? false
              }).count < Self.maximumPreparedOrBoundLeases else {
            throw WindowsExecutionContractError(
                reason: .bridgeAuthorityUnavailable,
                stage: .authority,
                detail: "ACQUIRE fields, association, or resource bound failed"
            )
        }
        let namespace = WindowsAuthorityRecordIdentityV3.namespaceSHA256(
            preparedSessionBootstrapSHA256: bootstrap.sha256,
            prefixScopeSHA256: bootstrap.prefixScopeSHA256
        )
        let recordKey = try WindowsAuthorityRecordIdentityV3.recordKeySHA256(
            namespaceSHA256: namespace,
            servicesInstanceID: request.servicesInstanceID,
            bindingAttemptSequence: request.bindingAttemptSequence
        )
        guard mutationScope.record(for: recordKey) == nil else {
            throw WindowsExecutionContractError(
                reason: .bridgeGenerationMismatch,
                stage: .authority,
                detail: "bindingAttemptSequence is reused"
            )
        }
        let expiration = nowMonotonicNanoseconds.addingReportingOverflow(
            Self.leaseLifetimeNanoseconds
        )
        guard !expiration.overflow else {
            throw WindowsExecutionContractError(
                reason: .bridgeGenerationMismatch,
                stage: .authority,
                detail: "lease expiration arithmetic overflowed"
            )
        }
        let leaseID = try randomNonzeroSHA256()
        let authorityDigest = authorityBindingRecordSHA256(
            runtimeBindingFactsSHA256: request.runtimeBindingFactsSHA256,
            leaseID: leaseID,
            expirationMonotonicNanoseconds: expiration.partialValue,
            requestID: request.requestID,
            servicesInstanceID: request.servicesInstanceID,
            configGeneration: request.configGeneration,
            bindingAttemptSequence: request.bindingAttemptSequence
        )
        let ownership: WindowsAuthorityOwnershipClass =
            request.servicePersistence == .sessionTransient
                ? .sessionTransient
                : .guestPersistent
        let record = try WindowsAuthorityRecordV3(
            recordKeySHA256: recordKey,
            servicesInstanceID: request.servicesInstanceID,
            bindingAttemptSequence: request.bindingAttemptSequence,
            ownershipClass: ownership,
            authorityState: .prepared,
            processOwnership: .none,
            cleanupState: .none
        )
        try mutationScope.insert(record)
        leases[leaseID] = WindowsAuthorityLeaseV1(
            leaseID: leaseID,
            recordKeySHA256: recordKey,
            servicesInstanceID: request.servicesInstanceID,
            runtimeBindingFactsSHA256: request.runtimeBindingFactsSHA256,
            authorityBindingRecordSHA256: authorityDigest,
            serviceIdentityDigestSHA256:
                request.serviceIdentityDigestSHA256,
            serviceCreationNonce: request.serviceCreationNonce,
            configGeneration: request.configGeneration,
            bindingAttemptSequence: request.bindingAttemptSequence,
            expirationMonotonicNanoseconds: expiration.partialValue,
            ownershipClass: ownership,
            existingServiceRebind: request.existingServiceRebind
        )
        return WindowsAuthorityAcquireResponseV1(
            leaseID: leaseID,
            authorityBindingRecordSHA256: authorityDigest,
            expirationMonotonicNanoseconds: expiration.partialValue,
            configGeneration: request.configGeneration,
            serviceCreationNonce: request.serviceCreationNonce
        )
    }

    func bind(
        leaseID: WindowsExecutionSHA256,
        requestID: WindowsExecutionAuthorityIdentifier,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        runtimeBindingFactsSHA256: WindowsExecutionSHA256,
        authorityBindingRecordSHA256: WindowsExecutionSHA256,
        configGeneration: UInt64,
        bindingAttemptSequence: UInt64,
        nowMonotonicNanoseconds: UInt64
    ) throws {
        try requireReady()
        try reserveRequestID(requestID)
        let lease = try exactLease(
            leaseID: leaseID,
            servicesInstanceID: servicesInstanceID,
            runtimeBindingFactsSHA256: runtimeBindingFactsSHA256,
            authorityBindingRecordSHA256: authorityBindingRecordSHA256,
            configGeneration: configGeneration,
            bindingAttemptSequence: bindingAttemptSequence
        )
        guard nowMonotonicNanoseconds <
                lease.expirationMonotonicNanoseconds else {
            throw WindowsExecutionContractError(
                reason: .lifecycleDeadlineExceeded,
                stage: .authority,
                detail: "prepared lease expired before BIND"
            )
        }
        try mutationScope.applyRetainedBaseTransition(
            recordKeySHA256: lease.recordKeySHA256,
            expectedState: .prepared,
            newState: .bound,
            processOwnership: .none,
            cleanupState: .none
        )
    }

    func rejectVerifiedBind(
        leaseID: WindowsExecutionSHA256
    ) throws -> WindowsAuthorityMutationResultV3 {
        try requireReady()
        guard let lease = leases[leaseID] else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingMissing,
                stage: .authority,
                detail: "verified BIND rejection has no prepared lease"
            )
        }
        return try mutationScope.execute(
            operation: .bindVerifiedRejection,
            targetRecordKeySHA256: lease.recordKeySHA256
        )
    }

    func activate(
        leaseID: WindowsExecutionSHA256,
        processOwnership: WindowsAuthorityProcessOwnership
    ) throws -> WindowsRendererEnvironmentClone {
        try requireReady()
        guard processOwnership != .none,
              let lease = leases[leaseID] else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingMissing,
                stage: .authority,
                detail: "ACTIVATE requires one exact bound process owner"
            )
        }
        try mutationScope.applyRetainedBaseTransition(
            recordKeySHA256: lease.recordKeySHA256,
            expectedState: .bound,
            newState: .activationPending,
            processOwnership: processOwnership,
            cleanupState: .none
        )
        return try neutralEnvironmentProjection
            .applying(to: rendererNeutralBaseEnvironment)
    }

    func commit(leaseID: WindowsExecutionSHA256) throws {
        try requireReady()
        guard let lease = leases[leaseID],
              let record = mutationScope.record(
                  for: lease.recordKeySHA256
              ),
              record.processOwnership != .none else {
            throw WindowsExecutionContractError(
                reason: .lifecycleProcessIdentityMismatch,
                stage: .authority,
                detail: "COMMIT has no exact prepared-session process join"
            )
        }
        try mutationScope.applyRetainedBaseTransition(
            recordKeySHA256: lease.recordKeySHA256,
            expectedState: .activationPending,
            newState: .processCommitted,
            processOwnership: record.processOwnership,
            cleanupState: .none
        )
    }

    func beginCommitAmbiguity(
        leaseID: WindowsExecutionSHA256
    ) throws -> WindowsAuthorityMutationResultV3 {
        try requireReady()
        guard let lease = leases[leaseID] else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingMissing,
                stage: .authority,
                detail: "COMMIT ambiguity has no correlated lease"
            )
        }
        let result = try mutationScope.execute(
            operation: .commitAmbiguityTargetMutation,
            targetRecordKeySHA256: lease.recordKeySHA256
        )
        ambiguousCommitLeaseIDs.insert(leaseID)
        return result
    }

    func beginVerifiedCommitRejection(
        leaseID: WindowsExecutionSHA256
    ) throws -> WindowsAuthorityMutationResultV3 {
        try requireReady()
        guard let lease = leases[leaseID] else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingMissing,
                stage: .authority,
                detail: "verified COMMIT rejection has no correlated lease"
            )
        }
        return try mutationScope.execute(
            operation: .commitAmbiguityTargetMutation,
            targetRecordKeySHA256: lease.recordKeySHA256
        )
    }

    func reconcileCommitAmbiguity(
        leaseID: WindowsExecutionSHA256
    ) throws -> WindowsAuthorityMutationResultV3 {
        try requireReady()
        guard let lease = leases[leaseID] else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingMissing,
                stage: .authority,
                detail: "COMMIT reconciliation has no correlated lease"
            )
        }
        let result = try mutationScope.execute(
            operation: .authoritySessionInvalidationReconciliation,
            targetRecordKeySHA256: lease.recordKeySHA256
        )
        ambiguousCommitLeaseIDs.remove(leaseID)
        state = .invalidated
        return result
    }

    func release(leaseID: WindowsExecutionSHA256) throws {
        try requireReady()
        guard let lease = leases[leaseID],
              let record = mutationScope.record(
                  for: lease.recordKeySHA256
              ),
              record.authorityState == .bound ||
                record.authorityState == .processCommitted ||
                (
                    record.authorityState == .processCleanupPending &&
                    !ambiguousCommitLeaseIDs.contains(leaseID)
                ) else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingMissing,
                stage: .authority,
                detail: "RELEASE has no releasable exact lease"
            )
        }
        try mutationScope.applyRetainedBaseTransition(
            recordKeySHA256: lease.recordKeySHA256,
            expectedState: record.authorityState,
            newState: .releasePending,
            processOwnership: .none,
            cleanupState: .compensating
        )
        try mutationScope.applyRetainedBaseTransition(
            recordKeySHA256: lease.recordKeySHA256,
            expectedState: .releasePending,
            newState: .released,
            processOwnership: .none,
            cleanupState: .none
        )
    }

    func acknowledgeEvidence(
        kind: WindowsAuthorityEvidenceKind,
        leaseID: WindowsExecutionSHA256
    ) throws {
        try requireReady()
        guard evidenceJournal.count < Self.maximumEvidenceJournalRecords,
              let lease = leases[leaseID],
              let record = mutationScope.record(for: lease.recordKeySHA256) else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .evidence,
                detail: "evidence has no exact retained lease"
            )
        }
        switch kind {
        case .bindingRecommitted:
            guard lease.existingServiceRebind,
                  record.authorityState == .bound else {
                throw WindowsExecutionContractError(
                    reason: .lifecycleEvidenceInvalid,
                    stage: .evidence,
                    detail: "bindingRecommitted is not valid for this lease"
                )
            }
        case .persistentServicePreserved:
            guard lease.ownershipClass == .guestPersistent,
                  record.authorityState == .released else {
                throw WindowsExecutionContractError(
                    reason: .lifecycleEvidenceInvalid,
                    stage: .evidence,
                    detail: "persistent preservation requires released persistent lease"
                )
            }
        }
        let key = "\(kind.rawValue):\(leaseID.hexadecimal)"
        guard evidenceJournal.insert(key).inserted else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .evidence,
                detail: "evidence acknowledgement is replayed"
            )
        }
    }

    func disconnectProcessFree() throws {
        try mutationScope.invalidateProcessFreeRecords()
        state = .invalidated
    }

    var liveLeaseCount: Int {
        leases.values.filter {
            guard let record = mutationScope.record(for: $0.recordKeySHA256) else {
                return false
            }
            return record.authorityState != .released &&
                record.authorityState != .invalidated
        }.count
    }

    var evidenceJournalCount: Int {
        evidenceJournal.count
    }

    private func requireReady() throws {
        guard state == .ready else {
            throw WindowsExecutionContractError(
                reason: .bridgeAuthorityUnavailable,
                stage: .authority,
                detail: "authority REGISTRY has not been exactly collected"
            )
        }
    }

    private func reserveRequestID(
        _ requestID: WindowsExecutionAuthorityIdentifier
    ) throws {
        guard requestIDs.count < Self.maximumRequests,
              requestIDs.insert(requestID).inserted else {
            throw WindowsExecutionContractError(
                reason: .bridgeProtocolInvalid,
                stage: .authority,
                detail: "request ID is replayed or request bound is exhausted"
            )
        }
    }

    private func exactLease(
        leaseID: WindowsExecutionSHA256,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        runtimeBindingFactsSHA256: WindowsExecutionSHA256,
        authorityBindingRecordSHA256: WindowsExecutionSHA256,
        configGeneration: UInt64,
        bindingAttemptSequence: UInt64
    ) throws -> WindowsAuthorityLeaseV1 {
        guard let lease = leases[leaseID],
              lease.servicesInstanceID == servicesInstanceID,
              lease.runtimeBindingFactsSHA256.isAuthenticatedEqual(
                  to: runtimeBindingFactsSHA256
              ),
              lease.authorityBindingRecordSHA256.isAuthenticatedEqual(
                  to: authorityBindingRecordSHA256
              ),
              lease.configGeneration == configGeneration,
              lease.bindingAttemptSequence == bindingAttemptSequence else {
            throw WindowsExecutionContractError(
                reason: .serviceBindingCommitFailed,
                stage: .authority,
                detail: "lease digest pair, generation, or association differs"
            )
        }
        return lease
    }

    private func authorityBindingRecordSHA256(
        runtimeBindingFactsSHA256: WindowsExecutionSHA256,
        leaseID: WindowsExecutionSHA256,
        expirationMonotonicNanoseconds: UInt64,
        requestID: WindowsExecutionAuthorityIdentifier,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        configGeneration: UInt64,
        bindingAttemptSequence: UInt64
    ) -> WindowsExecutionSHA256 {
        var data = Data("FPBINDH1".utf8)
        data.append(contentsOf: runtimeBindingFactsSHA256.bytes)
        data.append(contentsOf: leaseID.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(
            expirationMonotonicNanoseconds,
            to: &data
        )
        data.append(contentsOf: requestID.bytes)
        data.append(contentsOf: servicesInstanceID.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(configGeneration, to: &data)
        WindowsExecutionBinaryCodec.appendUInt64(
            bindingAttemptSequence,
            to: &data
        )
        return .hash(data)
    }

    private func randomNonzeroSHA256() throws -> WindowsExecutionSHA256 {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4 {
            let value = try WindowsExecutionSHA256(
                bytes: (0..<WindowsExecutionSHA256.byteCount).map { _ in
                    UInt8.random(in: .min ... .max, using: &generator)
                }
            )
            if !value.isZero {
                return value
            }
        }
        throw WindowsExecutionContractError(
            reason: .bridgeAuthorityUnavailable,
            stage: .authority,
            detail: "cryptographic lease ID generation failed"
        )
    }

    private func helloErrorFrame(
        requestID: WindowsExecutionAuthorityIdentifier,
        reason: WindowsExecutionReasonCode,
        detailCode: UInt32
    ) -> WindowsExecutionAuthorityFrame? {
        let payload = WindowsExecutionAuthorityErrorPayloadV1(
            reasonCode: UInt16(truncatingIfNeeded: reason.rawValue),
            offendingMessageType: .hello,
            detailCode: detailCode
        ).encoded()
        // All arguments are bounded protocol constants and an already
        // structurally validated nonzero request ID.
        return try? WindowsExecutionAuthorityFrame(
                header: WindowsExecutionAuthorityHeaderV1(
                    messageType: .error,
                    flags: [.isResponse, .rejected],
                    payloadBytes: UInt32(payload.count),
                    requestID: requestID,
                    servicesInstanceID: .zero
                ),
                payload: payload
            )
    }
}
