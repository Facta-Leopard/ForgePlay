import SwiftData
import XCTest
@testable import ForgePlay

private final class PrefixRestoreFailureFileManager: FileManager {
    var failingCopySourcePath: String?
    var shouldFailStagingMoveToDestination = false

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if let failingCopySourcePath,
           srcURL.standardizedFileURL.path == failingCopySourcePath {
            throw CocoaError(.fileReadUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldFailStagingMoveToDestination,
           srcURL.lastPathComponent.contains(".restore-staging-") {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class PrefixStagingFontCopyFailureFileManager: FileManager {
    private(set) var failedDestination: URL?

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.pathExtension.lowercased() == "ttf",
           dstURL.path.contains(".SteamShared."),
           dstURL.path.contains("-staging-") {
            failedDestination = dstURL
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private enum PostWineInitializationFailureFlow: String, CaseIterable {
    case initialize
    case rebuild
    case reset

    var stagingNameFragment: String {
        ".\(rawValue)-staging-"
    }
}

private final class PrefixSwapFailureInjector: PrefixDirectorySwapping {
    var shouldFailNextSwap = false
    private let swapper = AtomicPrefixDirectorySwapper()

    func swap(_ first: URL, _ second: URL) throws {
        if shouldFailNextSwap {
            shouldFailNextSwap = false
            throw CocoaError(.fileWriteUnknown)
        }
        try swapper.swap(first, second)
    }
}

private final class PrefixQuiescenceCheckRecorder {
    private(set) var paths: [String] = []

    func record(_ url: URL) {
        paths.append(url.standardizedFileURL.path)
    }
}

private final class PrefixQuiescenceContractSwapper: PrefixDirectorySwapping {
    private let recorder: PrefixQuiescenceCheckRecorder
    private let swapper = AtomicPrefixDirectorySwapper()
    private(set) var firstSwapURLs: [URL]?
    private(set) var quiescenceChecksAtFirstSwap: [String]?

    init(recorder: PrefixQuiescenceCheckRecorder) {
        self.recorder = recorder
    }

    func swap(_ first: URL, _ second: URL) throws {
        if firstSwapURLs == nil {
            firstSwapURLs = [first, second]
            quiescenceChecksAtFirstSwap = recorder.paths
        }
        try swapper.swap(first, second)
    }
}

private final class PrefixRollbackFailureInjector: PrefixDirectorySwapping {
    private let swapper = AtomicPrefixDirectorySwapper()
    private(set) var displacedEnvironmentURL: URL?
    private var swapCount = 0

    func swap(_ first: URL, _ second: URL) throws {
        swapCount += 1
        if swapCount == 1 {
            try swapper.swap(first, second)
            displacedEnvironmentURL = first
            try FileManager.default.removeItem(at: second.appending(path: "user.reg"))
            return
        }
        throw CocoaError(.fileWriteUnknown)
    }
}

@MainActor
final class PrefixManagerTests: XCTestCase {
    func testPrefixRecordUpsertMirrorsMetadataListsOnCreateAndUpdate() throws {
        let schema = Schema([PrefixRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        var metadata = makePrefixMetadata()
        metadata.schemaVersion = PrefixMetadata.currentSchemaVersion
        metadata.runtimeBinding = PrefixRuntimeBinding(manifest: makeRuntimeManifest(seed: "a"))

        let created = try PrefixRecord.upsert(metadata: metadata, in: context)

        XCTAssertEqual(try decodeArray(created.installedRuntimesJSON), [.vcrun2022, .openal] as [RuntimeId])
        XCTAssertEqual(try decodeArray(created.dllOverridesJSON), ["d3dcompiler_47=native,builtin"])
        XCTAssertEqual(try decodeArray(created.launchOptionsJSON), ["-windowed"])
        XCTAssertEqual(try decodeArray(created.snapshotsJSON), ["/tmp/snapshot-a"])
        XCTAssertEqual(created.runnerBuildFingerprint, metadata.runtimeBinding?.runnerBuildFingerprint)
        XCTAssertEqual(
            created.prefixCompatibilityFingerprint,
            metadata.runtimeBinding?.prefixCompatibilityFingerprint
        )

        metadata.installedRuntimes = [.dotnet48]
        metadata.dllOverrides = ["xinput1_3=native,builtin"]
        metadata.launchOptions = ["-force-d3d11", "-novid"]
        metadata.snapshots = ["/tmp/snapshot-b", "/tmp/snapshot-c"]
        metadata.runtimeBinding = PrefixRuntimeBinding(manifest: makeRuntimeManifest(seed: "b"))
        metadata.updatedAt = Date(timeIntervalSince1970: 2)

        let updated = try PrefixRecord.upsert(metadata: metadata, in: context)

        XCTAssertTrue(created === updated)
        XCTAssertEqual(try decodeArray(updated.installedRuntimesJSON), [.dotnet48] as [RuntimeId])
        XCTAssertEqual(try decodeArray(updated.dllOverridesJSON), ["xinput1_3=native,builtin"])
        XCTAssertEqual(try decodeArray(updated.launchOptionsJSON), ["-force-d3d11", "-novid"])
        XCTAssertEqual(try decodeArray(updated.snapshotsJSON), ["/tmp/snapshot-b", "/tmp/snapshot-c"])
        XCTAssertEqual(updated.runnerBuildFingerprint, metadata.runtimeBinding?.runnerBuildFingerprint)
        XCTAssertEqual(
            updated.prefixCompatibilityFingerprint,
            metadata.runtimeBinding?.prefixCompatibilityFingerprint
        )
    }

    func testLoadMetadataRejectsSymlinkPrefixJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalMetadata = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefix-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalMetadata)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        try FileManager.default.removeItem(at: metadataURL)
        try Data("{}".utf8).write(to: externalMetadata)
        try FileManager.default.createSymbolicLink(at: metadataURL, withDestinationURL: externalMetadata)

        do {
            _ = try prefixManager.loadMetadata(at: prefixURL)
            XCTFail("Expected symlink prefix metadata to be rejected")
        } catch PrefixMetadataError.unsafeMetadataFile(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, metadataURL.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadMetadataRejectsOversizedPrefixJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        try Data(repeating: UInt8(ascii: "x"), count: 300 * 1024).write(to: metadataURL)

        do {
            _ = try prefixManager.loadMetadata(at: prefixURL)
            XCTFail("Expected oversized prefix metadata to be rejected")
        } catch PrefixMetadataError.metadataTooLarge(let url, let byteCount, let limit) {
            XCTAssertEqual(url.standardizedFileURL.path, metadataURL.standardizedFileURL.path)
            XCTAssertEqual(byteCount, 300 * 1024)
            XCTAssertLessThan(limit, byteCount)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadMetadataNormalizesStoredLaunchOptionsAndLists() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        var metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        metadata.installedRuntimes = [.vcrun2022, .vcrun2022, .openal]
        metadata.launchOptions = [" -Windowed ", "; rm -rf /", "-windowed", "-force-d3d11"]
        metadata.dllOverrides = [" d3dcompiler_47=native,builtin ", "", "bad\nvalue"]
        metadata.snapshots = [" /tmp/snapshot ", "/tmp/snapshot", ""]
        metadata.environmentVariables = ["DYLD_LIBRARY_PATH": "/tmp/injected"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL)

        let loaded = try prefixManager.loadMetadata(at: prefixURL)

        XCTAssertEqual(loaded.installedRuntimes, [.vcrun2022, .openal])
        XCTAssertEqual(loaded.launchOptions, ["-windowed", "-force-d3d11"])
        XCTAssertEqual(loaded.dllOverrides, ["d3dcompiler_47=native,builtin"])
        XCTAssertEqual(loaded.snapshots, ["/tmp/snapshot"])
        XCTAssertTrue(loaded.environmentVariables.isEmpty)
    }

    func testPrefixMetadataMigratesLegacySynchronizationPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(metadata)
        var legacyDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyDocument["schemaVersion"] = 1
        legacyDocument.removeValue(forKey: "synchronizationSelection")
        legacyDocument.removeValue(forKey: "synchronizationBackend")
        try JSONSerialization.data(withJSONObject: legacyDocument, options: [.sortedKeys])
            .write(to: prefixURL.appending(path: "prefix.json"))

        let loaded = try prefixManager.loadMetadata(at: prefixURL)
        XCTAssertEqual(loaded.synchronizationSelection, .automatic)
        XCTAssertEqual(loaded.synchronizationBackend, .server)
    }

    func testPrefixSynchronizationContractExposesAutomaticServerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()

        XCTAssertEqual(WineSynchronizationSelection.allCases, [.automatic])
        XCTAssertEqual(WineSynchronizationBackend.allCases, [.server])
        XCTAssertEqual(metadata.synchronizationSelection, .automatic)
        XCTAssertEqual(metadata.synchronizationBackend, .server)
        XCTAssertEqual(WineSynchronizationPolicy.automaticServer.selection, .automatic)
        XCTAssertEqual(WineSynchronizationPolicy.automaticServer.backend, .server)
        XCTAssertTrue(WineSynchronizationPolicy.automaticServer.isConsistent)
    }

    func testSteamEnvironmentGenerationIsStableUntilExplicitRotation() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let initialGeneration = try XCTUnwrap(metadata.environmentGenerationID)

        XCTAssertEqual(try prefixManager.ensureSteamSharedEnvironmentGenerationID(), initialGeneration)
        let rotatedGeneration = try prefixManager.rotateSteamSharedEnvironmentGeneration()
        XCTAssertNotEqual(rotatedGeneration, initialGeneration)
        XCTAssertEqual(
            try prefixManager.loadMetadata(at: URL(fileURLWithPath: metadata.path)).environmentGenerationID,
            rotatedGeneration
        )
    }

    func testCreateSteamSharedPrefixDoesNotOverwriteInvalidExistingMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let metadataURL = URL(fileURLWithPath: metadata.path).appending(path: "prefix.json")
        try Data("{".utf8).write(to: metadataURL)

        XCTAssertThrowsError(try prefixManager.createSteamSharedPrefix())
        XCTAssertEqual(try String(contentsOf: metadataURL, encoding: .utf8), "{")
    }

    func testIsUsablePrefixRejectsInvalidExistingMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))

        try Data("{".utf8).write(to: prefixURL.appending(path: "prefix.json"))

        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL, expectedArchitecture: "win64"))
        XCTAssertThrowsError(try prefixManager.validateUsablePrefix(at: prefixURL)) { error in
            guard case PrefixUsabilityError.invalidMetadata(let url, _) = error else {
                return XCTFail("Expected invalidMetadata, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, prefixURL.appending(path: "prefix.json").standardizedFileURL.path)
        }
    }

    func testIsUsablePrefixRejectsUnreadableSystemRegistry() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let systemRegistry = prefixURL.appending(path: "system.reg")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: systemRegistry.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: systemRegistry,
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: systemRegistry.path)

        XCTAssertThrowsError(try prefixManager.prefixArchitecture(at: prefixURL))
        XCTAssertThrowsError(try prefixManager.validateUsablePrefix(at: prefixURL)) { error in
            guard case PrefixUsabilityError.unreadableRequiredItem(let url, _) = error else {
                return XCTFail("Expected unreadableRequiredItem, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, systemRegistry.standardizedFileURL.path)
        }
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL, expectedArchitecture: "win64"))

        try FileManager.default.removeItem(at: prefixURL.appending(path: "prefix.json"))

        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testValidateUsablePrefixRejectsUnsafeRequiredRegistryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRegistry = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRegistry-\(UUID().uuidString).reg")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRegistry)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let systemRegistry = prefixURL.appending(path: "system.reg")
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: externalRegistry,
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: systemRegistry, withDestinationURL: externalRegistry)

        XCTAssertThrowsError(try prefixManager.validateUsablePrefix(at: prefixURL)) { error in
            guard case PrefixUsabilityError.unsafeRequiredItem(let url) = error else {
                return XCTFail("Expected unsafeRequiredItem, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, systemRegistry.standardizedFileURL.path)
        }
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testValidateUsablePrefixRejectsHardlinkedRequiredRegistryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRegistry = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalHardlinkedRegistry-\(UUID().uuidString).reg")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRegistry)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let systemRegistry = prefixURL.appending(path: "system.reg")
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: externalRegistry,
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.linkItem(at: externalRegistry, to: systemRegistry)

        XCTAssertThrowsError(try prefixManager.validateUsablePrefix(at: prefixURL)) { error in
            guard case PrefixUsabilityError.unsafeRequiredItem(let url) = error else {
                return XCTFail("Expected unsafeRequiredItem, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, systemRegistry.standardizedFileURL.path)
        }
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testCreateSteamSharedPrefixRejectsSymlinkPrefixDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalPrefix = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalPrefix)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        try FileManager.default.createDirectory(at: externalPrefix, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: prefixURL)
        try FileManager.default.createSymbolicLink(at: prefixURL, withDestinationURL: externalPrefix)

        do {
            _ = try prefixManager.createSteamSharedPrefix()
            XCTFail("Expected symlink prefix directory to be rejected")
        } catch PrefixMetadataError.unsafePrefixDirectory(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, prefixURL.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPrepareSteamSharedPrefixReinitializesArchitectureMismatchWithoutPersistentSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let marker = prefixURL.appending(path: "win32-marker.txt")
        try Data("replace mismatch without backup".utf8).write(to: marker)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win32\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )

        let launcher = try makePrefixInitializerLauncher(in: root)

        let result = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
        let stdout = try XCTUnwrap(result.processResult?.stdoutLog)
        let output = try String(contentsOf: stdout, encoding: .utf8)

        XCTAssertTrue(result.isInitialized)
        XCTAssertEqual(result.processResult?.succeeded, true)
        XCTAssertTrue(output.contains("initialized:win64"))
        XCTAssertEqual(try prefixManager.prefixArchitecture(at: prefixURL), "win64")
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
        XCTAssertTrue(result.metadata.snapshots.isEmpty)
        XCTAssertNil(result.residualPreviousEnvironmentURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPrepareSteamSharedPrefixPreservesExistingPrefixWhenArchitectureResetInitializationFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let marker = prefixURL.appending(path: "win32-marker.txt")
        try Data("existing prefix".utf8).write(to: marker)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win32\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )

        let cleanupMarker = root.appending(path: "failed-initialization-cleanup.log")
        let failingLauncher = try makeFailingPrefixInitializerLauncher(
            in: root,
            cleanupMarker: cleanupMarker
        )

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: failingLauncher)
            XCTFail("Expected architecture reset initialization to fail")
        } catch let error as PrefixManagerError {
            XCTAssertEqual(error.result.exitCode, 42)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "existing prefix")
        XCTAssertEqual(try prefixManager.prefixArchitecture(at: prefixURL), "win32")
        let cleanupLifecycle = try String(contentsOf: cleanupMarker, encoding: .utf8)
        XCTAssertTrue(cleanupLifecycle.contains(".SteamShared.reset-staging-"), cleanupLifecycle)
        XCTAssertTrue(cleanupLifecycle.contains(":--kill=\(SIGTERM)"), cleanupLifecycle)
        let preservedMetadata = try prefixManager.loadMetadata(at: prefixURL)
        XCTAssertTrue(preservedMetadata.snapshots.isEmpty)

        let prefixParentItems = try FileManager.default.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(prefixParentItems.contains { $0.lastPathComponent.contains(".reset-staging-") })
    }

    func testPrepareSteamSharedPrefixSeedsWineFontsForExistingUsablePrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let launcher = try makePrefixInitializerLauncherWithFonts(in: root)

        let result = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
        let seededFont = prefixURL.appending(path: "drive_c/windows/Fonts/tahoma.ttf")

        XCTAssertTrue(result.isInitialized)
        XCTAssertEqual(result.processResult?.actionName, "migratePrefixRuntime")
        XCTAssertEqual(result.processResult?.succeeded, true)
        XCTAssertEqual(try String(contentsOf: seededFont, encoding: .utf8), "font")
    }

    func testPrepareMigratesLegacyRuntimeBindingOnceAndDisablesImplicitWineUpdates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        var metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let legacyGeneration = try XCTUnwrap(metadata.environmentGenerationID)
        metadata.schemaVersion = 1
        metadata.runtimeBinding = nil
        try prefixManager.save(metadata, at: prefixURL)
        try Data("1784039919\n".utf8).write(to: prefixURL.appending(path: ".update-timestamp"))

        let lifecycleMarker = root.appending(path: "runtime-migration-lifecycle.log")
        let launcher = try makeRegistryFlushRuntime(in: root, marker: lifecycleMarker)
        let expectedManifest = try RuntimeManifestResolver().manifest(for: launcher)

        let migrated = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
        let lifecycleAfterMigration = try String(contentsOf: lifecycleMarker, encoding: .utf8)
        let migratedMetadata = try prefixManager.loadMetadata(at: prefixURL)

        XCTAssertEqual(migrated.processResult?.actionName, "migratePrefixRuntime")
        XCTAssertTrue(lifecycleAfterMigration.contains("wineboot:wineboot -u"), lifecycleAfterMigration)
        XCTAssertTrue(lifecycleAfterMigration.contains(":-w"), lifecycleAfterMigration)
        XCTAssertEqual(migratedMetadata.schemaVersion, PrefixMetadata.currentSchemaVersion)
        XCTAssertEqual(migratedMetadata.runtimeBinding?.runnerBuildFingerprint, expectedManifest.runnerBuildFingerprint)
        XCTAssertEqual(
            migratedMetadata.runtimeBinding?.prefixCompatibilityFingerprint,
            expectedManifest.prefixCompatibilityFingerprint
        )
        XCTAssertNotEqual(migratedMetadata.environmentGenerationID, legacyGeneration)
        XCTAssertEqual(
            try String(contentsOf: prefixURL.appending(path: ".update-timestamp"), encoding: .utf8),
            "disable\n"
        )

        let secondPreparation = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
        XCTAssertNil(secondPreparation.processResult)
        XCTAssertEqual(
            try String(contentsOf: lifecycleMarker, encoding: .utf8),
            lifecycleAfterMigration,
            "A matching runtime binding must not rerun wineboot or wineserver during preparation."
        )
        XCTAssertNoThrow(try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(runtimeExecutable: launcher))
    }

    func testFailedRuntimeMigrationDoesNotPublishBindingOrRotateGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        var metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let originalSystemRegistry = "WINE REGISTRY Version 2\n#arch=win64\n#preserve=canonical\n"
        try originalSystemRegistry.write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let legacyGeneration = try XCTUnwrap(metadata.environmentGenerationID)
        metadata.schemaVersion = 1
        metadata.runtimeBinding = nil
        try prefixManager.save(metadata, at: prefixURL)
        let updateMarker = prefixURL.appending(path: ".update-timestamp")
        try Data("1784039919\n".utf8).write(to: updateMarker)

        let cleanupMarker = root.appending(path: "failed-runtime-migration-cleanup.log")
        let launcher = try makeFailingPrefixInitializerLauncher(
            in: root,
            cleanupMarker: cleanupMarker
        )

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected runtime migration to fail")
        } catch let error as PrefixManagerError {
            XCTAssertEqual(error.result.exitCode, 42)
        }

        let preserved = try prefixManager.loadMetadata(at: prefixURL)
        XCTAssertEqual(preserved.schemaVersion, 1)
        XCTAssertNil(preserved.runtimeBinding)
        XCTAssertEqual(preserved.environmentGenerationID, legacyGeneration)
        XCTAssertEqual(try String(contentsOf: updateMarker, encoding: .utf8), "1784039919\n")
        XCTAssertEqual(
            try String(contentsOf: prefixURL.appending(path: "system.reg"), encoding: .utf8),
            originalSystemRegistry,
            "A failed runtime migration must not mutate the canonical Steam Prefix."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefixURL.appending(path: "failed-runtime-mutation.txt").path
            )
        )
        XCTAssertThrowsError(
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(runtimeExecutable: launcher)
        ) { error in
            guard case PrefixRuntimeCompatibilityError.migrationRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPrepareSteamSharedPrefixInitializesMetadataOnlyPrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runner = makeCuratedRuntimeRunner()
        let quiescenceRecorder = PrefixQuiescenceCheckRecorder()
        let swapper = PrefixQuiescenceContractSwapper(recorder: quiescenceRecorder)
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: runner,
            directorySwapper: swapper,
            prefixReplacementQuiescenceVerifier: { prefix in
                quiescenceRecorder.record(prefix)
                try await runner.requirePrefixReplacementQuiescence(prefix)
            }
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let launchMarkerObservation = root.appending(path: "launch-preservation-marker-state.txt")
        let launcher = try makePrefixInitializerLauncher(
            in: root,
            launchMarkerObservation: launchMarkerObservation
        )

        let result = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)

        XCTAssertTrue(result.isInitialized)
        XCTAssertEqual(result.processResult?.succeeded, true)
        XCTAssertEqual(try prefixManager.prefixArchitecture(at: prefixURL), "win64")
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
        XCTAssertEqual(
            try String(contentsOf: launchMarkerObservation, encoding: .utf8),
            "present\n",
            "The crash-recovery marker must exist before Wine can touch replacement staging."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefixURL.appending(path: ".forgeplay-preserve-recovery").path
            ),
            "A verified quiescent staging prefix must not publish its recovery marker."
        )
        try await runner.requirePrefixReplacementQuiescence(prefixURL)
        let swapURLs = try XCTUnwrap(swapper.firstSwapURLs)
        let checksAtSwap = try XCTUnwrap(swapper.quiescenceChecksAtFirstSwap)
        XCTAssertEqual(
            Array(checksAtSwap.suffix(2)),
            swapURLs.map { $0.standardizedFileURL.path },
            "The staging and destination prefixes must both pass the final quiescence gate immediately before the atomic swap."
        )
    }

    func testPrepareSteamSharedPrefixRetriesFromCleanStagingAfterFailedBootstrap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let cleanupMarker = root.appending(path: "failed-first-bootstrap-cleanup.log")
        let failingLauncher = try makeFailingPrefixInitializerLauncher(
            in: root,
            cleanupMarker: cleanupMarker
        )

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: failingLauncher)
            XCTFail("Expected first bootstrap to fail")
        } catch let error as PrefixManagerError {
            XCTAssertEqual(error.result.exitCode, 42)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: prefixURL.appending(path: "drive_c").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefixURL.appending(path: "system.reg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefixURL.appending(path: "user.reg").path))
        let siblingsAfterFailure = try FileManager.default.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblingsAfterFailure.contains { $0.lastPathComponent.contains(".initialize-staging-") })

        let successfulLauncher = try makePrefixInitializerLauncher(in: root)
        let result = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: successfulLauncher)

        XCTAssertTrue(result.isInitialized)
        XCTAssertEqual(result.processResult?.succeeded, true)
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testPrepareSteamSharedPrefixWaitsForRegistryFlushBeforeValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let marker = root.appending(path: "wine-lifecycle.log")
        let launcher = try makeRegistryFlushRuntime(in: root, marker: marker)

        let result = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
        let lifecycle = try String(contentsOf: marker, encoding: .utf8)

        XCTAssertTrue(result.isInitialized)
        XCTAssertEqual(result.processResult?.succeeded, true)
        XCTAssertTrue(lifecycle.contains("wineboot:wineboot -u"))
        XCTAssertTrue(
            lifecycle.split(whereSeparator: \.isNewline).contains {
                $0.contains(".SteamShared.initialize-staging-") && $0.hasSuffix(":-w")
            },
            lifecycle
        )
        XCTAssertEqual(try prefixManager.prefixArchitecture(at: prefixURL), "win64")
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testPrepareSteamSharedPrefixCleansUpWhenRegistryFlushFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        _ = try prefixManager.createSteamSharedPrefix()
        let marker = root.appending(path: "failed-registry-flush-lifecycle.log")
        let launcher = try makeFailingRegistryFlushRuntime(in: root, marker: marker)

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected registry flush to fail")
        } catch let error as PrefixManagerError {
            XCTAssertEqual(error.result.exitCode, 37)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let lifecycle = try String(contentsOf: marker, encoding: .utf8)
        let lifecycleLines = lifecycle.split(whereSeparator: \.isNewline).map(String.init)
        let waitIndex = try XCTUnwrap(lifecycleLines.firstIndex {
            $0.contains(".SteamShared.initialize-staging-") && $0.hasSuffix(":-w")
        }, lifecycle)
        let failedStagingPrefix = String(
            lifecycleLines[waitIndex].dropFirst("wineserver:".count).dropLast(":-w".count)
        )
        let cleanupIndex = try XCTUnwrap(lifecycleLines.firstIndex {
            $0 == "wineserver:\(failedStagingPrefix):--kill=\(SIGTERM)"
        }, lifecycle)
        let shutdownBarrierIndex = try XCTUnwrap(lifecycleLines.lastIndex {
            $0 == "wineserver:\(failedStagingPrefix):-w"
        }, lifecycle)
        XCTAssertLessThan(waitIndex, cleanupIndex)
        XCTAssertLessThan(cleanupIndex, shutdownBarrierIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedStagingPrefix))
    }

    func testPrepareSteamSharedPrefixPreservesStagingWhenFailedBootstrapCleanupIsUnconfirmed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let canonicalMarker = prefixURL.appending(path: "canonical-prefix-marker.txt")
        try Data("canonical".utf8).write(to: canonicalMarker)
        let lifecycleMarker = root.appending(path: "unconfirmed-bootstrap-cleanup.log")
        let launcher = try makeFailingPrefixInitializerWithUnconfirmedCleanupRuntime(
            in: root,
            marker: lifecycleMarker
        )

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected bootstrap and cleanup to fail")
        } catch let error as PrefixManagerError {
            guard case .initializationCleanupFailed = error else {
                return XCTFail("Unexpected prefix error: \(error)")
            }
            XCTAssertEqual(error.result.exitCode, 42)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let siblings = try FileManager.default.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        let preservedStaging = try XCTUnwrap(siblings.first {
            $0.lastPathComponent.contains(".SteamShared.initialize-staging-")
        })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preservedStaging.appending(path: "failed-runtime-mutation.txt").path
            )
        )
        let preservationMarker = preservedStaging.appending(
            path: ".forgeplay-preserve-recovery"
        )
        XCTAssertTrue(
            FileSystemItemPolicy.isRegularNonSymlinkFile(
                preservationMarker,
                fileManager: .default
            )
        )
        let markerAttributes = try FileManager.default.attributesOfItem(
            atPath: preservationMarker.path
        )
        XCTAssertEqual(
            (markerAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(try String(contentsOf: canonicalMarker, encoding: .utf8), "canonical")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefixURL.appending(path: "drive_c").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefixURL.appending(path: "system.reg").path))

        let lifecycle = try String(contentsOf: lifecycleMarker, encoding: .utf8)
        XCTAssertTrue(
            lifecycle.contains("\(preservedStaging.lastPathComponent):--kill=\(SIGTERM)"),
            lifecycle
        )
        XCTAssertGreaterThanOrEqual(
            lifecycle.split(whereSeparator: \.isNewline).filter {
                $0.contains("\(preservedStaging.lastPathComponent):-w")
            }.count,
            2,
            lifecycle
        )

        let nextLaunchPrefixManager = PrefixManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner()
        )
        try nextLaunchPrefixManager.cleanupInterruptedReplacementArtifacts(at: prefixURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preservedStaging.path),
            "A later app launch must not discard staging whose Wine cleanup was never verified."
        )
        XCTAssertEqual(try String(contentsOf: canonicalMarker, encoding: .utf8), "canonical")
    }

    func testPrepareSteamSharedPrefixDeletesVerifiedStagingWhenCanonicalShutdownFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let canonicalMarker = prefixURL.appending(path: "canonical-prefix-marker.txt")
        try Data("canonical".utf8).write(to: canonicalMarker)
        let lifecycleMarker = root.appending(path: "canonical-second-shutdown-failure.log")
        let launcher = try makeCanonicalSecondShutdownFailureRuntime(
            in: root,
            marker: lifecycleMarker
        )

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected the final canonical-prefix shutdown to fail")
        } catch is SteamPrefixLifecycleCleanupError {
            // Expected: the canonical destination could not be verified inactive.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try String(contentsOf: canonicalMarker, encoding: .utf8), "canonical")
        let siblings = try FileManager.default.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(
            siblings.contains { $0.lastPathComponent.contains(".initialize-staging-") },
            "Staging already verified quiescent must be removed when only canonical cleanup fails."
        )
        let lifecycle = try String(contentsOf: lifecycleMarker, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(
            lifecycle.split(whereSeparator: \.isNewline).filter {
                $0.contains(prefixURL.lastPathComponent) && $0.hasSuffix(":-w")
            }.count,
            3,
            lifecycle
        )
    }

    func testInitializeStagingVerifiesCleanupAfterPostWineFailure() async throws {
        try await assertPostWineFontFailureCleansStaging(flow: .initialize)
    }

    func testRebuildStagingVerifiesCleanupAfterPostWineFailure() async throws {
        try await assertPostWineFontFailureCleansStaging(flow: .rebuild)
    }

    func testResetStagingVerifiesCleanupAfterPostWineFailure() async throws {
        try await assertPostWineFontFailureCleansStaging(flow: .reset)
    }

    func testRuntimeMigrationStagingVerifiesCleanupAfterPostWineValidationFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        var metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try createUsablePrefixContents(at: prefixURL, architecture: "win64")
        let canonicalMarker = prefixURL.appending(path: "canonical-prefix-marker.txt")
        try Data("canonical".utf8).write(to: canonicalMarker)
        metadata.schemaVersion = 1
        metadata.runtimeBinding = nil
        try prefixManager.save(metadata, at: prefixURL)
        let lifecycleMarker = root.appending(path: "post-wine-migration-validation-failure.log")
        let launcher = try makePostWineValidationFailureMigrationRuntime(
            in: root,
            marker: lifecycleMarker
        )

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected staged runtime validation to fail")
        } catch {
            // The concrete validation error is not the contract under test.
        }

        XCTAssertEqual(try String(contentsOf: canonicalMarker, encoding: .utf8), "canonical")
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(
            siblings.contains { $0.lastPathComponent.contains(".runtime-migration-staging-") },
            "A post-Wine migration failure may delete staging only after common cleanup verifies quiescence."
        )
        let lifecycle = try String(contentsOf: lifecycleMarker, encoding: .utf8)
        XCTAssertTrue(lifecycle.contains(".runtime-migration-staging-"), lifecycle)
        XCTAssertTrue(lifecycle.contains(":--kill=\(SIGTERM)"), lifecycle)
    }

    func testRebuildSteamSharedPrefixShutsDownAndReplacesExistingPrefixWithoutPersistentBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        var statefulMetadata = metadata
        statefulMetadata.installedRuntimes = [.vcrun2022]
        statefulMetadata.dllOverrides = ["dxgi=native"]
        statefulMetadata.launchOptions = ["-legacy"]
        try prefixManager.save(statefulMetadata, at: URL(fileURLWithPath: metadata.path))
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let liveMarker = prefixURL.appending(path: "live-prefix-marker.txt")
        try "snapshot me".write(to: liveMarker, atomically: true, encoding: .utf8)
        let marker = root.appending(path: "rebuild-lifecycle.log")
        let launcher = try makeRebuildLifecycleRuntime(in: root, marker: marker)

        let result = try await prefixManager.rebuildSteamSharedPrefix(
            runtimeExecutable: launcher,
            reason: "qa-reset"
        )
        let lifecycle = try String(contentsOf: marker, encoding: .utf8)
        let shutdownRange = try XCTUnwrap(
            lifecycle.range(
                of: "wineserver:\(prefixURL.path):--kill=\(SIGTERM)"
            )
        )
        let waitRange = try XCTUnwrap(lifecycle.range(of: "wineserver:", range: shutdownRange.upperBound..<lifecycle.endIndex))
        let stagingShutdownLine = lifecycle
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first {
                $0.contains(".rebuild-staging-") &&
                    $0.hasSuffix(":--kill=\(SIGTERM)")
            }

        XCTAssertEqual(result.processResult.succeeded, true)
        XCTAssertLessThan(shutdownRange.lowerBound, waitRange.lowerBound)
        XCTAssertNotNil(stagingShutdownLine, lifecycle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveMarker.path))
        XCTAssertNil(result.residualPreviousEnvironmentURL)
        XCTAssertTrue(result.metadata.snapshots.isEmpty)
        XCTAssertTrue(result.metadata.installedRuntimes.isEmpty)
        XCTAssertTrue(result.metadata.dllOverrides.isEmpty)
        XCTAssertTrue(result.metadata.launchOptions.isEmpty)
        XCTAssertGreaterThan(result.metadata.createdAt, metadata.createdAt)
        XCTAssertEqual(result.metadata.runner, WinePrefixDefaults.runner)
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testRebuildSteamSharedPrefixRestoresExistingEnvironmentWhenFinalMoveFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let fileManager = PrefixRestoreFailureFileManager()
        let swapper = PrefixSwapFailureInjector()
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            fileManager: fileManager,
            directorySwapper: swapper
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let liveMarker = prefixURL.appending(path: "authenticated-session-marker.txt")
        try "preserve on rollback".write(to: liveMarker, atomically: true, encoding: .utf8)
        let launcher = try makeRebuildLifecycleRuntime(
            in: root,
            marker: root.appending(path: "rebuild-rollback-lifecycle.log")
        )
        swapper.shouldFailNextSwap = true

        do {
            _ = try await prefixManager.rebuildSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected final staging move failure")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: liveMarker.path))
        XCTAssertEqual(
            try prefixManager.loadMetadata(at: prefixURL).createdAt.timeIntervalSince1970,
            metadata.createdAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".rebuild-rollback-") })
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".rebuild-staging-") })
    }

    func testRebuildSteamSharedPrefixRepairsCorruptMetadataWithoutSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try "not valid JSON".write(
            to: prefixURL.appending(path: "prefix.json"),
            atomically: true,
            encoding: .utf8
        )
        let oldMarker = prefixURL.appending(path: "corrupt-environment-marker.txt")
        try "replace me".write(to: oldMarker, atomically: true, encoding: .utf8)
        let launcher = try makeRebuildLifecycleRuntime(
            in: root,
            marker: root.appending(path: "corrupt-rebuild-lifecycle.log")
        )

        let result = try await prefixManager.rebuildSteamSharedPrefix(runtimeExecutable: launcher)

        XCTAssertTrue(result.processResult.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMarker.path))
        XCTAssertTrue(result.metadata.snapshots.isEmpty)
        XCTAssertEqual(result.metadata.runner, WinePrefixDefaults.runner)
        XCTAssertEqual(result.metadata.architecture, WinePrefixDefaults.architecture)
        XCTAssertEqual(result.metadata.windowsVersion, WinePrefixDefaults.windowsVersion)
        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testRebuildSteamSharedPrefixPreservesDisplacedEnvironmentWhenRollbackFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let swapper = PrefixRollbackFailureInjector()
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            directorySwapper: swapper
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let oldMarkerName = "authenticated-session-marker.txt"
        try "preserve me".write(
            to: prefixURL.appending(path: oldMarkerName),
            atomically: true,
            encoding: .utf8
        )
        let launcher = try makeRebuildLifecycleRuntime(
            in: root,
            marker: root.appending(path: "rollback-failure-lifecycle.log")
        )

        var preservedEnvironment: URL?
        do {
            _ = try await prefixManager.rebuildSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected rollback failure")
        } catch PrefixResetError.rollbackFailed(_, let displacedEnvironment, _, _) {
            preservedEnvironment = displacedEnvironment
            XCTAssertTrue(displacedEnvironment.lastPathComponent.hasPrefix(".SteamShared.recovery-"))
            XCTAssertNotEqual(
                displacedEnvironment.standardizedFileURL.path,
                swapper.displacedEnvironmentURL?.standardizedFileURL.path
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: displacedEnvironment.path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: displacedEnvironment.appending(path: oldMarkerName).path
                )
            )
        } catch {
            XCTFail("Expected PrefixResetError.rollbackFailed, got \(error)")
        }

        let recoveryURL = try XCTUnwrap(preservedEnvironment)
        let nextLaunchPrefixManager = PrefixManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner()
        )
        try nextLaunchPrefixManager.cleanupInterruptedReplacementArtifacts(at: prefixURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recoveryURL.appending(path: oldMarkerName).path)
        )
    }

    func testCleanupInterruptedReplacementArtifactsRemovesOnlyManagedStagingDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let parent = prefixURL.deletingLastPathComponent()
        let rebuildStaging = parent.appending(
            path: ".SteamShared.rebuild-staging-interrupted",
            directoryHint: .isDirectory
        )
        let resetStaging = parent.appending(
            path: ".SteamShared.reset-staging-interrupted",
            directoryHint: .isDirectory
        )
        let unrelated = parent.appending(path: ".unrelated-staging", directoryHint: .isDirectory)
        for directory in [rebuildStaging, resetStaging, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        try prefixManager.cleanupInterruptedReplacementArtifacts(at: prefixURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: rebuildStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resetStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCleanupInterruptedReplacementArtifactsAcceptsFreshEmptyPrefixPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        let interrupted = prefixURL.deletingLastPathComponent().appending(
            path: ".SteamShared.initialize-staging-interrupted",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)

        XCTAssertTrue(try prefixManager.isUninitializedPrefixPlaceholder(at: prefixURL))
        try prefixManager.cleanupInterruptedReplacementArtifacts(at: prefixURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(try prefixManager.isUninitializedPrefixPlaceholder(at: prefixURL))
    }

    func testPrepareSteamSharedPrefixRejectsUnsafeExistingUserRegistryBeforeInitializing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRegistry = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamUserRegistry-\(UUID().uuidString).reg")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRegistry)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let userRegistry = prefixURL.appending(path: "user.reg")
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "external original".write(to: externalRegistry, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: userRegistry, withDestinationURL: externalRegistry)
        let launcher = try makePrefixInitializerLauncher(in: root)

        do {
            _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            XCTFail("Expected unsafe user registry to reject Steam shared prefix initialization")
        } catch {
            guard case PrefixUsabilityError.unsafeRequiredItem(let url) = error else {
                return XCTFail("Expected unsafeRequiredItem, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, userRegistry.standardizedFileURL.path)
        }
        XCTAssertEqual(try String(contentsOf: externalRegistry, encoding: .utf8), "external original")
    }

    func testApplyWindowsVersionRejectsUnsafePrefixBeforeRunningExternalCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRegistry = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSystemRegistry-\(UUID().uuidString).reg")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRegistry)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let systemRegistry = prefixURL.appending(path: "system.reg")
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(to: externalRegistry, atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: systemRegistry, withDestinationURL: externalRegistry)
        let marker = root.appending(path: "windows-version-runner-called")
        let launcher = try makeMarkerLauncher(in: root, marker: marker)

        do {
            _ = try await prefixManager.applyWindowsVersion(
                WindowsCompatibilityVersion.windows10.rawValue,
                prefixURL: prefixURL,
                runtimeExecutable: launcher
            )
            XCTFail("Expected unsafe system registry to reject Windows version command")
        } catch PrefixUsabilityError.unsafeRequiredItem(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, systemRegistry.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testApplyDLLOverrideRejectsUnsafePrefixBeforeRunningExternalCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRegistry = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalUserRegistry-\(UUID().uuidString).reg")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRegistry)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let userRegistry = prefixURL.appending(path: "user.reg")
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(to: externalRegistry, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: externalRegistry, to: userRegistry)
        let marker = root.appending(path: "dll-override-runner-called")
        let launcher = try makeMarkerLauncher(in: root, marker: marker)

        do {
            _ = try await prefixManager.applyDLLOverride(
                "d3dcompiler_47",
                override: "native,builtin",
                prefixURL: prefixURL,
                runtimeExecutable: launcher
            )
            XCTFail("Expected unsafe user registry to reject DLL override command")
        } catch PrefixUsabilityError.unsafeRequiredItem(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, userRegistry.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSnapshotCreatesDistinctDestinationsForRepeatedReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)

        let first = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "same reason")
        let second = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "same reason")

        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSnapshotPersistsSnapshotPathInPrefixMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)

        let snapshot = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "metadata record")
        let updated = try prefixManager.loadMetadata(at: prefixURL)

        XCTAssertTrue(updated.snapshots.contains(snapshot.path))
    }

    func testSnapshotRejectsUnsafePrefixMetadataBeforeCopying() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalMetadata = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefixMetadata-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalMetadata)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        let snapshotsRoot = try pathManager.url(for: .prefixSnapshots)
        try "{}".write(to: externalMetadata, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createSymbolicLink(at: metadataURL, withDestinationURL: externalMetadata)

        do {
            _ = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "unsafe metadata")
            XCTFail("Expected unsafe prefix metadata to reject snapshot creation")
        } catch PrefixMetadataError.unsafeMetadataFile(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, metadataURL.standardizedFileURL.path)
            let snapshots = try FileManager.default.contentsOfDirectory(
                at: snapshotsRoot,
                includingPropertiesForKeys: nil
            )
            XCTAssertTrue(snapshots.isEmpty)
        }
    }

    func testDeleteRejectsSymlinkPrefixDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalPrefix = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalPrefix)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let prefixURL = try pathManager.url(for: .prefixes)
            .appending(path: "LinkedPrefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalPrefix, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: prefixURL, withDestinationURL: externalPrefix)

        do {
            try prefixManager.delete(prefixURL: prefixURL)
            XCTFail("Expected symlink prefix directory to be rejected")
        } catch PrefixMetadataError.unsafePrefixDirectory(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, prefixURL.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalPrefix.path))
    }

    func testRestoreRejectsSymlinkDestinationPrefixDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalPrefix = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalPrefix)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let snapshotMetadata = try prefixManager.createSteamSharedPrefix()
        let snapshotURL = URL(fileURLWithPath: snapshotMetadata.path)
        let prefixURL = try pathManager.url(for: .prefixes)
            .appending(path: "LinkedRestorePrefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalPrefix, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: prefixURL, withDestinationURL: externalPrefix)

        do {
            try prefixManager.restore(snapshotURL: snapshotURL, to: prefixURL)
            XCTFail("Expected symlink prefix directory to be rejected")
        } catch PrefixMetadataError.unsafePrefixDirectory(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, prefixURL.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalPrefix.path))
    }

    func testRestorePreservesExistingPrefixWhenSnapshotCopyFails() async throws {
        let fileManager = PrefixRestoreFailureFileManager()
        let root = fileManager.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner(), fileManager: fileManager)
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let liveMarker = prefixURL.appending(path: "live-marker.txt")
        try Data("existing prefix".utf8).write(to: liveMarker)
        let snapshot = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "before restore")
        fileManager.failingCopySourcePath = snapshot.standardizedFileURL.path

        do {
            try prefixManager.restore(snapshotURL: snapshot, to: prefixURL)
            XCTFail("Expected snapshot copy failure")
        } catch {
            XCTAssertTrue(fileManager.fileExists(atPath: prefixURL.path))
            XCTAssertEqual(try String(contentsOf: liveMarker, encoding: .utf8), "existing prefix")
        }
    }

    func testRestorePreservesExistingPrefixWhenReplacementMoveFails() async throws {
        let fileManager = PrefixRestoreFailureFileManager()
        let root = fileManager.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner(), fileManager: fileManager)
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let liveMarker = prefixURL.appending(path: "live-marker.txt")
        try Data("existing prefix".utf8).write(to: liveMarker)
        let snapshot = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "before restore")

        fileManager.shouldFailStagingMoveToDestination = true
        do {
            try prefixManager.restore(snapshotURL: snapshot, to: prefixURL)
            XCTFail("Expected replacement move failure")
        } catch {
            XCTAssertTrue(fileManager.fileExists(atPath: prefixURL.path))
            XCTAssertEqual(try String(contentsOf: liveMarker, encoding: .utf8), "existing prefix")
        }
    }

    private func makePrefixMetadata() -> PrefixMetadata {
        PrefixMetadata(
            schemaVersion: 1,
            id: "prefix-test",
            displayName: "Test Prefix",
            path: "/tmp/ForgePlay/Prefixes/Test",
            mode: .steamShared,
            runner: WinePrefixDefaults.runner,
            architecture: WinePrefixDefaults.architecture,
            windowsVersion: WinePrefixDefaults.windowsVersion,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            installedRuntimes: [.vcrun2022, .openal],
            dllOverrides: ["d3dcompiler_47=native,builtin"],
            environmentVariables: [:],
            launchOptions: ["-windowed"],
            snapshots: ["/tmp/snapshot-a"]
        )
    }

    private func makeRuntimeManifest(seed: Character) -> RuntimeManifest {
        let digest = String(repeating: String(seed), count: 64)
        return RuntimeManifest(
            schemaVersion: RuntimeManifest.currentSchemaVersion,
            runtimeIdentifier: "runtime-\(seed)",
            wineVersion: "11.12",
            architecture: WinePrefixDefaults.architecture,
            sourceTreeSHA256: digest,
            patchSetSHA256: digest,
            runnerLauncherSHA256: digest,
            wineInfSHA256: digest,
            winebootSHA256: digest,
            prefixCompatibilityFingerprint: digest,
            runnerBuildFingerprint: digest
        )
    }

    private func assertPostWineFontFailureCleansStaging(
        flow: PostWineInitializationFailureFlow
    ) async throws {
        let fileManager = PrefixStagingFontCopyFailureFileManager()
        let root = fileManager.temporaryDirectory
            .appending(path: "ForgePlayPrefixManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            fileManager: fileManager
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let canonicalMarker = prefixURL.appending(path: "canonical-prefix-marker.txt")
        try Data("canonical".utf8).write(to: canonicalMarker)
        if flow == .reset {
            try createUsablePrefixContents(at: prefixURL, architecture: "win32")
        }
        let lifecycleMarker = root.appending(path: "\(flow.rawValue)-post-wine-failure.log")
        let launcher = try makePrefixInitializerLauncherWithFonts(
            in: root,
            lifecycleMarker: lifecycleMarker
        )

        do {
            switch flow {
            case .initialize, .reset:
                _ = try await prefixManager.prepareSteamSharedPrefix(runtimeExecutable: launcher)
            case .rebuild:
                _ = try await prefixManager.rebuildSteamSharedPrefix(runtimeExecutable: launcher)
            }
            XCTFail("Expected \(flow.rawValue) font seeding to fail")
        } catch {
            // The injected post-Wine file error is expected.
        }

        let failedDestination = try XCTUnwrap(fileManager.failedDestination)
        XCTAssertTrue(failedDestination.path.contains(flow.stagingNameFragment))
        XCTAssertEqual(try String(contentsOf: canonicalMarker, encoding: .utf8), "canonical")
        let siblings = try fileManager.contentsOfDirectory(
            at: prefixURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(
            siblings.contains { $0.lastPathComponent.contains(flow.stagingNameFragment) }
        )
        let lifecycle = try String(contentsOf: lifecycleMarker, encoding: .utf8)
        XCTAssertTrue(
            lifecycle.split(whereSeparator: \.isNewline).contains {
                $0.contains(flow.stagingNameFragment) &&
                    $0.hasSuffix(":--kill=\(SIGTERM)")
            },
            "Post-Wine failure must run verified staging cleanup before deletion: \(lifecycle)"
        )
    }

    private func createUsablePrefixContents(
        at prefixURL: URL,
        architecture: String
    ) throws {
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=\(architecture)\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makePrefixInitializerLauncher(
        in root: URL,
        launchMarkerObservation: URL? = nil
    ) throws -> URL {
        let wineRoot = root.appending(path: "Runtime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let markerObservationScript = launchMarkerObservation.map { observation in
            """
            if [ -f "$WINEPREFIX/.forgeplay-preserve-recovery" ]; then
              printf 'present\\n' > "\(observation.path)"
            else
              printf 'missing\\n' > "\(observation.path)"
              exit 91
            fi
            """
        } ?? ""
        try """
        #!/bin/sh
        \(markerObservationScript)
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "$WINEARCH" > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        printf 'initialized:%s\\n' "$WINEARCH"
        printf 'sync:%s:%s\\n' "$WINEMSYNC" "$WINEESYNC"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makeFailingPrefixInitializerLauncher(
        in root: URL,
        cleanupMarker: URL
    ) throws -> URL {
        let wineRoot = root.appending(path: "FailingRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "$WINEARCH" > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        printf 'mutated\\n' > "$WINEPREFIX/failed-runtime-mutation.txt"
        exit 42
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s:%s\n' "$WINEPREFIX" "$*" >> "\(cleanupMarker.path)"
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makeFailingPrefixInitializerWithUnconfirmedCleanupRuntime(
        in root: URL,
        marker: URL
    ) throws -> URL {
        let wineRoot = root.appending(path: "UnconfirmedCleanupRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "$WINEARCH" > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        printf 'mutated\\n' > "$WINEPREFIX/failed-runtime-mutation.txt"
        exit 42
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        case "$WINEPREFIX:${1:-}" in
          *.SteamShared.initialize-staging-*:-w)
            exit 9
            ;;
        esac
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makeCanonicalSecondShutdownFailureRuntime(
        in root: URL,
        marker: URL
    ) throws -> URL {
        let wineRoot = root.appending(path: "CanonicalCleanupFailureRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        let canonicalBarrierCount = root.appending(path: "canonical-barrier-count.txt")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "$WINEARCH" > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        case "$WINEPREFIX:${1:-}" in
          */SteamShared:-w)
            count=0
            if [ -f "\(canonicalBarrierCount.path)" ]; then
              count=$(cat "\(canonicalBarrierCount.path)")
            fi
            count=$((count + 1))
            printf '%s\\n' "$count" > "\(canonicalBarrierCount.path)"
            if [ "$count" -ge 2 ]; then
              exit 9
            fi
            ;;
        esac
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makePostWineValidationFailureMigrationRuntime(
        in root: URL,
        marker: URL
    ) throws -> URL {
        let wineRoot = root.appending(path: "PostWineMigrationValidationFailureRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        printf 'wine:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        case "$WINEPREFIX:${1:-}" in
          *.SteamShared.runtime-migration-staging-*:-w)
            rm -f "$WINEPREFIX/system.reg"
            ;;
        esac
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makeRegistryFlushRuntime(in root: URL, marker: URL) throws -> URL {
        let wineRoot = root.appending(path: "FlushRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'wineboot:%s\\n' "$*" >> "\(marker.path)"
        printf 'initialized:%s\\n' "$WINEARCH"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=win64\\n' > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makeFailingRegistryFlushRuntime(in root: URL, marker: URL) throws -> URL {
        let wineRoot = root.appending(path: "FailingFlushRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'wineserver:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        failure_marker="\(marker.path).failed-once"
        case "$WINEPREFIX:$1" in
          *.SteamShared.initialize-staging-*:-w)
            if [ ! -e "$failure_marker" ]; then
              : > "$failure_marker"
              exit 37
            fi
            ;;
        esac
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makeRebuildLifecycleRuntime(in root: URL, marker: URL) throws -> URL {
        let wineRoot = root.appending(path: "RebuildRuntime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        printf 'wine:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "$WINEARCH" > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        printf 'initialized:%s\\n' "$WINEARCH"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
        exit 0
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func makePrefixInitializerLauncherWithFonts(
        in root: URL,
        lifecycleMarker: URL? = nil
    ) throws -> URL {
        let wineRoot = root.appending(path: "Runtime/wine", directoryHint: .isDirectory)
        let launcher = wineRoot.appending(path: "bin/wine")
        let wineserver = wineRoot.appending(path: "bin/wineserver")
        let fontDirectory = wineRoot.appending(path: "share/wine/fonts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fontDirectory,
            withIntermediateDirectories: true
        )
        try "font".write(
            to: fontDirectory.appending(path: "tahoma.ttf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        #!/bin/sh
        mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices/c:"
        printf 'WINE REGISTRY Version 2\\n#arch=%s\\n' "$WINEARCH" > "$WINEPREFIX/system.reg"
        printf 'WINE REGISTRY Version 2\\n' > "$WINEPREFIX/user.reg"
        printf 'initialized:%s\\n' "$WINEARCH"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        let wineserverScript = lifecycleMarker.map { marker in
            """
            #!/bin/sh
            printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """
        } ?? "#!/bin/sh\nexit 0\n"
        try wineserverScript.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        try writeRuntimeIdentityPayloads(for: launcher)
        return launcher
    }

    private func writeRuntimeIdentityPayloads(for launcher: URL) throws {
        let wineRoot = launcher.deletingLastPathComponent().deletingLastPathComponent()
        try installAuthenticatedRuntimePayloadFixture(
            at: wineRoot.deletingLastPathComponent(),
            executable: launcher
        )
    }

    /// Prefix lifecycle tests use synthetic executables after the runtime service
    /// boundary has already accepted the app-bundled Runtime identity.
    private func makeCuratedRuntimeRunner() -> SafeProcessRunner {
        SafeProcessRunner(
            managedWineProcessJournalEnabled: false,
            managedWineRuntimeFingerprintResolver: {
                _ in String(repeating: "a", count: 64)
            },
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { _, _ in }
        )
    }

    private func makeMarkerLauncher(in root: URL, marker: URL) throws -> URL {
        let launcher = root.appending(path: "marker-wine-\(UUID().uuidString)")
        try """
        #!/bin/sh
        touch "\(marker.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher
    }

    private func decodeArray<T: Decodable>(_ json: String) throws -> [T] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode([T].self, from: data)
    }
}
