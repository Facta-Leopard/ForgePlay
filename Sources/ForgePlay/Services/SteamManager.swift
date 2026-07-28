// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import CryptoKit
import Darwin
import Foundation

struct SteamBootstrapLogSourceAssessment: Sendable, Hashable {
    var url: URL
    var required: Bool
    var state: SteamEvidenceReadState
    var detail: String
    var text: String

    var evidenceUnavailable: Bool {
        switch state {
        case .unreadable, .unsafe, .changedDuringRead:
            true
        case .missing:
            required
        case .captured, .truncated:
            false
        }
    }
}

struct SteamBootstrapUpdateLogAssessment: Sendable, Hashable {
    /// `nil` means that unavailable evidence prevented a reliable yes/no answer.
    var hasProgress: Bool?
    var state: SteamEvidenceReadState
    var detail: String
    var sources: [SteamBootstrapLogSourceAssessment]

    var evidenceUnavailable: Bool {
        sources.contains(where: \.evidenceUnavailable)
    }
}

/// Keeps prefix mutation and execution ownership explicit across Steam's
/// bootstrap/retry state machine. Direct callers that do not own a coordinated
/// prefix lease can omit it; `SteamPrefixService` always supplies one.
struct SteamPrefixExecutionLeaseTransition {
    let prepareForMutation: () throws -> Void
    let prepareForExecution: () throws -> Void
}

struct SteamLibraryDrivePreparation: Hashable {
    var mappings: [SteamLibraryDriveMapping]
    var discoveries: [SteamLibraryRootDiscoveryResult]
}

@MainActor
final class SteamManager {
    private struct GameLaunchDiagnosticMonitorKey: Equatable {
        var steamDirectory: String
        var processObservationLog: String
        var launchStdoutLog: String?
        var launchStderrLog: String?
        var cutoff: Date?
        var gameRunDirectory: String?
    }

    private struct BootstrapEvidenceFileMetadata: Equatable {
        var deviceNumber: UInt64
        var fileNumber: UInt64
        var byteCount: UInt64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64

        var modificationDate: Date {
            Date(
                timeIntervalSince1970: TimeInterval(modificationSeconds) +
                    TimeInterval(modificationNanoseconds) / 1_000_000_000
            )
        }
    }

    private enum BootstrapEvidenceOpenResult {
        case opened(descriptor: Int32, metadata: BootstrapEvidenceFileMetadata)
        case failed(state: SteamEvidenceReadState, detail: String)
    }

    static let officialDownloadURL = ExternalLinkPolicy.steamOfficialDownloadURL
    private nonisolated static let steamRenderingObservationTimeout: TimeInterval = 45
    private nonisolated static let steamRenderingObservationPollInterval: TimeInterval = 1
    private nonisolated static let steamProcessEvidenceTimeout: TimeInterval = 20
    private nonisolated static let steamProcessEvidencePollInterval: TimeInterval = 0.5
    private nonisolated static let steamBootstrapCompletionTimeout: TimeInterval = 600
    private nonisolated static let steamBootstrapCompletionPollInterval: TimeInterval = 1
    private nonisolated static let steamUIStartupObservationTimeout: TimeInterval = 60
    private nonisolated static let steamUIStartupObservationPollInterval: TimeInterval = 0.25
    nonisolated static let defaultSteamLaunchArguments = SteamClientCompatibilityProfile.defaultLaunchArguments
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
    private static let steamLogTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let fileManager: FileManager
    private let rendererPolicyManager: SteamRendererPolicyManager
    private let windowsFontCompatibilityProfile: WindowsFontCompatibilityProfile
    private let steamClientCompatibilityProfile: SteamClientCompatibilityProfile
    private let steamClientCompatibilityVerifier: SteamClientCompatibilityVerifier
    private let libraryDriveMapper: SteamLibraryDriveMapper
    private let libraryScanner: SteamLibraryScanner
    private let steamLaunchDiagnosticsReporter: SteamLaunchDiagnosticsReporter
    private let screenEvidenceProvider: ((ProcessRunResult) -> SteamLaunchScreenEvidence)?
    private let prefixProcessSupervisor: SteamPrefixProcessSupervisor
    private let processSnapshotProvider: () -> SteamLaunchProcessSnapshot
    private let processEvidenceTimeout: TimeInterval
    private let processEvidencePollInterval: TimeInterval
    private let renderingObservationTimeout: TimeInterval
    private let renderingObservationPollInterval: TimeInterval
    private let bootstrapCompletionTimeout: TimeInterval
    private let bootstrapCompletionPollInterval: TimeInterval
    private let steamUIStartupObservationTimeout: TimeInterval
    private let steamUIStartupObservationPollInterval: TimeInterval
    private var gameLaunchDiagnosticMonitorTask: Task<Void, Never>?
    private var gameLaunchDiagnosticMonitorKey: GameLaunchDiagnosticMonitorKey?
    private var monitoredGameLaunchDiagnostic: SteamGameLaunchDiagnostic?

    init(
        pathManager: PathManager,
        runner: SafeProcessRunner,
        fileManager: FileManager = .default,
        processSnapshotProvider: @escaping () -> SteamLaunchProcessSnapshot = SteamLaunchProcessSnapshot.current,
        processEvidenceTimeout: TimeInterval = SteamManager.steamProcessEvidenceTimeout,
        processEvidencePollInterval: TimeInterval = SteamManager.steamProcessEvidencePollInterval,
        renderingObservationTimeout: TimeInterval = SteamManager.steamRenderingObservationTimeout,
        renderingObservationPollInterval: TimeInterval = SteamManager.steamRenderingObservationPollInterval,
        bootstrapCompletionTimeout: TimeInterval = SteamManager.steamBootstrapCompletionTimeout,
        bootstrapCompletionPollInterval: TimeInterval = SteamManager.steamBootstrapCompletionPollInterval,
        steamUIStartupObservationTimeout: TimeInterval = SteamManager.steamUIStartupObservationTimeout,
        steamUIStartupObservationPollInterval: TimeInterval = SteamManager.steamUIStartupObservationPollInterval,
        screenEvidenceProvider: ((ProcessRunResult) -> SteamLaunchScreenEvidence)? = nil
    ) {
        self.pathManager = pathManager
        self.runner = runner
        self.fileManager = fileManager
        self.processSnapshotProvider = processSnapshotProvider
        self.processEvidenceTimeout = max(processEvidenceTimeout, 0)
        self.processEvidencePollInterval = max(processEvidencePollInterval, 0.1)
        self.renderingObservationTimeout = max(renderingObservationTimeout, 0)
        self.renderingObservationPollInterval = max(renderingObservationPollInterval, 0.1)
        self.bootstrapCompletionTimeout = max(bootstrapCompletionTimeout, 0)
        self.bootstrapCompletionPollInterval = max(bootstrapCompletionPollInterval, 0.1)
        self.steamUIStartupObservationTimeout = max(steamUIStartupObservationTimeout, 0)
        self.steamUIStartupObservationPollInterval = max(steamUIStartupObservationPollInterval, 0.1)
        self.screenEvidenceProvider = screenEvidenceProvider
        self.rendererPolicyManager = SteamRendererPolicyManager(fileManager: fileManager)
        self.windowsFontCompatibilityProfile = WindowsFontCompatibilityProfile(
            runner: runner,
            fileManager: fileManager
        )
        self.steamClientCompatibilityProfile = SteamClientCompatibilityProfile(
            runner: runner,
            fileManager: fileManager
        )
        self.steamClientCompatibilityVerifier = SteamClientCompatibilityVerifier(fileManager: fileManager)
        self.libraryDriveMapper = SteamLibraryDriveMapper(fileManager: fileManager)
        self.libraryScanner = SteamLibraryScanner(fileManager: fileManager)
        self.steamLaunchDiagnosticsReporter = SteamLaunchDiagnosticsReporter(fileManager: fileManager)
        self.prefixProcessSupervisor = SteamPrefixProcessSupervisor(runner: runner)
    }

    deinit {
        gameLaunchDiagnosticMonitorTask?.cancel()
    }

    func validateSteamInstaller(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased() == "steamsetup.exe" &&
            FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager)
    }

    func normalizedLibraryRoots(for selectedURL: URL) -> [URL] {
        libraryScanner.normalizedLibraryRoots(for: selectedURL)
    }

    func libraryRootDiscovery(
        for selectedURL: URL
    ) -> SteamLibraryRootDiscoveryResult {
        libraryScanner.discoverLibraryRoots(for: selectedURL)
    }

    func latestGameLaunchDiagnostic(
        in steamDirectory: URL,
        processObservationLog: URL,
        launchStdoutLog: URL? = nil,
        launchStderrLog: URL? = nil,
        since cutoff: Date?,
        observedAt: Date = Date(),
        persistTo gameRunDirectory: URL? = nil
    ) -> SteamGameLaunchDiagnostic? {
        steamLaunchDiagnosticsReporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: processObservationLog,
            launchStdoutLog: launchStdoutLog,
            launchStderrLog: launchStderrLog,
            since: cutoff,
            observedAt: observedAt,
            persistTo: gameRunDirectory
        )
    }

    /// Starts a service-owned monitor for game launches within the current
    /// Windows Steam session. The UI may observe its cached result, but evidence
    /// generation continues even when the Steam page is not visible.
    func ensureGameLaunchDiagnosticMonitoring(
        in steamDirectory: URL,
        processObservationLog: URL,
        launchStdoutLog: URL? = nil,
        launchStderrLog: URL? = nil,
        since cutoff: Date?,
        persistTo gameRunDirectory: URL? = nil
    ) {
        let key = GameLaunchDiagnosticMonitorKey(
            steamDirectory: steamDirectory.standardizedFileURL.path,
            processObservationLog: processObservationLog.standardizedFileURL.path,
            launchStdoutLog: launchStdoutLog?.standardizedFileURL.path,
            launchStderrLog: launchStderrLog?.standardizedFileURL.path,
            cutoff: cutoff,
            gameRunDirectory: gameRunDirectory?.standardizedFileURL.path
        )
        guard gameLaunchDiagnosticMonitorKey != key || gameLaunchDiagnosticMonitorTask == nil else {
            return
        }
        gameLaunchDiagnosticMonitorTask?.cancel()
        gameLaunchDiagnosticMonitorKey = key
        monitoredGameLaunchDiagnostic = nil
        let reporter = steamLaunchDiagnosticsReporter
        gameLaunchDiagnosticMonitorTask = Task { [weak self, reporter] in
            while !Task.isCancelled {
                guard self?.gameLaunchDiagnosticMonitorKey == key else { return }
                let diagnostic = await Task.detached(priority: .utility) {
                    reporter.latestGameLaunchDiagnostic(
                        in: steamDirectory,
                        processObservationLog: processObservationLog,
                        launchStdoutLog: launchStdoutLog,
                        launchStderrLog: launchStderrLog,
                        since: cutoff,
                        persistTo: gameRunDirectory
                    )
                }.value
                guard let pollInterval = self?.recordMonitoredGameLaunchDiagnostic(
                    diagnostic,
                    monitorKey: key
                ) else { return }
                do {
                    try await Task.sleep(for: .seconds(pollInterval))
                } catch {
                    return
                }
            }
        }
    }

    /// Materializes the incident-linked Steam launch evidence immediately
    /// before a support-bundle scan. When no incident is linked, the newest
    /// complete Steam launch record is used. All filesystem work runs off the
    /// main actor; only immutable paths and timestamps cross the boundary.
    func refreshGameLaunchDiagnosticEvidenceForSupportBundle(
        launchRecords: [LaunchRecord],
        incidentLaunchRecordIdentifier: String? = nil
    ) async -> SupportBundleEvidencePreparationResult {
        let record: LaunchRecord?
        if let incidentLaunchRecordIdentifier {
            guard let incidentRecord = launchRecords.first(where: {
                $0.id == incidentLaunchRecordIdentifier
            }) else {
                return .skipped("the incident-linked launch record is not available in the captured timeline")
            }
            guard incidentRecord.commandKind == "launchSteam" else {
                return .notApplicable
            }
            record = incidentRecord
        } else {
            record = launchRecords
                .filter { $0.commandKind == "launchSteam" }
                .sorted(by: { $0.startedAt > $1.startedAt })
                .first(where: {
                    $0.processObservationPath != nil && $0.stdoutPath != nil && $0.stderrPath != nil
                })
        }
        guard let record else {
            return launchRecords.contains(where: { $0.commandKind == "launchSteam" })
                ? .skipped("recent Steam launch records do not contain process-observation paths")
                : .notApplicable
        }
        guard let processObservationPath = record.processObservationPath,
              let stdoutPath = record.stdoutPath,
              let stderrPath = record.stderrPath else {
            return .skipped("the selected Steam launch record has incomplete evidence paths")
        }
        let prefix: URL
        let launchLogsRoot: URL
        do {
            prefix = try pathManager.url(for: .steamSharedPrefix)
            launchLogsRoot = try pathManager.url(for: .launchLogs)
        } catch {
            return .failed(forgePlayTechnicalErrorSummary(error))
        }
        let steamDirectory = steamExecutableURL(in: prefix).deletingLastPathComponent()
        let processObservationLog = URL(fileURLWithPath: processObservationPath)
        let stdoutLog = URL(fileURLWithPath: stdoutPath)
        let stderrLog = URL(fileURLWithPath: stderrPath)
        let standardizedLaunchLogsRoot = launchLogsRoot.standardizedFileURL.path
        guard processObservationLog.standardizedFileURL.path.hasPrefix(
            "\(standardizedLaunchLogsRoot)/"
        ), stdoutLog.standardizedFileURL.path.hasPrefix(
            "\(standardizedLaunchLogsRoot)/"
        ), stderrLog.standardizedFileURL.path.hasPrefix("\(standardizedLaunchLogsRoot)/") else {
            return .failed("the selected launch record points outside the managed Launch log root")
        }
        let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(for: stderrLog)
        guard UUID(uuidString: runIdentifier) != nil else {
            return .failed("the selected launch record has an invalid run identifier")
        }
        let gameRunDirectory = stderrLog.deletingLastPathComponent().appending(
            path: "GameRuns/\(runIdentifier)",
            directoryHint: .isDirectory
        )
        let cutoff = record.startedAt
        let captureRequestIdentifier = UUID()
        let reporter = steamLaunchDiagnosticsReporter
        let diagnostic = await Task.detached(priority: .utility) {
            reporter.latestGameLaunchDiagnostic(
                in: steamDirectory,
                processObservationLog: processObservationLog,
                launchStdoutLog: stdoutLog,
                launchStderrLog: stderrLog,
                since: cutoff,
                persistTo: gameRunDirectory,
                forceCurrentSnapshot: true,
                captureRequestIdentifier: captureRequestIdentifier
            )
        }.value
        let key = GameLaunchDiagnosticMonitorKey(
            steamDirectory: steamDirectory.standardizedFileURL.path,
            processObservationLog: processObservationLog.standardizedFileURL.path,
            launchStdoutLog: stdoutLog.standardizedFileURL.path,
            launchStderrLog: stderrLog.standardizedFileURL.path,
            cutoff: cutoff,
            gameRunDirectory: gameRunDirectory.standardizedFileURL.path
        )
        if gameLaunchDiagnosticMonitorKey == key {
            monitoredGameLaunchDiagnostic = diagnostic
        }
        guard let diagnostic else {
            if reporter.gameLaunchCaptureMatchesRequest(
                in: gameRunDirectory,
                requestIdentifier: captureRequestIdentifier
            ) {
                return .captured
            }
            return .failed("the game launch capture document was not refreshed for the current support request")
        }
        if diagnostic.structuredLogState == "captured" {
            return .captured
        }
        if diagnostic.structuredLogState.hasPrefix("failed:") {
            return .failed(diagnostic.structuredLogState)
        }
        return .skipped("the game launch diagnostic did not produce a structured evidence file")
    }

    private func recordMonitoredGameLaunchDiagnostic(
        _ diagnostic: SteamGameLaunchDiagnostic?,
        monitorKey: GameLaunchDiagnosticMonitorKey
    ) -> TimeInterval? {
        guard gameLaunchDiagnosticMonitorKey == monitorKey else { return nil }
        monitoredGameLaunchDiagnostic = diagnostic
        return switch diagnostic?.state {
        case .launching:
            3
        case .running, .runningHeadless:
            15
        case .earlyExit, .exitedWithError, .exited, .rendererError:
            60
        case nil:
            15
        }
    }

    func currentMonitoredGameLaunchDiagnostic(
        in steamDirectory: URL,
        processObservationLog: URL,
        launchStdoutLog: URL? = nil,
        launchStderrLog: URL? = nil,
        since cutoff: Date?,
        persistTo gameRunDirectory: URL? = nil
    ) -> SteamGameLaunchDiagnostic? {
        let key = GameLaunchDiagnosticMonitorKey(
            steamDirectory: steamDirectory.standardizedFileURL.path,
            processObservationLog: processObservationLog.standardizedFileURL.path,
            launchStdoutLog: launchStdoutLog?.standardizedFileURL.path,
            launchStderrLog: launchStderrLog?.standardizedFileURL.path,
            cutoff: cutoff,
            gameRunDirectory: gameRunDirectory?.standardizedFileURL.path
        )
        guard gameLaunchDiagnosticMonitorKey == key else { return nil }
        return monitoredGameLaunchDiagnostic
    }

    func installSteam(runtimeExecutable: URL, installer: URL) async throws -> SteamInstallResult {
        try requireSteamInstaller(installer)
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let logDirectory = try pathManager.url(for: .installLogs)
        let steamExecutable = steamExecutableURL(in: prefix)
        let executableFingerprintBefore = steamExecutableFingerprint(steamExecutable)
        let processResult = try await runner.run(.installSteam(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            installer: installer,
            logDirectory: logDirectory
        ))
        let executableFingerprintAfter = steamExecutableFingerprint(steamExecutable)
        return SteamInstallResult(
            processResult: processResult,
            steamExecutableURL: steamExecutable,
            hasSteamExecutable: executableFingerprintAfter != nil,
            hadSteamExecutableBeforeInstall: executableFingerprintBefore != nil,
            didObserveSteamExecutableMutation: executableFingerprintBefore != executableFingerprintAfter
        )
    }

    private func steamExecutableFingerprint(_ executable: URL) -> String? {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(executable, fileManager: fileManager),
              let data = try? Data(contentsOf: executable, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func prepareInstalledSteamForFirstLaunch(
        runtimeExecutable: URL,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB
    ) async throws {
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let logDirectory = try pathManager.url(for: .installLogs)
        _ = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        try await applySteamClientCompatibilityProfile(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            videoMemorySizeMB: videoMemorySizeMB
        )
        try restoreSteamRendererBridgeModules(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable
        )
        _ = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
    }

    func launchSteam(
        runtimeExecutable: URL,
        verificationMode: SteamLaunchVerificationMode,
        rendererPolicy requestedRendererPolicy: SteamRendererPolicyPreference? = nil,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB,
        steamArguments: [String]? = nil,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = [],
        prefixExecutionLeaseTransition: SteamPrefixExecutionLeaseTransition? = nil
    ) async throws -> ProcessRunResult {
        do {
            let result = try await launchSteamUnfinalized(
                runtimeExecutable: runtimeExecutable,
                verificationMode: verificationMode,
                rendererPolicy: requestedRendererPolicy,
                gameModePolicy: gameModePolicy,
                videoMemorySizeMB: videoMemorySizeMB,
                steamArguments: steamArguments,
                libraryRoots: libraryRoots,
                reservedLibraryRoots: reservedLibraryRoots,
                prefixExecutionLeaseTransition: prefixExecutionLeaseTransition
            )
            let finalizedResult = await runner.finalizeProcessEvidence(result)
            beginGameLaunchDiagnosticMonitoring(for: finalizedResult)
            return finalizedResult
        } catch {
            let evidenceResults = diagnosticProcessRunResults(from: error)
            guard !evidenceResults.isEmpty else { throw error }

            var finalizedResults: [ProcessRunResult] = []
            finalizedResults.reserveCapacity(evidenceResults.count)
            for result in evidenceResults {
                finalizedResults.append(await runner.finalizeProcessEvidence(result))
            }
            var primaryResult = finalizedResults[0]
            Self.attachLaunchChainEvidence(
                [],
                auxiliaryResults: Array(finalizedResults.dropFirst()),
                to: &primaryResult
            )
            primaryResult = await runner.finalizeProcessEvidence(primaryResult)
            let underlyingError = (error as? ProcessExecutionEvidenceError)?.underlyingError ?? error
            throw ProcessExecutionEvidenceError(
                underlyingError: underlyingError,
                result: primaryResult
            )
        }
    }

    private func beginGameLaunchDiagnosticMonitoring(for result: ProcessRunResult) {
        guard let processObservationLog = result.processObservationLog,
              let prefix = try? steamPrefixURL(for: result.executable) else { return }
        let steamDirectory = steamExecutableURL(in: prefix).deletingLastPathComponent()
        let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(for: result.stderrLog)
        let gameRunDirectory: URL? = UUID(uuidString: runIdentifier).map { _ in
            result.stderrLog.deletingLastPathComponent().appending(
                path: "GameRuns/\(runIdentifier)",
                directoryHint: .isDirectory
            )
        }
        ensureGameLaunchDiagnosticMonitoring(
            in: steamDirectory,
            processObservationLog: processObservationLog,
            launchStdoutLog: result.stdoutLog,
            launchStderrLog: result.stderrLog,
            since: result.startedAt,
            persistTo: gameRunDirectory
        )
    }

    private func launchSteamUnfinalized(
        runtimeExecutable: URL,
        verificationMode: SteamLaunchVerificationMode,
        rendererPolicy requestedRendererPolicy: SteamRendererPolicyPreference? = nil,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB,
        steamArguments: [String]? = nil,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = [],
        prefixExecutionLeaseTransition: SteamPrefixExecutionLeaseTransition? = nil
    ) async throws -> ProcessRunResult {
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: runtimeExecutable,
            supplementalRendererRoot: ForgePlaySupplementalRendererPolicy.rendererRoot(containingPrefix: prefix),
            fileManager: fileManager
        )
        let steamCompatibility = steamClientCompatibilityVerifier.verify(capability: capability)
        let logDirectory = try pathManager.url(for: .launchLogs)
        let steamExecutable = steamExecutableURL(in: prefix)
        let expectedLaunchRunner = steamLaunchObservedRunnerExecutable(for: runtimeExecutable)
        let launchTarget = SteamLaunchTarget(
            expectedRunnerPath: expectedLaunchRunner,
            expectedPrefixPath: prefix,
            expectedSteamExecutablePath: steamExecutable,
            allowHostSteam: verificationMode == .operational
        )
        let steamDirectory = steamExecutable.deletingLastPathComponent()
        let dumpsDirectory = steamDirectory.appending(path: "dumps", directoryHint: .isDirectory)
        let crashDumpObservationContext = steamLaunchDiagnosticsReporter
            .beginCrashDumpObservationContext()
        defer {
            steamLaunchDiagnosticsReporter.discardCrashDumpObservationContext(
                crashDumpObservationContext
            )
        }
        let dumpsBeforePreflight = steamLaunchDiagnosticsReporter.recentSteamCrashDumps(
            in: dumpsDirectory,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        let preflightSnapshot = processSnapshotProvider()
        let preflightAssessment = await steamLaunchPreflightAssessment(
            capability: capability,
            compatibility: steamCompatibility,
            target: launchTarget,
            processSnapshot: preflightSnapshot,
            logDirectory: logDirectory,
            verificationMode: verificationMode
        )
        guard preflightAssessment.status != .blocked else {
            return try blockedSteamLaunchResult(
                logDirectory: logDirectory,
                launchTarget: launchTarget,
                capability: capability,
                assessment: preflightAssessment,
                steamDirectory: steamDirectory,
                dumpsBefore: dumpsBeforePreflight,
                processSnapshot: preflightSnapshot,
                crashDumpObservationContext: crashDumpObservationContext
            )
        }
        try requireSteamExecutable(steamExecutable)
        let steamRendererPolicy = try rendererPolicyManager.resolvedPolicy(
            requestedRendererPolicy,
            capability: capability
        )
        let rendererSelection = SteamRendererPolicyManager.selection(for: steamRendererPolicy)
        let initialRendererInspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        guard initialRendererInspection.status == .ok || initialRendererInspection.requiresApply else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(initialRendererInspection.userMessage)
        }
        let runnerVersionEvidence = await captureWineVersionEvidence(for: expectedLaunchRunner)
        var preflightShutdown = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        let clientPayloadWasMissingBeforeLaunch = !SteamClientCompatibilityProfileContract.hasSteamClientPayload(
            in: prefix,
            fileManager: fileManager
        )
        try await applySteamClientCompatibilityProfile(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            videoMemorySizeMB: videoMemorySizeMB
        )
        let rendererInspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        guard rendererInspection.status == .ok else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(rendererInspection.userMessage)
        }
        let libraryDrivePreparation = try prepareSteamLibraryDriveLinksWithEvidence(
            prefix: prefix,
            libraryRoots: libraryRoots,
            reservedLibraryRoots: reservedLibraryRoots,
            logDirectory: logDirectory
        )
        let libraryDriveMappings = libraryDrivePreparation.mappings
        try synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: libraryDriveMappings,
            discoveries: libraryDrivePreparation.discoveries,
            logDirectory: logDirectory
        )
        let launchExternalStorageRoots = libraryDriveMappings.map(\.macDriveRootURL)
        let resolvedSteamArguments = steamArguments
            ?? SteamClientCompatibilityProfile.defaultLaunchArguments
        var processSnapshotBeforeLaunch = processSnapshotProvider()
        var hostSteamProcessesBeforeLaunch = processSnapshotBeforeLaunch.hostMacOSSteamProcesses
        var externalRunnerProcessesBeforeLaunch = processSnapshotBeforeLaunch.externalApplicationRunnerProcesses
        let dumpsBeforeLaunchScan = steamLaunchDiagnosticsReporter.recentSteamCrashDumpScan(
            in: dumpsDirectory,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        let dumpsBeforeLaunch = dumpsBeforeLaunchScan.urls
        let dumpFingerprintsBeforeLaunch = dumpsBeforeLaunchScan.fingerprints
        var dumpFingerprintsObservedAcrossAttempts = dumpFingerprintsBeforeLaunch
        var priorLaunchAttempts: [SteamLaunchAttemptEvidence] = []
        var steamUIStartupLogCursor = steamLaunchDiagnosticsReporter
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        try prefixExecutionLeaseTransition?.prepareForExecution()
        var result = try await runner.run(.launchSteam(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: resolvedSteamArguments,
            graphicsBackend: steamRendererPolicy,
            gameModePolicy: gameModePolicy,
            logDirectory: logDirectory,
            externalStorageRoots: launchExternalStorageRoots
        ))
        if verificationMode == .operational {
            let immediateProcessSnapshot = currentSteamLaunchProcessSnapshot(
                for: result,
                target: launchTarget
            )
            let initialBootstrapLogAssessment = steamBootstrapUpdateLogAssessment(
                result: result,
                steamDirectory: steamDirectory
            )
            let initialBootstrapUpdateInProgress = initialBootstrapLogAssessment.hasProgress == true
            let processSnapshotAfterLaunch: SteamLaunchProcessSnapshot
            if result.succeeded, !initialBootstrapUpdateInProgress {
                processSnapshotAfterLaunch = await waitForSteamLaunchProcessEvidence(
                    for: launchTarget,
                    initialSnapshot: immediateProcessSnapshot,
                    result: result,
                    verificationMode: .operational
                )
            } else {
                processSnapshotAfterLaunch = immediateProcessSnapshot
            }
            let launchCommandSucceeded = result.succeeded
            let hostSteamProcessesAfterLaunch = processSnapshotAfterLaunch.hostMacOSSteamProcesses
            let newlyLaunchedHostSteamProcesses = MacOSSteamProcessSnapshot(
                processes: hostSteamProcessesAfterLaunch
            )
            .newProcesses(since: MacOSSteamProcessSnapshot(processes: hostSteamProcessesBeforeLaunch))
            let externalRunnerProcessesAfterLaunch = processSnapshotAfterLaunch.externalApplicationRunnerProcesses
            let newlyLaunchedExternalRunnerProcesses = SteamLaunchProcessSnapshot(
                processes: externalRunnerProcessesAfterLaunch
            )
            .newProcesses(since: SteamLaunchProcessSnapshot(processes: externalRunnerProcessesBeforeLaunch))
            let dumpCandidates = steamLaunchDiagnosticsReporter.recentSteamCrashDumpScan(
                in: dumpsDirectory,
                since: Date(timeIntervalSince1970: 0),
                observationContext: crashDumpObservationContext
            )
            let newDumps = Self.newSteamCrashDumps(
                in: dumpCandidates,
                excluding: dumpFingerprintsBeforeLaunch
            )
            let fatalCrashDumps = Self.fatalSteamCrashDumps(in: newDumps)
            let assertDumps = Self.assertSteamDumps(in: newDumps)
            let launchLogCutoff = result.startedAt.addingTimeInterval(-2)
            let renderingIssue = steamLaunchDiagnosticsReporter.detectSteamWebHelperRenderingFailure(
                in: steamDirectory,
                since: launchLogCutoff,
                logCursor: steamUIStartupLogCursor
            )
            let screenEvidence = SteamLaunchScreenEvidence.notCaptured(
                "operational launch does not capture the user's screen or claim visible UI conformance"
            )
            let launchAssessment = steamLaunchHardGateAssessment(
                target: launchTarget,
                after: processSnapshotAfterLaunch,
                hostSteamProcessesBeforeLaunch: hostSteamProcessesBeforeLaunch,
                hostSteamProcessesAfterLaunch: hostSteamProcessesAfterLaunch,
                newlyLaunchedHostSteamProcesses: newlyLaunchedHostSteamProcesses,
                externalRunnerProcessesBeforeLaunch: externalRunnerProcessesBeforeLaunch,
                externalRunnerProcessesAfterLaunch: externalRunnerProcessesAfterLaunch,
                launchCommandSucceeded: launchCommandSucceeded,
                crashDumps: fatalCrashDumps,
                assertDumps: assertDumps,
                renderingIssue: renderingIssue,
                runnerVersionEvidence: runnerVersionEvidence,
                screenEvidence: screenEvidence,
                verificationMode: .operational,
                steamUIStartupFailure: nil
            )
            let finalBootstrapLogAssessment = steamBootstrapUpdateLogAssessment(
                result: result,
                steamDirectory: steamDirectory
            )
            let bootstrapUpdateInProgress = steamBootstrapUpdateIsInProgress(
                result: result,
                launchTarget: launchTarget,
                processSnapshot: processSnapshotAfterLaunch,
                renderingIssue: renderingIssue,
                fatalCrashDumps: fatalCrashDumps,
                hasBootstrapUpdateProgress: initialBootstrapUpdateInProgress ||
                    finalBootstrapLogAssessment.hasProgress == true
            )
            let effectiveLaunchAssessment = bootstrapUpdateInProgress
                ? steamBootstrapUpdateDeferredAssessment(from: launchAssessment)
                : launchAssessment
            let shouldDeferSteamUIVerification = effectiveLaunchAssessment.status == .deferred
            let processVerificationUnavailable = shouldDeferSteamUIVerification && !bootstrapUpdateInProgress
            let launchAssessmentAccepted = effectiveLaunchAssessment.status == .launched
            if bootstrapUpdateInProgress {
                result.forgePlayStatusCode = Self.steamBootstrapUpdateInProgressExitCode
            } else if processVerificationUnavailable {
                result.forgePlayStatusCode = Self.steamLaunchProcessVerificationUnavailableExitCode
            } else if launchCommandSucceeded, !launchAssessmentAccepted {
                result.forgePlayStatusCode = Self.hardGateEvidenceIncompleteExitCode
            }
            var failureShutdown: ProcessRunResult?
            var failureShutdownError: Error?
            if !shouldDeferSteamUIVerification && (!launchCommandSucceeded || !launchAssessmentAccepted) {
                let shutdownOutcome = await prefixProcessSupervisor.shutdownAfterFailure(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
                failureShutdown = shutdownOutcome.result
                failureShutdownError = shutdownOutcome.error
            }
            Self.attachLaunchChainEvidence(
                priorLaunchAttempts,
                auxiliaryResults: [preflightShutdown] + [failureShutdown].compactMap { $0 },
                to: &result
            )
            let diagnosticCapture = Result {
                try steamLaunchDiagnosticsReporter.writeDiagnostics(
                    for: result,
                preflightShutdown: preflightShutdown,
                failureShutdown: failureShutdown,
                failureShutdownError: failureShutdownError,
                priorLaunchAttempts: priorLaunchAttempts,
                dumps: fatalCrashDumps,
                steamDirectory: steamDirectory,
                renderingIssue: renderingIssue,
                hostSteamProcesses: newlyLaunchedHostSteamProcesses,
                hostSteamProcessesBefore: hostSteamProcessesBeforeLaunch,
                hostSteamProcessesAfter: hostSteamProcessesAfterLaunch,
                externalApplicationRunnerProcesses: newlyLaunchedExternalRunnerProcesses,
                externalApplicationRunnerProcessesBefore: externalRunnerProcessesBeforeLaunch,
                externalApplicationRunnerProcessesAfter: externalRunnerProcessesAfterLaunch,
                processSnapshotBefore: processSnapshotBeforeLaunch.processes,
                processSnapshotAfter: processSnapshotAfterLaunch.processes,
                launchTarget: launchTarget,
                runnerCapability: capability,
                runnerVersionEvidence: runnerVersionEvidence,
                dumpsBefore: dumpsBeforeLaunch,
                dumpsAfter: newDumps,
                gateStatus: effectiveLaunchAssessment.status,
                reasonCodes: effectiveLaunchAssessment.reasonCodes,
                hardGateFailureReasons: effectiveLaunchAssessment.diagnosticReasons,
                webHelperCommandLines: processSnapshotAfterLaunch.webHelperCommandLines(for: launchTarget),
                screenEvidence: screenEvidence,
                launchEnvironmentSummary: steamLaunchDiagnosticsReporter.launchEnvironmentSummary(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    rendererPolicy: steamRendererPolicy
                ),
                logCursor: steamUIStartupLogCursor,
                crashDumpObservationContext: crashDumpObservationContext,
                    since: launchLogCutoff
                )
            }
            _ = applyDiagnosticsCapture(diagnosticCapture, to: &result)
            applyProcessObservationReadWarning(processSnapshotAfterLaunch, to: &result)
            applyBootstrapLogEvidenceWarnings(
                [initialBootstrapLogAssessment, finalBootstrapLogAssessment],
                to: &result
            )
            if shouldDeferSteamUIVerification {
                result.steamUIVerificationState = .launchedButUnverified
            } else {
                result.steamUIVerificationState = result.succeeded && launchAssessmentAccepted
                    ? .launchedButUnverified
                    : .failed
            }
            return result
        }
        let clientMutationDetectedAfterLaunch = clientPayloadWasMissingBeforeLaunch
            ? false
            : await waitForSteamClientMutationAfterLaunch(
                result: result,
                prefix: prefix,
                steamDirectory: steamDirectory,
                videoMemorySizeMB: videoMemorySizeMB
            )
        if (clientPayloadWasMissingBeforeLaunch || clientMutationDetectedAfterLaunch),
           result.succeeded,
           !result.waitedForExit,
           await waitForSteamClientBootstrapCompletion(
               result: result,
               prefix: prefix,
               steamDirectory: steamDirectory,
               launchTarget: launchTarget,
               requiresUpdaterCompletion: clientMutationDetectedAfterLaunch
           ) {
            appendPriorLaunchAttempt(
                result,
                reason: clientPayloadWasMissingBeforeLaunch
                    ? .clientBootstrapCompleted
                    : .steamClientUpdated,
                preLaunchShutdownResult: preflightShutdown,
                dumpsDirectory: dumpsDirectory,
                crashDumpObservationContext: crashDumpObservationContext,
                knownDumpFingerprints: &dumpFingerprintsObservedAcrossAttempts,
                attempts: &priorLaunchAttempts
            )
            do {
                preflightShutdown = try await prefixProcessSupervisor.shutdownBeforeLaunch(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
                try prefixExecutionLeaseTransition?.prepareForMutation()
                try await applySteamClientCompatibilityProfile(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    videoMemorySizeMB: videoMemorySizeMB
                )
                let postBootstrapRendererInspection = inspectSteamRendererPolicy(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    selection: rendererSelection,
                    videoMemorySizeMB: videoMemorySizeMB
                )
                guard postBootstrapRendererInspection.status == .ok else {
                    throw SteamLaunchError.rendererPolicyVerificationFailed(
                        postBootstrapRendererInspection.userMessage
                    )
                }
                processSnapshotBeforeLaunch = processSnapshotProvider()
                hostSteamProcessesBeforeLaunch = processSnapshotBeforeLaunch.hostMacOSSteamProcesses
                externalRunnerProcessesBeforeLaunch = processSnapshotBeforeLaunch.externalApplicationRunnerProcesses
                steamUIStartupLogCursor = steamLaunchDiagnosticsReporter
                    .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
                try prefixExecutionLeaseTransition?.prepareForExecution()
                result = try await runner.run(.launchSteam(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    steamExecutable: steamExecutable,
                    steamArguments: resolvedSteamArguments,
                    graphicsBackend: steamRendererPolicy,
                    gameModePolicy: gameModePolicy,
                    logDirectory: logDirectory,
                    externalStorageRoots: launchExternalStorageRoots
                ))
                Self.attachLaunchChainEvidence(
                    priorLaunchAttempts,
                    auxiliaryResults: [preflightShutdown],
                    to: &result
                )
            } catch {
                var failedResult = result
                failedResult.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    failedResult.diagnosticCaptureWarning,
                    "Steam bootstrap relaunch preparation failed: \(forgePlayTechnicalErrorSummary(error))"
                )
                Self.attachLaunchChainEvidence(
                    priorLaunchAttempts,
                    auxiliaryResults: [preflightShutdown],
                    to: &failedResult
                )
                throw ProcessExecutionEvidenceError(
                    underlyingError: error,
                    result: failedResult
                )
            }
        }
        var steamUIStartupObservation = await observeSteamUIStartup(
            result: result,
            prefix: prefix,
            steamDirectory: steamDirectory,
            launchTarget: launchTarget,
            logCursor: steamUIStartupLogCursor
        )
        if steamUIStartupObservation.shouldRetry {
            let recoveryReason = steamUIStartupObservation.reason ??
                "Steam WebHelper startup failed before the shared UI context became ready"
            appendPriorLaunchAttempt(
                result,
                reason: .webHelperStartupRecovery,
                preLaunchShutdownResult: preflightShutdown,
                dumpsDirectory: dumpsDirectory,
                crashDumpObservationContext: crashDumpObservationContext,
                knownDumpFingerprints: &dumpFingerprintsObservedAcrossAttempts,
                attempts: &priorLaunchAttempts
            )
            do {
                preflightShutdown = try await prefixProcessSupervisor.shutdownBeforeLaunch(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
                try prefixExecutionLeaseTransition?.prepareForMutation()
                try await applySteamClientCompatibilityProfile(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    videoMemorySizeMB: videoMemorySizeMB
                )
                let retryRendererInspection = inspectSteamRendererPolicy(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    selection: rendererSelection,
                    videoMemorySizeMB: videoMemorySizeMB
                )
                guard retryRendererInspection.status == .ok else {
                    throw SteamLaunchError.rendererPolicyVerificationFailed(
                        retryRendererInspection.userMessage
                    )
                }
                processSnapshotBeforeLaunch = processSnapshotProvider()
                hostSteamProcessesBeforeLaunch = processSnapshotBeforeLaunch.hostMacOSSteamProcesses
                externalRunnerProcessesBeforeLaunch = processSnapshotBeforeLaunch.externalApplicationRunnerProcesses
                steamUIStartupLogCursor = steamLaunchDiagnosticsReporter
                    .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
                try prefixExecutionLeaseTransition?.prepareForExecution()
                result = try await runner.run(.launchSteam(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    steamExecutable: steamExecutable,
                    steamArguments: resolvedSteamArguments,
                    graphicsBackend: steamRendererPolicy,
                    gameModePolicy: gameModePolicy,
                    logDirectory: logDirectory,
                    externalStorageRoots: launchExternalStorageRoots
                ))
                result.steamUIStartupRecoveryAttemptCount = 1
                result.steamUIStartupRecoveryReason = recoveryReason
                Self.attachLaunchChainEvidence(
                    priorLaunchAttempts,
                    auxiliaryResults: [preflightShutdown],
                    to: &result
                )
            } catch {
                var failedResult = result
                failedResult.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    failedResult.diagnosticCaptureWarning,
                    "Steam UI recovery relaunch failed: \(forgePlayTechnicalErrorSummary(error))"
                )
                Self.attachLaunchChainEvidence(
                    priorLaunchAttempts,
                    auxiliaryResults: [preflightShutdown],
                    to: &failedResult
                )
                throw ProcessExecutionEvidenceError(
                    underlyingError: error,
                    result: failedResult
                )
            }
            steamUIStartupObservation = await observeSteamUIStartup(
                result: result,
                prefix: prefix,
                steamDirectory: steamDirectory,
                launchTarget: launchTarget,
                logCursor: steamUIStartupLogCursor
            )
        }
        let steamUIStartupRecoveryExhausted =
            result.steamUIStartupRecoveryAttemptCount > 0 && steamUIStartupObservation.state != .ready
        let steamUIStartupFailureReason = steamUIStartupRecoveryExhausted
            ? (steamUIStartupObservation.reason ?? "Steam WebHelper did not become ready before the startup timeout")
            : nil
        let launchLogCutoff = result.startedAt.addingTimeInterval(-2)
        let immediateProcessSnapshot = currentSteamLaunchProcessSnapshot(
            for: result,
            target: launchTarget
        )
        let initialBootstrapLogAssessment = steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory
        )
        let initialBootstrapUpdateInProgress = initialBootstrapLogAssessment.hasProgress == true
        let observedProcessSnapshot: SteamLaunchProcessSnapshot
        if result.succeeded, !result.waitedForExit, !initialBootstrapUpdateInProgress {
            observedProcessSnapshot = await waitForSteamLaunchProcessEvidence(
                for: launchTarget,
                initialSnapshot: immediateProcessSnapshot,
                result: result,
                verificationMode: verificationMode
            )
        } else if result.succeeded, !result.waitedForExit, initialBootstrapUpdateInProgress {
            observedProcessSnapshot = immediateProcessSnapshot
        } else {
            observedProcessSnapshot = immediateProcessSnapshot
        }
        let finalBootstrapLogAssessment = steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory
        )
        let bootstrapUpdateInProgressBeforeRenderingObservation = initialBootstrapUpdateInProgress ||
            finalBootstrapLogAssessment.hasProgress == true
        let renderingIssue: SteamWebHelperRenderingIssue?
        if verificationMode == .conformance,
           result.succeeded,
           !result.waitedForExit,
           !bootstrapUpdateInProgressBeforeRenderingObservation,
           observedProcessSnapshot.containsExpectedPrefixSteamProcess(for: launchTarget) {
            renderingIssue = await steamLaunchDiagnosticsReporter.waitForSteamWebHelperRenderingFailure(
                in: steamDirectory,
                since: launchLogCutoff,
                timeout: renderingObservationTimeout,
                pollInterval: renderingObservationPollInterval,
                logCursor: steamUIStartupLogCursor
            )
        } else {
            renderingIssue = steamLaunchDiagnosticsReporter.detectSteamWebHelperRenderingFailure(
                in: steamDirectory,
                since: launchLogCutoff,
                logCursor: steamUIStartupLogCursor
            )
        }
        let launchCommandSucceeded = result.succeeded
        let dumpCandidatesAfterLaunch = steamLaunchDiagnosticsReporter.recentSteamCrashDumpScan(
            in: dumpsDirectory,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        let dumpsAfterLaunch = Self.newSteamCrashDumps(
            in: dumpCandidatesAfterLaunch,
            excluding: dumpFingerprintsBeforeLaunch
        )
        let fatalCrashDumps = Self.fatalSteamCrashDumps(in: dumpsAfterLaunch)
        let assertDumps = Self.assertSteamDumps(in: dumpsAfterLaunch)
        let processSnapshotAfterLaunch = observedProcessSnapshot
        let hostSteamProcessesAfterLaunch = processSnapshotAfterLaunch.hostMacOSSteamProcesses
        let newlyLaunchedHostSteamProcesses = MacOSSteamProcessSnapshot(processes: hostSteamProcessesAfterLaunch)
            .newProcesses(since: MacOSSteamProcessSnapshot(processes: hostSteamProcessesBeforeLaunch))
        let externalRunnerProcessesAfterLaunch = processSnapshotAfterLaunch.externalApplicationRunnerProcesses
        let newlyLaunchedExternalRunnerProcesses = SteamLaunchProcessSnapshot(processes: externalRunnerProcessesAfterLaunch)
            .newProcesses(since: SteamLaunchProcessSnapshot(processes: externalRunnerProcessesBeforeLaunch))
        let screenEvidence: SteamLaunchScreenEvidence
        if verificationMode.requiresVisibleUIEvidence,
           launchCommandSucceeded,
           renderingIssue == nil,
           processSnapshotAfterLaunch.containsExpectedRunnerProcess(for: launchTarget),
           processSnapshotAfterLaunch.containsExpectedPrefixSteamProcess(for: launchTarget),
           processSnapshotAfterLaunch.webHelperCommandLinesContainRequiredLaunchPolicy(for: launchTarget) {
            screenEvidence = screenEvidenceProvider?(result) ??
                steamLaunchDiagnosticsReporter.captureScreenEvidence(for: result)
        } else {
            screenEvidence = verificationMode == .operational
                ? .notCaptured("operational launch does not capture the user's screen or claim visible UI conformance")
                : .notCaptured("expected runner, WINEPREFIX Steam process, and Steam WebHelper evidence were not all present; screenshot capture was skipped")
        }
        let hardGateAssessment = steamLaunchHardGateAssessment(
            target: launchTarget,
            after: processSnapshotAfterLaunch,
            hostSteamProcessesBeforeLaunch: hostSteamProcessesBeforeLaunch,
            hostSteamProcessesAfterLaunch: hostSteamProcessesAfterLaunch,
            newlyLaunchedHostSteamProcesses: newlyLaunchedHostSteamProcesses,
            externalRunnerProcessesBeforeLaunch: externalRunnerProcessesBeforeLaunch,
            externalRunnerProcessesAfterLaunch: externalRunnerProcessesAfterLaunch,
            launchCommandSucceeded: launchCommandSucceeded,
            crashDumps: fatalCrashDumps,
            assertDumps: assertDumps,
            renderingIssue: renderingIssue,
            runnerVersionEvidence: runnerVersionEvidence,
            screenEvidence: screenEvidence,
            verificationMode: verificationMode,
            steamUIStartupFailure: steamUIStartupFailureReason
        )
        let didLaunchHostSteam = verificationMode == .conformance && !newlyLaunchedHostSteamProcesses.isEmpty
        let didObserveExternalRunner = !externalRunnerProcessesBeforeLaunch.isEmpty ||
            !externalRunnerProcessesAfterLaunch.isEmpty ||
            !newlyLaunchedExternalRunnerProcesses.isEmpty
        let didObserveExternalRunnerDuringConformance = verificationMode == .conformance && didObserveExternalRunner
        let bootstrapUpdateInProgress = steamBootstrapUpdateIsInProgress(
            result: result,
            launchTarget: launchTarget,
            processSnapshot: processSnapshotAfterLaunch,
            renderingIssue: renderingIssue,
            fatalCrashDumps: fatalCrashDumps,
            hasBootstrapUpdateProgress: bootstrapUpdateInProgressBeforeRenderingObservation
        )
        let shouldDeferSteamUIVerification = bootstrapUpdateInProgress && !didObserveExternalRunnerDuringConformance
        let effectiveHardGateAssessment = shouldDeferSteamUIVerification
            ? steamBootstrapUpdateDeferredAssessment(from: hardGateAssessment)
            : hardGateAssessment
        let acceptedGateStatus: SteamLaunchGateStatus = verificationMode == .conformance ? .success : .launched
        let launchAssessmentAccepted = effectiveHardGateAssessment.status == acceptedGateStatus
        if shouldDeferSteamUIVerification {
            result.forgePlayStatusCode = Self.steamBootstrapUpdateInProgressExitCode
        }
        let shouldStopSteamAfterLaunch = !shouldDeferSteamUIVerification && (
            !launchCommandSucceeded ||
            steamUIStartupRecoveryExhausted ||
            (verificationMode == .conformance && (
                !fatalCrashDumps.isEmpty ||
                renderingIssue != nil ||
                didLaunchHostSteam ||
                didObserveExternalRunnerDuringConformance ||
                !launchAssessmentAccepted
            ))
        )
        if shouldStopSteamAfterLaunch {
            let failureShutdown: ProcessRunResult?
            let failureShutdownError: Error?
            if launchCommandSucceeded {
                if didLaunchHostSteam {
                    result.forgePlayStatusCode = Self.hostSteamLaunchContaminationExitCode
                } else if didObserveExternalRunnerDuringConformance {
                    result.forgePlayStatusCode = Self.externalRunnerContaminationExitCode
                } else if !fatalCrashDumps.isEmpty {
                    result.forgePlayStatusCode = Self.steamCrashDumpExitCode
                } else if steamUIStartupRecoveryExhausted {
                    result.forgePlayStatusCode = Self.steamRenderingFailureExitCode
                } else if renderingIssue != nil {
                    result.forgePlayStatusCode = Self.steamRenderingFailureExitCode
                } else if !launchAssessmentAccepted {
                    result.forgePlayStatusCode = Self.hardGateEvidenceIncompleteExitCode
                } else {
                    result.forgePlayStatusCode = Self.steamRenderingFailureExitCode
                }
            }
            let shutdownOutcome = await prefixProcessSupervisor.shutdownAfterFailure(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            failureShutdown = shutdownOutcome.result
            failureShutdownError = shutdownOutcome.error
            Self.attachLaunchChainEvidence(
                priorLaunchAttempts,
                auxiliaryResults: [preflightShutdown] + [failureShutdown].compactMap { $0 },
                to: &result
            )
            let diagnosticCapture = Result {
                try steamLaunchDiagnosticsReporter.writeDiagnostics(
                    for: result,
                preflightShutdown: preflightShutdown,
                failureShutdown: failureShutdown,
                failureShutdownError: failureShutdownError,
                priorLaunchAttempts: priorLaunchAttempts,
                dumps: fatalCrashDumps,
                steamDirectory: steamDirectory,
                renderingIssue: renderingIssue,
                hostSteamProcesses: newlyLaunchedHostSteamProcesses,
                hostSteamProcessesBefore: hostSteamProcessesBeforeLaunch,
                hostSteamProcessesAfter: hostSteamProcessesAfterLaunch,
                externalApplicationRunnerProcesses: newlyLaunchedExternalRunnerProcesses,
                externalApplicationRunnerProcessesBefore: externalRunnerProcessesBeforeLaunch,
                externalApplicationRunnerProcessesAfter: externalRunnerProcessesAfterLaunch,
                processSnapshotBefore: processSnapshotBeforeLaunch.processes,
                processSnapshotAfter: processSnapshotAfterLaunch.processes,
                launchTarget: launchTarget,
                runnerCapability: capability,
                runnerVersionEvidence: runnerVersionEvidence,
                dumpsBefore: dumpsBeforeLaunch,
                dumpsAfter: dumpsAfterLaunch,
                gateStatus: effectiveHardGateAssessment.status,
                reasonCodes: effectiveHardGateAssessment.reasonCodes,
                hardGateFailureReasons: effectiveHardGateAssessment.diagnosticReasons,
                webHelperCommandLines: processSnapshotAfterLaunch.webHelperCommandLines(for: launchTarget),
                screenEvidence: screenEvidence,
                launchEnvironmentSummary: steamLaunchDiagnosticsReporter.launchEnvironmentSummary(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    rendererPolicy: steamRendererPolicy
                ),
                logCursor: steamUIStartupLogCursor,
                crashDumpObservationContext: crashDumpObservationContext,
                    since: launchLogCutoff
                )
            }
            _ = applyDiagnosticsCapture(diagnosticCapture, to: &result)
        } else {
            Self.attachLaunchChainEvidence(
                priorLaunchAttempts,
                auxiliaryResults: [preflightShutdown],
                to: &result
            )
            let diagnosticCapture = Result {
                try steamLaunchDiagnosticsReporter.writeDiagnostics(
                    for: result,
            preflightShutdown: preflightShutdown,
            failureShutdown: nil,
            failureShutdownError: nil,
            priorLaunchAttempts: priorLaunchAttempts,
            dumps: fatalCrashDumps,
            steamDirectory: steamDirectory,
            renderingIssue: renderingIssue,
            hostSteamProcesses: newlyLaunchedHostSteamProcesses,
            hostSteamProcessesBefore: hostSteamProcessesBeforeLaunch,
            hostSteamProcessesAfter: hostSteamProcessesAfterLaunch,
            externalApplicationRunnerProcesses: newlyLaunchedExternalRunnerProcesses,
            externalApplicationRunnerProcessesBefore: externalRunnerProcessesBeforeLaunch,
            externalApplicationRunnerProcessesAfter: externalRunnerProcessesAfterLaunch,
            processSnapshotBefore: processSnapshotBeforeLaunch.processes,
            processSnapshotAfter: processSnapshotAfterLaunch.processes,
            launchTarget: launchTarget,
            runnerCapability: capability,
            runnerVersionEvidence: runnerVersionEvidence,
            dumpsBefore: dumpsBeforeLaunch,
            dumpsAfter: dumpsAfterLaunch,
            gateStatus: effectiveHardGateAssessment.status,
            reasonCodes: effectiveHardGateAssessment.reasonCodes,
            hardGateFailureReasons: effectiveHardGateAssessment.diagnosticReasons,
            webHelperCommandLines: processSnapshotAfterLaunch.webHelperCommandLines(for: launchTarget),
            screenEvidence: screenEvidence,
            launchEnvironmentSummary: steamLaunchDiagnosticsReporter.launchEnvironmentSummary(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                rendererPolicy: steamRendererPolicy
            ),
            logCursor: steamUIStartupLogCursor,
            crashDumpObservationContext: crashDumpObservationContext,
                    since: launchLogCutoff
                )
            }
            let diagnosticCaptureSucceeded = applyDiagnosticsCapture(diagnosticCapture, to: &result)
            if !diagnosticCaptureSucceeded,
               verificationMode == .conformance,
               launchCommandSucceeded,
                !shouldDeferSteamUIVerification {
                result.forgePlayStatusCode = Self.hardGateEvidenceIncompleteExitCode
                let diagnosticFailureShutdown = await prefixProcessSupervisor.shutdownAfterFailure(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
                Self.attachLaunchChainEvidence(
                    priorLaunchAttempts,
                    auxiliaryResults: [preflightShutdown] +
                        [diagnosticFailureShutdown.result].compactMap { $0 },
                    to: &result
                )
            }
        }
        applyProcessObservationReadWarning(processSnapshotAfterLaunch, to: &result)
        applyBootstrapLogEvidenceWarnings(
            [initialBootstrapLogAssessment, finalBootstrapLogAssessment],
            to: &result
        )
        if result.forgePlayStatusCode == Self.steamBootstrapUpdateInProgressExitCode {
            result.steamUIVerificationState = .launchedButUnverified
        } else if result.succeeded {
            result.steamUIVerificationState = verificationMode == .conformance ? .rendered : .launchedButUnverified
        }
        result.steamUISurface = screenEvidence.surface
        return result
    }

    nonisolated static let steamCrashDumpExitCode: Int32 = 70
    nonisolated static let steamRenderingFailureExitCode: Int32 = 71
    nonisolated static let hostSteamLaunchContaminationExitCode: Int32 = 72
    nonisolated static let externalRunnerContaminationExitCode: Int32 = 73
    nonisolated static let hardGateEvidenceIncompleteExitCode: Int32 = 74
    nonisolated static let steamLaunchBlockedExitCode: Int32 = 75
    nonisolated static let steamBootstrapUpdateInProgressExitCode: Int32 = 76
    nonisolated static let steamLaunchProcessVerificationUnavailableExitCode: Int32 = 77

    private func steamPrefixURL(for _: URL) throws -> URL {
        return try pathManager.url(for: .steamSharedPrefix)
    }

    private func steamExecutableURL(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
    }

    private nonisolated static func fatalSteamCrashDumps(in dumps: [URL]) -> [URL] {
        dumps.filter { !$0.lastPathComponent.lowercased().hasPrefix("assert_") }
    }

    private nonisolated static func assertSteamDumps(in dumps: [URL]) -> [URL] {
        dumps.filter { $0.lastPathComponent.lowercased().hasPrefix("assert_") }
    }

    nonisolated static func newSteamCrashDumps(
        in scan: SteamCrashDumpScanResult,
        excluding before: Set<SteamCrashDumpFingerprint>
    ) -> [URL] {
        scan.items.compactMap { item in
            before.contains(item.fingerprint) ? nil : item.url
        }
    }

    private func appendPriorLaunchAttempt(
        _ result: ProcessRunResult,
        reason: SteamLaunchAttemptEvidence.RelaunchReason,
        preLaunchShutdownResult: ProcessRunResult?,
        dumpsDirectory: URL,
        crashDumpObservationContext: SteamCrashDumpObservationContext,
        knownDumpFingerprints: inout Set<SteamCrashDumpFingerprint>,
        attempts: inout [SteamLaunchAttemptEvidence]
    ) {
        let dumpScan = steamLaunchDiagnosticsReporter.recentSteamCrashDumpScan(
            in: dumpsDirectory,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        let newlyObservedDumps = Self.newSteamCrashDumps(
            in: dumpScan,
            excluding: knownDumpFingerprints
        )
        knownDumpFingerprints.formUnion(dumpScan.fingerprints)
        attempts.append(SteamLaunchAttemptEvidence(
            sequence: attempts.count + 1,
            relaunchReason: reason,
            result: result,
            preLaunchShutdownResult: preLaunchShutdownResult,
            crashDumpsObserved: newlyObservedDumps
        ))
    }

    private nonisolated static func attachLaunchChainEvidence(
        _ attempts: [SteamLaunchAttemptEvidence],
        auxiliaryResults: [ProcessRunResult],
        to result: inout ProcessRunResult
    ) {
        var seen = Set<String>()
        var relatedEvidence: [URL] = []
        let attemptResults = attempts.flatMap { attempt in
            [attempt.result] + [attempt.preLaunchShutdownResult].compactMap { $0 }
        }
        let candidates = result.relatedRunEvidenceLogs + (attemptResults + auxiliaryResults).flatMap {
            $0.relatedRunEvidenceLogs + [$0.runEvidenceLog].compactMap { $0 }
        }
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard result.runEvidenceLog?.standardizedFileURL.path != path,
                  seen.insert(path).inserted else {
                continue
            }
            relatedEvidence.append(candidate)
        }
        result.relatedRunEvidenceLogs = relatedEvidence
    }

    func inspectSteamRendererPolicy(
        prefix: URL,
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int? = nil
    ) -> SteamRendererPolicyInspection {
        rendererPolicyManager.inspect(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            selection: selection,
            videoMemorySizeMB: videoMemorySizeMB
        )
    }

    func prepareSteamLibraryDriveLinks(
        prefix: URL,
        libraryRoots: [URL],
        reservedLibraryRoots: [URL] = [],
        logDirectory: URL? = nil
    ) throws -> [SteamLibraryDriveMapping] {
        try prepareSteamLibraryDriveLinksWithEvidence(
            prefix: prefix,
            libraryRoots: libraryRoots,
            reservedLibraryRoots: reservedLibraryRoots,
            logDirectory: logDirectory
        ).mappings
    }

    func prepareSteamLibraryDriveLinksWithEvidence(
        prefix: URL,
        libraryRoots: [URL],
        reservedLibraryRoots: [URL] = [],
        logDirectory: URL? = nil
    ) throws -> SteamLibraryDrivePreparation {
        let discoveries = steamLibraryRootDiscoveries(for: libraryRoots)
        let driveSources: [SteamLibraryDriveSource]
        do {
            driveSources = try steamLibraryDriveSources(
                discoveries: discoveries
            )
        } catch {
            if let logDirectory {
                do {
                    try persistSteamLibraryRegistrationAudit(
                        prefix: prefix,
                        mappings: [],
                        discoveries: discoveries,
                        status: "library_discovery_failed",
                        errorDescription: forgePlayTechnicalErrorSummary(error),
                        logDirectory: logDirectory
                    )
                } catch let auditError {
                    throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                        logDirectory,
                        forgePlayTechnicalErrorSummary(error) +
                            "; discovery audit log failed: " +
                            forgePlayTechnicalErrorSummary(auditError)
                    )
                }
            }
            throw error
        }
        let normalizedReservedRoots = steamLibraryReservationRoots(
            reservedLibraryRoots
        )
        let mappings = try libraryDriveMapper.prepareDriveLinks(
            prefix: prefix,
            sources: driveSources,
            reservedDriveRoots: normalizedReservedRoots
        )
        return SteamLibraryDrivePreparation(
            mappings: mappings,
            discoveries: discoveries
        )
    }

    func synchronizeSteamLibraryRegistrations(
        prefix: URL,
        mappings: [SteamLibraryDriveMapping],
        discoveries: [SteamLibraryRootDiscoveryResult] = [],
        logDirectory: URL? = nil
    ) throws {
        do {
            try libraryDriveMapper.synchronizeDriveMappingsWithSteam(
                prefix: prefix,
                mappings: mappings
            )
        } catch {
            if let logDirectory {
                do {
                    try persistSteamLibraryRegistrationAudit(
                        prefix: prefix,
                        mappings: mappings,
                        discoveries: discoveries,
                        status: "failed",
                        errorDescription: forgePlayTechnicalErrorSummary(error),
                        logDirectory: logDirectory
                    )
                } catch let auditError {
                    throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                        prefix,
                        forgePlayTechnicalErrorSummary(error) +
                            "; registration audit log failed: " +
                            forgePlayTechnicalErrorSummary(auditError)
                    )
                }
            }
            throw error
        }
        if let logDirectory {
            do {
                try persistSteamLibraryRegistrationAudit(
                    prefix: prefix,
                    mappings: mappings,
                    discoveries: discoveries,
                    status: mappings.isEmpty
                        ? "no_authorized_storage"
                        : "success",
                    errorDescription: nil,
                    logDirectory: logDirectory
                )
            } catch {
                throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                    logDirectory,
                    "registration succeeded but its audit log could not be persisted: " +
                        forgePlayTechnicalErrorSummary(error)
                )
            }
        }
    }

    private func persistSteamLibraryRegistrationAudit(
        prefix: URL,
        mappings: [SteamLibraryDriveMapping],
        discoveries: [SteamLibraryRootDiscoveryResult] = [],
        status: String,
        errorDescription: String?,
        logDirectory: URL
    ) throws {
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            logDirectory,
            fileManager: fileManager
        )
        let logURL = logDirectory.appending(
            path: "steam_library_registration_\(UUID().uuidString.lowercased()).json",
            directoryHint: .notDirectory
        )
        var document: [String: Any] = [
            "schema_version": 1,
            "producer": "forgeplay-steam-library-registration",
            "recorded_at": ISO8601DateFormatter().string(from: Date()),
            "status": status,
            "prefix": prefix.standardizedFileURL.path,
            "mappings": mappings.map {
                [
                    "drive_letter": $0.driveLetter.uppercased(),
                    "windows_library_path": $0.windowsLibraryPath,
                    "mac_drive_root_path": $0.macDriveRootURL.standardizedFileURL.path,
                    "mac_library_path": $0.macLibraryURL.standardizedFileURL.path
                ]
            },
            "library_discovery": discoveries.map(Self.libraryDiscoveryAuditRecord)
        ]
        if let errorDescription {
            document["error"] = errorDescription
        }
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: logURL, options: .atomic)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(
            logURL,
            fileManager: fileManager
        )
    }

    private static func libraryDiscoveryAuditRecord(
        _ discovery: SteamLibraryRootDiscoveryResult
    ) -> [String: Any] {
        var record: [String: Any] = [
            "selected_root_path": discovery.selectedRoot.standardizedFileURL.path,
            "verified_library_paths": discovery.libraryRoots.map {
                $0.standardizedFileURL.path
            },
            "skipped_input_paths": discovery.skippedInputPaths.sorted(),
            "is_complete": discovery.isComplete
        ]
        if let resolution = discovery.resolution {
            record["resolution"] = resolution.rawValue
        }
        if let failure = discovery.failure {
            switch failure {
            case .traversalFailed(let url, let reason):
                record["failure_type"] = "traversal_failed"
                record["failure_path"] = url.standardizedFileURL.path
                record["failure_reason"] = reason
            case .noVerifiedSteamLibrary(let url, let skippedPaths):
                record["failure_type"] = "no_verified_steam_library"
                record["failure_path"] = url.standardizedFileURL.path
                record["failure_skipped_paths"] = skippedPaths
            case .ancestorAuthorizationRequired(
                let selectedRoot,
                let requiredRoot
            ):
                record["failure_type"] = "ancestor_authorization_required"
                record["failure_path"] = selectedRoot.standardizedFileURL.path
                record["required_root_path"] =
                    requiredRoot.standardizedFileURL.path
            }
        }
        return record
    }

    nonisolated static func mappedWindowsLibraryPath(for libraryRoot: URL, prefix: URL) -> String? {
        SteamLibraryDriveMapper.mappedWindowsLibraryPath(for: libraryRoot, prefix: prefix)
    }

    func applySteamClientCompatibilityProfile(
        runtimeExecutable: URL,
        prefix: URL,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB
    ) async throws {
        let logDirectory = try pathManager.url(for: .launchLogs)
        if let failedFontSetup = try await windowsFontCompatibilityProfile.apply(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ) {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(failedFontSetup)
        }
        if let failedCompatibilitySetup = try await steamClientCompatibilityProfile.apply(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            videoMemorySizeMB: videoMemorySizeMB
        ) {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(failedCompatibilitySetup)
        }
    }

    func shutdownSteamPrefixBeforePolicyMutation(
        runtimeExecutable: URL,
        prefix: URL
    ) async throws {
        let logDirectory = try pathManager.url(for: .launchLogs)
        _ = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
    }

    func restoreSteamRendererBridgeModules(
        prefix: URL,
        runtimeExecutable: URL
    ) throws {
        try rendererPolicyManager.restoreBridgeModules(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable
        )
    }

    func requireSteamInstaller(_ url: URL) throws {
        guard url.lastPathComponent.lowercased() == "steamsetup.exe" else {
            throw SteamInstallError.invalidInstaller(url)
        }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SteamInstallError.installerMetadataReadFailed(url, message)
        } catch {
            throw SteamInstallError.invalidInstaller(url)
        }
    }

    private func requireSteamExecutable(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SteamLaunchError.steamExecutableMetadataReadFailed(url, message)
        } catch {
            throw SteamLaunchError.steamExecutableUnavailable(url)
        }
    }

    func possibleLibraryRoots() throws -> [URL] {
        let root = try pathManager.url(for: .defaultSteamLibrary)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        return libraryScanner.possibleLibraryRoots(defaultSteamLibrary: root, steamSharedPrefix: prefix)
    }

    func scanInstalledGames(extraLibraryRoots: [URL] = []) throws -> [SteamGame] {
        try scanInstalledGamesResult(extraLibraryRoots: extraLibraryRoots).games
    }

    func scanInstalledGamesResult(extraLibraryRoots: [URL] = []) throws -> SteamLibraryScanResult {
        let discoveries = steamLibraryRootDiscoveries(
            for: extraLibraryRoots
        )
        let roots = try possibleLibraryRoots() +
            verifiedSteamLibraryRoots(from: discoveries)
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        var result = try libraryScanner.scanInstalledGamesResult(
            roots: roots,
            prefixURL: prefixURL
        )
        for discovery in discoveries {
            result.skippedInputPaths.formUnion(discovery.skippedInputPaths)
        }
        return result
    }

    func scanInstalledGamesInBackground(extraLibraryRoots: [URL] = []) async throws -> [SteamGame] {
        try await scanInstalledGamesResultInBackground(extraLibraryRoots: extraLibraryRoots).games
    }

    func scanInstalledGamesResultInBackground(
        extraLibraryRoots: [URL] = []
    ) async throws -> SteamLibraryScanResult {
        let discoveries = steamLibraryRootDiscoveries(
            for: extraLibraryRoots
        )
        let roots = try possibleLibraryRoots() +
            verifiedSteamLibraryRoots(from: discoveries)
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        let scanner = libraryScanner
        var result = try await Task.detached(priority: .userInitiated) {
            try scanner.scanInstalledGamesResult(roots: roots, prefixURL: prefixURL)
        }.value
        for discovery in discoveries {
            result.skippedInputPaths.formUnion(discovery.skippedInputPaths)
        }
        return result
    }

    func linkedGamesFromUserSelection(_ selectedURL: URL) throws -> [SteamGame] {
        try scanInstalledGames(extraLibraryRoots: [selectedURL])
    }

    nonisolated static func libraryRootCandidate(from game: SteamGame) -> URL {
        SteamLibraryDriveMapper.libraryRootCandidate(from: game)
    }

    private func steamLibraryRootDiscoveries(
        for selectedRoots: [URL]
    ) -> [SteamLibraryRootDiscoveryResult] {
        selectedRoots.map {
            libraryScanner.discoverLibraryRoots(for: $0)
        }
    }

    private func verifiedSteamLibraryRoots(
        from discoveries: [SteamLibraryRootDiscoveryResult]
    ) throws -> [URL] {
        var seen = Set<String>()
        var verifiedRoots: [URL] = []
        for discovery in discoveries {
            for libraryRoot in try discovery.requireVerifiedLibraryRoots() {
                _ = try steamLibraryDriveRoot(
                    for: discovery,
                    libraryRoot: libraryRoot
                )
                let normalized = libraryRoot.standardizedFileURL
                let identity = normalized.resolvingSymlinksInPath()
                    .standardizedFileURL.path
                guard seen.insert(identity).inserted else { continue }
                verifiedRoots.append(normalized)
            }
        }
        return verifiedRoots.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func steamLibraryDriveSources(
        discoveries: [SteamLibraryRootDiscoveryResult]
    ) throws -> [SteamLibraryDriveSource] {
        var seen = Set<String>()
        var sources: [SteamLibraryDriveSource] = []
        for discovery in discoveries {
            for libraryRoot in try discovery.requireVerifiedLibraryRoots() {
                let normalizedLibraryRoot = libraryRoot.standardizedFileURL
                let normalizedAuthorizedRoot = try steamLibraryDriveRoot(
                    for: discovery,
                    libraryRoot: normalizedLibraryRoot
                )
                let identity = [
                    normalizedAuthorizedRoot.resolvingSymlinksInPath().path,
                    normalizedLibraryRoot.resolvingSymlinksInPath().path
                ].joined(separator: "|")
                guard seen.insert(identity).inserted else { continue }
                sources.append(SteamLibraryDriveSource(
                    authorizedRootURL: normalizedAuthorizedRoot,
                    libraryURL: normalizedLibraryRoot
                ))
            }
        }
        return sources
    }

    private func steamLibraryDriveRoot(
        for discovery: SteamLibraryRootDiscoveryResult,
        libraryRoot: URL
    ) throws -> URL {
        let selectedRoot = discovery.selectedRoot.standardizedFileURL
        let normalizedLibraryRoot = libraryRoot.standardizedFileURL
        let canonicalSelectedRoot = selectedRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalLibraryRoot = normalizedLibraryRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL

        if Self.isURL(
            canonicalLibraryRoot,
            containedBy: canonicalSelectedRoot
        ) {
            return selectedRoot
        }
        if Self.isURL(
            canonicalSelectedRoot,
            containedBy: canonicalLibraryRoot
        ) {
            guard !ForgePlaySandboxPolicy.isAppSandboxEnabled else {
                throw SteamLibraryRootDiscoveryError
                    .ancestorAuthorizationRequired(
                        selectedRoot: selectedRoot,
                        requiredRoot: normalizedLibraryRoot
                    )
            }
            return normalizedLibraryRoot
        }
        throw SteamLibraryRootDiscoveryError.noVerifiedSteamLibrary(
            selectedRoot,
            skippedPaths: [normalizedLibraryRoot.path]
        )
    }

    private nonisolated static func isURL(
        _ candidate: URL,
        containedBy root: URL
    ) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count &&
            Array(candidateComponents.prefix(rootComponents.count)) ==
                rootComponents
    }

    private func steamLibraryReservationRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.map(\.standardizedFileURL).filter { root in
            seen.insert(root.resolvingSymlinksInPath().standardizedFileURL.path).inserted
        }
    }

    private struct SteamConformanceSmokeResult: Hashable {
        var passed: Bool
        var details: [String]
    }

    private func steamLaunchPreflightAssessment(
        capability: WindowsRuntimeCapability,
        compatibility: SteamClientCompatibilityVerification,
        target: SteamLaunchTarget,
        processSnapshot: SteamLaunchProcessSnapshot,
        logDirectory: URL,
        verificationMode: SteamLaunchVerificationMode
    ) async -> SteamLaunchGateAssessment {
        var reasonCodes: [SteamLaunchGateReasonCode] = []
        var details: [String] = []

        func append(_ code: SteamLaunchGateReasonCode, _ detail: String) {
            reasonCodes.appendUnique(code)
            details.append(detail)
        }

        let runnerPath = target.normalizedRunnerPath
        let normalizedRunnerPath = runnerPath.lowercased()
        if normalizedRunnerPath.hasSuffix(".dmg") || normalizedRunnerPath.contains(".dmg/") {
            append(.blockedSupplementalDMGIsNotRuntime, "selected Apple supplemental renderer image is not the bundled runtime executable: \(runnerPath)")
        }
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(target.expectedRunnerPath, fileManager: fileManager),
              fileManager.isExecutableFile(atPath: runnerPath) else {
            append(.blockedRunnerMissing, "expected runner path is missing or not executable: \(runnerPath)")
            return SteamLaunchGateAssessment(status: .blocked, reasonCodes: reasonCodes, details: details)
        }

        if !FileSystemItemPolicy.isNonSymlinkDirectory(target.expectedPrefixPath, fileManager: fileManager) {
            append(.blockedRunnerPreflightFailed, "expected WINEPREFIX directory is missing or unsafe: \(target.normalizedPrefixPath)")
        }
        if !FileSystemItemPolicy.isRegularNonSymlinkFile(target.expectedSteamExecutablePath, fileManager: fileManager) {
            append(.blockedRunnerPreflightFailed, "expected Windows Steam executable is missing or unsafe: \(target.normalizedSteamExecutablePath)")
        }
        if capability.isUnsupportedExternalApplicationRunner || SteamLaunchProcessSnapshot.isExternalApplicationRunnerCommand(runnerPath) {
            append(.blockedExternalApplicationRunner, "configured executable belongs to another macOS application and cannot be used as a ForgePlay runtime: \(runnerPath)")
        }
        if !target.allowHostSteam, !processSnapshot.hostMacOSSteamProcesses.isEmpty {
            append(
                .blockedHostSteamRunning,
                "macOS Steam.app process is already running before Windows Steam validation: \(processSnapshot.hostMacOSSteamProcesses.prefix(3).map { "PID \($0.processID)" }.joined(separator: ", "))"
            )
        }
        if verificationMode == .conformance,
           !processSnapshot.externalApplicationRunnerProcesses.isEmpty {
            append(
                .blockedExternalApplicationRunner,
                "an external app-bundled Wine/Steam process is already running before ForgePlay target validation: \(processSnapshot.externalApplicationRunnerProcesses.prefix(3).map(\.diagnosticLine).joined(separator: " | "))"
            )
        }

        for blocker in compatibility.launchBlockers {
            switch blocker {
            case .unsupportedExternalApplicationRunner:
                append(.blockedExternalApplicationRunner, "another macOS application's embedded runner cannot be used as a ForgePlay product runtime")
            case .missingSteamTextRuntime:
                append(.blockedMissingWineFreetypeRuntime, "Wine-root FreeType runtime is missing; Windows Steam launch was not attempted")
            case .knownBadSteamUIConformance:
                append(.blockedRunnerPreflightFailed, "the bundled ForgePlay Runtime is classified as Windows Steam UI failed_known_bad")
            case .missingSteamNetworking:
                append(.blockedRunnerPreflightFailed, "the bundled ForgePlay Runtime lacks Steam networking runtime support")
            case .unsupportedSteamUIRenderer:
                append(.blockedRunnerPreflightFailed, "the bundled ForgePlay Runtime has an unsupported Windows Steam CEF/WebHelper renderer profile")
            case .activeD3DMetalOverlay:
                append(.blockedRunnerPreflightFailed, "the bundled ForgePlay Runtime globally overlays D3DMetal into base Wine modules and is unsafe for Steam UI validation")
            case .missingModernDirect3DRenderer:
                append(.blockedRunnerPreflightFailed, "the bundled ForgePlay Runtime lacks D3DMetal/Vulkan renderer payload needed for Steam-launched games")
            }
        }

        if verificationMode == .conformance {
            switch await prefixHolderProcessIDs(under: target.expectedPrefixPath) {
            case .success(let pids):
                if !pids.isEmpty {
                    append(.blockedPrefixHeldByStaleProcess, "expected WINEPREFIX is held by existing process(es): \(pids.map(String.init).joined(separator: ", "))")
                }
            case .failure(let error):
                append(.blockedRunnerPreflightFailed, "could not verify stale prefix holders before Steam launch: \(forgePlayTechnicalErrorSummary(error))")
            }
        }

        if verificationMode == .conformance, reasonCodes.isEmpty {
            let smoke = await runFreshConformanceSmokeTest(
                runner: target.expectedRunnerPath,
                logDirectory: logDirectory
            )
            details.append(contentsOf: smoke.details)
            if !smoke.passed {
                reasonCodes.appendUnique(.blockedRunnerPreflightFailed)
            }
        }

        if reasonCodes.isEmpty {
            return SteamLaunchGateAssessment(status: .success, reasonCodes: [], details: details)
        }
        return SteamLaunchGateAssessment(status: .blocked, reasonCodes: reasonCodes, details: details)
    }

    private func blockedSteamLaunchResult(
        logDirectory: URL,
        launchTarget: SteamLaunchTarget,
        capability: WindowsRuntimeCapability,
        assessment: SteamLaunchGateAssessment,
        steamDirectory: URL,
        dumpsBefore: [URL],
        processSnapshot: SteamLaunchProcessSnapshot,
        crashDumpObservationContext: SteamCrashDumpObservationContext
    ) throws -> ProcessRunResult {
        var result = try syntheticSteamLaunchResult(
            actionName: "launchSteam",
            executable: launchTarget.expectedRunnerPath,
            arguments: [],
            logDirectory: logDirectory,
            forgePlayStatusCode: Self.steamLaunchBlockedExitCode,
            stdoutLines: [
                "ForgePlay Windows Steam launch was blocked before process start."
            ],
            stderrLines: [
                "STATUS: BLOCKED",
                "TARGET_RUNNER: \(launchTarget.normalizedRunnerPath)",
                "TARGET_PREFIX: \(launchTarget.normalizedPrefixPath)",
                "TARGET_STEAM_EXE: \(launchTarget.normalizedSteamExecutablePath)",
                "REASON_CODES: \(assessment.reasonCodes.map(\.rawValue).joined(separator: ", "))",
                assessment.diagnosticReasons.joined(separator: "\n")
            ].filter { !$0.isEmpty }
        )
        let diagnosticCapture = Result {
            try steamLaunchDiagnosticsReporter.writeDiagnostics(
                for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            hostSteamProcesses: [],
            hostSteamProcessesBefore: processSnapshot.hostMacOSSteamProcesses,
            hostSteamProcessesAfter: processSnapshot.hostMacOSSteamProcesses,
            externalApplicationRunnerProcesses: [],
            externalApplicationRunnerProcessesBefore: processSnapshot.externalApplicationRunnerProcesses,
            externalApplicationRunnerProcessesAfter: processSnapshot.externalApplicationRunnerProcesses,
            processSnapshotBefore: processSnapshot.processes,
            processSnapshotAfter: processSnapshot.processes,
            launchTarget: launchTarget,
            runnerCapability: capability,
            runnerVersionEvidence: "not captured; Windows Steam launch was BLOCKED before runner version probing\n",
            dumpsBefore: dumpsBefore,
            gateStatus: .blocked,
            reasonCodes: assessment.reasonCodes,
            hardGateFailureReasons: assessment.diagnosticReasons,
            webHelperCommandLines: [],
            screenEvidence: .notCaptured("Windows Steam launch preflight returned BLOCKED; screenshot capture was not attempted"),
            launchEnvironmentSummary: steamLaunchBlockedEnvironmentSummary(
                capability: capability,
                assessment: assessment
            ),
                crashDumpObservationContext: crashDumpObservationContext,
                since: result.startedAt
            )
        }
        _ = applyDiagnosticsCapture(diagnosticCapture, to: &result)
        return result
    }

    @discardableResult
    private func applyDiagnosticsCapture(
        _ capture: Result<URL, Error>,
        to result: inout ProcessRunResult
    ) -> Bool {
        switch capture {
        case .success(let url):
            result.diagnosticLog = url
            guard let assessment = steamLaunchDiagnosticsReporter.evidenceAssessment(for: url) else {
                result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    result.diagnosticCaptureWarning,
                    "Steam diagnostics were written without a verifiable evidence-completeness assessment; hard-gate success is forbidden."
                )
                return false
            }
            guard assessment.isCompleteEnoughForHardGateSuccess else {
                result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    result.diagnosticCaptureWarning,
                    assessment.diagnosticCaptureWarning ??
                        "Steam diagnostic evidence is incomplete; hard-gate success is forbidden."
                )
                return false
            }
            return true
        case .failure(let error):
            let summary = forgePlayTechnicalErrorSummary(error)
            result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                result.diagnosticCaptureWarning,
                "Full Steam diagnostics capture failed: \(summary)"
            )
            do {
                result.diagnosticLog = try steamLaunchDiagnosticsReporter.writeDiagnosticsFailureFallback(
                    for: result,
                    error: error
                )
            } catch let fallbackError {
                result.diagnosticLog = nil
                result.diagnosticCaptureWarning = [
                    result.diagnosticCaptureWarning,
                    "Minimal diagnostics fallback also failed: \(forgePlayTechnicalErrorSummary(fallbackError))"
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            return false
        }
    }

    private func applyProcessObservationReadWarning(
        _ snapshot: SteamLaunchProcessSnapshot,
        to result: inout ProcessRunResult
    ) {
        guard let observationWarning = snapshot.processObservationDiagnosticWarning else { return }
        let existingWarning = result.diagnosticCaptureWarning
        guard existingWarning?.contains(observationWarning) != true else { return }
        result.diagnosticCaptureWarning = [existingWarning, observationWarning]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func applyBootstrapLogEvidenceWarnings(
        _ assessments: [SteamBootstrapUpdateLogAssessment],
        to result: inout ProcessRunResult
    ) {
        var seen = Set<String>()
        let failures = assessments
            .filter(\.evidenceUnavailable)
            .compactMap { assessment -> String? in
                let message = "bootstrap evidence=\(assessment.state.rawValue) (\(assessment.detail))"
                return seen.insert(message).inserted ? message : nil
            }
        guard !failures.isEmpty else { return }
        let warning = "Steam bootstrap/update log evidence was unavailable; ForgePlay did not infer updater completion from missing evidence. \(failures.joined(separator: "; "))"
        guard result.diagnosticCaptureWarning?.contains(warning) != true else { return }
        result.diagnosticCaptureWarning = [result.diagnosticCaptureWarning, warning]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func steamLaunchBlockedEnvironmentSummary(
        capability: WindowsRuntimeCapability,
        assessment: SteamLaunchGateAssessment
    ) -> [String] {
        [
            "- Windows Steam launch did not start because preflight returned \(assessment.status.rawValue).",
            "- Reason codes: \(assessment.reasonCodes.map(\.rawValue).joined(separator: ", "))",
            "- Runner capability executable: \(capability.executableURL.path)",
            "- Runner limitations: \(capability.limitations.isEmpty ? "none" : capability.limitations.joined(separator: ", "))"
        ]
    }

    private func steamBootstrapUpdateIsInProgress(
        result: ProcessRunResult,
        launchTarget: SteamLaunchTarget,
        processSnapshot: SteamLaunchProcessSnapshot,
        renderingIssue: SteamWebHelperRenderingIssue?,
        fatalCrashDumps: [URL],
        hasBootstrapUpdateProgress: Bool
    ) -> Bool {
        guard result.succeeded, !result.waitedForExit else { return false }
        guard renderingIssue == nil, fatalCrashDumps.isEmpty else { return false }
        guard processSnapshot.webHelperCommandLines(for: launchTarget).isEmpty else { return false }
        return hasBootstrapUpdateProgress
    }

    private func steamBootstrapUpdateDeferredAssessment(
        from originalAssessment: SteamLaunchGateAssessment
    ) -> SteamLaunchGateAssessment {
        var details = [
            "Steam bootstrap update is still in progress; ForgePlay left Windows Steam running and deferred UI verification instead of treating missing steamwebhelper.exe as fatal."
        ]
        if !originalAssessment.reasonCodes.isEmpty {
            details.append(
                "Original hard gate evidence while update was in progress: \(originalAssessment.reasonCodes.map(\.rawValue).joined(separator: ", "))"
            )
        }
        details.append(contentsOf: originalAssessment.details)
        return SteamLaunchGateAssessment(
            status: .deferred,
            reasonCodes: [.steamBootstrapUpdateInProgress],
            details: details
        )
    }

    func steamBootstrapUpdateLogHasProgress(
        result: ProcessRunResult,
        steamDirectory: URL
    ) -> Bool {
        steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory
        ).hasProgress == true
    }

    func steamBootstrapUpdateLogAssessment(
        result: ProcessRunResult,
        steamDirectory: URL
    ) -> SteamBootstrapUpdateLogAssessment {
        let bootstrapLog = steamDirectory.appending(path: "logs/bootstrap_log.txt")
        let cutoff = result.startedAt.addingTimeInterval(-2)
        var sources = [
            secureTrailingText(
                from: result.stdoutLog,
                maxBytes: 128_000,
                modifiedAfter: cutoff,
                anchoredAt: result.stdoutLog.deletingLastPathComponent(),
                required: true
            ),
            secureTrailingText(
                from: bootstrapLog,
                maxBytes: 128_000,
                modifiedAfter: cutoff,
                anchoredAt: steamDirectory,
                required: false
            )
        ]
        if !sources[1].text.isEmpty {
            sources[1].text = steamLogText(sources[1].text, since: cutoff)
        }
        let text = sources
            .filter { !$0.evidenceUnavailable }
            .map(\.text)
            .joined(separator: "\n")
            .lowercased()

        let updateSignals = [
            "업데이트 다운로드 중",
            "downloading update",
            "download update",
            "updating steam",
            "extracting package",
            "installing update",
            "verifying installation"
        ]
        let completionSignals = [
            "steam client startup complete",
            "steamui startup complete",
            "steamwebhelper.exe",
            "ready for user input",
            "verification complete",
            "nothing to do",
            "download skipped"
        ]
        let containsUpdateSignal = updateSignals.contains { text.contains($0) }
        let containsCompletionSignal = completionSignals.contains { text.contains($0) }
        let hasProgress: Bool?
        if containsUpdateSignal, !containsCompletionSignal {
            hasProgress = true
        } else if containsCompletionSignal {
            hasProgress = false
        } else if sources.contains(where: \.evidenceUnavailable) {
            hasProgress = nil
        } else {
            hasProgress = false
        }

        let state: SteamEvidenceReadState
        if sources.contains(where: { $0.state == .unsafe }) {
            state = .unsafe
        } else if sources.contains(where: { $0.state == .changedDuringRead }) {
            state = .changedDuringRead
        } else if sources.contains(where: { $0.state == .unreadable }) {
            state = .unreadable
        } else if sources.contains(where: { $0.state == .missing && $0.required }) {
            state = .missing
        } else if sources.contains(where: { $0.state == .truncated }) {
            state = .truncated
        } else if sources.contains(where: { $0.state == .captured }) {
            state = .captured
        } else {
            state = .missing
        }
        let detail = sources.map {
            "\($0.url.lastPathComponent)=\($0.state.rawValue) (\($0.detail))"
        }.joined(separator: "; ")
        return SteamBootstrapUpdateLogAssessment(
            hasProgress: hasProgress,
            state: state,
            detail: detail,
            sources: sources
        )
    }

    private func steamLogText(_ text: String, since cutoff: Date) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        let currentTimestampedLines = lines.filter { line in
            guard line.first == "[",
                  let end = line.firstIndex(of: "]") else {
                return false
            }
            let timestamp = String(line[line.index(after: line.startIndex)..<end])
            guard let loggedAt = Self.steamLogTimestampFormatter.date(from: timestamp) else {
                return false
            }
            return loggedAt >= cutoff
        }
        guard !currentTimestampedLines.isEmpty else {
            return text
        }
        return currentTimestampedLines.joined(separator: "\n")
    }

    private func waitForSteamClientMutationAfterLaunch(
        result: ProcessRunResult,
        prefix: URL,
        steamDirectory: URL,
        videoMemorySizeMB: Int
    ) async -> Bool {
        let timeout = min(bootstrapCompletionTimeout, 3)
        guard timeout > 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            let bootstrapAssessment = steamBootstrapUpdateLogAssessment(
                result: result,
                steamDirectory: steamDirectory
            )
            if bootstrapAssessment.hasProgress == true {
                return true
            }
            let profile = SteamClientCompatibilityProfileContract.inspect(
                prefix: prefix,
                fileManager: fileManager,
                videoMemorySizeMB: videoMemorySizeMB
            )
            if !profile.isSatisfied {
                return true
            }
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    private func waitForSteamClientBootstrapCompletion(
        result: ProcessRunResult,
        prefix: URL,
        steamDirectory: URL,
        launchTarget: SteamLaunchTarget,
        requiresUpdaterCompletion: Bool
    ) async -> Bool {
        guard bootstrapCompletionTimeout > 0 else { return false }

        let deadline = Date().addingTimeInterval(bootstrapCompletionTimeout)
        var previousPayloadSignature: String?
        var stablePayloadObservationCount = 0
        while !Task.isCancelled {
            let payloadSignature = steamClientBootstrapPayloadSignature(in: prefix)
            if let payloadSignature {
                if payloadSignature == previousPayloadSignature {
                    stablePayloadObservationCount += 1
                } else {
                    stablePayloadObservationCount = 1
                }
            } else {
                stablePayloadObservationCount = 0
            }
            previousPayloadSignature = payloadSignature

            if stablePayloadObservationCount >= 2 {
                let snapshot = processSnapshotProvider()
                let webHelperStarted = !snapshot.webHelperCommandLines(for: launchTarget).isEmpty
                let updaterAssessment = steamBootstrapUpdateLogAssessment(
                    result: result,
                    steamDirectory: steamDirectory
                )
                let updaterCompletionConfirmed = updaterAssessment.hasProgress == false
                if requiresUpdaterCompletion
                    ? updaterCompletionConfirmed
                    : (webHelperStarted || updaterCompletionConfirmed) {
                    return true
                }
            }

            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(for: .seconds(bootstrapCompletionPollInterval))
            } catch {
                return false
            }
        }
        return false
    }

    private func observeSteamUIStartup(
        result: ProcessRunResult,
        prefix: URL,
        steamDirectory: URL,
        launchTarget: SteamLaunchTarget,
        logCursor: SteamWebHelperStartupLogCursor
    ) async -> SteamWebHelperStartupObservation {
        guard result.succeeded,
              !result.waitedForExit,
              steamUIStartupObservationTimeout > 0 else {
            return SteamWebHelperStartupObservation(
                state: .timedOut,
                reason: nil,
                steamUIHTMLTail: [],
                consoleTail: [],
                webHelperTail: []
            )
        }

        if steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory
        ).hasProgress == true {
            _ = await waitForSteamClientBootstrapCompletion(
                result: result,
                prefix: prefix,
                steamDirectory: steamDirectory,
                launchTarget: launchTarget,
                requiresUpdaterCompletion: false
            )
        }

        return await steamLaunchDiagnosticsReporter.waitForSteamWebHelperStartup(
            in: steamDirectory,
            since: logCursor,
            timeout: steamUIStartupObservationTimeout,
            pollInterval: steamUIStartupObservationPollInterval
        )
    }

    private func steamClientBootstrapPayloadSignature(in prefix: URL) -> String? {
        for cefDirectory in SteamClientCompatibilityProfileContract.steamWebHelperCandidateDirectories(in: prefix) {
            let requiredFiles = [
                SteamClientCompatibilityProfileContract.steamWebHelperFile(in: cefDirectory),
                cefDirectory.appending(path: "libcef.dll")
            ]
            var components: [String] = []
            for file in requiredFiles {
                guard FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager),
                      let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                      let size = attributes[.size] as? NSNumber,
                      size.int64Value > 0,
                      let modificationDate = attributes[.modificationDate] as? Date else {
                    components.removeAll()
                    break
                }
                components.append("\(file.lastPathComponent):\(size.int64Value):\(modificationDate.timeIntervalSince1970)")
            }
            if components.count == requiredFiles.count {
                return "\(cefDirectory.path)|\(components.joined(separator: "|"))"
            }
        }
        return nil
    }

    private func secureTrailingText(
        from url: URL,
        maxBytes: Int,
        modifiedAfter cutoff: Date,
        anchoredAt root: URL,
        required: Bool
    ) -> SteamBootstrapLogSourceAssessment {
        let boundedMaxBytes = max(maxBytes, 0)
        guard boundedMaxBytes > 0 else {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .captured,
                detail: "zero-byte read requested",
                text: ""
            )
        }
        let openResult = openBootstrapEvidenceFile(at: url, anchoredAt: root)
        let descriptor: Int32
        let initialMetadata: BootstrapEvidenceFileMetadata
        switch openResult {
        case .failed(let state, let detail):
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: state,
                detail: detail,
                text: ""
            )
        case .opened(let openedDescriptor, let metadata):
            descriptor = openedDescriptor
            initialMetadata = metadata
        }
        defer { Darwin.close(descriptor) }

        guard initialMetadata.modificationDate >= cutoff else {
            guard bootstrapEvidenceMetadata(descriptor: descriptor) == initialMetadata else {
                return SteamBootstrapLogSourceAssessment(
                    url: url,
                    required: required,
                    state: .changedDuringRead,
                    detail: "file changed while its modification time was compared with the launch cutoff",
                    text: ""
                )
            }
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .captured,
                detail: "file predates the launch cutoff",
                text: ""
            )
        }

        let readByteCount = min(initialMetadata.byteCount, UInt64(boundedMaxBytes))
        let readOffset = initialMetadata.byteCount - readByteCount
        let data: Data
        do {
            data = try readBootstrapEvidenceBytes(
                descriptor: descriptor,
                offset: readOffset,
                count: Int(readByteCount)
            )
        } catch {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .unreadable,
                detail: "bounded secure read failed: \(forgePlayTechnicalErrorSummary(error))",
                text: ""
            )
        }
        var text = String(decoding: data, as: UTF8.self)
        if readOffset > 0,
           let firstNewline = text.firstIndex(where: { $0.isNewline }) {
            text = String(text[text.index(after: firstNewline)...])
        }
        guard data.count == Int(readByteCount),
              bootstrapEvidenceMetadata(descriptor: descriptor) == initialMetadata else {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .changedDuringRead,
                detail: "file size, identity, or modification time changed during the bounded read",
                text: text
            )
        }

        let verificationOpen = openBootstrapEvidenceFile(at: url, anchoredAt: root)
        switch verificationOpen {
        case .failed(let state, let detail):
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: state == .unsafe ? .unsafe : .changedDuringRead,
                detail: "source path changed after the bounded read: \(detail)",
                text: text
            )
        case .opened(let verificationDescriptor, let finalPathMetadata):
            Darwin.close(verificationDescriptor)
            guard finalPathMetadata == initialMetadata else {
                return SteamBootstrapLogSourceAssessment(
                    url: url,
                    required: required,
                    state: .changedDuringRead,
                    detail: "source path identity changed during the bounded read",
                    text: text
                )
            }
        }

        if initialMetadata.byteCount > UInt64(boundedMaxBytes) {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .truncated,
                detail: "tail was bounded to the last \(boundedMaxBytes) bytes",
                text: text
            )
        }
        return SteamBootstrapLogSourceAssessment(
            url: url,
            required: required,
            state: .captured,
            detail: "secure bounded tail captured",
            text: text
        )
    }

    private func openBootstrapEvidenceFile(
        at url: URL,
        anchoredAt root: URL
    ) -> BootstrapEvidenceOpenResult {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let isBelowRoot = standardizedRoot.path == "/"
            ? standardizedURL.path != "/"
            : standardizedURL.path.hasPrefix("\(standardizedRoot.path)/")
        guard isBelowRoot else {
            return .failed(
                state: .unsafe,
                detail: "source is outside its allowed evidence root: \(standardizedURL.path)"
            )
        }

        var descriptor = Darwin.open(
            standardizedRoot.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            let code = errno
            return .failed(
                state: bootstrapEvidenceFailureState(for: code),
                detail: "secure root open failed for \(standardizedRoot.path): \(bootstrapPOSIXFailureDescription(code))"
            )
        }

        let rootComponents = standardizedRoot.pathComponents
        let targetComponents = standardizedURL.pathComponents
        let relativeComponents = targetComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.isEmpty else {
            Darwin.close(descriptor)
            return .failed(state: .unsafe, detail: "evidence source resolves to its directory root")
        }
        for (index, component) in relativeComponents.enumerated() {
            let isLeaf = index == relativeComponents.count - 1
            let flags = isLeaf
                ? O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                : O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            let nextDescriptor = component.withCString {
                Darwin.openat(descriptor, $0, flags)
            }
            let code = errno
            Darwin.close(descriptor)
            guard nextDescriptor >= 0 else {
                return .failed(
                    state: bootstrapEvidenceFailureState(for: code),
                    detail: "secure component open failed for \(standardizedURL.path): \(bootstrapPOSIXFailureDescription(code))"
                )
            }
            descriptor = nextDescriptor
        }

        guard let metadata = bootstrapEvidenceMetadata(descriptor: descriptor) else {
            Darwin.close(descriptor)
            return .failed(
                state: .unsafe,
                detail: "securely opened source is not a single-link regular file: \(standardizedURL.path)"
            )
        }
        return .opened(descriptor: descriptor, metadata: metadata)
    }

    private func bootstrapEvidenceMetadata(
        descriptor: Int32
    ) -> BootstrapEvidenceFileMetadata? {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0 else {
            return nil
        }
        return BootstrapEvidenceFileMetadata(
            deviceNumber: UInt64(bitPattern: Int64(status.st_dev)),
            fileNumber: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private func readBootstrapEvidenceBytes(
        descriptor: Int32,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count >= 0, offset <= UInt64(Int64.max) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard count > 0 else { return Data() }
        var output = Data()
        output.reserveCapacity(count)
        var currentOffset = Int64(offset)
        while output.count < count {
            let requested = min(64 * 1024, count - output.count)
            var buffer = [UInt8](repeating: 0, count: requested)
            let readCount = Darwin.pread(descriptor, &buffer, requested, off_t(currentOffset))
            if readCount < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if readCount == 0 { break }
            output.append(buffer, count: readCount)
            currentOffset += Int64(readCount)
        }
        return output
    }

    private func bootstrapEvidenceFailureState(for code: Int32) -> SteamEvidenceReadState {
        switch code {
        case ENOENT:
            .missing
        case ELOOP, ENOTDIR:
            .unsafe
        default:
            .unreadable
        }
    }

    private func bootstrapPOSIXFailureDescription(_ code: Int32) -> String {
        "errno=\(code) \(String(cString: Darwin.strerror(code)))"
    }

    private func waitForSteamLaunchProcessEvidence(
        for target: SteamLaunchTarget,
        initialSnapshot: SteamLaunchProcessSnapshot,
        result: ProcessRunResult,
        verificationMode: SteamLaunchVerificationMode
    ) async -> SteamLaunchProcessSnapshot {
        var snapshot = initialSnapshot
        let deadline = Date().addingTimeInterval(processEvidenceTimeout)
        while !Task.isCancelled && Date() < deadline {
            let containsExpectedPrefixSteam = snapshot.containsExpectedPrefixSteamProcess(for: target)
            let hasRequiredEvidence = verificationMode == .operational
                ? containsExpectedPrefixSteam
                : snapshot.containsExpectedRunnerProcess(for: target) &&
                    containsExpectedPrefixSteam &&
                    snapshot.webHelperCommandLinesContainRequiredLaunchPolicy(for: target)
            if hasRequiredEvidence {
                return snapshot
            }
            do {
                try await Task.sleep(for: .seconds(processEvidencePollInterval))
            } catch {
                break
            }
            snapshot = currentSteamLaunchProcessSnapshot(for: result, target: target)
        }
        return snapshot
    }

    private func currentSteamLaunchProcessSnapshot(
        for result: ProcessRunResult,
        target: SteamLaunchTarget
    ) -> SteamLaunchProcessSnapshot {
        let currentSnapshot = processSnapshotProvider()
        let sameRunEvidence = SteamLaunchProcessSnapshot.sameRunLaunchEvidence(
                for: result,
                target: target,
                fileManager: fileManager
            )
            .reconcilingProcessCreationEvidence(with: currentSnapshot)
        return currentSnapshot.merging(sameRunEvidence)
    }

    private func steamLaunchHardGateAssessment(
        target: SteamLaunchTarget,
        after: SteamLaunchProcessSnapshot,
        hostSteamProcessesBeforeLaunch: [MacOSSteamProcess],
        hostSteamProcessesAfterLaunch: [MacOSSteamProcess],
        newlyLaunchedHostSteamProcesses: [MacOSSteamProcess],
        externalRunnerProcessesBeforeLaunch: [SteamLaunchObservedProcess],
        externalRunnerProcessesAfterLaunch: [SteamLaunchObservedProcess],
        launchCommandSucceeded: Bool,
        crashDumps: [URL],
        assertDumps: [URL],
        renderingIssue: SteamWebHelperRenderingIssue?,
        runnerVersionEvidence: String,
        screenEvidence: SteamLaunchScreenEvidence,
        verificationMode: SteamLaunchVerificationMode,
        steamUIStartupFailure: String?
    ) -> SteamLaunchGateAssessment {
        var reasonCodes: [SteamLaunchGateReasonCode] = []
        var details: [String] = []
        var hasFailureDetail = false

        func append(_ code: SteamLaunchGateReasonCode, _ detail: String) {
            reasonCodes.appendUnique(code)
            details.append(detail)
        }

        func appendFailureDetail(_ detail: String) {
            hasFailureDetail = true
            details.append(detail)
        }

        if let observationWarning = after.processObservationDiagnosticWarning {
            details.append(observationWarning)
        }
        if !launchCommandSucceeded {
            append(.failedLaunchCommand, "launch command did not succeed")
        }
        if !crashDumps.isEmpty {
            if verificationMode == .conformance {
                append(.failedSteamCrashDumpCreated, "Steam crash dump was created during this run")
                if crashDumps.contains(where: steamLaunchDiagnosticsReporter.crashDumpIndicatesAccessViolation) {
                    append(.failedSteamAccessViolation, "Steam crash dump reports 0xC0000005 access violation")
                }
            } else {
                details.append("operational launch observed a new Steam crash dump; it was recorded without terminating the user's Steam session")
            }
        }
        if !assertDumps.isEmpty {
            details.append("Steam assert dump(s) were created during this run and recorded as a stability warning: \(assertDumps.prefix(3).map(\.path).joined(separator: " | "))")
        }
        if renderingIssue != nil {
            if verificationMode == .conformance {
                appendFailureDetail("Steam WebHelper rendering failure signature was detected")
            } else {
                details.append("operational launch observed a Steam WebHelper warning signature; it was recorded without terminating the user's Steam session")
            }
        }
        if let steamUIStartupFailure {
            append(
                .failedSteamUIStartup,
                "Steam UI startup failed again after one automatic prefix restart: \(steamUIStartupFailure)"
            )
        }
        if !runnerVersionEvidence.hasCapturedWineVersionEvidence {
            if verificationMode == .conformance {
                appendFailureDetail("wine --version evidence for the expected runner is missing")
            } else {
                details.append("operational launch did not capture wine --version evidence")
            }
        }
        if verificationMode == .conformance {
            if !target.allowHostSteam && (!hostSteamProcessesBeforeLaunch.isEmpty || !hostSteamProcessesAfterLaunch.isEmpty) {
                append(.failedHostSteamContamination, "macOS Steam.app process was present in the launch window")
            }
            if !newlyLaunchedHostSteamProcesses.isEmpty {
                append(.failedHostSteamContamination, "new macOS Steam.app process appeared during the launch window")
            }
            if !externalRunnerProcessesBeforeLaunch.isEmpty || !externalRunnerProcessesAfterLaunch.isEmpty {
                append(.failedExternalRunnerContamination, "an external app-bundled Wine/Steam process was present in the launch window")
            }
            let outsideTargetProcesses = after.steamOrWineProcessesOutsideTarget(for: target)
            if !outsideTargetProcesses.isEmpty {
                appendFailureDetail("Steam/Wine process outside the expected runner or WINEPREFIX was present: \(outsideTargetProcesses.prefix(3).map(\.diagnosticLine).joined(separator: " | "))")
            }
        }
        if verificationMode == .conformance {
            if !after.containsExpectedRunnerProcess(for: target) {
                appendFailureDetail("expected runner path was not observed in same-run launch evidence")
            }
            if !after.containsExpectedPrefixSteamProcess(for: target) {
                append(.failedExpectedPrefixNotObserved, "expected WINEPREFIX was not observed with steam.exe or steamwebhelper.exe in same-run launch evidence")
            }
            if after.webHelperCommandLines(for: target).isEmpty {
                append(.failedWebHelperCommandLineMissing, "Steam WebHelper command line evidence for the expected prefix is missing")
            } else if !after.webHelperCommandLinesContainRequiredLaunchPolicy(for: target) {
                append(
                    .failedWebHelperLaunchPolicyMissing,
                    "Steam WebHelper same-run command line is missing: \(SteamWebHelperLaunchPolicy.requiredArguments.joined(separator: ", "))"
                )
            }
            if !screenEvidence.verifiesWindowsSteamUI {
                append(.failedVisibleUINotVerified, "screen-final.png visual evidence did not verify Windows Steam login, Steam Guard, or Library UI: \(screenEvidence.message)")
            }
        } else {
            if !after.containsExpectedRunnerProcess(for: target) {
                details.append("operational same-run launch evidence did not observe the runner")
            }
            if !after.containsExpectedPrefixSteamProcess(for: target) {
                append(
                    .operationalProcessEvidenceUnavailable,
                    "operational launch did not observe steam.exe or steamwebhelper.exe in the expected WINEPREFIX before the bounded process-evidence deadline"
                )
            }
            if after.webHelperCommandLines(for: target).isEmpty {
                details.append("operational same-run launch evidence did not capture Steam WebHelper; UI verification remains pending")
            } else if !after.webHelperCommandLinesContainRequiredLaunchPolicy(for: target) {
                details.append("operational Steam WebHelper evidence is missing the required ForgePlay launch policy arguments; UI verification remains pending")
            }
        }
        if reasonCodes.isEmpty, !hasFailureDetail {
            let status: SteamLaunchGateStatus = verificationMode == .conformance ? .success : .launched
            return SteamLaunchGateAssessment(status: status, reasonCodes: [], details: details)
        }
        if verificationMode == .operational,
           reasonCodes == [.operationalProcessEvidenceUnavailable],
           !hasFailureDetail {
            return SteamLaunchGateAssessment(status: .deferred, reasonCodes: reasonCodes, details: details)
        }
        return SteamLaunchGateAssessment(status: .failed, reasonCodes: reasonCodes, details: details)
    }

    private func prefixHolderProcessIDs(under prefix: URL) async -> Result<[pid_t], Error> {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(prefix, fileManager: fileManager) else {
            return .success([])
        }
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard fileManager.isExecutableFile(atPath: lsof.path) else {
            return .failure(SafeProcessRunnerError.executableMissing(lsof))
        }
        let capture: BoundedProcessCaptureResult
        do {
            capture = try await Task.detached(priority: .utility) {
                try BoundedProcessExecutor.capture(
                    executable: lsof,
                    arguments: ["-t", "+D", prefix.path],
                    timeout: 10
                )
            }.value
        } catch {
            return .failure(error)
        }
        guard capture.didExit else {
            return .failure(SafeProcessRunnerError.prefixProcessVerificationFailed(
                prefix,
                "lsof did not exit before the prefix inspection deadline"
            ))
        }
        let output = capture.stdout
        let errorOutput = capture.stderr
        let currentPID = Darwin.getpid()
        let pids = String(data: output, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 && $0 != currentPID } ?? []
        if !pids.isEmpty {
            return .success(pids)
        }
        if capture.exitCode == 1, output.isEmpty, errorOutput.isEmpty {
            return .success([])
        }
        if capture.exitCode != 0 {
            let message = String(data: errorOutput, encoding: .utf8) ??
                String(data: output, encoding: .utf8) ??
                "lsof exited with \(capture.exitCode)"
            return .failure(SafeProcessRunnerError.prefixProcessVerificationFailed(prefix, message))
        }
        return .success([])
    }

    private func runFreshConformanceSmokeTest(
        runner: URL,
        logDirectory: URL
    ) async -> SteamConformanceSmokeResult {
        let conformanceRoot = logDirectory
            .deletingLastPathComponent()
            .appending(path: "SteamConformance/\(Self.logTimestampFormatter.string(from: Date()))_\(UUID().uuidString)", directoryHint: .isDirectory)
        let conformancePrefix = conformanceRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let stdoutURL = conformanceRoot.appending(path: "cmd_ver_stdout.log")
        let stderrURL = conformanceRoot.appending(path: "cmd_ver_stderr.log")
        let commandArguments = runnerInvocationArguments(
            for: runner,
            prefix: conformancePrefix,
            command: ["cmd", "/c", "ver"]
        )
        do {
            try fileManager.createDirectory(at: conformanceRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: conformancePrefix, withIntermediateDirectories: true)
        } catch {
            try? fileManager.removeItem(at: conformanceRoot)
            return SteamConformanceSmokeResult(
                passed: false,
                details: ["fresh conformance prefix could not be created: \(forgePlayTechnicalErrorSummary(error))"]
            )
        }
        let processEnvironment: [String: String]
        do {
            let runnerEnvironment = try SafeProcessRunner.runnerEnvironment(
                for: runner,
                base: [
                    "WINEPREFIX": conformancePrefix.path,
                    "WINEARCH": WinePrefixDefaults.architecture
                ],
                injectGraphicsDLLOverrides: false
            )
            processEnvironment = SafeProcessRunner.processEnvironment(overrides: runnerEnvironment)
        } catch {
            try? fileManager.removeItem(at: conformanceRoot)
            return SteamConformanceSmokeResult(
                passed: false,
                details: ["fresh conformance runner environment could not be built: \(forgePlayTechnicalErrorSummary(error))"]
            )
        }

        let startedAt = Date()
        var capture: BoundedProcessCaptureResult?
        var details = [
            "fresh conformance prefix: \(conformancePrefix.path)",
            "fresh conformance mode: temporary WINEPREFIX",
            "fresh conformance command: \(runner.path) \(commandArguments.joined(separator: " "))",
            "fresh conformance stdout: \(stdoutURL.path)",
            "fresh conformance stderr: \(stderrURL.path)"
        ]
        do {
            capture = try await Task.detached(priority: .userInitiated) {
                try BoundedProcessExecutor.capture(
                    executable: runner,
                    arguments: commandArguments,
                    environment: processEnvironment,
                    workingDirectory: conformancePrefix,
                    timeout: 20
                )
            }.value
        } catch {
            details.append("fresh conformance cmd /c ver could not start: \(forgePlayTechnicalErrorSummary(error))")
        }
        let endedAt = Date()
        var evidencePersisted = true
        if let capture {
            do {
                try String(decoding: capture.stdout, as: UTF8.self)
                    .write(to: stdoutURL, atomically: true, encoding: .utf8)
                try String(decoding: capture.stderr, as: UTF8.self)
                    .write(to: stderrURL, atomically: true, encoding: .utf8)
            } catch {
                evidencePersisted = false
                details.append("fresh conformance output evidence could not be persisted: \(forgePlayTechnicalErrorSummary(error))")
            }
            details.append("fresh conformance exitCode: \(capture.exitCode)")
            details.append("fresh conformance timedOut: \(capture.didTimeOut)")
        }

        let cleanup = await prefixProcessSupervisor.shutdownAfterFailure(
            runtimeExecutable: runner,
            prefix: conformancePrefix,
            logDirectory: conformanceRoot
        )
        let cleanupSucceeded = cleanup.error == nil && cleanup.result?.succeeded == true
        if let cleanupError = cleanup.error {
            details.append("fresh conformance prefix cleanup failed: \(forgePlayTechnicalErrorSummary(cleanupError))")
        } else if let cleanupResult = cleanup.result, !cleanupResult.succeeded {
            details.append(
                "fresh conformance prefix cleanup process exit \(cleanupResult.diagnosticExitCodeDescription), " +
                    "ForgePlay status \(cleanupResult.diagnosticForgePlayStatusDescription): \(cleanupResult.stderrLog.path)"
            )
        }

        var prefixRemoved = false
        if cleanupSucceeded {
            do {
                try fileManager.removeItem(at: conformancePrefix)
                prefixRemoved = true
            } catch {
                details.append("fresh conformance prefix could not be removed after wineserver shutdown: \(forgePlayTechnicalErrorSummary(error))")
            }
        }

        let commandPassed = capture?.didExit == true &&
            capture?.didTimeOut == false &&
            capture?.exitCode == 0
        let passed = commandPassed && evidencePersisted && cleanupSucceeded && prefixRemoved
        details.append("fresh conformance cleanup: \(cleanupSucceeded ? "passed" : "failed")")
        details.append("fresh conformance prefix removed: \(prefixRemoved)")
        details.append("fresh conformance duration: \(String(format: "%.2f", endedAt.timeIntervalSince(startedAt)))s")
        details.append("fresh conformance result: \(passed ? "passed" : "failed")")
        return SteamConformanceSmokeResult(
            passed: passed,
            details: details
        )
    }

    private func runnerInvocationArguments(
        for executable: URL,
        prefix: URL,
        command: [String]
    ) -> [String] {
        let name = executable.lastPathComponent.lowercased()
        if name == "wine" || name == "wine64" {
            return command
        }
        return [prefix.path] + command
    }

    private func syntheticSteamLaunchResult(
        actionName: String,
        executable: URL,
        arguments: [String],
        logDirectory: URL,
        forgePlayStatusCode: Int32,
        stdoutLines: [String],
        stderrLines: [String]
    ) throws -> ProcessRunResult {
        let logs = steamManagerLogPair(in: logDirectory, name: "\(actionName)_blocked")
        let startedAt = Date()
        try writeSyntheticLog(stdoutLines, to: logs.stdout)
        try writeSyntheticLog(stderrLines, to: logs.stderr)
        let endedAt = Date()
        var result = ProcessRunResult(
            actionName: actionName,
            executable: executable,
            arguments: arguments,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: 0,
            hasProcessExitCode: false,
            forgePlayStatusCode: forgePlayStatusCode,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .preflightFailed
        )
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: logs.stderr)
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: logs.stderr),
            actionName: "\(actionName):preflight",
            executable: executable.path,
            arguments: arguments,
            environmentOverrides: [:],
            workingDirectory: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: Int64(max(0, endedAt.timeIntervalSince(startedAt) * 1_000)),
            outcome: .preflightFailed,
            exitCode: nil,
            forgePlayStatusCode: forgePlayStatusCode,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: nil,
            stdoutLog: logs.stdout.path,
            stderrLog: logs.stderr.path,
            processObservationLog: nil,
            captureError: stderrLines.isEmpty ? nil : stderrLines.joined(separator: "\n"),
            failureDomain: "ForgePlay.SteamLaunchGate",
            failureCode: Int(forgePlayStatusCode)
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
        } catch {
            result.evidenceCaptureWarning = "Synthetic launch evidence metadata could not be written: \(forgePlayTechnicalErrorSummary(error))"
        }
        return result
    }

    private func writeSyntheticLog(_ lines: [String], to url: URL) throws {
        let handle = try SafeProcessRunner.openLogFileHandle(at: url, fileManager: fileManager)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.synchronize()
    }

    private func steamManagerLogPair(in directory: URL, name: String) -> (stdout: URL, stderr: URL) {
        let stamp = Self.logTimestampFormatter.string(from: Date())
        let safeName = PathManager.sanitizedFileName(name)
        let uniqueID = UUID().uuidString
        return (
            directory.appending(path: "\(stamp)_\(safeName)_\(uniqueID)_stdout.log"),
            directory.appending(path: "\(stamp)_\(safeName)_\(uniqueID)_stderr.log")
        )
    }

    private func steamLaunchObservedRunnerExecutable(for executable: URL) -> URL {
        let name = executable.lastPathComponent.lowercased()
        if name == "wine" || name == "wine64" {
            return executable
        }
        let directory = executable.deletingLastPathComponent()
        for fileName in ["wine64", "wine"] {
            let candidate = directory.appending(path: fileName)
            if fileManager.isExecutableFile(atPath: candidate.path),
               FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        return executable
    }

    private func captureWineVersionEvidence(for executable: URL) async -> String {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(executable, fileManager: fileManager),
              fileManager.isExecutableFile(atPath: executable.path) else {
            return "BLOCKED: expected runner is not an executable regular file: \(executable.path)\n"
        }
        let environment: [String: String]
        do {
            environment = try SafeProcessRunner.runnerEnvironment(for: executable)
        } catch {
            return "BLOCKED: wine --version environment could not be resolved for \(executable.path): \(forgePlayTechnicalErrorSummary(error))\n"
        }
        let capture: BoundedProcessCaptureResult
        do {
            capture = try await Task.detached(priority: .utility) {
                try BoundedProcessExecutor.capture(
                    executable: executable,
                    arguments: ["--version"],
                    environment: environment,
                    timeout: 5
                )
            }.value
        } catch {
            return "BLOCKED: wine --version could not start for \(executable.path): \(forgePlayTechnicalErrorSummary(error))\n"
        }
        let stdoutText = String(decoding: capture.stdout, as: UTF8.self)
        let stderrText = String(decoding: capture.stderr, as: UTF8.self)
        return [
            "runner: \(executable.standardizedFileURL.path)",
            "exitCode: \(capture.exitCode)",
            "timedOut: \(capture.didTimeOut)",
            "",
            "stdout:",
            stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<empty>" : stdoutText.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "stderr:",
            stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<empty>" : stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\n") + "\n"
    }

    nonisolated static func macURL(fromSteamLibraryPath path: String, prefix: URL?) -> URL {
        SteamLibraryDriveMapper.macURL(fromSteamLibraryPath: path, prefix: prefix)
    }
}

enum SteamLaunchProcessEvidenceSource: Sendable, Hashable {
    case systemSnapshot
    case processCreationObservation
    case runnerLaunch

    var processIdentifierNamespace: SteamLaunchProcessIdentifierNamespace {
        switch self {
        case .systemSnapshot, .runnerLaunch:
            .darwin
        case .processCreationObservation:
            .windows
        }
    }
}

enum SteamLaunchProcessIdentifierNamespace: Sendable, Hashable {
    case darwin
    case windows
}

struct SteamLaunchProcessIdentifier: Sendable, Hashable {
    var namespace: SteamLaunchProcessIdentifierNamespace
    var value: Int32
}

struct SteamLaunchObservedProcess: Sendable, Hashable {
    var processID: Int32
    var command: String
    var evidenceSource: SteamLaunchProcessEvidenceSource

    init(
        processID: Int32,
        command: String,
        evidenceSource: SteamLaunchProcessEvidenceSource = .systemSnapshot
    ) {
        self.processID = processID
        self.command = command
        self.evidenceSource = evidenceSource
    }

    var identifier: SteamLaunchProcessIdentifier {
        SteamLaunchProcessIdentifier(
            namespace: evidenceSource.processIdentifierNamespace,
            value: processID
        )
    }

    var diagnosticLine: String {
        "PID \(processID): \(command)"
    }
}

struct DarwinProcessArguments: Sendable, Hashable {
    var arguments: [String]
    var winePrefix: String?
}

struct DarwinProcessSnapshotReadResult: Sendable, Hashable {
    var processes: [SteamLaunchObservedProcess]
    var state: SteamProcessObservationReadState
    var issues: [SteamProcessObservationReadIssue]
}

enum DarwinProcessSnapshotReader {
    private enum SnapshotReadResult<Value> {
        case success(Value)
        case failure(Int32)
    }

    private static let maximumArgumentBufferSize = 2 * 1024 * 1024
    private static let processPathBufferSize = Int(MAXPATHLEN) * 4

    static func current() -> DarwinProcessSnapshotReadResult {
        let processIDs: [pid_t]
        switch processIDsResult() {
        case .success(let capturedProcessIDs):
            processIDs = capturedProcessIDs
        case .failure(let errorNumber):
            return DarwinProcessSnapshotReadResult(
                processes: [],
                state: .unavailable,
                issues: [.init(
                    code: .systemSnapshotEnumerationFailed,
                    affectedRecordCount: 1,
                    detail: "proc_listallpids failed (errno=\(errorNumber): \(posixErrorMessage(errorNumber)))"
                )]
            )
        }

        var processes: [SteamLaunchObservedProcess] = []
        var pathFailureCount = 0
        var argumentFailureCount = 0
        for processID in processIDs {
            let executablePath: String
            switch executablePathResult(for: processID) {
            case .success(let path):
                executablePath = path
            case .failure(let errorNumber):
                if errorNumber != ESRCH { pathFailureCount += 1 }
                continue
            }
            guard isRelevantExecutablePath(executablePath) else { continue }
            let processArguments = arguments(for: processID)
            if processArguments == nil { argumentFailureCount += 1 }
            processes.append(SteamLaunchObservedProcess(
                processID: processID,
                command: diagnosticCommandLine(
                    executablePath: executablePath,
                    processArguments: processArguments
                )
            ))
        }
        var issues: [SteamProcessObservationReadIssue] = []
        if pathFailureCount > 0 {
            issues.append(.init(
                code: .systemProcessPathReadFailed,
                affectedRecordCount: pathFailureCount,
                detail: "one or more process paths could not be inspected; the system snapshot may be incomplete"
            ))
        }
        if argumentFailureCount > 0 {
            issues.append(.init(
                code: .systemProcessArgumentsReadFailed,
                affectedRecordCount: argumentFailureCount,
                detail: "arguments/environment were unavailable for relevant processes; WINEPREFIX attribution may be incomplete"
            ))
        }
        return DarwinProcessSnapshotReadResult(
            processes: processes,
            state: issues.isEmpty ? .complete : .recovered,
            issues: issues
        )
    }

    static func parseProcessArguments(_ data: Data) -> DarwinProcessArguments? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let argumentCount = data.withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argumentCount >= 0, argumentCount <= 4_096 else { return nil }

        let bytes = [UInt8](data)
        var offset = MemoryLayout<Int32>.size
        guard readNullTerminatedString(in: bytes, offset: &offset) != nil else {
            return nil
        }
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<Int(argumentCount) {
            guard let argument = readNullTerminatedString(in: bytes, offset: &offset) else {
                return nil
            }
            arguments.append(argument)
        }

        var winePrefix: String?
        while offset < bytes.count {
            while offset < bytes.count, bytes[offset] == 0 {
                offset += 1
            }
            guard offset < bytes.count,
                  let environmentEntry = readNullTerminatedString(in: bytes, offset: &offset) else {
                break
            }
            if environmentEntry.hasPrefix("WINEPREFIX=") {
                winePrefix = String(environmentEntry.dropFirst("WINEPREFIX=".count))
                break
            }
        }
        return DarwinProcessArguments(arguments: arguments, winePrefix: winePrefix)
    }

    static func diagnosticCommandLine(
        executablePath: String,
        processArguments: DarwinProcessArguments?
    ) -> String {
        var commandParts = [executablePath]
        if var arguments = processArguments?.arguments, !arguments.isEmpty {
            if arguments[0] == executablePath ||
                URL(fileURLWithPath: arguments[0]).standardizedFileURL.path ==
                URL(fileURLWithPath: executablePath).standardizedFileURL.path {
                arguments.removeFirst()
            }
            commandParts.append(contentsOf: arguments)
        }
        if let winePrefix = processArguments?.winePrefix, !winePrefix.isEmpty {
            commandParts.append("WINEPREFIX=\(winePrefix)")
        }
        return commandParts.joined(separator: " ")
    }

    private static func processIDsResult() -> SnapshotReadResult<[pid_t]> {
        let initialCount = proc_listallpids(nil, 0)
        guard initialCount >= 0 else { return .failure(errno) }
        var capacity = max(Int(initialCount) + 64, 256)
        for _ in 0..<3 {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else { return .failure(errno) }
            guard count > 0 else { return .success([]) }
            if count < capacity {
                return .success(Array(processIDs.prefix(Int(count))).filter { $0 > 0 })
            }
            capacity = Int(count) + 64
        }
        return .failure(EOVERFLOW)
    }

    private static func executablePathResult(for processID: pid_t) -> SnapshotReadResult<String> {
        var pathBuffer = [CChar](repeating: 0, count: processPathBufferSize)
        let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(processID, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathLength > 0 else { return .failure(errno) }
        guard let path = pathBuffer.withUnsafeBufferPointer({ buffer -> String? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }) else { return .failure(EIO) }
        return .success(path)
    }

    static func arguments(for processID: pid_t) -> DarwinProcessArguments? {
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), processID]
        var size = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), nil, &size, nil, 0)
        }
        guard sizeResult == 0,
              size > MemoryLayout<Int32>.size,
              size <= maximumArgumentBufferSize else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let readResult = mib.withUnsafeMutableBufferPointer { mibPointer in
            buffer.withUnsafeMutableBytes { bufferPointer in
                sysctl(
                    mibPointer.baseAddress,
                    u_int(mibPointer.count),
                    bufferPointer.baseAddress,
                    &size,
                    nil,
                    0
                )
            }
        }
        guard readResult == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcessArguments(Data(buffer.prefix(size)))
    }

    private static func isRelevantExecutablePath(_ executablePath: String) -> Bool {
        let normalizedPath = executablePath.lowercased()
        let executableName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        let isExternalAppRuntime = normalizedPath.contains(".app/contents/") &&
            !normalizedPath.contains("/contents/resources/runners/forgeplayruntime/") &&
            (executableName.contains("wine") || executableName.contains("steam"))
        return executableName == "wine" ||
            executableName == "wine64" ||
            executableName.hasPrefix("wine-preloader") ||
            executableName.hasPrefix("wineserver") ||
            normalizedPath.contains("/wine/lib/wine/") ||
            isExternalAppRuntime ||
            normalizedPath.contains("/steam.app/") ||
            normalizedPath.contains("/steam/steam.appbundle/") ||
            executableName == "steam_osx" ||
            executableName == "ipcserver"
    }

    private static func readNullTerminatedString(
        in bytes: [UInt8],
        offset: inout Int
    ) -> String? {
        guard offset < bytes.count else { return nil }
        let start = offset
        while offset < bytes.count, bytes[offset] != 0 {
            offset += 1
        }
        guard offset < bytes.count else { return nil }
        let value = String(decoding: bytes[start..<offset], as: UTF8.self)
        offset += 1
        return value
    }

    private static func posixErrorMessage(_ errorNumber: Int32) -> String {
        String(cString: Darwin.strerror(errorNumber))
    }
}

enum SteamGameRendererPlannedComponentOwnership: String, Sendable, Hashable {
    case d3dMetal
    case dxmt
    case dxvk
    case d9vk
    case loader
    case legacy32
    case unreported
}

enum SteamGameRendererActualLoadedState: String, Sendable, Hashable {
    /// ForgePlay selected a renderer plan but did not observe a renderer module
    /// being loaded in the child. Never replace this with a route-time guess.
    case unobserved
    /// At least one Direct3D renderer module reached Wine's successful loader
    /// return path and its resolved module path was captured.
    case loaded
    /// Wine reported a successful module load, but the resolved DLL path was
    /// not proven to belong to the active architecture-specific renderer
    /// allowlist. This evidence must never be promoted to `loaded`.
    case loadPathUnverified = "load-path-unverified"
    /// Relevant renderer module loads were observed, but none succeeded.
    case loadFailed = "load-failed"
}

enum SteamGameRendererModuleLoadState: String, Sendable, Hashable {
    case loaded
    case failed
}

enum SteamGameRendererLoadPathOwnership: String, Sendable, Hashable {
    case verified
    case mismatch
    case unavailable
    /// LOAD_V2 did not carry loader-path ownership. It remains readable as
    /// historical raw evidence, but it cannot prove a renderer load.
    case legacyUnverified = "legacy-unverified"
}

struct SteamGameRendererModuleLoadObservation: Sendable, Hashable {
    var recordSequence: Int
    var processID: Int32
    var state: SteamGameRendererModuleLoadState
    var module: String
    var actualPath: String?
    var pathOwnership: SteamGameRendererLoadPathOwnership
    var plannedProfile: String
    var plannedOwner: String
    var statusCode: UInt32
    var correlationIdentifier: String
    var executable: String

    var statusHex: String {
        String(format: "0x%08X", statusCode)
    }
}

struct SteamGameRendererObservation: Sendable, Hashable {
    /// Monotonic position in the process-observation log. This preserves the
    /// relative order between successful routes and renderer setup failures.
    var recordSequence: Int
    var processID: Int32
    /// The exact user-selected renderer for this Steam session.
    var rendererPolicy: SteamRendererPolicyPreference
    /// Named profile selected before process creation. This is a plan, not
    /// evidence that any renderer module was actually loaded.
    var plannedProfile: String
    var plannedComponentOwnership: SteamGameRendererPlannedComponentOwnership
    var plannedComponentsX64: String
    var plannedComponentsX86: String
    var actualLoadedState: SteamGameRendererActualLoadedState
    var routingReason: String
    var routingEvidence: String
    var correlationIdentifier: String?
    var executable: String

    init(
        recordSequence: Int = 0,
        processID: Int32,
        rendererPolicy: SteamRendererPolicyPreference,
        executable: String
    ) {
        self.recordSequence = recordSequence
        self.processID = processID
        self.rendererPolicy = rendererPolicy
        self.plannedProfile = rendererPolicy.rawValue
        switch rendererPolicy {
        case .d3dMetal:
            self.plannedComponentOwnership = .d3dMetal
        case .dxmt:
            self.plannedComponentOwnership = .dxmt
        case .d9vk:
            self.plannedComponentOwnership = .d9vk
        case .vulkan:
            self.plannedComponentOwnership = .dxvk
        }
        self.plannedComponentsX64 = "unreported"
        self.plannedComponentsX86 = "unreported"
        self.actualLoadedState = .unobserved
        self.routingReason = "legacy-policy"
        self.routingEvidence = "legacy-observation"
        self.correlationIdentifier = nil
        self.executable = executable
    }

    init(
        recordSequence: Int = 0,
        processID: Int32,
        rendererPolicy: SteamRendererPolicyPreference,
        plannedProfile: String,
        plannedComponentOwnership: SteamGameRendererPlannedComponentOwnership,
        plannedComponentsX64: String = "unreported",
        plannedComponentsX86: String = "unreported",
        actualLoadedState: SteamGameRendererActualLoadedState = .unobserved,
        routingReason: String,
        routingEvidence: String,
        correlationIdentifier: String? = nil,
        executable: String
    ) {
        self.recordSequence = recordSequence
        self.processID = processID
        self.rendererPolicy = rendererPolicy
        self.plannedProfile = plannedProfile
        self.plannedComponentOwnership = plannedComponentOwnership
        self.plannedComponentsX64 = plannedComponentsX64
        self.plannedComponentsX86 = plannedComponentsX86
        self.actualLoadedState = actualLoadedState
        self.routingReason = routingReason
        self.routingEvidence = routingEvidence
        self.correlationIdentifier = correlationIdentifier
        self.executable = executable
    }

    var executableName: String {
        executable
            .split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .last
            .map(String.init) ?? executable
    }
}

struct SteamGameRendererErrorObservation: Sendable, Hashable {
    /// Monotonic position in the process-observation log. See
    /// `SteamGameRendererObservation.recordSequence`.
    var recordSequence: Int
    var processID: Int32
    var stage: String
    var statusCode: UInt32
    var path: String

    var statusHex: String {
        String(format: "0x%08X", statusCode)
    }

    init(
        recordSequence: Int = 0,
        processID: Int32,
        stage: String,
        statusCode: UInt32,
        path: String
    ) {
        self.recordSequence = recordSequence
        self.processID = processID
        self.stage = stage
        self.statusCode = statusCode
        self.path = path
    }
}

struct SteamGameRendererEnvironmentFailureObservation: Sendable, Hashable {
    var recordSequence: Int
    var processID: Int32
    var operation: String
    var sourceVariable: String
    var targetVariable: String
    var statusCode: UInt32

    var statusHex: String {
        String(format: "0x%08X", statusCode)
    }
}

struct SteamGameRendererFallbackObservation: Sendable, Hashable {
    var recordSequence: Int
    var processID: Int32
    var stage: String
    var statusCode: UInt32
    var result: String
    var path: String

    var statusHex: String {
        String(format: "0x%08X", statusCode)
    }
}

enum SteamProcessObservationReadState: String, Sendable, Hashable {
    case complete
    case recovered
    case unavailable
}

enum SteamProcessObservationReadIssueCode: String, Sendable, Hashable {
    case sourceURLMissing
    case sourceMissing
    case openFailed
    case metadataReadFailed
    case unsafeSource
    case oversizedTailRecovered
    case leadingPartialRecordDiscarded
    case trailingPartialRecordDiscarded
    case recordLimitApplied
    case invalidUTF8RecordDiscarded
    case malformedRecordDiscarded
    case shortRead
    case readFailed
    case systemSnapshotEnumerationFailed
    case systemProcessPathReadFailed
    case systemProcessArgumentsReadFailed
}

struct SteamProcessObservationReadIssue: Sendable, Hashable {
    var code: SteamProcessObservationReadIssueCode
    var affectedRecordCount: Int
    var detail: String

    var diagnosticDescription: String {
        "\(code.rawValue)(count=\(affectedRecordCount)): \(detail)"
    }
}

struct SteamProcessObservationReadResult: Sendable, Hashable {
    var processes: [SteamLaunchObservedProcess]
    var gameRendererObservations: [SteamGameRendererObservation]
    var gameRendererErrors: [SteamGameRendererErrorObservation] = []
    var gameRendererEnvironmentFailures: [SteamGameRendererEnvironmentFailureObservation] = []
    var gameRendererFallbacks: [SteamGameRendererFallbackObservation] = []
    var gameRendererModuleLoads: [SteamGameRendererModuleLoadObservation] = []
    var state: SteamProcessObservationReadState
    var issues: [SteamProcessObservationReadIssue]

    var diagnosticWarning: String? {
        guard state != .complete else { return nil }
        let issueSummary = issues.map(\.diagnosticDescription).joined(separator: " | ")
        return "Process observation read state=\(state.rawValue); \(issueSummary)"
    }
}

enum SteamProcessCreationObservationLog {
    private static let processRecordPrefix = "FORGEPLAY_PROCESS_V1"
    private static let gameRendererRecordPrefix = "FORGEPLAY_GAME_RENDERER_V1"
    private static let gameRendererRouteV2RecordPrefix = "FORGEPLAY_GAME_RENDERER_ROUTE_V2"
    private static let gameRendererErrorRecordPrefix = "FORGEPLAY_GAME_RENDERER_ERROR_V1"
    private static let gameRendererEnvironmentRecordPrefix =
        "FORGEPLAY_GAME_RENDERER_ENVIRONMENT_V1"
    private static let gameRendererFallbackRecordPrefix = "FORGEPLAY_GAME_RENDERER_FALLBACK_V1"
    private static let gameRendererModuleLoadRecordPrefix = "FORGEPLAY_GAME_RENDERER_LOAD_V3"
    private static let legacyGameRendererModuleLoadRecordPrefix =
        "FORGEPLAY_GAME_RENDERER_LOAD_V2"
    private static let maximumFileSize = 1024 * 1024
    private static let maximumRecordCount = 4_096
    private static let maximumCommandSize = 256 * 1024
    private static let rendererModuleNames: Set<String> = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "d3d12.dll",
        "d3d12core.dll",
        "dxgi.dll",
        "winemetal.dll",
        "nvapi64.dll",
        "nvngx.dll",
        "nvngx-on-metalfx.dll"
    ]

    private static func value(in component: String, after prefix: String) -> String? {
        guard component.hasPrefix(prefix) else { return nil }
        return String(component.dropFirst(prefix.count))
    }

    static func processes(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamLaunchObservedProcess] {
        read(at: url, fileManager: fileManager).processes
    }

    static func gameRendererObservations(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamGameRendererObservation] {
        read(at: url, fileManager: fileManager).gameRendererObservations
    }

    static func gameRendererErrors(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamGameRendererErrorObservation] {
        read(at: url, fileManager: fileManager).gameRendererErrors
    }

    static func gameRendererEnvironmentFailures(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamGameRendererEnvironmentFailureObservation] {
        read(at: url, fileManager: fileManager).gameRendererEnvironmentFailures
    }

    static func gameRendererFallbacks(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamGameRendererFallbackObservation] {
        read(at: url, fileManager: fileManager).gameRendererFallbacks
    }

    static func gameRendererModuleLoads(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamGameRendererModuleLoadObservation] {
        read(at: url, fileManager: fileManager).gameRendererModuleLoads
    }

    static func parse(_ data: Data) -> [SteamLaunchObservedProcess] {
        parseResult(data).processes
    }

    static func parseGameRendererObservations(_ data: Data) -> [SteamGameRendererObservation] {
        parseResult(data).gameRendererObservations
    }

    static func parseGameRendererErrors(_ data: Data) -> [SteamGameRendererErrorObservation] {
        parseResult(data).gameRendererErrors
    }

    static func parseGameRendererEnvironmentFailures(
        _ data: Data
    ) -> [SteamGameRendererEnvironmentFailureObservation] {
        parseResult(data).gameRendererEnvironmentFailures
    }

    static func parseGameRendererFallbacks(
        _ data: Data
    ) -> [SteamGameRendererFallbackObservation] {
        parseResult(data).gameRendererFallbacks
    }

    static func parseGameRendererModuleLoads(
        _ data: Data
    ) -> [SteamGameRendererModuleLoadObservation] {
        parseResult(data).gameRendererModuleLoads
    }

    static func read(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> SteamProcessObservationReadResult {
        guard let url else {
            return unavailableResult(
                code: .sourceURLMissing,
                detail: "no process observation source URL was recorded"
            )
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let errorNumber = errno
            let code: SteamProcessObservationReadIssueCode =
                errorNumber == ENOENT && !fileManager.fileExists(atPath: url.path)
                ? .sourceMissing
                : .openFailed
            return unavailableResult(
                code: code,
                detail: "open failed (errno=\(errorNumber): \(posixErrorMessage(errorNumber)))"
            )
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let errorNumber = errno
            return unavailableResult(
                code: .metadataReadFailed,
                detail: "fstat failed (errno=\(errorNumber): \(posixErrorMessage(errorNumber)))"
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              info.st_size >= 0 else {
            return unavailableResult(
                code: .unsafeSource,
                detail: "source is not a private, owner-controlled regular file"
            )
        }

        let snapshotSize = info.st_size
        let readCount = Int(min(snapshotSize, off_t(maximumFileSize)))
        let readOffset = snapshotSize - off_t(readCount)
        var prefixIssues: [SteamProcessObservationReadIssue] = []
        let leadingBoundaryIsNewline: Bool
        if readOffset > 0 {
            let previousByte = readBytes(descriptor: descriptor, offset: readOffset - 1, count: 1)
            if let errorNumber = previousByte.errorNumber {
                prefixIssues.append(issue(
                    .readFailed,
                    detail: "could not verify the bounded tail record boundary " +
                        "(errno=\(errorNumber): \(posixErrorMessage(errorNumber)))"
                ))
                leadingBoundaryIsNewline = false
            } else if previousByte.data.count == 1 {
                leadingBoundaryIsNewline = previousByte.data[previousByte.data.startIndex] == 0x0a
            } else {
                prefixIssues.append(issue(
                    .shortRead,
                    detail: "the source changed while checking the bounded tail record boundary"
                ))
                leadingBoundaryIsNewline = false
            }
        } else {
            leadingBoundaryIsNewline = true
        }

        let snapshot = readBytes(descriptor: descriptor, offset: readOffset, count: readCount)
        if let errorNumber = snapshot.errorNumber {
            prefixIssues.append(issue(
                .readFailed,
                detail: "bounded read failed after \(snapshot.data.count) of \(readCount) bytes " +
                    "(errno=\(errorNumber): \(posixErrorMessage(errorNumber)))"
            ))
        }
        if snapshot.data.count < readCount {
            prefixIssues.append(issue(
                .shortRead,
                detail: "source changed during read; recovered \(snapshot.data.count) of \(readCount) bytes"
            ))
        }
        if readCount > 0, snapshot.data.isEmpty, !prefixIssues.isEmpty {
            return SteamProcessObservationReadResult(
                processes: [],
                gameRendererObservations: [],
                gameRendererErrors: [],
                state: .unavailable,
                issues: prefixIssues
            )
        }

        if snapshotSize > off_t(maximumFileSize) {
            prefixIssues.append(issue(
                .oversizedTailRecovered,
                detail: "source size \(snapshotSize) bytes exceeded \(maximumFileSize); parsed the newest bounded tail"
            ))
        }
        return decode(
            snapshot.data,
            clippedLeadingBytes: readOffset > 0,
            leadingBoundaryIsNewline: leadingBoundaryIsNewline,
            prefixIssues: prefixIssues
        )
    }

    static func parseResult(_ data: Data) -> SteamProcessObservationReadResult {
        let clippedByteCount = max(0, data.count - maximumFileSize)
        let leadingBoundaryIsNewline = clippedByteCount == 0 || data[data.index(data.startIndex, offsetBy: clippedByteCount - 1)] == 0x0a
        let boundedData = clippedByteCount > 0 ? Data(data.suffix(maximumFileSize)) : data
        let prefixIssues = clippedByteCount > 0
            ? [issue(
                .oversizedTailRecovered,
                detail: "input size \(data.count) bytes exceeded \(maximumFileSize); parsed the newest bounded tail"
            )]
            : []
        return decode(
            boundedData,
            clippedLeadingBytes: clippedByteCount > 0,
            leadingBoundaryIsNewline: leadingBoundaryIsNewline,
            prefixIssues: prefixIssues
        )
    }

    private static func decode(
        _ boundedData: Data,
        clippedLeadingBytes: Bool,
        leadingBoundaryIsNewline: Bool,
        prefixIssues: [SteamProcessObservationReadIssue]
    ) -> SteamProcessObservationReadResult {
        var issues = prefixIssues
        var completeData = boundedData

        if clippedLeadingBytes, !leadingBoundaryIsNewline, !completeData.isEmpty {
            if let firstNewline = completeData.firstIndex(of: 0x0a) {
                completeData = Data(completeData[completeData.index(after: firstNewline)...])
            } else {
                completeData.removeAll(keepingCapacity: false)
            }
            issues.append(issue(
                .leadingPartialRecordDiscarded,
                detail: "discarded the record fragment crossing the bounded tail boundary"
            ))
        }

        if !completeData.isEmpty, completeData.last != 0x0a {
            if let finalNewline = completeData.lastIndex(of: 0x0a) {
                completeData = Data(completeData[...finalNewline])
            } else {
                completeData.removeAll(keepingCapacity: false)
            }
            issues.append(issue(
                .trailingPartialRecordDiscarded,
                detail: "discarded a trailing record without a newline commit marker"
            ))
        }

        var lineData: [Data] = []
        var lineStart = completeData.startIndex
        for index in completeData.indices where completeData[index] == 0x0a {
            if lineStart < index {
                lineData.append(Data(completeData[lineStart..<index]))
            }
            lineStart = completeData.index(after: index)
        }
        if lineData.count > maximumRecordCount {
            let discardedCount = lineData.count - maximumRecordCount
            lineData = Array(lineData.suffix(maximumRecordCount))
            issues.append(issue(
                .recordLimitApplied,
                affectedRecordCount: discardedCount,
                detail: "retained the newest \(maximumRecordCount) complete records"
            ))
        }

        var processes: [SteamLaunchObservedProcess] = []
        var rendererObservations: [SteamGameRendererObservation] = []
        var rendererErrors: [SteamGameRendererErrorObservation] = []
        var rendererEnvironmentFailures: [SteamGameRendererEnvironmentFailureObservation] = []
        var rendererFallbacks: [SteamGameRendererFallbackObservation] = []
        var rendererModuleLoads: [SteamGameRendererModuleLoadObservation] = []
        var invalidUTF8Count = 0
        var malformedCount = 0
        for (recordSequence, recordData) in lineData.enumerated() {
            guard let rawLine = String(data: recordData, encoding: .utf8) else {
                invalidUTF8Count += 1
                continue
            }
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                malformedCount += 1
                continue
            }
            // A route rejected before NtCreateUserProcess has no child PID. Wine
            // emits ROUTE_V2 with PID 0 so the exact generation/profile failure
            // survives; no other observation type may use the sentinel.
            let processID: Int32?
            if fields[0] == gameRendererRouteV2RecordPrefix, fields[1] == "0" {
                processID = 0
            } else {
                processID = validatedProcessID(fields[1])
            }
            guard let processID else {
                malformedCount += 1
                continue
            }

            if fields[0] == processRecordPrefix {
                let command = String(fields[2])
                guard !command.isEmpty,
                      command.utf8.count <= maximumCommandSize,
                      command.lowercased().contains(SteamWebHelperLaunchPolicy.executableName),
                      !command.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                    malformedCount += 1
                    continue
                }
                processes.append(SteamLaunchObservedProcess(
                    processID: processID,
                    command: command,
                    evidenceSource: .processCreationObservation
                ))
            } else if fields[0] == gameRendererRecordPrefix ||
                        fields[0] == gameRendererRouteV2RecordPrefix {
                let payload = String(fields[2])
                guard payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                    malformedCount += 1
                    continue
                }
                let components = payload.components(separatedBy: " | ")
                if components.count >= 10,
                   let requestedText = value(in: components[0], after: "requested="),
                   let appliedText = value(in: components[1], after: "applied="),
                   let plannedProfile = value(in: components[2], after: "planned-profile="),
                   let plannedOwnerText = value(in: components[3], after: "planned-owner="),
                   let plannedComponentsX64 = value(
                    in: components[4],
                    after: "planned-components-x64="
                   ),
                   let plannedComponentsX86 = value(
                    in: components[5],
                    after: "planned-components-x86="
                   ),
                   let actualLoadedText = value(in: components[6], after: "actual-loaded="),
                   let routingReason = value(in: components[7], after: "reason="),
                   let routingEvidence = value(in: components[8], after: "evidence="),
                   let plannedComponentOwnership = SteamGameRendererPlannedComponentOwnership(
                    rawValue: plannedOwnerText
                   ),
                   let actualLoadedState = SteamGameRendererActualLoadedState(
                    rawValue: actualLoadedText
                   ),
                   appliedText == plannedOwnerText {
                    let rendererPolicy = SteamRendererPolicyPreference(
                        rawValue: requestedText
                    )
                    let isVersion2 = fields[0] == gameRendererRouteV2RecordPrefix
                    let correlationIdentifier: String?
                    let executableStartIndex: Int
                    if isVersion2 {
                        guard components.count >= 11,
                              let correlation = value(
                                in: components[9],
                                after: "correlation="
                              ),
                              !correlation.isEmpty,
                              correlation.utf8.count <= 128 else {
                            malformedCount += 1
                            continue
                        }
                        correlationIdentifier = correlation
                        executableStartIndex = 10
                    } else {
                        correlationIdentifier = nil
                        executableStartIndex = 9
                    }
                    let executable = components.dropFirst(executableStartIndex)
                        .joined(separator: " | ")
                    guard let rendererPolicy,
                          !plannedProfile.isEmpty,
                          !plannedComponentsX64.isEmpty,
                          !plannedComponentsX86.isEmpty,
                          !routingReason.isEmpty,
                          !routingEvidence.isEmpty,
                          !executable.isEmpty else {
                        malformedCount += 1
                        continue
                    }
                    rendererObservations.append(SteamGameRendererObservation(
                        recordSequence: recordSequence,
                        processID: processID,
                        rendererPolicy: rendererPolicy,
                        plannedProfile: plannedProfile,
                        plannedComponentOwnership: plannedComponentOwnership,
                        plannedComponentsX64: plannedComponentsX64,
                        plannedComponentsX86: plannedComponentsX86,
                        actualLoadedState: actualLoadedState,
                        routingReason: routingReason,
                        routingEvidence: routingEvidence,
                        correlationIdentifier: correlationIdentifier,
                        executable: executable
                    ))
                } else if components.count >= 5,
                          let requestedText = value(in: components[0], after: "requested="),
                          let appliedText = value(in: components[1], after: "applied="),
                          let routingReason = value(in: components[2], after: "reason="),
                          let routingEvidence = value(in: components[3], after: "evidence="),
                          let plannedComponentOwnership =
                            SteamGameRendererPlannedComponentOwnership(rawValue: appliedText) {
                    let rendererPolicy = SteamRendererPolicyPreference(
                        rawValue: requestedText
                    )
                    let executable = components.dropFirst(4).joined(separator: " | ")
                    guard let rendererPolicy,
                          !routingReason.isEmpty,
                          !routingEvidence.isEmpty,
                          !executable.isEmpty else {
                        malformedCount += 1
                        continue
                    }
                    rendererObservations.append(SteamGameRendererObservation(
                        recordSequence: recordSequence,
                        processID: processID,
                        rendererPolicy: rendererPolicy,
                        plannedProfile: appliedText,
                        plannedComponentOwnership: plannedComponentOwnership,
                        actualLoadedState: .unobserved,
                        routingReason: routingReason,
                        routingEvidence: routingEvidence,
                        executable: executable
                    ))
                } else if let separator = payload.range(of: " | ") {
                    let policyText = String(payload[..<separator.lowerBound])
                    let executable = String(payload[separator.upperBound...])
                    guard let rendererPolicy = SteamRendererPolicyPreference(rawValue: policyText),
                          !executable.isEmpty else {
                        malformedCount += 1
                        continue
                    }
                    rendererObservations.append(SteamGameRendererObservation(
                        recordSequence: recordSequence,
                        processID: processID,
                        rendererPolicy: rendererPolicy,
                        executable: executable
                    ))
                } else {
                    malformedCount += 1
                }
            } else if fields[0] == gameRendererErrorRecordPrefix {
                let payload = String(fields[2])
                let components = payload.components(separatedBy: " | ")
                guard components.count >= 3,
                      payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: { $0.value < 0x20 }),
                      let statusText = value(in: components[1], after: "status=0x"),
                      statusText.count == 8,
                      statusText.allSatisfy(\.isHexDigit),
                      let statusCode = UInt32(statusText, radix: 16) else {
                    malformedCount += 1
                    continue
                }
                let stage = components[0]
                let path = components.dropFirst(2).joined(separator: " | ")
                guard !stage.isEmpty, !path.isEmpty else {
                    malformedCount += 1
                    continue
                }
                rendererErrors.append(SteamGameRendererErrorObservation(
                    recordSequence: recordSequence,
                    processID: processID,
                    stage: stage,
                    statusCode: statusCode,
                    path: path
                ))
            } else if fields[0] == gameRendererEnvironmentRecordPrefix {
                let payload = String(fields[2])
                let components = payload.components(separatedBy: " | ")
                guard components.count == 4,
                      payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: { $0.value < 0x20 }),
                      let operation = value(in: components[0], after: "operation="),
                      let sourceVariable = value(in: components[1], after: "source="),
                      let targetVariable = value(in: components[2], after: "target="),
                      let statusText = value(in: components[3], after: "status=0x"),
                      !operation.isEmpty,
                      !sourceVariable.isEmpty,
                      !targetVariable.isEmpty,
                      operation.utf8.count <= 64,
                      sourceVariable.utf8.count <= 192,
                      targetVariable.utf8.count <= 192,
                      statusText.count == 8,
                      statusText.allSatisfy(\.isHexDigit),
                      let statusCode = UInt32(statusText, radix: 16) else {
                    malformedCount += 1
                    continue
                }
                rendererEnvironmentFailures.append(
                    SteamGameRendererEnvironmentFailureObservation(
                        recordSequence: recordSequence,
                        processID: processID,
                        operation: operation,
                        sourceVariable: sourceVariable,
                        targetVariable: targetVariable,
                        statusCode: statusCode
                    )
                )
            } else if fields[0] == gameRendererFallbackRecordPrefix {
                let payload = String(fields[2])
                let components = payload.components(separatedBy: " | ")
                guard components.count >= 4,
                      payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: { $0.value < 0x20 }),
                      let stage = value(in: components[0], after: "stage="),
                      let statusText = value(in: components[1], after: "status=0x"),
                      let result = value(in: components[2], after: "result="),
                      let path = value(
                        in: components.dropFirst(3).joined(separator: " | "),
                        after: "path="
                      ),
                      !stage.isEmpty,
                      !result.isEmpty,
                      !path.isEmpty,
                      stage.utf8.count <= 96,
                      result.utf8.count <= 96,
                      statusText.count == 8,
                      statusText.allSatisfy(\.isHexDigit),
                      let statusCode = UInt32(statusText, radix: 16) else {
                    malformedCount += 1
                    continue
                }
                rendererFallbacks.append(SteamGameRendererFallbackObservation(
                    recordSequence: recordSequence,
                    processID: processID,
                    stage: stage,
                    statusCode: statusCode,
                    result: result,
                    path: path
                ))
            } else if fields[0] == gameRendererModuleLoadRecordPrefix ||
                        fields[0] == legacyGameRendererModuleLoadRecordPrefix {
                let payload = String(fields[2])
                let components = payload.components(separatedBy: " | ")
                let isVersion3 = fields[0] == gameRendererModuleLoadRecordPrefix
                let pathOwnership: SteamGameRendererLoadPathOwnership
                if isVersion3 {
                    guard components.count == 9,
                          let ownershipText = value(
                            in: components[3],
                            after: "path-owner="
                          ),
                          let parsedOwnership = SteamGameRendererLoadPathOwnership(
                            rawValue: ownershipText
                          ),
                          parsedOwnership != .legacyUnverified else {
                        malformedCount += 1
                        continue
                    }
                    pathOwnership = parsedOwnership
                } else {
                    guard components.count == 8 else {
                        malformedCount += 1
                        continue
                    }
                    pathOwnership = .legacyUnverified
                }
                let profileIndex = isVersion3 ? 4 : 3
                let ownerIndex = isVersion3 ? 5 : 4
                let statusIndex = isVersion3 ? 6 : 5
                let correlationIndex = isVersion3 ? 7 : 6
                let executableIndex = isVersion3 ? 8 : 7
                guard
                      payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: { $0.value < 0x20 }),
                      let stateText = value(in: components[0], after: "state="),
                      let loadState = SteamGameRendererModuleLoadState(rawValue: stateText),
                      let module = value(in: components[1], after: "module="),
                      rendererModuleNames.contains(module.lowercased()),
                      let actualPathText = value(in: components[2], after: "actual-path="),
                      !actualPathText.isEmpty,
                      let profile = value(
                        in: components[profileIndex],
                        after: "profile="
                      ),
                      !profile.isEmpty,
                      profile.utf8.count <= 64,
                      let owner = value(
                        in: components[ownerIndex],
                        after: "owner="
                      ),
                      !owner.isEmpty,
                      owner.utf8.count <= 64,
                      let statusText = value(
                        in: components[statusIndex],
                        after: "status=0x"
                      ),
                      statusText.count == 8,
                      statusText.allSatisfy(\.isHexDigit),
                      let statusCode = UInt32(statusText, radix: 16),
                      let correlationIdentifier = value(
                        in: components[correlationIndex],
                        after: "correlation="
                      ),
                      !correlationIdentifier.isEmpty,
                      correlationIdentifier.utf8.count <= 128,
                      let executable = value(
                        in: components[executableIndex],
                        after: "executable="
                      ),
                      !executable.isEmpty,
                      (loadState == .loaded) == (statusCode == 0),
                      loadState != .loaded || actualPathText != "unavailable" else {
                    malformedCount += 1
                    continue
                }
                rendererModuleLoads.append(SteamGameRendererModuleLoadObservation(
                    recordSequence: recordSequence,
                    processID: processID,
                    state: loadState,
                    module: module.lowercased(),
                    actualPath: actualPathText == "unavailable" ? nil : actualPathText,
                    pathOwnership: pathOwnership,
                    plannedProfile: profile,
                    plannedOwner: owner,
                    statusCode: statusCode,
                    correlationIdentifier: correlationIdentifier,
                    executable: executable
                ))
            } else {
                malformedCount += 1
            }
        }
        if invalidUTF8Count > 0 {
            issues.append(issue(
                .invalidUTF8RecordDiscarded,
                affectedRecordCount: invalidUTF8Count,
                detail: "discarded invalid UTF-8 records without discarding adjacent valid records"
            ))
        }
        if malformedCount > 0 {
            issues.append(issue(
                .malformedRecordDiscarded,
                affectedRecordCount: malformedCount,
                detail: "discarded records that did not match a supported observation schema"
            ))
        }

        return SteamProcessObservationReadResult(
            processes: processes,
            gameRendererObservations: rendererObservations,
            gameRendererErrors: rendererErrors,
            gameRendererEnvironmentFailures: rendererEnvironmentFailures,
            gameRendererFallbacks: rendererFallbacks,
            gameRendererModuleLoads: rendererModuleLoads,
            state: issues.isEmpty ? .complete : .recovered,
            issues: issues
        )
    }

    private static func validatedProcessID(_ field: Substring) -> Int32? {
        guard !field.isEmpty,
              field.allSatisfy(\.isNumber),
              let unsignedProcessID = UInt32(field),
              unsignedProcessID > 0,
              unsignedProcessID <= UInt32(Int32.max) else {
            return nil
        }
        return Int32(unsignedProcessID)
    }

    private static func unavailableResult(
        code: SteamProcessObservationReadIssueCode,
        detail: String
    ) -> SteamProcessObservationReadResult {
        SteamProcessObservationReadResult(
            processes: [],
            gameRendererObservations: [],
            gameRendererErrors: [],
            state: .unavailable,
            issues: [issue(code, detail: detail)]
        )
    }

    private static func issue(
        _ code: SteamProcessObservationReadIssueCode,
        affectedRecordCount: Int = 1,
        detail: String
    ) -> SteamProcessObservationReadIssue {
        SteamProcessObservationReadIssue(
            code: code,
            affectedRecordCount: affectedRecordCount,
            detail: detail
        )
    }

    private static func posixErrorMessage(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }

    private static func readBytes(
        descriptor: Int32,
        offset: off_t,
        count: Int
    ) -> (data: Data, errorNumber: Int32?) {
        guard count > 0 else { return (Data(), nil) }
        var bytes = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        var readError: Int32?
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while totalRead < count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    count - totalRead,
                    offset + off_t(totalRead)
                )
                if result > 0 {
                    totalRead += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    readError = errno
                    break
                }
            }
        }
        if totalRead < bytes.count {
            bytes.removeSubrange(totalRead...)
        }
        return (Data(bytes), readError)
    }
}

enum SteamGameLaunchDiagnosticState: String, Codable, Sendable, Hashable {
    case launching
    case running
    case runningHeadless
    case earlyExit
    case exitedWithError
    case exited
    case rendererError
}

struct SteamGameLaunchDiagnostic: Codable, Sendable, Hashable {
    var schemaVersion = 4
    var state: SteamGameLaunchDiagnosticState
    var appID: String?
    var primaryProcessID: Int32?
    var trackedProcessIDs: [Int32]
    var activeProcessIDs: [Int32]
    var executable: String?
    var startedAt: Date?
    var endedAt: Date?
    var observedAt: Date
    var elapsedSeconds: TimeInterval?
    var exitCodesByProcessID: [String: Int32]
    var primaryExitCode: Int32?
    var primaryExitStatusHex: String?
    var failureProcessID: Int32?
    var failureExitCode: Int32?
    var failureExitStatusHex: String?
    var consoleLastTask: String?
    var rendererRequested: String?
    /// Legacy serialized field retained for document compatibility. New
    /// diagnostics leave it nil unless an actually loaded module is observed.
    var rendererApplied: String?
    var rendererPlannedProfile: String?
    var rendererPlannedComponentOwnership: String?
    var rendererPlannedComponentsX64: String?
    var rendererPlannedComponentsX86: String?
    var rendererActualLoaded: String?
    var rendererLoadedModules: [String]? = nil
    var rendererLoadedModulePaths: [String]? = nil
    var rendererModuleLoadFailures: [String]? = nil
    var rendererRoutingReason: String?
    var rendererRoutingEvidence: String?
    /// Route V2 lineage token used to prove that route and Load V3 records
    /// belong to the same process creation. It is diagnostic evidence, not a
    /// user or game identifier.
    var rendererCorrelationIdentifier: String? = nil
    var rendererErrorStage: String?
    var rendererErrorStatusHex: String?
    var rendererErrorPath: String?
    var runtimeCrashEvents: [SteamGameRuntimeCrashEvent] = []
    var runtimeCrashStdoutEvidenceState: String = SteamEvidenceReadState.missing.rawValue
    var runtimeCrashStdoutEvidenceDetail: String? = nil
    var runtimeCrashStderrEvidenceState: String = SteamEvidenceReadState.missing.rawValue
    var runtimeCrashStderrEvidenceDetail: String? = nil
    var runtimeCrashDedicatedEvidenceState: String = SteamEvidenceReadState.missing.rawValue
    var runtimeCrashDedicatedEvidenceDetail: String? = nil
    var gameProcessEvidenceState: String
    var consoleEvidenceState: String
    var processObservationEvidenceState: String
    var structuredLogState = "notRequested"
    var summary: String
    var correlatedEvidence: [String]

    var executableName: String? {
        guard let executable else { return nil }
        let throughExecutableSuffix: String
        if let range = executable.range(of: ".exe", options: [.caseInsensitive]) {
            throughExecutableSuffix = String(executable[..<range.upperBound])
        } else {
            throughExecutableSuffix = executable
        }
        let component = throughExecutableSuffix
            .split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .last
            .map(String.init) ?? throughExecutableSuffix
        return component.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    var rendererObservation: SteamGameRendererObservation? {
        guard let processID = primaryProcessID,
              let executable,
              let rendererRequested,
              let rendererPolicy = SteamRendererPolicyPreference(rawValue: rendererRequested),
              let plannedOwnershipText = rendererPlannedComponentOwnership ?? rendererApplied,
              let plannedComponentOwnership = SteamGameRendererPlannedComponentOwnership(
                rawValue: plannedOwnershipText
              ),
              let actualLoadedState = SteamGameRendererActualLoadedState(
                rawValue: rendererActualLoaded ?? SteamGameRendererActualLoadedState.unobserved.rawValue
              ),
              let rendererRoutingReason,
              let rendererRoutingEvidence else {
            return nil
        }
        return SteamGameRendererObservation(
            processID: processID,
            rendererPolicy: rendererPolicy,
            plannedProfile: rendererPlannedProfile ?? plannedOwnershipText,
            plannedComponentOwnership: plannedComponentOwnership,
            plannedComponentsX64: rendererPlannedComponentsX64 ?? "unreported",
            plannedComponentsX86: rendererPlannedComponentsX86 ?? "unreported",
            actualLoadedState: actualLoadedState,
            routingReason: rendererRoutingReason,
            routingEvidence: rendererRoutingEvidence,
            correlationIdentifier: rendererCorrelationIdentifier,
            executable: executable
        )
    }
}

enum SteamGameLaunchDiagnosticAnalyzer {
    static let defaultLaunchStabilityThreshold: TimeInterval = 15

    private struct TrackedProcess {
        var processID: Int32
        var trackedCommand: String
        var executable: String
        var startedAt: Date
        var endedAt: Date?
        var exitCode: Int32?
    }

    private struct Attempt {
        var appID: String
        var startedAt: Date
        /// Monotonic source-line position of the first tracked process record.
        /// Steam timestamps have only one-second precision, so this is the
        /// authoritative ordering key when a title is relaunched immediately.
        var startedSequence: Int
        var removedAt: Date?
        var processes: [Int32: TrackedProcess]
        var processOrder: [Int32]
        var gameProcessEvidence: [String]

        var effectiveEndedAt: Date? {
            if let removedAt { return removedAt }
            guard !processes.isEmpty,
                  processes.values.allSatisfy({ $0.endedAt != nil }) else {
                return nil
            }
            return processes.values.compactMap(\.endedAt).max()
        }

        var activeProcessIDs: [Int32] {
            guard removedAt == nil else { return [] }
            return processOrder.filter { processes[$0]?.endedAt == nil }
        }
    }

    private struct CorrelatedRuntimeCrash {
        var observation: WineRuntimeCrashObservation
        var basis: String
    }

    private struct StartedProcessEvent {
        var timestamp: Date
        var appID: String
        var processID: Int32
        var trackedCommand: String
        var executable: String
    }

    private struct ExitedProcessEvent {
        var timestamp: Date
        var appID: String
        var processID: Int32
        /// `nil` means Steam stopped tracking the process without recording a
        /// Windows exit status (the `Game ... going away` log form).
        var exitCode: Int32?
    }

    private struct RemovedAppEvent {
        var timestamp: Date
        var appID: String
    }

    static func analyze(
        gameProcessLines: [String],
        consoleLines: [String],
        processObservation: SteamProcessObservationReadResult,
        runtimeCrashObservations: [WineRuntimeCrashObservation] = [],
        runtimeCrashStdoutEvidenceState: String = SteamEvidenceReadState.missing.rawValue,
        runtimeCrashStdoutEvidenceDetail: String? = nil,
        runtimeCrashStderrEvidenceState: String = SteamEvidenceReadState.missing.rawValue,
        runtimeCrashStderrEvidenceDetail: String? = nil,
        runtimeCrashDedicatedEvidenceState: String = SteamEvidenceReadState.missing.rawValue,
        runtimeCrashDedicatedEvidenceDetail: String? = nil,
        allowsSameLaunchSessionOrderFallback: Bool = false,
        since cutoff: Date? = nil,
        now: Date = Date(),
        earlyExitThreshold: TimeInterval = 15,
        launchStabilityThreshold: TimeInterval = SteamGameLaunchDiagnosticAnalyzer.defaultLaunchStabilityThreshold,
        gameProcessEvidenceState: String = SteamEvidenceReadState.captured.rawValue,
        consoleEvidenceState: String = SteamEvidenceReadState.captured.rawValue
    ) -> SteamGameLaunchDiagnostic? {
        analyzeAttempts(
            gameProcessLines: gameProcessLines,
            consoleLines: consoleLines,
            processObservation: processObservation,
            runtimeCrashObservations: runtimeCrashObservations,
            runtimeCrashStdoutEvidenceState: runtimeCrashStdoutEvidenceState,
            runtimeCrashStdoutEvidenceDetail: runtimeCrashStdoutEvidenceDetail,
            runtimeCrashStderrEvidenceState: runtimeCrashStderrEvidenceState,
            runtimeCrashStderrEvidenceDetail: runtimeCrashStderrEvidenceDetail,
            runtimeCrashDedicatedEvidenceState: runtimeCrashDedicatedEvidenceState,
            runtimeCrashDedicatedEvidenceDetail: runtimeCrashDedicatedEvidenceDetail,
            allowsSameLaunchSessionOrderFallback: allowsSameLaunchSessionOrderFallback,
            since: cutoff,
            now: now,
            earlyExitThreshold: earlyExitThreshold,
            launchStabilityThreshold: launchStabilityThreshold,
            gameProcessEvidenceState: gameProcessEvidenceState,
            consoleEvidenceState: consoleEvidenceState
        ).last
    }

    /// Returns every launch attempt retained by the bounded Steam log input in
    /// source order. Callers that only need the current UI state should keep
    /// using `analyze`; evidence persistence uses this collection so a fast
    /// retry cannot erase the failure which preceded it.
    static func analyzeAttempts(
        gameProcessLines: [String],
        consoleLines: [String],
        processObservation: SteamProcessObservationReadResult,
        runtimeCrashObservations: [WineRuntimeCrashObservation] = [],
        runtimeCrashStdoutEvidenceState: String = SteamEvidenceReadState.missing.rawValue,
        runtimeCrashStdoutEvidenceDetail: String? = nil,
        runtimeCrashStderrEvidenceState: String = SteamEvidenceReadState.missing.rawValue,
        runtimeCrashStderrEvidenceDetail: String? = nil,
        runtimeCrashDedicatedEvidenceState: String = SteamEvidenceReadState.missing.rawValue,
        runtimeCrashDedicatedEvidenceDetail: String? = nil,
        allowsSameLaunchSessionOrderFallback: Bool = false,
        since cutoff: Date? = nil,
        now: Date = Date(),
        earlyExitThreshold: TimeInterval = 15,
        launchStabilityThreshold: TimeInterval = SteamGameLaunchDiagnosticAnalyzer.defaultLaunchStabilityThreshold,
        gameProcessEvidenceState: String = SteamEvidenceReadState.captured.rawValue,
        consoleEvidenceState: String = SteamEvidenceReadState.captured.rawValue
    ) -> [SteamGameLaunchDiagnostic] {
        let attempts = parsedAttempts(from: gameProcessLines, since: cutoff)
            .sorted { $0.startedSequence < $1.startedSequence }
        if attempts.isEmpty,
           let rendererError = latestRendererErrorBeforeSteamTracking(in: processObservation) {
            return [
                rendererSetupFailureBeforeSteamTrackingDiagnostic(
                    rendererError,
                    processObservation: processObservation,
                    observedAt: now,
                    gameProcessEvidenceState: gameProcessEvidenceState,
                    consoleEvidenceState: consoleEvidenceState
                )
            ]
        }
        let correlatedCrashes = correlatedRuntimeCrashes(
            runtimeCrashObservations,
            with: attempts,
            allowsSameLaunchSessionOrderFallback: allowsSameLaunchSessionOrderFallback
        )
        return attempts.enumerated().map { index, attempt in
                analyze(
                    attempt: attempt,
                    consoleLines: consoleLines,
                    processObservation: processObservation,
                    runtimeCrashObservation: correlatedCrashes[index],
                    runtimeCrashStdoutEvidenceState: runtimeCrashStdoutEvidenceState,
                    runtimeCrashStdoutEvidenceDetail: runtimeCrashStdoutEvidenceDetail,
                    runtimeCrashStderrEvidenceState: runtimeCrashStderrEvidenceState,
                    runtimeCrashStderrEvidenceDetail: runtimeCrashStderrEvidenceDetail,
                    runtimeCrashDedicatedEvidenceState: runtimeCrashDedicatedEvidenceState,
                    runtimeCrashDedicatedEvidenceDetail: runtimeCrashDedicatedEvidenceDetail,
                    now: now,
                    earlyExitThreshold: earlyExitThreshold,
                    launchStabilityThreshold: launchStabilityThreshold,
                    gameProcessEvidenceState: gameProcessEvidenceState,
                    consoleEvidenceState: consoleEvidenceState
                )
        }
    }

    private static func analyze(
        attempt: Attempt,
        consoleLines: [String],
        processObservation: SteamProcessObservationReadResult,
        runtimeCrashObservation: CorrelatedRuntimeCrash?,
        runtimeCrashStdoutEvidenceState: String,
        runtimeCrashStdoutEvidenceDetail: String?,
        runtimeCrashStderrEvidenceState: String,
        runtimeCrashStderrEvidenceDetail: String?,
        runtimeCrashDedicatedEvidenceState: String,
        runtimeCrashDedicatedEvidenceDetail: String?,
        now: Date,
        earlyExitThreshold: TimeInterval,
        launchStabilityThreshold: TimeInterval,
        gameProcessEvidenceState: String,
        consoleEvidenceState: String
    ) -> SteamGameLaunchDiagnostic {

        let processIDs = attempt.processOrder
        let trackedCommandsByProcessID = attempt.processes.mapValues(\.trackedCommand)
        let rendererEvent = latestRendererEvent(
            in: processObservation,
            trackedCommandsByProcessID: trackedCommandsByProcessID
        )
        let rendererFallbackEvidence = correlatedRendererFallbackEvidence(
            in: processObservation,
            trackedCommandsByProcessID: trackedCommandsByProcessID
        )
        var rendererObservation: SteamGameRendererObservation? = if case .route(let route) = rendererEvent {
            route
        } else {
            nil
        }
        let rendererModuleLoads = rendererObservation.map {
            correlatedRendererModuleLoads(for: $0, in: processObservation)
        } ?? []
        let successfulRendererModuleLoads = rendererModuleLoads.filter {
            $0.state == .loaded && $0.pathOwnership == .verified
        }
        let unverifiedRendererModuleLoads = rendererModuleLoads.filter {
            $0.state == .loaded && $0.pathOwnership != .verified
        }
        let failedRendererModuleLoads = rendererModuleLoads.filter { $0.state == .failed }
        if var resolvedObservation = rendererObservation {
            if !successfulRendererModuleLoads.isEmpty {
                resolvedObservation.actualLoadedState = .loaded
            } else if !unverifiedRendererModuleLoads.isEmpty {
                resolvedObservation.actualLoadedState = .loadPathUnverified
            } else if !failedRendererModuleLoads.isEmpty {
                resolvedObservation.actualLoadedState = .loadFailed
            }
            rendererObservation = resolvedObservation
        }
        let primaryProcessID = rendererObservation?.processID ?? processIDs.first
        let executable = primaryProcessID.flatMap { attempt.processes[$0]?.executable }
            ?? rendererObservation?.executable
            ?? attempt.processOrder.compactMap { attempt.processes[$0]?.executable }.first
        let rendererError: SteamGameRendererErrorObservation? = if case .error(let error) = rendererEvent {
            error
        } else {
            nil
        }
        let endedAt = attempt.effectiveEndedAt
        let elapsed = max(0, (endedAt ?? now).timeIntervalSince(attempt.startedAt))
        let exitCodes = attempt.processes.values.reduce(into: [String: Int32]()) { result, process in
            if let exitCode = process.exitCode {
                result[String(process.processID)] = exitCode
            }
        }
        let primaryExitCode = primaryProcessID.flatMap { attempt.processes[$0]?.exitCode }
        let primaryExitStatusHex = primaryExitCode.map(statusHex)
        let failureProcessID: Int32? = {
            if let primaryProcessID,
               let primaryExitCode,
               primaryExitCode != 0 {
                return primaryProcessID
            }
            return attempt.processOrder.first {
                guard let exitCode = attempt.processes[$0]?.exitCode else { return false }
                return exitCode != 0
            }
        }()
        let failureExitCode = failureProcessID.flatMap { attempt.processes[$0]?.exitCode }
        let failureExitStatusHex = failureExitCode.map(statusHex)
        let consoleEvidence = correlatedConsoleEvidence(
            consoleLines,
            appID: attempt.appID,
            since: attempt.startedAt
        )
        let runtimeCrashEvent = runtimeCrashObservation.map {
            SteamGameRuntimeCrashEvent(
                exceptionCode: $0.observation.exceptionCode,
                exceptionStatusHex: String(format: "0x%08X", $0.observation.exceptionCode),
                threadIDHex: $0.observation.threadIDHex,
                instructionAddressHex: $0.observation.instructionAddressHex,
                windowsProcessID: $0.observation.debuggerProcessID,
                automaticBacktraceState: $0.observation.automaticBacktraceState,
                backtraceFrames: $0.observation.backtraceFrames,
                systemInformation: $0.observation.systemInformation,
                correlationBasis: $0.basis
            )
        }
        let state: SteamGameLaunchDiagnosticState
        if rendererError != nil {
            state = .rendererError
        } else if endedAt != nil, elapsed <= max(0, earlyExitThreshold) {
            state = .earlyExit
        } else if endedAt != nil, failureExitCode != nil {
            state = .exitedWithError
        } else if endedAt != nil {
            state = .exited
        } else if elapsed < max(0, launchStabilityThreshold) {
            state = .launching
        } else {
            // Steam's WaitingGameWindow/Completed tasks describe its launch
            // workflow, not host window visibility. Without independent window
            // evidence the only honest classification is running/unknown.
            state = .running
        }

        var evidence = Array(attempt.gameProcessEvidence.suffix(24))
        evidence.append(contentsOf: consoleEvidence.lines.suffix(24))
        if let rendererObservation {
            evidence.append(
                "FORGEPLAY renderer: pid=\(rendererObservation.processID); " +
                    "requested=\(rendererObservation.rendererPolicy.rawValue); " +
                    "planned-profile=\(rendererObservation.plannedProfile); " +
                    "planned-owner=\(rendererObservation.plannedComponentOwnership.rawValue); " +
                    "planned-components-x64=\(rendererObservation.plannedComponentsX64); " +
                    "planned-components-x86=\(rendererObservation.plannedComponentsX86); " +
                    "actual-loaded=\(rendererObservation.actualLoadedState.rawValue); " +
                    "reason=\(rendererObservation.routingReason); " +
                    "evidence=\(rendererObservation.routingEvidence); " +
                    "correlation=\(rendererObservation.correlationIdentifier ?? "unavailable")"
            )
        }
        evidence.append(contentsOf: rendererModuleLoads.suffix(24).map { load in
            "FORGEPLAY renderer module: pid=\(load.processID); " +
                "state=\(load.state.rawValue); module=\(load.module); " +
                "actual-path=\(load.actualPath ?? "unavailable"); " +
                "path-owner=\(load.pathOwnership.rawValue); " +
                "planned-profile=\(load.plannedProfile); " +
                "planned-owner=\(load.plannedOwner); status=\(load.statusHex); " +
                "correlation=\(load.correlationIdentifier)"
        })
        if let rendererError {
            evidence.append(
                "FORGEPLAY renderer error: pid=\(rendererError.processID); " +
                    "stage=\(rendererError.stage); status=\(rendererError.statusHex); " +
                    "path=\(rendererError.path)"
            )
        }
        evidence.append(contentsOf: rendererFallbackEvidence.suffix(24))
        if let runtimeCrashEvent {
            evidence.append(
                "FORGEPLAY Wine crash: exception=\(runtimeCrashEvent.exceptionStatusHex); " +
                    "thread=\(runtimeCrashEvent.threadIDHex ?? "unavailable"); " +
                    "address=\(runtimeCrashEvent.instructionAddressHex ?? "unavailable"); " +
                    "debugger-pid=\(runtimeCrashEvent.windowsProcessID.map(String.init) ?? "unavailable"); " +
                    "backtrace=\(runtimeCrashEvent.automaticBacktraceState.rawValue); " +
                    "correlation=\(runtimeCrashEvent.correlationBasis)"
            )
            evidence.append(contentsOf: runtimeCrashEvent.backtraceFrames.prefix(16).map {
                "FORGEPLAY Wine backtrace: \($0)"
            })
        }
        if let failureProcessID,
           failureProcessID != primaryProcessID,
           let failureExitCode,
           let failureExitStatusHex {
            evidence.append(
                "FORGEPLAY auxiliary process failure: pid=\(failureProcessID); " +
                    "exit=\(failureExitCode); status=\(failureExitStatusHex)"
            )
        }

        return SteamGameLaunchDiagnostic(
            state: state,
            appID: attempt.appID,
            primaryProcessID: primaryProcessID,
            trackedProcessIDs: processIDs,
            activeProcessIDs: attempt.activeProcessIDs,
            executable: rendererObservation?.executable ?? executable,
            startedAt: attempt.startedAt,
            endedAt: endedAt,
            observedAt: now,
            elapsedSeconds: elapsed,
            exitCodesByProcessID: exitCodes,
            primaryExitCode: primaryExitCode,
            primaryExitStatusHex: primaryExitStatusHex,
            failureProcessID: failureProcessID,
            failureExitCode: failureExitCode,
            failureExitStatusHex: failureExitStatusHex,
            consoleLastTask: consoleEvidence.lastTask,
            rendererRequested: rendererObservation?.rendererPolicy.rawValue,
            rendererApplied: nil,
            rendererPlannedProfile: rendererObservation?.plannedProfile,
            rendererPlannedComponentOwnership: rendererObservation?
                .plannedComponentOwnership.rawValue,
            rendererPlannedComponentsX64: rendererObservation?.plannedComponentsX64,
            rendererPlannedComponentsX86: rendererObservation?.plannedComponentsX86,
            rendererActualLoaded: rendererObservation?.actualLoadedState.rawValue,
            rendererLoadedModules: successfulRendererModuleLoads.isEmpty
                ? nil
                : successfulRendererModuleLoads.map(\.module),
            rendererLoadedModulePaths: successfulRendererModuleLoads.isEmpty
                ? nil
                : successfulRendererModuleLoads.compactMap(\.actualPath),
            rendererModuleLoadFailures: failedRendererModuleLoads.isEmpty &&
                unverifiedRendererModuleLoads.isEmpty
                ? nil
                : failedRendererModuleLoads.map {
                    "\($0.module)=\($0.statusHex)"
                } + unverifiedRendererModuleLoads.map {
                    "\($0.module)=load-path-\($0.pathOwnership.rawValue):" +
                        "\($0.actualPath ?? "unavailable")"
                },
            rendererRoutingReason: rendererObservation?.routingReason,
            rendererRoutingEvidence: rendererObservation?.routingEvidence,
            rendererCorrelationIdentifier: rendererObservation?.correlationIdentifier,
            rendererErrorStage: rendererError?.stage,
            rendererErrorStatusHex: rendererError?.statusHex,
            rendererErrorPath: rendererError?.path,
            runtimeCrashEvents: runtimeCrashEvent.map { [$0] } ?? [],
            runtimeCrashStdoutEvidenceState: runtimeCrashStdoutEvidenceState,
            runtimeCrashStdoutEvidenceDetail: runtimeCrashStdoutEvidenceDetail,
            runtimeCrashStderrEvidenceState: runtimeCrashStderrEvidenceState,
            runtimeCrashStderrEvidenceDetail: runtimeCrashStderrEvidenceDetail,
            runtimeCrashDedicatedEvidenceState: runtimeCrashDedicatedEvidenceState,
            runtimeCrashDedicatedEvidenceDetail: runtimeCrashDedicatedEvidenceDetail,
            gameProcessEvidenceState: gameProcessEvidenceState,
            consoleEvidenceState: consoleEvidenceState,
            processObservationEvidenceState: processObservation.state.rawValue,
            summary: summary(
                state: state,
                elapsed: elapsed,
                primaryExitCode: primaryExitCode,
                primaryExitStatusHex: primaryExitStatusHex,
                failureProcessID: failureProcessID,
                failureExitCode: failureExitCode,
                failureExitStatusHex: failureExitStatusHex,
                consoleLastTask: consoleEvidence.lastTask,
                rendererError: rendererError,
                runtimeCrashEvent: runtimeCrashEvent
            ),
            correlatedEvidence: Array(evidence.suffix(64))
        )
    }

    private static func correlatedRuntimeCrashes(
        _ observations: [WineRuntimeCrashObservation],
        with attempts: [Attempt],
        allowsSameLaunchSessionOrderFallback: Bool
    ) -> [CorrelatedRuntimeCrash?] {
        var result = [CorrelatedRuntimeCrash?](repeating: nil, count: attempts.count)
        var unusedIndices = Set(observations.indices)

        func orderedUnusedObservationIndices() -> [Int] {
            unusedIndices.sorted {
                let lhsSequence = observations[$0].sourceSequence
                let rhsSequence = observations[$1].sourceSequence
                if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
                return $0 > $1
            }
        }

        func exitStatuses(for attempt: Attempt) -> Set<UInt32> {
            Set(attempt.processes.values.compactMap { process -> UInt32? in
                guard let exitCode = process.exitCode, exitCode != 0 else { return nil }
                return UInt32(bitPattern: exitCode)
            })
        }

        func assign(_ observationIndex: Int, to attemptIndex: Int, basis: String) {
            result[attemptIndex] = CorrelatedRuntimeCrash(
                observation: observations[observationIndex],
                basis: basis
            )
            unusedIndices.remove(observationIndex)
        }

        // Strongest correlation: WineDbg's attached target PID and Steam's raw
        // Windows status both identify the same attempt.
        for attemptIndex in attempts.indices.reversed() where result[attemptIndex] == nil {
            let attempt = attempts[attemptIndex]
            let processIDs = Set(attempt.processOrder)
            let statuses = exitStatuses(for: attempt)
            guard let selectedIndex = orderedUnusedObservationIndices().first(where: {
                guard let processID = observations[$0].debuggerProcessID else { return false }
                return processIDs.contains(processID) && statuses.contains(observations[$0].exceptionCode)
            }) else { continue }
            assign(selectedIndex, to: attemptIndex, basis: "windowsProcessIDAndExitStatus")
        }

        // Steam can normalize an unhandled Windows exception to exit code 1.
        // The attached target PID remains stronger evidence than that normalized
        // status, and unlike order fallback it does not depend on timing.
        for attemptIndex in attempts.indices.reversed() where result[attemptIndex] == nil {
            let processIDs = Set(attempts[attemptIndex].processOrder)
            guard let selectedIndex = orderedUnusedObservationIndices().first(where: {
                guard let processID = observations[$0].debuggerProcessID else { return false }
                return processIDs.contains(processID)
            }) else { continue }
            assign(
                selectedIndex,
                to: attemptIndex,
                basis: "windowsProcessIDWithSteamNormalizedExitStatus"
            )
        }

        // Older Wine stderr evidence may not include a target PID. Preserve the
        // previous status correlation before considering any ordering heuristic.
        for attemptIndex in attempts.indices.reversed() where result[attemptIndex] == nil {
            let statuses = exitStatuses(for: attempts[attemptIndex])
            guard let selectedIndex = orderedUnusedObservationIndices().first(where: {
                observations[$0].debuggerProcessID == nil &&
                    statuses.contains(observations[$0].exceptionCode)
            }) else { continue }
            assign(
                selectedIndex,
                to: attemptIndex,
                basis: "matchingExitStatusAndReverseSourceOrder"
            )
        }

        // Raw `wine: Unhandled exception` lines carry no process ID, and Steam
        // sometimes records only exit 1. A final positional fallback is allowed
        // solely when the caller proved every input belongs to one managed Steam
        // launch. It is one-to-one, newest-to-newest, terminal-attempt-only and
        // bounded so retries cannot reuse or spread one crash across attempts.
        guard allowsSameLaunchSessionOrderFallback else { return result }
        let maximumFallbackCorrelations = 16
        let fallbackAttempts = attempts.indices.reversed().filter { attemptIndex in
            result[attemptIndex] == nil &&
                attempts[attemptIndex].effectiveEndedAt != nil &&
                !exitStatuses(for: attempts[attemptIndex]).isEmpty
        }.prefix(maximumFallbackCorrelations)
        let fallbackObservations = orderedUnusedObservationIndices().filter {
            observations[$0].debuggerProcessID == nil
        }.prefix(maximumFallbackCorrelations)
        for (attemptIndex, observationIndex) in zip(fallbackAttempts, fallbackObservations) {
            assign(
                observationIndex,
                to: attemptIndex,
                basis: "boundedOneToOneReverseSteamLaunchSessionOrderAfterStatusMismatch"
            )
        }
        return result
    }

    private static func parsedAttempts(
        from lines: [String],
        since cutoff: Date?
    ) -> [Attempt] {
        var activeAttempts: [String: Attempt] = [:]
        var completedAttempts: [Attempt] = []

        for (lineSequence, line) in lines.enumerated() {
            if let event = parseStartedProcess(line), cutoff.map({ event.timestamp < $0 }) != true {
                if let existing = activeAttempts[event.appID],
                   existing.effectiveEndedAt != nil {
                    completedAttempts.append(existing)
                    activeAttempts.removeValue(forKey: event.appID)
                }
                var attempt = activeAttempts[event.appID] ?? Attempt(
                    appID: event.appID,
                    startedAt: event.timestamp,
                    startedSequence: lineSequence,
                    removedAt: nil,
                    processes: [:],
                    processOrder: [],
                    gameProcessEvidence: []
                )
                if attempt.processes[event.processID] == nil {
                    attempt.processOrder.append(event.processID)
                }
                attempt.processes[event.processID] = TrackedProcess(
                    processID: event.processID,
                    trackedCommand: event.trackedCommand,
                    executable: event.executable,
                    startedAt: event.timestamp,
                    endedAt: nil,
                    exitCode: nil
                )
                attempt.gameProcessEvidence.append(line)
                activeAttempts[event.appID] = attempt
                continue
            }

            if let event = parseExitedProcess(line), cutoff.map({ event.timestamp < $0 }) != true,
               var attempt = activeAttempts[event.appID] {
                if var process = attempt.processes[event.processID] {
                    process.endedAt = event.timestamp
                    process.exitCode = event.exitCode
                    attempt.processes[event.processID] = process
                }
                attempt.gameProcessEvidence.append(line)
                activeAttempts[event.appID] = attempt
                continue
            }

            if let event = parseRemovedApp(line), cutoff.map({ event.timestamp < $0 }) != true,
               var attempt = activeAttempts.removeValue(forKey: event.appID) {
                attempt.removedAt = event.timestamp
                attempt.gameProcessEvidence.append(line)
                completedAttempts.append(attempt)
            }
        }
        completedAttempts.append(contentsOf: activeAttempts.values)
        return completedAttempts
    }

    private static func parseStartedProcess(_ line: String) -> StartedProcessEvent? {
        guard let parsed = timestampAndBody(in: line),
              let appAndRest = split(parsed.body, prefix: "AppID ", marker: " adding PID "),
              isDecimal(appAndRest.head),
              let processAndRest = split(appAndRest.tail, prefix: "", marker: " as a tracked process "),
              let processID = validatedProcessID(processAndRest.head),
              !processAndRest.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let executable = trackedProcessExecutable(in: processAndRest.tail) else {
            return nil
        }
        return StartedProcessEvent(
            timestamp: parsed.timestamp,
            appID: appAndRest.head,
            processID: processID,
            trackedCommand: processAndRest.tail,
            executable: executable
        )
    }

    /// Steam wraps the tracked Windows command line in an additional pair of
    /// quotes. For example, a Source-engine launch is recorded as
    /// `""G:\...\hl2.exe" -steam -game hl2_complete"`. Renderer evidence
    /// contains only the executable image path, so retain the first Windows
    /// command-line argument rather than the complete command line. This keeps
    /// renderer correlation bound to PID plus an exact normalized image path.
    private static func trackedProcessExecutable(in trackedCommand: String) -> String? {
        guard let commandLine = trackedCommandBody(trackedCommand) else { return nil }

        // Some Steam builds quote the complete field instead of quoting argv[0]
        // inside that field. In that form a path containing spaces has no
        // syntactic separator before its arguments, but the executable suffix
        // still provides an unambiguous boundary. Exact renderer correlation
        // continues to use the preserved raw command below.
        if commandLine.first != "\"",
           let executable = unquotedWindowsExecutablePathPrefix(in: commandLine) {
            return executable
        }

        var executable = ""
        var isInsideQuotes = false
        var index = commandLine.startIndex
        while index < commandLine.endIndex {
            let character = commandLine[index]
            if character == "\"" {
                isInsideQuotes.toggle()
            } else if character.isWhitespace, !isInsideQuotes {
                break
            } else {
                executable.append(character)
            }
            index = commandLine.index(after: index)
        }

        let result = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func unquotedWindowsExecutablePathPrefix(in commandLine: String) -> String? {
        var searchStart = commandLine.startIndex
        while searchStart < commandLine.endIndex,
              let suffix = commandLine.range(
                of: ".exe",
                options: [.caseInsensitive],
                range: searchStart..<commandLine.endIndex
              ) {
            let boundary = suffix.upperBound
            if boundary == commandLine.endIndex ||
                commandLine[boundary] == "\"" ||
                commandLine[boundary].isWhitespace {
                let result = commandLine[..<boundary]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }
            searchStart = suffix.upperBound
        }
        return nil
    }

    /// Removes Steam's outer field quotes but intentionally preserves an inner
    /// executable quote. A single outer pair may wrap the complete command
    /// (`"G:\...\SB.exe -DistributionPlatform=Steam"`), while Source games
    /// commonly use an outer pair around an already quoted argv[0].
    private static func trackedCommandBody(_ trackedCommand: String) -> String? {
        var commandLine = trackedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandLine.isEmpty else { return nil }
        if commandLine.first == "\"", commandLine.last == "\"", commandLine.count >= 2 {
            commandLine.removeFirst()
            commandLine.removeLast()
            commandLine = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return commandLine.isEmpty ? nil : commandLine
    }

    private static func parseExitedProcess(_ line: String) -> ExitedProcessEvent? {
        guard let parsed = timestampAndBody(in: line) else { return nil }
        if let appAndRest = split(parsed.body, prefix: "AppID ", marker: " no longer tracking PID "),
           isDecimal(appAndRest.head),
           let processAndRest = split(appAndRest.tail, prefix: "", marker: ", exit code "),
           let processID = validatedProcessID(processAndRest.head),
           let exitCode = Int32(processAndRest.tail) {
            return ExitedProcessEvent(
                timestamp: parsed.timestamp,
                appID: appAndRest.head,
                processID: processID,
                exitCode: exitCode
            )
        }
        guard let appAndRest = split(parsed.body, prefix: "Game ", marker: " going away; no longer tracking PID "),
              isDecimal(appAndRest.head),
              let processID = validatedProcessID(appAndRest.tail) else {
            return nil
        }
        return ExitedProcessEvent(
            timestamp: parsed.timestamp,
            appID: appAndRest.head,
            processID: processID,
            exitCode: nil
        )
    }

    private static func parseRemovedApp(_ line: String) -> RemovedAppEvent? {
        guard let parsed = timestampAndBody(in: line),
              let appAndRest = split(parsed.body, prefix: "Remove ", marker: " from running list"),
              appAndRest.tail.isEmpty,
              isDecimal(appAndRest.head) else {
            return nil
        }
        return RemovedAppEvent(timestamp: parsed.timestamp, appID: appAndRest.head)
    }

    private static func correlatedConsoleEvidence(
        _ lines: [String],
        appID: String,
        since cutoff: Date
    ) -> (lines: [String], lastTask: String?) {
        let appMarker = "AppID \(appID)"
        var evidence: [String] = []
        var lastTask: String?
        for line in lines {
            guard let parsed = timestampAndBody(in: line), parsed.timestamp >= cutoff,
                  parsed.body.localizedCaseInsensitiveContains(appMarker) else {
                continue
            }
            evidence.append(line)
            let actionMarker = "GameAction [AppID \(appID),"
            guard parsed.body.hasPrefix(actionMarker),
                  let taskRange = parsed.body.range(of: "changed task to ") else {
                continue
            }
            let taskAndRest = String(parsed.body[taskRange.upperBound...])
            lastTask = taskAndRest.components(separatedBy: " with ").first
        }
        return (Array(evidence.suffix(24)), lastTask)
    }

    private static func rendererSetupFailureBeforeSteamTrackingDiagnostic(
        _ error: SteamGameRendererErrorObservation,
        processObservation: SteamProcessObservationReadResult,
        observedAt: Date,
        gameProcessEvidenceState: String,
        consoleEvidenceState: String
    ) -> SteamGameLaunchDiagnostic {
        SteamGameLaunchDiagnostic(
            state: .rendererError,
            appID: nil,
            primaryProcessID: nil,
            trackedProcessIDs: [],
            activeProcessIDs: [],
            executable: error.path,
            startedAt: nil,
            endedAt: nil,
            observedAt: observedAt,
            elapsedSeconds: nil,
            exitCodesByProcessID: [:],
            primaryExitCode: nil,
            primaryExitStatusHex: nil,
            failureProcessID: nil,
            failureExitCode: nil,
            failureExitStatusHex: nil,
            consoleLastTask: nil,
            rendererRequested: nil,
            rendererApplied: nil,
            rendererPlannedProfile: nil,
            rendererPlannedComponentOwnership: nil,
            rendererPlannedComponentsX64: nil,
            rendererPlannedComponentsX86: nil,
            rendererActualLoaded: nil,
            rendererRoutingReason: nil,
            rendererRoutingEvidence: nil,
            rendererCorrelationIdentifier: nil,
            rendererErrorStage: error.stage,
            rendererErrorStatusHex: error.statusHex,
            rendererErrorPath: error.path,
            gameProcessEvidenceState: gameProcessEvidenceState,
            consoleEvidenceState: consoleEvidenceState,
            processObservationEvidenceState: processObservation.state.rawValue,
            summary: "Renderer setup failed at \(error.stage) with status \(error.statusHex).",
            correlatedEvidence: [
                "FORGEPLAY renderer error before Steam tracking: emitter-pid=\(error.processID); " +
                    "stage=\(error.stage); " +
                    "status=\(error.statusHex); path=\(error.path)"
            ]
        )
    }

    /// A renderer child can fail while Wine is preparing its environment,
    /// before Steam has a PID to record in `gameprocess_log.txt`. Preserve the
    /// newest such failure, but do not revive an older error when a later
    /// renderer route record shows that child setup subsequently progressed.
    private static func latestRendererErrorBeforeSteamTracking(
        in observation: SteamProcessObservationReadResult
    ) -> SteamGameRendererErrorObservation? {
        guard let latestError = observation.gameRendererErrors.max(by: {
            $0.recordSequence < $1.recordSequence
        }) else {
            return nil
        }
        let latestRouteSequence = observation.gameRendererObservations
            .map(\.recordSequence)
            .max()
        if let latestRouteSequence,
           latestError.recordSequence <= latestRouteSequence {
            return nil
        }
        return latestError
    }

    private static func summary(
        state: SteamGameLaunchDiagnosticState,
        elapsed: TimeInterval,
        primaryExitCode: Int32?,
        primaryExitStatusHex: String?,
        failureProcessID: Int32?,
        failureExitCode: Int32?,
        failureExitStatusHex: String?,
        consoleLastTask: String?,
        rendererError: SteamGameRendererErrorObservation?,
        runtimeCrashEvent: SteamGameRuntimeCrashEvent?
    ) -> String {
        let seconds = String(format: "%.1f", elapsed)
        if let runtimeCrashEvent {
            let backtrace = runtimeCrashEvent.automaticBacktraceState == .captured
                ? " Automatic Wine backtrace captured."
                : " Automatic Wine backtrace was not captured."
            return "The game terminated after \(seconds) seconds with unhandled exception " +
                "\(runtimeCrashEvent.exceptionStatusHex).\(backtrace)"
        }
        switch state {
        case .rendererError:
            guard let rendererError else { return "The game renderer setup failed." }
            return "Renderer setup failed at \(rendererError.stage) with status \(rendererError.statusHex)."
        case .earlyExit:
            let exit = (failureExitCode ?? primaryExitCode).map(String.init) ?? "unavailable"
            let hex = (failureExitStatusHex ?? primaryExitStatusHex).map { " (\($0))" } ?? ""
            return "Steam stopped tracking the game after \(seconds) seconds; reported exit code \(exit)\(hex)."
        case .exitedWithError:
            let exit = failureExitCode.map(String.init) ?? "unavailable"
            let hex = failureExitStatusHex.map { " (\($0))" } ?? ""
            let process = failureProcessID.map { " in PID \($0)" } ?? ""
            return "The game launch exited after \(seconds) seconds with code \(exit)\(hex)\(process)."
        case .exited:
            return "Steam stopped tracking the game after \(seconds) seconds without a recorded nonzero exit code."
        case .runningHeadless:
            let task = consoleLastTask.map { "; last Steam launch task=\($0)" } ?? ""
            return "Steam still tracks the game after \(seconds) seconds and is still waiting for a game window\(task)."
        case .running:
            return "Steam still tracks the game after \(seconds) seconds; window state is not available from the captured logs."
        case .launching:
            return "Steam began tracking the game \(seconds) seconds ago; waiting for a stable launch outcome."
        }
    }

    private static func statusHex(_ code: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }

    private enum RendererEvent {
        case route(SteamGameRendererObservation)
        case error(SteamGameRendererErrorObservation)

        var recordSequence: Int {
            switch self {
            case .route(let route): route.recordSequence
            case .error(let error): error.recordSequence
            }
        }
    }

    private enum RendererEvidenceRank: Int {
        case ambiguousOrNoStaticEvidence = 1
        case errorOrRejectedLoad = 2
        case specificDirect3DImport = 3
        case verifiedActualLoad = 4
    }

    private struct RendererEventCandidate {
        var event: RendererEvent
        /// Evidence strength is authoritative. Source order may break a tie,
        /// but a late helper/launcher route with no generation evidence must
        /// not hide an earlier API-specific route for the actual game.
        var evidenceRank: RendererEvidenceRank
        /// DLL-only loader errors can be written immediately before their
        /// parent writes the matching route after resuming the child. Anchor
        /// those errors to the later position of the pair so the error wins
        /// regardless of which process appended its record first.
        var correlationSequence: Int
        var prefersErrorAtSameSequence: Bool
    }

    /// Bind loader evidence to one exact route. PID alone is insufficient
    /// because Wine PIDs can be reused; the executable path, selected profile,
    /// owner, and launch correlation token must agree as well. If two route
    /// records are equally close, the load is intentionally left unassigned.
    private static func correlatedRendererModuleLoads(
        for route: SteamGameRendererObservation,
        in observation: SteamProcessObservationReadResult
    ) -> [SteamGameRendererModuleLoadObservation] {
        guard let normalizedRouteExecutable = normalizedWindowsPath(route.executable) else {
            return []
        }
        let sameProcessRoutes = observation.gameRendererObservations.filter {
            $0.processID == route.processID &&
                $0.plannedProfile == route.plannedProfile &&
                $0.plannedComponentOwnership == route.plannedComponentOwnership &&
                normalizedWindowsPath($0.executable) == normalizedRouteExecutable &&
                (route.correlationIdentifier == nil ||
                    $0.correlationIdentifier == route.correlationIdentifier)
        }

        return observation.gameRendererModuleLoads.filter { load in
            guard load.processID == route.processID,
                  load.plannedProfile == route.plannedProfile,
                  load.plannedOwner == route.plannedComponentOwnership.rawValue,
                  normalizedWindowsPath(load.executable) == normalizedRouteExecutable,
                  route.correlationIdentifier == nil ||
                    load.correlationIdentifier == route.correlationIdentifier else {
                return false
            }
            let distances = sameProcessRoutes.map {
                abs($0.recordSequence - load.recordSequence)
            }
            guard let nearestDistance = distances.min() else { return false }
            let nearestRoutes = sameProcessRoutes.filter {
                abs($0.recordSequence - load.recordSequence) == nearestDistance
            }
            return nearestRoutes.count == 1 &&
                nearestRoutes[0].recordSequence == route.recordSequence
        }
        .sorted { $0.recordSequence < $1.recordSequence }
    }

    /// Select one canonical renderer event for the attempt. A tracked PID is
    /// necessary but not sufficient: its own full executable image path must
    /// also match so a reused Wine PID cannot import a renderer event from
    /// another game. Basename matching is intentionally unsupported.
    private static func latestRendererEvent(
        in observation: SteamProcessObservationReadResult,
        trackedCommandsByProcessID: [Int32: String]
    ) -> RendererEvent? {
        var candidates: [RendererEventCandidate] = []
        let routesByProcessID = Dictionary(
            grouping: observation.gameRendererObservations,
            by: \.processID
        )
        candidates.reserveCapacity(
            observation.gameRendererObservations.count + observation.gameRendererErrors.count
        )
        for route in observation.gameRendererObservations {
            guard let trackedCommand = trackedCommandsByProcessID[route.processID],
                  self.trackedCommand(
                    trackedCommand,
                    matchesExecutable: route.executable
                  ) else {
                continue
            }
            candidates.append(RendererEventCandidate(
                event: .route(route),
                evidenceRank: rendererEvidenceRank(
                    for: route,
                    in: observation
                ),
                correlationSequence: route.recordSequence,
                prefersErrorAtSameSequence: false
            ))
        }
        for error in observation.gameRendererErrors {
            guard let correlationSequence = rendererErrorCorrelationSequence(
                error,
                trackedCommandsByProcessID: trackedCommandsByProcessID,
                routesByProcessID: routesByProcessID
            ) else {
                continue
            }
            candidates.append(RendererEventCandidate(
                event: .error(error),
                evidenceRank: rendererEvidenceRank(for: error),
                correlationSequence: correlationSequence,
                prefersErrorAtSameSequence: true
            ))
        }
        return candidates.max { lhs, rhs in
            if lhs.evidenceRank != rhs.evidenceRank {
                return lhs.evidenceRank.rawValue < rhs.evidenceRank.rawValue
            }
            if lhs.correlationSequence != rhs.correlationSequence {
                return lhs.correlationSequence < rhs.correlationSequence
            }
            if lhs.prefersErrorAtSameSequence != rhs.prefersErrorAtSameSequence {
                return !lhs.prefersErrorAtSameSequence
            }
            return lhs.event.recordSequence < rhs.event.recordSequence
        }?.event
    }

    /// A loader/module-load failure is evidence about the selected renderer at
    /// least as strong as the route's static import scan. Giving both the same
    /// rank lets the correlation sequence and error tie-breaker preserve a
    /// failure written immediately before or after its matching route. Earlier
    /// parent setup failures remain weaker so a later successful route for the
    /// same process can supersede them.
    private static func rendererEvidenceRank(
        for error: SteamGameRendererErrorObservation
    ) -> RendererEvidenceRank {
        let stage = error.stage.lowercased()
        if stage.contains("loader") || stage.contains("module-load") {
            return .specificDirect3DImport
        }
        return .errorOrRejectedLoad
    }

    /// A fallback is emitted by the parent creating the child, so its PID is
    /// not necessarily one of Steam's tracked game PIDs. Correlate it through
    /// the exact executable path and use same-emitter record order only to
    /// attach the environment-operation failures that led to that fallback.
    /// This evidence is diagnostic context, not a fatal renderer event: the
    /// fallback contract explicitly continued Win32 process creation.
    private static func correlatedRendererFallbackEvidence(
        in observation: SteamProcessObservationReadResult,
        trackedCommandsByProcessID: [Int32: String]
    ) -> [String] {
        struct EvidenceLine {
            var recordSequence: Int
            var detailOrder: Int
            var line: String
        }

        let matchingFallbacks = observation.gameRendererFallbacks.filter { fallback in
            trackedCommandsByProcessID.values.contains { trackedCommand in
                self.trackedCommand(trackedCommand, matchesExecutable: fallback.path)
            }
        }
        guard !matchingFallbacks.isEmpty else { return [] }

        var evidence: [EvidenceLine] = []
        for fallback in matchingFallbacks {
            let previousFallbackSequence = observation.gameRendererFallbacks
                .lazy
                .filter {
                    $0.processID == fallback.processID &&
                        $0.recordSequence < fallback.recordSequence
                }
                .map(\.recordSequence)
                .max() ?? -1
            for failure in observation.gameRendererEnvironmentFailures where
                failure.processID == fallback.processID &&
                failure.recordSequence > previousFallbackSequence &&
                failure.recordSequence <= fallback.recordSequence {
                evidence.append(EvidenceLine(
                    recordSequence: failure.recordSequence,
                    detailOrder: 0,
                    line: "FORGEPLAY renderer environment failure: " +
                        "emitter-pid=\(failure.processID); operation=\(failure.operation); " +
                        "source=\(failure.sourceVariable); target=\(failure.targetVariable); " +
                        "status=\(failure.statusHex)"
                ))
            }
            evidence.append(EvidenceLine(
                recordSequence: fallback.recordSequence,
                detailOrder: 1,
                line: "FORGEPLAY renderer fallback: emitter-pid=\(fallback.processID); " +
                    "stage=\(fallback.stage); status=\(fallback.statusHex); " +
                    "result=\(fallback.result); path=\(fallback.path)"
            ))
        }
        return evidence.sorted {
            if $0.recordSequence != $1.recordSequence {
                return $0.recordSequence < $1.recordSequence
            }
            return $0.detailOrder < $1.detailOrder
        }.map(\.line)
    }

    private static func rendererEvidenceRank(
        for route: SteamGameRendererObservation,
        in observation: SteamProcessObservationReadResult
    ) -> RendererEvidenceRank {
        let moduleLoads = correlatedRendererModuleLoads(for: route, in: observation)
        if moduleLoads.contains(where: {
            $0.state == .loaded && $0.pathOwnership == .verified
        }) {
            return .verifiedActualLoad
        }
        if hasSpecificDirect3DImportEvidence(route.routingEvidence) {
            return .specificDirect3DImport
        }
        if route.actualLoadedState == .loadFailed ||
            route.actualLoadedState == .loadPathUnverified ||
            moduleLoads.contains(where: {
                $0.state == .failed ||
                    ($0.state == .loaded && $0.pathOwnership != .verified)
            }) {
            return .errorOrRejectedLoad
        }
        return .ambiguousOrNoStaticEvidence
    }

    private static func hasSpecificDirect3DImportEvidence(_ evidence: String) -> Bool {
        let generationTokens = [
            "d3d8", "d3d9", "d3d10", "d3d11", "d3d12",
            "dx8", "dx9", "dx10", "dx11", "dx12", "dxgi"
        ]
        return evidence.split(separator: ";").contains { component in
            let normalized = component
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalized.hasPrefix("import=") ||
                    normalized.hasPrefix("delay-import=") else {
                return false
            }
            guard let separator = normalized.firstIndex(of: "=") else {
                return false
            }
            let module = normalized[normalized.index(after: separator)...]
            return generationTokens.contains { module.contains($0) }
        }
    }

    private static func rendererErrorCorrelationSequence(
        _ error: SteamGameRendererErrorObservation,
        trackedCommandsByProcessID: [Int32: String],
        routesByProcessID: [Int32: [SteamGameRendererObservation]]
    ) -> Int? {
        guard let trackedCommand = trackedCommandsByProcessID[error.processID] else {
            return nil
        }
        guard let normalizedPath = normalizedWindowsPath(error.path) else { return nil }
        // Child-environment failures carry the game executable and must match
        // exactly. Loader failures may only carry the DLL path, so PID remains
        // only one part of the correlation boundary for those records.
        if normalizedPath.hasSuffix(".exe") {
            return self.trackedCommand(trackedCommand, matchesExecutable: error.path)
                ? error.recordSequence
                : nil
        }

        // The parent resumes the child before appending its route observation,
        // so a child loader error can legitimately appear on either side of
        // that route. Select the nearest same-PID route in both directions and
        // require every equally-near route to identify this exact executable.
        // A tie across different full paths is a PID-reuse boundary and must
        // remain uncorrelated. Setup failures with no route remain available
        // through the no-attempt diagnostic path.
        guard let routes = routesByProcessID[error.processID], !routes.isEmpty else {
            return nil
        }
        let routeDistances = routes.map { route in
            let distance = route.recordSequence >= error.recordSequence
                ? route.recordSequence - error.recordSequence
                : error.recordSequence - route.recordSequence
            return (route: route, distance: distance)
        }
        guard let nearestDistance = routeDistances.map(\.distance).min() else {
            return nil
        }
        let nearestRoutes = routeDistances
            .filter { $0.distance == nearestDistance }
            .map(\.route)
        guard nearestRoutes.allSatisfy({ route in
            self.trackedCommand(trackedCommand, matchesExecutable: route.executable)
        }) else {
            return nil
        }
        let routeSequence = nearestRoutes.map(\.recordSequence).max() ?? error.recordSequence
        return max(error.recordSequence, routeSequence)
    }

    /// Correlates a renderer image path with the raw Steam tracked command.
    /// Steam's outer quote is not necessarily an argv[0] quote, so matching is
    /// performed against the exact normalized path prefix and then requires an
    /// executable boundary. This supports both Steam quote forms without ever
    /// falling back to a basename.
    private static func trackedCommand(
        _ trackedCommand: String,
        matchesExecutable executable: String
    ) -> Bool {
        guard var command = trackedCommandBody(trackedCommand),
              let normalizedExecutable = normalizedWindowsPath(executable) else {
            return false
        }
        if command.first == "\"" {
            command.removeFirst()
        }
        command = command.replacingOccurrences(of: "/", with: "\\").lowercased()
        while command.contains("\\\\") {
            command = command.replacingOccurrences(of: "\\\\", with: "\\")
        }
        guard command.hasPrefix(normalizedExecutable) else { return false }

        var remainder = command.dropFirst(normalizedExecutable.count)
        if remainder.first == "\"" {
            remainder.removeFirst()
        }
        return remainder.isEmpty || remainder.first?.isWhitespace == true
    }

    private static func normalizedWindowsPath(_ value: String) -> String? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.count >= 2, normalized.first == "\"", normalized.last == "\"" {
            normalized.removeFirst()
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized.isEmpty else { return nil }
        normalized = normalized.replacingOccurrences(of: "/", with: "\\")
        while normalized.contains("\\\\") {
            normalized = normalized.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return normalized.lowercased()
    }

    private static func timestampAndBody(in line: String) -> (timestamp: Date, body: String)? {
        guard line.count >= 22,
              line.first == "[",
              let closingBracket = line.firstIndex(of: "]"),
              line.distance(from: line.startIndex, to: closingBracket) == 20 else {
            return nil
        }
        let timestampStart = line.index(after: line.startIndex)
        let timestampText = String(line[timestampStart..<closingBracket])
        let components = timestampText.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
        guard components.count == 6,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              let hour = Int(components[3]),
              let minute = Int(components[4]),
              let second = Int(components[5]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        guard let timestamp = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) else {
            return nil
        }
        let bodyStart = line.index(after: closingBracket)
        let body = line[bodyStart...].trimmingCharacters(in: .whitespaces)
        return (timestamp, body)
    }

    private static func split(
        _ value: String,
        prefix: String,
        marker: String
    ) -> (head: String, tail: String)? {
        guard value.hasPrefix(prefix) else { return nil }
        let remainder = String(value.dropFirst(prefix.count))
        guard let markerRange = remainder.range(of: marker) else { return nil }
        return (
            String(remainder[..<markerRange.lowerBound]),
            String(remainder[markerRange.upperBound...])
        )
    }

    private static func isDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }

    private static func validatedProcessID(_ value: String) -> Int32? {
        guard isDecimal(value),
              let unsigned = UInt32(value),
              unsigned > 0,
              unsigned <= UInt32(Int32.max) else {
            return nil
        }
        return Int32(unsigned)
    }
}

struct SteamLaunchProcessSnapshot: Sendable, Hashable {
    var processes: [SteamLaunchObservedProcess]
    var processObservationReadState: SteamProcessObservationReadState = .complete
    var processObservationReadIssues: [SteamProcessObservationReadIssue] = []

    var processObservationDiagnosticWarning: String? {
        guard processObservationReadState != .complete else { return nil }
        let issueSummary = processObservationReadIssues
            .map(\.diagnosticDescription)
            .joined(separator: " | ")
        return "Process observation read state=\(processObservationReadState.rawValue); \(issueSummary)"
    }

    var processIdentifiers: Set<SteamLaunchProcessIdentifier> {
        Set(processes.map(\.identifier))
    }

    var hostMacOSSteamProcesses: [MacOSSteamProcess] {
        processes.compactMap { process in
            guard MacOSSteamProcessSnapshot.isMacOSSteamCommand(process.command) else {
                return nil
            }
            return MacOSSteamProcess(processID: process.processID, command: process.command)
        }
    }

    var externalApplicationRunnerProcesses: [SteamLaunchObservedProcess] {
        processes.filter { Self.isExternalApplicationRunnerCommand($0.command) }
    }

    var containsWindowsSteamProcess: Bool {
        processes.contains { process in
            let command = Self.normalizedCommand(process.command)
            return command.contains("steam.exe") || command.contains("steamwebhelper.exe")
        }
    }

    static func current() -> SteamLaunchProcessSnapshot {
        let snapshot = DarwinProcessSnapshotReader.current()
        return SteamLaunchProcessSnapshot(
            processes: snapshot.processes,
            processObservationReadState: snapshot.state,
            processObservationReadIssues: snapshot.issues
        )
    }

    static func sameRunLaunchEvidence(
        for result: ProcessRunResult,
        target: SteamLaunchTarget,
        fileManager: FileManager = .default
    ) -> SteamLaunchProcessSnapshot {
        guard result.succeeded else {
            return SteamLaunchProcessSnapshot(processes: [])
        }

        let observationRead = SteamProcessCreationObservationLog.read(
            at: result.processObservationLog,
            fileManager: fileManager
        )
        var evidence = observationRead.processes
        if !result.waitedForExit,
           let processIdentifier = result.processIdentifier,
           processIdentifier > 0 {
            // The detached PID belongs to the macOS runner process. Its command arguments
            // describe the requested Windows command, not proof that steam.exe started.
            let command = ([result.executable.path] + [
                "WINEPREFIX=\(target.normalizedPrefixPath)"
            ]).joined(separator: " ")
            evidence.insert(
                SteamLaunchObservedProcess(
                    processID: processIdentifier,
                    command: command,
                    evidenceSource: .runnerLaunch
                ),
                at: 0
            )
        }
        return SteamLaunchProcessSnapshot(
            processes: evidence,
            processObservationReadState: observationRead.state,
            processObservationReadIssues: observationRead.issues
        )
    }

    func merging(_ other: SteamLaunchProcessSnapshot) -> SteamLaunchProcessSnapshot {
        var merged = processes
        var seen = Set(processes)
        for process in other.processes where seen.insert(process).inserted {
            merged.append(process)
        }
        var mergedIssues = processObservationReadIssues
        for issue in other.processObservationReadIssues where !mergedIssues.contains(issue) {
            mergedIssues.append(issue)
        }
        return SteamLaunchProcessSnapshot(
            processes: merged,
            processObservationReadState: Self.mostSevereReadState(
                processObservationReadState,
                other.processObservationReadState
            ),
            processObservationReadIssues: mergedIssues
        )
    }

    func reconcilingProcessCreationEvidence(
        with currentSnapshot: SteamLaunchProcessSnapshot
    ) -> SteamLaunchProcessSnapshot {
        guard currentSnapshot.processObservationReadState == .complete else {
            // A degraded system snapshot cannot prove that a journaled PID is
            // gone. Preserve the creation evidence and propagate the degraded
            // read state instead of turning "could not inspect" into "not live".
            return merging(SteamLaunchProcessSnapshot(
                processes: [],
                processObservationReadState: currentSnapshot.processObservationReadState,
                processObservationReadIssues: currentSnapshot.processObservationReadIssues
            ))
        }
        let currentNamespaces = Set(
            currentSnapshot.processes.map { $0.identifier.namespace }
        )
        let liveProcessesByIdentifier = Dictionary(
            currentSnapshot.processes.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return SteamLaunchProcessSnapshot(
            processes: processes.filter { process in
                guard process.evidenceSource == .processCreationObservation else { return true }
                // FORGEPLAY_PROCESS_V1 records carry Windows PIDs. The regular
                // system snapshot carries Darwin PIDs, and equal integers across
                // those namespaces do not identify the same process. Preserve
                // same-run creation evidence when no Windows process snapshot is
                // available; only a snapshot in the same namespace can validate
                // or retire that evidence.
                guard currentNamespaces.contains(process.identifier.namespace) else {
                    return true
                }
                guard let liveProcess = liveProcessesByIdentifier[process.identifier],
                      !Self.isExternalApplicationRunnerCommand(liveProcess.command) else {
                    return false
                }
                let recordedCommand = Self.normalizedCommand(process.command)
                let liveCommand = Self.normalizedCommand(liveProcess.command)
                if recordedCommand.contains("steamwebhelper.exe") {
                    return liveCommand.contains("steamwebhelper.exe")
                }
                return recordedCommand.contains("steam.exe") && liveCommand.contains("steam.exe")
            },
            processObservationReadState: processObservationReadState,
            processObservationReadIssues: processObservationReadIssues
        )
    }

    private static func mostSevereReadState(
        _ lhs: SteamProcessObservationReadState,
        _ rhs: SteamProcessObservationReadState
    ) -> SteamProcessObservationReadState {
        if lhs == .unavailable || rhs == .unavailable { return .unavailable }
        if lhs == .recovered || rhs == .recovered { return .recovered }
        return .complete
    }

    func newProcesses(since previous: SteamLaunchProcessSnapshot) -> [SteamLaunchObservedProcess] {
        let previousIdentifiers = previous.processIdentifiers
        return processes
            .filter { !previousIdentifiers.contains($0.identifier) }
            .sorted { $0.processID < $1.processID }
    }

    func containsExpectedRunnerProcess(for target: SteamLaunchTarget) -> Bool {
        let runnerPath = target.normalizedRunnerPath
        let runnerDirectoryPath = target.normalizedRunnerDirectoryPath
        let runnerWineRootPath = target.normalizedRunnerWineRootPath
        guard !Self.isExternalApplicationRunnerCommand(runnerPath) else {
            return false
        }
        return processes.contains { process in
            let normalizedCommand = Self.normalizedCommand(process.command)
            let command = Self.casePreservingCommand(process.command)
            guard Self.isWineOrWineServerCommand(normalizedCommand),
                  !Self.isExternalApplicationRunnerCommand(normalizedCommand) else {
                return false
            }
            return Self.commandContainsPath(command, path: runnerPath) ||
                Self.commandContainsPath(command, path: runnerDirectoryPath + "/wine") ||
                Self.commandContainsPath(command, path: runnerDirectoryPath + "/wine64") ||
                Self.commandContainsPath(command, path: runnerDirectoryPath + "/wineserver") ||
                command.contains(runnerWineRootPath + "/lib/wine/")
        }
    }

    func containsExpectedPrefixSteamProcess(for target: SteamLaunchTarget) -> Bool {
        let prefixPath = target.normalizedPrefixPath
        let steamPath = target.normalizedSteamExecutablePath
        return processes.contains { process in
            let normalizedCommand = Self.normalizedCommand(process.command)
            let command = Self.casePreservingCommand(process.command)
            guard !Self.isExternalApplicationRunnerCommand(normalizedCommand) else { return false }
            guard normalizedCommand.contains("steam.exe") || normalizedCommand.contains("steamwebhelper.exe") else {
                return false
            }
            return Self.commandContainsEnvironmentValue(
                    command,
                    name: "wineprefix",
                    value: prefixPath
                ) ||
                Self.commandContainsPath(command, path: steamPath) ||
                Self.isExpectedWindowsSteamClientCommand(
                    process.command,
                    target: target,
                    evidenceSource: process.evidenceSource
                )
        }
    }

    func webHelperCommandLines(for target: SteamLaunchTarget) -> [String] {
        let prefixPath = target.normalizedPrefixPath
        return processes.compactMap { process in
            let normalizedCommand = Self.normalizedCommand(process.command)
            let command = Self.casePreservingCommand(process.command)
            guard !Self.isExternalApplicationRunnerCommand(normalizedCommand) else { return nil }
            guard normalizedCommand.contains("steamwebhelper.exe") else { return nil }
            guard Self.commandContainsEnvironmentValue(
                    command,
                    name: "wineprefix",
                    value: prefixPath
                ) ||
                    Self.isExpectedWindowsSteamClientCommand(
                        process.command,
                        target: target,
                        evidenceSource: process.evidenceSource
                    ) else {
                return nil
            }
            return process.diagnosticLine
        }
    }

    func webHelperCommandLinesContainRequiredLaunchPolicy(for target: SteamLaunchTarget) -> Bool {
        let commandLines = webHelperCommandLines(for: target)
        return !commandLines.isEmpty && commandLines.allSatisfy {
            SteamWebHelperLaunchPolicy.commandLineContainsRequiredArguments($0)
        }
    }

    func steamOrWineProcessesOutsideTarget(for target: SteamLaunchTarget) -> [SteamLaunchObservedProcess] {
        processes.filter { process in
            let command = Self.normalizedCommand(process.command)
            guard Self.isSteamOrWineCommand(command) else {
                return false
            }
            if Self.isExternalApplicationRunnerCommand(command) {
                return true
            }
            if MacOSSteamProcessSnapshot.isMacOSSteamCommand(process.command) {
                return false
            }
            if Self.isExpectedTargetCommand(process, target: target) {
                return false
            }
            return true
        }
    }

    static func parsePSOutput(_ text: String) -> [SteamLaunchObservedProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }
            let pidText = String(trimmed[..<firstSpace])
            let command = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int32(pidText), !command.isEmpty else {
                return nil
            }
            return SteamLaunchObservedProcess(processID: pid, command: command)
        }
    }

    static func isExternalApplicationRunnerCommand(_ command: String) -> Bool {
        let normalized = normalizedCommand(command)
        guard normalized.contains(".app/contents/"),
              !normalized.contains("/contents/resources/runners/forgeplayruntime/") else {
            return false
        }
        return isSteamOrWineCommand(normalized) || normalized.contains("wineprefix=")
    }

    private static func isExpectedTargetCommand(
        _ process: SteamLaunchObservedProcess,
        target: SteamLaunchTarget
    ) -> Bool {
        let normalizedCommand = normalizedCommand(process.command)
        let command = casePreservingCommand(process.command)
        let runnerPath = target.normalizedRunnerPath
        let runnerDirectoryPath = target.normalizedRunnerDirectoryPath
        let runnerWineRootPath = target.normalizedRunnerWineRootPath
        let prefixPath = target.normalizedPrefixPath
        let steamPath = target.normalizedSteamExecutablePath
        if normalizedCommand.contains("wineprefix=") {
            return commandContainsEnvironmentValue(
                command,
                name: "wineprefix",
                value: prefixPath
            )
        }
        if commandContainsPath(command, path: steamPath) {
            return true
        }
        if isExpectedWindowsSteamClientCommand(
            process.command,
            target: target,
            evidenceSource: process.evidenceSource
        ) {
            return true
        }
        guard isWineOrWineServerCommand(normalizedCommand) else {
            return false
        }
        return commandContainsPath(command, path: runnerPath) ||
            commandContainsPath(command, path: runnerDirectoryPath + "/wine") ||
            commandContainsPath(command, path: runnerDirectoryPath + "/wine64") ||
            commandContainsPath(command, path: runnerDirectoryPath + "/wineserver") ||
            command.contains(runnerWineRootPath + "/lib/wine/")
    }

    private static func isSteamOrWineCommand(_ command: String) -> Bool {
        command.contains("steam.exe") ||
            command.contains("steamwebhelper.exe") ||
            isWineOrWineServerCommand(command)
    }

    private static func isWineOrWineServerCommand(_ command: String) -> Bool {
        command.contains("/wine ") ||
            command.contains("/wine64 ") ||
            command.contains("/wine-preloader") ||
            command.contains("/wineserver") ||
            command.hasSuffix("/wine") ||
            command.hasSuffix("/wine64") ||
            command.hasSuffix("/wineserver") ||
        command.contains(" wineserver ")
    }

    private static func isExpectedWindowsSteamClientCommand(
        _ command: String,
        target: SteamLaunchTarget,
        evidenceSource: SteamLaunchProcessEvidenceSource
    ) -> Bool {
        let normalizedCommand = normalizedCommand(command)
        guard !isExternalApplicationRunnerCommand(target.normalizedRunnerPath),
              !isExternalApplicationRunnerCommand(normalizedCommand),
              normalizedCommand.contains("steam.exe") || normalizedCommand.contains("steamwebhelper.exe") else {
            return false
        }
        if normalizedCommand.contains("wineprefix=") {
            return commandContainsEnvironmentValue(
                casePreservingCommand(command),
                name: "wineprefix",
                value: target.normalizedPrefixPath
            )
        }
        guard evidenceSource == .processCreationObservation else {
            return false
        }
        return normalizedCommand.contains("c:\\program files (x86)\\steam\\")
    }

    private static func commandContainsEnvironmentValue(
        _ command: String,
        name: String,
        value: String
    ) -> Bool {
        let marker = "\(name)="
        var searchStart = command.startIndex
        while searchStart < command.endIndex,
              let range = command.range(
                of: marker,
                options: [.caseInsensitive],
                range: searchStart..<command.endIndex
              ) {
            let hasLeadingBoundary = range.lowerBound == command.startIndex ||
                command[command.index(before: range.lowerBound)].isWhitespace
            if hasLeadingBoundary {
                var valueStart = range.upperBound
                var quote: Character?
                if valueStart < command.endIndex,
                   command[valueStart] == "\"" || command[valueStart] == "'" {
                    quote = command[valueStart]
                    valueStart = command.index(after: valueStart)
                }
                if command[valueStart...].hasPrefix(value) {
                    let valueEnd = command.index(valueStart, offsetBy: value.count)
                    let hasTrailingBoundary: Bool
                    if let quote {
                        hasTrailingBoundary = valueEnd < command.endIndex && command[valueEnd] == quote
                    } else {
                        hasTrailingBoundary = valueEnd == command.endIndex || command[valueEnd].isWhitespace
                    }
                    if hasTrailingBoundary { return true }
                }
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func commandContainsPath(_ command: String, path: String) -> Bool {
        var searchStart = command.startIndex
        while searchStart < command.endIndex,
              let range = command.range(of: path, range: searchStart..<command.endIndex) {
            let hasLeadingBoundary: Bool
            if range.lowerBound == command.startIndex {
                hasLeadingBoundary = true
            } else {
                let character = command[command.index(before: range.lowerBound)]
                hasLeadingBoundary = character.isWhitespace || character == "=" || character == "\"" || character == "'"
            }
            let hasTrailingBoundary: Bool
            if range.upperBound == command.endIndex {
                hasTrailingBoundary = true
            } else {
                let character = command[range.upperBound]
                hasTrailingBoundary = character.isWhitespace || character == "\"" || character == "'"
            }
            if hasLeadingBoundary && hasTrailingBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func normalizedCommand(_ command: String) -> String {
        casePreservingCommand(command).lowercased()
    }

    private static func casePreservingCommand(_ command: String) -> String {
        command.replacingOccurrences(of: "\\ ", with: " ")
    }
}

struct MacOSSteamProcess: Sendable, Hashable {
    var processID: Int32
    var command: String
}

struct MacOSSteamProcessSnapshot: Sendable, Hashable {
    var processes: [MacOSSteamProcess]

    var processIDs: Set<Int32> {
        Set(processes.map(\.processID))
    }

    static func current() -> MacOSSteamProcessSnapshot {
        let processes: [MacOSSteamProcess] = DarwinProcessSnapshotReader.current().processes.compactMap { process -> MacOSSteamProcess? in
            guard isMacOSSteamCommand(process.command) else { return nil }
            return MacOSSteamProcess(processID: process.processID, command: process.command)
        }
        return MacOSSteamProcessSnapshot(processes: processes)
    }

    func newProcesses(since previous: MacOSSteamProcessSnapshot) -> [MacOSSteamProcess] {
        let previousIDs = previous.processIDs
        return processes
            .filter { !previousIDs.contains($0.processID) }
            .sorted { $0.processID < $1.processID }
    }

    static func parsePSOutput(_ text: String) -> [MacOSSteamProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }
            let pidText = String(trimmed[..<firstSpace])
            let command = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int32(pidText),
                  isMacOSSteamCommand(command) else {
                return nil
            }
            return MacOSSteamProcess(processID: pid, command: command)
        }
    }

    static func isMacOSSteamCommand(_ command: String) -> Bool {
        let normalized = command
            .replacingOccurrences(of: "\\ ", with: " ")
            .lowercased()
        guard normalized.contains("/contents/macos/") else {
            return false
        }
        let isSteamBundle =
            normalized.contains("/steam.app/") ||
            normalized.contains("/steam.appbundle/") ||
            normalized.contains("/library/application support/steam/")
        let isSteamExecutable =
            normalized.contains("/steam_osx") ||
            normalized.contains("/steam helper") ||
            normalized.contains("/ipcserver")
        return isSteamBundle && isSteamExecutable
    }
}

private extension String {
    var hasCapturedWineVersionEvidence: Bool {
        let normalized = lowercased()
        return !normalized.contains("blocked:") &&
            normalized.contains("exitcode: 0") &&
            (
                normalized.contains("wine-") ||
                (
                    normalized.contains("public version:") &&
                    normalized.contains("product version:")
                )
            )
    }
}

private extension Array where Element == SteamLaunchGateReasonCode {
    mutating func appendUnique(_ code: SteamLaunchGateReasonCode) {
        guard !contains(code) else { return }
        append(code)
    }
}
