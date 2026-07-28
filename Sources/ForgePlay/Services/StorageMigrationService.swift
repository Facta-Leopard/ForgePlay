import Darwin
import Foundation
import SwiftData

struct StorageMigrationResult: Hashable {
    var copiedFiles: Int
    var copiedBytes: Int64
    var sourceRoot: URL
    var destinationRoot: URL
    var externalizedLibraryPaths: [String] = []
}

struct StorageRecordRebaseResult: Hashable {
    var runtimeExecutableURL: URL?
    var steamInstallerURL: URL?
    var rebasedPrefixRecords: Int
    var rebasedRuntimeRecords: Int
    var rebasedGameRecords: Int
    var rebasedLaunchRecords: Int
    var rebasedAutoFixRecords: Int
}

enum StorageMigrationError: LocalizedError {
    case sameLocation
    case nestedLocation
    case destinationIsVolumeRoot(URL)
    case destinationNotEmpty(URL)
    case insufficientSpace(required: Int64, available: Int64)
    case unsafeSymlink(URL)
    case unsafeHardlink(URL)
    case scanFailed(URL, String)
    case metadataReadFailed(URL, String)
    case recordProjectionFailed(String)
    case migrationInProgress(URL)
    case cleanupFailed(destination: URL, originalError: Error, cleanupError: Error)

    var errorDescription: String? {
        switch self {
        case .sameLocation:
            "이미 선택된 저장 위치입니다."
        case .nestedLocation:
            "기존 저장 위치 안쪽이나 바깥쪽의 상위 폴더로는 바로 복사할 수 없습니다. 별도의 빈 폴더를 선택하세요."
        case .destinationIsVolumeRoot(let url):
            "드라이브 최상위는 앱 데이터 위치로 사용할 수 없습니다. 드라이브 안에 비어 있는 하위 폴더를 만든 뒤 선택하세요: \(url.path)"
        case .destinationNotEmpty(let url):
            "기존 데이터를 복사하려면 비어 있는 폴더를 선택해야 합니다: \(url.path)"
        case .insufficientSpace(let required, let available):
            "저장 위치를 옮기기에 공간이 부족합니다. 필요 공간: \(required) bytes, 여유 공간: \(available) bytes"
        case .unsafeSymlink(let url):
            "저장 위치를 옮기기 전에 외부를 가리키는 symlink를 제거해야 합니다: \(url.path)"
        case .unsafeHardlink(let url):
            "저장 위치를 옮기기 전에 hardlink 파일을 제거해야 합니다: \(url.path)"
        case .scanFailed(let url, let message):
            "저장 위치를 검사하지 못했습니다: \(url.path). \(message)"
        case .metadataReadFailed(let url, let message):
            "저장 위치의 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .recordProjectionFailed(let field):
            "저장 기록의 \(field) JSON을 UTF-8 텍스트로 저장하지 못했습니다."
        case .migrationInProgress(let url):
            "다른 ForgePlay 프로세스가 내부 저장소 이전을 진행 중입니다: \(url.path)"
        case .cleanupFailed(let destination, let originalError, let cleanupError):
            "저장 위치 이동에 실패했고 부분 복사본을 정리하지 못했습니다: \(destination.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 정리 오류: \(forgePlayTechnicalErrorSummary(cleanupError))"
        }
    }
}

private struct ManagedStorageMarker: Codable {
    var version: Int
    var logicalSourcePath: String?
    var physicalSourcePath: String?
    var externalizedLibraryPaths: [String]
    var completedAt: Date
}

private struct ManagedStorageStagingOwnershipMarker: Codable {
    static let currentVersion = 1

    var version: Int
    var identity: String
    var destinationPath: String
}

private enum MigratableExternalSymlinkPolicy: Equatable {
    case none
    case winePrefix
}

enum ManagedStorageTransferPurpose: Equatable {
    case legacyImport
    case currentRelocation

    var topLevelDirectoryNames: Set<String> {
        switch self {
        case .legacyImport:
            ForgePlayManagedStorageLayout.copiedTopLevelDirectoryNames
        case .currentRelocation:
            ForgePlayManagedStorageLayout.relocatedTopLevelDirectoryNames
        }
    }

    var preservesSnapshots: Bool {
        self == .currentRelocation
    }
}

@MainActor
final class StorageMigrationService {
    private let pathManager: PathManager
    private let fileManager: FileManager
    private let metadataEncoder: JSONEncoder
    private let metadataDecoder: JSONDecoder

    init(pathManager: PathManager, fileManager: FileManager = .default) {
        self.pathManager = pathManager
        self.fileManager = fileManager
        self.metadataEncoder = JSONEncoder()
        self.metadataEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.metadataEncoder.dateEncodingStrategy = .iso8601
        self.metadataDecoder = JSONDecoder()
        self.metadataDecoder.dateDecodingStrategy = .iso8601
    }

    func configureFreshRoot(_ destinationRoot: URL) throws {
        try pathManager.configureRoot(destinationRoot.standardizedFileURL)
    }

    func copyExistingRoot(from sourceRoot: URL, to destinationRoot: URL) async throws -> StorageMigrationResult {
        let source = sourceRoot.standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        let migrationLeases = try acquireManagedDataTransferLeases(
            from: source,
            to: destination
        )
        defer { migrationLeases.reversed().forEach { $0.release() } }

        try pathManager.validateExistingManagedRoot(source)
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }
        guard !Self.isNested(source, inside: destination),
              !Self.isNested(destination, inside: source) else {
            throw StorageMigrationError.nestedLocation
        }
        try Self.validateMigratableLinks(in: source)

        try ensureEmptyDestination(destination)
        let destinationExistedBeforeCopy = fileManager.fileExists(atPath: destination.path)
        let copiedTopLevelNames = try Self.topLevelMigratableItemNames(in: source)
        let sourceSize = try await Task.detached(priority: .userInitiated) {
            try Self.directoryAllocatedSize(source)
        }.value
        let available = try availableCapacity(for: destination)
        guard available >= sourceSize else {
            throw StorageMigrationError.insufficientSpace(required: sourceSize, available: available)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try pathManager.validateWritable(destination)

        let copiedFiles: Int
        do {
            copiedFiles = try await Task.detached(priority: .userInitiated) {
                let copiedFiles = try Self.copyContents(of: source, to: destination)
                try Self.rebasePrefixMetadata(in: destination, from: source, to: destination)
                return copiedFiles
            }.value
            try pathManager.configureRoot(destination)
        } catch {
            do {
                try Self.cleanupPartialMigrationDestination(
                    destination,
                    removeDestinationDirectory: !destinationExistedBeforeCopy,
                    copiedTopLevelNames: copiedTopLevelNames
                )
            } catch let cleanupError {
                throw StorageMigrationError.cleanupFailed(
                    destination: destination,
                    originalError: error,
                    cleanupError: cleanupError
                )
            }
            throw error
        }

        return StorageMigrationResult(
            copiedFiles: copiedFiles,
            copiedBytes: sourceSize,
            sourceRoot: source,
            destinationRoot: destination
        )
    }

    func hasManagedData(at rootURL: URL) throws -> Bool {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.unsafeDirectory(root)
        }
        try Self.requireNonSymlinkDirectory(root, fileManager: fileManager)

        if try hasCurrentManagedStorageMarker(at: root) {
            return true
        }

        let requiredAnchor = root.appending(path: ForgePlayPathRole.prefixes.rawValue, directoryHint: .isDirectory)
        guard try Self.isRegularDirectory(requiredAnchor, fileManager: fileManager) else {
            return false
        }
        let supportingAnchors: Set<String> = [
            ForgePlayPathRole.apps.rawValue,
            ForgePlayPathRole.runtimeCache.rawValue,
            ForgePlayPathRole.config.rawValue
        ]
        for name in supportingAnchors {
            let item = root.appending(path: name, directoryHint: .isDirectory)
            if try Self.isRegularDirectory(item, fileManager: fileManager) { return true }
        }
        return false
    }

    func hasCurrentManagedStorageMarker(at rootURL: URL) throws -> Bool {
        let root = rootURL.standardizedFileURL
        let marker = root.appending(path: ForgePlayManagedStorageLayout.markerFileName)
        guard fileManager.fileExists(atPath: marker.path) else { return false }
        if try isRecoverableFreshManagedDestination(at: root) {
            return false
        }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker, fileManager: fileManager)
            return try Self.readManagedStorageMarker(at: marker).version ==
                ForgePlayManagedStorageLayout.currentVersion
        } catch let error as StorageMigrationError {
            throw error
        } catch {
            throw StorageMigrationError.metadataReadFailed(marker, forgePlayTechnicalErrorSummary(error))
        }
    }

    func copyManagedDataOnly(
        from sourceRoot: URL,
        rebasingPathsFrom logicalSourceRoot: URL? = nil,
        to destinationRoot: URL,
        purpose: ManagedStorageTransferPurpose = .legacyImport
    ) async throws -> StorageMigrationResult {
        let migrationLeases = try acquireManagedDataTransferLeases(
            from: sourceRoot,
            to: destinationRoot
        )
        defer { migrationLeases.reversed().forEach { $0.release() } }
        return try await copyManagedDataOnlyAssumingExclusiveTransfer(
            from: sourceRoot,
            rebasingPathsFrom: logicalSourceRoot,
            to: destinationRoot,
            purpose: purpose
        )
    }

    func acquireManagedDataTransferLeases(
        from sourceRoot: URL,
        to destinationRoot: URL
    ) throws -> [ManagedRootOperationLease] {
        try acquireManagedRootLeases(for: [sourceRoot, destinationRoot])
    }

    func acquireManagedRootLeases(
        for managedRoots: [URL]
    ) throws -> [ManagedRootOperationLease] {
        let roots = managedRoots.map(\.standardizedFileURL)
        guard let errorRoot = roots.last else { return [] }
        do {
            return try ManagedRootOperationLease.acquireExclusive(
                forManagedRoots: roots,
                fileManager: fileManager
            )
        } catch ManagedRootOperationLeaseError.operationInProgress(let lockURL) {
            throw StorageMigrationError.migrationInProgress(lockURL)
        } catch {
            throw StorageMigrationError.metadataReadFailed(
                errorRoot,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    func validateCurrentRelocationPreflight(
        from sourceRoot: URL,
        to destinationRoot: URL
    ) throws {
        let source = sourceRoot.standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }
        try rejectVolumeRootDestination(destination)
        guard !Self.isNested(source, inside: destination),
              !Self.isNested(destination, inside: source) else {
            throw StorageMigrationError.nestedLocation
        }

        let hasMatchingTransferDestination = try validManagedStorageMarker(
            at: destination,
            expectedLogicalSource: source,
            expectedPhysicalSource: source
        ) != nil
        _ = try shouldReplaceDestinationForManagedMigration(
            destination,
            allowsRecoverableFreshDestination: false,
            allowsMatchingTransferDestination: hasMatchingTransferDestination
        )
    }

    func copyManagedDataOnlyAssumingExclusiveTransfer(
        from sourceRoot: URL,
        rebasingPathsFrom logicalSourceRoot: URL? = nil,
        to destinationRoot: URL,
        purpose: ManagedStorageTransferPurpose = .legacyImport
    ) async throws -> StorageMigrationResult {
        let source = sourceRoot.standardizedFileURL
        let logicalSource = (logicalSourceRoot ?? sourceRoot).standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        guard source.path != destination.path else {
            throw StorageMigrationError.sameLocation
        }
        try rejectVolumeRootDestination(destination)
        let allowsNestedLegacyDestination = purpose == .legacyImport &&
            destination.deletingLastPathComponent().standardizedFileURL.path == source.path &&
            destination.lastPathComponent == PathManager.managedDataDirectoryName
        guard !Self.isNested(source, inside: destination),
              (!Self.isNested(destination, inside: source) || allowsNestedLegacyDestination) else {
            throw StorageMigrationError.nestedLocation
        }

        try pathManager.validateExistingManagedRoot(source)

        let hasRecoverableFreshDestination: Bool
        let hasFreshDestinationMarker: Bool
        if purpose == .legacyImport {
            hasFreshDestinationMarker = try hasFreshManagedDestinationMarker(at: destination)
            hasRecoverableFreshDestination = try isRecoverableFreshManagedDestination(at: destination)
        } else {
            hasFreshDestinationMarker = false
            hasRecoverableFreshDestination = false
        }
        if hasFreshDestinationMarker, !hasRecoverableFreshDestination {
            throw StorageMigrationError.destinationNotEmpty(destination)
        }
        if !hasRecoverableFreshDestination {
            _ = try validManagedStorageMarker(
                at: destination,
                expectedLogicalSource: logicalSource,
                expectedPhysicalSource: source
            )
        }

        let sourceItems = try managedMigrationSourceItems(
            in: source,
            topLevelDirectoryNames: purpose.topLevelDirectoryNames
        )
        for item in sourceItems {
            let externalSymlinkPolicy: MigratableExternalSymlinkPolicy =
                item.lastPathComponent == ForgePlayPathRole.prefixes.rawValue ? .winePrefix : .none
            try Self.validateMigratableLinks(
                in: item,
                externalSymlinkPolicy: externalSymlinkPolicy
            )
        }
        let externalizedLibraries = try Self.externalizedSteamAppsDirectories(in: source)
        let excludedPaths = Set(externalizedLibraries.map { $0.standardizedFileURL.path })

        let sourceSize = try await Task.detached(priority: .userInitiated) {
            try sourceItems.reduce(Int64(0)) { partial, item in
                partial + (try Self.directoryAllocatedSize(item, excluding: excludedPaths))
            }
        }.value
        let available = try availableCapacity(for: destination)
        guard available >= sourceSize else {
            throw StorageMigrationError.insufficientSpace(required: sourceSize, available: available)
        }

        let hasMatchingTransferDestination: Bool
        if hasRecoverableFreshDestination {
            hasMatchingTransferDestination = false
        } else {
            hasMatchingTransferDestination = try validManagedStorageMarker(
                at: destination,
                expectedLogicalSource: logicalSource,
                expectedPhysicalSource: source
            ) != nil
        }

        try cleanupAbandonedManagedStorageStagingDirectories(for: destination)
        let replacesExistingDestination = try shouldReplaceDestinationForManagedMigration(
            destination,
            allowsRecoverableFreshDestination: hasRecoverableFreshDestination,
            allowsMatchingTransferDestination: hasMatchingTransferDestination
        )
        let stagingIdentity = UUID()
        let staging = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent)-migration-\(stagingIdentity.uuidString)",
            directoryHint: .isDirectory
        )
        var movedToDestination = false
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try Self.writeManagedStorageStagingOwnershipMarker(
                at: staging,
                identity: stagingIdentity,
                destination: destination
            )
            try pathManager.validateWritable(staging)
            let copiedFiles = try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                var count = 0
                for item in sourceItems {
                    let target = staging.appending(path: item.lastPathComponent, directoryHint: .isDirectory)
                    count += try Self.copyItem(
                        at: item,
                        to: target,
                        excluding: excludedPaths,
                        fileManager: fileManager
                    )
                }
                try Self.rebasePrefixMetadata(
                    in: staging,
                    from: logicalSource,
                    to: destination,
                    clearsSnapshots: !purpose.preservesSnapshots
                )
                try Self.rebaseCopiedExternalSymlinkTargets(
                    in: staging,
                    sourceRoot: source,
                    logicalSource: logicalSource,
                    physicalSource: source,
                    destinationRoot: destination
                )
                try Self.createExternalizedLibraryLinks(
                    in: staging,
                    sourceRoot: source,
                    externalizedLibraries: externalizedLibraries
                )
                let relativeExternalizedPaths = externalizedLibraries.compactMap {
                    Self.relativePath(of: $0, under: source)
                }
                try Self.writeManagedStorageMarker(
                    at: staging,
                    logicalSource: logicalSource,
                    physicalSource: source,
                    externalizedLibraryPaths: relativeExternalizedPaths
                )
                return count
            }.value
            if hasRecoverableFreshDestination {
                try preserveRecoverableFreshDestinationLogs(
                    from: destination,
                    in: staging
                )
            }
            if replacesExistingDestination {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            movedToDestination = true
            try Self.removeManagedStorageStagingOwnershipMarker(
                at: destination,
                identity: stagingIdentity,
                destination: destination,
                fileManager: fileManager
            )
            return StorageMigrationResult(
                copiedFiles: copiedFiles,
                copiedBytes: sourceSize,
                sourceRoot: source,
                destinationRoot: destination,
                externalizedLibraryPaths: externalizedLibraries.map(\.path)
            )
        } catch {
            if !movedToDestination,
               Self.isOwnedManagedStorageStagingDirectory(
                    staging,
                    identity: stagingIdentity,
                    destination: destination,
                    fileManager: fileManager
               ) {
                do {
                    try fileManager.removeItem(at: staging)
                } catch let cleanupError {
                    throw StorageMigrationError.cleanupFailed(
                        destination: staging,
                        originalError: error,
                        cleanupError: cleanupError
                    )
                }
            }
            throw error
        }
    }

    func ensureManagedStorageMarker(at root: URL, migratedFrom source: URL?) throws {
        let marker = root.appending(path: ForgePlayManagedStorageLayout.markerFileName)
        if fileManager.fileExists(atPath: marker.path) {
            if try isRecoverableFreshManagedDestination(at: root) {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker, fileManager: fileManager)
                try fileManager.removeItem(at: marker)
            } else {
                do {
                    try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker, fileManager: fileManager)
                    guard try Self.readManagedStorageMarker(at: marker).version ==
                        ForgePlayManagedStorageLayout.currentVersion else {
                        throw StorageMigrationError.metadataReadFailed(marker, "managed storage marker version mismatch")
                    }
                    return
                } catch let error as StorageMigrationError {
                    throw error
                } catch {
                    throw StorageMigrationError.metadataReadFailed(marker, forgePlayTechnicalErrorSummary(error))
                }
            }
        }
        try Self.writeManagedStorageMarker(
            at: root,
            logicalSource: source,
            physicalSource: source,
            externalizedLibraryPaths: []
        )
    }

    @discardableResult
    func cleanupRelocatedManagedData(
        at sourceRoot: URL,
        preserving protectedPaths: [String]
    ) throws -> Bool {
        let source = sourceRoot.standardizedFileURL
        try pathManager.validateExistingManagedRoot(source)
        let protectedURLs = protectedPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }

        for name in ForgePlayManagedStorageLayout.relocatedTopLevelDirectoryNames.sorted() {
            let item = source.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: item.path) ||
                    (try? fileManager.destinationOfSymbolicLink(atPath: item.path)) != nil else {
                continue
            }
            try Self.removeItem(
                at: item,
                preserving: protectedURLs,
                fileManager: fileManager
            )
        }

        let marker = source.appending(path: ForgePlayManagedStorageLayout.markerFileName)
        if fileManager.fileExists(atPath: marker.path) {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker, fileManager: fileManager)
            try fileManager.removeItem(at: marker)
        }

        guard try Self.isEmptyManagedSkeleton(source, fileManager: fileManager) else {
            return false
        }
        try fileManager.removeItem(at: source)
        return true
    }

    nonisolated static func rebasedPath(_ path: String?, from sourceRoot: URL, to destinationRoot: URL) -> String? {
        guard let path else { return nil }
        let source = sourceRoot.standardizedFileURL.path
        let destination = destinationRoot.standardizedFileURL.path
        if path == source {
            return destination
        }
        let sourcePrefix = source.hasSuffix("/") ? source : source + "/"
        guard path.hasPrefix(sourcePrefix) else {
            return path
        }
        return destination + "/" + String(path.dropFirst(sourcePrefix.count))
    }

    nonisolated static func pathIsInsideRoot(_ path: String?, root: URL) -> Bool {
        guard let path else { return false }
        let source = root.standardizedFileURL.path
        if path == source { return true }
        let sourcePrefix = source.hasSuffix("/") ? source : source + "/"
        return path.hasPrefix(sourcePrefix)
    }

    func rebaseStoredRecords(
        in context: ModelContext,
        from sourceRoot: URL,
        to destinationRoot: URL,
        bookmarkData: (URL, PersistedFileSelectionRole) -> Data?
    ) throws -> StorageRecordRebaseResult {
        let settings = try loadOrCreateSettings(in: context)
        let rebasedSteamInstallerPath = Self.rebasedPath(settings.lastSteamInstallerPath, from: sourceRoot, to: destinationRoot)
        let rebasedSteamInstallerBookmark = rebasedSteamInstallerPath
            .map(URL.init(fileURLWithPath:))
            .flatMap { bookmarkData($0, .steamInstaller) }

        let prefixRecords = try context.fetch(FetchDescriptor<PrefixRecord>())
        let runtimeRecords = try context.fetch(FetchDescriptor<RuntimeRecord>())
        let gameRecords = try context.fetch(FetchDescriptor<SteamGameRecord>())
        let storageMountRecords = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let launchRecords = try context.fetch(FetchDescriptor<LaunchRecord>())
        let autoFixRecords = try context.fetch(FetchDescriptor<AutoFixRecord>())

        let prefixUpdates = try prefixRecords.map { record in
            (
                record: record,
                path: Self.rebasedPath(record.path, from: sourceRoot, to: destinationRoot) ?? record.path,
                snapshotsJSON: try Self.rebasedStringArrayJSON(
                    record.snapshotsJSON,
                    field: "snapshots",
                    from: sourceRoot,
                    to: destinationRoot
                )
            )
        }
        let runtimeUpdates = runtimeRecords.map {
            (record: $0, installLogPath: Self.rebasedPath($0.installLogPath, from: sourceRoot, to: destinationRoot))
        }
        let gameUpdates = gameRecords.map {
            (
                record: $0,
                libraryPath: Self.rebasedPath($0.libraryPath, from: sourceRoot, to: destinationRoot) ?? $0.libraryPath,
                manifestPath: Self.rebasedPath($0.manifestPath, from: sourceRoot, to: destinationRoot) ?? $0.manifestPath
            )
        }
        let storageMountUpdates = storageMountRecords.map { record in
            let path = Self.rebasedPath(record.path, from: sourceRoot, to: destinationRoot) ?? record.path
            return (
                record: record,
                path: path,
                bookmark: path == record.path
                    ? record.bookmark
                    : bookmarkData(URL(fileURLWithPath: path, isDirectory: true), .steamLibrary)
            )
        }
        let launchUpdates = launchRecords.map {
            (
                record: $0,
                stdoutPath: Self.rebasedPath($0.stdoutPath, from: sourceRoot, to: destinationRoot),
                stderrPath: Self.rebasedPath($0.stderrPath, from: sourceRoot, to: destinationRoot)
            )
        }
        let autoFixUpdates = autoFixRecords.map {
            (
                record: $0,
                snapshotPath: Self.rebasedPath($0.snapshotPath, from: sourceRoot, to: destinationRoot),
                logPath: Self.rebasedPath($0.logPath, from: sourceRoot, to: destinationRoot)
            )
        }

        // These columns exist only so old SwiftData stores remain readable.
        // A storage move must not turn a retired external Runtime selection
        // into a current executable or security-scoped bookmark.
        settings.gptkExecutablePath = nil
        settings.gptkExecutableBookmark = nil
        settings.lastSteamInstallerPath = rebasedSteamInstallerPath
        settings.lastSteamInstallerBookmark = rebasedSteamInstallerBookmark

        for update in prefixUpdates {
            update.record.path = update.path
            update.record.snapshotsJSON = update.snapshotsJSON
            update.record.updatedAt = Date()
        }
        for update in runtimeUpdates {
            update.record.installLogPath = update.installLogPath
        }
        for update in gameUpdates {
            update.record.libraryPath = update.libraryPath
            update.record.manifestPath = update.manifestPath
        }
        for update in storageMountUpdates {
            update.record.path = update.path
            update.record.bookmark = update.bookmark
            update.record.updatedAt = Date()
        }
        for update in launchUpdates {
            update.record.stdoutPath = update.stdoutPath
            update.record.stderrPath = update.stderrPath
        }
        for update in autoFixUpdates {
            update.record.snapshotPath = update.snapshotPath
            update.record.logPath = update.logPath
        }

        return StorageRecordRebaseResult(
            runtimeExecutableURL: nil,
            steamInstallerURL: rebasedSteamInstallerPath.map(URL.init(fileURLWithPath:)),
            rebasedPrefixRecords: prefixUpdates.count,
            rebasedRuntimeRecords: runtimeUpdates.count,
            rebasedGameRecords: gameUpdates.count,
            rebasedLaunchRecords: launchUpdates.count,
            rebasedAutoFixRecords: autoFixUpdates.count
        )
    }

    func rebaseManagedRecords(
        in context: ModelContext,
        from sourceRoot: URL,
        to destinationRoot: URL,
        purpose: ManagedStorageTransferPurpose = .legacyImport
    ) throws -> StorageRecordRebaseResult {
        let settings = try loadOrCreateSettings(in: context)
        let rebasedSteamInstallerPath = Self.managedRebasedPath(
            settings.lastSteamInstallerPath,
            from: sourceRoot,
            to: destinationRoot,
            topLevelDirectoryNames: purpose.topLevelDirectoryNames
        )
        let prefixRecords = try context.fetch(FetchDescriptor<PrefixRecord>())
        let runtimeRecords = try context.fetch(FetchDescriptor<RuntimeRecord>())
        let launchRecords = try context.fetch(FetchDescriptor<LaunchRecord>())
        let autoFixRecords = try context.fetch(FetchDescriptor<AutoFixRecord>())

        let prefixUpdates = try prefixRecords.compactMap { record -> (PrefixRecord, String, String)? in
            guard let path = Self.managedRebasedPath(
                record.path,
                from: sourceRoot,
                to: destinationRoot,
                topLevelDirectoryNames: purpose.topLevelDirectoryNames
            ),
                  path != record.path else {
                return nil
            }
            let snapshotsJSON = purpose.preservesSnapshots
                ? try Self.rebasedStringArrayJSON(
                    record.snapshotsJSON,
                    field: "snapshots",
                    from: sourceRoot,
                    to: destinationRoot
                )
                : "[]"
            return (record, path, snapshotsJSON)
        }
        let runtimeUpdates = runtimeRecords.compactMap { record -> (RuntimeRecord, String?)? in
            let path = Self.managedRebasedPath(
                record.installLogPath,
                from: sourceRoot,
                to: destinationRoot,
                topLevelDirectoryNames: purpose.topLevelDirectoryNames
            )
            return path == record.installLogPath ? nil : (record, path)
        }
        let launchUpdates = launchRecords.compactMap { record -> (LaunchRecord, String?, String?, String?)? in
            let stdout = Self.managedRebasedPath(
                record.stdoutPath,
                from: sourceRoot,
                to: destinationRoot,
                topLevelDirectoryNames: purpose.topLevelDirectoryNames
            )
            let stderr = Self.managedRebasedPath(
                record.stderrPath,
                from: sourceRoot,
                to: destinationRoot,
                topLevelDirectoryNames: purpose.topLevelDirectoryNames
            )
            let diagnostic = Self.managedRebasedPath(
                record.diagnosticLogPath,
                from: sourceRoot,
                to: destinationRoot,
                topLevelDirectoryNames: purpose.topLevelDirectoryNames
            )
            guard stdout != record.stdoutPath || stderr != record.stderrPath || diagnostic != record.diagnosticLogPath else {
                return nil
            }
            return (record, stdout, stderr, diagnostic)
        }
        let autoFixUpdates = autoFixRecords.compactMap { record -> (AutoFixRecord, String?, String?)? in
            let legacySnapshotsRoot = sourceRoot.appending(path: ForgePlayPathRole.snapshots.rawValue)
            let snapshot = purpose.preservesSnapshots
                ? Self.managedRebasedPath(
                    record.snapshotPath,
                    from: sourceRoot,
                    to: destinationRoot,
                    topLevelDirectoryNames: purpose.topLevelDirectoryNames
                )
                : (Self.pathIsInsideRoot(record.snapshotPath, root: legacySnapshotsRoot)
                    ? nil
                    : Self.managedRebasedPath(record.snapshotPath, from: sourceRoot, to: destinationRoot))
            let log = Self.managedRebasedPath(
                record.logPath,
                from: sourceRoot,
                to: destinationRoot,
                topLevelDirectoryNames: purpose.topLevelDirectoryNames
            )
            guard snapshot != record.snapshotPath || log != record.logPath else { return nil }
            return (record, snapshot, log)
        }

        settings.gptkExecutablePath = nil
        settings.gptkExecutableBookmark = nil
        if rebasedSteamInstallerPath != settings.lastSteamInstallerPath {
            settings.lastSteamInstallerPath = rebasedSteamInstallerPath
            settings.lastSteamInstallerBookmark = nil
        }
        for (record, path, snapshotsJSON) in prefixUpdates {
            record.path = path
            record.snapshotsJSON = snapshotsJSON
            record.updatedAt = Date()
        }
        for (record, path) in runtimeUpdates {
            record.installLogPath = path
        }
        for (record, stdout, stderr, diagnostic) in launchUpdates {
            record.stdoutPath = stdout
            record.stderrPath = stderr
            record.diagnosticLogPath = diagnostic
        }
        for (record, snapshot, log) in autoFixUpdates {
            record.snapshotPath = snapshot
            record.logPath = log
        }

        return StorageRecordRebaseResult(
            runtimeExecutableURL: nil,
            steamInstallerURL: rebasedSteamInstallerPath.map(URL.init(fileURLWithPath:)),
            rebasedPrefixRecords: prefixUpdates.count,
            rebasedRuntimeRecords: runtimeUpdates.count,
            rebasedGameRecords: 0,
            rebasedLaunchRecords: launchUpdates.count,
            rebasedAutoFixRecords: autoFixUpdates.count
        )
    }

    private func ensureEmptyDestination(_ destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.cannotCreate(destination)
        }
        try Self.requireNonSymlinkDirectory(destination, fileManager: fileManager)
        let contents = try fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let visibleContents = contents.filter { $0.lastPathComponent != ".DS_Store" }
        guard visibleContents.isEmpty else {
            throw StorageMigrationError.destinationNotEmpty(destination)
        }
    }

    private func managedMigrationSourceItems(
        in source: URL,
        topLevelDirectoryNames: Set<String>
    ) throws -> [URL] {
        var items: [URL] = []
        for name in topLevelDirectoryNames.sorted() {
            let item = source.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
                continue
            }
            guard isDirectory.boolValue else {
                throw PathManagerError.cannotCreate(item)
            }
            try Self.requireNonSymlinkDirectory(item, fileManager: fileManager)
            items.append(item)
        }
        return items
    }

    private func isRecoverableFreshManagedDestination(at rootURL: URL) throws -> Bool {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else { return false }
        try Self.requireNonSymlinkDirectory(root, fileManager: fileManager)

        guard try hasFreshManagedDestinationMarker(at: root) else { return false }
        let marker = root.appending(path: ForgePlayManagedStorageLayout.markerFileName)

        let logsRoot = root.appending(path: ForgePlayPathRole.logs.rawValue, directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let markerPath = marker.resolvingSymlinksInPath().standardizedFileURL.path
        var enumerationError: (URL, Error)?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .linkCountKey
            ],
            options: [],
            errorHandler: { failedURL, error in
                enumerationError = (failedURL, error)
                return false
            }
        ) else {
            throw StorageMigrationError.scanFailed(
                root,
                forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown))
            )
        }

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .linkCountKey
            ])
            if values.isSymbolicLink == true {
                return false
            }
            if values.isDirectory == true {
                continue
            }
            if Self.isDiscardableFreshDestinationRuntimeArtifact(item, under: root) {
                if values.isRegularFile == true, (values.linkCount ?? 1) != 1 {
                    return false
                }
                continue
            }
            guard values.isRegularFile == true, (values.linkCount ?? 1) == 1 else {
                return false
            }
            let physicalItemPath = item.resolvingSymlinksInPath().standardizedFileURL.path
            if physicalItemPath == markerPath ||
                item.lastPathComponent == ".DS_Store" ||
                Self.pathIsInsideRoot(physicalItemPath, root: logsRoot) {
                continue
            }
            return false
        }
        if let enumerationError {
            throw StorageMigrationError.scanFailed(
                enumerationError.0,
                forgePlayTechnicalErrorSummary(enumerationError.1)
            )
        }
        return true
    }

    private nonisolated static func isDiscardableFreshDestinationRuntimeArtifact(
        _ item: URL,
        under root: URL
    ) -> Bool {
        guard let relativePath = relativePath(of: item, under: root) else { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        return components.count >= 4 &&
            components[0] == ForgePlayPathRole.prefixes.rawValue &&
            components[2] == ".forgeplay-wineserver"
    }

    private func hasFreshManagedDestinationMarker(at rootURL: URL) throws -> Bool {
        let root = rootURL.standardizedFileURL
        let marker = root.appending(path: ForgePlayManagedStorageLayout.markerFileName)
        guard fileManager.fileExists(atPath: marker.path) else { return false }
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker, fileManager: fileManager)
        return try Self.markerRepresentsFreshDestination(marker)
    }

    private func preserveRecoverableFreshDestinationLogs(
        from root: URL,
        in staging: URL
    ) throws {
        let logs = root.appending(path: ForgePlayPathRole.logs.rawValue, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: logs.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.unsafeDirectory(logs)
        }
        try Self.requireNonSymlinkDirectory(logs, fileManager: fileManager)
        try Self.validateMigratableLinks(in: logs)

        let migratedLogs = staging.appending(
            path: ForgePlayPathRole.logs.rawValue,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: migratedLogs, withIntermediateDirectories: true)
        let recoveredLogs = migratedLogs.appending(
            path: "RecoveredBeforeLegacyImport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.copyItem(at: logs, to: recoveredLogs)
    }

    private nonisolated static func markerRepresentsFreshDestination(_ marker: URL) throws -> Bool {
        if let value = try? readManagedStorageMarker(at: marker) {
            return value.version == ForgePlayManagedStorageLayout.currentVersion &&
                value.logicalSourcePath == nil &&
                value.physicalSourcePath == nil
        }

        let fileSize = try marker.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= 64 * 1024 else { return false }
        let data = try Data(contentsOf: marker, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else { return false }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, fields[key] == nil else { return false }
            fields[key] = value
        }
        return fields == [
            "version": String(ForgePlayManagedStorageLayout.currentVersion),
            "source": "none"
        ]
    }

    private func validManagedStorageMarker(
        at root: URL,
        expectedLogicalSource: URL,
        expectedPhysicalSource: URL
    ) throws -> ManagedStorageMarker? {
        let marker = root.appending(path: ForgePlayManagedStorageLayout.markerFileName)
        guard fileManager.fileExists(atPath: marker.path) else { return nil }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker, fileManager: fileManager)
            let value = try Self.readManagedStorageMarker(at: marker)
            guard value.version == ForgePlayManagedStorageLayout.currentVersion,
                  value.logicalSourcePath == expectedLogicalSource.standardizedFileURL.path,
                  value.physicalSourcePath == expectedPhysicalSource.standardizedFileURL.path else {
                throw StorageMigrationError.metadataReadFailed(
                    marker,
                    "managed storage marker does not match the requested migration source"
                )
            }
            return value
        } catch let error as StorageMigrationError {
            throw error
        } catch {
            throw StorageMigrationError.metadataReadFailed(marker, forgePlayTechnicalErrorSummary(error))
        }
    }

    private func cleanupAbandonedManagedStorageStagingDirectories(
        for destination: URL
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let prefix = ".\(destination.lastPathComponent)-migration-"
        let contents = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for item in contents {
            guard item.lastPathComponent.hasPrefix(prefix),
                  let identity = UUID(
                    uuidString: String(item.lastPathComponent.dropFirst(prefix.count))
                  ),
                  Self.isOwnedManagedStorageStagingDirectory(
                    item,
                    identity: identity,
                    destination: destination,
                    fileManager: fileManager
                  ) else {
                continue
            }
            try fileManager.removeItem(at: item)
        }
    }

    private nonisolated static let managedStorageStagingOwnershipMarkerFileName =
        ".forgeplay-managed-storage-staging-owner.json"

    private nonisolated static func writeManagedStorageStagingOwnershipMarker(
        at staging: URL,
        identity: UUID,
        destination: URL
    ) throws {
        let marker = staging.appending(path: managedStorageStagingOwnershipMarkerFileName)
        let value = ManagedStorageStagingOwnershipMarker(
            version: ManagedStorageStagingOwnershipMarker.currentVersion,
            identity: identity.uuidString,
            destinationPath: destination.standardizedFileURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: marker, options: .atomic)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(marker)
    }

    private nonisolated static func isOwnedManagedStorageStagingDirectory(
        _ staging: URL,
        identity: UUID,
        destination: URL,
        fileManager: FileManager
    ) -> Bool {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(staging, fileManager: fileManager) else {
            return false
        }
        let marker = staging.appending(path: managedStorageStagingOwnershipMarkerFileName)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager),
              let resourceValues = try? marker.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resourceValues.fileSize,
              fileSize <= 64 * 1024,
              let data = try? Data(contentsOf: marker, options: [.mappedIfSafe]),
              let value = try? JSONDecoder().decode(
                ManagedStorageStagingOwnershipMarker.self,
                from: data
              ),
              value.version == ManagedStorageStagingOwnershipMarker.currentVersion,
              UUID(uuidString: value.identity) == identity,
              value.destinationPath == destination.standardizedFileURL.path else {
            return false
        }
        return true
    }

    private nonisolated static func removeManagedStorageStagingOwnershipMarker(
        at root: URL,
        identity: UUID,
        destination: URL,
        fileManager: FileManager
    ) throws {
        guard isOwnedManagedStorageStagingDirectory(
            root,
            identity: identity,
            destination: destination,
            fileManager: fileManager
        ) else {
            throw StorageMigrationError.metadataReadFailed(
                root,
                "managed storage staging ownership marker changed before publication"
            )
        }
        try fileManager.removeItem(
            at: root.appending(path: managedStorageStagingOwnershipMarkerFileName)
        )
    }

    private func shouldReplaceDestinationForManagedMigration(
        _ destination: URL,
        allowsRecoverableFreshDestination: Bool,
        allowsMatchingTransferDestination: Bool
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw StorageMigrationError.destinationNotEmpty(destination)
        }
        try Self.requireNonSymlinkDirectory(destination, fileManager: fileManager)
        if !allowsRecoverableFreshDestination, !allowsMatchingTransferDestination {
            guard try Self.isEmptyManagedSkeleton(destination, fileManager: fileManager) else {
                throw StorageMigrationError.destinationNotEmpty(destination)
            }
        }
        return true
    }

    private func rejectVolumeRootDestination(_ destination: URL) throws {
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let volumeURL: URL
        do {
            let values = try resolvedDestination.resourceValues(forKeys: [.volumeURLKey])
            guard let resolvedVolume = values.volume else {
                throw StorageMigrationError.metadataReadFailed(
                    destination,
                    "the destination volume root is unavailable"
                )
            }
            volumeURL = resolvedVolume.resolvingSymlinksInPath().standardizedFileURL
        } catch let error as StorageMigrationError {
            throw error
        } catch {
            throw StorageMigrationError.metadataReadFailed(
                destination,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        guard resolvedDestination.path != volumeURL.path else {
            throw StorageMigrationError.destinationIsVolumeRoot(destination)
        }
    }

    private nonisolated static func isEmptyManagedSkeleton(
        _ root: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let allowedTopLevelNames = Set(ForgePlayPathRole.allCases.compactMap {
            $0.rawValue.split(separator: "/").first.map(String.init)
        })
        let contents = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for item in contents {
            if item.lastPathComponent == ".DS_Store" { continue }
            guard allowedTopLevelNames.contains(item.lastPathComponent) else { return false }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
            guard try directoryContainsNoFilesOrSymlinks(item, fileManager: fileManager) else { return false }
        }
        return true
    }

    private nonisolated static func isRegularDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.cannotCreate(url)
        }
        try requireNonSymlinkDirectory(url, fileManager: fileManager)
        return true
    }

    private nonisolated static func directoryContainsNoFilesOrSymlinks(
        _ root: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw StorageMigrationError.scanFailed(
                root,
                forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown))
            )
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isDirectory != true {
                return false
            }
        }
        return true
    }

    private func loadOrCreateSettings(in context: ModelContext) throws -> AppSettingsRecord {
        let descriptor = FetchDescriptor<AppSettingsRecord>()
        if let settings = try context.fetch(descriptor).first {
            return settings
        }
        let settings = AppSettingsRecord()
        context.insert(settings)
        return settings
    }

    private nonisolated static func rebasedStringArrayJSON(
        _ json: String,
        field: String,
        from sourceRoot: URL,
        to destinationRoot: URL
    ) throws -> String {
        let data = Data(json.utf8)
        let values = try JSONDecoder().decode([String].self, from: data)
        let rebasedValues = values.map {
            Self.rebasedPath($0, from: sourceRoot, to: destinationRoot) ?? $0
        }
        let updatedData = try JSONEncoder().encode(rebasedValues)
        guard let updatedJSON = String(data: updatedData, encoding: .utf8) else {
            throw StorageMigrationError.recordProjectionFailed(field)
        }
        return updatedJSON
    }

    nonisolated static func managedRebasedPath(
        _ path: String?,
        from sourceRoot: URL,
        to destinationRoot: URL,
        topLevelDirectoryNames: Set<String> = ForgePlayManagedStorageLayout.copiedTopLevelDirectoryNames
    ) -> String? {
        guard let path else { return nil }
        let sourcePath = sourceRoot.standardizedFileURL.path
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        guard path.hasPrefix(sourcePrefix) else { return path }
        let relativePath = String(path.dropFirst(sourcePrefix.count))
        guard let topLevelName = relativePath.split(separator: "/").first.map(String.init),
              topLevelDirectoryNames.contains(topLevelName) else {
            return path
        }
        return destinationRoot.standardizedFileURL.appending(path: relativePath).path
    }

    private nonisolated static func validateMigratableLinks(
        in root: URL,
        externalSymlinkPolicy: MigratableExternalSymlinkPolicy = .none
    ) throws {
        let fileManager = FileManager.default
        var enumerationError: (URL, Error)?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .linkCountKey],
            options: [],
            errorHandler: { url, error in
                enumerationError = (url, error)
                return false
            }
        ) else {
            throw StorageMigrationError.scanFailed(root, forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown)))
        }

        for case let item as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .linkCountKey])
            } catch {
                throw StorageMigrationError.metadataReadFailed(item, forgePlayTechnicalErrorSummary(error))
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                let target: String
                do {
                    target = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                } catch {
                    throw StorageMigrationError.metadataReadFailed(item, forgePlayTechnicalErrorSummary(error))
                }
                if target.hasPrefix("/") {
                    guard externalSymlinkPolicy == .winePrefix,
                          isAllowedWinePrefixExternalSymlink(item, under: root) else {
                        throw StorageMigrationError.unsafeSymlink(item)
                    }
                    continue
                }
                let resolvedTarget = URL(
                    fileURLWithPath: target,
                    relativeTo: item.deletingLastPathComponent()
                ).standardizedFileURL
                guard pathIsInsideRoot(resolvedTarget.path, root: root) ||
                    (externalSymlinkPolicy == .winePrefix &&
                        isAllowedWinePrefixExternalSymlink(item, under: root)) else {
                    throw StorageMigrationError.unsafeSymlink(item)
                }
                continue
            }
            if values.isRegularFile == true, (values.linkCount ?? 1) != 1 {
                throw StorageMigrationError.unsafeHardlink(item)
            }
        }
        if let enumerationError {
            throw StorageMigrationError.scanFailed(
                enumerationError.0,
                forgePlayTechnicalErrorSummary(enumerationError.1)
            )
        }
    }

    private nonisolated static func isAllowedWinePrefixExternalSymlink(
        _ item: URL,
        under prefixesRoot: URL
    ) -> Bool {
        guard let relative = relativePath(of: item, under: prefixesRoot) else { return false }
        let components = relative.split(separator: "/").map(String.init)
        guard components.count >= 3 else { return false }

        if components[1] == "dosdevices" {
            return true
        }
        if components[1] == ".forgeplay-library-drives" {
            return true
        }
        if components.count == 5,
           Array(components[1...]) == ["drive_c", "Program Files (x86)", "Steam", "steamapps"] {
            return true
        }
        return components.count >= 4 &&
            components[1] == "drive_c" &&
            components[2] == "users"
    }

    private nonisolated static func writeManagedStorageMarker(
        at root: URL,
        logicalSource: URL?,
        physicalSource: URL?,
        externalizedLibraryPaths: [String]
    ) throws {
        let marker = root.appending(path: ForgePlayManagedStorageLayout.markerFileName)
        let value = ManagedStorageMarker(
            version: ForgePlayManagedStorageLayout.currentVersion,
            logicalSourcePath: logicalSource?.standardizedFileURL.path,
            physicalSourcePath: physicalSource?.standardizedFileURL.path,
            externalizedLibraryPaths: externalizedLibraryPaths.sorted(),
            completedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: marker, options: [.atomic])
    }

    private nonisolated static func readManagedStorageMarker(
        at marker: URL
    ) throws -> ManagedStorageMarker {
        let fileSize = try marker.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= 64 * 1024 else {
            throw StorageMigrationError.metadataReadFailed(marker, "managed storage marker is too large")
        }
        let data = try Data(contentsOf: marker, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ManagedStorageMarker.self, from: data)
    }

    private nonisolated static func externalizedSteamAppsDirectories(
        in sourceRoot: URL
    ) throws -> [URL] {
        var results: [URL] = []
        let steamApps = sourceRoot
            .appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue, directoryHint: .isDirectory)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: steamApps.path)) == nil,
           try containsSteamGameLibraryPayload(in: steamApps) {
            results.append(steamApps.standardizedFileURL)
        }

        let managedLibraries = sourceRoot.appending(
            path: ForgePlayPathRole.steamLibraries.rawValue,
            directoryHint: .isDirectory
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: managedLibraries.path, isDirectory: &isDirectory) else {
            return results
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.cannotCreate(managedLibraries)
        }
        try requireNonSymlinkDirectory(managedLibraries, fileManager: .default)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: managedLibraries,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let candidateSteamApps = candidate.appending(path: "steamapps", directoryHint: .isDirectory)
            if try containsSteamGameLibraryPayload(in: candidateSteamApps) {
                results.append(candidateSteamApps.standardizedFileURL)
            }
        }
        return Array(Set(results)).sorted { $0.path < $1.path }
    }

    private nonisolated static func containsSteamGameLibraryPayload(
        in steamApps: URL
    ) throws -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: steamApps.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.cannotCreate(steamApps)
        }
        try requireNonSymlinkDirectory(steamApps, fileManager: fileManager)
        let contents = try fileManager.contentsOfDirectory(
            at: steamApps,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        if contents.contains(where: {
            $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension.lowercased() == "acf"
        }) {
            return true
        }
        let payloadDirectoryNames: Set<String> = [
            "common",
            "compatdata",
            "downloading",
            "shadercache",
            "sourcemods",
            "temp",
            "workshop"
        ]
        for item in contents where payloadDirectoryNames.contains(item.lastPathComponent.lowercased()) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PathManagerError.unsafeDirectory(item)
            }
            if try !fileManager.contentsOfDirectory(atPath: item.path).isEmpty {
                return true
            }
        }
        return false
    }

    private nonisolated static func copyItem(
        at source: URL,
        to destination: URL,
        excluding excludedPaths: Set<String>,
        fileManager: FileManager
    ) throws -> Int {
        let sourcePath = source.standardizedFileURL.path
        if excludedPaths.contains(sourcePath) {
            return 0
        }
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        let nestedExclusions = excludedPaths.filter { $0.hasPrefix(sourcePrefix) }
        if nestedExclusions.isEmpty {
            try fileManager.copyItem(at: source, to: destination)
            return try copiedFileCount(at: source, fileManager: fileManager)
        }

        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            try fileManager.copyItem(at: source, to: destination)
            return 1
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var count = 0
        for child in children {
            count += try copyItem(
                at: child,
                to: destination.appending(path: child.lastPathComponent),
                excluding: excludedPaths,
                fileManager: fileManager
            )
        }
        return count
    }

    private nonisolated static func removeItem(
        at item: URL,
        preserving protectedURLs: [URL],
        fileManager: FileManager
    ) throws {
        let normalizedItem = item.standardizedFileURL
        if protectedURLs.contains(where: { $0.path == normalizedItem.path }) {
            return
        }
        let itemPrefix = normalizedItem.path.hasSuffix("/")
            ? normalizedItem.path
            : normalizedItem.path + "/"
        let protectedDescendants = protectedURLs.filter { $0.path.hasPrefix(itemPrefix) }
        guard !protectedDescendants.isEmpty else {
            try fileManager.removeItem(at: normalizedItem)
            return
        }

        let values = try normalizedItem.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StorageMigrationError.unsafeSymlink(normalizedItem)
        }
        let children = try fileManager.contentsOfDirectory(
            at: normalizedItem,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for child in children {
            try removeItem(
                at: child,
                preserving: protectedDescendants,
                fileManager: fileManager
            )
        }
        if try fileManager.contentsOfDirectory(atPath: normalizedItem.path).isEmpty {
            try fileManager.removeItem(at: normalizedItem)
        }
    }

    private nonisolated static func createExternalizedLibraryLinks(
        in stagingRoot: URL,
        sourceRoot: URL,
        externalizedLibraries: [URL]
    ) throws {
        let fileManager = FileManager.default
        for sourceLibrary in externalizedLibraries {
            guard let relativePath = relativePath(of: sourceLibrary, under: sourceRoot) else {
                throw StorageMigrationError.scanFailed(
                    sourceLibrary,
                    "externalized Steam library is outside the legacy root"
                )
            }
            let link = stagingRoot.appending(path: relativePath, directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: link.path) ||
                (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: sourceLibrary)
        }
    }

    private nonisolated static func rebaseCopiedExternalSymlinkTargets(
        in stagingRoot: URL,
        sourceRoot: URL,
        logicalSource: URL,
        physicalSource: URL,
        destinationRoot: URL
    ) throws {
        let prefixes = stagingRoot.appending(path: ForgePlayPathRole.prefixes.rawValue, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: prefixes.path) else { return }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: prefixes,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw StorageMigrationError.scanFailed(prefixes, "could not enumerate copied prefix symlinks")
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            guard let relativeItemPath = relativePath(of: item, under: stagingRoot) else {
                continue
            }
            let sourceItem = sourceRoot.appending(path: relativeItemPath)
            let sourceTarget = try fileManager.destinationOfSymbolicLink(atPath: sourceItem.path)
            let resolvedSourceTarget = sourceTarget.hasPrefix("/")
                ? URL(fileURLWithPath: sourceTarget).standardizedFileURL
                : URL(
                    fileURLWithPath: sourceTarget,
                    relativeTo: sourceItem.deletingLastPathComponent()
                ).standardizedFileURL

            let sourcePrefix = sourceItem
                .deletingLastPathComponent()
                .pathComponents
                .firstIndex(of: ForgePlayPathRole.prefixes.rawValue)
                .flatMap { prefixesIndex -> URL? in
                    let components = sourceItem.pathComponents
                    guard components.indices.contains(prefixesIndex + 1) else { return nil }
                    return sourceRoot
                        .appending(path: ForgePlayPathRole.prefixes.rawValue, directoryHint: .isDirectory)
                        .appending(path: components[prefixesIndex + 1], directoryHint: .isDirectory)
                }

            let rebasedTarget: String
            if let sourcePrefix,
               pathIsInsideRoot(resolvedSourceTarget.path, root: sourcePrefix) {
                guard sourceTarget.hasPrefix("/"),
                      let destinationPath = rebasedPath(
                        resolvedSourceTarget.path,
                        from: sourceRoot,
                        to: destinationRoot
                      ) else {
                    continue
                }
                rebasedTarget = destinationPath
            } else {
                rebasedTarget = rebasedPath(
                    resolvedSourceTarget.path,
                    from: logicalSource,
                    to: physicalSource
                ) ?? resolvedSourceTarget.path
            }

            let copiedTarget = try fileManager.destinationOfSymbolicLink(atPath: item.path)
            guard copiedTarget != rebasedTarget else {
                continue
            }
            try fileManager.removeItem(at: item)
            try fileManager.createSymbolicLink(
                atPath: item.path,
                withDestinationPath: rebasedTarget
            )
        }
    }

    private nonisolated static func relativePath(
        of item: URL,
        under root: URL
    ) -> String? {
        let itemPath = item
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appending(path: item.lastPathComponent)
            .standardizedFileURL
            .path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { return nil }
        return String(itemPath.dropFirst(prefix.count))
    }

    private nonisolated static func copyContents(of source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var copiedFiles = 0
        for item in contents {
            let target = destination.appending(path: item.lastPathComponent)
            try fileManager.copyItem(at: item, to: target)
            copiedFiles += try copiedFileCount(at: item, fileManager: fileManager)
        }
        return copiedFiles
    }

    private nonisolated static func topLevelMigratableItemNames(in source: URL) throws -> Set<String> {
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(contents.map(\.lastPathComponent))
    }

    private nonisolated static func cleanupPartialMigrationDestination(
        _ destination: URL,
        removeDestinationDirectory: Bool,
        copiedTopLevelNames: Set<String>,
        fileManager: FileManager = .default
    ) throws {
        try Self.requireNonSymlinkDirectory(destination, fileManager: fileManager)
        if removeDestinationDirectory {
            try fileManager.removeItem(at: destination)
            return
        }
        for name in copiedTopLevelNames {
            let item = destination.appending(path: name)
            if fileManager.fileExists(atPath: item.path) ||
                (try? fileManager.destinationOfSymbolicLink(atPath: item.path)) != nil {
                try fileManager.removeItem(at: item)
            }
        }
    }

    private nonisolated static func copiedFileCount(at url: URL, fileManager: FileManager) throws -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        guard isDirectory.boolValue else {
            return 1
        }
        var enumerationError: (URL, Error)?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { failedURL, error in
                enumerationError = (failedURL, error)
                return false
            }
        ) else {
            throw StorageMigrationError.scanFailed(url, forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown)))
        }
        var count = 0
        for case let fileURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                throw StorageMigrationError.metadataReadFailed(fileURL, forgePlayTechnicalErrorSummary(error))
            }
            if values.isDirectory != true {
                count += 1
            }
        }
        if let enumerationError {
            throw StorageMigrationError.scanFailed(
                enumerationError.0,
                forgePlayTechnicalErrorSummary(enumerationError.1)
            )
        }
        return count
    }

    private nonisolated static func requireNonSymlinkDirectory(_ url: URL, fileManager: FileManager) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            throw PathManagerError.unsafeDirectory(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw StorageMigrationError.metadataReadFailed(url, message)
        } catch {
            throw StorageMigrationError.scanFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private nonisolated static func directoryAllocatedSize(
        _ url: URL,
        excluding excludedPaths: Set<String> = []
    ) throws -> Int64 {
        var enumerationError: (URL, Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [],
            errorHandler: { failedURL, error in
                enumerationError = (failedURL, error)
                return false
            }
        ) else {
            throw StorageMigrationError.scanFailed(url, forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown)))
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if excludedPaths.contains(fileURL.standardizedFileURL.path) {
                enumerator.skipDescendants()
                continue
            }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            } catch {
                throw StorageMigrationError.metadataReadFailed(fileURL, forgePlayTechnicalErrorSummary(error))
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        if let enumerationError {
            throw StorageMigrationError.scanFailed(
                enumerationError.0,
                forgePlayTechnicalErrorSummary(enumerationError.1)
            )
        }
        return total
    }

    private func availableCapacity(for destination: URL) throws -> Int64 {
        let probeRoot = fileManager.fileExists(atPath: destination.path) ? destination : destination.deletingLastPathComponent()
        let values = try probeRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private nonisolated static func rebasePrefixMetadata(
        in root: URL,
        from sourceRoot: URL,
        to destinationRoot: URL,
        clearsSnapshots: Bool = false
    ) throws {
        let fileManager = FileManager.default
        let metadataEncoder = JSONEncoder()
        metadataEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        metadataEncoder.dateEncodingStrategy = .iso8601
        let metadataDecoder = JSONDecoder()
        metadataDecoder.dateDecodingStrategy = .iso8601
        let prefixesRoot = root.appending(path: ForgePlayPathRole.prefixes.rawValue, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: prefixesRoot.path) else {
            return
        }
        var enumerationError: (URL, Error)?
        guard let enumerator = fileManager.enumerator(
            at: prefixesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { failedURL, error in
                enumerationError = (failedURL, error)
                return false
            }
        ) else {
            throw StorageMigrationError.scanFailed(prefixesRoot, forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown)))
        }

        for case let metadataURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try metadataURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw StorageMigrationError.metadataReadFailed(metadataURL, forgePlayTechnicalErrorSummary(error))
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard metadataURL.lastPathComponent == "prefix.json", values.isRegularFile == true else { continue }
            let fileSize: Int
            do {
                fileSize = try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            } catch {
                throw StorageMigrationError.metadataReadFailed(metadataURL, forgePlayTechnicalErrorSummary(error))
            }
            guard fileSize <= PrefixManager.maxMetadataBytes else {
                throw PrefixMetadataError.metadataTooLarge(metadataURL, fileSize, PrefixManager.maxMetadataBytes)
            }
            let data = try Data(contentsOf: metadataURL)
            guard data.count <= PrefixManager.maxMetadataBytes else {
                throw PrefixMetadataError.metadataTooLarge(metadataURL, data.count, PrefixManager.maxMetadataBytes)
            }
            var metadata = try metadataDecoder.decode(PrefixMetadata.self, from: data)
            metadata.path = Self.rebasedPath(metadata.path, from: sourceRoot, to: destinationRoot) ?? metadata.path
            metadata.snapshots = clearsSnapshots
                ? []
                : metadata.snapshots.map {
                    Self.rebasedPath($0, from: sourceRoot, to: destinationRoot) ?? $0
                }
            metadata.launchOptions = normalizedLaunchOptions(metadata.launchOptions)
            metadata.environmentVariables = [:]
            metadata.updatedAt = Date()
            let updated = try metadataEncoder.encode(metadata)
            guard updated.count <= PrefixManager.maxMetadataBytes else {
                throw PrefixMetadataError.metadataTooLarge(metadataURL, updated.count, PrefixManager.maxMetadataBytes)
            }
            try updated.write(to: metadataURL, options: [.atomic])
        }
        if let enumerationError {
            throw StorageMigrationError.scanFailed(
                enumerationError.0,
                forgePlayTechnicalErrorSummary(enumerationError.1)
            )
        }
    }

    private nonisolated static func normalizedLaunchOptions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            LLMRecommendedActionPolicy.normalizedLaunchOption($0)
        }.filter {
            seen.insert($0).inserted
        }
    }

    private nonisolated static func isNested(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(rootPrefix)
    }
}
