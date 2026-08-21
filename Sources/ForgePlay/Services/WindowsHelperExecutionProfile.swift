// ForgePlay-authored clean-room output.
// Distribution remains blocked until explicit project license assignment.

import Foundation

enum WindowsHelperExecutionProfile: String, CaseIterable, Codable, Sendable {
    case maintenanceOneShot
    case maintenanceGuestPersistentService
    case maintenanceSessionTransientService
    case sessionAttachedOneShotHelper
    case sessionAttachedGuestPersistentService
    case sessionAttachedSessionTransientService
    case sessionAttachedOneShot

    var executionMode: WindowsExecutionMode {
        switch self {
        case .maintenanceOneShot,
             .maintenanceGuestPersistentService,
             .maintenanceSessionTransientService:
            return .maintenance
        case .sessionAttachedOneShotHelper,
             .sessionAttachedGuestPersistentService,
             .sessionAttachedSessionTransientService,
             .sessionAttachedOneShot:
            return .sessionAttached
        }
    }

    var rendererRequirement: WindowsRendererRequirement {
        self == .sessionAttachedOneShot
            ? .inheritedWhenSupported
            : .forbidden
    }

    var lifecycleKind: WindowsExecutionLifecycleKind {
        switch self {
        case .maintenanceOneShot,
             .sessionAttachedOneShotHelper,
             .sessionAttachedOneShot:
            return .oneShot
        default:
            return .windowsService
        }
    }

    var servicePersistence: WindowsServicePersistence {
        switch self {
        case .maintenanceGuestPersistentService,
             .sessionAttachedGuestPersistentService:
            return .guestPersistent
        case .maintenanceSessionTransientService,
             .sessionAttachedSessionTransientService:
            return .sessionTransient
        default:
            return .notApplicable
        }
    }

    var permittedRoles: Set<WindowsExecutionLineageRole> {
        switch self {
        case .maintenanceOneShot, .sessionAttachedOneShotHelper:
            return [.trustedHelperRoot, .descendant]
        case .maintenanceGuestPersistentService,
             .maintenanceSessionTransientService,
             .sessionAttachedGuestPersistentService,
             .sessionAttachedSessionTransientService:
            return [.trustedHelperRoot, .descendant, .boundServiceActivation]
        case .sessionAttachedOneShot:
            return [.directTarget, .descendant]
        }
    }

    init(
        executionMode: WindowsExecutionMode,
        rendererRequirement: WindowsRendererRequirement,
        lifecycleKind: WindowsExecutionLifecycleKind,
        servicePersistence: WindowsServicePersistence
    ) throws {
        guard let profile = Self.allCases.first(where: {
            $0.executionMode == executionMode &&
                $0.rendererRequirement == rendererRequirement &&
                $0.lifecycleKind == lifecycleKind &&
                $0.servicePersistence == servicePersistence
        }) else {
            throw WindowsExecutionContractError(
                reason: .capabilityProfileInvalid,
                stage: .admission,
                detail: "execution profile is not one of seven frozen tuples"
            )
        }
        self = profile
    }
}

struct WindowsPreparedHelperExecutionProfile: Hashable, Sendable {
    let profile: WindowsHelperExecutionProfile
    let bootstrapSHA256: WindowsExecutionSHA256

    init(
        descriptor: WindowsExecutionLaunchDescriptorV1,
        bootstrap: WindowsPreparedSessionBootstrapV2
    ) throws {
        guard descriptor.sequence == bootstrap.sequence,
              descriptor.runID == bootstrap.runID,
              descriptor.sessionNonce == bootstrap.sessionNonce,
              descriptor.prefixScopeSHA256 == bootstrap.prefixScopeSHA256,
              descriptor.runtimeFingerprintSHA256 ==
                bootstrap.runtimeFingerprintSHA256,
              descriptor.recordSHA256.isAuthenticatedEqual(
                  to: bootstrap.launchDescriptorRecordSHA256
              ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .admission,
                detail: "profile is not bound to the immutable prepared bootstrap"
            )
        }
        profile = try WindowsHelperExecutionProfile(
            executionMode: descriptor.executionMode,
            rendererRequirement: descriptor.rendererRequirement,
            lifecycleKind: descriptor.lifecycleKind,
            servicePersistence: descriptor.servicePersistence
        )
        bootstrapSHA256 = bootstrap.sha256
    }
}

struct WindowsStructuralAdmissionProjectionV1: Hashable, Sendable {
    static let magic = Array("FPADMIT1".utf8)
    static let byteCount = 88

    let profile: WindowsHelperExecutionProfile
    let lineageRole: WindowsExecutionLineageRole
    let rendererIntent: WindowsRendererIntent
    let rendererArchitectureSupport: WindowsRendererArchitectureSupport
    let serviceBindingState: WindowsServiceBindingState
    let peMachine: WindowsPEMachine
    let runtimeCapabilitySetFingerprintSHA256: WindowsExecutionSHA256
    let rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256

    init(
        profile: WindowsHelperExecutionProfile,
        lineageRole: WindowsExecutionLineageRole,
        rendererIntent: WindowsRendererIntent,
        rendererArchitectureSupport: WindowsRendererArchitectureSupport,
        serviceBindingState: WindowsServiceBindingState,
        peMachine: WindowsPEMachine,
        runtimeCapabilitySetFingerprintSHA256: WindowsExecutionSHA256,
        rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256
    ) throws {
        guard !runtimeCapabilitySetFingerprintSHA256.isZero,
              !rendererCapabilityFingerprintSHA256.isZero else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .admission,
                detail: "admission projection fingerprints are nonzero"
            )
        }
        self.profile = profile
        self.lineageRole = lineageRole
        self.rendererIntent = rendererIntent
        self.rendererArchitectureSupport = rendererArchitectureSupport
        self.serviceBindingState = serviceBindingState
        self.peMachine = peMachine
        self.runtimeCapabilitySetFingerprintSHA256 =
            runtimeCapabilitySetFingerprintSHA256
        self.rendererCapabilityFingerprintSHA256 =
            rendererCapabilityFingerprintSHA256
    }

    func encoded() -> Data {
        var data = Data(Self.magic)
        WindowsExecutionBinaryCodec.appendUInt16(1, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        data.append(profile.executionMode.rawValue)
        data.append(profile.rendererRequirement.rawValue)
        data.append(profile.lifecycleKind.rawValue)
        data.append(profile.servicePersistence.rawValue)
        data.append(lineageRole.rawValue)
        data.append(rendererIntent.rawValue)
        data.append(rendererArchitectureSupport.rawValue)
        data.append(serviceBindingState.rawValue)
        WindowsExecutionBinaryCodec.appendUInt16(peMachine.rawValue, to: &data)
        WindowsExecutionBinaryCodec.appendUInt16(0, to: &data)
        data.append(
            contentsOf: runtimeCapabilitySetFingerprintSHA256.bytes
        )
        data.append(
            contentsOf: rendererCapabilityFingerprintSHA256.bytes
        )
        return data
    }

    var sha256: WindowsExecutionSHA256 {
        WindowsExecutionSHA256.hash(encoded())
    }
}

struct WindowsStructuralAdmissionProofV1: Hashable, Sendable {
    let runtimeCapabilitySetFingerprintSHA256: WindowsExecutionSHA256
    let rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256
    let architecture: WindowsRendererArchitectureEntry
    let registryBinding: WindowsRendererRegistryBinding

    init(
        records: WindowsExecutionValidatedCapabilityRecords,
        projection: WindowsRendererNeutralEnvironmentProjection
    ) throws {
        guard let architecture = records.rendererSnapshot.architectures.first else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .admission,
                detail: "validated renderer snapshot has no architecture"
            )
        }
        let binding = WindowsRendererRegistryBinding(
            snapshot: records.rendererSnapshot,
            projection: projection
        )
        guard binding.authenticate(
            snapshot: records.rendererSnapshot,
            projection: projection
        ) else {
            throw WindowsExecutionContractError(
                reason: .admissionRendererClosureInvalid,
                stage: .admission,
                detail: "renderer registry binding authentication failed"
            )
        }
        runtimeCapabilitySetFingerprintSHA256 =
            records.negotiation.runtimeCapabilitySetFingerprintSHA256
        rendererCapabilityFingerprintSHA256 =
            records.rendererSnapshot.recordSHA256
        self.architecture = architecture
        registryBinding = binding
    }

    init(
        runtimeCapabilitySetFingerprintSHA256: WindowsExecutionSHA256,
        rendererCapabilityFingerprintSHA256: WindowsExecutionSHA256,
        architecture: WindowsRendererArchitectureEntry,
        registryBinding: WindowsRendererRegistryBinding
    ) {
        self.runtimeCapabilitySetFingerprintSHA256 =
            runtimeCapabilitySetFingerprintSHA256
        self.rendererCapabilityFingerprintSHA256 =
            rendererCapabilityFingerprintSHA256
        self.architecture = architecture
        self.registryBinding = registryBinding
    }
}

struct WindowsStructuralAdmissionResult: Hashable, Sendable {
    let decision: WindowsAdmissionDecision
    let reason: WindowsExecutionReasonCode?
    let inputProjectionSHA256: WindowsExecutionSHA256

    var isAccepted: Bool {
        decision != .reject && reason == nil
    }
}

enum WindowsHelperStructuralAdmission {
    static func evaluate(
        _ projection: WindowsStructuralAdmissionProjectionV1,
        proof: WindowsStructuralAdmissionProofV1
    ) -> WindowsStructuralAdmissionResult {
        let digest = projection.sha256
        guard projection.profile.permittedRoles.contains(
            projection.lineageRole
        ) else {
            return reject(.admissionRoleUnknown, digest)
        }
        guard proof.runtimeCapabilitySetFingerprintSHA256
            .isAuthenticatedEqual(
                to: projection.runtimeCapabilitySetFingerprintSHA256
            ),
        proof.rendererCapabilityFingerprintSHA256.isAuthenticatedEqual(
            to: projection.rendererCapabilityFingerprintSHA256
        ),
        proof.architecture.peMachine == projection.peMachine,
        proof.architecture.support == projection.rendererArchitectureSupport,
        proof.architecture.flags.contains(.runtimeLoadGuardMandatory) else {
            return reject(.admissionRendererClosureInvalid, digest)
        }
        switch projection.lineageRole {
        case .boundServiceActivation:
            switch projection.serviceBindingState {
            case .valid:
                break
            case .notApplicable, .missing:
                return reject(.serviceBindingMissing, digest)
            case .stale:
                return reject(.serviceBindingStale, digest)
            case .scopeMismatch:
                return reject(.serviceBindingScopeMismatch, digest)
            case .alreadyConsumed:
                return reject(.serviceBindingReplayed, digest)
            }
        case .directTarget, .descendant, .trustedHelperRoot:
            guard projection.serviceBindingState == .notApplicable else {
                return reject(.serviceBindingUnexpected, digest)
            }
        }
        if projection.profile.rendererRequirement == .forbidden {
            switch projection.rendererIntent {
            case .rendering:
                return reject(.admissionRendererRequired, digest)
            case .unknown:
                return reject(.admissionIntentUnknown, digest)
            case .nonRenderingCandidate:
                return accept(.guardedRendererNeutral, digest)
            }
        }
        if projection.rendererArchitectureSupport == .supported {
            return accept(.selectedRenderer, digest)
        }
        if projection.lineageRole == .directTarget {
            return reject(
                .admissionDirectRendererArchitectureUnsupported,
                digest
            )
        }
        switch projection.rendererIntent {
        case .rendering:
            return reject(.admissionRendererRequired, digest)
        case .unknown:
            return reject(.admissionIntentUnknown, digest)
        case .nonRenderingCandidate:
            return accept(.guardedRendererNeutral, digest)
        }
    }

    static func authorizeModuleLoad(
        moduleBasename: String,
        admission: WindowsStructuralAdmissionResult,
        architecture: WindowsRendererArchitectureEntry
    ) -> WindowsExecutionReasonCode? {
        guard admission.decision == .guardedRendererNeutral else {
            return nil
        }
        guard let digest = try? WindowsRendererCapabilitySnapshotBuilder
            .moduleFamilyDigest(moduleBasename) else {
            return .admissionRendererLoadBlocked
        }
        return architecture.ownsModuleFamily(digest)
            ? .admissionRendererLoadBlocked
            : nil
    }

    private static func accept(
        _ decision: WindowsAdmissionDecision,
        _ digest: WindowsExecutionSHA256
    ) -> WindowsStructuralAdmissionResult {
        WindowsStructuralAdmissionResult(
            decision: decision,
            reason: nil,
            inputProjectionSHA256: digest
        )
    }

    private static func reject(
        _ reason: WindowsExecutionReasonCode,
        _ digest: WindowsExecutionSHA256
    ) -> WindowsStructuralAdmissionResult {
        WindowsStructuralAdmissionResult(
            decision: .reject,
            reason: reason,
            inputProjectionSHA256: digest
        )
    }
}

enum WindowsExecutionImageStageClass: UInt32, Codable, Sendable {
    case bindingInspection = 1
    case serviceActualCreation = 2
    case oneShotActualCreation = 3
    case maintenanceServiceActualCreation = 4
}

enum WindowsExecutionImageStageOrigin: UInt8, Sendable {
    case createService = 1
    case startService = 2
    case createProcess = 3
}

struct WindowsExecutionImageStageContext: Hashable, Sendable {
    let origin: WindowsExecutionImageStageOrigin
    let ownProcessService: Bool
    let persistence: WindowsServicePersistence
    let retainedBinding: Bool
    let servicesProcessOwner: Bool
    let exactServiceScope: Bool
}

enum WindowsExecutionImageStageAuthorization {
    static let statusSuccess: UInt32 = 0
    static let statusNotSupported: UInt32 = 0xc00000bb
    static let statusInvalidParameter: UInt32 = 0xc000000d

    static func authorize(
        rawStageClass: UInt32,
        registry: WindowsExecutionProviderRegistry,
        context: WindowsExecutionImageStageContext
    ) -> UInt32 {
        guard let stageClass = WindowsExecutionImageStageClass(
            rawValue: rawStageClass
        ) else {
            return statusInvalidParameter
        }
        guard stageClass == .maintenanceServiceActualCreation else {
            return statusSuccess
        }
        guard registry.fixtureOnly,
              context.origin == .startService,
              context.ownProcessService,
              context.persistence == .sessionTransient,
              context.retainedBinding,
              context.servicesProcessOwner,
              context.exactServiceScope,
              registry.entries.contains(where: {
                  $0.identifierSHA256 ==
                    (try? WindowsExecutionCapabilityContract.identifierSHA256(
                        WindowsExecutionProviderRegistry
                            .syntheticMaintenanceIdentifier
                    )) &&
                    $0.major == 1
              }),
              registry.entries.contains(where: {
                  $0.identifierSHA256 ==
                    (try? WindowsExecutionCapabilityContract.identifierSHA256(
                        WindowsExecutionProviderRegistry
                            .helperSupervisionIdentifier
                    )) &&
                    $0.major == 1 && $0.minor >= 2
              }) else {
            return statusNotSupported
        }
        return statusSuccess
    }
}
