import CryptoKit
import XCTest
@testable import ForgePlay

private final class RuntimeManagerCopyObservingFileManager: FileManager {
    private let observationLock = NSLock()
    private var copyMainThreadObservations: [Bool] = []
    private var removalMainThreadObservations: [Bool] = []

    var copyCount: Int {
        observationLock.withLock { copyMainThreadObservations.count }
    }

    var observedMainThreadCopy: Bool {
        observationLock.withLock { copyMainThreadObservations.contains(true) }
    }

    var removalCount: Int {
        observationLock.withLock { removalMainThreadObservations.count }
    }

    var observedMainThreadRemoval: Bool {
        observationLock.withLock { removalMainThreadObservations.contains(true) }
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        observationLock.withLock {
            copyMainThreadObservations.append(Thread.isMainThread)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        observationLock.withLock {
            removalMainThreadObservations.append(Thread.isMainThread)
        }
        try super.removeItem(at: URL)
    }
}

@MainActor
final class RuntimeManagerTests: XCTestCase {
    func testInstallerValidationRequiresExistingAllowedMatchingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let validInstaller = root.appending(path: "xnafx40_redist.msi")
        let wrongRuntimeInstaller = root.appending(path: "vc_redist.x64.exe")
        let wrongExtensionInstaller = root.appending(path: "xnafx40_redist.txt")
        let linkedInstaller = root.appending(path: "xnafx40_redist_link.msi")
        let hardlinkSourceInstaller = root.appending(path: "hardlink-source-installer.msi")
        let hardlinkFolder = root.appending(path: "HardlinkInstaller", directoryHint: .isDirectory)
        let hardlinkedInstaller = hardlinkFolder.appending(path: "xnafx40_redist.msi")
        try FileManager.default.createDirectory(at: hardlinkFolder, withIntermediateDirectories: true)
        try Data().write(to: validInstaller)
        try Data().write(to: hardlinkSourceInstaller)
        try Data().write(to: wrongRuntimeInstaller)
        try Data().write(to: wrongExtensionInstaller)
        try FileManager.default.createSymbolicLink(at: linkedInstaller, withDestinationURL: validInstaller)
        try FileManager.default.linkItem(at: hardlinkSourceInstaller, to: hardlinkedInstaller)

        XCTAssertTrue(runtimeManager.isInstaller(validInstaller, plausibleFor: .xna40))
        XCTAssertFalse(runtimeManager.isInstaller(linkedInstaller, plausibleFor: .xna40))
        XCTAssertFalse(runtimeManager.isInstaller(hardlinkedInstaller, plausibleFor: .xna40))
        XCTAssertFalse(runtimeManager.isInstaller(wrongRuntimeInstaller, plausibleFor: .xna40))
        XCTAssertFalse(runtimeManager.isInstaller(wrongExtensionInstaller, plausibleFor: .xna40))
        XCTAssertFalse(runtimeManager.isInstaller(root.appending(path: "missing_xnafx40_redist.msi"), plausibleFor: .xna40))
    }

    func testRuntimeDefinitionsIncludeConcreteUserRemediation() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let appState = AppState()
        appState.languageMode = .english

        for definition in runtimeManager.definitions {
            let remediationSteps = definition.localizedRemediationSteps(appState: appState)
            let officialURL = try XCTUnwrap(definition.officialURL, "\(definition.id.rawValue) needs an official vendor URL")
            XCTAssertEqual(officialURL.scheme, "https", "\(definition.id.rawValue) official URL must use HTTPS")
            XCTAssertNotNil(officialURL.host, "\(definition.id.rawValue) official URL needs a host")
            XCTAssertNil(officialURL.user, "\(definition.id.rawValue) official URL must not include user info")
            XCTAssertNil(officialURL.password, "\(definition.id.rawValue) official URL must not include credentials")
            XCTAssertNil(officialURL.fragment, "\(definition.id.rawValue) official URL must not include fragments")
            XCTAssertFalse(definition.officialSourceName.isEmpty, "\(definition.id.rawValue) needs an official source name")
            XCTAssertFalse(definition.downloadFileHints.isEmpty, "\(definition.id.rawValue) needs download file hints")
            XCTAssertFalse(definition.installerHints.isEmpty, "\(definition.id.rawValue) needs selectable installer hints")
            XCTAssertTrue(
                remediationSteps.contains { $0.contains("Prefix") },
                "\(definition.id.rawValue) should explain the target Prefix"
            )
            XCTAssertTrue(
                remediationSteps.contains { $0.contains("RuntimeCache/Installers") },
                "\(definition.id.rawValue) should explain where ForgePlay caches selected installers"
            )
        }
    }

    func testDirectXRedistArchiveIsExtractableButNotFinalInstaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let appState = AppState()
        appState.languageMode = .english
        let redistArchive = root.appending(path: "directx_Jun2010_redist.exe")
        let linkedRedistArchive = root.appending(path: "directx_Jun2010_redist_link.exe")
        let hardlinkSourceArchive = root.appending(path: "hardlink-source-archive.exe")
        let hardlinkFolder = root.appending(path: "HardlinkArchive", directoryHint: .isDirectory)
        let hardlinkedRedistArchive = hardlinkFolder.appending(path: "directx_Jun2010_redist.exe")
        let extractedSetup = root.appending(path: "DXSETUP.exe")
        try FileManager.default.createDirectory(at: hardlinkFolder, withIntermediateDirectories: true)
        try Data().write(to: redistArchive)
        try Data().write(to: hardlinkSourceArchive)
        try FileManager.default.createSymbolicLink(at: linkedRedistArchive, withDestinationURL: redistArchive)
        try FileManager.default.linkItem(at: hardlinkSourceArchive, to: hardlinkedRedistArchive)
        try Data().write(to: extractedSetup)

        let definition = runtimeManager.definition(for: .d3dx9)
        XCTAssertTrue(definition.downloadFileHints.contains("directx_Jun2010_redist.exe"))
        XCTAssertTrue(definition.preparationNotes.contains { $0.contains("DXSETUP.exe") })
        XCTAssertTrue(definition.extractableArchiveHints.contains("directx_Jun2010_redist.exe"))
        XCTAssertTrue(definition.localizedRemediationSteps(appState: appState).contains { $0.contains("RuntimeCache/ExtractedInstallers") })
        XCTAssertFalse(runtimeManager.isInstaller(redistArchive, plausibleFor: .d3dx9))
        XCTAssertTrue(runtimeManager.isExtractionArchive(redistArchive, plausibleFor: .d3dx9))
        XCTAssertFalse(runtimeManager.isExtractionArchive(linkedRedistArchive, plausibleFor: .d3dx9))
        XCTAssertFalse(runtimeManager.isExtractionArchive(hardlinkedRedistArchive, plausibleFor: .d3dx9))
        XCTAssertTrue(runtimeManager.isInstaller(extractedSetup, plausibleFor: .d3dx9))
    }

    func testRuntimeInstallerCacheUsesSanitizedFileName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let observingFileManager = RuntimeManagerCopyObservingFileManager()
        let runtimeManager = try makeFixtureRuntimeManager(
            pathManager: pathManager,
            fileManager: observingFileManager
        )
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let installer = root.appending(path: "xnafx40%redist.msi")
        let installerPayload = Data()
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try installerPayload.write(to: installer)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await runtimeManager.install(
            runtime: .xna40,
            installer: installer,
            runtimeExecutable: launcher,
            prefixURL: prefix
        )

        let cachedInstaller = try runtimeCacheTarget(
            for: installer,
            payload: installerPayload,
            pathManager: pathManager
        )
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedInstaller.path))
        XCTAssertTrue(cachedInstaller.lastPathComponent.hasPrefix("xnafx40_redist-"))
        XCTAssertTrue(output.contains(cachedInstaller.path), output)
        XCTAssertFalse(output.contains(installer.path), output)
        XCTAssertTrue(FileSystemItemPolicy.isRegularNonSymlinkFile(cachedInstaller))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try pathManager.url(for: .runtimeInstallers).appending(path: "xnafx40%redist.msi").path))
        XCTAssertGreaterThan(observingFileManager.copyCount, 0)
        XCTAssertFalse(observingFileManager.observedMainThreadCopy)
    }

    func testRuntimeInstallerCacheSeparatesSameBasenameWithDifferentContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let firstDirectory = root.appending(path: "First", directoryHint: .isDirectory)
        let secondDirectory = root.appending(path: "Second", directoryHint: .isDirectory)
        let firstInstaller = firstDirectory.appending(path: "xnafx40_redist.msi")
        let secondInstaller = secondDirectory.appending(path: "xnafx40_redist.msi")
        let firstPayload = Data("first vendor payload".utf8)
        let secondPayload = Data("updated vendor payload".utf8)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try firstPayload.write(to: firstInstaller)
        try secondPayload.write(to: secondInstaller)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let firstResult = try await runtimeManager.install(
            runtime: .xna40,
            installer: firstInstaller,
            runtimeExecutable: launcher,
            prefixURL: prefix
        )
        let secondResult = try await runtimeManager.install(
            runtime: .xna40,
            installer: secondInstaller,
            runtimeExecutable: launcher,
            prefixURL: prefix
        )

        let firstCachedInstaller = try runtimeCacheTarget(
            for: firstInstaller,
            payload: firstPayload,
            pathManager: pathManager
        )
        let secondCachedInstaller = try runtimeCacheTarget(
            for: secondInstaller,
            payload: secondPayload,
            pathManager: pathManager
        )
        XCTAssertNotEqual(firstCachedInstaller, secondCachedInstaller)
        XCTAssertEqual(try Data(contentsOf: firstCachedInstaller), firstPayload)
        XCTAssertEqual(try Data(contentsOf: secondCachedInstaller), secondPayload)
        XCTAssertTrue(
            try String(contentsOf: firstResult.stdoutLog, encoding: .utf8)
                .contains(firstCachedInstaller.path)
        )
        XCTAssertTrue(
            try String(contentsOf: secondResult.stdoutLog, encoding: .utf8)
                .contains(secondCachedInstaller.path)
        )
    }

    func testRuntimeInstallerCacheRejectsFingerprintMismatchAtContentAddress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let installer = root.appending(path: "xnafx40_redist.msi")
        let selectedPayload = Data("selected vendor payload".utf8)
        try selectedPayload.write(to: installer)
        let cachedInstaller = try runtimeCacheTarget(
            for: installer,
            payload: selectedPayload,
            pathManager: pathManager
        )
        try Data("different cached payload".utf8).write(to: cachedInstaller)

        do {
            _ = try await runtimeManager.install(
                runtime: .xna40,
                installer: installer,
                runtimeExecutable: root.appending(path: "wine64"),
                prefixURL: root.appending(path: "Prefix", directoryHint: .isDirectory)
            )
            XCTFail("Expected mismatched content-addressed cache entry to be rejected")
        } catch RuntimeManagerError.unsafeCachedInstaller(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, cachedInstaller.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeInstallerCacheRejectsExistingSymlinkTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let installer = root.appending(path: "xnafx40_redist.msi")
        let externalCacheTarget = root.appending(path: "ExternalCachedInstaller.msi")
        let installerPayload = Data("selected".utf8)
        try installerPayload.write(to: installer)
        try Data("external".utf8).write(to: externalCacheTarget)
        let cachedInstaller = try runtimeCacheTarget(
            for: installer,
            payload: installerPayload,
            pathManager: pathManager
        )
        try FileManager.default.createSymbolicLink(at: cachedInstaller, withDestinationURL: externalCacheTarget)

        do {
            _ = try await runtimeManager.install(
                runtime: .xna40,
                installer: installer,
                runtimeExecutable: root.appending(path: "wine64"),
                prefixURL: root.appending(path: "Prefix", directoryHint: .isDirectory)
            )
            XCTFail("Expected runtime cache symlink target to be rejected")
        } catch RuntimeManagerError.unsafeCachedInstaller(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, cachedInstaller.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeInstallerCacheRejectsExistingHardlinkTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let installer = root.appending(path: "xnafx40_redist.msi")
        let externalCacheTarget = root.appending(path: "ExternalCachedInstaller.msi")
        let installerPayload = Data("selected".utf8)
        try installerPayload.write(to: installer)
        try Data("external".utf8).write(to: externalCacheTarget)
        let cachedInstaller = try runtimeCacheTarget(
            for: installer,
            payload: installerPayload,
            pathManager: pathManager
        )
        try FileManager.default.linkItem(at: externalCacheTarget, to: cachedInstaller)

        do {
            _ = try await runtimeManager.install(
                runtime: .xna40,
                installer: installer,
                runtimeExecutable: root.appending(path: "wine64"),
                prefixURL: root.appending(path: "Prefix", directoryHint: .isDirectory)
            )
            XCTFail("Expected runtime cache hardlink target to be rejected")
        } catch RuntimeManagerError.unsafeCachedInstaller(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, cachedInstaller.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeInstallerCacheRejectsBrokenSymlinkTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let installer = root.appending(path: "xnafx40_redist.msi")
        let missingCacheTarget = root.appending(path: "MissingExternalCachedInstaller.msi")
        let installerPayload = Data("selected".utf8)
        try installerPayload.write(to: installer)
        let cachedInstaller = try runtimeCacheTarget(
            for: installer,
            payload: installerPayload,
            pathManager: pathManager
        )
        try FileManager.default.createSymbolicLink(at: cachedInstaller, withDestinationURL: missingCacheTarget)

        do {
            _ = try await runtimeManager.install(
                runtime: .xna40,
                installer: installer,
                runtimeExecutable: root.appending(path: "wine64"),
                prefixURL: root.appending(path: "Prefix", directoryHint: .isDirectory)
            )
            XCTFail("Expected runtime cache broken symlink target to be rejected")
        } catch RuntimeManagerError.unsafeCachedInstaller(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, cachedInstaller.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstallRejectsUnsafeInstallerAtServiceBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let realInstaller = root.appending(path: "real-xnafx40_redist.msi")
        let linkedInstaller = root.appending(path: "xnafx40_redist.msi")
        let hardlinkFolder = root.appending(path: "HardlinkInstaller", directoryHint: .isDirectory)
        let hardlinkedInstaller = hardlinkFolder.appending(path: "xnafx40_redist.msi")
        try FileManager.default.createDirectory(at: hardlinkFolder, withIntermediateDirectories: true)
        try Data().write(to: realInstaller)
        try FileManager.default.createSymbolicLink(at: linkedInstaller, withDestinationURL: realInstaller)
        try FileManager.default.linkItem(at: realInstaller, to: hardlinkedInstaller)

        for installer in [linkedInstaller, hardlinkedInstaller] {
            do {
                _ = try await runtimeManager.install(
                    runtime: .xna40,
                    installer: installer,
                    runtimeExecutable: root.appending(path: "wine64"),
                    prefixURL: root.appending(path: "Prefix", directoryHint: .isDirectory)
                )
                XCTFail("Expected service boundary to reject an unsafe installer")
            } catch RuntimeManagerError.unsupportedInstaller(let url, let runtime) {
                XCTAssertEqual(url, installer)
                XCTAssertEqual(runtime, .xna40)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExtractDirectXRedistArchiveFindsDXSetup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let archive = root.appending(path: "directx_Jun2010_redist.exe")
        let archivePayload = Data()
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try archivePayload.write(to: archive)
        try """
        #!/bin/sh
        for dir in "$(dirname "$0")"/RuntimeCache/ExtractedInstallers/*; do
          if [ -d "$dir" ]; then
            touch "$dir/DXSETUP.exe"
          fi
        done
        printf '%s\\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let extraction = try await runtimeManager.withExtractedInstaller(
            runtime: .d3dx9,
            archive: archive,
            runtimeExecutable: launcher,
            prefixURL: prefix
        ) { extraction in
            XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.installer.path))
            return extraction
        }
        let output = try String(contentsOf: extraction.processResult.stdoutLog, encoding: .utf8)
        let cachedArchive = try runtimeCacheTarget(
            for: archive,
            payload: archivePayload,
            pathManager: pathManager
        )

        XCTAssertTrue(extraction.processResult.succeeded)
        XCTAssertEqual(extraction.sourceArchive, archive)
        XCTAssertEqual(extraction.installer.lastPathComponent, "DXSETUP.exe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.installer.path))
        XCTAssertTrue(extraction.extractionDirectory.path.contains("RuntimeCache/ExtractedInstallers"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedArchive.path))
        XCTAssertTrue(FileSystemItemPolicy.isRegularNonSymlinkFile(cachedArchive))
        XCTAssertTrue(output.contains("\(cachedArchive.path)\n/Q\n/T:Z:\\"), output)
        XCTAssertFalse(output.contains("\(archive.path)\n/Q"), output)
    }

    func testWithExtractedInstallerCleansAfterSuccessAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let observingFileManager = RuntimeManagerCopyObservingFileManager()
        let runtimeManager = try makeFixtureRuntimeManager(
            pathManager: pathManager,
            fileManager: observingFileManager
        )
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let archive = root.appending(path: "directx_Jun2010_redist.exe")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: archive)
        try """
        #!/bin/sh
        for dir in "$(dirname "$0")"/RuntimeCache/ExtractedInstallers/*; do
          if [ -d "$dir" ]; then
            touch "$dir/DXSETUP.exe"
          fi
        done
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let successfulDirectory = try await runtimeManager.withExtractedInstaller(
            runtime: .d3dx9,
            archive: archive,
            runtimeExecutable: launcher,
            prefixURL: prefix
        ) { extraction in
            XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.installer.path))
            return extraction.extractionDirectory
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: successfulDirectory.path))

        do {
            let _: Void = try await runtimeManager.withExtractedInstaller(
                runtime: .d3dx9,
                archive: archive,
                runtimeExecutable: launcher,
                prefixURL: prefix
            ) { extraction in
                XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.installer.path))
                throw CancellationError()
            }
            XCTFail("Expected cancellation from extracted installer use")
        } catch is CancellationError {
            // The temporary tree must still be removed below.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let extractedRoot = try pathManager.url(for: .runtimeExtractedInstallers)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: extractedRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertGreaterThanOrEqual(observingFileManager.removalCount, 2)
        XCTAssertFalse(observingFileManager.observedMainThreadRemoval)
    }

    func testExtractedInstallerSymlinkIsNotAccepted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let archive = root.appending(path: "directx_Jun2010_redist.exe")
        let externalSetup = root.appending(path: "ExternalDXSETUP.exe")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: archive)
        try Data().write(to: externalSetup)
        try """
        #!/bin/sh
        for dir in "$(dirname "$0")"/RuntimeCache/ExtractedInstallers/*; do
          if [ -d "$dir" ]; then
            ln -s "\(externalSetup.path)" "$dir/DXSETUP.exe"
          fi
        done
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        do {
            _ = try await runtimeManager.withExtractedInstaller(
                runtime: .d3dx9,
                archive: archive,
                runtimeExecutable: launcher,
                prefixURL: prefix
            ) { _ in
                XCTFail("Expected extracted symlink to be rejected before use")
            }
            XCTFail("Expected symlinked extracted installer to be rejected")
        } catch RuntimeManagerError.extractedInstallerMissing {
            let extractedRoot = try pathManager.url(for: .runtimeExtractedInstallers)
            let contents = try FileManager.default.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil)
            XCTAssertTrue(contents.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExtractionSurfacesUnreadableExtractionDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let archive = root.appending(path: "directx_Jun2010_redist.exe")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: archive)
        try """
        #!/bin/sh
        for dir in "$(dirname "$0")"/RuntimeCache/ExtractedInstallers/*; do
          if [ -d "$dir" ]; then
            chmod 000 "$dir"
          fi
        done
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        do {
            _ = try await runtimeManager.withExtractedInstaller(
                runtime: .d3dx9,
                archive: archive,
                runtimeExecutable: launcher,
                prefixURL: prefix
            ) { _ in
                XCTFail("Expected unreadable extraction directory before use")
            }
            XCTFail("Expected unreadable extraction directory to be surfaced")
        } catch RuntimeManagerError.extractedInstallerScanFailed(let directory, _) {
            XCTAssertTrue(directory.path.contains("RuntimeCache/ExtractedInstallers"))
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExtractionCleanupFailurePreservesOriginalError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appending(path: "RuntimeCache/ExtractedInstallers").path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let archive = root.appending(path: "directx_Jun2010_redist.exe")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: archive)
        try """
        #!/bin/sh
        extracted_root="$(dirname "$0")/RuntimeCache/ExtractedInstallers"
        chmod 500 "$extracted_root"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        do {
            _ = try await runtimeManager.withExtractedInstaller(
                runtime: .d3dx9,
                archive: archive,
                runtimeExecutable: launcher,
                prefixURL: prefix
            ) { _ in
                XCTFail("Expected missing extracted installer before use")
            }
            XCTFail("Expected extraction cleanup failure to preserve the original missing-installer error")
        } catch RuntimeManagerError.extractionCleanupFailed(let directory, let originalError, let cleanupError) {
            XCTAssertTrue(directory.path.contains("RuntimeCache/ExtractedInstallers"))
            XCTAssertTrue(originalError is RuntimeManagerError)
            if case RuntimeManagerError.extractedInstallerMissing(let missingDirectory) = originalError {
                XCTAssertEqual(missingDirectory.standardizedFileURL.path, directory.standardizedFileURL.path)
            } else {
                XCTFail("Expected original error to be extractedInstallerMissing, got \(originalError)")
            }
            XCTAssertFalse(forgePlayTechnicalErrorSummary(cleanupError).isEmpty)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appending(path: "RuntimeCache/ExtractedInstallers").path
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExtractionSurfacesUnreadableNestedExtractionDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appending(path: "RuntimeCache/ExtractedInstallers").path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeManager = try makeFixtureRuntimeManager(pathManager: pathManager)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let archive = root.appending(path: "directx_Jun2010_redist.exe")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: archive)
        try """
        #!/bin/sh
        for dir in "$(dirname "$0")"/RuntimeCache/ExtractedInstallers/*; do
          if [ -d "$dir" ]; then
            mkdir -p "$dir/Locked"
            printf 'locked' > "$dir/Locked/payload.txt"
            chmod 000 "$dir/Locked"
          fi
        done
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        do {
            _ = try await runtimeManager.withExtractedInstaller(
                runtime: .d3dx9,
                archive: archive,
                runtimeExecutable: launcher,
                prefixURL: prefix
            ) { _ in
                XCTFail("Expected unreadable nested extraction directory before use")
            }
            XCTFail("Expected unreadable nested extraction directory to be surfaced")
        } catch RuntimeManagerError.extractedInstallerScanFailed(let directory, _) {
            XCTAssertTrue(directory.path.contains("RuntimeCache/ExtractedInstallers"))
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.appending(path: "Locked").path
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQuiescentPrefixMutationShutsDownBeforeAndAfterSuccess() async throws {
        let fixture = try makeQuiescentMutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let value = try await fixture.runtimeManager.withQuiescentPrefixMutation(
            runtimeExecutable: fixture.launcher,
            prefixURL: fixture.prefix,
            operationDescription: "test mutation"
        ) {
            42
        }

        XCTAssertEqual(value, 42)
        let invocations = try shutdownInvocationLines(at: fixture.marker)
        XCTAssertEqual(invocations.filter { $0.contains("-k") }.count, 2)
        XCTAssertEqual(invocations.filter { $0.contains("-w") }.count, 2)
    }

    func testQuiescentPrefixMutationShutsDownAfterThrownFailure() async throws {
        struct ExpectedMutationError: Error {}

        let fixture = try makeQuiescentMutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            let _: Int = try await fixture.runtimeManager.withQuiescentPrefixMutation(
                runtimeExecutable: fixture.launcher,
                prefixURL: fixture.prefix,
                operationDescription: "failing test mutation"
            ) {
                throw ExpectedMutationError()
            }
            XCTFail("Expected mutation failure")
        } catch is ExpectedMutationError {
            // Expected. The post-failure shutdown must still complete.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let invocations = try shutdownInvocationLines(at: fixture.marker)
        XCTAssertEqual(invocations.filter { $0.contains("-k") }.count, 2)
        XCTAssertEqual(invocations.filter { $0.contains("-w") }.count, 2)
    }

    private func makeQuiescentMutationFixture() throws -> (
        root: URL,
        prefix: URL,
        launcher: URL,
        marker: URL,
        runtimeManager: RuntimeManager
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayQuiescentMutation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine64")
        let marker = root.appending(path: "shutdown-invocations.log")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(marker.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return (
            root,
            prefix,
            launcher,
            marker,
            try makeFixtureRuntimeManager(pathManager: pathManager)
        )
    }

    private func makeFixtureRuntimeManager(
        pathManager: PathManager,
        fileManager: FileManager = .default
    ) throws -> RuntimeManager {
        let fixtureRoot = try XCTUnwrap(pathManager.rootURL).standardizedFileURL
        let fixtureRootPrefix = fixtureRoot.path + "/"
        let runner = SafeProcessRunner(
            sandboxEnabled: false,
            // RuntimeManager tests exercise installer caching, extraction, and
            // quiescent mutation orchestration with root-level shell stand-ins.
            // Managed Wine journal coverage owns a curated `wine/bin` Runtime
            // layout and is exercised by SafeProcessRunnerTests instead.
            managedWineProcessJournalEnabled: false,
            managedWineRuntimeFingerprintResolver: { _ in
                String(repeating: "a", count: 64)
            },
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { executable, actionName in
                let path = executable.standardizedFileURL.path
                guard path == fixtureRoot.path || path.hasPrefix(fixtureRootPrefix) else {
                    throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                        actionName: actionName,
                        path: executable.path
                    )
                }
            }
        )
        return RuntimeManager(pathManager: pathManager, runner: runner, fileManager: fileManager)
    }

    private func runtimeCacheTarget(
        for installer: URL,
        payload: Data,
        pathManager: PathManager
    ) throws -> URL {
        let contentSHA256 = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return try pathManager.url(for: .runtimeInstallers).appending(
            path: RuntimeManager.contentAddressedCacheFileName(
                for: installer,
                contentSHA256: contentSHA256
            )
        )
    }

    private func shutdownInvocationLines(at marker: URL) throws -> [Substring] {
        try String(contentsOf: marker, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
    }
}
