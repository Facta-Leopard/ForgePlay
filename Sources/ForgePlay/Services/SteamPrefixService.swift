// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import CryptoKit
import Darwin
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
    case launchWindowsUtility
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
    @ObservationIgnored private(set) var operationGeneration: UInt64 = 0
    @ObservationIgnored private var activeOperationCancellationRequester:
        (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var managedPrefixPaths: Set<String> = []
    @ObservationIgnored private var applicationTerminationIdleWaiters:
        [UUID: CheckedContinuation<Bool, Never>] = [:]

    var isBusy: Bool {
        activeOperation != nil
    }

    var activeManagedPrefixURLs: [URL] {
        managedPrefixPaths
            .sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func begin(
        _ operation: SteamPrefixLifecycleOperation,
        permittingApplicationTerminationCleanup: Bool = false
    ) throws -> UUID {
        if isTerminating && !permittingApplicationTerminationCleanup {
            throw SteamPrefixLifecycleError.applicationTerminating
        }
        guard activeOperation == nil else {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        operationGeneration &+= 1
        let token = UUID()
        activeOperation = operation
        activeOperationToken = token
        return token
    }

    func end(_ token: UUID) {
        guard activeOperationToken == token else { return }
        activeOperation = nil
        activeOperationToken = nil
        activeOperationCancellationRequester = nil
        if isTerminating {
            let waiters = applicationTerminationIdleWaiters
            applicationTerminationIdleWaiters.removeAll(keepingCapacity: false)
            waiters.values.forEach { $0.resume(returning: true) }
        }
    }

    func setCancellationRequester(
        _ requester: @escaping @MainActor @Sendable () -> Void,
        for token: UUID
    ) {
        guard activeOperationToken == token else { return }
        activeOperationCancellationRequester = requester
    }

    func requestCancellationOfActiveOperation() {
        activeOperationCancellationRequester?()
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

    /// Closes admission immediately while the currently owned operation is
    /// cancelled and drained. Termination-only restoration may subsequently
    /// enter through the explicit privileged begin path.
    func reserveApplicationTermination() {
        isTerminating = true
    }

    @discardableResult
    func beginApplicationTerminationAndWaitForIdle(
        timeout: TimeInterval = 10,
        cancellationRequester:
            @escaping @MainActor @Sendable () -> Void = {}
    ) async -> Bool {
        isTerminating = true
        guard activeOperation != nil else { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            if activeOperation == nil {
                continuation.resume(returning: true)
            } else {
                applicationTerminationIdleWaiters[waiterID] = continuation
                let deadline = Date().addingTimeInterval(max(timeout, 0))
                Task { @MainActor [weak self] in
                    while let self,
                          self.applicationTerminationIdleWaiters[waiterID] != nil,
                          self.activeOperation != nil,
                          Date() < deadline {
                        cancellationRequester()
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard let self,
                          let waiter = self.applicationTerminationIdleWaiters
                            .removeValue(forKey: waiterID) else {
                        return
                    }
                    waiter.resume(returning: self.activeOperation == nil)
                }
            }
        }
    }

    var canCancelApplicationTermination: Bool {
        activeOperation == nil && applicationTerminationIdleWaiters.isEmpty
    }

    func cancelApplicationTermination() {
        guard canCancelApplicationTermination else { return }
        isTerminating = false
    }
}

struct SteamPrefixRendererPolicyResolution: Hashable {
    var capability: WindowsRuntimeCapability
    var rendererPolicy: SteamRendererPolicyPreference
}

struct SteamPrefixSynchronizationPolicyResolution: Hashable, Sendable {
    var requestedSelection: WineSynchronizationSelection
    var supportedBackends: Set<WineSynchronizationBackend>
    var resolvedBackend: WineSynchronizationBackend
    var previouslyAppliedBackend: WineSynchronizationBackend
    var didChangeAppliedBackend: Bool
}

struct SteamCompatibilityCoordinatedLaunchResult: Sendable {
    let processResult: ProcessRunResult
    let prefixBinding: SteamCompatibilityPrefixBinding
    let capturedBaselineDigest: String
    let persistentPrefixSnapshot: SteamCompatibilityPersistentPrefixSnapshot
    let appliedStateDigest: String
    let providerReadbackDigest: String
    let componentMutationEvidence:
        [CompatibilityRuntimeComponentMutationEvidenceV1]
    let synchronizationResolution: SteamPrefixSynchronizationPolicyResolution
    let sessionPrefixLease: SteamCompatibilityPrefixSessionLease
}

/// Converts optional evidence collection performed after an operational Steam
/// dispatch into an advisory result. Once the runner has returned an accepted
/// session, a readback failure must not escape into the launch transaction's
/// rollback path and terminate that live session.
enum SteamCompatibilityPostDispatchAdvisoryReadback {
    struct Result<Value> {
        let value: Value
        let diagnosticWarning: String?
    }

    static func capture<Value>(
        componentID: String,
        fallback: Value,
        _ read: () throws -> Value
    ) -> Result<Value> {
        do {
            return Result(value: try read(), diagnosticWarning: nil)
        } catch {
            return Result(
                value: fallback,
                diagnosticWarning:
                    "Post-dispatch \(componentID) advisory readback was " +
                    "unavailable; the accepted Steam session remains active " +
                    "and deterministic fallback evidence was recorded: " +
                    forgePlayTechnicalErrorSummary(error)
            )
        }
    }
}

/// Keeps a MainActor-owned operation result inside a Sendable task result
/// without requiring every legacy prefix result model to expose concurrency
/// conformance solely for lifecycle cancellation plumbing.
private final class SteamPrefixOperationResultBox<Value>: @unchecked Sendable {
    let result: Result<Value, Error>

    init(_ result: Result<Value, Error>) {
        self.result = result
    }
}

struct SteamCompatibilityPrefixBinding: Hashable, Sendable {
    let canonicalPrefixURL: URL
    let device: UInt64
    let inode: UInt64

    init(capturing prefix: URL) throws {
        let canonical = prefix.standardizedFileURL.resolvingSymlinksInPath()
        var status = stat()
        guard lstat(canonical.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "compatibility-prefix-binding-capture"
            )
        }
        canonicalPrefixURL = canonical
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }

    init(canonicalPrefixURL: URL, device: UInt64, inode: UInt64) {
        self.canonicalPrefixURL = canonicalPrefixURL.standardizedFileURL
        self.device = device
        self.inode = inode
    }

    func validateCurrentPrefix(_ candidate: URL) throws -> URL {
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == canonicalPrefixURL.path else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "compatibility-prefix-path-binding-mismatch"
            )
        }
        var status = stat()
        guard lstat(canonical.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              UInt64(status.st_dev) == device,
              UInt64(status.st_ino) == inode else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "compatibility-prefix-object-binding-mismatch"
            )
        }
        return canonical
    }
}

enum SteamCompatibilityFailedCleanupCompletionReason: Equatable, Sendable {
    case automaticRecovery
    case applicationTermination
}

final class SteamCompatibilityBackgroundWorkCompletionState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.withLock { completed }
    }

    func markCompleted() {
        lock.withLock { completed = true }
    }
}

@MainActor
protocol SteamCompatibilityBackgroundWorkOwner: AnyObject {
    /// Cancels every automatic retry and in-flight completion operation owned by
    /// this retained session, returning observer-free completion states for work
    /// that may currently be crossing an async process boundary.
    func cancelCompatibilityBackgroundWork()
        -> [SteamCompatibilityBackgroundWorkCompletionState]
}

struct SteamCompatibilityFailedCleanupCompletionProof: Hashable, Sendable {
    let cleanupReceiptID: String
    let prefixBinding: SteamCompatibilityPrefixBinding
    let capturedBaselineDigest: String
    let restoredBaselineDigest: String
}

@MainActor
protocol SteamCompatibilityFailedCleanupOwner:
    SteamCompatibilityBackgroundWorkOwner
{
    var cleanupReceiptID: String { get }
    var prefixBinding: SteamCompatibilityPrefixBinding { get }
    var capturedBaselineDigest: String { get }

    func completeFailedPostLaunchCleanup(
        using service: SteamPrefixService,
        reason: SteamCompatibilityFailedCleanupCompletionReason
    ) async throws -> SteamCompatibilityFailedCleanupCompletionProof
}

@MainActor
final class SteamCompatibilityPrefixSessionLease: @unchecked Sendable {
    private var lease: PrefixExecutionLease?

    init(adopting lease: PrefixExecutionLease) {
        self.lease = lease
    }

    func transitionToExclusiveMutation() throws {
        guard let lease else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "released-prefix-session-lease"
            )
        }
        try lease.transitionToExclusiveMutation()
    }

    func transitionToSharedExecution() throws {
        guard let lease else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "released-prefix-session-lease"
            )
        }
        try lease.transitionToSharedExecution()
    }

    func release() {
        guard let retained = lease else { return }
        lease = nil
        retained.release()
    }

    deinit { lease?.release() }
}

private struct SteamPrefixSynchronizationPolicyTarget {
    var requestedSelection: WineSynchronizationSelection
    var capabilities: WineSynchronizationRuntimeCapabilities
    var policy: WineSynchronizationPolicy
}

private struct SteamPrefixRendererCapabilityTransaction {
    var snapshot: WindowsRuntimeCapabilitySnapshot
    var resolution: SteamPrefixRendererPolicyResolution
}

@MainActor
final class SteamPrefixService {
    private let windowsRuntimeService: WindowsRuntimeService
    private let prefixManager: PrefixManager
    private let steamManager: SteamManager
    private let steamClientCompatibilityVerifier: SteamClientCompatibilityVerifier
    private let lifecycleCoordinator: SteamPrefixLifecycleCoordinator
    private var runtimeOwnershipLeasesByLockPath: [String: ManagedRootOperationLease] = [:]
    /// Type-erased provider session owners retain security scopes and stable
    /// game-root descriptors independently of transient SwiftUI view lifetime.
    private var compatibilitySessionLifetimeOwners:
        [String: any SteamCompatibilityBackgroundWorkOwner] = [:]
    /// A preparation can fail after Steam was dispatched and then also fail its
    /// immediate rollback. These owners keep the exact prefix snapshot, lease,
    /// and security scopes reachable from AppServices so application
    /// termination cannot silently discard them.
    private var failedCompatibilityCleanupOwners:
        [String: any SteamCompatibilityFailedCleanupOwner] = [:]
    private var compatibilitySessionRestorationFailures: [String: String] = [:]

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

    private func validatedRunnerSnapshotForWindowsSteam(
        _ runtimeExecutable: URL
    ) async throws -> WindowsRuntimeCapabilitySnapshot {
        let snapshot = try await windowsRuntimeService
            .runtimeCapabilitySnapshot(executable: runtimeExecutable)
        let verification = steamClientCompatibilityVerifier.verify(
            capability: snapshot.capability
        )
        guard verification.canLaunchWindowsSteam else {
            throw WindowsRuntimeServiceError.missingSteamRendererCapability(
                snapshot.capability
            )
        }
        return snapshot
    }

    private func revalidatedRunnerSnapshotForWindowsSteam(
        _ snapshot: WindowsRuntimeCapabilitySnapshot,
        runtimeExecutable: URL
    ) async throws -> WindowsRuntimeCapabilitySnapshot {
        let revalidated = try await windowsRuntimeService
            .revalidatedRuntimeCapabilitySnapshot(
                snapshot,
                executable: runtimeExecutable
            )
        let verification = steamClientCompatibilityVerifier.verify(
            capability: revalidated.capability
        )
        guard verification.canLaunchWindowsSteam else {
            throw WindowsRuntimeServiceError.missingSteamRendererCapability(
                revalidated.capability
            )
        }
        return revalidated
    }

    func validateSteamInstaller(_ installer: URL) -> Bool {
        steamManager.validateSteamInstaller(installer)
    }

    func installSteam(
        runtimeExecutable: URL,
        installer: URL,
        language: SteamClientLanguage,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> SteamInstallResult {
        try await withCoordinatedPrefixOperation(.install) { [self] _ in
            try steamManager.requireSteamInstaller(installer)
            let runtimeSnapshot = try await
                validatedRunnerSnapshotForWindowsSteam(runtimeExecutable)
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
            let steamClientLogRetentionMessage = await steamManager
                .rotateOfflineSteamClientLogsIfNeeded(prefix: prefix)
            _ = try await
                revalidatedRunnerSnapshotForWindowsSteam(
                    runtimeSnapshot,
                    runtimeExecutable: runtimeExecutable
                )
            // Runtime identity is the admission authority for this mutation.
            // Do not rotate the existing prefix generation until that authority
            // has been revalidated and installer dispatch is about to begin.
            _ = try prefixManager.rotateSteamSharedEnvironmentGeneration()
            var result = try await steamManager.installSteam(
                runtimeExecutable: runtimeExecutable,
                installer: installer,
                language: language
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
                    result.hasVerifiedSteamClientService = try await steamManager
                        .prepareInstalledSteamForFirstLaunch(
                            runtimeExecutable: runtimeExecutable,
                            language: result.didClaimSteamLanguageOwnership
                                ? language
                                : nil,
                            videoMemorySizeMB: videoMemorySelection.resolvedSizeMB()
                        )
                    if result.didClaimSteamLanguageOwnership {
                        result.hasVerifiedSteamLanguageProjection = true
                    }
                } catch {
                    let preparationError = error
                    let manager = steamManager
                    let cleanup = await Task.detached {
                        await manager.shutdownSteamPrefixAfterFailure(
                            runtimeExecutable: runtimeExecutable,
                            prefix: prefix
                        )
                    }.value
                    let cleanupFailure = Self.prefixCleanupFailure(
                        cleanup,
                        missingReason:
                            "first-launch preparation cleanup returned no result"
                    )
                    if let cleanupFailure {
                        throw SteamPrefixLifecycleCleanupError(
                            originalDescription:
                                forgePlayTechnicalErrorSummary(preparationError),
                            cleanupDescription:
                                forgePlayTechnicalErrorSummary(cleanupFailure),
                            originalError: preparationError,
                            cleanupError: cleanupFailure,
                            cleanupProcessResults:
                                cleanup.result.map { [$0] } ?? []
                        )
                    }
                    // The install itself is complete and the prefix is proven
                    // inactive. Preserve the established retry-on-first-launch
                    // contract for compatibility readiness only.
                    result.hasVerifiedSteamClientService =
                        SteamClientServiceContract.inspect(prefix: prefix).isReady
                    result.hasVerifiedSteamLanguageProjection =
                        result.didClaimSteamLanguageOwnership &&
                        ((try? steamManager
                            .hasVerifiedSteamClientLanguageProjection(
                                runtimeExecutable: runtimeExecutable,
                                language: language
                            )) == true)
                    result.compatibilityPreparationWarning =
                        forgePlayTechnicalErrorSummary(preparationError)
                }
            }
            result.compatibilityPreparationWarning = DiagnosticWarningText.combined(
                result.compatibilityPreparationWarning,
                steamClientLogRetentionMessage
            )
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

    private func resolveRendererPolicyTransaction(
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection
    ) async throws -> SteamPrefixRendererCapabilityTransaction {
        let snapshot = try await validatedRunnerSnapshotForWindowsSteam(
            runtimeExecutable
        )
        return SteamPrefixRendererCapabilityTransaction(
            snapshot: snapshot,
            resolution: try rendererPolicyResolution(
                capability: snapshot.capability,
                selection: selection
            )
        )
    }

    private func revalidatedRendererPolicyTransaction(
        _ transaction: SteamPrefixRendererCapabilityTransaction,
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection
    ) async throws -> SteamPrefixRendererCapabilityTransaction {
        let snapshot = try await revalidatedRunnerSnapshotForWindowsSteam(
            transaction.snapshot,
            runtimeExecutable: runtimeExecutable
        )
        return SteamPrefixRendererCapabilityTransaction(
            snapshot: snapshot,
            resolution: try rendererPolicyResolution(
                capability: snapshot.capability,
                selection: selection
            )
        )
    }

    private func rendererPolicyResolution(
        capability: WindowsRuntimeCapability,
        selection: SteamRendererPolicySelection
    ) throws -> SteamPrefixRendererPolicyResolution {
        guard let rendererPolicy = selection.resolvedLaunchPreference(
            capability: capability
        ) else {
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
        try await withExclusiveOperation(.prepare) { [self] in
            let runtimeSnapshot = try await
                validatedRunnerSnapshotForWindowsSteam(runtimeExecutable)
            let synchronizationTarget = try resolveSynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                selection: synchronizationSelection
            )
            let prefix = try prefixManager.steamSharedPrefixURL()
            // A missing prefix has no valid Game Mode consumer and remains
            // protected by the cross-process managed-root operation lease. Bind
            // the path-scoped execution lease whenever the role already exists.
            let prefixExecutionLease = try
                acquireExclusivePrefixLeaseIfPresent(prefix)
            defer { prefixExecutionLease?.release() }
            try await transitionExistingPrefixSynchronizationPolicyIfNeeded(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                target: synchronizationTarget
            )
            _ = try await
                revalidatedRunnerSnapshotForWindowsSteam(
                    runtimeSnapshot,
                    runtimeExecutable: runtimeExecutable
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
        try await withExclusiveOperation(.rebuild) { [self] in
            let runtimeSnapshot = try await
                validatedRunnerSnapshotForWindowsSteam(runtimeExecutable)
            let synchronizationTarget = try resolveSynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                selection: synchronizationSelection
            )
            let prefix = try prefixManager.steamSharedPrefixURL()
            let prefixExecutionLease = try
                acquireExclusivePrefixLeaseIfPresent(prefix)
            defer { prefixExecutionLease?.release() }
            try await transitionExistingPrefixSynchronizationPolicyIfNeeded(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                target: synchronizationTarget
            )
            _ = try await
                revalidatedRunnerSnapshotForWindowsSteam(
                    runtimeSnapshot,
                    runtimeExecutable: runtimeExecutable
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
        try await withCoordinatedPrefixOperation(
            .applyCompatibilityProfile,
            prefix: prefix
        ) { [self] _ in
            try prefixManager.validateUsablePrefix(at: prefix)
            var rendererTransaction = try await
                resolveRendererPolicyTransaction(
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
            rendererTransaction = try await
                revalidatedRendererPolicyTransaction(
                    rendererTransaction,
                    runtimeExecutable: runtimeExecutable,
                    selection: selection
                )
            try await steamManager.applySteamClientCompatibilityProfile(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                videoMemorySizeMB: videoMemorySizeMB
            )
            try await steamManager.restoreSteamRendererBridgeModules(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )
            _ = try await steamManager.reconcileWindowsFontCompatibilityProfile(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix
            )
            return steamManager.inspectSteamRendererPolicy(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: rendererTransaction.resolution.capability,
                selection: selection,
                videoMemorySizeMB: videoMemorySizeMB
            )
        }
    }

    func launchSteam(
        runtimeExecutable: URL,
        steamClientLanguage: SteamClientLanguage,
        rendererPolicySelection: SteamRendererPolicySelection,
        frameGenerationConfiguration: FrameGenerationConfiguration = .off,
        networkSelection: SteamNetworkCompatibilitySelection,
        audioInputSelection: SteamAudioInputSelection,
        fpsCursorPolicy: FPSCursorCapturePolicy = .off,
        controllerPolicy: ControllerCompatibilityPolicy = .automatic,
        keyboardMapping: KeyboardMappingPreference = .systemDefault,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = []
    ) async throws -> ProcessRunResult {
        let launch = try await launchSteam(
            runtimeExecutable: runtimeExecutable,
            steamClientLanguage: steamClientLanguage,
            rendererPolicySelection: rendererPolicySelection,
            frameGenerationConfiguration: frameGenerationConfiguration,
            networkSelection: networkSelection,
            audioInputSelection: audioInputSelection,
            fpsCursorPolicy: fpsCursorPolicy,
            controllerPolicy: controllerPolicy,
            keyboardMapping: keyboardMapping,
            gameModePolicy: gameModePolicy,
            videoMemorySelection: videoMemorySelection,
            synchronizationSelection: synchronizationSelection,
            libraryRoots: libraryRoots,
            reservedLibraryRoots: reservedLibraryRoots,
            prepareLaunch: { () }
        )
        return launch.processResult
    }

    func launchWindowsUtility(
        runtimeExecutable: URL,
        executable: URL,
        arguments: [String] = [],
        externalStorageRoots: [URL] = []
    ) async throws -> ProcessRunResult {
        try await withCoordinatedPrefixOperation(
            .launchWindowsUtility
        ) { [self] prefixExecutionLease in
            let prefix = try prefixManager.steamSharedPrefixURL()
            try prefixManager.validateUsablePrefix(at: prefix)
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                runtimeExecutable: runtimeExecutable
            )
            try prefixExecutionLease.transitionToSharedExecution()
            return try await steamManager.launchWindowsUtility(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                executable: executable,
                arguments: arguments,
                externalStorageRoots: externalStorageRoots
            )
        }
    }

    func launchSteam<LaunchContext>(
        runtimeExecutable: URL,
        steamClientLanguage: SteamClientLanguage,
        rendererPolicySelection: SteamRendererPolicySelection,
        frameGenerationConfiguration: FrameGenerationConfiguration = .off,
        networkSelection: SteamNetworkCompatibilitySelection,
        audioInputSelection: SteamAudioInputSelection,
        fpsCursorPolicy: FPSCursorCapturePolicy = .off,
        controllerPolicy: ControllerCompatibilityPolicy = .automatic,
        keyboardMapping: KeyboardMappingPreference = .systemDefault,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = [],
        prepareLaunch: @escaping @MainActor @Sendable () throws -> LaunchContext
    ) async throws -> (processResult: ProcessRunResult, context: LaunchContext) {
        return try await withCoordinatedPrefixLaunchOperation(.launch) { [self]
            prefixExecutionLease,
            restorationLease in
            var launchWarnings: [String] = []
            var effectiveFrameGenerationConfiguration =
                frameGenerationConfiguration
            do {
                try effectiveFrameGenerationConfiguration.validate(
                    isSupportedRenderer:
                        rendererPolicySelection
                            .supportsD3DMetalFrameGeneration
                )
            } catch {
                effectiveFrameGenerationConfiguration = .off
                launchWarnings.append(
                    "Invalid Frame Generation settings were disabled for " +
                        "this launch: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
            let effectiveFPSCursorPolicy: FPSCursorCapturePolicy
            if fpsCursorPolicy == .off {
                effectiveFPSCursorPolicy = .off
            } else {
                effectiveFPSCursorPolicy = .off
                launchWarnings.append(
                    "Unsupported legacy cursor capture was disabled for this launch."
                )
            }
            let effectiveControllerPolicy: ControllerCompatibilityPolicy
            if controllerPolicy == .automatic {
                effectiveControllerPolicy = .automatic
            } else {
                effectiveControllerPolicy = .automatic
                launchWarnings.append(
                    "Unsupported legacy controller policy was replaced with " +
                        "automatic Wine IOHID passthrough for this launch."
                )
            }
            let effectiveKeyboardMapping: KeyboardMappingPreference
            if keyboardMapping.preset == .systemDefault,
               keyboardMapping.customPermutation == nil {
                effectiveKeyboardMapping = keyboardMapping
            } else {
                effectiveKeyboardMapping = .systemDefault
                launchWarnings.append(
                    "Unsupported legacy keyboard mapping was replaced with " +
                        "the system default for this launch."
                )
            }
            var rendererTransaction: SteamPrefixRendererCapabilityTransaction?
            do {
                rendererTransaction = try await resolveRendererPolicyTransaction(
                    runtimeExecutable: runtimeExecutable,
                    selection: rendererPolicySelection
                )
            } catch {
                launchWarnings.append(
                    "Runtime/renderer capability inspection did not complete; " +
                        "launch continued with the selected renderer request: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
            let compatibilitySelection = SteamPrelaunchCompatibilitySelection(
                rendererSelection: rendererPolicySelection,
                frameGenerationConfiguration:
                    effectiveFrameGenerationConfiguration,
                networkSelection: networkSelection,
                audioInputSelection: audioInputSelection,
                fpsCursorPolicy: effectiveFPSCursorPolicy,
                controllerPolicy: effectiveControllerPolicy,
                keyboardMapping: effectiveKeyboardMapping
            )
            do {
                try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                    runtimeExecutable: runtimeExecutable
                )
            } catch {
                launchWarnings.append(
                    "Steam prefix runtime compatibility could not be confirmed; " +
                    "launch continued with the existing prefix: " +
                    forgePlayTechnicalErrorSummary(error)
                )
            }
            let prefix = try prefixManager.steamSharedPrefixURL()
            do {
                _ = try await applySynchronizationPolicy(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    selection: synchronizationSelection
                )
            } catch {
                launchWarnings.append(
                    "Wine synchronization policy could not be applied; launch " +
                    "continued with the prefix's existing setting: " +
                    forgePlayTechnicalErrorSummary(error)
                )
            }
            if let initialRendererTransaction = rendererTransaction {
                do {
                    rendererTransaction = try await
                        revalidatedRendererPolicyTransaction(
                        initialRendererTransaction,
                        runtimeExecutable: runtimeExecutable,
                        selection: rendererPolicySelection
                    )
                } catch {
                    launchWarnings.append(
                        "Renderer revalidation did not complete; launch " +
                            "continued with the initial renderer transaction: " +
                            forgePlayTechnicalErrorSummary(error)
                    )
                    rendererTransaction = initialRendererTransaction
                }
            }
            let context = try prepareLaunch()
            var processResult = try await steamManager.launchSteam(
                runtimeExecutable: runtimeExecutable,
                verificationMode: .operational,
                steamClientLanguage: steamClientLanguage,
                rendererPolicy:
                    rendererTransaction?.resolution.rendererPolicy ??
                    rendererPolicySelection.forcedPreference,
                runtimeCapability:
                    rendererTransaction?.resolution.capability,
                compatibilitySelection: compatibilitySelection,
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
                    },
                    restorationLease: restorationLease
                )
            )
            if !launchWarnings.isEmpty {
                processResult.diagnosticCaptureWarning =
                    DiagnosticWarningText.combined(
                        processResult.diagnosticCaptureWarning,
                        launchWarnings.joined(separator: " | ")
                    )
            }
            return (processResult, context)
        }
    }

    func launchCompatibilitySteamTransaction(
        runtimeExecutable: URL,
        request: ResolvedCompatibilityLaunchRequestV1,
        managedWineChildPolicy: SteamManagedWineChildCompatibilityPolicy,
        steamClientLanguage: SteamClientLanguage,
        steamArguments: [String]? = nil,
        libraryRoots: [URL],
        reservedLibraryRoots: [URL] = []
    ) async throws -> SteamCompatibilityCoordinatedLaunchResult {
        try request.validate()
        let projection = try SteamManagerCompatibilityLaunchRequestMapperV1
            .projection(for: request)
        guard managedWineChildPolicy.steamAppID == request.identity.steamAppID,
              managedWineChildPolicy.manifestRootAuthorizationDigest ==
                request.manifestRootAuthorization.authorizationDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "managed-child-policy-request-binding"
            )
        }

        return try await withOperationOwnership(.launch) { [self] in
            var launchWarnings: [String] = []
            let prefix = try prefixManager.steamSharedPrefixURL()
            let prefixExecutionLease = try PrefixExecutionLease
                .acquireExclusiveMutation(forPrefix: prefix)
            var leaseTransferred = false
            defer {
                if !leaseTransferred { prefixExecutionLease.release() }
            }
            // Bind only after exclusive ownership has been acquired. Capturing
            // before the lease would permit a path replacement in between and
            // could launch against a different inode than the retained owner is
            // later allowed to restore.
            let prefixBinding = try SteamCompatibilityPrefixBinding(
                capturing: prefix
            )
            // The provider remains the sole release owner because it must keep
            // this same prefix lease through persistent-baseline restoration.
            // SteamManager receives only delegated mutation authority so its
            // transient input/controller/NVIDIA session can still fail closed
            // and restore after the managed prefix becomes inactive.
            let providerRestorationLease =
                SteamCompatibilityRestorationPrefixLease(
                    prepareForMutation: {
                        try prefixExecutionLease
                            .transitionToExclusiveMutation()
                    },
                    release: {}
                )
            var rendererTransaction: SteamPrefixRendererCapabilityTransaction
            do {
                rendererTransaction = try await
                    resolveRendererPolicyTransaction(
                        runtimeExecutable: runtimeExecutable,
                        selection: projection.rendererSelection
                    )
            } catch {
                let snapshot = try await windowsRuntimeService
                    .runtimeCapabilitySnapshot(executable: runtimeExecutable)
                rendererTransaction = SteamPrefixRendererCapabilityTransaction(
                    snapshot: snapshot,
                    resolution: SteamPrefixRendererPolicyResolution(
                        capability: snapshot.capability,
                        rendererPolicy:
                            projection.rendererSelection.forcedPreference ??
                            .d3dMetal
                    )
                )
                launchWarnings.append(
                    "Renderer capability admission was unavailable; launch " +
                        "continued so the runner can select plain D3DMetal or " +
                        "base Wine: " + forgePlayTechnicalErrorSummary(error)
                )
            }
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                runtimeExecutable: runtimeExecutable
            )
            // Exclusive ownership proves no prior process can still hold the
            // prefix. Reconcile any termination-monitor lag before capturing
            // the new session's baseline so active-session flags cannot make
            // the baseline impossible to restore.
            do {
                _ = try await steamManager.completeCompatibilitySessionIfInactive(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    selection: projection.rendererSelection,
                    videoMemorySizeMB: projection.videoMemorySizeMB
                )
            } catch {
                launchWarnings.append(
                    "Prior compatibility-session restoration was unavailable; " +
                        "launch continued with renderer fail-open ownership: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
            do {
                rendererTransaction = try await
                    revalidatedRendererPolicyTransaction(
                        rendererTransaction,
                        runtimeExecutable: runtimeExecutable,
                        selection: projection.rendererSelection
                    )
            } catch {
                launchWarnings.append(
                    "Renderer capability revalidation was unavailable; the " +
                        "captured transaction was retained for fail-open " +
                        "dispatch: " + forgePlayTechnicalErrorSummary(error)
                )
            }
            // Persistent prefix preparation belongs to the captured baseline;
            // only transient input/controller/provider session state is
            // restored at explicit completion.
            do {
                try await steamManager.applySteamClientCompatibilityProfile(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    videoMemorySizeMB: projection.videoMemorySizeMB
                )
            } catch {
                launchWarnings.append(
                    "Steam compatibility profile preparation was unavailable; " +
                        "operational launch continued with the prefix's current " +
                        "registry: " + forgePlayTechnicalErrorSummary(error)
                )
            }
            do {
                _ = try await steamManager.reconcileWindowsFontCompatibilityProfile(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    steamClientLanguage: steamClientLanguage
                )
            } catch {
                launchWarnings.append(
                    "Windows font compatibility preparation was unavailable; " +
                        "operational launch continued and SteamManager will " +
                        "apply its scoped locale fallback when required: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
            do {
                try await steamManager.restoreSteamRendererBridgeModules(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable
                )
            } catch {
                launchWarnings.append(
                    "Renderer session restoration was unavailable; launch " +
                        "continued and the effective renderer will fall back " +
                        "to plain D3DMetal or base Wine: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
            let persistentPrefixSnapshot = try steamManager
                .captureCompatibilityPersistentPrefixSnapshot(prefix: prefix)
            let rendererBeforeInspection = steamManager.inspectSteamRendererPolicy(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: rendererTransaction.resolution.capability,
                selection: projection.rendererSelection,
                videoMemorySizeMB: projection.videoMemorySizeMB
            )
            let baselineDigest = try steamManager.compatibilityLaunchBaselineDigest(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: rendererTransaction.resolution.capability,
                selection: projection.rendererSelection,
                videoMemorySizeMB: projection.videoMemorySizeMB,
                persistentStateDigest: persistentPrefixSnapshot.digest
            )
            do {
            try prefixExecutionLease.transitionToExclusiveMutation()
            let synchronizationResolution = try await applySynchronizationPolicy(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                selection: .automatic
            )
            guard synchronizationResolution.requestedSelection == .automatic,
                  synchronizationResolution.resolvedBackend == .server else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "synchronization-policy-application"
                )
            }
            do {
                let finalRendererTransaction = try await
                    revalidatedRendererPolicyTransaction(
                        rendererTransaction,
                        runtimeExecutable: runtimeExecutable,
                        selection: projection.rendererSelection
                    )
                if finalRendererTransaction.snapshot.generation ==
                    rendererTransaction.snapshot.generation {
                    rendererTransaction = finalRendererTransaction
                } else {
                    launchWarnings.append(
                        "Renderer capability generation changed before " +
                            "dispatch; the runner will resolve the effective " +
                            "plain D3DMetal or base Wine path."
                    )
                }
            } catch {
                launchWarnings.append(
                    "Final renderer capability revalidation was unavailable; " +
                        "dispatch continued with runtime fail-open selection: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
            let compatibilitySelection = SteamPrelaunchCompatibilitySelection(
                rendererSelection: projection.rendererSelection,
                frameGenerationConfiguration: projection.frameGenerationConfiguration,
                networkSelection: projection.networkSelection,
                audioInputSelection: projection.audioInputSelection,
                fpsCursorPolicy: projection.fpsCursorPolicy,
                controllerPolicy: projection.controllerPolicy,
                keyboardMapping: projection.keyboardMapping,
                managedWineChildPolicy: managedWineChildPolicy
            )
            var result = try await steamManager.launchSteam(
                runtimeExecutable: runtimeExecutable,
                verificationMode: .operational,
                steamClientLanguage: steamClientLanguage,
                rendererPolicy:
                    rendererTransaction.resolution.rendererPolicy,
                runtimeCapability:
                    rendererTransaction.resolution.capability,
                compatibilitySelection: compatibilitySelection,
                gameModePolicy: projection.gameModePolicy,
                videoMemorySizeMB: projection.videoMemorySizeMB,
                steamArguments: steamArguments,
                libraryRoots: libraryRoots,
                reservedLibraryRoots: reservedLibraryRoots,
                prefixExecutionLeaseTransition:
                    SteamPrefixExecutionLeaseTransition(
                        prepareForMutation: {
                            try prefixExecutionLease
                                .transitionToExclusiveMutation()
                        },
                        prepareForExecution: {
                            try prefixExecutionLease
                                .transitionToSharedExecution()
                        },
                        restorationLease: providerRestorationLease
                    )
            )
            if !launchWarnings.isEmpty {
                result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    result.diagnosticCaptureWarning,
                    launchWarnings.joined(separator: " | ")
                )
                result.runtimeCompatibility[
                    "prelaunchRendererRestorationStatus"
                ] = "failed-fail-open"
            }
            guard SteamLaunchDispatchDisposition.resolve(result)
                    .acceptsSessionLifetime else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "active-launch-session-required"
                )
            }
            let effectiveRendererSelection =
                result.rendererRouteApplicationReceipt?.selection ??
                SteamRendererPolicySelection(
                    rawValue:
                        result.runtimeCompatibility["rendererEffective"] ?? ""
                ) ?? projection.rendererSelection
            let launchedSessionDigest = Self.componentStateDigest(
                domain: "launched-session",
                rows: [
                    baselineDigest,
                    result.processIdentifier.map(String.init) ?? "unavailable",
                    result.runtimeCompatibility["rendererEffective"] ??
                        effectiveRendererSelection.rawValue
                ]
            )
            let launchedSessionFallbackDigest = Self.componentStateDigest(
                domain: "launched-session-advisory-unavailable",
                rows: [launchedSessionDigest]
            )
            func recordPostDispatchAdvisoryWarning(_ warning: String?) {
                guard let warning else { return }
                result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    result.diagnosticCaptureWarning,
                    warning
                )
                result.runtimeCompatibility[
                    "postDispatchAdvisoryReadbackStatus"
                ] = "degraded-fail-open"
            }
            let appliedStateReadback =
                SteamCompatibilityPostDispatchAdvisoryReadback.capture(
                    componentID: "applied-state digest",
                    fallback: launchedSessionFallbackDigest
                ) {
                    try steamManager.compatibilityLaunchBaselineDigest(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable,
                        runtimeCapability:
                            rendererTransaction.resolution.capability,
                        selection: effectiveRendererSelection,
                        videoMemorySizeMB: projection.videoMemorySizeMB
                    )
                }
            recordPostDispatchAdvisoryWarning(
                appliedStateReadback.diagnosticWarning
            )
            let capturedAppliedStateDigest = appliedStateReadback.value
            let appliedStateDigest = capturedAppliedStateDigest == baselineDigest
                ? launchedSessionDigest
                : capturedAppliedStateDigest
            let synchronizationReadback =
                result.managedWineChildSynchronizationReadback
            let readbackRows = [
                "forgeplay-provider-readback-v1",
                request.canonicalDigest,
                appliedStateDigest,
                synchronizationReadback?.selection.rawValue ??
                    "readback-unavailable",
                synchronizationReadback?.backend.rawValue ??
                    "readback-unavailable",
                result.rendererRouteApplicationReceipt?.selection.rawValue ?? "",
                result.inputCompatibilityReceipt?.isAppliedAndReadBack == true
                    ? "input=1" : "input=0",
                result.controllerCompatibilityReceipt?
                    .isStaticPreparationVerified == true
                    ? "controller=1" : "controller=0",
                result.windowsFontProvisioningReceipt?.isAppliedAndReadBack == true
                    ? "fonts=1" : "fonts=0"
            ]
            let providerReadbackDigest = SHA256.hash(
                data: Data(readbackRows.joined(separator: "\n").utf8)
            ).map { String(format: "%02x", $0) }.joined()
            let rendererAfterInspection = steamManager.inspectSteamRendererPolicy(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: rendererTransaction.resolution.capability,
                selection: effectiveRendererSelection,
                videoMemorySizeMB: projection.videoMemorySizeMB
            )
            let persistentReadbackFallbackDigest = Self.componentStateDigest(
                domain: "persistent-prefix-post-dispatch-advisory-unavailable",
                rows: [
                    persistentPrefixSnapshot.digest,
                    request.canonicalDigest,
                    result.processIdentifier.map(String.init) ?? "unavailable"
                ]
            )
            let persistentAfterReadback =
                SteamCompatibilityPostDispatchAdvisoryReadback.capture(
                    componentID: "persistent-prefix after-snapshot",
                    fallback: persistentReadbackFallbackDigest
                ) {
                    try steamManager
                        .captureCompatibilityPersistentPrefixSnapshot(
                            prefix: prefix
                        ).digest
                }
            recordPostDispatchAdvisoryWarning(
                persistentAfterReadback.diagnosticWarning
            )
            let rendererReadbackInspection =
                steamManager.inspectSteamRendererPolicy(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    runtimeCapability:
                        rendererTransaction.resolution.capability,
                    selection: effectiveRendererSelection,
                    videoMemorySizeMB: projection.videoMemorySizeMB
                )
            let persistentReadback =
                SteamCompatibilityPostDispatchAdvisoryReadback.capture(
                    componentID: "persistent-prefix verification snapshot",
                    fallback: persistentReadbackFallbackDigest
                ) {
                    try steamManager
                        .captureCompatibilityPersistentPrefixSnapshot(
                            prefix: prefix
                        ).digest
                }
            recordPostDispatchAdvisoryWarning(
                persistentReadback.diagnosticWarning
            )
            let fallbackInputBeforeDigest = Self.componentStateDigest(
                domain: "input",
                rows: ["transport=unbound"]
            )
            let fallbackInputAfterDigest = Self.componentStateDigest(
                domain: "input",
                rows: [
                    "transport=launch-dispatched",
                    "pid=\(result.processIdentifier.map(String.init) ?? "unavailable")"
                ]
            )
            let inputBeforeDigest = result.inputCompatibilityReceipt.map {
                Self.inputStateDigest($0, phase: .before)
            } ?? fallbackInputBeforeDigest
            let inputAfterDigest = result.inputCompatibilityReceipt.map {
                Self.inputStateDigest($0, phase: .after)
            } ?? fallbackInputAfterDigest
            let inputReadbackDigest = result.inputCompatibilityReceipt.map {
                Self.inputStateDigest($0, phase: .readback)
            } ?? fallbackInputAfterDigest
            let fallbackControllerDigest = Self.componentStateDigest(
                domain: "controller",
                rows: ["readback=unavailable"]
            )
            let controllerBeforeDigest = result.controllerCompatibilityReceipt
                .map { Self.controllerStateDigest($0, phase: .before) } ??
                fallbackControllerDigest
            let controllerAfterDigest = result.controllerCompatibilityReceipt
                .map { Self.controllerStateDigest($0, phase: .after) } ??
                fallbackControllerDigest
            let controllerReadbackDigest = result
                .controllerCompatibilityReceipt.map {
                    Self.controllerStateDigest($0, phase: .readback)
                } ?? fallbackControllerDigest
            let fallbackFontDigest = Self.componentStateDigest(
                domain: "fonts",
                rows: ["readback=unavailable"]
            )
            let fontBeforeDigest = result.windowsFontProvisioningReceipt.map {
                Self.fontStateDigest($0, phase: .before)
            } ?? fallbackFontDigest
            let fontAfterDigest = result.windowsFontProvisioningReceipt.map {
                Self.fontStateDigest($0, phase: .after)
            } ?? fallbackFontDigest
            let fontReadbackDigest = result.windowsFontProvisioningReceipt.map {
                Self.fontStateDigest($0, phase: .readback)
            } ?? fallbackFontDigest
            let rendererBeforeDigest = Self.rendererStateDigest(
                rendererBeforeInspection
            )
            let rendererAfterDigest = Self.rendererStateDigest(
                rendererAfterInspection
            )
            let rendererReadbackDigest = Self.rendererStateDigest(
                rendererReadbackInspection
            )
            let synchronizationBeforeDigest = Self.componentStateDigest(
                domain: "synchronization",
                rows: [
                    WineSynchronizationSelection.automatic.rawValue,
                    synchronizationResolution.previouslyAppliedBackend.rawValue
                ]
            )
            let synchronizationAfterDigest = Self.componentStateDigest(
                domain: "synchronization",
                rows: [
                    synchronizationResolution.requestedSelection.rawValue,
                    synchronizationResolution.resolvedBackend.rawValue
                ]
            )
            let synchronizationReadbackDigest = synchronizationReadback.map {
                Self.componentStateDigest(
                    domain: "synchronization",
                    rows: [$0.selection.rawValue, $0.backend.rawValue]
                )
            } ?? synchronizationAfterDigest
            func advisoryEvidence(
                componentID: String,
                before: String,
                after: String,
                readback: String
            ) -> CompatibilityRuntimeComponentMutationEvidenceV1 {
                guard after == readback else {
                    let unavailable = Self.componentStateDigest(
                        domain: "\(componentID)-readback-mismatch",
                        rows: [after, readback]
                    )
                    return CompatibilityRuntimeComponentMutationEvidenceV1(
                        componentID: componentID,
                        beforeDigest: unavailable,
                        afterDigest: unavailable,
                        readbackDigest: unavailable
                    )
                }
                return CompatibilityRuntimeComponentMutationEvidenceV1(
                    componentID: componentID,
                    beforeDigest: before,
                    afterDigest: after,
                    readbackDigest: readback
                )
            }
            var componentMutationEvidence = [
                advisoryEvidence(
                    componentID: "controller",
                    before: controllerBeforeDigest,
                    after: controllerAfterDigest,
                    readback: controllerReadbackDigest
                ),
                advisoryEvidence(
                    componentID: "fonts",
                    before: fontBeforeDigest,
                    after: fontAfterDigest,
                    readback: fontReadbackDigest
                ),
                advisoryEvidence(
                    componentID: "input",
                    before: inputBeforeDigest,
                    after: inputAfterDigest,
                    readback: inputReadbackDigest
                ),
                advisoryEvidence(
                    componentID: "persistent-prefix",
                    before: persistentPrefixSnapshot.digest,
                    after: persistentAfterReadback.value,
                    readback: persistentReadback.value
                ),
                advisoryEvidence(
                    componentID: "renderer",
                    before: rendererBeforeDigest,
                    after: rendererAfterDigest,
                    readback: rendererReadbackDigest
                ),
                advisoryEvidence(
                    componentID: "synchronization",
                    before: synchronizationBeforeDigest,
                    after: synchronizationAfterDigest,
                    readback: synchronizationReadbackDigest
                )
            ]
            if !componentMutationEvidence.contains(where: \.didMutate),
               let inputIndex = componentMutationEvidence.firstIndex(
                    where: { $0.componentID == "input" }
               ) {
                componentMutationEvidence[inputIndex] =
                    CompatibilityRuntimeComponentMutationEvidenceV1(
                        componentID: "input",
                        beforeDigest: fallbackInputBeforeDigest,
                        afterDigest: fallbackInputAfterDigest,
                        readbackDigest: fallbackInputAfterDigest
                    )
            }
            try componentMutationEvidence.forEach { try $0.validate() }
            let retainedPrefixLease = SteamCompatibilityPrefixSessionLease(
                adopting: prefixExecutionLease
            )
            leaseTransferred = true
            return SteamCompatibilityCoordinatedLaunchResult(
                processResult: result,
                prefixBinding: prefixBinding,
                capturedBaselineDigest: baselineDigest,
                persistentPrefixSnapshot: persistentPrefixSnapshot,
                appliedStateDigest: appliedStateDigest,
                providerReadbackDigest: providerReadbackDigest,
                componentMutationEvidence: componentMutationEvidence,
                synchronizationResolution: synchronizationResolution,
                sessionPrefixLease: retainedPrefixLease
            )
            } catch {
                let originalError = error
                do {
                    try await steamManager.shutdownSteamPrefixBeforePolicyMutation(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix
                    )
                    try prefixExecutionLease.transitionToExclusiveMutation()
                    _ = try await steamManager.completeCompatibilitySessionIfInactive(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable,
                        selection: projection.rendererSelection,
                        videoMemorySizeMB: projection.videoMemorySizeMB
                    )
                    try steamManager.restoreCompatibilityPersistentPrefixSnapshot(
                        persistentPrefixSnapshot,
                        prefix: prefix
                    )
                    let restoredDigest = try steamManager
                        .compatibilityLaunchBaselineDigest(
                            prefix: prefix,
                            runtimeExecutable: runtimeExecutable,
                            runtimeCapability:
                                rendererTransaction.resolution.capability,
                            selection: projection.rendererSelection,
                            videoMemorySizeMB: projection.videoMemorySizeMB,
                            persistentStateDigest: persistentPrefixSnapshot.digest
                        )
                    guard restoredDigest == baselineDigest else {
                        throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                            "failed-launch-baseline-restore"
                        )
                    }
                } catch {
                    throw SteamPrefixLifecycleCleanupError(
                        originalDescription:
                            forgePlayTechnicalErrorSummary(originalError),
                        cleanupDescription: forgePlayTechnicalErrorSummary(error),
                        originalError: originalError,
                        cleanupError: error,
                        cleanupProcessResults:
                            diagnosticProcessRunResults(from: error)
                    )
                }
                throw originalError
            }
        }
    }

    private enum ComponentEvidencePhase: Equatable {
        case before
        case after
        case readback
    }

    private nonisolated static func inputStateDigest(
        _ receipt: SteamInputCompatibilityApplicationReceipt,
        phase: ComponentEvidencePhase
    ) -> String {
        let keyboard = receipt.keyboard
        let permutation: ModifierKeyPermutation?
        let bridgeEnabled: Bool
        let targetPID: pid_t?
        switch phase {
        case .before:
            permutation = keyboard.requestedPermutation
            bridgeEnabled = false
            targetPID = nil
        case .after:
            permutation = keyboard.requestedPermutation
            bridgeEnabled = keyboard.bridgeEnabled
            targetPID = keyboard.targetProcessIdentifier
        case .readback:
            permutation = keyboard.readbackPermutation
            bridgeEnabled = keyboard.bridgeEnabled
            targetPID = keyboard.targetProcessIdentifier
        }
        return componentStateDigest(
            domain: "input",
            rows: [
                "cursor.requested=\(receipt.cursor.requested ? 1 : 0)",
                "cursor.captured=\(receipt.cursor.captured ? 1 : 0)",
                "cursor.display=\(receipt.cursor.displayIdentifier.map(String.init) ?? "-")",
                "cursor.restored=\(receipt.cursor.restored ? 1 : 0)",
                "keyboard.bridge=\(bridgeEnabled ? 1 : 0)",
                "keyboard.pid=\(targetPID.map(String.init) ?? "-")",
                "keyboard.command=\(permutation?.command.rawValue ?? "-")",
                "keyboard.option=\(permutation?.option.rawValue ?? "-")",
                "keyboard.control=\(permutation?.control.rawValue ?? "-")",
                "keyboard.restored=\(keyboard.restored ? 1 : 0)"
            ]
        )
    }

    private nonisolated static func controllerStateDigest(
        _ receipt: ControllerCompatibilityApplicationReceipt,
        phase: ComponentEvidencePhase
    ) -> String {
        let boundPID: pid_t?
        let routeDigest: String?
        switch phase {
        case .before:
            boundPID = nil
            routeDigest = receipt.staticBridgeCapability.routeDigest
        case .after:
            boundPID = receipt.boundLauncherProcessIdentifier
            routeDigest = receipt.staticBridgeCapability.routeDigest
        case .readback:
            boundPID = receipt.boundLauncherProcessIdentifier
            routeDigest = receipt.staticRouteContinuityDigest
        }
        return componentStateDigest(
            domain: "controller",
            rows: [
                "policy=\(receipt.policy.rawValue)",
                "macDiscovery=\(receipt.macDiscoveryCount)",
                "uniqueMacDevice=\(receipt.uniqueMacDeviceCount)",
                "acceptedLogicalDevice=\(receipt.acceptedLogicalDeviceCount)",
                "xinputOverflow=\(receipt.xinputSlotOverflowCount)",
                "duplicateReference=\(receipt.duplicateReferenceCount)",
                "routeAvailable=\(receipt.staticBridgeCapability.isStaticRouteAvailable ? 1 : 0)",
                "routeDigest=\(routeDigest ?? "-")",
                "boundPID=\(boundPID.map(String.init) ?? "-")",
                "requiresChildEnumeration=\(receipt.requiresChildDeviceEnumeration ? 1 : 0)",
                "childEnumerationVerified=\(receipt.actualChildEnumerationVerified ? 1 : 0)",
                "restored=\(receipt.restored ? 1 : 0)"
            ]
        )
    }

    private nonisolated static func fontStateDigest(
        _ receipt: WindowsFontProvisioningApplicationReceipt,
        phase: ComponentEvidencePhase
    ) -> String {
        switch phase {
        case .before:
            let reused = receipt.state == .reusedVerifiedProfile
            return componentStateDigest(
                domain: "fonts",
                rows: [
                    "profile=\(receipt.profileIdentifier)",
                    "state=\(receipt.state.rawValue)",
                    "profileDigest=\(receipt.baselineDigest)",
                    "appliedItems=\(reused ? receipt.appliedItemCount : 0)",
                    "readbackComplete=\(reused ? 1 : 0)"
                ]
            )
        case .after, .readback:
            let readback = phase == .readback
            return componentStateDigest(
                domain: "fonts",
                rows: [
                    "profile=\(receipt.profileIdentifier)",
                    "state=\(receipt.state.rawValue)",
                    "profileDigest=\(receipt.appliedDigest)",
                    "appliedItems=\(receipt.appliedItemCount)",
                    "missingItems=\(receipt.missingItemCount)",
                    "readbackComplete=\(readback ? 1 : 0)"
                ]
            )
        }
    }

    private nonisolated static func rendererStateDigest(
        _ inspection: SteamRendererPolicyInspection
    ) -> String {
        let recovery: String
        switch inspection.effectiveRecoveryKind {
        case .applyPolicy: recovery = "apply-policy"
        case .repairPolicy: recovery = "repair-policy"
        case .automaticSessionRecovery: recovery = "automatic-session-recovery"
        case .runtimeUnavailable: recovery = "runtime-unavailable"
        }
        return componentStateDigest(
            domain: "renderer",
            rows: [
                "selection=\(inspection.selection.rawValue)",
                "resolved=\(inspection.resolvedPolicy?.rawValue ?? "-")",
                "status=\(inspection.status.rawValue)",
                "recovery=\(recovery)",
                "appliedModules=\(inspection.appliedModules.sorted().joined(separator: ","))",
                "missingModules=\(inspection.missingModules.sorted().joined(separator: ","))",
                "mixedModules=\(inspection.mixedModules.sorted().joined(separator: ","))",
                "appliedOverrides=\(inspection.appliedProfileOverrides.sorted().joined(separator: ","))",
                "missingOverrides=\(inspection.missingProfileOverrides.sorted().joined(separator: ","))",
                "staleOverrides=\(inspection.staleProfileOverrides.sorted().joined(separator: ","))",
                "appliedSteamFiles=\(inspection.appliedSteamClientFiles.sorted().joined(separator: ","))",
                "missingSteamFiles=\(inspection.missingSteamClientFiles.sorted().joined(separator: ","))",
                "staleSteamFiles=\(inspection.staleSteamClientFiles.sorted().joined(separator: ","))"
            ]
        )
    }

    private nonisolated static func componentStateDigest(
        domain: String,
        rows: [String]
    ) -> String {
        var data = Data("forgeplay-runtime-component-state-v1\n".utf8)
        data.append(contentsOf: "domain=\(domain)\n".utf8)
        for row in rows {
            data.append(contentsOf: "row=\(row.utf8.count):".utf8)
            data.append(contentsOf: row.utf8)
            data.append(10)
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Completes a provider-owned compatibility session only after the exact
    /// managed prefix is proven inactive under exclusive mutation ownership.
    /// The returned digest is the post-restore state and must equal the
    /// baseline captured by `launchCompatibilitySteamTransaction`.
    func completeCompatibilitySteamTransaction(
        runtimeExecutable: URL,
        rendererSelection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int,
        persistentPrefixSnapshot: SteamCompatibilityPersistentPrefixSnapshot,
        capturedBaselineDigest: String,
        sessionPrefixLease: SteamCompatibilityPrefixSessionLease,
        prefixBinding: SteamCompatibilityPrefixBinding,
        permittingApplicationTerminationCleanup: Bool = false
    ) async throws -> String {
        try await withOperationOwnership(
            .maintenance,
            permittingApplicationTerminationCleanup:
                permittingApplicationTerminationCleanup
        ) { [self] in
            let prefix = try requireCurrentCompatibilityPrefix(prefixBinding)
            try sessionPrefixLease.transitionToExclusiveMutation()
            _ = try await steamManager
                .completeCompatibilitySessionIfInactive(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    selection: rendererSelection,
                    videoMemorySizeMB: videoMemorySizeMB
                )
            try steamManager.restoreCompatibilityPersistentPrefixSnapshot(
                persistentPrefixSnapshot,
                prefix: prefix
            )
            let digest = try steamManager.compatibilityLaunchBaselineDigest(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                selection: rendererSelection,
                videoMemorySizeMB: videoMemorySizeMB,
                persistentStateDigest: persistentPrefixSnapshot.digest
            )
            guard digest == capturedBaselineDigest else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "restored-baseline-mismatch"
                )
            }
            sessionPrefixLease.release()
            return digest
        }
    }

    func requireCurrentCompatibilityPrefix(
        _ prefixBinding: SteamCompatibilityPrefixBinding
    ) throws -> URL {
        try prefixBinding.validateCurrentPrefix(
            prefixManager.steamSharedPrefixURL()
        )
    }

    func shutdownCompatibilitySteamRuntime(
        runtimeExecutable: URL,
        prefixBinding: SteamCompatibilityPrefixBinding
    ) async throws -> ProcessRunResult {
        _ = try requireCurrentCompatibilityPrefix(prefixBinding)
        return try await steamManager.shutdownManagedSteamRuntimeOnly(
            runtimeExecutable: runtimeExecutable
        )
    }

    func retainCompatibilitySessionLifetime(
        receiptID: String,
        owner: any SteamCompatibilityBackgroundWorkOwner
    ) throws {
        guard compatibilitySessionLifetimeOwners[receiptID] == nil else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "duplicate-session-lifetime-owner"
            )
        }
        compatibilitySessionLifetimeOwners[receiptID] = owner
    }

    func compatibilitySessionLifetimeOwner(
        receiptID: String
    ) -> (any SteamCompatibilityBackgroundWorkOwner)? {
        compatibilitySessionLifetimeOwners[receiptID]
    }

    func recordCompatibilitySessionRestorationFailure(
        receiptID: String,
        diagnostic: String
    ) {
        compatibilitySessionRestorationFailures[receiptID] = diagnostic
    }

    func clearCompatibilitySessionRestorationFailure(receiptID: String) {
        compatibilitySessionRestorationFailures.removeValue(forKey: receiptID)
    }

    func compatibilitySessionRestorationFailure(
        receiptID: String
    ) -> String? {
        compatibilitySessionRestorationFailures[receiptID]
    }

    func releaseCompatibilitySessionLifetime(receiptID: String) {
        compatibilitySessionLifetimeOwners.removeValue(forKey: receiptID)
    }

    var hasRetainedCompatibilityCleanupOwnership: Bool {
        !compatibilitySessionLifetimeOwners.isEmpty ||
            !failedCompatibilityCleanupOwners.isEmpty
    }

    var failedCompatibilityCleanupOwnerCountForTesting: Int {
        failedCompatibilityCleanupOwners.count
    }

    func retainFailedCompatibilityCleanupOwner(
        _ owner: any SteamCompatibilityFailedCleanupOwner
    ) throws {
        guard failedCompatibilityCleanupOwners[owner.cleanupReceiptID] == nil else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "duplicate-failed-compatibility-cleanup-owner"
            )
        }
        failedCompatibilityCleanupOwners[owner.cleanupReceiptID] = owner
    }

    @discardableResult
    func completeFailedCompatibilityCleanup(
        receiptID: String,
        reason: SteamCompatibilityFailedCleanupCompletionReason
    ) async throws -> SteamCompatibilityFailedCleanupCompletionProof? {
        guard let owner = failedCompatibilityCleanupOwners[receiptID] else {
            return nil
        }
        let proof = try await owner.completeFailedPostLaunchCleanup(
            using: self,
            reason: reason
        )
        try Self.validateFailedCompatibilityCleanupProof(
            proof,
            owner: owner
        )
        if let current = failedCompatibilityCleanupOwners[receiptID],
           (current as AnyObject) === (owner as AnyObject) {
            failedCompatibilityCleanupOwners.removeValue(forKey: receiptID)
        }
        return proof
    }

    func completeFailedCompatibilityCleanupsForApplicationTermination()
        async throws
    {
        while let receiptID = failedCompatibilityCleanupOwners.keys.sorted().first {
            guard try await completeFailedCompatibilityCleanup(
                receiptID: receiptID,
                reason: .applicationTermination
            ) != nil else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "missing-failed-compatibility-cleanup-owner"
                )
            }
        }
    }

    func cancelCompatibilityBackgroundWork()
        -> [SteamCompatibilityBackgroundWorkCompletionState]
    {
        var owners: [any SteamCompatibilityBackgroundWorkOwner] = []
        owners.append(contentsOf: compatibilitySessionLifetimeOwners.values)
        for owner in failedCompatibilityCleanupOwners.values {
            owners.append(owner)
        }

        var seen = Set<ObjectIdentifier>()
        var completionStates:
            [SteamCompatibilityBackgroundWorkCompletionState] = []
        for owner in owners
        where seen.insert(ObjectIdentifier(owner)).inserted {
            completionStates.append(
                contentsOf: owner.cancelCompatibilityBackgroundWork()
            )
        }
        return completionStates
    }

    private static func validateFailedCompatibilityCleanupProof(
        _ proof: SteamCompatibilityFailedCleanupCompletionProof,
        owner: any SteamCompatibilityFailedCleanupOwner
    ) throws {
        guard proof.cleanupReceiptID == owner.cleanupReceiptID,
              proof.prefixBinding == owner.prefixBinding,
              proof.capturedBaselineDigest == owner.capturedBaselineDigest,
              proof.restoredBaselineDigest == owner.capturedBaselineDigest,
              SteamLaunchIdentifierValidation.isValidLowercaseSHA256(
                proof.capturedBaselineDigest
              ) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "failed-compatibility-cleanup-proof-mismatch"
            )
        }
    }

    func waitForCompatibilitySteamTransactionToBecomeInactive(
        prefixBinding: SteamCompatibilityPrefixBinding
    ) async throws -> Bool {
        let prefix = try requireCurrentCompatibilityPrefix(prefixBinding)
        return try await steamManager
            .waitForCompatibilityPrefixToBecomeInactive(prefix)
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
        let backend: WineSynchronizationBackend
        switch selection {
        case .automatic:
            backend = capabilities.preferredAutomaticBackend
        }
        guard capabilities.supports(backend) else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "synchronization-backend",
                value: "\(selection.rawValue):\(backend.rawValue)"
            )
        }
        return backend
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

        let policy = WineSynchronizationPolicy(
            selection: selection,
            backend: resolvedBackend
        )
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
            requestedSelection: target.requestedSelection,
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
        _ body: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withExclusiveOperation(.maintenance, perform: body)
    }

    func performCancellableProcessMaintenance<T: Sendable>(
        _ body: @escaping @MainActor @Sendable () async throws -> T
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

    /// Startup storage activation already owns the lifecycle transition. This
    /// variant adds only the root/prefix mutation barriers and keeps recursive
    /// removal off MainActor, so readiness remains a pure read projection.
    func cleanupInterruptedReplacementArtifactsDuringManagedStorageTransition(
        at prefixURL: URL
    ) async throws {
        try lifecycleCoordinator.checkpoint()
        let managedRootLeases: [ManagedRootOperationLease]
        do {
            managedRootLeases = try prefixManager.acquireManagedRootOperationLease()
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        defer { managedRootLeases.reversed().forEach { $0.release() } }

        do {
            try claimRuntimeOwnership(
                forManagedRoot: prefixManager.currentManagedRootURL()
            )
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        let prefixExecutionLease = try acquireExclusivePrefixLeaseIfPresent(
            prefixURL
        )
        defer { prefixExecutionLease?.release() }
        try await prefixManager
            .cleanupInterruptedReplacementArtifactsAssumingExclusiveAccess(
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
        perform body: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withOperationOwnership(operation, perform: body)
    }

    private func withCoordinatedPrefixOperation<T>(
        _ operation: SteamPrefixLifecycleOperation,
        prefix explicitPrefix: URL? = nil,
        perform body: @escaping @MainActor @Sendable (
            PrefixExecutionLease
        ) async throws -> T
    ) async throws -> T {
        try await withOperationOwnership(operation) { [self] in
            let prefix = try explicitPrefix ??
                prefixManager.steamSharedPrefixURL()
            let prefixExecutionLease = try PrefixExecutionLease.acquireExclusiveMutation(
                forPrefix: prefix
            )
            defer { prefixExecutionLease.release() }
            return try await body(prefixExecutionLease)
        }
    }

    private nonisolated static func prefixCleanupFailure(
        _ cleanup: (result: ProcessRunResult?, error: Error?),
        missingReason: String
    ) -> Error? {
        if let error = cleanup.error { return error }
        guard let result = cleanup.result else {
            return SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                missingReason
            )
        }
        guard result.succeeded,
              result.postconditionSatisfied == true else {
            return SteamLaunchError.prefixShutdownFailed(result)
        }
        return nil
    }

    private func withCoordinatedPrefixLaunchOperation<T>(
        _ operation: SteamPrefixLifecycleOperation,
        perform body: @escaping @MainActor @Sendable (
            PrefixExecutionLease,
            SteamCompatibilityRestorationPrefixLease
        ) async throws -> T
    ) async throws -> T {
        try await withOperationOwnership(operation) { [self] in
            let prefix = try prefixManager.steamSharedPrefixURL()
            let prefixExecutionLease = try await steamManager
                .acquirePrefixMutationLeaseForLaunch(prefix: prefix)
            let restorationLease = SteamCompatibilityRestorationPrefixLease(
                prepareForMutation: {
                    try prefixExecutionLease.transitionToExclusiveMutation()
                },
                release: {
                    prefixExecutionLease.release()
                }
            )
            defer {
                if !restorationLease.isTransferred {
                    restorationLease.release()
                }
            }
            return try await body(prefixExecutionLease, restorationLease)
        }
    }

    private func withOperationOwnership<T>(
        _ operation: SteamPrefixLifecycleOperation,
        permittingApplicationTerminationCleanup: Bool = false,
        perform body: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let token = try lifecycleCoordinator.begin(
            operation,
            permittingApplicationTerminationCleanup:
                permittingApplicationTerminationCleanup
        )
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
        return try await withTrackedOperationTask(token: token, body)
    }

    private func withTrackedOperationTask<T>(
        token: UUID,
        _ body: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let operationTask = Task { @MainActor in
            do {
                return SteamPrefixOperationResultBox(.success(try await body()))
            } catch {
                return SteamPrefixOperationResultBox(.failure(error))
            }
        }
        lifecycleCoordinator.setCancellationRequester(
            { operationTask.cancel() },
            for: token
        )
        let result = await withTaskCancellationHandler {
            await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
        return try result.result.get()
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

extension SteamPrefixService {
    /// Composes already-prepared control-plane ownership. This deliberately
    /// does not enter the current Steam launch path; launch integration remains
    /// a separately authorized operation.
    func makeWindowsHelperLifecycleCoordinator(
        preparedControl: WindowsRuntimePreparedExecutionControlV1,
        exclusivePrefixLease: PrefixExecutionLease,
        processSupervisor: any WindowsHelperProcessSupervising
    ) throws -> WindowsHelperLifecycleCoordinator {
        guard exclusivePrefixLease.mode == .exclusiveMutation else {
            throw WindowsExecutionContractError(
                reason: .lifecycleEvidenceInvalid,
                stage: .lifecycle,
                detail: "prepared helper requires exclusive prefix ownership"
            )
        }
        let ownership = try exclusivePrefixLease.windowsHelperOwnership(
            preparedPrefixScopeSHA256:
                preparedControl.records.bootstrap.prefixScopeSHA256
        )
        return try WindowsHelperLifecycleCoordinator(
            bootstrap: preparedControl.records.bootstrap,
            profile: preparedControl.profile,
            authority: preparedControl.authority,
            prefixLease: ownership,
            processSupervisor: processSupervisor,
            cleanupDeadlineMonotonicNanoseconds:
                preparedControl.cleanupDeadlineMonotonicNanoseconds
        )
    }
}
