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

typealias AppTerminationPrefixRestoration =
    @MainActor @Sendable (URL) async throws -> Void
typealias ForceWineProcessTerminator = @Sendable () async ->
    StartupWineProcessCleanupResult
typealias ForgePlayWineProcessInspector = @Sendable () ->
    StartupWineProcessCleanupPlan
typealias ManagedWindowsSteamActivityInspector = @Sendable (URL) async throws ->
    Bool

struct AppTerminationIntentGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isApplicationTerminationRequested = false

    mutating func beginApplicationTermination() {
        generation &+= 1
        isApplicationTerminationRequested = true
    }

    mutating func cancelApplicationTermination() {
        generation &+= 1
        isApplicationTerminationRequested = false
    }

    func temporaryForceStopResetTicket() -> UInt64? {
        isApplicationTerminationRequested ? nil : generation
    }

    func permitsTemporaryForceStopReset(ticket: UInt64?) -> Bool {
        guard let ticket else { return false }
        return !isApplicationTerminationRequested && ticket == generation
    }
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

struct SetupReadinessObservationKey: Equatable, Sendable {
    let environmentRevision: Int
    let hasSteamReferences: Bool
    let launchReadinessFingerprint:
        SteamLaunchRecordLookup.ReadinessFingerprint
    let selectedRootPath: String?
    let runtimeExecutablePath: String?
    let rendererSelection: String
    let videoMemorySelection: String
}

struct SetupWorkflowRequestTicket: Equatable, Sendable {
    let sequence: UInt64
}

struct SetupWorkflowRefreshAttemptGate {
    private(set) var latestTicket: SetupWorkflowRequestTicket?
    private(set) var activeTicket: SetupWorkflowRequestTicket?
    private var nextSequence: UInt64 = 0

    mutating func issue() -> SetupWorkflowRequestTicket {
        precondition(nextSequence < .max, "Setup workflow request ticket exhausted")
        nextSequence += 1
        let ticket = SetupWorkflowRequestTicket(sequence: nextSequence)
        latestTicket = ticket
        return ticket
    }

    func isLatest(_ ticket: SetupWorkflowRequestTicket) -> Bool {
        latestTicket == ticket
    }

    mutating func begin(_ ticket: SetupWorkflowRequestTicket) -> Bool {
        guard latestTicket == ticket else { return false }
        activeTicket = ticket
        return true
    }

    func permitsCommit(_ ticket: SetupWorkflowRequestTicket) -> Bool {
        latestTicket == ticket && activeTicket == ticket
    }

    @discardableResult
    mutating func finish(_ ticket: SetupWorkflowRequestTicket) -> Bool {
        guard activeTicket == ticket else { return false }
        activeTicket = nil
        return true
    }
}

enum SetupWorkflowRefreshControlError: Error, Equatable, Sendable {
    case superseded
}

enum SetupWorkflowRefreshRetryPolicy {
    static func shouldRetryAfterSupersession(outerTaskIsCancelled: Bool) -> Bool {
        !outerTaskIsCancelled
    }
}

@MainActor
final class SetupWorkflowRefreshWaiterRegistry<Value> {
    @MainActor
    private final class Delivery {
        let result: Result<Value, Error>

        init(result: Result<Value, Error>) {
            self.result = result
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Delivery, Never>
        let onFinalWaiterCancelled: @MainActor @Sendable () -> Void
    }

    private var waiters: [UUID: Waiter] = [:]

    var waiterCount: Int {
        waiters.count
    }

    func wait(
        onFinalWaiterCancelled: @escaping @MainActor @Sendable () -> Void
    ) async throws -> Value {
        let token = UUID()
        let delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[token] = Waiter(
                    continuation: continuation,
                    onFinalWaiterCancelled: onFinalWaiterCancelled
                )
                if Task.isCancelled {
                    cancelWaiter(token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(token)
            }
        }
        try Task.checkCancellation()
        return try delivery.result.get()
    }

    @discardableResult
    func complete(with result: Result<Value, Error>) -> Int {
        let registeredWaiters = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        let delivery = Delivery(result: result)
        for waiter in registeredWaiters {
            waiter.continuation.resume(returning: delivery)
        }
        return registeredWaiters.count
    }

    private func cancelWaiter(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        if waiters.isEmpty {
            waiter.onFinalWaiterCancelled()
        }
        waiter.continuation.resume(
            returning: Delivery(result: .failure(CancellationError()))
        )
    }
}

@MainActor
@Observable
final class AppServices {
    private struct ForceTerminatedWineQuiescenceProof: Sendable, Equatable {
        let lifecycleOperationGeneration: UInt64
    }

    private struct SetupWorkflowRefreshAttempt {
        let ticket: SetupWorkflowRequestTicket
        let key: SetupReadinessObservationKey
        let waiters: SetupWorkflowRefreshWaiterRegistry<SetupWorkflowRefreshResult>
        let task: Task<Void, Never>
    }

    private(set) var steamEnvironmentRevision = 0
    private(set) var gameInputProtectionAuthorizationRevision = 0
    private(set) var isManagedStorageTransitionInProgress = false
    private(set) var isSteamReferenceRefreshInProgress = false
    private(set) var managedStoragePreparationState: ManagedStoragePreparationState = .idle
    private(set) var fontCompatibilityPackActivationState:
        FontCompatibilityPackActivationState = .notAttempted
    @ObservationIgnored private var managedStoragePreparationTask: Task<ManagedStorageActivationResult, Error>?
    @ObservationIgnored private var cachedGameInputProtectionAuthorizationStatus:
        GameInputProtectionAuthorizationStatus?
    @ObservationIgnored private var gameInputPointerHideFailureSubscription:
        UUID?
    @ObservationIgnored private var completedManagedStorageActivation: ManagedStorageActivationResult?
    @ObservationIgnored private var approvedLegacyMigrationSourcePath: String?
    @ObservationIgnored private var activeSteamReferenceRefreshToken: SteamReferenceRefreshToken?
    @ObservationIgnored private var invalidatedSteamReferenceRefreshIDs: Set<UUID> = []
    @ObservationIgnored private var activeSetupWorkflowRefreshAttempt:
        SetupWorkflowRefreshAttempt?
    @ObservationIgnored private var setupWorkflowRefreshAttemptGate =
        SetupWorkflowRefreshAttemptGate()
    @ObservationIgnored private var applicationTerminationResetTask:
        Task<Void, Never>?
    @ObservationIgnored private var containmentDrainResetTask:
        Task<Void, Never>?
    @ObservationIgnored private var appTerminationIntentGate =
        AppTerminationIntentGate()
    @ObservationIgnored private var forceTerminatedWineQuiescenceProof:
        ForceTerminatedWineQuiescenceProof?
    @ObservationIgnored private var isForceWineTerminationInProgress = false
    let appSessionID: String
    let pathManager: PathManager
    let systemCheckService: SystemCheckService
    let managedWineSessionRegistry: ManagedWineSessionRegistry
    let safeProcessRunner: SafeProcessRunner
    let windowsRuntimeService: WindowsRuntimeService
    let prefixManager: PrefixManager
    let steamManager: SteamManager
    let gameInputProtectionPolicyStore: GameInputProtectionPolicyStore
    let gameInputProtectionAuthorization: GameInputProtectionAuthorization
    let awdlControlService: AWDLControlService
    let runtimeManager: RuntimeManager
    let ruleEngine: RuleEngine
    let compatibilityService: CompatibilityService
    let redactor: Redactor
    let failureDiagnosticEvidenceService: FailureDiagnosticEvidenceService
    let llmService: LLMService
    let fontCompatibilityPackService: FontCompatibilityPackService
    let controllerCompatibilityPreflightService: ControllerCompatibilityPreflightService
    let autoFixService: AutoFixService
    let supportBundleService: SupportBundleService
    let compatibilityCatalogRepository: CompatibilityCatalogRepository
    let compatibilityDBUpdateService: CompatibilityDBUpdateService
    let logRetentionService: LogRetentionService
    let storageMigrationService: StorageMigrationService
    let managedStorageService: ManagedStorageService
    let setupResetService: SetupResetService
    let steamPrefixLifecycleCoordinator: SteamPrefixLifecycleCoordinator
    let steamPrefixService: SteamPrefixService
    let steamPrefixReadinessResolver: SteamPrefixReadinessResolver
    let steamLaunchReadinessRepository: SteamLaunchReadinessRepository
    let steamLaunchHistoryMaintenanceScheduler:
        SteamLaunchHistoryMaintenanceScheduler
    let steamCompatibilitySessionCoordinator: SteamCompatibilitySessionCoordinator
    let windowsExecutablePrefixExecutionLifetimeOwner:
        WindowsExecutablePrefixExecutionLifetimeOwner
    let windowsExecutableLaunchService: WindowsExecutableLaunchService
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
        let gameInputProtectionPolicyStore = GameInputProtectionPolicyStore()
        let gameInputProtectionAuthorization = GameInputProtectionAuthorization()
        let awdlControlService = AWDLControlService()
        let steamManager = SteamManager(
            pathManager: pathManager,
            runner: safeProcessRunner,
            gameInputProtectionPolicyStore: gameInputProtectionPolicyStore
        )
        let runtimeManager = RuntimeManager(pathManager: pathManager, runner: safeProcessRunner)
        let ruleEngine = RuleEngine()
        let redactor = Redactor()
        let failureDiagnosticEvidenceService = FailureDiagnosticEvidenceService(
            pathManager: pathManager,
            redactor: redactor
        )
        let llmService = LLMService(redactor: redactor)
        let fontCompatibilityPackService = FontCompatibilityPackService()
        let controllerCompatibilityPreflightService = ControllerCompatibilityPreflightService()
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
        let compatibilityCatalogRepository = CompatibilityCatalogRepository()
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
            steamManager: steamManager
        )
        let systemCheckService = SystemCheckService(
            pathManager: pathManager,
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager
        )
        let setupWorkflowCoordinator = SetupWorkflowCoordinator(
            systemCheckService: systemCheckService,
            readinessResolver: steamPrefixReadinessResolver
        )
        let steamLaunchReadinessRepository = SteamLaunchReadinessRepository()
        let steamLaunchHistoryMaintenanceScheduler =
            SteamLaunchHistoryMaintenanceScheduler()
        let steamCompatibilitySessionCoordinator =
            SteamCompatibilitySessionCoordinator()
        let windowsExecutablePrefixExecutionLifetimeOwner =
            WindowsExecutablePrefixExecutionLifetimeOwner()
        let windowsExecutableLaunchService = WindowsExecutableLaunchService(
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager,
            steamManager: steamManager,
            safeProcessRunner: safeProcessRunner,
            lifecycleCoordinator: steamPrefixLifecycleCoordinator,
            compatibilityCoordinator: steamCompatibilitySessionCoordinator,
            prefixExecutionLifetimeOwner:
                windowsExecutablePrefixExecutionLifetimeOwner
        )

        self.appSessionID = appSessionID
        self.pathManager = pathManager
        self.systemCheckService = systemCheckService
        self.managedWineSessionRegistry = managedWineSessionRegistry
        self.safeProcessRunner = safeProcessRunner
        self.windowsRuntimeService = windowsRuntimeService
        self.prefixManager = prefixManager
        self.steamManager = steamManager
        self.gameInputProtectionPolicyStore = gameInputProtectionPolicyStore
        self.gameInputProtectionAuthorization = gameInputProtectionAuthorization
        self.awdlControlService = awdlControlService
        self.runtimeManager = runtimeManager
        self.ruleEngine = ruleEngine
        self.compatibilityService = CompatibilityService()
        self.redactor = redactor
        self.failureDiagnosticEvidenceService = failureDiagnosticEvidenceService
        self.llmService = llmService
        self.fontCompatibilityPackService = fontCompatibilityPackService
        self.controllerCompatibilityPreflightService = controllerCompatibilityPreflightService
        self.autoFixService = autoFixService
        self.supportBundleService = supportBundleService
        self.compatibilityCatalogRepository = compatibilityCatalogRepository
        self.compatibilityDBUpdateService = compatibilityDBUpdateService
        self.logRetentionService = logRetentionService
        self.storageMigrationService = storageMigrationService
        self.managedStorageService = managedStorageService
        self.setupResetService = setupResetService
        self.steamPrefixLifecycleCoordinator = steamPrefixLifecycleCoordinator
        self.steamPrefixService = steamPrefixService
        self.steamPrefixReadinessResolver = steamPrefixReadinessResolver
        self.steamLaunchReadinessRepository = steamLaunchReadinessRepository
        self.steamLaunchHistoryMaintenanceScheduler =
            steamLaunchHistoryMaintenanceScheduler
        self.steamCompatibilitySessionCoordinator = steamCompatibilitySessionCoordinator
        self.windowsExecutablePrefixExecutionLifetimeOwner =
            windowsExecutablePrefixExecutionLifetimeOwner
        self.windowsExecutableLaunchService = windowsExecutableLaunchService
        self.setupWorkflowCoordinator = setupWorkflowCoordinator
    }

    func synchronizeGameInputProtectionPolicy(from appState: AppState) {
        gameInputProtectionPolicyStore.update(
            GameInputProtectionPolicy(
                modifierMap: appState.gameInputModifierMap,
                blockAppWindowManagementShortcuts:
                    appState.blocksGameAppWindowManagementShortcuts,
                blockAppSwitchingShortcuts: appState.blocksGameAppSwitchingShortcuts,
                blockMissionControlSpaceShortcuts:
                    appState.blocksGameMissionControlSpaceShortcuts,
                blockDefaultScreenshotShortcuts:
                    appState.blocksGameScreenshotShortcuts,
                hidePointerWhileManagedGameFrontmost:
                    appState.hidesPointerWhileManagedGameFrontmost
            )
        )
    }

    func connectGameInputProtectionLifecycle(to appState: AppState) {
        steamManager.setGameInputProtectionLifecycleEventHandler {
            [weak appState] event in
            appState?.handleGameInputProtectionLifecycleEvent(event)
        }
        if let gameInputPointerHideFailureSubscription {
            GameInputProtectionPointerHideFailureBroker.shared.unsubscribe(
                gameInputPointerHideFailureSubscription
            )
        }
        gameInputPointerHideFailureSubscription =
            GameInputProtectionPointerHideFailureBroker.shared.subscribe {
                [weak appState] event in
                appState?.handleGameInputPointerHideFailure(event)
            }
    }

    deinit {
        MainActor.assumeIsolated {
            steamLaunchHistoryMaintenanceScheduler.cancel()
            if let gameInputPointerHideFailureSubscription {
                GameInputProtectionPointerHideFailureBroker.shared.unsubscribe(
                    gameInputPointerHideFailureSubscription
                )
            }
        }
    }

    var gameInputProtectionAuthorizationStatus: GameInputProtectionAuthorizationStatus {
        _ = gameInputProtectionAuthorizationRevision
        return cachedGameInputProtectionAuthorizationStatus ??
            .accessibilityAndInputMonitoringRequired
    }

    @discardableResult
    func requestGameInputProtectionAuthorization() -> Bool {
        _ = gameInputProtectionAuthorization.request()
        cachedGameInputProtectionAuthorizationStatus =
            gameInputProtectionAuthorization.status()
        gameInputProtectionAuthorizationRevision &+= 1
        return cachedGameInputProtectionAuthorizationStatus == .authorized
    }

    @discardableResult
    func requestGameInputProtectionAuthorization(
        for pane: GameInputProtectionPrivacyPane
    ) -> Bool {
        _ = gameInputProtectionAuthorization.request(pane)
        cachedGameInputProtectionAuthorizationStatus =
            gameInputProtectionAuthorization.status()
        gameInputProtectionAuthorizationRevision &+= 1
        return cachedGameInputProtectionAuthorizationStatus?
            .isAuthorized(for: pane) == true
    }

    func refreshGameInputProtectionAuthorizationStatus() {
        cachedGameInputProtectionAuthorizationStatus =
            gameInputProtectionAuthorization.status()
        gameInputProtectionAuthorizationRevision &+= 1
    }

    @discardableResult
    func openPrimaryGameInputProtectionPrivacyPane() -> Bool {
        guard let pane = GameInputProtectionPrivacyPane.requiredPanes(
            for: gameInputProtectionAuthorizationStatus
        ).first else {
            return true
        }
        return openGameInputProtectionPrivacyPane(pane)
    }

    @discardableResult
    func openGameInputProtectionPrivacyPane(
        _ pane: GameInputProtectionPrivacyPane
    ) -> Bool {
        ExternalLinkPolicy.open(pane.settingsURL)
    }

    func activateFontCompatibilityPack(for language: ForgePlayLanguageMode) async {
        let localizationIdentifier = language.localizationDirectory ??
            ForgePlaySystemLanguageResolver.fallbackLanguage.localeIdentifier ?? "en"
        let state = await fontCompatibilityPackService.activate(
            localizationIdentifier: localizationIdentifier
        )
        guard !Task.isCancelled else { return }
        fontCompatibilityPackActivationState = state
    }

    func resolveSetupReadiness(
        hasSteamReferences: Bool,
        runtimeExecutable: URL? = nil,
        rendererPolicySelection: SteamRendererPolicySelection = .d3dMetalNVIDIA,
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

    /// Capture the exact Wine processes that predate this startup before the
    /// root UI becomes launchable. Later Wine processes are never admitted to
    /// this immutable cleanup plan.
    func captureStartupWineProcessCleanupPlan()
        -> StartupWineProcessCleanupPlan {
        safeProcessRunner.captureStartupWineProcessCleanupPlan()
    }

    /// ForgePlay is the sole owner of its embedded Wine runtime. The root view
    /// is already visible while this lifecycle cleanup runs, and the blocking
    /// TERM/KILL wait is detached from the shared SafeProcessRunner actor.
    func forceTerminateWineProcessesAfterStartup(
        _ plan: StartupWineProcessCleanupPlan
    ) async -> String? {
        let runner = safeProcessRunner
        let result = await Task.detached(priority: .userInitiated) {
            runner.forceTerminateWineProcessesAfterStartup(plan)
        }.value
        guard !result.succeeded else { return nil }
        var details: [String] = []
        if !result.remainingProcessIDs.isEmpty {
            details.append(
                "remaining Wine PIDs: " + result.remainingProcessIDs
                    .map(String.init).joined(separator: ", ")
            )
        }
        details.append(contentsOf: result.inspectionFailures)
        details.append(contentsOf: result.signalFailures)
        return Array(Set(details)).sorted().joined(separator: " | ")
    }

    /// User-requested emergency stop. Capture every currently running
    /// ForgePlay-bundled Wine loader, wineserver, Game Mode host and PE child,
    /// cancel any synchronous launcher still capable of creating a child, and
    /// re-enumerate while applying identity-checked SIGKILL until the process
    /// set remains empty. This deliberately does not wait for compatibility
    /// baseline restoration or a prefix/session validation gate.
    func forceTerminateAllForgePlayWineProcesses(
        forceTerminator: ForceWineProcessTerminator? = nil,
        initialDrainTimeout: TimeInterval = 0.25,
        finalDrainTimeout: TimeInterval = 3
    )
        async -> StartupWineProcessCleanupResult {
        let runner = safeProcessRunner
        forceTerminatedWineQuiescenceProof = nil
        isForceWineTerminationInProgress = true
        defer { isForceWineTerminationInProgress = false }
        applicationTerminationResetTask?.cancel()
        applicationTerminationResetTask = nil
        containmentDrainResetTask?.cancel()
        containmentDrainResetTask = nil
        let boundedInitialDrainTimeout = min(
            max(initialDrainTimeout.isFinite ? initialDrainTimeout : 0.25, 0),
            1
        )
        let boundedFinalDrainTimeout = min(
            max(finalDrainTimeout.isFinite ? finalDrainTimeout : 3, 0),
            10
        )
        let resetTicket = appTerminationIntentGate
            .temporaryForceStopResetTicket()
        // Close launch admission and cancel the current owner, but do not wait
        // for UI state to disappear. Every task which can launch, retry, or
        // restore through Wine receives cancellation before the first global
        // sweep and must reach its bounded completion state before this method
        // can issue a no-spawn proof.
        steamPrefixLifecycleCoordinator.reserveApplicationTermination()
        steamManager.beginApplicationTerminationInputContainmentDrain()
        let compatibilityBackgroundTasks = steamPrefixService
            .cancelCompatibilityBackgroundWork()
        steamPrefixLifecycleCoordinator.requestCancellationOfActiveOperation()
        _ = runner.requestCancellationOfActiveSynchronousProcess()
        let initiallyDrainedOperation = await steamPrefixLifecycleCoordinator
            .beginApplicationTerminationAndWaitForIdle(
                timeout: boundedInitialDrainTimeout,
                cancellationRequester: { [safeProcessRunner] in
                    self.steamPrefixLifecycleCoordinator
                        .requestCancellationOfActiveOperation()
                    _ = safeProcessRunner
                        .requestCancellationOfActiveSynchronousProcess()
                }
            )
        let initiallyDrainedMonitors = await steamManager
            .waitForApplicationTerminationInputContainmentDrain(
                timeout: boundedInitialDrainTimeout
            )
        let initiallyDrainedBackgroundWork = await
            waitForCompatibilityBackgroundWorkDrain(
                compatibilityBackgroundTasks,
                timeout: boundedInitialDrainTimeout
            )

        let firstSweep: StartupWineProcessCleanupResult
        if let forceTerminator {
            firstSweep = await forceTerminator()
        } else {
            firstSweep = await Task.detached(priority: .userInitiated) {
                runner.forceTerminateAllForgePlayWineProcesses()
            }.value
        }

        steamPrefixLifecycleCoordinator.requestCancellationOfActiveOperation()
        _ = runner.requestCancellationOfActiveSynchronousProcess()
        let operationDrained: Bool
        if initiallyDrainedOperation {
            operationDrained = true
        } else {
            operationDrained = await steamPrefixLifecycleCoordinator
                .beginApplicationTerminationAndWaitForIdle(
                    timeout: boundedFinalDrainTimeout,
                    cancellationRequester: { [safeProcessRunner] in
                        self.steamPrefixLifecycleCoordinator
                            .requestCancellationOfActiveOperation()
                        _ = safeProcessRunner
                            .requestCancellationOfActiveSynchronousProcess()
                    }
                )
        }
        let monitorDrainSucceeded: Bool
        if initiallyDrainedMonitors {
            monitorDrainSucceeded = true
        } else {
            monitorDrainSucceeded = await steamManager
                .waitForApplicationTerminationInputContainmentDrain(
                timeout: boundedFinalDrainTimeout
            )
        }
        let backgroundWorkDrained: Bool
        if initiallyDrainedBackgroundWork {
            backgroundWorkDrained = true
        } else {
            backgroundWorkDrained = await
                waitForCompatibilityBackgroundWorkDrain(
                compatibilityBackgroundTasks,
                timeout: boundedFinalDrainTimeout
            )
        }

        // A cancelled operation can cross its last runner boundary while the
        // first global sweep is in progress. Sweep once more only after every
        // bounded drain attempt, closing any completed task's final spawn race
        // before launch admission can reopen. An incomplete drain remains a
        // truthful force-stop failure and does not receive a no-spawn proof.
        let finalSweep: StartupWineProcessCleanupResult
        if let forceTerminator {
            finalSweep = await forceTerminator()
        } else {
            finalSweep = await Task.detached(priority: .userInitiated) {
                runner.forceTerminateAllForgePlayWineProcesses()
            }.value
        }
        let capturedResult = Self.mergingForceTerminationSweeps(
            firstSweep,
            finalSweep: finalSweep
        )
        var lifecycleFailures: [String] = []
        if !operationDrained {
            lifecycleFailures.append(
                "the active Steam prefix operation did not drain before the force stop"
            )
        }
        if !monitorDrainSucceeded {
            lifecycleFailures.append(
                "Steam launch/restoration monitors did not drain before the force stop"
            )
        }
        if !backgroundWorkDrained {
            lifecycleFailures.append(
                "Steam compatibility background work did not drain after cancellation"
            )
        }
        var compatibilityDeferralWarnings: [String] = []
        if capturedResult.succeeded, lifecycleFailures.isEmpty {
            let deferral = steamManager
                .deferRetainedCompatibilityRestorationAfterForcedWineTermination()
            lifecycleFailures.append(contentsOf: deferral.blockingErrors)
            compatibilityDeferralWarnings = deferral.diagnosticWarnings
        }
        if !compatibilityDeferralWarnings.isEmpty {
            NSLog(
                "ForgePlay force-stop host compatibility restoration warning: %@",
                compatibilityDeferralWarnings.joined(separator: " | ")
            )
        }
        let result = StartupWineProcessCleanupResult(
            initiallyTargetedProcessIDs:
                capturedResult.initiallyTargetedProcessIDs,
            remainingProcessIDs: capturedResult.remainingProcessIDs,
            inspectionFailures: Array(Set(
                capturedResult.inspectionFailures + lifecycleFailures
            )).sorted(),
            signalFailures: capturedResult.signalFailures
        )
        if result.succeeded {
            forceTerminatedWineQuiescenceProof =
                ForceTerminatedWineQuiescenceProof(
                    lifecycleOperationGeneration:
                        steamPrefixLifecycleCoordinator.operationGeneration
                )
        }
        // Reopen admission only when no real application-termination intent
        // arrived while the force stop was awaiting its process postcondition.
        if operationDrained,
           monitorDrainSucceeded,
           backgroundWorkDrained,
           appTerminationIntentGate.permitsTemporaryForceStopReset(
                ticket: resetTicket
           ) {
            steamPrefixLifecycleCoordinator.cancelApplicationTermination()
            steamManager.cancelApplicationTerminationContainmentDrain(
                rearmRestorationMonitors: false
            )
        }
        notifySteamEnvironmentChanged()
        return result
    }

    private func waitForCompatibilityBackgroundWorkDrain(
        _ states: [SteamCompatibilityBackgroundWorkCompletionState],
        timeout: TimeInterval
    ) async -> Bool {
        guard states.contains(where: { !$0.isCompleted }) else { return true }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while Date() < deadline {
            if states.allSatisfy(\.isCompleted) { return true }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return states.allSatisfy(\.isCompleted)
    }

    private nonisolated static func mergingForceTerminationSweeps(
        _ first: StartupWineProcessCleanupResult,
        finalSweep: StartupWineProcessCleanupResult
    ) -> StartupWineProcessCleanupResult {
        StartupWineProcessCleanupResult(
            initiallyTargetedProcessIDs: Array(Set(
                first.initiallyTargetedProcessIDs +
                    finalSweep.initiallyTargetedProcessIDs
            )).sorted(),
            remainingProcessIDs: finalSweep.remainingProcessIDs,
            inspectionFailures: Array(Set(
                first.inspectionFailures + finalSweep.inspectionFailures
            )).sorted(),
            signalFailures: Array(Set(
                first.signalFailures + finalSweep.signalFailures
            )).sorted()
        )
    }

    func currentSteamEnvironmentGenerationID() throws -> String {
        try prefixManager.ensureSteamSharedEnvironmentGenerationID()
    }

    func notifySteamEnvironmentChanged() {
        steamEnvironmentRevision += 1
    }

    func importAppleSupplementalRenderer(
        at selectedURL: URL
    ) async throws -> AppleSupplementalRendererImportResult {
        let result = try await windowsRuntimeService
            .importAppleSupplementalRenderer(at: selectedURL)
        await setupWorkflowCoordinator.invalidateRuntimeCapabilitySnapshot()
        notifySteamEnvironmentChanged()
        return result
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
        in context: ModelContext,
        hasSteamReferences: Bool
    ) throws -> SetupReadiness {
        let ticket = setupWorkflowRefreshAttemptGate.issue()
        cancelActiveSetupWorkflowRefresh()
        let launchReadinessProjection = try steamLaunchReadinessProjection(
            in: context
        )
        let readiness = setupWorkflowCoordinator.computeReadiness(
            hasSteamReferences: hasSteamReferences,
            launchReadinessProjection: launchReadinessProjection,
            runtimeExecutable: appState.runtimeExecutableURL,
            managedRootURL: pathManager.rootURL,
            rendererPolicySelection: appState.steamRendererPolicySelection,
            videoMemorySelection: appState.steamVideoMemorySelection
        )
        guard setupWorkflowRefreshAttemptGate.isLatest(ticket) else {
            return appState.setupReadiness
        }
        appState.updateSetupStage(readiness: readiness)
        return readiness
    }

    func refreshSetupWorkflow(
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool
    ) async throws -> SetupWorkflowRefreshResult {
        let runtimeExecutable = appState.runtimeExecutableURL
        let rendererPolicySelection = appState.steamRendererPolicySelection
        let videoMemorySelection = appState.steamVideoMemorySelection
        let launchReadinessProjection = try steamLaunchReadinessProjection(
            in: context
        )
        let key = setupReadinessObservationKey(
            appState: appState,
            hasSteamReferences: hasSteamReferences,
            launchReadinessFingerprint: launchReadinessProjection.fingerprint
        )
        return try await performSetupWorkflowRefresh(
            key: key,
            appState: appState,
            runtimeExecutable: runtimeExecutable,
            rendererPolicySelection: rendererPolicySelection,
            videoMemorySelection: videoMemorySelection,
            hasSteamReferences: hasSteamReferences,
            launchReadinessProjection: launchReadinessProjection,
            context: context
        ) {
            try await self.prepareManagedStorageOnce(
                appState: appState,
                in: context
            )
        }
    }

    func setupReadinessObservationKey(
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool
    ) throws -> SetupReadinessObservationKey {
        let projection = try steamLaunchReadinessProjection(in: context)
        return setupReadinessObservationKey(
            appState: appState,
            hasSteamReferences: hasSteamReferences,
            launchReadinessFingerprint: projection.fingerprint
        )
    }

    private func setupReadinessObservationKey(
        appState: AppState,
        hasSteamReferences: Bool,
        launchReadinessFingerprint:
            SteamLaunchRecordLookup.ReadinessFingerprint
    ) -> SetupReadinessObservationKey {
        SetupReadinessObservationKey(
            environmentRevision: steamEnvironmentRevision,
            hasSteamReferences: hasSteamReferences,
            launchReadinessFingerprint: launchReadinessFingerprint,
            selectedRootPath: appState.selectedRootURL?.standardizedFileURL.path,
            runtimeExecutablePath: appState.runtimeExecutableURL?.standardizedFileURL.path,
            rendererSelection: appState.steamRendererPolicySelection.rawValue,
            videoMemorySelection: appState.steamVideoMemorySelection.rawValue
        )
    }

    private func performSetupWorkflowRefresh(
        key: SetupReadinessObservationKey,
        appState: AppState,
        runtimeExecutable: URL?,
        rendererPolicySelection: SteamRendererPolicySelection,
        videoMemorySelection: SteamVideoMemorySelection,
        hasSteamReferences: Bool,
        launchReadinessProjection: SteamLaunchReadinessProjection,
        context: ModelContext,
        activationProvider: @escaping @MainActor () async throws ->
            ManagedStorageActivationResult
    ) async throws -> SetupWorkflowRefreshResult {
        try Task.checkCancellation()
        if let activeAttempt = activeSetupWorkflowRefreshAttempt,
           activeAttempt.key == key {
            return try await awaitSetupWorkflowRefreshAttempt(activeAttempt)
        }

        let ticket = setupWorkflowRefreshAttemptGate.issue()
        cancelActiveSetupWorkflowRefresh()
        guard setupWorkflowRefreshAttemptGate.begin(ticket) else {
            throw SetupWorkflowRefreshControlError.superseded
        }
        let waiters = SetupWorkflowRefreshWaiterRegistry<SetupWorkflowRefreshResult>()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let completion: Result<SetupWorkflowRefreshResult, Error>
            do {
                try Task.checkCancellation()
                let activation = try await activationProvider()
                try Task.checkCancellation()
                try self.validateSetupWorkflowObservation(
                    key,
                    appState: appState,
                    hasSteamReferences: hasSteamReferences,
                    context: context
                )
                let result = try await self.setupWorkflowCoordinator.computeRefresh(
                    storageActivation: activation,
                    runtimeExecutable: runtimeExecutable,
                    rendererPolicySelection: rendererPolicySelection,
                    videoMemorySelection: videoMemorySelection,
                    hasSteamReferences: hasSteamReferences,
                    launchReadinessProjection: launchReadinessProjection
                )
                try Task.checkCancellation()
                try self.validateSetupWorkflowObservation(
                    key,
                    appState: appState,
                    hasSteamReferences: hasSteamReferences,
                    context: context
                )
                try self.commitSetupWorkflowRefresh(
                    result,
                    ticket: ticket,
                    appState: appState
                )
                completion = .success(result)
            } catch {
                completion = .failure(error)
            }
            self.completeSetupWorkflowRefreshAttempt(
                ticket: ticket,
                with: completion
            )
        }
        let attempt = SetupWorkflowRefreshAttempt(
            ticket: ticket,
            key: key,
            waiters: waiters,
            task: task
        )
        activeSetupWorkflowRefreshAttempt = attempt
        return try await awaitSetupWorkflowRefreshAttempt(attempt)
    }

    private func validateSetupWorkflowObservation(
        _ expected: SetupReadinessObservationKey,
        appState: AppState,
        hasSteamReferences: Bool,
        context: ModelContext
    ) throws {
        let current = try setupReadinessObservationKey(
            appState: appState,
            in: context,
            hasSteamReferences: hasSteamReferences
        )
        guard current == expected else {
            throw SetupWorkflowRefreshControlError.superseded
        }
    }

    private func awaitSetupWorkflowRefreshAttempt(
        _ attempt: SetupWorkflowRefreshAttempt
    ) async throws -> SetupWorkflowRefreshResult {
        let ticket = attempt.ticket
        return try await attempt.waiters.wait { [weak self] in
            self?.cancelSetupWorkflowRefreshAttemptAfterFinalWaiter(
                ticket: ticket
            )
        }
    }

    private func commitSetupWorkflowRefresh(
        _ result: SetupWorkflowRefreshResult,
        ticket: SetupWorkflowRequestTicket,
        appState: AppState
    ) throws {
        guard activeSetupWorkflowRefreshAttempt?.ticket == ticket,
              setupWorkflowRefreshAttemptGate.permitsCommit(ticket) else {
            throw SetupWorkflowRefreshControlError.superseded
        }
        appState.latestChecks = result.checks
        appState.updateSetupStage(readiness: result.readiness)
    }

    private func cancelActiveSetupWorkflowRefresh() {
        guard let activeAttempt = activeSetupWorkflowRefreshAttempt else { return }
        activeSetupWorkflowRefreshAttempt = nil
        _ = setupWorkflowRefreshAttemptGate.finish(activeAttempt.ticket)
        setupWorkflowCoordinator.invalidateSystemCheck()
        activeAttempt.task.cancel()
        activeAttempt.waiters.complete(
            with: .failure(SetupWorkflowRefreshControlError.superseded)
        )
    }

    private func cancelSetupWorkflowRefreshAttemptAfterFinalWaiter(
        ticket: SetupWorkflowRequestTicket
    ) {
        guard let activeAttempt = activeSetupWorkflowRefreshAttempt,
              activeAttempt.ticket == ticket,
              activeAttempt.waiters.waiterCount == 0 else { return }
        activeSetupWorkflowRefreshAttempt = nil
        _ = setupWorkflowRefreshAttemptGate.finish(ticket)
        setupWorkflowCoordinator.invalidateSystemCheck()
        activeAttempt.task.cancel()
    }

    private func completeSetupWorkflowRefreshAttempt(
        ticket: SetupWorkflowRequestTicket,
        with result: Result<SetupWorkflowRefreshResult, Error>
    ) {
        guard let activeAttempt = activeSetupWorkflowRefreshAttempt,
              activeAttempt.ticket == ticket else { return }
        activeSetupWorkflowRefreshAttempt = nil
        _ = setupWorkflowRefreshAttemptGate.finish(ticket)
        activeAttempt.waiters.complete(with: result)
    }

    private func refreshSetupWorkflowAfterActivation(
        _ activation: ManagedStorageActivationResult,
        appState: AppState,
        in context: ModelContext,
        hasSteamReferences: Bool
    ) async throws -> SetupWorkflowRefreshResult {
        while true {
            try Task.checkCancellation()
            let runtimeExecutable = appState.runtimeExecutableURL
            let rendererPolicySelection = appState.steamRendererPolicySelection
            let videoMemorySelection = appState.steamVideoMemorySelection
            let launchReadinessProjection = try steamLaunchReadinessProjection(
                in: context
            )
            let key = setupReadinessObservationKey(
                appState: appState,
                hasSteamReferences: hasSteamReferences,
                launchReadinessFingerprint: launchReadinessProjection.fingerprint
            )
            do {
                return try await performSetupWorkflowRefresh(
                    key: key,
                    appState: appState,
                    runtimeExecutable: runtimeExecutable,
                    rendererPolicySelection: rendererPolicySelection,
                    videoMemorySelection: videoMemorySelection,
                    hasSteamReferences: hasSteamReferences,
                    launchReadinessProjection: launchReadinessProjection,
                    context: context
                ) {
                    activation
                }
            } catch SetupWorkflowRefreshControlError.superseded {
                guard SetupWorkflowRefreshRetryPolicy.shouldRetryAfterSupersession(
                    outerTaskIsCancelled: Task.isCancelled
                ) else {
                    throw CancellationError()
                }
                await Task.yield()
            }
        }
    }

    private func steamLaunchReadinessProjection(
        in context: ModelContext
    ) throws -> SteamLaunchReadinessProjection {
        try steamLaunchReadinessRepository.readinessProjection(
            in: context,
            environmentIdentity: steamPrefixReadinessResolver
                .currentSteamEnvironmentIdentity(),
            currentAppSessionID: appSessionID
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
                    _ = try await self.shutdownSteamProcessesBeforeRootChange(
                        from: request.destination,
                        runtimeExecutable: appState.runtimeExecutableURL
                    )
                } else {
                    do {
                        try self.steamPrefixService.claimRuntimeOwnership(
                            forManagedRoot: request.destination
                        )
                    } catch ManagedRootOperationLeaseError.operationInProgress {
                        throw SteamPrefixLifecycleError.operationInProgress
                    }
                }
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
                    let activatedSteamPrefix = activation.rootURL.appending(
                        path: ForgePlayPathRole.steamSharedPrefix.rawValue,
                        directoryHint: .isDirectory
                    )
                    try await self.steamPrefixService
                        .cleanupInterruptedReplacementArtifactsDuringManagedStorageTransition(
                            at: activatedSteamPrefix
                        )
                } catch {
                    // Storage activation has already committed. An abandoned
                    // staging cleanup failure is diagnostic, not grounds to
                    // roll back the selected root or hide a usable prefix.
                    postCommitWarnings.append(
                        "Interrupted Steam environment cleanup: " +
                            forgePlayTechnicalErrorSummary(error)
                    )
                }
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
        hasSteamReferences: Bool
    ) async throws -> SetupWorkflowRefreshResult {
        guard case .legacyMigrationDecisionRequired(let sourcePath) = managedStoragePreparationState else {
            throw ManagedStorageWorkflowError.legacyMigrationDecisionUnavailable
        }
        approvedLegacyMigrationSourcePath = sourcePath
        defer { approvedLegacyMigrationSourcePath = nil }
        while true {
            do {
                return try await refreshSetupWorkflow(
                    appState: appState,
                    in: context,
                    hasSteamReferences: hasSteamReferences
                )
            } catch SetupWorkflowRefreshControlError.superseded {
                guard SetupWorkflowRefreshRetryPolicy.shouldRetryAfterSupersession(
                    outerTaskIsCancelled: Task.isCancelled
                ) else {
                    throw CancellationError()
                }
                await Task.yield()
            }
        }
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

            _ = try await setupResetService.startFreshWithDefaultManagedStorage(
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
            let workflow = try await refreshSetupWorkflowAfterActivation(
                activation,
                appState: appState,
                in: context,
                hasSteamReferences: false
            )
            notifySteamEnvironmentChanged()
            return workflow
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
        hasSteamReferences: Bool
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
            let workflow = try await refreshSetupWorkflowAfterActivation(
                activation,
                appState: appState,
                in: context,
                hasSteamReferences: hasSteamReferences
            )
            notifySteamEnvironmentChanged()
            return workflow
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
        hasSteamReferences: Bool
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
            let workflow = try await refreshSetupWorkflowAfterActivation(
                activation,
                appState: appState,
                in: context,
                hasSteamReferences: hasSteamReferences
            )
            notifySteamEnvironmentChanged()
            return workflow
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
        language: SteamClientLanguage,
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
            language: language,
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
        fileManager: FileManager = .default,
        wineProcessInspector: ForgePlayWineProcessInspector? = nil
    ) async -> AppTerminationSteamShutdownSummary {
        appTerminationIntentGate.beginApplicationTermination()
        applicationTerminationResetTask?.cancel()
        applicationTerminationResetTask = nil
        containmentDrainResetTask?.cancel()
        containmentDrainResetTask = nil
        steamPrefixLifecycleCoordinator.reserveApplicationTermination()
        steamManager.beginApplicationTerminationInputContainmentDrain()
        let compatibilityBackgroundTasks = steamPrefixService
            .cancelCompatibilityBackgroundWork()
        steamPrefixLifecycleCoordinator.requestCancellationOfActiveOperation()
        _ = safeProcessRunner
            .requestCancellationOfActiveSynchronousProcess()
        let forceStopDrained = await waitForForceWineTerminationToFinish()
        let operationDrained = await steamPrefixLifecycleCoordinator
            .beginApplicationTerminationAndWaitForIdle(
                cancellationRequester: { [safeProcessRunner] in
                    self.steamPrefixLifecycleCoordinator
                        .requestCancellationOfActiveOperation()
                    _ = safeProcessRunner
                        .requestCancellationOfActiveSynchronousProcess()
                }
            )
        let containmentDrained = await steamManager
            .waitForApplicationTerminationInputContainmentDrain()
        let backgroundWorkDrained = await
            waitForCompatibilityBackgroundWorkDrain(
                compatibilityBackgroundTasks,
                timeout: 10
            )
        guard forceStopDrained,
              operationDrained,
              containmentDrained,
              backgroundWorkDrained else {
            return AppTerminationSteamShutdownSummary(
                prefix: nil,
                prefixes: steamPrefixLifecycleCoordinator
                    .activeManagedPrefixURLs,
                attemptedRuntimePath: runtimeExecutable?.path,
                results: [],
                errors: [
                    "active force stop, Steam prefix operation, launch monitor, " +
                    "compatibility background work, or input-containment " +
                    "owner did not stop after its owned process group was " +
                    "cancelled: " +
                    (steamPrefixLifecycleCoordinator.activeOperation?
                        .rawValue ?? "unknown")
                ],
                skippedReason: nil
            )
        }
        if let summary = verifiedForceTerminationShutdownSummary(
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot:
                includeDefaultApplicationSupportRoot,
            fileManager: fileManager,
            wineProcessInspector: wineProcessInspector
        ) {
            return summary
        }
        do {
            try await steamPrefixService
                .completeFailedCompatibilityCleanupsForApplicationTermination()
            _ = try await steamCompatibilitySessionCoordinator
                .completeActiveSessionForApplicationTerminationIfNeeded()
        } catch {
            return AppTerminationSteamShutdownSummary(
                prefix: nil,
                prefixes: [],
                attemptedRuntimePath: nil,
                results: [],
                errors: [
                    "could not safely complete the active compatibility Steam " +
                    "session before application termination: " +
                    forgePlayTechnicalErrorSummary(error)
                ],
                skippedReason: nil
            )
        }
        let plan = appTerminationSteamShutdownPlan(
            runtimeExecutable: runtimeExecutable,
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot: includeDefaultApplicationSupportRoot,
            fileManager: fileManager
        )
        return await Self.executeAppTerminationSteamShutdown(
            plan,
            safeProcessRunner: safeProcessRunner,
            restoreRetainedCompatibilitySessions: { [steamManager] prefix in
                try await steamManager
                    .completeRetainedCompatibilitySessionsAfterPrefixShutdown(
                        prefix: prefix
                    )
            },
            completeRetainedWindowsExecutableLeases: {
                [windowsExecutablePrefixExecutionLifetimeOwner, safeProcessRunner]
                prefix in
                try await windowsExecutablePrefixExecutionLifetimeOwner
                    .completeAfterConfirmedPrefixShutdown(
                        prefix: prefix,
                        inactivityWaiter: { prefix, timeout, pollInterval in
                            try await safeProcessRunner
                                .waitForManagedPrefixProcessesToExit(
                                    prefix,
                                    timeout: timeout,
                                    pollInterval: pollInterval
                                )
                        }
                    )
            }
        )
    }

    func cancelApplicationTermination() {
        appTerminationIntentGate.cancelApplicationTermination()
        scheduleApplicationTerminationResetWhenQuiescent()
    }

    private func scheduleApplicationTerminationResetWhenQuiescent() {
        containmentDrainResetTask?.cancel()
        containmentDrainResetTask = nil
        applicationTerminationResetTask?.cancel()
        applicationTerminationResetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.steamPrefixLifecycleCoordinator
                    .canCancelApplicationTermination,
                   self.steamManager
                    .canCancelApplicationTerminationContainmentDrain {
                    self.steamPrefixLifecycleCoordinator
                        .cancelApplicationTermination()
                    self.steamManager
                        .cancelApplicationTerminationContainmentDrain()
                    self.applicationTerminationResetTask = nil
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    private func waitForForceWineTerminationToFinish(
        timeout: TimeInterval = 15
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while isForceWineTerminationInProgress {
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return true
    }

    /// The force-stop loop already performed repeated identity-checked global
    /// enumeration and quiet snapshots. Reuse that proof only if no coordinated
    /// prefix operation has begun since it was captured and a fresh read-only
    /// process inspection still observes no ForgePlay Wine process. This avoids
    /// starting wineserver, Wine registry helpers, or `steam.exe -shutdown`
    /// merely to stop a prefix which is already known to be inactive.
    private func verifiedForceTerminationShutdownSummary(
        selectedRootURL: URL?,
        additionalManagedRoots: [URL],
        includeDefaultApplicationSupportRoot: Bool,
        fileManager: FileManager,
        wineProcessInspector: ForgePlayWineProcessInspector?
    ) -> AppTerminationSteamShutdownSummary? {
        guard let proof = forceTerminatedWineQuiescenceProof,
              proof.lifecycleOperationGeneration ==
                steamPrefixLifecycleCoordinator.operationGeneration,
              steamPrefixLifecycleCoordinator.activeOperation == nil else {
            return nil
        }
        let inspection = wineProcessInspector?() ??
            safeProcessRunner.captureStartupWineProcessCleanupPlan()
        guard inspection.targets.isEmpty,
              inspection.inspectionFailures.isEmpty else {
            forceTerminatedWineQuiescenceProof = nil
            return nil
        }
        forceTerminatedWineQuiescenceProof = nil
        let prefixes = appTerminationSteamSharedPrefixes(
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot:
                includeDefaultApplicationSupportRoot,
            fileManager: fileManager
        )
        return AppTerminationSteamShutdownSummary(
            prefix: prefixes.first,
            prefixes: prefixes,
            attemptedRuntimePath: nil,
            results: [],
            errors: [],
            warnings: [],
            skippedReason:
                "successful force stop and fresh process inspection verified no ForgePlay Wine processes"
        )
    }

    func shutdownSteamProcessesBeforeRootChange(
        from root: URL,
        runtimeExecutable _: URL?,
        fileManager: FileManager = .default
    ) async throws -> AppTerminationSteamShutdownSummary {
        guard !steamCompatibilitySessionCoordinator.hasActiveSession,
              !steamCompatibilitySessionCoordinator.isTransitionInProgress,
              !steamPrefixService.hasRetainedCompatibilityCleanupOwnership else {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        try steamPrefixLifecycleCoordinator.checkpoint()
        containmentDrainResetTask?.cancel()
        containmentDrainResetTask = nil
        steamManager.beginApplicationTerminationInputContainmentDrain()
        defer {
            scheduleContainmentDrainResetWhenQuiescent()
        }
        guard await steamManager
                .waitForApplicationTerminationInputContainmentDrain() else {
            throw SteamPrefixLifecycleError.operationInProgress
        }
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
            safeProcessRunner: safeProcessRunner,
            restoreRetainedCompatibilitySessions: { [steamManager] prefix in
                try await steamManager
                    .completeRetainedCompatibilitySessionsAfterPrefixShutdown(
                        prefix: prefix
                    )
            },
            completeRetainedWindowsExecutableLeases: {
                [windowsExecutablePrefixExecutionLifetimeOwner, safeProcessRunner]
                prefix in
                try await windowsExecutablePrefixExecutionLifetimeOwner
                    .completeAfterConfirmedPrefixShutdown(
                        prefix: prefix,
                        inactivityWaiter: { prefix, timeout, pollInterval in
                            try await safeProcessRunner
                                .waitForManagedPrefixProcessesToExit(
                                    prefix,
                                    timeout: timeout,
                                    pollInterval: pollInterval
                                )
                        }
                    )
            }
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

    private func scheduleContainmentDrainResetWhenQuiescent() {
        containmentDrainResetTask?.cancel()
        if steamManager.canCancelApplicationTerminationContainmentDrain {
            steamManager.cancelApplicationTerminationContainmentDrain()
            containmentDrainResetTask = nil
            return
        }
        containmentDrainResetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.steamManager
                    .canCancelApplicationTerminationContainmentDrain {
                    self.steamManager
                        .cancelApplicationTerminationContainmentDrain()
                    self.containmentDrainResetTask = nil
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
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

    /// Last-chance cleanup used only from `applicationWillTerminate`, where
    /// MainActor can no longer wait for normal lifecycle owners to release
    /// their leases. It does not claim or mutate ownership metadata; the
    /// runner still performs its descriptor-bound, bounded wineserver shutdown
    /// and managed-process postcondition checks for each known prefix.
    func emergencyAppTerminationSteamShutdownPlan(
        selectedRootURL: URL? = nil,
        additionalManagedRoots: [URL] = [],
        includeDefaultApplicationSupportRoot: Bool = false,
        fileManager: FileManager = .default
    ) -> AppTerminationSteamShutdownPlan {
        appTerminationIntentGate.beginApplicationTermination()
        applicationTerminationResetTask?.cancel()
        applicationTerminationResetTask = nil
        containmentDrainResetTask?.cancel()
        containmentDrainResetTask = nil
        steamPrefixLifecycleCoordinator.reserveApplicationTermination()
        steamManager.beginApplicationTerminationInputContainmentDrain()
        steamPrefixLifecycleCoordinator.requestCancellationOfActiveOperation()
        _ = safeProcessRunner
            .requestCancellationOfActiveSynchronousProcess()
        if let summary = verifiedForceTerminationShutdownSummary(
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot:
                includeDefaultApplicationSupportRoot,
            fileManager: fileManager,
            wineProcessInspector: nil
        ) {
            return AppTerminationSteamShutdownPlan(
                prefixes: [],
                runtimeExecutable: nil,
                initialErrors: [],
                initialWarnings: summary.warnings,
                skippedReason: summary.skippedReason
            )
        }
        let prefixes = appTerminationSteamSharedPrefixes(
            selectedRootURL: selectedRootURL,
            additionalManagedRoots: additionalManagedRoots,
            includeDefaultApplicationSupportRoot:
                includeDefaultApplicationSupportRoot,
            fileManager: fileManager
        )
        guard !prefixes.isEmpty else {
            return AppTerminationSteamShutdownPlan(
                prefixes: [],
                runtimeExecutable: nil,
                initialErrors: [],
                skippedReason: "no configured SteamShared prefix exists"
            )
        }
        let runtime = appTerminationShutdownRuntime(fileManager: fileManager)
        return AppTerminationSteamShutdownPlan(
            prefixes: prefixes,
            runtimeExecutable: runtime,
            initialErrors: runtime == nil
                ? [
                    "the bundled ForgePlay Runtime is unavailable for " +
                        "emergency termination cleanup"
                ]
                : [],
            skippedReason: nil
        )
    }

    nonisolated static func executeAppTerminationSteamShutdown(
        _ plan: AppTerminationSteamShutdownPlan,
        safeProcessRunner: SafeProcessRunner,
        managedSteamActivityInspector:
            ManagedWindowsSteamActivityInspector? = nil,
        restoreRetainedCompatibilitySessions:
            AppTerminationPrefixRestoration? = nil,
        completeRetainedWindowsExecutableLeases:
            AppTerminationPrefixRestoration? = nil,
        requiresExclusiveOwnerVerification: Bool = true
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
                    if let managedSteamActivityInspector {
                        shouldRequestGracefulShutdown = try await
                            managedSteamActivityInspector(prefix)
                    } else {
                        shouldRequestGracefulShutdown = try await
                            safeProcessRunner
                                .hasVerifiedManagedWindowsSteamActivity(
                                    under: prefix
                                )
                    }
                } catch {
                    warnings.append(
                        "\(prefix.path) managed Windows Steam activity inspection before graceful shutdown: " +
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
                        if requiresExclusiveOwnerVerification {
                            try await restoreRetainedCompatibilitySessions?(
                                prefix
                            )
                            try await completeRetainedWindowsExecutableLeases?(
                                prefix
                            )
                            // The native Game Mode host inherits a shared
                            // execution lease independently of wineserver.
                            // Reacquisition proves all normal owners drained.
                            let verificationLease = try PrefixExecutionLease
                                .acquireExclusiveMutation(forPrefix: prefix)
                            verificationLease.release()
                        }
                        didCleanPrefix = true
                    } catch {
                        prefixCleanupErrors.append(
                            "\(prefix.path) retained compatibility restoration or " +
                                "Game Mode host lease verification: " +
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
