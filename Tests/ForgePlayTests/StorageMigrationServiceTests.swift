import SwiftData
import XCTest
@testable import ForgePlay

private final class StorageMigrationCleanupObservingFileManager: FileManager {
    private let observationLock = NSLock()
    private var removalMainThreadObservations: [Bool] = []
    private var enumerationMainThreadObservations: [Bool] = []
    private var observesPresenceScan = false

    var removalCount: Int {
        observationLock.withLock { removalMainThreadObservations.count }
    }

    var observedMainThreadRemoval: Bool {
        observationLock.withLock { removalMainThreadObservations.contains(true) }
    }

    var enumerationCount: Int {
        observationLock.withLock { enumerationMainThreadObservations.count }
    }

    var observedMainThreadEnumeration: Bool {
        observationLock.withLock { enumerationMainThreadObservations.contains(true) }
    }

    override func removeItem(at URL: URL) throws {
        observationLock.withLock {
            removalMainThreadObservations.append(Thread.isMainThread)
        }
        try super.removeItem(at: URL)
    }

    func beginPresenceScanObservation() {
        observationLock.withLock {
            enumerationMainThreadObservations.removeAll(keepingCapacity: true)
            observesPresenceScan = true
        }
    }

    override func fileExists(
        atPath path: String,
        isDirectory: UnsafeMutablePointer<ObjCBool>?
    ) -> Bool {
        observationLock.withLock {
            if observesPresenceScan {
                enumerationMainThreadObservations.append(Thread.isMainThread)
            }
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
}

@MainActor
final class StorageMigrationServiceTests: XCTestCase {
    func testManagedStoragePresenceScanRunsOutsideMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlay-managed-presence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = StorageMigrationCleanupObservingFileManager()
        let pathManager = PathManager(fileManager: fileManager)
        try pathManager.configureRoot(root)
        try "version=\(ForgePlayManagedStorageLayout.currentVersion)\nsource=none\n".write(
            to: root.appending(path: ForgePlayManagedStorageLayout.markerFileName),
            atomically: true,
            encoding: .utf8
        )
        let service = StorageMigrationService(
            pathManager: pathManager,
            fileManager: fileManager
        )

        fileManager.beginPresenceScanObservation()
        let hasCurrentMarker = try await service
            .hasCurrentManagedStorageMarker(at: root)
        XCTAssertFalse(hasCurrentMarker)
        XCTAssertGreaterThan(fileManager.enumerationCount, 0)
        XCTAssertFalse(fileManager.observedMainThreadEnumeration)
    }

    func testRebaseStoredRecordsUpdatesSwiftDataPaths() throws {
        let source = URL(fileURLWithPath: "/tmp/ForgePlayRecordSource")
        let destination = URL(fileURLWithPath: "/tmp/ForgePlayRecordDestination")
        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        let service = StorageMigrationService(pathManager: pathManager)
        let settings = AppSettingsRecord(
            gptkExecutablePath: source.appending(path: "LegacyRuntimeSelection/wine").path,
            gptkExecutableBookmark: Data("retired-runtime-bookmark".utf8),
            lastSteamInstallerPath: source.appending(path: "RuntimeCache/Installers/SteamSetup.exe").path
        )
        let prefix = PrefixRecord(
            id: "prefix",
            displayName: "Prefix",
            path: source.appending(path: "Prefixes/SteamShared").path,
            snapshotsJSON: #"["/tmp/ForgePlayRecordSource/Snapshots/Prefixes/snapshot-a","/tmp/external-snapshot"]"#
        )
        let runtime = RuntimeRecord(
            id: "runtime",
            prefixId: "prefix",
            runtime: .vcrun2022,
            installLogPath: source.appending(path: "Logs/Launch/runtime.log").path
        )
        let game = SteamGameRecord(
            steamAppId: "42",
            name: "Record Game",
            installDir: "Record Game",
            libraryPath: source.appending(path: "SteamLibraries/DefaultLibrary").path,
            manifestPath: source.appending(path: "SteamLibraries/DefaultLibrary/steamapps/appmanifest_42.acf").path
        )
        let storageMount = SteamStorageMountRecord(
            path: source.appending(path: "SteamLibraries/DefaultLibrary").path,
            bookmark: Data("old-bookmark".utf8)
        )
        let launch = LaunchRecord(
            id: "launch",
            gameId: "42",
            prefixId: "prefix",
            commandKind: "game",
            stdoutPath: source.appending(path: "Logs/Launch/stdout.log").path,
            stderrPath: source.appending(path: "Logs/Launch/stderr.log").path
        )
        let autoFix = AutoFixRecord(
            id: "autofix",
            diagnosticId: "diagnostic",
            actionType: .installRuntime,
            status: "applied",
            snapshotPath: source.appending(path: "Snapshots/Prefixes/snapshot-a").path,
            logPath: source.appending(path: "Logs/Launch/autofix.log").path
        )
        context.insert(settings)
        context.insert(prefix)
        context.insert(runtime)
        context.insert(game)
        context.insert(storageMount)
        context.insert(launch)
        context.insert(autoFix)
        try context.save()

        let result = try service.rebaseStoredRecords(
            in: context,
            from: source,
            to: destination,
            bookmarkData: { _, role in Data(role.rawValue.utf8) }
        )

        XCTAssertNil(result.runtimeExecutableURL)
        XCTAssertEqual(result.steamInstallerURL?.path, destination.appending(path: "RuntimeCache/Installers/SteamSetup.exe").path)
        XCTAssertEqual(result.rebasedPrefixRecords, 1)
        XCTAssertEqual(result.rebasedRuntimeRecords, 1)
        XCTAssertEqual(result.rebasedGameRecords, 1)
        XCTAssertEqual(result.rebasedLaunchRecords, 1)
        XCTAssertEqual(result.rebasedAutoFixRecords, 1)
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerPath, destination.appending(path: "RuntimeCache/Installers/SteamSetup.exe").path)
        XCTAssertEqual(settings.lastSteamInstallerBookmark, Data(PersistedFileSelectionRole.steamInstaller.rawValue.utf8))
        XCTAssertEqual(prefix.path, destination.appending(path: "Prefixes/SteamShared").path)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(prefix.snapshotsJSON.utf8)),
            [
                destination.appending(path: "Snapshots/Prefixes/snapshot-a").path,
                "/tmp/external-snapshot"
            ]
        )
        XCTAssertEqual(runtime.installLogPath, destination.appending(path: "Logs/Launch/runtime.log").path)
        XCTAssertEqual(game.libraryPath, destination.appending(path: "SteamLibraries/DefaultLibrary").path)
        XCTAssertEqual(game.manifestPath, destination.appending(path: "SteamLibraries/DefaultLibrary/steamapps/appmanifest_42.acf").path)
        XCTAssertEqual(storageMount.path, destination.appending(path: "SteamLibraries/DefaultLibrary").path)
        XCTAssertEqual(storageMount.bookmark, Data(PersistedFileSelectionRole.steamLibrary.rawValue.utf8))
        XCTAssertEqual(launch.stdoutPath, destination.appending(path: "Logs/Launch/stdout.log").path)
        XCTAssertEqual(launch.stderrPath, destination.appending(path: "Logs/Launch/stderr.log").path)
        XCTAssertEqual(autoFix.snapshotPath, destination.appending(path: "Snapshots/Prefixes/snapshot-a").path)
        XCTAssertEqual(autoFix.logPath, destination.appending(path: "Logs/Launch/autofix.log").path)
    }

    func testRebaseStoredRecordsRejectsInvalidPrefixSnapshotsJSONBeforeMutation() throws {
        let source = URL(fileURLWithPath: "/tmp/ForgePlayRecordSource")
        let destination = URL(fileURLWithPath: "/tmp/ForgePlayRecordDestination")
        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        let service = StorageMigrationService(pathManager: pathManager)
        let originalPath = source.appending(path: "Prefixes/SteamShared").path
        let prefix = PrefixRecord(
            id: "prefix",
            displayName: "Prefix",
            path: originalPath,
            snapshotsJSON: "{not-json"
        )
        context.insert(AppSettingsRecord())
        context.insert(prefix)
        try context.save()

        XCTAssertThrowsError(
            try service.rebaseStoredRecords(
                in: context,
                from: source,
                to: destination,
                bookmarkData: { _, _ in Data() }
            )
        )
        XCTAssertEqual(prefix.path, originalPath)
        XCTAssertEqual(prefix.snapshotsJSON, "{not-json")
    }

    func testRebaseStoredRecordsUsesFailableUTF8ProjectionForSnapshotsJSON() throws {
        let source = try String(
            contentsOf: projectRoot()
                .appending(path: "Sources/ForgePlay/Services/StorageMigrationService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case recordProjectionFailed(String)"))
        XCTAssertTrue(source.contains("guard let updatedJSON = String(data: updatedData, encoding: .utf8) else"))
        XCTAssertTrue(source.contains("throw StorageMigrationError.recordProjectionFailed(field)"))
        XCTAssertFalse(source.contains("String(data: updatedData, encoding: .utf8) ?? json"))
    }

    func testCopiesRootAndRebasesPrefixMetadata() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: destination) }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        var metadata = try writeStoredPrefixMetadataFixture(
            prefixManager: prefixManager,
            root: source,
            steamAppId: "42",
            name: "Migration Test"
        )
        metadata.snapshots = [source.appending(path: "Snapshots/Prefixes/test-snapshot").path]
        try prefixManager.save(metadata, at: URL(fileURLWithPath: metadata.path))

        let service = StorageMigrationService(pathManager: pathManager)
        let result = try await service.copyExistingRoot(from: source, to: destination)
        let migratedMetadata = try prefixManager.loadMetadata(
            at: destination.appending(path: "Prefixes/Steam-42-MigrationTest")
        )

        XCTAssertGreaterThan(result.copiedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(migratedMetadata.path, destination.appending(path: "Prefixes/Steam-42-MigrationTest").path)
        XCTAssertEqual(
            migratedMetadata.snapshots.first,
            destination.appending(path: "Snapshots/Prefixes/test-snapshot").path
        )
    }

    func testCopyExistingRootRejectsConcurrentDestinationMutation() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExistingRootLock-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "Destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let activeLease = try ManagedRootOperationLease.acquireExclusive(forManagedRoot: destination)
        defer { activeLease.release() }

        let service = StorageMigrationService(pathManager: pathManager)
        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected an active destination lease to reject root copying")
        } catch StorageMigrationError.migrationInProgress(let lockURL) {
            XCTAssertEqual(
                lockURL.standardizedFileURL.path,
                activeLease.lockURL.standardizedFileURL.path
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationNormalizesUnsafePrefixMetadataLaunchOptions() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: destination) }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        var metadata = try writeStoredPrefixMetadataFixture(
            prefixManager: prefixManager,
            root: source,
            steamAppId: "77",
            name: "Unsafe Metadata"
        )
        metadata.launchOptions = [" -Windowed ", "; rm -rf /", "-windowed", "-force-d3d11"]
        metadata.environmentVariables = ["DYLD_LIBRARY_PATH": "/tmp/injected"]
        metadata.snapshots = [source.appending(path: "Snapshots/Prefixes/unsafe").path]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: URL(fileURLWithPath: metadata.path).appending(path: "prefix.json")
        )

        let service = StorageMigrationService(pathManager: pathManager)
        _ = try await service.copyExistingRoot(from: source, to: destination)

        let migratedMetadataURL = destination
            .appending(path: "Prefixes/Steam-77-UnsafeMetadata", directoryHint: .isDirectory)
            .appending(path: "prefix.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migratedMetadata = try decoder.decode(
            PrefixMetadata.self,
            from: Data(contentsOf: migratedMetadataURL)
        )

        XCTAssertEqual(migratedMetadata.launchOptions, ["-windowed", "-force-d3d11"])
        XCTAssertTrue(migratedMetadata.environmentVariables.isEmpty)
        XCTAssertEqual(
            migratedMetadata.snapshots,
            [destination.appending(path: "Snapshots/Prefixes/unsafe").path]
        )
    }

    func testMigrationRejectsOversizedPrefixMetadata() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: destination) }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let prefixURL = source.appending(path: "Prefixes/Oversized", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 300 * 1024)
            .write(to: prefixURL.appending(path: "prefix.json"))

        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected oversized prefix metadata to be rejected")
        } catch PrefixMetadataError.metadataTooLarge(let url, let byteCount, let limit) {
            XCTAssertEqual(
                normalizedSystemAliasPath(url.standardizedFileURL.path),
                normalizedSystemAliasPath(destination.appending(path: "Prefixes/Oversized/prefix.json").standardizedFileURL.path)
            )
            XCTAssertEqual(byteCount, 300 * 1024)
            XCTAssertLessThan(limit, byteCount)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationCleansCopiedContentsButPreservesExistingEmptyDestinationOnRebaseFailure() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: destination) }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let prefixURL = source.appending(path: "Prefixes/Oversized", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 300 * 1024)
            .write(to: prefixURL.appending(path: "prefix.json"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("finder metadata".utf8).write(to: destination.appending(path: ".DS_Store"))

        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected oversized prefix metadata to be rejected")
        } catch PrefixMetadataError.metadataTooLarge {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: ".DS_Store").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "Prefixes").path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationSurfacesUnreadableSourceDirectoryBeforeCopying() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        let unreadableDirectory = source
            .appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
            .appending(path: "LockedData", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try Data("locked payload".utf8).write(to: unreadableDirectory.appending(path: "payload.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectory.path)

        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected unreadable source directory to fail migration")
        } catch StorageMigrationError.scanFailed(let url, let message) {
            XCTAssertTrue(
                unreadableDirectory.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path) ||
                    url.standardizedFileURL.path.hasPrefix(unreadableDirectory.standardizedFileURL.path),
                "Unexpected scan failure URL: \(url.path)"
            )
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch StorageMigrationError.metadataReadFailed(let url, let message) {
            XCTAssertTrue(
                unreadableDirectory.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path) ||
                    url.standardizedFileURL.path.hasPrefix(unreadableDirectory.standardizedFileURL.path),
                "Unexpected metadata failure URL: \(url.path)"
            )
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRebasesOnlyPathsInsideSourceRoot() {
        let source = URL(fileURLWithPath: "/tmp/ForgePlayA")
        let destination = URL(fileURLWithPath: "/tmp/ForgePlayB")

        XCTAssertEqual(
            StorageMigrationService.rebasedPath("/tmp/ForgePlayA/Logs/a.log", from: source, to: destination),
            "/tmp/ForgePlayB/Logs/a.log"
        )
        XCTAssertEqual(
            StorageMigrationService.rebasedPath("/tmp/Other/a.log", from: source, to: destination),
            "/tmp/Other/a.log"
        )
    }

    func testMigrationRejectsSymlinkedPrefixMetadataTargetBeforeCopying() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalMetadata = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefix-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: externalMetadata)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let metadataDirectory = source.appending(path: "Prefixes/Steam-7-Symlinked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let originalMetadata = """
        {
          "createdAt" : "2026-06-21T00:00:00Z",
          "displayName" : "Symlinked",
          "id" : "Steam-7-Symlinked",
          "path" : "\(source.appending(path: "Prefixes/Steam-7-Symlinked").path)",
          "snapshots" : [
            "\(source.appending(path: "Snapshots/Prefixes/symlinked").path)"
          ],
          "updatedAt" : "2026-06-21T00:00:00Z"
        }
        """
        try originalMetadata.write(to: externalMetadata, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: metadataDirectory.appending(path: "prefix.json"),
            withDestinationURL: externalMetadata
        )

        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected symlinked prefix metadata to be rejected")
        } catch StorageMigrationError.unsafeSymlink(let url) {
            XCTAssertEqual(
                url.standardizedFileURL.path,
                metadataDirectory.appending(path: "prefix.json").standardizedFileURL.path
            )
            XCTAssertEqual(
                try String(contentsOf: externalMetadata, encoding: .utf8),
                originalMetadata
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationRejectsHardlinkedSourceFileBeforeCopying() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalSecret = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalHardlinkSecret-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: externalSecret)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        try "hardlinked-secret".write(to: externalSecret, atomically: true, encoding: .utf8)
        let hardlinkedLog = source
            .appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
            .appending(path: "hardlinked.log")
        try FileManager.default.linkItem(at: externalSecret, to: hardlinkedLog)

        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected hardlinked source file to be rejected")
        } catch StorageMigrationError.unsafeHardlink(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, hardlinkedLog.standardizedFileURL.path)
            XCTAssertEqual(try String(contentsOf: externalSecret, encoding: .utf8), "hardlinked-secret")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationRejectsSymlinkSourceRoot() async throws {
        let sourceTarget = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSourceTarget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceSymlink = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSourceSymlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: sourceSymlink)
            try? FileManager.default.removeItem(at: sourceTarget)
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.createDirectory(at: sourceTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sourceSymlink, withDestinationURL: sourceTarget)

        let pathManager = PathManager()
        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: sourceSymlink, to: destination)
            XCTFail("Expected symlink source root to be rejected")
        } catch PathManagerError.unsafeDirectory(let url) {
            XCTAssertEqual(url.path, sourceSymlink.path)
        }
    }

    func testMigrationRejectsSymlinkDestinationBeforeCopying() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destinationTarget = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestinationTarget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destinationSymlink = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestinationSymlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destinationSymlink)
            try? FileManager.default.removeItem(at: destinationTarget)
        }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationTarget, withIntermediateDirectories: true)
        try "payload".write(
            to: source.appending(path: "payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: destinationSymlink, withDestinationURL: destinationTarget)

        let pathManager = PathManager()
        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destinationSymlink)
            XCTFail("Expected symlink destination root to be rejected")
        } catch PathManagerError.unsafeDirectory(let url) {
            XCTAssertEqual(url.path, destinationSymlink.path)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: destinationTarget.appending(path: "payload.txt").path
            ))
        }
    }

    func testMigrationRejectsSymlinkManagedRoleBeforeCopying() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLogs = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLogs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: externalLogs)
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalLogs, withIntermediateDirectories: true)
        try "payload".write(
            to: source.appending(path: "payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: ForgePlayPathRole.logs.rawValue, directoryHint: .isDirectory),
            withDestinationURL: externalLogs
        )

        let pathManager = PathManager()
        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected symlink managed role to be rejected")
        } catch PathManagerError.unsafeDirectory(let url) {
            XCTAssertEqual(url.path, source.appending(path: ForgePlayPathRole.logs.rawValue).path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testMigrationRejectsNestedSymlinkEscapingSourceRootBeforeCopying() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalSecret = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSecret-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: externalSecret)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        try "external-secret".write(to: externalSecret, atomically: true, encoding: .utf8)
        let linkedLog = source
            .appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
            .appending(path: "linked.log")
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: externalSecret)

        let service = StorageMigrationService(pathManager: pathManager)

        do {
            _ = try await service.copyExistingRoot(from: source, to: destination)
            XCTFail("Expected external nested symlink to be rejected")
        } catch StorageMigrationError.unsafeSymlink(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, linkedLog.standardizedFileURL.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMigrationAllowsRelativeSymlinkThatStaysInsideSourceRoot() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMigrationDestination-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let launchLogs = source.appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
        try "managed-log".write(to: launchLogs.appending(path: "real.log"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: launchLogs.appending(path: "relative.log").path,
            withDestinationPath: "real.log"
        )

        let service = StorageMigrationService(pathManager: pathManager)
        _ = try await service.copyExistingRoot(from: source, to: destination)
        let migratedLink = destination
            .appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
            .appending(path: "relative.log")

        let target = try FileManager.default.destinationOfSymbolicLink(atPath: migratedLink.path)
        XCTAssertEqual(target, "real.log")
        XCTAssertEqual(
            try String(contentsOf: migratedLink, encoding: .utf8),
            "managed-log"
        )
    }

    func testManagedMigrationLeavesPartialSteamDownloadOnLegacyStorage() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManagedPartialDownload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let steamApps = try sourcePathManager.url(for: .steamSharedPrefix)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)
        let partialDownload = steamApps.appending(
            path: "downloading/42/chunk.bin",
            directoryHint: .notDirectory
        )
        try FileManager.default.createDirectory(
            at: partialDownload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "partial-game-data".write(to: partialDownload, atomically: true, encoding: .utf8)

        let service = StorageMigrationService(pathManager: PathManager())
        let result = try await service.copyManagedDataOnly(from: source, to: destination)
        let migratedSteamApps = destination
            .appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue, directoryHint: .isDirectory)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)

        XCTAssertEqual(result.externalizedLibraryPaths, [steamApps.standardizedFileURL.path])
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: migratedSteamApps.path),
            steamApps.standardizedFileURL.path
        )
        XCTAssertEqual(try String(contentsOf: partialDownload, encoding: .utf8), "partial-game-data")
        XCTAssertEqual(try String(contentsOf: migratedSteamApps.appending(path: "downloading/42/chunk.bin"), encoding: .utf8), "partial-game-data")
    }

    func testManagedMigrationExternalizesUnindexedDefaultSteamLibrary() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnindexedDefaultLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let steamApps = try sourcePathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        let partialDownload = steamApps.appending(path: "downloading/42/chunk.bin")
        try FileManager.default.createDirectory(
            at: partialDownload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(to: partialDownload)

        let service = StorageMigrationService(pathManager: PathManager())
        let result = try await service.copyManagedDataOnly(
            from: source,
            to: destination,
            purpose: .currentRelocation
        )
        let migratedSteamApps = destination.appending(
            path: "SteamLibraries/DefaultLibrary/steamapps",
            directoryHint: .isDirectory
        )

        XCTAssertTrue(result.externalizedLibraryPaths.contains(steamApps.standardizedFileURL.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: migratedSteamApps.path),
            steamApps.standardizedFileURL.path
        )
        XCTAssertEqual(try Data(contentsOf: partialDownload), Data("partial".utf8))
    }

    func testCurrentRelocationPreservesAppleD3DMetalRendererPayload() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRendererRelocation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "Destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let rendererPayload = try sourcePathManager.url(for: .appleSupplementalRenderer)
            .appending(path: "Payload/lib/wine/arm64-windows/d3d11.dll")
        try FileManager.default.createDirectory(
            at: rendererPayload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("apple-d3dmetal-fixture".utf8).write(to: rendererPayload)

        let service = StorageMigrationService(pathManager: PathManager())
        _ = try await service.copyManagedDataOnly(
            from: source,
            to: destination,
            purpose: .currentRelocation
        )
        let relocatedPayload = destination
            .appending(path: ForgePlayPathRole.appleSupplementalRenderer.rawValue, directoryHint: .isDirectory)
            .appending(path: "Payload/lib/wine/arm64-windows/d3d11.dll")

        XCTAssertEqual(
            try Data(contentsOf: relocatedPayload),
            Data("apple-d3dmetal-fixture".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendererPayload.path))
        XCTAssertTrue(
            ForgePlayManagedStorageLayout.relocatedTopLevelDirectoryNames.contains(
                ForgePlayPathRole.renderers.rawValue
            )
        )
    }

    func testCurrentRelocationCanMoveExternalizedSteamAppsSymlinkTwiceWithoutRetargeting() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCurrentRelocationTwice-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let firstDestination = base.appending(path: "FirstDestination", directoryHint: .isDirectory)
        let secondDestination = base.appending(path: "SecondDestination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourceSteamApps = try sourcePathManager.url(for: .steamSharedPrefix)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)
        let sourceGame = sourceSteamApps.appending(path: "common/Test Game/game.bin")
        try FileManager.default.createDirectory(
            at: sourceGame.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "external-game-data".write(to: sourceGame, atomically: true, encoding: .utf8)

        let service = StorageMigrationService(pathManager: PathManager())
        _ = try await service.copyManagedDataOnly(
            from: source,
            to: firstDestination,
            purpose: .currentRelocation
        )
        let firstSteamAppsLink = firstDestination
            .appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue, directoryHint: .isDirectory)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)
        let firstLinkTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: firstSteamAppsLink.path
        )

        _ = try await service.copyManagedDataOnly(
            from: firstDestination,
            to: secondDestination,
            purpose: .currentRelocation
        )
        let secondSteamAppsLink = secondDestination
            .appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue, directoryHint: .isDirectory)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)
        let secondLinkTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: secondSteamAppsLink.path
        )

        XCTAssertEqual(firstLinkTarget, sourceSteamApps.standardizedFileURL.path)
        XCTAssertEqual(secondLinkTarget, firstLinkTarget)
        XCTAssertEqual(
            try String(contentsOf: secondSteamAppsLink.appending(path: "common/Test Game/game.bin"), encoding: .utf8),
            "external-game-data"
        )
    }

    func testManagedMigrationRejectsConcurrentProcessLock() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManagedMigrationLock-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        let lock = try ManagedRootOperationLease.coordinatedLockURL(forManagedRoot: destination)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let activeLease = try ManagedRootOperationLease.acquireExclusive(forManagedRoot: destination)
        defer { activeLease.release() }

        let service = StorageMigrationService(pathManager: PathManager())
        do {
            _ = try await service.copyManagedDataOnly(from: source, to: destination)
            XCTFail("Expected the active migration lock to reject a second migration")
        } catch StorageMigrationError.migrationInProgress(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, lock.standardizedFileURL.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSandboxManagedRootLeaseUsesInternalCoordinationDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySandboxManagedRootLock-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applicationSupport = base.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        let externalRoot = base.appending(path: "External/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let lock = try ManagedRootOperationLease.coordinatedLockURL(
            forManagedRoot: externalRoot,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        XCTAssertTrue(lock.path.hasPrefix(applicationSupport.path + "/"))
        XCTAssertFalse(lock.path.hasPrefix(externalRoot.deletingLastPathComponent().path + "/"))

        let lease = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: externalRoot,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        defer { lease.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))

        do {
            let unexpectedLease = try ManagedRootOperationLease.acquireExclusive(
                forManagedRoot: externalRoot,
                sandboxEnabled: true,
                applicationSupportBaseURL: applicationSupport
            )
            unexpectedLease.release()
            XCTFail("Expected the second sandbox managed-root lease to be rejected")
        } catch ManagedRootOperationLeaseError.operationInProgress(let activeLock) {
            XCTAssertEqual(activeLock.standardizedFileURL.path, lock.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNonSandboxVolumeRootLeaseUsesInternalCoordinationDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayVolumeRootLock-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applicationSupport = base.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        let volumeRoot = URL(fileURLWithPath: "/Volumes/ForgePlayExternalTest", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let lock = try ManagedRootOperationLease.coordinatedLockURL(
            forManagedRoot: volumeRoot,
            sandboxEnabled: false,
            applicationSupportBaseURL: applicationSupport
        )
        XCTAssertTrue(lock.path.hasPrefix(applicationSupport.path + "/"))
        XCTAssertFalse(lock.path.hasPrefix("/Volumes/"))

        let lease = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: volumeRoot,
            sandboxEnabled: false,
            applicationSupportBaseURL: applicationSupport
        )
        defer { lease.release() }
        XCTAssertEqual(lease.lockURL, lock)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testCurrentRelocationPreflightRejectsVolumeRoot() throws {
        let service = StorageMigrationService(pathManager: PathManager())
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPreflightSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        let volumeRoot = URL(fileURLWithPath: "/", isDirectory: true)

        XCTAssertThrowsError(
            try service.validateCurrentRelocationPreflight(from: source, to: volumeRoot)
        ) { error in
            guard case StorageMigrationError.destinationIsVolumeRoot(let url) = error else {
                return XCTFail("Expected destinationIsVolumeRoot, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, volumeRoot.standardizedFileURL.path)
        }
    }

    func testManagedRootLeaseConcurrentReleaseIsIdempotent() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConcurrentLeaseRelease-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let lease = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root,
            sandboxEnabled: false
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    lease.release()
                }
            }
        }

        let reacquired = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root,
            sandboxEnabled: false
        )
        reacquired.release()
    }

    func testSandboxManagedRootLeaseUsesPhysicalIdentityForSymlinkAliases() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLeaseAlias-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        let alias = base.appending(path: "ManagedDataAlias", directoryHint: .isDirectory)
        let applicationSupport = base.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        let directLock = try ManagedRootOperationLease.coordinatedLockURL(
            forManagedRoot: root,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        let aliasLock = try ManagedRootOperationLease.coordinatedLockURL(
            forManagedRoot: alias,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        XCTAssertEqual(directLock, aliasLock)

        let lease = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        defer { lease.release() }
        XCTAssertThrowsError(
            try ManagedRootOperationLease.acquireExclusive(
                forManagedRoot: alias,
                sandboxEnabled: true,
                applicationSupportBaseURL: applicationSupport
            )
        ) { error in
            guard case ManagedRootOperationLeaseError.operationInProgress = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSandboxManagedRootLeaseIdentityDoesNotChangeWhenRootIsCreated() throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayLeaseCreationIdentity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        let applicationSupport = base.appending(
            path: "ApplicationSupport",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )

        let first = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        defer { first.release() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ManagedRootOperationLease.acquireExclusive(
                forManagedRoot: root,
                sandboxEnabled: true,
                applicationSupportBaseURL: applicationSupport
            )
        ) { error in
            guard case ManagedRootOperationLeaseError.operationInProgress = error else {
                return XCTFail("Expected operationInProgress, got \(error)")
            }
        }
    }

    func testSandboxManagedRootLeaseIdentityMatchesCaseVariantBeforeRootCreation() throws {
        let base = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayLeaseCaseIdentity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        let caseVariant = base.appending(path: "manageddata", directoryHint: .isDirectory)
        let applicationSupport = base.appending(
            path: "ApplicationSupport",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )

        let first = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root,
            sandboxEnabled: true,
            applicationSupportBaseURL: applicationSupport
        )
        defer { first.release() }

        XCTAssertThrowsError(
            try ManagedRootOperationLease.acquireExclusive(
                forManagedRoot: caseVariant,
                sandboxEnabled: true,
                applicationSupportBaseURL: applicationSupport
            )
        ) { error in
            guard case ManagedRootOperationLeaseError.operationInProgress = error else {
                return XCTFail("Expected operationInProgress, got \(error)")
            }
        }
    }

    func testRuntimeOwnershipLeaseIsIndependentFromOperationLeaseAndExclusive() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeOwnership-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let operationLease = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root,
            sandboxEnabled: false
        )
        defer { operationLease.release() }
        let runtimeLease = try ManagedRootOperationLease.acquireRuntimeOwnership(
            forManagedRoot: root,
            sandboxEnabled: false
        )
        defer { runtimeLease.release() }

        XCTAssertNotEqual(operationLease.lockURL, runtimeLease.lockURL)
        XCTAssertThrowsError(
            try ManagedRootOperationLease.acquireRuntimeOwnership(
                forManagedRoot: root,
                sandboxEnabled: false
            )
        ) { error in
            guard case ManagedRootOperationLeaseError.operationInProgress = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManagedMigrationRecoversStaleLockAndAbandonedStagingDirectory() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManagedMigrationRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        let lock = try ManagedRootOperationLease.coordinatedLockURL(forManagedRoot: destination)
        let abandonedIdentity = UUID()
        let abandonedStaging = base.appending(
            path: ".ManagedData-migration-\(abandonedIdentity.uuidString)",
            directoryHint: .isDirectory
        )
        let unownedStaging = base.appending(
            path: ".ManagedData-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let forgedIdentity = UUID()
        let forgedStaging = base.appending(
            path: ".ManagedData-migration-\(forgedIdentity.uuidString)",
            directoryHint: .isDirectory
        )
        let prefixImpostor = base.appending(
            path: ".ManagedData-migration-\(UUID().uuidString)-user-notes",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: base) }
        defer { try? FileManager.default.removeItem(at: lock) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourceLog = source.appending(path: "Logs/Launch/first-run.log")
        try "managed-data".write(to: sourceLog, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "invalid-pid\n".write(to: lock, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: abandonedStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unownedStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: forgedStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefixImpostor, withIntermediateDirectories: true)
        try "partial-copy".write(
            to: abandonedStaging.appending(path: "partial.log"),
            atomically: true,
            encoding: .utf8
        )
        let ownershipMarker = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "identity": abandonedIdentity.uuidString,
            "destinationPath": destination.standardizedFileURL.path
        ])
        try ownershipMarker.write(
            to: abandonedStaging.appending(path: ".forgeplay-managed-storage-staging-owner.json"),
            options: .atomic
        )
        let forgedMarker = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "identity": UUID().uuidString,
            "destinationPath": destination.standardizedFileURL.path
        ])
        try forgedMarker.write(
            to: forgedStaging.appending(path: ".forgeplay-managed-storage-staging-owner.json"),
            options: .atomic
        )
        try "user-data".write(
            to: unownedStaging.appending(path: "keep.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "user-data".write(
            to: prefixImpostor.appending(path: "keep.txt"),
            atomically: true,
            encoding: .utf8
        )

        let service = StorageMigrationService(pathManager: PathManager())
        let result = try await service.copyManagedDataOnly(from: source, to: destination)

        XCTAssertGreaterThan(result.copiedFiles, 0)
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "Logs/Launch/first-run.log"), encoding: .utf8),
            "managed-data"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unownedStaging.appending(path: "keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: forgedStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefixImpostor.appending(path: "keep.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appending(path: ".forgeplay-managed-storage-staging-owner.json").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testManagedMigrationRecopiesChangedSourceAndRejectsMarkerFromDifferentSource() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManagedMigrationMarker-\(UUID().uuidString)", directoryHint: .isDirectory)
        let firstSource = base.appending(path: "FirstSource", directoryHint: .isDirectory)
        let secondSource = base.appending(path: "SecondSource", directoryHint: .isDirectory)
        let destination = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try PathManager().configureRoot(firstSource)
        try PathManager().configureRoot(secondSource)
        try "first".write(
            to: firstSource.appending(path: "Logs/Launch/source.log"),
            atomically: true,
            encoding: .utf8
        )

        let service = StorageMigrationService(pathManager: PathManager())
        let firstResult = try await service.copyManagedDataOnly(from: firstSource, to: destination)
        try "newer-source-data".write(
            to: firstSource.appending(path: "Logs/Launch/source.log"),
            atomically: true,
            encoding: .utf8
        )
        let repeatedResult = try await service.copyManagedDataOnly(from: firstSource, to: destination)

        XCTAssertGreaterThan(firstResult.copiedFiles, 0)
        XCTAssertGreaterThan(repeatedResult.copiedFiles, 0)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Logs/Launch/source.log"),
                encoding: .utf8
            ),
            "newer-source-data"
        )

        do {
            _ = try await service.copyManagedDataOnly(from: secondSource, to: destination)
            XCTFail("Expected a marker from another source to be rejected")
        } catch StorageMigrationError.metadataReadFailed(let url, let message) {
            XCTAssertEqual(
                url.lastPathComponent,
                ForgePlayManagedStorageLayout.markerFileName
            )
            XCTAssertTrue(message.contains("requested migration source"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRelocatedManagedDataCleanupDoesNotRecursivelyDeleteOnMainActor() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRelocatedCleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: source) }

        let pathManager = PathManager()
        try pathManager.configureRoot(source)
        let payload = try pathManager.url(for: .launchLogs).appending(path: "cleanup-fixture.log")
        try Data("fixture".utf8).write(to: payload)
        let observingFileManager = StorageMigrationCleanupObservingFileManager()
        let service = StorageMigrationService(
            pathManager: pathManager,
            fileManager: observingFileManager
        )

        let removedRoot = try await service.cleanupRelocatedManagedData(
            at: source,
            preserving: []
        )

        XCTAssertTrue(removedRoot)
        XCTAssertGreaterThan(observingFileManager.removalCount, 0)
        XCTAssertFalse(observingFileManager.observedMainThreadRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    private func projectRoot() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
        while current.pathComponents.count > 1 {
            current.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: current.appending(path: "project.yml").path) {
                return current
            }
        }
        throw XCTSkip("Could not locate project root from #filePath")
    }

    private func writeStoredPrefixMetadataFixture(
        prefixManager: PrefixManager,
        root: URL,
        steamAppId: String,
        name: String
    ) throws -> PrefixMetadata {
        let compactName = name.replacingOccurrences(of: " ", with: "")
        let folderName = PathManager.sanitizedFileName("Steam-\(steamAppId)-\(compactName)")
        let prefixURL = root.appending(path: "Prefixes", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        let metadata = PrefixMetadata(
            schemaVersion: 1,
            id: "legacy-\(steamAppId)",
            displayName: name,
            path: prefixURL.path,
            mode: .legacy("stored-game-prefix"),
            runner: WinePrefixDefaults.runner,
            architecture: WinePrefixDefaults.architecture,
            windowsVersion: WinePrefixDefaults.windowsVersion,
            createdAt: Date(),
            updatedAt: Date(),
            installedRuntimes: [],
            dllOverrides: [],
            environmentVariables: [:],
            launchOptions: [],
            snapshots: []
        )
        try prefixManager.save(metadata, at: prefixURL)
        return metadata
    }

    private func normalizedSystemAliasPath(_ path: String) -> String {
        path.hasPrefix("/private/var/")
            ? String(path.dropFirst("/private".count))
            : path
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            AppSettingsRecord.self,
            PrefixRecord.self,
            RuntimeRecord.self,
            SteamGameRecord.self,
            SteamStorageMountRecord.self,
            LaunchRecord.self,
            DiagnosticRecord.self,
            CompatibilityRecipeRecord.self,
            AutoFixRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
