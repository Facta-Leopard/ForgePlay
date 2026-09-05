import CryptoKit
import Darwin
import SwiftData
import XCTest
@testable import ForgePlay

private struct FailureEvidenceSensitivePathError: LocalizedError, ForgePlayTechnicalDescribingError {
    let detail: String

    var errorDescription: String? { detail }
    var forgePlayTechnicalDescription: String { detail }
}

private actor CancellationAwarePrefixExitProbe {
    private var entered = false
    private var entryCount = 0

    func waitUntilCancelled() async throws -> Bool {
        entered = true
        entryCount += 1
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(60))
        }
    }

    func hasEntered() -> Bool { entered }
    func observedEntryCount() -> Int { entryCount }
}

private actor RelaunchPrefixExitProbe {
    private var inactive: Bool?

    func setInactive(_ value: Bool?) { inactive = value }

    func wait() async throws -> Bool {
        if let inactive { return inactive }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(60))
        }
    }
}

@MainActor
private final class NonDrainingCompatibilityBackgroundOwner:
    SteamCompatibilityFailedCleanupOwner,
    SteamCompatibilityBackgroundWorkOwner
{
    let cleanupReceiptID = "non-draining-background-owner"
    let prefixBinding = SteamCompatibilityPrefixBinding(
        canonicalPrefixURL: URL(
            fileURLWithPath: "/tmp/forgeplay-non-draining-prefix"
        ),
        device: 91,
        inode: 92
    )
    let capturedBaselineDigest = String(repeating: "a", count: 64)
    private let completionState =
        SteamCompatibilityBackgroundWorkCompletionState()
    private(set) var completionAttempts = 0

    func cancelCompatibilityBackgroundWork()
        -> [SteamCompatibilityBackgroundWorkCompletionState]
    {
        [completionState]
    }

    func markBackgroundWorkCompleted() {
        completionState.markCompleted()
    }

    func completeFailedPostLaunchCleanup(
        using _: SteamPrefixService,
        reason _: SteamCompatibilityFailedCleanupCompletionReason
    ) async throws -> SteamCompatibilityFailedCleanupCompletionProof {
        completionAttempts += 1
        throw FailureEvidenceSensitivePathError(
            detail: "fixture retained cleanup reached"
        )
    }
}

@MainActor
final class AppServicesTests: XCTestCase {
    func testDefaultEmergencyDiagnosticsUsesStableProductNamespace() {
        let directory = FailureDiagnosticEvidenceService.defaultEmergencyDiagnosticDirectory(
            fileManager: .default
        )

        XCTAssertEqual(directory.lastPathComponent, "EmergencyDiagnostics")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "ForgePlay")
        XCTAssertFalse(directory.path.contains("com.forgeplay.ForgePlay"))
    }

    func testFailureDiagnosticEvidenceCapturesRedactedHostContextWithoutProcessSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFailureEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let hostContext = ProcessRunHostContext(
            capturedAt: capturedAt,
            applicationVersion: "1.2.3",
            applicationBuild: "456",
            bundleIdentifier: "com.forgeplay.tests",
            operatingSystemVersion: "macOS 26.0",
            operatingSystemBuild: "25A123",
            kernelVersion: "Darwin test kernel",
            modelIdentifier: "Mac16,1",
            cpuBrand: "Apple M4",
            processArchitecture: "arm64",
            processorCount: 10,
            activeProcessorCount: 8,
            physicalMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
            translatedProcess: false
        )
        let service = FailureDiagnosticEvidenceService(
            pathManager: pathManager,
            redactor: Redactor(),
            hostContextProvider: { hostContext }
        )
        let privatePath = root.appending(path: "Private Steam Library").path
        let failure = NSError(
            domain: "ForgePlayFailureEvidenceTests",
            code: 77,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Authorization: Bearer failure-secret-token-123456789 at \(privatePath)",
                NSLocalizedFailureReasonErrorKey: "password=failure-private-secret",
                NSLocalizedRecoverySuggestionErrorKey: "Inspect \(privatePath)"
            ]
        )

        let resolution = try service.ensureEvidence(
            for: failure,
            operationIdentifier: "steam.launch",
            surfaceIdentifier: "dashboard",
            capturedAt: capturedAt
        )
        guard case .capturedFailure(let reportURL) = resolution else {
            return XCTFail("Expected a standalone failure report")
        }

        XCTAssertEqual(
            reportURL.deletingLastPathComponent(),
            try pathManager.url(for: .diagnosticLogs).standardizedFileURL
        )
        XCTAssertTrue(reportURL.lastPathComponent.hasSuffix("_diagnostic.json"))
        let data = try Data(contentsOf: reportURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(FailureDiagnosticEvidenceDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, FailureDiagnosticEvidenceDocument.currentSchemaVersion)
        XCTAssertEqual(document.capturedAt, capturedAt)
        XCTAssertEqual(document.evidenceKind, "preProcessFailure")
        XCTAssertEqual(document.operationIdentifier, "steam.launch")
        XCTAssertEqual(document.surfaceIdentifier, "dashboard")
        XCTAssertEqual(document.failure.code, 77)
        XCTAssertEqual(document.hostContext.applicationVersion, "1.2.3")
        XCTAssertEqual(document.hostContext.operatingSystemBuild, "25A123")
        XCTAssertEqual(document.hostContext.modelIdentifier, "Mac16,1")
        XCTAssertEqual(document.hostContext.cpuBrand, "Apple M4")
        XCTAssertEqual(document.hostContext.processArchitecture, "arm64")
        XCTAssertEqual(document.hostContext.processorCount, 10)
        XCTAssertEqual(document.hostContext.activeProcessorCount, 8)
        XCTAssertEqual(document.hostContext.physicalMemoryBytes, 24 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(document.hostContext.translatedProcess, false)
        XCTAssertFalse(text.contains("failure-secret-token"), text)
        XCTAssertFalse(text.contains("failure-private-secret"), text)
        XCTAssertFalse(text.contains(privatePath), text)
        XCTAssertTrue(text.contains("[REDACTED_SECRET]"), text)
        XCTAssertTrue(text.contains("[REDACTED_PATH]"), text)
        let attributes = try FileManager.default.attributesOfItem(atPath: reportURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testFailureDiagnosticEvidenceReusesValidatedProcessSidecar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFailureEvidenceDedup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let executable = root.appending(path: "failure-probe")
        try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let result = try await makeCuratedRuntimeRunner().run(.probeRuntime(
            executable: executable,
            logDirectory: try pathManager.url(for: .launchLogs)
        ))
        let existingEvidence = try XCTUnwrap(result.runEvidenceLog)
        let failure = ProcessExecutionEvidenceError(
            underlyingError: NSError(domain: "ExistingProcessEvidence", code: 7),
            result: result
        )
        let service = FailureDiagnosticEvidenceService(
            pathManager: pathManager,
            redactor: Redactor()
        )

        let resolution = try service.ensureEvidence(
            for: failure,
            operationIdentifier: "steam.launch",
            surfaceIdentifier: "steam-launch"
        )

        XCTAssertEqual(resolution, .existingProcessEvidence(existingEvidence.standardizedFileURL))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: pathManager.url(for: .diagnosticLogs),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testFailureDiagnosticEvidenceRejectsSymlinkedDiagnosticDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFailureEvidenceUnsafe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFailureEvidenceExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let diagnosticDirectory = try pathManager.url(for: .diagnosticLogs)
        try FileManager.default.removeItem(at: diagnosticDirectory)
        try FileManager.default.createSymbolicLink(at: diagnosticDirectory, withDestinationURL: external)
        let emergencyDirectory = root.appending(
            path: "EmergencyDiagnostics",
            directoryHint: .isDirectory
        )
        let service = FailureDiagnosticEvidenceService(
            pathManager: pathManager,
            redactor: Redactor(),
            emergencyDiagnosticDirectory: emergencyDirectory
        )

        let resolution = try service.ensureEvidence(
            for: NSError(domain: "UnsafeDiagnosticDirectory", code: 1),
            operationIdentifier: "steam.launch",
            surfaceIdentifier: "dashboard"
        )
        guard case .capturedFailure(let evidenceURL) = resolution else {
            return XCTFail("Expected emergency failure evidence, got \(resolution)")
        }
        XCTAssertEqual(
            evidenceURL.deletingLastPathComponent().standardizedFileURL,
            emergencyDirectory.standardizedFileURL
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: external,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testLaunchFailureLifecyclePersistsStandaloneEvidenceOnLaunchRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLaunchFailureEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices(appSessionID: "failure-evidence-session")
        try services.pathManager.configureRoot(root)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let launchRecord = LaunchRecord(
            id: "launch-failure-evidence",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            hostAppSessionID: services.appSessionID
        )
        context.insert(launchRecord)
        try context.saveOrRollback()
        let appState = AppState()
        appState.selectedRootURL = root
        let externalLibraryPath = "/Volumes/ForgePlay QA Secret/Private Tester Library"
        let privateInstallDirectory = "PrivateCompatibilityBuild"
        appState.selectedSteamReference = SteamGameRecord(
            steamAppId: "123456",
            name: "Private test game",
            installDir: privateInstallDirectory,
            libraryPath: externalLibraryPath,
            manifestPath: "\(externalLibraryPath)/steamapps/appmanifest_123456.acf"
        ).game
        let runtimeExecutable = URL(
            fileURLWithPath: "/Volumes/ForgePlay Runtime Secret/Private Runtime Distribution/bin/wine"
        )
        appState.runtimeExecutableURL = runtimeExecutable
        let lifecycle = SteamLaunchRecordLifecycle(
            modelContext: context,
            appState: appState,
            services: services
        )

        lifecycle.handleLaunchFailure(
            launchRecord,
            error: FailureEvidenceSensitivePathError(
                detail: "Steam preflight failed at \(externalLibraryPath)/steamapps/common/\(privateInstallDirectory)/game.exe using \(runtimeExecutable.path)"
            ),
            surfaceIdentifier: "dashboard"
        )

        let diagnosticLogPath = try XCTUnwrap(launchRecord.diagnosticLogPath)
        let diagnosticLogURL = URL(fileURLWithPath: diagnosticLogPath).standardizedFileURL
        XCTAssertEqual(launchRecord.status, "failed")
        XCTAssertEqual(launchRecord.processOutcome, ProcessRunOutcome.preflightFailed.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticLogURL.path))
        XCTAssertEqual(appState.currentNotice?.logURL?.standardizedFileURL, diagnosticLogURL)
        let verificationContext = ModelContext(container)
        let persisted = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<LaunchRecord>())
                .first { $0.id == launchRecord.id }
        )
        XCTAssertEqual(persisted.diagnosticLogPath, diagnosticLogURL.path)
        XCTAssertEqual(persisted.status, "failed")

        let data = try Data(contentsOf: diagnosticLogURL)
        let reportText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(reportText.contains("Private Tester Library"), reportText)
        XCTAssertFalse(reportText.contains(privateInstallDirectory), reportText)
        XCTAssertFalse(reportText.contains("Private Runtime Distribution"), reportText)
        XCTAssertTrue(reportText.contains("[REDACTED_PATH]"), reportText)
        XCTAssertTrue(reportText.contains("[REDACTED_VALUE]"), reportText)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(FailureDiagnosticEvidenceDocument.self, from: data)
        XCTAssertEqual(document.operationIdentifier, "steam.launch")
        XCTAssertEqual(document.surfaceIdentifier, "dashboard")
    }

    func testApplicationTerminationRequiresSuccessfulManagedProcessCleanup() {
        let failed = AppTerminationSteamShutdownSummary(
            prefix: URL(fileURLWithPath: "/tmp/SteamShared"),
            prefixes: [URL(fileURLWithPath: "/tmp/SteamShared")],
            attemptedRuntimePath: "/tmp/wine",
            results: [],
            errors: ["cleanup failed"],
            skippedReason: nil
        )
        let skippedWithoutPrefix = AppTerminationSteamShutdownSummary(
            prefix: nil,
            prefixes: [],
            attemptedRuntimePath: nil,
            results: [],
            errors: [],
            skippedReason: "no configured SteamShared prefix exists"
        )

        XCTAssertFalse(ForgePlayApplicationDelegate.shouldAllowTermination(after: failed))
        XCTAssertTrue(ForgePlayApplicationDelegate.shouldAllowTermination(after: skippedWithoutPrefix))
    }

    func testApplicationTerminationDoesNotTreatSkippedPlanWithErrorsAsSuccess() {
        let summary = AppTerminationSteamShutdownSummary(
            prefix: nil,
            prefixes: [],
            attemptedRuntimePath: nil,
            results: [],
            errors: ["runtime ownership lock failed"],
            skippedReason: "no owned prefix"
        )

        XCTAssertFalse(summary.succeeded)
    }

    func testApplicationTerminationAcceptsSuccessfulBundledRuntimeCleanup() {
        let prefix = URL(fileURLWithPath: "/tmp/SteamShared", isDirectory: true)
        let now = Date()
        func shutdownResult(runner: String, exitCode: Int32) -> ProcessRunResult {
            ProcessRunResult(
                actionName: "shutdownWinePrefix",
                executable: URL(fileURLWithPath: runner),
                arguments: ["-k"],
                startedAt: now,
                endedAt: now,
                exitCode: exitCode,
                stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
                stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
                didTimeOut: false
            )
        }
        let summary = AppTerminationSteamShutdownSummary(
            prefix: prefix,
            prefixes: [prefix],
            attemptedRuntimePath: "/tmp/bundled-wine",
            results: [shutdownResult(runner: "/tmp/bundled-wine", exitCode: 0)],
            errors: [],
            skippedReason: nil
        )

        XCTAssertTrue(summary.succeeded)
        XCTAssertTrue(ForgePlayApplicationDelegate.shouldAllowTermination(after: summary))
    }

    func testSteamPrefixLifecycleCoordinatorRejectsOverlappingAndPostTerminationOperations() throws {
        let coordinator = SteamPrefixLifecycleCoordinator()
        let rebuildToken = try coordinator.begin(.rebuild)

        XCTAssertEqual(coordinator.activeOperation, .rebuild)
        XCTAssertThrowsError(try coordinator.begin(.launch)) { error in
            XCTAssertEqual(error as? SteamPrefixLifecycleError, .operationInProgress)
        }

        coordinator.end(rebuildToken)
        XCTAssertNil(coordinator.activeOperation)
        XCTAssertTrue(coordinator.beginApplicationTermination())
        XCTAssertThrowsError(try coordinator.begin(.prepare)) { error in
            XCTAssertEqual(error as? SteamPrefixLifecycleError, .applicationTerminating)
        }
        XCTAssertThrowsError(try coordinator.checkpoint()) { error in
            XCTAssertEqual(error as? SteamPrefixLifecycleError, .applicationTerminating)
        }
    }

    func testSteamPrefixLifecycleCoordinatorRejectsTerminationWhileOperationIsActiveAndCanRetry() throws {
        let coordinator = SteamPrefixLifecycleCoordinator()
        let launchToken = try coordinator.begin(.launch)

        XCTAssertFalse(coordinator.beginApplicationTermination())
        XCTAssertFalse(coordinator.isTerminating)
        XCTAssertEqual(coordinator.activeOperation, .launch)

        coordinator.end(launchToken)
        XCTAssertTrue(coordinator.beginApplicationTermination())
        XCTAssertTrue(coordinator.isTerminating)

        coordinator.cancelApplicationTermination()
        XCTAssertFalse(coordinator.isTerminating)
        let retryToken = try coordinator.begin(.maintenance)
        coordinator.end(retryToken)
    }

    func testApplicationTerminationIntentInvalidatesEarlierForceStopResetTicket() {
        var gate = AppTerminationIntentGate()
        let forceStopResetTicket = gate.temporaryForceStopResetTicket()

        gate.beginApplicationTermination()

        XCTAssertTrue(gate.isApplicationTerminationRequested)
        XCTAssertFalse(
            gate.permitsTemporaryForceStopReset(ticket: forceStopResetTicket)
        )

        gate.cancelApplicationTermination()
        XCTAssertFalse(gate.isApplicationTerminationRequested)
        XCTAssertFalse(
            gate.permitsTemporaryForceStopReset(ticket: forceStopResetTicket),
            "A cancelled quit must still invalidate the older force-stop reset"
        )
        XCTAssertNotNil(gate.temporaryForceStopResetTicket())
    }

#if DEBUG
    func testStoppedNVIDIASessionCanRelaunchRepeatedlyInSameManager()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlay-Relaunch-Lease-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "SteamShared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "drive_c/windows/system32"),
            withIntermediateDirectories: true
        )
        let probe = RelaunchPrefixExitProbe()
        let manager = SteamManager(
            pathManager: PathManager(),
            runner: SafeProcessRunner(
                sandboxEnabled: false,
                managedWineProcessJournalEnabled: false
            ),
            compatibilityPrefixExitWaiter: { _, _, _ in
                try await probe.wait()
            }
        )
        let runtime = root.appending(path: "absent-wine-runtime")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let rendererBackups = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rendererBackups,
            withIntermediateDirectories: true
        )
        let marker = rendererBackups.appending(
            path: SteamRendererPolicyManager.nvidiaMetalFXRegistrySessionMarkerName
        )
        var restorationTransitions = 0
        var releases = 0
        var launchLease = try await manager.acquirePrefixMutationLeaseForLaunch(
            prefix: prefix
        )
        let lockURL = launchLease.lockURL
        defer {
            launchLease.release()
            try? FileManager.default.removeItem(at: lockURL)
        }

        // FG-enabled and disabled NVIDIA launches share this owner. Exercise
        // repeated stopped-session handoffs in one manager without dispatching
        // a Steam/Wine process; rendering itself is outside this test's scope.
        for completedLaunch in 1...3 {
            let markerData: Data
            if completedLaunch == 2 {
                markerData = Data("malformed optional NVIDIA marker".utf8)
            } else {
                markerData = try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 2,
                    "projections": [[
                        "registryPath": SteamRendererPolicyManager
                            .nvidiaMetalFXNGXCoreRegistryPath,
                        "valueName": SteamRendererPolicyManager
                            .nvidiaMetalFXNGXCoreFullPathValueName,
                        "stagedValue": SteamRendererPolicyManager
                            .nvidiaMetalFXNGXCoreSystem32Path
                    ]]
                ])
            }
            try markerData.write(to: marker, options: .atomic)
            let previousLease = launchLease
            try previousLease.transitionToSharedExecution()
            let restorationLease = SteamCompatibilityRestorationPrefixLease(
                prepareForMutation: {
                    try previousLease.transitionToExclusiveMutation()
                    restorationTransitions += 1
                },
                release: {
                    previousLease.release()
                    releases += 1
                }
            )
            manager.debugInstallNVIDIACompatibilityRestorationSession(
                prefix: prefix,
                runtimeExecutable: runtime,
                logDirectory: logs,
                restorationLease: restorationLease
            )
            manager.beginApplicationTerminationInputContainmentDrain()
            let drained = await manager
                .waitForApplicationTerminationInputContainmentDrain(timeout: 1)
            XCTAssertTrue(drained)
            await probe.setInactive(true)
            let deferral = manager
                .deferRetainedCompatibilityRestorationAfterForcedWineTermination()
            XCTAssertTrue(deferral.blockingErrors.isEmpty)
            manager.cancelApplicationTerminationContainmentDrain(
                rearmRestorationMonitors: false
            )
            XCTAssertEqual(releases, completedLaunch - 1)
            XCTAssertEqual(restorationTransitions, completedLaunch - 1)
            XCTAssertEqual(try Data(contentsOf: marker), markerData)
            XCTAssertThrowsError(
                try PrefixExecutionLease.acquireExclusiveMutation(forPrefix: prefix)
            ) { error in
                guard case .conflictingOperation(_, .exclusiveMutation) =
                        error as? PrefixExecutionLeaseError else {
                    return XCTFail("Unexpected lock failure: \(error)")
                }
            }

            if completedLaunch == 1 {
                await probe.setInactive(false)
                do {
                    _ = try await manager.acquirePrefixMutationLeaseForLaunch(
                        prefix: prefix
                    )
                    XCTFail("A live prefix must keep its session owner")
                } catch {
                    XCTAssertEqual(
                        error as? SteamCompatibilityLaunchProfileErrorV1,
                        .invalidReceipt("renderer-restoration-managed-prefix-still-active")
                    )
                }
                XCTAssertEqual(releases, 0)
                XCTAssertEqual(restorationTransitions, 0)
                XCTAssertEqual(try Data(contentsOf: marker), markerData)
                await probe.setInactive(true)

                let otherExecutionLease = try PrefixExecutionLease
                    .acquireSharedExecution(forPrefix: prefix)
                do {
                    _ = try await manager.acquirePrefixMutationLeaseForLaunch(
                        prefix: prefix
                    )
                    XCTFail("Another execution lease must prevent owner detachment")
                } catch {
                    guard case .conflictingOperation(_, .exclusiveMutation) =
                            error as? PrefixExecutionLeaseError else {
                        otherExecutionLease.release()
                        return XCTFail("Unexpected lease upgrade failure: \(error)")
                    }
                }
                XCTAssertEqual(releases, 0)
                XCTAssertEqual(restorationTransitions, 0)
                XCTAssertEqual(try Data(contentsOf: marker), markerData)
                otherExecutionLease.release()
            }

            launchLease = try await manager.acquirePrefixMutationLeaseForLaunch(
                prefix: prefix
            )
            XCTAssertEqual(launchLease.mode, .exclusiveMutation)
            XCTAssertEqual(restorationTransitions, completedLaunch)
            XCTAssertEqual(releases, completedLaunch)
            XCTAssertEqual(
                try Data(contentsOf: marker), markerData,
                "Even malformed optional NVIDIA state belongs to existing preflight, not lease acquisition"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
            await probe.setInactive(nil)
        }
    }

    func testApplicationTerminationDrainsRestorationMonitorWithoutWineThenDefersRendererWork()
        async throws
    {
        let probe = CancellationAwarePrefixExitProbe()
        let runner = SafeProcessRunner(
            sandboxEnabled: false,
            managedWineProcessJournalEnabled: false
        )
        let manager = SteamManager(
            pathManager: PathManager(),
            runner: runner,
            compatibilityPrefixExitWaiter: { _, _, _ in
                try await probe.waitUntilCancelled()
            }
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault
        )
        try session.captureBeforeLaunch()
        let prefix = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlay-Termination-Monitor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        manager.debugInstallInputOnlyCompatibilityRestorationMonitor(
            session: session,
            prefix: prefix
        )
        var didEnter = await probe.hasEntered()
        for _ in 0..<1_000 where !didEnter {
            await Task.yield()
            didEnter = await probe.hasEntered()
        }
        XCTAssertTrue(didEnter)

        manager.beginApplicationTerminationInputContainmentDrain()
        let drained = await manager
            .waitForApplicationTerminationInputContainmentDrain(timeout: 1)

        XCTAssertTrue(drained)
        XCTAssertFalse(
            session.isRestored,
            "Cancellation must win before the monitor's restoration callback"
        )
        let deferral = manager
            .deferRetainedCompatibilityRestorationAfterForcedWineTermination()
        XCTAssertTrue(deferral.blockingErrors.isEmpty)
        XCTAssertTrue(deferral.diagnosticWarnings.isEmpty)
        XCTAssertTrue(session.isRestored)
    }

    func testForceStopContainmentResetDoesNotRearmRestorationMonitor()
        async throws
    {
        let probe = CancellationAwarePrefixExitProbe()
        let runner = SafeProcessRunner(
            sandboxEnabled: false,
            managedWineProcessJournalEnabled: false
        )
        let manager = SteamManager(
            pathManager: PathManager(),
            runner: runner,
            compatibilityPrefixExitWaiter: { _, _, _ in
                try await probe.waitUntilCancelled()
            }
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault
        )
        try session.captureBeforeLaunch()
        manager.debugInstallInputOnlyCompatibilityRestorationMonitor(
            session: session,
            prefix: URL(
                fileURLWithPath: "/tmp/ForgePlay-ForceStop-No-Rearm",
                isDirectory: true
            )
        )
        var observedEntryCount = await probe.observedEntryCount()
        for _ in 0..<1_000 where observedEntryCount == 0 {
            await Task.yield()
            observedEntryCount = await probe.observedEntryCount()
        }
        XCTAssertEqual(observedEntryCount, 1)

        manager.beginApplicationTerminationInputContainmentDrain()
        let drainSucceeded = await manager
            .waitForApplicationTerminationInputContainmentDrain(
                timeout: 1
            )
        XCTAssertTrue(
            drainSucceeded
        )
        manager.cancelApplicationTerminationContainmentDrain(
            rearmRestorationMonitors: false
        )
        for _ in 0..<100 { await Task.yield() }

        let finalEntryCount = await probe.observedEntryCount()
        XCTAssertEqual(
            finalEntryCount,
            1,
            "Force-stop admission reset must not automatically restart a Wine-capable restoration monitor"
        )
        XCTAssertFalse(session.isRestored)
    }
#endif

    func testTerminationCancellationDrainsActiveLifecycleOperation() async throws {
        let coordinator = SteamPrefixLifecycleCoordinator()
        let token = try coordinator.begin(.install)
        coordinator.setCancellationRequester(
            { coordinator.end(token) },
            for: token
        )

        let drained = await coordinator
            .beginApplicationTerminationAndWaitForIdle(
                timeout: 1,
                cancellationRequester: {
                    coordinator.requestCancellationOfActiveOperation()
                }
            )

        XCTAssertTrue(drained)
        XCTAssertNil(coordinator.activeOperation)
        XCTAssertTrue(coordinator.isTerminating)
    }

    func testTerminationCancellationFailsClosedWhenOperationDoesNotDrain() async throws {
        let coordinator = SteamPrefixLifecycleCoordinator()
        let token = try coordinator.begin(.install)
        defer { coordinator.end(token) }

        let drained = await coordinator
            .beginApplicationTerminationAndWaitForIdle(
                timeout: 0.05,
                cancellationRequester: {}
            )

        XCTAssertFalse(drained)
        XCTAssertEqual(coordinator.activeOperation, .install)
        XCTAssertTrue(coordinator.isTerminating)
    }

    func testManagedStorageTransitionBlocksSteamLaunchAndApplicationTermination() throws {
        let coordinator = SteamPrefixLifecycleCoordinator()
        let storageToken = try coordinator.begin(.managedStorageTransition)

        XCTAssertEqual(coordinator.activeOperation, .managedStorageTransition)
        XCTAssertThrowsError(try coordinator.begin(.launch)) { error in
            XCTAssertEqual(error as? SteamPrefixLifecycleError, .operationInProgress)
        }
        XCTAssertFalse(coordinator.beginApplicationTermination())
        XCTAssertFalse(coordinator.isTerminating)

        coordinator.end(storageToken)
        XCTAssertTrue(coordinator.beginApplicationTermination())
    }

    func testSetupResetRejectsWhileSteamPrefixOperationIsActive() async throws {
        let services = AppServices()
        let launchToken = try services.steamPrefixLifecycleCoordinator.begin(.launch)
        defer { services.steamPrefixLifecycleCoordinator.end(launchToken) }
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)

        do {
            _ = try await services.resetSetupProgress(
                appState: AppState(),
                in: container.mainContext
            )
            XCTFail("Expected setup reset to reject an active Steam launch")
        } catch let error as SteamPrefixLifecycleError {
            XCTAssertEqual(error, .operationInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSetupResetRejectsManagedRootHeldByAnotherOperation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySetupResetLease-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let appState = AppState()
        try appState.load(from: container.mainContext)
        appState.selectedRootURL = root

        let activeLease = try ManagedRootOperationLease.acquireExclusive(forManagedRoot: root)
        defer { activeLease.release() }

        do {
            _ = try await services.resetSetupProgress(
                appState: appState,
                in: container.mainContext
            )
            XCTFail("Expected setup reset to reject a managed root held by another operation")
        } catch let error as SteamPrefixLifecycleError {
            XCTAssertEqual(error, .operationInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSteamPrefixMaintenanceRejectsManagedRootHeldByAnotherOperation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMaintenanceLease-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let activeLease = try ManagedRootOperationLease.acquireExclusive(forManagedRoot: root)
        defer { activeLease.release() }
        var didRunBody = false

        do {
            try await services.steamPrefixService.performMaintenance {
                didRunBody = true
            }
            XCTFail("Expected maintenance to reject a managed root held by another operation")
        } catch let error as SteamPrefixLifecycleError {
            XCTAssertEqual(error, .operationInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(didRunBody)
        XCTAssertNil(services.steamPrefixLifecycleCoordinator.activeOperation)
    }

    func testReadinessDoesNotCleanReplacementArtifactsOwnedByAnotherForgePlayInstance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayReadinessRuntimeOwner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let owner = AppServices()
        try owner.steamPrefixService.claimRuntimeOwnership(forManagedRoot: root)
        let observer = AppServices()
        try observer.pathManager.configureRoot(root)
        let transitionToken = try observer.steamPrefixLifecycleCoordinator
            .begin(.managedStorageTransition)
        defer {
            observer.steamPrefixLifecycleCoordinator.end(transitionToken)
        }
        let prefix = try observer.steamSharedPrefixURL()
        let interrupted = prefix.deletingLastPathComponent().appending(
            path: ".SteamShared.initialize-staging-interrupted",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)

        _ = observer.resolveSetupReadiness(hasSteamReferences: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertFalse(observer.steamPrefixService.hasRuntimeOwnership(forManagedRoot: root))

        do {
            try await observer.steamPrefixService
                .cleanupInterruptedReplacementArtifactsDuringManagedStorageTransition(
                    at: prefix
                )
            XCTFail("Expected replacement cleanup to reject another ForgePlay runtime owner")
        } catch let error as SteamPrefixLifecycleError {
            XCTAssertEqual(error, .operationInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertFalse(observer.steamPrefixService.hasRuntimeOwnership(forManagedRoot: root))

        owner.steamPrefixService.releaseRuntimeOwnership(forManagedRoot: root)
        _ = observer.resolveSetupReadiness(hasSteamReferences: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertFalse(observer.steamPrefixService.hasRuntimeOwnership(forManagedRoot: root))

        try await observer.steamPrefixService
            .cleanupInterruptedReplacementArtifactsDuringManagedStorageTransition(
                at: prefix
            )
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(observer.steamPrefixService.hasRuntimeOwnership(forManagedRoot: root))
    }

    func testSteamLaunchPreparationDoesNotRunWhenLifecycleOwnershipIsUnavailable() async throws {
        let services = AppServices()
        let activeToken = try services.steamPrefixLifecycleCoordinator.begin(.maintenance)
        defer { services.steamPrefixLifecycleCoordinator.end(activeToken) }
        var didPrepareLaunch = false

        do {
            _ = try await services.steamPrefixService.launchSteam(
                runtimeExecutable: URL(fileURLWithPath: "/missing/wine"),
                steamClientLanguage: .english,
                rendererPolicySelection: .d3dMetal,
                networkSelection: .standard,
                audioInputSelection: .enabled,
                prepareLaunch: {
                    didPrepareLaunch = true
                }
            )
            XCTFail("Expected launch to reject an already-owned Steam Prefix lifecycle")
        } catch let error as SteamPrefixLifecycleError {
            XCTAssertEqual(error, .operationInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(didPrepareLaunch)
    }

    func testSteamReferenceRefreshInvalidationCannotEndNewerRefresh() throws {
        let services = AppServices()
        let first = try XCTUnwrap(services.beginSteamReferenceRefresh())

        services.invalidateSteamReferenceRefresh()
        XCTAssertFalse(services.isCurrentSteamReferenceRefresh(first))
        XCTAssertTrue(services.isSteamReferenceRefreshInProgress)
        XCTAssertNil(services.beginSteamReferenceRefresh())

        services.endSteamReferenceRefresh(first)
        XCTAssertFalse(services.isSteamReferenceRefreshInProgress)

        let second = try XCTUnwrap(services.beginSteamReferenceRefresh())
        services.endSteamReferenceRefresh(first)

        XCTAssertTrue(services.isSteamReferenceRefreshInProgress)
        XCTAssertTrue(services.isCurrentSteamReferenceRefresh(second))

        services.endSteamReferenceRefresh(second)
        XCTAssertFalse(services.isSteamReferenceRefreshInProgress)
    }

    func testSteamReferenceRefreshOwnsLifecycleUntilScanEnds() throws {
        let services = AppServices()
        let token = try XCTUnwrap(services.beginSteamReferenceRefresh())

        XCTAssertEqual(
            services.steamPrefixLifecycleCoordinator.activeOperation,
            .referenceRefresh
        )
        XCTAssertThrowsError(
            try services.steamPrefixLifecycleCoordinator.begin(.launch)
        ) { error in
            XCTAssertEqual(error as? SteamPrefixLifecycleError, .operationInProgress)
        }
        XCTAssertFalse(services.steamPrefixLifecycleCoordinator.beginApplicationTermination())

        services.invalidateSteamReferenceRefresh()
        XCTAssertEqual(
            services.steamPrefixLifecycleCoordinator.activeOperation,
            .referenceRefresh
        )

        services.endSteamReferenceRefresh(token)
        XCTAssertNil(services.steamPrefixLifecycleCoordinator.activeOperation)
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.beginApplicationTermination())
    }

    func testSteamReferenceRefreshRejectsPrefixAndStorageMutations() throws {
        let services = AppServices()
        let prefixToken = try services.steamPrefixLifecycleCoordinator.begin(.maintenance)
        XCTAssertNil(services.beginSteamReferenceRefresh())
        services.steamPrefixLifecycleCoordinator.end(prefixToken)

        let storageToken = try services.steamPrefixLifecycleCoordinator.begin(.managedStorageTransition)
        XCTAssertNil(services.beginSteamReferenceRefresh())
        services.steamPrefixLifecycleCoordinator.end(storageToken)
    }

    func testAppStateSharesAndNormalizesPersistedLogRetentionPolicy() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let settings = AppSettingsRecord()
        settings.isLogAutoCleanupEnabled = false
        settings.logRetentionDays = 0
        settings.launchLogLimit = 999
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        XCTAssertFalse(appState.isLogAutoCleanupEnabled)
        XCTAssertEqual(appState.logRetentionDays, 1)
        XCTAssertEqual(appState.launchLogLimit, 200)
        XCTAssertEqual(settings.logRetentionDays, 1)
        XCTAssertEqual(settings.launchLogLimit, 200)
    }

    func testManagedStorageStartupInitializesDefaultRootWithoutMigrationForNewUser() throws {
        let defaultRoot = URL(fileURLWithPath: "/tmp/ForgePlay-Internal", isDirectory: true)

        let request = try ManagedStorageStartupRequest.resolve(
            layoutVersion: nil,
            persistedRootPath: nil,
            persistedRootBookmark: nil,
            selectedRootURL: nil,
            defaultManagedRoot: defaultRoot,
            approvedLegacyMigrationSourcePath: nil
        )

        XCTAssertEqual(request.destination, defaultRoot.standardizedFileURL)
        XCTAssertNil(request.destinationBookmark)
        XCTAssertNil(request.legacySource)
    }

    func testManagedStorageStartupRequiresExplicitDecisionBeforeLegacyMigration() throws {
        let defaultRoot = URL(fileURLWithPath: "/tmp/ForgePlay-Internal", isDirectory: true)
        let legacyRoot = URL(fileURLWithPath: "/Volumes/Legacy-ForgePlay", isDirectory: true)

        XCTAssertThrowsError(
            try ManagedStorageStartupRequest.resolve(
                layoutVersion: nil,
                persistedRootPath: legacyRoot.path,
                persistedRootBookmark: Data("bookmark".utf8),
                selectedRootURL: legacyRoot,
                defaultManagedRoot: defaultRoot,
                approvedLegacyMigrationSourcePath: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedStorageActivationError,
                .legacyMigrationDecisionRequired(legacyRoot.path)
            )
        }
    }

    func testManagedStorageStartupMigratesOnlyExplicitlyApprovedLegacyRoot() throws {
        let defaultRoot = URL(fileURLWithPath: "/tmp/ForgePlay-Internal", isDirectory: true)
        let legacyRoot = URL(fileURLWithPath: "/Volumes/Legacy-ForgePlay", isDirectory: true)

        let request = try ManagedStorageStartupRequest.resolve(
            layoutVersion: nil,
            persistedRootPath: legacyRoot.path,
            persistedRootBookmark: Data("bookmark".utf8),
            selectedRootURL: legacyRoot,
            defaultManagedRoot: defaultRoot,
            approvedLegacyMigrationSourcePath: legacyRoot.path
        )

        XCTAssertEqual(request.destination, defaultRoot.standardizedFileURL)
        XCTAssertNil(request.destinationBookmark)
        XCTAssertEqual(request.legacySource, legacyRoot.standardizedFileURL)
    }

    func testManagedStorageStartupRequiresAuthorizationForUnavailableLegacyRoot() throws {
        let defaultRoot = URL(fileURLWithPath: "/tmp/ForgePlay-Internal", isDirectory: true)
        let legacyRoot = URL(fileURLWithPath: "/Volumes/Legacy-ForgePlay", isDirectory: true)

        XCTAssertThrowsError(
            try ManagedStorageStartupRequest.resolve(
                layoutVersion: nil,
                persistedRootPath: legacyRoot.path,
                persistedRootBookmark: Data("bookmark".utf8),
                selectedRootURL: nil,
                defaultManagedRoot: defaultRoot,
                approvedLegacyMigrationSourcePath: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedStorageActivationError,
                .legacyRootAuthorizationRequired(legacyRoot.path)
            )
        }
    }

    func testManagedStorageWorkflowsUseSharedPrefixLifecycleCoordinator() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/App/AppServices.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(
            source.components(separatedBy: "begin(.managedStorageTransition)").count - 1,
            4
        )
        XCTAssertTrue(
            source.contains(
                "steamPrefixLifecycleCoordinator.activeOperation == .managedStorageTransition"
            )
        )
    }

    func testTerminationPlanFailsWithoutEnteringTerminatingStateWhenPrefixOperationIsActive() throws {
        let services = AppServices()
        let token = try services.steamPrefixLifecycleCoordinator.begin(.rebuild)
        defer { services.steamPrefixLifecycleCoordinator.end(token) }

        let plan = services.appTerminationSteamShutdownPlan(runtimeExecutable: nil)

        XCTAssertTrue(plan.prefixes.isEmpty)
        XCTAssertNil(plan.runtimeExecutable)
        XCTAssertTrue(plan.initialErrors.contains { $0.contains("rebuild") })
        XCTAssertFalse(services.steamPrefixLifecycleCoordinator.isTerminating)
    }

    func testTerminationCleanupUsesOnlyBundledRuntime() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/App/AppServices.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("appTerminationShutdownRuntime"))
        XCTAssertTrue(source.contains("runtimeExecutable: bundledRuntime"))
        XCTAssertTrue(source.contains("guard let bundledRuntime else"))
    }

    func testSupplementalRendererImportUsesSharedPrefixLifecycleCoordinator() async throws {
        let services = AppServices()
        let token = try services.steamPrefixLifecycleCoordinator.begin(.launch)
        defer { services.steamPrefixLifecycleCoordinator.end(token) }

        do {
            _ = try await services.windowsRuntimeService.importAppleSupplementalRenderer(
                at: URL(fileURLWithPath: "/tmp/missing-evaluation-redist")
            )
            XCTFail("Expected the active launch operation to block supplemental renderer import")
        } catch {
            XCTAssertEqual(error as? SteamPrefixLifecycleError, .operationInProgress)
        }
    }

    func testTerminationPlanIncludesActiveReplacementPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let staging = root.appending(
            path: "Prefixes/.SteamShared.rebuild-staging-active",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try services.steamPrefixLifecycleCoordinator.registerManagedPrefix(staging)
        let runner = root.appending(path: "runner")
        try "#!/bin/sh\nexit 0\n".write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)

        let plan = services.appTerminationSteamShutdownPlan(runtimeExecutable: runner)

        XCTAssertTrue(plan.prefixes.contains { $0.standardizedFileURL.path == staging.standardizedFileURL.path })
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.isTerminating)
    }

    func testTerminationPlanIncludesPrefixUsedEarlierInSameAppSession() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySessionPrefixRegistry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let currentRoot = root.appending(path: "Current", directoryHint: .isDirectory)
        let priorPrefix = root.appending(
            path: "Prior/Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(currentRoot)
        try FileManager.default.createDirectory(
            at: try services.steamSharedPrefixURL(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: priorPrefix,
            withIntermediateDirectories: true
        )
        services.managedWineSessionRegistry.record(priorPrefix)

        let plan = services.appTerminationSteamShutdownPlan(runtimeExecutable: nil)

        XCTAssertTrue(plan.prefixes.contains {
            $0.standardizedFileURL.path == priorPrefix.standardizedFileURL.path
        })
    }

    func testTerminationPlanRetainsRecordedPrefixWhenExternalDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayUnavailableSessionPrefix-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let currentRoot = root.appending(path: "Current", directoryHint: .isDirectory)
        let unavailablePrefix = root.appending(
            path: "Disconnected/Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(currentRoot)
        services.managedWineSessionRegistry.record(unavailablePrefix)

        XCTAssertFalse(
            FileSystemItemPolicy.isNonSymlinkDirectory(
                unavailablePrefix,
                fileManager: .default
            )
        )

        let plan = services.appTerminationSteamShutdownPlan(runtimeExecutable: nil)

        XCTAssertTrue(plan.prefixes.contains {
            $0.standardizedFileURL.path == unavailablePrefix.standardizedFileURL.path
        })
        XCTAssertNil(plan.skippedReason)
    }

    func testTerminationPlanDoesNotAdoptUnavailableUntrackedPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayUnavailableUntrackedPrefix-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let currentRoot = root.appending(path: "Current", directoryHint: .isDirectory)
        let unavailableRoot = root.appending(
            path: "NeverUsed",
            directoryHint: .isDirectory
        )
        let unavailablePrefix = unavailableRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(currentRoot)

        let plan = services.appTerminationSteamShutdownPlan(
            runtimeExecutable: nil,
            additionalManagedRoots: [unavailableRoot]
        )

        XCTAssertFalse(plan.prefixes.contains {
            $0.standardizedFileURL.path == unavailablePrefix.standardizedFileURL.path
        })
    }

    func testTerminationPlanSkipsPrefixOwnedByAnotherForgePlayInstance() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayForeignRuntimeOwner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let owner = AppServices()
        try owner.steamPrefixService.claimRuntimeOwnership(forManagedRoot: root)
        let observer = AppServices()
        try observer.pathManager.configureRoot(root)

        let plan = observer.appTerminationSteamShutdownPlan(runtimeExecutable: nil)

        XCTAssertTrue(plan.prefixes.isEmpty)
        XCTAssertTrue(plan.initialErrors.isEmpty)
        XCTAssertTrue(plan.initialWarnings.contains { $0.contains("owned by another ForgePlay process") })
        XCTAssertEqual(plan.skippedReason, "no SteamShared prefix owned by this ForgePlay process")
    }

    func testRootChangeClaimsRuntimeOwnershipBeforeReturningForMissingPrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayEmptyRootOwnership-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let owner = AppServices()
        let summary = try await owner.shutdownSteamProcessesBeforeRootChange(
            from: root,
            runtimeExecutable: nil
        )

        XCTAssertEqual(summary.skippedReason, "the previous root has no SteamShared prefix")
        XCTAssertEqual(owner.steamPrefixService.runtimeOwnershipCountForTesting, 1)
        let observer = AppServices()
        XCTAssertThrowsError(
            try observer.steamPrefixService.claimRuntimeOwnership(forManagedRoot: root)
        ) { error in
            guard case ManagedRootOperationLeaseError.operationInProgress = error else {
                return XCTFail("Expected operationInProgress, got \(error)")
            }
        }
    }

    func testRootChangeDoesNotRequireRuntimeForInactiveInitializedPrefix() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Inactive prefix inspection requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayInactiveRootChange-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        try Data("{}\n".utf8).write(to: prefix.appending(path: "prefix.json"))

        let summary = try await services.shutdownSteamProcessesBeforeRootChange(
            from: root,
            runtimeExecutable: nil
        )

        XCTAssertEqual(summary.skippedReason, "the previous root has no active Steam or Wine process")
        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertTrue(summary.results.isEmpty)
        XCTAssertNil(summary.attemptedRuntimePath)
    }

    func testFailedManagedStorageRelocationReleasesNewDestinationOwnership() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRelocationOwnershipRollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = base.appending(path: "Source", directoryHint: .isDirectory)
        let destination = base.appending(path: "Destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: destination.appending(path: "existing.bin"))

        let services = AppServices()
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        context.insert(AppSettingsRecord(
            selectedRootPath: source.path,
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        ))
        try context.save()
        let appState = AppState()
        try appState.load(from: context)
        _ = try await services.prepareManagedStorageOnce(appState: appState, in: context)
        XCTAssertEqual(services.steamPrefixService.runtimeOwnershipCountForTesting, 1)

        do {
            _ = try await services.relocateManagedStorage(
                to: destination,
                destinationBookmark: nil,
                appState: appState,
                in: context,
                hasSteamReferences: false
            )
            XCTFail("Expected relocation into a non-empty destination to fail")
        } catch StorageMigrationError.destinationNotEmpty {
            // Expected from the read-only preflight, before destination ownership or shutdown.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(services.steamPrefixService.hasRuntimeOwnership(forManagedRoot: source))
        XCTAssertFalse(services.steamPrefixService.hasRuntimeOwnership(forManagedRoot: destination))
        XCTAssertEqual(services.steamPrefixService.runtimeOwnershipCountForTesting, 1)
        let observer = AppServices()
        try observer.steamPrefixService.claimRuntimeOwnership(forManagedRoot: destination)
    }

    func testFailedLegacyImportReleasesNewSourceOwnership() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayImportOwnershipRollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        let currentRoot = base.appending(path: "Current", directoryHint: .isDirectory)
        let invalidLegacySource = base.appending(path: "LegacyWithoutManagedData", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalidLegacySource, withIntermediateDirectories: true)

        let services = AppServices()
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        context.insert(AppSettingsRecord(
            selectedRootPath: currentRoot.path,
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        ))
        try context.save()
        let appState = AppState()
        try appState.load(from: context)
        _ = try await services.prepareManagedStorageOnce(appState: appState, in: context)

        do {
            _ = try await services.importLegacyManagedStorage(
                from: invalidLegacySource,
                sourceBookmark: nil,
                appState: appState,
                in: context,
                hasSteamReferences: false
            )
            XCTFail("Expected a legacy source without managed data to fail")
        } catch ManagedStorageActivationError.legacyRootDoesNotContainManagedData {
            // Expected after the source runtime ownership lease has been claimed.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(services.steamPrefixService.hasRuntimeOwnership(forManagedRoot: currentRoot))
        XCTAssertFalse(services.steamPrefixService.hasRuntimeOwnership(forManagedRoot: invalidLegacySource))
        let observer = AppServices()
        try observer.steamPrefixService.claimRuntimeOwnership(forManagedRoot: invalidLegacySource)
    }

    func testAppTerminationShutdownUsesSingleBundledRuntimeForSteamSharedPrefix() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        let marker = root.appending(path: "termination-shutdown-marker.txt")
        let runner = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            {
              printf 'WINEPREFIX=%s\\n' "$WINEPREFIX"
              printf 'ARGS=%s\\n' "$*"
            } >> "\(marker.path)"
            exit 0
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner()
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(summary.attemptedRuntimePath, runner.path)
        XCTAssertEqual(summary.results.count, 1)
        XCTAssertEqual(summary.results.first?.actionName, "shutdownWinePrefix")
        XCTAssertEqual(summary.results.first?.executable.lastPathComponent, "wineserver")

        let markerText = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(markerText.contains("WINEPREFIX=\(prefix.path)"), markerText)
        XCTAssertTrue(markerText.contains("ARGS=--kill=\(SIGTERM)"), markerText)
        XCTAssertTrue(markerText.contains("ARGS=-w"), markerText)
    }

    func testAppTerminationRestoresRetainedCompatibilityStateAfterWineShutdown() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayAppServicesTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        let shutdownMarker = root.appending(path: "termination-shutdown-order.txt")
        let restorationMarker = root.appending(path: "termination-restoration.txt")
        let runner = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            printf 'ARGS=%s\\n' "$*" >> "\(shutdownMarker.path)"
            exit 0
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner(),
            restoreRetainedCompatibilitySessions: { restoredPrefix in
                guard restoredPrefix.standardizedFileURL ==
                        prefix.standardizedFileURL else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "fixture-restoration-prefix"
                    )
                }
                let shutdownText = try String(
                    contentsOf: shutdownMarker,
                    encoding: .utf8
                )
                guard shutdownText.contains("ARGS=-w") else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "fixture-restoration-before-wine-shutdown"
                    )
                }
                try "restored".write(
                    to: restorationMarker,
                    atomically: true,
                    encoding: .utf8
                )
            }
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(
            try String(contentsOf: restorationMarker, encoding: .utf8),
            "restored"
        )
    }

    func testAppTerminationFailsClosedWhenRetainedCompatibilityRestorationFails() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayAppServicesTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        let runner = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\nexit 0\n"
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner(),
            restoreRetainedCompatibilitySessions: { _ in
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "fixture-restoration-failed"
                )
            }
        )

        XCTAssertFalse(summary.succeeded)
        XCTAssertTrue(
            summary.diagnosticDescription.contains(
                "retained compatibility restoration"
            ),
            summary.diagnosticDescription
        )
        XCTAssertTrue(
            summary.diagnosticDescription.contains("fixture-restoration-failed"),
            summary.diagnosticDescription
        )
    }

    func testAppTerminationShutdownIncludesAdditionalManagedSteamSharedPrefixes() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentRoot = root.appending(path: "CurrentRoot", directoryHint: .isDirectory)
        let additionalRoot = root.appending(path: "AdditionalRoot", directoryHint: .isDirectory)
        let additionalPrefix = additionalRoot.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let marker = root.appending(path: "termination-shutdown-prefixes.txt")
        let services = AppServices()
        try services.pathManager.configureRoot(currentRoot)
        try FileManager.default.createDirectory(at: additionalPrefix, withIntermediateDirectories: true)
        let currentPrefix = try services.steamSharedPrefixURL()
        let runner = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            {
              printf 'WINEPREFIX=%s\\n' "$WINEPREFIX"
              printf 'ARGS=%s\\n' "$*"
            } >> "\(marker.path)"
            exit 0
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [currentPrefix, additionalPrefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner()
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(Set(summary.prefixes.map(\.path)), Set([currentPrefix.path, additionalPrefix.path]))
        XCTAssertEqual(summary.results.count, 2)

        let markerText = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(markerText.contains("WINEPREFIX=\(currentPrefix.path)"), markerText)
        XCTAssertTrue(markerText.contains("WINEPREFIX=\(additionalPrefix.path)"), markerText)
    }

    func testAppTerminationUsesEmergencyLogsWhenManagedLogDirectoryIsUnavailable() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices()
        try services.pathManager.configureRoot(root)
        _ = try services.steamSharedPrefixURL()
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: logs)
        try Data("not a directory".utf8).write(to: logs)
        let runner = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\nexit 0\n"
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [try services.steamSharedPrefixURL()],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner()
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertTrue(summary.errors.isEmpty, summary.diagnosticDescription)
        XCTAssertTrue(summary.warnings.contains { $0.contains("using emergency logs") })
        XCTAssertEqual(summary.results.filter { $0.actionName == "shutdownWinePrefix" }.count, 1)
    }

    func testAppTerminationUnavailableRecordedPrefixFailsWithPreflightEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayUnavailableTermination-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let unavailablePrefix = root.appending(
            path: "Disconnected/Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let runner = try makeWineRunner(
            in: root.appending(path: "Bundled", directoryHint: .isDirectory),
            wineserverScript: "#!/bin/sh\nexit 0\n"
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [unavailablePrefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner()
        )

        XCTAssertFalse(summary.succeeded, summary.diagnosticDescription)
        XCTAssertNil(summary.skippedReason)
        XCTAssertTrue(summary.errors.contains { $0.contains(unavailablePrefix.path) })
        let preflight = try XCTUnwrap(summary.results.last)
        XCTAssertEqual(preflight.actionName, "shutdownWinePrefix:preflight")
        XCTAssertEqual(preflight.outcome, .preflightFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preflight.stderrLog.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(preflight.runEvidenceLog).path
        ))
    }

    func testAppTerminationDoesNotStartSteamForNonSteamManagedActivity()
        async throws
    {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        let steamExecutable = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steam.exe"
        )
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fake-steam".utf8).write(to: steamExecutable)

        let marker = root.appending(path: "termination-shutdown-order.txt")
        let activeProcessIDFile = root.appending(path: "termination-active-process-id.txt")
        let runner = try makeWineRunner(
            in: root,
            launcherScript: """
            #!/bin/sh
            printf 'steam:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            case "$*" in
              *-shutdown*)
                if [ -f "\(activeProcessIDFile.path)" ]; then
                  kill "$(cat "\(activeProcessIDFile.path)")" 2>/dev/null || true
                fi
                ;;
            esac
            exit 0
            """,
            wineserverScript: """
            #!/bin/sh
            printf 'wineserver:%s:%s\\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            case "$*" in
              *--kill*)
                if [ -f "\(activeProcessIDFile.path)" ]; then
                  kill "$(cat "\(activeProcessIDFile.path)")" 2>/dev/null || true
                fi
                ;;
            esac
            exit 0
            """
        )

        let processRunner = makeCuratedRuntimeRunner(sandboxEnabled: true)
        // Keep the synthetic process object alive until it reaches a terminal
        // state. Production Windows launches use the descriptor-bound process
        // owner; this test runtime deliberately bypasses that identity gate.
        // If the runner's tracking table becomes its sole owner, Foundation
        // can deinitialize Process while delivering its exit transition.
        let activeProcess = Process()
        activeProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        activeProcess.arguments = ["60"]
        activeProcess.currentDirectoryURL = prefix
        activeProcess.standardOutput = FileHandle.nullDevice
        activeProcess.standardError = FileHandle.nullDevice
        try activeProcess.run()
        var didReapActiveProcess = false
        defer {
            if !didReapActiveProcess {
                if activeProcess.isRunning {
                    _ = Darwin.kill(activeProcess.processIdentifier, SIGKILL)
                }
                activeProcess.waitUntilExit()
            }
        }
        await processRunner.trackDetachedProcess(activeProcess, for: prefix)
        try Data(String(activeProcess.processIdentifier).utf8).write(
            to: activeProcessIDFile
        )
        try Data().write(to: marker)

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: processRunner
        )

        let terminationDeadline = Date().addingTimeInterval(2)
        while activeProcess.isRunning, Date() < terminationDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(activeProcess.isRunning)
        if !activeProcess.isRunning {
            activeProcess.waitUntilExit()
            didReapActiveProcess = true
        }

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(
            summary.results.map(\.actionName),
            ["shutdownWinePrefix"]
        )
        XCTAssertTrue(summary.warnings.isEmpty, summary.diagnosticDescription)

        let markerLines = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        guard markerLines.count == 2 else {
            return XCTFail("Unexpected shutdown sequence:\n\(markerLines.joined(separator: "\n"))")
        }
        XCTAssertEqual(
            markerLines[0],
            "wineserver:\(prefix.path):--kill=\(SIGTERM)"
        )
        XCTAssertEqual(markerLines[1], "wineserver:\(prefix.path):-w")
    }

    func testAppTerminationRequestsGracefulShutdownOnlyForVerifiedSteamActivity()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayVerifiedSteamTermination-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let steamExecutable = WindowsSteamInstallationLayout.executable(
            in: prefix
        )
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fake-steam".utf8).write(to: steamExecutable)
        let marker = root.appending(path: "verified-steam-shutdown.txt")
        let runner = try makeWineRunner(
            in: root,
            launcherScript: """
            #!/bin/sh
            printf 'steam:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """,
            wineserverScript: """
            #!/bin/sh
            printf 'wineserver:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner(),
            managedSteamActivityInspector: { _ in true }
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(summary.results.map(\.actionName), [
            "requestSteamClientShutdown",
            "shutdownWinePrefix"
        ])
        let text = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(text.contains("steam.exe -shutdown"), text)
    }

    func testAppTerminationSteamActivityInspectionFailureNeverStartsSteam()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayUncertainSteamTermination-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let steamExecutable = WindowsSteamInstallationLayout.executable(
            in: prefix
        )
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fake-steam".utf8).write(to: steamExecutable)
        let marker = root.appending(path: "uncertain-steam-shutdown.txt")
        let runner = try makeWineRunner(
            in: root,
            launcherScript: """
            #!/bin/sh
            printf 'unexpected-steam\n' >> "\(marker.path)"
            exit 0
            """,
            wineserverScript: """
            #!/bin/sh
            printf 'wineserver:%s\n' "$*" >> "\(marker.path)"
            exit 0
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner(),
            managedSteamActivityInspector: { _ in
                throw FailureEvidenceSensitivePathError(
                    detail: "fixture inspection unavailable"
                )
            }
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(
            summary.results.map(\.actionName),
            ["shutdownWinePrefix"]
        )
        XCTAssertTrue(
            summary.warnings.joined(separator: " ").contains(
                "fixture inspection unavailable"
            ),
            summary.diagnosticDescription
        )
        let text = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertFalse(text.contains("unexpected-steam"), text)
    }

    func testAppTerminationDoesNotLaunchSteamShutdownForInactivePrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayInactiveTerminationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fake-steam".utf8).write(to: steamExecutable)

        let marker = root.appending(path: "inactive-termination-order.txt")
        let runner = try makeWineRunner(
            in: root,
            launcherScript: """
            #!/bin/sh
            printf 'unexpected-steam:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """,
            wineserverScript: """
            #!/bin/sh
            printf 'wineserver:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: runner,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner()
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(summary.results.map(\.actionName), ["shutdownWinePrefix"])
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            """
            wineserver:\(prefix.path):--kill=\(SIGTERM)
            wineserver:\(prefix.path):-w
            """
        )
    }

    func testSuccessfulForceStopThenImmediateTerminationRunsNoWineAction()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayForceStopTermination-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        let rendererBackupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rendererBackupDirectory,
            withIntermediateDirectories: true
        )
        let rendererMarker = rendererBackupDirectory.appending(
            path: SteamRendererPolicyManager
                .nvidiaMetalFXRegistrySessionMarkerName
        )
        let markerData = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "projections": [[
                    "registryPath": SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreRegistryPath,
                    "valueName": SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName,
                    "stagedValue": SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreSystem32Path
                ]]
            ],
            options: [.sortedKeys]
        )
        try markerData.write(to: rendererMarker, options: .atomic)

        let forceResult = await services
            .forceTerminateAllForgePlayWineProcesses(forceTerminator: {
                StartupWineProcessCleanupResult(
                    initiallyTargetedProcessIDs: [41, 42],
                    remainingProcessIDs: [],
                    inspectionFailures: [],
                    signalFailures: []
                )
            })
        XCTAssertTrue(forceResult.succeeded)

        let summary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil,
            selectedRootURL: root,
            wineProcessInspector: {
                StartupWineProcessCleanupPlan(
                    targets: [],
                    inspectionFailures: []
                )
            }
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertTrue(summary.results.isEmpty, summary.diagnosticDescription)
        XCTAssertNil(summary.attemptedRuntimePath)
        XCTAssertEqual(summary.prefix, prefix)
        XCTAssertTrue(
            summary.skippedReason?.contains(
                "verified no ForgePlay Wine processes"
            ) == true,
            summary.diagnosticDescription
        )
        XCTAssertTrue(
            services.steamPrefixLifecycleCoordinator.isTerminating,
            "The earlier force-stop reset must not reopen launch admission after quit begins"
        )
        XCTAssertEqual(try Data(contentsOf: rendererMarker), markerData)
        let rendererPolicyManager = SteamRendererPolicyManager()
        XCTAssertTrue(
            rendererPolicyManager.hasRecoverableNVIDIAMetalFXRegistrySession(
                in: prefix
            )
        )
        XCTAssertTrue(
            SteamManager.requiresPriorNVIDIARestoration(
                requestedSelection: .d3dMetalNVIDIA,
                hasRecoverableModuleResidue: false,
                hasRecoverableRegistryResidue: true,
                hasActiveSession: false
            ),
            "The next explicit prelaunch must consume the durable NVIDIA restoration marker"
        )
    }

    func testForceStopBoundsNonCooperativeBackgroundDrainAndIssuesNoProof()
        async throws
    {
        let services = AppServices()
        let owner = NonDrainingCompatibilityBackgroundOwner()
        try services.steamPrefixService
            .retainFailedCompatibilityCleanupOwner(owner)
        let startedAt = Date()

        let result = await services.forceTerminateAllForgePlayWineProcesses(
            forceTerminator: {
                StartupWineProcessCleanupResult(
                    initiallyTargetedProcessIDs: [71],
                    remainingProcessIDs: [],
                    inspectionFailures: [],
                    signalFailures: []
                )
            },
            initialDrainTimeout: 0.01,
            finalDrainTimeout: 0.02
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(
            result.inspectionFailures.contains {
                $0.contains("background work did not drain")
            },
            String(describing: result.inspectionFailures)
        )

        owner.markBackgroundWorkCompleted()
        let summary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil,
            wineProcessInspector: {
                StartupWineProcessCleanupPlan(
                    targets: [],
                    inspectionFailures: []
                )
            }
        )
        XCTAssertFalse(summary.succeeded)
        XCTAssertEqual(owner.completionAttempts, 1)
        XCTAssertTrue(
            summary.errors.joined(separator: " ").contains(
                "fixture retained cleanup reached"
            ),
            summary.diagnosticDescription
        )
    }

    func testAppTerminationDoesNotFallbackToAnotherRuntimeAfterBundledRuntimeFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayTerminationSingleRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let marker = root.appending(path: "termination-single-runtime.txt")
        let bundledRuntime = try makeWineRunner(
            in: root.appending(path: "Bundled", directoryHint: .isDirectory),
            wineserverScript: """
            #!/bin/sh
            printf 'bundled-wineserver:%s\n' "$*" >> "\(marker.path)"
            exit 8
            """
        )

        let summary = await AppServices.executeAppTerminationSteamShutdown(
            AppTerminationSteamShutdownPlan(
                prefixes: [prefix],
                runtimeExecutable: bundledRuntime,
                initialErrors: [],
                skippedReason: nil
            ),
            safeProcessRunner: makeCuratedRuntimeRunner(sandboxEnabled: true)
        )

        XCTAssertFalse(summary.succeeded)
        XCTAssertEqual(summary.attemptedRuntimePath, bundledRuntime.path)
        XCTAssertEqual(summary.results.count, 1)
        let markerText = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(
            markerText.contains("bundled-wineserver:--kill=\(SIGTERM)"),
            markerText
        )
        XCTAssertFalse(markerText.contains("fallback"), markerText)
    }

    func testPreflightPrefixShutdownDoesNotStartSteamToStopIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPreflightShutdownTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("fake-steam".utf8).write(to: steamExecutable)

        let marker = root.appending(path: "preflight-shutdown-order.txt")
        let wine = try makeWineRunner(
            in: root,
            launcherScript: """
            #!/bin/sh
            printf 'unexpected-steam:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """,
            wineserverScript: """
            #!/bin/sh
            printf 'wineserver:%s:%s\n' "$WINEPREFIX" "$*" >> "\(marker.path)"
            exit 0
            """
        )
        let supervisor = SteamPrefixProcessSupervisor(
            runner: makeCuratedRuntimeRunner(sandboxEnabled: true)
        )

        let result = try await supervisor.shutdownBeforeLaunch(
            runtimeExecutable: wine,
            prefix: prefix,
            logDirectory: logs
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            """
            wineserver:\(prefix.path):--kill=\(SIGTERM)
            wineserver:\(prefix.path):-w
            """
        )
    }

    func testSteamPrefixPreparationUsesBundledRuntimeProbeBeforePrefixInitialization() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/App/AppServices.swift"),
            encoding: .utf8
        )
        let preparation = try XCTUnwrap(
            source.range(of: "func prepareSteamPrefix(")
                .map { String(source[$0.lowerBound...]) }
        )

        XCTAssertTrue(preparation.contains("windowsRuntimeService.probeAndValidate"))
        XCTAssertTrue(preparation.contains("steamPrefixService.prepareSharedPrefix"))
        XCTAssertLessThan(
            try XCTUnwrap(preparation.range(of: "windowsRuntimeService.probeAndValidate")?.lowerBound),
            try XCTUnwrap(preparation.range(of: "steamPrefixService.prepareSharedPrefix")?.lowerBound)
        )
    }

    func testSetupStageStillRequiresSteamPrefixWhenSteamReferencesExist() {
        let appState = AppState()
        appState.selectedRootURL = URL(fileURLWithPath: "/tmp/ForgePlay")
        appState.latestChecks = [
            SystemCheckResult(
                title: "Mac 상태 확인",
                detail: "OK",
                status: .ok,
                technicalDetail: nil
            )
        ]
        appState.runtimeExecutableURL = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine/bin/wine")

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: true,
            steamPrefixURL: nil,
            steamExecutableURL: nil
        ))

        XCTAssertEqual(appState.setupStage, .prepareSteamEnvironment)
    }

    func testSetupStageRequiresSteamPathWhenNoSteamReferencesExist() {
        let appState = AppState()
        appState.selectedRootURL = URL(fileURLWithPath: "/tmp/ForgePlay")
        appState.latestChecks = [
            SystemCheckResult(
                title: "Mac 상태 확인",
                detail: "OK",
                status: .ok,
                technicalDetail: nil
            )
        ]
        appState.runtimeExecutableURL = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine/bin/wine")

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: nil,
            steamExecutableURL: nil
        ))
        XCTAssertEqual(appState.setupStage, .prepareSteamEnvironment)

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"),
            steamExecutableURL: nil
        ))
        XCTAssertEqual(appState.setupStage, .installSteam)

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared/drive_c/Steam/steam.exe"),
            runtimeCompatibilityInspection: .migrationRequired("legacy binding")
        ))
        XCTAssertEqual(appState.setupStage, .authenticateSteam)
    }

    func testSetupStageTreatsRuntimeDiagnosticsAsAdvisory() {
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let scenarios: [(
            technicalDetail: String,
            readiness: SetupReadiness,
            expectedStage: SetupStage
        )] = [
            (
                "/tmp/runtime_probe-stderr.log",
                SetupReadiness(
                    hasSteamPrefix: false,
                    hasSteamExecutable: false,
                    hasSteamReferences: false,
                    steamPrefixURL: prefix,
                    steamExecutableURL: nil
                ),
                .prepareSteamEnvironment
            ),
            (
                "limitations: missing-wine-gnutls-runtime. executable: /tmp/ForgePlayRuntime/wine/bin/wine",
                SetupReadiness(
                    hasSteamPrefix: true,
                    hasSteamExecutable: true,
                    hasSteamReferences: false,
                    steamPrefixURL: prefix,
                    steamExecutableURL: steam,
                    runtimeCompatibilityInspection: .runtimeUnavailable("runtime manifest unavailable")
                ),
                .authenticateSteam
            )
        ]

        for scenario in scenarios {
            let appState = readyAppStateForSetupStageTests()
            appState.latestChecks = orderedSystemChecks(
                runtimeStatus: .error,
                runtimeTechnicalDetail: scenario.technicalDetail,
                steamPrefixStatus: .warning
            )

            appState.updateSetupStage(readiness: scenario.readiness)

            XCTAssertEqual(
                appState.setupStage,
                scenario.expectedStage,
                "Runtime diagnostics must not replace the concrete setup stage: \(scenario.technicalDetail)"
            )
        }
    }

    func testSetupStageRoutesPrefixErrorToSteamEnvironmentPreparation() {
        let appState = readyAppStateForSetupStageTests()
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        appState.latestChecks = orderedSystemChecks(
            steamPrefixStatus: .error,
            steamPrefixTechnicalDetail: "PrefixUsabilityError.invalidMetadata"
        )

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: nil,
            steamPrefixIssue: .invalidMetadata(
                prefix.appending(path: "prefix.json"),
                "invalid fixture metadata"
            )
        ))

        XCTAssertEqual(appState.setupStage, .prepareSteamEnvironment)
    }

    func testSetupStageKeepsMachineAndStorageErrorsAtFoundationStages() {
        let readiness = SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"),
            steamExecutableURL: nil
        )
        let machineFailure = readyAppStateForSetupStageTests()
        machineFailure.latestChecks = orderedSystemChecks(operatingSystemStatus: .error)
        machineFailure.updateSetupStage(readiness: readiness)
        XCTAssertEqual(machineFailure.setupStage, .checkMac)

        let storageFailure = readyAppStateForSetupStageTests()
        storageFailure.latestChecks = orderedSystemChecks(storageStatus: .error)
        storageFailure.updateSetupStage(readiness: readiness)
        XCTAssertEqual(storageFailure.setupStage, .chooseRoot)
    }

    func testSetupStageRoutingUsesCheckCategoriesInsteadOfResultOrder() {
        let readiness = SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"),
            steamExecutableURL: nil
        )
        let appState = readyAppStateForSetupStageTests()
        appState.latestChecks = Array(orderedSystemChecks(runtimeStatus: .error).reversed())

        appState.updateSetupStage(readiness: readiness)

        XCTAssertEqual(appState.setupStage, .prepareSteamEnvironment)
    }

    func testSteamPrefixStateSeparatesOperationalReadinessFromLaunchEvidence() {
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let unverified = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: steam
        )

        XCTAssertEqual(unverified.steamPrefixState, .rendererUnverified)
        XCTAssertFalse(unverified.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(unverified.canAttemptWindowsSteamLaunch)

        let runtimeMigrationRequired = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: steam,
            runtimeCompatibilityInspection: .migrationRequired("legacy binding")
        )

        XCTAssertEqual(runtimeMigrationRequired.steamPrefixState, .runtimeMigrationRequired)
        XCTAssertTrue(runtimeMigrationRequired.canAttemptWindowsSteamLaunch)

        let needsApply = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: steam,
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .warning,
                userMessage: "renderer needs apply",
                appliedModules: [],
                missingModules: ["system32/d3d11.dll"],
                mixedModules: []
            )
        )

        XCTAssertEqual(needsApply.steamPrefixState, .rendererNeedsApply)
        XCTAssertFalse(needsApply.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(needsApply.canAttemptWindowsSteamLaunch)
        XCTAssertEqual(needsApply.rendererInspection?.recoveryStatusLabelKey, "Steam 실행 경로 적용 필요")
        XCTAssertEqual(needsApply.rendererInspection?.recoveryActionTitleKey, "실행 경로 적용/검증")
        XCTAssertEqual(needsApply.rendererInspection?.setupRecoveryActionTitleKey, "Steam 실행 경로 적용")

        let needsRepair = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: steam,
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .error,
                userMessage: "mixed Steam launch path",
                appliedModules: ["system32/d3d11.dll"],
                missingModules: [],
                mixedModules: ["syswow64/dxgi.dll"]
            )
        )

        XCTAssertEqual(needsRepair.steamPrefixState, .rendererNeedsRepair)
        XCTAssertFalse(needsRepair.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(needsRepair.canAttemptWindowsSteamLaunch)
        XCTAssertEqual(needsRepair.rendererInspection?.recoveryStatusLabelKey, "Steam 실행 경로 정비 필요")
        XCTAssertEqual(needsRepair.rendererInspection?.recoveryActionTitleKey, "실행 경로 정비/검증")
        XCTAssertEqual(needsRepair.rendererInspection?.setupRecoveryActionTitleKey, "Steam 실행 경로 정비")
        XCTAssertTrue(needsRepair.rendererInspection?.allowsRecoveryAction == true)

        let runtimeUnavailable = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: steam,
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: nil,
                status: .error,
                userMessage: "runtime cannot render Windows Steam",
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                recoveryKind: .runtimeUnavailable
            )
        )

        XCTAssertEqual(runtimeUnavailable.steamPrefixState, .runtimeUnavailable)
        XCTAssertFalse(runtimeUnavailable.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(runtimeUnavailable.canAttemptWindowsSteamLaunch)
        XCTAssertEqual(runtimeUnavailable.rendererInspection?.recoveryStatusLabelKey, "ForgePlay Runtime 교체 필요")
        XCTAssertEqual(runtimeUnavailable.rendererInspection?.recoveryActionTitleKey, "Runtime 확인")
        XCTAssertEqual(runtimeUnavailable.rendererInspection?.setupRecoveryActionTitleKey, "Runtime 확인")
        XCTAssertTrue(runtimeUnavailable.rendererInspection?.allowsRecoveryAction == false)

        let operationallyReady = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: steam,
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .ok,
                userMessage: "renderer ready",
                appliedModules: ["system32/d3d11.dll"],
                missingModules: [],
                mixedModules: []
            )
        )

        XCTAssertEqual(operationallyReady.steamPrefixState, .launchReady)
        XCTAssertFalse(operationallyReady.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(operationallyReady.canAttemptWindowsSteamLaunch)
        XCTAssertTrue(operationallyReady.hasAppliedRendererPolicyForSteam)

        let blackScreen = operationallyReady.withSteamUIVerification(.blackScreenSuspected)

        XCTAssertEqual(blackScreen.steamPrefixState, .launchReady)
        XCTAssertFalse(blackScreen.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(blackScreen.canAttemptWindowsSteamLaunch)

        let launchFailed = operationallyReady.withSteamUIVerification(.failed)

        XCTAssertEqual(launchFailed.steamPrefixState, .launchReady)
        XCTAssertFalse(launchFailed.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(launchFailed.canAttemptWindowsSteamLaunch)

        let visuallyVerified = operationallyReady.withSteamUIVerification(.rendered)

        XCTAssertEqual(visuallyVerified.steamPrefixState, .launchReady)
        XCTAssertTrue(visuallyVerified.hasVerifiedWindowsSteamUI)
        XCTAssertTrue(visuallyVerified.canAttemptWindowsSteamLaunch)
    }

    func testSetupStageTreatsUnverifiedRendererAsAdvisory() {
        let appState = AppState()
        appState.selectedRootURL = URL(fileURLWithPath: "/tmp/ForgePlay")
        appState.latestChecks = [
            SystemCheckResult(
                title: "Mac 상태 확인",
                detail: "OK",
                status: .ok,
                technicalDetail: nil
            )
        ]
        appState.runtimeExecutableURL = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine/bin/wine")

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe")
        ))

        XCTAssertEqual(appState.setupStage, .authenticateSteam)
    }

    func testSetupStageKeepsRendererApplyAndRepairStatesLaunchable() {
        let appState = readyAppStateForSetupStageTests()
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")

        for inspection in [
            SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .warning,
                userMessage: "apply",
                appliedModules: [],
                missingModules: ["system32/dxgi.dll"],
                mixedModules: []
            ),
            SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .error,
                userMessage: "repair",
                appliedModules: ["system32/dxgi.dll"],
                missingModules: [],
                mixedModules: ["syswow64/dxgi.dll"]
            )
        ] {
            appState.updateSetupStage(readiness: SetupReadiness(
                hasSteamPrefix: true,
                hasSteamExecutable: true,
                hasSteamReferences: false,
                steamPrefixURL: prefix,
                steamExecutableURL: steam,
                rendererInspection: inspection
            ))
            XCTAssertEqual(appState.setupStage, .authenticateSteam)
        }
    }

    func testSetupStageRequiresAuthenticatedLibraryBeforeReady() {
        let appState = AppState()
        appState.selectedRootURL = URL(fileURLWithPath: "/tmp/ForgePlay")
        appState.latestChecks = [
            SystemCheckResult(
                title: "Mac 상태 확인",
                detail: "OK",
                status: .ok,
                technicalDetail: nil
            )
        ]
        appState.runtimeExecutableURL = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine/bin/wine")
        let operationallyReady = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"),
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .ok,
                userMessage: "renderer ready",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            ),
            steamEnvironmentCreatedAt: .distantPast
        )

        appState.updateSetupStage(readiness: operationallyReady)
        XCTAssertEqual(appState.setupStage, .authenticateSteam)

        let libraryRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            hostAppSessionID: "app-session-1"
        )
        libraryRecord.markSteamUISurface(.library)
        appState.updateSetupStage(
            readiness: projectingSteamLaunchReadiness(
                operationallyReady,
                records: [libraryRecord]
            )
        )
        XCTAssertEqual(appState.setupStage, .ready)

        let relaunchedLibraryRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            hostAppSessionID: "app-session-2"
        )
        relaunchedLibraryRecord.markSteamUISurface(.library)
        let thirdSessionReadiness = projectingSteamLaunchReadiness(
            operationallyReady,
            records: [libraryRecord, relaunchedLibraryRecord],
            currentAppSessionID: "app-session-3"
        )
        XCTAssertFalse(thirdSessionReadiness.hasVerifiedAuthenticatedLibrary)
        XCTAssertTrue(thirdSessionReadiness.hasVerifiedSessionPersistence)

        appState.updateSetupStage(readiness: thirdSessionReadiness)
        XCTAssertEqual(appState.setupStage, .ready)

        let failedCurrentSessionRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date().addingTimeInterval(60),
            hostAppSessionID: "app-session-3"
        )
        failedCurrentSessionRecord.markSteamUIBlackScreenSuspected()
        let failedCurrentSessionReadiness = projectingSteamLaunchReadiness(
            operationallyReady,
            records: [libraryRecord, relaunchedLibraryRecord, failedCurrentSessionRecord],
            currentAppSessionID: "app-session-3"
        )
        XCTAssertTrue(failedCurrentSessionReadiness.hasVerifiedSessionPersistence)
        XCTAssertEqual(failedCurrentSessionReadiness.steamUIVerificationState, .blackScreenSuspected)

        appState.updateSetupStage(readiness: failedCurrentSessionReadiness)
        XCTAssertEqual(appState.setupStage, .authenticateSteam)

        let signInCurrentSessionRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date().addingTimeInterval(120),
            hostAppSessionID: "app-session-3"
        )
        signInCurrentSessionRecord.markSteamUISurface(.signIn)
        let signInCurrentSessionReadiness = projectingSteamLaunchReadiness(
            operationallyReady,
            records: [libraryRecord, relaunchedLibraryRecord, signInCurrentSessionRecord],
            currentAppSessionID: "app-session-3"
        )
        XCTAssertTrue(signInCurrentSessionReadiness.hasVerifiedSessionPersistence)
        XCTAssertTrue(signInCurrentSessionReadiness.currentSteamSurfaceRequiresAuthentication)
        XCTAssertFalse(signInCurrentSessionReadiness.hasUsableAuthenticatedSteamSession)

        appState.updateSetupStage(readiness: signInCurrentSessionReadiness)
        XCTAssertEqual(appState.setupStage, .authenticateSteam)
    }

    func testSetupStageDoesNotTreatLocalAccountArtifactsAsAuthenticatedSession() {
        let appState = readyAppStateForSetupStageTests()
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared")
        let readiness = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: prefix,
            steamExecutableURL: prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe"),
            rendererInspection: SteamRendererPolicyInspection(
                selection: .d3dMetal,
                resolvedPolicy: .d3dMetal,
                status: .ok,
                userMessage: "renderer ready",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            ),
            steamSessionInspection: SteamSessionInspection(
                state: .rememberedSignInConfigured,
                accountCount: 1,
                userDataDirectoryCount: 1,
                issue: nil
            )
        )

        XCTAssertTrue(readiness.hasDetectedSteamAccountSession)
        appState.updateSetupStage(readiness: readiness)
        XCTAssertEqual(appState.setupStage, .authenticateSteam)
    }

    func testSteamPrefixServiceResolvesD3DMetalPolicyForSteamCapableRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamPrefixServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let launcher = try makeD3DMetalSteamRuntime(at: root)

        let resolution = try services.steamPrefixService.resolveRendererPolicy(
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )

        XCTAssertEqual(resolution.rendererPolicy, .d3dMetal)
        XCTAssertTrue(resolution.capability.supportsWindowsSteamClientLaunches)
        XCTAssertTrue(resolution.capability.supportsManagedSteamGameLaunches)
    }

    func testSteamPrefixServiceRejectsKnownSteamBlackScreenRuntimeBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamPrefixServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let launcher = try makeD3DMetalSteamRuntime(
            at: root,
            winemacMarker: "Cross-process child window Metal swapchains are not implemented"
        )

        do {
            _ = try services.steamPrefixService.resolveRendererPolicy(
                runtimeExecutable: launcher,
                selection: .d3dMetal
            )
            XCTFail("Expected the Steam WebHelper black-screen Runtime to be rejected before launch")
        } catch WindowsRuntimeServiceError.missingSteamRendererCapability(let capability) {
            XCTAssertTrue(capability.supportsModernDirect3DGames)
            XCTAssertTrue(capability.supportsSteamClientNetworking)
            XCTAssertFalse(capability.supportsWindowsSteamClientLaunches)
            XCTAssertTrue(capability.limitations.contains("steam-cef-child-window-metal-swapchain-unsupported"))
        }
    }

    func testNewSteamPrefixPersistsAutomaticServerSynchronizationPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamPrefixSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let metadata = try services.prefixManager.createSteamSharedPrefix()

        XCTAssertEqual(metadata.synchronizationSelection, .automatic)
        XCTAssertEqual(metadata.synchronizationBackend, .server)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: metadata.path).appending(path: "prefix.json").path
            )
        )
    }

    func testSteamPrefixSynchronizationAlwaysUsesStandardServer() {
        let capabilities = WineSynchronizationRuntimeCapabilities(
            supportedBackends: [.server]
        )

        XCTAssertEqual(WineSynchronizationSelection.allCases, [.automatic])
        XCTAssertEqual(WineSynchronizationBackend.allCases, [.server])
        XCTAssertEqual(
            try? SteamPrefixService.resolveSynchronizationBackend(
                selection: .automatic,
                capabilities: capabilities
            ),
            WineSynchronizationBackend.server
        )
    }

    func testSteamPrefixServiceRejectsUnsupportedRuntimeBeforeSteamInstallProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamPrefixInstallTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let prefix = try services.steamSharedPrefixURL()
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let launcher = root.appending(path: "wine")
        try """
        #!/bin/sh
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let installer = root.appending(path: "SteamSetup.exe")
        try Data("not a real installer".utf8).write(to: installer)

        do {
            _ = try await services.steamPrefixService.installSteam(
                runtimeExecutable: launcher,
                installer: installer,
                language: .english
            )
            XCTFail("Expected the unsupported Runtime to be rejected before the Steam installer process")
        } catch WindowsRuntimeServiceError.missingSteamRendererCapability(let capability) {
            XCTAssertFalse(capability.supportsWindowsSteamClientLaunches)
            XCTAssertFalse(capability.supportsManagedSteamGameLaunches)
        }

        let installLogs = try services.pathManager.url(for: .installLogs)
        let installLogEntries = try FileManager.default.contentsOfDirectory(
            at: installLogs,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            installLogEntries.isEmpty,
            "Steam installer process should not start after Runtime preflight rejection"
        )
    }

    func testFreshSteamLanguageClaimPersistsReadBackOwnershipAndLaunchArgument() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageFresh-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                writes.append(language)
                try self.writeSteamLanguageRegistry(
                    language.rawValue,
                    to: prefix
                )
            }
        )

        let claimedLease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )
        let lease = try XCTUnwrap(claimedLease)

        XCTAssertEqual(writes, [.koreana])
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(try policy.hasOwnershipMarker(in: prefix))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: SteamClientLanguageOwnershipPolicy
                    .markerURL(in: prefix).path
            )[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertEqual(
            SteamClientLanguageOwnershipPolicy.launchArguments(
                baseArguments: ["-no-cef-sandbox"],
                lease: lease
            ),
            ["-no-cef-sandbox", "-language", "koreana"]
        )
    }

    func testSteamLanguageUserControlReadinessRequiresFreshUsableSteamSurfaceAndMatchingWebHelperLocale() throws {
        let processOnly = SteamWebHelperStartupObservation(
            state: .ready,
            reason: nil,
            steamUIHTMLTail: [],
            consoleTail: [],
            webHelperTail: ["Starting message loop"]
        )
        XCTAssertNil(SteamClientLanguageUserControlReadiness(
            observation: processOnly,
            language: .koreana,
            webHelperLanguageReadback: steamLanguageReadback(.koreana)
        ))

        let browserReadyDespiteBroaderPendingState = SteamWebHelperStartupObservation(
            state: .pending,
            reason: nil,
            steamUIHTMLTail: ["BrowserReady: handle:65536"],
            consoleTail: [],
            webHelperTail: [],
            sharedContextReadiness: .ready,
            usableUIReadiness: .pending
        )
        XCTAssertNil(SteamClientLanguageUserControlReadiness(
            observation: browserReadyDespiteBroaderPendingState,
            language: .koreana,
            webHelperLanguageReadback: steamLanguageReadback(.koreana)
        ))

        XCTAssertNil(SteamClientLanguageUserControlReadiness(
            observation: steamUsableUIObservation(),
            language: .koreana,
            webHelperLanguageReadback: steamLanguageReadback(.english)
        ))
        XCTAssertNil(SteamClientLanguageUserControlReadiness(
            observation: steamUsableUIObservation(),
            language: .koreana,
            webHelperLanguageReadback: SteamWebHelperLanguageReadback(
                state: .evidenceUnavailable,
                observedLocaleIdentifiers: []
            )
        ))

        let readiness = try XCTUnwrap(
            SteamClientLanguageUserControlReadiness(
                observation: steamUsableUIObservation(),
                language: .koreana,
                webHelperLanguageReadback: steamLanguageReadback(.koreana)
            )
        )
        XCTAssertEqual(readiness.language, .koreana)
    }

    func testUnownedSteamLanguageRegistryIsNeverClaimedOrOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageUnowned-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try writeSteamLanguageRegistry("english", to: prefix)
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, _, _, language in
                writes.append(language)
            }
        )

        let lease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )

        XCTAssertNil(lease)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "english"
        )
        XCTAssertFalse(try policy.hasOwnershipMarker(in: prefix))
    }

    func testFreshSteamLanguageClaimRejectsExistingSteamExecutableWithoutRegistryState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageExistingExecutable-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing-steam".utf8).write(to: steamExecutable)
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, _, _, language in
                writes.append(language)
            }
        )

        let lease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )

        XCTAssertNil(lease)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(try policy.observedRegistryLanguageToken(in: prefix))
        XCTAssertFalse(try policy.hasOwnershipMarker(in: prefix))
    }

    func testPartialInstallerRetryResumesPendingLanguageClaimWithExistingSteamExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageInstallerRetry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                writes.append(language)
                try self.writeSteamLanguageRegistry(
                    language.rawValue,
                    to: prefix
                )
            }
        )
        let initialLease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .english
        )
        XCTAssertNotNil(initialLease)

        // A failed/partial SteamSetup transaction can leave both steam.exe and
        // an installer-written registry value behind before service setup.
        try Data("partial-steam".utf8).write(to: steamExecutable)
        try writeSteamLanguageRegistry("english", to: prefix)
        let resumedLease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )

        XCTAssertEqual(resumedLease?.language, .koreana)
        XCTAssertEqual(writes, [.english, .koreana])
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(try policy.hasOwnershipMarker(in: prefix))
    }

    func testPostUsableUIOwnedLanguageClaimIsNeverReclaimedWhenSteamExecutableIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageOwnedReinstall-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                writes.append(language)
                try self.writeSteamLanguageRegistry(
                    language.rawValue,
                    to: prefix
                )
            }
        )
        let claimedLease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )
        let lease = try XCTUnwrap(claimedLease)
        XCTAssertTrue(
            try policy.markSteamUserControlAvailable(
                lease,
                readiness: try XCTUnwrap(
                    SteamClientLanguageUserControlReadiness(
                        observation: steamUsableUIObservation(),
                        language: .koreana,
                        webHelperLanguageReadback:
                            steamLanguageReadback(.koreana)
                    )
                ),
                in: prefix
            )
        )
        writes.removeAll()

        let reclaimedLease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .german
        )

        XCTAssertNil(reclaimedLease)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(try policy.hasOwnershipMarker(in: prefix))
    }

    func testContradictoryPendingAfterUsableUILanguageMarkerFailsClosedWithoutRegistryWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageContradictoryMarker-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        let marker = #"""
        {
          "claimID" : "00000000-0000-0000-0000-000000000001",
          "schemaVersion" : 1,
          "state" : "pending",
          "steamLanguage" : "koreana",
          "userControlBoundaryReached" : true,
          "webHelperLocaleIdentifier" : "ko_KR"
        }
        """#
        try marker.write(
            to: SteamClientLanguageOwnershipPolicy.markerURL(in: prefix),
            atomically: true,
            encoding: .utf8
        )
        var writeCount = 0
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, _, _, _ in writeCount += 1 }
        )

        do {
            _ = try await policy.claimFreshInstallation(
                runtimeExecutable: root.appending(path: "wine"),
                prefix: prefix,
                logDirectory: root,
                language: .german
            )
            XCTFail("A pending marker cannot cross the usable Steam UI boundary")
        } catch is SteamClientLanguageOwnershipError {
            XCTAssertEqual(writeCount, 0)
        }
    }

    func testUsableUILanguageMismatchRelinquishesWithoutRegistryWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageReadback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                writes.append(language)
                try self.writeSteamLanguageRegistry(
                    language.rawValue,
                    to: prefix
                )
            }
        )
        let claimedLease = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )
        let initialLease = try XCTUnwrap(claimedLease)
        try writeSteamLanguageRegistry("english", to: prefix)
        writes.removeAll()

        let readiness = try XCTUnwrap(
            SteamClientLanguageUserControlReadiness(
                observation: steamUsableUIObservation(),
                language: .koreana,
                webHelperLanguageReadback: steamLanguageReadback(.koreana)
            )
        )
        XCTAssertFalse(
            try policy.markSteamUserControlAvailable(
                initialLease,
                readiness: readiness,
                in: prefix
            )
        )
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "english"
        )
        XCTAssertFalse(try policy.hasOwnershipMarker(in: prefix))

        let relinquishedLease = try await policy.prepareForLaunch(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root
        )

        XCTAssertNil(relinquishedLease)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "english"
        )
        XCTAssertFalse(try policy.hasOwnershipMarker(in: prefix))
    }

    func testOwnedSteamLanguageFollowsAppLanguageUntilSteamTakesOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageAppOwnership-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                writes.append(language)
                try self.writeSteamLanguageRegistry(
                    language.rawValue,
                    to: prefix
                )
            }
        )
        let claimedInstallation = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .english
        )
        let claimedLease = try XCTUnwrap(claimedInstallation)
        _ = try await policy.reaffirm(
            claimedLease,
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root
        )

        let preparedKoreanLease = try await policy.prepareForLaunch(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            desiredLanguage: .koreana
        )
        let koreanLease = try XCTUnwrap(preparedKoreanLease)

        XCTAssertEqual(koreanLease.language, .koreana)
        XCTAssertEqual(writes, [.english, .koreana])
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(
            try policy.markSteamUserControlAvailable(
                koreanLease,
                readiness: try XCTUnwrap(
                    SteamClientLanguageUserControlReadiness(
                        observation: steamUsableUIObservation(),
                        language: .koreana,
                        webHelperLanguageReadback:
                            steamLanguageReadback(.koreana)
                    )
                ),
                in: prefix
            )
        )

        try writeSteamLanguageRegistry("french", to: prefix)
        let relinquishedLease = try await policy.prepareForLaunch(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            desiredLanguage: .german
        )

        XCTAssertNil(relinquishedLease)
        XCTAssertEqual(writes, [.english, .koreana])
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "french"
        )
        XCTAssertFalse(try policy.hasOwnershipMarker(in: prefix))
    }

    func testFailedServicePreparationKeepsFreshLanguageClaimResumable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageServiceRetry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        var writes: [SteamClientLanguage] = []
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                writes.append(language)
                try self.writeSteamLanguageRegistry(
                    language.rawValue,
                    to: prefix
                )
            }
        )
        _ = try await policy.claimFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )
        _ = try await policy.resumeFreshInstallation(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root,
            language: .koreana
        )

        // Simulate a service/compatibility registry mutation followed by an
        // exception before the launch-preparation barrier can reaffirm it.
        try writeSteamLanguageRegistry("english", to: prefix)
        let resumedLease = try await policy.prepareForLaunch(
            runtimeExecutable: root.appending(path: "wine"),
            prefix: prefix,
            logDirectory: root
        )

        XCTAssertEqual(resumedLease?.language, .koreana)
        XCTAssertEqual(writes, [.koreana, .koreana])
        XCTAssertEqual(
            try policy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(try policy.hasOwnershipMarker(in: prefix))
    }

    func testMalformedSteamLanguageMarkerFailsClosedWithoutRegistryWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamLanguageUnsafe-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: SteamClientLanguageOwnershipPolicy.markerURL(in: prefix)
        )
        var writeCount = 0
        let policy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, _, _, _ in writeCount += 1 }
        )

        do {
            _ = try await policy.claimFreshInstallation(
                runtimeExecutable: root.appending(path: "wine"),
                prefix: prefix,
                logDirectory: root,
                language: .koreana
            )
            XCTFail("Expected malformed ownership state to fail closed")
        } catch is SteamClientLanguageOwnershipError {
            XCTAssertEqual(writeCount, 0)
            XCTAssertNil(
                try policy.observedRegistryLanguageToken(in: prefix)
            )
        }
    }

    func testSteamManagerVerifiesFirstInstallOnlyAfterSteamExecutableIsCreated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamInstallVerification-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let installer = root.appending(path: "SteamSetup.exe")
        try Data("installer".utf8).write(to: installer)
        let launcher = root.appending(path: "wine")
        try """
        #!/bin/sh
        if [ "$1" = "reg" ]; then
            printf '%s\\n' '[Software\\Valve\\Steam]' '"Language"="koreana"' > "$WINEPREFIX/user.reg"
            exit 0
        fi
        if [ "$1" = "wineboot" ]; then
            exit 0
        fi
        if [ "$1" = "\(installer.path)" ]; then
            grep -F '"Language"="koreana"' "$WINEPREFIX/user.reg" >/dev/null || exit 41
        fi
        steam_dir="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
        mkdir -p "$steam_dir"
        printf 'new-steam-executable' > "$steam_dir/steam.exe"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let manager = SteamManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())

        let result = try await manager.installSteam(
            runtimeExecutable: launcher,
            installer: installer,
            language: .koreana
        )

        XCTAssertTrue(result.processResult.succeeded)
        XCTAssertTrue(result.hasSteamExecutable)
        XCTAssertFalse(result.hadSteamExecutableBeforeInstall)
        XCTAssertTrue(result.didObserveSteamExecutableMutation)
        XCTAssertEqual(result.requestedSteamLanguage, .koreana)
        XCTAssertTrue(result.didClaimSteamLanguageOwnership)
        XCTAssertTrue(result.hasVerifiedSteamLanguageProjection)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: SteamClientLanguageOwnershipPolicy
                    .markerURL(in: prefix).path
            )
        )
        XCTAssertFalse(result.hasVerifiedSteamClientService)
        XCTAssertEqual(
            result.verificationState,
            .steamClientServiceNotReady
        )
        XCTAssertFalse(
            result.installationVerified,
            "Steam.exe alone must not satisfy the installation contract"
        )
    }

    func testSteamManagerDoesNotVerifyNoOpReinstallFromPreexistingExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamInstallVerification-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unchanged-steam-executable".utf8).write(to: steamExecutable)
        let installer = root.appending(path: "SteamSetup.exe")
        try Data("installer".utf8).write(to: installer)
        let launcher = root.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let manager = SteamManager(pathManager: pathManager, runner: makeCuratedRuntimeRunner())

        let result = try await manager.installSteam(
            runtimeExecutable: launcher,
            installer: installer,
            language: .koreana
        )

        XCTAssertTrue(result.processResult.succeeded)
        XCTAssertTrue(result.hasSteamExecutable)
        XCTAssertTrue(result.hadSteamExecutableBeforeInstall)
        XCTAssertFalse(result.didObserveSteamExecutableMutation)
        XCTAssertFalse(result.didClaimSteamLanguageOwnership)
        XCTAssertFalse(result.hasVerifiedSteamLanguageProjection)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: SteamClientLanguageOwnershipPolicy
                    .markerURL(in: prefix).path
            )
        )
        XCTAssertFalse(result.hasVerifiedSteamClientService)
        XCTAssertEqual(
            result.verificationState,
            .steamExecutableNotCreatedOrChanged
        )
        XCTAssertFalse(result.installationVerified)
    }

    func testSteamManagerResumesPendingLanguageClaimAcrossPartialInstallerRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamInstallLanguageRetry-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        let installer = root.appending(path: "SteamSetup.exe")
        try Data("installer".utf8).write(to: installer)
        let launcher = root.appending(path: "wine")
        try """
        #!/bin/sh
        if [ "$1" = "reg" ]; then
            printf '%s\\n' '[Software\\Valve\\Steam]' '"Language"="koreana"' > "$WINEPREFIX/user.reg"
            exit 0
        fi
        if [ "$1" = "wineboot" ]; then
            exit 0
        fi
        if [ "$1" = "\(installer.path)" ]; then
            grep -F '"Language"="koreana"' "$WINEPREFIX/user.reg" >/dev/null || exit 41
            printf 'completed-steam-executable' > "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe"
        fi
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let setupPolicy = SteamClientLanguageOwnershipPolicy(
            registryLanguageWriter: { _, prefix, _, language in
                try self.writeSteamLanguageRegistry(language.rawValue, to: prefix)
            }
        )
        let initialLease = try await setupPolicy.claimFreshInstallation(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: root,
            language: .english
        )
        XCTAssertNotNil(initialLease)
        let steamExecutable = WindowsSteamInstallationLayout.executable(in: prefix)
        try FileManager.default.createDirectory(
            at: steamExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial-steam-executable".utf8).write(to: steamExecutable)
        try writeSteamLanguageRegistry("english", to: prefix)

        let manager = SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner()
        )
        let result = try await manager.installSteam(
            runtimeExecutable: launcher,
            installer: installer,
            language: .koreana
        )

        XCTAssertTrue(result.processResult.succeeded)
        XCTAssertTrue(result.hadSteamExecutableBeforeInstall)
        XCTAssertTrue(result.didObserveSteamExecutableMutation)
        XCTAssertTrue(result.didClaimSteamLanguageOwnership)
        XCTAssertTrue(result.hasVerifiedSteamLanguageProjection)
        XCTAssertEqual(
            try setupPolicy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(try setupPolicy.hasOwnershipMarker(in: prefix))
    }

    func testSteamInstallVerificationStateKeepsFailureReasonsDistinct() {
        let now = Date(timeIntervalSince1970: 10)
        func processResult(exitCode: Int32) -> ProcessRunResult {
            ProcessRunResult(
                actionName: "installSteam",
                executable: URL(fileURLWithPath: "/tmp/wine"),
                arguments: ["/tmp/SteamSetup.exe", "/S"],
                startedAt: now,
                endedAt: now,
                exitCode: exitCode,
                stdoutLog: URL(fileURLWithPath: "/tmp/steam-install.stdout.log"),
                stderrLog: URL(fileURLWithPath: "/tmp/steam-install.stderr.log"),
                didTimeOut: false,
                outcome: .exited
            )
        }
        func installResult(
            exitCode: Int32 = 0,
            hasSteamExecutable: Bool = true,
            hadSteamExecutableBeforeInstall: Bool = false,
            didObserveSteamExecutableMutation: Bool = true,
            didClaimSteamLanguageOwnership: Bool = false,
            hasVerifiedSteamLanguageProjection: Bool = false,
            hasVerifiedSteamClientService: Bool = true
        ) -> SteamInstallResult {
            SteamInstallResult(
                processResult: processResult(exitCode: exitCode),
                steamExecutableURL: URL(fileURLWithPath: "/tmp/steam.exe"),
                hasSteamExecutable: hasSteamExecutable,
                hadSteamExecutableBeforeInstall: hadSteamExecutableBeforeInstall,
                didObserveSteamExecutableMutation: didObserveSteamExecutableMutation,
                requestedSteamLanguage: .koreana,
                didClaimSteamLanguageOwnership:
                    didClaimSteamLanguageOwnership,
                hasVerifiedSteamLanguageProjection:
                    hasVerifiedSteamLanguageProjection,
                hasVerifiedSteamClientService: hasVerifiedSteamClientService
            )
        }

        XCTAssertEqual(
            installResult(exitCode: 1).verificationState,
            .installerFailed
        )
        XCTAssertEqual(
            installResult(hasSteamExecutable: false).verificationState,
            .steamExecutableNotCreatedOrChanged
        )
        XCTAssertEqual(
            installResult(
                hadSteamExecutableBeforeInstall: true,
                didObserveSteamExecutableMutation: false
            ).verificationState,
            .steamExecutableNotCreatedOrChanged
        )
        XCTAssertEqual(
            installResult(
                didClaimSteamLanguageOwnership: true,
                hasVerifiedSteamLanguageProjection: false
            ).verificationState,
            .steamLanguageNotReady
        )
        XCTAssertEqual(
            installResult(hasVerifiedSteamClientService: false)
                .verificationState,
            .steamClientServiceNotReady
        )
        XCTAssertEqual(installResult().verificationState, .verified)
        XCTAssertTrue(installResult().installationVerified)
    }

    func testSteamClientServiceContractRequiresCurrentBinaryAndExactRegistration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamClientServiceContract-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = SteamClientServiceContract.sourceExecutable(in: root)
        let installed = SteamClientServiceContract.installedExecutable(in: root)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let currentService = Data("current-steam-service".utf8)
        try currentService.write(to: source)
        try currentService.write(to: installed)
        try #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Valve\\SteamService]
        "installpath_default"="C:\\Program Files (x86)\\Steam"

        [System\\ControlSet001\\Services\\Steam Client Service]
        "DisplayName"="Steam Client Service"
        "ImagePath"=str(2):"\"C:\\Program Files (x86)\\Common Files\\Steam\\SteamService.exe\" /RunAsService"
        "ObjectName"="LocalSystem"
        "Start"=dword:00000003
        "Type"=dword:00000010
        "WOW64"=dword:00000001
        """#.write(
            to: root.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )

        let ready = SteamClientServiceContract.inspect(prefix: root)
        XCTAssertTrue(ready.isReady, ready.failureDetail)

        try Data("stale-steam-service".utf8).write(to: installed)
        let stale = SteamClientServiceContract.inspect(prefix: root)
        XCTAssertFalse(stale.isReady)
        XCTAssertFalse(stale.installedExecutableMatchesSource)
    }

    func testSteamManagerRepairsMissingSteamClientServiceAndThenUsesFastPath() async throws {
        let fixture = try makeSteamClientServiceMutationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.manager.prepareSteamClientServiceForLaunch(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        let repaired = SteamClientServiceContract.inspect(
            prefix: fixture.prefix
        )
        XCTAssertTrue(repaired.isReady, repaired.failureDetail)
        let actionsAfterRepair = try steamClientServiceMutationActions(
            fixture
        )
        XCTAssertEqual(
            actionsAfterRepair,
            [
                "runtime:/install",
                "runtime:query",
                "wineserver:-w",
                "wineserver:--kill=\(SIGTERM)",
                "wineserver:-w"
            ]
        )
        try assertSteamClientServiceMutationOwnershipRetired(fixture)

        try await fixture.manager.prepareSteamClientServiceForLaunch(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertEqual(
            try steamClientServiceMutationActions(fixture),
            actionsAfterRepair,
            "A verified service must not spawn Wine maintenance commands again"
        )
    }

    func testSteamClientServiceInstallFailureStillVerifiesShutdown() async throws {
        let fixture = try makeSteamClientServiceMutationFixture(
            installExitCode: 27
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.manager.prepareSteamClientServiceForLaunch(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("The failed service installation must escape")
        } catch let error as SteamPrefixLifecycleCleanupError {
            XCTAssertEqual(
                error.originalProcessResult?.actionName,
                "installSteamClientService"
            )
            XCTAssertEqual(error.originalProcessResult?.processExitCode, 27)
            XCTAssertNil(error.cleanupError)
            let shutdown = try XCTUnwrap(error.cleanupProcessResults.last)
            XCTAssertEqual(shutdown.actionName, "shutdownWinePrefix")
            XCTAssertTrue(shutdown.succeeded)
            XCTAssertEqual(shutdown.postconditionSatisfied, true)
        }
        XCTAssertEqual(
            try steamClientServiceMutationActions(fixture),
            [
                "runtime:/install",
                "wineserver:--kill=\(SIGTERM)",
                "wineserver:-w"
            ]
        )
        try assertSteamClientServiceMutationOwnershipRetired(fixture)
    }

    func testSteamClientServiceQueryFailureStillVerifiesShutdown() async throws {
        let fixture = try makeSteamClientServiceMutationFixture(
            queryExitCode: 28
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.manager.prepareSteamClientServiceForLaunch(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("The failed service query must escape")
        } catch let error as SteamPrefixLifecycleCleanupError {
            XCTAssertEqual(
                error.originalProcessResult?.actionName,
                "querySteamClientService"
            )
            XCTAssertEqual(error.originalProcessResult?.processExitCode, 28)
            XCTAssertNil(error.cleanupError)
            XCTAssertEqual(
                error.cleanupProcessResults.last?.postconditionSatisfied,
                true
            )
        }
        XCTAssertEqual(
            try steamClientServiceMutationActions(fixture),
            [
                "runtime:/install",
                "runtime:query",
                "wineserver:--kill=\(SIGTERM)",
                "wineserver:-w"
            ]
        )
        try assertSteamClientServiceMutationOwnershipRetired(fixture)
    }

    func testSteamClientServiceWaitAndInitialCleanupFailuresStillEndClean() async throws {
        let fixture = try makeSteamClientServiceMutationFixture(
            wineserverExitCodes: [29, 30, 0]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.manager.prepareSteamClientServiceForLaunch(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("The failed Wine wait must escape")
        } catch let error as SteamPrefixLifecycleCleanupError {
            XCTAssertEqual(
                error.originalProcessResult?.actionName,
                "waitForWinePrefix"
            )
            XCTAssertEqual(error.originalProcessResult?.processExitCode, 29)
            XCTAssertNil(error.cleanupError)
            let shutdown = try XCTUnwrap(error.cleanupProcessResults.last)
            XCTAssertEqual(shutdown.actionName, "shutdownWinePrefix")
            XCTAssertEqual(shutdown.processExitCode, 30)
            XCTAssertTrue(shutdown.succeeded)
            XCTAssertEqual(shutdown.postconditionSatisfied, true)
        }
        XCTAssertEqual(
            try steamClientServiceMutationActions(fixture),
            [
                "runtime:/install",
                "runtime:query",
                "wineserver:-w",
                "wineserver:--kill=\(SIGTERM)",
                "wineserver:-w"
            ]
        )
        try assertSteamClientServiceMutationOwnershipRetired(fixture)
    }

    func testFirstLaunchPreparationFailureStillCompletesVerifiedShutdown() async throws {
        enum PreparationFailure: Error { case injected }

        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayFirstLaunchCleanup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        let actionLog = prefix.appending(path: "first-launch-shutdowns.txt")
        let runtime = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            printf '%s\n' "$1" >> "\(actionLog.path)"
            exit 0
            """
        )
        let manager = SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            steamClientServicePreparer: { _, _, _ in
                throw PreparationFailure.injected
            }
        )

        do {
            _ = try await manager.prepareInstalledSteamForFirstLaunch(
                runtimeExecutable: runtime,
                language: nil
            )
            XCTFail("The injected preparation failure must escape")
        } catch let error as SteamPrefixLifecycleCleanupError {
            XCTAssertNil(error.cleanupError)
            XCTAssertTrue(error.originalError is PreparationFailure)
            let shutdown = try XCTUnwrap(error.cleanupProcessResults.last)
            XCTAssertTrue(shutdown.succeeded)
            XCTAssertEqual(shutdown.postconditionSatisfied, true)
        }
        let shutdownActions = try String(
            contentsOf: actionLog,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline)
        XCTAssertEqual(
            shutdownActions,
            ["--kill=15", "-w", "--kill=15", "-w"],
            "Both the opening barrier and failure cleanup must verify inactivity"
        )
    }

    func testSteamClientCompatibilityVerifierRequiresRendererForSteamClientReadiness() throws {
        let rendererlessCapability = WindowsRuntimeCapability(
            executableURL: URL(filePath: "/tmp/wine-rendererless-steam-client"),
            graphicsBackend: .unknown,
            evidence: ["lib/libgnutls.30.dylib"],
            limitations: ["missing-direct3d-renderer"]
        )

        let rendererlessVerification = SteamClientCompatibilityVerifier.verify(capability: rendererlessCapability)

        XCTAssertTrue(rendererlessVerification.supportsNetworking)
        XCTAssertFalse(rendererlessVerification.canLaunchWindowsSteam)
        XCTAssertFalse(rendererlessVerification.canLaunchManagedSteamGames)
        XCTAssertEqual(rendererlessVerification.launchBlockers, [.missingModernDirect3DRenderer])
        XCTAssertEqual(rendererlessVerification.managedGameBlockers, [.missingModernDirect3DRenderer])

        let blackScreenCapability = WindowsRuntimeCapability(
            executableURL: URL(filePath: "/tmp/wine-steam-black-screen"),
            graphicsBackend: .d3dMetal,
            evidence: ["lib/libgnutls.30.dylib", "lib/wine/x86_64-unix/winemac.so"],
            limitations: ["steam-cef-child-window-metal-swapchain-unsupported"]
        )

        let blackScreenVerification = SteamClientCompatibilityVerifier.verify(capability: blackScreenCapability)

        XCTAssertTrue(blackScreenVerification.supportsNetworking)
        XCTAssertFalse(blackScreenVerification.canLaunchWindowsSteam)
        XCTAssertFalse(blackScreenVerification.canLaunchManagedSteamGames)
        XCTAssertEqual(blackScreenVerification.launchBlockers, [.unsupportedSteamUIRenderer])
        XCTAssertTrue(
            blackScreenVerification.userMessage.contains(
                "CEF 자식 창 표면 렌더링을 지원하지 않습니다"
            )
        )

        let externalApplicationRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRuntimeCompatibilityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: externalApplicationRoot) }
        let externalRuntime = externalApplicationRoot
            .appending(path: "ThirdPartyRuntime.app/Contents/Resources/Runtime/bin/wine")
        try FileManager.default.createDirectory(
            at: externalRuntime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: externalRuntime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalRuntime.path)
        let externalRuntimeCapability = WindowsRuntimeCapability(
            executableURL: externalRuntime,
            graphicsBackend: .d3dMetal,
            evidence: ["external app-bundled runtime", "lib64/libgnutls.30.dylib"],
            limitations: ["steam-cef-child-window-metal-swapchain-unsupported"]
        )

        let externalRuntimeVerification = SteamClientCompatibilityVerifier.verify(capability: externalRuntimeCapability)

        XCTAssertTrue(externalRuntimeCapability.isUnsupportedExternalApplicationRunner)
        XCTAssertFalse(externalRuntimeVerification.canLaunchWindowsSteam)
        XCTAssertEqual(
            externalRuntimeVerification.launchBlockers,
            [.unsupportedExternalApplicationRunner, .unsupportedSteamUIRenderer]
        )
        XCTAssertTrue(externalRuntimeVerification.userMessage.contains("다른 macOS 앱"))
    }

    func testSteamClientCompatibilityVerifierBlocksMissingRootScopedArgumentPolicy() {
        let capability = WindowsRuntimeCapability(
            executableURL: URL(
                filePath: "/tmp/wine-steam-missing-argument-policy"
            ),
            graphicsBackend: .d3dMetal,
            evidence: ["lib/libgnutls.30.dylib"],
            limitations: [
                "missing-steam-webhelper-root-scoped-executable-argument-policy"
            ]
        )

        let verification = SteamClientCompatibilityVerifier.verify(
            capability: capability
        )

        XCTAssertTrue(verification.supportsNetworking)
        XCTAssertFalse(verification.canLaunchWindowsSteam)
        XCTAssertFalse(verification.canLaunchManagedSteamGames)
        XCTAssertEqual(
            verification.launchBlockers,
            [.unsupportedSteamUIRenderer]
        )
        XCTAssertEqual(
            verification.managedGameBlockers,
            [.unsupportedSteamUIRenderer]
        )
        XCTAssertTrue(
            verification.userMessage.contains(
                "32비트/64비트 Wine kernelbase 중 하나 이상"
            )
        )
        XCTAssertTrue(
            verification.userMessage.contains(
                "선택한 자식 실행 파일의 루트 프로세스로만 호환성 인자를 한정"
            )
        )
    }

    func testLaunchRecordStoresSteamUIVerificationSeparateFromProcessLaunch() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached
        )

        record.applySteamLaunchResult(result)

        XCTAssertEqual(record.status, "launchedUnverified")
        XCTAssertEqual(record.steamUIVerificationState, .launchedButUnverified)
        XCTAssertEqual(record.stdoutPath, "/tmp/stdout.log")
        XCTAssertEqual(record.stderrPath, "/tmp/stderr.log")
        XCTAssertNil(record.diagnosticLogPath)
    }

    func testLaunchRecordStoresSteamBlackScreenEvidenceAsNotSuccessfulUI() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            forgePlayStatusCode: SteamManager.steamRenderingFailureExitCode,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            diagnosticLog: URL(fileURLWithPath: "/tmp/diagnostic.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached
        )

        record.applySteamLaunchResult(result)

        XCTAssertEqual(record.status, "failed")
        XCTAssertEqual(record.steamUIVerificationState, .blackScreenSuspected)
        XCTAssertNil(record.steamUISurface)
        XCTAssertEqual(record.diagnosticLogPath, "/tmp/diagnostic.log")
        XCTAssertNil(record.exitCode)
        XCTAssertEqual(record.forgePlayStatusCode, SteamManager.steamRenderingFailureExitCode)
        XCTAssertFalse(record.steamUIVerificationDetail?.isEmpty ?? true)
    }

    func testLaunchRecordFailurePreservesEmbeddedProcessEvidenceAndStage() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        let evidenceURL = URL(fileURLWithPath: "/tmp/shutdown.run.json")
        let result = ProcessRunResult(
            actionName: "shutdownWinePrefix",
            executable: URL(fileURLWithPath: "/tmp/wineserver"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 74,
            stdoutLog: URL(fileURLWithPath: "/tmp/shutdown_stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/shutdown_stderr.log"),
            didTimeOut: false,
            outcome: .exited,
            runEvidenceLog: evidenceURL
        )

        record.markSteamLaunchFailed(
            with: result,
            failureDomain: "ForgePlay.SteamLaunchError",
            failureCode: 9,
            failureSummary: "prefix shutdown failed"
        )

        XCTAssertEqual(record.status, "failed")
        XCTAssertEqual(record.steamUIVerificationState, .failed)
        XCTAssertEqual(record.processOutcome, ProcessRunOutcome.exited.rawValue)
        XCTAssertEqual(record.exitCode, 74)
        XCTAssertEqual(record.stdoutPath, "/tmp/shutdown_stdout.log")
        XCTAssertEqual(record.stderrPath, "/tmp/shutdown_stderr.log")
        XCTAssertEqual(record.runEvidencePath, evidenceURL.path)
        XCTAssertTrue(record.failureSummary?.contains("shutdownWinePrefix") == true)
        XCTAssertEqual(record.failureDomain, "ForgePlay.SteamLaunchError")
        XCTAssertEqual(record.failureCode, 9)
    }

    func testLaunchRecordDoesNotInventExitCodeForPreflightFailureEvidence() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        let result = ProcessRunResult(
            actionName: "launchSteam:preflight",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 1,
            hasProcessExitCode: false,
            forgePlayStatusCode: SteamManager.steamLaunchBlockedExitCode,
            stdoutLog: URL(fileURLWithPath: "/tmp/preflight_stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/preflight_stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .preflightFailed,
            runEvidenceLog: URL(fileURLWithPath: "/tmp/preflight.run.json")
        )

        record.markSteamLaunchFailed(with: result, failureSummary: "unsafe input")

        XCTAssertNil(record.exitCode)
        XCTAssertEqual(record.forgePlayStatusCode, SteamManager.steamLaunchBlockedExitCode)
        XCTAssertEqual(record.processOutcome, ProcessRunOutcome.preflightFailed.rawValue)
        XCTAssertEqual(record.runEvidencePath, "/tmp/preflight.run.json")
        XCTAssertEqual(record.waitedForExit, false)
    }

    func testLaunchRecordDoesNotOverwriteManualSteamUIEvidenceWithLaterLaunchResult() {
        let renderedRecord = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        renderedRecord.markSteamUIRendered(now: Date(timeIntervalSince1970: 12))
        let successfulLaunchResult = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached
        )

        renderedRecord.applySteamLaunchResult(successfulLaunchResult)

        XCTAssertEqual(renderedRecord.status, "finished")
        XCTAssertEqual(renderedRecord.steamUIVerificationState, .rendered)
        XCTAssertEqual(renderedRecord.stdoutPath, "/tmp/stdout.log")
        XCTAssertEqual(renderedRecord.stderrPath, "/tmp/stderr.log")

        let blackScreenRecord = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        blackScreenRecord.markSteamUIBlackScreenSuspected(now: Date(timeIntervalSince1970: 12))

        blackScreenRecord.applySteamLaunchResult(successfulLaunchResult)

        XCTAssertEqual(blackScreenRecord.status, "failed")
        XCTAssertEqual(blackScreenRecord.steamUIVerificationState, .blackScreenSuspected)
        XCTAssertEqual(blackScreenRecord.stdoutPath, "/tmp/stdout.log")
        XCTAssertEqual(blackScreenRecord.stderrPath, "/tmp/stderr.log")
    }

    func testLaunchRecordDiagnosticRenderingFailureOverridesPrematureManualRenderedState() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        record.markSteamUIRendered(now: Date(timeIntervalSince1970: 12))
        let renderingFailureResult = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            forgePlayStatusCode: SteamManager.steamRenderingFailureExitCode,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            diagnosticLog: URL(fileURLWithPath: "/tmp/diagnostic.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached
        )

        record.applySteamLaunchResult(renderingFailureResult)

        XCTAssertEqual(record.status, "failed")
        XCTAssertEqual(record.steamUIVerificationState, .blackScreenSuspected)
        XCTAssertNil(record.steamUISurface)
        XCTAssertEqual(
            record.processSteamUIVerificationStatus,
            SteamUIVerificationState.blackScreenSuspected.rawValue
        )
        XCTAssertEqual(record.diagnosticLogPath, "/tmp/diagnostic.log")
    }

    func testModelContextPersistsSteamLaunchRecordLifecycle() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        let startedAt = Date(timeIntervalSince1970: 10)
        let selectedGameContext = SteamLaunchSelectedGameContext(
            steamAppID: "1245620",
            name: "ELDEN RING",
            buildID: "20260715",
            manifestStateFlags: 4,
            installedByteCount: 70_000_000_000,
            lastUpdated: Date(timeIntervalSince1970: 9),
            manifestAvailable: true,
            manifestCaptureIssue: nil
        )
        let record = try context.createSteamLaunchRecord(
            appSessionID: "app-session-1",
            selectedGameContext: selectedGameContext,
            startedAt: startedAt
        )

        XCTAssertEqual(record.prefixId, PrefixIdentifier.steamShared)
        XCTAssertEqual(record.commandKind, "launchSteam")
        XCTAssertEqual(record.status, "running")
        XCTAssertEqual(record.startedAt, startedAt)
        XCTAssertEqual(record.hostAppSessionID, "app-session-1")
        XCTAssertEqual(record.gameId, "1245620")
        XCTAssertEqual(record.gameName, "ELDEN RING")
        XCTAssertEqual(record.gameBuildID, "20260715")
        XCTAssertEqual(record.gameManifestStateFlags, 4)
        XCTAssertEqual(record.gameInstalledByteCount, 70_000_000_000)
        XCTAssertEqual(record.gameAssociationSource, SteamLaunchSelectedGameContext.associationSource)

        let launchResult = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: startedAt,
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached
        )

        try context.saveSteamLaunchResult(launchResult, for: record)

        let persisted = try XCTUnwrap(try context.fetch(FetchDescriptor<LaunchRecord>()).first)
        XCTAssertEqual(persisted.status, "launchedUnverified")
        XCTAssertEqual(persisted.steamUIVerificationState, .launchedButUnverified)
        XCTAssertEqual(persisted.stdoutPath, "/tmp/stdout.log")

        try context.markSteamUIRendered(persisted, now: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(persisted.status, "finished")
        XCTAssertEqual(persisted.steamUIVerificationState, .rendered)
        XCTAssertEqual(persisted.endedAt, Date(timeIntervalSince1970: 11))

        let failedRecord = try context.createSteamLaunchRecord(
            appSessionID: "app-session-1",
            startedAt: Date(timeIntervalSince1970: 12)
        )
        try context.markSteamLaunchFailedWithoutResult(failedRecord, now: Date(timeIntervalSince1970: 13))

        XCTAssertEqual(failedRecord.status, "failed")
        XCTAssertEqual(failedRecord.steamUIVerificationState, .failed)
        XCTAssertEqual(failedRecord.endedAt, Date(timeIntervalSince1970: 13))

        let blackScreenRecord = try context.createSteamLaunchRecord(
            appSessionID: "app-session-1",
            startedAt: Date(timeIntervalSince1970: 14)
        )
        try context.markSteamUIBlackScreenSuspected(blackScreenRecord, now: Date(timeIntervalSince1970: 15))

        XCTAssertEqual(blackScreenRecord.status, "failed")
        XCTAssertEqual(blackScreenRecord.steamUIVerificationState, .blackScreenSuspected)
        XCTAssertEqual(blackScreenRecord.endedAt, Date(timeIntervalSince1970: 15))
    }

    func testModelContextReconcilesOnlyAbandonedSteamLaunchRecordsFromPreviousSessions() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let previousRunning = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 1),
            hostAppSessionID: "previous-session"
        )
        let currentRunning = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 2),
            hostAppSessionID: "current-session"
        )
        let previousRendered = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 3),
            endedAt: Date(timeIntervalSince1970: 4),
            status: "finished",
            steamUIVerificationStatus: SteamUIVerificationState.rendered.rawValue,
            hostAppSessionID: "previous-session"
        )
        let unrelated = LaunchRecord(
            prefixId: "game-prefix",
            commandKind: "launchGame",
            startedAt: Date(timeIntervalSince1970: 5),
            hostAppSessionID: "previous-session"
        )
        [previousRunning, currentRunning, previousRendered, unrelated].forEach(context.insert)
        try context.save()
        let reconciledAt = Date(timeIntervalSince1970: 10)

        let count = try context.reconcileAbandonedSteamLaunchRecords(
            currentAppSessionID: "current-session",
            now: reconciledAt
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(previousRunning.status, "abandoned")
        XCTAssertEqual(previousRunning.endedAt, reconciledAt)
        XCTAssertEqual(previousRunning.steamUIVerificationState, .failed)
        XCTAssertEqual(currentRunning.status, "running")
        XCTAssertEqual(currentRunning.steamUIVerificationState, .notRun)
        XCTAssertEqual(previousRendered.status, "finished")
        XCTAssertEqual(previousRendered.steamUIVerificationState, .rendered)
        XCTAssertEqual(unrelated.status, "running")
    }

    func testLaunchRecordPersistsVerifiedLibrarySurfaceSeparatelyFromProcessLaunch() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached,
            steamUIVerificationState: .rendered,
            steamUISurface: .library
        )

        record.applySteamLaunchResult(result)

        XCTAssertEqual(record.status, "finished")
        XCTAssertEqual(record.steamUIVerificationState, .rendered)
        XCTAssertEqual(record.steamUISurface, .library)
    }

    func testManualSteamUISurfaceCanAdvanceFromSignInToLibrary() {
        let record = LaunchRecord(prefixId: PrefixIdentifier.steamShared, commandKind: "launchSteam")

        record.markSteamUISurface(.signIn, now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(record.steamUISurface, .signIn)
        XCTAssertEqual(record.steamUIVerificationState, .rendered)

        record.markSteamUISurface(.library, now: Date(timeIntervalSince1970: 11))
        XCTAssertEqual(record.steamUISurface, .library)
        XCTAssertEqual(record.steamUIVerificationState, .rendered)
    }

    func testSetupReadinessRequiresLibraryVerificationAcrossDistinctAppSessionsForContinuity() {
        let oldRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 90),
            hostAppSessionID: "old-environment-session"
        )
        oldRecord.markSteamUISurface(.library)
        let firstCurrentRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 110),
            hostAppSessionID: "app-session-1"
        )
        firstCurrentRecord.markSteamUISurface(.library)
        let secondCurrentRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 120),
            hostAppSessionID: "app-session-1"
        )
        secondCurrentRecord.markSteamUISurface(.library)
        let relaunchedRecord = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 130),
            hostAppSessionID: "app-session-2"
        )
        relaunchedRecord.markSteamUISurface(.library)
        let base = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/SteamShared/steam.exe"),
            steamEnvironmentCreatedAt: Date(timeIntervalSince1970: 100)
        )

        let firstLaunch = projectingSteamLaunchReadiness(
            base,
            records: [oldRecord, firstCurrentRecord]
        )
        XCTAssertTrue(firstLaunch.hasVerifiedAuthenticatedLibrary)
        XCTAssertFalse(firstLaunch.hasVerifiedSessionPersistence)
        XCTAssertEqual(firstLaunch.steamSessionContinuityState, .libraryVerifiedOnce)

        let repeatedInSameAppSession = projectingSteamLaunchReadiness(
            base,
            records: [oldRecord, firstCurrentRecord, secondCurrentRecord]
        )
        XCTAssertFalse(repeatedInSameAppSession.hasVerifiedSessionPersistence)
        XCTAssertEqual(repeatedInSameAppSession.steamSessionContinuityState, .libraryVerifiedOnce)

        let relaunched = projectingSteamLaunchReadiness(
            base,
            records: [
                oldRecord,
                firstCurrentRecord,
                secondCurrentRecord,
                relaunchedRecord
            ]
        )
        XCTAssertTrue(relaunched.hasVerifiedAuthenticatedLibrary)
        XCTAssertTrue(relaunched.hasVerifiedSessionPersistence)
        XCTAssertEqual(relaunched.steamSessionContinuityState, .libraryVerifiedAfterRelaunch)
        XCTAssertEqual(
            SteamLaunchRecordLookup.latestSteamLaunchRecord(
                from: [oldRecord, firstCurrentRecord, secondCurrentRecord, relaunchedRecord],
                environmentCreatedAt: Date(timeIntervalSince1970: 100)
            )?.startedAt,
            Date(timeIntervalSince1970: 130)
        )
    }

    func testSteamSessionContinuityUsesGenerationUUIDAndCurrentAppSession() {
        let timestamp = Date(timeIntervalSince1970: 500)
        let oldGeneration = "11111111-1111-1111-1111-111111111111"
        let currentGeneration = "22222222-2222-2222-2222-222222222222"
        let oldFirst = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: timestamp,
            hostAppSessionID: "old-session-1",
            environmentGenerationID: oldGeneration
        )
        oldFirst.markSteamUISurface(.library)
        let oldSecond = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: timestamp,
            hostAppSessionID: "old-session-2",
            environmentGenerationID: oldGeneration
        )
        oldSecond.markSteamUISurface(.library)
        let current = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: timestamp,
            hostAppSessionID: "current-session",
            environmentGenerationID: currentGeneration
        )
        current.markSteamUISurface(.library)
        let base = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/SteamShared/steam.exe"),
            steamEnvironmentCreatedAt: timestamp,
            steamEnvironmentGenerationID: currentGeneration
        )

        let readiness = projectingSteamLaunchReadiness(
            base,
            records: [oldFirst, oldSecond, current],
            currentAppSessionID: "current-session"
        )

        XCTAssertTrue(readiness.hasVerifiedAuthenticatedLibrary)
        XCTAssertFalse(readiness.hasVerifiedSessionPersistence)
        XCTAssertEqual(readiness.steamSessionContinuityState, .libraryVerifiedOnce)
        XCTAssertEqual(
            SteamLaunchRecordLookup.latestSteamLaunchRecord(
                from: [oldFirst, oldSecond, current],
                environmentGenerationID: currentGeneration,
                currentAppSessionID: "current-session"
            )?.id,
            current.id
        )
    }

    func testPreviousSessionLibraryDoesNotBecomeCurrentSessionSurfaceBeforeRelaunch() {
        let generation = "33333333-3333-3333-3333-333333333333"
        let previous = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            hostAppSessionID: "previous-session",
            environmentGenerationID: generation
        )
        previous.markSteamUISurface(.library)
        let base = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/SteamShared/steam.exe"),
            steamEnvironmentGenerationID: generation
        )

        let readiness = projectingSteamLaunchReadiness(
            base,
            records: [previous],
            currentAppSessionID: "new-session"
        )

        XCTAssertEqual(readiness.steamUIVerificationState, .notRun)
        XCTAssertNil(readiness.steamUISurface)
        XCTAssertFalse(readiness.hasVerifiedAuthenticatedLibrary)
        XCTAssertEqual(readiness.steamSessionContinuityState, .libraryVerifiedOnce)
    }

    func testSteamLaunchReadinessRejectsEvidenceFromAnotherEnvironment() {
        let readiness = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: true,
            hasSteamReferences: false,
            steamPrefixURL: URL(fileURLWithPath: "/tmp/SteamShared"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/SteamShared/steam.exe"),
            steamUIVerificationState: .rendered,
            steamUISurface: .library,
            steamSessionContinuityState: .libraryVerifiedAfterRelaunch,
            steamEnvironmentGenerationID: "current-generation"
        )

        let updated = readiness.withSteamLaunchReadinessProjection(
            .empty(environmentIdentity: SteamEnvironmentIdentity(
                generationID: "stale-generation",
                createdAt: nil
            ))
        )

        XCTAssertEqual(updated.steamUIVerificationState, .notRun)
        XCTAssertNil(updated.steamUISurface)
        XCTAssertEqual(updated.steamSessionContinuityState, .notVerified)
    }

    func testSteamLaunchReadinessRepositoryFindsDistinctSessionBeyondDenseRecentHistory() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let generation = "readiness-generation"
        let current = LaunchRecord(
            id: "current-session-launch",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 1_000),
            hostAppSessionID: "current-session",
            environmentGenerationID: generation
        )
        context.insert(current)
        for index in 0..<70 {
            let record = LaunchRecord(
                id: "same-library-session-\(index)",
                prefixId: PrefixIdentifier.steamShared,
                commandKind: "launchSteam",
                startedAt: Date(timeIntervalSince1970: TimeInterval(900 - index)),
                hostAppSessionID: "library-session-a",
                environmentGenerationID: generation
            )
            record.markSteamUISurface(.library)
            context.insert(record)
        }
        let olderDistinctSession = LaunchRecord(
            id: "older-distinct-library-session",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 800),
            hostAppSessionID: "library-session-b",
            environmentGenerationID: generation
        )
        olderDistinctSession.markSteamUISurface(.library)
        context.insert(olderDistinctSession)
        try context.saveOrRollback()

        let projection = try SteamLaunchReadinessRepository().readinessProjection(
            in: context,
            environmentIdentity: SteamEnvironmentIdentity(
                generationID: generation,
                createdAt: nil
            ),
            currentAppSessionID: "current-session"
        )

        XCTAssertEqual(projection.latestCurrentSessionRecord?.id, current.id)
        XCTAssertEqual(
            Set(projection.libraryVerificationRecords.compactMap(\.hostAppSessionID)),
            ["library-session-a", "library-session-b"]
        )
    }

    func testSteamLaunchHistoryPruningPreservesReadinessActiveAndDiagnosticEvidence() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let generation = "retention-generation"
        for index in 0..<506 {
            let record = LaunchRecord(
                id: "ordinary-\(index)",
                prefixId: PrefixIdentifier.steamShared,
                commandKind: "launchSteam",
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                hostAppSessionID: "ordinary-session",
                environmentGenerationID: generation
            )
            record.markSteamUISurface(.unknown)
            context.insert(record)
        }
        let firstContinuityEvidence = LaunchRecord(
            id: "continuity-a",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: -10),
            hostAppSessionID: "continuity-session-a",
            environmentGenerationID: generation
        )
        firstContinuityEvidence.markSteamUISurface(.library)
        context.insert(firstContinuityEvidence)
        let secondContinuityEvidence = LaunchRecord(
            id: "continuity-b",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: -11),
            hostAppSessionID: "continuity-session-b",
            environmentGenerationID: generation
        )
        secondContinuityEvidence.markSteamUISurface(.library)
        context.insert(secondContinuityEvidence)
        let diagnosticEvidence = LaunchRecord(
            id: "diagnostic-linked",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: -12),
            hostAppSessionID: "diagnostic-session",
            environmentGenerationID: generation
        )
        diagnosticEvidence.markSteamUISurface(.unknown)
        context.insert(diagnosticEvidence)
        context.insert(DiagnosticRecord(
            launchRecordId: diagnosticEvidence.id,
            source: DiagnosticRecordSource.ruleEngine.rawValue,
            resultJSON: "{}"
        ))
        let unfinished = LaunchRecord(
            id: "unfinished",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: -13),
            hostAppSessionID: "unfinished-session",
            environmentGenerationID: generation
        )
        context.insert(unfinished)
        let currentSessionEvidence = LaunchRecord(
            id: "current-session-terminal",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: -14),
            hostAppSessionID: "current-session",
            environmentGenerationID: generation
        )
        currentSessionEvidence.markSteamUISurface(.unknown)
        context.insert(currentSessionEvidence)
        try context.saveOrRollback()

        let deletedCount = try SteamLaunchReadinessRepository()
            .pruneCompletedHistory(
                in: context,
                environmentIdentity: SteamEnvironmentIdentity(
                    generationID: generation,
                    createdAt: nil
                ),
                currentAppSessionID: "current-session"
            )
        let retainedIDs = Set(try context.fetch(FetchDescriptor<LaunchRecord>()).map(\.id))

        XCTAssertEqual(deletedCount, 6)
        XCTAssertFalse(retainedIDs.contains("ordinary-0"))
        XCTAssertTrue(retainedIDs.contains("ordinary-6"))
        XCTAssertTrue(retainedIDs.contains(firstContinuityEvidence.id))
        XCTAssertTrue(retainedIDs.contains(secondContinuityEvidence.id))
        XCTAssertTrue(retainedIDs.contains(diagnosticEvidence.id))
        XCTAssertTrue(retainedIDs.contains(unfinished.id))
        XCTAssertTrue(retainedIDs.contains(currentSessionEvidence.id))
    }

    func testSteamLaunchRecordLifecycleRejectsHistoricalRecordRelabeling() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLaunchRecordLifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = AppServices(appSessionID: "current-session")
        try services.pathManager.configureRoot(root)
        let metadata = try services.prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try makeInitializedPrefixLayout(at: prefixURL)
        let generation = try services.currentSteamEnvironmentGenerationID()
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let historical = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 1),
            hostAppSessionID: "historical-session",
            environmentGenerationID: generation
        )
        let current = LaunchRecord(
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 2),
            hostAppSessionID: services.appSessionID,
            environmentGenerationID: generation
        )
        context.insert(historical)
        context.insert(current)
        try context.save()
        let appState = AppState()
        let lifecycle = SteamLaunchRecordLifecycle(
            modelContext: context,
            appState: appState,
            services: services
        )

        XCTAssertFalse(lifecycle.canConfirmSteamUI(for: historical))
        _ = lifecycle.confirmSteamUISurface(.library, launchRecord: historical)
        XCTAssertEqual(historical.steamUIVerificationState, .notRun)
        XCTAssertFalse(lifecycle.canConfirmSteamUI(for: current))
        current.applySteamLaunchResult(ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: current.startedAt,
            endedAt: current.startedAt.addingTimeInterval(1),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached,
            steamUIVerificationState: .launchedButUnverified
        ))
        XCTAssertTrue(lifecycle.canConfirmSteamUI(for: current))
        _ = lifecycle.confirmSteamUISurface(.library, launchRecord: current)
        XCTAssertEqual(current.steamUISurface, .library)
    }

    func testSetupReadinessSurfacesBrokenSteamPrefixMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let metadata = try services.prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try makeInitializedPrefixLayout(at: prefixURL)
        XCTAssertTrue(services.resolveSetupReadiness(hasSteamReferences: false).hasSteamPrefix)

        let metadataURL = prefixURL.appending(path: "prefix.json")
        try Data("{".utf8).write(to: metadataURL)

        let readiness = services.resolveSetupReadiness(hasSteamReferences: false)
        XCTAssertTrue(readiness.hasSteamPrefix)
        XCTAssertFalse(readiness.hasSteamExecutable)
        guard case .invalidMetadata(let url, _)? = readiness.steamPrefixIssue else {
            return XCTFail("Expected invalidMetadata issue, got \(String(describing: readiness.steamPrefixIssue))")
        }
        XCTAssertEqual(url.standardizedFileURL.path, metadataURL.standardizedFileURL.path)
    }

    func testSetupReadinessTreatsFreshEmptySteamPrefixDirectoryAsNotInstalled() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)

        let readiness = services.resolveSetupReadiness(hasSteamReferences: false)

        XCTAssertFalse(readiness.hasSteamPrefix)
        XCTAssertFalse(readiness.hasSteamExecutable)
        XCTAssertNil(readiness.steamPrefixIssue)
    }

    func testSetupReadinessSurfacesBrokenManagedRootStructure() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppServicesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let services = AppServices()
        try services.pathManager.configureRoot(root)
        let brokenRoleURL = root.appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue)
        try FileManager.default.removeItem(at: brokenRoleURL)
        try Data("not a directory".utf8).write(to: brokenRoleURL)

        let readiness = services.resolveSetupReadiness(hasSteamReferences: false)

        XCTAssertFalse(readiness.hasSteamPrefix)
        XCTAssertFalse(readiness.hasSteamExecutable)
        XCTAssertNil(readiness.steamPrefixIssue)
        guard case .cannotCreate(let url)? = readiness.rootIssue else {
            return XCTFail("Expected cannotCreate root issue, got \(String(describing: readiness.rootIssue))")
        }
        XCTAssertEqual(url.standardizedFileURL.path, brokenRoleURL.standardizedFileURL.path)
    }

    func testSetupReadinessSteamPrefixTargetDoesNotFallbackWhenRootIsBroken() {
        let selectedRoot = URL(fileURLWithPath: "/tmp/ForgePlayRoot")
        let expectedPrefix = selectedRoot.appending(
            path: ForgePlayPathRole.steamSharedPrefix.rawValue,
            directoryHint: .isDirectory
        )

        let missingPrefixReadiness = SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: nil,
            steamExecutableURL: nil
        )
        XCTAssertEqual(
            missingPrefixReadiness.steamPrefixTargetURL(selectedRootURL: selectedRoot)?.standardizedFileURL.path,
            expectedPrefix.standardizedFileURL.path
        )

        let resolvedPrefixReadiness = SetupReadiness(
            hasSteamPrefix: true,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: expectedPrefix,
            steamExecutableURL: nil
        )
        XCTAssertEqual(
            resolvedPrefixReadiness.steamPrefixTargetURL(selectedRootURL: selectedRoot)?.standardizedFileURL.path,
            expectedPrefix.standardizedFileURL.path
        )

        let brokenRootReadiness = SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: nil,
            steamExecutableURL: nil,
            rootIssue: .cannotCreate(expectedPrefix)
        )
        XCTAssertNil(brokenRootReadiness.steamPrefixTargetURL(selectedRootURL: selectedRoot))
    }

    func testSetupStageReturnsToRootSelectionWhenManagedRootIsBroken() {
        let appState = AppState()
        appState.selectedRootURL = URL(fileURLWithPath: "/tmp/ForgePlay")
        appState.latestChecks = [
            SystemCheckResult(
                title: "Mac 상태 확인",
                detail: "OK",
                status: .ok,
                technicalDetail: nil
            )
        ]
        appState.runtimeExecutableURL = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine/bin/wine")

        appState.updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: false,
            hasSteamExecutable: false,
            hasSteamReferences: false,
            steamPrefixURL: nil,
            steamExecutableURL: nil,
            rootIssue: .cannotCreate(URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes"))
        ))

        XCTAssertEqual(appState.setupStage, .chooseRoot)
    }

    func testCompatibilityDBPublicKeyLoaderAcceptsOnlyValidP256PublicKey() {
        let publicKey = P256.Signing.PrivateKey().publicKey.rawRepresentation
        let publicKeyBase64 = publicKey.base64EncodedString()

        XCTAssertEqual(
            AppServices.validatedCompatibilityDBPublicKeyRawRepresentation(fromBase64: publicKeyBase64),
            publicKey
        )
        XCTAssertNil(AppServices.validatedCompatibilityDBPublicKeyRawRepresentation(fromBase64: "not-base64"))
        XCTAssertNil(AppServices.validatedCompatibilityDBPublicKeyRawRepresentation(fromBase64: Data("short".utf8).base64EncodedString()))
    }

    func testCompatibilityDBPublicKeyConfigurationTreatsInvalidInfoKeyAsInvalid() {
        let publicKeyBase64 = P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let resourceURL = URL(fileURLWithPath: "/tmp/CompatibilityDBPublicKey.base64")

        let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
            infoDictionaryValue: "not-base64",
            resourceURL: resourceURL,
            readResourceText: { _ in publicKeyBase64 }
        )

        guard case .invalid(let message) = configuration else {
            return XCTFail("Expected invalid key configuration, got \(configuration)")
        }
        XCTAssertTrue(message.contains("Info.plist ForgePlayCompatibilityDBPublicKeyBase64"))
        XCTAssertFalse(configuration.canApplyRemoteUpdates)
    }

    func testCompatibilityDBPublicKeyConfigurationSurfacesUnreadableResource() {
        let resourceURL = URL(fileURLWithPath: "/tmp/CompatibilityDBPublicKey.base64")

        let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
            infoDictionaryValue: nil,
            resourceURL: resourceURL,
            readResourceText: { _ in
                throw CocoaError(.fileReadNoSuchFile)
            }
        )

        guard case .invalid(let message) = configuration else {
            return XCTFail("Expected invalid key configuration, got \(configuration)")
        }
        XCTAssertTrue(message.contains("CompatibilityDBPublicKey.base64"))
        XCTAssertFalse(configuration.canApplyRemoteUpdates)
    }

    func testCompatibilityDBPublicKeyResourceRejectsSymlinkAndHardlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityKeyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let publicKeyBase64 = P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let source = root.appending(path: "source.base64")
        let symlink = root.appending(path: "CompatibilityDBPublicKey-symlink.base64")
        let hardlink = root.appending(path: "CompatibilityDBPublicKey-hardlink.base64")
        try publicKeyBase64.write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)

        for resourceURL in [symlink, hardlink] {
            let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
                infoDictionaryValue: nil,
                resourceURL: resourceURL
            )
            guard case .invalid(let message) = configuration else {
                return XCTFail("Expected unsafe key resource to be invalid, got \(configuration)")
            }
            XCTAssertTrue(message.contains("CompatibilityDBPublicKey.base64"))
            XCTAssertFalse(configuration.canApplyRemoteUpdates)
        }
    }

    func testCompatibilityDBPublicKeyResourceRejectsOversizedAndNonUTF8Files() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityKeyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oversized = root.appending(path: "CompatibilityDBPublicKey-oversized.base64")
        let nonUTF8 = root.appending(path: "CompatibilityDBPublicKey-nonutf8.base64")
        try Data(repeating: UInt8(ascii: "A"), count: AppServices.maxCompatibilityDBPublicKeyResourceBytes + 1)
            .write(to: oversized)
        try Data([0xFF, 0xFE, 0x00]).write(to: nonUTF8)

        for resourceURL in [oversized, nonUTF8] {
            let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
                infoDictionaryValue: nil,
                resourceURL: resourceURL
            )
            guard case .invalid(let message) = configuration else {
                return XCTFail("Expected invalid key resource, got \(configuration)")
            }
            XCTAssertTrue(message.contains("CompatibilityDBPublicKey.base64"))
            XCTAssertFalse(configuration.canApplyRemoteUpdates)
        }
    }

    func testCompatibilityDBPublicKeyConfigurationUsesValidResourceWhenInfoKeyIsAbsent() {
        let publicKey = P256.Signing.PrivateKey().publicKey.rawRepresentation
        let resourceURL = URL(fileURLWithPath: "/tmp/CompatibilityDBPublicKey.base64")

        let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
            infoDictionaryValue: nil,
            resourceURL: resourceURL,
            readResourceText: { _ in publicKey.base64EncodedString() }
        )

        guard case .trustedPublicKey(let rawRepresentation) = configuration else {
            return XCTFail("Expected trusted key configuration, got \(configuration)")
        }
        XCTAssertEqual(rawRepresentation, publicKey)
        XCTAssertTrue(configuration.canApplyRemoteUpdates)
    }

    func testCompatibilityDBPublicKeyConfigurationReadsValidResourceFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityKeyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let publicKey = P256.Signing.PrivateKey().publicKey.rawRepresentation
        let resourceURL = root.appending(path: "CompatibilityDBPublicKey.base64")
        try publicKey.base64EncodedString().write(to: resourceURL, atomically: true, encoding: .utf8)

        let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
            infoDictionaryValue: nil,
            resourceURL: resourceURL
        )

        guard case .trustedPublicKey(let rawRepresentation) = configuration else {
            return XCTFail("Expected trusted key configuration, got \(configuration)")
        }
        XCTAssertEqual(rawRepresentation, publicKey)
    }

    func testBundledCompatibilityDBPublicKeyResourceIsTrusted() throws {
        let resourceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "CompatibilityDBPublicKey", withExtension: "base64")
        )

        let configuration = AppServices.compatibilityDBPublicKeyConfiguration(
            infoDictionaryValue: nil,
            resourceURL: resourceURL
        )

        guard case .trustedPublicKey = configuration else {
            return XCTFail("Expected bundled compatibility DB public key to be trusted, got \(configuration)")
        }
        XCTAssertTrue(configuration.canApplyRemoteUpdates)
    }

    private func readyAppStateForSetupStageTests() -> AppState {
        let appState = AppState()
        appState.selectedRootURL = URL(fileURLWithPath: "/tmp/ForgePlay")
        appState.latestChecks = [
            SystemCheckResult(
                title: "Mac 상태 확인",
                detail: "OK",
                status: .ok,
                technicalDetail: nil
            )
        ]
        appState.runtimeExecutableURL = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine/bin/wine")
        return appState
    }

    private func orderedSystemChecks(
        appleSiliconStatus: CheckStatus = .ok,
        operatingSystemStatus: CheckStatus = .ok,
        storageStatus: CheckStatus = .ok,
        runtimeStatus: CheckStatus = .ok,
        runtimeTechnicalDetail: String? = nil,
        steamPrefixStatus: CheckStatus = .ok,
        steamPrefixTechnicalDetail: String? = nil
    ) -> [SystemCheckResult] {
        [
            SystemCheckResult(
                category: .appleSilicon,
                title: "check-0",
                detail: "fixture",
                status: appleSiliconStatus
            ),
            SystemCheckResult(
                category: .operatingSystem,
                title: "check-1",
                detail: "fixture",
                status: operatingSystemStatus
            ),
            SystemCheckResult(
                category: .storage,
                title: "check-2",
                detail: "fixture",
                status: storageStatus
            ),
            SystemCheckResult(
                category: .windowsRuntime,
                title: "check-3",
                detail: "fixture",
                status: runtimeStatus,
                technicalDetail: runtimeTechnicalDetail
            ),
            SystemCheckResult(
                category: .steamPrefix,
                title: "check-4",
                detail: "fixture",
                status: steamPrefixStatus,
                technicalDetail: steamPrefixTechnicalDetail
            )
        ]
    }

    private func makeInitializedPrefixLayout(at prefixURL: URL) throws {
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
    }

    private func makeD3DMetalSteamRuntime(
        at root: URL,
        winemacMarker: String? = nil
    ) throws -> URL {
        let runtimeRoot = root.appending(
            path: "BundledResources/Runners/ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let wineLib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
        let wineUnixModules = wineLib.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let rendererFramework = renderer.appending(path: "external/D3DMetal.framework", directoryHint: .isDirectory)
        let rendererResources = rendererFramework.appending(path: "Resources", directoryHint: .isDirectory)
        let rendererUnixModules = renderer.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        let rendererWindowsModules = renderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wineLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wineUnixModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rendererResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rendererUnixModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rendererWindowsModules, withIntermediateDirectories: true)

        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try Data().write(to: wineLib.appending(path: "libgnutls.30.dylib"))
        try Data().write(to: wineLib.appending(path: "libfreetype.6.dylib"))
        try Data().write(to: wineLib.appending(path: "libvulkan.1.dylib"))
        try Data().write(to: wineLib.appending(path: "libMoltenVK.dylib"))
        let processArgumentPolicyMarkers = [
            SteamWebHelperLaunchPolicy.argumentTargetEnvironmentKey,
            SteamWebHelperLaunchPolicy.argumentAppendEnvironmentKey,
            SteamWebHelperLaunchPolicy.argumentRootOnlyEnvironmentKey
        ].joined(separator: "\0")
        for architecture in ["i386-windows", "x86_64-windows"] {
            let kernelbase = wineLib.appending(
                path: "wine/\(architecture)/kernelbase.dll"
            )
            try FileManager.default.createDirectory(
                at: kernelbase.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try processArgumentPolicyMarkers.write(
                to: kernelbase,
                atomically: true,
                encoding: .utf8
            )
        }
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdDirectory.appending(path: "MoltenVK_icd.json"), atomically: true, encoding: .utf8)
        if let winemacMarker {
            try winemacMarker.write(to: wineUnixModules.appending(path: "winemac.so"), atomically: true, encoding: .utf8)
        }
        try Data("fake-ntdll".utf8).write(to: wineUnixModules.appending(path: "ntdll.so"))
        try Data("shared".utf8).write(to: renderer.appending(path: "external/libd3dshared.dylib"))
        try Data("framework".utf8).write(to: rendererFramework.appending(path: "D3DMetal"))
        let frameworkInfo = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "D3DMetal",
                "CFBundleShortVersionString": "4.1",
                "CFBundleVersion": "4100"
            ],
            format: .xml,
            options: 0
        )
        try frameworkInfo.write(to: rendererResources.appending(path: "Info.plist"))
        for resource in [
            "default.metallib",
            "libdxccontainer.dylib",
            "libdxcompiler.dylib",
            "libdxilconv.dylib",
            "libmetalirconverter.dylib"
        ] {
            try Data("resource".utf8).write(to: rendererResources.appending(path: resource))
        }
        for relativePath in D3DMetalRendererPayloadContract.sharedUnixModuleRelativePaths {
            let link = renderer.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: D3DMetalRendererPayloadContract.sharedUnixModuleLinkTarget
            )
        }
        for module in [
            "d3d10.dll",
            "d3d11.dll",
            "d3d12.dll",
            "dxgi.dll",
            "nvapi.dll",
            "nvapi64.dll",
            "nvngx-on-metalfx.dll"
        ] {
            try Data("module".utf8).write(to: rendererWindowsModules.appending(path: module))
        }
        return launcher
    }

    private func makeWineRunner(
        in root: URL,
        launcherScript: String = "#!/bin/sh\nexit 0\n",
        wineserverScript: String
    ) throws -> URL {
        let bin = root.appending(path: "FakeRuntime/wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appending(path: "wine")
        let wineserver = bin.appending(path: "wineserver")
        try launcherScript.write(to: launcher, atomically: true, encoding: .utf8)
        try wineserverScript.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        return launcher
    }

    private func writeDXMTRendererFixture(for launcher: URL) throws {
        let runtimeRoot = launcher
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rendererRoot = runtimeRoot.appending(
            path: "Frameworks/renderer/dxmt",
            directoryHint: .isDirectory
        )
        let files = [
            "wine/x86_64-unix/winemetal.so",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/dxgi.dll",
            "wine/x86_64-windows/winemetal.dll",
            "wine/i386-windows/d3d10core.dll",
            "wine/i386-windows/d3d11.dll",
            "wine/i386-windows/dxgi.dll",
            "wine/i386-windows/winemetal.dll"
        ]
        for relativePath in files {
            let file = rendererRoot.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("dxmt fixture".utf8).write(to: file)
        }
    }

    private func projectingSteamLaunchReadiness(
        _ base: SetupReadiness,
        records: [LaunchRecord],
        currentAppSessionID: String? = nil
    ) -> SetupReadiness {
        let identity = SteamEnvironmentIdentity(
            generationID: base.steamEnvironmentGenerationID,
            createdAt: base.steamEnvironmentCreatedAt
        )
        let projection = SteamLaunchRecordLookup.newestFirstReadinessProjection(
            from: records.sorted { $0.startedAt > $1.startedAt },
            environmentIdentity: identity,
            currentAppSessionID: currentAppSessionID
        )
        return base.withSteamLaunchReadinessProjection(projection)
    }

    private func writeSteamLanguageRegistry(
        _ token: String,
        to prefix: URL
    ) throws {
        try """
        WINE REGISTRY Version 2

        [Software\\\\Valve\\\\Steam]
        "Language"="\(token)"
        """.write(
            to: prefix.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func steamUsableUIObservation() -> SteamWebHelperStartupObservation {
        SteamWebHelperStartupObservation(
            state: .ready,
            reason: nil,
            steamUIHTMLTail: ["BrowserReady: handle:65536"],
            consoleTail: [],
            webHelperTail: [
                "SP DesktopLoginWindow_uid0-'Steam': WasHidden 0: (0, 0) 700x440"
            ],
            sharedContextReadiness: .ready,
            usableUIReadiness: .loginWindow
        )
    }

    private func steamLanguageReadback(
        _ language: SteamClientLanguage
    ) -> SteamWebHelperLanguageReadback {
        SteamWebHelperLanguageReadback(
            state: .matched,
            observedLocaleIdentifiers: [language.webHelperLocaleIdentifier]
        )
    }

    private struct SteamClientServiceMutationFixture {
        let root: URL
        let prefix: URL
        let logs: URL
        let runtime: URL
        let actionLog: URL
        let registry: ManagedWineSessionRegistry
        let manager: SteamManager
    }

    private func makeSteamClientServiceMutationFixture(
        installExitCode: Int32 = 0,
        queryExitCode: Int32 = 0,
        wineserverExitCodes: [Int32] = [0]
    ) throws -> SteamClientServiceMutationFixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamClientServiceMutation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let logs = try pathManager.url(for: .launchLogs)
        let source = SteamClientServiceContract.sourceExecutable(in: prefix)
        let serviceControl = SteamClientServiceContract
            .serviceControlExecutable(in: prefix)
        let runtimeBin = root.appending(
            path: "FakeRuntime/wine/bin",
            directoryHint: .isDirectory
        )
        let runtime = runtimeBin.appending(path: "wine")
        let wineLoader = runtimeBin.appending(path: "wine.bin")
        let wineserver = runtimeBin.appending(path: "wineserver")
        for directory in [
            prefix,
            logs,
            source.deletingLastPathComponent(),
            serviceControl.deletingLastPathComponent(),
            runtimeBin
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("current-service".utf8).write(to: source)
        try Data("service-control".utf8).write(to: serviceControl)
        try #"""
        #!/bin/sh
        printf 'runtime:%s\n' "$2" >> "$WINEPREFIX/service-transaction-actions.txt"
        if [ -n "$FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE" ]; then
          recorded_seconds=$(/bin/date +%s)
          recorded_milliseconds=$((recorded_seconds * 1000))
          started_microseconds=$((recorded_seconds * 1000000))
          printf '{"schema_version":1,"producer":"forgeplay-wine-runtime","event_code":"darwin_process_started","role":"wine-loader","run_identifier":"%s","prefix_scope":"%s","runtime_fingerprint":"%s","darwin_pid":2147483647,"recorded_at_unix_milliseconds":%s,"process_started_at_unix_microseconds":%s}\n' \
            "$FORGEPLAY_MANAGED_WINE_PROCESS_RUN_ID" \
            "$FORGEPLAY_MANAGED_WINE_PREFIX_SCOPE" \
            "$FORGEPLAY_MANAGED_WINE_RUNTIME_FINGERPRINT" \
            "$recorded_milliseconds" \
            "$started_microseconds" \
            >> "$FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE"
        fi
        case "$2" in
          /install)
            if [ \#(installExitCode) -ne 0 ]; then
              exit \#(installExitCode)
            fi
            /bin/mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Common Files/Steam"
            /bin/cp "$1" "$WINEPREFIX/drive_c/Program Files (x86)/Common Files/Steam/SteamService.exe"
            /bin/cat > "$WINEPREFIX/system.reg" <<'REGISTRY'
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Valve\\SteamService]
        "installpath_default"="C:\\Program Files (x86)\\Steam"

        [System\\ControlSet001\\Services\\Steam Client Service]
        "DisplayName"="Steam Client Service"
        "ImagePath"=str(2):"\"C:\\Program Files (x86)\\Common Files\\Steam\\SteamService.exe\" /RunAsService"
        "ObjectName"="LocalSystem"
        "Start"=dword:00000003
        "Type"=dword:00000010
        "WOW64"=dword:00000001
        REGISTRY
            ;;
          query)
            if [ \#(queryExitCode) -ne 0 ]; then
              exit \#(queryExitCode)
            fi
            /usr/bin/grep -q 'Steam Client Service' "$WINEPREFIX/system.reg"
            ;;
          *)
            exit 64
            ;;
        esac
        """#.write(to: runtime, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(
            to: wineLoader,
            atomically: true,
            encoding: .utf8
        )
        let exitCases = wineserverExitCodes.enumerated().map {
            "  \($0.offset + 1)) exit \($0.element) ;;"
        }.joined(separator: "\n")
        try """
        #!/bin/sh
        printf 'wineserver:%s\n' "$1" >> "$WINEPREFIX/service-transaction-actions.txt"
        counter="$WINEPREFIX/service-transaction-wineserver-count.txt"
        count=0
        if [ -f "$counter" ]; then
          count=$(/bin/cat "$counter")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$counter"
        case "$count" in
        \(exitCases)
          *) exit 0 ;;
        esac
        """.write(to: wineserver, atomically: true, encoding: .utf8)
        for executable in [runtime, wineLoader, wineserver] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let registry = ManagedWineSessionRegistry()
        let runner = SafeProcessRunner(
            sandboxEnabled: false,
            managedWineProcessJournalEnabled: true,
            managedWineProcessEvidenceSandboxEnabled: false,
            managedWineSessionRegistry: registry,
            gameModeHostApplicationGroupIdentifier: nil,
            managedWineRuntimeFingerprintResolver: {
                _ in String(repeating: "a", count: 64)
            },
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { _, _ in }
        )
        return SteamClientServiceMutationFixture(
            root: root,
            prefix: prefix,
            logs: logs,
            runtime: runtime,
            actionLog: prefix.appending(
                path: "service-transaction-actions.txt"
            ),
            registry: registry,
            manager: SteamManager(pathManager: pathManager, runner: runner)
        )
    }

    private func steamClientServiceMutationActions(
        _ fixture: SteamClientServiceMutationFixture
    ) throws -> [String] {
        try String(contentsOf: fixture.actionLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func assertSteamClientServiceMutationOwnershipRetired(
        _ fixture: SteamClientServiceMutationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            fixture.registry.launchSessions(for: fixture.prefix).isEmpty,
            "The service transaction left a registered Wine session",
            file: file,
            line: line
        )
        let enumerator = FileManager.default.enumerator(
            at: fixture.root,
            includingPropertiesForKeys: nil
        )
        let activeDescriptors = (enumerator?.allObjects as? [URL] ?? [])
            .filter {
                $0.lastPathComponent.hasSuffix(
                    ManagedWineProcessJournal.activeSessionDescriptorSuffix
                )
            }
        XCTAssertTrue(
            activeDescriptors.isEmpty,
            "The service transaction left active descriptor(s): " +
                activeDescriptors.map(\.path).joined(separator: ", "),
            file: file,
            line: line
        )
    }

    /// The synthetic executable represents the single app-bundled runtime after
    /// WindowsRuntimeService has accepted its identity. These lifecycle tests
    /// exercise cleanup behavior, not runtime selection.
    private func makeCuratedRuntimeRunner(
        sandboxEnabled: Bool = false
    ) -> SafeProcessRunner {
        SafeProcessRunner(
            sandboxEnabled: sandboxEnabled,
            managedWineProcessJournalEnabled: false,
            managedWineProcessEvidenceSandboxEnabled: false,
            managedWineRuntimeFingerprintResolver: {
                _ in String(repeating: "a", count: 64)
            },
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { _, _ in }
        )
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate project root from #filePath")
    }
}
