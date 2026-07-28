import Foundation
import SwiftData

enum ForgePlayManagedStorageLayout {
    static let currentVersion = 2
    static let markerFileName = ".managed-storage-layout-v2"

    static let copiedTopLevelDirectoryNames: Set<String> = [
        "Apps",
        "Prefixes",
        "RuntimeCache",
        "CompatibilityDB",
        "Logs",
        "Config"
    ]

    static let relocatedTopLevelDirectoryNames = copiedTopLevelDirectoryNames.union([
        ForgePlayPathRole.snapshots.rawValue
    ])
}

struct ManagedStorageActivationResult: Hashable {
    var rootURL: URL
    var migratedFromURL: URL?
    var copiedFiles: Int
    var copiedBytes: Int64
    var sourceCleanupWarning: String? = nil
    var postCommitWarning: String? = nil

    var didMigrateLegacyData: Bool {
        migratedFromURL != nil
    }
}

enum ManagedStorageActivationError: LocalizedError, Equatable {
    case legacyMigrationDecisionRequired(String)
    case legacyRootAuthorizationRequired(String)
    case managedRootAuthorizationRequired(String)
    case legacyRootDoesNotContainManagedData(URL)
    case managedRootDoesNotContainManagedData(URL)
    case managedRootBookmarkRequired(URL)
    case stateRollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .legacyMigrationDecisionRequired(let path):
            "기존 ForgePlay 앱 데이터의 처리 방법을 선택하세요: \(path)"
        case .legacyRootAuthorizationRequired(let path):
            "기존 ForgePlay 데이터를 내부 저장소로 옮기려면 이전 저장 위치를 다시 연결해야 합니다: \(path)"
        case .managedRootAuthorizationRequired(let path):
            "선택한 ForgePlay 앱 데이터 위치에 다시 접근할 권한이 필요합니다: \(path)"
        case .legacyRootDoesNotContainManagedData(let url):
            "선택한 폴더에서 이전 ForgePlay 프리픽스를 찾을 수 없습니다: \(url.path)"
        case .managedRootDoesNotContainManagedData(let url):
            "현재 ForgePlay 앱 데이터 위치에서 옮길 프리픽스를 찾을 수 없습니다: \(url.path)"
        case .managedRootBookmarkRequired(let url):
            "선택한 앱 데이터 위치의 접근 권한을 저장하지 못했습니다. macOS 폴더 선택기에서 다시 선택하세요: \(url.path)"
        case .stateRollbackFailed(let message):
            "내부 저장소 전환 실패 후 이전 상태를 복원하지 못했습니다: \(message)"
        }
    }

    var requiresUserIntervention: Bool {
        switch self {
        case .legacyMigrationDecisionRequired,
             .legacyRootAuthorizationRequired,
             .managedRootAuthorizationRequired,
             .managedRootBookmarkRequired:
            true
        case .legacyRootDoesNotContainManagedData,
             .managedRootDoesNotContainManagedData,
             .stateRollbackFailed:
            false
        }
    }
}

@MainActor
final class ManagedStorageService {
    private let pathManager: PathManager
    private let storageMigrationService: StorageMigrationService

    init(
        pathManager: PathManager,
        storageMigrationService: StorageMigrationService
    ) {
        self.pathManager = pathManager
        self.storageMigrationService = storageMigrationService
    }

    func activate(
        in context: ModelContext,
        legacyRootURL: URL?,
        managedRootURLOverride: URL? = nil,
        managedRootBookmark: Data? = nil
    ) async throws -> ManagedStorageActivationResult {
        let settings = try loadOrCreateSettings(in: context)
        let destination = try (managedRootURLOverride ?? PathManager.defaultManagedRootURL())
            .standardizedFileURL
        let persistedVersion = settings.managedStorageLayoutVersion ?? 0
        let persistedRootPath = settings.selectedRootPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedRootIsDestination = persistedRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path == destination.path
        } ?? false
        let requiresLegacyMigration = persistedVersion < ForgePlayManagedStorageLayout.currentVersion &&
            persistedRootPath?.isEmpty == false &&
            !persistedRootIsDestination

        if requiresLegacyMigration,
           let persistedRootPath,
           legacyRootURL == nil {
            throw ManagedStorageActivationError.legacyRootAuthorizationRequired(persistedRootPath)
        }

        let normalizedLegacyRoot = legacyRootURL?.standardizedFileURL
        if requiresLegacyMigration,
           normalizedLegacyRoot?.path == destination.path {
            throw ManagedStorageActivationError.legacyRootDoesNotContainManagedData(destination)
        }
        let source: URL?
        if let normalizedLegacyRoot,
           normalizedLegacyRoot.path != destination.path {
            source = normalizedLegacyRoot
        } else {
            source = nil
        }
        let logicalSource = persistedRootPath.flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return url.path == destination.path ? nil : url
        } ?? source
        let legacyBookmark = settings.selectedRootBookmark
        let destinationBookmark = managedRootBookmark ?? (persistedRootIsDestination
            ? settings.selectedRootBookmark
            : nil)
        let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
        if ForgePlaySandboxPolicy.isAppSandboxEnabled,
           destination.path != defaultManagedRoot.path,
           destinationBookmark == nil {
            throw ManagedStorageActivationError.managedRootBookmarkRequired(destination)
        }
        let previousPathRoot = pathManager.rootURL
        let transferLeases = try storageMigrationService.acquireManagedRootLeases(
            for: [source, destination].compactMap { $0 }
        )
        defer { transferLeases.reversed().forEach { $0.release() } }

        do {
            var migrationResult: StorageMigrationResult?
            if persistedVersion < ForgePlayManagedStorageLayout.currentVersion,
               let source,
               let logicalSource {
                guard try storageMigrationService.hasManagedData(at: source) else {
                    throw ManagedStorageActivationError.legacyRootDoesNotContainManagedData(source)
                }
                migrationResult = try await storageMigrationService.copyManagedDataOnlyAssumingExclusiveTransfer(
                    from: source,
                    rebasingPathsFrom: logicalSource,
                    to: destination
                )
                _ = try storageMigrationService.rebaseManagedRecords(
                    in: context,
                    from: logicalSource,
                    to: destination
                )
                try rebaseLegacyExternalRecords(
                    in: context,
                    from: logicalSource,
                    to: source
                )
            }

            if let source {
                try preserveLegacyGameLibraryAccess(
                    in: context,
                    physicalSourceRoot: source,
                    externalizedLibraryPaths: migrationResult?.externalizedLibraryPaths ?? [],
                    bookmark: legacyBookmark,
                    preservesBookmarkWithoutKnownLibrary: true
                )
            }

            try pathManager.configureRoot(destination)
            try storageMigrationService.ensureManagedStorageMarker(
                at: destination,
                migratedFrom: migrationResult?.sourceRoot
            )

            settings.selectedRootPath = destination.path
            settings.selectedRootBookmark = destination.path == defaultManagedRoot.path
                ? nil
                : destinationBookmark
            settings.managedStorageLayoutVersion = ForgePlayManagedStorageLayout.currentVersion
            if let logicalSource {
                settings.legacyManagedRootPath = logicalSource.path
            }
            if migrationResult != nil {
                settings.managedStorageMigrationCompletedAt = Date()
            }
            settings.updatedAt = Date()
            try context.saveOrRollback()

            return ManagedStorageActivationResult(
                rootURL: destination,
                migratedFromURL: migrationResult?.sourceRoot,
                copiedFiles: migrationResult?.copiedFiles ?? 0,
                copiedBytes: migrationResult?.copiedBytes ?? 0
            )
        } catch {
            context.rollback()
            do {
                try pathManager.restoreWorkflowRoot(previousPathRoot)
            } catch let rollbackError {
                pathManager.setRoot(nil)
                throw ManagedStorageActivationError.stateRollbackFailed(
                    "original=\(forgePlayTechnicalErrorSummary(error)); rollback=\(forgePlayTechnicalErrorSummary(rollbackError))"
                )
            }
            throw error
        }
    }

    func relocate(
        in context: ModelContext,
        from sourceRootURL: URL,
        to destinationRootURL: URL,
        destinationBookmark: Data?
    ) async throws -> ManagedStorageActivationResult {
        let source = sourceRootURL.standardizedFileURL
        let destination = destinationRootURL.standardizedFileURL
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }

        let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
        if ForgePlaySandboxPolicy.isAppSandboxEnabled,
           destination.path != defaultManagedRoot.path,
           destinationBookmark == nil {
            throw ManagedStorageActivationError.managedRootBookmarkRequired(destination)
        }

        let settings = try loadOrCreateSettings(in: context)
        let persistedSourcePath = settings.selectedRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        let sourceBookmark = persistedSourcePath == source.path
            ? settings.selectedRootBookmark
            : nil
        let previousPathRoot = pathManager.rootURL
        let transferLeases = try storageMigrationService.acquireManagedDataTransferLeases(
            from: source,
            to: destination
        )
        defer { transferLeases.reversed().forEach { $0.release() } }

        do {
            guard try storageMigrationService.hasManagedData(at: source) else {
                throw ManagedStorageActivationError.managedRootDoesNotContainManagedData(source)
            }
            let migrationResult = try await storageMigrationService.copyManagedDataOnlyAssumingExclusiveTransfer(
                from: source,
                to: destination,
                purpose: .currentRelocation
            )
            _ = try storageMigrationService.rebaseManagedRecords(
                in: context,
                from: source,
                to: destination,
                purpose: .currentRelocation
            )
            try preserveLegacyGameLibraryAccess(
                in: context,
                physicalSourceRoot: source,
                externalizedLibraryPaths: migrationResult.externalizedLibraryPaths,
                bookmark: sourceBookmark,
                preservesBookmarkWithoutKnownLibrary: false
            )

            try pathManager.configureRoot(destination)
            try storageMigrationService.ensureManagedStorageMarker(
                at: destination,
                migratedFrom: source
            )

            settings.selectedRootPath = destination.path
            settings.selectedRootBookmark = destination.path == defaultManagedRoot.path
                ? nil
                : destinationBookmark
            settings.managedStorageLayoutVersion = ForgePlayManagedStorageLayout.currentVersion
            settings.legacyManagedRootPath = source.path
            settings.managedStorageMigrationCompletedAt = Date()
            settings.updatedAt = Date()
            try context.saveOrRollback()

            var sourceCleanupWarning: String?
            do {
                _ = try storageMigrationService.cleanupRelocatedManagedData(
                    at: source,
                    preserving: migrationResult.externalizedLibraryPaths
                )
            } catch {
                sourceCleanupWarning = forgePlayTechnicalErrorSummary(error)
            }

            return ManagedStorageActivationResult(
                rootURL: destination,
                migratedFromURL: source,
                copiedFiles: migrationResult.copiedFiles,
                copiedBytes: migrationResult.copiedBytes,
                sourceCleanupWarning: sourceCleanupWarning
            )
        } catch {
            context.rollback()
            do {
                try pathManager.restoreWorkflowRoot(previousPathRoot)
            } catch let rollbackError {
                pathManager.setRoot(nil)
                throw ManagedStorageActivationError.stateRollbackFailed(
                    "original=\(forgePlayTechnicalErrorSummary(error)); rollback=\(forgePlayTechnicalErrorSummary(rollbackError))"
                )
            }
            throw error
        }
    }

    func importLegacyManagedData(
        in context: ModelContext,
        from sourceRootURL: URL,
        to destinationRootURL: URL,
        sourceBookmark: Data?
    ) async throws -> ManagedStorageActivationResult {
        let source = sourceRootURL.standardizedFileURL
        let destination = destinationRootURL.standardizedFileURL
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }

        let settings = try loadOrCreateSettings(in: context)
        let previousPathRoot = pathManager.rootURL
        let transferLeases = try storageMigrationService.acquireManagedDataTransferLeases(
            from: source,
            to: destination
        )
        defer { transferLeases.reversed().forEach { $0.release() } }

        do {
            guard try storageMigrationService.hasManagedData(at: source) else {
                throw ManagedStorageActivationError.legacyRootDoesNotContainManagedData(source)
            }
            let migrationResult = try await storageMigrationService.copyManagedDataOnlyAssumingExclusiveTransfer(
                from: source,
                to: destination,
                purpose: .legacyImport
            )
            _ = try storageMigrationService.rebaseManagedRecords(
                in: context,
                from: source,
                to: destination,
                purpose: .legacyImport
            )
            try preserveLegacyGameLibraryAccess(
                in: context,
                physicalSourceRoot: source,
                externalizedLibraryPaths: migrationResult.externalizedLibraryPaths,
                bookmark: sourceBookmark,
                preservesBookmarkWithoutKnownLibrary: sourceBookmark != nil
            )

            try pathManager.configureRoot(destination)
            try storageMigrationService.ensureManagedStorageMarker(
                at: destination,
                migratedFrom: source
            )

            let defaultManagedRoot = try PathManager.defaultManagedRootURL().standardizedFileURL
            settings.selectedRootPath = destination.path
            if destination.path == defaultManagedRoot.path {
                settings.selectedRootBookmark = nil
            }
            settings.managedStorageLayoutVersion = ForgePlayManagedStorageLayout.currentVersion
            settings.legacyManagedRootPath = source.path
            settings.managedStorageMigrationCompletedAt = Date()
            settings.updatedAt = Date()
            try context.saveOrRollback()

            return ManagedStorageActivationResult(
                rootURL: destination,
                migratedFromURL: source,
                copiedFiles: migrationResult.copiedFiles,
                copiedBytes: migrationResult.copiedBytes
            )
        } catch {
            context.rollback()
            do {
                try pathManager.restoreWorkflowRoot(previousPathRoot)
            } catch let rollbackError {
                pathManager.setRoot(nil)
                throw ManagedStorageActivationError.stateRollbackFailed(
                    "original=\(forgePlayTechnicalErrorSummary(error)); rollback=\(forgePlayTechnicalErrorSummary(rollbackError))"
                )
            }
            throw error
        }
    }

    private func preserveLegacyGameLibraryAccess(
        in context: ModelContext,
        physicalSourceRoot: URL,
        externalizedLibraryPaths: [String],
        bookmark: Data?,
        preservesBookmarkWithoutKnownLibrary: Bool
    ) throws {
        let games = try context.fetch(FetchDescriptor<SteamGameRecord>())
        let gamesInsideLegacyRoot = games.filter {
            StorageMigrationService.pathIsInsideRoot($0.libraryPath, root: physicalSourceRoot)
        }
        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let hasMountedStorageInsideLegacyRoot = mounts.contains {
            StorageMigrationService.pathIsInsideRoot($0.path, root: physicalSourceRoot)
        }

        guard (preservesBookmarkWithoutKnownLibrary && bookmark != nil) ||
                !gamesInsideLegacyRoot.isEmpty ||
                hasMountedStorageInsideLegacyRoot ||
                !externalizedLibraryPaths.isEmpty else {
            return
        }

        _ = try context.upsertSteamStorageMount(url: physicalSourceRoot, bookmark: bookmark)
        for path in externalizedLibraryPaths {
            let steamRoot = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
            _ = try context.upsertSteamStorageMount(url: steamRoot, bookmark: bookmark)
        }
    }

    private func rebaseLegacyExternalRecords(
        in context: ModelContext,
        from logicalSourceRoot: URL,
        to physicalSourceRoot: URL
    ) throws {
        guard logicalSourceRoot.standardizedFileURL.path != physicalSourceRoot.standardizedFileURL.path else {
            return
        }
        let games = try context.fetch(FetchDescriptor<SteamGameRecord>())
        for game in games {
            game.libraryPath = StorageMigrationService.rebasedPath(
                game.libraryPath,
                from: logicalSourceRoot,
                to: physicalSourceRoot
            ) ?? game.libraryPath
            game.manifestPath = StorageMigrationService.rebasedPath(
                game.manifestPath,
                from: logicalSourceRoot,
                to: physicalSourceRoot
            ) ?? game.manifestPath
        }
        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        for mount in mounts {
            let path = StorageMigrationService.rebasedPath(
                mount.path,
                from: logicalSourceRoot,
                to: physicalSourceRoot
            ) ?? mount.path
            if path != mount.path {
                mount.path = path
                mount.updatedAt = Date()
            }
        }
    }

    private func loadOrCreateSettings(in context: ModelContext) throws -> AppSettingsRecord {
        if let settings = try context.fetch(FetchDescriptor<AppSettingsRecord>()).first {
            return settings
        }
        let settings = AppSettingsRecord()
        context.insert(settings)
        return settings
    }
}
