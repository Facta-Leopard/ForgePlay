// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import CryptoKit
import Foundation
import Observation
import SwiftData

struct AppTerminationSteamShutdownSummary: Sendable, Hashable {
    var prefix: URL?
    var prefixes: [URL] = []
    var attemptedRuntimePath: String?
    var results: [ProcessRunResult]
    var errors: [String]
    var warnings: [String] = []
    var skippedReason: String?

    var succeeded: Bool {
        if skippedReason != nil {
            return errors.isEmpty
        }
        let requiredShutdownResults = results.filter { $0.actionName == "shutdownWinePrefix" }
        return attemptedRuntimePath != nil &&
            errors.isEmpty &&
            requiredShutdownResults.filter(\.succeeded).count >= prefixes.count
    }

    var diagnosticDescription: String {
        var parts: [String] = []
        if let skippedReason {
            parts.append("skipped=\(skippedReason)")
        }
        if let prefix {
            parts.append("prefix=\(prefix.path)")
        }
        if !prefixes.isEmpty {
            parts.append("prefixes=\(prefixes.map(\.path).joined(separator: ","))")
        }
        if let attemptedRuntimePath {
            parts.append("runtime=\(attemptedRuntimePath)")
        }
        if !results.isEmpty {
            let resultSummary = results
                .map {
                    return "\($0.actionName):processExit=\($0.diagnosticExitCodeDescription):forgePlayStatus=\($0.diagnosticForgePlayStatusDescription):timeout=\($0.didTimeOut)"
                }
                .joined(separator: ",")
            parts.append("results=\(resultSummary)")
        }
        if !errors.isEmpty {
            parts.append("errors=\(errors.joined(separator: " | "))")
        }
        if !warnings.isEmpty {
            parts.append("warnings=\(warnings.joined(separator: " | "))")
        }
        return parts.joined(separator: " ")
    }
}

struct AppTerminationSteamShutdownPlan: Sendable, Hashable {
    var prefixes: [URL]
    var runtimeExecutable: URL?
    var initialErrors: [String]
    var initialWarnings: [String] = []
    var skippedReason: String?
}

struct ManagedStorageStartupRequest: Equatable {
    var destination: URL
    var destinationBookmark: Data?
    var legacySource: URL?

    static func resolve(
        layoutVersion: Int?,
        persistedRootPath: String?,
        persistedRootBookmark: Data?,
        selectedRootURL: URL?,
        defaultManagedRoot: URL,
        approvedLegacyMigrationSourcePath: String?
    ) throws -> ManagedStorageStartupRequest {
        let defaultRoot = defaultManagedRoot.standardizedFileURL
        let selectedRoot = selectedRootURL?.standardizedFileURL
        let persistedPath = normalizedPath(persistedRootPath)

        guard layoutVersion == ForgePlayManagedStorageLayout.currentVersion else {
            if selectedRoot == nil,
               let persistedPath,
               persistedPath != defaultRoot.path {
                throw ManagedStorageActivationError.legacyRootAuthorizationRequired(persistedPath)
            }
            guard let legacySource = selectedRoot,
                  legacySource.path != defaultRoot.path else {
                return ManagedStorageStartupRequest(
                    destination: defaultRoot,
                    destinationBookmark: nil,
                    legacySource: nil
                )
            }
            guard normalizedPath(approvedLegacyMigrationSourcePath) == legacySource.path else {
                throw ManagedStorageActivationError.legacyMigrationDecisionRequired(legacySource.path)
            }
            return ManagedStorageStartupRequest(
                destination: defaultRoot,
                destinationBookmark: nil,
                legacySource: legacySource
            )
        }

        if let persistedPath,
           persistedPath != defaultRoot.path,
           selectedRoot == nil {
            throw ManagedStorageActivationError.managedRootAuthorizationRequired(persistedPath)
        }
        let destination = selectedRoot ?? defaultRoot
        return ManagedStorageStartupRequest(
            destination: destination,
            destinationBookmark: destination.path == defaultRoot.path ? nil : persistedRootBookmark,
            legacySource: nil
        )
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }
}

enum ManagedStorageWorkflowError: LocalizedError, Equatable {
    case transitionInProgress
    case legacyMigrationDecisionUnavailable

    var errorDescription: String? {
        switch self {
        case .transitionInProgress:
            "다른 앱 데이터 작업이 진행 중입니다. 완료된 뒤 다시 시도하세요."
        case .legacyMigrationDecisionUnavailable:
            "옮길 기존 ForgePlay 앱 데이터가 선택되지 않았습니다. 앱 데이터 설정을 다시 여세요."
        }
    }
}

enum ManagedStoragePreparationState: Equatable {
    case idle
    case preparing
    case relocating(from: URL, to: URL)
    case importing(from: URL, to: URL)
    case legacyMigrationDecisionRequired(String)
    case authorizationRequired(String)
    case ready(URL)
    case failed(String)
}

struct SteamReferenceRefreshToken: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let lifecycleToken: UUID
}

@MainActor
@Observable
final class AppServices {
    private(set) var steamEnvironmentRevision = 0
    private(set) var isManagedStorageTransitionInProgress = false
    private(set) var isSteamReferenceRefreshInProgress = false
    private(set) var managedStoragePreparationState: ManagedStoragePreparationState = .idle
    @ObservationIgnored private var managedStoragePreparationTask: Task<ManagedStorageActivationResult, Error>?
    @ObservationIgnored private var completedManagedStorageActivation: ManagedStorageActivationResult?
    @ObservationIgnored private var approvedLegacyMigrationSourcePath: String?
    @ObservationIgnored private var activeSteamReferenceRefreshToken: SteamReferenceRefreshToken?
    @ObservationIgnored private var invalidatedSteamReferenceRefreshIDs: Set<UUID> = []
    let appSessionID: String
    let pathManager: PathManager
    let systemCheckService: SystemCheckService
    let managedWineSessionRegistry: ManagedWineSessionRegistry
    let safeProcessRunner: SafeProcessRunner
    let windowsRuntimeService: WindowsRuntimeService
    let prefixManager: PrefixManager
    let steamManager: SteamManager
    let runtimeManager: RuntimeManager
    let ruleEngine: RuleEngine
    let compatibilityService: CompatibilityService
    let redactor: Redactor
    let failureDiagnosticEvidenceService: FailureDiagnosticEvidenceService
    let llmService: LLMService
    let autoFixService: AutoFixService
    let supportBundleService: SupportBundleService
    let compatibilityDBUpdateService: CompatibilityDBUpdateService
    let logRetentionService: LogRetentionService
    let storageMigrationService: StorageMigrationService
    let managedStorageService: ManagedStorageService
    let setupResetService: SetupResetService
    let steamPrefixLifecycleCoordinator: SteamPrefixLifecycleCoordinator
    let steamPrefixService: SteamPrefixService
    let steamPrefixReadinessResolver: SteamPrefixReadinessResolver
    let setupWorkflowCoordinator: SetupWorkflowCoordinator

    nonisolated static let maxCompatibilityDBPublicKeyResourceBytes = 8 * 1024

    init(appSessionID: String = "app-session-\(UUID().uuidString)") {
        let pathManager = PathManager()
        let managedWineSessionRegistry = ManagedWineSessionRegistry()
        let safeProcessRunner = SafeProcessRunner(
            managedWineSessionRegistry: managedWineSessionRegistry
        )
        let steamPrefixLifecycleCoordinator = SteamPrefixLifecycleCoordinator()
        let windowsRuntimeService = WindowsRuntimeService(
            pathManager: pathManager,
            runner: safeProcessRunner,
            bundledRuntimeExecutableProvider: {
                ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL()
            },
            lifecycleCoordinator: steamPrefixLifecycleCoordinator
        )
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: safeProcessRunner,
            lifecycleCoordinator: steamPrefixLifecycleCoordinator
        )
        let steamManager = SteamManager(pathManager: pathManager, runner: safeProcessRunner)
        let runtimeManager = RuntimeManager(pathManager: pathManager, runner: safeProcessRunner)
        let ruleEngine = RuleEngine()
        let redactor = Redactor()
        let failureDiagnosticEvidenceService = FailureDiagnosticEvidenceService(
            pathManager: pathManager,
            redactor: redactor
        )
        let llmService = LLMService(redactor: redactor)
        let steamPrefixService = SteamPrefixService(
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager,
            steamManager: steamManager,
            lifecycleCoordinator: steamPrefixLifecycleCoordinator
        )
        let autoFixService = AutoFixService(
            prefixManager: prefixManager,
            runtimeManager: runtimeManager,
            steamPrefixService: steamPrefixService
        )
        let supportBundleService = SupportBundleService(
            pathManager: pathManager,
            runner: safeProcessRunner,
            redactor: redactor,
            prepareEvidenceForCapture: { request in
                await steamManager.refreshGameLaunchDiagnosticEvidenceForSupportBundle(
                    launchRecords: request.launchRecords,
                    incidentLaunchRecordIdentifier: request.incidentLaunchRecordIdentifier
                )
            }
        )
        let compatibilityDBUpdateService = CompatibilityDBUpdateService(
            signatureVerifierConfiguration: Self.compatibilityDBPublicKeyConfiguration()
        )
        let logRetentionService = LogRetentionService(pathManager: pathManager)
        let storageMigrationService = StorageMigrationService(pathManager: pathManager)
        let managedStorageService = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: storageMigrationService
        )
        let setupResetService = SetupResetService(
            pathManager: pathManager,
            storageMigrationService: storageMigrationService
        )
        let steamPrefixReadinessResolver = SteamPrefixReadinessResolver(
            pathManager: pathManager,
            prefixManager: prefixManager,
            steamManager: steamManager,
            steamPrefixService: steamPrefixService
        )
        let systemCheckService = SystemCheckService(
            pathManager: pathManager,
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager
        )
        let setupWorkflowCoordinator = SetupWorkflowCoordinator(
            systemCheckService: systemCheckService,
            readinessResolver: steamPrefixReadinessResolver,
            appSessionID: appSessionID
        )

        self.appSessionID = appSessionID
        self.pathManager = pathManager
        self.systemCheckService = systemCheckService
        self.managedWineSessionRegistry = managedWineSessionRegistry
        self.safeProcessRunner = safeProcessRunner
        self.windowsRuntimeService = windowsRuntimeService
        self.prefixManager = prefixManager
        self.steamManager = steamManager
        self.runtimeManager = runtimeManager
        self.ruleEngine = ruleEngine
        self.compatibilityService = CompatibilityService()
        self.redactor = redactor
        self.failureDiagnosticEvidenceService = failureDiagnosticEvidenceService
        self.llmService = llmService
        self.autoFixService = autoFixService
        self.supportBundleService = supportBundleService
        self.compatibilityDBUpdateService = compatibilityDBUpdateService
        self.logRetentionService = logRetentionService
        self.storageMigrationService = storageMigrationService
        self.managedStorageService = managedStorageService
        self.setupResetService = setupResetService
        self.steamPrefixLifecycleCoordinator = steamPrefixLifecycleCoordinator
        self.steamPrefixService = steamPrefixService
        self.steamPrefixReadinessResolver = steamPrefixReadinessResolver
        self.setupWorkflowCoordinator = setupWorkflowCoordinator
    }

    func resolveSetupReadiness(
        hasSteamReferences: Bool,
        runtimeExecutable: URL? = nil,
        rendererPolicySelection: SteamRendererPolicySelection = .d3dMetal,
        videoMemorySelection: SteamVideoMemorySelection = .automatic
    ) -> SetupReadiness {
        steamPrefixReadinessResolver.resolve(
            hasSteamReferences: hasSteamReferences,
            runtimeExecutable: runtimeExecutable,
            rendererPolicySelection: rendererPolicySelection,
            videoMemorySelection: videoMemorySelection
        )
    }

    func steamSharedPrefixURL() throws -> URL {
        try pathManager.url(for: .steamSharedPrefix)
    }

    func currentSteamEnvironmentGenerationID() throws -> String {
        try prefixManager.ensureSteamSharedEnvironmentGenerationID()
    }

    func notifySteamEnvironmentChanged() {
        steamEnvironmentRevision += 1
    }

    func beginSteamReferenceRefresh() -> SteamReferenceRefreshToken? {
        guard !isSteamReferenceRefreshInProgress,
              !isManagedStorageTransitionInProgress else {
            return nil
        }
        guard let lifecycleToken = try? steamPrefixLifecycleCoordinator.begin(.referenceRefresh) else {
            return nil
        }
        let token = SteamReferenceRefreshToken(
            id: UUID(),
            lifecycleToken: lifecycleToken
        )
        activeSteamReferenceRefreshToken = token
        invalidatedSteamReferenceRefreshIDs.remove(token.id)
        isSteamReferenceRefreshInProgress = true
        return token
    }

    func isCurrentSteamReferenceRefresh(_ token: SteamReferenceRefreshToken) -> Bool {
        activeSteamReferenceRefreshToken == token &&
            !invalidatedSteamReferenceRefreshIDs.contains(token.id)
    }

    func endSteamReferenceRefresh(_ token: SteamReferenceRefreshToken) {
        steamPrefixLifecycleCoordinator.end(token.lifecycleToken)
        invalidatedSteamReferenceRefreshIDs.remove(token.id)
        guard activeSteamReferenceRefreshToken == token else { return }
        activeSteamReferenceRefreshToken = nil
        isSteamReferenceRefreshInProgress = false
    }

    func invalidateSteamReferenceRefresh() {
        guard let activeSteamReferenceRefreshToken else { return }
        invalidatedSteamReferenceRefreshIDs.insert(activeSteamReferenceRefreshToken.id)
    }

    @discardableResult
    func synchronizeSetupWorkflow(
        appState: AppState,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) -> SetupReadiness {
        setupWorkflowCoordinator.synchronizeReadiness(
            appState: appState,
            hasSteamReferences: hasSteamReferences,
            launchRecords: launchRecords
        )
    }

    func refreshSetupWorkflow(
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) async throws -> SetupWorkflowRefreshResult {
        let activation = try await prepareManagedStorageOnce(appState: appState, in: context)
        return await setupWorkflowCoordinator.refresh(
            storageActivation: activation,
            appState: appState,
            hasSteamReferences: hasSteamReferences,
            launchRecords: launchRecords
        )
    }

    func prepareManagedStorageOnce(
        appState: AppState,
        in context: ModelContext
    ) async throws -> ManagedStorageActivationResult {
        if let completedManagedStorageActivation {
            managedStoragePreparationState = .ready(completedManagedStorageActivation.rootURL)
            return completedManagedStorageActivation
        }
        if let managedStoragePreparationTask {
            return try await managedStoragePreparationTask.value
        }

        managedStoragePreparationState = .preparing
        let task = Task { @MainActor in
            let lifecycleToken = try self.steamPrefixLifecycleCoordinator.begin(.managedStorageTransition)
            defer { self.steamPrefixLifecycleCoordinator.end(lifecycleToken) }
            try appState.loadIfNeeded(from: context)
            let request = try self.managedStorageStartupRequest(
                appState: appState,
                in: context
            )
            let ownershipCandidates = Self.deduplicated(
                [request.legacySource, request.destination].compactMap { $0 }
            )
            let ownershipPathsBeforeTransition = self.runtimeOwnershipPaths(
                forManagedRoots: ownershipCandidates
            )
            do {
                if let legacyRoot = request.legacySource,
                   legacyRoot.path != request.destination.path {
                    _ = try await self.shutdownSteamProcessesBeforeRootChange(
                        from: legacyRoot,
                        runtimeExecutable: appState.runtimeExecutableURL
                    )
                }
                _ = try await self.shutdownSteamProcessesBeforeRootChange(
                    from: request.destination,
                    runtimeExecutable: appState.runtimeExecutableURL
                )
                var activation = try await self.managedStorageService.activate(
                    in: context,
                    legacyRootURL: request.legacySource,
                    managedRootURLOverride: request.destination,
                    managedRootBookmark: request.destinationBookmark
                )
                if let legacyRoot = request.legacySource,
                   legacyRoot.path != request.destination.path {
                    self.steamPrefixService.releaseRuntimeOwnership(forManagedRoot: legacyRoot)
                }
                var postCommitWarnings: [String] = []
                do {
                    try appState.load(from: context)
                } catch {
                    appState.setPersistedFileSelection(
                        activation.rootURL,
                        for: .selectedRoot,
                        requiresBookmarkReplacement: false
                    )
                    postCommitWarnings.append(forgePlayTechnicalErrorSummary(error))
                }
                do {
                    _ = try context.reconcileAbandonedSteamLaunchRecords(
                        currentAppSessionID: self.appSessionID
                    )
                } catch {
                    postCommitWarnings.append(forgePlayTechnicalErrorSummary(error))
                }
                activation = self.activation(
                    activation,
                    appendingPostCommitWarnings: postCommitWarnings
                )
                return activation
            } catch {
                self.releaseRuntimeOwnershipClaimedDuringTransition(
                    forManagedRoots: ownershipCandidates,
                    preserving: ownershipPathsBeforeTransition
                )
                throw error
            }
        }
        managedStoragePreparationTask = task

        do {
            let result = try await task.value
            completedManagedStorageActivation = result
            managedStoragePreparationTask = nil
            managedStoragePreparationState = .ready(result.rootURL)
            return result
        } catch {
            managedStoragePreparationTask = nil
            switch error {
            case ManagedStorageActivationError.legacyMigrationDecisionRequired(let path):
                managedStoragePreparationState = .legacyMigrationDecisionRequired(path)
            case ManagedStorageActivationError.legacyRootAuthorizationRequired(let path),
                 ManagedStorageActivationError.managedRootAuthorizationRequired(let path):
                managedStoragePreparationState = .authorizationRequired(path)
            case ManagedStorageActivationError.managedRootBookmarkRequired(let url):
                managedStoragePreparationState = .authorizationRequired(url.path)
            default:
                managedStoragePreparationState = .failed(appState.localizedError(error))
            }
            throw error
        }
    }

    func migratePersistedLegacyManagedStorage(
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) async throws -> SetupWorkflowRefreshResult {
        guard case .legacyMigrationDecisionRequired(let sourcePath) = managedStoragePreparationState else {
            throw ManagedStorageWorkflowError.legacyMigrationDecisionUnavailable
        }
        approvedLegacyMigrationSourcePath = sourcePath
        defer { approvedLegacyMigrationSourcePath = nil }
        return try await refreshSetupWorkflow(
            appState: appState,
            in: context,
            hasSteamReferences: hasSteamReferences,
            launchRecords: launchRecords
        )
    }

    func startFreshWithDefaultManagedStorage(
        appState: AppState,
        in context: ModelContext
    ) async throws -> SetupWorkflowRefreshResult {
        guard !isManagedStorageTransitionInProgress,
              managedStoragePreparationTask == nil else {
            throw ManagedStorageWorkflowError.transitionInProgress
        }
        isManagedStorageTransitionInProgress = true
        defer { isManagedStorageTransitionInProgress = false }

        let lifecycleToken = try steamPrefixLifecycleCoordinator.begin(.managedStorageTransition)
        defer { steamPrefixLifecycleCoordinator.end(lifecycleToken) }
        try appState.loadIfNeeded(from: context)
        let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
        let previousManagedRoot = (pathManager.rootURL ?? appState.selectedRootURL)?.standardizedFileURL
        let ownershipCandidates = Self.deduplicated(
            [previousManagedRoot, defaultManagedRoot].compactMap { $0 }
        )
        let ownershipPathsBeforeTransition = runtimeOwnershipPaths(
            forManagedRoots: ownershipCandidates
        )
        let managedRootLeases: [ManagedRootOperationLease]
        do {
            managedRootLeases = try ManagedRootOperationLease.acquireExclusive(
                forManagedRoots: [previousManagedRoot, defaultManagedRoot].compactMap { $0 }
            )
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        defer { managedRootLeases.reversed().forEach { $0.release() } }

        managedStoragePreparationState = .preparing
        do {
            invalidateSteamReferenceRefresh()
            if let previousManagedRoot,
               previousManagedRoot.path != defaultManagedRoot.path {
                _ = try await shutdownSteamProcessesBeforeRootChange(
                    from: previousManagedRoot,
                    runtimeExecutable: appState.runtimeExecutableURL
                )
            }
            _ = try await shutdownSteamProcessesBeforeRootChange(
                from: defaultManagedRoot,
                runtimeExecutable: appState.runtimeExecutableURL
            )

            _ = try setupResetService.startFreshWithDefaultManagedStorage(
                appState: appState,
                in: context
            )
            if let previousManagedRoot,
               previousManagedRoot.path != defaultManagedRoot.path {
                steamPrefixService.releaseRuntimeOwnership(forManagedRoot: previousManagedRoot)
            }
            try appState.load(from: context)

            let activation = ManagedStorageActivationResult(
                rootURL: defaultManagedRoot,
                migratedFromURL: nil,
                copiedFiles: 0,
                copiedBytes: 0
            )
            managedStoragePreparationTask = nil
            completedManagedStorageActivation = activation
            managedStoragePreparationState = .ready(defaultManagedRoot)
            setupWorkflowCoordinator.invalidateSystemCheck()
            notifySteamEnvironmentChanged()
            return await setupWorkflowCoordinator.refresh(
                storageActivation: activation,
                appState: appState,
                hasSteamReferences: false,
                launchRecords: []
            )
        } catch {
            releaseRuntimeOwnershipClaimedDuringTransition(
                forManagedRoots: ownershipCandidates,
                preserving: ownershipPathsBeforeTransition
            )
            managedStoragePreparationTask = nil
            completedManagedStorageActivation = nil
            managedStoragePreparationState = .failed(appState.localizedError(error))
            throw error
        }
    }

    func resetSetupProgress(
        appState: AppState,
        in context: ModelContext
    ) async throws -> SetupResetResult {
        let lifecycleToken = try steamPrefixLifecycleCoordinator.begin(.maintenance)
        defer { steamPrefixLifecycleCoordinator.end(lifecycleToken) }

        try appState.loadIfNeeded(from: context)
        let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
        let managedRoot = (pathManager.rootURL ?? appState.selectedRootURL)?.standardizedFileURL ?? defaultManagedRoot
        let managedRootLeases: [ManagedRootOperationLease]
        do {
            managedRootLeases = try ManagedRootOperationLease.acquireExclusive(
                forManagedRoots: [managedRoot]
            )
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        defer { managedRootLeases.reversed().forEach { $0.release() } }

        invalidateSteamReferenceRefresh()
        _ = try await shutdownSteamProcessesBeforeRootChange(
            from: managedRoot,
            runtimeExecutable: appState.runtimeExecutableURL
        )
        return try setupResetService.resetSetupProgress(appState: appState, in: context)
    }

    func relocateManagedStorage(
        to destinationURL: URL,
        destinationBookmark: Data?,
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) async throws -> SetupWorkflowRefreshResult {
        guard !isManagedStorageTransitionInProgress else {
            throw ManagedStorageWorkflowError.transitionInProgress
        }
        isManagedStorageTransitionInProgress = true
        defer { isManagedStorageTransitionInProgress = false }

        let currentActivation = try await prepareManagedStorageOnce(
            appState: appState,
            in: context
        )
        let source = currentActivation.rootURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }
        let lifecycleToken = try steamPrefixLifecycleCoordinator.begin(.managedStorageTransition)
        defer { steamPrefixLifecycleCoordinator.end(lifecycleToken) }
        let ownershipCandidates = Self.deduplicated([source, destination])
        let ownershipPathsBeforeTransition = runtimeOwnershipPaths(
            forManagedRoots: ownershipCandidates
        )

        let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
        let needsSecurityScope = ForgePlaySandboxPolicy.isAppSandboxEnabled &&
            destination.path != defaultManagedRoot.path
        let didStartSecurityScope = destination.startAccessingSecurityScopedResource()
        if needsSecurityScope, !didStartSecurityScope {
            throw ManagedStorageActivationError.managedRootBookmarkRequired(destination)
        }
        defer {
            if didStartSecurityScope {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        try storageMigrationService.validateCurrentRelocationPreflight(
            from: source,
            to: destination
        )

        managedStoragePreparationState = .relocating(from: source, to: destination)
        do {
            _ = try await shutdownSteamProcessesBeforeRootChange(
                from: source,
                runtimeExecutable: appState.runtimeExecutableURL
            )
            _ = try await shutdownSteamProcessesBeforeRootChange(
                from: destination,
                runtimeExecutable: appState.runtimeExecutableURL
            )
            var activation = try await managedStorageService.relocate(
                in: context,
                from: source,
                to: destination,
                destinationBookmark: destinationBookmark
            )
            steamPrefixService.releaseRuntimeOwnership(forManagedRoot: source)

            managedStoragePreparationTask = nil
            setupWorkflowCoordinator.invalidateSystemCheck()
            var postCommitWarnings: [String] = []
            do {
                try appState.load(from: context)
            } catch {
                appState.setPersistedFileSelection(
                    activation.rootURL,
                    for: .selectedRoot,
                    requiresBookmarkReplacement: false
                )
                postCommitWarnings.append(forgePlayTechnicalErrorSummary(error))
            }
            do {
                _ = try context.reconcileAbandonedSteamLaunchRecords(
                    currentAppSessionID: appSessionID
                )
            } catch {
                postCommitWarnings.append(forgePlayTechnicalErrorSummary(error))
            }
            activation = self.activation(
                activation,
                appendingPostCommitWarnings: postCommitWarnings
            )
            completedManagedStorageActivation = activation
            managedStoragePreparationState = .ready(activation.rootURL)
            notifySteamEnvironmentChanged()
            return await setupWorkflowCoordinator.refresh(
                storageActivation: activation,
                appState: appState,
                hasSteamReferences: hasSteamReferences,
                launchRecords: launchRecords
            )
        } catch {
            releaseRuntimeOwnershipClaimedDuringTransition(
                forManagedRoots: ownershipCandidates,
                preserving: ownershipPathsBeforeTransition
            )
            if pathManager.rootURL?.standardizedFileURL.path == source.path {
                managedStoragePreparationState = .ready(source)
            } else {
                completedManagedStorageActivation = nil
                managedStoragePreparationState = .failed(appState.localizedError(error))
            }
            throw error
        }
    }

    func importLegacyManagedStorage(
        from sourceURL: URL,
        sourceBookmark: Data?,
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) async throws -> SetupWorkflowRefreshResult {
        guard !isManagedStorageTransitionInProgress else {
            throw ManagedStorageWorkflowError.transitionInProgress
        }
        isManagedStorageTransitionInProgress = true
        defer { isManagedStorageTransitionInProgress = false }

        let currentActivation = try await prepareManagedStorageOnce(
            appState: appState,
            in: context
        )
        let source = sourceURL.standardizedFileURL
        let destination = currentActivation.rootURL.standardizedFileURL
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }
        let lifecycleToken = try steamPrefixLifecycleCoordinator.begin(.managedStorageTransition)
        defer { steamPrefixLifecycleCoordinator.end(lifecycleToken) }
        let ownershipCandidates = Self.deduplicated([source, destination])
        let ownershipPathsBeforeTransition = runtimeOwnershipPaths(
            forManagedRoots: ownershipCandidates
        )

        let needsSecurityScope = ForgePlaySandboxPolicy.isAppSandboxEnabled
        if needsSecurityScope, sourceBookmark == nil {
            throw ManagedStorageActivationError.legacyRootAuthorizationRequired(source.path)
        }
        let didStartSecurityScope = source.startAccessingSecurityScopedResource()
        if needsSecurityScope, !didStartSecurityScope {
            throw ManagedStorageActivationError.legacyRootAuthorizationRequired(source.path)
        }
        defer {
            if didStartSecurityScope {
                source.stopAccessingSecurityScopedResource()
            }
        }

        managedStoragePreparationState = .importing(from: source, to: destination)
        do {
            _ = try await shutdownSteamProcessesBeforeRootChange(
                from: destination,
                runtimeExecutable: appState.runtimeExecutableURL
            )
            _ = try await shutdownSteamProcessesBeforeRootChange(
                from: source,
                runtimeExecutable: appState.runtimeExecutableURL
            )
            var activation = try await managedStorageService.importLegacyManagedData(
                in: context,
                from: source,
                to: destination,
                sourceBookmark: sourceBookmark
            )
            steamPrefixService.releaseRuntimeOwnership(forManagedRoot: source)

            managedStoragePreparationTask = nil
            setupWorkflowCoordinator.invalidateSystemCheck()
            var postCommitWarnings: [String] = []
            do {
                try appState.load(from: context)
            } catch {
                appState.activateManagedRoot(activation.rootURL)
                postCommitWarnings.append(forgePlayTechnicalErrorSummary(error))
            }
            do {
                _ = try context.reconcileAbandonedSteamLaunchRecords(
                    currentAppSessionID: appSessionID
                )
            } catch {
                postCommitWarnings.append(forgePlayTechnicalErrorSummary(error))
            }
            activation = self.activation(
                activation,
                appendingPostCommitWarnings: postCommitWarnings
            )
            completedManagedStorageActivation = activation
            managedStoragePreparationState = .ready(activation.rootURL)
            notifySteamEnvironmentChanged()
            return await setupWorkflowCoordinator.refresh(
                storageActivation: activation,
                appState: appState,
                hasSteamReferences: hasSteamReferences,
                launchRecords: launchRecords
            )
        } catch {
            releaseRuntimeOwnershipClaimedDuringTransition(
                forManagedRoots: ownershipCandidates,
                preserving: ownershipPathsBeforeTransition
            )
            if pathManager.rootURL?.standardizedFileURL.path == destination.path {
                managedStoragePreparationState = .ready(destination)
            } else {
                completedManagedStorageActivation = nil
                managedStoragePreparationState = .failed(appState.localizedError(error))
            }
            throw error
        }
    }

    private func managedStorageStartupRequest(
        appState: AppState,
        in context: ModelContext
    ) throws -> ManagedStorageStartupRequest {
        let settings = try appState.loadOrCreateSettings(in: context)
        let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
        return try ManagedStorageStartupRequest.resolve(
            layoutVersion: settings.managedStorageLayoutVersion,
            persistedRootPath: settings.selectedRootPath,
            persistedRootBookmark: settings.selectedRootBookmark,
            selectedRootURL: appState.selectedRootURL,
            defaultManagedRoot: defaultManagedRoot,
            approvedLegacyMigrationSourcePath: approvedLegacyMigrationSourcePath
        )
    }

    private func activation(
        _ activation: ManagedStorageActivationResult,
        appendingPostCommitWarnings warnings: [String]
    ) -> ManagedStorageActivationResult {
        guard !warnings.isEmpty else { return activation }
        var updated = activation
        updated.postCommitWarning = warnings.joined(separator: " | ")
        return updated
    }

    private func runtimeOwnershipPaths(forManagedRoots roots: [URL]) -> Set<String> {
        Set(roots.compactMap { root in
            steamPrefixService.hasRuntimeOwnership(forManagedRoot: root)
                ? root.standardizedFileURL.path
                : nil
        })
    }

    private func releaseRuntimeOwnershipClaimedDuringTransition(
        forManagedRoots roots: [URL],
        preserving previouslyOwnedPaths: Set<String>
    ) {
        for root in roots where !previouslyOwnedPaths.contains(root.standardizedFileURL.path) {
            steamPrefixService.releaseRuntimeOwnership(forManagedRoot: root)
        }
    }

    func prepareSteamPrefix(
        runtimeExecutable: URL,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> PrefixPreparationResult {
        _ = try steamSharedPrefixURL()
        _ = try await windowsRuntimeService.probeAndValidate(
            executable: runtimeExecutable,
            requiresModernGraphicsBackend: false
        )
        let result = try await steamPrefixService.prepareSharedPrefix(
            runtimeExecutable: runtimeExecutable,
            synchronizationSelection: synchronizationSelection
        )
        steamEnvironmentRevision += 1
        return result
    }

    func rebuildSteamSharedPrefix(
        runtimeExecutable: URL,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> PrefixRebuildResult {
        _ = try steamSharedPrefixURL()
        _ = try await windowsRuntimeService.probeAndValidate(
            executable: runtimeExecutable,
            requiresModernGraphicsBackend: false
        )
        let result = try await steamPrefixService.rebuildSharedPrefix(
            runtimeExecutable: runtimeExecutable,
            synchronizationSelection: synchronizationSelection
        )
        steamEnvironmentRevision += 1
        return result
    }

    func validateSteamInstaller(_ installer: URL) -> Bool {
        steamPrefixService.validateSteamInstaller(installer)
    }

    func installSteamInSteamPrefix(
        runtimeExecutable: URL,
        installer: URL,
        videoMemorySelection: SteamVideoMemorySelection = .automatic,
        synchronizationSelection: WineSynchronizationSelection = .automatic
    ) async throws -> SteamInstallResult {
        _ = try steamSharedPrefixURL()
        _ = try await windowsRuntimeService.probeAndValidate(
            executable: runtimeExecutable,
            requiresModernGraphicsBackend: false
        )
        let result = try await steamPrefixService.installSteam(
            runtimeExecutable: runtimeExecutable,
            installer: installer,
            videoMemorySelection: videoMemorySelection,
            synchronizationSelection: synchronizationSelection
        )
        steamEnvironmentRevision += 1
        return result
    }

    func shutdownSteamProcessesForAppTermination(
        runtimeExecutable: URL?,
        selectedRootURL: URL? = nil,
        additionalManagedRoots: [URL] = [],
        includeDefaultApplicationSupportRoot: Bool = false,
        fileManager: FileManager = .default
    ) async -> AppTerminationSteamShutdownSummary {
        let plan = appTerminationSteamShutdownPlan(
            runtimeExecutable: runtimeExecutable,
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot: includeDefaultApplicationSupportRoot,
            fileManager: fileManager
        )
        return await Self.executeAppTerminationSteamShutdown(
            plan,
            safeProcessRunner: safeProcessRunner
        )
    }

    func shutdownSteamProcessesBeforeRootChange(
        from root: URL,
        runtimeExecutable _: URL?,
        fileManager: FileManager = .default
    ) async throws -> AppTerminationSteamShutdownSummary {
        try steamPrefixLifecycleCoordinator.checkpoint()
        guard !steamPrefixLifecycleCoordinator.isBusy ||
                steamPrefixLifecycleCoordinator.activeOperation == .managedStorageTransition ||
                steamPrefixLifecycleCoordinator.activeOperation == .maintenance else {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        do {
            try steamPrefixService.claimRuntimeOwnership(forManagedRoot: root)
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        let prefix = Self.steamSharedPrefix(in: root)
        guard FileSystemItemPolicy.isNonSymlinkDirectory(prefix, fileManager: fileManager) else {
            return AppTerminationSteamShutdownSummary(
                prefix: nil,
                prefixes: [],
                attemptedRuntimePath: nil,
                results: [],
                errors: [],
                skippedReason: "the previous root has no SteamShared prefix"
            )
        }
        if try prefixManager.isUninitializedPrefixPlaceholder(at: prefix) {
            return AppTerminationSteamShutdownSummary(
                prefix: nil,
                prefixes: [],
                attemptedRuntimePath: nil,
                results: [],
                errors: [],
                skippedReason: "the previous root has only an uninitialized SteamShared placeholder"
            )
        }
        var activityInspectionWarnings: [String] = []
        if !ForgePlaySandboxPolicy.isAppSandboxEnabled {
            do {
                let hasActiveProcess = try await safeProcessRunner.hasManagedPrefixActivity(prefix)
                if !hasActiveProcess {
                    return AppTerminationSteamShutdownSummary(
                        prefix: nil,
                        prefixes: [],
                        attemptedRuntimePath: nil,
                        results: [],
                        errors: [],
                        skippedReason: "the previous root has no active Steam or Wine process"
                    )
                }
            } catch {
                activityInspectionWarnings.append(
                    "could not inspect active Steam or Wine processes before root change: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        let bundledRuntime = appTerminationShutdownRuntime(fileManager: fileManager)
        let plan = AppTerminationSteamShutdownPlan(
            prefixes: [prefix],
            runtimeExecutable: bundledRuntime,
            initialErrors: bundledRuntime == nil
                ? ["the bundled ForgePlay Runtime is unavailable before root change"]
                : [],
            initialWarnings: activityInspectionWarnings,
            skippedReason: nil
        )
        let summary = await Self.executeAppTerminationSteamShutdown(
            plan,
            safeProcessRunner: safeProcessRunner
        )
        guard summary.succeeded else {
            throw SteamPrefixLifecycleCleanupError(
                originalDescription: "ForgePlay storage root change could not stop the previous Steam environment",
                cleanupDescription: summary.diagnosticDescription,
                cleanupProcessResults: summary.results
            )
        }
        return summary
    }

    func appTerminationSteamShutdownPlan(
        runtimeExecutable _: URL?,
        selectedRootURL: URL? = nil,
        additionalManagedRoots: [URL] = [],
        includeDefaultApplicationSupportRoot: Bool = false,
        fileManager: FileManager = .default
    ) -> AppTerminationSteamShutdownPlan {
        guard steamPrefixLifecycleCoordinator.beginApplicationTermination() else {
            let operation = steamPrefixLifecycleCoordinator.activeOperation?.rawValue ?? "unknown"
            return AppTerminationSteamShutdownPlan(
                prefixes: [],
                runtimeExecutable: nil,
                initialErrors: ["Steam Prefix operation is still active during termination: \(operation)"],
                skippedReason: nil
            )
        }
        let candidatePrefixes = appTerminationSteamSharedPrefixes(
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot: includeDefaultApplicationSupportRoot,
            fileManager: fileManager
        )
        var prefixes: [URL] = []
        var ownershipErrors: [String] = []
        var ownershipWarnings: [String] = []
        for prefix in candidatePrefixes {
            let managedRoot = prefix.deletingLastPathComponent().deletingLastPathComponent()
            do {
                try steamPrefixService.claimRuntimeOwnership(forManagedRoot: managedRoot)
                prefixes.append(prefix)
            } catch ManagedRootOperationLeaseError.operationInProgress {
                ownershipWarnings.append(
                    "skipped prefix owned by another ForgePlay process: \(prefix.path)"
                )
            } catch {
                ownershipErrors.append(
                    "could not establish runtime ownership for \(prefix.path): " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        guard !prefixes.isEmpty else {
            return AppTerminationSteamShutdownPlan(
                prefixes: [],
                runtimeExecutable: nil,
                initialErrors: ownershipErrors,
                initialWarnings: ownershipWarnings,
                skippedReason: candidatePrefixes.isEmpty
                    ? "no configured SteamShared prefix exists"
                    : "no SteamShared prefix owned by this ForgePlay process"
            )
        }

        let bundledRuntime = appTerminationShutdownRuntime(fileManager: fileManager)
        guard let bundledRuntime else {
            return AppTerminationSteamShutdownPlan(
                prefixes: prefixes,
                runtimeExecutable: nil,
                initialErrors: ownershipErrors + [
                    "the bundled ForgePlay Runtime is unavailable for termination cleanup"
                ],
                initialWarnings: ownershipWarnings,
                skippedReason: nil
            )
        }

        return AppTerminationSteamShutdownPlan(
            prefixes: prefixes,
            runtimeExecutable: bundledRuntime,
            initialErrors: ownershipErrors,
            initialWarnings: ownershipWarnings,
            skippedReason: nil
        )
    }

    nonisolated static func executeAppTerminationSteamShutdown(
        _ plan: AppTerminationSteamShutdownPlan,
        safeProcessRunner: SafeProcessRunner
    ) async -> AppTerminationSteamShutdownSummary {
        let fileManager = FileManager.default
        guard !plan.prefixes.isEmpty else {
            return AppTerminationSteamShutdownSummary(
                prefix: nil,
                prefixes: [],
                attemptedRuntimePath: nil,
                results: [],
                errors: plan.initialErrors,
                warnings: plan.initialWarnings,
                skippedReason: plan.skippedReason
            )
        }
        guard let runtimeExecutable = plan.runtimeExecutable else {
            return AppTerminationSteamShutdownSummary(
                prefix: plan.prefixes.first,
                prefixes: plan.prefixes,
                attemptedRuntimePath: nil,
                results: [],
                errors: plan.initialErrors,
                warnings: plan.initialWarnings,
                skippedReason: plan.skippedReason
            )
        }

        var results: [ProcessRunResult] = []
        var errors = plan.initialErrors
        var warnings = plan.initialWarnings
        for prefix in plan.prefixes {
            // A prefix retained by ManagedWineSessionRegistry can belong to an
            // external root that is no longer the current selected root. Give
            // a security-scoped URL one last chance to reactivate its access
            // for the complete shutdown attempt. Internal URLs normally
            // return false here and need no matching stop call.
            let managedRoot = prefix
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let didStartManagedRootSecurityScope =
                managedRoot.startAccessingSecurityScopedResource()
            defer {
                if didStartManagedRootSecurityScope {
                    managedRoot.stopAccessingSecurityScopedResource()
                }
            }
            var logDirectory = Self.appTerminationLaunchLogDirectory(for: prefix)
            do {
                try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            } catch {
                let primaryError = forgePlayTechnicalErrorSummary(error)
                logDirectory = fileManager.temporaryDirectory
                    .appending(path: "ForgePlayTerminationLogs", directoryHint: .isDirectory)
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                do {
                    try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
                    warnings.append(
                        "\(prefix.path) launch log directory is unavailable; using emergency logs at " +
                            "\(logDirectory.path): \(primaryError)"
                    )
                } catch {
                    errors.append(
                        "\(prefix.path) launch and emergency log directories are unavailable: " +
                            "\(primaryError) | \(forgePlayTechnicalErrorSummary(error))"
                    )
                    continue
                }
            }
            var prefixCleanupErrors: [String] = []
            var didCleanPrefix = false
            let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
            var shouldRequestGracefulShutdown = false
            if FileSystemItemPolicy.isRegularNonSymlinkFile(steamExecutable, fileManager: fileManager) {
                do {
                    shouldRequestGracefulShutdown = try await safeProcessRunner
                        .hasManagedPrefixActivity(prefix)
                } catch {
                    warnings.append(
                        "\(prefix.path) active process inspection before graceful shutdown: " +
                            forgePlayTechnicalErrorSummary(error)
                    )
                }
            }
            if shouldRequestGracefulShutdown {
                do {
                    let gracefulResult = try await safeProcessRunner.run(.requestSteamClientShutdown(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        steamExecutable: steamExecutable,
                        logDirectory: logDirectory
                    ))
                    results.append(gracefulResult)
                    if !gracefulResult.succeeded {
                        warnings.append(
                            "\(prefix.path) Steam graceful shutdown process exit \(gracefulResult.diagnosticExitCodeDescription), " +
                                "ForgePlay status \(gracefulResult.diagnosticForgePlayStatusDescription)"
                        )
                    } else {
                        do {
                            let didDrain = try await safeProcessRunner.waitForManagedPrefixProcessesToExit(
                                prefix,
                                timeout: 2
                            )
                            if !didDrain {
                                warnings.append(
                                    "\(prefix.path) Steam did not drain within the graceful shutdown interval"
                                )
                            }
                        } catch {
                            warnings.append(
                                "\(prefix.path) graceful shutdown drain verification: " +
                                    forgePlayTechnicalErrorSummary(error)
                            )
                        }
                    }
                } catch {
                    if let diagnosticResult = diagnosticProcessRunResult(from: error) {
                        results.append(diagnosticResult)
                    }
                    warnings.append(
                        "\(prefix.path) Steam graceful shutdown: \(forgePlayTechnicalErrorSummary(error))"
                    )
                }
            }
            do {
                let result = try await safeProcessRunner.run(.shutdownWinePrefix(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                ))
                results.append(result)
                if !result.succeeded {
                    prefixCleanupErrors.append(
                        "\(prefix.path) \(runtimeExecutable.path) processExit \(result.diagnosticExitCodeDescription), " +
                            "forgePlayStatus \(result.diagnosticForgePlayStatusDescription)"
                    )
                } else {
                    do {
                        // The native Game Mode host inherits a shared execution
                        // lease independently of wineserver. Reacquiring the
                        // exclusive lease proves that no ForgePlay-owned host
                        // survived the shutdown sequence.
                        let verificationLease = try PrefixExecutionLease
                            .acquireExclusiveMutation(forPrefix: prefix)
                        verificationLease.release()
                        didCleanPrefix = true
                    } catch {
                        prefixCleanupErrors.append(
                            "\(prefix.path) Game Mode host lease verification: " +
                                forgePlayTechnicalErrorSummary(error)
                        )
                    }
                }
            } catch {
                if let diagnosticResult = diagnosticProcessRunResult(from: error) {
                    results.append(diagnosticResult)
                }
                prefixCleanupErrors.append(
                    "\(prefix.path) \(runtimeExecutable.path): \(forgePlayTechnicalErrorSummary(error))"
                )
            }
            if !didCleanPrefix {
                errors.append(contentsOf: prefixCleanupErrors)
            }
        }

        return AppTerminationSteamShutdownSummary(
            prefix: plan.prefixes.first,
            prefixes: plan.prefixes,
            attemptedRuntimePath: runtimeExecutable.path,
            results: results,
            errors: errors,
            warnings: warnings,
            skippedReason: plan.skippedReason
        )
    }

    private func appTerminationShutdownRuntime(
        fileManager: FileManager
    ) -> URL? {
        guard let bundledRuntime = ForgePlayBundledWindowsRuntimePolicy
            .bundledRuntimeExecutableURL(fileManager: fileManager),
              FileSystemItemPolicy.isRegularNonSymlinkFile(
                bundledRuntime,
                fileManager: fileManager
              ),
              fileManager.isExecutableFile(atPath: bundledRuntime.path) else {
            return nil
        }
        return bundledRuntime.standardizedFileURL
    }

    private func appTerminationSteamSharedPrefixes(
        selectedRootURL: URL?,
        additionalManagedRoots: [URL],
        includeDefaultApplicationSupportRoot: Bool,
        fileManager: FileManager
    ) -> [URL] {
        // Prefixes recorded by the process runner or an active lifecycle
        // operation are authoritative session targets. Keep them even when an
        // external volume is temporarily unavailable or its directory cannot
        // currently be inspected; dropping them here would falsely turn a
        // required cleanup into a successful "nothing to do" skip.
        let retainedSessionPrefixes = Self.deduplicated(
            managedWineSessionRegistry.prefixURLs +
                steamPrefixLifecycleCoordinator.activeManagedPrefixURLs
        )
        let retainedSessionPaths = Set(retainedSessionPrefixes.map {
            $0.standardizedFileURL.path
        })

        var candidates: [URL] = []
        if let pathManagerPrefix = try? steamSharedPrefixURL() {
            candidates.append(pathManagerPrefix)
        }
        candidates.append(contentsOf: retainedSessionPrefixes)
        if let selectedRootURL {
            candidates.append(Self.steamSharedPrefix(in: selectedRootURL))
        }
        candidates.append(contentsOf: additionalManagedRoots.map(Self.steamSharedPrefix(in:)))
        if includeDefaultApplicationSupportRoot,
           let defaultRoot = Self.defaultApplicationSupportManagedRoot(fileManager: fileManager) {
            candidates.append(Self.steamSharedPrefix(in: defaultRoot))
        }
        return Self.deduplicated(candidates).filter {
            retainedSessionPaths.contains($0.standardizedFileURL.path) ||
                FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
        }
    }

    private nonisolated static func steamSharedPrefix(in managedRoot: URL) -> URL {
        managedRoot.standardizedFileURL
            .appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue, directoryHint: .isDirectory)
    }

    nonisolated static func appTerminationLaunchLogDirectory(for prefix: URL) -> URL {
        prefix
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
    }

    private nonisolated static func defaultApplicationSupportManagedRoot(fileManager: FileManager) -> URL? {
        try? PathManager.defaultManagedRootURL(fileManager: fileManager)
    }

    private nonisolated static func deduplicated(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for value in values {
            let path = value.standardizedFileURL.path
            if seen.insert(path).inserted {
                output.append(value.standardizedFileURL)
            }
        }
        return output
    }

    nonisolated static func compatibilityDBPublicKeyConfiguration(
        infoDictionaryValue: String? = Bundle.main.object(
            forInfoDictionaryKey: "ForgePlayCompatibilityDBPublicKeyBase64"
        ) as? String,
        resourceURL: URL? = Bundle.main.url(forResource: "CompatibilityDBPublicKey", withExtension: "base64"),
        readResourceText: (URL) throws -> String = { url in
            try AppServices.readCompatibilityDBPublicKeyResourceText(url)
        }
    ) -> CompatibilityDBSignatureVerifierConfiguration {
        if let value = infoDictionaryValue {
            return compatibilityDBPublicKeyConfiguration(
                fromBase64: value,
                sourceDescription: "Info.plist ForgePlayCompatibilityDBPublicKeyBase64"
            )
        }
        guard let resourceURL else {
            return .missing
        }
        do {
            let text = try readResourceText(resourceURL)
            return compatibilityDBPublicKeyConfiguration(
                fromBase64: text,
                sourceDescription: "Resources/CompatibilityDBPublicKey.base64"
            )
        } catch {
            return .invalid(
                "Resources/CompatibilityDBPublicKey.base64 could not be read: \(forgePlayTechnicalErrorSummary(error))"
            )
        }
    }

    nonisolated static func readCompatibilityDBPublicKeyResourceText(_ url: URL) throws -> String {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey, .fileSizeKey]
            )
        } catch {
            throw CompatibilityDBPublicKeyResourceError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true,
              (values.linkCount ?? 1) == 1 else {
            throw CompatibilityDBPublicKeyResourceError.unsafeResource(url)
        }
        guard let fileSize = values.fileSize else {
            throw CompatibilityDBPublicKeyResourceError.metadataReadFailed(url, "missing file size")
        }
        guard fileSize <= maxCompatibilityDBPublicKeyResourceBytes else {
            throw CompatibilityDBPublicKeyResourceError.oversized(url, fileSize, maxCompatibilityDBPublicKeyResourceBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CompatibilityDBPublicKeyResourceError.readFailed(url, forgePlayTechnicalErrorSummary(error))
        }
        guard data.count <= maxCompatibilityDBPublicKeyResourceBytes else {
            throw CompatibilityDBPublicKeyResourceError.oversized(url, data.count, maxCompatibilityDBPublicKeyResourceBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CompatibilityDBPublicKeyResourceError.textDecodeFailed(url)
        }
        return text
    }

    private nonisolated static func compatibilityDBPublicKeyConfiguration(
        fromBase64 value: String,
        sourceDescription: String
    ) -> CompatibilityDBSignatureVerifierConfiguration {
        guard let data = validatedCompatibilityDBPublicKeyRawRepresentation(fromBase64: value) else {
            return .invalid("\(sourceDescription) is not a valid P-256 signing public key")
        }
        return .trustedPublicKey(data)
    }

    nonisolated static func validatedCompatibilityDBPublicKeyRawRepresentation(fromBase64 value: String) -> Data? {
        guard let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        do {
            _ = try P256.Signing.PublicKey(rawRepresentation: data)
            return data
        } catch {
            return nil
        }
    }

}

enum CompatibilityDBPublicKeyResourceError: LocalizedError {
    case unsafeResource(URL)
    case metadataReadFailed(URL, String)
    case readFailed(URL, String)
    case oversized(URL, Int, Int)
    case textDecodeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unsafeResource(let url):
            "Compatibility DB public key resource must be a non-symlink, non-hardlinked regular file: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "Compatibility DB public key resource metadata could not be read: \(url.path). \(message)"
        case .readFailed(let url, let message):
            "Compatibility DB public key resource could not be read: \(url.path). \(message)"
        case .oversized(let url, let byteCount, let limit):
            "Compatibility DB public key resource is too large: \(url.path) \(byteCount) bytes / limit \(limit) bytes"
        case .textDecodeFailed(let url):
            "Compatibility DB public key resource is not UTF-8 text: \(url.path)"
        }
    }
}
