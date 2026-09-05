import Darwin
import Foundation
import SwiftData
import XCTest
@testable import ForgePlay

private enum ExistingStoreFixtureCopyError: Error {
    case invalidBounds
    case unsafeSource(URL)
    case sourceTooLarge(URL, byteCount: UInt64, maximumByteCount: UInt64)
    case sourceIOFailed(URL, code: Int32)
    case unsafeDestination(URL)
    case destinationIOFailed(URL, code: Int32)
    case sourceChangedDuringCopy(URL)
}

private enum ExistingStoreFixtureFileCopier {
    static let maximumFileByteCount: UInt64 = 256 * 1024 * 1024
    static let chunkByteCount = 64 * 1024

    @discardableResult
    static func copyIfPresent(
        from source: URL,
        to destination: URL,
        maximumByteCount: UInt64 = maximumFileByteCount,
        chunkByteCount: Int = ExistingStoreFixtureFileCopier.chunkByteCount
    ) throws -> Bool {
        guard maximumByteCount > 0, chunkByteCount > 0 else {
            throw ExistingStoreFixtureCopyError.invalidBounds
        }

        let sourceDescriptor = source.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceDescriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return false
            }
            if code == ELOOP {
                throw ExistingStoreFixtureCopyError.unsafeSource(source)
            }
            throw ExistingStoreFixtureCopyError.sourceIOFailed(source, code: code)
        }
        defer { Darwin.close(sourceDescriptor) }

        var initialStatus = stat()
        guard fstat(sourceDescriptor, &initialStatus) == 0 else {
            throw ExistingStoreFixtureCopyError.sourceIOFailed(source, code: errno)
        }
        guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size >= 0 else {
            throw ExistingStoreFixtureCopyError.unsafeSource(source)
        }
        let expectedByteCount = UInt64(initialStatus.st_size)
        guard expectedByteCount <= maximumByteCount else {
            throw ExistingStoreFixtureCopyError.sourceTooLarge(
                source,
                byteCount: expectedByteCount,
                maximumByteCount: maximumByteCount
            )
        }

        let destinationDescriptor = destination.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else {
            throw ExistingStoreFixtureCopyError.destinationIOFailed(destination, code: errno)
        }
        var removePartialDestination = true
        defer {
            Darwin.close(destinationDescriptor)
            if removePartialDestination {
                _ = destination.path.withCString { Darwin.unlink($0) }
            }
        }

        var destinationStatus = stat()
        guard fstat(destinationDescriptor, &destinationStatus) == 0 else {
            throw ExistingStoreFixtureCopyError.destinationIOFailed(destination, code: errno)
        }
        guard (destinationStatus.st_mode & S_IFMT) == S_IFREG,
              destinationStatus.st_nlink == 1 else {
            throw ExistingStoreFixtureCopyError.unsafeDestination(destination)
        }

        var buffer = [UInt8](repeating: 0, count: chunkByteCount)
        var copiedByteCount: UInt64 = 0
        while true {
            let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                var result: Int
                repeat {
                    result = Darwin.read(sourceDescriptor, baseAddress, rawBuffer.count)
                } while result < 0 && errno == EINTR
                return result
            }
            guard bytesRead >= 0 else {
                throw ExistingStoreFixtureCopyError.sourceIOFailed(source, code: errno)
            }
            if bytesRead == 0 { break }
            guard UInt64(bytesRead) <= maximumByteCount - copiedByteCount else {
                throw ExistingStoreFixtureCopyError.sourceTooLarge(
                    source,
                    byteCount: copiedByteCount + UInt64(bytesRead),
                    maximumByteCount: maximumByteCount
                )
            }

            var writtenByteCount = 0
            while writtenByteCount < bytesRead {
                let bytesWritten: Int = buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    var result: Int
                    repeat {
                        result = Darwin.write(
                            destinationDescriptor,
                            baseAddress.advanced(by: writtenByteCount),
                            bytesRead - writtenByteCount
                        )
                    } while result < 0 && errno == EINTR
                    return result
                }
                guard bytesWritten > 0 else {
                    let code = bytesWritten < 0 ? errno : EIO
                    throw ExistingStoreFixtureCopyError.destinationIOFailed(
                        destination,
                        code: code
                    )
                }
                writtenByteCount += bytesWritten
            }
            copiedByteCount += UInt64(bytesRead)
        }

        var finalStatus = stat()
        guard fstat(sourceDescriptor, &finalStatus) == 0 else {
            throw ExistingStoreFixtureCopyError.sourceIOFailed(source, code: errno)
        }
        guard copiedByteCount == expectedByteCount,
              finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_size == initialStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec else {
            throw ExistingStoreFixtureCopyError.sourceChangedDuringCopy(source)
        }

        removePartialDestination = false
        return true
    }
}

private final class CompetingStorePublicationFileManager: FileManager {
    let competingStoreURL: URL
    let competingStoreData: Data
    private var didPublishCompetingStore = false

    init(competingStoreURL: URL, competingStoreData: Data) {
        self.competingStoreURL = competingStoreURL
        self.competingStoreData = competingStoreData
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !didPublishCompetingStore,
           dstURL.standardizedFileURL.path == competingStoreURL.standardizedFileURL.path {
            didPublishCompetingStore = true
            try competingStoreData.write(to: competingStoreURL, options: .atomic)
            throw CocoaError(.fileWriteFileExists)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class PausingStoreMigrationFileManager: FileManager {
    let legacyStoreURL: URL
    let copyStarted: DispatchSemaphore
    let resumeCopy: DispatchSemaphore
    private var didPause = false

    init(
        legacyStoreURL: URL,
        copyStarted: DispatchSemaphore,
        resumeCopy: DispatchSemaphore
    ) {
        self.legacyStoreURL = legacyStoreURL
        self.copyStarted = copyStarted
        self.resumeCopy = resumeCopy
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if !didPause,
           srcURL.standardizedFileURL.path == legacyStoreURL.standardizedFileURL.path {
            didPause = true
            copyStarted.signal()
            guard resumeCopy.wait(timeout: .now() + 5) == .success else {
                throw CocoaError(.userCancelled)
            }
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}

@MainActor
final class AppLaunchTests: XCTestCase {
    func testModelContainerFactoryCreatesInMemoryStore() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord()

        context.insert(settings)
        try context.save()

        let descriptor = FetchDescriptor<AppSettingsRecord>()
        XCTAssertEqual(try context.fetch(descriptor).count, 1)
    }

    func testFreshAppStateSelectsBundledRuntimeWithoutPersistingLegacyRuntimeSelection() throws {
        let bundledRuntime = try XCTUnwrap(
            ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL()
        )
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let appState = AppState()

        try appState.load(from: context)

        XCTAssertEqual(
            appState.runtimeExecutableURL?.standardizedFileURL.path,
            bundledRuntime.standardizedFileURL.path
        )
        XCTAssertTrue(appState.isRuntimeConfigured)
        let settings = try XCTUnwrap(
            try context.fetch(FetchDescriptor<AppSettingsRecord>()).first
        )
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertNil(appState.steamInstallerURL)
    }

    func testWineSynchronizationSelectionDefaultsToAutomaticMode() {
        let appState = AppState()

        XCTAssertEqual(appState.wineSynchronizationSelection, .automatic)
        XCTAssertEqual(WineSynchronizationSelection.allCases, [.automatic])
    }

    func testAppStateMigratesLegacyWineSynchronizationSelectionToAutomatic() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord()
        settings.wineSynchronizationSelection = "msync"
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        XCTAssertEqual(appState.wineSynchronizationSelection, .automatic)
        XCTAssertNil(settings.wineSynchronizationSelection)
    }

    func testExistingStoreMigratesWhenSteamStorageMountModelIsAdded() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayStorageMountSchemaMigration")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let storeURL = try ForgePlayApp.preparePersistentStoreURL(
            applicationSupportDirectory: applicationSupport
        )
        let legacySchema = Schema([
            AppSettingsRecord.self,
            PrefixRecord.self,
            RuntimeRecord.self,
            SteamGameRecord.self,
            LaunchRecord.self,
            DiagnosticRecord.self,
            CompatibilityRecipeRecord.self,
            AutoFixRecord.self
        ])
        do {
            let configuration = ModelConfiguration(
                "ForgePlay",
                schema: legacySchema,
                url: storeURL
            )
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [configuration]
            )
            let context = ModelContext(legacyContainer)
            context.insert(AppSettingsRecord())
            try context.save()
        }

        let upgradedContainer = try ForgePlayApp.makeModelContainer(
            applicationSupportDirectory: applicationSupport
        )
        let upgradedContext = ModelContext(upgradedContainer)

        XCTAssertEqual(try upgradedContext.fetch(FetchDescriptor<AppSettingsRecord>()).count, 1)
        XCTAssertTrue(try upgradedContext.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
    }

    func testCurrentModelMigratesCopiedExistingStoreFixture() throws {
        let fixturePointer = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExistingStoreMigrationFixturePath.txt")
        let sourcePath = ProcessInfo.processInfo.environment["FORGEPLAY_EXISTING_STORE_MIGRATION_FIXTURE"] ??
            (try? String(contentsOf: fixturePointer, encoding: .utf8))
        guard let sourcePath = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourcePath.isEmpty else {
            throw XCTSkip("Set FORGEPLAY_EXISTING_STORE_MIGRATION_FIXTURE to a real ForgePlay.store path.")
        }
        let sourceStore = URL(fileURLWithPath: sourcePath)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(sourceStore) else {
            throw XCTSkip("The existing store fixture is unavailable or unsafe: \(sourcePath)")
        }

        let applicationSupport = try temporaryDirectory(named: "ForgePlayExistingStoreMigration")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let destinationDirectory = applicationSupport.appending(
            path: ForgePlayApp.applicationSupportDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationStore = destinationDirectory.appending(path: ForgePlayApp.persistentStoreFileName)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: sourceStore.path + suffix)
            let didCopy = try ExistingStoreFixtureFileCopier.copyIfPresent(
                from: source,
                to: URL(fileURLWithPath: destinationStore.path + suffix)
            )
            if suffix.isEmpty, !didCopy {
                throw XCTSkip("The existing store fixture disappeared before it could be copied.")
            }
        }

        let container = try ForgePlayApp.makeModelContainer(
            applicationSupportDirectory: applicationSupport
        )
        let context = ModelContext(container)
        let migratedRecord = LaunchRecord(
            id: "launch-migration-\(UUID().uuidString)",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            steamUISurfaceRawValue: SteamUISurface.library.rawValue,
            hostAppSessionID: "migration-fixture-session"
        )
        context.insert(migratedRecord)
        try context.save()

        let records = try context.fetch(FetchDescriptor<LaunchRecord>())
        let reloaded = try XCTUnwrap(records.first { $0.id == migratedRecord.id })
        XCTAssertEqual(reloaded.steamUISurface, .library)
        XCTAssertEqual(reloaded.hostAppSessionID, "migration-fixture-session")
    }

    func testExistingStoreFixtureCopyUsesBoundedChunksWithoutCloneCopying() throws {
        let directory = try temporaryDirectory(named: "ForgePlayFixtureByteCopy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.store")
        let destination = directory.appending(path: "destination.store")
        let payload = Data((0..<97).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let didCopy = try ExistingStoreFixtureFileCopier.copyIfPresent(
            from: source,
            to: destination,
            maximumByteCount: UInt64(payload.count),
            chunkByteCount: 7
        )

        XCTAssertTrue(didCopy)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testExistingStoreFixtureCopyRejectsSymlinkAndNonRegularSources() throws {
        let directory = try temporaryDirectory(named: "ForgePlayUnsafeFixtureCopy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let regularSource = directory.appending(path: "regular.store")
        let symlinkSource = directory.appending(path: "linked.store")
        let directorySource = directory.appending(
            path: "directory.store",
            directoryHint: .isDirectory
        )
        try Data("fixture".utf8).write(to: regularSource)
        try FileManager.default.createSymbolicLink(at: symlinkSource, withDestinationURL: regularSource)
        try FileManager.default.createDirectory(at: directorySource, withIntermediateDirectories: false)

        for source in [symlinkSource, directorySource] {
            let destination = directory.appending(path: "destination-\(UUID().uuidString).store")
            XCTAssertThrowsError(
                try ExistingStoreFixtureFileCopier.copyIfPresent(
                    from: source,
                    to: destination,
                    maximumByteCount: 1_024,
                    chunkByteCount: 8
                )
            ) { error in
                guard case ExistingStoreFixtureCopyError.unsafeSource(let rejectedURL) = error else {
                    XCTFail("Expected unsafeSource, got \(error)")
                    return
                }
                XCTAssertEqual(
                    rejectedURL.standardizedFileURL.path,
                    source.standardizedFileURL.path
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testExistingStoreFixtureCopyRejectsOversizedSourceWithoutPartialDestination() throws {
        let directory = try temporaryDirectory(named: "ForgePlayOversizedFixtureCopy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "oversized.store")
        let destination = directory.appending(path: "destination.store")
        try Data(repeating: 0xA5, count: 9).write(to: source)

        XCTAssertThrowsError(
            try ExistingStoreFixtureFileCopier.copyIfPresent(
                from: source,
                to: destination,
                maximumByteCount: 8,
                chunkByteCount: 3
            )
        ) { error in
            guard case ExistingStoreFixtureCopyError.sourceTooLarge(
                let rejectedURL,
                let byteCount,
                let maximumByteCount
            ) = error else {
                XCTFail("Expected sourceTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(rejectedURL.standardizedFileURL.path, source.standardizedFileURL.path)
            XCTAssertEqual(byteCount, 9)
            XCTAssertEqual(maximumByteCount, 8)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExistingStoreFixtureCopyDoesNotFollowDestinationSymlink() throws {
        let directory = try temporaryDirectory(named: "ForgePlayDestinationSymlinkCopy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.store")
        let symlinkDestination = directory.appending(path: "destination.store")
        let protectedTarget = directory.appending(path: "protected.store")
        let protectedPayload = Data("do-not-overwrite".utf8)
        try Data("fixture".utf8).write(to: source)
        try protectedPayload.write(to: protectedTarget)
        try FileManager.default.createSymbolicLink(
            at: symlinkDestination,
            withDestinationURL: protectedTarget
        )

        XCTAssertThrowsError(
            try ExistingStoreFixtureFileCopier.copyIfPresent(
                from: source,
                to: symlinkDestination,
                maximumByteCount: 1_024,
                chunkByteCount: 8
            )
        ) { error in
            guard case ExistingStoreFixtureCopyError.destinationIOFailed(
                let rejectedURL,
                let code
            ) = error else {
                XCTFail("Expected destinationIOFailed, got \(error)")
                return
            }
            XCTAssertEqual(
                rejectedURL.standardizedFileURL.path,
                symlinkDestination.standardizedFileURL.path
            )
            XCTAssertEqual(code, EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: protectedTarget), protectedPayload)
    }

    func testPersistentStoreUsesAppSpecificApplicationSupportDirectory() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayAppSupport")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }

        let storeURL = try ForgePlayApp.preparePersistentStoreURL(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(storeURL.lastPathComponent, ForgePlayApp.persistentStoreFileName)
        XCTAssertEqual(storeURL.deletingLastPathComponent().lastPathComponent, ForgePlayApp.applicationSupportDirectoryName)
        XCTAssertTrue(
            FileSystemItemPolicy.isNonSymlinkDirectory(storeURL.deletingLastPathComponent())
        )
    }

    func testPersistentModelContainerWritesStoreInAppSpecificDirectory() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayPersistentStore")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let container = try ForgePlayApp.makeModelContainer(
            applicationSupportDirectory: applicationSupport
        )
        let context = ModelContext(container)

        context.insert(AppSettingsRecord())
        try context.save()

        let storeURL = applicationSupport
            .appending(path: ForgePlayApp.applicationSupportDirectoryName, directoryHint: .isDirectory)
            .appending(path: ForgePlayApp.persistentStoreFileName, directoryHint: .notDirectory)
        XCTAssertTrue(FileSystemItemPolicy.isRegularNonSymlinkFile(storeURL), storeURL.path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: applicationSupport.appending(path: ForgePlayApp.legacyDefaultStoreFileName).path
            )
        )
    }

    func testForgePlayLegacyDefaultStoreIsCopiedIntoAppSpecificStore() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayLegacyStore")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacyStore = applicationSupport.appending(path: ForgePlayApp.legacyDefaultStoreFileName)
        let legacyWAL = URL(fileURLWithPath: legacyStore.path + "-wal")
        try Data("SQLite header ZAPPSETTINGSRECORD AppSettingsRecord".utf8).write(to: legacyStore)
        try Data("legacy wal".utf8).write(to: legacyWAL)

        let storeURL = try ForgePlayApp.preparePersistentStoreURL(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertEqual(try Data(contentsOf: storeURL), try Data(contentsOf: legacyStore))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: storeURL.path + "-wal")),
            try Data(contentsOf: legacyWAL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.path))
    }

    func testLegacyStoreMigrationFailureNeverDeletesCompetingProcessFinalStore() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayConcurrentLegacyStore")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacyStore = applicationSupport.appending(path: ForgePlayApp.legacyDefaultStoreFileName)
        try Data("SQLite header ZAPPSETTINGSRECORD AppSettingsRecord".utf8).write(to: legacyStore)
        let finalStore = applicationSupport
            .appending(path: ForgePlayApp.applicationSupportDirectoryName, directoryHint: .isDirectory)
            .appending(path: ForgePlayApp.persistentStoreFileName, directoryHint: .notDirectory)
        let competingStoreData = Data("competing-process-final-store".utf8)
        let fileManager = CompetingStorePublicationFileManager(
            competingStoreURL: finalStore,
            competingStoreData: competingStoreData
        )

        XCTAssertThrowsError(
            try ForgePlayApp.preparePersistentStoreURL(
                applicationSupportDirectory: applicationSupport,
                fileManager: fileManager
            )
        )

        XCTAssertEqual(try Data(contentsOf: finalStore), competingStoreData)
    }

    func testLegacyStoreMigrationSerializesConcurrentPreparations() async throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlaySerializedLegacyStore")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacyStore = applicationSupport.appending(path: ForgePlayApp.legacyDefaultStoreFileName)
        let legacyStoreData = Data("SQLite header ZAPPSETTINGSRECORD AppSettingsRecord".utf8)
        try legacyStoreData.write(to: legacyStore)
        let finalStore = applicationSupport
            .appending(path: ForgePlayApp.applicationSupportDirectoryName, directoryHint: .isDirectory)
            .appending(path: ForgePlayApp.persistentStoreFileName, directoryHint: .notDirectory)
        let copyStarted = DispatchSemaphore(value: 0)
        let resumeCopy = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let pausingFileManager = PausingStoreMigrationFileManager(
            legacyStoreURL: legacyStore,
            copyStarted: copyStarted,
            resumeCopy: resumeCopy
        )
        let firstMigration = Task.detached(priority: .userInitiated) { () -> String in
            do {
                return try ForgePlayApp.preparePersistentStoreURL(
                    applicationSupportDirectory: applicationSupport,
                    fileManager: pausingFileManager
                ).standardizedFileURL.path
            } catch {
                return "error: \(forgePlayTechnicalErrorSummary(error))"
            }
        }
        let copyStartResult = await Task.detached(priority: .userInitiated) {
            waitForSemaphore(copyStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(copyStartResult, .success)

        let secondMigration = Task.detached(priority: .userInitiated) { () -> String in
            secondStarted.signal()
            defer { secondFinished.signal() }
            do {
                return try ForgePlayApp.preparePersistentStoreURL(
                    applicationSupportDirectory: applicationSupport
                ).standardizedFileURL.path
            } catch {
                return "error: \(forgePlayTechnicalErrorSummary(error))"
            }
        }
        let secondStartResult = await Task.detached(priority: .userInitiated) {
            waitForSemaphore(secondStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(secondStartResult, .success)
        let earlySecondCompletion = await Task.detached(priority: .userInitiated) {
            waitForSemaphore(secondFinished, timeout: .now() + 0.2)
        }.value
        XCTAssertEqual(earlySecondCompletion, .timedOut)

        resumeCopy.signal()
        let firstResult = await firstMigration.value
        let secondResult = await secondMigration.value

        XCTAssertEqual(firstResult, finalStore.standardizedFileURL.path)
        XCTAssertEqual(secondResult, finalStore.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: finalStore), legacyStoreData)
    }

    func testUnrelatedLegacyDefaultStoreIsNotCopied() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayUnrelatedLegacyStore")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacyStore = applicationSupport.appending(path: ForgePlayApp.legacyDefaultStoreFileName)
        try Data("OtherAppRecord".utf8).write(to: legacyStore)

        let storeURL = try ForgePlayApp.preparePersistentStoreURL(
            applicationSupportDirectory: applicationSupport
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.path))
    }

    func testUnreadableLegacyDefaultStoreMarkerIsNotSilentlySkipped() throws {
        let applicationSupport = try temporaryDirectory(named: "ForgePlayUnreadableLegacyStore")
        let legacyStore = applicationSupport.appending(path: ForgePlayApp.legacyDefaultStoreFileName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyStore.path)
            try? FileManager.default.removeItem(at: applicationSupport)
        }
        try Data("SQLite header ZAPPSETTINGSRECORD AppSettingsRecord".utf8).write(to: legacyStore)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: legacyStore.path)

        XCTAssertThrowsError(
            try ForgePlayApp.preparePersistentStoreURL(applicationSupportDirectory: applicationSupport)
        ) { error in
            guard let storeError = error as? ForgePlayStoreConfigurationError,
                  case .metadataReadFailed(let url, let message) = storeError else {
                XCTFail("Expected descriptor-bound metadataReadFailed, got \(error)")
                return
            }
            XCTAssertEqual(url.standardizedFileURL.path, legacyStore.standardizedFileURL.path)
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testAppSettingsRecordNormalizesLegacyAIDiagnosticProviderConfiguration() {
        let originalDate = Date(timeIntervalSince1970: 100)
        let normalizedDate = Date(timeIntervalSince1970: 200)
        let settings = AppSettingsRecord(
            llmProvider: "OpenAICompatible",
            llmBaseURL: "https://legacy.example.com/v1",
            llmModel: "gpt-4.1",
            updatedAt: originalDate
        )

        let changed = settings.normalizeAIDiagnosticProviderConfiguration(now: normalizedDate)

        XCTAssertTrue(changed)
        XCTAssertEqual(settings.llmProvider, AIDiagnosticProviderConfiguration.identifier)
        XCTAssertEqual(settings.llmBaseURL, "")
        XCTAssertEqual(settings.llmModel, AIDiagnosticProviderConfiguration.displayName)
        XCTAssertEqual(settings.updatedAt, normalizedDate)
    }

    func testAppSettingsRecordKeepsCurrentAIDiagnosticProviderConfigurationStable() {
        let originalDate = Date(timeIntervalSince1970: 100)
        let normalizedDate = Date(timeIntervalSince1970: 200)
        let settings = AppSettingsRecord(updatedAt: originalDate)

        let changed = settings.normalizeAIDiagnosticProviderConfiguration(now: normalizedDate)

        XCTAssertFalse(changed)
        XCTAssertEqual(settings.llmProvider, AIDiagnosticProviderConfiguration.identifier)
        XCTAssertEqual(settings.llmBaseURL, "")
        XCTAssertEqual(settings.llmModel, AIDiagnosticProviderConfiguration.displayName)
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testAppStateLoadNormalizesLegacyAIDiagnosticProviderConfiguration() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            isLLMDiagnosticsEnabled: true,
            llmProvider: "OpenAICompatible",
            llmBaseURL: "https://legacy.example.com/v1?api_key=old",
            llmModel: "gpt-4.1"
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        let descriptor = FetchDescriptor<AppSettingsRecord>()
        let reloaded = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertTrue(appState.isLLMDiagnosticsEnabled)
        XCTAssertEqual(reloaded.llmProvider, AIDiagnosticProviderConfiguration.identifier)
        XCTAssertEqual(reloaded.llmBaseURL, "")
        XCTAssertEqual(reloaded.llmModel, AIDiagnosticProviderConfiguration.displayName)
    }

    func testAppStateLoadClearsLeakedScreenshotFixtureSelections() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: ForgePlayDevelopmentFixturePaths.appStoreScreenshotRootPath,
            gptkExecutablePath: ForgePlayDevelopmentFixturePaths.appStoreScreenshotRuntimeExecutablePath,
            isAdvancedModeEnabled: true
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertNil(appState.selectedRootURL)
        if let resolvedRuntime = appState.runtimeExecutableURL {
            XCTAssertTrue(resolvedRuntime.path.contains("/Contents/Resources/Runners/"), resolvedRuntime.path)
            XCTAssertNotEqual(resolvedRuntime.path, ForgePlayDevelopmentFixturePaths.appStoreScreenshotRuntimeExecutablePath)
        }
        XCTAssertNil(reloaded.selectedRootPath)
        XCTAssertNil(reloaded.selectedRootBookmark)
        XCTAssertNil(reloaded.gptkExecutablePath)
        XCTAssertNil(reloaded.gptkExecutableBookmark)
        XCTAssertTrue(appState.isAdvancedModeEnabled)
    }

    func testAppStateLoadClearsHistoricalRuntimeSelectionsAndUsesCurrentBundledRuntime() throws {
        let currentBundledRuntime = try XCTUnwrap(
            ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL()
        )
        let historicalPaths = [
            "/Applications/ForgePlay-Previous.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine",
            "/Applications/ExternalRuntime.app/Contents/Resources/Runtime/bin/wine",
            "/Volumes/ForgePlay/LegacyManagedRuntime/wine/bin/wine"
        ]

        for historicalPath in historicalPaths {
            let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
            let context = ModelContext(container)
            let settings = AppSettingsRecord(
                gptkExecutablePath: historicalPath,
                gptkExecutableBookmark: Data([0, 1, 2, 3])
            )
            context.insert(settings)
            try context.save()

            let appState = AppState()
            try appState.load(from: context)

            let reloaded = try XCTUnwrap(
                try context.fetch(FetchDescriptor<AppSettingsRecord>()).first
            )
            XCTAssertEqual(
                appState.runtimeExecutableURL?.standardizedFileURL.path,
                currentBundledRuntime.standardizedFileURL.path,
                historicalPath
            )
            XCTAssertNil(reloaded.gptkExecutablePath, historicalPath)
            XCTAssertNil(reloaded.gptkExecutableBookmark, historicalPath)
        }
    }

    func testClearingPersistedRootAfterRestoreFailureResetsRootStateAndStore() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let root = URL(fileURLWithPath: "/Volumes/MissingForgePlayRoot", isDirectory: true)
        let settings = AppSettingsRecord(selectedRootPath: root.path, selectedRootBookmark: Data([1, 2, 3]))
        context.insert(settings)
        try context.save()
        let appState = AppState()
        appState.selectedRootURL = root

        let message = try appState.clearPersistedRootAfterRestoreFailure(
            in: context,
            reason: PathManagerError.missing(root)
        )

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertNil(appState.selectedRootURL)
        XCTAssertEqual(appState.setupStage, .chooseRoot)
        XCTAssertNil(reloaded.selectedRootPath)
        XCTAssertNil(reloaded.selectedRootBookmark)
        XCTAssertEqual(appState.currentNotice?.kind, .warning)
        XCTAssertEqual(appState.currentNotice?.message, message)
        XCTAssertTrue(message.contains(root.path))
    }

    func testStartupFailureViewSurfacesApplicationSupportOpenFailures() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/StartupFailureView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var recoveryActionErrorMessage"))
        XCTAssertTrue(source.contains("recoveryActionErrorMessage = appState.localizedError(error)"))
        XCTAssertFalse(source.contains("try? ForgePlayApp.applicationSupportDirectory()"))
    }

    func testMainWindowDoesNotUseHiddenTitlebarOverlay() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/ForgePlayApp.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".windowStyle(.hiddenTitleBar)"))
    }

    func testSuccessAndStartupFailureScenesConfigureTerminationCleanup() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/ForgePlayApp.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(
            source.components(separatedBy: "applicationDelegate.configure(appState: appState, services: services)").count - 1,
            4
        )
        XCTAssertTrue(source.contains(
            "didCompleteTerminationCleanup = waitResult != .timedOut && summary?.succeeded == true"
        ))
    }

    func testSettingsSceneOpensMainWindowWithoutDuplicatingInWindowNavigation() throws {
        let root = try projectRoot()
        let appSource = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/ForgePlayApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("opensMainWindowForNavigation: true"))
        XCTAssertTrue(settingsSource.contains("var opensMainWindowForNavigation = false"))
        XCTAssertTrue(settingsSource.contains("if opensMainWindowForNavigation {"))
        XCTAssertTrue(settingsSource.contains("openWindow(id: ForgePlaySceneID.main)"))

        let sheetSource = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sheetSource.contains("opensMainWindowForNavigation: opensMainWindowForNavigation"))
        XCTAssertTrue(sheetSource.contains("if opensMainWindowForNavigation {"))
        XCTAssertTrue(sheetSource.contains("openWindow(id: ForgePlaySceneID.main)"))
    }

    func testRootStartupPresentationTransitionsToReadyOrRecovery() {
        let loading = ForgePlayRootStartupPresentation.loading

        XCTAssertTrue(loading.showsBrandedLoading)
        XCTAssertFalse(ForgePlayRootStartupPresentation.ready.showsBrandedLoading)
        XCTAssertFalse(ForgePlayRootStartupPresentation.recovery.showsBrandedLoading)
        XCTAssertEqual(loading.transitioned(for: .succeeded), .ready)
        XCTAssertEqual(loading.transitioned(for: .failed), .recovery)
        XCTAssertEqual(loading.transitioned(for: .requiresUserIntervention), .recovery)
    }

    func testSidebarPrioritizesBothSteamLaunchDestinationsAndKeepsStartupRouting() {
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        let launchableReadiness = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: prefix.appending(
                path: "drive_c/Program Files (x86)/Steam/steam.exe"
            ),
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .ok,
                userMessage: "ready",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            )
        )
        XCTAssertEqual(
            Array(ForgePlayRootSidebarNavigation.primarySections.prefix(2)),
            [.steamLaunch, .steamCompatibilityLaunch]
        )
        XCTAssertEqual(
            ForgePlayRootSidebarNavigation.primarySections.filter {
                $0 == .steamLaunch || $0 == .steamCompatibilityLaunch
            },
            [.steamLaunch, .steamCompatibilityLaunch]
        )
        XCTAssertFalse(
            ForgePlayRootSidebarNavigation.primarySections.contains(.setup),
            "The bottom system-readiness control is the single sidebar entry point for Setup."
        )
        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .dashboard,
                readiness: launchableReadiness
            ),
            .steamLaunch
        )
        XCTAssertEqual(
            AppStartupDestinationResolver.resolve(
                current: .dashboard,
                readiness: .empty
            ),
            .setup
        )
    }

    func testWhyStoryUsesBundledNativeTextForEveryAppLanguage() throws {
        let expectedResources: [ForgePlayLanguageMode: String] = [
            .english: "en",
            .korean: "ko",
            .spanish: "es",
            .german: "de",
            .japanese: "ja",
            .simplifiedChinese: "zh-Hans",
            .traditionalChinese: "zh-Hant",
            .french: "fr"
        ]
        let root = try projectRoot()

        for (language, resourceName) in expectedResources {
            XCTAssertEqual(
                ForgePlayWhyStoryResource.resourceName(for: language),
                resourceName
            )
            let markdown = try String(
                contentsOf: root.appending(
                    path: "site-data/why-story/\(resourceName).md"
                ),
                encoding: .utf8
            )
            let document = ForgePlayWhyStoryDocument(markdown: markdown)
            XCTAssertEqual(document.sourceMarkdown, markdown)
            XCTAssertGreaterThan(document.blocks.count, 50)
            XCTAssertTrue(
                document.blocks.contains { block in
                    if case .heading(level: 2) = block.kind { return true }
                    return false
                }
            )
            XCTAssertFalse(
                document.blocks.contains { $0.text.contains("[^") },
                "Internal Markdown footnote identifiers must never reach the reader UI."
            )
            let referenceNumbers = document.blocks.compactMap { block -> Int? in
                if case .reference(let number) = block.kind { return number }
                return nil
            }
            XCTAssertEqual(referenceNumbers, Array(1...8))
            XCTAssertTrue(document.blocks.contains { $0.text.contains("¹") })
        }

        XCTAssertEqual(
            ForgePlayWhyStoryResource.resourceName(
                for: .system,
                resolveSystemLanguage: { .korean }
            ),
            "ko"
        )

        let source = try String(
            contentsOf: root.appending(
                path: "Sources/ForgePlay/UI/ForgePlayOverviewView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("import WebKit"))
        XCTAssertFalse(source.contains("WKWebView"))
        XCTAssertFalse(source.contains("브라우저에서 전문 열기"))
        XCTAssertFalse(source.contains("연결 방식"))
        XCTAssertTrue(source.contains("ForgePlayWhyStoryResource.load"))
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))

        let project = try String(
            contentsOf: root.appending(path: "project.yml"),
            encoding: .utf8
        )
        XCTAssertFalse(project.contains("WebKit.framework"))
        XCTAssertTrue(project.contains("- path: site-data/why-story"))
        XCTAssertTrue(project.contains("type: folder"))
    }

    func testSidebarCommunityActionsExposeHoverHighlightAndExplanation() throws {
        XCTAssertEqual(
            ForgePlaySidebarCommunityAction.allCases.map(\.titleKey),
            ["⭐ 좋아요", "💗 후원하기"]
        )
        XCTAssertEqual(
            ForgePlaySidebarCommunityAction.allCases.map(\.helpKey),
            [
                "GitHub 저장소에서 ForgePlay에 Star를 남깁니다.",
                "GitHub Sponsors에서 ForgePlay를 후원합니다."
            ]
        )
        XCTAssertTrue(
            ForgePlaySidebarCommunityAction.allCases.allSatisfy { $0.url != nil }
        )

        let source = try String(
            contentsOf: projectRoot().appending(
                path: "Sources/ForgePlay/UI/RootView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("@State private var hoveredCommunityAction"))
        XCTAssertTrue(source.contains(".onHover { isHovering in"))
        XCTAssertTrue(source.contains("palette.primary.opacity(0.15)"))
        XCTAssertTrue(source.contains("appState.localized(hoveredCommunityAction.helpKey)"))
        XCTAssertTrue(source.contains("selection = .setup"))
    }

    func testSidebarShowsBundleVersionAndManualHomepageUpdateCheck() throws {
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.2", build: "3"),
            "ForgePlay 1.2 (3)"
        )
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: " 1.2 ", build: " 3 "),
            "ForgePlay 1.2 (3)"
        )
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.2", build: nil),
            "ForgePlay 1.2"
        )

        let rootSource = try String(
            contentsOf: projectRoot().appending(
                path: "Sources/ForgePlay/UI/RootView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(rootSource.contains("Text(AppBuildInfo.displayVersion)"))
        XCTAssertTrue(rootSource.contains("appState.localized(updateCheckPresentation.labelKey)"))
        XCTAssertTrue(rootSource.contains("AppUpdateService().checkForUpdate()"))
        XCTAssertTrue(rootSource.contains("case .idle: \"업데이트 확인 (베타)\""))
        XCTAssertTrue(rootSource.contains("case .checking: \"업데이트 확인 중\""))
        XCTAssertTrue(rootSource.contains("case .noUpdate: \"업데이트 없음\""))
        XCTAssertTrue(rootSource.contains("case .updateRequired: \"업데이트 필요\""))
        XCTAssertTrue(rootSource.contains("case .noUpdate:"))
        XCTAssertTrue(rootSource.contains("case .updateRequired:"))
        XCTAssertFalse(rootSource.contains("appState.openExternalURL(ExternalLinkPolicy.forgePlayReleasesURL)"))

        let versionConfiguration = try String(
            contentsOf: projectRoot().appending(
                path: "Config/ForgePlayDefaults.xcconfig"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(versionConfiguration.contains("FORGEPLAY_MARKETING_VERSION = 1.2"))
        XCTAssertTrue(versionConfiguration.contains("FORGEPLAY_CURRENT_PROJECT_VERSION = 3"))
    }

    func testCompatibilityCatalogReusesOneFilteredProjectionPerContentRender() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/CompatibilityCatalogView.swift"),
            encoding: .utf8
        )
        let contentSource = try XCTUnwrap(
            source.components(separatedBy: "private func catalogContent(palette: ForgePlayPalette) -> some View {").last?
                .components(separatedBy: "private var filteredEntries:").first
        )

        XCTAssertEqual(
            contentSource.components(separatedBy: "filteredEntries").count - 1,
            1
        )
        XCTAssertTrue(contentSource.contains("let entries = filteredEntries"))
        XCTAssertTrue(contentSource.contains("if entries.isEmpty"))
        XCTAssertTrue(contentSource.contains("ForEach(entries)"))
        XCTAssertTrue(source.contains("refreshTask?.cancel()"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled else { return }"))
    }

    func testDismissingManagedStorageSheetDoesNotImplicitlyRetryStartup() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/RootView.swift"),
            encoding: .utf8
        )
        let initialStartupSource = try XCTUnwrap(
            source.components(separatedBy: "private func runStartupWorkflow() async {").last?
                .components(separatedBy: "private func resumeStartupAfterRootSheet").first
        )
        let functionSource = try XCTUnwrap(
            source.components(separatedBy: "private func resumeStartupAfterRootSheet() async {").last?
                .components(separatedBy: "private func finalizeStartup").first
        )

        XCTAssertTrue(source.contains("@State private var didAttemptStartupWorkflow = false"))
        XCTAssertTrue(initialStartupSource.contains("guard !didLoad, !didAttemptStartupWorkflow, !isStartupInProgress else { return }"))
        XCTAssertTrue(initialStartupSource.contains("didAttemptStartupWorkflow = true"))
        XCTAssertTrue(functionSource.contains("guard case .ready = services.managedStoragePreparationState else { return }"))
        XCTAssertFalse(functionSource.contains("runStartupWorkflow"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
        }
        throw XCTSkip("Could not locate project root from #filePath")
    }

    private func temporaryDirectory(named prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
