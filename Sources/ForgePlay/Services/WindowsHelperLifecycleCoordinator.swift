// ForgePlay-authored clean-room output.
// Distribution remains blocked until explicit project license assignment.

import Foundation

enum WindowsHelperSessionState: UInt8, CaseIterable, Codable, Sendable {
    case idle = 0
    case negotiating = 1
    case exclusiveLeased = 2
    case prepared = 3
    case launchBound = 4
    case sharedActive = 5
    case quiescing = 6
    case exclusiveCleanup = 7
    case compensating = 8
    case cleanupCompleted = 9
    case cleanupFailed = 10
    case closed = 11
}

enum WindowsHelperServiceState: UInt8, CaseIterable, Codable, Sendable {
    case notApplicable = 0
    case createRequested = 1
    case registered = 2
    case bindingCommitted = 3
    case configured = 4
    case activationPending = 5
    case running = 6
    case stopPending = 7
    case stopped = 8
    case deletePending = 9
    case deleted = 10
}

enum WindowsHelperLifecycleEventProducer: UInt8, Codable, Sendable {
    case forgePlayHost = 1
    case windowsRuntime = 2
}

enum WindowsHelperLifecycleEventCode: UInt16, CaseIterable, Codable, Sendable {
    case sessionPrepared = 1
    case launchBound = 2
    case runtimePrepared = 3
    case runtimeLaunchStarted = 4
    case runtimeProcessCreated = 5
    case runtimeProcessCommitted = 6
    case runtimeActive = 7
    case runtimeQuiesced = 8
    case runtimeCleanupObserved = 9
    case cleanupStarted = 10
    case cleanupCompleted = 11
    case cleanupFailed = 12
    case sessionClosed = 13
    case bindingRecommitted = 14
    case persistentServicePreserved = 15
    case transientResourcesAtomicallyFinalized = 16

    var producer: WindowsHelperLifecycleEventProducer {
        switch self {
        case .sessionPrepared, .launchBound, .cleanupStarted,
             .cleanupCompleted, .cleanupFailed, .sessionClosed:
            return .forgePlayHost
        case .runtimePrepared, .runtimeLaunchStarted, .runtimeProcessCreated,
             .runtimeProcessCommitted, .runtimeActive, .runtimeQuiesced,
             .runtimeCleanupObserved, .bindingRecommitted,
             .persistentServicePreserved,
             .transientResourcesAtomicallyFinalized:
            return .windowsRuntime
        }
    }
}

struct WindowsHelperResourceObservationV1: Hashable, Sendable {
    var terminalDescriptors: UInt32 = 0
    var readinessRequests: UInt32 = 0
    var authorityRequests: UInt32 = 0
    var requestInternalSynchronizers: UInt32 = 0
    var originCancellationLatches: UInt32 = 0
    var imageStages: UInt32 = 0
    var parentProcessAliases: UInt32 = 0
    var childProcessAliases: UInt32 = 0
    var loaderTransfers: UInt32 = 0
    var processHistories: UInt32 = 0
    var pendingRuntimeEventRecords: UInt32 = 0
    var authorityLeases: UInt32 = 0
    var originHandles: UInt32 = 0
    var attachmentReferences: UInt32 = 0
    var bindingHandles: UInt32 = 0
    var bindingObjects: UInt32 = 0
    var activationReservationHandles: UInt32 = 0
    var activationReservationObjects: UInt32 = 0
    var activationThreadSlots: UInt32 = 0
    var armedThreadLocalSlots: UInt32 = 0
    var environmentClones: UInt32 = 0
    var journalSlots: UInt32 = 0
    var prefixExecutionLeases: UInt32 = 0
    var processSupervisors: UInt32 = 0
    var cleanupDeadlines: UInt32 = 0
    var authorityEndpoints: UInt32 = 0
    var lifecycleEvidenceEndpoints: UInt32 = 0
    var launchDescriptorDescriptors: UInt32 = 0
    var rendererSnapshotDescriptors: UInt32 = 0
    var processTasks: UInt32 = 0
    var pendingCleanupOperations: UInt32 = 0

    var isZero: Bool {
        canonicalCounts.allSatisfy { $0 == 0 }
    }

    var canonicalSHA256: WindowsExecutionSHA256 {
        var data = Data("FPRESOBS1".utf8)
        for count in canonicalCounts {
            WindowsExecutionBinaryCodec.appendUInt32(count, to: &data)
        }
        return .hash(data)
    }

    private var canonicalCounts: [UInt32] {
        [
            terminalDescriptors,
            readinessRequests,
            authorityRequests,
            requestInternalSynchronizers,
            originCancellationLatches,
            imageStages,
            parentProcessAliases,
            childProcessAliases,
            loaderTransfers,
            processHistories,
            pendingRuntimeEventRecords,
            authorityLeases,
            originHandles,
            attachmentReferences,
            bindingHandles,
            bindingObjects,
            activationReservationHandles,
            activationReservationObjects,
            activationThreadSlots,
            armedThreadLocalSlots,
            environmentClones,
            journalSlots,
            prefixExecutionLeases,
            processSupervisors,
            cleanupDeadlines,
            authorityEndpoints,
            lifecycleEvidenceEndpoints,
            launchDescriptorDescriptors,
            rendererSnapshotDescriptors,
            processTasks,
            pendingCleanupOperations,
        ]
    }
}

struct WindowsHelperRuntimeEvidenceV1: Hashable, Sendable {
    let eventCode: WindowsHelperLifecycleEventCode
    let sourceSequence: UInt64
    let monotonicNanoseconds: UInt64
    let serviceState: WindowsHelperServiceState
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let bindingAttemptSequence: UInt64
    let leaseID: WindowsExecutionSHA256
    let processIdentitySHA256: WindowsExecutionSHA256
    let admissionProjectionSHA256: WindowsExecutionSHA256
    let resourceObservation: WindowsHelperResourceObservationV1
    let mutationDescriptorSHA256: WindowsExecutionSHA256
    let atomicFinalizationCommitted: Bool

    init(
        eventCode: WindowsHelperLifecycleEventCode,
        sourceSequence: UInt64,
        monotonicNanoseconds: UInt64,
        serviceState: WindowsHelperServiceState = .notApplicable,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier = .zero,
        bindingAttemptSequence: UInt64 = 0,
        leaseID: WindowsExecutionSHA256 = .zero,
        processIdentitySHA256: WindowsExecutionSHA256 = .zero,
        admissionProjectionSHA256: WindowsExecutionSHA256 = .zero,
        resourceObservation: WindowsHelperResourceObservationV1 =
            WindowsHelperResourceObservationV1(),
        mutationDescriptorSHA256: WindowsExecutionSHA256 = .zero,
        atomicFinalizationCommitted: Bool = false
    ) throws {
        guard eventCode.producer == .windowsRuntime,
              sourceSequence != 0,
              monotonicNanoseconds != 0 else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .evidence,
                detail: "runtime evidence producer, sequence, and time are exact"
            )
        }
        self.eventCode = eventCode
        self.sourceSequence = sourceSequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.serviceState = serviceState
        self.servicesInstanceID = servicesInstanceID
        self.bindingAttemptSequence = bindingAttemptSequence
        self.leaseID = leaseID
        self.processIdentitySHA256 = processIdentitySHA256
        self.admissionProjectionSHA256 = admissionProjectionSHA256
        self.resourceObservation = resourceObservation
        self.mutationDescriptorSHA256 = mutationDescriptorSHA256
        self.atomicFinalizationCommitted = atomicFinalizationCommitted
    }
}

struct WindowsHelperLifecycleEventV1: Hashable, Sendable {
    static let schemaMajor: UInt16 = 1
    static let schemaMinor: UInt16 = 0

    let globalSequence: UInt64
    let producer: WindowsHelperLifecycleEventProducer
    let sourceSequence: UInt64
    let eventCode: WindowsHelperLifecycleEventCode
    let monotonicNanoseconds: UInt64
    let runID: WindowsExecutionRunID
    let sessionNonce: WindowsExecutionSHA256
    let prefixScopeSHA256: WindowsExecutionSHA256
    let preparedSessionBootstrapSHA256: WindowsExecutionSHA256
    let profile: WindowsHelperExecutionProfile
    let sessionState: WindowsHelperSessionState
    let serviceState: WindowsHelperServiceState
    let servicesInstanceID: WindowsExecutionAuthorityIdentifier
    let bindingAttemptSequence: UInt64
    let leaseID: WindowsExecutionSHA256
    let processIdentitySHA256: WindowsExecutionSHA256
    let admissionProjectionSHA256: WindowsExecutionSHA256
    let resourceObservationSHA256: WindowsExecutionSHA256
    let mutationDescriptorSHA256: WindowsExecutionSHA256
    let reasonCode: WindowsExecutionReasonCode?
    let previousRecordSHA256: WindowsExecutionSHA256

    var recordSHA256: WindowsExecutionSHA256 {
        var data = Data("FPLCEVT1".utf8)
        WindowsExecutionBinaryCodec.appendUInt16(Self.schemaMajor, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(Self.schemaMinor, to: &data)
        WindowsExecutionBinaryCodec.appendUInt64(globalSequence, to: &data)
        data.append(producer.rawValue)
        WindowsExecutionBinaryCodec.appendUInt64(sourceSequence, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(eventCode.rawValue, to: &data)
        WindowsExecutionBinaryCodec.appendUInt64(
            monotonicNanoseconds,
            to: &data
        )
        data.append(contentsOf: runID.bytes)
        data.append(contentsOf: sessionNonce.bytes)
        data.append(contentsOf: prefixScopeSHA256.bytes)
        data.append(contentsOf: preparedSessionBootstrapSHA256.bytes)
        data.append(contentsOf: Data(profile.rawValue.utf8).sha256Bytes)
        data.append(sessionState.rawValue)
        data.append(serviceState.rawValue)
        data.append(contentsOf: servicesInstanceID.bytes)
        WindowsExecutionBinaryCodec.appendUInt64(
            bindingAttemptSequence,
            to: &data
        )
        data.append(contentsOf: leaseID.bytes)
        data.append(contentsOf: processIdentitySHA256.bytes)
        data.append(contentsOf: admissionProjectionSHA256.bytes)
        data.append(contentsOf: resourceObservationSHA256.bytes)
        data.append(contentsOf: mutationDescriptorSHA256.bytes)
        WindowsExecutionBinaryCodec.appendUInt32(
            reasonCode?.rawValue ?? 0,
            to: &data
        )
        data.append(contentsOf: previousRecordSHA256.bytes)
        return .hash(data)
    }
}

struct WindowsHelperCleanupAmbiguityV1: Hashable, Sendable {
    let reason: WindowsExecutionReasonCode
    let recordKeySHA256: WindowsExecutionSHA256
    let mutationDescriptorSHA256: WindowsExecutionSHA256
    let detailSHA256: WindowsExecutionSHA256
    let resolved: Bool

    init(
        reason: WindowsExecutionReasonCode,
        recordKeySHA256: WindowsExecutionSHA256,
        mutationDescriptorSHA256: WindowsExecutionSHA256,
        detailSHA256: WindowsExecutionSHA256,
        resolved: Bool
    ) throws {
        guard !recordKeySHA256.isZero,
              !mutationDescriptorSHA256.isZero,
              !detailSHA256.isZero else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .cleanup,
                detail: "cleanup ambiguity is digest-bound"
            )
        }
        self.reason = reason
        self.recordKeySHA256 = recordKeySHA256
        self.mutationDescriptorSHA256 = mutationDescriptorSHA256
        self.detailSHA256 = detailSHA256
        self.resolved = resolved
    }
}

protocol WindowsHelperPrefixLeaseOwning: AnyObject, Sendable {
    var windowsHelperLeaseScopeSHA256: WindowsExecutionSHA256 { get }
    func releaseWindowsHelperLease() async throws
}

protocol WindowsHelperProcessSupervising: AnyObject, Sendable {
    func requestWindowsHelperTermination() async throws
    func waitForWindowsHelperTermination(
        deadlineMonotonicNanoseconds: UInt64
    ) async throws -> Bool
    func windowsHelperTrackedProcessCount() async -> Int
}

protocol WindowsExecutionCapabilityAuthorityCoordinating: Actor {
    func disconnectProcessFree() throws
}

extension WindowsExecutionCapabilityAuthority:
    WindowsExecutionCapabilityAuthorityCoordinating {}

actor WindowsHelperLifecycleCoordinator {
    static let maximumEvents = 4_096
    static let maximumCleanupAmbiguities = 128

    let bootstrap: WindowsPreparedSessionBootstrapV2
    let profile: WindowsPreparedHelperExecutionProfile
    let authority: any WindowsExecutionCapabilityAuthorityCoordinating

    private let prefixLease: any WindowsHelperPrefixLeaseOwning
    private let processSupervisor: any WindowsHelperProcessSupervising
    private let cleanupDeadlineMonotonicNanoseconds: UInt64

    private(set) var state = WindowsHelperSessionState.idle
    private(set) var events: [WindowsHelperLifecycleEventV1] = []
    private(set) var cleanupAmbiguities:
        [WindowsHelperCleanupAmbiguityV1] = []

    private var hostSourceSequence: UInt64 = 0
    private var lastRuntimeSourceSequence: UInt64 = 0
    private var lastRecordSHA256 = WindowsExecutionSHA256.zero
    private var cleanupStarted = false
    private var terminalEvidenceObserved = false
    private var hostResources = WindowsHelperResourceObservationV1()

    init(
        bootstrap: WindowsPreparedSessionBootstrapV2,
        profile: WindowsPreparedHelperExecutionProfile,
        authority: any WindowsExecutionCapabilityAuthorityCoordinating,
        prefixLease: any WindowsHelperPrefixLeaseOwning,
        processSupervisor: any WindowsHelperProcessSupervising,
        cleanupDeadlineMonotonicNanoseconds: UInt64
    ) throws {
        guard profile.bootstrapSHA256.isAuthenticatedEqual(
            to: bootstrap.sha256
        ),
        prefixLease.windowsHelperLeaseScopeSHA256.isAuthenticatedEqual(
            to: bootstrap.prefixScopeSHA256
        ),
        cleanupDeadlineMonotonicNanoseconds != 0 else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .lifecycle,
                detail: "coordinator ownership is bound to one prepared session"
            )
        }
        self.bootstrap = bootstrap
        self.profile = profile
        self.authority = authority
        self.prefixLease = prefixLease
        self.processSupervisor = processSupervisor
        self.cleanupDeadlineMonotonicNanoseconds =
            cleanupDeadlineMonotonicNanoseconds
    }

    func prepare(monotonicNanoseconds: UInt64) throws {
        guard state == .idle else {
            throw lifecycleError("prepare is single-use")
        }
        try requireBeforeDeadline(monotonicNanoseconds)
        state = .negotiating
        state = .exclusiveLeased
        hostResources.prefixExecutionLeases = 1
        hostResources.processSupervisors = 1
        hostResources.cleanupDeadlines = 1
        hostResources.authorityEndpoints = 1
        hostResources.lifecycleEvidenceEndpoints = 1
        state = .prepared
        try appendHostEvent(
            .sessionPrepared,
            monotonicNanoseconds: monotonicNanoseconds
        )
    }

    func bindLaunch(
        admissionProjectionSHA256: WindowsExecutionSHA256,
        monotonicNanoseconds: UInt64
    ) throws {
        guard state == .prepared,
              !admissionProjectionSHA256.isZero else {
            throw lifecycleError("launch binding requires one prepared projection")
        }
        try requireBeforeDeadline(monotonicNanoseconds)
        state = .launchBound
        try appendHostEvent(
            .launchBound,
            monotonicNanoseconds: monotonicNanoseconds,
            admissionProjectionSHA256: admissionProjectionSHA256
        )
    }

    func recordRuntimeEvidence(
        _ evidence: WindowsHelperRuntimeEvidenceV1
    ) throws {
        guard state != .idle,
              state != .cleanupCompleted,
              state != .cleanupFailed,
              state != .closed,
              events.count < Self.maximumEvents,
              evidence.sourceSequence == lastRuntimeSourceSequence + 1,
              evidence.monotonicNanoseconds <=
                cleanupDeadlineMonotonicNanoseconds else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .evidence,
                detail: "runtime evidence order or lifecycle boundary is invalid"
            )
        }
        try validateRuntimeEventBoundary(evidence)
        lastRuntimeSourceSequence = evidence.sourceSequence

        switch evidence.eventCode {
        case .runtimeActive:
            state = .sharedActive
        case .runtimeQuiesced:
            guard state == .quiescing || state == .exclusiveCleanup else {
                throw lifecycleError("runtime quiescence precedes cleanup")
            }
            state = .exclusiveCleanup
        case .bindingRecommitted:
            guard profile.profile.lifecycleKind == .windowsService else {
                throw lifecycleError("binding evidence requires a service profile")
            }
        case .persistentServicePreserved:
            guard cleanupStarted,
                  profile.profile.servicePersistence == .guestPersistent,
                  evidence.serviceState == .running,
                  !evidence.leaseID.isZero else {
                throw lifecycleError(
                    "persistent preservation evidence is incomplete"
                )
            }
            terminalEvidenceObserved = true
        case .transientResourcesAtomicallyFinalized:
            guard cleanupStarted,
                  profile.profile.servicePersistence != .guestPersistent,
                  evidence.atomicFinalizationCommitted,
                  evidence.resourceObservation.isZero else {
                throw lifecycleError(
                    "transient finalization is not atomic and zero-resource"
                )
            }
            terminalEvidenceObserved = true
        case .runtimePrepared, .runtimeLaunchStarted, .runtimeProcessCreated,
             .runtimeProcessCommitted, .runtimeCleanupObserved:
            break
        case .sessionPrepared, .launchBound, .cleanupStarted,
             .cleanupCompleted, .cleanupFailed, .sessionClosed:
            throw lifecycleError("host event appeared on the runtime source")
        }

        try appendEvent(
            producer: .windowsRuntime,
            sourceSequence: evidence.sourceSequence,
            eventCode: evidence.eventCode,
            monotonicNanoseconds: evidence.monotonicNanoseconds,
            serviceState: evidence.serviceState,
            servicesInstanceID: evidence.servicesInstanceID,
            bindingAttemptSequence: evidence.bindingAttemptSequence,
            leaseID: evidence.leaseID,
            processIdentitySHA256: evidence.processIdentitySHA256,
            admissionProjectionSHA256:
                evidence.admissionProjectionSHA256,
            resourceObservationSHA256:
                evidence.resourceObservation.canonicalSHA256,
            mutationDescriptorSHA256:
                evidence.mutationDescriptorSHA256,
            reasonCode: nil
        )
    }

    func beginCleanup(monotonicNanoseconds: UInt64) async throws {
        guard !cleanupStarted,
              state == .prepared || state == .launchBound ||
                state == .sharedActive else {
            throw lifecycleError("cleanup may begin exactly once")
        }
        try requireBeforeDeadline(monotonicNanoseconds)
        cleanupStarted = true
        state = .quiescing
        hostResources.pendingCleanupOperations = 1
        try await processSupervisor.requestWindowsHelperTermination()
        state = .exclusiveCleanup
        try appendHostEvent(
            .cleanupStarted,
            monotonicNanoseconds: monotonicNanoseconds
        )
    }

    func recordCleanupAmbiguity(
        _ ambiguity: WindowsHelperCleanupAmbiguityV1,
        monotonicNanoseconds: UInt64
    ) throws {
        guard cleanupStarted,
              state == .exclusiveCleanup || state == .compensating,
              cleanupAmbiguities.count < Self.maximumCleanupAmbiguities else {
            throw lifecycleError("cleanup ambiguity is outside cleanup")
        }
        try requireBeforeDeadline(monotonicNanoseconds)
        cleanupAmbiguities.append(ambiguity)
        state = .compensating
    }

    func completeCleanup(monotonicNanoseconds: UInt64) async throws {
        guard cleanupStarted,
              state == .exclusiveCleanup || state == .compensating else {
            throw lifecycleError("cleanup completion lacks cleanup ownership")
        }
        do {
            try requireBeforeDeadline(monotonicNanoseconds)
            guard cleanupAmbiguities.isEmpty,
                  terminalEvidenceObserved else {
                throw WindowsExecutionContractError(
                    reason: .lifecycleEvidenceInvalid,
                    stage: .cleanup,
                    detail: "success is forbidden with ambiguity or missing evidence"
                )
            }
            let terminated = try await processSupervisor
                .waitForWindowsHelperTermination(
                    deadlineMonotonicNanoseconds:
                        cleanupDeadlineMonotonicNanoseconds
                )
            let tracked = await processSupervisor
                .windowsHelperTrackedProcessCount()
            guard terminated, tracked == 0 else {
                throw WindowsExecutionContractError(
                    reason: .lifecycleCleanupFailed,
                    stage: .cleanup,
                    detail: "supervised helper processes remain"
                )
            }
            try await prefixLease.releaseWindowsHelperLease()
            try await authority.disconnectProcessFree()
            hostResources = WindowsHelperResourceObservationV1()
            state = .cleanupCompleted
            try appendHostEvent(
                .cleanupCompleted,
                monotonicNanoseconds: monotonicNanoseconds
            )
        } catch {
            try recordTerminalFailure(
                error,
                monotonicNanoseconds: monotonicNanoseconds
            )
            throw error
        }
    }

    func failCleanup(
        reason: WindowsExecutionReasonCode,
        monotonicNanoseconds: UInt64
    ) throws {
        guard cleanupStarted,
              state != .cleanupCompleted,
              state != .cleanupFailed,
              state != .closed else {
            throw lifecycleError("cleanup failure is not a valid transition")
        }
        state = .cleanupFailed
        try appendHostEvent(
            .cleanupFailed,
            monotonicNanoseconds: monotonicNanoseconds,
            reasonCode: reason
        )
    }

    func close(monotonicNanoseconds: UInt64) throws {
        guard state == .cleanupCompleted,
              hostResources.isZero,
              cleanupAmbiguities.isEmpty else {
            throw lifecycleError("only proven cleanup completion may close")
        }
        state = .closed
        try appendHostEvent(
            .sessionClosed,
            monotonicNanoseconds: monotonicNanoseconds
        )
    }

    var currentResourceObservation: WindowsHelperResourceObservationV1 {
        hostResources
    }

    private func validateRuntimeEventBoundary(
        _ evidence: WindowsHelperRuntimeEvidenceV1
    ) throws {
        switch evidence.eventCode {
        case .runtimePrepared, .runtimeLaunchStarted,
             .runtimeProcessCreated, .runtimeProcessCommitted:
            guard state == .launchBound || state == .sharedActive else {
                throw lifecycleError("runtime launch evidence precedes launch binding")
            }
        case .runtimeActive:
            guard state == .launchBound || state == .sharedActive else {
                throw lifecycleError("runtime activation precedes launch binding")
            }
        case .runtimeQuiesced, .runtimeCleanupObserved,
             .persistentServicePreserved,
             .transientResourcesAtomicallyFinalized:
            guard cleanupStarted else {
                throw lifecycleError("cleanup evidence precedes cleanup")
            }
        case .bindingRecommitted:
            guard state == .launchBound || state == .sharedActive else {
                throw lifecycleError("binding evidence precedes launch binding")
            }
        case .sessionPrepared, .launchBound, .cleanupStarted,
             .cleanupCompleted, .cleanupFailed, .sessionClosed:
            throw lifecycleError("runtime evidence uses a host event code")
        }
    }

    private func appendHostEvent(
        _ code: WindowsHelperLifecycleEventCode,
        monotonicNanoseconds: UInt64,
        admissionProjectionSHA256: WindowsExecutionSHA256 = .zero,
        reasonCode: WindowsExecutionReasonCode? = nil
    ) throws {
        guard code.producer == .forgePlayHost,
              hostSourceSequence != UInt64.max else {
            throw lifecycleError("host event source sequence exhausted")
        }
        hostSourceSequence += 1
        try appendEvent(
            producer: .forgePlayHost,
            sourceSequence: hostSourceSequence,
            eventCode: code,
            monotonicNanoseconds: monotonicNanoseconds,
            serviceState: .notApplicable,
            servicesInstanceID: .zero,
            bindingAttemptSequence: 0,
            leaseID: .zero,
            processIdentitySHA256: .zero,
            admissionProjectionSHA256: admissionProjectionSHA256,
            resourceObservationSHA256: hostResources.canonicalSHA256,
            mutationDescriptorSHA256: .zero,
            reasonCode: reasonCode
        )
    }

    private func appendEvent(
        producer: WindowsHelperLifecycleEventProducer,
        sourceSequence: UInt64,
        eventCode: WindowsHelperLifecycleEventCode,
        monotonicNanoseconds: UInt64,
        serviceState: WindowsHelperServiceState,
        servicesInstanceID: WindowsExecutionAuthorityIdentifier,
        bindingAttemptSequence: UInt64,
        leaseID: WindowsExecutionSHA256,
        processIdentitySHA256: WindowsExecutionSHA256,
        admissionProjectionSHA256: WindowsExecutionSHA256,
        resourceObservationSHA256: WindowsExecutionSHA256,
        mutationDescriptorSHA256: WindowsExecutionSHA256,
        reasonCode: WindowsExecutionReasonCode?
    ) throws {
        guard events.count < Self.maximumEvents,
              eventCode.producer == producer,
              sourceSequence != 0,
              monotonicNanoseconds != 0 else {
            throw lifecycleError("lifecycle event bounds or producer failed")
        }
        let global = UInt64(events.count) + 1
        let event = WindowsHelperLifecycleEventV1(
            globalSequence: global,
            producer: producer,
            sourceSequence: sourceSequence,
            eventCode: eventCode,
            monotonicNanoseconds: monotonicNanoseconds,
            runID: bootstrap.runID,
            sessionNonce: bootstrap.sessionNonce,
            prefixScopeSHA256: bootstrap.prefixScopeSHA256,
            preparedSessionBootstrapSHA256: bootstrap.sha256,
            profile: profile.profile,
            sessionState: state,
            serviceState: serviceState,
            servicesInstanceID: servicesInstanceID,
            bindingAttemptSequence: bindingAttemptSequence,
            leaseID: leaseID,
            processIdentitySHA256: processIdentitySHA256,
            admissionProjectionSHA256: admissionProjectionSHA256,
            resourceObservationSHA256: resourceObservationSHA256,
            mutationDescriptorSHA256: mutationDescriptorSHA256,
            reasonCode: reasonCode,
            previousRecordSHA256: lastRecordSHA256
        )
        lastRecordSHA256 = event.recordSHA256
        events.append(event)
    }

    private func recordTerminalFailure(
        _ error: Error,
        monotonicNanoseconds: UInt64
    ) throws {
        guard state != .cleanupFailed else {
            return
        }
        state = .cleanupFailed
        let reason =
            (error as? WindowsExecutionContractError)?.reason ??
            .lifecycleCleanupFailed
        try appendHostEvent(
            .cleanupFailed,
            monotonicNanoseconds: monotonicNanoseconds,
            reasonCode: reason
        )
    }

    private func requireBeforeDeadline(_ monotonicNanoseconds: UInt64) throws {
        guard monotonicNanoseconds != 0,
              monotonicNanoseconds <=
                cleanupDeadlineMonotonicNanoseconds else {
            throw WindowsExecutionContractError(
                reason: .lifecycleDeadlineExceeded,
                stage: .lifecycle,
                detail: "lifecycle deadline exceeded"
            )
        }
    }

    private func lifecycleError(_ detail: String)
        -> WindowsExecutionContractError {
        WindowsExecutionContractError(
            reason: .lifecycleEvidenceInvalid,
            stage: .lifecycle,
            detail: detail
        )
    }
}

private extension Data {
    var sha256Bytes: [UInt8] {
        WindowsExecutionSHA256.hash(self).bytes
    }
}
