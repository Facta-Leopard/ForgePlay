import CryptoKit
import Darwin
import Foundation

struct WindowsFontCompatibilityInspection: Hashable, Sendable {
    var appliedItems: [String]
    var missingItems: [String]

    var isSatisfied: Bool { missingItems.isEmpty }
}

struct WindowsFontProvisioningApplicationReceipt: Hashable, Sendable {
    enum ProvisioningState: String, Hashable, Sendable {
        case reusedVerifiedProfile
        case provisionedAndVerified
        case reconciledAndVerified
        case verifiedUnsupportedLocalePassthrough
        case verifiedCollisionPassthrough
        case verifiedExternalFontPassthrough
        case unverifiedOperationalPassthrough
    }

    let profileIdentifier: String
    let state: ProvisioningState
    let baselineDigest: String
    let appliedDigest: String
    let appliedItemCount: Int
    let missingItemCount: Int

    var isAppliedAndReadBack: Bool {
        let expectedItemCount: Int?
        switch profileIdentifier {
        case WindowsFontCompatibilityProfileContract.profileIdentifier:
            expectedItemCount =
                WindowsFontCompatibilityProfileContract.definition.payloads.count +
                WindowsFontCompatibilityProfileContract.definition
                    .registryRequirements.count + 1
        case WindowsFontCompatibilityProfileV6Contract.profileIdentifier:
            expectedItemCount = state == .verifiedUnsupportedLocalePassthrough ||
                state == .verifiedCollisionPassthrough ||
                state == .verifiedExternalFontPassthrough
                ? 0
                : WindowsFontCompatibilityProfileV6Contract.expectedAppliedItemCount
        default:
            expectedItemCount = nil
        }
        guard let expectedItemCount else { return false }
        return expectedItemCount == appliedItemCount &&
            missingItemCount == 0 &&
            SteamLaunchIdentifierValidation.isValidLowercaseSHA256(
                baselineDigest
            ) &&
            SteamLaunchIdentifierValidation.isValidLowercaseSHA256(
                appliedDigest
            )
    }

    var requiresScopedWineChildPOSIXLocaleFallback: Bool {
        state == .verifiedUnsupportedLocalePassthrough ||
            state == .verifiedCollisionPassthrough
    }
}

enum WindowsFontPayloadSourceRole: String, Codable, CaseIterable, Hashable, Sendable {
    case runtimeNanum = "runtime-nanum"
    case appNotoPack = "app-noto-pack"
}

struct WindowsFontPayloadDescriptor: Hashable, Sendable {
    let sourceRole: WindowsFontPayloadSourceRole
    let fileName: String
    let sha256: String
    let registryDisplayName: String
    let registryFileTypeLabel: String

    var descriptorID: String {
        WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontLifecyclePayloadV1",
            fields: [
                sourceRole.rawValue,
                fileName,
                sha256,
                registryDisplayName,
                registryFileTypeLabel
            ]
        )
    }
}

struct WindowsFontRegistryRequirement: Hashable, Sendable {
    let registryPath: String
    let valueName: String
    let valueType: String
    let orderedValues: [String]

    var encodedRunnerValue: String {
        valueType == "REG_MULTI_SZ"
            ? orderedValues.joined(separator: "\\0")
            : (orderedValues.first ?? "")
    }

    var label: String {
        "\(registryPath)\\\(valueName)=\(orderedValues.joined(separator: " -> "))"
    }

    var descriptorID: String {
        WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontLifecycleRegistryV1",
            fields: [registryPath.lowercased(), valueName.lowercased(), valueType] + orderedValues
        )
    }
}

struct WindowsFontRegistryReplacementDescriptor: Hashable, Sendable {
    let baseline: WindowsFontRegistryRequirement
    let target: WindowsFontRegistryRequirement

    var replacementID: String {
        WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontLifecycleRegistryReplacementV1",
            fields: [target.descriptorID, baseline.descriptorID]
        )
    }
}

enum WindowsFontLifecycleFailureKind: String, CaseIterable, Codable, Hashable, Sendable {
    case filesystemThrow = "filesystem-throw"
    case shortWrite = "short-write"
    case semanticMismatch = "semantic-mismatch"
    case collision
    case processUnsuccessfulResult = "process-unsuccessful-result"
    case processThrownError = "process-thrown-error"
    case semanticConflict = "semantic-conflict"
    case directoryNotEmptyConflict = "directory-not-empty-conflict"
}

enum WindowsFontLifecycleOperationKind: String, CaseIterable, Codable, Hashable, Sendable {
    case journalExclusiveCreate = "journal-exclusive-create"
    case journalCompleteWrite = "journal-complete-write"
    case journalFileFSync = "journal-file-fsync"
    case journalClose = "journal-close"
    case journalReopenCanonicalVerify = "journal-reopen-canonical-verify"
    case journalParentDirectoryFSync = "journal-parent-directory-fsync"
    case plannedDirectoryCreateVerify = "planned-directory-create-verify"
    case plannedDirectoryContainingParentFSync =
        "planned-directory-containing-parent-fsync"
    case payloadStageExclusiveCreate = "payload-stage-exclusive-create"
    case payloadAuthenticatedSourceCopy = "payload-authenticated-source-copy"
    case payloadStageFSyncHashVerify = "payload-stage-fsync-hash-verify"
    case committedOwnershipStageExclusiveCreate =
        "committed-ownership-stage-exclusive-create"
    case committedOwnershipStageCompleteWrite =
        "committed-ownership-stage-complete-write"
    case committedOwnershipStageFileFSync =
        "committed-ownership-stage-file-fsync"
    case committedOwnershipStageClose = "committed-ownership-stage-close"
    case committedOwnershipStageReopenCanonicalVerify =
        "committed-ownership-stage-reopen-canonical-verify"
    case committedOwnershipExchange = "committed-ownership-exchange"
    case committedOwnershipDriveCFSync = "committed-ownership-drive-c-fsync"
    case committedOwnershipStaleStageUnlink =
        "committed-ownership-stale-stage-unlink"
    case committedOwnershipUpdateParentFSync =
        "committed-ownership-update-parent-fsync"
    case committedOwnershipUpdateParentClose =
        "committed-ownership-update-parent-close"
    case committedOwnershipCanonicalReread =
        "committed-ownership-canonical-reread"
    case payloadNoOverwriteDestinationPublish = "payload-no-overwrite-destination-publish"
    case payloadPublicationStageParentFSync =
        "payload-publication-stage-parent-fsync"
    case payloadPublicationDestinationParentFSync =
        "payload-publication-destination-parent-fsync"
    case registrySet = "registry-set"
    case forwardRegistryFlush = "forward-registry-flush"
    case markerFreeCompleteInspection = "marker-free-complete-inspection"
    case markerStageExclusiveCreate = "marker-stage-exclusive-create"
    case markerCompleteWrite = "marker-complete-write"
    case markerFileFSync = "marker-file-fsync"
    case markerReopenCanonicalVerify = "marker-reopen-canonical-verify"
    case markerNoOverwritePublication = "marker-no-overwrite-publication"
    case markerPublicationStageParentFSync =
        "marker-publication-stage-parent-fsync"
    case markerParentDirectoryFSync = "marker-parent-directory-fsync"
    case committedDirectoryContainingParentFSync =
        "committed-directory-containing-parent-fsync"
    case committedPayloadStageParentFSync =
        "committed-payload-stage-parent-fsync"
    case committedPayloadDestinationParentFSync =
        "committed-payload-destination-parent-fsync"
    case committedMarkerStageParentFSync =
        "committed-marker-stage-parent-fsync"
    case committedMarkerParentFSync = "committed-marker-parent-fsync"
    case ownedRegistryDelete = "owned-registry-delete"
    case replacedRegistryRestore = "replaced-registry-restore"
    case compensationRegistryFlush = "compensation-registry-flush"
    case ownedFileDelete = "owned-file-delete"
    case ownedFileDeletionParentFSync = "owned-file-deletion-parent-fsync"
    case boundStageDelete = "bound-stage-delete"
    case plannedDirectoryDelete = "planned-directory-delete"
    case plannedDirectoryDeletionContainingParentFSync =
        "planned-directory-deletion-containing-parent-fsync"
    case adoptedStateVerification = "adopted-state-verification"
    case markerDelete = "marker-delete"
    case markerDeletionParentDirectoryFSync = "marker-deletion-parent-directory-fsync"
    case journalDelete = "journal-delete"
    case journalDeletionParentDirectoryFSync = "journal-deletion-parent-directory-fsync"
}

struct WindowsFontLifecycleOperationSpecification: Hashable, Sendable {
    let phase: String
    let operationKind: WindowsFontLifecycleOperationKind
    let resourceDomain: String
    let failureKinds: [WindowsFontLifecycleFailureKind]
}

struct WindowsFontLifecycleOperationInstance: Hashable, Sendable {
    let operationID: String
    let phase: String
    let operationKind: WindowsFontLifecycleOperationKind
    let resourceDomain: String
    let resourceIDOrPathID: String
    let ordinal: Int
}

struct WindowsFontLifecycleFailureCase: Hashable, Sendable {
    let operationID: String
    let failureKind: WindowsFontLifecycleFailureKind
}

struct WindowsFontLifecycleInterruptionCase: Hashable, Sendable {
    let operationID: String
    let interruptAfterSuccessfulOperation: Bool
}

enum WindowsFontLifecycleProjectionError: LocalizedError, Equatable {
    case duplicateResource(WindowsFontLifecycleOperationKind, String)
    case unknownOperationKind(WindowsFontLifecycleOperationKind)
    case instanceMismatch
    case failureCaseMismatch
    case interruptionCaseMismatch

    var errorDescription: String? {
        switch self {
        case .duplicateResource(let kind, let resource):
            "중복 Windows 글꼴 수명주기 리소스입니다: \(kind.rawValue) / \(resource)"
        case .unknownOperationKind(let kind):
            "알 수 없는 Windows 글꼴 수명주기 작업입니다: \(kind.rawValue)"
        case .instanceMismatch:
            "Windows 글꼴 수명주기 작업 인스턴스 순서가 일치하지 않습니다."
        case .failureCaseMismatch:
            "Windows 글꼴 수명주기 실패 사례 집합이 일치하지 않습니다."
        case .interruptionCaseMismatch:
            "Windows 글꼴 수명주기 중단 사례 집합이 일치하지 않습니다."
        }
    }
}

enum WindowsFontLifecycleOperationRegistry {
    nonisolated static let specifications: [WindowsFontLifecycleOperationSpecification] = [
        .init(
            phase: "journal-prepare",
            operationKind: .journalExclusiveCreate,
            resourceDomain: "singleton-journal",
            failureKinds: [.filesystemThrow, .collision]
        ),
        .init(
            phase: "journal-prepare",
            operationKind: .journalCompleteWrite,
            resourceDomain: "singleton-journal",
            failureKinds: [.filesystemThrow, .shortWrite]
        ),
        .init(
            phase: "journal-prepare",
            operationKind: .journalFileFSync,
            resourceDomain: "singleton-journal",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "journal-prepare",
            operationKind: .journalClose,
            resourceDomain: "singleton-journal",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "journal-prepare",
            operationKind: .journalReopenCanonicalVerify,
            resourceDomain: "singleton-journal",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "journal-prepare",
            operationKind: .journalParentDirectoryFSync,
            resourceDomain: "singleton-drive-c",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "forward-filesystem",
            operationKind: .plannedDirectoryCreateVerify,
            resourceDomain: "each-planned-created-directory-sorted-parent-first-0-through-7",
            failureKinds: [.filesystemThrow, .semanticMismatch, .collision]
        ),
        .init(
            phase: "forward-filesystem",
            operationKind: .plannedDirectoryContainingParentFSync,
            resourceDomain: "each-planned-created-directory-sorted-parent-first-0-through-7",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "forward-payload",
            operationKind: .payloadStageExclusiveCreate,
            resourceDomain: "each-planned-owned-payload-sorted-0-through-12",
            failureKinds: [.filesystemThrow, .collision]
        ),
        .init(
            phase: "forward-payload",
            operationKind: .payloadAuthenticatedSourceCopy,
            resourceDomain: "each-planned-owned-payload-sorted-0-through-12",
            failureKinds: [.filesystemThrow, .shortWrite]
        ),
        .init(
            phase: "forward-payload",
            operationKind: .payloadStageFSyncHashVerify,
            resourceDomain: "each-planned-owned-payload-sorted-0-through-12",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipStageExclusiveCreate,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow, .collision]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipStageCompleteWrite,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow, .shortWrite]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipStageFileFSync,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipStageClose,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipStageReopenCanonicalVerify,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipExchange,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipDriveCFSync,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipStaleStageUnlink,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow, .semanticConflict]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipUpdateParentFSync,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipUpdateParentClose,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "write-ahead-ownership",
            operationKind: .committedOwnershipCanonicalReread,
            resourceDomain: "each-planned-owned-payload-then-registry-resource",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "forward-payload",
            operationKind: .payloadNoOverwriteDestinationPublish,
            resourceDomain: "each-planned-owned-payload-sorted-0-through-12",
            failureKinds: [
                .filesystemThrow,
                .shortWrite,
                .semanticMismatch,
                .collision
            ]
        ),
        .init(
            phase: "forward-payload-durability",
            operationKind: .payloadPublicationStageParentFSync,
            resourceDomain: "each-published-owned-payload-sorted-0-through-12",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "forward-payload-durability",
            operationKind: .payloadPublicationDestinationParentFSync,
            resourceDomain: "each-published-owned-payload-sorted-0-through-12",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "forward-registry",
            operationKind: .registrySet,
            resourceDomain: "each-planned-created-or-replaced-registry-in-definition-order",
            failureKinds: [
                .filesystemThrow,
                .shortWrite,
                .semanticMismatch,
                .collision,
                .processUnsuccessfulResult,
                .processThrownError
            ]
        ),
        .init(
            phase: "forward-registry",
            operationKind: .forwardRegistryFlush,
            resourceDomain: "singleton-if-any-registry-set-attempted",
            failureKinds: [.processUnsuccessfulResult, .processThrownError]
        ),
        .init(
            phase: "forward-verification",
            operationKind: .markerFreeCompleteInspection,
            resourceDomain: "singleton-complete-profile",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerStageExclusiveCreate,
            resourceDomain: "singleton-marker-stage",
            failureKinds: [.filesystemThrow, .collision]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerCompleteWrite,
            resourceDomain: "singleton-marker-stage",
            failureKinds: [.filesystemThrow, .shortWrite]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerFileFSync,
            resourceDomain: "singleton-marker-stage",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerReopenCanonicalVerify,
            resourceDomain: "singleton-marker-stage",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerNoOverwritePublication,
            resourceDomain: "singleton-marker",
            failureKinds: [.filesystemThrow, .collision]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerPublicationStageParentFSync,
            resourceDomain: "singleton-marker-stage-parent-after-publication",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "marker-commit",
            operationKind: .markerParentDirectoryFSync,
            resourceDomain: "singleton-marker-parent-after-publication",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "committed-namespace-gate",
            operationKind: .committedDirectoryContainingParentFSync,
            resourceDomain: "each-committed-created-directory-before-journal-delete",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "committed-namespace-gate",
            operationKind: .committedPayloadStageParentFSync,
            resourceDomain: "each-committed-payload-stage-parent-before-journal-delete",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "committed-namespace-gate",
            operationKind: .committedPayloadDestinationParentFSync,
            resourceDomain: "each-committed-payload-destination-parent-before-journal-delete",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "committed-namespace-gate",
            operationKind: .committedMarkerStageParentFSync,
            resourceDomain: "singleton-committed-marker-stage-parent-before-journal-delete",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "committed-namespace-gate",
            operationKind: .committedMarkerParentFSync,
            resourceDomain: "singleton-committed-marker-parent-before-journal-delete",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "rollback-or-uninstall",
            operationKind: .ownedRegistryDelete,
            resourceDomain: "each-actually-created-or-marker-owned-registry-reverse-action-order",
            failureKinds: [.semanticConflict, .processUnsuccessfulResult, .processThrownError]
        ),
        .init(
            phase: "rollback-or-uninstall",
            operationKind: .replacedRegistryRestore,
            resourceDomain: "each-committed-replaced-registry-reverse-action-order",
            failureKinds: [.semanticConflict, .processUnsuccessfulResult, .processThrownError]
        ),
        .init(
            phase: "rollback-or-uninstall",
            operationKind: .compensationRegistryFlush,
            resourceDomain: "singleton-if-any-registry-delete-or-restore-attempted",
            failureKinds: [.processUnsuccessfulResult, .processThrownError]
        ),
        .init(
            phase: "rollback-or-uninstall",
            operationKind: .ownedFileDelete,
            resourceDomain: "each-actually-created-or-marker-owned-payload-reverse-action-order",
            failureKinds: [.semanticConflict, .filesystemThrow]
        ),
        .init(
            phase: "rollback-or-uninstall",
            operationKind: .ownedFileDeletionParentFSync,
            resourceDomain: "each-deleted-owned-payload-reverse-action-order",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "rollback-or-committed-cleanup",
            operationKind: .boundStageDelete,
            resourceDomain: "each-present-journal-bound-stage-reverse-path-order",
            failureKinds: [.semanticConflict, .filesystemThrow]
        ),
        .init(
            phase: "rollback-or-committed-cleanup-or-uninstall",
            operationKind: .plannedDirectoryDelete,
            resourceDomain: "each-lifecycle-created-directory-reverse-depth-order",
            failureKinds: [.semanticConflict, .directoryNotEmptyConflict, .filesystemThrow]
        ),
        .init(
            phase: "rollback-or-committed-cleanup-or-uninstall",
            operationKind: .plannedDirectoryDeletionContainingParentFSync,
            resourceDomain: "each-deleted-lifecycle-directory-reverse-depth-order",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "rollback-or-committed-cleanup-or-uninstall",
            operationKind: .adoptedStateVerification,
            resourceDomain: "singleton-complete-adopted-set",
            failureKinds: [.filesystemThrow, .semanticMismatch]
        ),
        .init(
            phase: "uninstall",
            operationKind: .markerDelete,
            resourceDomain: "singleton-valid-marker-after-owned-resource-removal",
            failureKinds: [.semanticConflict, .filesystemThrow]
        ),
        .init(
            phase: "uninstall",
            operationKind: .markerDeletionParentDirectoryFSync,
            resourceDomain: "singleton-marker-parent-after-deletion",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "terminal-cleanup",
            operationKind: .journalDelete,
            resourceDomain: "singleton-journal-last",
            failureKinds: [.filesystemThrow]
        ),
        .init(
            phase: "terminal-cleanup",
            operationKind: .journalDeletionParentDirectoryFSync,
            resourceDomain: "singleton-drive-c-after-journal-delete",
            failureKinds: [.filesystemThrow]
        )
    ]

    nonisolated static var failureKindMembershipCount: Int {
        specifications.reduce(0) { $0 + $1.failureKinds.count }
    }

    nonisolated static func specification(
        for operationKind: WindowsFontLifecycleOperationKind
    ) throws -> WindowsFontLifecycleOperationSpecification {
        guard let specification = specifications.first(where: {
            $0.operationKind == operationKind
        }) else {
            throw WindowsFontLifecycleProjectionError.unknownOperationKind(operationKind)
        }
        return specification
    }

    nonisolated static func instance(
        operationKind: WindowsFontLifecycleOperationKind,
        resourceIDOrPathID: String,
        ordinal: Int
    ) throws -> WindowsFontLifecycleOperationInstance {
        let specification = try specification(for: operationKind)
        let operationID = WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontLifecycleOperationFailureProjectionV2",
            fields: [
                specification.phase,
                operationKind.rawValue,
                resourceIDOrPathID,
                String(ordinal)
            ]
        )
        return WindowsFontLifecycleOperationInstance(
            operationID: operationID,
            phase: specification.phase,
            operationKind: operationKind,
            resourceDomain: specification.resourceDomain,
            resourceIDOrPathID: resourceIDOrPathID,
            ordinal: ordinal
        )
    }
}

struct WindowsFontLifecycleOperationProjection: Hashable, Sendable {
    var operationInstances: [WindowsFontLifecycleOperationInstance]
    var failureCases: [WindowsFontLifecycleFailureCase]
    var interruptionCases: [WindowsFontLifecycleInterruptionCase]

    nonisolated static func make(
        resourcesByOperationKind: [WindowsFontLifecycleOperationKind: [String]]
    ) throws -> Self {
        var instances: [WindowsFontLifecycleOperationInstance] = []
        for specification in WindowsFontLifecycleOperationRegistry.specifications {
            let resources = resourcesByOperationKind[specification.operationKind] ?? []
            guard Set(resources).count == resources.count else {
                var seen = Set<String>()
                let duplicate = resources.first(where: { !seen.insert($0).inserted }) ?? ""
                throw WindowsFontLifecycleProjectionError.duplicateResource(
                    specification.operationKind,
                    duplicate
                )
            }
            for (ordinal, resource) in resources.enumerated() {
                instances.append(try WindowsFontLifecycleOperationRegistry.instance(
                    operationKind: specification.operationKind,
                    resourceIDOrPathID: resource,
                    ordinal: ordinal
                ))
            }
        }
        let failures = try instances.flatMap { instance in
            try WindowsFontLifecycleOperationRegistry
                .specification(for: instance.operationKind)
                .failureKinds
                .map {
                    WindowsFontLifecycleFailureCase(
                        operationID: instance.operationID,
                        failureKind: $0
                    )
                }
        }
        let interruptions = instances.map {
            WindowsFontLifecycleInterruptionCase(
                operationID: $0.operationID,
                interruptAfterSuccessfulOperation: true
            )
        }
        return Self(
            operationInstances: instances,
            failureCases: failures,
            interruptionCases: interruptions
        )
    }

    nonisolated func validateExactEquality(
        resourcesByOperationKind: [WindowsFontLifecycleOperationKind: [String]]
    ) throws {
        let expected = try Self.make(resourcesByOperationKind: resourcesByOperationKind)
        guard operationInstances == expected.operationInstances else {
            throw WindowsFontLifecycleProjectionError.instanceMismatch
        }
        guard failureCases == expected.failureCases else {
            throw WindowsFontLifecycleProjectionError.failureCaseMismatch
        }
        guard interruptionCases == expected.interruptionCases else {
            throw WindowsFontLifecycleProjectionError.interruptionCaseMismatch
        }
    }

    nonisolated func validateExactConsumption(
        _ consumedOperations: [WindowsFontLifecycleOperationInstance]
    ) throws {
        guard consumedOperations == operationInstances else {
            throw WindowsFontLifecycleProjectionError.instanceMismatch
        }
    }
}

private enum WindowsFontCanonical {
    nonisolated static func digest(domain: String, fields: [String]) -> String {
        var data = Data(domain.utf8)
        for field in fields {
            data.append(0)
            data.append(contentsOf: field.utf8)
        }
        data.append(0x0a)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sortedUnique(_ values: [String]) -> Bool {
        values == Array(Set(values)).sorted()
    }

    nonisolated static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("\\") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

struct WindowsFontLifecycleDefinition: Hashable, Sendable {
    let profileIdentifier: String
    let payloads: [WindowsFontPayloadDescriptor]
    let registryRequirements: [WindowsFontRegistryRequirement]

    var payloadsInDescriptorOrder: [WindowsFontPayloadDescriptor] {
        payloads.sorted {
            $0.fileName.utf8.lexicographicallyPrecedes($1.fileName.utf8)
        }
    }

    var registryRequirementsInDescriptorOrder: [WindowsFontRegistryRequirement] {
        registryRequirements.sorted {
            let left = [
                $0.registryPath.lowercased(),
                $0.valueName.lowercased(),
                $0.valueType,
                $0.orderedValues.joined(separator: "\u{0}")
            ]
            let right = [
                $1.registryPath.lowercased(),
                $1.valueName.lowercased(),
                $1.valueType,
                $1.orderedValues.joined(separator: "\u{0}")
            ]
            return left.lexicographicallyPrecedes(right)
        }
    }

    var descriptorDigest: String {
        let resourceIDs = (
            payloads.map(\.descriptorID) + registryRequirements.map(\.descriptorID)
        ).sorted()
        return WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontLifecycleProfileDescriptorV1",
            fields: resourceIDs
        )
    }

    func payload(forID id: String) -> WindowsFontPayloadDescriptor? {
        payloads.first(where: { $0.descriptorID == id })
    }

    func registryRequirement(forID id: String) -> WindowsFontRegistryRequirement? {
        registryRequirements.first(where: { $0.descriptorID == id })
    }
}

private struct WindowsFontLifecycleMarker: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileIdentifier: String
    let descriptorDigest: String
    let ownedFileIDs: [String]
    let ownedRegistryIDs: [String]
    let createdDirectoryRelativePaths: [String]

    static let exactKeys: Set<String> = [
        "schemaVersion",
        "profileIdentifier",
        "descriptorDigest",
        "ownedFileIDs",
        "ownedRegistryIDs",
        "createdDirectoryRelativePaths"
    ]
}

private struct WindowsFontCommittedReconciliationPlan: Sendable {
    let originalMarker: WindowsFontLifecycleMarker
    let finalMarker: WindowsFontLifecycleMarker
    let registryRequirementsToApply: [WindowsFontRegistryRequirement]
    let journal: WindowsFontLifecycleJournal
}

private struct WindowsFontLifecycleJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileIdentifier: String
    let descriptorDigest: String
    let transactionID: String
    let operation: String
    let plannedOwnedFileIDs: [String]
    let plannedOwnedRegistryIDs: [String]
    let committedOwnedFileIDs: [String]
    let committedOwnedRegistryIDs: [String]
    let scratchRootRelativePath: String
    let payloadStageRelativePaths: [String]
    let markerStageRelativePath: String
    let plannedCreatedDirectoryRelativePaths: [String]
    let immutablePhase: String

    static let exactKeys: Set<String> = [
        "schemaVersion",
        "profileIdentifier",
        "descriptorDigest",
        "transactionID",
        "operation",
        "plannedOwnedFileIDs",
        "plannedOwnedRegistryIDs",
        "committedOwnedFileIDs",
        "committedOwnedRegistryIDs",
        "scratchRootRelativePath",
        "payloadStageRelativePaths",
        "markerStageRelativePath",
        "plannedCreatedDirectoryRelativePaths",
        "immutablePhase"
    ]

    func committing(fileID: String) throws -> Self {
        guard plannedOwnedFileIDs.contains(fileID) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return replacingCommittedOwnership(
            fileIDs: Array(Set(committedOwnedFileIDs + [fileID])).sorted(),
            registryIDs: committedOwnedRegistryIDs
        )
    }

    func committing(registryID: String) throws -> Self {
        guard plannedOwnedRegistryIDs.contains(registryID) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return replacingCommittedOwnership(
            fileIDs: committedOwnedFileIDs,
            registryIDs: Array(Set(committedOwnedRegistryIDs + [registryID])).sorted()
        )
    }

    private func replacingCommittedOwnership(
        fileIDs: [String],
        registryIDs: [String]
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            profileIdentifier: profileIdentifier,
            descriptorDigest: descriptorDigest,
            transactionID: transactionID,
            operation: operation,
            plannedOwnedFileIDs: plannedOwnedFileIDs,
            plannedOwnedRegistryIDs: plannedOwnedRegistryIDs,
            committedOwnedFileIDs: fileIDs,
            committedOwnedRegistryIDs: registryIDs,
            scratchRootRelativePath: scratchRootRelativePath,
            payloadStageRelativePaths: payloadStageRelativePaths,
            markerStageRelativePath: markerStageRelativePath,
            plannedCreatedDirectoryRelativePaths: plannedCreatedDirectoryRelativePaths,
            immutablePhase: immutablePhase
        )
    }
}

private struct WindowsFontLegacyV4RetirementJournal:
    Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileIdentifier: String
    let descriptorDigest: String
    let transactionID: String
    let baselineVariant: WindowsFontFreshBaselineVariant
    let phase: String

    static let exactKeys: Set<String> = [
        "schemaVersion",
        "profileIdentifier",
        "descriptorDigest",
        "transactionID",
        "baselineVariant",
        "phase"
    ]

    func preparingRegistryRetirement() -> Self {
        replacingPhase("retirement-prepared")
    }

    func committingRegistryRetirement() -> Self {
        replacingPhase("registry-committed")
    }

    private func replacingPhase(_ phase: String) -> Self {
        Self(
            schemaVersion: schemaVersion,
            profileIdentifier: profileIdentifier,
            descriptorDigest: descriptorDigest,
            transactionID: transactionID,
            baselineVariant: baselineVariant,
            phase: phase
        )
    }
}

private enum WindowsFontLifecycleJSON {
    static let maximumEvidenceByteCount = 1_048_576

    static func encodeCanonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    static func decodeCanonical<T: Codable & Equatable>(
        _ type: T.Type,
        data: Data,
        exactKeys: Set<String>
    ) throws -> T {
        guard !data.isEmpty,
              data.count <= maximumEvidenceByteCount,
              data.last == 0x0a,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == exactKeys else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let decoded: T
        do {
            decoded = try JSONDecoder().decode(type, from: data)
        } catch {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        guard try encodeCanonical(decoded) == data else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return decoded
    }
}

struct WindowsFontRegistrySnapshotState {
    let snapshot: WineUserRegistrySnapshot
    let duplicateKeys: Set<String>

    static func load(
        url: URL,
        fileManager: FileManager
    ) throws -> Self {
        let data = try WindowsFontLifecycleFileSystem.readRegularFile(
            at: url,
            maximumByteCount: 16 * 1_024 * 1_024
        )
        guard let contents = String(data: data, encoding: .utf8) else {
            throw WindowsFontCompatibilityProfileError.registrySnapshotMalformed(url)
        }
        var currentSection: String?
        var seen = Set<String>()
        var duplicates = Set<String>()
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else {
                continue
            }
            if line.hasPrefix("["), let closing = line.firstIndex(of: "]") {
                let section = String(line[line.index(after: line.startIndex)..<closing])
                currentSection = normalizedRegistryPath(section)
                continue
            }
            guard let currentSection,
                  line.hasPrefix("\""),
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let rawName = String(line[..<separator])
            let name = unquotedRegistryToken(rawName).lowercased()
            let key = "\(currentSection)\u{0}\(name)"
            if !seen.insert(key).inserted {
                duplicates.insert(key)
            }
        }
        return Self(
            snapshot: WineUserRegistrySnapshot(contents: contents),
            duplicateKeys: duplicates
        )
    }

    func orderedValues(for requirement: WindowsFontRegistryRequirement) -> [String]? {
        let key = "\(Self.normalizedRegistryPath(requirement.registryPath))\u{0}" +
            requirement.valueName.lowercased()
        guard !duplicateKeys.contains(key) else { return nil }
        if requirement.valueType == "REG_MULTI_SZ" {
            return snapshot.multiStringValues(
                forRegistryPath: requirement.registryPath,
                valueName: requirement.valueName
            )
        }
        guard let value = snapshot.value(
            forRegistryPath: requirement.registryPath,
            valueName: requirement.valueName
        ) else {
            return nil
        }
        return [value]
    }

    func containsValue(for requirement: WindowsFontRegistryRequirement) -> Bool {
        let key = "\(Self.normalizedRegistryPath(requirement.registryPath))\u{0}" +
            requirement.valueName.lowercased()
        guard !duplicateKeys.contains(key) else { return true }
        return snapshot.value(
            forRegistryPath: requirement.registryPath,
            valueName: requirement.valueName
        ) != nil
    }

    func stringValue(registryPath: String, valueName: String) -> String? {
        let key = "\(Self.normalizedRegistryPath(registryPath))\u{0}" +
            valueName.lowercased()
        guard !duplicateKeys.contains(key) else { return nil }
        return snapshot.value(
            forRegistryPath: registryPath,
            valueName: valueName
        )
    }

    func values(
        forRegistryPath registryPath: String
    ) -> [(name: String, value: String, isDuplicate: Bool)] {
        let normalizedPath = Self.normalizedRegistryPath(registryPath)
        return snapshot.values(forRegistryPath: registryPath).map { entry in
            (
                name: entry.name,
                value: entry.value,
                isDuplicate: duplicateKeys.contains(
                    "\(normalizedPath)\u{0}\(entry.name.lowercased())"
                )
            )
        }
    }

    private static func normalizedRegistryPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("hkcu\\") {
            normalized.removeFirst("HKCU\\".count)
        } else if normalized.lowercased().hasPrefix("hklm\\") {
            normalized.removeFirst("HKLM\\".count)
        }
        while normalized.contains("\\\\") {
            normalized = normalized.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return normalized.lowercased()
    }

    private static func unquotedRegistryToken(_ token: String) -> String {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}

enum WindowsFontCompatibilityProfileContract {
    nonisolated static let profileIdentifier = "forgeplay-windows-font-compatibility-v5"
    nonisolated static let legacyProfileIdentifier = "forgeplay-windows-font-compatibility-v4"

    nonisolated static let fontPayloads: [WindowsFontPayloadDescriptor] = [
        .init(
            sourceRole: .runtimeNanum,
            fileName: "NanumGothic-Regular.ttf",
            sha256: "76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31",
            registryDisplayName: "NanumGothic (TrueType)",
            registryFileTypeLabel: "TrueType"
        ),
        .init(
            sourceRole: .runtimeNanum,
            fileName: "NanumGothic-Bold.ttf",
            sha256: "21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2",
            registryDisplayName: "NanumGothic Bold (TrueType)",
            registryFileTypeLabel: "TrueType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSans-Regular.ttf",
            sha256: "478c558ea716033cd60c03438f628dfa75694dcf6b5f6d505a2f05fd2b4f3823",
            registryDisplayName: "Noto Sans (TrueType)",
            registryFileTypeLabel: "TrueType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSans-Bold.ttf",
            sha256: "1df075a380fc7cb898acf64c1f7b3b4dd780de3caa860178bf929de35817a913",
            registryDisplayName: "Noto Sans Bold (TrueType)",
            registryFileTypeLabel: "TrueType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKkr-Regular.otf",
            sha256: "6bcb2a0703aa137e874fc2dffa85f6c21ba9a67fa329e81b8c801663af7e992a",
            registryDisplayName: "Noto Sans CJK KR (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKkr-Bold.otf",
            sha256: "26d0c6748500a0444844280b308f5b62c7ae92ac6c6ac88148e502dd211eb52a",
            registryDisplayName: "Noto Sans CJK KR Bold (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKjp-Regular.otf",
            sha256: "68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5",
            registryDisplayName: "Noto Sans CJK JP (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKjp-Bold.otf",
            sha256: "e53dcb0dcb2922e45d01aae1ebd2f382bb81d4229b18b6b883bd170678af1f76",
            registryDisplayName: "Noto Sans CJK JP Bold (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKsc-Regular.otf",
            sha256: "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b",
            registryDisplayName: "Noto Sans CJK SC (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKsc-Bold.otf",
            sha256: "b5f0d1a190a7f9b43c310a8850630af12553df32c4c050543f9059732d9b4c0a",
            registryDisplayName: "Noto Sans CJK SC Bold (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKtc-Regular.otf",
            sha256: "dce08bd4fd91aa8aa76ed8fea4b694c2dfb8550f67871e326843212ddbeb88b4",
            registryDisplayName: "Noto Sans CJK TC (OpenType)",
            registryFileTypeLabel: "OpenType"
        ),
        .init(
            sourceRole: .appNotoPack,
            fileName: "NotoSansCJKtc-Bold.otf",
            sha256: "3ee160e5015106e3ec1a394301df54fa9bbbf8a251519984aec5c0abc50840c0",
            registryDisplayName: "Noto Sans CJK TC Bold (OpenType)",
            registryFileTypeLabel: "OpenType"
        )
    ]

    private nonisolated static let koreanFamilyAliases = [
        "Gulim",
        "GulimChe",
        "Dotum",
        "DotumChe",
        "Malgun Gothic",
        "Malgun Gothic Semilight",
        "Batang",
        "BatangChe",
        "Gungsuh",
        "GungsuhChe"
    ]

    nonisolated static let linkedLatinFamilies = [
        "Tahoma",
        "Arial",
        "Microsoft Sans Serif",
        "Segoe UI",
        "Verdana"
    ]
    nonisolated static let standardSubstitutionFamilies = ["MS Shell Dlg"]
    nonisolated static let wineDefaultTahomaSubstitutionFamilies = ["MS Shell Dlg 2"]
    nonisolated static let forcedReplacementFamilies = ["Tahoma"]
    nonisolated static let fontLinkFallbackFile = "NanumGothic-Regular.ttf"
    nonisolated static let linkedLatinFallbackFiles = [
        "NanumGothic-Regular.ttf",
        "NotoSans-Regular.ttf",
        "NotoSansCJKkr-Regular.otf",
        "NotoSansCJKjp-Regular.otf",
        "NotoSansCJKsc-Regular.otf",
        "NotoSansCJKtc-Regular.otf"
    ]
    nonisolated static let nanumFallbackFiles = [
        "NotoSans-Regular.ttf",
        "NotoSansCJKkr-Regular.otf",
        "NotoSansCJKjp-Regular.otf",
        "NotoSansCJKsc-Regular.otf",
        "NotoSansCJKtc-Regular.otf"
    ]
    nonisolated static let notoSansFallbackFiles = [
        "NanumGothic-Regular.ttf",
        "NotoSansCJKkr-Regular.otf",
        "NotoSansCJKjp-Regular.otf",
        "NotoSansCJKsc-Regular.otf",
        "NotoSansCJKtc-Regular.otf"
    ]

    nonisolated static let registryRequirements: [WindowsFontRegistryRequirement] = {
        let fontsPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
        let substitutesPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let linksPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
        let replacementsPath = "HKCU\\Software\\Wine\\Fonts\\Replacements"
        let forcedReplacementsPath = "HKCU\\Software\\Wine\\Fonts\\ForcedReplacements"

        let fontFiles = fontPayloads.map {
            WindowsFontRegistryRequirement(
                registryPath: fontsPath,
                valueName: $0.registryDisplayName,
                valueType: "REG_SZ",
                orderedValues: [$0.fileName]
            )
        }
        let replacements = koreanFamilyAliases.map {
            WindowsFontRegistryRequirement(
                registryPath: replacementsPath,
                valueName: $0,
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            )
        }
        let standardSubstitutions = standardSubstitutionFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: $0,
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            )
        }
        let wineDefaultSubstitutions = wineDefaultTahomaSubstitutionFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: $0,
                valueType: "REG_SZ",
                orderedValues: ["Tahoma"]
            )
        }
        let forcedReplacements = forcedReplacementFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: forcedReplacementsPath,
                valueName: $0,
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            )
        }
        let linkedLatin = linkedLatinFamilies.map {
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: $0,
                valueType: "REG_MULTI_SZ",
                orderedValues: linkedLatinFallbackFiles
            )
        }
        let nonSelfReferential = [
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: "NanumGothic",
                valueType: "REG_MULTI_SZ",
                orderedValues: nanumFallbackFiles
            ),
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: "Noto Sans",
                valueType: "REG_MULTI_SZ",
                orderedValues: notoSansFallbackFiles
            )
        ]
        return fontFiles + replacements + standardSubstitutions +
            wineDefaultSubstitutions + forcedReplacements + linkedLatin +
            nonSelfReferential
    }()

    /// Exact locale-dependent registry baselines emitted by the bundled Wine
    /// 11.12 `win32u` font code. Keep every ordered SystemLink closure exact:
    /// accepting one locale's shell font with another locale's link order
    /// would weaken the foreign-state collision boundary.
    private nonisolated static let bundledWineNonCJKSystemLinkBaseline = [
        "MSGOTHIC.TTC,MS UI Gothic",
        "MINGLIU.TTC,PMingLiU",
        "SIMSUN.TTC,SimSun",
        "GULIM.TTC,Gulim",
        "YUGOTHM.TTC,Yu Gothic UI",
        "MSJH.TTC,Microsoft JhengHei UI",
        "MSYH.TTC,Microsoft YaHei UI",
        "MALGUN.TTF,Malgun Gothic",
        "SEGUISYM.TTF,Segoe UI Symbol"
    ]

    private nonisolated static let bundledWineSimplifiedChineseSystemLinkBaseline = [
        "SIMSUN.TTC,SimSun",
        "MINGLIU.TTC,PMingLiu",
        "MSGOTHIC.TTC,MS UI Gothic",
        "BATANG.TTC,Batang",
        "MSYH.TTC,Microsoft YaHei UI",
        "MSJH.TTC,Microsoft JhengHei UI",
        "YUGOTHM.TTC,Yu Gothic UI",
        "MALGUN.TTF,Malgun Gothic",
        "SEGUISYM.TTF,Segoe UI Symbol"
    ]

    private nonisolated static let bundledWineTraditionalChineseSystemLinkBaseline = [
        "MINGLIU.TTC,PMingLiu",
        "SIMSUN.TTC,SimSun",
        "MSGOTHIC.TTC,MS UI Gothic",
        "BATANG.TTC,Batang",
        "MSJH.TTC,Microsoft JhengHei UI",
        "MSYH.TTC,Microsoft YaHei UI",
        "YUGOTHM.TTC,Yu Gothic UI",
        "MALGUN.TTF,Malgun Gothic",
        "SEGUISYM.TTF,Segoe UI Symbol"
    ]

    private nonisolated static let bundledWineKoreanSystemLinkBaseline = [
        "GULIM.TTC,Gulim",
        "MSGOTHIC.TTC,MS UI Gothic",
        "MINGLIU.TTC,PMingLiU",
        "SIMSUN.TTC,SimSun",
        "MALGUN.TTF,Malgun Gothic",
        "YUGOTHM.TTC,Yu Gothic UI",
        "MSJH.TTC,Microsoft JhengHei UI",
        "MSYH.TTC,Microsoft YaHei UI",
        "SEGUISYM.TTF,Segoe UI Symbol"
    ]

    private nonisolated static func makeFreshWineRegistryReplacementSet(
        systemLinkBaseline: [String],
        shellDialogBaseline: String
    ) -> [WindowsFontRegistryReplacementDescriptor] {
        let linksPath = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
        let substitutesPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let baselines = [
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: "Microsoft Sans Serif",
                valueType: "REG_MULTI_SZ",
                orderedValues: systemLinkBaseline
            ),
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: "Tahoma",
                valueType: "REG_MULTI_SZ",
                orderedValues: systemLinkBaseline
            ),
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: "MS Shell Dlg",
                valueType: "REG_SZ",
                orderedValues: [shellDialogBaseline]
            )
        ]
        let targets = [
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: "Microsoft Sans Serif",
                valueType: "REG_MULTI_SZ",
                orderedValues: linkedLatinFallbackFiles
            ),
            WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: "Tahoma",
                valueType: "REG_MULTI_SZ",
                orderedValues: linkedLatinFallbackFiles
            ),
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: "MS Shell Dlg",
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            )
        ]
        return zip(baselines, targets).map {
            WindowsFontRegistryReplacementDescriptor(
                baseline: $0.0,
                target: $0.1
            )
        }.sorted { $0.replacementID < $1.replacementID }
    }

    /// Latin, Western/Central/Eastern European, Cyrillic, Greek, Turkish,
    /// Hebrew, Baltic, Vietnamese, Thai and UTF-8 locales use this exact
    /// bundled-Wine baseline. This includes the United States, Canada, Spain,
    /// Germany and France.
    nonisolated static let freshWineRegistryReplacements =
        makeFreshWineRegistryReplacementSet(
            systemLinkBaseline: bundledWineNonCJKSystemLinkBaseline,
            shellDialogBaseline: "Tahoma"
        )

    nonisolated static let japaneseFreshWineRegistryReplacements =
        makeFreshWineRegistryReplacementSet(
            systemLinkBaseline: bundledWineNonCJKSystemLinkBaseline,
            shellDialogBaseline: "MS UI Gothic"
        )

    nonisolated static let simplifiedChineseFreshWineRegistryReplacements =
        makeFreshWineRegistryReplacementSet(
            systemLinkBaseline: bundledWineSimplifiedChineseSystemLinkBaseline,
            shellDialogBaseline: "SimSun"
        )

    nonisolated static let traditionalChineseFreshWineRegistryReplacements =
        makeFreshWineRegistryReplacementSet(
            systemLinkBaseline: bundledWineTraditionalChineseSystemLinkBaseline,
            shellDialogBaseline: "PMingLiU"
        )

    nonisolated static let arabicFreshWineRegistryReplacements =
        makeFreshWineRegistryReplacementSet(
            systemLinkBaseline: bundledWineNonCJKSystemLinkBaseline,
            shellDialogBaseline: "Microsoft Sans Serif"
        )

    /// This identifier is retained for marker/source compatibility. The same
    /// exact closure is also the current bundled-Wine Korean locale baseline.
    nonisolated static let previousFreshWineRegistryReplacements =
        makeFreshWineRegistryReplacementSet(
            systemLinkBaseline: bundledWineKoreanSystemLinkBaseline,
            shellDialogBaseline: "Gulim"
        )

    nonisolated static let freshWineRegistryReplacementSets:
        [[WindowsFontRegistryReplacementDescriptor]] = [
        freshWineRegistryReplacements,
        japaneseFreshWineRegistryReplacements,
        simplifiedChineseFreshWineRegistryReplacements,
        traditionalChineseFreshWineRegistryReplacements,
        previousFreshWineRegistryReplacements,
        arabicFreshWineRegistryReplacements
    ]

    nonisolated static let freshWineAlreadyTargetRequirements:
        [WindowsFontRegistryRequirement] = [
        WindowsFontRegistryRequirement(
            registryPath:
                "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes",
            valueName: "MS Shell Dlg 2",
            valueType: "REG_SZ",
            orderedValues: ["Tahoma"]
        )
    ]

    /// Exact registry state written by ForgePlay's previous v4 profile.  This
    /// is not a generic "single fallback" allowance: migration is authorized
    /// only when the complete v4 marker, both owned Nanum payloads, and this
    /// whole registry closure still match.
    nonisolated static let legacyV4RegistryReplacements:
        [WindowsFontRegistryReplacementDescriptor] = {
        let linksPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
        return linkedLatinFamilies.map { family in
            WindowsFontRegistryReplacementDescriptor(
                baseline: WindowsFontRegistryRequirement(
                    registryPath: linksPath,
                    valueName: family,
                    valueType: "REG_MULTI_SZ",
                    orderedValues: [fontLinkFallbackFile]
                ),
                target: WindowsFontRegistryRequirement(
                    registryPath: linksPath,
                    valueName: family,
                    valueType: "REG_MULTI_SZ",
                    orderedValues: linkedLatinFallbackFiles
                )
            )
        }.sorted { $0.replacementID < $1.replacementID }
    }()

    nonisolated static let legacyV4RegistryRequirements:
        [WindowsFontRegistryRequirement] = {
        let fontsPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
        let substitutesPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let replacementsPath = "HKCU\\Software\\Wine\\Fonts\\Replacements"
        let forcedReplacementsPath =
            "HKCU\\Software\\Wine\\Fonts\\ForcedReplacements"
        let fontFiles = fontPayloads
            .filter { $0.sourceRole == .runtimeNanum }
            .map {
                WindowsFontRegistryRequirement(
                    registryPath: fontsPath,
                    valueName: $0.registryDisplayName,
                    valueType: "REG_SZ",
                    orderedValues: [$0.fileName]
                )
            }
        let replacements = koreanFamilyAliases.map {
            WindowsFontRegistryRequirement(
                registryPath: replacementsPath,
                valueName: $0,
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            )
        }
        let substitutions = [
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: "MS Shell Dlg",
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            ),
            WindowsFontRegistryRequirement(
                registryPath: substitutesPath,
                valueName: "MS Shell Dlg 2",
                valueType: "REG_SZ",
                orderedValues: ["Tahoma"]
            )
        ]
        let forced = [
            WindowsFontRegistryRequirement(
                registryPath: forcedReplacementsPath,
                valueName: "Tahoma",
                valueType: "REG_SZ",
                orderedValues: ["NanumGothic"]
            )
        ]
        return (fontFiles + replacements + substitutions + forced +
            legacyV4RegistryReplacements.map(\.baseline))
            .sorted { $0.descriptorID < $1.descriptorID }
    }()

    nonisolated static let legacyV4MarkerData: Data = {
        let legacyPayloads = fontPayloads.filter {
            $0.sourceRole == .runtimeNanum
        }
        let lines = [legacyProfileIdentifier] + legacyPayloads.map {
            "\($0.fileName)=\($0.sha256)"
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }()

    nonisolated static let supportedRegistryReplacementSets:
        [[WindowsFontRegistryReplacementDescriptor]] =
        freshWineRegistryReplacementSets + [legacyV4RegistryReplacements]

    private nonisolated static func deduplicatedRegistryReplacements(
        _ sets: [[WindowsFontRegistryReplacementDescriptor]]
    ) -> [WindowsFontRegistryReplacementDescriptor] {
        var replacementsByID: [String: WindowsFontRegistryReplacementDescriptor] = [:]
        for replacement in sets.flatMap({ $0 }) {
            replacementsByID[replacement.replacementID] = replacement
        }
        return replacementsByID.values.sorted {
            $0.replacementID < $1.replacementID
        }
    }

    nonisolated static let supportedRegistryReplacements:
        [WindowsFontRegistryReplacementDescriptor] =
        deduplicatedRegistryReplacements(supportedRegistryReplacementSets)

    nonisolated static func freshWineReplacement(
        forReplacementID replacementID: String
    ) -> WindowsFontRegistryReplacementDescriptor? {
        freshWineRegistryReplacementSets.flatMap { $0 }.first {
            $0.replacementID == replacementID
        }
    }

    nonisolated static func freshWineReplacement(
        forTargetRequirementID targetRequirementID: String
    ) -> WindowsFontRegistryReplacementDescriptor? {
        freshWineRegistryReplacements.first {
            $0.target.descriptorID == targetRequirementID
        }
    }

    nonisolated static func supportedReplacement(
        forReplacementID replacementID: String
    ) -> WindowsFontRegistryReplacementDescriptor? {
        supportedRegistryReplacements.first {
            $0.replacementID == replacementID
        }
    }

    nonisolated static func registryOwnershipIDsAreValid(
        _ ids: [String],
        definition: WindowsFontLifecycleDefinition,
        allowsReplacements: Bool,
        requiresCompleteReplacementSet: Bool
    ) -> Bool {
        let requirementIDs = Set(definition.registryRequirements.map(\.descriptorID))
        let replacementSets = supportedRegistryReplacementSets.map { set in
            set.filter { requirementIDs.contains($0.target.descriptorID) }
        }.filter { !$0.isEmpty }
        let replacements = deduplicatedRegistryReplacements(replacementSets)
        let replacementsByID = Dictionary(uniqueKeysWithValues: replacements.map {
            ($0.replacementID, $0)
        })
        let replacementIDs = Set(ids.filter { replacementsByID[$0] != nil })
        let createdIDs = Set(ids).subtracting(replacementIDs)
        let allowedIDs = requirementIDs.union(Set(replacementsByID.keys))
        guard createdIDs.isSubset(of: requirementIDs),
              allowsReplacements || replacementIDs.isEmpty,
              Set(ids).isSubset(of: allowedIDs) else {
            return false
        }
        let replacedTargetIDs = Set(replacementIDs.compactMap {
            replacementsByID[$0]?.target.descriptorID
        })
        guard createdIDs.isDisjoint(with: replacedTargetIDs),
              replacedTargetIDs.count == replacementIDs.count else {
            return false
        }
        if !replacementIDs.isEmpty {
            let freshReplacementIDs = Set(
                freshWineRegistryReplacementSets.flatMap { $0 }.map(\.replacementID)
            )
            let usesOnlyFreshWineReplacements = replacementIDs.isSubset(
                of: freshReplacementIDs
            )
            let containingSets = replacementSets.filter {
                replacementIDs.isSubset(of: Set($0.map(\.replacementID)))
            }
            guard usesOnlyFreshWineReplacements || containingSets.count == 1 else {
                return false
            }
            if usesOnlyFreshWineReplacements {
                let requiredAnchorIDs = Set(
                    freshWineAlreadyTargetRequirements.map(\.descriptorID)
                )
                guard requiredAnchorIDs.isSubset(of: requirementIDs) else {
                    return false
                }
            }
        }
        if requiresCompleteReplacementSet, !replacementIDs.isEmpty {
            return replacementSets.contains {
                replacementIDs == Set($0.map(\.replacementID))
            }
        }
        return true
    }

    nonisolated static let definition = WindowsFontLifecycleDefinition(
        profileIdentifier: profileIdentifier,
        payloads: fontPayloads,
        registryRequirements: registryRequirements
    )

    /// Wine mirrors macOS system fonts into the Windows Fonts registry during
    /// prefix creation. When that exact host registration already owns the
    /// display name, ForgePlay keeps it and installs its deterministic payload
    /// alongside it instead of overwriting a system-owned value. Only Apple
    /// system/font-asset paths qualify; arbitrary foreign registry values still
    /// collide before mutation.
    nonisolated static func isAcceptedAppleHostFontRegistration(
        snapshot: WindowsFontRegistrySnapshotState,
        requirement: WindowsFontRegistryRequirement
    ) -> Bool {
        let fontsPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
        guard requirement.registryPath == fontsPath,
              requirement.valueType == "REG_SZ",
              fontPayloads.contains(where: {
                  $0.registryDisplayName == requirement.valueName
              }),
              let values = snapshot.orderedValues(for: requirement),
              values.count == 1 else {
            return false
        }
        let value = values[0].lowercased()
        return value.hasPrefix("z:\\system\\library\\fonts\\") ||
            value.hasPrefix(
                "z:\\system\\library\\assetsv2\\com_apple_mobileasset_font"
            ) ||
            value.hasPrefix("z:\\library\\fonts\\")
    }

    nonisolated static func isSatisfiedRegistryRequirement(
        snapshot: WindowsFontRegistrySnapshotState,
        requirement: WindowsFontRegistryRequirement
    ) -> Bool {
        snapshot.orderedValues(for: requirement) == requirement.orderedValues ||
            isAcceptedAppleHostFontRegistration(
                snapshot: snapshot,
                requirement: requirement
            )
    }

    /// A managed prefix may already contain a user-selected Noto build, or
    /// Wine may have projected a host-installed Noto family into its external
    /// font catalog. In either case, publishing ForgePlay's same-named family
    /// beside it makes Wine/DirectWrite face selection ambiguous. Preserve the
    /// external family when preparing a new profile; its presence alone does
    /// not prove complete multilingual coverage. A complete, already verified
    /// managed profile must not be retired merely because this catalog exists.
    nonisolated static func externalNotoOwnershipObservations(
        prefix: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let notoPayloads = fontPayloads.filter {
            $0.sourceRole == .appNotoPack
        }
        let fontsDirectory = windowsFontsDirectory(in: prefix)
        var observations: [String] = []

        var exactManagedFileNames = Set<String>()
        if try WindowsFontLifecycleFileSystem.lstatItem(fontsDirectory) != nil {
            try WindowsFontLifecycleFileSystem.requireDirectory(fontsDirectory)
            let entries = try fileManager.contentsOfDirectory(
                at: fontsDirectory,
                includingPropertiesForKeys: nil
            )
            for entry in entries where isManagedNotoFamilyName(
                entry.lastPathComponent
            ) {
                let normalizedFileName = entry.lastPathComponent.lowercased()
                let payload = notoPayloads.first {
                    $0.fileName.lowercased() == normalizedFileName
                }
                let status = try WindowsFontLifecycleFileSystem.lstatItem(entry)
                guard let status,
                      (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_nlink == 1 else {
                    observations.append(
                        externalNotoObservation(
                            domain: "prefix-unsafe-entry",
                            fields: [normalizedFileName]
                        )
                    )
                    continue
                }
                let digest = try WindowsFontLifecycleFileSystem
                    .sha256OfRegularFile(at: entry)
                if let payload, digest == payload.sha256 {
                    exactManagedFileNames.insert(normalizedFileName)
                    continue
                }
                observations.append(
                    externalNotoObservation(
                        domain: "prefix-file",
                        fields: [normalizedFileName, digest]
                    )
                )
            }
        }

        let userSnapshot = try WindowsFontRegistrySnapshotState.load(
            url: prefix.appending(path: "user.reg"),
            fileManager: fileManager
        )
        let systemSnapshot = try WindowsFontRegistrySnapshotState.load(
            url: prefix.appending(path: "system.reg"),
            fileManager: fileManager
        )
        let fontsPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
        let externalFontsPath = "HKCU\\Software\\Wine\\Fonts\\External Fonts"

        let exactRegistrations = Dictionary(uniqueKeysWithValues:
            notoPayloads.map {
                ($0.registryDisplayName.lowercased(), $0.fileName.lowercased())
            }
        )
        for entry in systemSnapshot.values(forRegistryPath: fontsPath) {
            let normalizedName = entry.name.lowercased()
            let normalizedValue = normalizedRegistryFontReference(entry.value)
            let isExactManagedRegistration =
                exactRegistrations[normalizedName] == normalizedValue &&
                exactManagedFileNames.contains(normalizedValue)
            guard !isExactManagedRegistration,
                  isManagedNotoFamilyName(entry.name) ||
                    isManagedNotoFamilyReference(entry.value) else {
                continue
            }
            observations.append(
                externalNotoObservation(
                    domain: entry.isDuplicate
                        ? "windows-registration-duplicate"
                        : "windows-registration",
                    fields: [normalizedName, normalizedValue]
                )
            )
        }

        for entry in userSnapshot.values(forRegistryPath: externalFontsPath)
            where isManagedNotoFamilyName(entry.name) ||
                isManagedNotoFamilyReference(entry.value) {
            observations.append(
                externalNotoObservation(
                    domain: entry.isDuplicate
                        ? "host-registration-duplicate"
                        : "host-registration",
                    fields: [
                        entry.name.lowercased(),
                        normalizedRegistryFontReference(entry.value)
                    ]
                )
            )
        }
        return Array(Set(observations)).sorted()
    }

    private nonisolated static func isManagedNotoFamilyReference(
        _ value: String
    ) -> Bool {
        isManagedNotoFamilyName(normalizedRegistryFontReference(value))
    }

    private nonisolated static func normalizedRegistryFontReference(
        _ value: String
    ) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "\\")
            .lowercased()
        while normalized.contains("\\\\") {
            normalized = normalized.replacingOccurrences(
                of: "\\\\",
                with: "\\"
            )
        }
        return normalized.split(separator: "\\").last.map(String.init) ??
            normalized
    }

    private nonisolated static func isManagedNotoFamilyName(
        _ name: String
    ) -> Bool {
        let lowercased = name.lowercased()
        guard [".ttf", ".otf", ".ttc"].contains(where: {
            lowercased.hasSuffix($0)
        }) || lowercased.contains("noto sans") else {
            return false
        }
        var familyAndStyle = lowercased
        for extensionSuffix in [".ttf", ".otf", ".ttc"]
            where familyAndStyle.hasSuffix(extensionSuffix) {
            familyAndStyle.removeLast(extensionSuffix.count)
            break
        }
        let canonical = familyAndStyle.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "truetype", with: "")
            .replacingOccurrences(of: "opentype", with: "")
        let familyBases = [
            "notosanscjkkr", "notosanscjkjp", "notosanscjksc",
            "notosanscjktc", "notosanscjk", "notosanskr",
            "notosansjp", "notosanssc", "notosanstc", "notosans"
        ]
        let styleSuffixes: Set<String> = [
            "", "regular", "bold", "italic", "bolditalic", "medium",
            "mediumitalic", "semibold", "semibolditalic", "light",
            "lightitalic", "extralight", "extralightitalic", "black",
            "blackitalic", "thin", "thinitalic", "demilight",
            "demilightitalic", "wght", "wdthwght", "variable",
            "variablefont", "variablefontwdthwght"
        ]
        for base in familyBases where canonical.hasPrefix(base) {
            let suffix = String(canonical.dropFirst(base.count))
            if styleSuffixes.contains(suffix) { return true }
        }
        return false
    }

    private nonisolated static func externalNotoObservation(
        domain: String,
        fields: [String]
    ) -> String {
        "\(domain):" +
            WindowsFontCanonical.digest(
                domain: "ForgePlayExternalNotoOwnershipObservationV1",
                fields: fields
            )
    }

    fileprivate nonisolated static let journalRelativePath =
        "drive_c/.forgeplay-windows-font-compatibility-v5.transaction.json"
    fileprivate nonisolated static let markerRelativePath =
        "drive_c/ForgePlay/FontCompatibility/forgeplay-windows-font-compatibility-v5.txt"

    nonisolated static func inspect(
        prefix: URL,
        fileManager: FileManager = .default,
        requiresProfileMarker: Bool = true,
        payloadHashObserver: ((URL) -> Void)? = nil
    ) -> WindowsFontCompatibilityInspection {
        var applied: [String] = []
        var missing: [String] = []
        let fontsDirectory = windowsFontsDirectory(in: prefix)

        for payload in definition.payloadsInDescriptorOrder {
            let destination = fontsDirectory.appending(path: payload.fileName)
            let label = "C:\\windows\\Fonts\\\(payload.fileName)=\(payload.sha256)"
            payloadHashObserver?(destination)
            if (try? WindowsFontLifecycleFileSystem.sha256OfRegularFile(at: destination)) ==
                payload.sha256 {
                applied.append(label)
            } else {
                missing.append(label)
            }
        }

        let userSnapshot = try? WindowsFontRegistrySnapshotState.load(
            url: prefix.appending(path: "user.reg"),
            fileManager: fileManager
        )
        let systemSnapshot = try? WindowsFontRegistrySnapshotState.load(
            url: prefix.appending(path: "system.reg"),
            fileManager: fileManager
        )
        for requirement in definition.registryRequirementsInDescriptorOrder {
            let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                ? userSnapshot
                : systemSnapshot
            if let snapshot,
               isSatisfiedRegistryRequirement(
                   snapshot: snapshot,
                   requirement: requirement
               ) {
                applied.append(requirement.label)
            } else {
                missing.append(requirement.label)
            }
        }

        if requiresProfileMarker {
            let markerLabel = "\(profileIdentifier)=managed"
            if let marker = try? readMarker(prefix: prefix),
               marker.profileIdentifier == profileIdentifier,
               marker.descriptorDigest == definition.descriptorDigest,
               [1, 2].contains(marker.schemaVersion) {
                applied.append(markerLabel)
            } else {
                missing.append(markerLabel)
            }
        }

        return WindowsFontCompatibilityInspection(
            appliedItems: applied.sorted(),
            missingItems: missing.sorted()
        )
    }

    nonisolated static func resourceDirectory(
        for runtimeExecutable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        runtimeResourceDirectory(for: runtimeExecutable, fileManager: fileManager)
    }

    nonisolated static func runtimeResourceDirectory(
        for runtimeExecutable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        let binDirectory = runtimeExecutable.deletingLastPathComponent()
        if binDirectory.lastPathComponent == "bin" {
            candidates.append(
                binDirectory.deletingLastPathComponent()
                    .appending(path: "share/wine/fonts", directoryHint: .isDirectory)
            )
        }
        for resourceURL in [
            Bundle.main.resourceURL,
            Bundle(for: WindowsFontCompatibilityBundleToken.self).resourceURL
        ].compactMap({ $0 }) {
            candidates.append(resourceURL.appending(
                path: "Runners/ForgePlayRuntime/wine/share/wine/fonts",
                directoryHint: .isDirectory
            ))
        }
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(sourceRoot.appending(
            path: "Resources/Runners/ForgePlayRuntime/wine/share/wine/fonts",
            directoryHint: .isDirectory
        ))
        #endif
        return firstAuthenticatedRoot(
            candidates,
            sourceRole: .runtimeNanum,
            fileManager: fileManager
        )
    }

    nonisolated static func appPackResourceDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [Bundle.main.resourceURL,
                          Bundle(for: WindowsFontCompatibilityBundleToken.self).resourceURL]
            .compactMap { $0 }
            .map {
                $0.appending(
                    path: "Fonts/ForgePlayNotoV1",
                    directoryHint: .isDirectory
                )
            }
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(sourceRoot.appending(
            path: "Resources/Fonts/ForgePlayNotoV1",
            directoryHint: .isDirectory
        ))
        #endif
        return firstAuthenticatedRoot(
            candidates,
            sourceRole: .appNotoPack,
            fileManager: fileManager
        )
    }

    fileprivate nonisolated static func resolvedSourceRoots(
        runtimeExecutable: URL,
        fileManager: FileManager
    ) throws -> [WindowsFontPayloadSourceRole: URL] {
        guard let runtime = runtimeResourceDirectory(
            for: runtimeExecutable,
            fileManager: fileManager
        ), let appPack = appPackResourceDirectory(fileManager: fileManager) else {
            throw WindowsFontCompatibilityProfileError.bundledPayloadMissing
        }
        return [.runtimeNanum: runtime, .appNotoPack: appPack]
    }

    fileprivate nonisolated static func windowsFontsDirectory(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/windows/Fonts", directoryHint: .isDirectory)
    }

    fileprivate nonisolated static func markerURL(in prefix: URL) -> URL {
        prefix.appending(path: markerRelativePath)
    }

    fileprivate nonisolated static func journalURL(in prefix: URL) -> URL {
        prefix.appending(path: journalRelativePath)
    }

    fileprivate nonisolated static func fontSourceURLs(in directory: URL) -> [URL] {
        fontPayloads
            .filter { $0.sourceRole == .runtimeNanum }
            .map { directory.appending(path: $0.fileName) }
    }

    private nonisolated static func firstAuthenticatedRoot(
        _ candidates: [URL],
        sourceRole: WindowsFontPayloadSourceRole,
        fileManager: FileManager
    ) -> URL? {
        let assigned = fontPayloads.filter { $0.sourceRole == sourceRole }
        var seen = Set<String>()
        return candidates.first { candidate in
            let normalized = candidate.standardizedFileURL
            guard seen.insert(normalized.path).inserted,
                  FileSystemItemPolicy.isNonSymlinkDirectory(
                    normalized,
                    fileManager: fileManager
                  ) else {
                return false
            }
            return assigned.allSatisfy {
                (try? WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                    at: normalized.appending(path: $0.fileName)
                )) == $0.sha256
            }
        }
    }

    private nonisolated static func readMarker(
        prefix: URL
    ) throws -> WindowsFontLifecycleMarker {
        let markerPath = markerURL(in: prefix)
        let data: Data
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: markerPath,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: markerPath,
                maximumByteCount: WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let marker = try WindowsFontLifecycleJSON.decodeCanonical(
            WindowsFontLifecycleMarker.self,
            data: data,
            exactKeys: WindowsFontLifecycleMarker.exactKeys
        )
        let payloadIDs = Set(definition.payloads.map(\.descriptorID))
        let allowedDirectories = Set([
            "windows/Fonts",
            "ForgePlay",
            "ForgePlay/FontCompatibility"
        ])
        guard [1, 2].contains(marker.schemaVersion),
              marker.profileIdentifier == profileIdentifier,
              marker.descriptorDigest == definition.descriptorDigest,
              WindowsFontCanonical.sortedUnique(marker.ownedFileIDs),
              WindowsFontCanonical.sortedUnique(marker.ownedRegistryIDs),
              Set(marker.ownedFileIDs).isSubset(of: payloadIDs),
              registryOwnershipIDsAreValid(
                marker.ownedRegistryIDs,
                definition: definition,
                allowsReplacements: marker.schemaVersion == 2,
                requiresCompleteReplacementSet: true
              ),
              WindowsFontCanonical.sortedUnique(marker.createdDirectoryRelativePaths),
              Set(marker.createdDirectoryRelativePaths)
                .isSubset(of: allowedDirectories) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return marker
    }
}

enum WindowsFontLocaleVariant: String, CaseIterable, Hashable, Sendable {
    case western
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case korean = "ko"

    nonisolated static func supportedWindowsLocale(
        identifier: String
    ) -> WindowsFontLocaleVariant? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        func hasRoot(_ root: String) -> Bool {
            normalized == root || normalized.hasPrefix("\(root)-")
        }
        if ["zh-hant", "zh-tw", "zh-hk", "zh-mo", "zh-cht"].contains(
            where: { hasRoot($0) }
        ) {
            return .traditionalChinese
        }
        if ["zh-hans", "zh-cn", "zh-sg", "zh-my", "zh-chs"].contains(
            where: { hasRoot($0) }
        ) {
            return .simplifiedChinese
        }
        if hasRoot("ja") { return .japanese }
        if hasRoot("ko") { return .korean }
        // A bare or unknown Chinese tag does not identify the script. Let the
        // coordinator use Wine's codepage signal instead of guessing Western.
        if hasRoot("zh") { return nil }
        // CJK locales use their script-specific ordering. Every other valid
        // locale intentionally uses the Western/English policy so a language
        // outside ForgePlay's localized catalog never disables font setup.
        return .western
    }
}

fileprivate enum WindowsFontFreshBaselineVariant:
    String, Codable, Hashable, Sendable {
    case western
    case japanese
    case simplifiedChinese
    case traditionalChinese
    case korean
    case unsupportedArabic

    static func retirementBaseline(
        fontCodepages: String
    ) -> WindowsFontFreshBaselineVariant? {
        let components = fontCodepages.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              components.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy {
                      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                  }
              }),
              let ansi = Int(components[0]),
              let oem = Int(components[1]),
              (1...65_535).contains(ansi),
              (1...65_535).contains(oem),
              String(ansi) == String(components[0]),
              String(oem) == String(components[1]) else {
            return nil
        }
        switch (ansi, oem) {
        case (932, 932):
            return .japanese
        case (936, 936):
            return .simplifiedChinese
        case (950, 950):
            return .traditionalChinese
        case (949, 949):
            return .korean
        case (1256, 720):
            return .unsupportedArabic
        case (1252, 437), (1252, 850), (65_001, 65_001),
             (1250, 852), (1251, 866), (1253, 737),
             (1254, 857), (1255, 862), (1257, 775),
             (1258, 1258), (874, 874):
            return .western
        default:
            return nil
        }
    }
}

fileprivate struct WindowsFontRegistryBaselineTransition: Hashable, Sendable {
    let baselineVariant: WindowsFontFreshBaselineVariant
    let sourceRequirements: [WindowsFontRegistryRequirement]
    let replacements: [WindowsFontRegistryReplacementDescriptor]
}

fileprivate struct WindowsFontLifecycleNamespace: Hashable, Sendable {
    let profileIdentifier: String

    var journalRelativePath: String {
        "drive_c/.\(profileIdentifier).transaction.json"
    }

    var driveCJournalRelativePath: String {
        ".\(profileIdentifier).transaction.json"
    }

    var markerRelativePath: String {
        "drive_c/ForgePlay/FontCompatibility/\(profileIdentifier).txt"
    }

    var driveCMarkerRelativePath: String {
        "ForgePlay/FontCompatibility/\(profileIdentifier).txt"
    }

    var scratchDirectoryRelativePath: String {
        ".\(profileIdentifier).scratch"
    }

    var markerStageFileName: String {
        "\(profileIdentifier).marker-stage"
    }
}

fileprivate struct WindowsFontLifecycleRuntimeContract: Sendable {
    let namespace: WindowsFontLifecycleNamespace
    let definition: WindowsFontLifecycleDefinition
    let freshBaselineTransitions: [WindowsFontRegistryBaselineTransition]
    let freshAlreadyTargetRequirements: [WindowsFontRegistryRequirement]
    let legacyV4RegistryReplacements: [WindowsFontRegistryReplacementDescriptor]
    let targetVariant: WindowsFontLocaleVariant?

    private var supportedReplacementSets:
        [[WindowsFontRegistryReplacementDescriptor]] {
        freshBaselineTransitions.map(\.replacements) +
            (legacyV4RegistryReplacements.isEmpty
                ? []
                : [legacyV4RegistryReplacements])
    }

    private var supportedReplacements:
        [WindowsFontRegistryReplacementDescriptor] {
        var byID: [String: WindowsFontRegistryReplacementDescriptor] = [:]
        for replacement in supportedReplacementSets.flatMap({ $0 }) {
            byID[replacement.replacementID] = replacement
        }
        return byID.values.sorted { $0.replacementID < $1.replacementID }
    }

    func supportedReplacement(
        forReplacementID replacementID: String
    ) -> WindowsFontRegistryReplacementDescriptor? {
        if targetVariant == nil {
            return WindowsFontCompatibilityProfileContract.supportedReplacement(
                forReplacementID: replacementID
            )
        }
        return supportedReplacements.first {
            $0.replacementID == replacementID
        }
    }

    func registryOwnershipIDsAreValid(
        _ ids: [String],
        allowsReplacements: Bool,
        requiresCompleteReplacementSet: Bool
    ) -> Bool {
        if targetVariant == nil {
            return WindowsFontCompatibilityProfileContract
                .registryOwnershipIDsAreValid(
                    ids,
                    definition: definition,
                    allowsReplacements: allowsReplacements,
                    requiresCompleteReplacementSet:
                        requiresCompleteReplacementSet
                )
        }
        let requirementIDs = Set(definition.registryRequirements.map(\.descriptorID))
        let replacementSets = supportedReplacementSets.map { set in
            set.filter { requirementIDs.contains($0.target.descriptorID) }
        }.filter { !$0.isEmpty }
        var replacementsByID: [String: WindowsFontRegistryReplacementDescriptor] = [:]
        for replacement in replacementSets.flatMap({ $0 }) {
            replacementsByID[replacement.replacementID] = replacement
        }
        let replacementIDs = Set(ids.filter { replacementsByID[$0] != nil })
        let createdIDs = Set(ids).subtracting(replacementIDs)
        let allowedIDs = requirementIDs.union(Set(replacementsByID.keys))
        guard createdIDs.isSubset(of: requirementIDs),
              allowsReplacements || replacementIDs.isEmpty,
              Set(ids).isSubset(of: allowedIDs) else {
            return false
        }
        let replacedTargetIDs = Set(replacementIDs.compactMap {
            replacementsByID[$0]?.target.descriptorID
        })
        guard createdIDs.isDisjoint(with: replacedTargetIDs),
              replacedTargetIDs.count == replacementIDs.count else {
            return false
        }
        if !replacementIDs.isEmpty {
            let freshIDs = Set(
                freshBaselineTransitions.flatMap(\.replacements).map(\.replacementID)
            )
            if replacementIDs.isSubset(of: freshIDs) {
                let requiredAnchorIDs = Set(
                    freshAlreadyTargetRequirements.map(\.descriptorID)
                )
                guard requiredAnchorIDs.isSubset(of: requirementIDs) else {
                    return false
                }
            } else {
                let containingSets = replacementSets.filter {
                    replacementIDs.isSubset(of: Set($0.map(\.replacementID)))
                }
                guard containingSets.count == 1 else { return false }
            }
        }
        if requiresCompleteReplacementSet, !replacementIDs.isEmpty {
            return replacementSets.contains {
                replacementIDs == Set($0.map(\.replacementID))
            }
        }
        return true
    }

    func baselineVariant(
        forOwnedRegistryIDs ownedRegistryIDs: [String]
    ) -> WindowsFontFreshBaselineVariant? {
        let owned = Set(ownedRegistryIDs)
        let matches = freshBaselineTransitions.filter { transition in
            let ids = Set(transition.replacements.map(\.replacementID))
            return !ids.isEmpty && ids.isSubset(of: owned)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].baselineVariant
    }

    static func frozenV5(
        definition: WindowsFontLifecycleDefinition =
            WindowsFontCompatibilityProfileContract.definition
    ) -> Self {
        let targetByKey = Dictionary(uniqueKeysWithValues:
            definition.registryRequirements.map {
                (Self.registryKey($0), $0)
            }
        )
        let transitions = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacementSets.compactMap { replacements ->
                WindowsFontRegistryBaselineTransition? in
                guard let variant = Self.baselineVariant(
                    sourceRequirements: replacements.map(\.baseline)
                ) else {
                    return nil
                }
                let applicable = replacements.compactMap { replacement in
                    targetByKey[Self.registryKey(replacement.target)].map { target in
                        WindowsFontRegistryReplacementDescriptor(
                            baseline: replacement.baseline,
                            target: target
                        )
                    }
                }
                return WindowsFontRegistryBaselineTransition(
                    baselineVariant: variant,
                    sourceRequirements: replacements.map(\.baseline),
                    replacements: applicable
                )
            }
        return Self(
            namespace: .init(
                profileIdentifier:
                    WindowsFontCompatibilityProfileContract.profileIdentifier
            ),
            definition: definition,
            freshBaselineTransitions: transitions,
            freshAlreadyTargetRequirements:
                WindowsFontCompatibilityProfileContract
                    .freshWineAlreadyTargetRequirements,
            legacyV4RegistryReplacements:
                WindowsFontCompatibilityProfileContract
                    .legacyV4RegistryReplacements.compactMap { replacement in
                    targetByKey[Self.registryKey(replacement.target)].map { target in
                        WindowsFontRegistryReplacementDescriptor(
                            baseline: replacement.baseline,
                            target: target
                        )
                    }
                },
            targetVariant: nil
        )
    }

    static func localeAwareV6(
        variant: WindowsFontLocaleVariant,
        definition definitionOverride: WindowsFontLifecycleDefinition? = nil
    ) -> Self {
        let definition = definitionOverride ??
            WindowsFontCompatibilityProfileV6Contract.definition(for: variant)
        let targetByKey = Dictionary(uniqueKeysWithValues:
            definition.registryRequirements.map {
                (Self.registryKey($0), $0)
            }
        )
        let transitions = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacementSets.compactMap { source ->
                WindowsFontRegistryBaselineTransition? in
                let sourceRequirements = source.map(\.baseline)
                guard let baselineVariant = Self.baselineVariant(
                    sourceRequirements: sourceRequirements
                ) else {
                    return nil
                }
                let replacements = sourceRequirements.compactMap { baseline ->
                    WindowsFontRegistryReplacementDescriptor? in
                    guard let target = targetByKey[Self.registryKey(baseline)],
                          target.descriptorID != baseline.descriptorID else {
                        return nil
                    }
                    return WindowsFontRegistryReplacementDescriptor(
                        baseline: baseline,
                        target: target
                    )
                }.sorted { $0.replacementID < $1.replacementID }
                return WindowsFontRegistryBaselineTransition(
                    baselineVariant: baselineVariant,
                    sourceRequirements: sourceRequirements,
                    replacements: replacements
                )
            }
        return Self(
            namespace: .init(
                profileIdentifier:
                    WindowsFontCompatibilityProfileV6Contract.profileIdentifier
            ),
            definition: definition,
            freshBaselineTransitions: transitions,
            freshAlreadyTargetRequirements:
                WindowsFontCompatibilityProfileContract
                    .freshWineAlreadyTargetRequirements,
            legacyV4RegistryReplacements: [],
            targetVariant: variant
        )
    }

    private static func registryKey(
        _ requirement: WindowsFontRegistryRequirement
    ) -> String {
        "\(requirement.registryPath.lowercased())\u{0}" +
            requirement.valueName.lowercased()
    }

    private static func baselineVariant(
        sourceRequirements: [WindowsFontRegistryRequirement]
    ) -> WindowsFontFreshBaselineVariant? {
        guard let shell = sourceRequirements.first(where: {
            $0.valueName == "MS Shell Dlg"
        })?.orderedValues.first else {
            return nil
        }
        switch shell {
        case "Tahoma": return .western
        case "MS UI Gothic": return .japanese
        case "SimSun": return .simplifiedChinese
        case "PMingLiU": return .traditionalChinese
        case "Gulim": return .korean
        case "Microsoft Sans Serif": return .unsupportedArabic
        default: return nil
        }
    }
}

enum WindowsFontCompatibilityProfileV6Contract {
    nonisolated static let profileIdentifier =
        "forgeplay-windows-font-compatibility-v6"

    private struct TargetPolicy: Sendable {
        let shellDialogFamily: String
        let linkedLatinFallbackFiles: [String]
    }

    private nonisolated static let definitionsByVariant:
        [WindowsFontLocaleVariant: WindowsFontLifecycleDefinition] =
        Dictionary(uniqueKeysWithValues: WindowsFontLocaleVariant.allCases.map {
            variant in
            (variant, makeDefinition(variant: variant))
        })

    nonisolated static let expectedAppliedItemCount: Int = {
        guard let count = definitionsByVariant.values.first.map({
            $0.payloads.count + $0.registryRequirements.count + 1
        }), definitionsByVariant.values.allSatisfy({
            $0.payloads.count + $0.registryRequirements.count + 1 == count
        }) else {
            return -1
        }
        return count
    }()

    nonisolated static func definition(
        for variant: WindowsFontLocaleVariant
    ) -> WindowsFontLifecycleDefinition {
        definitionsByVariant[variant]!
    }

    nonisolated static func variant(
        forDescriptorDigest descriptorDigest: String
    ) -> WindowsFontLocaleVariant? {
        definitionsByVariant.first {
            $0.value.descriptorDigest == descriptorDigest
        }?.key
    }

    nonisolated static func supportedVariant(
        localeIdentifier: String
    ) -> WindowsFontLocaleVariant? {
        WindowsFontLocaleVariant.supportedWindowsLocale(
            identifier: localeIdentifier
        )
    }

    private nonisolated static func makeDefinition(
        variant: WindowsFontLocaleVariant
    ) -> WindowsFontLifecycleDefinition {
        let policy = targetPolicy(for: variant)
        let linksPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
        let substitutesPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let replacementsPath = "HKCU\\Software\\Wine\\Fonts\\Replacements"
        let forcedReplacementsPath =
            "HKCU\\Software\\Wine\\Fonts\\ForcedReplacements"
        let nanumFile = "NanumGothic-Regular.ttf"
        let notoFile = "NotoSans-Regular.ttf"
        var requirements = WindowsFontCompatibilityProfileContract
            .registryRequirements.compactMap { requirement ->
                WindowsFontRegistryRequirement? in
                // v6 never replaces the whole Tahoma family. Locale-ordered
                // SystemLink supplies only missing glyphs, preserving Tahoma's
                // shaping for mixed-script and unsupported-language text.
                if requirement.registryPath == forcedReplacementsPath,
                   requirement.valueName == "Tahoma" {
                    return nil
                }
                if requirement.registryPath == replacementsPath {
                    return WindowsFontRegistryRequirement(
                        registryPath: replacementsPath,
                        valueName: requirement.valueName,
                        valueType: "REG_SZ",
                        orderedValues: ["Noto Sans CJK KR"]
                    )
                }
                if requirement.registryPath == linksPath,
                   WindowsFontCompatibilityProfileContract.linkedLatinFamilies
                    .contains(requirement.valueName) {
                    return WindowsFontRegistryRequirement(
                        registryPath: linksPath,
                        valueName: requirement.valueName,
                        valueType: "REG_MULTI_SZ",
                        orderedValues: policy.linkedLatinFallbackFiles
                    )
                }
                if requirement.registryPath == linksPath,
                   requirement.valueName == "NanumGothic" {
                    return WindowsFontRegistryRequirement(
                        registryPath: linksPath,
                        valueName: requirement.valueName,
                        valueType: "REG_MULTI_SZ",
                        orderedValues: policy.linkedLatinFallbackFiles.filter {
                            $0 != nanumFile
                        }
                    )
                }
                if requirement.registryPath == linksPath,
                   requirement.valueName == "Noto Sans" {
                    return WindowsFontRegistryRequirement(
                        registryPath: linksPath,
                        valueName: requirement.valueName,
                        valueType: "REG_MULTI_SZ",
                        orderedValues: policy.linkedLatinFallbackFiles.filter {
                            $0 != notoFile
                        }
                    )
                }
                if requirement.registryPath == substitutesPath,
                   requirement.valueName == "MS Shell Dlg" {
                    return WindowsFontRegistryRequirement(
                        registryPath: substitutesPath,
                        valueName: requirement.valueName,
                        valueType: "REG_SZ",
                        orderedValues: [policy.shellDialogFamily]
                    )
                }
                return requirement
            }
        let localizedNotoFamilies = [
            ("Noto Sans CJK JP", "NotoSansCJKjp-Regular.otf"),
            ("Noto Sans CJK SC", "NotoSansCJKsc-Regular.otf"),
            ("Noto Sans CJK TC", "NotoSansCJKtc-Regular.otf"),
            ("Noto Sans CJK KR", "NotoSansCJKkr-Regular.otf")
        ]
        requirements.append(contentsOf: localizedNotoFamilies.map { entry in
            let (family, ownFile) = entry
            return WindowsFontRegistryRequirement(
                registryPath: linksPath,
                valueName: family,
                valueType: "REG_MULTI_SZ",
                orderedValues: policy.linkedLatinFallbackFiles.filter {
                    $0 != ownFile
                }
            )
        })
        return WindowsFontLifecycleDefinition(
            profileIdentifier: profileIdentifier,
            payloads: WindowsFontCompatibilityProfileContract.fontPayloads,
            registryRequirements: requirements
        )
    }

    private nonisolated static func targetPolicy(
        for variant: WindowsFontLocaleVariant
    ) -> TargetPolicy {
        let latin = "NotoSans-Regular.ttf"
        let japanese = "NotoSansCJKjp-Regular.otf"
        let simplifiedChinese = "NotoSansCJKsc-Regular.otf"
        let traditionalChinese = "NotoSansCJKtc-Regular.otf"
        let korean = "NotoSansCJKkr-Regular.otf"
        let nanum = "NanumGothic-Regular.ttf"
        switch variant {
        case .western:
            return TargetPolicy(
                shellDialogFamily: "Tahoma",
                linkedLatinFallbackFiles: [
                    latin,
                    japanese,
                    traditionalChinese,
                    simplifiedChinese,
                    korean,
                    nanum
                ]
            )
        case .japanese:
            return TargetPolicy(
                shellDialogFamily: "Noto Sans CJK JP",
                linkedLatinFallbackFiles: [
                    latin,
                    japanese,
                    traditionalChinese,
                    simplifiedChinese,
                    korean,
                    nanum
                ]
            )
        case .simplifiedChinese:
            return TargetPolicy(
                shellDialogFamily: "Noto Sans CJK SC",
                linkedLatinFallbackFiles: [
                    latin,
                    simplifiedChinese,
                    traditionalChinese,
                    japanese,
                    korean,
                    nanum
                ]
            )
        case .traditionalChinese:
            return TargetPolicy(
                shellDialogFamily: "Noto Sans CJK TC",
                linkedLatinFallbackFiles: [
                    latin,
                    traditionalChinese,
                    simplifiedChinese,
                    japanese,
                    korean,
                    nanum
                ]
            )
        case .korean:
            return TargetPolicy(
                shellDialogFamily: "Noto Sans CJK KR",
                linkedLatinFallbackFiles: [
                    latin,
                    korean,
                    nanum,
                    japanese,
                    traditionalChinese,
                    simplifiedChinese
                ]
            )
        }
    }
}

enum WindowsFontCompatibilityProfileError: LocalizedError, Equatable {
    case bundledPayloadMissing
    case unsafeDestination(URL)
    case verificationFailed([String])
    case collision(String)
    case overlappingLifecycle(URL)
    case malformedLifecycleEvidence
    case registrySnapshotMalformed(URL)
    case journalDurabilityFailed(String)
    case cleanupDurabilityUnknown(String)
    case commitCleanupDurabilityUnknown(String)
    case uninstallDurabilityUnknown(String)
    case rollbackIncomplete(String, [String])
    case uninstallIncomplete(String, [String])
    case recoveryConflict(String)
    case operationProjectionMismatch(String)
    case interruptedAfterOperation(String)
    case filesystemFailure(String)

    var errorDescription: String? {
        switch self {
        case .bundledPayloadMissing:
            "번들 Windows 글꼴 payload가 없거나 무결성 검사를 통과하지 못했습니다."
        case .unsafeDestination(let url):
            "Windows 글꼴을 적용할 대상이 안전한 폴더가 아닙니다: \(url.path)"
        case .verificationFailed(let missing):
            "Windows 글꼴 호환성 적용을 확인하지 못했습니다: \(missing.joined(separator: ", "))"
        case .collision(let reason):
            "기존 Windows 글꼴 호환성 상태와 충돌합니다: \(reason)"
        case .overlappingLifecycle(let prefix):
            "같은 Windows prefix에서 글꼴 수명주기 작업이 이미 실행 중입니다: \(prefix.path)"
        case .malformedLifecycleEvidence:
            "Windows 글꼴 수명주기 기록이 정규 형식이 아니므로 자동 복구하지 않았습니다."
        case .registrySnapshotMalformed(let url):
            "Wine 레지스트리 snapshot을 안전하게 읽지 못했습니다: \(url.path)"
        case .journalDurabilityFailed(let reason):
            "Windows 글꼴 transaction 기록을 내구성 있게 확정하지 못했습니다: \(reason)"
        case .cleanupDurabilityUnknown(let reason):
            "Windows 글꼴 정리 완료의 디렉터리 내구성을 확인하지 못했습니다: \(reason)"
        case .commitCleanupDurabilityUnknown(let reason):
            "Windows 글꼴 commit marker의 디렉터리 내구성을 확인하지 못했습니다: \(reason)"
        case .uninstallDurabilityUnknown(let reason):
            "Windows 글꼴 제거 marker의 디렉터리 내구성을 확인하지 못했습니다: \(reason)"
        case .rollbackIncomplete(let reason, let remaining):
            "Windows 글꼴 rollback이 완료되지 않았습니다: \(reason). 남은 항목: \(remaining.joined(separator: ", "))"
        case .uninstallIncomplete(let reason, let remaining):
            "Windows 글꼴 제거가 완료되지 않았습니다: \(reason). 남은 항목: \(remaining.joined(separator: ", "))"
        case .recoveryConflict(let reason):
            "Windows 글꼴 자동 복구가 현재 상태와 충돌합니다: \(reason)"
        case .operationProjectionMismatch(let reason):
            "Windows 글꼴 수명주기 작업 projection이 일치하지 않습니다: \(reason)"
        case .interruptedAfterOperation(let operationID):
            "Windows 글꼴 수명주기 작업 직후 중단을 시뮬레이션했습니다: \(operationID)"
        case .filesystemFailure(let reason):
            "Windows 글꼴 파일 시스템 작업이 실패했습니다: \(reason)"
        }
    }
}

struct WindowsFontLifecycleExecutionHooks {
    typealias FilesystemOperationExecutor = (
        _ operation: WindowsFontLifecycleOperationInstance,
        _ body: () throws -> Void
    ) throws -> Void
    typealias RunnerActionExecutor = (
        _ operation: WindowsFontLifecycleOperationInstance,
        _ action: RunnerAction
    ) async throws -> ProcessRunResult
    typealias CompletionObserver = (
        _ operation: WindowsFontLifecycleOperationInstance
    ) throws -> Void

    var filesystemOperationExecutor: FilesystemOperationExecutor
    var runnerActionExecutor: RunnerActionExecutor
    var completionObserver: CompletionObserver

    static func production(runner: SafeProcessRunner) -> Self {
        Self(
            filesystemOperationExecutor: { _, body in try body() },
            runnerActionExecutor: { _, action in try await runner.run(action) },
            completionObserver: { _ in }
        )
    }
}

private enum WindowsFontLifecycleFileSystem {
    static let regularFileMode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
    static let evidenceFileMode: mode_t = S_IRUSR | S_IWUSR
    static let privateDirectoryMode: mode_t = S_IRWXU
    static let productDirectoryMode: mode_t =
        S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH

    static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw failure("open directory", url)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
        }
        return descriptor
    }

    static func requireStableRoot(
        descriptor: Int32,
        at root: URL
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              root.path.withCString({ Darwin.lstat($0, &pathStatus) }) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(root)
        }
    }

    static func openDirectory(
        relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32
    ) throws -> Int32 {
        try requireStableRoot(descriptor: rootDescriptor, at: root)
        guard WindowsFontCanonical.isSafeRelativePath(relativePath) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        var current = Darwin.openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard current >= 0 else {
            throw failure("duplicate root directory", root)
        }
        do {
            for component in relativePath.split(separator: "/").map(String.init) {
                let next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard next >= 0 else {
                    throw failure(
                        "open relative directory",
                        try relativeURL(relativePath, below: root)
                    )
                }
                Darwin.close(current)
                current = next
                var status = stat()
                guard fstat(current, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw WindowsFontCompatibilityProfileError.unsafeDestination(
                        try relativeURL(relativePath, below: root)
                    )
                }
            }
            try requireStableRoot(descriptor: rootDescriptor, at: root)
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func openParentDirectory(
        for relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32
    ) throws -> (descriptor: Int32, leaf: String, url: URL) {
        guard WindowsFontCanonical.isSafeRelativePath(relativePath) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.last else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let parentPath = components.dropLast().joined(separator: "/")
        let parentDescriptor: Int32
        if parentPath.isEmpty {
            try requireStableRoot(descriptor: rootDescriptor, at: root)
            parentDescriptor = Darwin.openat(
                rootDescriptor,
                ".",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        } else {
            parentDescriptor = try openDirectory(
                relativePath: parentPath,
                below: root,
                descriptor: rootDescriptor
            )
        }
        guard parentDescriptor >= 0 else {
            throw failure(
                "open relative parent",
                try relativeURL(relativePath, below: root)
            )
        }
        return (
            parentDescriptor,
            leaf,
            try relativeURL(relativePath, below: root)
        )
    }

    static func openContainingDirectory(
        for relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32
    ) throws -> Int32 {
        try openParentDirectory(
            for: relativePath,
            below: root,
            descriptor: rootDescriptor
        ).descriptor
    }

    static func createDirectory(
        relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32,
        mode: mode_t
    ) throws {
        let parent = try openParentDirectory(
            for: relativePath,
            below: root,
            descriptor: rootDescriptor
        )
        defer { Darwin.close(parent.descriptor) }
        let created = parent.leaf.withCString {
            Darwin.mkdirat(parent.descriptor, $0, mode)
        }
        guard created == 0 else {
            if errno == EEXIST {
                throw WindowsFontCompatibilityProfileError.collision(parent.url.path)
            }
            throw failure("relative mkdir", parent.url)
        }
        let createdDescriptor = parent.leaf.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard createdDescriptor >= 0 else {
            throw failure("open created relative directory", parent.url)
        }
        defer { Darwin.close(createdDescriptor) }
        guard Darwin.fchmod(createdDescriptor, mode) == 0 else {
            throw failure("relative directory mode", parent.url)
        }
        var status = stat()
        guard fstat(createdDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == mode else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(parent.url)
        }
        try requireStableRoot(descriptor: rootDescriptor, at: root)
    }

    static func openExclusiveRegularFile(
        relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32,
        mode: mode_t
    ) throws -> Int32 {
        let parent = try openParentDirectory(
            for: relativePath,
            below: root,
            descriptor: rootDescriptor
        )
        defer { Darwin.close(parent.descriptor) }
        let descriptor = parent.leaf.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw WindowsFontCompatibilityProfileError.collision(parent.url.path)
            }
            throw failure("relative exclusive create", parent.url)
        }
        guard Darwin.fchmod(descriptor, mode) == 0 else {
            let error = failure("relative exclusive file mode", parent.url)
            Darwin.close(descriptor)
            throw error
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == mode else {
            Darwin.close(descriptor)
            throw WindowsFontCompatibilityProfileError.unsafeDestination(parent.url)
        }
        try requireStableRoot(descriptor: rootDescriptor, at: root)
        return descriptor
    }

    static func fsyncDescriptor(_ descriptor: Int32, label: String) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw WindowsFontCompatibilityProfileError.filesystemFailure(
                "\(label): \(String(cString: strerror(errno)))"
            )
        }
    }

    static func closeDescriptor(_ descriptor: inout Int32, label: String) throws {
        let value = descriptor
        descriptor = -1
        guard value >= 0, Darwin.close(value) == 0 else {
            throw WindowsFontCompatibilityProfileError.filesystemFailure(
                "\(label): \(String(cString: strerror(errno)))"
            )
        }
    }

    static func lstatItem(_ url: URL) throws -> stat? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 { return status }
        if errno == ENOENT { return nil }
        throw failure("lstat", url)
    }

    static func requireAbsent(_ url: URL) throws {
        guard try lstatItem(url) == nil else {
            throw WindowsFontCompatibilityProfileError.collision(url.path)
        }
    }

    static func requireDirectory(_ url: URL) throws {
        guard let status = try lstatItem(url),
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw WindowsFontCompatibilityProfileError.filesystemFailure(
                        "complete write: \(String(cString: strerror(errno)))"
                    )
                }
                offset += written
            }
        }
    }

    static func readRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("open regular file", url) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= off_t(maximumByteCount) else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
        }
        var output = Data()
        output.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure("read", url) }
            if count == 0 { break }
            guard output.count <= maximumByteCount - count else {
                throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
            }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    static func verifyRegularFile(
        at url: URL,
        expectedData: Data,
        exactMode: mode_t
    ) throws {
        guard let status = try lstatItem(url),
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == exactMode else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
        }
        let data = try readRegularFile(
            at: url,
            maximumByteCount: max(expectedData.count, 1)
        )
        guard data == expectedData else {
            throw WindowsFontCompatibilityProfileError.verificationFailed([url.path])
        }
    }

    static func requireRegularFileMetadata(
        at url: URL,
        exactMode: mode_t
    ) throws {
        guard let status = try lstatItem(url),
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == exactMode else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
        }
    }

    static func sha256OfRegularFile(
        at url: URL,
        maximumByteCount: Int = 256 * 1_024 * 1_024
    ) throws -> String {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw failure("open regular file for hashing", url)
        }
        defer { Darwin.close(descriptor) }
        return try sha256OfRegularFileDescriptor(
            descriptor,
            url: url,
            maximumByteCount: maximumByteCount
        )
    }

    private static func sha256OfRegularFileDescriptor(
        _ descriptor: Int32,
        url: URL,
        maximumByteCount: Int = 256 * 1_024 * 1_024
    ) throws -> String {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= off_t(maximumByteCount) else {
            throw WindowsFontCompatibilityProfileError.unsafeDestination(url)
        }
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < status.st_size {
            let remaining = Int(status.st_size - offset)
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, requested, offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("relative pread", url) }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino,
              finalStatus.st_size == status.st_size,
              finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
              finalStatus.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
              finalStatus.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(url.path)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requireSameItem(
        _ descriptorStatus: stat,
        relativeLeaf leaf: String,
        parentDescriptor: Int32,
        url: URL
    ) throws {
        var pathStatus = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parentDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_mode == pathStatus.st_mode,
              descriptorStatus.st_nlink == pathStatus.st_nlink,
              descriptorStatus.st_size == pathStatus.st_size,
              descriptorStatus.st_mtimespec.tv_sec == pathStatus.st_mtimespec.tv_sec,
              descriptorStatus.st_mtimespec.tv_nsec == pathStatus.st_mtimespec.tv_nsec,
              descriptorStatus.st_ctimespec.tv_sec == pathStatus.st_ctimespec.tv_sec,
              descriptorStatus.st_ctimespec.tv_nsec == pathStatus.st_ctimespec.tv_nsec else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(url.path)
        }
    }

    static func publishNoReplace(
        fromRelativePath sourcePath: String,
        toRelativePath destinationPath: String,
        below root: URL,
        descriptor rootDescriptor: Int32,
        expectedSHA256: String
    ) throws -> (sourceParent: Int32, destinationParent: Int32) {
        let source = try openParentDirectory(
            for: sourcePath,
            below: root,
            descriptor: rootDescriptor
        )
        var sourceParentDescriptor = source.descriptor
        defer {
            if sourceParentDescriptor >= 0 { Darwin.close(sourceParentDescriptor) }
        }
        let destination = try openParentDirectory(
            for: destinationPath,
            below: root,
            descriptor: rootDescriptor
        )
        var destinationParentDescriptor = destination.descriptor
        defer {
            if destinationParentDescriptor >= 0 {
                Darwin.close(destinationParentDescriptor)
            }
        }
        let sourceDescriptor = source.leaf.withCString {
            Darwin.openat(source.descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            throw failure("open relative publication source", source.url)
        }
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG,
              sourceStatus.st_nlink == 1,
              try sha256OfRegularFileDescriptor(
                sourceDescriptor,
                url: source.url
              ) == expectedSHA256 else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(source.url.path)
        }
        try requireSameItem(
            sourceStatus,
            relativeLeaf: source.leaf,
            parentDescriptor: source.descriptor,
            url: source.url
        )
        var destinationStatus = stat()
        let destinationResult = destination.leaf.withCString {
            Darwin.fstatat(
                destination.descriptor,
                $0,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard destinationResult != 0, errno == ENOENT else {
            throw WindowsFontCompatibilityProfileError.collision(destination.url.path)
        }
        let result = source.leaf.withCString { sourceLeaf in
            destination.leaf.withCString { destinationLeaf in
                renameatx_np(
                    source.descriptor,
                    sourceLeaf,
                    destination.descriptor,
                    destinationLeaf,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw WindowsFontCompatibilityProfileError.collision(destination.url.path)
            }
            throw failure("relative no-overwrite publication", destination.url)
        }
        try requireStableRoot(descriptor: rootDescriptor, at: root)
        let resultDescriptors = (
            sourceParent: sourceParentDescriptor,
            destinationParent: destinationParentDescriptor
        )
        sourceParentDescriptor = -1
        destinationParentDescriptor = -1
        return resultDescriptors
    }

    static func exchangeRegularFiles(
        firstRelativePath: String,
        firstExpectedSHA256: String,
        secondRelativePath: String,
        secondExpectedSHA256: String,
        below root: URL,
        descriptor rootDescriptor: Int32
    ) throws {
        let first = try openParentDirectory(
            for: firstRelativePath,
            below: root,
            descriptor: rootDescriptor
        )
        defer { Darwin.close(first.descriptor) }
        let second = try openParentDirectory(
            for: secondRelativePath,
            below: root,
            descriptor: rootDescriptor
        )
        defer { Darwin.close(second.descriptor) }
        for entry in [
            (first.descriptor, first.leaf, first.url, firstExpectedSHA256),
            (second.descriptor, second.leaf, second.url, secondExpectedSHA256)
        ] {
            let descriptor = entry.1.withCString {
                Darwin.openat(entry.0, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw failure("open exchange input", entry.2) }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  try sha256OfRegularFileDescriptor(
                    descriptor,
                    url: entry.2,
                    maximumByteCount: WindowsFontLifecycleJSON.maximumEvidenceByteCount
                  ) == entry.3 else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(entry.2.path)
            }
            try requireSameItem(
                status,
                relativeLeaf: entry.1,
                parentDescriptor: entry.0,
                url: entry.2
            )
        }
        let result = first.leaf.withCString { firstLeaf in
            second.leaf.withCString { secondLeaf in
                renameatx_np(
                    first.descriptor,
                    firstLeaf,
                    second.descriptor,
                    secondLeaf,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else { throw failure("relative journal exchange", first.url) }
        try requireStableRoot(descriptor: rootDescriptor, at: root)
    }

    static func unlinkRegularFile(
        relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32,
        expectedSHA256: String? = nil
    ) throws {
        let parent = try openParentDirectory(
            for: relativePath,
            below: root,
            descriptor: rootDescriptor
        )
        defer { Darwin.close(parent.descriptor) }
        let descriptor = parent.leaf.withCString {
            Darwin.openat(parent.descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw failure("open relative unlink target", parent.url) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(parent.url.path)
        }
        if let expectedSHA256 {
            guard try sha256OfRegularFileDescriptor(
                descriptor,
                url: parent.url
            ) == expectedSHA256 else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(parent.url.path)
            }
        }
        try requireSameItem(
            status,
            relativeLeaf: parent.leaf,
            parentDescriptor: parent.descriptor,
            url: parent.url
        )
        let result = parent.leaf.withCString {
            Darwin.unlinkat(parent.descriptor, $0, 0)
        }
        guard result == 0 else { throw failure("relative unlink", parent.url) }
        try requireStableRoot(descriptor: rootDescriptor, at: root)
    }

    static func removeDirectory(
        relativePath: String,
        below root: URL,
        descriptor rootDescriptor: Int32
    ) throws {
        let parent = try openParentDirectory(
            for: relativePath,
            below: root,
            descriptor: rootDescriptor
        )
        defer { Darwin.close(parent.descriptor) }
        let descriptor = parent.leaf.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw failure("open relative rmdir target", parent.url) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(parent.url.path)
        }
        try requireSameItem(
            status,
            relativeLeaf: parent.leaf,
            parentDescriptor: parent.descriptor,
            url: parent.url
        )
        let result = parent.leaf.withCString {
            Darwin.unlinkat(parent.descriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "directory-not-empty: \(parent.url.path)"
                )
            }
            throw failure("relative rmdir", parent.url)
        }
        try requireStableRoot(descriptor: rootDescriptor, at: root)
    }

    static func relativeURL(_ relativePath: String, below driveC: URL) throws -> URL {
        guard WindowsFontCanonical.isSafeRelativePath(relativePath) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let result = driveC.appending(path: relativePath).standardizedFileURL
        let root = driveC.standardizedFileURL.path
        guard result.path.hasPrefix("\(root)/") else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return result
    }

    static func failure(_ operation: String, _ url: URL) -> Error {
        WindowsFontCompatibilityProfileError.filesystemFailure(
            "\(operation) \(url.path): \(String(cString: strerror(errno)))"
        )
    }
}

private struct WindowsFontLifecyclePreflightPlan {
    let profileIdentifier: String
    let descriptorDigest: String
    let transactionID: String
    let adoptedFileIDs: [String]
    let plannedOwnedFileIDs: [String]
    let adoptedRegistryIDs: [String]
    let plannedCreatedRegistryIDs: [String]
    let plannedReplacedRegistryIDs: [String]
    let persistentCreatedDirectoryRelativePaths: [String]
    let plannedCreatedDirectoryRelativePaths: [String]
    let scratchRootRelativePath: String
    let payloadStageRelativePaths: [String]
    let markerStageRelativePath: String
    let sourceURLsByPayloadID: [String: URL]

    var plannedRegistryMutationIDs: [String] {
        (plannedCreatedRegistryIDs + plannedReplacedRegistryIDs).sorted()
    }

    var journal: WindowsFontLifecycleJournal {
        WindowsFontLifecycleJournal(
            schemaVersion: 4,
            profileIdentifier: profileIdentifier,
            descriptorDigest: descriptorDigest,
            transactionID: transactionID,
            operation: "apply",
            plannedOwnedFileIDs: plannedOwnedFileIDs.sorted(),
            plannedOwnedRegistryIDs: plannedRegistryMutationIDs,
            committedOwnedFileIDs: [],
            committedOwnedRegistryIDs: [],
            scratchRootRelativePath: scratchRootRelativePath,
            payloadStageRelativePaths: payloadStageRelativePaths.sorted(),
            markerStageRelativePath: markerStageRelativePath,
            plannedCreatedDirectoryRelativePaths:
                plannedCreatedDirectoryRelativePaths,
            immutablePhase: "apply-prepared"
        )
    }
}

private struct WindowsFontLifecycleMutationLog {
    var createdFileIDs: [String] = []
    var createdRegistryIDs: [String] = []
    var replacedRegistryIDs: [String] = []
}

private struct WindowsFontLifecycleRemovalOutcome {
    var firstErrorDescription: String?
    var firstProcessResult: ProcessRunResult?
    var remainingIDs: [String] = []
    var terminalError: WindowsFontCompatibilityProfileError?

    var succeeded: Bool {
        firstErrorDescription == nil && firstProcessResult == nil && remainingIDs.isEmpty
    }

    mutating func record(error: Error, resourceID: String? = nil) {
        if firstErrorDescription == nil {
            firstErrorDescription = String(describing: error)
        }
        if terminalError == nil,
           let profileError = error as? WindowsFontCompatibilityProfileError {
            switch profileError {
            case .interruptedAfterOperation,
                 .cleanupDurabilityUnknown,
                 .commitCleanupDurabilityUnknown,
                 .uninstallDurabilityUnknown:
                terminalError = profileError
            default:
                break
            }
        }
        if let resourceID { remainingIDs.append(resourceID) }
    }

    mutating func record(result: ProcessRunResult, resourceID: String? = nil) {
        if firstProcessResult == nil { firstProcessResult = result }
        if let resourceID { remainingIDs.append(resourceID) }
    }
}

private struct WindowsFontVerifiedMutationResult {
    let unsuccessfulProcessResult: ProcessRunResult?
    let verifiedInspection: WindowsFontCompatibilityInspection?

    static func unsuccessful(
        _ result: ProcessRunResult
    ) -> WindowsFontVerifiedMutationResult {
        .init(
            unsuccessfulProcessResult: result,
            verifiedInspection: nil
        )
    }

    static func verified(
        _ inspection: WindowsFontCompatibilityInspection
    ) -> WindowsFontVerifiedMutationResult {
        .init(
            unsuccessfulProcessResult: nil,
            verifiedInspection: inspection
        )
    }
}

private struct WindowsFontLaunchConvergenceResult {
    let baseline: WindowsFontCompatibilityInspection?
    let verifiedFinal: WindowsFontCompatibilityInspection?
    let hadCommittedMarker: Bool
    let recoveredInterruptedLifecycle: Bool
    let unsuccessfulProcessResult: ProcessRunResult?
}

private struct WindowsFontLifecycleRepairResult {
    let didRepair: Bool
    let unsuccessfulProcessResult: ProcessRunResult?
    let verifiedInspection: WindowsFontCompatibilityInspection?

    static let notRequired = WindowsFontLifecycleRepairResult(
        didRepair: false,
        unsuccessfulProcessResult: nil,
        verifiedInspection: nil
    )
}

@MainActor
final class WindowsFontCompatibilityProfile {
    typealias SourceRootResolver = (
        _ runtimeExecutable: URL,
        _ fileManager: FileManager
    ) throws -> [WindowsFontPayloadSourceRole: URL]

    private static var activePrefixPaths = Set<String>()

    private let fileManager: FileManager
    private let definition: WindowsFontLifecycleDefinition
    private let lifecycleContract: WindowsFontLifecycleRuntimeContract
    private let sourceRootResolver: SourceRootResolver
    private let hooks: WindowsFontLifecycleExecutionHooks
    private let transactionIDProvider: () -> UUID
    private let payloadHashObserver: (URL) -> Void
    private let performsDetachedInspection: Bool
    private let productionCoordinator: WindowsFontCompatibilityProfileCoordinator?
    private(set) var consumedOperations: [WindowsFontLifecycleOperationInstance] = []

    init(runner: SafeProcessRunner, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        definition = WindowsFontCompatibilityProfileContract.definition
        lifecycleContract = .frozenV5()
        sourceRootResolver = { runtimeExecutable, fileManager in
            try WindowsFontCompatibilityProfileContract.resolvedSourceRoots(
                runtimeExecutable: runtimeExecutable,
                fileManager: fileManager
            )
        }
        hooks = .production(runner: runner)
        transactionIDProvider = UUID.init
        payloadHashObserver = { _ in }
        performsDetachedInspection = true
        productionCoordinator = WindowsFontCompatibilityProfileCoordinator(
            runner: runner,
            fileManager: fileManager
        )
    }

    init(
        fileManager: FileManager = .default,
        definition: WindowsFontLifecycleDefinition,
        sourceRootResolver: @escaping SourceRootResolver,
        hooks: WindowsFontLifecycleExecutionHooks,
        transactionIDProvider: @escaping () -> UUID = UUID.init,
        payloadHashObserver: @escaping (URL) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.definition = definition
        lifecycleContract = .frozenV5(definition: definition)
        self.sourceRootResolver = sourceRootResolver
        self.hooks = hooks
        self.transactionIDProvider = transactionIDProvider
        self.payloadHashObserver = payloadHashObserver
        performsDetachedInspection = false
        productionCoordinator = nil
    }

    init(
        fileManager: FileManager = .default,
        localeVariant: WindowsFontLocaleVariant,
        definition: WindowsFontLifecycleDefinition? = nil,
        sourceRootResolver: @escaping SourceRootResolver,
        hooks: WindowsFontLifecycleExecutionHooks,
        transactionIDProvider: @escaping () -> UUID = UUID.init,
        payloadHashObserver: @escaping (URL) -> Void = { _ in }
    ) {
        let contract = WindowsFontLifecycleRuntimeContract.localeAwareV6(
            variant: localeVariant,
            definition: definition
        )
        self.fileManager = fileManager
        self.definition = contract.definition
        lifecycleContract = contract
        self.sourceRootResolver = sourceRootResolver
        self.hooks = hooks
        self.transactionIDProvider = transactionIDProvider
        self.payloadHashObserver = payloadHashObserver
        performsDetachedInspection = false
        productionCoordinator = nil
    }

    fileprivate init(
        fileManager: FileManager,
        lifecycleContract: WindowsFontLifecycleRuntimeContract,
        sourceRootResolver: @escaping SourceRootResolver,
        hooks: WindowsFontLifecycleExecutionHooks,
        transactionIDProvider: @escaping () -> UUID = UUID.init,
        payloadHashObserver: @escaping (URL) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        definition = lifecycleContract.definition
        self.lifecycleContract = lifecycleContract
        self.sourceRootResolver = sourceRootResolver
        self.hooks = hooks
        self.transactionIDProvider = transactionIDProvider
        self.payloadHashObserver = payloadHashObserver
        performsDetachedInspection = true
        productionCoordinator = nil
    }

    func apply(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult? {
        if let productionCoordinator {
            return try await productionCoordinator.apply(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        let result = try await convergeForLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        return result.unsuccessfulProcessResult
    }

    private func convergeForLaunch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> WindowsFontLaunchConvergenceResult {
        let normalizedPrefix = prefix.standardizedFileURL
        try acquirePrefixGate(normalizedPrefix)
        defer { releasePrefixGate(normalizedPrefix) }
        consumedOperations.removeAll(keepingCapacity: true)

        let hadCommittedMarker = markerEntryExists(prefix: normalizedPrefix)

        let driveC = try validatedDriveC(in: normalizedPrefix)
        let driveCDescriptor = try WindowsFontLifecycleFileSystem.openDirectory(driveC)
        defer {
            if driveCDescriptor >= 0 { Darwin.close(driveCDescriptor) }
        }

        let repair = try await repairIfRequired(
            runtimeExecutable: runtimeExecutable,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            logDirectory: logDirectory
        )
        if let unsuccessful = repair.unsuccessfulProcessResult {
            return .init(
                baseline: nil,
                verifiedFinal: nil,
                hadCommittedMarker: hadCommittedMarker,
                recoveredInterruptedLifecycle: repair.didRepair,
                unsuccessfulProcessResult: unsuccessful
            )
        }
        if let verifiedRepair = repair.verifiedInspection {
            return .init(
                baseline: verifiedRepair,
                verifiedFinal: verifiedRepair,
                hadCommittedMarker: hadCommittedMarker,
                recoveredInterruptedLifecycle: true,
                unsuccessfulProcessResult: nil
            )
        }

        let baseline = await inspectForLaunch(
            prefix: normalizedPrefix,
            requiresProfileMarker: true
        )
        if baseline.isSatisfied {
            return .init(
                baseline: baseline,
                verifiedFinal: baseline,
                hadCommittedMarker: hadCommittedMarker,
                recoveredInterruptedLifecycle: repair.didRepair,
                unsuccessfulProcessResult: nil
            )
        }
        let markerURL = markerURL(in: normalizedPrefix)
        if try WindowsFontLifecycleFileSystem.lstatItem(markerURL) != nil {
            let marker = try readAndValidateMarker(prefix: normalizedPrefix)
            let plan = try makeCommittedReconciliationPlan(
                marker: marker,
                prefix: normalizedPrefix,
                driveC: driveC
            )
            try persistJournal(
                plan.journal,
                prefix: normalizedPrefix,
                driveCDescriptor: driveCDescriptor
            )
            let reconciliation = try await continueCommittedReconciliation(
                plan: plan,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                logDirectory: logDirectory
            )
            return .init(
                baseline: baseline,
                verifiedFinal: reconciliation.verifiedInspection,
                hadCommittedMarker: hadCommittedMarker,
                recoveredInterruptedLifecycle: repair.didRepair,
                unsuccessfulProcessResult:
                    reconciliation.unsuccessfulProcessResult
            )
        }

        let sourceRoots = try sourceRootResolver(runtimeExecutable, fileManager)
        let plan = try makeApplyPlan(
            prefix: normalizedPrefix,
            driveC: driveC,
            sourceRoots: sourceRoots
        )
        var journal = plan.journal
        try validate(journal: journal, driveC: driveC)

        do {
            try persistJournal(
                journal,
                prefix: normalizedPrefix,
                driveCDescriptor: driveCDescriptor
            )
        } catch let error as WindowsFontCompatibilityProfileError {
            if case .interruptedAfterOperation = error { throw error }
            throw WindowsFontCompatibilityProfileError.journalDurabilityFailed(
                String(describing: error)
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.journalDurabilityFailed(
                String(describing: error)
            )
        }

        var mutationLog = WindowsFontLifecycleMutationLog()
        var rollbackStarted = false
        do {
            try createPlannedDirectories(
                journal: journal,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor
            )
            try installPlannedPayloads(
                plan: plan,
                journal: &journal,
                prefix: normalizedPrefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                mutationLog: &mutationLog
            )

            if let unsuccessful = try await installPlannedRegistryValues(
                plan: plan,
                journal: &journal,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                logDirectory: logDirectory,
                mutationLog: &mutationLog
            ) {
                rollbackStarted = true
                try await rollback(
                    journal: journal,
                    runtimeExecutable: runtimeExecutable,
                    prefix: normalizedPrefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor,
                    logDirectory: logDirectory,
                    fileIDs: mutationLog.createdFileIDs,
                    registryIDs: mutationLog.createdRegistryIDs +
                        mutationLog.replacedRegistryIDs
                )
                return .init(
                    baseline: baseline,
                    verifiedFinal: nil,
                    hadCommittedMarker: hadCommittedMarker,
                    recoveredInterruptedLifecycle: repair.didRepair,
                    unsuccessfulProcessResult: unsuccessful
                )
            }

            let inspectionOperation = try operation(
                .markerFreeCompleteInspection,
                resource: definition.descriptorDigest,
                ordinal: 0
            )
            let markerFreeInspection = await inspectForLaunch(
                prefix: normalizedPrefix,
                requiresProfileMarker: false
            )
            try performFilesystem(inspectionOperation) {
                guard markerFreeInspection.isSatisfied else {
                    throw WindowsFontCompatibilityProfileError.verificationFailed(
                        markerFreeInspection.missingItems
                    )
                }
            }

            guard journal.committedOwnedFileIDs == journal.plannedOwnedFileIDs,
                  journal.committedOwnedRegistryIDs == journal.plannedOwnedRegistryIDs else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
            let marker = WindowsFontLifecycleMarker(
                schemaVersion: 2,
                profileIdentifier: definition.profileIdentifier,
                descriptorDigest: definition.descriptorDigest,
                ownedFileIDs: journal.committedOwnedFileIDs,
                ownedRegistryIDs: journal.committedOwnedRegistryIDs,
                createdDirectoryRelativePaths:
                    plan.persistentCreatedDirectoryRelativePaths.sorted()
            )
            try publishMarker(
                marker,
                journal: journal,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor
            )
            do {
                try fsyncMarkerParent(
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor,
                    operationKind: .markerParentDirectoryFSync
                )
            } catch let error as WindowsFontCompatibilityProfileError {
                if case .interruptedAfterOperation = error { throw error }
                throw WindowsFontCompatibilityProfileError
                    .commitCleanupDurabilityUnknown(String(describing: error))
            } catch {
                throw WindowsFontCompatibilityProfileError
                    .commitCleanupDurabilityUnknown(String(describing: error))
            }
        } catch let error as WindowsFontCompatibilityProfileError {
            switch error {
            case .commitCleanupDurabilityUnknown:
                throw error
            case .interruptedAfterOperation:
                throw error
            default:
                if rollbackStarted { throw error }
                if markerEntryExists(prefix: normalizedPrefix) {
                    throw WindowsFontCompatibilityProfileError
                        .commitCleanupDurabilityUnknown(String(describing: error))
                }
                rollbackStarted = true
                try await rollback(
                    journal: journal,
                    runtimeExecutable: runtimeExecutable,
                    prefix: normalizedPrefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor,
                    logDirectory: logDirectory,
                    fileIDs: mutationLog.createdFileIDs,
                    registryIDs: mutationLog.createdRegistryIDs +
                        mutationLog.replacedRegistryIDs
                )
                throw error
            }
        } catch {
            if rollbackStarted { throw error }
            if markerEntryExists(prefix: normalizedPrefix) {
                throw WindowsFontCompatibilityProfileError
                    .commitCleanupDurabilityUnknown(String(describing: error))
            }
            rollbackStarted = true
            try await rollback(
                journal: journal,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                logDirectory: logDirectory,
                fileIDs: mutationLog.createdFileIDs,
                registryIDs: mutationLog.createdRegistryIDs +
                    mutationLog.replacedRegistryIDs
            )
            throw error
        }

        let finalInspection = await inspectForLaunch(
            prefix: normalizedPrefix,
            requiresProfileMarker: true
        )
        let verifiedFinal = try cleanupCommittedApply(
            journal: journal,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            verifiedInspection: finalInspection
        )
        return .init(
            baseline: baseline,
            verifiedFinal: verifiedFinal,
            hadCommittedMarker: hadCommittedMarker,
            recoveredInterruptedLifecycle: repair.didRepair,
            unsuccessfulProcessResult: nil
        )
    }

    func provisionForLaunch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        preferredLocaleIdentifier: String? = nil
    ) async throws -> WindowsFontProvisioningApplicationReceipt {
        if let productionCoordinator {
            return try await productionCoordinator.provisionForLaunch(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory,
                preferredLocaleIdentifier: preferredLocaleIdentifier
            )
        }
        let convergence = try await convergeForLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        if let unsuccessful = convergence.unsuccessfulProcessResult {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                unsuccessful
            )
        }
        guard let baseline = convergence.baseline,
              let readback = convergence.verifiedFinal else {
            throw WindowsFontCompatibilityProfileError.verificationFailed([])
        }
        guard readback.isSatisfied else {
            throw WindowsFontCompatibilityProfileError.verificationFailed(
                readback.missingItems
            )
        }
        let receipt = WindowsFontProvisioningApplicationReceipt(
            profileIdentifier:
                definition.profileIdentifier,
            state: baseline.isSatisfied
                ? (convergence.recoveredInterruptedLifecycle
                    ? .reconciledAndVerified
                    : .reusedVerifiedProfile)
                : (convergence.hadCommittedMarker
                    ? .reconciledAndVerified
                    : .provisionedAndVerified),
            baselineDigest: Self.inspectionDigest(baseline),
            appliedDigest: Self.inspectionDigest(readback),
            appliedItemCount: readback.appliedItems.count,
            missingItemCount: readback.missingItems.count
        )
        guard receipt.missingItemCount == 0,
              receipt.appliedItemCount ==
                definition.payloads.count +
                definition.registryRequirements.count + 1,
              SteamLaunchIdentifierValidation.isValidLowercaseSHA256(
                  receipt.baselineDigest
              ),
              SteamLaunchIdentifierValidation.isValidLowercaseSHA256(
                  receipt.appliedDigest
              ) else {
            throw WindowsFontCompatibilityProfileError.verificationFailed(
                readback.missingItems
            )
        }
        return receipt
    }

    /// Returns a stable, path-free description of pre-existing font state
    /// that ForgePlay must preserve instead of replacing. This is a read-only
    /// preflight: a non-empty result selects whole-profile passthrough before
    /// any transaction journal or registry/file mutation is created.
    fileprivate func externalOwnershipObservations(
        prefix: URL
    ) throws -> [String] {
        let normalizedPrefix = prefix.standardizedFileURL
        if try WindowsFontLifecycleFileSystem.lstatItem(
            journalURL(in: normalizedPrefix)
        ) != nil {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "font-external-passthrough-with-active-transaction"
            )
        }
        if try WindowsFontLifecycleFileSystem.lstatItem(
            markerURL(in: normalizedPrefix)
        ) != nil {
            _ = try readAndValidateMarker(prefix: normalizedPrefix)
        }
        var observations: [String] = []
        let fontsDirectory = normalizedPrefix.appending(
            path: "drive_c/windows/Fonts",
            directoryHint: .isDirectory
        )
        for payload in definition.payloadsInDescriptorOrder {
            let destination = fontsDirectory.appending(path: payload.fileName)
            guard let status = try WindowsFontLifecycleFileSystem
                .lstatItem(destination) else {
                continue
            }
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1 else {
                throw WindowsFontCompatibilityProfileError
                    .unsafeDestination(destination)
            }
            let observedDigest = try WindowsFontLifecycleFileSystem
                .sha256OfRegularFile(at: destination)
            guard observedDigest != payload.sha256 else { continue }
            observations.append(
                WindowsFontCanonical.digest(
                    domain: "ForgePlayWindowsFontExternalPayloadV1",
                    fields: [
                        payload.fileName.lowercased(),
                        observedDigest
                    ]
                )
            )
        }

        let snapshots = try loadRegistrySnapshots(prefix: normalizedPrefix)
        let selectedReplacements = try selectedRegistryReplacementSet(
            prefix: normalizedPrefix,
            snapshots: snapshots
        ) ?? []
        for requirement in definition.registryRequirementsInDescriptorOrder {
            let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                ? snapshots.user
                : snapshots.system
            if WindowsFontCompatibilityProfileContract
                .isSatisfiedRegistryRequirement(
                    snapshot: snapshot,
                    requirement: requirement
                ) || !snapshot.containsValue(for: requirement) {
                continue
            }
            let isKnownBundledWineBaseline = selectedReplacements.contains {
                $0.target.descriptorID == requirement.descriptorID &&
                    snapshot.orderedValues(for: $0.baseline) ==
                        $0.baseline.orderedValues
            }
            guard !isKnownBundledWineBaseline else { continue }

            // Duplicate or type-mismatched registry data is not a readable
            // external preference. Leave it to the lifecycle engine's
            // existing fail-closed evidence checks.
            guard let values = snapshot.orderedValues(for: requirement) else {
                continue
            }
            observations.append(
                WindowsFontCanonical.digest(
                    domain: "ForgePlayWindowsFontExternalRegistryValueV1",
                    fields: [
                        requirement.registryPath.lowercased(),
                        requirement.valueName.lowercased(),
                        "present-readable"
                    ] + values
                )
            )
        }
        return Array(Set(observations)).sorted()
    }

    func uninstall(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult? {
        if let productionCoordinator {
            return try await productionCoordinator.uninstall(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        let normalizedPrefix = prefix.standardizedFileURL
        try acquirePrefixGate(normalizedPrefix)
        defer { releasePrefixGate(normalizedPrefix) }
        consumedOperations.removeAll(keepingCapacity: true)

        let driveC = try validatedDriveC(in: normalizedPrefix)
        let driveCDescriptor = try WindowsFontLifecycleFileSystem.openDirectory(driveC)
        defer {
            if driveCDescriptor >= 0 { Darwin.close(driveCDescriptor) }
        }

        let repair = try await repairIfRequired(
            runtimeExecutable: runtimeExecutable,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            logDirectory: logDirectory
        )
        if let unsuccessful = repair.unsuccessfulProcessResult {
            return unsuccessful
        }

        let markerPath = markerURL(in: normalizedPrefix)
        guard try WindowsFontLifecycleFileSystem.lstatItem(markerPath) != nil else {
            return nil
        }
        let marker = try readAndValidateMarker(prefix: normalizedPrefix)
        let inspection = inspect(prefix: normalizedPrefix, requiresProfileMarker: true)
        guard inspection.isSatisfied else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                inspection.missingItems.joined(separator: ", ")
            )
        }
        if restoresLegacyV4Baseline(registryIDs: marker.ownedRegistryIDs),
           !legacyV4BaselineFilesAreAuthorized(prefix: normalizedPrefix) {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "legacy-v4-font-profile-baseline-evidence-mismatch"
            )
        }

        let transactionID = transactionIDProvider().uuidString.lowercased()
        let scratchRoot = scratchRootRelativePath(transactionID: transactionID)
        let journal = WindowsFontLifecycleJournal(
            schemaVersion: marker.schemaVersion == 2 ? 4 : 3,
            profileIdentifier: definition.profileIdentifier,
            descriptorDigest: definition.descriptorDigest,
            transactionID: transactionID,
            operation: "uninstall",
            plannedOwnedFileIDs: marker.ownedFileIDs,
            plannedOwnedRegistryIDs: marker.ownedRegistryIDs,
            committedOwnedFileIDs: marker.ownedFileIDs,
            committedOwnedRegistryIDs: marker.ownedRegistryIDs,
            scratchRootRelativePath: scratchRoot,
            payloadStageRelativePaths: [],
            markerStageRelativePath:
                "\(scratchRoot)/marker/" +
                lifecycleContract.namespace.markerStageFileName,
            plannedCreatedDirectoryRelativePaths:
                marker.createdDirectoryRelativePaths,
            immutablePhase: "uninstall-prepared"
        )
        try validate(journal: journal, driveC: driveC)
        do {
            try persistJournal(
                journal,
                prefix: normalizedPrefix,
                driveCDescriptor: driveCDescriptor
            )
        } catch let error as WindowsFontCompatibilityProfileError {
            if case .interruptedAfterOperation = error { throw error }
            throw WindowsFontCompatibilityProfileError.journalDurabilityFailed(
                String(describing: error)
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.journalDurabilityFailed(
                String(describing: error)
            )
        }

        let outcome = await removeOwnedResources(
            journal: journal,
            runtimeExecutable: runtimeExecutable,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            logDirectory: logDirectory,
            fileIDs: marker.ownedFileIDs,
            registryIDs: marker.ownedRegistryIDs,
            removeMarkerWhenComplete: true
        )
        if let terminalError = outcome.terminalError { throw terminalError }
        if let result = outcome.firstProcessResult { return result }
        guard outcome.succeeded else {
            throw WindowsFontCompatibilityProfileError.uninstallIncomplete(
                outcome.firstErrorDescription ?? "unknown",
                Array(Set(outcome.remainingIDs)).sorted()
            )
        }

        try deleteJournalAndSynchronizeParent(
            journal: journal,
            prefix: normalizedPrefix,
            driveCDescriptor: driveCDescriptor
        )
        return nil
    }

    fileprivate func verifiedReceiptWithoutMutation(
        prefix: URL
    ) async throws -> WindowsFontProvisioningApplicationReceipt {
        let inspection = await inspectForLaunch(
            prefix: prefix.standardizedFileURL,
            requiresProfileMarker: true
        )
        guard inspection.isSatisfied else {
            throw WindowsFontCompatibilityProfileError.verificationFailed(
                inspection.missingItems
            )
        }
        let digest = Self.inspectionDigest(inspection)
        return WindowsFontProvisioningApplicationReceipt(
            profileIdentifier: definition.profileIdentifier,
            state: .reusedVerifiedProfile,
            baselineDigest: digest,
            appliedDigest: digest,
            appliedItemCount: inspection.appliedItems.count,
            missingItemCount: 0
        )
    }

    private func acquirePrefixGate(_ prefix: URL) throws {
        guard Self.activePrefixPaths.insert(prefix.path).inserted else {
            throw WindowsFontCompatibilityProfileError.overlappingLifecycle(prefix)
        }
    }

    private func releasePrefixGate(_ prefix: URL) {
        Self.activePrefixPaths.remove(prefix.path)
    }

    private func markerEntryExists(prefix: URL) -> Bool {
        do {
            return try WindowsFontLifecycleFileSystem.lstatItem(
                markerURL(in: prefix)
            ) != nil
        } catch {
            return true
        }
    }

    private func operation(
        _ kind: WindowsFontLifecycleOperationKind,
        resource: String,
        ordinal: Int
    ) throws -> WindowsFontLifecycleOperationInstance {
        try WindowsFontLifecycleOperationRegistry.instance(
            operationKind: kind,
            resourceIDOrPathID: resource,
            ordinal: ordinal
        )
    }

    private func performFilesystem(
        _ operation: WindowsFontLifecycleOperationInstance,
        _ body: () throws -> Void
    ) throws {
        let expected = try WindowsFontLifecycleOperationRegistry.specification(
            for: operation.operationKind
        )
        guard expected.phase == operation.phase,
              expected.resourceDomain == operation.resourceDomain else {
            throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                operation.operationID
            )
        }
        consumedOperations.append(operation)
        try hooks.filesystemOperationExecutor(operation, body)
        try hooks.completionObserver(operation)
    }

    private func performRunnerAction(
        _ operation: WindowsFontLifecycleOperationInstance,
        _ action: RunnerAction
    ) async throws -> ProcessRunResult {
        let expected = try WindowsFontLifecycleOperationRegistry.specification(
            for: operation.operationKind
        )
        guard expected.phase == operation.phase,
              expected.resourceDomain == operation.resourceDomain else {
            throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                operation.operationID
            )
        }
        consumedOperations.append(operation)
        let result = try await hooks.runnerActionExecutor(operation, action)
        try hooks.completionObserver(operation)
        return result
    }

    private func validatedDriveC(in prefix: URL) throws -> URL {
        try WindowsFontLifecycleFileSystem.requireDirectory(prefix)
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let windows = driveC.appending(path: "windows", directoryHint: .isDirectory)
        try WindowsFontLifecycleFileSystem.requireDirectory(driveC)
        try WindowsFontLifecycleFileSystem.requireDirectory(windows)
        return driveC
    }

    private func inspect(
        prefix: URL,
        requiresProfileMarker: Bool
    ) -> WindowsFontCompatibilityInspection {
        if definition == WindowsFontCompatibilityProfileContract.definition {
            return WindowsFontCompatibilityProfileContract.inspect(
                prefix: prefix,
                fileManager: fileManager,
                requiresProfileMarker: requiresProfileMarker,
                payloadHashObserver: payloadHashObserver
            )
        }
        return inspectDefinition(
            prefix: prefix,
            requiresProfileMarker: requiresProfileMarker
        )
    }

    /// Routine launch admission spends most of its time authenticating the
    /// installed payload bytes. Keep that descriptor-bound streaming work off
    /// the main actor. Custom lifecycle fixtures retain their observer seam and
    /// execute synchronously so operation accounting remains deterministic.
    private func inspectForLaunch(
        prefix: URL,
        requiresProfileMarker: Bool
    ) async -> WindowsFontCompatibilityInspection {
        guard performsDetachedInspection else {
            return inspect(
                prefix: prefix,
                requiresProfileMarker: requiresProfileMarker
            )
        }
        let normalizedPrefix = prefix.standardizedFileURL
        if definition != WindowsFontCompatibilityProfileContract.definition {
            let capturedDefinition = definition
            let capturedContract = lifecycleContract
            return await Task.detached(priority: .utility) {
                Self.inspectDefinition(
                    definition: capturedDefinition,
                    lifecycleContract: capturedContract,
                    prefix: normalizedPrefix,
                    fileManager: FileManager(),
                    requiresProfileMarker: requiresProfileMarker
                )
            }.value
        }
        return await Task.detached(priority: .utility) {
            WindowsFontCompatibilityProfileContract.inspect(
                prefix: normalizedPrefix,
                fileManager: FileManager(),
                requiresProfileMarker: requiresProfileMarker
            )
        }.value
    }

    private nonisolated static func inspectionDigest(
        _ inspection: WindowsFontCompatibilityInspection
    ) -> String {
        var data = Data("forgeplay-windows-font-inspection-v1\n".utf8)
        for value in inspection.appliedItems.sorted() {
            data.append(contentsOf: "applied=\(value.utf8.count):".utf8)
            data.append(contentsOf: value.utf8)
            data.append(10)
        }
        for value in inspection.missingItems.sorted() {
            data.append(contentsOf: "missing=\(value.utf8.count):".utf8)
            data.append(contentsOf: value.utf8)
            data.append(10)
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func inspectDefinition(
        prefix: URL,
        requiresProfileMarker: Bool
    ) -> WindowsFontCompatibilityInspection {
        Self.inspectDefinition(
            definition: definition,
            lifecycleContract: lifecycleContract,
            prefix: prefix,
            fileManager: fileManager,
            requiresProfileMarker: requiresProfileMarker,
            payloadHashObserver: payloadHashObserver
        )
    }

    private nonisolated static func inspectDefinition(
        definition: WindowsFontLifecycleDefinition,
        lifecycleContract: WindowsFontLifecycleRuntimeContract,
        prefix: URL,
        fileManager: FileManager,
        requiresProfileMarker: Bool,
        payloadHashObserver: ((URL) -> Void)? = nil
    ) -> WindowsFontCompatibilityInspection {
        var applied: [String] = []
        var missing: [String] = []
        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        for payload in definition.payloadsInDescriptorOrder {
            let destination = fonts.appending(path: payload.fileName)
            payloadHashObserver?(destination)
            if (try? WindowsFontLifecycleFileSystem.sha256OfRegularFile(at: destination)) ==
                payload.sha256 {
                applied.append(payload.descriptorID)
            } else {
                missing.append(payload.descriptorID)
            }
        }
        let snapshots: (
            user: WindowsFontRegistrySnapshotState,
            system: WindowsFontRegistrySnapshotState
        )? = try? (
            WindowsFontRegistrySnapshotState.load(
                url: prefix.appending(path: "user.reg"),
                fileManager: fileManager
            ),
            WindowsFontRegistrySnapshotState.load(
                url: prefix.appending(path: "system.reg"),
                fileManager: fileManager
            )
        )
        for requirement in definition.registryRequirementsInDescriptorOrder {
            let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                ? snapshots?.user
                : snapshots?.system
            if let snapshot,
               WindowsFontCompatibilityProfileContract
                .isSatisfiedRegistryRequirement(
                    snapshot: snapshot,
                    requirement: requirement
                ) {
                applied.append(requirement.descriptorID)
            } else {
                missing.append(requirement.descriptorID)
            }
        }
        if requiresProfileMarker {
            if markerIsValid(
                definition: definition,
                lifecycleContract: lifecycleContract,
                prefix: prefix
            ) {
                applied.append(definition.profileIdentifier)
            } else {
                missing.append(definition.profileIdentifier)
            }
        }
        return .init(appliedItems: applied.sorted(), missingItems: missing.sorted())
    }

    private nonisolated static func markerIsValid(
        definition: WindowsFontLifecycleDefinition,
        lifecycleContract: WindowsFontLifecycleRuntimeContract,
        prefix: URL
    ) -> Bool {
        let markerPath = prefix.appending(
            path: lifecycleContract.namespace.markerRelativePath
        )
        let data: Data
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: markerPath,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: markerPath,
                maximumByteCount:
                    WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
        } catch {
            return false
        }
        guard let marker = try? WindowsFontLifecycleJSON.decodeCanonical(
            WindowsFontLifecycleMarker.self,
            data: data,
            exactKeys: WindowsFontLifecycleMarker.exactKeys
        ) else {
            return false
        }
        let allowedDirectories = Set([
            "windows/Fonts",
            "ForgePlay",
            "ForgePlay/FontCompatibility"
        ])
        return [1, 2].contains(marker.schemaVersion) &&
            marker.profileIdentifier == definition.profileIdentifier &&
            marker.descriptorDigest == definition.descriptorDigest &&
            WindowsFontCanonical.sortedUnique(marker.ownedFileIDs) &&
            WindowsFontCanonical.sortedUnique(marker.ownedRegistryIDs) &&
            Set(marker.ownedFileIDs).isSubset(
                of: Set(definition.payloads.map(\.descriptorID))
            ) &&
            lifecycleContract.registryOwnershipIDsAreValid(
                marker.ownedRegistryIDs,
                allowsReplacements: marker.schemaVersion == 2,
                requiresCompleteReplacementSet: true
            ) &&
            WindowsFontCanonical.sortedUnique(
                marker.createdDirectoryRelativePaths
            ) &&
            Set(marker.createdDirectoryRelativePaths).isSubset(
                of: allowedDirectories
            )
    }

    private var applicableFreshWineRegistryTransitions:
        [WindowsFontRegistryBaselineTransition] {
        let requirements = definition.registryRequirements
        func containsTarget(for source: WindowsFontRegistryRequirement) -> Bool {
            requirements.contains {
                $0.registryPath == source.registryPath &&
                    $0.valueName == source.valueName
            }
        }
        let requirementIDs = Set(requirements.map(\.descriptorID))
        return lifecycleContract.freshBaselineTransitions.compactMap { transition in
            let sourceRequirements = transition.sourceRequirements.filter(
                containsTarget
            )
            let replacements = transition.replacements.filter {
                requirementIDs.contains($0.target.descriptorID)
            }
            guard !sourceRequirements.isEmpty, !replacements.isEmpty else {
                return nil
            }
            return WindowsFontRegistryBaselineTransition(
                baselineVariant: transition.baselineVariant,
                sourceRequirements: sourceRequirements,
                replacements: replacements
            )
        }
    }

    private var applicableFreshWineAlreadyTargetRequirements:
        [WindowsFontRegistryRequirement] {
        let requirementIDs = Set(definition.registryRequirements.map(\.descriptorID))
        return lifecycleContract.freshAlreadyTargetRequirements
            .filter { requirementIDs.contains($0.descriptorID) }
    }

    private var applicableLegacyV4RegistryReplacements:
        [WindowsFontRegistryReplacementDescriptor] {
        let requirementIDs = Set(definition.registryRequirements.map(\.descriptorID))
        return lifecycleContract.legacyV4RegistryReplacements
            .filter { requirementIDs.contains($0.target.descriptorID) }
    }

    private var applicableSupportedRegistryReplacements:
        [WindowsFontRegistryReplacementDescriptor] {
        let requirementIDs = Set(definition.registryRequirements.map(\.descriptorID))
        var byID: [String: WindowsFontRegistryReplacementDescriptor] = [:]
        for replacement in (
            lifecycleContract.freshBaselineTransitions.flatMap(\.replacements) +
            lifecycleContract.legacyV4RegistryReplacements
        ) where requirementIDs.contains(replacement.target.descriptorID) {
            byID[replacement.replacementID] = replacement
        }
        return byID.values.sorted { $0.replacementID < $1.replacementID }
    }

    private func selectedRegistryReplacementSet(
        prefix: URL,
        snapshots: (
            user: WindowsFontRegistrySnapshotState,
            system: WindowsFontRegistrySnapshotState
        )
    ) throws -> [WindowsFontRegistryReplacementDescriptor]? {
        let legacyMarker = prefix.appending(
            path: "drive_c/ForgePlay/FontCompatibility/" +
                "forgeplay-windows-font-compatibility-v4.txt"
        )
        if try WindowsFontLifecycleFileSystem.lstatItem(legacyMarker) != nil {
            let legacy = applicableLegacyV4RegistryReplacements
            guard !legacy.isEmpty,
                  legacy.count == lifecycleContract
                    .legacyV4RegistryReplacements.count,
                  legacyV4MigrationIsAuthorized(
                    prefix: prefix,
                    snapshots: snapshots
                  ) else {
                throw WindowsFontCompatibilityProfileError.collision(
                    "legacy-v4-font-profile-evidence-mismatch: \(legacyMarker.path)"
                )
            }
            return legacy
        }

        return matchingFreshBaselineTransition(snapshots: snapshots)?.replacements
    }

    private func matchingFreshBaselineTransition(
        snapshots: (
            user: WindowsFontRegistrySnapshotState,
            system: WindowsFontRegistrySnapshotState
        )
    ) -> WindowsFontRegistryBaselineTransition? {
        let anchorsMatch =
            applicableFreshWineAlreadyTargetRequirements.count ==
                lifecycleContract.freshAlreadyTargetRequirements.count &&
            applicableFreshWineAlreadyTargetRequirements.allSatisfy { requirement in
                let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                    ? snapshots.user
                    : snapshots.system
                return snapshot.orderedValues(for: requirement) ==
                    requirement.orderedValues
            }
        guard anchorsMatch else { return nil }
        let matches = applicableFreshWineRegistryTransitions.filter { transition in
            transition.sourceRequirements.allSatisfy { baseline in
                    let snapshot = baseline.registryPath.hasPrefix("HKCU\\")
                        ? snapshots.user
                        : snapshots.system
                    return snapshot.orderedValues(for: baseline) ==
                        baseline.orderedValues
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func legacyV4MigrationIsAuthorized(
        prefix: URL,
        snapshots: (
            user: WindowsFontRegistrySnapshotState,
            system: WindowsFontRegistrySnapshotState
        )
    ) -> Bool {
        legacyV4BaselineFilesAreAuthorized(prefix: prefix) &&
            legacyV4RegistryStateIsAuthorized(snapshots: snapshots)
    }

    private func legacyV4BaselineFilesAreAuthorized(prefix: URL) -> Bool {
        let marker = prefix.appending(
            path: "drive_c/ForgePlay/FontCompatibility/" +
                "forgeplay-windows-font-compatibility-v4.txt"
        )
        do {
            try WindowsFontLifecycleFileSystem.verifyRegularFile(
                at: marker,
                expectedData:
                    WindowsFontCompatibilityProfileContract.legacyV4MarkerData,
                exactMode: S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
            )
        } catch {
            return false
        }

        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        let legacyPayloads = WindowsFontCompatibilityProfileContract.fontPayloads
            .filter { $0.sourceRole == .runtimeNanum }
        guard legacyPayloads.allSatisfy({ payload in
            let url = fonts.appending(path: payload.fileName)
            do {
                try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                    at: url,
                    exactMode: S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
                )
                return try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                    at: url
                ) == payload.sha256
            } catch {
                return false
            }
        }) else {
            return false
        }

        return true
    }

    private func legacyV4RegistryStateIsAuthorized(
        snapshots: (
            user: WindowsFontRegistrySnapshotState,
            system: WindowsFontRegistrySnapshotState
        )
    ) -> Bool {
        WindowsFontCompatibilityProfileContract
            .legacyV4RegistryRequirements.allSatisfy { requirement in
                let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                    ? snapshots.user
                    : snapshots.system
                return snapshot.orderedValues(for: requirement) ==
                    requirement.orderedValues
            }
    }

    private func restoresLegacyV4Baseline(registryIDs: [String]) -> Bool {
        let required = Set(applicableLegacyV4RegistryReplacements.map(\.replacementID))
        return !required.isEmpty &&
            required.count == lifecycleContract
                .legacyV4RegistryReplacements.count &&
            required.isSubset(of: Set(registryIDs))
    }

    private func registryStateDigest(
        snapshot: WindowsFontRegistrySnapshotState,
        requirement: WindowsFontRegistryRequirement
    ) -> String {
        let values = snapshot.orderedValues(for: requirement)
        let classification: String
        if values != nil {
            classification = "present-readable"
        } else if snapshot.containsValue(for: requirement) {
            classification = "present-duplicate-or-type-mismatch"
        } else {
            classification = "absent"
        }
        return WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontObservedRegistryStateV1",
            fields: [
                requirement.registryPath.lowercased(),
                requirement.valueName.lowercased(),
                requirement.valueType,
                classification
            ] + (values ?? [])
        )
    }

    private func registryCollisionReason(
        snapshot: WindowsFontRegistrySnapshotState,
        requirement: WindowsFontRegistryRequirement,
        classification: String
    ) -> String {
        let observedDigest = registryStateDigest(
            snapshot: snapshot,
            requirement: requirement
        )
        return "\(requirement.registryPath)\\\(requirement.valueName) " +
            "classification=\(classification) " +
            "observedDigest=\(observedDigest) " +
            "expectedDigest=\(requirement.descriptorID)"
    }

    private func makeApplyPlan(
        prefix: URL,
        driveC: URL,
        sourceRoots: [WindowsFontPayloadSourceRole: URL]
    ) throws -> WindowsFontLifecyclePreflightPlan {
        let journalPath = journalURL(in: prefix)
        try WindowsFontLifecycleFileSystem.requireAbsent(journalPath)

        var sourceURLsByPayloadID: [String: URL] = [:]
        for payload in definition.payloadsInDescriptorOrder {
            guard let root = sourceRoots[payload.sourceRole] else {
                throw WindowsFontCompatibilityProfileError.bundledPayloadMissing
            }
            try WindowsFontLifecycleFileSystem.requireDirectory(root)
            let source = root.appending(path: payload.fileName)
            guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(at: source) ==
                payload.sha256 else {
                throw WindowsFontCompatibilityProfileError.bundledPayloadMissing
            }
            sourceURLsByPayloadID[payload.descriptorID] = source
        }

        let fontsDirectory = driveC.appending(
            path: "windows/Fonts",
            directoryHint: .isDirectory
        )
        var persistentCreatedDirectories: [String] = []
        var plannedDirectories: [String] = []
        if try WindowsFontLifecycleFileSystem.lstatItem(fontsDirectory) == nil {
            persistentCreatedDirectories.append("windows/Fonts")
            plannedDirectories.append("windows/Fonts")
        } else {
            try WindowsFontLifecycleFileSystem.requireDirectory(fontsDirectory)
        }

        var adoptedFileIDs: [String] = []
        var ownedFileIDs: [String] = []
        for payload in definition.payloadsInDescriptorOrder {
            let destination = fontsDirectory.appending(path: payload.fileName)
            if try WindowsFontLifecycleFileSystem.lstatItem(destination) == nil {
                ownedFileIDs.append(payload.descriptorID)
            } else if try WindowsFontLifecycleFileSystem.sha256OfRegularFile(at: destination) ==
                payload.sha256 {
                adoptedFileIDs.append(payload.descriptorID)
            } else {
                throw WindowsFontCompatibilityProfileError.collision(destination.path)
            }
        }

        let snapshots = try loadRegistrySnapshots(prefix: prefix)
        var adoptedRegistryIDs: [String] = []
        var createdRegistryIDs: [String] = []
        var replacedRegistryIDs: [String] = []
        let selectedReplacements = try selectedRegistryReplacementSet(
            prefix: prefix,
            snapshots: snapshots
        ) ?? []
        let replacementsByTargetID = Dictionary(uniqueKeysWithValues:
            selectedReplacements.map {
                ($0.target.descriptorID, $0)
            }
        )
        for requirement in definition.registryRequirementsInDescriptorOrder {
            let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                ? snapshots.user
                : snapshots.system
            if WindowsFontCompatibilityProfileContract
                .isSatisfiedRegistryRequirement(
                    snapshot: snapshot,
                    requirement: requirement
                ) {
                adoptedRegistryIDs.append(requirement.descriptorID)
            } else if !snapshot.containsValue(for: requirement) {
                createdRegistryIDs.append(requirement.descriptorID)
            } else if let replacement = replacementsByTargetID[requirement.descriptorID],
                      snapshot.orderedValues(for: replacement.baseline) ==
                        replacement.baseline.orderedValues {
                replacedRegistryIDs.append(replacement.replacementID)
            } else {
                let classification = snapshot.orderedValues(for: requirement) == nil
                    ? "duplicate-or-type-mismatch"
                    : "foreign-present"
                throw WindowsFontCompatibilityProfileError.collision(
                    registryCollisionReason(
                        snapshot: snapshot,
                        requirement: requirement,
                        classification: classification
                    )
                )
            }
        }

        if !replacedRegistryIDs.isEmpty {
            let requiredReplacementIDs = Set(
                selectedReplacements.map(\.replacementID)
            )
            guard !requiredReplacementIDs.isEmpty,
                  Set(replacedRegistryIDs) == requiredReplacementIDs else {
                guard let replacement = selectedReplacements.first(where: {
                    !replacedRegistryIDs.contains($0.replacementID)
                }) else {
                    throw WindowsFontCompatibilityProfileError
                        .operationProjectionMismatch("supported-baseline-replacement-set")
                }
                let snapshot = replacement.target.registryPath.hasPrefix("HKCU\\")
                    ? snapshots.user
                    : snapshots.system
                throw WindowsFontCompatibilityProfileError.collision(
                    registryCollisionReason(
                        snapshot: snapshot,
                        requirement: replacement.target,
                        classification: "partial-supported-baseline"
                    )
                )
            }
        }

        let forgePlayDirectory = driveC.appending(
            path: "ForgePlay",
            directoryHint: .isDirectory
        )
        let markerDirectory = driveC.appending(
            path: "ForgePlay/FontCompatibility",
            directoryHint: .isDirectory
        )
        for (url, relative) in [
            (forgePlayDirectory, "ForgePlay"),
            (markerDirectory, "ForgePlay/FontCompatibility")
        ] {
            if try WindowsFontLifecycleFileSystem.lstatItem(url) == nil {
                persistentCreatedDirectories.append(relative)
                plannedDirectories.append(relative)
            } else {
                try WindowsFontLifecycleFileSystem.requireDirectory(url)
            }
        }

        let transactionID = transactionIDProvider().uuidString.lowercased()
        let scratchRoot = scratchRootRelativePath(transactionID: transactionID)
        let scratchDirectories = [
            lifecycleContract.namespace.scratchDirectoryRelativePath,
            scratchRoot,
            "\(scratchRoot)/payload",
            "\(scratchRoot)/marker"
        ]
        for relative in scratchDirectories {
            let url = try WindowsFontLifecycleFileSystem.relativeURL(relative, below: driveC)
            try WindowsFontLifecycleFileSystem.requireAbsent(url)
            plannedDirectories.append(relative)
        }
        guard plannedDirectories.count <= 7 else {
            throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                "planned-directory-count"
            )
        }

        let ownedPayloads = definition.payloadsInDescriptorOrder.filter {
            ownedFileIDs.contains($0.descriptorID)
        }
        let stagePaths = ownedPayloads.map {
            "\(scratchRoot)/payload/\($0.descriptorID).font-stage"
        }
        let markerStage =
            "\(scratchRoot)/marker/" +
            lifecycleContract.namespace.markerStageFileName
        return WindowsFontLifecyclePreflightPlan(
            profileIdentifier: definition.profileIdentifier,
            descriptorDigest: definition.descriptorDigest,
            transactionID: transactionID,
            adoptedFileIDs: adoptedFileIDs.sorted(),
            plannedOwnedFileIDs: ownedFileIDs.sorted(),
            adoptedRegistryIDs: adoptedRegistryIDs.sorted(),
            plannedCreatedRegistryIDs: createdRegistryIDs.sorted(),
            plannedReplacedRegistryIDs: replacedRegistryIDs.sorted(),
            persistentCreatedDirectoryRelativePaths:
                persistentCreatedDirectories.sorted(),
            plannedCreatedDirectoryRelativePaths:
                parentFirst(plannedDirectories),
            scratchRootRelativePath: scratchRoot,
            payloadStageRelativePaths: stagePaths.sorted(),
            markerStageRelativePath: markerStage,
            sourceURLsByPayloadID: sourceURLsByPayloadID
        )
    }

    /// A committed marker is the durable ownership ledger for the profile.
    /// Wine may legitimately rebuild its font registry while starting a
    /// service or updating a prefix, so a valid marker plus a known Wine
    /// baseline is a repairable state rather than a collision. Unknown or
    /// duplicate values remain a zero-write conflict.
    private func makeCommittedReconciliationPlan(
        marker: WindowsFontLifecycleMarker,
        prefix: URL,
        driveC: URL
    ) throws -> WindowsFontCommittedReconciliationPlan {
        try verifyCommittedPayloadFiles(prefix: prefix)
        let registryPlan = try committedRegistryReconciliation(
            marker: marker,
            prefix: prefix
        )
        let finalMarker = WindowsFontLifecycleMarker(
            schemaVersion: 2,
            profileIdentifier: marker.profileIdentifier,
            descriptorDigest: marker.descriptorDigest,
            ownedFileIDs: marker.ownedFileIDs,
            ownedRegistryIDs: registryPlan.finalOwnedRegistryIDs,
            createdDirectoryRelativePaths: marker.createdDirectoryRelativePaths
        )
        let transactionID = transactionIDProvider().uuidString.lowercased()
        let scratchRoot = scratchRootRelativePath(transactionID: transactionID)
        let directories = parentFirst([
            lifecycleContract.namespace.scratchDirectoryRelativePath,
            scratchRoot,
            "\(scratchRoot)/marker"
        ])
        for relativePath in directories {
            let url = try WindowsFontLifecycleFileSystem.relativeURL(
                relativePath,
                below: driveC
            )
            try WindowsFontLifecycleFileSystem.requireAbsent(url)
        }
        let journal = WindowsFontLifecycleJournal(
            schemaVersion: 4,
            profileIdentifier: definition.profileIdentifier,
            descriptorDigest: definition.descriptorDigest,
            transactionID: transactionID,
            operation: "reconcile",
            plannedOwnedFileIDs: finalMarker.ownedFileIDs,
            plannedOwnedRegistryIDs: finalMarker.ownedRegistryIDs,
            committedOwnedFileIDs: marker.ownedFileIDs,
            committedOwnedRegistryIDs: marker.ownedRegistryIDs,
            scratchRootRelativePath: scratchRoot,
            payloadStageRelativePaths: [],
            markerStageRelativePath:
                "\(scratchRoot)/marker/" +
                lifecycleContract.namespace.markerStageFileName,
            plannedCreatedDirectoryRelativePaths: directories,
            immutablePhase: "reconcile-prepared"
        )
        try validate(journal: journal, driveC: driveC)
        return WindowsFontCommittedReconciliationPlan(
            originalMarker: marker,
            finalMarker: finalMarker,
            registryRequirementsToApply:
                registryPlan.registryRequirementsToApply,
            journal: journal
        )
    }

    private func makeCommittedReconciliationPlan(
        journal: WindowsFontLifecycleJournal,
        prefix: URL,
        driveC: URL
    ) throws -> WindowsFontCommittedReconciliationPlan {
        guard journal.operation == "reconcile" else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let observedMarker = try readAndValidateMarker(prefix: prefix)
        let finalMarker = WindowsFontLifecycleMarker(
            schemaVersion: 2,
            profileIdentifier: definition.profileIdentifier,
            descriptorDigest: definition.descriptorDigest,
            ownedFileIDs: journal.plannedOwnedFileIDs,
            ownedRegistryIDs: journal.plannedOwnedRegistryIDs,
            createdDirectoryRelativePaths:
                observedMarker.createdDirectoryRelativePaths
        )
        let stage = try WindowsFontLifecycleFileSystem.relativeURL(
            journal.markerStageRelativePath,
            below: driveC
        )
        let originalMarker: WindowsFontLifecycleMarker
        if observedMarker == finalMarker,
           try WindowsFontLifecycleFileSystem.lstatItem(stage) != nil {
            originalMarker = try readAndValidateMarker(at: stage)
            guard originalMarker.ownedFileIDs == journal.committedOwnedFileIDs,
                  originalMarker.ownedRegistryIDs ==
                    journal.committedOwnedRegistryIDs,
                  originalMarker.createdDirectoryRelativePaths ==
                    finalMarker.createdDirectoryRelativePaths else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "committed-font-marker-stage-ownership-drift"
                )
            }
        } else {
            originalMarker = WindowsFontLifecycleMarker(
                schemaVersion: observedMarker.schemaVersion,
                profileIdentifier: definition.profileIdentifier,
                descriptorDigest: definition.descriptorDigest,
                ownedFileIDs: journal.committedOwnedFileIDs,
                ownedRegistryIDs: journal.committedOwnedRegistryIDs,
                createdDirectoryRelativePaths:
                    observedMarker.createdDirectoryRelativePaths
            )
        }
        guard observedMarker == originalMarker || observedMarker == finalMarker else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "committed-font-marker-reconciliation-drift"
            )
        }
        try verifyCommittedPayloadFiles(prefix: prefix)
        let registryPlan = try committedRegistryReconciliation(
            marker: finalMarker,
            prefix: prefix
        )
        guard registryPlan.finalOwnedRegistryIDs == finalMarker.ownedRegistryIDs else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "committed-font-reconciliation-ownership-drift"
            )
        }
        return WindowsFontCommittedReconciliationPlan(
            originalMarker: originalMarker,
            finalMarker: finalMarker,
            registryRequirementsToApply:
                registryPlan.registryRequirementsToApply,
            journal: journal
        )
    }

    private func verifyCommittedPayloadFiles(prefix: URL) throws {
        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        for payload in definition.payloadsInDescriptorOrder {
            let destination = fonts.appending(path: payload.fileName)
            guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                at: destination
            ) == payload.sha256 else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "committed-font-payload-drift: \(destination.path)"
                )
            }
        }
    }

    private func committedRegistryReconciliation(
        marker: WindowsFontLifecycleMarker,
        prefix: URL
    ) throws -> (
        finalOwnedRegistryIDs: [String],
        registryRequirementsToApply: [WindowsFontRegistryRequirement]
    ) {
        let snapshots = try loadRegistrySnapshots(prefix: prefix)
        let observedFreshTransition = matchingFreshBaselineTransition(
            snapshots: snapshots
        )
        var finalOwnedIDs = Set(marker.ownedRegistryIDs)
        var requirementsToApply: [WindowsFontRegistryRequirement] = []
        let ownedReplacementByTargetID = Dictionary(uniqueKeysWithValues:
            marker.ownedRegistryIDs.compactMap { ownershipID in
                lifecycleContract.supportedReplacement(
                    forReplacementID: ownershipID
                )
                    .map { ($0.target.descriptorID, $0) }
            }
        )

        for requirement in definition.registryRequirementsInDescriptorOrder {
            let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                ? snapshots.user
                : snapshots.system
            let observedValues = snapshot.orderedValues(for: requirement)
            if observedValues == requirement.orderedValues {
                continue
            }

            let directOwnership = finalOwnedIDs.contains(requirement.descriptorID)
            let replacementOwnership = ownedReplacementByTargetID[
                requirement.descriptorID
            ]
            if WindowsFontCompatibilityProfileContract
                .isAcceptedAppleHostFontRegistration(
                    snapshot: snapshot,
                    requirement: requirement
                ) {
                guard replacementOwnership == nil else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        registryCollisionReason(
                            snapshot: snapshot,
                            requirement: requirement,
                            classification:
                                "owned-replacement-became-host-registration"
                        )
                    )
                }
                // Wine has taken responsibility for this exact registration.
                // Stop claiming a direct value that ForgePlay no longer owns.
                if directOwnership {
                    finalOwnedIDs.remove(requirement.descriptorID)
                }
                continue
            }

            let containsValue = snapshot.containsValue(for: requirement)
            if let replacementOwnership {
                let matchingSupportedBaselines =
                    applicableSupportedRegistryReplacements.filter { candidate in
                        candidate.target.descriptorID ==
                            replacementOwnership.target.descriptorID &&
                        snapshot.orderedValues(for: candidate.baseline) ==
                            candidate.baseline.orderedValues
                    }
                guard !containsValue || matchingSupportedBaselines.count == 1 else {
                    throw WindowsFontCompatibilityProfileError.collision(
                        registryCollisionReason(
                            snapshot: snapshot,
                            requirement: requirement,
                            classification:
                                "owned-replacement-foreign-drift"
                        )
                    )
                }
                if let observedReplacement = matchingSupportedBaselines.first,
                   observedReplacement.replacementID !=
                    replacementOwnership.replacementID {
                    finalOwnedIDs.remove(replacementOwnership.replacementID)
                    finalOwnedIDs.insert(observedReplacement.replacementID)
                }
                requirementsToApply.append(requirement)
            } else if directOwnership {
                let matchingSupportedBaselines =
                    applicableSupportedRegistryReplacements.filter { candidate in
                        candidate.target.descriptorID == requirement.descriptorID &&
                            snapshot.orderedValues(for: candidate.baseline) ==
                            candidate.baseline.orderedValues
                    }
                if matchingSupportedBaselines.count == 1,
                   let observedReplacement = matchingSupportedBaselines.first {
                    finalOwnedIDs.remove(requirement.descriptorID)
                    finalOwnedIDs.insert(observedReplacement.replacementID)
                    requirementsToApply.append(requirement)
                    continue
                }
                guard !containsValue else {
                    throw WindowsFontCompatibilityProfileError.collision(
                        registryCollisionReason(
                            snapshot: snapshot,
                            requirement: requirement,
                            classification: "owned-created-value-foreign-drift"
                        )
                    )
                }
                requirementsToApply.append(requirement)
            } else {
                if let observedFreshTransition,
                   let observedReplacement = observedFreshTransition
                    .replacements.first(where: {
                        $0.target.descriptorID == requirement.descriptorID
                    }), snapshot.orderedValues(for: observedReplacement.baseline) ==
                    observedReplacement.baseline.orderedValues {
                    // A previously adopted target may be replaced by Wine as
                    // part of one complete locale baseline rebuild. Bind that
                    // exact source baseline before restoring the v6 target;
                    // partial or mixed locale state never reaches this path.
                    finalOwnedIDs.insert(observedReplacement.replacementID)
                    requirementsToApply.append(requirement)
                    continue
                }
                guard !containsValue else {
                    throw WindowsFontCompatibilityProfileError.collision(
                        registryCollisionReason(
                            snapshot: snapshot,
                            requirement: requirement,
                            classification: "unowned-required-value-present"
                        )
                    )
                }
                // The exact key was adopted when the profile was committed,
                // but Wine later removed it while rebuilding Fonts. Claim the
                // absent key in the marker before recreating it.
                finalOwnedIDs.insert(requirement.descriptorID)
                requirementsToApply.append(requirement)
            }
        }

        let sortedOwnedIDs = Array(finalOwnedIDs).sorted()
        guard lifecycleContract.registryOwnershipIDsAreValid(
            sortedOwnedIDs,
            allowsReplacements: true,
            requiresCompleteReplacementSet: true
        ) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return (
            sortedOwnedIDs,
            requirementsToApply.sorted {
                $0.descriptorID < $1.descriptorID
            }
        )
    }

    private func continueCommittedReconciliation(
        plan: WindowsFontCommittedReconciliationPlan,
        runtimeExecutable: URL,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        logDirectory: URL
    ) async throws -> WindowsFontVerifiedMutationResult {
        try ensureReconciliationDirectories(
            journal: plan.journal,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
        try reconcileCommittedMarker(
            plan: plan,
            prefix: prefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )

        let refreshed = try committedRegistryReconciliation(
            marker: plan.finalMarker,
            prefix: prefix
        )
        guard refreshed.finalOwnedRegistryIDs ==
                plan.finalMarker.ownedRegistryIDs else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "committed-font-reconciliation-ownership-changed"
            )
        }
        var attemptedRegistryMutation = false
        for (ordinal, requirement) in
            refreshed.registryRequirementsToApply.enumerated() {
            let current = try committedRegistryReconciliation(
                marker: plan.finalMarker,
                prefix: prefix
            )
            guard current.finalOwnedRegistryIDs ==
                    plan.finalMarker.ownedRegistryIDs else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "committed-font-reconciliation-concurrent-ownership-drift"
                )
            }
            guard current.registryRequirementsToApply.contains(where: {
                $0.descriptorID == requirement.descriptorID
            }) else {
                continue
            }
            let ownershipID = plan.finalMarker.ownedRegistryIDs.first(where: {
                lifecycleContract.supportedReplacement(
                    forReplacementID: $0
                )?
                    .target.descriptorID == requirement.descriptorID
            }) ?? requirement.descriptorID
            attemptedRegistryMutation = true
            let result = try await performRunnerAction(
                try operation(
                    .registrySet,
                    resource: ownershipID,
                    ordinal: ordinal
                ),
                .setRegistryValue(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    registryPath: requirement.registryPath,
                    valueName: requirement.valueName,
                    valueType: requirement.valueType,
                    value: requirement.encodedRunnerValue,
                    logDirectory: logDirectory
                )
            )
            guard result.succeeded else { return .unsuccessful(result) }
        }

        if attemptedRegistryMutation {
            let result = try await performRunnerAction(
                try operation(
                    .forwardRegistryFlush,
                    resource: "registry-reconciliation-flush",
                    ordinal: 0
                ),
                .waitForWinePrefix(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
            )
            guard result.succeeded else { return .unsuccessful(result) }
        }

        let readback = await inspectForLaunch(
            prefix: prefix,
            requiresProfileMarker: true
        )
        guard readback.isSatisfied else {
            throw WindowsFontCompatibilityProfileError.verificationFailed(
                readback.missingItems
            )
        }
        try cleanupBoundStages(
            journal: plan.journal,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
        try removePlannedDirectories(
            plan.journal.plannedCreatedDirectoryRelativePaths,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
        try deleteJournalAndSynchronizeParent(
            journal: plan.journal,
            prefix: prefix,
            driveCDescriptor: driveCDescriptor
        )
        return .verified(readback)
    }

    private func ensureReconciliationDirectories(
        journal: WindowsFontLifecycleJournal,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        for (ordinal, relativePath) in
            journal.plannedCreatedDirectoryRelativePaths.enumerated() {
            let url = try WindowsFontLifecycleFileSystem.relativeURL(
                relativePath,
                below: driveC
            )
            if let status = try WindowsFontLifecycleFileSystem.lstatItem(url) {
                guard (status.st_mode & S_IFMT) == S_IFDIR,
                      status.st_uid == geteuid(),
                      (status.st_mode & 0o777) ==
                        WindowsFontLifecycleFileSystem.privateDirectoryMode else {
                    throw WindowsFontCompatibilityProfileError
                        .unsafeDestination(url)
                }
                continue
            }
            try performFilesystem(try operation(
                .plannedDirectoryCreateVerify,
                resource: relativePath,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.createDirectory(
                    relativePath: relativePath,
                    below: driveC,
                    descriptor: driveCDescriptor,
                    mode: WindowsFontLifecycleFileSystem.privateDirectoryMode
                )
            }
            var parentDescriptor: Int32 = -1
            defer {
                if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
            }
            try performFilesystem(try operation(
                .plannedDirectoryContainingParentFSync,
                resource: relativePath,
                ordinal: ordinal
            )) {
                parentDescriptor = try WindowsFontLifecycleFileSystem
                    .openContainingDirectory(
                        for: relativePath,
                        below: driveC,
                        descriptor: driveCDescriptor
                    )
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    parentDescriptor,
                    label: "font reconciliation directory parent fsync"
                )
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &parentDescriptor,
                    label: "font reconciliation directory parent close"
                )
            }
        }
    }

    private func reconcileCommittedMarker(
        plan: WindowsFontCommittedReconciliationPlan,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        var observed = try readAndValidateMarker(prefix: prefix)
        guard observed == plan.originalMarker || observed == plan.finalMarker else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "committed-font-marker-changed-during-reconciliation"
            )
        }
        let stage = try WindowsFontLifecycleFileSystem.relativeURL(
            plan.journal.markerStageRelativePath,
            below: driveC
        )
        let originalData = try WindowsFontLifecycleJSON.encodeCanonical(
            plan.originalMarker
        )
        let finalData = try WindowsFontLifecycleJSON.encodeCanonical(
            plan.finalMarker
        )
        let originalDigest = SHA256.hash(data: originalData).map {
            String(format: "%02x", $0)
        }.joined()
        let finalDigest = SHA256.hash(data: finalData).map {
            String(format: "%02x", $0)
        }.joined()

        if observed == plan.originalMarker,
           plan.originalMarker != plan.finalMarker {
            if try WindowsFontLifecycleFileSystem.lstatItem(stage) != nil {
                let stagedData = try WindowsFontLifecycleFileSystem.readRegularFile(
                    at: stage,
                    maximumByteCount:
                        WindowsFontLifecycleJSON.maximumEvidenceByteCount
                )
                if stagedData != finalData {
                    // The journal and unchanged committed marker prove this is
                    // an incomplete transaction-owned stage from a crash
                    // before RENAME_SWAP. It is safe to recreate; arbitrary
                    // marker or registry state is never overwritten here.
                    try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                        relativePath: plan.journal.markerStageRelativePath,
                        below: driveC,
                        descriptor: driveCDescriptor
                    )
                }
            }
            if try WindowsFontLifecycleFileSystem.lstatItem(stage) == nil {
                var descriptor = try WindowsFontLifecycleFileSystem
                    .openExclusiveRegularFile(
                        relativePath: plan.journal.markerStageRelativePath,
                        below: driveC,
                        descriptor: driveCDescriptor,
                        mode: WindowsFontLifecycleFileSystem.evidenceFileMode
                    )
                do {
                    try WindowsFontLifecycleFileSystem.writeAll(
                        finalData,
                        to: descriptor
                    )
                    try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                        descriptor,
                        label: "font reconciliation marker stage fsync"
                    )
                    try WindowsFontLifecycleFileSystem.closeDescriptor(
                        &descriptor,
                        label: "font reconciliation marker stage close"
                    )
                } catch {
                    if descriptor >= 0 { Darwin.close(descriptor) }
                    throw error
                }
            }
            try WindowsFontLifecycleFileSystem.verifyRegularFile(
                at: stage,
                expectedData: finalData,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            try WindowsFontLifecycleFileSystem.exchangeRegularFiles(
                firstRelativePath: plan.journal.markerStageRelativePath,
                firstExpectedSHA256: finalDigest,
                secondRelativePath:
                    lifecycleContract.namespace.driveCMarkerRelativePath,
                secondExpectedSHA256: originalDigest,
                below: driveC,
                descriptor: driveCDescriptor
            )
            try fsyncMarkerParent(
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                operationKind: .markerParentDirectoryFSync
            )
            observed = try readAndValidateMarker(prefix: prefix)
        }
        guard observed == plan.finalMarker else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "committed-font-marker-reconciliation-not-published"
            )
        }
        if try WindowsFontLifecycleFileSystem.lstatItem(stage) != nil {
            let stageData = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: stage,
                maximumByteCount:
                    WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
            guard stageData == originalData || stageData == finalData else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    stage.path
                )
            }
        }
        try synchronizeReconciliationMarkerNamespaces(
            journal: plan.journal,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
    }

    private func synchronizeReconciliationMarkerNamespaces(
        journal: WindowsFontLifecycleJournal,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        var stageParentDescriptor: Int32 = -1
        defer {
            if stageParentDescriptor >= 0 { Darwin.close(stageParentDescriptor) }
        }
        try performFilesystem(try operation(
            .committedMarkerStageParentFSync,
            resource: "\(journal.scratchRootRelativePath)/marker",
            ordinal: 0
        )) {
            stageParentDescriptor = try WindowsFontLifecycleFileSystem
                .openContainingDirectory(
                    for: journal.markerStageRelativePath,
                    below: driveC,
                    descriptor: driveCDescriptor
                )
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                stageParentDescriptor,
                label: "font reconciliation marker stage parent fsync"
            )
            try WindowsFontLifecycleFileSystem.closeDescriptor(
                &stageParentDescriptor,
                label: "font reconciliation marker stage parent close"
            )
        }
        try fsyncMarkerParent(
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            operationKind: .committedMarkerParentFSync
        )
    }

    private func scratchRootRelativePath(transactionID: String) -> String {
        "\(lifecycleContract.namespace.scratchDirectoryRelativePath)/" +
            transactionID
    }

    private func parentFirst(_ paths: [String]) -> [String] {
        Array(Set(paths)).sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth == rightDepth { return $0 < $1 }
            return leftDepth < rightDepth
        }
    }

    private func reverseDepth(_ paths: [String]) -> [String] {
        Array(Set(paths)).sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth == rightDepth { return $0 > $1 }
            return leftDepth > rightDepth
        }
    }

    private func loadRegistrySnapshots(
        prefix: URL
    ) throws -> (user: WindowsFontRegistrySnapshotState, system: WindowsFontRegistrySnapshotState) {
        let userURL = prefix.appending(path: "user.reg")
        let systemURL = prefix.appending(path: "system.reg")
        do {
            return (
                try WindowsFontRegistrySnapshotState.load(
                    url: userURL,
                    fileManager: fileManager
                ),
                try WindowsFontRegistrySnapshotState.load(
                    url: systemURL,
                    fileManager: fileManager
                )
            )
        } catch let error as WindowsFontCompatibilityProfileError {
            throw error
        } catch {
            throw WindowsFontCompatibilityProfileError.registrySnapshotMalformed(
                userURL
            )
        }
    }

    private func validate(
        journal: WindowsFontLifecycleJournal,
        driveC: URL
    ) throws {
        let transactionID = journal.transactionID
        guard UUID(uuidString: transactionID)?.uuidString.lowercased() == transactionID,
              [3, 4].contains(journal.schemaVersion),
              journal.profileIdentifier == definition.profileIdentifier,
              journal.descriptorDigest == definition.descriptorDigest,
              ["apply", "reconcile", "uninstall"].contains(journal.operation),
              journal.immutablePhase == "\(journal.operation)-prepared",
              WindowsFontCanonical.sortedUnique(journal.plannedOwnedFileIDs),
              WindowsFontCanonical.sortedUnique(journal.plannedOwnedRegistryIDs),
              WindowsFontCanonical.sortedUnique(journal.committedOwnedFileIDs),
              WindowsFontCanonical.sortedUnique(journal.committedOwnedRegistryIDs),
              WindowsFontCanonical.sortedUnique(journal.payloadStageRelativePaths),
              Set(journal.plannedOwnedFileIDs).isSubset(
                of: Set(definition.payloads.map(\.descriptorID))
              ),
              lifecycleContract.registryOwnershipIDsAreValid(
                journal.plannedOwnedRegistryIDs,
                allowsReplacements: journal.schemaVersion == 4,
                requiresCompleteReplacementSet: true
              ),
              (journal.operation == "reconcile" ||
                Set(journal.committedOwnedFileIDs).isSubset(
                    of: Set(journal.plannedOwnedFileIDs)
                )),
              (journal.operation == "reconcile" ||
                Set(journal.committedOwnedRegistryIDs).isSubset(
                    of: Set(journal.plannedOwnedRegistryIDs)
                )),
              lifecycleContract.registryOwnershipIDsAreValid(
                journal.committedOwnedRegistryIDs,
                allowsReplacements: journal.schemaVersion == 4,
                requiresCompleteReplacementSet: false
              ),
              journal.scratchRootRelativePath ==
                scratchRootRelativePath(transactionID: transactionID),
              WindowsFontCanonical.isSafeRelativePath(journal.scratchRootRelativePath),
              WindowsFontCanonical.isSafeRelativePath(journal.markerStageRelativePath),
              journal.markerStageRelativePath ==
                "\(journal.scratchRootRelativePath)/marker/" +
                lifecycleContract.namespace.markerStageFileName,
              journal.payloadStageRelativePaths.allSatisfy({ path in
                WindowsFontCanonical.isSafeRelativePath(path) &&
                    path.hasPrefix("\(journal.scratchRootRelativePath)/payload/") &&
                    path.hasSuffix(".font-stage")
              }),
              journal.plannedCreatedDirectoryRelativePaths.allSatisfy(
                WindowsFontCanonical.isSafeRelativePath
              ) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }

        let expectedStages = journal.operation == "apply"
            ? journal.plannedOwnedFileIDs.map {
                "\(journal.scratchRootRelativePath)/payload/\($0).font-stage"
            }.sorted()
            : []
        guard journal.payloadStageRelativePaths == expectedStages else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        if journal.operation == "uninstall" {
            guard journal.committedOwnedFileIDs == journal.plannedOwnedFileIDs,
                  journal.committedOwnedRegistryIDs == journal.plannedOwnedRegistryIDs else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        } else if journal.operation == "reconcile" {
            guard journal.committedOwnedFileIDs == journal.plannedOwnedFileIDs else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        }

        let allowedPersistent = Set([
            "windows/Fonts",
            "ForgePlay",
            "ForgePlay/FontCompatibility"
        ])
        let allowedScratch = Set([
            lifecycleContract.namespace.scratchDirectoryRelativePath,
            journal.scratchRootRelativePath,
            "\(journal.scratchRootRelativePath)/payload",
            "\(journal.scratchRootRelativePath)/marker"
        ])
        let directorySet = Set(journal.plannedCreatedDirectoryRelativePaths)
        if journal.operation == "apply" {
            guard allowedScratch.isSubset(of: directorySet),
                  directorySet.isSubset(of: allowedPersistent.union(allowedScratch)),
                  journal.plannedCreatedDirectoryRelativePaths ==
                    parentFirst(journal.plannedCreatedDirectoryRelativePaths),
                  journal.plannedCreatedDirectoryRelativePaths.count <= 7 else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        } else if journal.operation == "reconcile" {
            let required = Set([
                lifecycleContract.namespace.scratchDirectoryRelativePath,
                journal.scratchRootRelativePath,
                "\(journal.scratchRootRelativePath)/marker"
            ])
            guard required == directorySet,
                  journal.plannedCreatedDirectoryRelativePaths ==
                    parentFirst(journal.plannedCreatedDirectoryRelativePaths) else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        } else {
            guard directorySet.isSubset(of: allowedPersistent),
                  journal.plannedCreatedDirectoryRelativePaths ==
                    journal.plannedCreatedDirectoryRelativePaths.sorted() else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        }

        _ = try WindowsFontLifecycleFileSystem.relativeURL(
            journal.scratchRootRelativePath,
            below: driveC
        )
        for relative in journal.payloadStageRelativePaths +
            [journal.markerStageRelativePath] +
            journal.plannedCreatedDirectoryRelativePaths {
            _ = try WindowsFontLifecycleFileSystem.relativeURL(relative, below: driveC)
        }
    }

    private func journalURL(in prefix: URL) -> URL {
        prefix.appending(path: lifecycleContract.namespace.journalRelativePath)
    }

    private func markerURL(in prefix: URL) -> URL {
        prefix.appending(path: lifecycleContract.namespace.markerRelativePath)
    }

    private func readAndValidateJournal(
        prefix: URL,
        driveC: URL
    ) throws -> WindowsFontLifecycleJournal {
        let journalPath = journalURL(in: prefix)
        let data: Data
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: journalPath,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: journalPath,
                maximumByteCount: WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let journal = try WindowsFontLifecycleJSON.decodeCanonical(
            WindowsFontLifecycleJournal.self,
            data: data,
            exactKeys: WindowsFontLifecycleJournal.exactKeys
        )
        try validate(journal: journal, driveC: driveC)
        return journal
    }

    private func readAndValidateMarker(
        prefix: URL
    ) throws -> WindowsFontLifecycleMarker {
        try readAndValidateMarker(at: markerURL(in: prefix))
    }

    private func readAndValidateMarker(
        at markerPath: URL
    ) throws -> WindowsFontLifecycleMarker {
        let data: Data
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: markerPath,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: markerPath,
                maximumByteCount: WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        let marker = try WindowsFontLifecycleJSON.decodeCanonical(
            WindowsFontLifecycleMarker.self,
            data: data,
            exactKeys: WindowsFontLifecycleMarker.exactKeys
        )
        let payloadIDs = Set(definition.payloads.map(\.descriptorID))
        let allowedDirectories = Set([
            "windows/Fonts",
            "ForgePlay",
            "ForgePlay/FontCompatibility"
        ])
        guard [1, 2].contains(marker.schemaVersion),
              marker.profileIdentifier == definition.profileIdentifier,
              marker.descriptorDigest == definition.descriptorDigest,
              WindowsFontCanonical.sortedUnique(marker.ownedFileIDs),
              WindowsFontCanonical.sortedUnique(marker.ownedRegistryIDs),
              Set(marker.ownedFileIDs).isSubset(of: payloadIDs),
              lifecycleContract.registryOwnershipIDsAreValid(
                marker.ownedRegistryIDs,
                allowsReplacements: marker.schemaVersion == 2,
                requiresCompleteReplacementSet: true
              ),
              WindowsFontCanonical.sortedUnique(marker.createdDirectoryRelativePaths),
              Set(marker.createdDirectoryRelativePaths).isSubset(of: allowedDirectories) else {
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return marker
    }

    private func persistJournal(
        _ journal: WindowsFontLifecycleJournal,
        prefix: URL,
        driveCDescriptor: Int32
    ) throws {
        let url = journalURL(in: prefix)
        let driveC = prefix.appending(path: "drive_c")
        let data = try WindowsFontLifecycleJSON.encodeCanonical(journal)
        var descriptor: Int32 = -1
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        try performFilesystem(try operation(
            .journalExclusiveCreate,
            resource: lifecycleContract.namespace.journalRelativePath,
            ordinal: 0
        )) {
            descriptor = try WindowsFontLifecycleFileSystem.openExclusiveRegularFile(
                relativePath:
                    lifecycleContract.namespace.driveCJournalRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                mode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
        }
        try performFilesystem(try operation(
            .journalCompleteWrite,
            resource: lifecycleContract.namespace.journalRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.writeAll(data, to: descriptor)
        }
        try performFilesystem(try operation(
            .journalFileFSync,
            resource: lifecycleContract.namespace.journalRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                descriptor,
                label: "journal file fsync"
            )
        }
        try performFilesystem(try operation(
            .journalClose,
            resource: lifecycleContract.namespace.journalRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.closeDescriptor(
                &descriptor,
                label: "journal close"
            )
        }
        try performFilesystem(try operation(
            .journalReopenCanonicalVerify,
            resource: lifecycleContract.namespace.journalRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.verifyRegularFile(
                at: url,
                expectedData: data,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            let verified = try self.readAndValidateJournal(prefix: prefix, driveC: prefix.appending(path: "drive_c"))
            guard verified == journal else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        }
        try performFilesystem(try operation(
            .journalParentDirectoryFSync,
            resource: "drive_c",
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                driveCDescriptor,
                label: "journal parent directory fsync"
            )
        }
    }

    private func persistCommittedOwnership(
        _ next: WindowsFontLifecycleJournal,
        replacing current: WindowsFontLifecycleJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        resourceID: String,
        ordinal: Int
    ) throws {
        let updateRelativePath =
            "\(next.scratchRootRelativePath)/marker/journal-ownership-update.json"
        let updateURL = try WindowsFontLifecycleFileSystem.relativeURL(
            updateRelativePath,
            below: driveC
        )
        let nextData = try WindowsFontLifecycleJSON.encodeCanonical(next)
        let currentData = try WindowsFontLifecycleJSON.encodeCanonical(current)
        let nextDigest = SHA256.hash(data: nextData)
            .map { String(format: "%02x", $0) }.joined()
        let currentDigest = SHA256.hash(data: currentData)
            .map { String(format: "%02x", $0) }.joined()
        var updateDescriptor: Int32 = -1
        defer {
            if updateDescriptor >= 0 { Darwin.close(updateDescriptor) }
        }
        do {
            try performFilesystem(try operation(
                .committedOwnershipStageExclusiveCreate,
                resource: resourceID,
                ordinal: ordinal
            )) {
                updateDescriptor = try WindowsFontLifecycleFileSystem
                    .openExclusiveRegularFile(
                        relativePath: updateRelativePath,
                        below: driveC,
                        descriptor: driveCDescriptor,
                        mode: WindowsFontLifecycleFileSystem.evidenceFileMode
                    )
            }
            try performFilesystem(try operation(
                .committedOwnershipStageCompleteWrite,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.writeAll(nextData, to: updateDescriptor)
            }
            try performFilesystem(try operation(
                .committedOwnershipStageFileFSync,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    updateDescriptor,
                    label: "committed ownership journal stage fsync"
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipStageClose,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &updateDescriptor,
                    label: "committed ownership journal stage close"
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipStageReopenCanonicalVerify,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.verifyRegularFile(
                    at: updateURL,
                    expectedData: nextData,
                    exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipExchange,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.exchangeRegularFiles(
                    firstRelativePath: updateRelativePath,
                    firstExpectedSHA256: nextDigest,
                    secondRelativePath:
                        lifecycleContract.namespace.driveCJournalRelativePath,
                    secondExpectedSHA256: currentDigest,
                    below: driveC,
                    descriptor: driveCDescriptor
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipDriveCFSync,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    driveCDescriptor,
                    label: "committed ownership journal parent fsync"
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipStaleStageUnlink,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                    relativePath: updateRelativePath,
                    below: driveC,
                    descriptor: driveCDescriptor,
                    expectedSHA256: currentDigest
                )
            }
            var updateParentDescriptor = try WindowsFontLifecycleFileSystem.openDirectory(
                relativePath: "\(next.scratchRootRelativePath)/marker",
                below: driveC,
                descriptor: driveCDescriptor
            )
            defer {
                if updateParentDescriptor >= 0 { Darwin.close(updateParentDescriptor) }
            }
            try performFilesystem(try operation(
                .committedOwnershipUpdateParentFSync,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    updateParentDescriptor,
                    label: "committed ownership journal update parent fsync"
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipUpdateParentClose,
                resource: resourceID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &updateParentDescriptor,
                    label: "committed ownership journal update parent close"
                )
            }
            try performFilesystem(try operation(
                .committedOwnershipCanonicalReread,
                resource: resourceID,
                ordinal: ordinal
            )) {
                let verified = try readAndValidateJournal(prefix: prefix, driveC: driveC)
                guard verified == next else {
                    throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
                }
            }
        } catch let error as WindowsFontCompatibilityProfileError {
            switch error {
            case .commitCleanupDurabilityUnknown, .interruptedAfterOperation:
                throw error
            default:
                break
            }
            throw WindowsFontCompatibilityProfileError.commitCleanupDurabilityUnknown(
                "committed ownership journal update: \(error.localizedDescription)"
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.commitCleanupDurabilityUnknown(
                "committed ownership journal update: \(error.localizedDescription)"
            )
        }
    }

    private func createPlannedDirectories(
        journal: WindowsFontLifecycleJournal,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        for (ordinal, relativePath) in
            journal.plannedCreatedDirectoryRelativePaths.enumerated() {
            let createOperation = try operation(
                .plannedDirectoryCreateVerify,
                resource: relativePath,
                ordinal: ordinal
            )
            try performFilesystem(createOperation) {
                let isScratch = relativePath.hasPrefix(
                    lifecycleContract.namespace.scratchDirectoryRelativePath
                )
                try WindowsFontLifecycleFileSystem.createDirectory(
                    relativePath: relativePath,
                    below: driveC,
                    descriptor: driveCDescriptor,
                    mode: isScratch
                        ? WindowsFontLifecycleFileSystem.privateDirectoryMode
                        : WindowsFontLifecycleFileSystem.productDirectoryMode
                )
            }
            var parentDescriptor: Int32 = -1
            defer {
                if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
            }
            try performFilesystem(try operation(
                .plannedDirectoryContainingParentFSync,
                resource: relativePath,
                ordinal: ordinal
            )) {
                parentDescriptor = try WindowsFontLifecycleFileSystem
                    .openContainingDirectory(
                        for: relativePath,
                        below: driveC,
                        descriptor: driveCDescriptor
                    )
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    parentDescriptor,
                    label: "planned directory containing parent fsync"
                )
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &parentDescriptor,
                    label: "planned directory containing parent close"
                )
            }
        }
    }

    private func installPlannedPayloads(
        plan: WindowsFontLifecyclePreflightPlan,
        journal: inout WindowsFontLifecycleJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        mutationLog: inout WindowsFontLifecycleMutationLog
    ) throws {
        let plannedSet = Set(plan.plannedOwnedFileIDs)
        let payloads = definition.payloadsInDescriptorOrder.filter {
            plannedSet.contains($0.descriptorID)
        }
        let entries: [(
            payload: WindowsFontPayloadDescriptor,
            source: URL,
            stageRelativePath: String,
            stageURL: URL,
            destinationRelativePath: String
        )] = try payloads.map { payload in
            guard let source = plan.sourceURLsByPayloadID[payload.descriptorID] else {
                throw WindowsFontCompatibilityProfileError.bundledPayloadMissing
            }
            let stageRelative =
                "\(journal.scratchRootRelativePath)/payload/\(payload.descriptorID).font-stage"
            guard journal.payloadStageRelativePaths.contains(stageRelative) else {
                throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                    payload.descriptorID
                )
            }
            let stageURL = try WindowsFontLifecycleFileSystem.relativeURL(
                stageRelative,
                below: driveC
            )
            return (
                payload,
                source,
                stageRelative,
                stageURL,
                "windows/Fonts/\(payload.fileName)"
            )
        }

        var descriptorsByPayloadID: [String: Int32] = [:]
        defer {
            for descriptor in descriptorsByPayloadID.values where descriptor >= 0 {
                Darwin.close(descriptor)
            }
        }

        for (ordinal, entry) in entries.enumerated() {
            try performFilesystem(try operation(
                .payloadStageExclusiveCreate,
                resource: entry.payload.descriptorID,
                ordinal: ordinal
            )) {
                let descriptor = try WindowsFontLifecycleFileSystem.openExclusiveRegularFile(
                    relativePath: entry.stageRelativePath,
                    below: driveC,
                    descriptor: driveCDescriptor,
                    mode: WindowsFontLifecycleFileSystem.regularFileMode
                )
                descriptorsByPayloadID[entry.payload.descriptorID] = descriptor
            }
        }

        for (ordinal, entry) in entries.enumerated() {
            guard let descriptor = descriptorsByPayloadID[entry.payload.descriptorID] else {
                throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                    entry.payload.descriptorID
                )
            }
            try performFilesystem(try operation(
                .payloadAuthenticatedSourceCopy,
                resource: entry.payload.descriptorID,
                ordinal: ordinal
            )) {
                let sourceData = try WindowsFontLifecycleFileSystem.readRegularFile(
                    at: entry.source,
                    maximumByteCount: 256 * 1_024 * 1_024
                )
                guard SHA256.hash(data: sourceData)
                    .map({ String(format: "%02x", $0) }).joined() == entry.payload.sha256 else {
                    throw WindowsFontCompatibilityProfileError.bundledPayloadMissing
                }
                try WindowsFontLifecycleFileSystem.writeAll(sourceData, to: descriptor)
            }
        }

        for (ordinal, entry) in entries.enumerated() {
            guard var descriptor = descriptorsByPayloadID[entry.payload.descriptorID] else {
                throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                    entry.payload.descriptorID
                )
            }
            try performFilesystem(try operation(
                .payloadStageFSyncHashVerify,
                resource: entry.payload.descriptorID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    descriptor,
                    label: "payload stage fsync"
                )
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &descriptor,
                    label: "payload stage close"
                )
                descriptorsByPayloadID[entry.payload.descriptorID] = descriptor
                try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                    at: entry.stageURL,
                    exactMode: WindowsFontLifecycleFileSystem.regularFileMode
                )
                guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                    at: entry.stageURL
                ) == entry.payload.sha256 else {
                    throw WindowsFontCompatibilityProfileError.verificationFailed([
                        entry.stageURL.path
                    ])
                }
            }
            descriptorsByPayloadID[entry.payload.descriptorID] = descriptor
        }

        for (ordinal, entry) in entries.enumerated() {
            // Claim ownership durably before publishing the destination.  The
            // journal is the only recovery authority that survives a process
            // stop, so recording ownership after publish leaves an
            // unobservable publish -> journal window.  A claimed resource
            // that was never published is safe for rollback: removal is
            // identity-checked and treats absence as success.
            let currentJournal = journal
            let nextJournal = try currentJournal.committing(
                fileID: entry.payload.descriptorID
            )
            try persistCommittedOwnership(
                nextJournal,
                replacing: currentJournal,
                prefix: prefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                resourceID: entry.payload.descriptorID,
                ordinal: ordinal
            )
            journal = nextJournal
            mutationLog.createdFileIDs.append(entry.payload.descriptorID)

            var publicationParents: (sourceParent: Int32, destinationParent: Int32)?
            defer {
                if let publicationParents {
                    Darwin.close(publicationParents.sourceParent)
                    Darwin.close(publicationParents.destinationParent)
                }
            }
            try performFilesystem(try operation(
                .payloadNoOverwriteDestinationPublish,
                resource: entry.payload.descriptorID,
                ordinal: ordinal
            )) {
                publicationParents = try WindowsFontLifecycleFileSystem.publishNoReplace(
                    fromRelativePath: entry.stageRelativePath,
                    toRelativePath: entry.destinationRelativePath,
                    below: driveC,
                    descriptor: driveCDescriptor,
                    expectedSHA256: entry.payload.sha256
                )
            }
            guard let publicationParents else {
                throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                    entry.payload.descriptorID
                )
            }
            try performFilesystem(try operation(
                .payloadPublicationStageParentFSync,
                resource: entry.payload.descriptorID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    publicationParents.sourceParent,
                    label: "payload publication stage parent fsync"
                )
            }
            try performFilesystem(try operation(
                .payloadPublicationDestinationParentFSync,
                resource: entry.payload.descriptorID,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    publicationParents.destinationParent,
                    label: "payload publication destination parent fsync"
                )
            }
        }
    }

    private func installPlannedRegistryValues(
        plan: WindowsFontLifecyclePreflightPlan,
        journal: inout WindowsFontLifecycleJournal,
        runtimeExecutable: URL,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        logDirectory: URL,
        mutationLog: inout WindowsFontLifecycleMutationLog
    ) async throws -> ProcessRunResult? {
        let createdSet = Set(plan.plannedCreatedRegistryIDs)
        let replacedSet = Set(plan.plannedReplacedRegistryIDs)
        let replacementsByTargetID = Dictionary(uniqueKeysWithValues:
            applicableSupportedRegistryReplacements
                .filter { replacedSet.contains($0.replacementID) }
                .map { ($0.target.descriptorID, $0) }
        )
        let mutations: [(
            ownershipID: String,
            target: WindowsFontRegistryRequirement,
            baseline: WindowsFontRegistryRequirement?
        )] = definition.registryRequirementsInDescriptorOrder.compactMap { requirement in
            if createdSet.contains(requirement.descriptorID) {
                return (requirement.descriptorID, requirement, nil)
            }
            if let replacement = replacementsByTargetID[requirement.descriptorID] {
                return (
                    replacement.replacementID,
                    replacement.target,
                    replacement.baseline
                )
            }
            return nil
        }
        guard Set(mutations.map(\.ownershipID)) ==
            Set(plan.plannedRegistryMutationIDs) else {
            throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                "planned-registry-mutation-set"
            )
        }
        var attempted = false
        for (ordinal, mutation) in mutations.enumerated() {
            let snapshots = try loadRegistrySnapshots(prefix: prefix)
            let snapshot = mutation.target.registryPath.hasPrefix("HKCU\\")
                ? snapshots.user
                : snapshots.system
            if let baseline = mutation.baseline {
                guard snapshot.orderedValues(for: baseline) == baseline.orderedValues else {
                    throw WindowsFontCompatibilityProfileError.collision(
                        registryCollisionReason(
                            snapshot: snapshot,
                            requirement: mutation.target,
                            classification: "concurrent-fresh-baseline-drift"
                        )
                    )
                }
            } else if snapshot.containsValue(for: mutation.target) {
                throw WindowsFontCompatibilityProfileError.collision(
                    registryCollisionReason(
                        snapshot: snapshot,
                        requirement: mutation.target,
                        classification: "concurrent-created-value-appeared"
                    )
                )
            }
            attempted = true
            let registryOperation = try operation(
                .registrySet,
                resource: mutation.ownershipID,
                ordinal: ordinal
            )
            // Registry mutation has the same write-ahead ownership contract
            // as payload publication.  If the runner mutates the prefix and
            // the host stops before returning, recovery must already know the
            // exact registry value it owns and must compensate.
            let nextJournal = try journal.committing(
                registryID: mutation.ownershipID
            )
            try persistCommittedOwnership(
                nextJournal,
                replacing: journal,
                prefix: prefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                resourceID: mutation.ownershipID,
                ordinal: plan.plannedOwnedFileIDs.count + ordinal
            )
            journal = nextJournal
            if mutation.baseline == nil {
                mutationLog.createdRegistryIDs.append(mutation.ownershipID)
            } else {
                mutationLog.replacedRegistryIDs.append(mutation.ownershipID)
            }
            let result = try await performRunnerAction(
                registryOperation,
                .setRegistryValue(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    registryPath: mutation.target.registryPath,
                    valueName: mutation.target.valueName,
                    valueType: mutation.target.valueType,
                    value: mutation.target.encodedRunnerValue,
                    logDirectory: logDirectory
                )
            )
            guard result.succeeded else { return result }
        }

        if attempted {
            let result = try await performRunnerAction(
                try operation(
                    .forwardRegistryFlush,
                    resource: "registry-forward-flush",
                    ordinal: 0
                ),
                .waitForWinePrefix(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
            )
            guard result.succeeded else { return result }
        }
        return nil
    }

    private func publishMarker(
        _ marker: WindowsFontLifecycleMarker,
        journal: WindowsFontLifecycleJournal,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        let data = try WindowsFontLifecycleJSON.encodeCanonical(marker)
        let stage = try WindowsFontLifecycleFileSystem.relativeURL(
            journal.markerStageRelativePath,
            below: driveC
        )
        let destinationRelativePath =
            lifecycleContract.namespace.driveCMarkerRelativePath
        var descriptor: Int32 = -1
        var publicationParents: (sourceParent: Int32, destinationParent: Int32)?
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if let publicationParents {
                Darwin.close(publicationParents.sourceParent)
                Darwin.close(publicationParents.destinationParent)
            }
        }
        try performFilesystem(try operation(
            .markerStageExclusiveCreate,
            resource: journal.markerStageRelativePath,
            ordinal: 0
        )) {
            descriptor = try WindowsFontLifecycleFileSystem.openExclusiveRegularFile(
                relativePath: journal.markerStageRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                mode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
        }
        try performFilesystem(try operation(
            .markerCompleteWrite,
            resource: journal.markerStageRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.writeAll(data, to: descriptor)
        }
        try performFilesystem(try operation(
            .markerFileFSync,
            resource: journal.markerStageRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                descriptor,
                label: "marker stage fsync"
            )
            try WindowsFontLifecycleFileSystem.closeDescriptor(
                &descriptor,
                label: "marker stage close"
            )
        }
        try performFilesystem(try operation(
            .markerReopenCanonicalVerify,
            resource: journal.markerStageRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.verifyRegularFile(
                at: stage,
                expectedData: data,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            let decoded = try WindowsFontLifecycleJSON.decodeCanonical(
                WindowsFontLifecycleMarker.self,
                data: data,
                exactKeys: WindowsFontLifecycleMarker.exactKeys
            )
            guard decoded == marker else {
                throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            }
        }
        try performFilesystem(try operation(
            .markerNoOverwritePublication,
            resource: lifecycleContract.namespace.driveCMarkerRelativePath,
            ordinal: 0
        )) {
            publicationParents = try WindowsFontLifecycleFileSystem.publishNoReplace(
                fromRelativePath: journal.markerStageRelativePath,
                toRelativePath: destinationRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                expectedSHA256: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
            )
        }
        guard let publicationParents else {
            throw WindowsFontCompatibilityProfileError.operationProjectionMismatch(
                destinationRelativePath
            )
        }
        try performFilesystem(try operation(
            .markerPublicationStageParentFSync,
            resource: "\(journal.scratchRootRelativePath)/marker",
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                publicationParents.sourceParent,
                label: "marker publication stage parent fsync"
            )
        }
    }

    private func fsyncMarkerParent(
        driveC: URL,
        driveCDescriptor: Int32,
        operationKind: WindowsFontLifecycleOperationKind
    ) throws {
        var descriptor = try WindowsFontLifecycleFileSystem.openDirectory(
            relativePath: "ForgePlay/FontCompatibility",
            below: driveC,
            descriptor: driveCDescriptor
        )
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        try performFilesystem(try operation(
            operationKind,
            resource: "ForgePlay/FontCompatibility",
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                descriptor,
                label: "marker parent directory fsync"
            )
        }
        try WindowsFontLifecycleFileSystem.closeDescriptor(
            &descriptor,
            label: "marker parent close"
        )
    }

    private func synchronizeCommittedNamespaces(
        journal: WindowsFontLifecycleJournal,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        for (ordinal, relativePath) in
            journal.plannedCreatedDirectoryRelativePaths.enumerated() {
            var parentDescriptor: Int32 = -1
            defer {
                if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
            }
            try performFilesystem(try operation(
                .committedDirectoryContainingParentFSync,
                resource: relativePath,
                ordinal: ordinal
            )) {
                parentDescriptor = try WindowsFontLifecycleFileSystem
                    .openContainingDirectory(
                        for: relativePath,
                        below: driveC,
                        descriptor: driveCDescriptor
                    )
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    parentDescriptor,
                    label: "committed planned directory parent fsync"
                )
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &parentDescriptor,
                    label: "committed planned directory parent close"
                )
            }
        }

        let committedPayloads = definition.payloadsInDescriptorOrder.filter {
            journal.committedOwnedFileIDs.contains($0.descriptorID)
        }
        for (ordinal, payload) in committedPayloads.enumerated() {
            let stageRelativePath =
                "\(journal.scratchRootRelativePath)/payload/\(payload.descriptorID).font-stage"
            for (kind, relativePath, label) in [
                (
                    WindowsFontLifecycleOperationKind.committedPayloadStageParentFSync,
                    stageRelativePath,
                    "committed payload stage parent fsync"
                ),
                (
                    WindowsFontLifecycleOperationKind
                        .committedPayloadDestinationParentFSync,
                    "windows/Fonts/\(payload.fileName)",
                    "committed payload destination parent fsync"
                )
            ] {
                var parentDescriptor: Int32 = -1
                defer {
                    if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
                }
                try performFilesystem(try operation(
                    kind,
                    resource: payload.descriptorID,
                    ordinal: ordinal
                )) {
                    parentDescriptor = try WindowsFontLifecycleFileSystem
                        .openContainingDirectory(
                            for: relativePath,
                            below: driveC,
                            descriptor: driveCDescriptor
                        )
                    try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                        parentDescriptor,
                        label: label
                    )
                    try WindowsFontLifecycleFileSystem.closeDescriptor(
                        &parentDescriptor,
                        label: "\(label) close"
                    )
                }
            }
        }

        var markerStageParentDescriptor: Int32 = -1
        defer {
            if markerStageParentDescriptor >= 0 {
                Darwin.close(markerStageParentDescriptor)
            }
        }
        try performFilesystem(try operation(
            .committedMarkerStageParentFSync,
            resource: "\(journal.scratchRootRelativePath)/marker",
            ordinal: 0
        )) {
            markerStageParentDescriptor = try WindowsFontLifecycleFileSystem
                .openContainingDirectory(
                    for: journal.markerStageRelativePath,
                    below: driveC,
                    descriptor: driveCDescriptor
                )
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                markerStageParentDescriptor,
                label: "committed marker stage parent fsync"
            )
            try WindowsFontLifecycleFileSystem.closeDescriptor(
                &markerStageParentDescriptor,
                label: "committed marker stage parent close"
            )
        }
        try fsyncMarkerParent(
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            operationKind: .committedMarkerParentFSync
        )
    }

    private func repairIfRequired(
        runtimeExecutable: URL,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        logDirectory: URL
    ) async throws -> WindowsFontLifecycleRepairResult {
        let journalPath = journalURL(in: prefix)
        guard try WindowsFontLifecycleFileSystem.lstatItem(journalPath) != nil else {
            return .notRequired
        }
        let journal = try readAndValidateJournal(prefix: prefix, driveC: driveC)
        // A prior process may have stopped after writing the canonical journal
        // but before its parent fsync completed. Re-establish that durability
        // boundary before any recovery mutation consumes the journal.
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            driveCDescriptor,
            label: "font recovery journal parent fsync"
        )
        switch journal.operation {
        case "apply":
            if try WindowsFontLifecycleFileSystem.lstatItem(markerURL(in: prefix)) != nil {
                _ = try readAndValidateMarker(prefix: prefix)
                let inspection = await inspectForLaunch(
                    prefix: prefix,
                    requiresProfileMarker: true
                )
                guard inspection.isSatisfied else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        inspection.missingItems.joined(separator: ", ")
                    )
                }
                let verified = try cleanupCommittedApply(
                    journal: journal,
                    prefix: prefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor,
                    verifiedInspection: inspection
                )
                return .init(
                    didRepair: true,
                    unsuccessfulProcessResult: nil,
                    verifiedInspection: verified
                )
            } else {
                try await rollback(
                    journal: journal,
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor,
                    logDirectory: logDirectory,
                    fileIDs: journal.committedOwnedFileIDs,
                    registryIDs: journal.committedOwnedRegistryIDs
                )
            }
        case "reconcile":
            let plan = try makeCommittedReconciliationPlan(
                journal: journal,
                prefix: prefix,
                driveC: driveC
            )
            let reconciliation = try await continueCommittedReconciliation(
                plan: plan,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                logDirectory: logDirectory
            )
            return .init(
                didRepair: true,
                unsuccessfulProcessResult:
                    reconciliation.unsuccessfulProcessResult,
                verifiedInspection: reconciliation.verifiedInspection
            )
        case "uninstall":
            let outcome = await removeOwnedResources(
                journal: journal,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor,
                logDirectory: logDirectory,
                fileIDs: journal.committedOwnedFileIDs,
                registryIDs: journal.committedOwnedRegistryIDs,
                removeMarkerWhenComplete: true
            )
            if let terminalError = outcome.terminalError { throw terminalError }
            guard outcome.succeeded else {
                let reason = outcome.firstErrorDescription ??
                    outcome.firstProcessResult.map { "process \($0.actionName)" } ??
                    "unknown"
                throw WindowsFontCompatibilityProfileError.uninstallIncomplete(
                    reason,
                    Array(Set(outcome.remainingIDs)).sorted()
                )
            }
            try deleteJournalAndSynchronizeParent(
                journal: journal,
                prefix: prefix,
                driveCDescriptor: driveCDescriptor
            )
        default:
            throw WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
        }
        return .init(
            didRepair: true,
            unsuccessfulProcessResult: nil,
            verifiedInspection: nil
        )
    }

    private func rollback(
        journal: WindowsFontLifecycleJournal,
        runtimeExecutable: URL,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        logDirectory: URL,
        fileIDs: [String],
        registryIDs: [String]
    ) async throws {
        var outcome = await removeOwnedResources(
            journal: journal,
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor,
            logDirectory: logDirectory,
            fileIDs: fileIDs,
            registryIDs: registryIDs,
            removeMarkerWhenComplete: false,
            verifyStateBeforeMarker: false
        )
        if let terminalError = outcome.terminalError { throw terminalError }
        do {
            try cleanupBoundStages(
                journal: journal,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor
            )
        } catch {
            outcome.record(error: error, resourceID: journal.scratchRootRelativePath)
            if let terminalError = outcome.terminalError { throw terminalError }
        }
        do {
            try removePlannedDirectories(
                journal.plannedCreatedDirectoryRelativePaths,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor
            )
        } catch {
            outcome.record(error: error)
            if let terminalError = outcome.terminalError { throw terminalError }
        }
        do {
            try verifyAdoptedAndOwnedState(
                journal: journal,
                prefix: prefix,
                ownedFilesMustBeAbsent: true,
                ownedRegistryMustBeAbsent: true
            )
        } catch {
            outcome.record(error: error)
            if let terminalError = outcome.terminalError { throw terminalError }
        }
        if let processResult = outcome.firstProcessResult {
            outcome.record(
                error: WindowsFontCompatibilityProfileError.filesystemFailure(
                    "rollback process failed: \(processResult.actionName)"
                )
            )
        }
        guard outcome.succeeded else {
            throw WindowsFontCompatibilityProfileError.rollbackIncomplete(
                outcome.firstErrorDescription ?? "unknown",
                Array(Set(outcome.remainingIDs)).sorted()
            )
        }
        try deleteJournalAndSynchronizeParent(
            journal: journal,
            prefix: prefix,
            driveCDescriptor: driveCDescriptor
        )
    }

    private func removeOwnedResources(
        journal: WindowsFontLifecycleJournal,
        runtimeExecutable: URL,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        logDirectory: URL,
        fileIDs: [String],
        registryIDs: [String],
        removeMarkerWhenComplete: Bool,
        verifyStateBeforeMarker: Bool = true
    ) async -> WindowsFontLifecycleRemovalOutcome {
        var outcome = WindowsFontLifecycleRemovalOutcome()
        let registryIDSet = Set(registryIDs)
        let replacementsByTargetID = Dictionary(uniqueKeysWithValues:
            applicableSupportedRegistryReplacements
                .filter { registryIDSet.contains($0.replacementID) }
                .map { ($0.target.descriptorID, $0) }
        )
        let forwardRegistryMutations: [(
            ownershipID: String,
            target: WindowsFontRegistryRequirement,
            baseline: WindowsFontRegistryRequirement?
        )] = definition.registryRequirementsInDescriptorOrder.compactMap { requirement in
            if registryIDSet.contains(requirement.descriptorID) {
                return (requirement.descriptorID, requirement, nil)
            }
            if let replacement = replacementsByTargetID[requirement.descriptorID] {
                return (
                    replacement.replacementID,
                    replacement.target,
                    replacement.baseline
                )
            }
            return nil
        }
        let orderedRegistryMutations = Array(forwardRegistryMutations.reversed())
        guard Set(orderedRegistryMutations.map(\.ownershipID)) == registryIDSet else {
            outcome.record(
                error: WindowsFontCompatibilityProfileError.malformedLifecycleEvidence
            )
            return outcome
        }
        var registryMutationAttempted = false
        var registryDeleteOrdinal = 0
        var registryRestoreOrdinal = 0
        for mutation in orderedRegistryMutations {
            do {
                let snapshots = try loadRegistrySnapshots(prefix: prefix)
                let snapshot = mutation.target.registryPath.hasPrefix("HKCU\\")
                    ? snapshots.user
                    : snapshots.system
                if let baseline = mutation.baseline {
                    if snapshot.orderedValues(for: baseline) == baseline.orderedValues {
                        continue
                    }
                    let restoreOperation = try operation(
                        .replacedRegistryRestore,
                        resource: mutation.ownershipID,
                        ordinal: registryRestoreOrdinal
                    )
                    registryRestoreOrdinal += 1
                    guard snapshot.orderedValues(for: mutation.target) ==
                        mutation.target.orderedValues else {
                        try performFilesystem(restoreOperation) {
                            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                                registryCollisionReason(
                                    snapshot: snapshot,
                                    requirement: mutation.target,
                                    classification: "restore-current-value-drift"
                                )
                            )
                        }
                        continue
                    }
                    registryMutationAttempted = true
                    let result = try await performRunnerAction(
                        restoreOperation,
                        .setRegistryValue(
                            runtimeExecutable: runtimeExecutable,
                            prefix: prefix,
                            registryPath: baseline.registryPath,
                            valueName: baseline.valueName,
                            valueType: baseline.valueType,
                            value: baseline.encodedRunnerValue,
                            logDirectory: logDirectory
                        )
                    )
                    if !result.succeeded {
                        outcome.record(result: result, resourceID: mutation.ownershipID)
                    }
                } else {
                    guard snapshot.containsValue(for: mutation.target) else { continue }
                    let deleteOperation = try operation(
                        .ownedRegistryDelete,
                        resource: mutation.ownershipID,
                        ordinal: registryDeleteOrdinal
                    )
                    registryDeleteOrdinal += 1
                    if snapshot.orderedValues(for: mutation.target) ==
                        mutation.target.orderedValues {
                        registryMutationAttempted = true
                        let result = try await performRunnerAction(
                            deleteOperation,
                            .deleteRegistryValue(
                                runtimeExecutable: runtimeExecutable,
                                prefix: prefix,
                                registryPath: mutation.target.registryPath,
                                valueName: mutation.target.valueName,
                                logDirectory: logDirectory
                            )
                        )
                        if !result.succeeded {
                            outcome.record(result: result, resourceID: mutation.ownershipID)
                        }
                    } else {
                        try performFilesystem(deleteOperation) {
                            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                                registryCollisionReason(
                                    snapshot: snapshot,
                                    requirement: mutation.target,
                                    classification: "delete-current-value-drift"
                                )
                            )
                        }
                    }
                }
            } catch {
                outcome.record(error: error, resourceID: mutation.ownershipID)
                if outcome.terminalError != nil { return outcome }
            }
        }

        if registryMutationAttempted {
            do {
                let result = try await performRunnerAction(
                    try operation(
                        .compensationRegistryFlush,
                        resource: "registry-compensation-flush",
                        ordinal: 0
                    ),
                    .waitForWinePrefix(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        logDirectory: logDirectory
                    )
                )
                if !result.succeeded { outcome.record(result: result) }
            } catch {
                outcome.record(error: error)
                if outcome.terminalError != nil { return outcome }
            }
        }

        do {
            let snapshots = try loadRegistrySnapshots(prefix: prefix)
            for mutation in orderedRegistryMutations {
                let snapshot = mutation.target.registryPath.hasPrefix("HKCU\\")
                    ? snapshots.user
                    : snapshots.system
                if let baseline = mutation.baseline {
                    if snapshot.orderedValues(for: baseline) != baseline.orderedValues {
                        outcome.remainingIDs.append(mutation.ownershipID)
                    }
                } else if snapshot.containsValue(for: mutation.target) {
                    outcome.remainingIDs.append(mutation.ownershipID)
                }
            }
        } catch {
            outcome.record(error: error)
            if outcome.terminalError != nil { return outcome }
        }

        let orderedFiles = definition.payloadsInDescriptorOrder
            .filter { fileIDs.contains($0.descriptorID) }
            .reversed()
        var fileDeleteOrdinal = 0
        for payload in orderedFiles {
            let destinationRelativePath = "windows/Fonts/\(payload.fileName)"
            let destination = driveC.appending(path: destinationRelativePath)
            do {
                guard try WindowsFontLifecycleFileSystem.lstatItem(destination) != nil else {
                    continue
                }
                let ordinal = fileDeleteOrdinal
                fileDeleteOrdinal += 1
                try performFilesystem(try operation(
                    .ownedFileDelete,
                    resource: payload.descriptorID,
                    ordinal: ordinal
                )) {
                    guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                        at: destination
                    ) == payload.sha256 else {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(
                            destination.path
                        )
                    }
                    try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                        relativePath: destinationRelativePath,
                        below: driveC,
                        descriptor: driveCDescriptor,
                        expectedSHA256: payload.sha256
                    )
                }
                var parentDescriptor: Int32 = -1
                defer {
                    if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
                }
                try performFilesystem(try operation(
                    .ownedFileDeletionParentFSync,
                    resource: payload.descriptorID,
                    ordinal: ordinal
                )) {
                    parentDescriptor = try WindowsFontLifecycleFileSystem
                        .openContainingDirectory(
                            for: destinationRelativePath,
                            below: driveC,
                            descriptor: driveCDescriptor
                        )
                    try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                        parentDescriptor,
                        label: "owned payload deletion parent fsync"
                    )
                    try WindowsFontLifecycleFileSystem.closeDescriptor(
                        &parentDescriptor,
                        label: "owned payload deletion parent close"
                    )
                }
            } catch {
                outcome.record(error: error, resourceID: payload.descriptorID)
                if outcome.terminalError != nil { return outcome }
            }
        }

        if verifyStateBeforeMarker {
            do {
                try verifyAdoptedAndOwnedState(
                    journal: journal,
                    prefix: prefix,
                    ownedFilesMustBeAbsent: true,
                    ownedRegistryMustBeAbsent: true
                )
            } catch {
                outcome.record(error: error)
                if outcome.terminalError != nil { return outcome }
            }
        }

        if outcome.succeeded,
           restoresLegacyV4Baseline(
            registryIDs: journal.plannedOwnedRegistryIDs
           ) {
            do {
                let snapshots = try loadRegistrySnapshots(prefix: prefix)
                guard legacyV4BaselineFilesAreAuthorized(prefix: prefix),
                      legacyV4RegistryStateIsAuthorized(snapshots: snapshots) else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-font-profile-baseline-restore-mismatch"
                    )
                }
            } catch {
                outcome.record(error: error)
                if outcome.terminalError != nil { return outcome }
            }
        }

        if removeMarkerWhenComplete, outcome.succeeded {
            do {
                let markerPath = markerURL(in: prefix)
                if try WindowsFontLifecycleFileSystem.lstatItem(markerPath) != nil {
                    let marker = try readAndValidateMarker(prefix: prefix)
                    let markerData = try WindowsFontLifecycleJSON.encodeCanonical(marker)
                    let markerDigest = SHA256.hash(data: markerData)
                        .map { String(format: "%02x", $0) }.joined()
                    var markerParentDescriptor = try WindowsFontLifecycleFileSystem
                        .openDirectory(
                            relativePath: "ForgePlay/FontCompatibility",
                            below: driveC,
                            descriptor: driveCDescriptor
                        )
                    defer {
                        if markerParentDescriptor >= 0 {
                            Darwin.close(markerParentDescriptor)
                        }
                    }
                    try performFilesystem(try operation(
                        .markerDelete,
                        resource:
                            lifecycleContract.namespace.driveCMarkerRelativePath,
                        ordinal: 0
                    )) {
                        try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                            relativePath:
                                lifecycleContract.namespace.driveCMarkerRelativePath,
                            below: driveC,
                            descriptor: driveCDescriptor,
                            expectedSHA256: markerDigest
                        )
                    }
                    do {
                        try performFilesystem(try operation(
                            .markerDeletionParentDirectoryFSync,
                            resource: "ForgePlay/FontCompatibility",
                            ordinal: 0
                        )) {
                            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                                markerParentDescriptor,
                                label: "marker deletion parent fsync"
                            )
                        }
                    } catch let error as WindowsFontCompatibilityProfileError {
                        if case .interruptedAfterOperation = error { throw error }
                        throw WindowsFontCompatibilityProfileError
                            .uninstallDurabilityUnknown(String(describing: error))
                    } catch {
                        throw WindowsFontCompatibilityProfileError
                            .uninstallDurabilityUnknown(String(describing: error))
                    }
                    try WindowsFontLifecycleFileSystem.closeDescriptor(
                        &markerParentDescriptor,
                        label: "marker deletion parent close"
                    )
                }
                try removePlannedDirectories(
                    journal.plannedCreatedDirectoryRelativePaths,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor
                )
            } catch {
                outcome.record(error: error)
                if outcome.terminalError != nil { return outcome }
            }
        }
        outcome.remainingIDs = Array(Set(outcome.remainingIDs)).sorted()
        return outcome
    }

    private func verifyAdoptedAndOwnedState(
        journal: WindowsFontLifecycleJournal,
        prefix: URL,
        ownedFilesMustBeAbsent: Bool,
        ownedRegistryMustBeAbsent: Bool
    ) throws {
        let operation = try operation(
            .adoptedStateVerification,
            resource: definition.descriptorDigest,
            ordinal: 0
        )
        try performFilesystem(operation) {
            let plannedFileIDs = Set(journal.plannedOwnedFileIDs)
            let plannedRegistryIDs = Set(journal.plannedOwnedRegistryIDs)
            let committedFileIDs = Set(journal.committedOwnedFileIDs)
            let committedRegistryIDs = Set(journal.committedOwnedRegistryIDs)
            let fonts = prefix.appending(path: "drive_c/windows/Fonts")
            for payload in definition.payloadsInDescriptorOrder {
                let url = fonts.appending(path: payload.fileName)
                let hash: String?
                if try WindowsFontLifecycleFileSystem.lstatItem(url) == nil {
                    hash = nil
                } else {
                    hash = try WindowsFontLifecycleFileSystem.sha256OfRegularFile(at: url)
                }
                if committedFileIDs.contains(payload.descriptorID) {
                    if ownedFilesMustBeAbsent {
                        if hash != nil {
                            throw WindowsFontCompatibilityProfileError.recoveryConflict(url.path)
                        }
                    } else if hash != payload.sha256 {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(url.path)
                    }
                } else if plannedFileIDs.contains(payload.descriptorID) {
                    guard ownedFilesMustBeAbsent,
                          hash == nil || hash == payload.sha256 else {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(url.path)
                    }
                } else if hash != payload.sha256 {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(url.path)
                }
            }
            let snapshots = try loadRegistrySnapshots(prefix: prefix)
            let journalReplacementIDs = plannedRegistryIDs.union(
                committedRegistryIDs
            )
            let replacementsByTargetID = Dictionary(uniqueKeysWithValues:
                applicableSupportedRegistryReplacements
                    .filter {
                        journalReplacementIDs.contains($0.replacementID)
                    }
                    .map {
                    ($0.target.descriptorID, $0)
                }
            )
            for requirement in definition.registryRequirementsInDescriptorOrder {
                let snapshot = requirement.registryPath.hasPrefix("HKCU\\")
                    ? snapshots.user
                    : snapshots.system
                let current = snapshot.orderedValues(for: requirement)
                let replacement = replacementsByTargetID[requirement.descriptorID]
                let replacementID = replacement?.replacementID
                if let replacement,
                   let replacementID,
                   committedRegistryIDs.contains(replacementID) {
                    let expected = ownedRegistryMustBeAbsent
                        ? replacement.baseline.orderedValues
                        : replacement.target.orderedValues
                    if snapshot.orderedValues(for: replacement.baseline) != expected {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(
                            registryCollisionReason(
                                snapshot: snapshot,
                                requirement: requirement,
                                classification: ownedRegistryMustBeAbsent
                                    ? "committed-replacement-not-restored"
                                    : "committed-replacement-not-target"
                            )
                        )
                    }
                } else if let replacement,
                          let replacementID,
                          plannedRegistryIDs.contains(replacementID) {
                    let expected = ownedRegistryMustBeAbsent
                        ? replacement.baseline.orderedValues
                        : replacement.target.orderedValues
                    if snapshot.orderedValues(for: replacement.baseline) != expected {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(
                            registryCollisionReason(
                                snapshot: snapshot,
                                requirement: requirement,
                                classification: ownedRegistryMustBeAbsent
                                    ? "planned-replacement-baseline-drift"
                                    : "planned-replacement-not-target"
                            )
                        )
                    }
                } else if committedRegistryIDs.contains(requirement.descriptorID) {
                    if ownedRegistryMustBeAbsent {
                        if snapshot.containsValue(for: requirement) {
                            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                                registryCollisionReason(
                                    snapshot: snapshot,
                                    requirement: requirement,
                                    classification: "committed-created-value-not-removed"
                                )
                            )
                        }
                    } else if current != requirement.orderedValues {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(
                            registryCollisionReason(
                                snapshot: snapshot,
                                requirement: requirement,
                                classification: "committed-created-value-drift"
                            )
                        )
                    }
                } else if plannedRegistryIDs.contains(requirement.descriptorID) {
                    guard ownedRegistryMustBeAbsent,
                          !snapshot.containsValue(for: requirement) ||
                            current == requirement.orderedValues else {
                        throw WindowsFontCompatibilityProfileError.recoveryConflict(
                            registryCollisionReason(
                                snapshot: snapshot,
                                requirement: requirement,
                                classification: "planned-created-value-drift"
                            )
                        )
                    }
                } else if !WindowsFontCompatibilityProfileContract
                    .isSatisfiedRegistryRequirement(
                        snapshot: snapshot,
                        requirement: requirement
                    ) {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        registryCollisionReason(
                            snapshot: snapshot,
                            requirement: requirement,
                            classification: "adopted-value-drift"
                        )
                    )
                }
            }
        }
    }

    private func cleanupBoundStages(
        journal: WindowsFontLifecycleJournal,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        try validateBoundScratchEntrySet(journal: journal, driveC: driveC)
        let ownershipUpdateStage =
            "\(journal.scratchRootRelativePath)/marker/journal-ownership-update.json"
        let stagePaths = (journal.payloadStageRelativePaths +
                          [journal.markerStageRelativePath, ownershipUpdateStage])
            .sorted(by: >)
        var presentStageOrdinal = 0
        for relativePath in stagePaths {
            let url = try WindowsFontLifecycleFileSystem.relativeURL(
                relativePath,
                below: driveC
            )
            guard try WindowsFontLifecycleFileSystem.lstatItem(url) != nil else {
                continue
            }
            let ordinal = presentStageOrdinal
            presentStageOrdinal += 1
            try performFilesystem(try operation(
                .boundStageDelete,
                resource: relativePath,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                    relativePath: relativePath,
                    below: driveC,
                    descriptor: driveCDescriptor
                )
            }
        }
    }

    private func validateBoundScratchEntrySet(
        journal: WindowsFontLifecycleJournal,
        driveC: URL
    ) throws {
        let root = try WindowsFontLifecycleFileSystem.relativeURL(
            journal.scratchRootRelativePath,
            below: driveC
        )
        guard try WindowsFontLifecycleFileSystem.lstatItem(root) != nil else { return }
        try WindowsFontLifecycleFileSystem.requireDirectory(root)
        let rootEntries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent).sorted()
        guard Set(rootEntries).isSubset(of: Set(["payload", "marker"])) else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(root.path)
        }
        let expectedPayloadNames = Set(journal.payloadStageRelativePaths.map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        let payloadDirectory = root.appending(path: "payload")
        if try WindowsFontLifecycleFileSystem.lstatItem(payloadDirectory) != nil {
            try WindowsFontLifecycleFileSystem.requireDirectory(payloadDirectory)
            let entries = try fileManager.contentsOfDirectory(
                at: payloadDirectory,
                includingPropertiesForKeys: nil,
                options: []
            ).map(\.lastPathComponent)
            guard Set(entries).isSubset(of: expectedPayloadNames) else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    payloadDirectory.path
                )
            }
        }
        let markerDirectory = root.appending(path: "marker")
        if try WindowsFontLifecycleFileSystem.lstatItem(markerDirectory) != nil {
            try WindowsFontLifecycleFileSystem.requireDirectory(markerDirectory)
            let entries = try fileManager.contentsOfDirectory(
                at: markerDirectory,
                includingPropertiesForKeys: nil,
                options: []
            ).map(\.lastPathComponent)
            let expected = URL(fileURLWithPath: journal.markerStageRelativePath)
                .lastPathComponent
            guard Set(entries).isSubset(
                of: Set([expected, "journal-ownership-update.json"])
            ) else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    markerDirectory.path
                )
            }
        }
    }

    private func removePlannedDirectories(
        _ relativePaths: [String],
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        var presentDirectoryOrdinal = 0
        for relativePath in reverseDepth(relativePaths) {
            let url = try WindowsFontLifecycleFileSystem.relativeURL(
                relativePath,
                below: driveC
            )
            guard try WindowsFontLifecycleFileSystem.lstatItem(url) != nil else {
                continue
            }
            let ordinal = presentDirectoryOrdinal
            presentDirectoryOrdinal += 1
            try performFilesystem(try operation(
                .plannedDirectoryDelete,
                resource: relativePath,
                ordinal: ordinal
            )) {
                try WindowsFontLifecycleFileSystem.removeDirectory(
                    relativePath: relativePath,
                    below: driveC,
                    descriptor: driveCDescriptor
                )
            }
            var parentDescriptor: Int32 = -1
            defer {
                if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
            }
            try performFilesystem(try operation(
                .plannedDirectoryDeletionContainingParentFSync,
                resource: relativePath,
                ordinal: ordinal
            )) {
                parentDescriptor = try WindowsFontLifecycleFileSystem
                    .openContainingDirectory(
                        for: relativePath,
                        below: driveC,
                        descriptor: driveCDescriptor
                    )
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    parentDescriptor,
                    label: "removed planned directory containing parent fsync"
                )
                try WindowsFontLifecycleFileSystem.closeDescriptor(
                    &parentDescriptor,
                    label: "removed planned directory containing parent close"
                )
            }
        }
    }

    private func cleanupCommittedApply(
        journal: WindowsFontLifecycleJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32,
        verifiedInspection: WindowsFontCompatibilityInspection? = nil
    ) throws -> WindowsFontCompatibilityInspection {
        let marker = try readAndValidateMarker(prefix: prefix)
        guard journal.committedOwnedFileIDs == journal.plannedOwnedFileIDs,
              journal.committedOwnedRegistryIDs == journal.plannedOwnedRegistryIDs,
              marker.ownedFileIDs == journal.committedOwnedFileIDs,
              marker.ownedRegistryIDs == journal.committedOwnedRegistryIDs else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "marker/journal committed ownership mismatch"
            )
        }
        let inspection = verifiedInspection ?? inspect(
            prefix: prefix,
            requiresProfileMarker: true
        )
        guard inspection.isSatisfied else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                inspection.missingItems.joined(separator: ", ")
            )
        }
        do {
            try synchronizeCommittedNamespaces(
                journal: journal,
                driveC: driveC,
                driveCDescriptor: driveCDescriptor
            )
        } catch let error as WindowsFontCompatibilityProfileError {
            if case .interruptedAfterOperation = error { throw error }
            throw WindowsFontCompatibilityProfileError
                .commitCleanupDurabilityUnknown(String(describing: error))
        } catch {
            throw WindowsFontCompatibilityProfileError
                .commitCleanupDurabilityUnknown(String(describing: error))
        }
        try cleanupBoundStages(
            journal: journal,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
        try removePlannedDirectories(
            journal.plannedCreatedDirectoryRelativePaths.filter {
                $0.hasPrefix(
                    lifecycleContract.namespace.scratchDirectoryRelativePath
                )
            },
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
        try verifyAdoptedAndOwnedState(
            journal: journal,
            prefix: prefix,
            ownedFilesMustBeAbsent: false,
            ownedRegistryMustBeAbsent: false
        )
        try deleteJournalAndSynchronizeParent(
            journal: journal,
            prefix: prefix,
            driveCDescriptor: driveCDescriptor
        )
        return inspection
    }

    private func deleteJournalAndSynchronizeParent(
        journal: WindowsFontLifecycleJournal,
        prefix: URL,
        driveCDescriptor: Int32
    ) throws {
        let path = journalURL(in: prefix)
        let current = try readAndValidateJournal(
            prefix: prefix,
            driveC: prefix.appending(path: "drive_c")
        )
        guard current == journal else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(path.path)
        }
        let journalData = try WindowsFontLifecycleJSON.encodeCanonical(current)
        let journalDigest = SHA256.hash(data: journalData)
            .map { String(format: "%02x", $0) }.joined()
        try performFilesystem(try operation(
            .journalDelete,
            resource: lifecycleContract.namespace.journalRelativePath,
            ordinal: 0
        )) {
            try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                relativePath:
                    lifecycleContract.namespace.driveCJournalRelativePath,
                below: prefix.appending(path: "drive_c"),
                descriptor: driveCDescriptor,
                expectedSHA256: journalDigest
            )
        }
        do {
            try performFilesystem(try operation(
                .journalDeletionParentDirectoryFSync,
                resource: "drive_c",
                ordinal: 0
            )) {
                try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                    driveCDescriptor,
                    label: "journal deletion parent fsync"
                )
            }
        } catch let error as WindowsFontCompatibilityProfileError {
            if case .interruptedAfterOperation = error { throw error }
            throw WindowsFontCompatibilityProfileError.cleanupDurabilityUnknown(
                String(describing: error)
            )
        } catch {
            throw WindowsFontCompatibilityProfileError.cleanupDurabilityUnknown(
                String(describing: error)
            )
        }
    }
}

@MainActor
final class WindowsFontLegacyV4RetirementEngine {
    nonisolated static let profileIdentifier =
        "forgeplay-windows-font-compatibility-v4-retirement-v1"

    private let fileManager: FileManager
    private let hooks: WindowsFontLifecycleExecutionHooks
    private let transactionIDProvider: () -> UUID

    init(
        fileManager: FileManager = .default,
        hooks: WindowsFontLifecycleExecutionHooks,
        transactionIDProvider: @escaping () -> UUID = UUID.init
    ) {
        self.fileManager = fileManager
        self.hooks = hooks
        self.transactionIDProvider = transactionIDProvider
    }

    func retireIfPresent(
        fontCodepages: String?,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws {
        let normalizedPrefix = prefix.standardizedFileURL
        let driveC = normalizedPrefix.appending(
            path: "drive_c",
            directoryHint: .isDirectory
        )
        try WindowsFontLifecycleFileSystem.requireDirectory(normalizedPrefix)
        try WindowsFontLifecycleFileSystem.requireDirectory(driveC)
        try WindowsFontLifecycleFileSystem.requireDirectory(
            driveC.appending(path: "windows", directoryHint: .isDirectory)
        )
        let driveCDescriptor = try WindowsFontLifecycleFileSystem.openDirectory(
            driveC
        )
        defer { Darwin.close(driveCDescriptor) }

        let journalPath = normalizedPrefix.appending(path: Self.journalRelativePath)
        let markerPath = normalizedPrefix.appending(path: Self.markerRelativePath)
        let hasJournal = try WindowsFontLifecycleFileSystem.lstatItem(journalPath) != nil
        let hasMarker = try WindowsFontLifecycleFileSystem.lstatItem(markerPath) != nil
        let updatePath = normalizedPrefix.appending(
            path: Self.journalUpdateRelativePath
        )
        if !hasJournal,
           try WindowsFontLifecycleFileSystem.lstatItem(updatePath) != nil {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "orphaned-legacy-v4-retirement-journal-update"
            )
        }
        guard hasJournal || hasMarker else { return }

        var inferredBaseline = fontCodepages.flatMap {
            WindowsFontFreshBaselineVariant.retirementBaseline(
                fontCodepages: $0
            )
        }
        if hasJournal {
            let journal = try readJournal(
                prefix: normalizedPrefix,
                driveC: driveC
            )
            _ = try journalUpdateDigestIfPresent(
                prefix: normalizedPrefix,
                peerOf: journal
            )
            switch journal.phase {
            case "retirement-prepared":
                try validatePreparedTransitionalState(
                    prefix: normalizedPrefix,
                    baselineVariant: journal.baselineVariant
                )
                try await restoreLegacyRegistryState(
                    runtimeExecutable: runtimeExecutable,
                    prefix: normalizedPrefix,
                    logDirectory: logDirectory,
                    baselineVariant: journal.baselineVariant
                )
                try authenticateExactLegacyV4State(prefix: normalizedPrefix)
                try deleteJournal(
                    journal,
                    prefix: normalizedPrefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor
                )
                if inferredBaseline == nil {
                    inferredBaseline = journal.baselineVariant
                }
            case "registry-committed":
                try validateCommittedTransitionalState(
                    prefix: normalizedPrefix,
                    baselineVariant: journal.baselineVariant
                )
                try completeCommittedRetirement(
                    journal: journal,
                    prefix: normalizedPrefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor
                )
                return
            default:
                throw WindowsFontCompatibilityProfileError
                    .malformedLifecycleEvidence
            }
        }

        guard let baselineVariant = inferredBaseline else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "legacy-v4-retirement-codepages-unavailable-or-malformed"
            )
        }
        try authenticateExactLegacyV4State(prefix: normalizedPrefix)
        let transactionID = transactionIDProvider().uuidString.lowercased()
        let prepared = WindowsFontLegacyV4RetirementJournal(
            schemaVersion: 1,
            profileIdentifier: Self.profileIdentifier,
            descriptorDigest: descriptorDigest(for: baselineVariant),
            transactionID: transactionID,
            baselineVariant: baselineVariant,
            phase: "retirement-prepared"
        )
        try validate(journal: prepared)
        try persistNewJournal(
            prepared,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )

        do {
            try await applyFreshRegistryBaseline(
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory,
                baselineVariant: baselineVariant
            )
            try verifyFreshRegistryBaseline(
                prefix: normalizedPrefix,
                baselineVariant: baselineVariant
            )
        } catch {
            let originalError = error
            do {
                try await restoreLegacyRegistryState(
                    runtimeExecutable: runtimeExecutable,
                    prefix: normalizedPrefix,
                    logDirectory: logDirectory,
                    baselineVariant: baselineVariant
                )
                try authenticateExactLegacyV4State(prefix: normalizedPrefix)
                try deleteJournal(
                    prepared,
                    prefix: normalizedPrefix,
                    driveC: driveC,
                    driveCDescriptor: driveCDescriptor
                )
            } catch {
                throw WindowsFontCompatibilityProfileError.rollbackIncomplete(
                    "legacy-v4-retirement: \(error)",
                    [Self.profileIdentifier]
                )
            }
            throw originalError
        }

        let committed = prepared.committingRegistryRetirement()
        try replaceJournal(
            prepared,
            with: committed,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
        try completeCommittedRetirement(
            journal: committed,
            prefix: normalizedPrefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
    }

    private static let driveCJournalRelativePath =
        ".\(profileIdentifier).transaction.json"
    private static let journalRelativePath =
        "drive_c/\(driveCJournalRelativePath)"
    private static let driveCJournalUpdateRelativePath =
        ".\(profileIdentifier).transaction-update.json"
    private static let journalUpdateRelativePath =
        "drive_c/\(driveCJournalUpdateRelativePath)"
    private static let driveCMarkerRelativePath =
        "ForgePlay/FontCompatibility/" +
            "forgeplay-windows-font-compatibility-v4.txt"
    private static let markerRelativePath =
        "drive_c/\(driveCMarkerRelativePath)"

    private var legacyPayloads: [WindowsFontPayloadDescriptor] {
        WindowsFontCompatibilityProfileContract.fontPayloads.filter {
            $0.sourceRole == .runtimeNanum
        }
    }

    private func freshRequirements(
        for variant: WindowsFontFreshBaselineVariant
    ) -> [WindowsFontRegistryRequirement] {
        let replacements: [WindowsFontRegistryReplacementDescriptor]
        switch variant {
        case .western:
            replacements = WindowsFontCompatibilityProfileContract
                .freshWineRegistryReplacements
        case .japanese:
            replacements = WindowsFontCompatibilityProfileContract
                .japaneseFreshWineRegistryReplacements
        case .simplifiedChinese:
            replacements = WindowsFontCompatibilityProfileContract
                .simplifiedChineseFreshWineRegistryReplacements
        case .traditionalChinese:
            replacements = WindowsFontCompatibilityProfileContract
                .traditionalChineseFreshWineRegistryReplacements
        case .korean:
            replacements = WindowsFontCompatibilityProfileContract
                .previousFreshWineRegistryReplacements
        case .unsupportedArabic:
            replacements = WindowsFontCompatibilityProfileContract
                .arabicFreshWineRegistryReplacements
        }
        return replacements.map(\.baseline) +
            WindowsFontCompatibilityProfileContract
                .freshWineAlreadyTargetRequirements
    }

    private func descriptorDigest(
        for baselineVariant: WindowsFontFreshBaselineVariant
    ) -> String {
        let markerDigest = SHA256.hash(
            data: WindowsFontCompatibilityProfileContract.legacyV4MarkerData
        ).map { String(format: "%02x", $0) }.joined()
        return WindowsFontCanonical.digest(
            domain: "ForgePlayWindowsFontLegacyV4RetirementDescriptorV1",
            fields: [
                Self.profileIdentifier,
                baselineVariant.rawValue,
                markerDigest
            ] + legacyPayloads.map(\.descriptorID).sorted() +
                WindowsFontCompatibilityProfileContract
                    .legacyV4RegistryRequirements.map(\.descriptorID).sorted() +
                freshRequirements(for: baselineVariant)
                    .map(\.descriptorID).sorted()
        )
    }

    private func validate(
        journal: WindowsFontLegacyV4RetirementJournal
    ) throws {
        guard journal.schemaVersion == 1,
              journal.profileIdentifier == Self.profileIdentifier,
              journal.descriptorDigest == descriptorDigest(
                  for: journal.baselineVariant
              ),
              UUID(uuidString: journal.transactionID)?.uuidString.lowercased() ==
                journal.transactionID,
              ["retirement-prepared", "registry-committed"].contains(
                  journal.phase
              ) else {
            throw WindowsFontCompatibilityProfileError
                .malformedLifecycleEvidence
        }
    }

    private func registryKey(
        _ requirement: WindowsFontRegistryRequirement
    ) -> String {
        "\(requirement.registryPath.lowercased())\u{0}" +
            requirement.valueName.lowercased()
    }

    private func loadRegistrySnapshots(
        prefix: URL
    ) throws -> (
        user: WindowsFontRegistrySnapshotState,
        system: WindowsFontRegistrySnapshotState
    ) {
        do {
            return (
                try WindowsFontRegistrySnapshotState.load(
                    url: prefix.appending(path: "user.reg"),
                    fileManager: fileManager
                ),
                try WindowsFontRegistrySnapshotState.load(
                    url: prefix.appending(path: "system.reg"),
                    fileManager: fileManager
                )
            )
        } catch let error as WindowsFontCompatibilityProfileError {
            throw error
        } catch {
            throw WindowsFontCompatibilityProfileError
                .registrySnapshotMalformed(prefix.appending(path: "user.reg"))
        }
    }

    private func snapshot(
        for requirement: WindowsFontRegistryRequirement,
        snapshots: (
            user: WindowsFontRegistrySnapshotState,
            system: WindowsFontRegistrySnapshotState
        )
    ) -> WindowsFontRegistrySnapshotState {
        requirement.registryPath.hasPrefix("HKCU\\")
            ? snapshots.user
            : snapshots.system
    }

    private func authenticateExactLegacyV4State(prefix: URL) throws {
        try WindowsFontLifecycleFileSystem.verifyRegularFile(
            at: prefix.appending(path: Self.markerRelativePath),
            expectedData:
                WindowsFontCompatibilityProfileContract.legacyV4MarkerData,
            exactMode: WindowsFontLifecycleFileSystem.regularFileMode
        )
        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        for payload in legacyPayloads {
            let path = fonts.appending(path: payload.fileName)
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: path,
                exactMode: WindowsFontLifecycleFileSystem.regularFileMode
            )
            guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                at: path
            ) == payload.sha256 else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "legacy-v4-payload-identity-mismatch: \(path.path)"
                )
            }
        }
        let snapshots = try loadRegistrySnapshots(prefix: prefix)
        guard WindowsFontCompatibilityProfileContract
            .legacyV4RegistryRequirements.allSatisfy({ requirement in
                snapshot(for: requirement, snapshots: snapshots)
                    .orderedValues(for: requirement) ==
                    requirement.orderedValues
            }) else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "legacy-v4-registry-identity-mismatch"
            )
        }
    }

    private func validatePreparedTransitionalState(
        prefix: URL,
        baselineVariant: WindowsFontFreshBaselineVariant
    ) throws {
        try WindowsFontLifecycleFileSystem.verifyRegularFile(
            at: prefix.appending(path: Self.markerRelativePath),
            expectedData:
                WindowsFontCompatibilityProfileContract.legacyV4MarkerData,
            exactMode: WindowsFontLifecycleFileSystem.regularFileMode
        )
        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        for payload in legacyPayloads {
            let path = fonts.appending(path: payload.fileName)
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: path,
                exactMode: WindowsFontLifecycleFileSystem.regularFileMode
            )
            guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                at: path
            ) == payload.sha256 else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "legacy-v4-prepared-payload-drift"
                )
            }
        }
        try validateRegistryTransitionState(
            prefix: prefix,
            baselineVariant: baselineVariant
        )
    }

    private func validateCommittedTransitionalState(
        prefix: URL,
        baselineVariant: WindowsFontFreshBaselineVariant
    ) throws {
        try verifyFreshRegistryBaseline(
            prefix: prefix,
            baselineVariant: baselineVariant
        )
        let fonts = prefix.appending(path: "drive_c/windows/Fonts")
        for payload in legacyPayloads {
            let path = fonts.appending(path: payload.fileName)
            if try WindowsFontLifecycleFileSystem.lstatItem(path) != nil {
                try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                    at: path,
                    exactMode: WindowsFontLifecycleFileSystem.regularFileMode
                )
                guard try WindowsFontLifecycleFileSystem.sha256OfRegularFile(
                    at: path
                ) == payload.sha256 else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-committed-payload-drift"
                    )
                }
            }
        }
        let marker = prefix.appending(path: Self.markerRelativePath)
        if try WindowsFontLifecycleFileSystem.lstatItem(marker) != nil {
            try WindowsFontLifecycleFileSystem.verifyRegularFile(
                at: marker,
                expectedData:
                    WindowsFontCompatibilityProfileContract.legacyV4MarkerData,
                exactMode: WindowsFontLifecycleFileSystem.regularFileMode
            )
        }
    }

    private func validateRegistryTransitionState(
        prefix: URL,
        baselineVariant: WindowsFontFreshBaselineVariant
    ) throws {
        let finalByKey = Dictionary(uniqueKeysWithValues:
            freshRequirements(for: baselineVariant).map {
                (registryKey($0), $0)
            }
        )
        let snapshots = try loadRegistrySnapshots(prefix: prefix)
        for legacy in WindowsFontCompatibilityProfileContract
            .legacyV4RegistryRequirements {
            let current = snapshot(for: legacy, snapshots: snapshots)
            let values = current.orderedValues(for: legacy)
            if values == legacy.orderedValues { continue }
            if let final = finalByKey[registryKey(legacy)] {
                guard values == final.orderedValues else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-retirement-registry-transition-drift"
                    )
                }
            } else if current.containsValue(for: legacy) {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "legacy-v4-retirement-registry-transition-drift"
                )
            }
        }
    }

    private func applyFreshRegistryBaseline(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        baselineVariant: WindowsFontFreshBaselineVariant
    ) async throws {
        let finalByKey = Dictionary(uniqueKeysWithValues:
            freshRequirements(for: baselineVariant).map {
                (registryKey($0), $0)
            }
        )
        var attemptedMutation = false
        for (ordinal, legacy) in WindowsFontCompatibilityProfileContract
            .legacyV4RegistryRequirements.sorted(by: {
                $0.descriptorID < $1.descriptorID
            }).enumerated() {
            let snapshots = try loadRegistrySnapshots(prefix: prefix)
            let current = snapshot(for: legacy, snapshots: snapshots)
            if let final = finalByKey[registryKey(legacy)] {
                if current.orderedValues(for: final) == final.orderedValues {
                    continue
                }
                guard current.orderedValues(for: legacy) ==
                    legacy.orderedValues else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-retirement-registry-forward-drift"
                    )
                }
                attemptedMutation = true
                try await performRunnerAction(
                    kind: .replacedRegistryRestore,
                    resource: legacy.descriptorID,
                    ordinal: ordinal,
                    action: .setRegistryValue(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        registryPath: final.registryPath,
                        valueName: final.valueName,
                        valueType: final.valueType,
                        value: final.encodedRunnerValue,
                        logDirectory: logDirectory
                    )
                )
            } else {
                guard current.containsValue(for: legacy) else { continue }
                guard current.orderedValues(for: legacy) ==
                    legacy.orderedValues else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-retirement-registry-delete-drift"
                    )
                }
                attemptedMutation = true
                try await performRunnerAction(
                    kind: .ownedRegistryDelete,
                    resource: legacy.descriptorID,
                    ordinal: ordinal,
                    action: .deleteRegistryValue(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        registryPath: legacy.registryPath,
                        valueName: legacy.valueName,
                        logDirectory: logDirectory
                    )
                )
            }
        }
        if attemptedMutation {
            try await performRunnerAction(
                kind: .forwardRegistryFlush,
                resource: "legacy-v4-retirement-forward-flush",
                ordinal: 0,
                action: .waitForWinePrefix(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
            )
        }
    }

    private func restoreLegacyRegistryState(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        baselineVariant: WindowsFontFreshBaselineVariant
    ) async throws {
        let finalByKey = Dictionary(uniqueKeysWithValues:
            freshRequirements(for: baselineVariant).map {
                (registryKey($0), $0)
            }
        )
        var attemptedMutation = false
        for (ordinal, legacy) in WindowsFontCompatibilityProfileContract
            .legacyV4RegistryRequirements.sorted(by: {
                $0.descriptorID < $1.descriptorID
            }).enumerated() {
            let snapshots = try loadRegistrySnapshots(prefix: prefix)
            let current = snapshot(for: legacy, snapshots: snapshots)
            if current.orderedValues(for: legacy) == legacy.orderedValues {
                continue
            }
            if let final = finalByKey[registryKey(legacy)] {
                guard current.orderedValues(for: final) == final.orderedValues else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-retirement-registry-rollback-drift"
                    )
                }
            } else {
                guard !current.containsValue(for: legacy) else {
                    throw WindowsFontCompatibilityProfileError.recoveryConflict(
                        "legacy-v4-retirement-registry-rollback-drift"
                    )
                }
            }
            attemptedMutation = true
            try await performRunnerAction(
                kind: .replacedRegistryRestore,
                resource: legacy.descriptorID,
                ordinal: ordinal,
                action: .setRegistryValue(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    registryPath: legacy.registryPath,
                    valueName: legacy.valueName,
                    valueType: legacy.valueType,
                    value: legacy.encodedRunnerValue,
                    logDirectory: logDirectory
                )
            )
        }
        if attemptedMutation {
            try await performRunnerAction(
                kind: .compensationRegistryFlush,
                resource: "legacy-v4-retirement-rollback-flush",
                ordinal: 0,
                action: .waitForWinePrefix(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
            )
        }
    }

    private func verifyFreshRegistryBaseline(
        prefix: URL,
        baselineVariant: WindowsFontFreshBaselineVariant
    ) throws {
        let finalByKey = Dictionary(uniqueKeysWithValues:
            freshRequirements(for: baselineVariant).map {
                (registryKey($0), $0)
            }
        )
        let snapshots = try loadRegistrySnapshots(prefix: prefix)
        for legacy in WindowsFontCompatibilityProfileContract
            .legacyV4RegistryRequirements {
            let current = snapshot(for: legacy, snapshots: snapshots)
            if let final = finalByKey[registryKey(legacy)] {
                guard current.orderedValues(for: final) ==
                    final.orderedValues else {
                    throw WindowsFontCompatibilityProfileError.verificationFailed([
                        final.label
                    ])
                }
            } else if current.containsValue(for: legacy) {
                throw WindowsFontCompatibilityProfileError.verificationFailed([
                    legacy.label
                ])
            }
        }
    }

    private func performRunnerAction(
        kind: WindowsFontLifecycleOperationKind,
        resource: String,
        ordinal: Int,
        action: RunnerAction
    ) async throws {
        let operation = try WindowsFontLifecycleOperationRegistry.instance(
            operationKind: kind,
            resourceIDOrPathID: resource,
            ordinal: ordinal
        )
        let result = try await hooks.runnerActionExecutor(operation, action)
        try hooks.completionObserver(operation)
        guard result.succeeded else {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(result)
        }
    }

    private func completeCommittedRetirement(
        journal: WindowsFontLegacyV4RetirementJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        try verifyFreshRegistryBaseline(
            prefix: prefix,
            baselineVariant: journal.baselineVariant
        )
        var deletedPayload = false
        for payload in legacyPayloads {
            let relativePath = "windows/Fonts/\(payload.fileName)"
            let path = driveC.appending(path: relativePath)
            guard try WindowsFontLifecycleFileSystem.lstatItem(path) != nil else {
                continue
            }
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: path,
                exactMode: WindowsFontLifecycleFileSystem.regularFileMode
            )
            try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                relativePath: relativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                expectedSHA256: payload.sha256
            )
            deletedPayload = true
        }
        if deletedPayload {
            var fontsDescriptor = try WindowsFontLifecycleFileSystem.openDirectory(
                relativePath: "windows/Fonts",
                below: driveC,
                descriptor: driveCDescriptor
            )
            defer { if fontsDescriptor >= 0 { Darwin.close(fontsDescriptor) } }
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                fontsDescriptor,
                label: "legacy v4 payload retirement parent fsync"
            )
            try WindowsFontLifecycleFileSystem.closeDescriptor(
                &fontsDescriptor,
                label: "legacy v4 payload retirement parent close"
            )
        }

        let marker = prefix.appending(path: Self.markerRelativePath)
        if try WindowsFontLifecycleFileSystem.lstatItem(marker) != nil {
            try WindowsFontLifecycleFileSystem.verifyRegularFile(
                at: marker,
                expectedData:
                    WindowsFontCompatibilityProfileContract.legacyV4MarkerData,
                exactMode: WindowsFontLifecycleFileSystem.regularFileMode
            )
            let markerDigest = SHA256.hash(
                data: WindowsFontCompatibilityProfileContract.legacyV4MarkerData
            ).map { String(format: "%02x", $0) }.joined()
            try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                relativePath: Self.driveCMarkerRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                expectedSHA256: markerDigest
            )
            var markerParent = try WindowsFontLifecycleFileSystem.openDirectory(
                relativePath: "ForgePlay/FontCompatibility",
                below: driveC,
                descriptor: driveCDescriptor
            )
            defer { if markerParent >= 0 { Darwin.close(markerParent) } }
            try WindowsFontLifecycleFileSystem.fsyncDescriptor(
                markerParent,
                label: "legacy v4 marker retirement parent fsync"
            )
            try WindowsFontLifecycleFileSystem.closeDescriptor(
                &markerParent,
                label: "legacy v4 marker retirement parent close"
            )
        }

        for payload in legacyPayloads {
            guard try WindowsFontLifecycleFileSystem.lstatItem(
                driveC.appending(path: "windows/Fonts/\(payload.fileName)")
            ) == nil else {
                throw WindowsFontCompatibilityProfileError.verificationFailed([
                    payload.fileName
                ])
            }
        }
        guard try WindowsFontLifecycleFileSystem.lstatItem(marker) == nil else {
            throw WindowsFontCompatibilityProfileError.verificationFailed([
                marker.path
            ])
        }
        try deleteJournal(
            journal,
            prefix: prefix,
            driveC: driveC,
            driveCDescriptor: driveCDescriptor
        )
    }

    private func persistNewJournal(
        _ journal: WindowsFontLegacyV4RetirementJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        let data = try WindowsFontLifecycleJSON.encodeCanonical(journal)
        var descriptor = try WindowsFontLifecycleFileSystem
            .openExclusiveRegularFile(
                relativePath: Self.driveCJournalRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                mode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        try WindowsFontLifecycleFileSystem.writeAll(data, to: descriptor)
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            descriptor,
            label: "legacy v4 retirement journal fsync"
        )
        try WindowsFontLifecycleFileSystem.closeDescriptor(
            &descriptor,
            label: "legacy v4 retirement journal close"
        )
        try WindowsFontLifecycleFileSystem.verifyRegularFile(
            at: prefix.appending(path: Self.journalRelativePath),
            expectedData: data,
            exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
        )
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            driveCDescriptor,
            label: "legacy v4 retirement journal parent fsync"
        )
    }

    private func replaceJournal(
        _ current: WindowsFontLegacyV4RetirementJournal,
        with next: WindowsFontLegacyV4RetirementJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        try validate(journal: next)
        let currentData = try WindowsFontLifecycleJSON.encodeCanonical(current)
        let nextData = try WindowsFontLifecycleJSON.encodeCanonical(next)
        let currentDigest = SHA256.hash(data: currentData)
            .map { String(format: "%02x", $0) }.joined()
        let nextDigest = SHA256.hash(data: nextData)
            .map { String(format: "%02x", $0) }.joined()
        var descriptor = try WindowsFontLifecycleFileSystem
            .openExclusiveRegularFile(
                relativePath: Self.driveCJournalUpdateRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                mode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        try WindowsFontLifecycleFileSystem.writeAll(nextData, to: descriptor)
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            descriptor,
            label: "legacy v4 retirement journal update fsync"
        )
        try WindowsFontLifecycleFileSystem.closeDescriptor(
            &descriptor,
            label: "legacy v4 retirement journal update close"
        )
        try WindowsFontLifecycleFileSystem.verifyRegularFile(
            at: prefix.appending(path: Self.journalUpdateRelativePath),
            expectedData: nextData,
            exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
        )
        try WindowsFontLifecycleFileSystem.exchangeRegularFiles(
            firstRelativePath: Self.driveCJournalUpdateRelativePath,
            firstExpectedSHA256: nextDigest,
            secondRelativePath: Self.driveCJournalRelativePath,
            secondExpectedSHA256: currentDigest,
            below: driveC,
            descriptor: driveCDescriptor
        )
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            driveCDescriptor,
            label: "legacy v4 retirement journal exchange parent fsync"
        )
        try WindowsFontLifecycleFileSystem.unlinkRegularFile(
            relativePath: Self.driveCJournalUpdateRelativePath,
            below: driveC,
            descriptor: driveCDescriptor,
            expectedSHA256: currentDigest
        )
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            driveCDescriptor,
            label: "legacy v4 retirement journal update deletion fsync"
        )
        let verified = try readJournal(prefix: prefix, driveC: driveC)
        guard verified == next else {
            throw WindowsFontCompatibilityProfileError
                .malformedLifecycleEvidence
        }
    }

    private func readJournal(
        prefix: URL,
        driveC: URL
    ) throws -> WindowsFontLegacyV4RetirementJournal {
        _ = driveC
        let path = prefix.appending(path: Self.journalRelativePath)
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: path,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            let data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: path,
                maximumByteCount:
                    WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
            let journal = try WindowsFontLifecycleJSON.decodeCanonical(
                WindowsFontLegacyV4RetirementJournal.self,
                data: data,
                exactKeys: WindowsFontLegacyV4RetirementJournal.exactKeys
            )
            try validate(journal: journal)
            return journal
        } catch let error as WindowsFontCompatibilityProfileError {
            throw error
        } catch {
            throw WindowsFontCompatibilityProfileError
                .malformedLifecycleEvidence
        }
    }

    private func journalUpdateDigestIfPresent(
        prefix: URL,
        peerOf journal: WindowsFontLegacyV4RetirementJournal
    ) throws -> String? {
        let updatePath = prefix.appending(path: Self.journalUpdateRelativePath)
        guard try WindowsFontLifecycleFileSystem.lstatItem(updatePath) != nil else {
            return nil
        }
        let expectedPeer: WindowsFontLegacyV4RetirementJournal
        switch journal.phase {
        case "retirement-prepared":
            expectedPeer = journal.committingRegistryRetirement()
        case "registry-committed":
            expectedPeer = journal.preparingRegistryRetirement()
        default:
            throw WindowsFontCompatibilityProfileError
                .malformedLifecycleEvidence
        }
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: updatePath,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            let data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: updatePath,
                maximumByteCount:
                    WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
            let update = try WindowsFontLifecycleJSON.decodeCanonical(
                WindowsFontLegacyV4RetirementJournal.self,
                data: data,
                exactKeys: WindowsFontLegacyV4RetirementJournal.exactKeys
            )
            try validate(journal: update)
            guard update == expectedPeer else {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "legacy-v4-retirement-journal-update-drift"
                )
            }
            return SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
        } catch let error as WindowsFontCompatibilityProfileError {
            throw error
        } catch {
            throw WindowsFontCompatibilityProfileError
                .malformedLifecycleEvidence
        }
    }

    private func deleteJournal(
        _ journal: WindowsFontLegacyV4RetirementJournal,
        prefix: URL,
        driveC: URL,
        driveCDescriptor: Int32
    ) throws {
        let current = try readJournal(prefix: prefix, driveC: driveC)
        guard current == journal else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "legacy-v4-retirement-journal-drift"
            )
        }
        if let updateDigest = try journalUpdateDigestIfPresent(
            prefix: prefix,
            peerOf: current
        ) {
            try WindowsFontLifecycleFileSystem.unlinkRegularFile(
                relativePath: Self.driveCJournalUpdateRelativePath,
                below: driveC,
                descriptor: driveCDescriptor,
                expectedSHA256: updateDigest
            )
        }
        let data = try WindowsFontLifecycleJSON.encodeCanonical(current)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        try WindowsFontLifecycleFileSystem.unlinkRegularFile(
            relativePath: Self.driveCJournalRelativePath,
            below: driveC,
            descriptor: driveCDescriptor,
            expectedSHA256: digest
        )
        try WindowsFontLifecycleFileSystem.fsyncDescriptor(
            driveCDescriptor,
            label: "legacy v4 retirement journal deletion parent fsync"
        )
    }
}

@MainActor
private final class WindowsFontCompatibilityProfileCoordinator {
    private enum LocaleResolution {
        case supported(WindowsFontLocaleVariant)
        case unsupported
        case unavailable
    }

    private struct RegistryLocaleSignals {
        let localeIdentifier: String?
        let fontCodepages: String?
    }

    private let runner: SafeProcessRunner
    private let fileManager: FileManager
    private static var activeMigrationPrefixPaths = Set<String>()

    init(runner: SafeProcessRunner, fileManager: FileManager) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func apply(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult? {
        _ = try await provisionForLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        return nil
    }

    func provisionForLaunch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        preferredLocaleIdentifier: String? = nil
    ) async throws -> WindowsFontProvisioningApplicationReceipt {
        let normalizedPrefix = prefix.standardizedFileURL
        try acquireMigrationGate(normalizedPrefix)
        defer { releaseMigrationGate(normalizedPrefix) }

        let registrySignals = registryLocaleSignals(prefix: normalizedPrefix)
        let preferredVariant = preferredLocaleIdentifier.flatMap {
            WindowsFontCompatibilityProfileV6Contract.supportedVariant(
                localeIdentifier: $0
            )
        }
        let localeResolution = preferredVariant.map(LocaleResolution.supported) ??
            resolvedLocale(
                identifier: registrySignals.localeIdentifier,
                fontCodepages: registrySignals.fontCodepages
            )
        try rejectOverlappingVersionEvidence(prefix: normalizedPrefix)
        let hasV5 = hasV5Evidence(prefix: normalizedPrefix)
        let activeV6Variant = try v6EvidenceVariant(prefix: normalizedPrefix)
        let hasLegacyV4 = hasLegacyV4Evidence(prefix: normalizedPrefix)
        let v5Engine = hasV5
            ? makeEngine(contract: .frozenV5())
            : nil
        let activeV6Engine = activeV6Variant.map {
            makeEngine(contract: .localeAwareV6(variant: $0))
        }

        // Existing version evidence owns its own authentication, recovery and
        // reconciliation. Do not duplicate that decision in a generic
        // preflight or disguise a valid managed v6 profile as external state.
        if let v5Engine {
            let receipt = try await provisionOrPassthrough(
                engine: v5Engine,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
            if receipt.state == .verifiedExternalFontPassthrough ||
                receipt.state == .verifiedCollisionPassthrough {
                return receipt
            }
            if case .unavailable = localeResolution, !hasLegacyV4 {
                return receipt
            }
            if let collision = try externalNotoCollisionReceipt(
                prefix: normalizedPrefix
            ) {
                return collision
            }
            if hasLegacyV4Marker(prefix: normalizedPrefix),
               registrySignals.fontCodepages.flatMap({
                   WindowsFontFreshBaselineVariant.retirementBaseline(
                       fontCodepages: $0
                   )
               }) == nil {
                throw WindowsFontCompatibilityProfileError.recoveryConflict(
                    "legacy-v4-retirement-codepages-unavailable-or-malformed"
                )
            }
            try await retire(
                engine: v5Engine,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
        }

        if hasLegacyV4 {
            try await makeLegacyV4RetirementEngine().retireIfPresent(
                fontCodepages: registrySignals.fontCodepages,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
        }

        var activeV6Receipt: WindowsFontProvisioningApplicationReceipt?
        if let activeV6Engine {
            let receipt = try await provisionOrPassthrough(
                engine: activeV6Engine,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
            if receipt.state == .verifiedExternalFontPassthrough ||
                receipt.state == .verifiedCollisionPassthrough {
                return receipt
            }
            if case .unavailable = localeResolution {
                return receipt
            }
            activeV6Receipt = receipt
        }

        let requestedVariant: WindowsFontLocaleVariant
        switch localeResolution {
        case .supported(let variant):
            requestedVariant = variant
        case .unsupported:
            requestedVariant = .western
        case .unavailable:
            return passthroughReceipt()
        }

        if activeV6Variant == requestedVariant, let activeV6Receipt {
            // The engine verified every required file and registry entry.
            // Additional host font catalog entries do not invalidate or own
            // this complete installed profile.
            return activeV6Receipt
        }

        if let collision = try externalNotoCollisionReceipt(
            prefix: normalizedPrefix
        ) {
            return collision
        }

        if let activeV6Engine {
            try await retire(
                engine: activeV6Engine,
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
        }

        let requestedEngine = makeEngine(
            contract: .localeAwareV6(variant: requestedVariant)
        )
        if let receipt = try externalPassthroughReceipt(
            engine: requestedEngine,
            prefix: normalizedPrefix
        ) {
            return receipt
        }
        return try await provisionOrPassthrough(
            engine: requestedEngine,
            runtimeExecutable: runtimeExecutable,
            prefix: normalizedPrefix,
            logDirectory: logDirectory
        )
    }

    func uninstall(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult? {
        let normalizedPrefix = prefix.standardizedFileURL
        try acquireMigrationGate(normalizedPrefix)
        defer { releaseMigrationGate(normalizedPrefix) }
        try rejectOverlappingVersionEvidence(prefix: normalizedPrefix)
        if let variant = try v6EvidenceVariant(prefix: normalizedPrefix) {
            return try await makeEngine(
                contract: .localeAwareV6(variant: variant)
            ).uninstall(
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
        }
        if hasV5Evidence(prefix: normalizedPrefix) {
            return try await makeEngine(contract: .frozenV5()).uninstall(
                runtimeExecutable: runtimeExecutable,
                prefix: normalizedPrefix,
                logDirectory: logDirectory
            )
        }
        return nil
    }

    private var v5Namespace: WindowsFontLifecycleNamespace {
        .init(
            profileIdentifier:
                WindowsFontCompatibilityProfileContract.profileIdentifier
        )
    }

    private var v6Namespace: WindowsFontLifecycleNamespace {
        .init(
            profileIdentifier:
                WindowsFontCompatibilityProfileV6Contract.profileIdentifier
        )
    }

    private func makeEngine(
        contract: WindowsFontLifecycleRuntimeContract
    ) -> WindowsFontCompatibilityProfile {
        WindowsFontCompatibilityProfile(
            fileManager: fileManager,
            lifecycleContract: contract,
            sourceRootResolver: { runtimeExecutable, fileManager in
                try WindowsFontCompatibilityProfileContract.resolvedSourceRoots(
                    runtimeExecutable: runtimeExecutable,
                    fileManager: fileManager
                )
            },
            hooks: .production(runner: runner)
        )
    }

    private func makeLegacyV4RetirementEngine() ->
        WindowsFontLegacyV4RetirementEngine {
        WindowsFontLegacyV4RetirementEngine(
            fileManager: fileManager,
            hooks: .production(runner: runner)
        )
    }

    private func retire(
        engine: WindowsFontCompatibilityProfile,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws {
        if let unsuccessful = try await engine.uninstall(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ) {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                unsuccessful
            )
        }
    }

    private func externalNotoCollisionReceipt(
        prefix: URL
    ) throws -> WindowsFontProvisioningApplicationReceipt? {
        let observations = try WindowsFontCompatibilityProfileContract
            .externalNotoOwnershipObservations(
                prefix: prefix,
                fileManager: fileManager
            )
        guard !observations.isEmpty else { return nil }
        // A different-build same-family font does not prove multilingual
        // coverage. Preserve it and any working old profile, and reserve the
        // English locale fallback for this genuine ownership conflict.
        return passthroughReceipt(
            state: .verifiedCollisionPassthrough,
            digestDomain: "ForgePlayWindowsFontCollisionPassthroughV1",
            observations: observations
        )
    }

    private func externalPassthroughReceipt(
        engine: WindowsFontCompatibilityProfile,
        prefix: URL
    ) throws -> WindowsFontProvisioningApplicationReceipt? {
        let observations = try engine.externalOwnershipObservations(
            prefix: prefix
        )
        guard !observations.isEmpty else { return nil }
        return passthroughReceipt(
            state: .verifiedCollisionPassthrough,
            digestDomain:
                "ForgePlayWindowsFontCollisionPassthroughV1",
            observations: observations
        )
    }

    private func provisionOrPassthrough(
        engine: WindowsFontCompatibilityProfile,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> WindowsFontProvisioningApplicationReceipt {
        do {
            return try await engine.provisionForLaunch(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        } catch WindowsFontCompatibilityProfileError.collision(let reason) {
            let lowercasedReason = reason.lowercased()
            guard engine.consumedOperations.isEmpty,
                  !lowercasedReason.contains("duplicate-or-type-mismatch"),
                  !lowercasedReason.contains("evidence-mismatch") else {
                throw WindowsFontCompatibilityProfileError.collision(reason)
            }
            return passthroughReceipt(
                state: .verifiedCollisionPassthrough,
                digestDomain:
                    "ForgePlayWindowsFontCollisionPassthroughV1",
                observations: [
                    WindowsFontCanonical.digest(
                        domain: "ForgePlayWindowsFontCollisionV1",
                        fields: [reason]
                    )
                ]
            )
        }
    }

    private func registryLocaleSignals(prefix: URL) -> RegistryLocaleSignals {
        do {
            let snapshot = try WindowsFontRegistrySnapshotState.load(
                url: prefix.appending(path: "user.reg"),
                fileManager: fileManager
            )
            return RegistryLocaleSignals(
                localeIdentifier: snapshot.stringValue(
                    registryPath: "HKCU\\Control Panel\\International",
                    valueName: "LocaleName"
                ),
                fontCodepages: snapshot.stringValue(
                    registryPath: "HKCU\\Software\\Wine\\Fonts",
                    valueName: "Codepages"
                )
            )
        } catch {
            return RegistryLocaleSignals(
                localeIdentifier: nil,
                fontCodepages: nil
            )
        }
    }

    private func resolvedLocale(
        identifier: String?,
        fontCodepages: String?
    ) -> LocaleResolution {
        if let identifier,
           !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let variant = WindowsFontCompatibilityProfileV6Contract
            .supportedVariant(localeIdentifier: identifier) {
            return .supported(variant)
        }
        guard let fontCodepages,
              let baseline = WindowsFontFreshBaselineVariant
                .retirementBaseline(fontCodepages: fontCodepages) else {
            return .unavailable
        }
        switch baseline {
        case .japanese: return .supported(.japanese)
        case .simplifiedChinese: return .supported(.simplifiedChinese)
        case .traditionalChinese: return .supported(.traditionalChinese)
        case .korean: return .supported(.korean)
        case .western, .unsupportedArabic: return .supported(.western)
        }
    }

    private func hasLegacyV4Marker(prefix: URL) -> Bool {
        evidenceExists(
            at: "drive_c/ForgePlay/FontCompatibility/" +
                "forgeplay-windows-font-compatibility-v4.txt",
            prefix: prefix
        )
    }

    private func hasLegacyV4Evidence(prefix: URL) -> Bool {
        hasLegacyV4Marker(prefix: prefix) || evidenceExists(
            at: "drive_c/." +
                WindowsFontLegacyV4RetirementEngine.profileIdentifier +
                ".transaction.json",
            prefix: prefix
        ) || evidenceExists(
            at: "drive_c/." +
                WindowsFontLegacyV4RetirementEngine.profileIdentifier +
                ".transaction-update.json",
            prefix: prefix
        )
    }

    private func legacyV4RetirementTransactionExists(prefix: URL) -> Bool {
        evidenceExists(
            at: "drive_c/." +
                WindowsFontLegacyV4RetirementEngine.profileIdentifier +
                ".transaction.json",
            prefix: prefix
        ) || evidenceExists(
            at: "drive_c/." +
                WindowsFontLegacyV4RetirementEngine.profileIdentifier +
                ".transaction-update.json",
            prefix: prefix
        )
    }

    private func passthroughReceipt(
        state: WindowsFontProvisioningApplicationReceipt.ProvisioningState =
            .verifiedUnsupportedLocalePassthrough,
        digestDomain: String =
            "ForgePlayWindowsFontUnsupportedLocalePassthroughV1",
        observations: [String] = []
    ) -> WindowsFontProvisioningApplicationReceipt {
        let digest = WindowsFontCanonical.digest(
            domain: digestDomain,
            fields: observations.sorted()
        )
        return WindowsFontProvisioningApplicationReceipt(
            profileIdentifier:
                WindowsFontCompatibilityProfileV6Contract.profileIdentifier,
            state: state,
            baselineDigest: digest,
            appliedDigest: digest,
            appliedItemCount: 0,
            missingItemCount: 0
        )
    }

    private func hasV5Evidence(prefix: URL) -> Bool {
        evidenceExists(at: v5Namespace.markerRelativePath, prefix: prefix) ||
            evidenceExists(at: v5Namespace.journalRelativePath, prefix: prefix)
    }

    private func rejectOverlappingVersionEvidence(prefix: URL) throws {
        let hasV5 = hasV5Evidence(prefix: prefix)
        let hasV6 =
            evidenceExists(at: v6Namespace.markerRelativePath, prefix: prefix) ||
            evidenceExists(at: v6Namespace.journalRelativePath, prefix: prefix)
        let hasV4Marker = hasLegacyV4Marker(prefix: prefix)
        let hasV4RetirementTransaction = legacyV4RetirementTransactionExists(
            prefix: prefix
        )
        guard !(hasV5 && hasV6),
              !(hasV6 && hasV4Marker),
              !(hasV4RetirementTransaction && (hasV5 || hasV6)) else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "overlapping-font-profile-version-evidence"
            )
        }
    }

    private func evidenceExists(at relativePath: String, prefix: URL) -> Bool {
        do {
            return try WindowsFontLifecycleFileSystem.lstatItem(
                prefix.appending(path: relativePath)
            ) != nil
        } catch {
            return true
        }
    }

    private func acquireMigrationGate(_ prefix: URL) throws {
        guard Self.activeMigrationPrefixPaths.insert(prefix.path).inserted else {
            throw WindowsFontCompatibilityProfileError.overlappingLifecycle(prefix)
        }
    }

    private func releaseMigrationGate(_ prefix: URL) {
        Self.activeMigrationPrefixPaths.remove(prefix.path)
    }

    private func v6EvidenceVariant(
        prefix: URL
    ) throws -> WindowsFontLocaleVariant? {
        let markerURL = prefix.appending(path: v6Namespace.markerRelativePath)
        let journalURL = prefix.appending(path: v6Namespace.journalRelativePath)
        var variants: [WindowsFontLocaleVariant] = []
        if try WindowsFontLifecycleFileSystem.lstatItem(markerURL) != nil {
            let marker: WindowsFontLifecycleMarker = try readCanonicalEvidence(
                WindowsFontLifecycleMarker.self,
                at: markerURL,
                exactKeys: WindowsFontLifecycleMarker.exactKeys
            )
            guard marker.profileIdentifier == v6Namespace.profileIdentifier,
                  let variant = WindowsFontCompatibilityProfileV6Contract.variant(
                    forDescriptorDigest: marker.descriptorDigest
                  ) else {
                throw WindowsFontCompatibilityProfileError
                    .malformedLifecycleEvidence
            }
            variants.append(variant)
        }
        if try WindowsFontLifecycleFileSystem.lstatItem(journalURL) != nil {
            let journal: WindowsFontLifecycleJournal = try readCanonicalEvidence(
                WindowsFontLifecycleJournal.self,
                at: journalURL,
                exactKeys: WindowsFontLifecycleJournal.exactKeys
            )
            guard journal.profileIdentifier == v6Namespace.profileIdentifier,
                  let variant = WindowsFontCompatibilityProfileV6Contract.variant(
                    forDescriptorDigest: journal.descriptorDigest
                  ) else {
                throw WindowsFontCompatibilityProfileError
                    .malformedLifecycleEvidence
            }
            variants.append(variant)
        }
        guard Set(variants).count <= 1 else {
            throw WindowsFontCompatibilityProfileError.recoveryConflict(
                "v6-font-profile-variant-evidence-mismatch"
            )
        }
        return variants.first
    }

    private func readCanonicalEvidence<T: Codable & Equatable>(
        _ type: T.Type,
        at url: URL,
        exactKeys: Set<String>
    ) throws -> T {
        do {
            try WindowsFontLifecycleFileSystem.requireRegularFileMetadata(
                at: url,
                exactMode: WindowsFontLifecycleFileSystem.evidenceFileMode
            )
            let data = try WindowsFontLifecycleFileSystem.readRegularFile(
                at: url,
                maximumByteCount:
                    WindowsFontLifecycleJSON.maximumEvidenceByteCount
            )
            return try WindowsFontLifecycleJSON.decodeCanonical(
                type,
                data: data,
                exactKeys: exactKeys
            )
        } catch let error as WindowsFontCompatibilityProfileError {
            throw error
        } catch {
            throw WindowsFontCompatibilityProfileError
                .malformedLifecycleEvidence
        }
    }
}

private final class WindowsFontCompatibilityBundleToken: NSObject {}
