// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import Foundation
import Observation

enum SteamPrefixLifecycleOperation: String, Hashable, Sendable {
    case managedStorageTransition
    case referenceRefresh
    case supplementalRendererImport
    case prepare
    case rebuild
    case install
    case applyCompatibilityProfile
    case maintenance
    case launch
}

enum SteamPrefixLifecycleError: LocalizedError, Equatable {
    case operationInProgress
    case applicationTerminating

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "다른 Steam 프리픽스 작업이 이미 진행 중입니다. 완료된 뒤 다시 시도하세요."
        case .applicationTerminating:
            "ForgePlay가 종료 중이어서 새 Steam 프리픽스 작업을 시작할 수 없습니다."
        }
    }
}

@MainActor
@Observable
final class SteamPrefixLifecycleCoordinator {
    private(set) var activeOperation: SteamPrefixLifecycleOperation?
    private(set) var isTerminating = false

    @ObservationIgnored private var activeOperationToken: UUID?
    @ObservationIgnored private var managedPrefixPaths: Set<String> = []

    var isBusy: Bool {
        activeOperation != nil
    }

    var activeManagedPrefixURLs: [URL] {
        managedPrefixPaths
            .sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func begin(_ operation: SteamPrefixLifecycleOperation) throws -> UUID {
        try checkpoint()
        guard activeOperation == nil else {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        let token = UUID()
        activeOperation = operation
        activeOperationToken = token
        return token
    }

    func end(_ token: UUID) {
        guard activeOperationToken == token else { return }
        activeOperation = nil
        activeOperationToken = nil
    }

    func registerManagedPrefix(_ prefix: URL) throws {
        try checkpoint()
        managedPrefixPaths.insert(prefix.standardizedFileURL.path)
    }

    func unregisterManagedPrefix(_ prefix: URL) {
        managedPrefixPaths.remove(prefix.standardizedFileURL.path)
    }

    func checkpoint() throws {
        guard !isTerminating else {
            throw SteamPrefixLifecycleError.applicationTerminating
        }
    }

    @discardableResult
    func beginApplicationTermination() -> Bool {
        guard activeOperation == nil else { return false }
        isTerminating = true
        return true
    }

    func cancelApplicationTermination() {
        isTerminating = false
    }
}

struct SteamPrefixRendererPolicyResolution: Hashable {
    var capability: WindowsRuntimeCapability
    var rendererPolicy: SteamRendererPolicyPreference
}

struct SteamPrefixSynchronizationPolicyResolution: Hashable {
    var requestedSelection: WineSynchronizationSelection
    var supportedBackends: Set<WineSynchronizationBackend>
    var resolvedBackend: WineSynchronizationBackend
    var previouslyAppliedBackend: WineSynchronizationBackend
    var didChangeAppliedBackend: Bool
}

private struct SteamPrefixSynchronizationPolicyTarget {
    var requestedSelection: WineSynchronizationSelection
    var capabilities: WineSynchronizationRuntimeCapabilities
    var policy: WineSynchronizationPolicy
}

@MainActor
final class SteamPrefixService {
    private let windowsRuntimeService: WindowsRuntimeService
    private let prefixManager: PrefixManager
    private let steamManager: SteamManager
    private let steamClientCompatibilityVerifier: SteamClientCompatibilityVerifier
    private let lifecycleCoordinator: SteamPrefixLifecycleCoordinator
    private var runtimeOwnershipLeasesByLockPath: [String: ManagedRootOperationLease] = [:]

    init(
        windowsRuntimeService: WindowsRuntimeService,
        prefixManager: PrefixManager,
        steamManager: SteamManager,
        steamClientCompatibilityVerifier: SteamClientCompatibilityVerifier = SteamClientCompatibilityVerifier(),
        lifecycleCoordinator: SteamPrefixLifecycleCoordinator? = nil
    ) {
        self.windowsRuntimeService = windowsRuntimeService
        self.prefixManager = prefixManager
        self.steamManager = steamManager
        self.steamClientCompatibilityVerifier = steamClientCompatibilityVerifier
        self.lifecycleCoordinator = lifecycleCoordinator ?? SteamPrefixLifecycleCoordinator()
    }

    func inspectSteamClientCompatibility(_ runtimeExecutable: URL) throws -> SteamClientCompatibilityVerification {
        let capability = try windowsRuntimeService.inspectRuntimeCapability(executable: runtimeExecutable)
        return steamClientCompatibilityVerifier.verify(capability: capability)
    }

    func verifyRunnerForWindowsSteam(_ runtimeExecutable: URL) throws -> SteamClientCompatibilityVerification {
        let verification = try inspectSteamClientCompatibility(runtimeExecutable)
        guard verification.canLaunchWindowsSteam else {
            throw WindowsRuntimeServiceError.missingSteamRendererCapability(verification.capability)
        }
        return verification
    }

    func validateRunnerForWindowsSteam(_ runtimeExecutable: URL) throws -> WindowsRuntimeCapability {
        try verifyRunnerForWindowsSteam(runtimeExecutable).capability
    }

    func validateSteamInstaller(_ installer: URL) -> Bool {
        steamManager.validateSteamInstaller(installer)
    }

    func installSteam(
        runtimeExecutable: URL,
        installer: URL,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> SteamInstallResult {
        try await withExclusiveOperation(.install) {
            try steamManager.requireSteamInstaller(installer)
            _ = try validateRunnerForWindowsSteam(runtimeExecutable)
            let prefix = try prefixManager.steamSharedPrefixURL()
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                runtimeExecutable: runtimeExecutable
            )
            _ = try await applySynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                selection: synchronizationSelection
            )
            try await steamManager.shutdownSteamPrefixBeforePolicyMutation(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix
            )
            _ = try prefixManager.rotateSteamSharedEnvironmentGeneration()
            var result = try await steamManager.installSteam(
                runtimeExecutable: runtimeExecutable,
                installer: installer
            )
            if !result.processResult.succeeded {
                do {
                    try await steamManager.shutdownSteamPrefixBeforePolicyMutation(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix
                    )
                } catch {
                    throw SteamPrefixLifecycleCleanupError(
                        originalDescription: "Steam installer exited with \(result.processResult.processExitCode.map(String.init) ?? "no process exit status")",
                        cleanupDescription: forgePlayTechnicalErrorSummary(error),
                        cleanupError: error,
                        originalProcessResult: result.processResult,
                        cleanupProcessResults: diagnosticProcessRunResults(from: error)
                    )
                }
            }
            if result.processResult.succeeded, result.hasSteamExecutable {
                do {
                    try await steamManager.prepareInstalledSteamForFirstLaunch(
                        runtimeExecutable: runtimeExecutable,
                        videoMemorySizeMB: videoMemorySelection.resolvedSizeMB()
                    )
                } catch {
                    result.compatibilityPreparationWarning = forgePlayTechnicalErrorSummary(error)
                }
            }
            return result
        }
    }

    func resolveRendererPolicy(
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection
    ) throws -> SteamPrefixRendererPolicyResolution {
        let verification = try verifyRunnerForWindowsSteam(runtimeExecutable)
        let capability = verification.capability
        guard let rendererPolicy = selection.resolvedLaunchPreference(capability: capability) else {
            throw SteamLaunchError.rendererPolicyUnavailable(
                "게임 렌더러 payload를 결정하지 못했습니다. WineD3D/OpenGL fallback으로 준비 완료처럼 처리하지 않습니다."
            )
        }
        return SteamPrefixRendererPolicyResolution(
            capability: capability,
            rendererPolicy: rendererPolicy
        )
    }

    func prepareSharedPrefix(
        runtimeExecutable: URL,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> PrefixPreparationResult {
        try await withExclusiveOperation(.prepare) {
            _ = try validateRunnerForWindowsSteam(runtimeExecutable)
            let synchronizationTarget = try resolveSynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                selection: synchronizationSelection
            )
            let prefix = try prefixManager.steamSharedPrefixURL()
            try await transitionExistingPrefixSynchronizationPolicyIfNeeded(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                target: synchronizationTarget
            )
            var result = try await prefixManager.prepareSteamSharedPrefix(
                runtimeExecutable: runtimeExecutable,
                synchronizationPolicy: synchronizationTarget.policy
            )
            result.metadata = try prefixManager.loadMetadata(at: prefix)
            return result
        }
    }

    func rebuildSharedPrefix(
        runtimeExecutable: URL,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> PrefixRebuildResult {
        try await withExclusiveOperation(.rebuild) {
            _ = try validateRunnerForWindowsSteam(runtimeExecutable)
            let synchronizationTarget = try resolveSynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                selection: synchronizationSelection
            )
            let prefix = try prefixManager.steamSharedPrefixURL()
            try await transitionExistingPrefixSynchronizationPolicyIfNeeded(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                target: synchronizationTarget
            )
            var result = try await prefixManager.rebuildSteamSharedPrefix(
                runtimeExecutable: runtimeExecutable,
                synchronizationPolicy: synchronizationTarget.policy
            )
            result.metadata = try prefixManager.loadMetadata(at: prefix)
            return result
        }
    }

    func applyRendererPolicy(
        prefix: URL,
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> SteamRendererPolicyInspection {
        try await withExclusiveOperation(.applyCompatibilityProfile) {
            try prefixManager.validateUsablePrefix(at: prefix)
            _ = try resolveRendererPolicy(
                runtimeExecutable: runtimeExecutable,
                selection: selection
            )
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                runtimeExecutable: runtimeExecutable
            )
            _ = try await applySynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                selection: synchronizationSelection
            )
            let videoMemorySizeMB = videoMemorySelection.resolvedSizeMB()
            try await steamManager.shutdownSteamPrefixBeforePolicyMutation(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix
            )
            try await steamManager.applySteamClientCompatibilityProfile(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                videoMemorySizeMB: videoMemorySizeMB
            )
            try steamManager.restoreSteamRendererBridgeModules(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )
            return steamManager.inspectSteamRendererPolicy(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                selection: selection,
                videoMemorySizeMB: videoMemorySizeMB
            )
        }
    }

    func launchSteam(
        runtimeExecutable: URL,
        rendererPolicySelection: SteamRendererPolicySelection,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = []
    ) async throws -> ProcessRunResult {
        let launch = try await launchSteam(
            runtimeExecutable: runtimeExecutable,
            rendererPolicySelection: rendererPolicySelection,
            gameModePolicy: gameModePolicy,
            videoMemorySelection: videoMemorySelection,
            synchronizationSelection: synchronizationSelection,
            libraryRoots: libraryRoots,
            reservedLibraryRoots: reservedLibraryRoots,
            prepareLaunch: { () }
        )
        return launch.processResult
    }

    func launchSteam<LaunchContext>(
        runtimeExecutable: URL,
        rendererPolicySelection: SteamRendererPolicySelection,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = [],
        prepareLaunch: () throws -> LaunchContext
    ) async throws -> (processResult: ProcessRunResult, context: LaunchContext) {
        try await withCoordinatedPrefixOperation(.launch) { prefixExecutionLease in
            let resolution = try resolveRendererPolicy(
                runtimeExecutable: runtimeExecutable,
                selection: rendererPolicySelection
            )
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                runtimeExecutable: runtimeExecutable
            )
            let prefix = try prefixManager.steamSharedPrefixURL()
            _ = try await applySynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                selection: synchronizationSelection
            )
            let context = try prepareLaunch()
            let processResult = try await steamManager.launchSteam(
                runtimeExecutable: runtimeExecutable,
                verificationMode: .operational,
                rendererPolicy: resolution.rendererPolicy,
                gameModePolicy: gameModePolicy,
                videoMemorySizeMB: videoMemorySelection.resolvedSizeMB(),
                libraryRoots: libraryRoots,
                reservedLibraryRoots: reservedLibraryRoots,
                prefixExecutionLeaseTransition: SteamPrefixExecutionLeaseTransition(
                    prepareForMutation: {
                        try prefixExecutionLease.transitionToExclusiveMutation()
                    },
                    prepareForExecution: {
                        try prefixExecutionLease.transitionToSharedExecution()
                    }
                )
            )
            return (processResult, context)
        }
    }

    func synchronizationRuntimeCapabilities(
        runtimeExecutable: URL
    ) -> WineSynchronizationRuntimeCapabilities {
        SafeProcessRunner.wineSynchronizationRuntimeCapabilities(for: runtimeExecutable)
    }

    nonisolated static func resolveSynchronizationBackend(
        selection: WineSynchronizationSelection,
        capabilities: WineSynchronizationRuntimeCapabilities
    ) throws -> WineSynchronizationBackend {
        _ = selection
        _ = capabilities
        return .server
    }

    private func applySynchronizationPolicy(
        runtimeExecutable: URL,
        prefix: URL,
        selection: WineSynchronizationSelection
    ) async throws -> SteamPrefixSynchronizationPolicyResolution {
        let target = try resolveSynchronizationPolicy(
            runtimeExecutable: runtimeExecutable,
            selection: selection
        )
        return try await applySynchronizationPolicy(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            target: target
        )
    }

    private func resolveSynchronizationPolicy(
        runtimeExecutable: URL,
        selection: WineSynchronizationSelection
    ) throws -> SteamPrefixSynchronizationPolicyTarget {
        let capabilities = synchronizationRuntimeCapabilities(runtimeExecutable: runtimeExecutable)
        let resolvedBackend = try Self.resolveSynchronizationBackend(
            selection: selection,
            capabilities: capabilities
        )

        let policy = WineSynchronizationPolicy(selection: .automatic, backend: resolvedBackend)
        return SteamPrefixSynchronizationPolicyTarget(
            requestedSelection: selection,
            capabilities: capabilities,
            policy: policy
        )
    }

    private func applySynchronizationPolicy(
        runtimeExecutable: URL,
        prefix: URL,
        target: SteamPrefixSynchronizationPolicyTarget
    ) async throws -> SteamPrefixSynchronizationPolicyResolution {
        let resolvedBackend = target.policy.backend
        let previouslyAppliedBackend = try prefixManager.appliedSynchronizationBackend(at: prefix)
        if previouslyAppliedBackend != resolvedBackend {
            try await steamManager.shutdownSteamPrefixBeforePolicyMutation(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix
            )
        }
        let didChangeAppliedBackend = try prefixManager.setAppliedSynchronizationPolicy(
            selection: target.policy.selection,
            backend: resolvedBackend,
            at: prefix
        )
        return SteamPrefixSynchronizationPolicyResolution(
            requestedSelection: target.policy.selection,
            supportedBackends: target.capabilities.supportedBackends,
            resolvedBackend: resolvedBackend,
            previouslyAppliedBackend: previouslyAppliedBackend,
            didChangeAppliedBackend: didChangeAppliedBackend
        )
    }

    private func transitionExistingPrefixSynchronizationPolicyIfNeeded(
        runtimeExecutable: URL,
        prefix: URL,
        target: SteamPrefixSynchronizationPolicyTarget
    ) async throws {
        if try prefixManager.steamSharedPrefixMetadataExists() {
            _ = try await applySynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                target: target
            )
            return
        }

        guard try prefixManager.steamSharedPrefixHasExistingContent() else { return }

        // Legacy managed roots without prefix.json predate the direct runtime
        // synchronization contract. Establish the standard server policy first.
        _ = try prefixManager.createSteamSharedPrefix(synchronizationPolicy: .automaticServer)
        _ = try await applySynchronizationPolicy(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            target: target
        )
    }

    func performMaintenance<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        try await withExclusiveOperation(.maintenance, perform: body)
    }

    func cleanupInterruptedReplacementArtifacts(at prefixURL: URL) throws {
        let token = try lifecycleCoordinator.begin(.maintenance)
        defer { lifecycleCoordinator.end(token) }

        let managedRootLeases: [ManagedRootOperationLease]
        do {
            managedRootLeases = try prefixManager.acquireManagedRootOperationLease()
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        defer { managedRootLeases.reversed().forEach { $0.release() } }

        do {
            try claimRuntimeOwnership(forManagedRoot: prefixManager.currentManagedRootURL())
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        let prefixExecutionLease = try acquireExclusivePrefixLeaseIfPresent(prefixURL)
        defer { prefixExecutionLease?.release() }
        try prefixManager.cleanupInterruptedReplacementArtifactsAssumingExclusiveAccess(
            at: prefixURL
        )
    }

    func claimRuntimeOwnership(forManagedRoot root: URL) throws {
        let lockURL = try ManagedRootOperationLease.coordinatedRuntimeOwnershipLockURL(
            forManagedRoot: root
        )
        guard runtimeOwnershipLeasesByLockPath[lockURL.path] == nil else { return }
        runtimeOwnershipLeasesByLockPath[lockURL.path] = try ManagedRootOperationLease
            .acquireRuntimeOwnership(forManagedRoot: root)
    }

    func releaseRuntimeOwnership(forManagedRoot root: URL) {
        guard let lockURL = try? ManagedRootOperationLease.coordinatedRuntimeOwnershipLockURL(
            forManagedRoot: root
        ), let lease = runtimeOwnershipLeasesByLockPath.removeValue(forKey: lockURL.path) else {
            return
        }
        lease.release()
    }

    func hasRuntimeOwnership(forManagedRoot root: URL) -> Bool {
        guard let lockURL = try? ManagedRootOperationLease.coordinatedRuntimeOwnershipLockURL(
            forManagedRoot: root
        ) else {
            return false
        }
        return runtimeOwnershipLeasesByLockPath[lockURL.path] != nil
    }

    var runtimeOwnershipCountForTesting: Int {
        runtimeOwnershipLeasesByLockPath.count
    }

    private func withExclusiveOperation<T>(
        _ operation: SteamPrefixLifecycleOperation,
        perform body: () async throws -> T
    ) async throws -> T {
        try await withOperationOwnership(operation) {
            let prefix = try prefixManager.steamSharedPrefixURL()
            // Initial creation cannot have a live game process. The
            // managed-root lease still serializes creation/replacement.
            let prefixExecutionLease = try acquireExclusivePrefixLeaseIfPresent(prefix)
            defer { prefixExecutionLease?.release() }
            return try await body()
        }
    }

    private func withCoordinatedPrefixOperation<T>(
        _ operation: SteamPrefixLifecycleOperation,
        perform body: (PrefixExecutionLease) async throws -> T
    ) async throws -> T {
        try await withOperationOwnership(operation) {
            let prefix = try prefixManager.steamSharedPrefixURL()
            let prefixExecutionLease = try PrefixExecutionLease.acquireExclusiveMutation(
                forPrefix: prefix
            )
            defer { prefixExecutionLease.release() }
            return try await body(prefixExecutionLease)
        }
    }

    private func withOperationOwnership<T>(
        _ operation: SteamPrefixLifecycleOperation,
        perform body: () async throws -> T
    ) async throws -> T {
        let token = try lifecycleCoordinator.begin(operation)
        defer { lifecycleCoordinator.end(token) }
        let managedRootLeases: [ManagedRootOperationLease]
        do {
            managedRootLeases = try prefixManager.acquireManagedRootOperationLease()
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        defer { managedRootLeases.reversed().forEach { $0.release() } }
        do {
            try claimRuntimeOwnership(forManagedRoot: prefixManager.currentManagedRootURL())
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        return try await body()
    }

    private func acquireExclusivePrefixLeaseIfPresent(
        _ prefix: URL
    ) throws -> PrefixExecutionLease? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: prefix.path,
            isDirectory: &isDirectory
        ) else {
            return nil
        }
        guard isDirectory.boolValue,
              FileSystemItemPolicy.isNonSymlinkDirectory(prefix) else {
            throw PrefixExecutionLeaseError.lockFailed(
                prefix,
                "prefix is not a non-symlink directory"
            )
        }
        return try PrefixExecutionLease.acquireExclusiveMutation(forPrefix: prefix)
    }
}
