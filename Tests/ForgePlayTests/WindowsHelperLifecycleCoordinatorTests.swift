import Foundation
import XCTest
@testable import ForgePlay

final class WindowsHelperLifecycleCoordinatorTests: XCTestCase {
    func testTransientCleanupRequiresAtomicZeroResourceEvidence() async throws {
        let fixture = try makeFixture(
            executionMode: .maintenance,
            rendererRequirement: .forbidden,
            lifecycleKind: .oneShot,
            servicePersistence: .notApplicable
        )
        let coordinator = try WindowsHelperLifecycleCoordinator(
            bootstrap: fixture.bootstrap,
            profile: fixture.profile,
            authority: fixture.authority,
            prefixLease: fixture.lease,
            processSupervisor: fixture.supervisor,
            cleanupDeadlineMonotonicNanoseconds: 1_000
        )

        try await coordinator.prepare(monotonicNanoseconds: 10)
        try await coordinator.bindLaunch(
            admissionProjectionSHA256: digest("admission"),
            monotonicNanoseconds: 20
        )
        try await coordinator.beginCleanup(monotonicNanoseconds: 30)
        let finalization = try WindowsHelperRuntimeEvidenceV1(
            eventCode: .transientResourcesAtomicallyFinalized,
            sourceSequence: 1,
            monotonicNanoseconds: 40,
            resourceObservation: WindowsHelperResourceObservationV1(),
            atomicFinalizationCommitted: true
        )
        try await coordinator.recordRuntimeEvidence(finalization)
        try await coordinator.completeCleanup(monotonicNanoseconds: 50)
        try await coordinator.close(monotonicNanoseconds: 60)

        let state = await coordinator.state
        let codes = await coordinator.events.map(\.eventCode)
        XCTAssertEqual(state, .closed)
        XCTAssertEqual(
            codes,
            [
                .sessionPrepared,
                .launchBound,
                .cleanupStarted,
                .transientResourcesAtomicallyFinalized,
                .cleanupCompleted,
                .sessionClosed,
            ]
        )
        XCTAssertTrue(fixture.lease.isReleased)
        let disconnectCount = await fixture.authority.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testPersistentCleanupRequiresPreservationEvidence() async throws {
        let fixture = try makeFixture(
            executionMode: .maintenance,
            rendererRequirement: .forbidden,
            lifecycleKind: .windowsService,
            servicePersistence: .guestPersistent
        )
        let coordinator = try WindowsHelperLifecycleCoordinator(
            bootstrap: fixture.bootstrap,
            profile: fixture.profile,
            authority: fixture.authority,
            prefixLease: fixture.lease,
            processSupervisor: fixture.supervisor,
            cleanupDeadlineMonotonicNanoseconds: 1_000
        )
        try await coordinator.prepare(monotonicNanoseconds: 10)
        try await coordinator.bindLaunch(
            admissionProjectionSHA256: digest("admission"),
            monotonicNanoseconds: 20
        )
        try await coordinator.beginCleanup(monotonicNanoseconds: 30)
        let evidence = try WindowsHelperRuntimeEvidenceV1(
            eventCode: .persistentServicePreserved,
            sourceSequence: 1,
            monotonicNanoseconds: 40,
            serviceState: .running,
            servicesInstanceID: try authorityID(7),
            bindingAttemptSequence: 9,
            leaseID: digest("lease"),
            processIdentitySHA256: digest("process")
        )
        try await coordinator.recordRuntimeEvidence(evidence)
        try await coordinator.completeCleanup(monotonicNanoseconds: 50)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .cleanupCompleted)
    }

    func testCleanupAmbiguityForbidsSuccessAndRecordsFailure() async throws {
        let fixture = try makeFixture(
            executionMode: .maintenance,
            rendererRequirement: .forbidden,
            lifecycleKind: .oneShot,
            servicePersistence: .notApplicable
        )
        let coordinator = try WindowsHelperLifecycleCoordinator(
            bootstrap: fixture.bootstrap,
            profile: fixture.profile,
            authority: fixture.authority,
            prefixLease: fixture.lease,
            processSupervisor: fixture.supervisor,
            cleanupDeadlineMonotonicNanoseconds: 1_000
        )
        try await coordinator.prepare(monotonicNanoseconds: 10)
        try await coordinator.bindLaunch(
            admissionProjectionSHA256: digest("admission"),
            monotonicNanoseconds: 20
        )
        try await coordinator.beginCleanup(monotonicNanoseconds: 30)
        let finalization = try WindowsHelperRuntimeEvidenceV1(
            eventCode: .transientResourcesAtomicallyFinalized,
            sourceSequence: 1,
            monotonicNanoseconds: 40,
            atomicFinalizationCommitted: true
        )
        try await coordinator.recordRuntimeEvidence(finalization)
        let ambiguity = try WindowsHelperCleanupAmbiguityV1(
            reason: .serviceBindingCommitFailed,
            recordKeySHA256: digest("record"),
            mutationDescriptorSHA256: digest("mutation"),
            detailSHA256: digest("detail"),
            resolved: false
        )
        try await coordinator.recordCleanupAmbiguity(
            ambiguity,
            monotonicNanoseconds: 45
        )

        do {
            try await coordinator.completeCleanup(
                monotonicNanoseconds: 50
            )
            XCTFail("cleanup success must be forbidden")
        } catch {
            XCTAssertEqual(
                (error as? WindowsExecutionContractError)?.reason,
                .lifecycleEvidenceInvalid
            )
        }
        let finalState = await coordinator.state
        let finalEventCode = await coordinator.events.last?.eventCode
        XCTAssertEqual(finalState, .cleanupFailed)
        XCTAssertEqual(finalEventCode, .cleanupFailed)
    }

    func testRuntimeEvidenceSequenceMustBeContiguous() async throws {
        let fixture = try makeFixture(
            executionMode: .maintenance,
            rendererRequirement: .forbidden,
            lifecycleKind: .oneShot,
            servicePersistence: .notApplicable
        )
        let coordinator = try WindowsHelperLifecycleCoordinator(
            bootstrap: fixture.bootstrap,
            profile: fixture.profile,
            authority: fixture.authority,
            prefixLease: fixture.lease,
            processSupervisor: fixture.supervisor,
            cleanupDeadlineMonotonicNanoseconds: 1_000
        )
        try await coordinator.prepare(monotonicNanoseconds: 10)
        try await coordinator.bindLaunch(
            admissionProjectionSHA256: digest("admission"),
            monotonicNanoseconds: 20
        )
        let outOfOrder = try WindowsHelperRuntimeEvidenceV1(
            eventCode: .runtimePrepared,
            sourceSequence: 2,
            monotonicNanoseconds: 25
        )

        do {
            try await coordinator.recordRuntimeEvidence(outOfOrder)
            XCTFail("runtime source sequence gap must be rejected")
        } catch {
            XCTAssertEqual(
                (error as? WindowsExecutionContractError)?.reason,
                .lifecycleEvidenceInvalid
            )
        }
    }

    private struct Fixture {
        let bootstrap: WindowsPreparedSessionBootstrapV2
        let profile: WindowsPreparedHelperExecutionProfile
        let authority: TestAuthority
        let lease: TestPrefixLease
        let supervisor: TestProcessSupervisor
    }

    private func makeFixture(
        executionMode: WindowsExecutionMode,
        rendererRequirement: WindowsRendererRequirement,
        lifecycleKind: WindowsExecutionLifecycleKind,
        servicePersistence: WindowsServicePersistence
    ) throws -> Fixture {
        let capability = try WindowsExecutionCapabilityRequirement(
            identifierSHA256: digest("capability"),
            requiredMajor: 1,
            minimumMinor: 0
        )
        let requirements = [capability]
        let descriptor = try WindowsExecutionLaunchDescriptorV1(
            sequence: 1,
            createdMonotonicNanoseconds: 1,
            runID: WindowsExecutionRunID(
                canonicalString:
                    "00112233-4455-4677-8899-aabbccddeeff"
            ),
            sessionNonce: digest("nonce"),
            prefixScopeSHA256: digest("prefix"),
            runtimeFingerprintSHA256: digest("runtime"),
            rendererCapabilityFingerprintSHA256: digest("renderer"),
            requiredCapabilitySetFingerprintSHA256:
                WindowsExecutionCapabilityContract
                    .requiredCapabilitySetFingerprint(requirements),
            executionMode: executionMode,
            rendererRequirement: rendererRequirement,
            lifecycleKind: lifecycleKind,
            servicePersistence: servicePersistence,
            processDeadlineMilliseconds: 1_000,
            cleanupDeadlineMilliseconds: 1_000,
            requiredCapabilities: requirements
        )
        let bootstrap = try WindowsPreparedSessionBootstrapV2(
            sequence: descriptor.sequence,
            runID: descriptor.runID,
            sessionNonce: descriptor.sessionNonce,
            prefixScopeSHA256: descriptor.prefixScopeSHA256,
            runtimeFingerprintSHA256: descriptor.runtimeFingerprintSHA256,
            launchDescriptorRecordSHA256: descriptor.recordSHA256,
            rendererCapabilityFingerprintSHA256:
                descriptor.rendererCapabilityFingerprintSHA256
        )
        return Fixture(
            bootstrap: bootstrap,
            profile: try WindowsPreparedHelperExecutionProfile(
                descriptor: descriptor,
                bootstrap: bootstrap
            ),
            authority: TestAuthority(),
            lease: TestPrefixLease(
                scope: bootstrap.prefixScopeSHA256
            ),
            supervisor: TestProcessSupervisor()
        )
    }

    private func authorityID(_ value: UInt8) throws
        -> WindowsExecutionAuthorityIdentifier {
        try WindowsExecutionAuthorityIdentifier(
            bytes: [UInt8](repeating: value, count: 16)
        )
    }

    private func digest(_ value: String) -> WindowsExecutionSHA256 {
        .hash(Data(value.utf8))
    }
}

private actor TestAuthority:
    WindowsExecutionCapabilityAuthorityCoordinating {
    private(set) var disconnectCount = 0

    func disconnectProcessFree() throws {
        disconnectCount += 1
    }
}

private final class TestPrefixLease:
    WindowsHelperPrefixLeaseOwning,
    @unchecked Sendable {
    let windowsHelperLeaseScopeSHA256: WindowsExecutionSHA256

    private let lock = NSLock()
    private var released = false

    init(scope: WindowsExecutionSHA256) {
        windowsHelperLeaseScopeSHA256 = scope
    }

    func releaseWindowsHelperLease() async throws {
        lock.withLock {
            released = true
        }
    }

    var isReleased: Bool {
        lock.withLock { released }
    }
}

private actor TestProcessSupervisor: WindowsHelperProcessSupervising {
    private var stopped = false

    func requestWindowsHelperTermination() async throws {
        stopped = true
    }

    func waitForWindowsHelperTermination(
        deadlineMonotonicNanoseconds: UInt64
    ) async throws -> Bool {
        deadlineMonotonicNanoseconds != 0 && stopped
    }

    func windowsHelperTrackedProcessCount() async -> Int {
        stopped ? 0 : 1
    }
}
