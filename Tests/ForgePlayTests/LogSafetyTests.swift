import Darwin
import XCTest
@testable import ForgePlay

@MainActor
final class LogSafetyTests: XCTestCase {
    func testLogTextReaderRejectsSymlinkLogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLog-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "secret outside log".write(to: externalLog, atomically: true, encoding: .utf8)
        let linkedLog = root.appending(path: "linked.log")
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: externalLog)

        XCTAssertThrowsError(try LogTextReader.trailingText(from: linkedLog)) { error in
            guard case LogTextReaderError.unsafeLogFile(let url) = error else {
                return XCTFail("Expected unsafeLogFile, got \(error)")
            }
            XCTAssertEqual(url.path, linkedLog.path)
        }
    }

    func testStrictCombinedLogTextSurfacesUnsafeLogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayStrictCombinedLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLog-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "external secret".write(to: externalLog, atomically: true, encoding: .utf8)
        let linkedLog = root.appending(path: "linked.log")
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: externalLog)

        XCTAssertThrowsError(try LogTextReader.combinedTrailingTextStrict(from: [linkedLog])) { error in
            guard case LogTextReaderError.unsafeLogFile(let url) = error else {
                return XCTFail("Expected unsafeLogFile, got \(error)")
            }
            XCTAssertEqual(url.path, linkedLog.path)
        }
    }

    func testLogTextReaderRejectsHardlinkedLogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalHardlink-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hardlinked outside log".write(to: externalLog, atomically: true, encoding: .utf8)
        let hardlinkedLog = root.appending(path: "hardlinked.log")
        try FileManager.default.linkItem(at: externalLog, to: hardlinkedLog)

        XCTAssertThrowsError(try LogTextReader.trailingText(from: hardlinkedLog)) { error in
            guard case LogTextReaderError.unsafeLogFile(let url) = error else {
                return XCTFail("Expected unsafeLogFile, got \(error)")
            }
            XCTAssertEqual(url.path, hardlinkedLog.path)
        }
        XCTAssertThrowsError(try LogTextReader.combinedTrailingTextStrict(from: [hardlinkedLog])) { error in
            guard case LogTextReaderError.unsafeLogFile(let url) = error else {
                return XCTFail("Expected unsafeLogFile, got \(error)")
            }
            XCTAssertEqual(url.path, hardlinkedLog.path)
        }

        let snapshot = LogTextReader.diagnosticSnapshot(from: [hardlinkedLog])
        XCTAssertTrue(snapshot.text.isEmpty)
        guard let snapshotError = snapshot.readError as? LogTextReaderError,
              case .unsafeLogFile(let url) = snapshotError else {
            return XCTFail("Expected unsafeLogFile, got \(String(describing: snapshot.readError))")
        }
        XCTAssertEqual(url.path, hardlinkedLog.path)
    }

    func testLogTextReaderSurfacesInvalidUTF8LogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayInvalidUTF8LogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appending(path: "invalid.log")
        try Data([0xff, 0xfe, 0xfd]).write(to: log)

        XCTAssertThrowsError(try LogTextReader.trailingText(from: log)) { error in
            guard case LogTextReaderError.textDecodeFailed(let url) = error else {
                return XCTFail("Expected textDecodeFailed, got \(error)")
            }
            XCTAssertEqual(url.path, log.path)
        }
    }

    func testDiagnosticLogSnapshotSurfacesReadWarning() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDiagnosticLogSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLog-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "external secret".write(to: externalLog, atomically: true, encoding: .utf8)
        let linkedLog = root.appending(path: "linked.log")
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: externalLog)

        let snapshot = LogTextReader.diagnosticSnapshot(from: [linkedLog])

        XCTAssertTrue(snapshot.text.isEmpty)
        guard let error = snapshot.readError as? LogTextReaderError,
              case .unsafeLogFile(let url) = error else {
            return XCTFail("Expected unsafeLogFile, got \(String(describing: snapshot.readError))")
        }
        XCTAssertEqual(url.path, linkedLog.path)
        XCTAssertEqual(
            DiagnosticWarningText.combined("로그 읽기 경고", "진단 결과 저장 경고"),
            "로그 읽기 경고\n진단 결과 저장 경고"
        )
    }

    func testDiagnosticLogSnapshotSurfacesInvalidUTF8Warning() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDiagnosticInvalidUTF8SnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appending(path: "invalid.log")
        try Data([0xff, 0xfe, 0xfd]).write(to: log)

        let snapshot = LogTextReader.diagnosticSnapshot(from: [log])

        XCTAssertTrue(snapshot.text.isEmpty)
        guard let error = snapshot.readError as? LogTextReaderError,
              case .textDecodeFailed(let url) = error else {
            return XCTFail("Expected textDecodeFailed, got \(String(describing: snapshot.readError))")
        }
        XCTAssertEqual(url.path, log.path)
    }

    func testTolerantDiagnosticLogSnapshotDecodesInvalidUTF8AndReportsRecoveryWarning() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDiagnosticTolerantSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appending(path: "partial.log")
        try Data(Array("Steam update ".utf8) + [0xff] + Array(" still running".utf8)).write(to: log)

        let snapshot = LogTextReader.tolerantDiagnosticSnapshot(from: [log])

        guard let error = snapshot.readError as? LogTextReaderError,
              case .textDecodeFailed(let url) = error else {
            return XCTFail("Expected lossy decode warning, got \(String(describing: snapshot.readError))")
        }
        XCTAssertEqual(url.path, log.path)
        XCTAssertTrue(snapshot.text.contains("Steam update"), snapshot.text)
        XCTAssertTrue(snapshot.text.contains("still running"), snapshot.text)
    }

    func testTolerantDiagnosticLogSnapshotKeepsReadableEvidenceWhenAnotherArtifactIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDiagnosticPartialSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingLog = root.appending(path: "missing_stderr.log")
        let readableLog = root.appending(path: "available_stdout.log")
        try "renderer initialization failed at launch stage".write(
            to: readableLog,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = LogTextReader.tolerantDiagnosticSnapshot(from: [missingLog, readableLog])

        XCTAssertTrue(snapshot.text.contains("available_stdout.log"), snapshot.text)
        XCTAssertTrue(snapshot.text.contains("renderer initialization failed"), snapshot.text)
        XCTAssertNotNil(snapshot.readError)
    }

    func testDiagnosticLogSnapshotPreservesForgePlayHeaderForLargeDiagnosticsLog() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDiagnosticLargeSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appending(path: "steam_launch_stderr.diagnostics.log")
        let header = """
        ForgePlay detected Windows Steam CEF/WebHelper rendering warnings after launch and marked this launch unusable. No post-failure shutdown was needed because the launch command had already returned.
        Interpreted findings:
        - Windows Steam CEF login UI was created while WebHelper GPU initialization reported the black-window signature. ForgePlay records this as rendering evidence and treats the visible Steam window as unusable.
        """
        let filler = String(repeating: "raw cef line\n", count: 5_000)
        let tail = "tail marker: eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED"
        try "\(header)\n\(filler)\n\(tail)".write(to: log, atomically: true, encoding: .utf8)

        let snapshot = LogTextReader.diagnosticSnapshot(from: [log], maxBytesPerFile: 1_200)
        let results = RuleEngine().analyze(logText: snapshot.text, context: .setupOrInstaller)

        XCTAssertNil(snapshot.readError)
        XCTAssertTrue(snapshot.text.contains("CEF/WebHelper rendering warnings after launch"))
        XCTAssertTrue(snapshot.text.contains("diagnostics log middle truncated"))
        XCTAssertTrue(snapshot.text.contains("tail marker"))
        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            results.first?.userMessage,
            "Windows용 Steam 창이 열렸지만 검은 화면으로만 렌더링되고 있습니다."
        )
    }

    func testRecentLogFilesSurfacesHardlinkedLogsAsUnsafeEvidence() throws {
        let logsRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRecentLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalHardlink-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: logsRoot)
            try? FileManager.default.removeItem(at: externalLog)
        }

        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        let safeLog = logsRoot.appending(path: "safe.log")
        try "safe log".write(to: safeLog, atomically: true, encoding: .utf8)
        try "hardlinked outside log".write(to: externalLog, atomically: true, encoding: .utf8)
        let hardlinkedLog = logsRoot.appending(path: "hardlinked.log")
        try FileManager.default.linkItem(at: externalLog, to: hardlinkedLog)

        XCTAssertThrowsError(
            try LogTextReader.recentLogFiles(under: logsRoot, maxFiles: 8)
        ) { error in
            guard case LogTextReaderError.unsafeLogFile(let url) = error else {
                return XCTFail("Expected unsafeLogFile, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, hardlinkedLog.standardizedFileURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeLog.path))
    }

    func testMostRecentRunLogFilesDoesNotMixDifferentExecutions() throws {
        let logsRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRecentRunLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: logsRoot) }
        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)

        let oldRunID = UUID().uuidString
        let recentRunID = UUID().uuidString
        let oldStdout = logsRoot.appending(path: "2026-07-15_10-00-00_steam_launch_\(oldRunID)_stdout.log")
        let oldStderr = logsRoot.appending(path: "2026-07-15_10-00-00_steam_launch_\(oldRunID)_stderr.log")
        let recentStdout = logsRoot.appending(path: "2026-07-15_11-00-00_steam_launch_\(recentRunID)_stdout.log")
        let recentStderr = logsRoot.appending(path: "2026-07-15_11-00-00_steam_launch_\(recentRunID)_stderr.log")
        for url in [oldStdout, oldStderr, recentStdout, recentStderr] {
            try url.lastPathComponent.write(to: url, atomically: true, encoding: .utf8)
        }
        let oldDate = Date(timeIntervalSince1970: 100)
        let recentDate = Date(timeIntervalSince1970: 200)
        for url in [oldStdout, oldStderr] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        for url in [recentStdout, recentStderr] {
            try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: url.path)
        }

        let selected = try LogTextReader.mostRecentRunLogFiles(under: logsRoot, maxFiles: 8)

        XCTAssertEqual(Set(selected.map(\.lastPathComponent)), Set([recentStdout.lastPathComponent, recentStderr.lastPathComponent]))
        XCTAssertFalse(selected.contains(oldStdout))
        XCTAssertFalse(selected.contains(oldStderr))
    }

    func testRecentLogFilesSurfacesUnreadableLogDirectory() throws {
        let logsRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRecentLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let unreadableDirectory = logsRoot.appending(path: "Locked", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path)
            try? FileManager.default.removeItem(at: logsRoot)
        }

        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try "safe log".write(to: logsRoot.appending(path: "safe.log"), atomically: true, encoding: .utf8)
        try "locked log".write(to: unreadableDirectory.appending(path: "locked.log"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectory.path)

        XCTAssertThrowsError(try LogTextReader.recentLogFiles(under: logsRoot)) { error in
            guard case LogTextReaderError.scanFailed(let url, _) = error else {
                return XCTFail("Expected scanFailed, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, logsRoot.standardizedFileURL.path)
        }
    }

    func testLogRetentionDoesNotRemoveSymlinkTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLog-\(UUID().uuidString).log")
        let externalDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLogDir-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
            try? FileManager.default.removeItem(at: externalDirectory)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logsRoot = try pathManager.url(for: .logs)
        let oldDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: Date()))

        let oldManagedLog = logsRoot.appending(path: "old.log")
        try "old managed log".write(to: oldManagedLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldManagedLog.path)

        try "external secret".write(to: externalLog, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: logsRoot.appending(path: "external.log"),
            withDestinationURL: externalLog
        )

        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalNestedLog = externalDirectory.appending(path: "nested.log")
        try "nested external secret".write(to: externalNestedLog, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: logsRoot.appending(path: "LinkedLogs", directoryHint: .isDirectory),
            withDestinationURL: externalDirectory
        )

        let service = LogRetentionService(pathManager: pathManager)
        let result = try service.cleanup(retentionDays: 1, launchLogLimit: 100)

        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManagedLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalNestedLog.path))
    }

    func testLogRetentionDoesNotRemoveHardlinkedLogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalHardlink-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logsRoot = try pathManager.url(for: .logs)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let oldDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: Date()))

        let oldManagedLog = logsRoot.appending(path: "old-managed.log")
        try "old managed log".write(to: oldManagedLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldManagedLog.path)

        try "external hardlinked log".write(to: externalLog, atomically: true, encoding: .utf8)
        let hardlinkedLog = launchLogs.appending(path: "hardlinked.log")
        try FileManager.default.linkItem(at: externalLog, to: hardlinkedLog)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: hardlinkedLog.path)

        let service = LogRetentionService(pathManager: pathManager)
        let result = try service.cleanup(retentionDays: 1, launchLogLimit: 1)

        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManagedLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardlinkedLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalLog.path))
    }

    func testLogRetentionBackgroundCleanupReturnsTaskAndCleansManagedLogs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logsRoot = try pathManager.url(for: .logs)
        let oldDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: Date()))

        let oldManagedLog = logsRoot.appending(path: "old-background-managed.log")
        try "old managed log".write(to: oldManagedLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldManagedLog.path)

        let currentManagedLog = logsRoot.appending(path: "current-background-managed.log")
        try "current managed log".write(to: currentManagedLog, atomically: true, encoding: .utf8)

        let service = LogRetentionService(pathManager: pathManager)
        let task = try service.cleanupInBackground(retentionDays: 1, launchLogLimit: 100)
        let result = try await task.value

        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldManagedLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentManagedLog.path))
    }

    func testLogRetentionBackgroundCleanupIsSingleFlightAndCancellationReachesWorker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionSingleFlight-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let workerStarted = expectation(description: "background log cleanup worker started")
        let service = LogRetentionService(
            pathManager: pathManager,
            backgroundCleanupOperation: { _, _, _, _, _, _ in
                workerStarted.fulfill()
                while true {
                    try Task.checkCancellation()
                    usleep(1_000)
                }
            }
        )

        let firstTask = try service.cleanupInBackground(retentionDays: 30, launchLogLimit: 20)
        await fulfillment(of: [workerStarted], timeout: 2)
        do {
            let duplicateTask = try service.cleanupInBackground(
                retentionDays: 30,
                launchLogLimit: 20
            )
            duplicateTask.cancel()
            XCTFail("Expected the duplicate cleanup to be rejected")
        } catch {
            guard case LogRetentionServiceError.cleanupInProgress = error else {
                return XCTFail("Unexpected single-flight error: \(error)")
            }
        }

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            XCTFail("Expected the background cleanup worker to observe cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cleanup cancellation error: \(error)")
        }
    }

    func testLogRetentionBackgroundCleanupHoldsManagedRootLeaseUntilWorkerCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayLogRetentionLease-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let migrationDestination = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayLogRetentionLeaseDestination-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: migrationDestination) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let workerStarted = expectation(description: "background log cleanup acquired root lease")
        let workerMayFinish = DispatchSemaphore(value: 0)
        defer { workerMayFinish.signal() }
        let service = LogRetentionService(
            pathManager: pathManager,
            backgroundCleanupOperation: { _, _, _, _, _, _ in
                workerStarted.fulfill()
                workerMayFinish.wait()
                return LogCleanupResult(removedFiles: 0, freedBytes: 0)
            }
        )

        let task = try service.cleanupInBackground(
            retentionDays: 30,
            launchLogLimit: 20
        )
        await fulfillment(of: [workerStarted], timeout: 2)

        let migrationService = StorageMigrationService(pathManager: PathManager())
        do {
            _ = try await migrationService.copyManagedDataOnly(
                from: root,
                to: migrationDestination,
                purpose: .currentRelocation
            )
            XCTFail("Expected active cleanup to block managed-root relocation")
        } catch StorageMigrationError.migrationInProgress {
            // The root transition must drain the cleanup-owned lease first.
        } catch {
            XCTFail("Unexpected relocation barrier error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrationDestination.path))

        workerMayFinish.signal()
        _ = try await task.value

        let reacquiredLease = try ManagedRootOperationLease.acquireExclusive(
            forManagedRoot: root
        )
        reacquiredLease.release()
    }

    func testLogRetentionBackgroundCleanupRejectsCapturedRootReplacement() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayLogRetentionBinding-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let root = base.appending(path: "ManagedData", directoryHint: .isDirectory)
        let movedRoot = base.appending(path: "MovedManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let workerStarted = expectation(description: "background log cleanup captured root")
        let workerMayFinish = DispatchSemaphore(value: 0)
        defer { workerMayFinish.signal() }
        let service = LogRetentionService(
            pathManager: pathManager,
            backgroundCleanupOperation: { _, _, _, _, _, _ in
                workerStarted.fulfill()
                workerMayFinish.wait()
                return LogCleanupResult(removedFiles: 0, freedBytes: 0)
            }
        )

        let task = try service.cleanupInBackground(
            retentionDays: 30,
            launchLogLimit: 20
        )
        await fulfillment(of: [workerStarted], timeout: 2)

        try FileManager.default.moveItem(at: root, to: movedRoot)
        let replacementLaunchLogs = root
            .appending(path: ForgePlayPathRole.launchLogs.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: replacementLaunchLogs,
            withIntermediateDirectories: true
        )
        let replacementLog = replacementLaunchLogs.appending(path: "must-survive.log")
        try "replacement root evidence".write(
            to: replacementLog,
            atomically: true,
            encoding: .utf8
        )

        workerMayFinish.signal()
        do {
            _ = try await task.value
            XCTFail("Expected captured managed-root identity mismatch")
        } catch LogRetentionServiceError.scanFailed(let url, _) {
            XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected captured-root validation error: \(error)")
        }
        XCTAssertEqual(
            try String(contentsOf: replacementLog, encoding: .utf8),
            "replacement root evidence"
        )
    }

    func testLogRetentionKeepsCompleteNewestLaunchLogSetAndRemovesOldEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionSets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let oldStem = "2026-07-01_10-00-00_steam_launch_11111111-1111-1111-1111-111111111111"
        let newStem = "2026-07-02_10-00-00_steam_launch_22222222-2222-2222-2222-222222222222"
        let oldEvidenceDirectory = launchLogs.appending(
            path: "\(oldStem)_stderr.diagnostics.diagnostics",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: oldEvidenceDirectory, withIntermediateDirectories: true)

        let oldArtifacts = [
            launchLogs.appending(path: "\(oldStem)_stdout.log"),
            launchLogs.appending(path: "\(oldStem)_stderr.log"),
            launchLogs.appending(path: "\(oldStem)_stderr.diagnostics.log"),
            oldEvidenceDirectory.appending(path: "index.md"),
            oldEvidenceDirectory.appending(path: "screen-final.png")
        ]
        let newArtifacts = [
            launchLogs.appending(path: "\(newStem)_stdout.log"),
            launchLogs.appending(path: "\(newStem)_stderr.log")
        ]
        let oldDate = Date().addingTimeInterval(-60)
        let newDate = Date()
        for artifact in oldArtifacts {
            try Data("old launch evidence".utf8).write(to: artifact)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: artifact.path)
        }
        for artifact in newArtifacts {
            try Data("new launch evidence".utf8).write(to: artifact)
            try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: artifact.path)
        }

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 365,
            launchLogLimit: 1
        )

        XCTAssertEqual(result.removedFiles, oldArtifacts.count)
        XCTAssertGreaterThan(result.freedBytes, 0)
        oldArtifacts.forEach { XCTAssertFalse(FileManager.default.fileExists(atPath: $0.path)) }
        newArtifacts.forEach { XCTAssertTrue(FileManager.default.fileExists(atPath: $0.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEvidenceDirectory.path))
    }

    func testLogRetentionAgesLaunchEvidenceAtomicallyUsingNewestRunArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionAtomic-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let runID = UUID().uuidString.lowercased()
        let stem = "2026-07-15_10-00-00_steam_launch_\(runID)"
        let stdout = launchLogs.appending(path: "\(stem)_stdout.log")
        let sidecar = launchLogs.appending(path: "\(stem)_stderr.run.json")
        let rendererDirectory = launchLogs.appending(
            path: "GameRuns/\(runID)",
            directoryHint: .isDirectory
        )
        let rendererLog = rendererDirectory.appending(path: "game_d3d11.log")
        try FileManager.default.createDirectory(at: rendererDirectory, withIntermediateDirectories: true)
        for artifact in [stdout, sidecar, rendererLog] {
            try Data(artifact.lastPathComponent.utf8).write(to: artifact)
        }
        let staleDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -30, to: Date()))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: stdout.path)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: sidecar.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rendererLog.path)

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 7,
            launchLogLimit: 10
        )

        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stdout.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendererLog.path))
    }

    func testLogRetentionPreservesEmptyRendererDirectoryForRetainedRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionInFlightRenderer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let retainedRunID = UUID().uuidString.lowercased()
        let staleRunID = UUID().uuidString.lowercased()
        let freshRunID = UUID().uuidString.lowercased()
        let retainedStem = "2026-07-16_10-00-00_steam_launch_\(retainedRunID)"
        let staleStem = "2026-07-15_10-00-00_steam_launch_\(staleRunID)"
        let freshStem = "2026-07-16_11-00-00_steam_launch_\(freshRunID)"
        let retainedStdout = launchLogs.appending(path: "\(retainedStem)_stdout.log")
        let retainedRendererDirectory = launchLogs.appending(
            path: "GameRuns/\(retainedRunID)",
            directoryHint: .isDirectory
        )
        let staleStdout = launchLogs.appending(path: "\(staleStem)_stdout.log")
        let staleRendererDirectory = launchLogs.appending(
            path: "GameRuns/\(staleRunID)",
            directoryHint: .isDirectory
        )
        let staleRendererLog = staleRendererDirectory.appending(path: "game_d3d11.log")
        let freshStdout = launchLogs.appending(path: "\(freshStem)_stdout.log")
        try FileManager.default.createDirectory(
            at: retainedRendererDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: staleRendererDirectory,
            withIntermediateDirectories: true
        )
        try Data("retained".utf8).write(to: retainedStdout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-180)],
            ofItemAtPath: retainedStdout.path
        )
        for artifact in [staleStdout, staleRendererLog] {
            try Data("stale".utf8).write(to: artifact)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-120)],
                ofItemAtPath: artifact.path
            )
        }
        try Data("fresh".utf8).write(to: freshStdout)

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 365,
            launchLogLimit: 1
        )

        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedStdout.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshStdout.path))
        XCTAssertTrue(
            FileSystemItemPolicy.isNonSymlinkDirectory(retainedRendererDirectory),
            "An empty in-flight renderer directory must remain available for a later game process."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRendererDirectory.path))
    }

    func testLogRetentionUnsafeUUIDArtifactsBlockDeletionOfSafeRunSiblings() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionBlockedGroups-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionBlockedExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let staleDate = Date().addingTimeInterval(-60)

        let hardlinkRunID = UUID().uuidString.lowercased()
        let symlinkRunID = UUID().uuidString.lowercased()
        let fifoRunID = UUID().uuidString.lowercased()
        let freshRunID = UUID().uuidString.lowercased()
        func stem(_ runID: String) -> String {
            "2026-07-15_10-00-00_steam_launch_\(runID)"
        }
        let safeSiblings = [hardlinkRunID, symlinkRunID, fifoRunID].map {
            launchLogs.appending(path: "\(stem($0))_stdout.log")
        }
        for sibling in safeSiblings {
            try Data("safe run sibling".utf8).write(to: sibling)
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: sibling.path
            )
        }

        let hardlinkSource = external.appending(path: "hardlink-source.log")
        try Data("external hardlink sentinel".utf8).write(to: hardlinkSource)
        let hardlinkedArtifact = launchLogs.appending(path: "\(stem(hardlinkRunID))_stderr.log")
        try FileManager.default.linkItem(at: hardlinkSource, to: hardlinkedArtifact)

        let symlinkTarget = external.appending(path: "symlink-target.log")
        try Data("external symlink sentinel".utf8).write(to: symlinkTarget)
        let symlinkedArtifact = launchLogs.appending(path: "\(stem(symlinkRunID))_stderr.log")
        try FileManager.default.createSymbolicLink(
            at: symlinkedArtifact,
            withDestinationURL: symlinkTarget
        )

        let fifoArtifact = launchLogs.appending(path: "\(stem(fifoRunID))_stderr.log")
        XCTAssertEqual(
            fifoArtifact.path.withCString {
                Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
            },
            0
        )

        let freshArtifact = launchLogs.appending(path: "\(stem(freshRunID))_stdout.log")
        try Data("fresh".utf8).write(to: freshArtifact)

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 365,
            launchLogLimit: 1
        )

        XCTAssertEqual(result.removedFiles, 0)
        safeSiblings.forEach { XCTAssertTrue(FileManager.default.fileExists(atPath: $0.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardlinkedArtifact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkedArtifact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifoArtifact.path))
        XCTAssertEqual(try String(contentsOf: hardlinkSource, encoding: .utf8), "external hardlink sentinel")
        XCTAssertEqual(try String(contentsOf: symlinkTarget, encoding: .utf8), "external symlink sentinel")
    }

    func testLogRetentionUnionsRelatedSchemaFourEvidenceAsOneRetentionUnit() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionEvidenceUnion-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let newestRunID = UUID().uuidString.lowercased()
        let relatedRunID = UUID().uuidString.lowercased()
        let removableRunID = UUID().uuidString.lowercased()
        func stem(_ runID: String) -> String {
            "2026-07-16_10-00-00_steam_launch_\(runID)"
        }
        func stdout(_ runID: String) -> URL {
            launchLogs.appending(path: "\(stem(runID))_stdout.log")
        }
        func evidence(_ runID: String) -> URL {
            launchLogs.appending(path: "\(stem(runID))_stderr.run.json")
        }

        let newestDate = Date()
        let relatedDate = newestDate.addingTimeInterval(-180)
        let removableDate = newestDate.addingTimeInterval(-60)
        for (runID, date) in [
            (newestRunID, newestDate),
            (relatedRunID, relatedDate),
            (removableRunID, removableDate)
        ] {
            try Data(runID.utf8).write(to: stdout(runID))
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: stdout(runID).path
            )
        }
        try writeRetentionEvidence(
            to: evidence(relatedRunID),
            runID: relatedRunID,
            outcome: .exited,
            relatedEvidencePaths: [],
            modificationDate: relatedDate
        )
        try writeRetentionEvidence(
            to: evidence(newestRunID),
            runID: newestRunID,
            outcome: .exited,
            relatedEvidencePaths: [evidence(relatedRunID).path],
            modificationDate: newestDate
        )
        try writeRetentionEvidence(
            to: evidence(removableRunID),
            runID: removableRunID,
            outcome: .exited,
            relatedEvidencePaths: [],
            modificationDate: removableDate
        )

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 365,
            launchLogLimit: 1
        )

        XCTAssertEqual(result.removedFiles, 2)
        for runID in [newestRunID, relatedRunID] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stdout(runID).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence(runID).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stdout(removableRunID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidence(removableRunID).path))
    }

    func testLogRetentionPropagatesUnknownExtensionBlockerAcrossRelatedEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionEvidenceBlocker-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let firstRunID = UUID().uuidString.lowercased()
        let blockedRunID = UUID().uuidString.lowercased()
        let freshRunID = UUID().uuidString.lowercased()
        func stem(_ runID: String) -> String {
            "2026-07-16_10-00-00_steam_launch_\(runID)"
        }
        func stdout(_ runID: String) -> URL {
            launchLogs.appending(path: "\(stem(runID))_stdout.log")
        }
        func evidence(_ runID: String) -> URL {
            launchLogs.appending(path: "\(stem(runID))_stderr.run.json")
        }
        let staleDate = Date().addingTimeInterval(-120)
        for runID in [firstRunID, blockedRunID] {
            try Data("safe sibling".utf8).write(to: stdout(runID))
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: stdout(runID).path
            )
        }
        try writeRetentionEvidence(
            to: evidence(blockedRunID),
            runID: blockedRunID,
            outcome: .exited,
            relatedEvidencePaths: [],
            modificationDate: staleDate
        )
        try writeRetentionEvidence(
            to: evidence(firstRunID),
            runID: firstRunID,
            outcome: .exited,
            relatedEvidencePaths: [evidence(blockedRunID).path],
            modificationDate: staleDate
        )
        let unsupported = launchLogs.appending(path: "\(stem(blockedRunID))_renderer.trace")
        try Data("unsupported evidence".utf8).write(to: unsupported)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: unsupported.path
        )
        try Data("fresh".utf8).write(to: stdout(freshRunID))

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 365,
            launchLogLimit: 1
        )

        XCTAssertEqual(result.removedFiles, 0)
        for runID in [firstRunID, blockedRunID, freshRunID] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stdout(runID).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence(firstRunID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence(blockedRunID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsupported.path))
    }

    func testLogRetentionExpiresStaleDetachedEvidenceAndProtectsFreshDetachedEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionActiveEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        let detachedRunID = UUID().uuidString.lowercased()
        let freshDetachedRunID = UUID().uuidString.lowercased()
        let incompleteRunID = UUID().uuidString.lowercased()
        let oversizedRunID = UUID().uuidString.lowercased()
        let freshRunID = UUID().uuidString.lowercased()
        func stem(_ runID: String) -> String {
            "2026-07-16_10-00-00_steam_launch_\(runID)"
        }
        func stdout(_ runID: String) -> URL {
            launchLogs.appending(path: "\(stem(runID))_stdout.log")
        }
        func evidence(_ runID: String) -> URL {
            launchLogs.appending(path: "\(stem(runID))_stderr.run.json")
        }
        let staleDate = Date().addingTimeInterval(-86_400 * 30)
        for runID in [detachedRunID, incompleteRunID, oversizedRunID] {
            try Data("stale evidence sibling".utf8).write(to: stdout(runID))
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: stdout(runID).path
            )
        }
        try writeRetentionEvidence(
            to: evidence(detachedRunID),
            runID: detachedRunID,
            outcome: .runningDetached,
            relatedEvidencePaths: [],
            modificationDate: staleDate
        )
        try Data("fresh detached sibling".utf8).write(to: stdout(freshDetachedRunID))
        try writeRetentionEvidence(
            to: evidence(freshDetachedRunID),
            runID: freshDetachedRunID,
            outcome: .runningDetached,
            relatedEvidencePaths: [],
            modificationDate: Date()
        )
        try Data("{\"schemaVersion\":4".utf8).write(to: evidence(incompleteRunID))
        try Data(repeating: 0x20, count: 513 * 1_024).write(to: evidence(oversizedRunID))
        for runID in [incompleteRunID, oversizedRunID] {
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: evidence(runID).path
            )
        }
        try Data("fresh".utf8).write(to: stdout(freshRunID))

        let result = try LogRetentionService(pathManager: pathManager).cleanup(
            retentionDays: 1,
            launchLogLimit: 1
        )

        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stdout(detachedRunID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidence(detachedRunID).path))
        for runID in [freshDetachedRunID, incompleteRunID, oversizedRunID, freshRunID] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stdout(runID).path))
        }
        for runID in [freshDetachedRunID, incompleteRunID, oversizedRunID] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence(runID).path))
        }
    }

    func testLogRetentionRejectsLaunchRootSymlinkReplacementWithoutTouchingExternalFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionLaunchRootSwap-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionLaunchRootExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let launchLogs = try pathManager.url(for: .launchLogs)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appending(path: "external-sentinel.log")
        try Data("do not delete".utf8).write(to: sentinel)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86_400 * 30)],
            ofItemAtPath: sentinel.path
        )
        try FileManager.default.removeItem(at: launchLogs)
        try FileManager.default.createSymbolicLink(at: launchLogs, withDestinationURL: external)

        XCTAssertThrowsError(
            try LogRetentionService(pathManager: pathManager).cleanup(
                retentionDays: 1,
                launchLogLimit: 1
            )
        ) { error in
            guard case LogRetentionServiceError.scanFailed(let url, _) = error else {
                return XCTFail("Expected scanFailed, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, launchLogs.standardizedFileURL.path)
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not delete")
    }

    func testLogRetentionRejectsLogsRootSymlinkReplacementWithoutTouchingExternalFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionLogsRootSwap-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionLogsRootExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logsRoot = try pathManager.url(for: .logs)
        let externalLaunch = external.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalLaunch, withIntermediateDirectories: true)
        let sentinel = external.appending(path: "external-sentinel.log")
        try Data("do not delete".utf8).write(to: sentinel)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86_400 * 30)],
            ofItemAtPath: sentinel.path
        )
        try FileManager.default.removeItem(at: logsRoot)
        try FileManager.default.createSymbolicLink(at: logsRoot, withDestinationURL: external)

        XCTAssertThrowsError(
            try LogRetentionService(pathManager: pathManager).cleanup(
                retentionDays: 1,
                launchLogLimit: 1
            )
        ) { error in
            guard case LogRetentionServiceError.scanFailed(let url, _) = error else {
                return XCTFail("Expected scanFailed, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, logsRoot.standardizedFileURL.path)
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not delete")
    }

    func testLogRetentionSurfacesUnreadableLogRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogRetentionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Logs").path)
            try? FileManager.default.removeItem(at: root)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let logsRoot = try pathManager.url(for: .logs)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logsRoot.path)

        let service = LogRetentionService(pathManager: pathManager)
        do {
            _ = try service.cleanup(retentionDays: 1, launchLogLimit: 100)
            XCTFail("Expected unreadable log root to fail cleanup")
        } catch LogRetentionServiceError.scanFailed(let url, _) {
            XCTAssertEqual(url.standardizedFileURL.path, logsRoot.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func writeRetentionEvidence(
        to url: URL,
        runID: String,
        outcome: ProcessRunOutcome,
        relatedEvidencePaths: [String],
        modificationDate: Date
    ) throws {
        let waitedForExit: Bool
        switch outcome {
        case .exited, .signaled, .timedOut:
            waitedForExit = true
        case .runningDetached, .preflightFailed, .spawnFailed, .unknown:
            waitedForExit = false
        }
        let document = ProcessRunEvidenceDocument(
            hostContext: nil,
            runIdentifier: runID,
            actionName: "log-retention-test",
            executable: "/usr/bin/true",
            arguments: [],
            environmentOverrides: [:],
            workingDirectory: nil,
            startedAt: modificationDate.addingTimeInterval(-1),
            endedAt: modificationDate,
            durationMilliseconds: 1_000,
            outcome: outcome,
            exitCode: outcome == .exited ? 0 : nil,
            relatedRunEvidenceLogs: relatedEvidencePaths,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: outcome == .timedOut,
            waitedForExit: waitedForExit,
            processIdentifier: outcome == .runningDetached ? 42_424 : nil,
            stdoutLog: url.deletingLastPathComponent().appending(path: "\(runID)_stdout.log").path,
            stderrLog: url.deletingLastPathComponent().appending(path: "\(runID)_stderr.log").path,
            processObservationLog: nil,
            captureError: nil
        )
        try ProcessRunEvidenceWriter.write(document, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
    }
}

@MainActor
final class SteamClientLogRetentionTests: XCTestCase {
    func testOfflineSteamClientLogRotationPreservesBoundedTailBeforeTruncating() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLogRotation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let steamLogs = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/logs",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: steamLogs,
            withIntermediateDirectories: true
        )
        let oversized = steamLogs.appending(path: "cef_log.txt")
        let expectedTail = Data("0123456789abcdef".utf8)
        let original = Data(repeating: 0x61, count: 128) + expectedTail
        try original.write(to: oversized)
        let small = steamLogs.appending(path: "webhelper.txt")
        try Data("small".utf8).write(to: small)

        let result = try SteamClientLogRetentionService.rotateOfflineLogs(
            in: prefix,
            managedLogsRoot: try pathManager.url(for: .logs),
            policy: SteamClientLogRetentionPolicy(
                maximumLogBytes: 64,
                preservedTailBytes: expectedTail.count
            )
        )

        XCTAssertEqual(result.rotatedFiles, 1)
        XCTAssertEqual(result.freedBytes, Int64(original.count))
        XCTAssertTrue(result.skippedFiles.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oversized), Data())
        XCTAssertEqual(try Data(contentsOf: small), Data("small".utf8))
        let snapshot = root.appending(path: "Logs/SteamClient/previous-cef_log.txt")
        let snapshotData = try Data(contentsOf: snapshot)
        XCTAssertTrue(snapshotData.suffix(expectedTail.count) == expectedTail)
        let values = try snapshot.resourceValues(forKeys: [.isRegularFileKey, .linkCountKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertEqual(values.linkCount, 1)
    }

    func testOfflineSteamClientLogRotationSkipsSymlinkAndHardlinkSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLogRotationUnsafe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLogRotationExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRoot)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let steamLogs = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/logs",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let external = externalRoot.appending(path: "external.log")
        let externalData = Data(repeating: 0x73, count: 128)
        try externalData.write(to: external)
        try FileManager.default.createSymbolicLink(
            at: steamLogs.appending(path: "cef_log.txt"),
            withDestinationURL: external
        )
        try FileManager.default.linkItem(
            at: external,
            to: steamLogs.appending(path: "webhelper.txt")
        )

        let result = try SteamClientLogRetentionService.rotateOfflineLogs(
            in: prefix,
            managedLogsRoot: try pathManager.url(for: .logs),
            policy: SteamClientLogRetentionPolicy(
                maximumLogBytes: 1,
                preservedTailBytes: 16
            )
        )

        XCTAssertEqual(result.rotatedFiles, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(result.skippedFiles, ["cef_log.txt", "webhelper.txt"])
        XCTAssertEqual(try Data(contentsOf: external), externalData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Logs/SteamClient/previous-cef_log.txt").path
            )
        )
    }
}
