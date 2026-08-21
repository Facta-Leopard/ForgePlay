import Foundation
import SwiftData

struct SetupResetResult: Hashable {
    var clearedSelectionCount: Int
    var deletedRecordCount: Int
}

@MainActor
final class SetupResetService {
    private let pathManager: PathManager
    private let storageMigrationService: StorageMigrationService
    private let defaultManagedRootURL: () throws -> URL

    private struct WorkflowStateSnapshot {
        var pathRoot: URL?
        var selectedRootURL: URL?
        var runtimeExecutableURL: URL?
        var steamInstallerURL: URL?
        var selectedSteamReference: SteamGame?
        var activeDiagnostics: [DiagnosticResult]
        var latestChecks: [SystemCheckResult]
        var setupReadiness: SetupReadiness
        var setupStage: SetupStage
        var selectedSection: AppSection
        var presentedSheet: SheetDestination?
    }

    private enum WorkflowRecordDeletionStrategy {
        case immediateBatch
        case deferredRollbackCapable
    }

    init(
        pathManager: PathManager,
        storageMigrationService: StorageMigrationService? = nil,
        defaultManagedRootURL: @escaping () throws -> URL = { try PathManager.defaultManagedRootURL() }
    ) {
        self.pathManager = pathManager
        self.storageMigrationService = storageMigrationService ?? StorageMigrationService(pathManager: pathManager)
        self.defaultManagedRootURL = defaultManagedRootURL
    }

    func resetSetupProgress(appState: AppState, in context: ModelContext) throws -> SetupResetResult {
        let snapshot = workflowStateSnapshot(appState)
        do {
            let settings = try appState.loadOrCreateSettings(in: context)
            let clearedSelections = clearAllSetupSelections(settings: settings, appState: appState)
            if pathManager.rootURL == nil,
               let selectedRootPath = settings.selectedRootPath,
               !selectedRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let selectedRoot = URL(fileURLWithPath: selectedRootPath, isDirectory: true).standardizedFileURL
                let defaultRoot = try defaultManagedRootURL().standardizedFileURL
                if selectedRoot.path != defaultRoot.path {
                    throw ManagedStorageActivationError.managedRootAuthorizationRequired(selectedRoot.path)
                }
            }
            let managedRoot = try pathManager.rootURL ?? defaultManagedRootURL()
            try pathManager.configureRoot(managedRoot)

            clearTransientWorkflowState(appState)
            appState.activateManagedRoot(managedRoot)
            settings.selectedRootPath = managedRoot.path
            let defaultManagedRoot = try defaultManagedRootURL().standardizedFileURL
            if managedRoot.standardizedFileURL.path == defaultManagedRoot.path {
                settings.selectedRootBookmark = nil
            }
            settings.managedStorageLayoutVersion = ForgePlayManagedStorageLayout.currentVersion
            appState.setupStage = .checkMac
            appState.selectedSection = .setup
            appState.presentedSheet = nil

            let deletedRecords = try deleteWorkflowRecords(
                in: context,
                preservesSteamStorageMounts: true,
                strategy: .immediateBatch
            )
            settings.updatedAt = Date()
            try context.saveOrRollback()

            return SetupResetResult(
                clearedSelectionCount: clearedSelections,
                deletedRecordCount: deletedRecords
            )
        } catch {
            context.rollback()
            restoreWorkflowState(snapshot, appState: appState)
            throw error
        }
    }

    func startFreshWithDefaultManagedStorage(
        appState: AppState,
        in context: ModelContext
    ) async throws -> SetupResetResult {
        let snapshot = workflowStateSnapshot(appState)
        do {
            let settings = try appState.loadOrCreateSettings(in: context)
            let previousManagedRoot = settings.selectedRootPath.flatMap { path -> URL? in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
            }
            let defaultManagedRoot = try defaultManagedRootURL().standardizedFileURL

            try pathManager.configureRoot(defaultManagedRoot)
            try await storageMigrationService.ensureManagedStorageMarker(
                at: defaultManagedRoot,
                migratedFrom: nil
            )

            let clearedSelections = clearAllSetupSelections(settings: settings, appState: appState)
            clearTransientWorkflowState(appState)
            appState.activateManagedRoot(defaultManagedRoot)
            settings.selectedRootPath = defaultManagedRoot.path
            settings.selectedRootBookmark = nil
            settings.managedStorageLayoutVersion = ForgePlayManagedStorageLayout.currentVersion
            if let previousManagedRoot, previousManagedRoot.path != defaultManagedRoot.path {
                settings.legacyManagedRootPath = previousManagedRoot.path
            }
            settings.managedStorageMigrationCompletedAt = nil
            appState.setupStage = .checkMac
            appState.selectedSection = .setup

            let deletedRecords = try deleteWorkflowRecords(
                in: context,
                preservesSteamStorageMounts: true,
                strategy: .immediateBatch
            )
            settings.updatedAt = Date()
            try context.saveOrRollback()

            return SetupResetResult(
                clearedSelectionCount: clearedSelections,
                deletedRecordCount: deletedRecords
            )
        } catch {
            context.rollback()
            restoreWorkflowState(snapshot, appState: appState)
            throw error
        }
    }

    func resetPathBoundWorkflowState(
        appState: AppState,
        oldRoot: URL,
        in context: ModelContext,
        saveImmediately: Bool = true
    ) throws -> SetupResetResult {
        let snapshot = workflowStateSnapshot(appState)
        do {
            let settings = try appState.loadOrCreateSettings(in: context)
            var clearedSelections = 0

            // Legacy Runtime selection columns are schema-only. The active
            // ForgePlay Runtime remains derived from the app bundle across a
            // managed-root reset and is never counted as user data.
            settings.gptkExecutablePath = nil
            settings.gptkExecutableBookmark = nil

            if StorageMigrationService.pathIsInsideRoot(settings.lastSteamInstallerPath, root: oldRoot) {
                settings.lastSteamInstallerPath = nil
                settings.lastSteamInstallerBookmark = nil
                appState.clearPersistedFileSelection(for: .steamInstaller)
                clearedSelections += 1
            }

            clearTransientWorkflowState(appState)
            let deletedRecords = try deleteWorkflowRecords(
                in: context,
                preservesSteamStorageMounts: false,
                strategy: saveImmediately
                    ? .immediateBatch
                    : .deferredRollbackCapable
            )
            settings.updatedAt = Date()
            if saveImmediately {
                try context.saveOrRollback()
            }

            return SetupResetResult(
                clearedSelectionCount: clearedSelections,
                deletedRecordCount: deletedRecords
            )
        } catch {
            context.rollback()
            restoreWorkflowState(snapshot, appState: appState)
            throw error
        }
    }

    private func workflowStateSnapshot(_ appState: AppState) -> WorkflowStateSnapshot {
        WorkflowStateSnapshot(
            pathRoot: pathManager.rootURL,
            selectedRootURL: appState.selectedRootURL,
            runtimeExecutableURL: appState.runtimeExecutableURL,
            steamInstallerURL: appState.steamInstallerURL,
            selectedSteamReference: appState.selectedSteamReference,
            activeDiagnostics: appState.activeDiagnostics,
            latestChecks: appState.latestChecks,
            setupReadiness: appState.setupReadiness,
            setupStage: appState.setupStage,
            selectedSection: appState.selectedSection,
            presentedSheet: appState.presentedSheet
        )
    }

    private func restoreWorkflowState(_ snapshot: WorkflowStateSnapshot, appState: AppState) {
        let pathRootRestoreFailed = restorePathRoot(snapshot.pathRoot) == false && snapshot.pathRoot != nil
        if pathRootRestoreFailed {
            appState.clearPersistedFileSelection(for: .selectedRoot)
        } else if let selectedRootURL = snapshot.selectedRootURL {
            appState.setPersistedFileSelection(
                selectedRootURL,
                for: .selectedRoot,
                requiresBookmarkReplacement: false
            )
        } else {
            appState.clearPersistedFileSelection(for: .selectedRoot)
        }
        appState.runtimeExecutableURL = snapshot.runtimeExecutableURL.flatMap {
            ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable($0)
                ? $0.standardizedFileURL
                : nil
        }
        appState.setPersistedFileSelection(
            snapshot.steamInstallerURL,
            for: .steamInstaller,
            requiresBookmarkReplacement: false
        )
        appState.selectedSteamReference = snapshot.selectedSteamReference
        appState.activeDiagnostics = snapshot.activeDiagnostics
        appState.latestChecks = snapshot.latestChecks
        appState.setupReadiness = snapshot.setupReadiness
        appState.setupStage = pathRootRestoreFailed ? .chooseRoot : snapshot.setupStage
        appState.selectedSection = pathRootRestoreFailed ? .setup : snapshot.selectedSection
        appState.presentedSheet = pathRootRestoreFailed ? nil : snapshot.presentedSheet
    }

    private func restorePathRoot(_ root: URL?) -> Bool {
        do {
            try pathManager.restoreWorkflowRoot(root)
            return true
        } catch {
            return false
        }
    }

    private func clearAllSetupSelections(settings: AppSettingsRecord, appState: AppState) -> Int {
        var clearedSelections = 0

        // Preserve the immutable bundled Runtime while retiring schema-only
        // legacy selection values.
        settings.gptkExecutablePath = nil
        settings.gptkExecutableBookmark = nil

        if settings.lastSteamInstallerPath != nil || settings.lastSteamInstallerBookmark != nil || appState.steamInstallerURL != nil {
            clearedSelections += 1
        }
        settings.lastSteamInstallerPath = nil
        settings.lastSteamInstallerBookmark = nil
        appState.clearPersistedFileSelection(for: .steamInstaller)

        return clearedSelections
    }

    private func clearTransientWorkflowState(_ appState: AppState) {
        appState.selectedSteamReference = nil
        appState.activeDiagnostics = []
        appState.latestChecks = []
        appState.setupReadiness = .empty
    }

    private func deleteWorkflowRecords(
        in context: ModelContext,
        preservesSteamStorageMounts: Bool,
        strategy: WorkflowRecordDeletionStrategy
    ) throws -> Int {
        var deletedRecords = 0
        deletedRecords += try deleteRecords(PrefixRecord.self, in: context, strategy: strategy)
        deletedRecords += try deleteRecords(RuntimeRecord.self, in: context, strategy: strategy)
        deletedRecords += try deleteRecords(SteamGameRecord.self, in: context, strategy: strategy)
        if !preservesSteamStorageMounts {
            deletedRecords += try deleteRecords(
                SteamStorageMountRecord.self,
                in: context,
                strategy: strategy
            )
        }
        deletedRecords += try deleteRecords(LaunchRecord.self, in: context, strategy: strategy)
        deletedRecords += try deleteRecords(DiagnosticRecord.self, in: context, strategy: strategy)
        deletedRecords += try deleteRecords(AutoFixRecord.self, in: context, strategy: strategy)
        return deletedRecords
    }

    private func deleteRecords<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext,
        strategy: WorkflowRecordDeletionStrategy
    ) throws -> Int {
        switch strategy {
        case .immediateBatch:
            let count = try context.fetchCount(FetchDescriptor<T>())
            guard count > 0 else { return 0 }
            // Normal product resets commit immediately and may include years
            // of history, so keep that path on SwiftData's batch deletion.
            try context.delete(model: type)
            return count
        case .deferredRollbackCapable:
            // SwiftData batch deletion is not restored by ModelContext.rollback().
            // A caller that explicitly defers the save therefore needs tracked
            // per-model deletes so its transaction remains genuinely reversible.
            let records = try context.fetch(FetchDescriptor<T>())
            for record in records {
                context.delete(record)
            }
            return records.count
        }
    }
}
