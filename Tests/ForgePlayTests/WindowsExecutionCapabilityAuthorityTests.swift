import Foundation
import XCTest
@testable import ForgePlay

final class WindowsExecutionCapabilityAuthorityTests: XCTestCase {
    func testBindRejectionMutatesOnlyTargetAndCarriesBindingAttemptSequence()
        throws {
        let scope = WindowsAuthorityMutationScopeV3()
        let target = try makeRecord(index: 1, bindingAttemptSequence: 41)
        let unaffected = try makeRecord(index: 2, bindingAttemptSequence: 42)
        try scope.insert(target)
        try scope.insert(unaffected)

        let result = try scope.execute(
            operation: .bindVerifiedRejection,
            targetRecordKeySHA256: target.recordKeySHA256
        )

        XCTAssertEqual(result.descriptor.mutationEventSequence, 1)
        XCTAssertEqual(
            result.descriptor.targetBindingAttemptSequence,
            target.bindingAttemptSequence
        )
        XCTAssertEqual(
            result.descriptor.affectedRecordKeySHA256s,
            [target.recordKeySHA256]
        )
        XCTAssertEqual(
            scope.record(for: target.recordKeySHA256)?.authorityState,
            .released
        )
        XCTAssertEqual(
            scope.record(for: unaffected.recordKeySHA256),
            unaffected
        )
        XCTAssertEqual(
            try WindowsAuthorityMutationDescriptorV3.decode(
                result.descriptor.payload()
            ),
            result.descriptor
        )
    }

    func testFailedProofConsumesSequenceButDoesNotCommitState() throws {
        let scope = WindowsAuthorityMutationScopeV3()
        let target = try makeRecord(
            index: 1,
            bindingAttemptSequence: 1,
            state: .bound
        )
        try scope.insert(target)

        XCTAssertThrowsError(
            try scope.execute(
                operation: .syntheticMaintenanceReservation,
                targetRecordKeySHA256: target.recordKeySHA256,
                injection: .postStateProofFailure
            )
        )
        XCTAssertEqual(scope.nextMutationEventSequence, 2)
        XCTAssertEqual(
            scope.record(for: target.recordKeySHA256),
            target
        )

        let committed = try scope.execute(
            operation: .syntheticMaintenanceReservation,
            targetRecordKeySHA256: target.recordKeySHA256
        )
        XCTAssertEqual(committed.descriptor.mutationEventSequence, 2)
    }

    func testSequenceExhaustionInvalidatesBeforeSecondSnapshot() throws {
        let scope = WindowsAuthorityMutationScopeV3()
        let first = try makeRecord(
            index: 1,
            bindingAttemptSequence: 1,
            state: .bound
        )
        let second = try makeRecord(
            index: 2,
            bindingAttemptSequence: 2,
            state: .bound
        )
        try scope.insert(first)
        try scope.insert(second)
        try scope.setNextMutationEventSequenceForBoundaryTest(
            UInt64.max - 1
        )

        let finalReservable = try scope.execute(
            operation: .syntheticMaintenanceReservation,
            targetRecordKeySHA256: first.recordKeySHA256
        )
        XCTAssertEqual(
            finalReservable.descriptor.mutationEventSequence,
            UInt64.max - 1
        )
        XCTAssertThrowsError(
            try scope.execute(
                operation: .syntheticMaintenanceReservation,
                targetRecordKeySHA256: second.recordKeySHA256
            )
        ) { error in
            XCTAssertEqual(
                error as? WindowsAuthorityMutationError,
                .mutationEventSequenceExhausted
            )
        }
        XCTAssertEqual(scope.sessionDisposition, .invalidated)
        XCTAssertEqual(scope.record(for: second.recordKeySHA256), second)
    }

    func testReconciliationKeepsTargetAsUnaffectedAnchor() throws {
        let scope = WindowsAuthorityMutationScopeV3()
        let target = try makeRecord(
            index: 1,
            bindingAttemptSequence: 7,
            state: .processCleanupPending,
            processOwnership: .processStarted,
            cleanupState: .commitAmbiguousCleanup
        )
        let prepared = try makeRecord(
            index: 2,
            bindingAttemptSequence: 8
        )
        try scope.insert(target)
        try scope.insert(prepared)

        let result = try scope.execute(
            operation: .authoritySessionInvalidationReconciliation,
            targetRecordKeySHA256: target.recordKeySHA256
        )

        XCTAssertFalse(
            result.descriptor.affectedRecordKeySHA256s.contains(
                target.recordKeySHA256
            )
        )
        XCTAssertEqual(
            result.descriptor.targetRecordBeforeSHA256,
            result.descriptor.targetRecordAfterSHA256
        )
        XCTAssertEqual(
            scope.record(for: prepared.recordKeySHA256)?.authorityState,
            .invalidated
        )
        XCTAssertEqual(scope.sessionDisposition, .invalidated)
    }

    func testDescriptorRejectsWrongVersionAndTrailingBytes() throws {
        let scope = WindowsAuthorityMutationScopeV3()
        let target = try makeRecord(
            index: 1,
            bindingAttemptSequence: 1,
            state: .bound
        )
        try scope.insert(target)
        let result = try scope.execute(
            operation: .syntheticMaintenanceReservation,
            targetRecordKeySHA256: target.recordKeySHA256
        )
        var wrongVersion = result.descriptor.payload()
        wrongVersion[0] = 2
        XCTAssertThrowsError(
            try WindowsAuthorityMutationDescriptorV3.decode(wrongVersion)
        )
        XCTAssertThrowsError(
            try WindowsAuthorityMutationDescriptorV3.decode(
                result.descriptor.payload() + Data([0])
            )
        )
    }

    private func makeRecord(
        index: UInt8,
        bindingAttemptSequence: UInt64,
        state: WindowsAuthorityState = .prepared,
        processOwnership: WindowsAuthorityProcessOwnership = .none,
        cleanupState: WindowsAuthorityCleanupState = .none
    ) throws -> WindowsAuthorityRecordV3 {
        let servicesInstanceID = try WindowsExecutionAuthorityIdentifier(
            bytes: [UInt8](repeating: index, count: 16)
        )
        let namespace = WindowsAuthorityRecordIdentityV3.namespaceSHA256(
            preparedSessionBootstrapSHA256: digest("bootstrap"),
            prefixScopeSHA256: digest("prefix")
        )
        let key = try WindowsAuthorityRecordIdentityV3.recordKeySHA256(
            namespaceSHA256: namespace,
            servicesInstanceID: servicesInstanceID,
            bindingAttemptSequence: bindingAttemptSequence
        )
        return try WindowsAuthorityRecordV3(
            recordKeySHA256: key,
            servicesInstanceID: servicesInstanceID,
            bindingAttemptSequence: bindingAttemptSequence,
            ownershipClass: .sessionTransient,
            authorityState: state,
            processOwnership: processOwnership,
            cleanupState: cleanupState
        )
    }

    private func digest(_ value: String) -> WindowsExecutionSHA256 {
        .hash(Data(value.utf8))
    }
}
