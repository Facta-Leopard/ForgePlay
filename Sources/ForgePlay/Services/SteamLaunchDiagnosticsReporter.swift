import Darwin
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

struct SteamWebHelperRenderingIssue: Sendable, Hashable {
    var webHelperGPUTail: [String]
    var steamUIHTMLTail: [String]
    var steamLoginTail: [String]
    var consoleTail: [String] = []
    var webHelperTail: [String] = []
    var webHelperGPUEvidence: SteamEvidenceSourceSnapshot
    var steamUIHTMLEvidence: SteamEvidenceSourceSnapshot
    var steamLoginEvidence: SteamEvidenceSourceSnapshot
    var consoleEvidence: SteamEvidenceSourceSnapshot
    var webHelperEvidence: SteamEvidenceSourceSnapshot
}

enum SteamEvidenceReadState: String, Sendable, Hashable {
    case captured
    case missing
    case unreadable
    case unsafe
    case truncated
    case changedDuringRead
}

struct SteamEvidenceSourceSnapshot: Sendable, Hashable {
    var state: SteamEvidenceReadState
    var detail: String
}

struct SteamCrashDumpFingerprint: Sendable, Hashable {
    var standardizedPath: String
    var deviceNumber: UInt64
    var fileNumber: UInt64
    var byteCount: UInt64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
}

struct SteamCrashDumpScanItem: Sendable, Hashable {
    var url: URL
    var fingerprint: SteamCrashDumpFingerprint
    var modificationDate: Date
}

struct SteamCrashDumpScanResult: Sendable, Hashable {
    var state: SteamEvidenceReadState
    var detail: String
    var items: [SteamCrashDumpScanItem]

    var urls: [URL] {
        items.map(\.url)
    }

    var fingerprints: Set<SteamCrashDumpFingerprint> {
        Set(items.map(\.fingerprint))
    }
}

struct SteamCrashDumpObservationContext: Sendable, Hashable {
    fileprivate let identifier: UUID
}

struct SteamLaunchAttemptEvidence: Sendable, Hashable {
    enum RelaunchReason: String, Sendable, Hashable, Codable {
        case clientBootstrapCompleted
        case steamClientUpdated
        case webHelperStartupRecovery
    }

    var sequence: Int
    var relaunchReason: RelaunchReason
    var result: ProcessRunResult
    var preLaunchShutdownResult: ProcessRunResult?
    var crashDumpsObserved: [URL]

    var runIdentifier: String {
        ProcessRunEvidenceWriter.runIdentifier(for: result.stderrLog)
    }

    var rendererLogDirectory: URL {
        result.stderrLog
            .deletingLastPathComponent()
            .appending(path: "GameRuns/\(runIdentifier)", directoryHint: .isDirectory)
    }
}

struct SteamLaunchDiagnosticEvidenceAssessment: Sendable, Hashable {
    enum Completeness: String, Sendable, Hashable {
        case complete
        case incomplete
    }

    var diagnosticURL: URL
    var completeness: Completeness
    var failureDescriptions: [String]
    var requestedGateStatus: SteamLaunchGateStatus?
    var reportedGateStatus: SteamLaunchGateStatus

    var isCompleteEnoughForHardGateSuccess: Bool {
        completeness == .complete
    }

    var diagnosticCaptureWarning: String? {
        guard completeness == .incomplete else { return nil }
        return "Steam diagnostic evidence is incomplete: \(failureDescriptions.joined(separator: "; "))"
    }
}

struct SteamLogFileCursor: Sendable, Hashable {
    var byteCount: UInt64
    var fileNumber: UInt64?
    var modificationDate: Date?
    var trailingSignature: Data
    var captureState: SteamEvidenceReadState
    var captureDetail: String?
}

struct SteamWebHelperStartupLogCursor: Sendable, Hashable {
    var webHelperGPU: SteamLogFileCursor
    var steamUIHTML: SteamLogFileCursor
    var steamLogin: SteamLogFileCursor
    var console: SteamLogFileCursor
    var webHelper: SteamLogFileCursor
    var shaderLog: SteamLogFileCursor
}

struct SteamWebHelperStartupObservation: Sendable, Hashable {
    enum State: Sendable, Hashable {
        case pending
        case ready
        case retryableFailure
        case evidenceUnavailable
        case timedOut
    }

    var state: State
    var reason: String?
    var steamUIHTMLTail: [String]
    var consoleTail: [String]
    var webHelperTail: [String]

    var shouldRetry: Bool {
        state == .retryableFailure || state == .evidenceUnavailable
    }
}

struct SteamLaunchScreenEvidence: Sendable, Hashable {
    enum VerificationState: String, Sendable, Hashable {
        case verifiedWindowsSteamUI
        case notCaptured
        case captureFailed
        case recognitionFailed
        case steamUITextNotRecognized
    }

    var screenshotURL: URL?
    var state: VerificationState
    var surface: SteamUISurface? = nil
    var recognizedText: [String]
    var message: String

    var verifiesWindowsSteamUI: Bool {
        state == .verifiedWindowsSteamUI
    }

    static func notCaptured(_ message: String) -> SteamLaunchScreenEvidence {
        SteamLaunchScreenEvidence(
            screenshotURL: nil,
            state: .notCaptured,
            recognizedText: [],
            message: message
        )
    }
}

final class SteamLaunchDiagnosticsReporter: @unchecked Sendable {
    private struct EvidenceFileMetadata: Sendable, Equatable {
        var byteCount: UInt64
        var fileNumber: UInt64
        var deviceNumber: UInt64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64

        var modificationDate: Date {
            Date(
                timeIntervalSince1970: TimeInterval(modificationSeconds) +
                    TimeInterval(modificationNanoseconds) / 1_000_000_000
            )
        }
    }

    private enum SecureEvidenceFileOpenResult {
        case opened(descriptor: Int32, metadata: EvidenceFileMetadata)
        case failed(state: SteamEvidenceReadState, detail: String)
    }

    private struct EvidenceDirectoryIdentity: Equatable {
        var deviceNumber: UInt64
        var fileNumber: UInt64
    }

    private enum SecureEvidenceDirectoryOpenResult {
        case opened(descriptor: Int32, identity: EvidenceDirectoryIdentity)
        case failed(state: SteamEvidenceReadState, detail: String)
    }

    private struct SteamLogReadResult: Sendable {
        var state: SteamEvidenceReadState
        var lines: [String]
        var detail: String

        var invalidatesHardGateSuccess: Bool {
            switch state {
            case .unsafe, .unreadable, .changedDuringRead:
                true
            case .captured, .missing, .truncated:
                false
            }
        }

        func diagnosticLines(limit: Int) -> [String] {
            guard limit > 0 else { return [] }
            let boundedLines = Array(lines.suffix(limit))
            guard state != .captured else { return boundedLines }
            let marker = "[ForgePlay: evidence state=\(state.rawValue); \(detail)]"
            guard limit > 1 else { return [marker] }
            return [marker] + Array(boundedLines.suffix(limit - 1))
        }

        func filteringLines(_ transform: ([String]) -> [String]) -> SteamLogReadResult {
            SteamLogReadResult(state: state, lines: transform(lines), detail: detail)
        }
    }

    private enum GameDiagnosticFileFingerprint: Equatable, Sendable {
        case available(EvidenceFileMetadata)
        case unavailable(SteamEvidenceReadState)
    }

    private struct GameDiagnosticInputFingerprint: Equatable, Sendable {
        var gameProcess: GameDiagnosticFileFingerprint
        var console: GameDiagnosticFileFingerprint
        var processObservation: GameDiagnosticFileFingerprint
        var launchStdout: GameDiagnosticFileFingerprint
        var launchStderr: GameDiagnosticFileFingerprint
        var dedicatedWineCrashReports: DedicatedWineCrashInputFingerprint
    }

    private struct GameDiagnosticInputCacheEntry: Sendable {
        var fingerprint: GameDiagnosticInputFingerprint
        var gameProcessRead: SteamLogReadResult
        var consoleRead: SteamLogReadResult
        var processObservation: SteamProcessObservationReadResult
        var launchStdoutRead: SteamLogReadResult
        var launchStderrRead: SteamLogReadResult
        var dedicatedWineCrashRead: SteamLogReadResult
        var hasAnalyzed: Bool
        var analyzedDiagnostics: [SteamGameLaunchDiagnostic]
    }

    private struct DedicatedWineCrashFileFingerprint: Equatable, Sendable {
        var fileName: String
        var metadata: EvidenceFileMetadata
    }

    private enum DedicatedWineCrashInputFingerprint: Equatable, Sendable {
        case unavailable(SteamEvidenceReadState)
        case available(
            state: SteamEvidenceReadState,
            candidateCount: Int,
            files: [DedicatedWineCrashFileFingerprint],
            rejectedCandidates: [String]
        )
    }

    private struct DedicatedWineCrashFile: Sendable {
        var url: URL
        var metadata: EvidenceFileMetadata
    }

    private struct DedicatedWineCrashFileScan: Sendable {
        var fingerprint: DedicatedWineCrashInputFingerprint
        var state: SteamEvidenceReadState
        var detail: String
        var files: [DedicatedWineCrashFile]
    }

    private struct GameDiagnosticMaterialSignature: Codable, Hashable {
        var state: SteamGameLaunchDiagnosticState
        var appID: String?
        var primaryProcessID: Int32?
        var trackedProcessIDs: [Int32]
        var activeProcessIDs: [Int32]
        var executable: String?
        var startedAt: Date?
        var endedAt: Date?
        var exitCodes: [String]
        var primaryExitCode: Int32?
        var failureProcessID: Int32?
        var failureExitCode: Int32?
        var consoleLastTask: String?
        var rendererRequested: String?
        var rendererApplied: String?
        var rendererPlannedProfile: String?
        var rendererPlannedComponentOwnership: String?
        var rendererPlannedComponentsX64: String?
        var rendererPlannedComponentsX86: String?
        var rendererActualLoaded: String?
        var rendererLoadedModules: [String]?
        var rendererLoadedModulePaths: [String]?
        var rendererModuleLoadFailures: [String]?
        var rendererRoutingReason: String?
        var rendererRoutingEvidence: String?
        var rendererCorrelationIdentifier: String?
        var rendererErrorStage: String?
        var rendererErrorStatusHex: String?
        var rendererErrorPath: String?
        var runtimeCrashEvents: [SteamGameRuntimeCrashEvent]
        var runtimeCrashStdoutEvidenceState: String
        var runtimeCrashStdoutEvidenceDetail: String?
        var runtimeCrashStderrEvidenceState: String
        var runtimeCrashStderrEvidenceDetail: String?
        var runtimeCrashDedicatedEvidenceState: String
        var runtimeCrashDedicatedEvidenceDetail: String?
        var gameProcessEvidenceState: String
        var consoleEvidenceState: String
        var processObservationEvidenceState: String
        var correlatedEvidence: [String]
    }

    private struct GameLaunchAttemptArtifact: Codable {
        static let schemaVersion = 1

        var schemaVersion = Self.schemaVersion
        var attemptIdentifier: String
        var materialRevision: String
        var diagnostic: SteamGameLaunchDiagnostic

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case attemptIdentifier = "attempt_identifier"
            case materialRevision = "material_revision"
            case diagnostic
        }
    }

    private struct GameLaunchCaptureInput: Codable {
        var role: String
        var state: String
        var detail: String?
    }

    /// Run-scoped capture envelope written even when Steam never reports a
    /// tracked game process. A zero-attempt result is evidence, not absence of
    /// evidence, and must remain machine-readable in another user's bundle.
    private struct GameLaunchCaptureDocument: Codable {
        static let schemaVersion = 1

        var schemaVersion = Self.schemaVersion
        var runIdentifier: String
        var capturedAt: Date
        var cutoff: Date?
        var captureRequestIdentifier: UUID?
        var captureState: String
        var reasonCode: String?
        var attemptCount: Int
        var steamTrackedAttemptCount: Int
        var inputs: [GameLaunchCaptureInput]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case runIdentifier = "run_identifier"
            case capturedAt = "captured_at"
            case cutoff
            case captureRequestIdentifier = "capture_request_identifier"
            case captureState = "capture_state"
            case reasonCode = "reason_code"
            case attemptCount = "attempt_count"
            case steamTrackedAttemptCount = "steam_tracked_attempt_count"
            case inputs
        }
    }

    private struct PriorLaunchAttemptRead {
        var attempt: SteamLaunchAttemptEvidence
        var stdout: SteamLogReadResult
        var stderr: SteamLogReadResult
        var runMetadata: SteamLogReadResult?
    }

    private struct LaunchAttemptDocument: Codable {
        var sequence: Int
        var relaunchReason: SteamLaunchAttemptEvidence.RelaunchReason
        var runIdentifier: String
        var actionName: String
        var startedAt: Date
        var endedAt: Date
        var processExitCode: Int32?
        var forgePlayStatusCode: Int32?
        var outcome: ProcessRunOutcome
        var didTimeOut: Bool
        var waitedForExit: Bool
        var stdoutLog: String
        var stderrLog: String
        var runEvidenceLog: String?
        var relatedRunEvidenceLogs: [String]
        var processObservationLog: String?
        var rendererLogDirectory: String
        var crashDumpsObserved: [String]
        var preLaunchShutdownRunEvidenceLog: String?
        var preLaunchShutdownRelatedRunEvidenceLogs: [String]

        enum CodingKeys: String, CodingKey {
            case sequence
            case relaunchReason = "relaunch_reason"
            case runIdentifier = "run_identifier"
            case actionName = "action_name"
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case processExitCode = "process_exit_code"
            case forgePlayStatusCode = "forgeplay_status_code"
            case outcome
            case didTimeOut = "did_time_out"
            case waitedForExit = "waited_for_exit"
            case stdoutLog = "stdout_log"
            case stderrLog = "stderr_log"
            case runEvidenceLog = "run_evidence_log"
            case relatedRunEvidenceLogs = "related_run_evidence_logs"
            case processObservationLog = "process_observation_log"
            case rendererLogDirectory = "renderer_log_directory"
            case crashDumpsObserved = "crash_dumps_observed"
            case preLaunchShutdownRunEvidenceLog = "pre_launch_shutdown_run_evidence_log"
            case preLaunchShutdownRelatedRunEvidenceLogs = "pre_launch_shutdown_related_run_evidence_logs"
        }
    }

    private struct CrashDumpScanObservation: Sendable {
        var state: SteamEvidenceReadState
        var directory: URL
        var detail: String

        var isIncomplete: Bool {
            switch state {
            case .unsafe, .unreadable, .changedDuringRead:
                true
            case .captured, .missing, .truncated:
                false
            }
        }

        var diagnosticLine: String {
            "- \(directory.path): \(state.rawValue) (\(detail))"
        }
    }

    private let fileManager: FileManager
    /// Dedicated per-run WineDbg files are not part of the July 17 runtime
    /// contract. Keep their backwards-compatible reader isolated behind an
    /// explicit capability so ordinary launches never depend on that surface.
    private let dedicatedWineCrashCapabilityEnabled: Bool
    private let diagnosticTailByteLimit = 512 * 1024
    private let maximumDedicatedWineCrashReports = 8
    private let maximumDedicatedWineCrashLinesPerReport = 2_048
    private let maximumPersistedGameLaunchAttemptArtifacts = 64
    private let crashDumpObservationLock = NSLock()
    private var crashDumpScanObservationsByContext: [UUID: [CrashDumpScanObservation]] = [:]
    private let evidenceAssessmentLock = NSLock()
    private var evidenceAssessmentsByPath: [String: SteamLaunchDiagnosticEvidenceAssessment] = [:]
    private var evidenceAssessmentPathOrder: [String] = []
    private let gameDiagnosticCacheLock = NSLock()
    private let gameDiagnosticRefreshLock = NSLock()
    private var gameDiagnosticInputCache: [String: GameDiagnosticInputCacheEntry] = [:]
    private var persistedGameDiagnosticSignatures: [String: GameDiagnosticMaterialSignature] = [:]
    private var persistedGameCaptureFingerprints: [String: GameDiagnosticInputFingerprint] = [:]

    init(
        fileManager: FileManager = .default,
        dedicatedWineCrashCapabilityEnabled: Bool = false
    ) {
        self.fileManager = fileManager
        self.dedicatedWineCrashCapabilityEnabled = dedicatedWineCrashCapabilityEnabled
    }

    func latestGameLaunchDiagnostic(
        in steamDirectory: URL,
        processObservationLog: URL,
        launchStdoutLog: URL? = nil,
        launchStderrLog: URL? = nil,
        since cutoff: Date?,
        observedAt: Date = Date(),
        persistTo gameRunDirectory: URL? = nil,
        forceCurrentSnapshot: Bool = false,
        captureRequestIdentifier: UUID? = nil
    ) -> SteamGameLaunchDiagnostic? {
        gameDiagnosticRefreshLock.lock()
        defer { gameDiagnosticRefreshLock.unlock() }
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let gameProcessLog = logs.appending(path: "gameprocess_log.txt")
        let consoleLog = logs.appending(path: "console_log.txt")
        let dedicatedWineCrashScan: DedicatedWineCrashFileScan = if dedicatedWineCrashCapabilityEnabled {
            dedicatedWineCrashFileScan(in: gameRunDirectory)
        } else {
            DedicatedWineCrashFileScan(
                fingerprint: .unavailable(.missing),
                state: .missing,
                detail: "dedicated Wine crash capture is not declared by this runtime",
                files: []
            )
        }
        let cacheKey = [
            steamDirectory.standardizedFileURL.path,
            processObservationLog.standardizedFileURL.path,
            launchStdoutLog?.standardizedFileURL.path ?? "no-stdout",
            launchStderrLog?.standardizedFileURL.path ?? "no-stderr",
            gameRunDirectory?.standardizedFileURL.path ?? "no-game-run-directory",
            cutoff.map { String($0.timeIntervalSinceReferenceDate) } ?? "no-cutoff"
        ].joined(separator: "\u{1f}")
        let inputFingerprint = GameDiagnosticInputFingerprint(
            gameProcess: gameDiagnosticFileFingerprint(
                at: gameProcessLog,
                allowedRoot: steamDirectory
            ),
            console: gameDiagnosticFileFingerprint(
                at: consoleLog,
                allowedRoot: steamDirectory
            ),
            processObservation: gameDiagnosticFileFingerprint(
                at: processObservationLog,
                allowedRoot: nil
            ),
            launchStdout: gameDiagnosticFileFingerprint(
                at: launchStdoutLog,
                allowedRoot: nil
            ),
            launchStderr: gameDiagnosticFileFingerprint(
                at: launchStderrLog,
                allowedRoot: nil
            ),
            dedicatedWineCrashReports: dedicatedWineCrashScan.fingerprint
        )
        let cachedInput: GameDiagnosticInputCacheEntry? = withGameDiagnosticCacheLock {
            guard let cached = gameDiagnosticInputCache[cacheKey],
                  cached.fingerprint == inputFingerprint else { return nil }
            return cached
        }
        let input: GameDiagnosticInputCacheEntry
        if let cachedInput {
            input = cachedInput
        } else {
            input = GameDiagnosticInputCacheEntry(
                fingerprint: inputFingerprint,
                gameProcessRead: tailReadResult(
                    from: gameProcessLog,
                    limit: 2_048,
                    modifiedAfter: cutoff,
                    allowedRoot: steamDirectory
                ),
                consoleRead: tailReadResult(
                    from: consoleLog,
                    limit: 2_048,
                    modifiedAfter: cutoff,
                    allowedRoot: steamDirectory
                ),
                processObservation: SteamProcessCreationObservationLog.read(
                    at: processObservationLog,
                    fileManager: fileManager
                ),
                launchStdoutRead: gameDiagnosticLogRead(
                    at: launchStdoutLog,
                    cutoff: cutoff,
                    missingDetail: "no Steam launch stdout path was recorded"
                ),
                launchStderrRead: gameDiagnosticLogRead(
                    at: launchStderrLog,
                    cutoff: cutoff,
                    missingDetail: "no Steam launch stderr path was recorded"
                ),
                dedicatedWineCrashRead: readDedicatedWineCrashFiles(
                    dedicatedWineCrashScan,
                    in: gameRunDirectory
                ),
                hasAnalyzed: false,
                analyzedDiagnostics: []
            )
            withGameDiagnosticCacheLock {
                gameDiagnosticInputCache[cacheKey] = input
                if gameDiagnosticInputCache.count > 8 {
                    gameDiagnosticInputCache = [cacheKey: input]
                }
            }
        }
        let crossesLaunchClassificationBoundary = input.analyzedDiagnostics.last?.state == .launching &&
            input.analyzedDiagnostics.last?.startedAt.map {
                observedAt >= $0.addingTimeInterval(
                    SteamGameLaunchDiagnosticAnalyzer.defaultLaunchStabilityThreshold
                )
            } == true
        let analyzedDiagnostics: [SteamGameLaunchDiagnostic]
        if forceCurrentSnapshot || !input.hasAnalyzed || crossesLaunchClassificationBoundary {
            let runtimeCrashObservations = WineRuntimeCrashEventParser.parse(
                stdoutLines: input.launchStdoutRead.lines + input.dedicatedWineCrashRead.lines,
                stderrLines: input.launchStderrRead.lines
            )
            analyzedDiagnostics = SteamGameLaunchDiagnosticAnalyzer.analyzeAttempts(
                gameProcessLines: input.gameProcessRead.lines,
                consoleLines: input.consoleRead.lines,
                processObservation: input.processObservation,
                runtimeCrashObservations: runtimeCrashObservations,
                runtimeCrashStdoutEvidenceState: input.launchStdoutRead.state.rawValue,
                runtimeCrashStdoutEvidenceDetail: input.launchStdoutRead.detail,
                runtimeCrashStderrEvidenceState: input.launchStderrRead.state.rawValue,
                runtimeCrashStderrEvidenceDetail: input.launchStderrRead.detail,
                runtimeCrashDedicatedEvidenceState: input.dedicatedWineCrashRead.state.rawValue,
                runtimeCrashDedicatedEvidenceDetail: input.dedicatedWineCrashRead.detail,
                allowsSameLaunchSessionOrderFallback: hasSafelyScopedRuntimeCrashInputs(
                    processObservationLog: processObservationLog,
                    launchStdoutLog: launchStdoutLog,
                    launchStderrLog: launchStderrLog,
                    gameRunDirectory: gameRunDirectory,
                    cutoff: cutoff
                ),
                since: cutoff,
                now: observedAt,
                gameProcessEvidenceState: input.gameProcessRead.state.rawValue,
                consoleEvidenceState: input.consoleRead.state.rawValue
            )
            withGameDiagnosticCacheLock {
                guard var current = gameDiagnosticInputCache[cacheKey],
                      current.fingerprint == inputFingerprint else { return }
                current.hasAnalyzed = true
                current.analyzedDiagnostics = analyzedDiagnostics
                gameDiagnosticInputCache[cacheKey] = current
            }
        } else {
            analyzedDiagnostics = input.analyzedDiagnostics
        }
        if let gameRunDirectory {
            do {
                let gameRunsDirectory = gameRunDirectory.deletingLastPathComponent()
                guard gameRunsDirectory.lastPathComponent == "GameRuns",
                      UUID(uuidString: gameRunDirectory.lastPathComponent) != nil else {
                    throw ProcessRunEvidenceWriterError.unsafeEvidencePath(gameRunDirectory)
                }
                try ensureGameRunDiagnosticDirectory(gameRunDirectory)
                try persistGameLaunchCapture(
                    diagnostics: analyzedDiagnostics,
                    input: input,
                    inputFingerprint: inputFingerprint,
                    cutoff: cutoff,
                    observedAt: observedAt,
                    gameRunDirectory: gameRunDirectory,
                    forceCurrentSnapshot: forceCurrentSnapshot,
                    captureRequestIdentifier: captureRequestIdentifier
                )
            } catch {
                guard var diagnostic = analyzedDiagnostics.last else { return nil }
                diagnostic.structuredLogState = "failed: \(forgePlayTechnicalErrorSummary(error))"
                return diagnostic
            }
        }
        guard var diagnostic = analyzedDiagnostics.last else {
            return nil
        }

        guard let gameRunDirectory else { return diagnostic }
        do {
            let gameRunsDirectory = gameRunDirectory.deletingLastPathComponent()
            guard gameRunsDirectory.lastPathComponent == "GameRuns",
                  UUID(uuidString: gameRunDirectory.lastPathComponent) != nil else {
                throw ProcessRunEvidenceWriterError.unsafeEvidencePath(gameRunDirectory)
            }
            try ensureGameRunDiagnosticDirectory(gameRunDirectory)
            let diagnosticURL = gameRunDirectory.appending(path: "game-launch-diagnostic.json")
            let signature = gameDiagnosticMaterialSignature(for: diagnostic)
            let persistenceKey = diagnosticURL.standardizedFileURL.path
            let wasAlreadyPersisted = withGameDiagnosticCacheLock {
                persistedGameDiagnosticSignatures[persistenceKey] == signature
            }
            diagnostic.structuredLogState = "captured"
            try persistGameLaunchAttemptArtifacts(
                analyzedDiagnostics,
                to: gameRunDirectory
            )
            guard forceCurrentSnapshot || !wasAlreadyPersisted else { return diagnostic }
            try ProcessRunEvidenceWriter.writeStructuredDocument(
                diagnostic,
                to: diagnosticURL,
                fileManager: fileManager
            )
            withGameDiagnosticCacheLock {
                persistedGameDiagnosticSignatures[persistenceKey] = signature
                if persistedGameDiagnosticSignatures.count > 32 {
                    persistedGameDiagnosticSignatures = [persistenceKey: signature]
                }
            }
        } catch {
            diagnostic.structuredLogState = "failed: \(forgePlayTechnicalErrorSummary(error))"
        }
        return diagnostic
    }

    private func persistGameLaunchCapture(
        diagnostics: [SteamGameLaunchDiagnostic],
        input: GameDiagnosticInputCacheEntry,
        inputFingerprint: GameDiagnosticInputFingerprint,
        cutoff: Date?,
        observedAt: Date,
        gameRunDirectory: URL,
        forceCurrentSnapshot: Bool,
        captureRequestIdentifier: UUID?
    ) throws {
        let captureURL = gameRunDirectory.appending(path: "game-launch-capture.json")
        let persistenceKey = captureURL.standardizedFileURL.path
        let wasAlreadyPersisted = withGameDiagnosticCacheLock {
            persistedGameCaptureFingerprints[persistenceKey] == inputFingerprint
        }
        guard forceCurrentSnapshot || !wasAlreadyPersisted else { return }

        let inputs = [
            GameLaunchCaptureInput(
                role: "steamGameProcessLog",
                state: input.gameProcessRead.state.rawValue,
                detail: input.gameProcessRead.detail
            ),
            GameLaunchCaptureInput(
                role: "steamConsoleLog",
                state: input.consoleRead.state.rawValue,
                detail: input.consoleRead.detail
            ),
            GameLaunchCaptureInput(
                role: "processObservation",
                state: input.processObservation.state.rawValue,
                detail: input.processObservation.diagnosticWarning
            ),
            GameLaunchCaptureInput(
                role: "launchStdout",
                state: input.launchStdoutRead.state.rawValue,
                detail: input.launchStdoutRead.detail
            ),
            GameLaunchCaptureInput(
                role: "launchStderr",
                state: input.launchStderrRead.state.rawValue,
                detail: input.launchStderrRead.detail
            ),
        ]
        let steamTrackedAttemptCount = diagnostics.filter { $0.appID != nil }.count
        let capturedPreTrackingRendererFailure = steamTrackedAttemptCount == 0 &&
            diagnostics.last?.state == .rendererError
        let captureState: String
        let reasonCode: String?
        if capturedPreTrackingRendererFailure {
            captureState = "rendererSetupFailureCaptured"
            reasonCode = "rendererSetupFailedBeforeSteamTracking"
        } else if steamTrackedAttemptCount > 0 {
            captureState = "attemptsCaptured"
            reasonCode = nil
        } else {
            captureState = "noTrackedGameProcess"
            reasonCode = "steamGameProcessNotObserved"
        }
        try ProcessRunEvidenceWriter.writeStructuredDocument(
            GameLaunchCaptureDocument(
                runIdentifier: gameRunDirectory.lastPathComponent.lowercased(),
                capturedAt: observedAt,
                cutoff: cutoff,
                captureRequestIdentifier: captureRequestIdentifier,
                captureState: captureState,
                reasonCode: reasonCode,
                attemptCount: diagnostics.count,
                steamTrackedAttemptCount: steamTrackedAttemptCount,
                inputs: inputs
            ),
            to: captureURL,
            fileManager: fileManager
        )
        withGameDiagnosticCacheLock {
            persistedGameCaptureFingerprints[persistenceKey] = inputFingerprint
            if persistedGameCaptureFingerprints.count > 32 {
                persistedGameCaptureFingerprints = [persistenceKey: inputFingerprint]
            }
        }
    }

    /// Confirms that a zero-attempt capture belongs to the current support
    /// request. Merely finding an older file is not evidence that the forced
    /// refresh succeeded.
    func gameLaunchCaptureMatchesRequest(
        in gameRunDirectory: URL,
        requestIdentifier: UUID
    ) -> Bool {
        let captureURL = gameRunDirectory.appending(path: "game-launch-capture.json")
        switch openSecureEvidenceFile(at: captureURL, allowedRoot: gameRunDirectory) {
        case .failed:
            return false
        case .opened(let descriptor, let metadata):
            defer { Darwin.close(descriptor) }
            guard metadata.byteCount <= 512 * 1_024,
                  let data = try? readFileBytes(
                    descriptor: descriptor,
                    offset: 0,
                    count: Int(metadata.byteCount)
                  ) else {
                return false
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let capture = try? decoder.decode(GameLaunchCaptureDocument.self, from: data) else {
                return false
            }
            return capture.captureRequestIdentifier == requestIdentifier
        }
    }

    private func gameDiagnosticFileFingerprint(
        at url: URL?,
        allowedRoot: URL?
    ) -> GameDiagnosticFileFingerprint {
        guard let url else { return .unavailable(.missing) }
        switch openSecureEvidenceFile(at: url, allowedRoot: allowedRoot) {
        case .opened(let descriptor, let metadata):
            Darwin.close(descriptor)
            return .available(metadata)
        case .failed(let state, _):
            return .unavailable(state)
        }
    }

    private func gameDiagnosticLogRead(
        at url: URL?,
        cutoff: Date?,
        missingDetail: String
    ) -> SteamLogReadResult {
        guard let url else {
            return SteamLogReadResult(state: .missing, lines: [], detail: missingDetail)
        }
        return tailReadResult(
            from: url,
            limit: 4_096,
            modifiedAfter: cutoff,
            allowedRoot: nil
        )
    }

    /// Finds only crash reports created for this exact Steam run. Enumeration
    /// is followed by anchored, no-follow opens so a symlink or directory swap
    /// is reported as incomplete evidence instead of being consumed.
    private func dedicatedWineCrashFileScan(
        in gameRunDirectory: URL?
    ) -> DedicatedWineCrashFileScan {
        guard let gameRunDirectory else {
            return DedicatedWineCrashFileScan(
                fingerprint: .unavailable(.missing),
                state: .missing,
                detail: "no per-run directory was provided for dedicated Wine crash reports",
                files: []
            )
        }
        let gameRunsDirectory = gameRunDirectory.deletingLastPathComponent()
        guard gameRunsDirectory.lastPathComponent == "GameRuns",
              UUID(uuidString: gameRunDirectory.lastPathComponent) != nil else {
            return DedicatedWineCrashFileScan(
                fingerprint: .unavailable(.unsafe),
                state: .unsafe,
                detail: "dedicated Wine crash report directory is not a managed GameRuns UUID path",
                files: []
            )
        }

        let initialDirectoryIdentity: EvidenceDirectoryIdentity
        let initialDirectoryDescriptor: Int32
        switch openSecureEvidenceDirectory(gameRunDirectory, anchoredAt: gameRunDirectory) {
        case .failed(let state, let detail):
            let normalizedState: SteamEvidenceReadState = state == .missing ? .missing : state
            return DedicatedWineCrashFileScan(
                fingerprint: .unavailable(normalizedState),
                state: normalizedState,
                detail: normalizedState == .missing
                    ? "no dedicated Wine crash report has been created for this run"
                    : detail,
                files: []
            )
        case .opened(let descriptor, let identity):
            initialDirectoryDescriptor = descriptor
            initialDirectoryIdentity = identity
        }
        defer { Darwin.close(initialDirectoryDescriptor) }

        let directoryItems: [URL]
        do {
            directoryItems = try fileManager.contentsOfDirectory(
                at: gameRunDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            return DedicatedWineCrashFileScan(
                fingerprint: .unavailable(.unreadable),
                state: .unreadable,
                detail: "dedicated Wine crash report enumeration failed: \(forgePlayTechnicalErrorSummary(error))",
                files: []
            )
        }

        let candidates = directoryItems.filter {
            $0.lastPathComponent.hasPrefix("wine-crash-") &&
                $0.pathExtension == "log"
        }
        guard !candidates.isEmpty else {
            return DedicatedWineCrashFileScan(
                fingerprint: .unavailable(.missing),
                state: .missing,
                detail: "no dedicated Wine crash report has been created for this run",
                files: []
            )
        }

        var readableFiles: [DedicatedWineCrashFile] = []
        var rejectedCandidates: [String] = []
        var scanState = SteamEvidenceReadState.captured
        for candidate in candidates {
            switch openSecureEvidenceFile(at: candidate, allowedRoot: gameRunDirectory) {
            case .opened(let descriptor, let metadata):
                Darwin.close(descriptor)
                readableFiles.append(DedicatedWineCrashFile(url: candidate, metadata: metadata))
            case .failed(let state, _):
                let effectiveState = state == .missing ? .changedDuringRead : state
                scanState = mergedEvidenceState(scanState, effectiveState)
                rejectedCandidates.append("\(candidate.lastPathComponent):\(effectiveState.rawValue)")
            }
        }

        switch openSecureEvidenceDirectory(gameRunDirectory, anchoredAt: gameRunDirectory) {
        case .failed:
            scanState = mergedEvidenceState(scanState, .changedDuringRead)
        case .opened(let descriptor, let finalIdentity):
            Darwin.close(descriptor)
            if finalIdentity != initialDirectoryIdentity {
                scanState = mergedEvidenceState(scanState, .changedDuringRead)
            }
        }

        readableFiles.sort {
            if $0.metadata.modificationSeconds != $1.metadata.modificationSeconds {
                return $0.metadata.modificationSeconds < $1.metadata.modificationSeconds
            }
            if $0.metadata.modificationNanoseconds != $1.metadata.modificationNanoseconds {
                return $0.metadata.modificationNanoseconds < $1.metadata.modificationNanoseconds
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        let selectedFiles = Array(readableFiles.suffix(maximumDedicatedWineCrashReports))
        if readableFiles.count > maximumDedicatedWineCrashReports {
            scanState = mergedEvidenceState(scanState, .truncated)
        }
        rejectedCandidates.sort()
        let fingerprints = selectedFiles.map {
            DedicatedWineCrashFileFingerprint(
                fileName: $0.url.lastPathComponent,
                metadata: $0.metadata
            )
        }
        let fingerprint = DedicatedWineCrashInputFingerprint.available(
            state: scanState,
            candidateCount: candidates.count,
            files: fingerprints,
            rejectedCandidates: rejectedCandidates
        )
        let detail = "selected \(selectedFiles.count) of \(candidates.count) dedicated Wine crash report candidate(s)" +
            (rejectedCandidates.isEmpty
                ? ""
                : "; rejected \(rejectedCandidates.count) unsafe or unstable candidate(s)")
        return DedicatedWineCrashFileScan(
            fingerprint: fingerprint,
            state: scanState,
            detail: detail,
            files: selectedFiles
        )
    }

    private func readDedicatedWineCrashFiles(
        _ scan: DedicatedWineCrashFileScan,
        in gameRunDirectory: URL?
    ) -> SteamLogReadResult {
        guard let gameRunDirectory, !scan.files.isEmpty else {
            return SteamLogReadResult(state: scan.state, lines: [], detail: scan.detail)
        }

        var state = scan.state
        var lines: [String] = []
        var acceptedCount = 0
        var issues: [String] = []
        for file in scan.files {
            let read = boundedHeadReadResult(
                from: file.url,
                expectedMetadata: file.metadata,
                byteLimit: diagnosticTailByteLimit,
                lineLimit: maximumDedicatedWineCrashLinesPerReport,
                allowedRoot: gameRunDirectory
            )
            let readState = read.state == .missing ? .changedDuringRead : read.state
            state = mergedEvidenceState(state, readState)
            guard let header = read.lines.first,
                  header.hasPrefix("FORGEPLAY_WINE_CRASH_V1") else {
                state = mergedEvidenceState(state, .unreadable)
                issues.append("\(file.url.lastPathComponent): missing FORGEPLAY_WINE_CRASH_V1 header")
                continue
            }
            acceptedCount += 1
            // Headers delimit files but are not WineDbg output. Removing them
            // also prevents a following header from being mistaken for a line
            // in the preceding report's System information section.
            lines.append(contentsOf: read.lines.dropFirst())
            if readState != .captured {
                issues.append("\(file.url.lastPathComponent): \(readState.rawValue)")
            }
        }

        if acceptedCount == 0 {
            state = mergedEvidenceState(state, .unreadable)
        }
        var detail = "accepted \(acceptedCount) of \(scan.files.count) selected dedicated Wine crash report(s); \(scan.detail)"
        if !issues.isEmpty {
            detail += "; " + issues.prefix(maximumDedicatedWineCrashReports).joined(separator: "; ")
        }
        return SteamLogReadResult(state: state, lines: lines, detail: detail)
    }

    private func boundedHeadReadResult(
        from url: URL,
        expectedMetadata: EvidenceFileMetadata,
        byteLimit: Int,
        lineLimit: Int,
        allowedRoot: URL
    ) -> SteamLogReadResult {
        switch openSecureEvidenceFile(at: url, allowedRoot: allowedRoot) {
        case .failed(let state, let detail):
            return SteamLogReadResult(state: state, lines: [], detail: detail)
        case .opened(let descriptor, let metadata):
            defer { Darwin.close(descriptor) }
            let requestedByteCount = min(Int(metadata.byteCount), max(0, byteLimit))
            let data: Data
            do {
                data = try readFileBytes(descriptor: descriptor, offset: 0, count: requestedByteCount)
            } catch {
                return SteamLogReadResult(
                    state: .unreadable,
                    lines: [],
                    detail: "bounded crash report read failed: \(forgePlayTechnicalErrorSummary(error))"
                )
            }
            let runtimeTruncationMarker = Data("FORGEPLAY_WINE_CRASH_LOG_TRUNCATED_V1".utf8)
            var runtimeReportedTruncation = data.range(of: runtimeTruncationMarker) != nil
            if metadata.byteCount > UInt64(requestedByteCount) {
                let tailByteCount = min(Int(metadata.byteCount), 8 * 1_024)
                do {
                    let tail = try readFileBytes(
                        descriptor: descriptor,
                        offset: Int64(metadata.byteCount) - Int64(tailByteCount),
                        count: tailByteCount
                    )
                    runtimeReportedTruncation = runtimeReportedTruncation ||
                        tail.range(of: runtimeTruncationMarker) != nil
                } catch {
                    let rawLines = String(decoding: data, as: UTF8.self).split(
                        omittingEmptySubsequences: false,
                        whereSeparator: { $0.isNewline }
                    ).map(String.init)
                    return SteamLogReadResult(
                        state: .unreadable,
                        lines: Array(rawLines.prefix(max(0, lineLimit))),
                        detail: "bounded crash report tail-marker read failed: \(forgePlayTechnicalErrorSummary(error))"
                    )
                }
            }
            let finalMetadata = evidenceFileMetadata(descriptor: descriptor)
            let changedDuringRead = metadata != expectedMetadata ||
                finalMetadata != metadata ||
                data.count != requestedByteCount
            let rawLines = String(decoding: data, as: UTF8.self).split(
                omittingEmptySubsequences: false,
                whereSeparator: { $0.isNewline }
            ).map(String.init).filter {
                !$0.hasPrefix("FORGEPLAY_WINE_CRASH_LOG_TRUNCATED_V1")
            }
            let lines = Array(rawLines.prefix(max(0, lineLimit)))
            if changedDuringRead {
                return SteamLogReadResult(
                    state: .changedDuringRead,
                    lines: lines,
                    detail: "crash report changed between enumeration and its bounded read"
                )
            }
            if runtimeReportedTruncation {
                return SteamLogReadResult(
                    state: .truncated,
                    lines: lines,
                    detail: "Wine crash logger reported FORGEPLAY_WINE_CRASH_LOG_TRUNCATED_V1"
                )
            }
            if metadata.byteCount > UInt64(max(0, byteLimit)) || rawLines.count > lineLimit {
                return SteamLogReadResult(
                    state: .truncated,
                    lines: lines,
                    detail: "crash report head was bounded to \(byteLimit) bytes and \(lineLimit) lines"
                )
            }
            return SteamLogReadResult(
                state: .captured,
                lines: lines,
                detail: "secure bounded crash report head captured"
            )
        }
    }

    private func mergedEvidenceState(
        _ lhs: SteamEvidenceReadState,
        _ rhs: SteamEvidenceReadState
    ) -> SteamEvidenceReadState {
        func severity(_ state: SteamEvidenceReadState) -> Int {
            switch state {
            case .captured: 0
            case .missing: 1
            case .truncated: 2
            case .unreadable: 3
            case .changedDuringRead: 4
            case .unsafe: 5
            }
        }
        return severity(lhs) >= severity(rhs) ? lhs : rhs
    }

    private func hasSafelyScopedRuntimeCrashInputs(
        processObservationLog: URL,
        launchStdoutLog: URL?,
        launchStderrLog: URL?,
        gameRunDirectory: URL?,
        cutoff: Date?
    ) -> Bool {
        guard cutoff != nil,
              let launchStdoutLog,
              let launchStderrLog,
              let gameRunDirectory,
              gameRunDirectory.deletingLastPathComponent().lastPathComponent == "GameRuns",
              UUID(uuidString: gameRunDirectory.lastPathComponent) != nil else {
            return false
        }
        let launchDirectory = gameRunDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        return processObservationLog.deletingLastPathComponent().standardizedFileURL == launchDirectory &&
            launchStdoutLog.deletingLastPathComponent().standardizedFileURL == launchDirectory &&
            launchStderrLog.deletingLastPathComponent().standardizedFileURL == launchDirectory
    }

    private func ensureGameRunDiagnosticDirectory(_ directory: URL) throws {
        let gameRunsDirectory = directory.deletingLastPathComponent()
        let launchLogsDirectory = gameRunsDirectory.deletingLastPathComponent()
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            launchLogsDirectory,
            fileManager: fileManager
        )
        if Darwin.mkdir(gameRunsDirectory.path, S_IRWXU) != 0, errno != EEXIST {
            throw ProcessRunEvidenceWriterError.unsafeEvidencePath(gameRunsDirectory)
        }
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            gameRunsDirectory,
            fileManager: fileManager
        )
        if Darwin.mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
            throw ProcessRunEvidenceWriterError.unsafeEvidencePath(directory)
        }
        try FileSystemItemPolicy.requireNonSymlinkDirectory(directory, fileManager: fileManager)
        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: gameRunsDirectory,
            to: directory,
            fileManager: fileManager
        ) else {
            throw ProcessRunEvidenceWriterError.unsafeEvidencePath(directory)
        }
    }

    private func withGameDiagnosticCacheLock<T>(_ body: () -> T) -> T {
        gameDiagnosticCacheLock.lock()
        defer { gameDiagnosticCacheLock.unlock() }
        return body()
    }

    private func gameDiagnosticMaterialSignature(
        for diagnostic: SteamGameLaunchDiagnostic
    ) -> GameDiagnosticMaterialSignature {
        GameDiagnosticMaterialSignature(
            state: diagnostic.state,
            appID: diagnostic.appID,
            primaryProcessID: diagnostic.primaryProcessID,
            trackedProcessIDs: diagnostic.trackedProcessIDs,
            activeProcessIDs: diagnostic.activeProcessIDs,
            executable: diagnostic.executable,
            startedAt: diagnostic.startedAt,
            endedAt: diagnostic.endedAt,
            exitCodes: diagnostic.exitCodesByProcessID
                .map { "\($0.key)=\($0.value)" }
                .sorted(),
            primaryExitCode: diagnostic.primaryExitCode,
            failureProcessID: diagnostic.failureProcessID,
            failureExitCode: diagnostic.failureExitCode,
            consoleLastTask: diagnostic.consoleLastTask,
            rendererRequested: diagnostic.rendererRequested,
            rendererApplied: diagnostic.rendererApplied,
            rendererPlannedProfile: diagnostic.rendererPlannedProfile,
            rendererPlannedComponentOwnership: diagnostic.rendererPlannedComponentOwnership,
            rendererPlannedComponentsX64: diagnostic.rendererPlannedComponentsX64,
            rendererPlannedComponentsX86: diagnostic.rendererPlannedComponentsX86,
            rendererActualLoaded: diagnostic.rendererActualLoaded,
            rendererLoadedModules: diagnostic.rendererLoadedModules,
            rendererLoadedModulePaths: diagnostic.rendererLoadedModulePaths,
            rendererModuleLoadFailures: diagnostic.rendererModuleLoadFailures,
            rendererRoutingReason: diagnostic.rendererRoutingReason,
            rendererRoutingEvidence: diagnostic.rendererRoutingEvidence,
            rendererCorrelationIdentifier: diagnostic.rendererCorrelationIdentifier,
            rendererErrorStage: diagnostic.rendererErrorStage,
            rendererErrorStatusHex: diagnostic.rendererErrorStatusHex,
            rendererErrorPath: diagnostic.rendererErrorPath,
            runtimeCrashEvents: diagnostic.runtimeCrashEvents,
            runtimeCrashStdoutEvidenceState: diagnostic.runtimeCrashStdoutEvidenceState,
            runtimeCrashStdoutEvidenceDetail: diagnostic.runtimeCrashStdoutEvidenceDetail,
            runtimeCrashStderrEvidenceState: diagnostic.runtimeCrashStderrEvidenceState,
            runtimeCrashStderrEvidenceDetail: diagnostic.runtimeCrashStderrEvidenceDetail,
            runtimeCrashDedicatedEvidenceState: diagnostic.runtimeCrashDedicatedEvidenceState,
            runtimeCrashDedicatedEvidenceDetail: diagnostic.runtimeCrashDedicatedEvidenceDetail,
            gameProcessEvidenceState: diagnostic.gameProcessEvidenceState,
            consoleEvidenceState: diagnostic.consoleEvidenceState,
            processObservationEvidenceState: diagnostic.processObservationEvidenceState,
            correlatedEvidence: diagnostic.correlatedEvidence
        )
    }

    private func persistGameLaunchAttemptArtifacts(
        _ diagnostics: [SteamGameLaunchDiagnostic],
        to gameRunDirectory: URL
    ) throws {
        for diagnostic in diagnostics.suffix(maximumPersistedGameLaunchAttemptArtifacts) {
            let signature = gameDiagnosticMaterialSignature(for: diagnostic)
            let materialRevision = try gameDiagnosticMaterialRevision(for: signature)
            let attemptIdentifier = gameDiagnosticAttemptIdentifier(for: diagnostic)
            let artifactURL = gameRunDirectory.appending(
                path: "game-launch-attempt-\(attemptIdentifier)-\(materialRevision).json"
            )
            if fileManager.fileExists(atPath: artifactURL.path) {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                    artifactURL,
                    fileManager: fileManager
                )
                continue
            }
            var capturedDiagnostic = diagnostic
            capturedDiagnostic.structuredLogState = "captured"
            try ProcessRunEvidenceWriter.writeStructuredDocument(
                GameLaunchAttemptArtifact(
                    attemptIdentifier: attemptIdentifier,
                    materialRevision: materialRevision,
                    diagnostic: capturedDiagnostic
                ),
                to: artifactURL,
                fileManager: fileManager
            )
        }
        try pruneGameLaunchAttemptArtifacts(in: gameRunDirectory)
    }

    private func gameDiagnosticAttemptIdentifier(
        for diagnostic: SteamGameLaunchDiagnostic
    ) -> String {
        let appID = String((diagnostic.appID ?? "unknown").prefix(20))
        let firstProcessID = diagnostic.trackedProcessIDs.first ?? diagnostic.primaryProcessID ?? 0
        guard let startedAt = diagnostic.startedAt else {
            // A renderer setup failure can occur before Steam has a tracked
            // process or timestamp. `observedAt` changes on every support
            // refresh, so using it here would duplicate the same immutable
            // attempt artifact. Hash only stable observed error identity.
            let identity = [
                "v1-undated",
                diagnostic.state.rawValue,
                appID,
                String(firstProcessID),
                diagnostic.executable ?? "",
                diagnostic.rendererErrorStage ?? "",
                diagnostic.rendererErrorStatusHex ?? "",
                diagnostic.rendererErrorPath ?? "",
            ].joined(separator: "|")
            let digest = SHA256.hash(data: Data(identity.utf8))
                .prefix(12)
                .map { String(format: "%02x", $0) }
                .joined()
            return "v1-undated-\(digest)"
        }
        let startedSeconds = Int64(startedAt.timeIntervalSince1970.rounded(.towardZero))
        let identity = "v1|\(startedSeconds)|\(appID)|\(firstProcessID)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return String(
            format: "v1-%020lld-%@-%010d-%@",
            startedSeconds,
            appID,
            firstProcessID,
            digest
        )
    }

    private func gameDiagnosticMaterialRevision(
        for signature: GameDiagnosticMaterialSignature
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(signature)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func pruneGameLaunchAttemptArtifacts(in gameRunDirectory: URL) throws {
        let prefix = "game-launch-attempt-"
        let candidates = try fileManager.contentsOfDirectory(
            at: gameRunDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension.lowercased() == "json"
        }
        guard candidates.count > maximumPersistedGameLaunchAttemptArtifacts else { return }
        let ordered = try candidates.map { url in
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
            return (
                url,
                try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    ?? .distantPast
            )
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }
        for (url, _) in ordered.prefix(candidates.count - maximumPersistedGameLaunchAttemptArtifacts) {
            let result = url.path.withCString { Darwin.unlink($0) }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func beginCrashDumpObservationContext() -> SteamCrashDumpObservationContext {
        let context = SteamCrashDumpObservationContext(identifier: UUID())
        crashDumpObservationLock.lock()
        crashDumpScanObservationsByContext[context.identifier] = []
        crashDumpObservationLock.unlock()
        return context
    }

    func discardCrashDumpObservationContext(_ context: SteamCrashDumpObservationContext) {
        crashDumpObservationLock.lock()
        crashDumpScanObservationsByContext.removeValue(forKey: context.identifier)
        crashDumpObservationLock.unlock()
    }

    func evidenceAssessment(
        for diagnosticURL: URL
    ) -> SteamLaunchDiagnosticEvidenceAssessment? {
        let key = diagnosticURL.standardizedFileURL.path
        evidenceAssessmentLock.lock()
        defer { evidenceAssessmentLock.unlock() }
        return evidenceAssessmentsByPath[key]
    }

    func evidenceAssessment(
        for result: ProcessRunResult
    ) -> SteamLaunchDiagnosticEvidenceAssessment? {
        evidenceAssessment(for: diagnosticURL(for: result))
    }

    private func recordEvidenceAssessment(
        _ assessment: SteamLaunchDiagnosticEvidenceAssessment
    ) {
        let key = assessment.diagnosticURL.standardizedFileURL.path
        evidenceAssessmentLock.lock()
        defer { evidenceAssessmentLock.unlock() }
        evidenceAssessmentsByPath[key] = assessment
        evidenceAssessmentPathOrder.removeAll { $0 == key }
        evidenceAssessmentPathOrder.append(key)
        if evidenceAssessmentPathOrder.count > 64 {
            let removedKeys = evidenceAssessmentPathOrder.prefix(
                evidenceAssessmentPathOrder.count - 64
            )
            for removedKey in removedKeys {
                evidenceAssessmentsByPath.removeValue(forKey: removedKey)
            }
            evidenceAssessmentPathOrder.removeFirst(evidenceAssessmentPathOrder.count - 64)
        }
    }

    private func clearEvidenceAssessment(for diagnosticURL: URL) {
        let key = diagnosticURL.standardizedFileURL.path
        evidenceAssessmentLock.lock()
        defer { evidenceAssessmentLock.unlock() }
        evidenceAssessmentsByPath.removeValue(forKey: key)
        evidenceAssessmentPathOrder.removeAll { $0 == key }
    }

    func captureSteamWebHelperStartupLogCursor(in steamDirectory: URL) -> SteamWebHelperStartupLogCursor {
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        return SteamWebHelperStartupLogCursor(
            webHelperGPU: logFileCursor(
                for: logs.appending(path: "webhelper_gpu.txt"),
                allowedRoot: steamDirectory
            ),
            steamUIHTML: logFileCursor(
                for: logs.appending(path: "steamui_html.txt"),
                allowedRoot: steamDirectory
            ),
            steamLogin: logFileCursor(
                for: logs.appending(path: "steamui_login.txt"),
                allowedRoot: steamDirectory
            ),
            console: logFileCursor(
                for: logs.appending(path: "console_log.txt"),
                allowedRoot: steamDirectory
            ),
            webHelper: logFileCursor(
                for: logs.appending(path: "webhelper.txt"),
                allowedRoot: steamDirectory
            ),
            shaderLog: logFileCursor(
                for: logs.appending(path: "shader_log.txt"),
                allowedRoot: steamDirectory
            )
        )
    }

    func waitForSteamWebHelperStartup(
        in steamDirectory: URL,
        since cursor: SteamWebHelperStartupLogCursor,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async -> SteamWebHelperStartupObservation {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let sleepNanoseconds = UInt64(max(0.1, pollInterval) * 1_000_000_000)
        while !Task.isCancelled && Date() < deadline {
            let observation = detectSteamWebHelperStartup(in: steamDirectory, since: cursor)
            if observation.state != .pending {
                return observation
            }
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                break
            }
        }
        var observation = detectSteamWebHelperStartup(in: steamDirectory, since: cursor)
        if observation.state == .pending {
            observation.state = .timedOut
        }
        return observation
    }

    func detectSteamWebHelperStartup(
        in steamDirectory: URL,
        since cursor: SteamWebHelperStartupLogCursor
    ) -> SteamWebHelperStartupObservation {
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let steamUIHTMLRead = appendedTailReadResult(
            from: logs.appending(path: "steamui_html.txt"),
            since: cursor.steamUIHTML,
            limit: 160,
            allowedRoot: steamDirectory
        )
        let consoleRead = appendedTailReadResult(
            from: logs.appending(path: "console_log.txt"),
            since: cursor.console,
            limit: 160,
            allowedRoot: steamDirectory
        )
        let webHelperRead = appendedTailReadResult(
            from: logs.appending(path: "webhelper.txt"),
            since: cursor.webHelper,
            limit: 160,
            allowedRoot: steamDirectory
        )
        let steamUIHTMLTail = steamUIHTMLRead.diagnosticLines(limit: 160)
        let consoleTail = consoleRead.diagnosticLines(limit: 160)
        let webHelperTail = webHelperRead.diagnosticLines(limit: 160)
        let unavailableReads = [
            ("steamui_html.txt", steamUIHTMLRead),
            ("console_log.txt", consoleRead),
            ("webhelper.txt", webHelperRead)
        ].filter { $0.1.invalidatesHardGateSuccess }
        if !unavailableReads.isEmpty {
            let detail = unavailableReads.map {
                "\($0.0)=\($0.1.state.rawValue) (\($0.1.detail))"
            }.joined(separator: "; ")
            return SteamWebHelperStartupObservation(
                state: .evidenceUnavailable,
                reason: "Steam WebHelper startup evidence is incomplete: \(detail)",
                steamUIHTMLTail: steamUIHTMLTail,
                consoleTail: consoleTail,
                webHelperTail: webHelperTail
            )
        }
        let steamUIHTML = steamUIHTMLTail.joined(separator: "\n").lowercased()
        let console = consoleTail.joined(separator: "\n").lowercased()
        let webHelper = webHelperTail.joined(separator: "\n").lowercased()

        let failureReason: String?
        if console.contains("failed creating offscreen shared js context") {
            failureReason = "Steam failed creating its offscreen shared JavaScript context"
        } else if steamUIHTML.contains("timed out waiting for webhelper init") {
            failureReason = "Steam timed out waiting for WebHelper initialization"
        } else {
            failureReason = nil
        }
        if let failureReason {
            return SteamWebHelperStartupObservation(
                state: .retryableFailure,
                reason: failureReason,
                steamUIHTMLTail: steamUIHTMLTail,
                consoleTail: consoleTail,
                webHelperTail: webHelperTail
            )
        }

        if steamUIHTML.contains("browserready: handle:") ||
            webHelper.contains("starting message loop") {
            return SteamWebHelperStartupObservation(
                state: .ready,
                reason: nil,
                steamUIHTMLTail: steamUIHTMLTail,
                consoleTail: consoleTail,
                webHelperTail: webHelperTail
            )
        }

        return SteamWebHelperStartupObservation(
            state: .pending,
            reason: nil,
            steamUIHTMLTail: steamUIHTMLTail,
            consoleTail: consoleTail,
            webHelperTail: webHelperTail
        )
    }

    func writeDiagnostics(
        for result: ProcessRunResult,
        preflightShutdown: ProcessRunResult?,
        failureShutdown: ProcessRunResult?,
        failureShutdownError: Error?,
        priorLaunchAttempts: [SteamLaunchAttemptEvidence] = [],
        dumps: [URL],
        steamDirectory: URL,
        renderingIssue: SteamWebHelperRenderingIssue?,
        hostSteamProcesses: [MacOSSteamProcess] = [],
        hostSteamProcessesBefore: [MacOSSteamProcess] = [],
        hostSteamProcessesAfter: [MacOSSteamProcess] = [],
        externalApplicationRunnerProcesses: [SteamLaunchObservedProcess] = [],
        externalApplicationRunnerProcessesBefore: [SteamLaunchObservedProcess] = [],
        externalApplicationRunnerProcessesAfter: [SteamLaunchObservedProcess] = [],
        processSnapshotBefore: [SteamLaunchObservedProcess] = [],
        processSnapshotAfter: [SteamLaunchObservedProcess] = [],
        launchTarget: SteamLaunchTarget? = nil,
        runnerCapability: WindowsRuntimeCapability? = nil,
        runnerVersionEvidence: String = "not captured; SUCCESS forbidden without wine --version evidence\n",
        dumpsBefore: [URL] = [],
        dumpsAfter explicitDumpsAfter: [URL]? = nil,
        gateStatus explicitGateStatus: SteamLaunchGateStatus? = nil,
        reasonCodes: [SteamLaunchGateReasonCode] = [],
        hardGateFailureReasons: [String] = [],
        webHelperCommandLines: [String] = [],
        screenEvidence: SteamLaunchScreenEvidence = .notCaptured("screen evidence was not collected"),
        launchEnvironmentSummary: [String],
        logCursor: SteamWebHelperStartupLogCursor? = nil,
        crashDumpObservationContext: SteamCrashDumpObservationContext? = nil,
        since cutoff: Date
    ) throws -> URL {
        let diagnosticURL = diagnosticURL(for: result)
        clearEvidenceAssessment(for: diagnosticURL)
        let evidenceDirectory = hardGateEvidenceDirectoryURL(for: diagnosticURL)
        let completionMarker = evidenceDirectory.appending(path: "capture-complete.txt")
        try removeCompletionMarkerIfPresent(completionMarker)
        let dumpsAfter = explicitDumpsAfter ?? dumps
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let stdoutRead = tailReadResult(from: result.stdoutLog, limit: 40)
        let stderrRead = tailReadResult(from: result.stderrLog, limit: 120)
        let priorAttemptReads = priorLaunchAttempts.map { attempt in
            PriorLaunchAttemptRead(
                attempt: attempt,
                stdout: tailReadResult(from: attempt.result.stdoutLog, limit: 40),
                stderr: tailReadResult(from: attempt.result.stderrLog, limit: 120),
                runMetadata: attempt.result.runEvidenceLog.map {
                    tailReadResult(from: $0, limit: 160)
                }
            )
        }
        let webHelperGPURead = renderingIssue.map {
            SteamLogReadResult(
                state: $0.webHelperGPUEvidence.state,
                lines: $0.webHelperGPUTail,
                detail: $0.webHelperGPUEvidence.detail
            )
        } ?? logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "webhelper_gpu.txt"),
                since: $0.webHelperGPU,
                limit: 80,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "webhelper_gpu.txt"),
            limit: 80,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let steamUIHTMLRead = renderingIssue.map {
            SteamLogReadResult(
                state: $0.steamUIHTMLEvidence.state,
                lines: $0.steamUIHTMLTail,
                detail: $0.steamUIHTMLEvidence.detail
            )
        } ?? logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "steamui_html.txt"),
                since: $0.steamUIHTML,
                limit: 80,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "steamui_html.txt"),
            limit: 80,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let steamLoginRead = renderingIssue.map {
            SteamLogReadResult(
                state: $0.steamLoginEvidence.state,
                lines: $0.steamLoginTail,
                detail: $0.steamLoginEvidence.detail
            )
        } ?? logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "steamui_login.txt"),
                since: $0.steamLogin,
                limit: 80,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "steamui_login.txt"),
            limit: 80,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let consoleRead = renderingIssue.map {
            SteamLogReadResult(
                state: $0.consoleEvidence.state,
                lines: $0.consoleTail,
                detail: $0.consoleEvidence.detail
            )
        } ?? logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "console_log.txt"),
                since: $0.console,
                limit: 80,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "console_log.txt"),
            limit: 80,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let webHelperRead = renderingIssue.map {
            SteamLogReadResult(
                state: $0.webHelperEvidence.state,
                lines: $0.webHelperTail,
                detail: $0.webHelperEvidence.detail
            )
        } ?? logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "webhelper.txt"),
                since: $0.webHelper,
                limit: 80,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "webhelper.txt"),
            limit: 80,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let shaderLogRead = logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "shader_log.txt"),
                since: $0.shaderLog,
                limit: 80,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "shader_log.txt"),
            limit: 80,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let bootstrapRead = tailReadResult(
            from: logs.appending(path: "bootstrap_log.txt"),
            limit: 120,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let stderrTail = stderrRead.diagnosticLines(limit: 120)
        let webHelperGPUTail = webHelperGPURead.diagnosticLines(limit: 80)
        let steamUIHTMLTail = steamUIHTMLRead.diagnosticLines(limit: 80)
        let steamLoginTail = steamLoginRead.diagnosticLines(limit: 80)
        let consoleTail = consoleRead.diagnosticLines(limit: 80)
        let webHelperTail = webHelperRead.diagnosticLines(limit: 80)
        let shaderLogTail = shaderLogRead.diagnosticLines(limit: 80)
        let currentAttemptSourceReads: [(label: String, url: URL, result: SteamLogReadResult, required: Bool)] = [
            ("process stdout", result.stdoutLog, stdoutRead, true),
            ("process stderr", result.stderrLog, stderrRead, true),
            ("bootstrap_log.txt", logs.appending(path: "bootstrap_log.txt"), bootstrapRead, false),
            ("webhelper_gpu.txt", logs.appending(path: "webhelper_gpu.txt"), webHelperGPURead, false),
            ("steamui_html.txt", logs.appending(path: "steamui_html.txt"), steamUIHTMLRead, false),
            ("steamui_login.txt", logs.appending(path: "steamui_login.txt"), steamLoginRead, false),
            ("console_log.txt", logs.appending(path: "console_log.txt"), consoleRead, false),
            ("webhelper.txt", logs.appending(path: "webhelper.txt"), webHelperRead, false),
            ("shader_log.txt", logs.appending(path: "shader_log.txt"), shaderLogRead, false)
        ]
        let priorAttemptSourceReads: [(label: String, url: URL, result: SteamLogReadResult, required: Bool)] =
            priorAttemptReads.flatMap { read in
                var sources: [(label: String, url: URL, result: SteamLogReadResult, required: Bool)] = [
                    (
                        "prior launch attempt \(read.attempt.sequence) stdout",
                        read.attempt.result.stdoutLog,
                        read.stdout,
                        true
                    ),
                    (
                        "prior launch attempt \(read.attempt.sequence) stderr",
                        read.attempt.result.stderrLog,
                        read.stderr,
                        true
                    )
                ]
                if let runEvidenceLog = read.attempt.result.runEvidenceLog,
                   let runMetadata = read.runMetadata {
                    sources.append((
                        "prior launch attempt \(read.attempt.sequence) run metadata",
                        runEvidenceLog,
                        runMetadata,
                        true
                    ))
                }
                return sources
            }
        let sourceReads = currentAttemptSourceReads + priorAttemptSourceReads
        let dumpScanObservations = takeCrashDumpScanObservations(
            for: crashDumpObservationContext
        )
        let sourceReadFailures = sourceReads.filter {
            $0.result.invalidatesHardGateSuccess || ($0.required && $0.result.state == .missing)
        }
        let dumpScanFailures = dumpScanObservations.filter(\.isIncomplete)
        let missingPriorRunMetadataFailures = priorAttemptReads.compactMap { read in
            read.attempt.result.runEvidenceLog == nil
                ? "prior launch attempt \(read.attempt.sequence) run metadata was not captured"
                : nil
        }
        let priorEvidenceCaptureFailures = priorAttemptReads.compactMap { read in
            read.attempt.result.evidenceCaptureWarning.map {
                "prior launch attempt \(read.attempt.sequence) process evidence capture warning: \($0)"
            }
        }
        let evidenceFailureDescriptions = sourceReadFailures.map {
            "\($0.label) evidence \($0.result.state.rawValue): \($0.result.detail)"
        } + dumpScanFailures.map {
            "crash dump scan \($0.state.rawValue): \($0.detail)"
        } + missingPriorRunMetadataFailures + priorEvidenceCaptureFailures
        let diagnosticFailureReasons = hardGateFailureReasons + evidenceFailureDescriptions.map {
            "diagnostic-evidence-incomplete: \($0)"
        }
        let requestedGateStatus = explicitGateStatus ?? (
            result.succeeded && hardGateFailureReasons.isEmpty ? .success : .failed
        )
        let diagnosticGateStatus: SteamLaunchGateStatus = if requestedGateStatus == .success,
                                                             !evidenceFailureDescriptions.isEmpty {
            .failed
        } else {
            requestedGateStatus
        }
        let findings = steamLaunchFindings(
            stderrTail: stderrTail,
            webHelperGPUTail: webHelperGPUTail,
            steamUIHTMLTail: steamUIHTMLTail,
            steamLoginTail: steamLoginTail,
            consoleTail: consoleTail,
            webHelperTail: webHelperTail,
            shaderLogTail: shaderLogTail,
            hostSteamProcesses: hostSteamProcesses + hostSteamProcessesBefore + hostSteamProcessesAfter,
            externalApplicationRunnerProcesses: externalApplicationRunnerProcesses + externalApplicationRunnerProcessesBefore + externalApplicationRunnerProcessesAfter,
            allowsHostSteam: launchTarget?.allowHostSteam == true,
            gateStatus: diagnosticGateStatus,
            hardGateFailureReasons: diagnosticFailureReasons,
            evidenceFailureDescriptions: evidenceFailureDescriptions
        )
        var lines = [
            "ForgePlay Steam launch diagnostics",
            "Raw stdout log: \(result.stdoutLog.path)",
            "Raw stderr log: \(result.stderrLog.path)",
            "Steam directory: \(steamDirectory.path)",
            "Hard gate evidence directory: \(evidenceDirectory.path)",
            "Process exit code: \(result.diagnosticExitCodeDescription)",
            "ForgePlay status code: \(result.diagnosticForgePlayStatusDescription)",
            "Timed out: \(result.didTimeOut)",
            "Waited for exit: \(result.waitedForExit)",
            ""
        ]
        if let launchTarget {
            lines.append("Hard gate target:")
            lines.append("- Expected runner: \(launchTarget.normalizedRunnerPath)")
            lines.append("- Expected WINEPREFIX: \(launchTarget.normalizedPrefixPath)")
            lines.append("- Expected Windows Steam executable: \(launchTarget.normalizedSteamExecutablePath)")
            lines.append("- Host Steam allowed: \(launchTarget.allowHostSteam)")
            lines.append("- External app-bundled runner allowed: false")
            lines.append("")
        }
        lines.append("Hard gate result:")
        lines.append("- Status: \(diagnosticGateStatus.rawValue)")
        if !diagnosticFailureReasons.isEmpty {
            lines.append(contentsOf: diagnosticFailureReasons.map { "- \($0)" })
        }
        lines.append("")
        lines.append("Steam evidence source status:")
        for source in sourceReads {
            lines.append(
                "- \(source.label): \(source.result.state.rawValue); \(source.url.path); \(source.result.detail)"
            )
        }
        if dumpScanObservations.isEmpty {
            lines.append("- crash dump scan: not recorded by this reporter invocation")
        } else {
            lines.append(contentsOf: dumpScanObservations.map(\.diagnosticLine))
        }
        lines.append("")
        if !launchEnvironmentSummary.isEmpty {
            lines.append("Launch graphics/runtime environment:")
            lines.append(contentsOf: launchEnvironmentSummary)
            lines.append("")
        }
        if let preflightShutdown {
            lines.append("Pre-launch Steam Prefix process shutdown:")
            lines.append("- Process exit code: \(preflightShutdown.diagnosticExitCodeDescription)")
            lines.append("- ForgePlay status code: \(preflightShutdown.diagnosticForgePlayStatusDescription)")
            lines.append("- Timed out: \(preflightShutdown.didTimeOut)")
            lines.append("- stdout: \(preflightShutdown.stdoutLog.path)")
            lines.append("- stderr: \(preflightShutdown.stderrLog.path)")
            lines.append("")
        }
        if let failureShutdown {
            lines.append("Post-failure Steam Prefix process shutdown:")
            lines.append("- Process exit code: \(failureShutdown.diagnosticExitCodeDescription)")
            lines.append("- ForgePlay status code: \(failureShutdown.diagnosticForgePlayStatusDescription)")
            lines.append("- Timed out: \(failureShutdown.didTimeOut)")
            lines.append("- stdout: \(failureShutdown.stdoutLog.path)")
            lines.append("- stderr: \(failureShutdown.stderrLog.path)")
            lines.append("")
        } else if let failureShutdownError {
            lines.append("Post-failure Steam Prefix process shutdown:")
            lines.append("- Failed to run shutdown command: \(forgePlayTechnicalErrorSummary(failureShutdownError))")
            lines.append("")
        }

        if result.steamUIStartupRecoveryAttemptCount > 0 {
            lines.append("Steam UI startup recovery:")
            lines.append("- Automatic restart attempts: \(result.steamUIStartupRecoveryAttemptCount)")
            if let reason = result.steamUIStartupRecoveryReason {
                lines.append("- Trigger: \(reason)")
            }
            lines.append("- ForgePlay stopped the failed Steam/Wine prefix before relaunching the same bundled runtime and managed prefix.")
            lines.append("")
        }

        if !priorAttemptReads.isEmpty {
            lines.append("Prior Steam launch attempts preserved for this relaunch chain:")
            for read in priorAttemptReads {
                let attempt = read.attempt
                lines.append("- Attempt \(attempt.sequence): relaunch reason=\(attempt.relaunchReason.rawValue)")
                lines.append("  run identifier: \(attempt.runIdentifier)")
                lines.append("  process exit code: \(attempt.result.diagnosticExitCodeDescription)")
                lines.append("  ForgePlay status code: \(attempt.result.diagnosticForgePlayStatusDescription)")
                lines.append("  outcome: \(attempt.result.outcome.rawValue)")
                lines.append("  stdout: \(attempt.result.stdoutLog.path) [\(read.stdout.state.rawValue)]")
                lines.append("  stderr: \(attempt.result.stderrLog.path) [\(read.stderr.state.rawValue)]")
                lines.append("  run metadata: \(attempt.result.runEvidenceLog?.path ?? "not captured") [\(read.runMetadata?.state.rawValue ?? "missing")]")
                lines.append("  process observation: \(attempt.result.processObservationLog?.path ?? "not captured")")
                lines.append("  renderer logs: \(attempt.rendererLogDirectory.path)")
                if let shutdown = attempt.preLaunchShutdownResult {
                    lines.append("  pre-launch shutdown run metadata: \(shutdown.runEvidenceLog?.path ?? "not captured")")
                    if !shutdown.relatedRunEvidenceLogs.isEmpty {
                        lines.append("  pre-launch shutdown related run metadata: \(shutdown.relatedRunEvidenceLogs.map(\.path).joined(separator: " | "))")
                    }
                }
                if attempt.crashDumpsObserved.isEmpty {
                    lines.append("  newly observed crash dumps: none safely fingerprinted during this attempt")
                } else {
                    lines.append("  newly observed crash dumps: \(attempt.crashDumpsObserved.map(\.path).joined(separator: " | "))")
                }
                let attemptStderrTail = read.stderr.diagnosticLines(limit: 20)
                if !attemptStderrTail.isEmpty {
                    lines.append("  stderr tail:")
                    lines.append(contentsOf: attemptStderrTail.map { "    \($0)" })
                }
            }
            lines.append("")
        }

        let allHostSteamProcesses = hostSteamProcessesBefore + hostSteamProcessesAfter + hostSteamProcesses
        if !allHostSteamProcesses.isEmpty {
            lines.append(launchTarget?.allowHostSteam == true
                ? "Host macOS Steam process evidence (allowed for operational launch):"
                : "Host macOS Steam process contamination:")
            for process in allHostSteamProcesses.prefix(12) {
                lines.append("- PID \(process.processID): \(process.command)")
            }
            lines.append("")
        }

        let allExternalRunnerProcesses = externalApplicationRunnerProcessesBefore + externalApplicationRunnerProcessesAfter + externalApplicationRunnerProcesses
        if !allExternalRunnerProcesses.isEmpty {
            let externalRunnerHeading = if launchTarget?.allowHostSteam == true {
                "External app-bundled runner process evidence (not used by this operational launch):"
            } else {
                "External app-bundled runner process contamination:"
            }
            lines.append(externalRunnerHeading)
            for process in allExternalRunnerProcesses.prefix(12) {
                lines.append("- \(process.diagnosticLine)")
            }
            lines.append("")
        }

        lines.append("Interpreted findings:")
        if findings.isEmpty {
            lines.append("- No known ForgePlay runtime pattern was detected in the captured tails.")
        } else {
            lines.append(contentsOf: findings.map { "- \($0)" })
        }
        lines.append("")

        if dumps.isEmpty, !dumpScanFailures.isEmpty {
            lines.append("Steam crash dumps: none confirmed; crash dump inspection was incomplete. Do not interpret this as no crash dump was produced.")
        } else if dumps.isEmpty,
                  !dumpScanObservations.isEmpty,
                  dumpScanObservations.allSatisfy({ $0.state == .missing }) {
            lines.append("Steam crash dumps: none detected because the dumps directory was missing at each recorded scan point.")
        } else if dumps.isEmpty {
            lines.append("Steam crash dumps: none detected after this launch.")
        } else {
            lines.append("ForgePlay detected Steam crash dump(s) after launch. Windows Steam did not stay alive under the bundled ForgePlay Runtime.")
            for dump in dumps.prefix(6) {
                let summary = minidumpExceptionSummary(at: dump, allowedRoot: steamDirectory)
                lines.append("- \(dump.path)\(summary.map { " (\($0))" } ?? "")")
            }
            if !dumpScanFailures.isEmpty {
                lines.append("- Additional dump evidence may be unavailable because at least one dump scan was incomplete.")
            }
        }
        let assertDumps = dumpsAfter.filter { $0.lastPathComponent.lowercased().hasPrefix("assert_") }
        if !assertDumps.isEmpty {
            lines.append("")
            lines.append("Steam assert dumps: recorded as stability warning, not fatal crash evidence.")
            for dump in assertDumps.prefix(6) {
                lines.append("- \(dump.path)")
            }
        }

        if renderingIssue != nil {
            lines.append("")
            if failureShutdown != nil {
                lines.append("ForgePlay detected an unusable Windows Steam CEF/WebHelper rendering state after this launch. Windows Steam was stopped because the visible Steam window is expected to be black or unusable.")
            } else {
                lines.append("ForgePlay detected Windows Steam CEF/WebHelper rendering warnings after launch and marked this launch unusable. No post-failure shutdown was needed because the launch command had already returned.")
            }
        }

        if !hostSteamProcesses.isEmpty, launchTarget?.allowHostSteam != true {
            lines.append("")
            if reasonCodes.contains(.steamBootstrapUpdateInProgress) {
                lines.append("ForgePlay detected that macOS Steam.app appeared during the Windows Steam bootstrap update. This was recorded as host evidence; Windows Steam was left running and UI verification is deferred.")
            } else {
                lines.append("ForgePlay detected that macOS Steam.app started during this Windows Steam launch. This launch is invalid and was not counted as Windows Steam UI rendering success.")
            }
        }
        if !allExternalRunnerProcesses.isEmpty,
           launchTarget?.allowHostSteam != true {
            lines.append("")
            lines.append("ForgePlay detected an external app-bundled Wine/Steam process during this Windows Steam launch. This launch is invalid for ForgePlay target validation and was not counted as Windows Steam UI rendering success.")
        }

        lines.append("")
        lines.append("Raw stderr tail:")
        lines.append(contentsOf: stderrTail)
        if !webHelperGPUTail.isEmpty {
            lines.append("")
            lines.append("Steam webhelper GPU log tail:")
            lines.append(contentsOf: webHelperGPUTail)
        }
        if !steamUIHTMLTail.isEmpty {
            lines.append("")
            lines.append("Steam UI HTML log tail:")
            lines.append(contentsOf: steamUIHTMLTail)
        }
        if !steamLoginTail.isEmpty {
            lines.append("")
            lines.append("Steam login log tail:")
            lines.append(contentsOf: steamLoginTail)
        }
        if !consoleTail.isEmpty {
            lines.append("")
            lines.append("Steam console log tail:")
            lines.append(contentsOf: consoleTail)
        }
        if !webHelperTail.isEmpty {
            lines.append("")
            lines.append("Steam WebHelper log tail:")
            lines.append(contentsOf: webHelperTail)
        }
        if !shaderLogTail.isEmpty {
            lines.append("")
            lines.append("Steam shader log tail:")
            lines.append(contentsOf: shaderLogTail)
        }
        lines.append("")

        try writeHardGateEvidenceDirectory(
            evidenceDirectory,
            diagnosticURL: diagnosticURL,
            result: result,
            launchTarget: launchTarget,
            runnerCapability: runnerCapability,
            runnerVersionEvidence: runnerVersionEvidence,
            gateStatus: diagnosticGateStatus,
            reasonCodes: reasonCodes,
            hardGateFailureReasons: diagnosticFailureReasons,
            processSnapshotBefore: processSnapshotBefore,
            processSnapshotAfter: processSnapshotAfter,
            hostSteamProcessesBefore: hostSteamProcessesBefore,
            hostSteamProcessesAfter: hostSteamProcessesAfter,
            externalApplicationRunnerProcessesBefore: externalApplicationRunnerProcessesBefore,
            externalApplicationRunnerProcessesAfter: externalApplicationRunnerProcessesAfter,
            webHelperCommandLines: webHelperCommandLines,
            screenEvidence: screenEvidence,
            priorLaunchAttempts: priorLaunchAttempts,
            stderrTail: stderrTail,
            bootstrapTail: bootstrapRead.diagnosticLines(limit: 120),
            webHelperGPUTail: webHelperGPUTail,
            steamUIHTMLTail: steamUIHTMLTail,
            steamLoginTail: steamLoginTail,
            dumpsBefore: dumpsBefore,
            dumpsAfter: dumpsAfter
        )
        try writeDiagnosticText(lines.joined(separator: "\n") + "\n", to: diagnosticURL)
        try writeDiagnosticText(
            "ForgePlay Steam diagnostic evidence capture completed.\n",
            to: completionMarker
        )
        recordEvidenceAssessment(
            SteamLaunchDiagnosticEvidenceAssessment(
                diagnosticURL: diagnosticURL,
                completeness: evidenceFailureDescriptions.isEmpty ? .complete : .incomplete,
                failureDescriptions: evidenceFailureDescriptions,
                requestedGateStatus: requestedGateStatus,
                reportedGateStatus: diagnosticGateStatus
            )
        )
        return diagnosticURL
    }

    /// Writes a small, explicit fallback artifact when the full evidence report
    /// cannot be completed. The caller still receives the original error and
    /// stores it on the launch record; this file prevents a silent fallback to an
    /// unrelated stderr log when only part of the diagnostic pipeline failed.
    func writeDiagnosticsFailureFallback(
        for result: ProcessRunResult,
        error: Error
    ) throws -> URL {
        let url = diagnosticURL(for: result)
        let terminationSignal = result.terminationSignal.map(String.init) ?? "none"
        let lines = [
            "ForgePlay Steam diagnostics capture failure",
            "Action: \(result.actionName)",
            "Started at: \(Self.iso8601String(from: result.startedAt))",
            "Ended at: \(Self.iso8601String(from: result.endedAt))",
            "Process exit code: \(result.diagnosticExitCodeDescription)",
            "ForgePlay status code: \(result.diagnosticForgePlayStatusDescription)",
            "Outcome: \(result.outcome.rawValue)",
            "Termination signal: \(terminationSignal)",
            "Timed out: \(result.didTimeOut)",
            "Waited for exit: \(result.waitedForExit)",
            "Raw stdout log: \(result.stdoutLog.path)",
            "Raw stderr log: \(result.stderrLog.path)",
            "Capture error: \(forgePlayTechnicalErrorSummary(error))",
            "",
            "The full diagnostics report is incomplete. Do not interpret its absence as no issue detected."
        ]
        try writeDiagnosticText(lines.joined(separator: "\n") + "\n", to: url)
        recordEvidenceAssessment(
            SteamLaunchDiagnosticEvidenceAssessment(
                diagnosticURL: url,
                completeness: .incomplete,
                failureDescriptions: [
                    "full diagnostics capture failed: \(forgePlayTechnicalErrorSummary(error))"
                ],
                requestedGateStatus: nil,
                reportedGateStatus: .failed
            )
        )
        return url
    }

    private func writeDiagnosticText(_ text: String, to url: URL) throws {
        let handle = try SafeProcessRunner.openLogFileHandle(at: url, fileManager: fileManager)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }

    private func removeCompletionMarkerIfPresent(_ url: URL) throws {
        let exists = fileManager.fileExists(atPath: url.path)
        let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard exists || isSymbolicLink else { return }
        guard !isSymbolicLink,
              FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fileManager.removeItem(at: url)
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func captureScreenEvidence(for result: ProcessRunResult) -> SteamLaunchScreenEvidence {
        let evidenceDirectory = hardGateEvidenceDirectoryURL(for: diagnosticURL(for: result))
        let screenshotURL = evidenceDirectory.appending(path: "screen-final.png")
        do {
            try fileManager.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        } catch {
            return SteamLaunchScreenEvidence(
                screenshotURL: screenshotURL,
                state: .captureFailed,
                recognizedText: [],
                message: "screen evidence directory could not be created: \(forgePlayTechnicalErrorSummary(error))"
            )
        }

        try? fileManager.removeItem(at: screenshotURL)
        let externalScreenshotPath = ProcessInfo.processInfo.environment["FORGEPLAY_EXTERNAL_SCREENSHOT_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredExternalScreenshotPath = externalScreenshotPath?.isEmpty == false ? externalScreenshotPath : nil
        let externalScreenshotFailure: String?
        if let configuredExternalScreenshotPath {
            externalScreenshotFailure = waitForExternalScreenshot(
                at: URL(fileURLWithPath: configuredExternalScreenshotPath),
                destination: screenshotURL
            )
        } else {
            externalScreenshotFailure = nil
        }
        if configuredExternalScreenshotPath == nil || externalScreenshotFailure != nil {
            let directCaptureFailure = runScreenCaptureCommand(
                executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                arguments: ["-x", screenshotURL.path]
            )
            if let directFailure = directCaptureFailure {
                try? fileManager.removeItem(at: screenshotURL)
                let shellCommand = "/usr/sbin/screencapture -x \(Self.shellQuoted(screenshotURL.path))"
                let script = "do shell script \(Self.appleScriptStringLiteral(shellCommand))"
                let fallbackCaptureFailure = runScreenCaptureCommand(
                    executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", script]
                )
                if let fallbackFailure = fallbackCaptureFailure {
                    let windowCaptureFailure = captureSteamWindowImage(to: screenshotURL)
                    if windowCaptureFailure == nil {
                        return verifyScreenEvidence(at: screenshotURL)
                    }
                    if let externalScreenshotFailure {
                        return SteamLaunchScreenEvidence(
                            screenshotURL: screenshotURL,
                            state: .captureFailed,
                            recognizedText: [],
                            message: "external screenshot handoff failed: \(externalScreenshotFailure); screencapture failed: \(directFailure); osascript screencapture fallback failed: \(fallbackFailure); window capture failed: \(windowCaptureFailure ?? "unknown")"
                        )
                    }
                    return SteamLaunchScreenEvidence(
                        screenshotURL: screenshotURL,
                        state: .captureFailed,
                        recognizedText: [],
                        message: "screencapture failed: \(directFailure); osascript screencapture fallback failed: \(fallbackFailure); window capture failed: \(windowCaptureFailure ?? "unknown")"
                    )
                }
            }
        }
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(screenshotURL, fileManager: fileManager) else {
            let windowCaptureFailure = captureSteamWindowImage(to: screenshotURL)
            if windowCaptureFailure == nil {
                return verifyScreenEvidence(at: screenshotURL)
            }
            return SteamLaunchScreenEvidence(
                screenshotURL: screenshotURL,
                state: .captureFailed,
                recognizedText: [],
                message: "screencapture reported success but screen-final.png was not created; window capture failed: \(windowCaptureFailure ?? "unknown")"
            )
        }

        return verifyScreenEvidence(at: screenshotURL)
    }

    private func verifyScreenEvidence(at screenshotURL: URL) -> SteamLaunchScreenEvidence {
        let recognizedText: [String]
        do {
            recognizedText = try recognizeText(in: screenshotURL)
        } catch {
            return SteamLaunchScreenEvidence(
                screenshotURL: screenshotURL,
                state: .recognitionFailed,
                recognizedText: [],
                message: "screen-final.png OCR failed: \(forgePlayTechnicalErrorSummary(error))"
            )
        }
        let qrCodeDetection: Result<Bool, Error> = Result {
            try containsQRCode(in: screenshotURL)
        }
        return Self.screenEvidenceAfterRecognition(
            screenshotURL: screenshotURL,
            recognizedText: recognizedText,
            qrCodeDetection: qrCodeDetection
        )
    }

    static func screenEvidenceAfterRecognition(
        screenshotURL: URL,
        recognizedText: [String],
        qrCodeDetection: Result<Bool, Error>
    ) -> SteamLaunchScreenEvidence {
        let containsQRCode: Bool
        switch qrCodeDetection {
        case .success(let value):
            containsQRCode = value
        case .failure(let error):
            return SteamLaunchScreenEvidence(
                screenshotURL: screenshotURL,
                state: .recognitionFailed,
                recognizedText: recognizedText,
                message: "screen-final.png QR code detector failed; visible Steam UI verification is unavailable: \(forgePlayTechnicalErrorSummary(error))"
            )
        }
        if let surface = windowsSteamUISurface(
            in: recognizedText,
            containsQRCode: containsQRCode
        ) {
            return SteamLaunchScreenEvidence(
                screenshotURL: screenshotURL,
                state: .verifiedWindowsSteamUI,
                surface: surface,
                recognizedText: recognizedText,
                message: "Windows Steam \(surface.rawValue) UI was recognized in screen-final.png"
            )
        }
        return SteamLaunchScreenEvidence(
            screenshotURL: screenshotURL,
            state: .steamUITextNotRecognized,
            recognizedText: recognizedText,
            message: "screen-final.png was captured, but Windows Steam login, Steam Guard, or Library UI text was not recognized"
        )
    }

    private func captureSteamWindowImage(to destination: URL) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        final class CaptureBox: @unchecked Sendable {
            var result: String?
        }
        let box = CaptureBox()
        Task {
            box.result = await captureSteamWindowImageWithScreenCaptureKit(to: destination)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 12) == .success else {
            return "ScreenCaptureKit window capture timed out"
        }
        return box.result
    }

    private func captureSteamWindowImageWithScreenCaptureKit(to destination: URL) async -> String? {
        do {
            let content = try await SCShareableContent.current
            let candidates = content.windows.compactMap { window -> (window: SCWindow, score: Int, description: String)? in
                let owner = window.owningApplication?.applicationName ?? ""
                let title = window.title ?? ""
                let ownerLower = owner.lowercased()
                let titleLower = title.lowercased()
                guard ownerLower.contains("wine") || titleLower.contains("steam") else {
                    return nil
                }
                guard window.windowLayer == 0, window.isOnScreen else {
                    return nil
                }
                guard window.frame.width >= 320, window.frame.height >= 240 else {
                    return nil
                }
                var score = 0
                if titleLower.contains("sign in to steam") { score += 100 }
                if titleLower.contains("steam") { score += 50 }
                if ownerLower == "wine" { score += 10 }
                return (window, score, "\(owner): \(title) \(Int(window.frame.width))x\(Int(window.frame.height))")
            }
            guard let candidate = candidates.max(by: { $0.score < $1.score }) else {
                return "no onscreen Steam/Wine window candidate found"
            }

            let filter = SCContentFilter(desktopIndependentWindow: candidate.window)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(max(1, SCShareableContent.info(for: filter).pointPixelScale))
            configuration.width = max(1, Int((candidate.window.frame.width * scale).rounded(.up)))
            configuration.height = max(1, Int((candidate.window.frame.height * scale).rounded(.up)))
            configuration.showsCursor = false
            configuration.scalesToFit = false

            let image = try await captureImage(contentFilter: filter, configuration: configuration)
            try? fileManager.removeItem(at: destination)
            guard let destinationRef = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return "CGImageDestinationCreateWithURL failed for \(destination.path)"
            }
            CGImageDestinationAddImage(destinationRef, image, nil)
            guard CGImageDestinationFinalize(destinationRef) else {
                return "CGImageDestinationFinalize failed for \(destination.path)"
            }
            return nil
        } catch {
            return "ScreenCaptureKit window capture failed: \(forgePlayTechnicalErrorSummary(error))"
        }
    }

    private func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func waitForExternalScreenshot(at source: URL, destination: URL) -> String? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileSystemItemPolicy.isRegularNonSymlinkFile(source, fileManager: fileManager) {
                do {
                    if source.standardizedFileURL.path != destination.standardizedFileURL.path {
                        try? fileManager.removeItem(at: destination)
                        try fileManager.copyItem(at: source, to: destination)
                    }
                    return nil
                } catch {
                    return "could not copy \(source.path) to \(destination.path): \(forgePlayTechnicalErrorSummary(error))"
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return "timed out waiting for \(source.path)"
    }

    private func runScreenCaptureCommand(executable: URL, arguments: [String]) -> String? {
        let capture: BoundedProcessCaptureResult
        do {
            capture = try BoundedProcessExecutor.capture(
                executable: executable,
                arguments: arguments,
                timeout: 8
            )
        } catch {
            return "could not start \(executable.path): \(forgePlayTechnicalErrorSummary(error))"
        }
        if capture.didTimeOut || !capture.didExit {
            return "\(executable.lastPathComponent) timed out"
        }
        guard capture.exitCode == 0 else {
            let stderrText = String(decoding: capture.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable.lastPathComponent) exited \(capture.exitCode): \(stderrText)"
        }
        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func diagnosticURL(for result: ProcessRunResult) -> URL {
        result.stderrLog
            .deletingPathExtension()
            .appendingPathExtension("diagnostics.log")
    }

    private func recognizeText(in imageURL: URL) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "ko-KR"]
        let handler = VNImageRequestHandler(url: imageURL)
        try handler.perform([request])
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private func containsQRCode(in imageURL: URL) throws -> Bool {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(url: imageURL)
        try handler.perform([request])
        return request.results?.contains { $0.symbology == .qr } == true
    }

    static func recognizesWindowsSteamUI(
        in recognizedText: [String],
        containsQRCode: Bool = false
    ) -> Bool {
        windowsSteamUISurface(in: recognizedText, containsQRCode: containsQRCode) != nil
    }

    static func windowsSteamUISurface(
        in recognizedText: [String],
        containsQRCode: Bool = false
    ) -> SteamUISurface? {
        let text = recognizedText
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let englishLibrarySignals = text.contains("store") &&
            text.contains("library") &&
            text.contains("community")
        let koreanLibrarySignals = text.contains("상점") &&
            text.contains("라이브러리") &&
            text.contains("커뮤니티")
        if englishLibrarySignals || koreanLibrarySignals {
            return .library
        }
        if text.contains("steam guard") || text.contains("스팀 가드") {
            return .steamGuard
        }
        if containsQRCode, text.contains("steam") || text.contains("스팀") {
            return .signIn
        }
        let signInSignals = [
            "sign in to steam",
            "sign into steam",
            "steam에 로그인",
            "steam 로그인",
            "스팀에 로그인",
            "스팀 로그인"
        ]
        if signInSignals.contains(where: { text.contains($0) }) {
            return .signIn
        }
        if text.contains("steam mobile app"), text.contains("qr code") {
            return .signIn
        }
        if text.contains("create a free account"), text.contains("steam") {
            return .signIn
        }
        let accountPasswordSignals = [
            text.contains("account name") && text.contains("password"),
            text.contains("계정") && text.contains("비밀번호"),
            text.contains("아이디") && text.contains("비밀번호")
        ]
        if accountPasswordSignals.contains(true), text.contains("steam") || text.contains("스팀") {
            return .signIn
        }
        return nil
    }

    private func hardGateEvidenceDirectoryURL(for diagnosticURL: URL) -> URL {
        diagnosticURL
            .deletingPathExtension()
            .appendingPathExtension("diagnostics")
    }

    private func writeHardGateEvidenceDirectory(
        _ evidenceDirectory: URL,
        diagnosticURL: URL,
        result: ProcessRunResult,
        launchTarget: SteamLaunchTarget?,
        runnerCapability: WindowsRuntimeCapability?,
        runnerVersionEvidence: String,
        gateStatus explicitGateStatus: SteamLaunchGateStatus?,
        reasonCodes: [SteamLaunchGateReasonCode],
        hardGateFailureReasons: [String],
        processSnapshotBefore: [SteamLaunchObservedProcess],
        processSnapshotAfter: [SteamLaunchObservedProcess],
        hostSteamProcessesBefore: [MacOSSteamProcess],
        hostSteamProcessesAfter: [MacOSSteamProcess],
        externalApplicationRunnerProcessesBefore: [SteamLaunchObservedProcess],
        externalApplicationRunnerProcessesAfter: [SteamLaunchObservedProcess],
        webHelperCommandLines: [String],
        screenEvidence: SteamLaunchScreenEvidence,
        priorLaunchAttempts: [SteamLaunchAttemptEvidence],
        stderrTail: [String],
        bootstrapTail: [String],
        webHelperGPUTail: [String],
        steamUIHTMLTail: [String],
        steamLoginTail: [String],
        dumpsBefore: [URL],
        dumpsAfter: [URL]
    ) throws {
        try fileManager.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        let status = explicitGateStatus ?? (result.succeeded && hardGateFailureReasons.isEmpty ? .success : .failed)
        let screenFinal = evidenceDirectory.appending(path: "screen-final.png")
        let screenEvidenceLine: String
        if status == .launched {
            screenEvidenceLine = "- screen-final.png: not requested for operational launch; visible UI conformance was not claimed"
        } else if FileSystemItemPolicy.isRegularNonSymlinkFile(screenFinal, fileManager: fileManager) {
            if screenEvidence.verifiesWindowsSteamUI {
                screenEvidenceLine = "- screen-final.png: present and verified as Windows Steam UI"
            } else {
                screenEvidenceLine = "- screen-final.png: present but not verified; SUCCESS forbidden"
            }
        } else {
            let missingScreenMessage = """
            screen-final.png was not captured for this run.
            ForgePlay must not report SUCCESS unless this file shows Windows Steam login, Steam Guard, or Library UI for the same bundled Runtime and Steam Prefix run.
            """
            try missingScreenMessage.write(
                to: evidenceDirectory.appending(path: "screen-final.png.missing.txt"),
                atomically: true,
                encoding: .utf8
            )
            screenEvidenceLine = "- screen-final.png: missing; SUCCESS forbidden"
        }

        let targetLines: [String] = if let launchTarget {
            [
                "- expected runner: \(launchTarget.normalizedRunnerPath)",
                "- expected WINEPREFIX: \(launchTarget.normalizedPrefixPath)",
                "- expected steam.exe: \(launchTarget.normalizedSteamExecutablePath)",
                "- allow host Steam: \(launchTarget.allowHostSteam)",
                "- allow external app-bundled runner: false"
            ]
        } else {
            ["- target: not captured; SUCCESS forbidden"]
        }
        let indexLines = [
            "# ForgePlay Windows Steam Hard Gate Evidence",
            "",
            "Status: \(status.rawValue)",
            "",
            "## Target",
            targetLines.joined(separator: "\n"),
            "",
            "## Result",
            "- action: \(result.actionName)",
            "- executable: \(result.executable.path)",
            "- process exit code: \(result.diagnosticExitCodeDescription)",
            "- ForgePlay status code: \(result.diagnosticForgePlayStatusDescription)",
            "- timed out: \(result.didTimeOut)",
            "- waited for exit: \(result.waitedForExit)",
            "- stdout: \(result.stdoutLog.path)",
            "- stderr: \(result.stderrLog.path)",
            "- screen verification: \(screenEvidence.state.rawValue)",
            "- Steam UI surface: \(screenEvidence.surface?.rawValue ?? "not identified")",
            "- screen verification message: \(screenEvidence.message)",
            "",
            "## Failure Reasons",
            reasonCodes.isEmpty ? "- reason_codes: none recorded" : reasonCodes.map { "- \($0.rawValue)" }.joined(separator: "\n"),
            hardGateFailureReasons.isEmpty ? "- none recorded" : hardGateFailureReasons.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "## Required Artifacts",
            "- processes-before.txt",
            "- processes-after.txt",
            "- host-steam-before.txt",
            "- host-steam-after.txt",
            "- external-runner-before.txt",
            "- external-runner-after.txt",
            "- runner-capability.txt",
            "- wine-version.txt",
            "- prefix-path.txt",
            "- steam-path.txt",
            "- webhelper-command-line.txt",
            "- manifest.json",
            "- launch-attempts.json",
            "- bootstrap-tail.txt",
            "- webhelper-tail.txt",
            "- dumps-before.txt",
            "- dumps-after.txt",
            "- capture-complete.txt",
            screenEvidenceLine
        ]
        try indexLines.joined(separator: "\n").write(
            to: evidenceDirectory.appending(path: "index.md"),
            atomically: true,
            encoding: .utf8
        )
        try writeLaunchAttempts(
            priorLaunchAttempts,
            to: evidenceDirectory.appending(path: "launch-attempts.json")
        )
        try writeHardGateManifest(
            to: evidenceDirectory.appending(path: "manifest.json"),
            diagnosticURL: diagnosticURL,
            evidenceDirectory: evidenceDirectory,
            result: result,
            status: status,
            reasonCodes: reasonCodes,
            launchTarget: launchTarget,
            runnerCapability: runnerCapability,
            processSnapshotAfter: processSnapshotAfter,
            hostSteamProcessesBefore: hostSteamProcessesBefore,
            hostSteamProcessesAfter: hostSteamProcessesAfter,
            externalApplicationRunnerProcessesBefore: externalApplicationRunnerProcessesBefore,
            externalApplicationRunnerProcessesAfter: externalApplicationRunnerProcessesAfter,
            webHelperCommandLines: webHelperCommandLines,
            screenEvidence: screenEvidence,
            dumpsBefore: dumpsBefore,
            dumpsAfter: dumpsAfter
        )
        try processSnapshotBefore.diagnosticText.write(
            to: evidenceDirectory.appending(path: "processes-before.txt"),
            atomically: true,
            encoding: .utf8
        )
        try processSnapshotBefore.diagnosticText.write(
            to: evidenceDirectory.appending(path: "process-before.txt"),
            atomically: true,
            encoding: .utf8
        )
        try processSnapshotAfter.diagnosticText.write(
            to: evidenceDirectory.appending(path: "processes-after.txt"),
            atomically: true,
            encoding: .utf8
        )
        try processSnapshotAfter.diagnosticText.write(
            to: evidenceDirectory.appending(path: "process-during.txt"),
            atomically: true,
            encoding: .utf8
        )
        try processSnapshotAfter.diagnosticText.write(
            to: evidenceDirectory.appending(path: "process-after.txt"),
            atomically: true,
            encoding: .utf8
        )
        try hostSteamProcessesBefore.diagnosticText.write(
            to: evidenceDirectory.appending(path: "host-steam-before.txt"),
            atomically: true,
            encoding: .utf8
        )
        try hostSteamProcessesAfter.diagnosticText.write(
            to: evidenceDirectory.appending(path: "host-steam-after.txt"),
            atomically: true,
            encoding: .utf8
        )
        try externalApplicationRunnerProcessesBefore.diagnosticText.write(
            to: evidenceDirectory.appending(path: "external-runner-before.txt"),
            atomically: true,
            encoding: .utf8
        )
        try externalApplicationRunnerProcessesAfter.diagnosticText.write(
            to: evidenceDirectory.appending(path: "external-runner-after.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runnerCapabilityDiagnostics(runnerCapability).write(
            to: evidenceDirectory.appending(path: "runner-capability.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runnerInfoJSON(
            runnerCapability: runnerCapability,
            launchTarget: launchTarget
        ).write(
            to: evidenceDirectory.appending(path: "runner-info.json"),
            atomically: true,
            encoding: .utf8
        )
        try runnerVersionEvidence.write(
            to: evidenceDirectory.appending(path: "wine-version.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "\(launchTarget?.normalizedPrefixPath ?? "not captured")\n".write(
            to: evidenceDirectory.appending(path: "prefix-path.txt"),
            atomically: true,
            encoding: .utf8
        )
        try prefixInfoJSON(
            launchTarget: launchTarget,
            steamCfgPinPresent: launchTarget.map {
                WindowsSteamInstallationLayout.steamCfgPinPresent(
                    in: $0.expectedPrefixPath,
                    fileManager: fileManager
                )
            } ?? false
        ).write(
            to: evidenceDirectory.appending(path: "prefix-info.json"),
            atomically: true,
            encoding: .utf8
        )
        try "\(launchTarget?.normalizedSteamExecutablePath ?? "not captured")\n".write(
            to: evidenceDirectory.appending(path: "steam-path.txt"),
            atomically: true,
            encoding: .utf8
        )
        try webHelperCommandLines.diagnosticText.write(
            to: evidenceDirectory.appending(path: "webhelper-command-line.txt"),
            atomically: true,
            encoding: .utf8
        )
        try ([
            "state: \(screenEvidence.state.rawValue)",
            "surface: \(screenEvidence.surface?.rawValue ?? "not identified")",
            "message: \(screenEvidence.message)",
            "screenshot: \(screenEvidence.screenshotURL?.path ?? "not captured")",
            "",
            "recognized text:",
            screenEvidence.recognizedText.diagnosticText
        ].joined(separator: "\n")).write(
            to: evidenceDirectory.appending(path: "screen-ocr.txt"),
            atomically: true,
            encoding: .utf8
        )
        try bootstrapTail.diagnosticText.write(
            to: evidenceDirectory.appending(path: "bootstrap-tail.txt"),
            atomically: true,
            encoding: .utf8
        )
        try bootstrapTail.diagnosticText.write(
            to: evidenceDirectory.appending(path: "bootstrap-log-tail.txt"),
            atomically: true,
            encoding: .utf8
        )
        try ([
            "== webhelper_gpu.txt ==",
            webHelperGPUTail.joined(separator: "\n"),
            "",
            "== steamui_html.txt ==",
            steamUIHTMLTail.joined(separator: "\n"),
            "",
            "== steamui_login.txt ==",
            steamLoginTail.joined(separator: "\n"),
            "",
            "== stderr tail ==",
            stderrTail.joined(separator: "\n")
        ].joined(separator: "\n")).write(
            to: evidenceDirectory.appending(path: "webhelper-tail.txt"),
            atomically: true,
            encoding: .utf8
        )
        try ([
            "== webhelper_gpu.txt ==",
            webHelperGPUTail.joined(separator: "\n"),
            "",
            "== steamui_html.txt ==",
            steamUIHTMLTail.joined(separator: "\n"),
            "",
            "== steamui_login.txt ==",
            steamLoginTail.joined(separator: "\n")
        ].joined(separator: "\n")).write(
            to: evidenceDirectory.appending(path: "steam-webhelper-tail.txt"),
            atomically: true,
            encoding: .utf8
        )
        try dumpsBefore.map(\.path).diagnosticText.write(
            to: evidenceDirectory.appending(path: "dumps-before.txt"),
            atomically: true,
            encoding: .utf8
        )
        try dumpsAfter.map(\.path).diagnosticText.write(
            to: evidenceDirectory.appending(path: "dumps-after.txt"),
            atomically: true,
            encoding: .utf8
        )
        if let screenshotURL = screenEvidence.screenshotURL,
           FileSystemItemPolicy.isRegularNonSymlinkFile(screenshotURL, fileManager: fileManager) {
            let screenshotAlias = evidenceDirectory.appending(path: "screenshot.png")
            if screenshotAlias.standardizedFileURL.path != screenshotURL.standardizedFileURL.path {
                try? fileManager.removeItem(at: screenshotAlias)
                try fileManager.copyItem(at: screenshotURL, to: screenshotAlias)
            }
        }
        try finalVerdictText(
            status: status,
            reasonCodes: reasonCodes,
            screenEvidence: screenEvidence,
            dumpsAfter: dumpsAfter
        ).write(
            to: evidenceDirectory.appending(path: "final-verdict.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeLaunchAttempts(
        _ attempts: [SteamLaunchAttemptEvidence],
        to url: URL
    ) throws {
        let documents = attempts.map { attempt in
            LaunchAttemptDocument(
                sequence: attempt.sequence,
                relaunchReason: attempt.relaunchReason,
                runIdentifier: attempt.runIdentifier,
                actionName: attempt.result.actionName,
                startedAt: attempt.result.startedAt,
                endedAt: attempt.result.endedAt,
                processExitCode: attempt.result.processExitCode,
                forgePlayStatusCode: attempt.result.forgePlayStatusCode,
                outcome: attempt.result.outcome,
                didTimeOut: attempt.result.didTimeOut,
                waitedForExit: attempt.result.waitedForExit,
                stdoutLog: attempt.result.stdoutLog.path,
                stderrLog: attempt.result.stderrLog.path,
                runEvidenceLog: attempt.result.runEvidenceLog?.path,
                relatedRunEvidenceLogs: attempt.result.relatedRunEvidenceLogs.map(\.path),
                processObservationLog: attempt.result.processObservationLog?.path,
                rendererLogDirectory: attempt.rendererLogDirectory.path,
                crashDumpsObserved: attempt.crashDumpsObserved.map(\.path),
                preLaunchShutdownRunEvidenceLog: attempt.preLaunchShutdownResult?.runEvidenceLog?.path,
                preLaunchShutdownRelatedRunEvidenceLogs: attempt.preLaunchShutdownResult?
                    .relatedRunEvidenceLogs.map(\.path) ?? []
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(documents).write(to: url, options: .atomic)
    }

    private func writeHardGateManifest(
        to url: URL,
        diagnosticURL: URL,
        evidenceDirectory: URL,
        result: ProcessRunResult,
        status: SteamLaunchGateStatus,
        reasonCodes: [SteamLaunchGateReasonCode],
        launchTarget: SteamLaunchTarget?,
        runnerCapability: WindowsRuntimeCapability?,
        processSnapshotAfter: [SteamLaunchObservedProcess],
        hostSteamProcessesBefore: [MacOSSteamProcess],
        hostSteamProcessesAfter: [MacOSSteamProcess],
        externalApplicationRunnerProcessesBefore: [SteamLaunchObservedProcess],
        externalApplicationRunnerProcessesAfter: [SteamLaunchObservedProcess],
        webHelperCommandLines: [String],
        screenEvidence: SteamLaunchScreenEvidence,
        dumpsBefore: [URL],
        dumpsAfter: [URL]
    ) throws {
        let runID = result.stderrLog
            .deletingPathExtension()
            .lastPathComponent
        let screenshots = [screenEvidence.screenshotURL]
            .compactMap { url -> String? in
                guard let url,
                      FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager) else {
                    return nil
                }
                return url.path
            }
        let target = SteamLaunchHardGateManifest.Target(
            app: Bundle.main.bundleURL.path,
            runner: launchTarget?.normalizedRunnerPath ?? result.executable.standardizedFileURL.path,
            wineprefix: launchTarget?.normalizedPrefixPath ?? "not captured",
            steamExe: launchTarget?.normalizedSteamExecutablePath ?? "not captured"
        )
        let evidence = SteamLaunchHardGateManifest.Evidence(
            diagnosticsLog: diagnosticURL.path,
            stderrLog: result.stderrLog.path,
            stdoutLog: result.stdoutLog.path,
            evidenceDirectory: evidenceDirectory.path,
            dumpsBefore: dumpsBefore.map(\.path),
            dumpsAfter: dumpsAfter.map(\.path),
            webhelperCommandLine: webHelperCommandLines,
            screenshots: screenshots
        )
        let manifest = SteamLaunchHardGateManifest(
            runID: runID,
            status: status,
            reasonCodes: reasonCodes,
            target: target,
            evidence: evidence,
            expectedRunner: launchTarget?.normalizedRunnerPath ?? result.executable.standardizedFileURL.path,
            actualRunnerProcesses: observedRunnerProcesses(
                in: processSnapshotAfter,
                launchTarget: launchTarget,
                runnerCapability: runnerCapability
            ),
            expectedPrefix: launchTarget?.normalizedPrefixPath ?? "not captured",
            observedSteamProcesses: observedSteamProcesses(
                in: processSnapshotAfter,
                launchTarget: launchTarget
            ),
            observedWebhelperProcesses: webHelperCommandLines,
            hostMacOSSteamContamination: !hostSteamProcessesBefore.isEmpty || !hostSteamProcessesAfter.isEmpty,
            externalRunnerContamination: !externalApplicationRunnerProcessesBefore.isEmpty || !externalApplicationRunnerProcessesAfter.isEmpty,
            unsupportedExternalRunnerDetected: runnerCapability?.isUnsupportedExternalApplicationRunner == true,
            webhelperCommandLineCaptured: !webHelperCommandLines.isEmpty,
            windowsSteamUIVisible: screenEvidence.verifiesWindowsSteamUI,
            steamUISurface: screenEvidence.surface,
            screenshotPath: screenshots.first,
            newCrashDumpCount: dumpsAfter.filter { !$0.lastPathComponent.lowercased().hasPrefix("assert_") }.count,
            newAssertDumpCount: dumpsAfter.filter { $0.lastPathComponent.lowercased().hasPrefix("assert_") }.count,
            steamCfgPinPresent: launchTarget.map {
                WindowsSteamInstallationLayout.steamCfgPinPresent(
                    in: $0.expectedPrefixPath,
                    fileManager: fileManager
                )
            } ?? false,
            steamLaunchArgs: result.arguments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func observedRunnerProcesses(
        in processes: [SteamLaunchObservedProcess],
        launchTarget: SteamLaunchTarget?,
        runnerCapability: WindowsRuntimeCapability?
    ) -> [String] {
        guard let launchTarget else { return [] }
        let targetSnapshot = SteamLaunchProcessSnapshot(processes: processes)
        let expectedRunner = launchTarget.normalizedRunnerPath.lowercased()
        let expectedDirectory = launchTarget.normalizedRunnerDirectoryPath.lowercased()
        let externalApplicationBundleRoot = runnerCapability?.isUnsupportedExternalApplicationRunner == true
            ? ExternalApplicationRunnerPolicy.containingApplicationBundle(
                for: launchTarget.expectedRunnerPath,
                fileManager: fileManager
            )?.standardizedFileURL.path.lowercased()
            : nil
        return targetSnapshot.processes.compactMap { process in
            let command = process.command.lowercased()
            guard command.contains(expectedRunner) ||
                    command.contains(expectedDirectory) ||
                    externalApplicationBundleRoot.map({ command.contains($0) }) == true else {
                return nil
            }
            return process.diagnosticLine
        }
    }

    private func observedSteamProcesses(
        in processes: [SteamLaunchObservedProcess],
        launchTarget: SteamLaunchTarget?
    ) -> [String] {
        guard let launchTarget else { return [] }
        let prefix = launchTarget.normalizedPrefixPath.lowercased()
        let steam = launchTarget.normalizedSteamExecutablePath.lowercased()
        return processes.compactMap { process in
            let command = process.command.lowercased()
            guard command.contains("steam.exe") || command.contains("steamwebhelper.exe") else {
                return nil
            }
            guard command.contains(prefix) ||
                    command.contains(steam) else {
                return nil
            }
            return process.diagnosticLine
        }
    }

    private func runnerInfoJSON(
        runnerCapability: WindowsRuntimeCapability?,
        launchTarget: SteamLaunchTarget?
    ) throws -> String {
        let payload: [String: Any] = [
            "expected_runner": launchTarget?.normalizedRunnerPath ?? "not captured",
            "display_name": runnerCapability.map { WindowsRuntimeDisplayName.displayName(for: $0.executableURL, capability: $0) } ?? "not captured",
            "is_unsupported_external_application_runner": runnerCapability?.isUnsupportedExternalApplicationRunner ?? false,
            "graphics_backend": runnerCapability.map { String(describing: $0.graphicsBackend) } ?? "not captured",
            "available_graphics_backends": runnerCapability?.availableGraphicsBackends
                .map(\.diagnosticName)
                .sorted() ?? [],
            "direct3d_generations": runnerCapability?.supportedDirect3DGenerations
                .map(\.rawValue)
                .sorted() ?? [],
            "direct3d_generations_by_backend": runnerCapability?
                .direct3DGenerationsByBackendDiagnostics ?? [:],
            "evidence": runnerCapability?.evidence ?? [],
            "limitations": runnerCapability?.limitations ?? []
        ]
        return try prettyPrintedJSON(payload)
    }

    private func prefixInfoJSON(
        launchTarget: SteamLaunchTarget?,
        steamCfgPinPresent: Bool
    ) throws -> String {
        let payload: [String: Any] = [
            "expected_prefix": launchTarget?.normalizedPrefixPath ?? "not captured",
            "expected_steam_executable": launchTarget?.normalizedSteamExecutablePath ?? "not captured",
            "steam_cfg_pin_present": steamCfgPinPresent
        ]
        return try prettyPrintedJSON(payload)
    }

    private func finalVerdictText(
        status: SteamLaunchGateStatus,
        reasonCodes: [SteamLaunchGateReasonCode],
        screenEvidence: SteamLaunchScreenEvidence,
        dumpsAfter: [URL]
    ) -> String {
        [
            "status: \(status.rawValue)",
            "reason_codes: \(reasonCodes.map(\.rawValue).joined(separator: ", "))",
            "screen_verification: \(screenEvidence.state.rawValue)",
            "screen_message: \(screenEvidence.message)",
            "new_crash_dump_count: \(dumpsAfter.filter { !$0.lastPathComponent.lowercased().hasPrefix("assert_") }.count)",
            "new_assert_dump_count: \(dumpsAfter.filter { $0.lastPathComponent.lowercased().hasPrefix("assert_") }.count)"
        ].joined(separator: "\n") + "\n"
    }

    private func prettyPrintedJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func runnerCapabilityDiagnostics(_ capability: WindowsRuntimeCapability?) -> String {
        guard let capability else {
            return "not captured; SUCCESS forbidden\n"
        }
        return [
            "executable: \(capability.executableURL.path)",
            "graphicsBackend: \(String(describing: capability.graphicsBackend))",
            "availableGraphicsBackends: \(capability.availableGraphicsBackends.map(\.diagnosticName).sorted().joined(separator: ","))",
            "direct3DGenerations: \(capability.direct3DGenerationSummary.isEmpty ? "none" : capability.direct3DGenerationSummary)",
            "direct3DGenerationsByBackend: \(capability.direct3DGenerationsByBackendSummary.isEmpty ? "none" : capability.direct3DGenerationsByBackendSummary)",
            "",
            "evidence:",
            capability.evidence.isEmpty ? "- none" : capability.evidence.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "limitations:",
            capability.limitations.isEmpty ? "- none" : capability.limitations.map { "- \($0)" }.joined(separator: "\n")
        ].joined(separator: "\n")
    }

    func launchEnvironmentSummary(
        runtimeExecutable: URL,
        prefix: URL,
        rendererPolicy: SteamRendererPolicyPreference?
    ) -> [String] {
        let runtimeIdentityLines = runtimeIdentitySummary(for: runtimeExecutable)
        do {
            let environment = try SafeProcessRunner.runnerEnvironment(
                for: runtimeExecutable,
                base: [
                    "WINEPREFIX": prefix.path,
                    "MTL_HUD_ENABLED": "0"
                ],
                graphicsBackend: nil,
                exposesVulkanICD: true,
                injectGraphicsDLLOverrides: false,
                restoresSteamWebHelperVulkanICD: true
            )
            let keys = [
                "WINEPREFIX",
                "FORGEPLAY_SYNCHRONIZATION_SELECTION",
                "FORGEPLAY_SYNCHRONIZATION_BACKEND",
                "MTL_HUD_ENABLED",
                "WINEDLLOVERRIDES",
                "WINEDLLPATH",
                "D3DMETAL_FRAMEWORK_PATH",
                "DYLD_LIBRARY_PATH",
                "DYLD_FRAMEWORK_PATH",
                "VK_ICD_FILENAMES",
                "VK_DRIVER_FILES"
            ]
            var lines = [
                "- Selected game renderer payload: \(rendererPolicy?.rawValue ?? "unresolved")",
                steamClientRendererEnvironmentSummary(for: rendererPolicy)
            ]
            lines.append(contentsOf: runtimeIdentityLines)
            if let rendererPolicy {
                let gamePolicyEnvironment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                    for: runtimeExecutable,
                    prefix: prefix,
                    graphicsBackend: rendererPolicy,
                    logDirectory: prefix
                )
                let policyKeys = [
                    "FORGEPLAY_GAME_RENDERER_POLICY_ENABLED",
                    "FORGEPLAY_GAME_RENDERER_POLICY",
                    "FORGEPLAY_GAME_RENDERER_REQUESTED",
                    "FORGEPLAY_GAME_RENDERER_COMPONENTS_X64",
                    "FORGEPLAY_GAME_RENDERER_COMPONENTS_X86",
                    "FORGEPLAY_GAME_RENDERER_DLL_PATH_X64",
                    "FORGEPLAY_GAME_RENDERER_DLL_PATH_X86",
                    "FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES",
                    "FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_SHARED_LIBRARY",
                    "FORGEPLAY_GAME_RENDERER_ENV_VK_ICD_FILENAMES",
                    "FORGEPLAY_GAME_RENDERER_ENV_DXVK_CONFIG"
                ]
                for key in policyKeys {
                    guard let value = gamePolicyEnvironment[key], !value.isEmpty else { continue }
                    lines.append("- \(key): \(limitedInlineDiagnosticValue(value))")
                }
            }
            lines.append(contentsOf: directRuntimeDependencySummary(for: runtimeExecutable))
            for key in keys {
                guard let value = environment[key], !value.isEmpty else { continue }
                lines.append("- \(key): \(limitedInlineDiagnosticValue(value))")
            }
            return lines
        } catch {
            return [
                "- Selected game renderer payload: \(rendererPolicy?.rawValue ?? "unresolved")",
                steamClientRendererEnvironmentSummary(for: rendererPolicy),
                runtimeIdentityLines.joined(separator: "\n"),
                directRuntimeDependencySummary(for: runtimeExecutable).joined(separator: "\n"),
                "- Environment inspection failed: \(forgePlayTechnicalErrorSummary(error))"
            ].filter { !$0.isEmpty }
        }
    }

    private func runtimeIdentitySummary(for executable: URL) -> [String] {
        do {
            let manifest = try RuntimeManifestResolver(fileManager: fileManager)
                .diagnosticManifest(for: executable)
            let issues = manifest.identityIssues ?? []
            return [
                "- Runtime identity capture: \(issues.isEmpty ? "verified" : "derivedIncomplete")",
                "- Runtime identifier: \(manifest.runtimeIdentifier)",
                "- Runtime Wine version: \(manifest.wineVersion)",
                "- Runtime architecture: \(manifest.architecture)",
                "- Runtime build fingerprint: \(manifest.runnerBuildFingerprint)",
                "- Runtime prefix compatibility fingerprint: \(manifest.prefixCompatibilityFingerprint)",
                "- Runtime wine.inf fingerprint/state: \(manifest.wineInfSHA256) / \(manifest.wineInfFingerprintState ?? "verified")",
                "- Runtime wineboot fingerprint/state: \(manifest.winebootSHA256) / \(manifest.winebootFingerprintState ?? "verified")"
            ] + issues.map { "- Runtime identity issue: \($0)" }
        } catch {
            return [
                "- Runtime identity capture: invalid",
                "- Runtime identity error: \(forgePlayTechnicalErrorSummary(error))"
            ]
        }
    }

    private func steamClientRendererEnvironmentSummary(
        for rendererPolicy: SteamRendererPolicyPreference?
    ) -> String {
        switch rendererPolicy {
        case .d3dMetal:
            return "- Steam and WebHelper stay on the base Wine renderer path. This Steam session applies only D3DMetal to game children, with no second renderer composed into that route."
        case .dxmt:
            return "- Steam and WebHelper stay on the base Wine renderer path. This Steam session applies only DXMT to game children."
        case .d9vk:
            return "- Steam and WebHelper stay on the base Wine renderer path. This Steam session applies only D9VK to game children."
        case .vulkan:
            return "- Steam and WebHelper stay on the base Wine renderer path. This Steam session applies only DXVK with Vulkan/MoltenVK to game children."
        case nil:
            return "- Renderer payload is unresolved for the Steam Prefix. Steam UI rendering still must be verified separately before reporting success."
        }
    }

    func waitForSteamWebHelperRenderingFailure(
        in steamDirectory: URL,
        since cutoff: Date,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        logCursor: SteamWebHelperStartupLogCursor? = nil
    ) async -> SteamWebHelperRenderingIssue? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let sleepNanoseconds = UInt64(max(0.2, pollInterval) * 1_000_000_000)
        while !Task.isCancelled && Date() < deadline {
            if let issue = detectSteamWebHelperRenderingFailure(
                in: steamDirectory,
                since: cutoff,
                logCursor: logCursor
            ) {
                return issue
            }
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                break
            }
        }
        return detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: cutoff,
            logCursor: logCursor
        )
    }

    func detectSteamWebHelperRenderingFailure(
        in steamDirectory: URL,
        since cutoff: Date,
        logCursor: SteamWebHelperStartupLogCursor? = nil
    ) -> SteamWebHelperRenderingIssue? {
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let webHelperGPURead = logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "webhelper_gpu.txt"),
                since: $0.webHelperGPU,
                limit: 120,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "webhelper_gpu.txt"),
            limit: 120,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let steamUIHTMLRead = logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "steamui_html.txt"),
                since: $0.steamUIHTML,
                limit: 120,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "steamui_html.txt"),
            limit: 120,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let steamLoginRead = logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "steamui_login.txt"),
                since: $0.steamLogin,
                limit: 120,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "steamui_login.txt"),
            limit: 120,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let consoleRead = logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "console_log.txt"),
                since: $0.console,
                limit: 120,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "console_log.txt"),
            limit: 120,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let webHelperRead = logCursor.map {
            appendedTailReadResult(
                from: logs.appending(path: "webhelper.txt"),
                since: $0.webHelper,
                limit: 120,
                allowedRoot: steamDirectory
            ).filteringLines { filterSteamLogLines($0, modifiedAfter: cutoff) }
        } ?? tailReadResult(
            from: logs.appending(path: "webhelper.txt"),
            limit: 120,
            modifiedAfter: cutoff,
            allowedRoot: steamDirectory
        )
        let webHelperGPU = webHelperGPURead.lines.joined(separator: "\n").lowercased()
        let steamUIHTML = steamUIHTMLRead.lines.joined(separator: "\n").lowercased()
        let steamLogin = steamLoginRead.lines.joined(separator: "\n").lowercased()
        let console = consoleRead.lines.joined(separator: "\n").lowercased()
        guard hasSteamWebHelperRenderingFailure(
            webHelperGPU: webHelperGPU,
            steamUIHTML: steamUIHTML,
            steamLogin: steamLogin,
            console: console
        ) else {
            return nil
        }
        return SteamWebHelperRenderingIssue(
            webHelperGPUTail: Array(webHelperGPURead.lines.suffix(120)),
            steamUIHTMLTail: Array(steamUIHTMLRead.lines.suffix(120)),
            steamLoginTail: Array(steamLoginRead.lines.suffix(120)),
            consoleTail: Array(consoleRead.lines.suffix(120)),
            webHelperTail: Array(webHelperRead.lines.suffix(120)),
            webHelperGPUEvidence: SteamEvidenceSourceSnapshot(
                state: webHelperGPURead.state,
                detail: webHelperGPURead.detail
            ),
            steamUIHTMLEvidence: SteamEvidenceSourceSnapshot(
                state: steamUIHTMLRead.state,
                detail: steamUIHTMLRead.detail
            ),
            steamLoginEvidence: SteamEvidenceSourceSnapshot(
                state: steamLoginRead.state,
                detail: steamLoginRead.detail
            ),
            consoleEvidence: SteamEvidenceSourceSnapshot(
                state: consoleRead.state,
                detail: consoleRead.detail
            ),
            webHelperEvidence: SteamEvidenceSourceSnapshot(
                state: webHelperRead.state,
                detail: webHelperRead.detail
            )
        )
    }

    func recentSteamCrashDumps(
        in dumpsDirectory: URL,
        since cutoff: Date,
        observationContext: SteamCrashDumpObservationContext? = nil
    ) -> [URL] {
        recentSteamCrashDumpScan(
            in: dumpsDirectory,
            since: cutoff,
            observationContext: observationContext
        ).urls
    }

    func recentSteamCrashDumpScan(
        in dumpsDirectory: URL,
        since cutoff: Date,
        observationContext: SteamCrashDumpObservationContext? = nil
    ) -> SteamCrashDumpScanResult {
        let dumpAllowedRoot = dumpsDirectory.standardizedFileURL.deletingLastPathComponent()
        let initialDirectoryDescriptor: Int32
        let initialDirectoryIdentity: EvidenceDirectoryIdentity
        switch openSecureEvidenceDirectory(
            dumpsDirectory,
            anchoredAt: dumpAllowedRoot
        ) {
        case .failed(let state, let detail):
            return finishCrashDumpScan(
                state: state,
                directory: dumpsDirectory,
                detail: detail,
                items: [],
                observationContext: observationContext
            )
        case .opened(let descriptor, let identity):
            initialDirectoryDescriptor = descriptor
            initialDirectoryIdentity = identity
        }
        defer { Darwin.close(initialDirectoryDescriptor) }

        var enumerationFailures: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: dumpsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                enumerationFailures.append(
                    "\(url.path): \(forgePlayTechnicalErrorSummary(error))"
                )
                return true
            }
        ) else {
            return finishCrashDumpScan(
                state: .unreadable,
                directory: dumpsDirectory,
                detail: "FileManager could not create a directory enumerator",
                items: [],
                observationContext: observationContext
            )
        }

        var dumps: [SteamCrashDumpScanItem] = []
        var evidenceFailures: [(state: SteamEvidenceReadState, detail: String)] = []
        for case let url as URL in enumerator {
            var itemStatus = stat()
            guard Darwin.lstat(url.path, &itemStatus) == 0 else {
                let code = errno
                evidenceFailures.append((
                    code == ENOENT ? .changedDuringRead : .unreadable,
                    "could not inspect enumerated dump item \(url.path): \(posixFailureDescription(code))"
                ))
                continue
            }
            if (itemStatus.st_mode & S_IFMT) == S_IFLNK {
                enumerator.skipDescendants()
                evidenceFailures.append((
                    .unsafe,
                    "symbolic-link item rejected during dump enumeration: \(url.path)"
                ))
                continue
            }
            guard url.pathExtension.lowercased() == "dmp" else {
                continue
            }
            switch openSecureEvidenceFile(at: url, allowedRoot: dumpAllowedRoot) {
            case .failed(let state, let detail):
                evidenceFailures.append((
                    state == .missing ? .changedDuringRead : state,
                    detail
                ))
            case .opened(let descriptor, let metadata):
                Darwin.close(descriptor)
                guard metadata.modificationDate >= cutoff else { continue }
                dumps.append(SteamCrashDumpScanItem(
                    url: url,
                    fingerprint: SteamCrashDumpFingerprint(
                        standardizedPath: url.standardizedFileURL.path,
                        deviceNumber: metadata.deviceNumber,
                        fileNumber: metadata.fileNumber,
                        byteCount: metadata.byteCount,
                        modificationSeconds: metadata.modificationSeconds,
                        modificationNanoseconds: metadata.modificationNanoseconds
                    ),
                    modificationDate: metadata.modificationDate
                ))
            }
        }
        evidenceFailures.append(contentsOf: enumerationFailures.map {
            (.unreadable, "directory enumeration failed: \($0)")
        })
        var retainedDirectoryStatus = stat()
        if Darwin.fstat(initialDirectoryDescriptor, &retainedDirectoryStatus) != 0 ||
            (retainedDirectoryStatus.st_mode & S_IFMT) != S_IFDIR {
            let code = errno
            evidenceFailures.append((
                .changedDuringRead,
                "retained dumps directory descriptor became invalid during enumeration: \(posixFailureDescription(code))"
            ))
        }
        switch openSecureEvidenceDirectory(dumpsDirectory, anchoredAt: dumpAllowedRoot) {
        case .failed(let state, let detail):
            evidenceFailures.append((
                state == .unsafe ? .unsafe : .changedDuringRead,
                "dumps directory changed during enumeration: \(detail)"
            ))
        case .opened(let finalDirectoryDescriptor, let finalDirectoryIdentity):
            Darwin.close(finalDirectoryDescriptor)
            if finalDirectoryIdentity != initialDirectoryIdentity {
                evidenceFailures.append((
                    .changedDuringRead,
                    "dumps directory identity changed during enumeration"
                ))
            }
        }
        let observationState: SteamEvidenceReadState
        if evidenceFailures.contains(where: { $0.state == .unsafe }) {
            observationState = .unsafe
        } else if evidenceFailures.contains(where: { $0.state == .changedDuringRead }) {
            observationState = .changedDuringRead
        } else if !evidenceFailures.isEmpty {
            observationState = .unreadable
        } else {
            observationState = .captured
        }
        let failureDetail = evidenceFailures.prefix(6).map(\.detail).joined(separator: "; ")
        let scanDetail = evidenceFailures.isEmpty
            ? "secure enumeration completed; matchingDumps=\(dumps.count)"
            : "secure enumeration was incomplete; matchingDumps=\(dumps.count); \(failureDetail)"
        return finishCrashDumpScan(
            state: observationState,
            directory: dumpsDirectory,
            detail: scanDetail,
            items: dumps.sorted { $0.modificationDate > $1.modificationDate },
            observationContext: observationContext
        )
    }

    private func finishCrashDumpScan(
        state: SteamEvidenceReadState,
        directory: URL,
        detail: String,
        items: [SteamCrashDumpScanItem],
        observationContext: SteamCrashDumpObservationContext?
    ) -> SteamCrashDumpScanResult {
        recordCrashDumpScanObservation(
            CrashDumpScanObservation(
                state: state,
                directory: directory,
                detail: detail
            ),
            for: observationContext
        )
        return SteamCrashDumpScanResult(state: state, detail: detail, items: items)
    }

    private func recordCrashDumpScanObservation(
        _ observation: CrashDumpScanObservation,
        for context: SteamCrashDumpObservationContext?
    ) {
        guard let context else { return }
        crashDumpObservationLock.lock()
        defer { crashDumpObservationLock.unlock() }
        guard crashDumpScanObservationsByContext[context.identifier] != nil else { return }
        var observations = crashDumpScanObservationsByContext[context.identifier] ?? []
        observations.append(observation)
        if observations.count > 16 {
            observations.removeFirst(observations.count - 16)
        }
        crashDumpScanObservationsByContext[context.identifier] = observations
    }

    private func takeCrashDumpScanObservations(
        for context: SteamCrashDumpObservationContext?
    ) -> [CrashDumpScanObservation] {
        guard let context else { return [] }
        crashDumpObservationLock.lock()
        defer { crashDumpObservationLock.unlock() }
        return crashDumpScanObservationsByContext.removeValue(forKey: context.identifier) ?? []
    }

    func crashDumpIndicatesAccessViolation(_ url: URL) -> Bool {
        minidumpExceptionSummary(
            at: url,
            allowedRoot: url.deletingLastPathComponent()
        )?
            .lowercased()
            .contains("0xc0000005") == true
    }

    private func limitedInlineDiagnosticValue(_ value: String, maxLength: Int = 900) -> String {
        guard value.count > maxLength else { return value }
        return "\(value.prefix(maxLength))... [truncated]"
    }

    private func steamLaunchFindings(
        stderrTail: [String],
        webHelperGPUTail: [String],
        steamUIHTMLTail: [String],
        steamLoginTail: [String],
        consoleTail: [String],
        webHelperTail: [String],
        shaderLogTail: [String],
        hostSteamProcesses: [MacOSSteamProcess],
        externalApplicationRunnerProcesses: [SteamLaunchObservedProcess],
        allowsHostSteam: Bool,
        gateStatus: SteamLaunchGateStatus,
        hardGateFailureReasons: [String],
        evidenceFailureDescriptions: [String]
    ) -> [String] {
        let stderr = stderrTail.joined(separator: "\n").lowercased()
        let webHelperGPU = webHelperGPUTail.joined(separator: "\n").lowercased()
        let steamUIHTML = steamUIHTMLTail.joined(separator: "\n").lowercased()
        let steamLogin = steamLoginTail.joined(separator: "\n").lowercased()
        let console = consoleTail.joined(separator: "\n").lowercased()
        let webHelper = webHelperTail.joined(separator: "\n").lowercased()
        let shaderLog = shaderLogTail.joined(separator: "\n").lowercased()
        var findings: [String] = []
        let combinedLaunchText = [
            stderr,
            webHelperGPU,
            steamUIHTML,
            steamLogin,
            console,
            webHelper,
            shaderLog
        ].joined(separator: "\n")
        let steamUIRenderingFailed = hasSteamWebHelperRenderingFailure(
            webHelperGPU: webHelperGPU,
            steamUIHTML: steamUIHTML,
            steamLogin: steamLogin,
            console: console
        )

        if !evidenceFailureDescriptions.isEmpty {
            findings.append(
                "Diagnostic evidence inspection was incomplete. No-pattern or no-dump observations apply only to the sources that were captured safely; unavailable sources must not be interpreted as clean evidence. \(evidenceFailureDescriptions.joined(separator: "; "))"
            )
        }

        if hasMacOSSteamEvidence(in: combinedLaunchText) {
            findings.append("macOS Steam.app or Valve ipcserver evidence was present in the captured logs. ForgePlay treats this as host-side background activity only, not as Windows Steam UI rendering success.")
        }
        let bootstrapUpdateDeferred = hardGateFailureReasons.contains {
            $0.contains(SteamLaunchGateReasonCode.steamBootstrapUpdateInProgress.rawValue)
        }
        let processEvidenceDeferred = hardGateFailureReasons.contains {
            $0.contains(SteamLaunchGateReasonCode.operationalProcessEvidenceUnavailable.rawValue)
        }
        if !hostSteamProcesses.isEmpty, allowsHostSteam {
            findings.append("macOS Steam.app background activity was present, but operational launch evidence was collected from the ForgePlay Windows runner and managed WINEPREFIX.")
        } else if !hostSteamProcesses.isEmpty {
            if bootstrapUpdateDeferred {
                findings.append("macOS Steam.app appeared during the Windows Steam bootstrap update. ForgePlay recorded this as host evidence, did not report SUCCESS, and left Windows Steam running while UI verification is deferred.")
            } else {
                findings.append("macOS Steam.app was newly launched while ForgePlay was attempting to start Windows Steam. This is host Steam contamination; the run is invalid, Windows Steam was stopped, and the Prefix should be retested from a clean Windows Steam install without importing macOS Steam state.")
            }
        }
        if !externalApplicationRunnerProcesses.isEmpty, allowsHostSteam {
            findings.append("External app-bundled Wine/Steam process activity was present on the Mac, but it was not the runner or prefix used by this operational ForgePlay launch.")
        } else if !externalApplicationRunnerProcesses.isEmpty {
            findings.append("External app-bundled Wine/Steam process evidence was present while ForgePlay was attempting to validate Windows Steam. Any runner or prefix owned by another macOS app violates this hard gate.")
        }
        if bootstrapUpdateDeferred {
            findings.append("Steam bootstrap update was still in progress. ForgePlay did not report SUCCESS and did not stop Windows Steam; UI verification is deferred until Steam finishes updating and starts WebHelper.")
        } else if processEvidenceDeferred {
            findings.append("The Steam launch command succeeded, but the sandboxed operational run could not confirm a live Steam/WebHelper process before the evidence deadline. ForgePlay did not report SUCCESS and did not stop Steam; confirm the visible window directly.")
        } else if !hardGateFailureReasons.isEmpty {
            if gateStatus == .launched {
                findings.append("Operational launch is LAUNCHED, not SUCCESS: process evidence was incomplete, so visible UI status remains unverified. Steam was left running for normal startup.")
            } else {
                findings.append("Hard gate did not receive the full same-run evidence set required for SUCCESS. ForgePlay reports this launch as \(gateStatus.rawValue).")
            }
        }
        if stderr.contains("wine cannot find the freetype font library") ||
            stderr.contains("libfreetype") {
            findings.append("FreeType runtime is missing or not loadable. Steam text/UI rendering can fail before the client appears.")
        }
        if stderr.contains("libgnutls") ||
            stderr.contains("no schannel support") ||
            stderr.contains("gnutls") && stderr.contains("failed") {
            findings.append("GnuTLS/Schannel runtime is missing or not loadable. Steam sign-in, update, or HTTPS bootstrap can fail.")
        }
        if stderr.contains("wine was built without vulkan support") ||
            stderr.contains("failed to load libvulkan") ||
            stderr.contains("vulkan_init_once") {
            findings.append("Vulkan loader/runtime is unavailable to the bundled ForgePlay Runtime. Steam WebHelper GPU initialization and Vulkan/DXVK Steam-launched game paths can fail.")
        }
        if webHelperGPU.contains("internal vulkan error") ||
            webHelperGPU.contains("eglinitialize swangle failed") ||
            webHelperGPU.contains("egl_not_initialized") ||
            webHelperGPU.contains("no available renderers") ||
            webHelperGPU.contains("vulkanfromangle") {
            findings.append("Steam WebHelper CEF/ANGLE attempted the Vulkan or SwiftShader path during Steam UI startup. This is Windows Steam CEF/WebHelper rendering failure evidence, not proof that an unverified CEF launch flag should be added; treat the launch as unusable until the Steam launch path and bundled ForgePlay Runtime are repaired and validated.")
        }
        if hasDecisiveWebHelperGPUFailure(webHelperGPU) {
            findings.append("Steam WebHelper GPU initialization failed before the login/library UI could be trusted. D3D11/D3D9 EGL reported no available renderers, so ForgePlay must treat this as a Steam UI renderer failure even when steamui_login.txt or steamui_html.txt did not produce a fresh matching tail.")
        }
        if steamUIRenderingFailed && (
            combinedLaunchText.contains("use-angle=swiftshader-webgl") ||
                combinedLaunchText.contains("vk_swiftshader.dll") ||
                combinedLaunchText.contains("vk_swiftshader_icd.json")
        ) {
            findings.append("Steam WebHelper selected Chromium ANGLE SwiftShader/WebGL instead of the ForgePlay Runtime Direct3D/Metal renderer path. This is a Steam CEF/WebHelper runtime compatibility failure, not a missing game dependency or proof that a CEF flag workaround is validated.")
        }
        if hasSteamWebHelperProcessPolicyApplied(in: combinedLaunchText) {
            findings.append("The executable-scoped Steam WebHelper process policy reached the Valve-managed WebHelper. This proves only that the bundled Wine CreateProcess policy was applied; visible login, Steam Guard, or Library rendering still depends on the ForgePlay Runtime cross-process window-surface path and must be verified separately.")
        }
        if steamUIRenderingFailed &&
            combinedLaunchText.contains("angle_default_platform") &&
            combinedLaunchText.contains("d3d11.dll") &&
            (
                combinedLaunchText.contains("use-angle=swiftshader-webgl") ||
                    combinedLaunchText.contains("vk_swiftshader.dll")
            ) {
            findings.append("Steam WebHelper observed ANGLE_DEFAULT_PLATFORM/D3D11 but still fell back to SwiftShader. Treat this as evidence that the bundled ForgePlay Runtime did not hold the latest Steam WebHelper on the D3D11/D3DMetal path.")
        }
        if stderr.contains("failed to create vulkan instance") ||
            stderr.contains("failed to initialize dxvk") {
            findings.append("DXVK loaded but could not create a Vulkan instance. Vulkan/DXVK is not usable with the current runtime configuration.")
        }
        if stderr.contains("failed to dlopen d3dmetal") ||
            stderr.contains("d3dmetal.framework") ||
            stderr.contains("d3dmetal") && stderr.contains("damaged") {
            findings.append("D3DMetal renderer modules were present during Steam startup, but the D3DMetal framework could not be loaded. Do not treat this launch as successful; repair the Steam launch path and bundled ForgePlay Runtime before retrying.")
        }
        if stderr.contains("sdl2.dll") && stderr.contains("gldriverquery.exe") {
            findings.append("Steam gldriverquery.exe could not load SDL2.dll. This helper is a 32-bit SDL2 ABI client; ForgePlay must satisfy it with the bundled SDL3-backed sdl2-compat shim, not by renaming SDL3.dll.")
        }
        let driverQueryFailure =
            shaderLog.contains("gldriverquery.exe") &&
            (
                shaderLog.contains("3221225781") ||
                    shaderLog.contains("c0000135") ||
                    shaderLog.contains("yieldingruntestprogram") ||
                    shaderLog.contains("process exit code") ||
                    shaderLog.contains("failed")
            )
        if driverQueryFailure {
            findings.append("Steam shader_log.txt reports gldriverquery.exe failed with a missing-dependency style exit code. On current Windows Steam this can happen because gldriverquery.exe still imports SDL2.dll while the Steam update lays down SDL3.dll; ForgePlay applies the SDL3-backed sdl2-compat pair next to gldriverquery.exe.")
        }
        if steamUIRenderingFailed && (
            webHelperGPU.contains("gpu process was unable to boot") ||
                webHelperGPU.contains("exiting gpu process") ||
                webHelperGPU.contains("swiftshader") ||
                webHelperGPU.contains("angle") && webHelperGPU.contains("failed")
        ) {
            findings.append("Steam WebHelper GPU acceleration fell back or failed. Software fallback is not Windows Steam UI success evidence; a black window points to WebHelper rendering initialization.")
        }
        if steamUIRenderingFailed {
            if console.contains("failed creating offscreen shared js context") ||
                steamUIHTML.contains("timed out waiting for webhelper init") {
                findings.append("Steam failed before creating its shared CEF JavaScript context. ForgePlay treats this as a retryable WebHelper startup failure, not as visible Steam UI success.")
            } else {
                findings.append("Windows Steam CEF login UI was created while WebHelper GPU initialization reported the black-window signature. ForgePlay records this as rendering evidence and treats the visible Steam window as unusable.")
            }
        }
        if combinedLaunchText.contains("invalid reuse after initialization failure") {
            findings.append("Steam/CEF reused a failed initialization path. Clear stale Windows Steam/ForgePlay Runtime processes, relaunch Windows Steam through the Steam Prefix, and inspect WebHelper GPU/runtime logs.")
        }

        return findings
    }

    private func hasSteamWebHelperProcessPolicyApplied(in text: String) -> Bool {
        text.contains("-cef-disable-gpu") ||
            text.contains("--disable-gpu") ||
            text.contains("--in-process-gpu") ||
            text.contains("-cef-disable-gpu-compositing") ||
            text.contains("--disable-gpu-compositing") ||
            text.contains("disabling gpu acceleration: disabled/commandline") ||
            text.contains("disabling gpu acceleration due to --disable-gpu-compositing")
    }

    private func hasSteamWebHelperRenderingFailure(
        webHelperGPU: String,
        steamUIHTML: String,
        steamLogin: String,
        console: String
    ) -> Bool {
        let sharedContextStartupFailed =
            console.contains("failed creating offscreen shared js context") ||
            steamUIHTML.contains("timed out waiting for webhelper init")
        let gpuRenderingFailed =
            hasDecisiveWebHelperGPUFailure(webHelperGPU) ||
            webHelperGPU.contains("eglinitialize d3d11 failed") ||
            webHelperGPU.contains("eglinitialize d3d9 failed") ||
            webHelperGPU.contains("egl_not_initialized") ||
            webHelperGPU.contains("no available renderers") ||
            webHelperGPU.contains("internal vulkan error (-9)") ||
            webHelperGPU.contains("internal vulkan error (-3)") ||
            webHelperGPU.contains("initialization of all egl display types failed") ||
            webHelperGPU.contains("invalid reuse after initialization failure") ||
            webHelperGPU.contains("gpu process was unable to boot") ||
            webHelperGPU.contains("exiting gpu process") ||
            webHelperGPU.contains("gl=disabled") && webHelperGPU.contains("angle=none") ||
            webHelperGPU.contains("swiftshader") && webHelperGPU.contains("crashed")
        let loginIsWaitingForInvisibleUI =
            steamLogin.contains("waitingforcredentials") ||
            steamLogin.contains("ui request: connect")
        let createdInvisibleCEFWindow =
            steamUIHTML.contains("createbrowser") &&
            (
                steamUIHTML.contains("0x0") ||
                steamUIHTML.contains("-2147483648")
            )
        return sharedContextStartupFailed ||
            hasDecisiveWebHelperGPUFailure(webHelperGPU) ||
            gpuRenderingFailed && loginIsWaitingForInvisibleUI && createdInvisibleCEFWindow
    }

    private func hasDecisiveWebHelperGPUFailure(_ webHelperGPU: String) -> Bool {
        let hasEGLRendererFailure =
            webHelperGPU.contains("no available renderers") ||
            webHelperGPU.contains("initialization of all egl display types failed") ||
            webHelperGPU.contains("eglinitialize d3d11 failed") && webHelperGPU.contains("eglinitialize d3d9 failed")
        let hasFailedOutcome =
            webHelperGPU.contains("egl_not_initialized") ||
            webHelperGPU.contains("exiting gpu process") ||
            webHelperGPU.contains("gpu_compositing ]: disabled_software") ||
            webHelperGPU.contains("display type ]: angle_swiftshader") ||
            webHelperGPU.contains("gl implementation parts ]: (gl=egl-angle,angle=swiftshader)")
        return hasEGLRendererFailure && hasFailedOutcome
    }

    private func directRuntimeDependencySummary(for executable: URL) -> [String] {
        let dependencyRoots = directRuntimeDependencyCandidateRoots(for: executable)
        let requiredNames = [
            "libgnutls.30.dylib",
            "libfreetype.6.dylib",
            "libMoltenVK.dylib"
        ]
        for root in dependencyRoots {
            let missing = requiredNames.filter { name in
                !FileSystemItemPolicy.isRegularNonSymlinkFile(root.appending(path: name), fileManager: fileManager)
            }
            if missing.isEmpty {
                return ["- ForgePlay direct runtime dependency payload: present at \(root.path)"]
            }
        }
        return ["- ForgePlay direct runtime dependency payload: missing required Wine/Steam support dylibs in wine/lib"]
    }

    private func directRuntimeDependencyCandidateRoots(for executable: URL) -> [URL] {
        let binDirectory = executable.deletingLastPathComponent()
        let wineRoot = binDirectory.deletingLastPathComponent()
        return [
            wineRoot.appending(path: "lib", directoryHint: .isDirectory)
        ]
    }

    private func hasMacOSSteamEvidence(in text: String) -> Bool {
        text.contains("steam.appbundle") ||
            text.contains("steam.app/contents/macos") ||
            text.contains("/steam.app/") ||
            text.contains("steam_osx") ||
            text.contains("steam helper") ||
            text.contains("com.valvesoftware.steam.ipctool") ||
            text.contains("valve") && text.contains("ipcserver")
    }

    private func logFileCursor(
        for url: URL,
        allowedRoot: URL? = nil
    ) -> SteamLogFileCursor {
        switch openSecureEvidenceFile(at: url, allowedRoot: allowedRoot) {
        case .failed(let state, let detail):
            return SteamLogFileCursor(
                byteCount: 0,
                fileNumber: nil,
                modificationDate: nil,
                trailingSignature: Data(),
                captureState: state,
                captureDetail: detail
            )
        case .opened(let descriptor, let metadata):
            defer { Darwin.close(descriptor) }
            do {
                let signature = try trailingSignature(
                    descriptor: descriptor,
                    byteCount: metadata.byteCount
                )
                guard let finalMetadata = evidenceFileMetadata(descriptor: descriptor),
                      finalMetadata == metadata else {
                    return SteamLogFileCursor(
                        byteCount: metadata.byteCount,
                        fileNumber: metadata.fileNumber,
                        modificationDate: metadata.modificationDate,
                        trailingSignature: Data(),
                        captureState: .changedDuringRead,
                        captureDetail: "file size or modification time changed while the baseline cursor was captured"
                    )
                }
                return SteamLogFileCursor(
                    byteCount: metadata.byteCount,
                    fileNumber: metadata.fileNumber,
                    modificationDate: metadata.modificationDate,
                    trailingSignature: signature,
                    captureState: .captured,
                    captureDetail: "secure baseline cursor captured"
                )
            } catch {
                return SteamLogFileCursor(
                    byteCount: metadata.byteCount,
                    fileNumber: metadata.fileNumber,
                    modificationDate: metadata.modificationDate,
                    trailingSignature: Data(),
                    captureState: .unreadable,
                    captureDetail: "could not read baseline trailing signature: \(forgePlayTechnicalErrorSummary(error))"
                )
            }
        }
    }

    private func appendedTailLines(
        from url: URL,
        since cursor: SteamLogFileCursor,
        limit: Int,
        allowedRoot: URL? = nil
    ) -> [String] {
        appendedTailReadResult(
            from: url,
            since: cursor,
            limit: limit,
            allowedRoot: allowedRoot
        )
            .diagnosticLines(limit: limit)
    }

    private func appendedTailReadResult(
        from url: URL,
        since cursor: SteamLogFileCursor,
        limit: Int,
        allowedRoot: URL? = nil
    ) -> SteamLogReadResult {
        guard limit > 0 else {
            return SteamLogReadResult(state: .captured, lines: [], detail: "zero-line read requested")
        }

        if cursor.captureState == .unsafe ||
            cursor.captureState == .unreadable ||
            cursor.captureState == .changedDuringRead {
            return SteamLogReadResult(
                state: cursor.captureState,
                lines: [],
                detail: "baseline cursor was \(cursor.captureState.rawValue); historical timestamp-free lines were not attributed to this launch (\(cursor.captureDetail ?? "no additional detail"))"
            )
        }

        switch openSecureEvidenceFile(at: url, allowedRoot: allowedRoot) {
        case .failed(let state, let detail):
            return SteamLogReadResult(state: state, lines: [], detail: detail)
        case .opened(let descriptor, let metadata):
            defer { Darwin.close(descriptor) }

            var appendOffset: UInt64 = 0
            var baseState: SteamEvidenceReadState = .captured
            var baseDetail = "secure append range captured"
            if cursor.captureState == .captured,
               let cursorFileNumber = cursor.fileNumber {
                if cursorFileNumber == metadata.fileNumber {
                    if metadata.byteCount >= cursor.byteCount {
                        do {
                            let signatureMatches = try fileStillContainsTrailingSignature(
                                descriptor: descriptor,
                                cursor: cursor
                            )
                            guard signatureMatches else {
                                return SteamLogReadResult(
                                    state: .changedDuringRead,
                                    lines: [],
                                    detail: "baseline continuity signature no longer matches; historical timestamp-free lines were not attributed to this launch"
                                )
                            }
                            appendOffset = cursor.byteCount
                        } catch {
                            return SteamLogReadResult(
                                state: .unreadable,
                                lines: [],
                                detail: "could not verify baseline continuity: \(forgePlayTechnicalErrorSummary(error))"
                            )
                        }
                    } else {
                        baseState = .truncated
                        baseDetail = "log was truncated after baseline capture; current post-truncation content was inspected"
                    }
                } else {
                    baseState = .truncated
                    baseDetail = "log inode changed after baseline capture; replacement-file tail was inspected"
                }
            } else if cursor.captureState == .missing {
                baseDetail = "source was missing at baseline and was created during this launch"
            }

            guard metadata.byteCount > appendOffset else {
                guard let finalMetadata = evidenceFileMetadata(descriptor: descriptor),
                      finalMetadata == metadata else {
                    return SteamLogReadResult(
                        state: .changedDuringRead,
                        lines: [],
                        detail: "file changed while confirming that no appended bytes were present"
                    )
                }
                return SteamLogReadResult(state: baseState, lines: [], detail: baseDetail)
            }

            let availableBytes = metadata.byteCount - appendOffset
            let byteLimit = UInt64(diagnosticTailByteLimit)
            let wasByteLimited = availableBytes > byteLimit
            let readOffset = wasByteLimited ? metadata.byteCount - byteLimit : appendOffset
            let requestedByteCount = Int(metadata.byteCount - readOffset)
            let data: Data
            do {
                data = try readFileBytes(
                    descriptor: descriptor,
                    offset: Int64(readOffset),
                    count: requestedByteCount
                )
            } catch {
                return SteamLogReadResult(
                    state: .unreadable,
                    lines: [],
                    detail: "bounded append read failed: \(forgePlayTechnicalErrorSummary(error))"
                )
            }

            let finalMetadata = evidenceFileMetadata(descriptor: descriptor)
            let changedDuringRead = finalMetadata != metadata || data.count != requestedByteCount
            var text = String(decoding: data, as: UTF8.self)
            if readOffset > appendOffset,
               let firstNewline = text.firstIndex(where: { $0.isNewline }) {
                text = String(text[text.index(after: firstNewline)...])
            }
            let lines = Array(text.split(
                omittingEmptySubsequences: false,
                whereSeparator: { $0.isNewline }
            ).map(String.init).suffix(limit))
            if changedDuringRead {
                return SteamLogReadResult(
                    state: .changedDuringRead,
                    lines: lines,
                    detail: "file size or modification time changed during the bounded append read; the captured tail is an unstable snapshot"
                )
            }
            if wasByteLimited {
                return SteamLogReadResult(
                    state: .truncated,
                    lines: lines,
                    detail: "appended content was bounded to the last \(diagnosticTailByteLimit) bytes before line limiting"
                )
            }
            return SteamLogReadResult(state: baseState, lines: lines, detail: baseDetail)
        }
    }

    private func trailingSignature(descriptor: Int32, byteCount: UInt64) throws -> Data {
        guard byteCount > 0 else { return Data() }
        let signatureLength = min(byteCount, 64)
        let signature = try readFileBytes(
            descriptor: descriptor,
            offset: Int64(byteCount - signatureLength),
            count: Int(signatureLength)
        )
        guard signature.count == Int(signatureLength) else {
            throw CocoaError(.fileReadUnknown)
        }
        return signature
    }

    private func fileStillContainsTrailingSignature(
        descriptor: Int32,
        cursor: SteamLogFileCursor
    ) throws -> Bool {
        guard !cursor.trailingSignature.isEmpty else { return cursor.byteCount == 0 }
        guard cursor.byteCount >= UInt64(cursor.trailingSignature.count) else { return false }
        let current = try readFileBytes(
            descriptor: descriptor,
            offset: Int64(cursor.byteCount - UInt64(cursor.trailingSignature.count)),
            count: cursor.trailingSignature.count
        )
        guard current.count == cursor.trailingSignature.count else {
            throw CocoaError(.fileReadUnknown)
        }
        return current == cursor.trailingSignature
    }

    private func filterSteamLogLines(_ lines: [String], modifiedAfter cutoff: Date) -> [String] {
        lines.filter { line in
            guard let loggedAt = steamLogTimestamp(in: line) else { return true }
            return loggedAt >= cutoff
        }
    }

    private func tailLines(
        from url: URL,
        limit: Int,
        modifiedAfter cutoff: Date? = nil,
        allowedRoot: URL? = nil
    ) -> [String] {
        tailReadResult(
            from: url,
            limit: limit,
            modifiedAfter: cutoff,
            allowedRoot: allowedRoot
        )
            .diagnosticLines(limit: limit)
    }

    private func tailReadResult(
        from url: URL,
        limit: Int,
        modifiedAfter cutoff: Date? = nil,
        allowedRoot: URL? = nil
    ) -> SteamLogReadResult {
        guard limit > 0 else {
            return SteamLogReadResult(state: .captured, lines: [], detail: "zero-line read requested")
        }
        switch openSecureEvidenceFile(at: url, allowedRoot: allowedRoot) {
        case .failed(let state, let detail):
            return SteamLogReadResult(state: state, lines: [], detail: detail)
        case .opened(let descriptor, let metadata):
            defer { Darwin.close(descriptor) }
            if let cutoff, metadata.modificationDate < cutoff {
                guard let finalMetadata = evidenceFileMetadata(descriptor: descriptor),
                      finalMetadata == metadata else {
                    return SteamLogReadResult(
                        state: .changedDuringRead,
                        lines: [],
                        detail: "file changed while its modification time was compared with the launch cutoff"
                    )
                }
                return SteamLogReadResult(
                    state: .captured,
                    lines: [],
                    detail: "file was unchanged since the launch cutoff"
                )
            }

            let byteLimit = UInt64(diagnosticTailByteLimit)
            let wasByteLimited = metadata.byteCount > byteLimit
            let readOffset = wasByteLimited ? metadata.byteCount - byteLimit : 0
            let requestedByteCount = Int(metadata.byteCount - readOffset)
            let data: Data
            do {
                data = try readFileBytes(
                    descriptor: descriptor,
                    offset: Int64(readOffset),
                    count: requestedByteCount
                )
            } catch {
                return SteamLogReadResult(
                    state: .unreadable,
                    lines: [],
                    detail: "bounded tail read failed: \(forgePlayTechnicalErrorSummary(error))"
                )
            }
            let finalMetadata = evidenceFileMetadata(descriptor: descriptor)
            let changedDuringRead = finalMetadata != metadata || data.count != requestedByteCount
            var text = String(decoding: data, as: UTF8.self)
            if wasByteLimited,
               let firstNewline = text.firstIndex(where: { $0.isNewline }) {
                text = String(text[text.index(after: firstNewline)...])
            }
            let rawLines = text.split(
                omittingEmptySubsequences: false,
                whereSeparator: { $0.isNewline }
            ).map(String.init)
            let relevantLines = cutoff.map {
                filterSteamLogLines(rawLines, modifiedAfter: $0)
            } ?? rawLines
            let lines = Array(relevantLines.suffix(limit))
            if changedDuringRead {
                return SteamLogReadResult(
                    state: .changedDuringRead,
                    lines: lines,
                    detail: "file size or modification time changed during the bounded tail read; the captured tail is an unstable snapshot"
                )
            }
            if wasByteLimited {
                return SteamLogReadResult(
                    state: .truncated,
                    lines: lines,
                    detail: "tail was bounded to the last \(diagnosticTailByteLimit) bytes before line limiting"
                )
            }
            return SteamLogReadResult(state: .captured, lines: lines, detail: "secure bounded tail captured")
        }
    }

    private func openSecureEvidenceFile(
        at url: URL,
        allowedRoot: URL? = nil
    ) -> SecureEvidenceFileOpenResult {
        if let allowedRoot {
            return openSecureEvidenceFileAnchored(at: url, allowedRoot: allowedRoot)
        }
        var pathStatus = stat()
        guard Darwin.lstat(url.path, &pathStatus) == 0 else {
            let code = errno
            if code == ENOENT {
                return .failed(state: .missing, detail: "source does not exist: \(url.path)")
            }
            return .failed(
                state: .unreadable,
                detail: "lstat failed for \(url.path): \(posixFailureDescription(code))"
            )
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFREG,
              pathStatus.st_nlink == 1,
              pathStatus.st_size >= 0 else {
            return .failed(
                state: .unsafe,
                detail: "source is not a single-link regular file: \(url.path)"
            )
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let code = errno
            return .failed(
                state: code == ELOOP ? .unsafe : .unreadable,
                detail: "secure open failed for \(url.path): \(posixFailureDescription(code))"
            )
        }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            return .failed(
                state: .unreadable,
                detail: "fstat failed for \(url.path): \(posixFailureDescription(code))"
            )
        }
        guard (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_size >= 0 else {
            Darwin.close(descriptor)
            return .failed(
                state: .unsafe,
                detail: "securely opened source is not a single-link regular file: \(url.path)"
            )
        }
        let metadata = evidenceFileMetadata(from: descriptorStatus)
        let pathFileNumber = UInt64(pathStatus.st_ino)
        let pathDeviceNumber = UInt64(bitPattern: Int64(pathStatus.st_dev))
        guard metadata.fileNumber == pathFileNumber,
              metadata.deviceNumber == pathDeviceNumber else {
            Darwin.close(descriptor)
            return .failed(
                state: .changedDuringRead,
                detail: "source identity changed between lstat and secure open: \(url.path)"
            )
        }
        return .opened(descriptor: descriptor, metadata: metadata)
    }

    private func openSecureEvidenceFileAnchored(
        at url: URL,
        allowedRoot: URL
    ) -> SecureEvidenceFileOpenResult {
        let standardizedRoot = allowedRoot.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let parentURL = standardizedURL.deletingLastPathComponent()
        let isBelowRoot = standardizedRoot.path == "/"
            ? standardizedURL.path != "/"
            : standardizedURL.path.hasPrefix("\(standardizedRoot.path)/")
        guard isBelowRoot else {
            return .failed(
                state: .unsafe,
                detail: "source is outside the allowed evidence root \(standardizedRoot.path): \(standardizedURL.path)"
            )
        }

        let parentDescriptor: Int32
        let initialParentIdentity: EvidenceDirectoryIdentity
        switch openSecureEvidenceDirectory(parentURL, anchoredAt: standardizedRoot) {
        case .failed(let state, let detail):
            return .failed(state: state, detail: detail)
        case .opened(let descriptor, let identity):
            parentDescriptor = descriptor
            initialParentIdentity = identity
        }

        let leafName = standardizedURL.lastPathComponent
        var pathStatus = stat()
        let pathStatusResult = leafName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard pathStatusResult == 0 else {
            let code = errno
            Darwin.close(parentDescriptor)
            return .failed(
                state: secureEvidenceFailureState(for: code),
                detail: "secure leaf inspection failed for \(standardizedURL.path): \(posixFailureDescription(code))"
            )
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFREG,
              pathStatus.st_nlink == 1,
              pathStatus.st_size >= 0 else {
            Darwin.close(parentDescriptor)
            return .failed(
                state: .unsafe,
                detail: "source is not a single-link regular file below the allowed root: \(standardizedURL.path)"
            )
        }

        let descriptor = leafName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = errno
            Darwin.close(parentDescriptor)
            return .failed(
                state: secureEvidenceFailureState(for: code),
                detail: "secure leaf open failed for \(standardizedURL.path): \(posixFailureDescription(code))"
            )
        }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
            return .failed(
                state: .unreadable,
                detail: "fstat failed for \(standardizedURL.path): \(posixFailureDescription(code))"
            )
        }
        guard (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_size >= 0 else {
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
            return .failed(
                state: .unsafe,
                detail: "securely opened source is not a single-link regular file: \(standardizedURL.path)"
            )
        }
        let metadata = evidenceFileMetadata(from: descriptorStatus)
        let inspectedMetadata = evidenceFileMetadata(from: pathStatus)
        guard metadata.deviceNumber == inspectedMetadata.deviceNumber,
              metadata.fileNumber == inspectedMetadata.fileNumber else {
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
            return .failed(
                state: .changedDuringRead,
                detail: "source identity changed between anchored inspection and open: \(standardizedURL.path)"
            )
        }

        var finalPathStatus = stat()
        let finalPathStatusResult = leafName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &finalPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        Darwin.close(parentDescriptor)
        guard finalPathStatusResult == 0,
              (finalPathStatus.st_mode & S_IFMT) == S_IFREG,
              finalPathStatus.st_nlink == 1,
              finalPathStatus.st_size >= 0 else {
            let code = errno
            Darwin.close(descriptor)
            return .failed(
                state: finalPathStatusResult == 0 ? .changedDuringRead : secureEvidenceFailureState(for: code),
                detail: "source path changed immediately after anchored open: \(standardizedURL.path)"
            )
        }
        let finalPathMetadata = evidenceFileMetadata(from: finalPathStatus)
        guard finalPathMetadata.deviceNumber == metadata.deviceNumber,
              finalPathMetadata.fileNumber == metadata.fileNumber else {
            Darwin.close(descriptor)
            return .failed(
                state: .changedDuringRead,
                detail: "source path identity changed immediately after anchored open: \(standardizedURL.path)"
            )
        }

        switch openSecureEvidenceDirectory(parentURL, anchoredAt: standardizedRoot) {
        case .failed(let state, let detail):
            Darwin.close(descriptor)
            return .failed(
                state: state == .unsafe ? .unsafe : .changedDuringRead,
                detail: "source parent changed after anchored open: \(detail)"
            )
        case .opened(let verificationParentDescriptor, let finalParentIdentity):
            Darwin.close(verificationParentDescriptor)
            guard finalParentIdentity == initialParentIdentity else {
                Darwin.close(descriptor)
                return .failed(
                    state: .changedDuringRead,
                    detail: "source parent identity changed during anchored open: \(parentURL.path)"
                )
            }
        }
        return .opened(descriptor: descriptor, metadata: metadata)
    }

    private func openSecureEvidenceDirectory(
        _ directory: URL,
        anchoredAt root: URL
    ) -> SecureEvidenceDirectoryOpenResult {
        let standardizedRoot = root.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        let isInsideRoot = standardizedDirectory.path == standardizedRoot.path ||
            standardizedRoot.path == "/" ||
            standardizedDirectory.path.hasPrefix("\(standardizedRoot.path)/")
        guard isInsideRoot else {
            return .failed(
                state: .unsafe,
                detail: "directory is outside the allowed evidence root \(standardizedRoot.path): \(standardizedDirectory.path)"
            )
        }

        var descriptor = Darwin.open(
            standardizedRoot.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            let code = errno
            return .failed(
                state: secureEvidenceFailureState(for: code),
                detail: "secure evidence root open failed for \(standardizedRoot.path): \(posixFailureDescription(code))"
            )
        }

        let rootComponents = standardizedRoot.pathComponents
        let directoryComponents = standardizedDirectory.pathComponents
        for component in directoryComponents.dropFirst(rootComponents.count) {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            let code = errno
            Darwin.close(descriptor)
            guard nextDescriptor >= 0 else {
                return .failed(
                    state: secureEvidenceFailureState(for: code),
                    detail: "secure directory component open failed for \(standardizedDirectory.path): \(posixFailureDescription(code))"
                )
            }
            descriptor = nextDescriptor
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            return .failed(
                state: .unsafe,
                detail: "securely opened evidence parent is not a directory: \(standardizedDirectory.path) (\(posixFailureDescription(code)))"
            )
        }
        return .opened(
            descriptor: descriptor,
            identity: EvidenceDirectoryIdentity(
                deviceNumber: UInt64(bitPattern: Int64(status.st_dev)),
                fileNumber: UInt64(status.st_ino)
            )
        )
    }

    private func secureEvidenceFailureState(for code: Int32) -> SteamEvidenceReadState {
        switch code {
        case ENOENT:
            .missing
        case ELOOP, ENOTDIR:
            .unsafe
        default:
            .unreadable
        }
    }

    private func evidenceFileMetadata(descriptor: Int32) -> EvidenceFileMetadata? {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0 else {
            return nil
        }
        return evidenceFileMetadata(from: status)
    }

    private func evidenceFileMetadata(from status: stat) -> EvidenceFileMetadata {
        return EvidenceFileMetadata(
            byteCount: UInt64(status.st_size),
            fileNumber: UInt64(status.st_ino),
            deviceNumber: UInt64(bitPattern: Int64(status.st_dev)),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private func posixFailureDescription(_ code: Int32) -> String {
        let message = String(cString: Darwin.strerror(code))
        return "errno=\(code) \(message)"
    }

    private func steamLogTimestamp(in line: String) -> Date? {
        guard line.first == "[",
              let end = line.firstIndex(of: "]") else {
            return nil
        }
        let rawTimestamp = String(line[line.index(after: line.startIndex)..<end])
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: rawTimestamp) {
                return date
            }
        }
        return nil
    }

    private func limitedDiagnosticLines(_ lines: [String], limit: Int) -> [String] {
        guard limit > 0, lines.count > limit else {
            return lines
        }
        let retainedLineCount = max(limit - 1, 0)
        return [
            "[ForgePlay: diagnostic section truncated to last \(limit) lines]",
        ] + Array(lines.suffix(retainedLineCount))
    }

    private func minidumpExceptionSummary(
        at url: URL,
        allowedRoot: URL
    ) -> String? {
        let descriptor: Int32
        switch openSecureEvidenceFile(at: url, allowedRoot: allowedRoot) {
        case .failed(let state, let detail):
            return "minidump \(state.rawValue): \(detail)"
        case .opened(let openedDescriptor, _):
            descriptor = openedDescriptor
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 32,
              let header = try? readFileBytes(descriptor: descriptor, offset: 0, count: 32),
              header.count == 32,
              header.prefix(4) == Data("MDMP".utf8),
              let streamCount = uint32LE(header, at: 8),
              let directoryRVA = uint32LE(header, at: 12) else {
            return nil
        }

        let maximumStreamCount: UInt32 = 128
        guard streamCount <= maximumStreamCount else {
            return "minidump stream directory rejected: \(streamCount) entries exceeds \(maximumStreamCount)"
        }
        let directoryOffset = Int64(directoryRVA)
        let directoryByteCount = Int64(streamCount) * 12
        let fileByteCount = Int64(status.st_size)
        guard directoryOffset >= 0,
              directoryByteCount >= 0,
              directoryOffset <= fileByteCount,
              directoryByteCount <= fileByteCount - directoryOffset,
              directoryByteCount <= Int64(Int.max),
              let directory = try? readFileBytes(
                  descriptor: descriptor,
                  offset: directoryOffset,
                  count: Int(directoryByteCount)
              ),
              directory.count == Int(directoryByteCount) else {
            return "minidump stream directory is outside the file bounds"
        }

        for index in 0..<Int(streamCount) {
            let entryOffset = index * 12
            guard let streamType = uint32LE(directory, at: entryOffset),
                  let streamRVA = uint32LE(directory, at: entryOffset + 8),
                  streamType == 6 else {
                continue
            }
            let streamOffset = Int64(streamRVA)
            let requiredStreamBytes = 32
            guard streamOffset <= fileByteCount,
                  Int64(requiredStreamBytes) <= fileByteCount - streamOffset,
                  let exception = try? readFileBytes(
                      descriptor: descriptor,
                      offset: streamOffset,
                      count: requiredStreamBytes
                  ),
                  exception.count == requiredStreamBytes,
                  let code = uint32LE(exception, at: 8),
                  let address = uint64LE(exception, at: 24) else {
                return "exception stream unreadable"
            }
            if code == 0xC0000005 {
                return "exception=0xC0000005 access violation address=0x\(String(address, radix: 16, uppercase: true))"
            }
            return "exception=0x\(String(code, radix: 16, uppercase: true)) address=0x\(String(address, radix: 16, uppercase: true))"
        }
        return nil
    }

    private func readFileBytes(
        descriptor: Int32,
        offset: Int64,
        count: Int
    ) throws -> Data {
        guard offset >= 0, count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard count > 0 else { return Data() }
        var output = Data()
        output.reserveCapacity(count)
        var currentOffset = offset
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

    private func uint32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let start = data.startIndex.advanced(by: offset)
        return UInt32(data[start]) |
            (UInt32(data[data.index(after: start)]) << 8) |
            (UInt32(data[data.index(start, offsetBy: 2)]) << 16) |
            (UInt32(data[data.index(start, offsetBy: 3)]) << 24)
    }

    private func uint64LE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[data.startIndex.advanced(by: offset + index)]) << UInt64(index * 8)
        }
        return value
    }
}

private extension Array where Element == String {
    var hasOnlyEmptyDiagnosticLines: Bool {
        allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var diagnosticText: String {
        guard !isEmpty else { return "none\n" }
        return joined(separator: "\n") + "\n"
    }
}

private extension Array where Element == SteamLaunchObservedProcess {
    var diagnosticText: String {
        guard !isEmpty else { return "none\n" }
        return map(\.diagnosticLine).joined(separator: "\n") + "\n"
    }
}

private extension Array where Element == MacOSSteamProcess {
    var diagnosticText: String {
        guard !isEmpty else { return "none\n" }
        return map { "PID \($0.processID): \($0.command)" }.joined(separator: "\n") + "\n"
    }
}
