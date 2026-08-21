import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class ManagedStorageServiceTests: XCTestCase {
    func testFirstLaunchAutomaticallyCreatesInternalManagedRoot() async throws {
        let base = temporaryDirectory("FirstLaunch")
        let destination = base.appending(path: "Application Support/ForgePlay/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        context.insert(AppSettingsRecord())
        try context.save()
        let pathManager = PathManager()
        let migrationService = StorageMigrationService(pathManager: pathManager)
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )

        let result = try await service.activate(
            in: context,
            legacyRootURL: nil,
            managedRootURLOverride: destination
        )
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettingsRecord>()).first)

        XCTAssertEqual(result.rootURL.path, destination.path)
        XCTAssertFalse(result.didMigrateLegacyData)
        XCTAssertEqual(pathManager.rootURL?.path, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try pathManager.url(for: .steamSharedPrefix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try pathManager.url(for: .launchLogs).path))
        XCTAssertEqual(settings.selectedRootPath, destination.path)
        XCTAssertNil(settings.selectedRootBookmark)
        XCTAssertEqual(settings.managedStorageLayoutVersion, ForgePlayManagedStorageLayout.currentVersion)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appending(path: ForgePlayManagedStorageLayout.markerFileName).path
        ))
    }

    func testFirstLaunchDoesNotInitializeManagedRootWhileAnotherProcessOwnsItsOperationLease() async throws {
        let base = temporaryDirectory("FirstLaunchOperationLease")
        let destination = base.appending(path: "Application Support/ForgePlay/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord()
        context.insert(settings)
        try context.save()
        let pathManager = PathManager()
        let migrationService = StorageMigrationService(pathManager: pathManager)
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )
        let activeLease = try ManagedRootOperationLease.acquireExclusive(forManagedRoot: destination)
        defer { activeLease.release() }

        do {
            _ = try await service.activate(
                in: context,
                legacyRootURL: nil,
                managedRootURLOverride: destination
            )
            XCTFail("Expected first-launch initialization to respect the active root lease")
        } catch StorageMigrationError.migrationInProgress(let lockURL) {
            XCTAssertEqual(lockURL.standardizedFileURL.path, activeLease.lockURL.standardizedFileURL.path)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(pathManager.rootURL)
        XCTAssertNil(settings.selectedRootPath)
        XCTAssertNil(settings.managedStorageLayoutVersion)
    }

    func testLegacyMigrationReplacesProvisionalFreshRootAndPreservesItsLogs() async throws {
        let base = temporaryDirectory("ProvisionalFreshRoot")
        let source = base.appending(path: "ExternalRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ForgePlay/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourcePrefix = try sourcePathManager.url(for: .steamSharedPrefix)
        try "legacy-system-registry".write(
            to: sourcePrefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )

        let provisionalPathManager = PathManager()
        try provisionalPathManager.configureRoot(destination)
        let provisionalLog = try provisionalPathManager.url(for: .launchLogs)
            .appending(path: "provisional-launch.log")
        try "provisional-log".write(
            to: provisionalLog,
            atomically: true,
            encoding: .utf8
        )
        let staleWineServerLock = try provisionalPathManager.url(for: .steamSharedPrefix)
            .appending(path: ".forgeplay-wineserver/server-test/lock")
        try FileManager.default.createDirectory(
            at: staleWineServerLock.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: staleWineServerLock)
        try "version=2\nsource=none\n".write(
            to: destination.appending(path: ForgePlayManagedStorageLayout.markerFileName),
            atomically: true,
            encoding: .utf8
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: source.path,
            selectedRootBookmark: Data("legacy-bookmark".utf8)
        )
        context.insert(settings)
        try context.save()

        let pathManager = PathManager()
        let migrationService = StorageMigrationService(pathManager: pathManager)
        let hasCurrentManagedStorageMarker = try await migrationService
            .hasCurrentManagedStorageMarker(at: destination)
        XCTAssertFalse(hasCurrentManagedStorageMarker)
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )
        let result = try await service.activate(
            in: context,
            legacyRootURL: source,
            managedRootURLOverride: destination
        )

        XCTAssertTrue(result.didMigrateLegacyData)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Prefixes/SteamShared/system.reg"),
                encoding: .utf8
            ),
            "legacy-system-registry"
        )
        let recoveredLogRoot = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: destination.appending(path: "Logs", directoryHint: .isDirectory),
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("RecoveredBeforeLegacyImport-") }
        )
        XCTAssertEqual(
            try String(
                contentsOf: recoveredLogRoot.appending(path: "Launch/provisional-launch.log"),
                encoding: .utf8
            ),
            "provisional-log"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePrefix.appending(path: "system.reg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleWineServerLock.path))
        XCTAssertEqual(settings.selectedRootPath, destination.path)
        XCTAssertEqual(settings.legacyManagedRootPath, source.path)
        XCTAssertEqual(settings.managedStorageLayoutVersion, ForgePlayManagedStorageLayout.currentVersion)
    }

    func testLegacyMigrationDoesNotReplaceProvisionalRootContainingPrefixPayload() async throws {
        let base = temporaryDirectory("ProvisionalRootConflict")
        let source = base.appending(path: "ExternalRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ForgePlay/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourceRegistry = try sourcePathManager.url(for: .steamSharedPrefix)
            .appending(path: "system.reg")
        try "legacy-source".write(to: sourceRegistry, atomically: true, encoding: .utf8)

        let destinationPathManager = PathManager()
        try destinationPathManager.configureRoot(destination)
        let destinationRegistry = try destinationPathManager.url(for: .steamSharedPrefix)
            .appending(path: "system.reg")
        try "existing-destination".write(
            to: destinationRegistry,
            atomically: true,
            encoding: .utf8
        )
        try "version=2\nsource=none\n".write(
            to: destination.appending(path: ForgePlayManagedStorageLayout.markerFileName),
            atomically: true,
            encoding: .utf8
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(selectedRootPath: source.path)
        context.insert(settings)
        try context.save()

        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )
        do {
            _ = try await service.activate(
                in: context,
                legacyRootURL: source,
                managedRootURLOverride: destination
            )
            XCTFail("Expected the existing destination payload to block replacement")
        } catch StorageMigrationError.destinationNotEmpty(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, destination.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try String(contentsOf: sourceRegistry, encoding: .utf8), "legacy-source")
        XCTAssertEqual(
            try String(contentsOf: destinationRegistry, encoding: .utf8),
            "existing-destination"
        )
        XCTAssertEqual(settings.selectedRootPath, source.path)
        XCTAssertNil(settings.managedStorageLayoutVersion)
        XCTAssertNil(pathManager.rootURL)
    }

    func testLegacyMigrationAllowsManagedDataAsDirectChildOfLegacyApplicationSupportRoot() async throws {
        let base = temporaryDirectory("NestedDefaultRoot")
        let source = base.appending(path: "Application Support/ForgePlay", directoryHint: .isDirectory)
        let destination = source.appending(
            path: PathManager.managedDataDirectoryName,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourcePrefix = try sourcePathManager.url(for: .steamSharedPrefix)
        try "nested-legacy-registry".write(
            to: sourcePrefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(selectedRootPath: source.path)
        context.insert(settings)
        try context.save()

        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )
        let result = try await service.activate(
            in: context,
            legacyRootURL: source,
            managedRootURLOverride: destination
        )

        XCTAssertTrue(result.didMigrateLegacyData)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Prefixes/SteamShared/system.reg"),
                encoding: .utf8
            ),
            "nested-legacy-registry"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePrefix.appending(path: "system.reg").path))
        XCTAssertEqual(pathManager.rootURL?.path, destination.path)
        XCTAssertEqual(settings.selectedRootPath, destination.path)
    }

    func testLegacyMigrationCopiesManagedDataButLeavesGameLibraryExternal() async throws {
        let base = temporaryDirectory("LegacyMigration")
        let source = base.appending(path: "ExternalRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ForgePlay/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let prefix = try sourcePathManager.url(for: .steamSharedPrefix)
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefix.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "g:"),
            withDestinationURL: source
        )
        try "legacy-log".write(
            to: try sourcePathManager.url(for: .launchLogs).appending(path: "legacy.log"),
            atomically: true,
            encoding: .utf8
        )

        let externalLibrary = source.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        let externalGame = externalLibrary.appending(path: "steamapps/common/Test Game", directoryHint: .isDirectory)
        let externalManifest = externalLibrary.appending(path: "steamapps/appmanifest_42.acf")
        try FileManager.default.createDirectory(at: externalGame, withIntermediateDirectories: true)
        try "manifest".write(to: externalManifest, atomically: true, encoding: .utf8)
        let managedDefaultManifest = try sourcePathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps/appmanifest_99.acf")
        try FileManager.default.createDirectory(
            at: managedDefaultManifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "leave-external".write(to: managedDefaultManifest, atomically: true, encoding: .utf8)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let legacyBookmark = Data("legacy-root-bookmark".utf8)
        let settings = AppSettingsRecord(
            selectedRootPath: source.path,
            selectedRootBookmark: legacyBookmark
        )
        let prefixRecord = PrefixRecord(
            id: PrefixIdentifier.steamShared,
            displayName: "Steam Prefix",
            path: prefix.path,
            snapshotsJSON: "[]"
        )
        let gameRecord = SteamGameRecord(
            steamAppId: "42",
            name: "Test Game",
            installDir: "Test Game",
            libraryPath: externalGame.path,
            manifestPath: externalManifest.path
        )
        context.insert(settings)
        context.insert(prefixRecord)
        context.insert(gameRecord)
        try context.save()

        let pathManager = PathManager()
        let migrationService = StorageMigrationService(pathManager: pathManager)
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )
        let result = try await service.activate(
            in: context,
            legacyRootURL: source,
            managedRootURLOverride: destination
        )

        XCTAssertTrue(result.didMigrateLegacyData)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appending(path: "Logs/Launch/legacy.log").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appending(path: "Prefixes/SteamShared/system.reg").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appending(path: "SteamLibrary/steamapps/appmanifest_42.acf").path
        ))
        let migratedDefaultSteamApps = destination.appending(
            path: "SteamLibraries/DefaultLibrary/steamapps",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: migratedDefaultSteamApps.path),
            managedDefaultManifest.deletingLastPathComponent().standardizedFileURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migratedDefaultSteamApps.appending(path: "appmanifest_99.acf").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedDefaultManifest.path))
        XCTAssertEqual(prefixRecord.path, destination.appending(path: "Prefixes/SteamShared").path)
        XCTAssertEqual(gameRecord.libraryPath, externalGame.path)
        XCTAssertEqual(gameRecord.manifestPath, externalManifest.path)
        XCTAssertNil(gameRecord.libraryBookmark)
        XCTAssertEqual(settings.selectedRootPath, destination.path)
        XCTAssertNil(settings.selectedRootBookmark)
        XCTAssertEqual(settings.legacyManagedRootPath, source.path)
        XCTAssertNotNil(settings.managedStorageMigrationCompletedAt)

        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let migratedMount = try XCTUnwrap(mounts.first { $0.path == source.path })
        XCTAssertEqual(migratedMount.bookmark, legacyBookmark)
        let migratedDriveLink = destination.appending(path: "Prefixes/SteamShared/dosdevices/g:")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: migratedDriveLink.path), source.path)
    }

    func testLegacyMigrationRequiresPreviousRootAuthorization() async throws {
        let base = temporaryDirectory("Authorization")
        let destination = base.appending(path: "Internal/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = try makeModelContainer()
        let context = ModelContext(container)
        context.insert(AppSettingsRecord(selectedRootPath: "/Volumes/MissingLegacyRoot"))
        try context.save()
        let pathManager = PathManager()
        let migrationService = StorageMigrationService(pathManager: pathManager)
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )

        do {
            _ = try await service.activate(
                in: context,
                legacyRootURL: nil,
                managedRootURLOverride: destination
            )
            XCTFail("Expected activation to require the legacy root authorization")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageActivationError,
                .legacyRootAuthorizationRequired("/Volumes/MissingLegacyRoot")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLegacyRootBookmarkBecomesStorageMountWithoutGameRecords() async throws {
        let base = temporaryDirectory("BookmarkHandoff")
        let source = base.appending(path: "ExternalRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let bookmark = Data("legacy-bookmark".utf8)
        context.insert(AppSettingsRecord(
            selectedRootPath: source.path,
            selectedRootBookmark: bookmark
        ))
        try context.save()

        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )
        _ = try await service.activate(
            in: context,
            legacyRootURL: source,
            managedRootURLOverride: destination
        )

        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let mount = try XCTUnwrap(mounts.first { $0.path == source.path })
        XCTAssertEqual(mount.bookmark, bookmark)
    }

    func testWrongLegacyFolderDoesNotReplacePersistedMigrationSource() async throws {
        let base = temporaryDirectory("WrongLegacyFolder")
        let expectedSource = base.appending(path: "ExpectedLegacyRoot", directoryHint: .isDirectory)
        let wrongSource = base.appending(path: "WrongFolder", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: wrongSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: expectedSource.path,
            selectedRootBookmark: Data("expected-bookmark".utf8)
        )
        context.insert(settings)
        try context.save()
        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )

        do {
            _ = try await service.activate(
                in: context,
                legacyRootURL: wrongSource,
                managedRootURLOverride: destination
            )
            XCTFail("Expected the wrong legacy folder to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageActivationError,
                .legacyRootDoesNotContainManagedData(wrongSource)
            )
        }

        XCTAssertEqual(settings.selectedRootPath, expectedSource.path)
        XCTAssertNil(settings.managedStorageLayoutVersion)
        XCTAssertNil(pathManager.rootURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLegacyReconnectCannotUseInternalDestinationAsMigrationSource() async throws {
        let base = temporaryDirectory("DestinationAsLegacySource")
        let logicalSource = base.appending(path: "OldExternalRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "Application Support/ForgePlay/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PathManager().configureRoot(destination)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: logicalSource.path,
            selectedRootBookmark: Data("legacy-bookmark".utf8)
        )
        context.insert(settings)
        try context.save()

        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )

        do {
            _ = try await service.activate(
                in: context,
                legacyRootURL: destination,
                managedRootURLOverride: destination
            )
            XCTFail("Expected the internal destination to be rejected as a legacy source")
        } catch ManagedStorageActivationError.legacyRootDoesNotContainManagedData(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, destination.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(settings.selectedRootPath, logicalSource.path)
        XCTAssertEqual(settings.selectedRootBookmark, Data("legacy-bookmark".utf8))
        XCTAssertNil(settings.managedStorageLayoutVersion)
        XCTAssertNil(pathManager.rootURL)
    }

    func testMovedLegacyRootRebasesManagedAndExternalPathsFromTheirCorrectBases() async throws {
        let base = temporaryDirectory("MovedLegacyRoot")
        let logicalSource = base.appending(path: "OldVolume", directoryHint: .isDirectory)
        let physicalSource = base.appending(path: "RenamedVolume", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(physicalSource)
        let dosdevices = physicalSource.appending(path: "Prefixes/SteamShared/dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "g:"),
            withDestinationURL: logicalSource
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let bookmark = Data("moved-root-bookmark".utf8)
        let settings = AppSettingsRecord(
            selectedRootPath: logicalSource.path,
            selectedRootBookmark: bookmark
        )
        let prefix = PrefixRecord(
            id: PrefixIdentifier.steamShared,
            displayName: "Steam Prefix",
            path: logicalSource.appending(path: "Prefixes/SteamShared").path
        )
        let game = SteamGameRecord(
            steamAppId: "42",
            name: "Moved Library Game",
            installDir: "Moved Library Game",
            libraryPath: logicalSource.appending(path: "SteamLibrary").path,
            manifestPath: logicalSource.appending(path: "SteamLibrary/steamapps/appmanifest_42.acf").path
        )
        context.insert(settings)
        context.insert(prefix)
        context.insert(game)
        try context.save()

        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )
        _ = try await service.activate(
            in: context,
            legacyRootURL: physicalSource,
            managedRootURLOverride: destination
        )

        XCTAssertEqual(prefix.path, destination.appending(path: "Prefixes/SteamShared").path)
        XCTAssertEqual(game.libraryPath, physicalSource.appending(path: "SteamLibrary").path)
        XCTAssertEqual(
            game.manifestPath,
            physicalSource.appending(path: "SteamLibrary/steamapps/appmanifest_42.acf").path
        )
        let migratedDrive = destination.appending(path: "Prefixes/SteamShared/dosdevices/g:")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: migratedDrive.path),
            physicalSource.path
        )
        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        XCTAssertEqual(mounts.first { $0.path == physicalSource.path }?.bookmark, bookmark)
        XCTAssertEqual(settings.legacyManagedRootPath, logicalSource.path)
    }

    func testEmbeddedSteamGameLibraryStaysOnLegacyStorageThroughSymlink() async throws {
        let base = temporaryDirectory("EmbeddedLibrary")
        let source = base.appending(path: "ExternalRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "Internal/ManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let steamApps = source.appending(
            path: "Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let gameFile = steamApps.appending(path: "common/Test Game/game.bin")
        try FileManager.default.createDirectory(at: gameFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: gameFile)
        try "manifest".write(
            to: steamApps.appending(path: "appmanifest_42.acf"),
            atomically: true,
            encoding: .utf8
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let bookmark = Data("embedded-library-bookmark".utf8)
        context.insert(AppSettingsRecord(
            selectedRootPath: source.path,
            selectedRootBookmark: bookmark
        ))
        try context.save()

        let pathManager = PathManager()
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )
        _ = try await service.activate(
            in: context,
            legacyRootURL: source,
            managedRootURLOverride: destination
        )

        let migratedSteamApps = destination.appending(
            path: "Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: migratedSteamApps.path),
            steamApps.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameFile.path))
        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let steamRoot = steamApps.deletingLastPathComponent().path
        XCTAssertEqual(mounts.first { $0.path == steamRoot }?.bookmark, bookmark)
    }

    func testDefaultManagedRootUsesApplicationSupportManagedData() throws {
        let base = temporaryDirectory("RootProvider")
        defer { try? FileManager.default.removeItem(at: base) }

        let root = try PathManager.defaultManagedRootURL(applicationSupportBaseURL: base)

        XCTAssertEqual(root.path, base.appending(path: "ForgePlay/ManagedData").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExplicitLegacyImportCopiesIntoFreshCurrentRootWithoutDeletingSource() async throws {
        let base = temporaryDirectory("ExplicitLegacyImport")
        let source = base.appending(path: "LegacyRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "CurrentRoot", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourceRegistry = try sourcePathManager.url(for: .steamSharedPrefix)
            .appending(path: "system.reg")
        try "legacy-registry".write(to: sourceRegistry, atomically: true, encoding: .utf8)

        let pathManager = PathManager()
        try pathManager.configureRoot(destination)
        let migrationService = StorageMigrationService(pathManager: pathManager)
        try await migrationService.ensureManagedStorageMarker(at: destination, migratedFrom: nil)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let destinationBookmark = Data("destination-bookmark".utf8)
        let sourceBookmark = Data("source-bookmark".utf8)
        let settings = AppSettingsRecord(
            selectedRootPath: destination.path,
            selectedRootBookmark: destinationBookmark,
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        )
        let prefix = PrefixRecord(
            id: PrefixIdentifier.steamShared,
            displayName: "Steam Prefix",
            path: source.appending(path: "Prefixes/SteamShared").path
        )
        context.insert(settings)
        context.insert(prefix)
        try context.save()

        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )
        let result = try await service.importLegacyManagedData(
            in: context,
            from: source,
            to: destination,
            sourceBookmark: sourceBookmark
        )

        XCTAssertEqual(result.migratedFromURL?.path, source.path)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appending(path: "Prefixes/SteamShared/system.reg"),
                encoding: .utf8
            ),
            "legacy-registry"
        )
        XCTAssertEqual(try String(contentsOf: sourceRegistry, encoding: .utf8), "legacy-registry")
        XCTAssertEqual(pathManager.rootURL?.path, destination.path)
        XCTAssertEqual(settings.selectedRootPath, destination.path)
        XCTAssertEqual(settings.selectedRootBookmark, destinationBookmark)
        XCTAssertEqual(settings.legacyManagedRootPath, source.path)
        XCTAssertNotNil(settings.managedStorageMigrationCompletedAt)
        XCTAssertEqual(prefix.path, destination.appending(path: "Prefixes/SteamShared").path)
        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        XCTAssertEqual(mounts.count, 1)
        XCTAssertEqual(mounts.first?.path, source.path)
        XCTAssertEqual(mounts.first?.bookmark, sourceBookmark)
    }

    func testExplicitLegacyImportRefusesToOverwriteCurrentPrefixPayload() async throws {
        let base = temporaryDirectory("ExplicitLegacyImportConflict")
        let source = base.appending(path: "LegacyRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "CurrentRoot", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourceRegistry = try sourcePathManager.url(for: .steamSharedPrefix)
            .appending(path: "system.reg")
        try "legacy-registry".write(to: sourceRegistry, atomically: true, encoding: .utf8)

        let pathManager = PathManager()
        try pathManager.configureRoot(destination)
        let destinationRegistry = try pathManager.url(for: .steamSharedPrefix)
            .appending(path: "system.reg")
        try "current-registry".write(to: destinationRegistry, atomically: true, encoding: .utf8)
        let migrationService = StorageMigrationService(pathManager: pathManager)
        try await migrationService.ensureManagedStorageMarker(at: destination, migratedFrom: nil)

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: destination.path,
            selectedRootBookmark: Data("destination-bookmark".utf8),
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        )
        context.insert(settings)
        try context.save()

        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: migrationService
        )
        do {
            _ = try await service.importLegacyManagedData(
                in: context,
                from: source,
                to: destination,
                sourceBookmark: Data("source-bookmark".utf8)
            )
            XCTFail("Expected current managed payload to block explicit legacy import")
        } catch StorageMigrationError.destinationNotEmpty(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, destination.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try String(contentsOf: sourceRegistry, encoding: .utf8), "legacy-registry")
        XCTAssertEqual(try String(contentsOf: destinationRegistry, encoding: .utf8), "current-registry")
        XCTAssertEqual(settings.selectedRootPath, destination.path)
        XCTAssertEqual(settings.selectedRootBookmark, Data("destination-bookmark".utf8))
        XCTAssertNil(settings.legacyManagedRootPath)
        XCTAssertEqual(pathManager.rootURL?.path, destination.path)
    }

    func testCurrentRelocationPreservesSnapshotsAndRebasesSnapshotRecords() async throws {
        let base = temporaryDirectory("CurrentRelocationSnapshots")
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "Destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sourcePathManager = PathManager()
        try sourcePathManager.configureRoot(source)
        let sourceSnapshot = source.appending(
            path: "Snapshots/Prefixes/snapshot-1",
            directoryHint: .isDirectory
        )
        let sourceSnapshotPayload = sourceSnapshot.appending(path: "system.reg")
        try FileManager.default.createDirectory(at: sourceSnapshot, withIntermediateDirectories: true)
        try "snapshot-registry".write(
            to: sourceSnapshotPayload,
            atomically: true,
            encoding: .utf8
        )

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let sourceBookmark = Data("source-root-bookmark".utf8)
        let destinationBookmark = Data("destination-root-bookmark".utf8)
        let settings = AppSettingsRecord(
            selectedRootPath: source.path,
            selectedRootBookmark: sourceBookmark,
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        )
        let snapshotsJSON = String(
            decoding: try JSONEncoder().encode([sourceSnapshot.path]),
            as: UTF8.self
        )
        let prefix = PrefixRecord(
            id: PrefixIdentifier.steamShared,
            displayName: "Steam Prefix",
            path: source.appending(path: "Prefixes/SteamShared").path,
            snapshotsJSON: snapshotsJSON
        )
        let autoFix = AutoFixRecord(
            diagnosticId: "diagnostic",
            actionType: .noAction,
            status: "complete",
            snapshotPath: sourceSnapshot.path,
            logPath: source.appending(path: "Logs/Diagnostic/autofix.log").path
        )
        context.insert(settings)
        context.insert(prefix)
        context.insert(autoFix)
        try context.save()

        let pathManager = PathManager()
        try pathManager.restorePersistedRoot(source)
        let service = ManagedStorageService(
            pathManager: pathManager,
            storageMigrationService: StorageMigrationService(pathManager: pathManager)
        )

        let result = try await service.relocate(
            in: context,
            from: source,
            to: destination,
            destinationBookmark: destinationBookmark
        )

        let destinationSnapshot = destination.appending(
            path: "Snapshots/Prefixes/snapshot-1",
            directoryHint: .isDirectory
        )
        let destinationSnapshotPayload = destinationSnapshot.appending(path: "system.reg")
        XCTAssertEqual(result.rootURL.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertEqual(
            try String(contentsOf: destinationSnapshotPayload, encoding: .utf8),
            "snapshot-registry"
        )
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(prefix.snapshotsJSON.utf8)),
            [destinationSnapshot.path]
        )
        XCTAssertEqual(autoFix.snapshotPath, destinationSnapshot.path)
        XCTAssertEqual(settings.selectedRootPath, destination.path)
        XCTAssertEqual(settings.selectedRootBookmark, destinationBookmark)
        XCTAssertNil(result.sourceCleanupWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
    }

    func testManagedRecordRebaseLeavesExternalGameAndMountPathsUnchanged() throws {
        let base = temporaryDirectory("RecordBoundary")
        let source = base.appending(path: "LegacyRoot", directoryHint: .isDirectory)
        let destination = base.appending(path: "InternalRoot", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            gptkExecutablePath: source.appending(path: "LegacyRuntimeSelection/wine").path,
            gptkExecutableBookmark: Data("retired-runtime-bookmark".utf8),
            lastSteamInstallerPath: source.appending(path: "RuntimeCache/Installers/SteamSetup.exe").path
        )
        let snapshotPath = source.appending(path: "Snapshots/Prefixes/snapshot-1").path
        let prefix = PrefixRecord(
            id: PrefixIdentifier.steamShared,
            displayName: "Steam Prefix",
            path: source.appending(path: "Prefixes/SteamShared").path,
            snapshotsJSON: "[\"\(snapshotPath)\"]"
        )
        let runtime = RuntimeRecord(
            id: "runtime",
            prefixId: prefix.id,
            runtime: .vcrun2022,
            installLogPath: source.appending(path: "Logs/Runtime/runtime.log").path
        )
        let externalLibrary = source.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        let game = SteamGameRecord(
            steamAppId: "42",
            name: "External Game",
            installDir: "External Game",
            libraryPath: externalLibrary.path,
            manifestPath: externalLibrary.appending(path: "steamapps/appmanifest_42.acf").path
        )
        let mount = SteamStorageMountRecord(path: source.path, bookmark: Data([1, 2, 3]))
        let launch = LaunchRecord(
            prefixId: prefix.id,
            commandKind: "steam",
            stdoutPath: source.appending(path: "Logs/Launch/stdout.log").path,
            stderrPath: source.appending(path: "Logs/Launch/stderr.log").path
        )
        launch.diagnosticLogPath = source.appending(path: "Logs/Diagnostic/launch.log").path
        let autoFix = AutoFixRecord(
            diagnosticId: "diagnostic",
            actionType: .noAction,
            status: "complete",
            snapshotPath: snapshotPath,
            logPath: source.appending(path: "Logs/Diagnostic/autofix.log").path
        )
        context.insert(settings)
        context.insert(prefix)
        context.insert(runtime)
        context.insert(game)
        context.insert(mount)
        context.insert(launch)
        context.insert(autoFix)
        try context.save()

        let service = StorageMigrationService(pathManager: PathManager())
        let result = try service.rebaseManagedRecords(
            in: context,
            from: source,
            to: destination
        )

        XCTAssertEqual(result.rebasedPrefixRecords, 1)
        XCTAssertEqual(result.rebasedGameRecords, 0)
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerPath, destination.appending(path: "RuntimeCache/Installers/SteamSetup.exe").path)
        XCTAssertEqual(prefix.path, destination.appending(path: "Prefixes/SteamShared").path)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(prefix.snapshotsJSON.utf8)),
            []
        )
        XCTAssertEqual(runtime.installLogPath, destination.appending(path: "Logs/Runtime/runtime.log").path)
        XCTAssertEqual(launch.stdoutPath, destination.appending(path: "Logs/Launch/stdout.log").path)
        XCTAssertEqual(launch.stderrPath, destination.appending(path: "Logs/Launch/stderr.log").path)
        XCTAssertEqual(launch.diagnosticLogPath, destination.appending(path: "Logs/Diagnostic/launch.log").path)
        XCTAssertNil(autoFix.snapshotPath)
        XCTAssertEqual(autoFix.logPath, destination.appending(path: "Logs/Diagnostic/autofix.log").path)
        XCTAssertEqual(game.libraryPath, externalLibrary.path)
        XCTAssertEqual(game.manifestPath, externalLibrary.appending(path: "steamapps/appmanifest_42.acf").path)
        XCTAssertEqual(mount.path, source.path)
        XCTAssertEqual(mount.bookmark, Data([1, 2, 3]))
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayManagedStorage-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
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
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}
