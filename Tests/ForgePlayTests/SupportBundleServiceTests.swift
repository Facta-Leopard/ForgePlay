import CryptoKit
import Darwin
import XCTest
@testable import ForgePlay

private final class RuntimeManifestHidingFileManager: FileManager {
    private let hiddenManifestPath: String
    private let probeLock = NSLock()
    private var _hiddenManifestProbeCount = 0

    init(hiddenManifestURL: URL) {
        self.hiddenManifestPath = hiddenManifestURL.standardizedFileURL.path
        super.init()
    }

    var hiddenManifestProbeCount: Int {
        probeLock.lock()
        defer { probeLock.unlock() }
        return _hiddenManifestProbeCount
    }

    override func fileExists(atPath path: String) -> Bool {
        if URL(fileURLWithPath: path).standardizedFileURL.path == hiddenManifestPath {
            probeLock.lock()
            _hiddenManifestProbeCount += 1
            probeLock.unlock()
            return false
        }
        return super.fileExists(atPath: path)
    }
}

private final class SupportBundleCollectionObservingFileManager: FileManager {
    private let lock = NSLock()
    private var _createDirectoryCallCount = 0
    private var fileExistenceMainThreadObservations: [Bool] = []

    var createDirectoryCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _createDirectoryCallCount
    }

    var fileExistenceProbeCount: Int {
        lock.withLock { fileExistenceMainThreadObservations.count }
    }

    var observedMainThreadFileExistenceProbe: Bool {
        lock.withLock { fileExistenceMainThreadObservations.contains(true) }
    }

    override func fileExists(atPath path: String) -> Bool {
        lock.withLock {
            fileExistenceMainThreadObservations.append(Thread.isMainThread)
        }
        return super.fileExists(atPath: path)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        lock.lock()
        _createDirectoryCallCount += 1
        lock.unlock()
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

private final class SupportBundleBlockingFileManager: FileManager {
    private let workerStarted: XCTestExpectation
    private let releaseWorker = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didBlockWorker = false

    init(workerStarted: XCTestExpectation) {
        self.workerStarted = workerStarted
        super.init()
    }

    func release() {
        releaseWorker.signal()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        let shouldBlock: Bool
        lock.lock()
        shouldBlock = !didBlockWorker && url.path.contains("ForgePlaySupport_")
        if shouldBlock { didBlockWorker = true }
        lock.unlock()
        if shouldBlock {
            workerStarted.fulfill()
            _ = releaseWorker.wait(timeout: .now() + 5)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

private final class SupportBundleStagingCleanupObservingFileManager: FileManager {
    private let cleanupStarted: XCTestExpectation
    private let releaseCleanup = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedCleanupThread: Bool?

    init(cleanupStarted: XCTestExpectation) {
        self.cleanupStarted = cleanupStarted
        super.init()
    }

    var cleanupRanOnMainThread: Bool? {
        lock.withLock { recordedCleanupThread }
    }

    func release() {
        releaseCleanup.signal()
    }

    override func removeItem(at URL: URL) throws {
        let shouldObserve = URL.lastPathComponent.hasPrefix("ForgePlaySupport_")
        if shouldObserve {
            lock.withLock {
                recordedCleanupThread = Thread.isMainThread
            }
            cleanupStarted.fulfill()
            _ = releaseCleanup.wait(timeout: .now() + 5)
        }
        try super.removeItem(at: URL)
    }
}

private final class SupportBundleLogsRootSwappingFileManager: FileManager {
    private let logsRoot: URL
    private let externalLogsRoot: URL
    private let lock = NSLock()
    private var _didSwap = false
    private var _swapError: Error?

    init(logsRoot: URL, externalLogsRoot: URL) {
        self.logsRoot = logsRoot.standardizedFileURL
        self.externalLogsRoot = externalLogsRoot.standardizedFileURL
        super.init()
    }

    var didSwap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didSwap
    }

    var swapError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _swapError
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
        let components = url.standardizedFileURL.pathComponents
        if let redactedLogsIndex = components.firstIndex(of: "redacted-logs"),
           redactedLogsIndex < components.index(before: components.endIndex) {
            lock.lock()
            let shouldSwap = !_didSwap
            if shouldSwap { _didSwap = true }
            lock.unlock()
            if shouldSwap {
                do {
                    try super.removeItem(at: logsRoot)
                    try super.createSymbolicLink(at: logsRoot, withDestinationURL: externalLogsRoot)
                } catch {
                    lock.lock()
                    _swapError = error
                    lock.unlock()
                }
            }
        }
    }
}

@MainActor
final class SupportBundleServiceTests: XCTestCase {
    func testEnvironmentFilesystemCaptureRunsOutsideMainThread() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlay-environment-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileManager = SupportBundleCollectionObservingFileManager()

        _ = try await DiagnosticEnvironmentSnapshotCollector.captureInBackground(
            managedRoot: root,
            selectedSteamReference: nil,
            runtimeExecutable: nil,
            fileManager: fileManager
        )

        XCTAssertGreaterThan(fileManager.fileExistenceProbeCount, 0)
        XCTAssertFalse(fileManager.observedMainThreadFileExistenceProbe)
    }

    func testSupportBundleAwaitsStagingCleanupWithoutBlockingMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleCleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let cleanupStarted = expectation(description: "support-bundle staging cleanup started")
        let fileManager = SupportBundleStagingCleanupObservingFileManager(
            cleanupStarted: cleanupStarted
        )
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor(),
            fileManager: fileManager
        )

        let task = Task {
            try await service.createSupportBundle(diagnostics: [], checks: [])
        }
        await fulfillment(of: [cleanupStarted], timeout: 5)
        XCTAssertEqual(fileManager.cleanupRanOnMainThread, false)
        fileManager.release()

        let archive = try await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testCancellingSupportBundleCancelsDetachedCollectionBeforeArchiveLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleCancellation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let workerStarted = expectation(description: "detached support-bundle worker started")
        let fileManager = SupportBundleBlockingFileManager(workerStarted: workerStarted)
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor(),
            fileManager: fileManager
        )

        let task = Task {
            try await service.createSupportBundle(diagnostics: [], checks: [])
        }
        await fulfillment(of: [workerStarted], timeout: 2)
        task.cancel()
        fileManager.release()

        do {
            _ = try await task.value
            XCTFail("Expected support-bundle collection cancellation")
        } catch is CancellationError {
            // Expected. Cancellation must be observed before archive creation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        let supportBundles = try pathManager.url(for: .supportBundles)
        let archives = try FileManager.default.contentsOfDirectory(
            at: supportBundles,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "zip" }
        XCTAssertTrue(archives.isEmpty)
    }

    func testSupportBundleRunsEvidenceHookImmediatelyBeforeSourceScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleHook-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleHookExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        let marker = launchLogs.appending(path: "support-pre-capture.log")
        let markerText = "support-pre-capture-hook-\(UUID().uuidString)"
        let markerData = Data(markerText.utf8)
        var capturedRequest: SupportBundleEvidencePreparationRequest?
        let selectedLaunch = LaunchRecord(
            id: "selected-incident-launch",
            gameId: "100",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 100),
            status: "failed"
        )
        let newestLaunch = LaunchRecord(
            id: "newest-unrelated-launch",
            gameId: "200",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 200),
            status: "failed"
        )
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor(),
            prepareEvidenceForCapture: { request in
                capturedRequest = request
                await Task.detached(priority: .utility) {
                    try? markerData.write(to: marker, options: [.atomic])
                }.value
                return .captured
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let archive = try await service.createSupportBundle(
            diagnostics: [],
            checks: [],
            launchRecords: [selectedLaunch, newestLaunch],
            incident: SupportIncidentContext(
                launchRecordIdentifier: selectedLaunch.id,
                occurredAt: selectedLaunch.startedAt
            )
        )
        try unzip(archive, to: extracted)
        let capturedText = try allFiles(under: extracted)
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(capturedText.contains(markerText))
        XCTAssertEqual(capturedRequest?.incidentLaunchRecordIdentifier, selectedLaunch.id)
        XCTAssertEqual(capturedRequest?.launchRecords.map(\.id), [newestLaunch.id, selectedLaunch.id])
    }

    func testSupportBundleArchiveNamesAreUnique() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let firstArchive = try await service.createSupportBundle(diagnostics: [], checks: [])
        let secondArchive = try await service.createSupportBundle(diagnostics: [], checks: [])

        XCTAssertNotEqual(firstArchive.path, secondArchive.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstArchive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondArchive.path))
    }

    func testSupportBundleSkipsExistingBundlesAndKeepsRedactedMetadataJSONValid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
            if FileManager.default.fileExists(atPath: extracted.path) {
                try? FileManager.default.removeItem(at: extracted)
            }
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )
        let runtimeExecutable = root.appending(path: "Apps/Runners/AppleGPTK/gameportingtoolkit")
        let selectedSteamReference = SteamGame(
            steamAppId: "1245620",
            name: "Support Bundle Test Game",
            installDir: "SupportBundleTestGame",
            libraryPath: root.appending(path: "SteamLibrary/steamapps/common/SupportBundleTestGame").path,
            manifestPath: root.appending(path: "SteamLibrary/steamapps/appmanifest_1245620.acf").path,
            sizeOnDisk: 1024,
            lastUpdated: nil
        )

        let launchLog = try pathManager.url(for: .launchLogs).appending(path: "launch.log")
        try """
        token=launch-secret
        standalone=sk-proj-launchabcdefghijklmnopqrstuvwxyz1234567890
        url=https://example.com/callback?access_token=url-launch-secret
        forgeplayRoot=\(root.path)
        runnerPath=\(runtimeExecutable.path)
        libraryPath=\(selectedSteamReference.libraryPath)
        manifestPath=\(selectedSteamReference.manifestPath)
        "AccountName" "supportBundleSteamLogin"
        "PersonaName" "Support Bundle Persona"
        "AutoLoginUser" "supportAutoLogin"
        "SteamLoginSecure" "support-cookie-secret"
        """.write(to: launchLog, atomically: true, encoding: .utf8)
        let previousBundle = try pathManager.url(for: .supportBundles).appending(path: "old.zip")
        try Data("token=old-bundle-secret".utf8).write(to: previousBundle)

        let diagnostic = DiagnosticResult(
            category: .unknown,
            confidence: 0.5,
            userMessage: "SteamGuard verification code 123456 should be removed",
            technicalSummary: #"C:\Users\"# + NSUserName() + #"\AppData\Local\Steam password=metadata-secret"#,
            riskLevel: .medium,
            recommendedActions: []
        )
        let check = SystemCheckResult(
            title: "GPTK",
            detail: "authorization: bearer check-secret",
            status: .warning,
            technicalDetail: root.appending(path: "Users/test/path").path
        )

        let archive = try await service.createSupportBundle(
            diagnostics: [diagnostic],
            checks: [check],
            selectedSteamReference: selectedSteamReference,
            runtimeExecutable: runtimeExecutable
        )

        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "old.zip" })
        let archiveEntryText = files.map(\.path).joined(separator: "\n")
        XCTAssertFalse(archiveEntryText.contains("launch.log"), archiveEntryText)

        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let normalizedCombinedText = combinedText.replacingOccurrences(of: "\\\\", with: "\\")
        XCTAssertFalse(combinedText.contains("launch-secret"))
        XCTAssertFalse(combinedText.contains("sk-proj-launchabcdefghijklmnopqrstuvwxyz1234567890"))
        XCTAssertFalse(combinedText.contains("url-launch-secret"))
        XCTAssertFalse(combinedText.contains("supportBundleSteamLogin"))
        XCTAssertFalse(combinedText.contains("Support Bundle Persona"))
        XCTAssertFalse(combinedText.contains("supportAutoLogin"))
        XCTAssertFalse(combinedText.contains("support-cookie-secret"))
        XCTAssertFalse(combinedText.contains("123456"))
        XCTAssertFalse(combinedText.contains("metadata-secret"))
        XCTAssertFalse(combinedText.contains("check-secret"))
        XCTAssertFalse(
            normalizedCombinedText.localizedCaseInsensitiveContains("C:\\Users\\\(NSUserName())"),
            normalizedCombinedText
        )
        XCTAssertFalse(combinedText.contains(root.path))
        XCTAssertFalse(combinedText.contains(runtimeExecutable.path))
        XCTAssertFalse(combinedText.contains(selectedSteamReference.libraryPath))
        XCTAssertFalse(combinedText.contains(selectedSteamReference.manifestPath))
        XCTAssertTrue(combinedText.contains("[REDACTED_SECRET]"))
        XCTAssertTrue(combinedText.contains("[REDACTED_STEAM_ACCOUNT]"))
        XCTAssertTrue(combinedText.contains("[REDACTED_PATH]"))
        XCTAssertTrue(combinedText.contains("1245620"))
        XCTAssertTrue(files.contains { $0.lastPathComponent == "bundle-manifest.json" })

        for metadataName in [
            "diagnostics.json",
            "diagnostic-records.json",
            "system-checks.json",
            "environment.json",
            "app-info.json",
            "bundle-manifest.json"
        ] {
            let metadataFile = try XCTUnwrap(files.first { $0.lastPathComponent == metadataName })
            let data = try Data(contentsOf: metadataFile)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                "Expected valid redacted JSON in \(metadataName)"
            )
        }
    }

    func testSupportBundleSkipsNonRegularLogFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let fifoLog = try pathManager.url(for: .launchLogs).appending(path: "fifo.log")
        let result = fifoLog.path.withCString { path in
            mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(result, 0)
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let archive = try await service.createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "fifo.log" })
        let skippedManifest = try XCTUnwrap(files.first { $0.lastPathComponent == "skipped-files.json" })
        let skippedText = try String(contentsOf: skippedManifest, encoding: .utf8)
        XCTAssertFalse(skippedText.contains("fifo.log"))
        XCTAssertTrue(skippedText.contains("log-000001"))
        XCTAssertTrue(skippedText.contains("anonymousSourceIdentifier"))
        XCTAssertFalse(skippedText.contains("relativePath"))
        XCTAssertTrue(skippedText.contains("notRegularFile"))
    }

    func testSupportBundlePersistsRuntimeIdentityValidationFailureInEnvironmentAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runtimeExecutable = try pathManager.url(for: .runtimeCache)
            .appending(path: "identity-invalid-runner")
        try "#!/bin/sh\nexit 0\n".write(
            to: runtimeExecutable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )
        try "{not-valid-runtime-manifest".write(
            to: runtimeExecutable.deletingLastPathComponent().appending(path: "RuntimeManifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            runtimeExecutable: runtimeExecutable
        )

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let manifestEnvironment = try XCTUnwrap(manifest["environment"] as? [String: Any])
        let manifestRuntime = try XCTUnwrap(manifestEnvironment["runtime"] as? [String: Any])
        let manifestIdentity = try XCTUnwrap(manifestRuntime["identity"] as? [String: Any])
        XCTAssertEqual(manifestIdentity["state"] as? String, "invalid")
        XCTAssertFalse((manifestIdentity["validationError"] as? String)?.isEmpty ?? true)

        let environmentURL = try XCTUnwrap(
            allFiles(under: extracted).first { $0.lastPathComponent == "environment.json" }
        )
        let environment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: environmentURL)) as? [String: Any]
        )
        let runtime = try XCTUnwrap(environment["runtime"] as? [String: Any])
        let identity = try XCTUnwrap(runtime["identity"] as? [String: Any])
        XCTAssertEqual(identity["state"] as? String, "invalid")
        XCTAssertEqual(identity["validationError"] as? String, manifestIdentity["validationError"] as? String)

        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains {
            $0["component"] as? String == "runtime.identity" &&
                !(($0["message"] as? String)?.isEmpty ?? true)
        }, "\(issues)")

        let readmeURL = try XCTUnwrap(
            allFiles(under: extracted).first { $0.lastPathComponent == "README.md" }
        )
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)
        XCTAssertTrue(readme.contains("- App version/build:"), readme)
        XCTAssertTrue(readme.contains("- Build configuration:"), readme)
        XCTAssertTrue(readme.contains("- Runtime identity: state=invalid"), readme)
        XCTAssertTrue(readme.contains("- Runtime build fingerprint:"), readme)
        XCTAssertTrue(readme.contains("- Runtime prefix compatibility fingerprint:"), readme)
        XCTAssertTrue(readme.contains("- Runtime identity validation error:"), readme)
        XCTAssertTrue(readme.contains("### Displays"), readme)
        XCTAssertTrue(readme.contains("### Volumes"), readme)
        XCTAssertTrue(readme.contains("- managedRoot: available=true"), readme)
        XCTAssertTrue(readme.contains("capacityBytes="), readme)
        XCTAssertTrue(readme.contains("freeBytes="), readme)
        XCTAssertTrue(readme.contains("readOnly="), readme)
        XCTAssertTrue(readme.contains("removable="), readme)
    }

    func testSupportBundleRuntimeIdentityUsesInjectedFileManager() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRuntimeRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayInjectedRuntime-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRuntimeRoot)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let bin = externalRuntimeRoot.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let runtimeExecutable = bin.appending(path: "wine64")
        try "#!/bin/sh\nexit 0\n".write(
            to: runtimeExecutable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )
        let adjacentManifest = bin.appending(path: "RuntimeManifest.json")
        try "{invalid-manifest-visible-to-default-manager".write(
            to: adjacentManifest,
            atomically: true,
            encoding: .utf8
        )
        let injectedFileManager = RuntimeManifestHidingFileManager(
            hiddenManifestURL: adjacentManifest
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor(),
            fileManager: injectedFileManager
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            runtimeExecutable: runtimeExecutable
        )

        try unzip(archive, to: extracted)
        let environmentURL = try XCTUnwrap(
            allFiles(under: extracted).first { $0.lastPathComponent == "environment.json" }
        )
        let environment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: environmentURL)) as? [String: Any]
        )
        let runtime = try XCTUnwrap(environment["runtime"] as? [String: Any])
        let environmentIdentity = try XCTUnwrap(runtime["identity"] as? [String: Any])
        XCTAssertEqual(environmentIdentity["state"] as? String, "derivedIncomplete")

        let manifest = try manifestObject(under: extracted)
        let manifestEnvironment = try XCTUnwrap(manifest["environment"] as? [String: Any])
        let manifestRuntime = try XCTUnwrap(manifestEnvironment["runtime"] as? [String: Any])
        let manifestIdentity = try XCTUnwrap(manifestRuntime["identity"] as? [String: Any])
        XCTAssertEqual(manifestIdentity["state"] as? String, "derivedIncomplete")
        XCTAssertGreaterThan(injectedFileManager.hiddenManifestProbeCount, 0)
    }

    func testSupportBundleCollectionUsesInjectedFileManagerInsideDetachedTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let observingFileManager = SupportBundleCollectionObservingFileManager()
        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor(),
            fileManager: observingFileManager
        ).createSupportBundle(diagnostics: [], checks: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertGreaterThan(observingFileManager.createDirectoryCallCount, 0)
    }

    func testSupportBundleDoesNotReadThroughLaunchLogsDirectoryReplacedAfterValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLogs = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLogs)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let externalLaunchLogs = externalLogs.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalLaunchLogs, withIntermediateDirectories: true)
        let runID = "44444444-5555-6666-7777-888888888888"
        let stem = "2026-07-15_12-00-00_swap_test_\(runID)"
        let stdout = launchLogs.appending(path: "\(stem)_stdout.log")
        let stderr = launchLogs.appending(path: "\(stem)_stderr.log")
        try "managed-stdout-before-swap".write(to: stdout, atomically: true, encoding: .utf8)
        try "managed-stderr-before-swap".write(to: stderr, atomically: true, encoding: .utf8)
        try "external-private-log-payload".write(
            to: externalLaunchLogs.appending(path: stdout.lastPathComponent),
            atomically: true,
            encoding: .utf8
        )
        try "external-private-log-payload".write(
            to: externalLaunchLogs.appending(path: stderr.lastPathComponent),
            atomically: true,
            encoding: .utf8
        )
        let swappingFileManager = SupportBundleLogsRootSwappingFileManager(
            logsRoot: launchLogs,
            externalLogsRoot: externalLaunchLogs
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor(),
            fileManager: swappingFileManager
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            launchRecords: [LaunchRecord(
                id: "launch-record-root-swap",
                gameId: "1245620",
                prefixId: PrefixIdentifier.steamShared,
                commandKind: "launchSteam",
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 101),
                exitCode: 1,
                stdoutPath: stdout.path,
                stderrPath: stderr.path,
                status: "failed"
            )]
        )

        XCTAssertTrue(swappingFileManager.didSwap)
        XCTAssertNil(swappingFileManager.swapError)
        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(combinedText.contains("external-private-log-payload"), combinedText)
        let manifest = try manifestObject(under: extracted)
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains {
            guard let component = $0["component"] as? String else { return false }
            return ["artifactRead", "logs.scan"].contains(component)
        }, "\(issues)")
    }

    func testSupportBundleRedactsEntireUnexpectedRuntimeRootFromIdentityEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let privateRuntimeDirectoryName = "Private Runtime Fixture Jane Doe \(UUID().uuidString)"
        let unexpectedRuntimeRoot = FileManager.default.temporaryDirectory
            .appending(path: privateRuntimeDirectoryName, directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let invalidExtracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unexpectedRuntimeRoot)
            try? FileManager.default.removeItem(at: extracted)
            try? FileManager.default.removeItem(at: invalidExtracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let bin = unexpectedRuntimeRoot.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let runtimeExecutable = bin.appending(path: "wine64")
        try "#!/bin/sh\nexit 0\n".write(
            to: runtimeExecutable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeExecutable.path
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            runtimeExecutable: runtimeExecutable
        )

        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        let environmentURL = try XCTUnwrap(
            files.first { $0.lastPathComponent == "environment.json" }
        )
        let readmeURL = try XCTUnwrap(files.first { $0.lastPathComponent == "README.md" })
        let manifestURL = try XCTUnwrap(
            files.first { $0.lastPathComponent == "bundle-manifest.json" }
        )
        let environmentText = try String(contentsOf: environmentURL, encoding: .utf8)
        let readmeText = try String(contentsOf: readmeURL, encoding: .utf8)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        for text in [environmentText, readmeText, manifestText] {
            XCTAssertFalse(text.contains(unexpectedRuntimeRoot.path), text)
            XCTAssertFalse(text.contains(privateRuntimeDirectoryName), text)
        }

        let environment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(environmentText.utf8)) as? [String: Any]
        )
        let runtime = try XCTUnwrap(environment["runtime"] as? [String: Any])
        let identity = try XCTUnwrap(runtime["identity"] as? [String: Any])
        XCTAssertEqual(identity["state"] as? String, "derivedIncomplete")
        let identityIssues = try XCTUnwrap(identity["identityIssues"] as? [String])
        XCTAssertEqual(identityIssues.count, 2)
        XCTAssertTrue(identityIssues.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(identityIssues.allSatisfy { !$0.contains(unexpectedRuntimeRoot.path) })
        XCTAssertTrue(identityIssues.allSatisfy { !$0.contains(privateRuntimeDirectoryName) })
        XCTAssertTrue(readmeText.contains("- Runtime identity issue:"), readmeText)

        try "{invalid-runtime-root-manifest".write(
            to: unexpectedRuntimeRoot.appending(path: "RuntimeManifest.json"),
            atomically: true,
            encoding: .utf8
        )
        let invalidArchive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            runtimeExecutable: runtimeExecutable
        )
        try unzip(invalidArchive, to: invalidExtracted)
        let invalidFiles = try allFiles(under: invalidExtracted)
        let invalidEnvironmentURL = try XCTUnwrap(
            invalidFiles.first { $0.lastPathComponent == "environment.json" }
        )
        let invalidReadmeURL = try XCTUnwrap(
            invalidFiles.first { $0.lastPathComponent == "README.md" }
        )
        let invalidManifestURL = try XCTUnwrap(
            invalidFiles.first { $0.lastPathComponent == "bundle-manifest.json" }
        )
        let invalidEnvironmentText = try String(contentsOf: invalidEnvironmentURL, encoding: .utf8)
        let invalidReadmeText = try String(contentsOf: invalidReadmeURL, encoding: .utf8)
        let invalidManifestText = try String(contentsOf: invalidManifestURL, encoding: .utf8)
        for text in [invalidEnvironmentText, invalidReadmeText, invalidManifestText] {
            XCTAssertFalse(text.contains(unexpectedRuntimeRoot.path), text)
            XCTAssertFalse(text.contains(privateRuntimeDirectoryName), text)
        }
        let invalidEnvironment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(invalidEnvironmentText.utf8)) as? [String: Any]
        )
        let invalidRuntime = try XCTUnwrap(invalidEnvironment["runtime"] as? [String: Any])
        let invalidIdentity = try XCTUnwrap(invalidRuntime["identity"] as? [String: Any])
        XCTAssertEqual(invalidIdentity["state"] as? String, "invalid")
        let validationError = try XCTUnwrap(invalidIdentity["validationError"] as? String)
        XCTAssertFalse(validationError.isEmpty)
        XCTAssertFalse(validationError.contains(unexpectedRuntimeRoot.path))
        XCTAssertFalse(validationError.contains(privateRuntimeDirectoryName))
        XCTAssertTrue(invalidReadmeText.contains("- Runtime identity validation error:"))
    }

    func testSupportBundleSkipsHardlinkedLogsAndPrefixMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let prefixes = try pathManager.url(for: .prefixes)
        let externalLog = root.appending(path: "outside-hardlinked-log-source.log")
        try "hardlinked-log-secret".write(to: externalLog, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(
            at: externalLog,
            to: launchLogs.appending(path: "hardlinked.log")
        )
        let prefix = prefixes.appending(path: "HardlinkedPrefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let externalMetadata = root.appending(path: "outside-hardlinked-prefix.json")
        try #"{"token":"hardlinked-prefix-secret"}"#.write(to: externalMetadata, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(
            at: externalMetadata,
            to: prefix.appending(path: "prefix.json")
        )

        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let archive = try await service.createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        XCTAssertFalse(files.contains { $0.path.contains("/redacted-logs/hardlinked.log") })
        XCTAssertFalse(files.contains { $0.path.contains("/metadata/prefixes/HardlinkedPrefix/prefix.json") })
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(combinedText.contains("hardlinked-log-secret"))
        XCTAssertFalse(combinedText.contains("hardlinked-prefix-secret"))
        let skippedManifest = try XCTUnwrap(files.first { $0.lastPathComponent == "skipped-files.json" })
        let skippedText = try String(contentsOf: skippedManifest, encoding: .utf8)
        XCTAssertFalse(skippedText.contains("hardlinked.log"))
        XCTAssertFalse(skippedText.contains("HardlinkedPrefix"))
        XCTAssertTrue(skippedText.contains("log-000001"))
        XCTAssertTrue(skippedText.contains("prefix-000001"))
        XCTAssertTrue(skippedText.contains("hardlinkedFile"))
    }

    func testSupportBundleUsesStableAnonymousArchiveEntriesAndSafeManifestMappings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let firstExtracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let secondExtracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: firstExtracted)
            try? FileManager.default.removeItem(at: secondExtracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let privateFolderName = "Private Customer Jane Doe"
        let privateLogName = "Project Phoenix - jane@example.com.log"
        let privatePrefixName = "Jane Doe Personal Prefix"
        let unsafeFolder = try pathManager.url(for: .launchLogs)
            .appending(path: privateFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unsafeFolder, withIntermediateDirectories: true)
        let unsafeLog = unsafeFolder.appending(path: privateLogName)
        try "support bundle path payload".write(to: unsafeLog, atomically: true, encoding: .utf8)
        let privatePrefix = try pathManager.url(for: .prefixes)
            .appending(path: privatePrefixName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: privatePrefix, withIntermediateDirectories: true)
        try #"{"renderer":"d3dmetal"}"#.write(
            to: privatePrefix.appending(path: "prefix.json"),
            atomically: true,
            encoding: .utf8
        )
        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let firstArchive = try await service.createSupportBundle(diagnostics: [], checks: [])
        let secondArchive = try await service.createSupportBundle(diagnostics: [], checks: [])

        try unzip(firstArchive, to: firstExtracted)
        try unzip(secondArchive, to: secondExtracted)
        let files = try allFiles(under: firstExtracted)
        let archiveEntryText = files.map(\.path).joined(separator: "\n")
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for privateValue in [privateFolderName, privateLogName, privatePrefixName, "jane@example.com"] {
            XCTAssertFalse(archiveEntryText.contains(privateValue), archiveEntryText)
            XCTAssertFalse(combinedText.contains(privateValue), combinedText)
        }
        let copiedLog = try XCTUnwrap(files.first { $0.lastPathComponent == "log-000001.log" })
        XCTAssertNotNil(files.first { $0.lastPathComponent == "prefix-000001.json" })
        let copiedText = try String(contentsOf: copiedLog, encoding: .utf8)
        XCTAssertTrue(copiedText.contains("support bundle path payload"))
        let manifest = try XCTUnwrap(files.first { $0.lastPathComponent == "bundle-manifest.json" })
        let manifestText = try String(contentsOf: manifest, encoding: .utf8)
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(manifestText.utf8)) as? [String: Any]
        )
        let includedFiles = try XCTUnwrap(manifestObject["includedFiles"] as? [[String: Any]])
        let mappedArchiveEntries = includedFiles.compactMap { $0["archiveEntry"] as? String }
        XCTAssertTrue(mappedArchiveEntries.contains("redacted-logs/unassigned/log-000001.log"))
        XCTAssertTrue(mappedArchiveEntries.contains("metadata/prefixes/prefix-000001.json"))
        XCTAssertTrue(includedFiles.allSatisfy { $0["anonymousSourceIdentifier"] != nil })
        XCTAssertFalse(manifestText.contains("relativePath"))
        XCTAssertFalse(manifestText.contains(privateFolderName))
        XCTAssertFalse(manifestText.contains(privateLogName))
        XCTAssertFalse(manifestText.contains(privatePrefixName))

        XCTAssertEqual(
            try anonymousPayloadEntryNames(under: firstExtracted),
            try anonymousPayloadEntryNames(under: secondExtracted)
        )
    }

    func testSupportBundleRejectsSymlinkManagedLogsRootBeforeArchiveCreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLogs = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLogs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLogs)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logsRoot = try pathManager.url(for: .logs)
        try FileManager.default.createDirectory(at: externalLogs, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: logsRoot)
        try FileManager.default.createSymbolicLink(at: logsRoot, withDestinationURL: externalLogs)

        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        do {
            _ = try await service.createSupportBundle(diagnostics: [], checks: [])
            XCTFail("Expected symlink Logs root to fail support bundle creation")
        } catch PathManagerError.unsafeDirectory(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, logsRoot.standardizedFileURL.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: externalLogs.appending(path: "SupportBundles").path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSupportBundleRejectsSymlinkManagedPrefixesRootBeforeCopyingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalPrefixes = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefixes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalPrefixes)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixesRoot = try pathManager.url(for: .prefixes)
        try FileManager.default.createDirectory(at: externalPrefixes, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: prefixesRoot)
        try FileManager.default.createSymbolicLink(at: prefixesRoot, withDestinationURL: externalPrefixes)

        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        do {
            _ = try await service.createSupportBundle(diagnostics: [], checks: [])
            XCTFail("Expected symlink Prefixes root to fail support bundle creation")
        } catch PathManagerError.unsafeDirectory(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, prefixesRoot.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSupportBundleRecordsUnreadablePrefixRootWithoutAbortingArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Prefixes").path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixesRoot = try pathManager.url(for: .prefixes)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: prefixesRoot.path)

        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let archive = try await service.createSupportBundle(diagnostics: [], checks: [])
        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])

        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
        XCTAssertFalse(issues.isEmpty)
    }

    func testSupportBundleRecordsUnreadableLogAndStillIncludesReadableEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        var unreadableLog: URL?
        defer {
            if let unreadableLog {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableLog.path)
            }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logURL = try pathManager.url(for: .launchLogs).appending(path: "unreadable.log")
        unreadableLog = logURL
        try "token=unreadable-log-secret".write(to: logURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        let readableLog = try pathManager.url(for: .launchLogs).appending(path: "readable.log")
        try "readable-evidence-marker".write(to: readableLog, atomically: true, encoding: .utf8)

        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let archive = try await service.createSupportBundle(diagnostics: [], checks: [])
        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let manifest = try manifestObject(under: extracted)
        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])

        XCTAssertTrue(combinedText.contains("readable-evidence-marker"), combinedText)
        XCTAssertFalse(combinedText.contains("unreadable-log-secret"), combinedText)
        XCTAssertTrue(skipped.contains { $0["reason"] as? String == "readFailed" }, "\(skipped)")
        XCTAssertTrue(issues.contains { $0["component"] as? String == "artifactRead" }, "\(issues)")
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
    }

    func testSupportBundleRecordsUnreadablePrefixMetadataWithoutAbortingArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        var unreadableMetadata: URL?
        defer {
            if let unreadableMetadata {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableMetadata.path)
            }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .prefixes)
            .appending(path: "UnreadablePrefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let metadataURL = prefix.appending(path: "prefix.json")
        unreadableMetadata = metadataURL
        try #"{"token":"unreadable-prefix-secret"}"#.write(to: metadataURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: metadataURL.path)

        let service = SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        )

        let archive = try await service.createSupportBundle(diagnostics: [], checks: [])
        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])

        XCTAssertTrue(skipped.contains {
            $0["sourceCategory"] as? String == "prefixMetadata" &&
                $0["reason"] as? String == "readFailed"
        }, "\(skipped)")
        XCTAssertTrue(issues.contains { $0["component"] as? String == "artifactRead" }, "\(issues)")
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
    }

    func testSupportBundleGroupsRunArtifactsAndLinksLaunchRecordReferences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let runID = "11111111-2222-3333-4444-555555555555"
        let stem = "2026-07-15_12-00-00_steam_launch_\(runID)"
        let stdout = launchLogs.appending(path: "\(stem)_stdout.log")
        let stderr = launchLogs.appending(path: "\(stem)_stderr.log")
        let diagnostics = launchLogs.appending(path: "\(stem)_stderr.diagnostics.log")
        let processEvidence = launchLogs.appending(path: "\(stem)_stderr.run.json")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(runID)",
            directoryHint: .isDirectory
        )
        let gameAttemptArtifact = gameRunDirectory.appending(
            path: "game-launch-attempt-v1-test-revision.json"
        )
        let gameDiagnosticArtifact = gameRunDirectory.appending(
            path: "game-launch-diagnostic.json"
        )
        let gameCaptureArtifact = gameRunDirectory.appending(
            path: "game-launch-capture.json"
        )
        try "stdout-run-marker".write(to: stdout, atomically: true, encoding: .utf8)
        try "stderr-run-marker".write(to: stderr, atomically: true, encoding: .utf8)
        try "diagnostics-run-marker".write(to: diagnostics, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: gameRunDirectory, withIntermediateDirectories: true)
        try """
        {"schema_version":1,"attempt_identifier":"v1-test","material_revision":"revision","diagnostic":{"summary":"game-attempt-history-marker"}}
        """.write(to: gameAttemptArtifact, atomically: true, encoding: .utf8)
        try """
        {"schema_version":2,"summary":"game-current-diagnostic-marker"}
        """.write(to: gameDiagnosticArtifact, atomically: true, encoding: .utf8)
        try """
        {"schema_version":1,"capture_state":"attemptsCaptured","summary":"game-capture-marker"}
        """.write(to: gameCaptureArtifact, atomically: true, encoding: .utf8)
        let evidenceDocument = ProcessRunEvidenceDocument(
            runIdentifier: runID,
            actionName: "launchSteam",
            executable: root.appending(path: "wine").path,
            arguments: ["steam.exe"],
            environmentOverrides: ["WINEPREFIX": root.appending(path: "Prefixes/SteamShared").path],
            workingDirectory: root.path,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 105),
            durationMilliseconds: 5_000,
            outcome: .exited,
            exitCode: 71,
            terminationSignal: nil,
            rawWaitStatus: 18_176,
            didTimeOut: false,
            waitedForExit: true,
            processIdentifier: 1234,
            stdoutLog: stdout.path,
            stderrLog: stderr.path,
            processObservationLog: nil,
            captureError: nil
        )
        let evidenceEncoder = JSONEncoder()
        evidenceEncoder.dateEncodingStrategy = .iso8601
        try evidenceEncoder.encode(evidenceDocument).write(to: processEvidence)

        let launchRecord = LaunchRecord(
            id: "launch-record-run-grouping",
            gameId: "1245620",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 105),
            exitCode: 71,
            stdoutPath: stdout.path,
            stderrPath: stderr.path,
            diagnosticLogPath: diagnostics.path,
            status: "failed"
        )
        launchRecord.processOutcome = ProcessRunOutcome.exited.rawValue
        launchRecord.rawWaitStatus = 18_176
        launchRecord.runEvidencePath = processEvidence.path
        launchRecord.gameName = "Support Bundle Selected Reference"
        launchRecord.gameBuildID = "build-987"
        launchRecord.gameManifestStateFlags = 4
        launchRecord.gameInstalledByteCount = 9_876_543
        launchRecord.gameLastUpdatedAt = Date(timeIntervalSince1970: 123)
        launchRecord.gameManifestAvailable = true
        launchRecord.gameManifestCaptureIssue = "manifest snapshot warning"
        launchRecord.gameAssociationSource = "selectedReferenceAtSteamLaunchNotExecutionVerified"

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            launchRecords: [launchRecord]
        )

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let launches = try XCTUnwrap(manifest["launches"] as? [[String: Any]])
        let launch = try XCTUnwrap(launches.first)
        let references = try XCTUnwrap(launch["artifactReferences"] as? [String: String])
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let runArtifacts = included.filter { $0["runIdentifier"] as? String == runID }

        XCTAssertEqual(launch["recordIdentifier"] as? String, launchRecord.id)
        XCTAssertEqual(launch["gameID"] as? String, "1245620")
        XCTAssertEqual(launch["gameName"] as? String, "Support Bundle Selected Reference")
        XCTAssertEqual(launch["gameBuildID"] as? String, "build-987")
        XCTAssertEqual((launch["gameManifestStateFlags"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((launch["gameInstalledByteCount"] as? NSNumber)?.int64Value, 9_876_543)
        XCTAssertNotNil(launch["gameLastUpdatedAt"] as? String)
        XCTAssertEqual(launch["gameManifestAvailable"] as? Bool, true)
        XCTAssertEqual(launch["gameManifestCaptureIssue"] as? String, "manifest snapshot warning")
        XCTAssertEqual(
            launch["gameAssociationSource"] as? String,
            "selectedReferenceAtSteamLaunchNotExecutionVerified"
        )
        XCTAssertEqual(launch["durationMilliseconds"] as? Int, 5_000)
        XCTAssertEqual(launch["processOutcome"] as? String, ProcessRunOutcome.exited.rawValue)
        XCTAssertEqual(Set(references.keys), ["stdout", "stderr", "diagnostics", "processRunMetadata"])
        XCTAssertTrue(references.values.allSatisfy {
            $0.contains("redacted-logs/runs/\(runID)/")
        }, "\(references)")
        XCTAssertEqual(
            Set(runArtifacts.compactMap { $0["artifactRole"] as? String }),
            [
                "stdout",
                "stderr",
                "diagnostics",
                "processRunMetadata",
                "gameLaunchCapture",
                "gameLaunchDiagnostic",
                "gameLaunchAttemptDiagnostic",
            ]
        )
        XCTAssertTrue(runArtifacts.filter {
            ["stdout", "stderr", "diagnostics", "processRunMetadata"]
                .contains($0["artifactRole"] as? String ?? "")
        }.allSatisfy { $0["actionName"] as? String == "steam_launch" })
        let gameAttempt = try XCTUnwrap(runArtifacts.first {
            $0["artifactRole"] as? String == "gameLaunchAttemptDiagnostic"
        })
        let gameAttemptEntry = try XCTUnwrap(gameAttempt["archiveEntry"] as? String)
        let gameAttemptCopy = try file(forArchiveEntry: gameAttemptEntry, under: extracted)
        XCTAssertTrue(
            try String(contentsOf: gameAttemptCopy, encoding: .utf8)
                .contains("game-attempt-history-marker")
        )
        let gameDiagnostic = try XCTUnwrap(runArtifacts.first {
            $0["artifactRole"] as? String == "gameLaunchDiagnostic"
        })
        let gameDiagnosticEntry = try XCTUnwrap(gameDiagnostic["archiveEntry"] as? String)
        let gameDiagnosticCopy = try file(forArchiveEntry: gameDiagnosticEntry, under: extracted)
        XCTAssertTrue(
            try String(contentsOf: gameDiagnosticCopy, encoding: .utf8)
                .contains("game-current-diagnostic-marker")
        )
        let gameCapture = try XCTUnwrap(runArtifacts.first {
            $0["artifactRole"] as? String == "gameLaunchCapture"
        })
        let gameCaptureEntry = try XCTUnwrap(gameCapture["archiveEntry"] as? String)
        let gameCaptureCopy = try file(forArchiveEntry: gameCaptureEntry, under: extracted)
        XCTAssertTrue(
            try String(contentsOf: gameCaptureCopy, encoding: .utf8)
                .contains("game-capture-marker")
        )
        XCTAssertEqual((launch["missingArtifactRoles"] as? [String]) ?? [], [])

        let readmeURL = try XCTUnwrap(allFiles(under: extracted).first { $0.lastPathComponent == "README.md" })
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)
        XCTAssertTrue(readme.contains("launch-time selected reference, not execution verification"), readme)
        XCTAssertTrue(readme.contains("actual AppID plus process start/exit evidence"), readme)
    }

    func testSupportBundleExpandsRelatedRunEvidenceReferencesSafelyAndWithoutCycles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRunEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
            try? FileManager.default.removeItem(at: external)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let hiddenEvidence = launchLogs.appending(
            path: ".related-run-evidence",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: hiddenEvidence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let primaryRunID = "22222222-3333-4444-5555-666666666666"
        let nestedRunID = "33333333-4444-5555-6666-777777777777"
        let primaryStem = "2026-07-15_12-00-00_related_launch_\(primaryRunID)"
        let nestedStem = "2026-07-15_12-00-01_related_launch_\(nestedRunID)"
        let primaryEvidence = launchLogs.appending(path: "\(primaryStem)_stderr.run.json")
        let primaryStdout = hiddenEvidence.appending(path: "\(primaryStem)_stdout.log")
        let primaryStderr = hiddenEvidence.appending(path: "\(primaryStem)_stderr.log")
        let primaryObservation = hiddenEvidence.appending(
            path: "\(primaryStem)_process-observation.log"
        )
        let primaryDiagnostics = hiddenEvidence.appending(
            path: "\(primaryStem).diagnostics.log"
        )
        let nestedEvidence = hiddenEvidence.appending(path: "\(nestedStem)_stderr.run.json")
        let nestedStdout = hiddenEvidence.appending(path: "\(nestedStem)_stdout.log")
        let unsafeEvidenceLink = hiddenEvidence.appending(path: "unsafe-related.run.json")
        let externalEvidence = external.appending(path: "external.run.json")
        let externalObservation = external.appending(path: "external-observation.log")

        try "EXPANDED-PRIMARY-STDOUT".write(to: primaryStdout, atomically: true, encoding: .utf8)
        try "EXPANDED-PRIMARY-STDERR".write(to: primaryStderr, atomically: true, encoding: .utf8)
        try "EXPANDED-PRIMARY-OBSERVATION".write(
            to: primaryObservation,
            atomically: true,
            encoding: .utf8
        )
        try "EXPANDED-PRIMARY-DIAGNOSTICS".write(
            to: primaryDiagnostics,
            atomically: true,
            encoding: .utf8
        )
        try "EXPANDED-NESTED-STDOUT".write(to: nestedStdout, atomically: true, encoding: .utf8)
        try #"{"marker":"UNSAFE-EXTERNAL-EVIDENCE"}"#.write(
            to: externalEvidence,
            atomically: true,
            encoding: .utf8
        )
        try "UNSAFE-EXTERNAL-OBSERVATION".write(
            to: externalObservation,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: unsafeEvidenceLink,
            withDestinationURL: externalEvidence
        )

        let nestedDocument = ProcessRunEvidenceDocument(
            runIdentifier: nestedRunID,
            actionName: "nestedLaunch",
            executable: root.appending(path: "wine").path,
            arguments: [],
            environmentOverrides: [:],
            workingDirectory: root.path,
            startedAt: Date(timeIntervalSince1970: 101),
            endedAt: Date(timeIntervalSince1970: 102),
            durationMilliseconds: 1_000,
            outcome: .exited,
            exitCode: 0,
            relatedRunEvidenceLogs: [primaryEvidence.path],
            terminationSignal: nil,
            rawWaitStatus: 0,
            didTimeOut: false,
            waitedForExit: true,
            processIdentifier: 4321,
            stdoutLog: nestedStdout.path,
            stderrLog: primaryStderr.path,
            processObservationLog: externalObservation.path,
            captureError: nil
        )
        let primaryDocument = ProcessRunEvidenceDocument(
            runIdentifier: primaryRunID,
            actionName: "primaryLaunch",
            executable: root.appending(path: "wine").path,
            arguments: [],
            environmentOverrides: [:],
            workingDirectory: root.path,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            durationMilliseconds: 1_000,
            outcome: .exited,
            exitCode: 0,
            relatedRunEvidenceLogs: [
                nestedEvidence.path,
                nestedEvidence.path,
                unsafeEvidenceLink.path
            ],
            terminationSignal: nil,
            rawWaitStatus: 0,
            didTimeOut: false,
            waitedForExit: true,
            processIdentifier: 1234,
            stdoutLog: primaryStdout.path,
            stderrLog: primaryStderr.path,
            processObservationLog: primaryObservation.path,
            diagnosticLog: primaryDiagnostics.path,
            captureError: nil
        )
        let evidenceEncoder = JSONEncoder()
        evidenceEncoder.dateEncodingStrategy = .iso8601
        try evidenceEncoder.encode(nestedDocument).write(to: nestedEvidence)
        try evidenceEncoder.encode(primaryDocument).write(to: primaryEvidence)

        let launchRecord = LaunchRecord(
            id: "launch-record-related-run-expansion",
            gameId: "1245620",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 102),
            exitCode: 0,
            status: "completed",
            relatedRunEvidencePaths: [primaryEvidence.path]
        )
        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            launchRecords: [launchRecord]
        )

        try unzip(archive, to: extracted)
        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for marker in [
            "EXPANDED-PRIMARY-STDOUT",
            "EXPANDED-PRIMARY-STDERR",
            "EXPANDED-PRIMARY-OBSERVATION",
            "EXPANDED-PRIMARY-DIAGNOSTICS",
            "EXPANDED-NESTED-STDOUT"
        ] {
            XCTAssertEqual(
                combinedText.components(separatedBy: marker).count - 1,
                1,
                "expected one safely expanded copy of \(marker)"
            )
        }
        XCTAssertFalse(combinedText.contains("UNSAFE-EXTERNAL-EVIDENCE"), combinedText)
        XCTAssertFalse(combinedText.contains("UNSAFE-EXTERNAL-OBSERVATION"), combinedText)

        let manifest = try manifestObject(under: extracted)
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        XCTAssertTrue(included.contains {
            $0["runIdentifier"] as? String == nestedRunID &&
                $0["artifactRole"] as? String == "processRunMetadata"
        }, "\(included)")
        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        XCTAssertTrue(skipped.contains { $0["reason"] as? String == "symbolicLink" }, "\(skipped)")
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains {
            $0["component"] as? String == "launchArtifact.runEvidenceExpansion"
        }, "\(issues)")
        let limits = try XCTUnwrap(manifest["limits"] as? [String: Any])
        XCTAssertEqual(limits["maxProcessRunEvidenceDocuments"] as? Int, 256)
        XCTAssertEqual(
            (limits["maxProcessRunEvidenceDiscoveryBytes"] as? NSNumber)?.int64Value,
            8 * 1024 * 1024
        )
    }

    func testSupportBundleRetainsLargeLogHeadAndTailWithTruncationMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let largeLog = try pathManager.url(for: .launchLogs)
            .appending(path: "2026-07-15_12-00-00_game_launch_\(runID)_stderr.log")
        var source = Data("LARGE-HEAD-MARKER\n".utf8)
        source.append(Data(repeating: UInt8(ascii: "x"), count: (2 * 1024 * 1024) + 257))
        source.append(Data("\nLARGE-TAIL-MARKER".utf8))
        try source.write(to: largeLog)

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let artifact = try XCTUnwrap(included.first {
            $0["runIdentifier"] as? String == runID && $0["artifactRole"] as? String == "stderr"
        })
        let archiveEntry = try XCTUnwrap(artifact["archiveEntry"] as? String)
        let copiedFile = try file(forArchiveEntry: archiveEntry, under: extracted)
        let copiedText = try String(contentsOf: copiedFile, encoding: .utf8)

        XCTAssertEqual(artifact["truncated"] as? Bool, true)
        XCTAssertEqual((artifact["originalByteCount"] as? NSNumber)?.intValue, source.count)
        XCTAssertEqual(artifact["sourceEncoding"] as? String, "utf-8")
        XCTAssertTrue(copiedText.contains("LARGE-HEAD-MARKER"), String(copiedText.prefix(500)))
        XCTAssertTrue(copiedText.contains("source truncated; original_bytes=\(source.count)"))
        XCTAssertTrue(copiedText.contains("LARGE-TAIL-MARKER"), String(copiedText.suffix(500)))
    }

    func testSupportBundlePrioritizesNewestFailedLaunchArtifactsBeyondBroadScanLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        for index in 0..<5_050 {
            try FileManager.default.createDirectory(
                at: launchLogs.appending(
                    path: String(format: "000-old-item-%05d", index),
                    directoryHint: .isDirectory
                ),
                withIntermediateDirectories: false
            )
        }

        let newestDirectory = launchLogs.appending(
            path: "zzzz-newest-failed-launch",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: newestDirectory, withIntermediateDirectories: false)
        let runID = "abababab-cdcd-efef-1212-343434343434"
        let stem = "2026-07-16_00-30-00_game_launch_\(runID)"
        let stdout = newestDirectory.appending(path: "\(stem)_stdout.log")
        let stderr = newestDirectory.appending(path: "\(stem)_stderr.log")
        let diagnostics = newestDirectory.appending(path: "\(stem)_stderr.diagnostics.log")
        let processObservation = newestDirectory.appending(path: "\(stem)_process-observation.txt")
        let runEvidence = newestDirectory.appending(path: "\(stem)_stderr.run.json")
        let rendererDirectory = launchLogs.appending(
            path: "GameRuns/\(runID)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rendererDirectory,
            withIntermediateDirectories: true
        )
        let rendererLog = rendererDirectory.appending(path: "game_d3d11.log")
        try "priority-newest-stdout".write(to: stdout, atomically: true, encoding: .utf8)
        try "priority-newest-stderr exit=91".write(to: stderr, atomically: true, encoding: .utf8)
        try "priority-newest-diagnostics".write(to: diagnostics, atomically: true, encoding: .utf8)
        try "priority-newest-process-observation".write(
            to: processObservation,
            atomically: true,
            encoding: .utf8
        )
        try """
        {"runIdentifier":"\(runID)","outcome":"failed"}
        """.write(to: runEvidence, atomically: true, encoding: .utf8)
        try "priority-renderer-device-lost".write(
            to: rendererLog,
            atomically: true,
            encoding: .utf8
        )
        let newestModificationDate = Date(timeIntervalSinceNow: 3_600)
        for artifact in [stdout, stderr, diagnostics, processObservation, runEvidence, rendererLog] {
            try FileManager.default.setAttributes(
                [.modificationDate: newestModificationDate],
                ofItemAtPath: artifact.path
            )
        }

        let launchRecord = LaunchRecord(
            id: "launch-record-beyond-scan-limit",
            gameId: "1245620",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchGame",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_005),
            exitCode: 91,
            stdoutPath: stdout.path,
            stderrPath: stderr.path,
            diagnosticLogPath: diagnostics.path,
            status: "failed"
        )
        launchRecord.processObservationPath = processObservation.path
        launchRecord.runEvidencePath = runEvidence.path

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            launchRecords: [launchRecord]
        )

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let limits = try XCTUnwrap(manifest["limits"] as? [String: Any])
        XCTAssertEqual(limits["maxPrioritizedGameRunScannedItems"] as? Int, 5_000)
        let launches = try XCTUnwrap(manifest["launches"] as? [[String: Any]])
        let launch = try XCTUnwrap(launches.first)
        let references = try XCTUnwrap(launch["artifactReferences"] as? [String: String])
        XCTAssertEqual(
            Set(references.keys),
            ["stdout", "stderr", "diagnostics", "processObservation", "processRunMetadata"]
        )
        XCTAssertEqual((launch["missingArtifactRoles"] as? [String]) ?? [], [])
        for entry in references.values {
            XCTAssertNoThrow(try file(forArchiveEntry: entry, under: extracted), entry)
        }

        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let runArtifacts = included.filter { $0["runIdentifier"] as? String == runID }
        XCTAssertEqual(runArtifacts.count, 6, "\(runArtifacts)")
        XCTAssertEqual(
            Set(runArtifacts.compactMap { $0["artifactRole"] as? String }),
            [
                "stdout",
                "stderr",
                "diagnostics",
                "processObservation",
                "processRunMetadata",
                "rendererLog",
            ]
        )
        let rendererArtifact = try XCTUnwrap(runArtifacts.first {
            $0["artifactRole"] as? String == "rendererLog"
        })
        let rendererArchiveEntry = try XCTUnwrap(rendererArtifact["archiveEntry"] as? String)
        let copiedRendererLog = try file(forArchiveEntry: rendererArchiveEntry, under: extracted)
        XCTAssertEqual(
            try String(contentsOf: copiedRendererLog, encoding: .utf8),
            "priority-renderer-device-lost"
        )
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains {
            $0["component"] as? String == "scan" &&
                ($0["message"] as? String)?.contains("configured item limit") == true
        }, "\(issues)")
    }

    func testSupportBundleIncludesAllowlistedSteamLateEvidenceWithAnonymousArchiveNames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamLogs = SteamClientCompatibilityProfileContract
            .steamDirectory(in: prefix)
            .appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        let evidence: [String: String] = [
            "gameprocess_log.txt": "AppID 1245620 process started; process exited with code 77; token=late-secret",
            "content_log.txt": "AppID 1245620 build 987654 content state fully installed",
            "shader_log.txt": "shader pipeline creation failed for AppID 1245620",
            "console_log.txt": "console late marker",
            "bootstrap_log.txt": "bootstrap late marker"
        ]
        for (name, text) in evidence {
            try text.write(
                to: steamLogs.appending(path: name),
                atomically: true,
                encoding: .utf8
            )
        }
        try "not allowlisted and must not be collected".write(
            to: steamLogs.appending(path: "account_history.txt"),
            atomically: true,
            encoding: .utf8
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let lateArtifacts = included.filter { $0["sourceCategory"] as? String == "steamLateEvidence" }
        let logArtifacts = lateArtifacts.filter {
            ($0["artifactRole"] as? String)?.hasSuffix("Log") == true
        }
        let expectedRoles: Set<String> = [
            "steamGameProcessLog",
            "steamContentLog",
            "steamShaderLog",
            "steamConsoleLog",
            "steamBootstrapLog"
        ]
        XCTAssertEqual(Set(logArtifacts.compactMap { $0["artifactRole"] as? String }), expectedRoles)

        let archiveEntries = try logArtifacts.map { try XCTUnwrap($0["archiveEntry"] as? String) }
        XCTAssertTrue(archiveEntries.allSatisfy {
            $0.hasPrefix("redacted-logs/steam-late-evidence/steam-late-") && $0.hasSuffix(".log")
        }, "\(archiveEntries)")
        for originalName in evidence.keys {
            XCTAssertFalse(archiveEntries.contains { $0.contains(originalName) }, "\(archiveEntries)")
        }

        let lateText = try archiveEntries.map {
            try String(contentsOf: file(forArchiveEntry: $0, under: extracted), encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertTrue(lateText.contains("AppID 1245620"), lateText)
        XCTAssertTrue(lateText.contains("process exited with code 77"), lateText)
        XCTAssertTrue(lateText.contains("build 987654"), lateText)
        XCTAssertFalse(lateText.contains("late-secret"), lateText)
        XCTAssertFalse(lateText.contains("not allowlisted"), lateText)

        let status = try XCTUnwrap(manifest["steamLateEvidence"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "collected")
        XCTAssertEqual(status["logsDirectoryState"] as? String, "available")
        XCTAssertEqual(Set(status["includedLogRoles"] as? [String] ?? []), expectedRoles)
        XCTAssertTrue((status["missingOptionalLogRoles"] as? [String])?.contains("steamWebHelperLog") == true)
    }

    func testSupportBundleCapturesUTF16AndLossyTextWithExplicitEncodingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let utf16Log = launchLogs.appending(path: "a-utf16.log")
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append(try XCTUnwrap("UTF16-EVIDENCE-MARKER".data(using: .utf16LittleEndian)))
        try utf16Data.write(to: utf16Log)
        let lossyLog = launchLogs.appending(path: "b-lossy.log")
        try Data(Array("LOSSY-START ".utf8) + [0xFF] + Array(" LOSSY-END".utf8)).write(to: lossyLog)

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let utf16Artifact = try XCTUnwrap(included.first {
            $0["sourceCategory"] as? String == "logs" &&
                $0["sourceEncoding"] as? String == "utf-16le"
        }, "Included artifacts: \(included)")
        let lossyArtifact = try XCTUnwrap(included.first {
            $0["sourceCategory"] as? String == "logs" &&
                $0["sourceEncoding"] as? String == "utf-8-lossy"
        }, "Included artifacts: \(included)")
        let utf16Entry = try XCTUnwrap(utf16Artifact["archiveEntry"] as? String)
        let lossyEntry = try XCTUnwrap(lossyArtifact["archiveEntry"] as? String)
        let utf16Text = try String(
            contentsOf: file(forArchiveEntry: utf16Entry, under: extracted),
            encoding: .utf8
        )
        let lossyText = try String(
            contentsOf: file(forArchiveEntry: lossyEntry, under: extracted),
            encoding: .utf8
        )

        XCTAssertTrue(utf16Text.contains("UTF16-EVIDENCE-MARKER"), utf16Text)
        XCTAssertTrue(lossyText.contains("LOSSY-START"), lossyText)
        XCTAssertTrue(lossyText.contains("LOSSY-END"), lossyText)
        XCTAssertTrue(
            (lossyArtifact["contentKind"] as? String)?.contains("lossyDecode") == true,
            "\(lossyArtifact)"
        )
    }

    func testSupportBundleReportsMissingOptionalSteamLateLogsWithoutTreatingThemAsReadFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let status = try XCTUnwrap(manifest["steamLateEvidence"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "notAvailable")
        XCTAssertEqual(status["logsDirectoryState"] as? String, "notPresent")
        XCTAssertEqual(status["dumpsDirectoryState"] as? String, "notPresent")
        XCTAssertEqual((status["includedLogRoles"] as? [String]) ?? [], [])
        XCTAssertTrue((status["missingOptionalLogRoles"] as? [String])?.contains("steamGameProcessLog") == true)

        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        XCTAssertFalse(skipped.contains { $0["sourceCategory"] as? String == "steamLateEvidence" })
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertFalse(issues.contains {
            ($0["component"] as? String)?.hasPrefix("steamLateEvidence") == true
        }, "\(issues)")
    }

    func testSupportBundleCapsSteamStoragePathInputsAndRecordsPartialCollection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let storagePaths = (0..<140).map {
            root.appending(path: "SteamStorage-\($0)", directoryHint: .isDirectory).path
        }
        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            steamStoragePaths: storagePaths
        )

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let limits = try XCTUnwrap(manifest["limits"] as? [String: Any])
        let maximumStoragePaths = try XCTUnwrap(limits["maxSteamStoragePaths"] as? Int)
        XCTAssertEqual(maximumStoragePaths, 128)
        let environment = try XCTUnwrap(manifest["environment"] as? [String: Any])
        let volumes = try XCTUnwrap(environment["volumes"] as? [[String: Any]])
        XCTAssertEqual(volumes.filter {
            ($0["role"] as? String)?.hasPrefix("steamStorage") == true
        }.count, maximumStoragePaths)
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["component"] as? String == "steamStoragePaths" })
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
    }

    func testSupportBundleRecordsPNGScreenEvidenceAsPrivacyExclusion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runID = "99999999-8888-7777-6666-555555555555"
        let evidenceDirectory = try pathManager.url(for: .launchLogs).appending(
            path: "2026-07-15_12-00-00_steam_launch_\(runID)_stderr.diagnostics.diagnostics",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let screenshot = evidenceDirectory.appending(path: "screen-final.png")
        try Data("private-screen-evidence-payload".utf8).write(to: screenshot)

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        let exclusion = try XCTUnwrap(skipped.first {
            $0["runIdentifier"] as? String == runID &&
                $0["artifactRole"] as? String == "screenEvidence"
        })
        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertEqual(exclusion["reason"] as? String, "imageEvidenceExcludedForPrivacy")
        XCTAssertFalse(files.contains { $0.lastPathComponent == "screen-final.png" })
        XCTAssertFalse(combinedText.contains("private-screen-evidence-payload"), combinedText)
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
    }

    func testSupportBundleExcludesRawScreenOCRTextForPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runID = "12121212-3434-5656-7878-909090909090"
        let evidenceDirectory = try pathManager.url(for: .launchLogs).appending(
            path: "2026-07-16_01-00-00_steam_launch_\(runID)_stderr.diagnostics.diagnostics",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let rawOCR = evidenceDirectory.appending(path: "screen-ocr.txt")
        try "OCR-PRIVATE account gamer@example.com friend-list SecretFriend library SecretGame".write(
            to: rawOCR,
            atomically: true,
            encoding: .utf8
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        let exclusion = try XCTUnwrap(skipped.first {
            $0["runIdentifier"] as? String == runID &&
                $0["artifactRole"] as? String == "screenOCR"
        })
        XCTAssertEqual(exclusion["reason"] as? String, "screenOCRExcludedForPrivacy")

        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(combinedText.contains("OCR-PRIVATE"), combinedText)
        XCTAssertFalse(combinedText.contains("SecretFriend"), combinedText)
        XCTAssertFalse(combinedText.contains("SecretGame"), combinedText)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "screen-ocr.txt" })
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
    }

    func testSupportBundleExcludesSteamDumpBinariesAndIncludesRedactedBoundedInventory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dumps = SteamClientCompatibilityProfileContract
            .steamDirectory(in: prefix)
            .appending(path: "dumps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        let privateDumpName = "crash_jane@example.com.dmp"
        let privatePayload = Data("PRIVATE-MINIDUMP-PAYLOAD".utf8)
        let privateDump = dumps.appending(path: privateDumpName)
        try privatePayload.write(to: privateDump)
        let assertDumpName = "assert_steam_1245620.mdmp"
        let assertPayload = Data("PRIVATE-ASSERT-DUMP-PAYLOAD".utf8)
        let assertDump = dumps.appending(path: assertDumpName)
        try assertPayload.write(to: assertDump)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: privateDump.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: assertDump.path
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let inventoryArtifact = try XCTUnwrap(included.first {
            $0["sourceCategory"] as? String == "steamLateEvidence" &&
                $0["artifactRole"] as? String == "steamDumpInventory"
        })
        let inventoryEntry = try XCTUnwrap(inventoryArtifact["archiveEntry"] as? String)
        XCTAssertTrue(inventoryEntry.hasPrefix("redacted-logs/steam-late-evidence/steam-late-"))
        XCTAssertTrue(inventoryEntry.hasSuffix(".json"))
        XCTAssertFalse(inventoryEntry.contains(privateDumpName))
        XCTAssertFalse(inventoryEntry.contains(assertDumpName))

        let inventoryURL = try file(forArchiveEntry: inventoryEntry, under: extracted)
        let inventoryData = try Data(contentsOf: inventoryURL)
        let inventory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: inventoryData) as? [String: Any]
        )
        let items = try XCTUnwrap(inventory["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let firstItem = try XCTUnwrap(items.first)
        XCTAssertEqual(Set(firstItem.keys), Set([
            "anonymousDumpIdentifier",
            "filenameSHA256",
            "byteCount",
            "modifiedAt",
            "fileExtension",
        ]))
        XCTAssertEqual(inventory["observedDumpCount"] as? Int, 2)
        XCTAssertEqual(inventory["retainedDumpCount"] as? Int, 2)
        XCTAssertEqual(items.first?["fileExtension"] as? String, "dmp")
        XCTAssertEqual((items.first?["byteCount"] as? NSNumber)?.intValue, privatePayload.count)
        XCTAssertNotNil(items.first?["modifiedAt"] as? String)
        XCTAssertEqual(
            items.first?["filenameSHA256"] as? String,
            SHA256.hash(data: Data(privateDumpName.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        )
        XCTAssertNil(items.first?["redactedFilename"])

        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        let excludedDumps = skipped.filter {
            $0["sourceCategory"] as? String == "steamLateEvidence" &&
                $0["artifactRole"] as? String == "steamDumpBinary"
        }
        XCTAssertEqual(excludedDumps.count, 2)
        XCTAssertTrue(excludedDumps.allSatisfy {
            $0["reason"] as? String == "binaryCrashEvidenceExcludedWithMetadataInventory"
        })

        let files = try allFiles(under: extracted)
        XCTAssertFalse(files.contains { ["dmp", "mdmp"].contains($0.pathExtension.lowercased()) })
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(combinedText.contains("PRIVATE-MINIDUMP-PAYLOAD"), combinedText)
        XCTAssertFalse(combinedText.contains("PRIVATE-ASSERT-DUMP-PAYLOAD"), combinedText)
        XCTAssertFalse(combinedText.contains("jane@example.com"), combinedText)
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")

        let status = try XCTUnwrap(manifest["steamLateEvidence"] as? [String: Any])
        XCTAssertEqual(status["dumpsDirectoryState"] as? String, "available")
        XCTAssertEqual(status["observedDumpCount"] as? Int, 2)
        XCTAssertEqual(status["retainedDumpCount"] as? Int, 2)
        XCTAssertEqual(status["dumpInventoryArchiveEntry"] as? String, inventoryEntry)
    }

    func testSupportBundleRecordsUnsafeAndUnreadableSteamLateLogsWithoutFollowingThem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamLate-\(UUID().uuidString).txt")
        var unreadableLog: URL?
        defer {
            if let unreadableLog {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: unreadableLog.path
                )
            }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
            try? FileManager.default.removeItem(at: external)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamLogs = SteamClientCompatibilityProfileContract
            .steamDirectory(in: prefix)
            .appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try "external-steam-late-secret".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: steamLogs.appending(path: "gameprocess_log.txt"),
            withDestinationURL: external
        )
        let unreadable = steamLogs.appending(path: "content_log.txt")
        unreadableLog = unreadable
        try "unreadable-steam-late-secret".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let skipped = try XCTUnwrap(manifest["skippedFiles"] as? [[String: Any]])
        XCTAssertTrue(skipped.contains {
            $0["sourceCategory"] as? String == "steamLateEvidence" &&
                $0["artifactRole"] as? String == "steamGameProcessLog" &&
                $0["reason"] as? String == "symbolicLink"
        }, "\(skipped)")
        XCTAssertTrue(skipped.contains {
            $0["sourceCategory"] as? String == "steamLateEvidence" &&
                $0["artifactRole"] as? String == "steamContentLog" &&
                $0["reason"] as? String == "readFailed"
        }, "\(skipped)")
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains {
            $0["component"] as? String == "artifactRead" &&
                $0["anonymousSourceIdentifier"] as? String == "steam-late-000002"
        }, "\(issues)")
        let status = try XCTUnwrap(manifest["steamLateEvidence"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "partial")
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")

        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(combinedText.contains("external-steam-late-secret"), combinedText)
        XCTAssertFalse(combinedText.contains("unreadable-steam-late-secret"), combinedText)
    }

    func testSupportBundleDoesNotTraverseSymlinkSteamLogsDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLogs = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamLogs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
            try? FileManager.default.removeItem(at: externalLogs)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamDirectory = SteamClientCompatibilityProfileContract.steamDirectory(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalLogs, withIntermediateDirectories: true)
        try "symlink-directory-private-gameprocess".write(
            to: externalLogs.appending(path: "gameprocess_log.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: steamDirectory.appending(path: "logs", directoryHint: .isDirectory),
            withDestinationURL: externalLogs
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let status = try XCTUnwrap(manifest["steamLateEvidence"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "partial")
        XCTAssertEqual(status["logsDirectoryState"] as? String, "unsafe")
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["component"] as? String == "steamLateEvidence.scan" })

        let files = try allFiles(under: extracted)
        let combinedText = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(combinedText.contains("symlink-directory-private-gameprocess"), combinedText)
    }

    func testSupportBundleCapsCollectionIssuesWithExplicitLimitMarker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            if FileManager.default.fileExists(atPath: extracted.path) {
                try? FileManager.default.removeItem(at: extracted)
            }
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        for index in 0..<1_005 {
            try "{invalid-json-\(index)".write(
                to: launchLogs.appending(path: String(format: "invalid-%04d.json", index)),
                atomically: true,
                encoding: .utf8
            )
        }

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let limits = try XCTUnwrap(manifest["limits"] as? [String: Any])
        let maximumIssues = try XCTUnwrap(limits["maxCollectionIssues"] as? Int)
        let issues = try XCTUnwrap(manifest["collectionIssues"] as? [[String: Any]])
        XCTAssertEqual(issues.count, maximumIssues)
        XCTAssertEqual(issues.last?["component"] as? String, "collectionIssues.limit")
        XCTAssertEqual(manifest["collectionStatus"] as? String, "partial")
        let includedFiles = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])
        let invalidJSONFallbacks = includedFiles.filter {
            ($0["contentKind"] as? String)?.hasPrefix("redactedTextWithInvalidJSONSource") == true
        }
        XCTAssertFalse(invalidJSONFallbacks.isEmpty)
        XCTAssertTrue(invalidJSONFallbacks.allSatisfy {
            ($0["archiveEntry"] as? String)?.hasSuffix(".txt") == true
        })
    }

    func testSupportBundleManifestHashesAndSizesMatchEveryDeclaredArchiveEntry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let log = try pathManager.url(for: .launchLogs).appending(path: "hash-verification.log")
        try "hash-verification-evidence".write(to: log, atomically: true, encoding: .utf8)
        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(diagnostics: [], checks: [])

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let included = try XCTUnwrap(manifest["includedFiles"] as? [[String: Any]])

        XCTAssertEqual(manifest["schemaVersion"] as? Int, 3)
        XCTAssertEqual(manifest["manifestSelfHashExcluded"] as? Bool, true)
        XCTAssertFalse(included.isEmpty)
        for entry in included {
            let archiveEntry = try XCTUnwrap(entry["archiveEntry"] as? String)
            let expectedHash = try XCTUnwrap(entry["sha256"] as? String)
            let expectedSize = try XCTUnwrap(entry["byteCount"] as? NSNumber).intValue
            let file = try file(forArchiveEntry: archiveEntry, under: extracted)
            let data = try Data(contentsOf: file)
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            XCTAssertEqual(data.count, expectedSize, archiveEntry)
            XCTAssertEqual(actualHash, expectedHash, archiveEntry)
        }
        let archivedText = try allFiles(under: extracted)
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(archivedText.contains("external-private-log-payload"), archivedText)
    }

    func testSupportBundlePersistsIncidentContextAndLaunchLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleIncidentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extracted = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySupportBundleIncidentExtracted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extracted)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launch = LaunchRecord(
            id: "launch-incident-test",
            gameId: "1245620",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_020),
            exitCode: 1,
            status: "failed",
            gameName: "Incident Test Game"
        )
        let incident = SupportIncidentContext(
            incidentIdentifier: "incident-test",
            launchRecordIdentifier: launch.id,
            steamAppID: launch.gameId,
            gameName: launch.gameName,
            occurredAt: launch.startedAt,
            expectedResult: "The game opens.",
            actualSymptoms: "Black screen. Authorization: Bearer incident-secret-token",
            reproductionSteps: "1. Open Steam\n2. Start the game",
            userNotes: "Happens every time."
        )

        let archive = try await SupportBundleService(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            redactor: Redactor()
        ).createSupportBundle(
            diagnostics: [],
            checks: [],
            launchRecords: [launch],
            incident: incident
        )

        try unzip(archive, to: extracted)
        let manifest = try manifestObject(under: extracted)
        let persistedIncident = try XCTUnwrap(manifest["incident"] as? [String: Any])
        XCTAssertEqual(persistedIncident["incidentIdentifier"] as? String, "incident-test")
        XCTAssertEqual(persistedIncident["launchRecordIdentifier"] as? String, launch.id)
        XCTAssertEqual(persistedIncident["launchRecordIncluded"] as? Bool, true)
        XCTAssertEqual(persistedIncident["steamAppID"] as? String, launch.gameId)

        let combinedText = try allFiles(under: extracted)
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(combinedText.contains("## Reported incident"))
        XCTAssertTrue(combinedText.contains("launch-incident-test"))
        XCTAssertFalse(combinedText.contains("incident-secret-token"))
    }

    func testEmergencySupportBundleDoesNotRequireManagedRootAndRedactsErrorChain() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayEmergencySupportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let underlying = NSError(
            domain: "EmergencyUnderlying",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "password=emergency-private-secret"]
        )
        let error = NSError(
            domain: "EmergencyTopLevel",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Authorization: Bearer emergency-secret-token",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let report = try EmergencySupportBundleService(
            destinationDirectory: root.appending(path: "reports", directoryHint: .isDirectory)
        ).createBundle(for: error, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try Data(contentsOf: report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["application"] as? [String: Any])
        XCTAssertNotNil(object["host"] as? [String: Any])
        XCTAssertFalse((object["disks"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual((object["errorChain"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(
            (object["bootstrap"] as? [String: Any])?["phase"] as? String,
            "swiftDataModelContainerInitialization"
        )
        XCTAssertFalse(text.contains("emergency-secret-token"))
        XCTAssertFalse(text.contains("emergency-private-secret"))
    }

    private func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func allFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true ? nil : url
        }
    }

    private func manifestObject(under extractedRoot: URL) throws -> [String: Any] {
        let manifestURL = try XCTUnwrap(
            allFiles(under: extractedRoot).first { $0.lastPathComponent == "bundle-manifest.json" }
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
    }

    private func file(forArchiveEntry archiveEntry: String, under extractedRoot: URL) throws -> URL {
        let suffix = archiveEntry.hasPrefix("/") ? archiveEntry : "/\(archiveEntry)"
        return try XCTUnwrap(
            allFiles(under: extractedRoot).first { $0.path.hasSuffix(suffix) },
            "Missing declared archive entry: \(archiveEntry)"
        )
    }

    private func anonymousPayloadEntryNames(under root: URL) throws -> [String] {
        try allFiles(under: root)
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("log-") || $0.hasPrefix("prefix-") }
            .sorted()
    }
}
