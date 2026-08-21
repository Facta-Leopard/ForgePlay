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
    /// Next exact source generation, present only after a stable append read.
    var nextCursor: SteamLogFileCursor? = nil

    var evidenceUnavailable: Bool {
        switch state {
        case .unreadable, .unsafe, .changedDuringRead:
            true
        case .missing:
            required
        case .captured:
            false
        case .truncated:
            true
        }
    }
}

struct SteamBootstrapUpdateLogAssessment: Sendable, Hashable {
    /// `nil` means that unavailable evidence prevented a reliable yes/no answer.
    var hasProgress: Bool?
    var state: SteamEvidenceReadState
    var detail: String
    var sources: [SteamBootstrapLogSourceAssessment]
    /// Stable identity of the safely captured updater-progress lines. A live
    /// Steam process plus an old progress string is not current updater
    /// activity; the bootstrap lifecycle extends its nominal wait only while
    /// this identity is new or was observed advancing recently.
    var progressIdentity: String?
    var observedProgress: Bool = false
    var observedCompletion: Bool = false
    var nextCursor: SteamBootstrapUpdateSourceCursor? = nil
    /// Every updater event captured in this append generation, ordered within
    /// its own source. There is intentionally no synthetic ordering between
    /// stdout and bootstrap_log.txt.
    var sourceEvents: [SteamBootstrapOrderedEvent] = []

    var evidenceUnavailable: Bool {
        sources.contains(where: \.evidenceUnavailable)
    }
}

struct SteamBootstrapUpdateSourceCursor: Sendable, Hashable {
    var stdout: SteamLogFileCursor
    var bootstrapLog: SteamLogFileCursor
}

enum SteamBootstrapOrderedEventKind: Sendable, Hashable {
    case progress
    case completion
}

enum SteamBootstrapUpdaterEvidenceSource: String, Sendable, Hashable, CaseIterable {
    case stdout
    case bootstrapLog
}

struct SteamBootstrapOrderedEvent: Sendable, Hashable {
    var source: SteamBootstrapUpdaterEvidenceSource
    var kind: SteamBootstrapOrderedEventKind
    var normalizedLine: String
    var sourceURL: URL
    var lineIndex: Int
    var generationCursor: SteamLogFileCursor

    var identity: String {
        [
            source.rawValue,
            sourceURL.standardizedFileURL.path,
            String(generationCursor.deviceNumber ?? 0),
            String(generationCursor.fileNumber ?? 0),
            String(generationCursor.byteCount),
            String(lineIndex),
            normalizedLine
        ].joined(separator: "|")
    }
}

enum SteamBootstrapUpdaterLifecycleState: Sendable, Hashable {
    case inProgress
    case notInProgress
    case evidenceUnavailable

    init(_ assessment: SteamBootstrapUpdateLogAssessment) {
        switch assessment.hasProgress {
        case true:
            self = .inProgress
        case false:
            self = .notInProgress
        case nil:
            self = .evidenceUnavailable
        }
    }
}

enum SteamBootstrapUpdaterEvidenceContinuity: Sendable, Hashable {
    case notInProgress
    case recentOrAdvancing
    /// A verified per-architecture completion is held for the fixed two-second
    /// stabilization interval while Steam replaces its updater process.
    case stageTransition
    case stale
    case evidenceUnavailable
}

/// Availability of the updater evidence read performed for this exact poll.
/// This remains separate from retained lifecycle continuity: a recent verified
/// progress observation may safely keep waiting through a transient read
/// failure, but that failed read must never authorize destructive recovery.
enum SteamBootstrapUpdaterEvidenceAvailability: Sendable, Hashable {
    case verified
    case transientlyUnavailable
    case unavailable

    init(_ assessment: SteamBootstrapUpdateLogAssessment) {
        guard assessment.evidenceUnavailable else {
            self = .verified
            return
        }
        let unavailableSources = assessment.sources.filter(
            \.evidenceUnavailable
        )
        self = !unavailableSources.isEmpty && unavailableSources.allSatisfy {
            $0.state == .missing || $0.state == .unreadable
        } ? .transientlyUnavailable : .unavailable
    }
}

struct SteamBootstrapUpdaterEvidenceTracker: Sendable, Hashable {
    /// The real updater can emit a per-architecture "update complete" row,
    /// restart, and begin the next architecture about one second later. Hold a
    /// completion candidate briefly so that later source-ordered progress can
    /// supersede it instead of letting a poll in that gap terminate the wait.
    private static let completionStabilizationInterval: TimeInterval = 2

    private(set) var progressIdentity: String? = nil
    private(set) var lastAdvancedAt: Date? = nil
    private(set) var updaterIsInProgress = false
    private(set) var cursor: SteamBootstrapUpdateSourceCursor
    private var stdoutEvent: SteamBootstrapOrderedEvent?
    private var bootstrapLogEvent: SteamBootstrapOrderedEvent?
    private var completionCandidateObservedAt: Date?

    init(cursor: SteamBootstrapUpdateSourceCursor) {
        self.cursor = cursor
    }

    mutating func observe(
        assessment: SteamBootstrapUpdateLogAssessment,
        at now: Date,
        idleTimeout: TimeInterval
    ) -> (
        state: SteamBootstrapUpdaterLifecycleState,
        continuity: SteamBootstrapUpdaterEvidenceContinuity
    ) {
        let currentEvidenceAvailability =
            SteamBootstrapUpdaterEvidenceAvailability(assessment)
        if currentEvidenceAvailability != .verified {
            guard currentEvidenceAvailability == .transientlyUnavailable else {
                return (.evidenceUnavailable, .evidenceUnavailable)
            }
            // Do not advance the cursor, source-event identities, or
            // lastAdvancedAt from a partially unreadable poll. A previously
            // verified updater remains continuous only within its original
            // idle window, so repeated failures cannot manufacture freshness.
            if let completionCandidateObservedAt,
               now.timeIntervalSince(completionCandidateObservedAt) <
                Self.completionStabilizationInterval {
                return (.inProgress, .stageTransition)
            }
            guard updaterIsInProgress else {
                return (.evidenceUnavailable, .evidenceUnavailable)
            }
            guard let lastAdvancedAt,
                  now.timeIntervalSince(lastAdvancedAt) <= max(0, idleTimeout)
            else {
                return (.inProgress, .stale)
            }
            return (.inProgress, .recentOrAdvancing)
        }
        if let nextCursor = assessment.nextCursor {
            cursor = nextCursor
        }
        if !assessment.sourceEvents.isEmpty {
            let wasInProgress = updaterIsInProgress
            var observedAdvancingProgress = false
            for event in assessment.sourceEvents {
                let previousEvent: SteamBootstrapOrderedEvent?
                switch event.source {
                case .stdout:
                    previousEvent = stdoutEvent
                    stdoutEvent = event
                case .bootstrapLog:
                    previousEvent = bootstrapLogEvent
                    bootstrapLogEvent = event
                }
                if event.kind == .progress,
                   previousEvent?.identity != event.identity {
                    observedAdvancingProgress = true
                }
            }

            let activeProgressEvents = [stdoutEvent, bootstrapLogEvent]
                .compactMap { $0 }
                .filter { $0.kind == .progress }
                .sorted { $0.source.rawValue < $1.source.rawValue }
            if activeProgressEvents.isEmpty {
                updaterIsInProgress = false
                progressIdentity = nil
                lastAdvancedAt = nil
                let observedCompletion = assessment.sourceEvents.contains {
                    $0.kind == .completion
                }
                let completionFollowedProgress =
                    wasInProgress ||
                    assessment.sourceEvents.contains { $0.kind == .progress } ||
                    completionCandidateObservedAt != nil
                if observedCompletion, completionFollowedProgress {
                    completionCandidateObservedAt = now
                }
            } else {
                updaterIsInProgress = true
                completionCandidateObservedAt = nil
                let combinedIdentity = activeProgressEvents
                    .map(\.identity)
                    .joined(separator: "\n")
                progressIdentity = SHA256.hash(data: Data(combinedIdentity.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                if observedAdvancingProgress {
                    lastAdvancedAt = now
                }
            }
        }
        if let completionCandidateObservedAt {
            if now.timeIntervalSince(completionCandidateObservedAt) <
                Self.completionStabilizationInterval {
                return (.inProgress, .stageTransition)
            }
            self.completionCandidateObservedAt = nil
        }
        if !assessment.sourceEvents.isEmpty {
            guard updaterIsInProgress else {
                return (.notInProgress, .notInProgress)
            }
            guard let lastAdvancedAt,
                  now.timeIntervalSince(lastAdvancedAt) <= max(0, idleTimeout)
            else {
                return (.inProgress, .stale)
            }
            return (.inProgress, .recentOrAdvancing)
        }

        // Compatibility path for focused lifecycle fixtures that construct an
        // assessment directly rather than reading a concrete source append.
        if assessment.observedCompletion {
            updaterIsInProgress = false
            progressIdentity = nil
            lastAdvancedAt = nil
            return (.notInProgress, .notInProgress)
        }
        if assessment.observedProgress {
            guard let nextIdentity = assessment.progressIdentity,
                  !nextIdentity.isEmpty else {
                return (.evidenceUnavailable, .evidenceUnavailable)
            }
            updaterIsInProgress = true
            if progressIdentity != nextIdentity {
                progressIdentity = nextIdentity
                lastAdvancedAt = now
                return (.inProgress, .recentOrAdvancing)
            }
        }
        guard updaterIsInProgress else {
            return (.notInProgress, .notInProgress)
        }
        guard let lastAdvancedAt,
              now.timeIntervalSince(lastAdvancedAt) <= max(0, idleTimeout)
        else {
            return (.inProgress, .stale)
        }
        return (.inProgress, .recentOrAdvancing)
    }
}

/// One launch-dispatch-owned updater cursor. The final launch assessment keeps
/// this cursor stable so an old updater batch cannot become "fresh" merely
/// because the assessment rereads the launch baseline.
final class SteamBootstrapUpdaterEvidenceSession {
    var tracker: SteamBootstrapUpdaterEvidenceTracker

    init(cursor: SteamBootstrapUpdateSourceCursor) {
        tracker = SteamBootstrapUpdaterEvidenceTracker(cursor: cursor)
    }
}

enum SteamLaunchDispatchDisposition: Equatable, Sendable {
    case runningDetachedProcess
    case successfulForgePlayLauncherHandoff
    case completedOrFailed

    static func resolve(_ result: ProcessRunResult) -> Self {
        guard result.actionName == "launchSteam",
              !result.didTimeOut else {
            return .completedOrFailed
        }
        if !result.waitedForExit,
           result.outcome == .runningDetached {
            return .runningDetachedProcess
        }
        guard result.waitedForExit,
              result.outcome == .exited,
              result.processExitCode == 0,
              result.terminationSignal == nil,
              result.arguments.count >= 3,
              URL(fileURLWithPath: result.arguments[0])
                .lastPathComponent
                .caseInsensitiveCompare("forgeplay-steam-launcher.exe") ==
                .orderedSame,
              result.arguments[1] == "--detach",
              result.arguments[2] == "--" else {
            return .completedOrFailed
        }
        return .successfulForgePlayLauncherHandoff
    }

    var acceptsSessionLifetime: Bool {
        self != .completedOrFailed
    }

    var isSuccessfulDetachedHelperHandoff: Bool {
        self == .successfulForgePlayLauncherHandoff
    }
}

private enum SteamCompatibilitySessionCommitAdmission {
    case providerReceiptsVerified
    case successfulDetachedHandoff(rendererPreparationVerified: Bool)
}

/// Keeps prefix mutation and execution ownership explicit across Steam's
/// bootstrap/retry state machine. Mutating Steam launches cannot be created
/// without this transition owner.
struct SteamPrefixExecutionLeaseTransition {
    let prepareForMutation: () throws -> Void
    let prepareForExecution: () throws -> Void
    let restorationLease: SteamCompatibilityRestorationPrefixLease?

    init(
        prepareForMutation: @escaping () throws -> Void,
        prepareForExecution: @escaping () throws -> Void,
        restorationLease: SteamCompatibilityRestorationPrefixLease? = nil
    ) {
        self.prepareForMutation = prepareForMutation
        self.prepareForExecution = prepareForExecution
        self.restorationLease = restorationLease
    }
}

/// Gives the termination-restoration lifecycle exclusive-mutation authority.
/// Direct launches also transfer release ownership; coordinated provider
/// launches delegate mutation while their retained transaction remains the
/// sole owner responsible for releasing the underlying prefix lease.
@MainActor
final class SteamCompatibilityRestorationPrefixLease {
    private let prepareForMutationImplementation: () throws -> Void
    private let releaseImplementation: () -> Void
    private(set) var isTransferred = false
    private var isReleased = false

    init(
        prepareForMutation: @escaping () throws -> Void,
        release: @escaping () -> Void
    ) {
        prepareForMutationImplementation = prepareForMutation
        releaseImplementation = release
    }

    func markTransferred() {
        precondition(!isReleased)
        isTransferred = true
    }

    func prepareForMutation() throws {
        precondition(!isReleased)
        try prepareForMutationImplementation()
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseImplementation()
    }
}

struct SteamLibraryDrivePreparation: Hashable {
    var mappings: [SteamLibraryDriveMapping]
    var pendingMappings: [SteamLibraryDriveMapping]
    var externalStorageRoots: [URL]
    var discoveries: [SteamLibraryRootDiscoveryResult]
}

struct SteamCompatibilityPersistentPrefixSnapshot: Hashable, Sendable {
    let prefixMetadata: Data?
    let steamLibraryFolders: Data?
    let dosDeviceSymlinkTargets: [String: String]
    let digest: String
}

struct GameInputProtectionContainmentDiagnosticError:
    LocalizedError,
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError,
    DiagnosticEvidenceCollectionProvidingError,
    ForgePlayDiagnosticLogProvidingError,
    @unchecked Sendable {
    let underlyingError: Error
    let diagnosticProcessResults: [ProcessRunResult]

    var errorDescription: String? {
        (underlyingError as? LocalizedError)?.errorDescription ??
            (underlyingError as NSError).localizedDescription
    }

    var forgePlayTechnicalDescription: String {
        forgePlayTechnicalErrorSummary(underlyingError)
    }

    var forgePlayDiagnosticLogURL: URL? {
        diagnosticProcessResults.first?.preferredDiagnosticLog
    }

    @MainActor
    func localizedDescription(appState: AppState) -> String {
        appState.localizedError(underlyingError)
    }
}

@MainActor
final class GameInputProtectionContainmentProcessEvidence {
    private(set) var processResults: [ProcessRunResult] = []

    func preparingForFinalization(
        _ input: ProcessRunResult
    ) -> ProcessRunResult {
        var result = input
        SteamManager.attachLaunchChainEvidence(
            [],
            auxiliaryResults: processResults,
            to: &result
        )
        return result
    }

    func recordFinalized(_ result: ProcessRunResult) {
        let evidencePath = result.runEvidenceLog?.standardizedFileURL.path
        guard !processResults.contains(where: {
            if let evidencePath {
                return $0.runEvidenceLog?.standardizedFileURL.path == evidencePath
            }
            return $0 == result
        }) else { return }
        processResults.append(result)
    }
}

@MainActor
final class SteamManager {
    typealias CompatibilityPrefixExitWaiter = @Sendable (
        _ prefix: URL,
        _ timeout: TimeInterval,
        _ pollInterval: TimeInterval
    ) async throws -> Bool
    typealias DetachedHandoffManagedWineReadbackProvider = @Sendable (
        _ prefix: URL
    ) async throws -> ManagedWineChildSynchronizationReadback?
    typealias ManagedWineLaunchProcessIdentityProvider = @Sendable (
        _ prefix: URL,
        _ runIdentifier: String
    ) async throws -> Set<ManagedWineLaunchProcessIdentity>
    typealias ManagedWineJournalProcessSnapshotProvider = (
        _ identities: Set<ManagedWineLaunchProcessIdentity>
    ) -> SteamLaunchProcessSnapshot
    typealias GameInputProtectionDriverFactory = @MainActor () ->
        any GameInputProtectionDriving
    typealias GameModeHostLaunchAdmission = () throws -> Void
    typealias SteamClientServicePreparer = @MainActor (
        _ runtimeExecutable: URL,
        _ prefix: URL,
        _ logDirectory: URL
    ) async throws -> Void

    private struct ActiveNVIDIARendererSession: Hashable {
        let prefix: URL
        let runtimeExecutable: URL
        let logDirectory: URL
    }

    private struct CompatibilityRestorationMonitor {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct GameLaunchDiagnosticMonitorKey: Equatable {
        var steamDirectory: String
        var processObservationLog: String
        var launchStdoutLog: String?
        var launchStderrLog: String?
        var cutoff: Date?
        var gameRunDirectory: String?
    }

    struct BootstrapEvidenceFileMetadata: Equatable, Sendable {
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

    nonisolated static func bootstrapEvidenceReadWindowIsStable(
        initialMetadata: BootstrapEvidenceFileMetadata,
        postReadMetadata: BootstrapEvidenceFileMetadata?,
        postRereadMetadata: BootstrapEvidenceFileMetadata?,
        capturedData: Data,
        rereadData: Data
    ) -> Bool {
        guard let postReadMetadata,
              let postRereadMetadata else { return false }
        let metadataRemainsSameNonshrinkingFile = [
            postReadMetadata,
            postRereadMetadata
        ].allSatisfy {
            $0.deviceNumber == initialMetadata.deviceNumber &&
                $0.fileNumber == initialMetadata.fileNumber &&
                $0.byteCount >= initialMetadata.byteCount
        }
        return metadataRemainsSameNonshrinkingFile &&
            capturedData == rereadData
    }

    static let officialDownloadURL = ExternalLinkPolicy.steamOfficialDownloadURL
    private nonisolated static let steamRenderingObservationTimeout: TimeInterval = 45
    private nonisolated static let steamRenderingObservationPollInterval: TimeInterval = 1
    private nonisolated static let steamProcessEvidenceTimeout: TimeInterval = 20
    private nonisolated static let steamProcessEvidencePollInterval: TimeInterval = 0.5
    private nonisolated static let steamBootstrapProgressIdleTimeout: TimeInterval = 900
    private nonisolated static let steamUIStartupObservationTimeout: TimeInterval = 60
    private nonisolated static let steamUIStartupObservationPollInterval: TimeInterval = 0.25
    private nonisolated static let steamUIProvisionalSurfaceStabilizationInterval: TimeInterval = 3
    nonisolated static let defaultSteamLaunchArguments = SteamClientCompatibilityProfile.defaultLaunchArguments

    nonisolated static func shouldDeferSteamUIVerification(
        bootstrapUpdateInProgress: Bool,
        operationalProcessVerificationUnavailable: Bool,
        didObserveExternalRunnerDuringConformance: Bool,
        hasTerminalSteamUIFailure: Bool
    ) -> Bool {
        !hasTerminalSteamUIFailure &&
            !didObserveExternalRunnerDuringConformance &&
            (bootstrapUpdateInProgress || operationalProcessVerificationUnavailable)
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let fileManager: FileManager
    private let rendererPolicyManager: SteamRendererPolicyManager
    private let windowsFontCompatibilityProfile: WindowsFontCompatibilityProfile
    private let steamClientCompatibilityProfile: SteamClientCompatibilityProfile
    private let steamClientLanguageOwnershipPolicy:
        SteamClientLanguageOwnershipPolicy
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
    private let bootstrapProgressIdleTimeout: TimeInterval
    private let steamUIStartupObservationTimeout: TimeInterval
    private let steamUIStartupObservationPollInterval: TimeInterval
    private let compatibilityPrefixExitWaiter: CompatibilityPrefixExitWaiter
    private let detachedHandoffManagedWineReadbackProvider:
        DetachedHandoffManagedWineReadbackProvider
    private let managedWineLaunchProcessIdentityProvider:
        ManagedWineLaunchProcessIdentityProvider
    private let managedWineJournalProcessSnapshotProvider:
        ManagedWineJournalProcessSnapshotProvider
    private let gameInputProtectionDriverFactory:
        GameInputProtectionDriverFactory
    private let gameInputProtectionPolicyStore: GameInputProtectionPolicyStore
    private let gameModeHostLaunchAdmission: GameModeHostLaunchAdmission
    private let steamClientServicePreparationOverride:
        SteamClientServicePreparer?
    private var gameLaunchDiagnosticMonitorTask: Task<Void, Never>?
    private var gameLaunchDiagnosticMonitorKey: GameLaunchDiagnosticMonitorKey?
    private var monitoredGameLaunchDiagnostic: SteamGameLaunchDiagnostic?
    private var steamLanguageUserControlMonitorTask: Task<Void, Never>?
    private var steamLanguageUserControlMonitorToken: UUID?
    private var activeInputCompatibilitySessions:
        [String: SteamInputCompatibilitySession] = [:]
    private var activeControllerCompatibilitySessions:
        [String: SteamControllerCompatibilitySession] = [:]
    private var activeNVIDIARendererSessions:
        [String: ActiveNVIDIARendererSession] = [:]
    private var activeCompatibilityRestorationPrefixLeases:
        [String: SteamCompatibilityRestorationPrefixLease] = [:]
    private var inputCompatibilityTerminationMonitors:
        [String: CompatibilityRestorationMonitor] = [:]
    private var gameInputProtectionTerminalContainmentTasks:
        [String: Task<Void, Never>] = [:]
    private var gameInputProtectionContainmentClaims =
        GameInputProtectionContainmentClaimRegistry()
    private var gameInputProtectionLifecycleEventHandler:
        GameInputProtectionLifecycleEventHandler?
    private var compatibilityRestorationClaims = Set<String>()
    private var compatibilitySessionRestorationFailures:
        [String: String] = [:]
    private var isApplicationTerminationContainmentDrainActive = false

    init(
        pathManager: PathManager,
        runner: SafeProcessRunner,
        fileManager: FileManager = .default,
        processSnapshotProvider: @escaping () -> SteamLaunchProcessSnapshot = SteamLaunchProcessSnapshot.current,
        processEvidenceTimeout: TimeInterval = SteamManager.steamProcessEvidenceTimeout,
        processEvidencePollInterval: TimeInterval = SteamManager.steamProcessEvidencePollInterval,
        renderingObservationTimeout: TimeInterval = SteamManager.steamRenderingObservationTimeout,
        renderingObservationPollInterval: TimeInterval = SteamManager.steamRenderingObservationPollInterval,
        bootstrapProgressIdleTimeout: TimeInterval = SteamManager.steamBootstrapProgressIdleTimeout,
        steamUIStartupObservationTimeout: TimeInterval = SteamManager.steamUIStartupObservationTimeout,
        steamUIStartupObservationPollInterval: TimeInterval = SteamManager.steamUIStartupObservationPollInterval,
        compatibilityPrefixExitWaiter: CompatibilityPrefixExitWaiter? = nil,
        detachedHandoffManagedWineReadbackProvider:
            DetachedHandoffManagedWineReadbackProvider? = nil,
        managedWineLaunchProcessIdentityProvider:
            ManagedWineLaunchProcessIdentityProvider? = nil,
        managedWineJournalProcessSnapshotProvider:
            ManagedWineJournalProcessSnapshotProvider? = nil,
        gameInputProtectionDriverFactory:
            GameInputProtectionDriverFactory? = nil,
        screenEvidenceProvider: ((ProcessRunResult) -> SteamLaunchScreenEvidence)? = nil,
        gameInputProtectionPolicyStore: GameInputProtectionPolicyStore =
            GameInputProtectionPolicyStore(),
        steamClientServicePreparer: SteamClientServicePreparer? = nil,
        gameModeHostLaunchAdmission: @escaping GameModeHostLaunchAdmission = {
            _ = try GameModeHostCapabilityInspector()
                .inspectBundledHostForSteamLaunchAdmission()
        }
    ) {
        self.pathManager = pathManager
        self.runner = runner
        self.fileManager = fileManager
        self.processSnapshotProvider = processSnapshotProvider
        self.processEvidenceTimeout = max(processEvidenceTimeout, 0)
        self.processEvidencePollInterval = max(processEvidencePollInterval, 0.1)
        self.renderingObservationTimeout = max(renderingObservationTimeout, 0)
        self.renderingObservationPollInterval = max(renderingObservationPollInterval, 0.1)
        self.bootstrapProgressIdleTimeout = max(bootstrapProgressIdleTimeout, 0)
        self.steamUIStartupObservationTimeout = max(steamUIStartupObservationTimeout, 0)
        self.steamUIStartupObservationPollInterval = max(steamUIStartupObservationPollInterval, 0.1)
        self.compatibilityPrefixExitWaiter =
            compatibilityPrefixExitWaiter ?? { prefix, timeout, pollInterval in
                try await runner.waitForManagedPrefixProcessesToExit(
                    prefix,
                    timeout: timeout,
                    pollInterval: pollInterval
                )
            }
        self.detachedHandoffManagedWineReadbackProvider =
            detachedHandoffManagedWineReadbackProvider ?? { prefix in
                try await runner.detachedHandoffManagedWineReadback(
                    for: prefix
                )
            }
        self.managedWineLaunchProcessIdentityProvider =
            managedWineLaunchProcessIdentityProvider ?? { prefix, runIdentifier in
                try await runner.verifiedManagedWineProcessIdentities(
                    under: prefix,
                    runIdentifier: runIdentifier
                )
            }
        self.managedWineJournalProcessSnapshotProvider =
            managedWineJournalProcessSnapshotProvider ?? { identities in
                SteamLaunchProcessSnapshot.currentManagedWineJournalProcesses(
                    identities
                )
            }
        self.gameInputProtectionDriverFactory =
            gameInputProtectionDriverFactory ?? {
                GameInputProtectionController()
            }
        self.screenEvidenceProvider = screenEvidenceProvider
        self.gameInputProtectionPolicyStore = gameInputProtectionPolicyStore
        self.steamClientServicePreparationOverride =
            steamClientServicePreparer
        self.gameModeHostLaunchAdmission = gameModeHostLaunchAdmission
        self.rendererPolicyManager = SteamRendererPolicyManager(fileManager: fileManager)
        self.windowsFontCompatibilityProfile = WindowsFontCompatibilityProfile(
            runner: runner,
            fileManager: fileManager
        )
        self.steamClientCompatibilityProfile = SteamClientCompatibilityProfile(
            runner: runner,
            fileManager: fileManager
        )
        self.steamClientLanguageOwnershipPolicy =
            SteamClientLanguageOwnershipPolicy(
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
        steamLanguageUserControlMonitorTask?.cancel()
        for monitor in inputCompatibilityTerminationMonitors.values {
            monitor.task.cancel()
        }
        for containment in gameInputProtectionTerminalContainmentTasks.values {
            containment.cancel()
        }
    }

    func setGameInputProtectionLifecycleEventHandler(
        _ handler: GameInputProtectionLifecycleEventHandler?
    ) {
        gameInputProtectionLifecycleEventHandler = handler
    }

    /// Stops admission synchronously before the termination coordinator waits
    /// on any other owner. Existing workers are cancelled but remain the owner
    /// of their claim cleanup until the bounded drain observes both registries
    /// empty.
    func beginApplicationTerminationInputContainmentDrain() {
        isApplicationTerminationContainmentDrainActive = true
        for task in gameInputProtectionTerminalContainmentTasks.values {
            task.cancel()
        }
    }

    /// A task can be inside a synchronous runner boundary when termination is
    /// requested. Do not await `task.value` without a bound: the runner and
    /// lifecycle cancellation owners make progress independently, while this
    /// method observes the authoritative task/claim postcondition.
    func waitForApplicationTerminationInputContainmentDrain(
        timeout: TimeInterval = 10
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while !gameInputProtectionTerminalContainmentTasks.isEmpty ||
                !gameInputProtectionContainmentClaims.isEmpty {
            for task in gameInputProtectionTerminalContainmentTasks.values {
                task.cancel()
            }
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return true
    }

    var canCancelApplicationTerminationContainmentDrain: Bool {
        gameInputProtectionTerminalContainmentTasks.isEmpty &&
            gameInputProtectionContainmentClaims.isEmpty
    }

    func cancelApplicationTerminationContainmentDrain() {
        guard canCancelApplicationTerminationContainmentDrain else { return }
        isApplicationTerminationContainmentDrainActive = false
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
        managedPrefix: URL,
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
        let prefixExitWaiter = compatibilityPrefixExitWaiter
        gameLaunchDiagnosticMonitorTask = Task { [weak self, reporter] in
            defer {
                if self?.gameLaunchDiagnosticMonitorKey == key {
                    self?.gameLaunchDiagnosticMonitorTask = nil
                }
            }
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
                // A missing terminal log record must not leave a service-owned
                // polling task alive after every managed Wine/Steam process
                // has gone. The process journal is the lifecycle authority;
                // diagnostics remain observational.
                if (try? await prefixExitWaiter(
                    managedPrefix,
                    0,
                    0.1
                )) == true {
                    return
                }
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
            nil
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

    func installSteam(
        runtimeExecutable: URL,
        installer: URL,
        language: SteamClientLanguage
    ) async throws -> SteamInstallResult {
        try requireSteamInstaller(installer)
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let logDirectory = try pathManager.url(for: .installLogs)
        let steamExecutable = steamExecutableURL(in: prefix)
        let executableFingerprintBefore = steamExecutableFingerprint(steamExecutable)
        // A failed installer may have created steam.exe before the transaction
        // completed. Let the ownership policy distinguish that exact pending
        // retry from an unowned installation or one where Steam has already
        // exposed a usable login/desktop surface and owns its language.
        let didClaimSteamLanguageOwnership =
            try await steamClientLanguageOwnershipPolicy
                .claimFreshInstallation(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory,
                    language: language
                ) != nil
        let processResult = try await runner.run(.installSteam(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            installer: installer,
            logDirectory: logDirectory
        ))
        let executableFingerprintAfter = steamExecutableFingerprint(steamExecutable)
        let clientServiceInspection = SteamClientServiceContract.inspect(
            prefix: prefix,
            fileManager: fileManager
        )
        let observedSteamLanguage = try steamClientLanguageOwnershipPolicy
            .observedRegistryLanguageToken(in: prefix)
        let hasVerifiedSteamLanguageProjection =
            didClaimSteamLanguageOwnership &&
            observedSteamLanguage?
                .caseInsensitiveCompare(language.rawValue) == .orderedSame
        return SteamInstallResult(
            processResult: processResult,
            steamExecutableURL: steamExecutable,
            hasSteamExecutable: executableFingerprintAfter != nil,
            hadSteamExecutableBeforeInstall: executableFingerprintBefore != nil,
            didObserveSteamExecutableMutation: executableFingerprintBefore != executableFingerprintAfter,
            requestedSteamLanguage: language,
            didClaimSteamLanguageOwnership: didClaimSteamLanguageOwnership,
            hasVerifiedSteamLanguageProjection:
                hasVerifiedSteamLanguageProjection,
            hasVerifiedSteamClientService: clientServiceInspection.isReady
        )
    }

    private func steamExecutableFingerprint(_ executable: URL) -> String? {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(executable, fileManager: fileManager),
              let data = try? Data(contentsOf: executable, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func hasVerifiedSteamClientLanguageProjection(
        runtimeExecutable: URL,
        language: SteamClientLanguage
    ) throws -> Bool {
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        guard try steamClientLanguageOwnershipPolicy
            .hasOwnershipMarker(in: prefix) else {
            return false
        }
        return try steamClientLanguageOwnershipPolicy
            .observedRegistryLanguageToken(in: prefix)?
            .caseInsensitiveCompare(language.rawValue) == .orderedSame
    }

    func prepareInstalledSteamForFirstLaunch(
        runtimeExecutable: URL,
        language: SteamClientLanguage?,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB
    ) async throws -> Bool {
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let logDirectory = try pathManager.url(for: .installLogs)
        _ = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        let languageLease: SteamClientLanguageOwnershipLease?
        if let language {
            languageLease = try await steamClientLanguageOwnershipPolicy
                .resumeFreshInstallation(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory,
                    language: language
                )
        } else {
            languageLease = nil
        }
        try await prepareSteamClientServiceForLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        try await applySteamClientCompatibilityProfile(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            videoMemorySizeMB: videoMemorySizeMB
        )
        try await restoreSteamRendererBridgeModules(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            logDirectory: logDirectory
        )
        if let languageLease {
            _ = try await steamClientLanguageOwnershipPolicy.reaffirm(
                languageLease,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        _ = try await reconcileWindowsFontCompatibilityProfile(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix
        )
        _ = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        return true
    }

    func prepareSteamClientServiceForLaunch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws {
        if let steamClientServicePreparationOverride {
            try await steamClientServicePreparationOverride(
                runtimeExecutable,
                prefix,
                logDirectory
            )
            return
        }

        let initialInspection = SteamClientServiceContract.inspect(
            prefix: prefix,
            fileManager: fileManager
        )
        guard !initialInspection.isReady else { return }

        let sourceExecutable = SteamClientServiceContract.sourceExecutable(
            in: prefix
        )
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(
            sourceExecutable,
            fileManager: fileManager
        ) else {
            throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                sourceExecutable,
                initialInspection.failureDetail
            )
        }
        let serviceControlExecutable =
            SteamClientServiceContract.serviceControlExecutable(in: prefix)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(
            serviceControlExecutable,
            fileManager: fileManager
        ) else {
            throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                serviceControlExecutable,
                "Windows service control executable is missing"
            )
        }

        let installResult = try await runner.run(.maintainSteamClientService(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            operation: .install,
            logDirectory: logDirectory
        ))
        guard installResult.succeeded else {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                installResult
            )
        }
        let queryResult = try await runner.run(.maintainSteamClientService(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            operation: .query,
            logDirectory: logDirectory
        ))
        guard queryResult.succeeded else {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                queryResult
            )
        }
        let flushResult = try await runner.run(.waitForWinePrefix(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ))
        guard flushResult.succeeded else {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(
                flushResult
            )
        }

        let finalInspection = SteamClientServiceContract.inspect(
            prefix: prefix,
            fileManager: fileManager
        )
        guard finalInspection.isReady else {
            throw SteamLaunchError.steamClientCompatibilityVerificationFailed(
                finalInspection.failureDetail
            )
        }
    }

    /// Direct-call boundary that owns the prefix lease for the entire launch
    /// transaction. Higher-level orchestrators can use the overload below to
    /// extend the same lease across their own preparation work.
    func launchSteam(
        runtimeExecutable: URL,
        verificationMode: SteamLaunchVerificationMode,
        steamClientLanguage: SteamClientLanguage? = nil,
        rendererPolicy requestedRendererPolicy: SteamRendererPolicyPreference? = nil,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        compatibilitySelection requestedCompatibilitySelection:
            SteamPrelaunchCompatibilitySelection? = nil,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB,
        steamArguments: [String]? = nil,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = []
    ) async throws -> ProcessRunResult {
        // The direct boundary checks before acquiring a prefix lease because
        // lease preparation itself creates coordination state.
        try requireGameModeHostLaunchAdmission(for: gameModePolicy)
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let prefixExecutionLease = try PrefixExecutionLease
            .acquireExclusiveMutation(
                forPrefix: prefix,
                fileManager: fileManager
            )
        let restorationLease = SteamCompatibilityRestorationPrefixLease(
            prepareForMutation: {
                try prefixExecutionLease.transitionToExclusiveMutation()
            },
            release: {
                prefixExecutionLease.release()
            }
        )
        defer {
            if !restorationLease.isTransferred {
                restorationLease.release()
            }
        }
        return try await launchSteam(
            runtimeExecutable: runtimeExecutable,
            verificationMode: verificationMode,
            steamClientLanguage: steamClientLanguage,
            rendererPolicy: requestedRendererPolicy,
            runtimeCapability: runtimeCapability,
            compatibilitySelection: requestedCompatibilitySelection,
            gameModePolicy: gameModePolicy,
            videoMemorySizeMB: videoMemorySizeMB,
            steamArguments: steamArguments,
            libraryRoots: libraryRoots,
            reservedLibraryRoots: reservedLibraryRoots,
            prefixExecutionLeaseTransition: SteamPrefixExecutionLeaseTransition(
                prepareForMutation: {
                    try prefixExecutionLease.transitionToExclusiveMutation()
                },
                prepareForExecution: {
                    try prefixExecutionLease.transitionToSharedExecution()
                },
                restorationLease: restorationLease
            )
        )
    }

    func launchSteam(
        runtimeExecutable: URL,
        verificationMode: SteamLaunchVerificationMode,
        steamClientLanguage: SteamClientLanguage? = nil,
        rendererPolicy requestedRendererPolicy: SteamRendererPolicyPreference? = nil,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        compatibilitySelection requestedCompatibilitySelection:
            SteamPrelaunchCompatibilitySelection? = nil,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB,
        steamArguments: [String]? = nil,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = [],
        prefixExecutionLeaseTransition: SteamPrefixExecutionLeaseTransition
    ) async throws -> ProcessRunResult {
        // Recheck at the lease-aware boundary. Besides covering orchestrators
        // that already own a lease, this closes the host-artifact TOCTOU window
        // before any compatibility profile or renderer staging begins.
        try requireGameModeHostLaunchAdmission(for: gameModePolicy)
        do {
            let result = try await launchSteamUnfinalized(
                runtimeExecutable: runtimeExecutable,
                verificationMode: verificationMode,
                steamClientLanguage: steamClientLanguage,
                rendererPolicy: requestedRendererPolicy,
                runtimeCapability: runtimeCapability,
                compatibilitySelection: requestedCompatibilitySelection,
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
            let underlyingError = Self.processDiagnosticUnderlyingError(
                from: error
            )
            throw ProcessExecutionEvidenceError(
                underlyingError: underlyingError,
                result: primaryResult
            )
        }
    }

    private func requireGameModeHostLaunchAdmission(
        for policy: SteamGameModeLaunchPolicy
    ) throws {
        guard policy == .experimentalRequiredHost else { return }
        try gameModeHostLaunchAdmission()
    }

    /// Runs a user-selected Windows maintenance utility in the existing
    /// SteamShared prefix. An explicitly selected renderer is validated and
    /// composed at the direct execution boundary; Steam network, audio-input,
    /// controller, compatibility-profile, and Game Mode policies remain out
    /// of scope.
    func launchWindowsUtility(
        runtimeExecutable: URL,
        prefix: URL,
        executable: URL,
        arguments: [String] = [],
        rendererPolicy requestedRendererPolicy:
            SteamRendererPolicyPreference? = nil,
        runtimeCapability suppliedRuntimeCapability:
            WindowsRuntimeCapability? = nil,
        externalStorageRoots: [URL] = []
    ) async throws -> ProcessRunResult {
        let logDirectory = try pathManager.url(for: .launchLogs)
        let resolvedRendererPolicy: SteamRendererPolicyPreference?
        let rendererReceipt: SteamRendererRouteApplicationReceipt?
        if let requestedRendererPolicy {
            guard let capability = suppliedRuntimeCapability else {
                throw SteamLaunchError.rendererPolicyUnavailable(
                    "직접 실행 과정에서 검증된 Runtime 기능 정보가 전달되지 않았습니다."
                )
            }
            let resolved = try rendererPolicyManager.resolvedPolicy(
                requestedRendererPolicy,
                capability: capability
            )
            let selection = SteamRendererPolicyManager.selection(for: resolved)
            let videoMemorySizeMB =
                SteamClientCompatibilityProfileContract
                    .recommendedVideoMemorySizeMB
            let inspection = rendererPolicyManager.inspect(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: capability,
                selection: selection,
                videoMemorySizeMB: videoMemorySizeMB
            )
            guard inspection.status == .ok else {
                throw SteamLaunchError.rendererPolicyVerificationFailed(
                    inspection.userMessage
                )
            }
            resolvedRendererPolicy = resolved
            rendererReceipt = try rendererPolicyManager.applicationReceipt(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: capability,
                selection: selection,
                videoMemorySizeMB: videoMemorySizeMB
            )
        } else {
            resolvedRendererPolicy = nil
            rendererReceipt = nil
        }
        do {
            var result = try await runner.run(.launchWindowsUtility(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                executable: executable,
                arguments: arguments,
                graphicsBackend: resolvedRendererPolicy,
                logDirectory: logDirectory,
                externalStorageRoots: externalStorageRoots
            ))
            result.rendererRouteApplicationReceipt = rendererReceipt
            return await runner.finalizeProcessEvidence(result)
        } catch {
            guard let evidenceResult = diagnosticProcessRunResult(from: error) else {
                throw error
            }
            var rendererEvidenceResult = evidenceResult
            rendererEvidenceResult.rendererRouteApplicationReceipt =
                rendererReceipt
            let finalizedResult = await runner.finalizeProcessEvidence(
                rendererEvidenceResult
            )
            let underlyingError =
                (error as? ProcessExecutionEvidenceError)?.underlyingError ??
                error
            throw ProcessExecutionEvidenceError(
                underlyingError: underlyingError,
                result: finalizedResult
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
            managedPrefix: prefix,
            in: steamDirectory,
            processObservationLog: processObservationLog,
            launchStdoutLog: result.stdoutLog,
            launchStderrLog: result.stderrLog,
            since: result.startedAt,
            persistTo: gameRunDirectory
        )
    }

    /// Keeps a fresh-install language claim pending until this launch produces
    /// a fresh, non-zero login or desktop surface and the same launch's process
    /// journal proves that WebHelper consumed the expected ICU locale.
    /// Installer, updater, process liveness, message-loop, `BrowserReady`, and
    /// registry state alone are intentionally excluded. Missing process
    /// evidence keeps the claim pending until evidence appears, prefix exit, or
    /// cancellation instead of turning observation failure into ownership.
    private func monitorSteamLanguageOwnershipUntilUserControlAvailable(
        _ lease: SteamClientLanguageOwnershipLease,
        prefix: URL,
        steamDirectory: URL,
        logCursor: SteamWebHelperStartupLogCursor,
        processObservationLog: URL?,
        result: ProcessRunResult,
        launchTarget: SteamLaunchTarget,
        initialObservation: SteamWebHelperStartupObservation? = nil
    ) {
        cancelSteamLanguageUserControlMonitor()
        let token = UUID()
        steamLanguageUserControlMonitorToken = token
        let reporter = steamLaunchDiagnosticsReporter
        let policy = steamClientLanguageOwnershipPolicy
        let prefixExitWaiter = compatibilityPrefixExitWaiter
        let fileManager = fileManager
        let pollInterval = max(steamUIStartupObservationPollInterval, 0.25)
        let provisionalSurfaceStabilizationInterval =
            Self.steamUIProvisionalSurfaceStabilizationInterval
        steamLanguageUserControlMonitorTask = Task { [weak self] in
            var didLogReadinessTransferFailure = false
            var nextPrefixExitObservation = Date()
            var nextLanguageReadbackObservation = Date.distantPast
            var consecutivePrefixExitObservations = 0
            var pendingInitialObservation = initialObservation
            var rendererStabilization =
                SteamWebHelperRendererStabilizationTracker()
            var languageReadback = SteamWebHelperLanguageReadback(
                state: .pending,
                observedLocaleIdentifiers: []
            )
            defer {
                if self?.steamLanguageUserControlMonitorToken == token {
                    self?.steamLanguageUserControlMonitorTask = nil
                    self?.steamLanguageUserControlMonitorToken = nil
                }
            }
            while !Task.isCancelled {
                var observation: SteamWebHelperStartupObservation
                if let initialObservation = pendingInitialObservation {
                    observation = initialObservation
                    pendingInitialObservation = nil
                } else {
                    observation = await Task.detached(priority: .utility) {
                        reporter.detectSteamWebHelperStartup(
                            in: steamDirectory,
                            since: logCursor
                        )
                    }.value
                }
                let now = Date()
                if now >= nextLanguageReadbackObservation {
                    let observationRead = SteamProcessCreationObservationLog.read(
                        at: processObservationLog,
                        fileManager: fileManager
                    )
                    let sameRunSnapshot = SteamLaunchProcessSnapshot(
                        processes: observationRead.processes,
                        processObservationReadState: observationRead.state,
                        processObservationReadIssues: observationRead.issues
                    )
                    languageReadback = sameRunSnapshot
                        .webHelperLanguageReadback(
                            for: launchTarget,
                            expected: lease.language
                        )
                    nextLanguageReadbackObservation =
                        now.addingTimeInterval(1)
                }
                if observation.state == .provisionalSurface {
                    let currentSnapshot = await self?
                        .verifiedCurrentLaunchProcessSnapshot(
                            result: result,
                            prefix: prefix,
                            target: launchTarget
                        )
                    let processBoundObservation = currentSnapshot.flatMap {
                        Self.processBoundRendererObservation(
                            observation,
                            snapshot: $0,
                            launchTarget: launchTarget
                        )
                    }
                    if let processBoundObservation,
                       rendererStabilization.observePositiveRenderer(
                            in: processBoundObservation,
                            at: now,
                            requiredInterval:
                                provisionalSurfaceStabilizationInterval
                       ) {
                        observation.state = .ready
                        observation.usableUIReadiness =
                            observation.provisionalSurfaceReadiness
                    } else if processBoundObservation == nil {
                        rendererStabilization.reset()
                    }
                } else if observation.state != .ready {
                    rendererStabilization.reset()
                }
                if let readiness = SteamClientLanguageUserControlReadiness(
                    observation: observation,
                    language: lease.language,
                    webHelperLanguageReadback: languageReadback
                ) {
                    do {
                        try policy.markSteamUserControlAvailable(
                            lease,
                            readiness: readiness,
                            in: prefix
                        )
                        return
                    } catch {
                        if !didLogReadinessTransferFailure {
                            NSLog(
                                "ForgePlay could not transfer Steam language ownership after verified Steam UI readiness: %@",
                                forgePlayTechnicalErrorSummary(error)
                            )
                            didLogReadinessTransferFailure = true
                        }
                    }
                }
                do {
                    if Date() >= nextPrefixExitObservation {
                        if try await prefixExitWaiter(prefix, 0, 0.1) {
                            consecutivePrefixExitObservations += 1
                            if consecutivePrefixExitObservations >= 2 {
                                return
                            }
                        } else {
                            consecutivePrefixExitObservations = 0
                        }
                        nextPrefixExitObservation = Date().addingTimeInterval(1)
                    }
                    try await Task.sleep(for: .seconds(pollInterval))
                } catch {
                    return
                }
            }
        }
    }

    private func cancelSteamLanguageUserControlMonitor() {
        steamLanguageUserControlMonitorTask?.cancel()
        steamLanguageUserControlMonitorTask = nil
        steamLanguageUserControlMonitorToken = nil
    }

    private func launchSteamUnfinalized(
        runtimeExecutable: URL,
        verificationMode: SteamLaunchVerificationMode,
        steamClientLanguage: SteamClientLanguage? = nil,
        rendererPolicy requestedRendererPolicy: SteamRendererPolicyPreference? = nil,
        runtimeCapability suppliedRuntimeCapability: WindowsRuntimeCapability? = nil,
        compatibilitySelection requestedCompatibilitySelection:
            SteamPrelaunchCompatibilitySelection? = nil,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB,
        steamArguments: [String]? = nil,
        libraryRoots: [URL] = [],
        reservedLibraryRoots: [URL] = [],
        prefixExecutionLeaseTransition: SteamPrefixExecutionLeaseTransition
    ) async throws -> ProcessRunResult {
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let prefixKey = prefix.standardizedFileURL.path
        try await GameInputProtectionContainmentAdmissionWaiter.wait(
            whileActive: { [weak self] in
                self?.gameInputProtectionContainmentClaims.hasClaim(
                    prefixKey: prefixKey
                ) == true
            }
        )
        let logDirectory = try pathManager.url(for: .launchLogs)
        let capability = suppliedRuntimeCapability ??
            WindowsRuntimeService.inspectRuntimeCapability(
                for: runtimeExecutable,
                supplementalRendererRoot: ForgePlaySupplementalRendererPolicy
                    .rendererRoot(containingPrefix: prefix),
                fileManager: fileManager
            )
        let steamCompatibility = steamClientCompatibilityVerifier.verify(capability: capability)
        let steamRendererPolicy = try rendererPolicyManager.resolvedPolicy(
            requestedRendererPolicy,
            capability: capability
        )
        let launchCompatibilitySelection =
            requestedCompatibilitySelection ??
            SteamPrelaunchCompatibilitySelection(
                rendererSelection: SteamRendererPolicyManager.selection(
                    for: steamRendererPolicy
                ),
                networkSelection: .standard,
                audioInputSelection: .enabled,
                keyboardMapping: .systemDefault
            )
        guard launchCompatibilitySelection.rendererPreference ==
                steamRendererPolicy else {
            throw SteamLaunchError.rendererPolicyUnavailable(
                "선택한 그래픽 백엔드와 Steam 실행 호환성 설정이 일치하지 않습니다."
            )
        }
        let rendererSelection =
            launchCompatibilitySelection.rendererSelection
        // Admission precedes process snapshots and the conformance preflight,
        // which may execute an isolated Wine smoke prefix. Unsupported input
        // requests therefore cannot cause even temporary preflight effects.
        let inputCompatibilitySession = try SteamInputCompatibilitySession(
            cursorPolicy: launchCompatibilitySelection.fpsCursorPolicy,
            keyboardMapping: launchCompatibilitySelection.keyboardMapping,
            gameInputProtectionPolicy:
                gameInputProtectionPolicyStore.snapshot(),
            gameInputProtection: gameInputProtectionDriverFactory(),
            terminalFailureHandler: { [weak self] session, failure in
                self?.scheduleGameInputProtectionTerminalContainment(
                    session: session,
                    failure: failure,
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
            }
        )
        let controllerCompatibilitySession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtimeExecutable,
            policy: launchCompatibilitySelection.controllerPolicy,
            fileManager: fileManager
        )
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
        let initialRendererInspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: capability,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        let hasRecoverableNVIDIAMetalFXResidue =
            rendererPolicyManager
                .isRecoverableNVIDIAMetalFXSessionResidue(
                    initialRendererInspection,
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable
                )
        guard initialRendererInspection.status == .ok ||
                initialRendererInspection.requiresApply ||
                hasRecoverableNVIDIAMetalFXResidue else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(initialRendererInspection.userMessage)
        }
        let runnerVersionEvidence = await captureWineVersionEvidence(for: expectedLaunchRunner)
        var preflightShutdown = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        try prefixExecutionLeaseTransition.prepareForMutation()
        preflightShutdown.diagnosticCaptureWarning = DiagnosticWarningText.combined(
            preflightShutdown.diagnosticCaptureWarning,
            await rotateOfflineSteamClientLogsIfNeeded(prefix: prefix)
        )
        try await reconcileCompatibilitySessionsAfterSuccessfulShutdown(
            prefix: prefix
        )
        cancelSteamLanguageUserControlMonitor()
        let steamLanguageOwnershipLease = try await
            steamClientLanguageOwnershipPolicy.prepareForLaunch(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory,
                desiredLanguage: steamClientLanguage
            )
        try await prepareSteamClientServiceForLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        try await applySteamClientCompatibilityProfile(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            videoMemorySizeMB: videoMemorySizeMB
        )
        try await rendererPolicyManager
            .restoreNVIDIAMetalFXRegistrySessionIfNeeded(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runner: runner,
                logDirectory: logDirectory,
                phase: .priorSessionRestoration
            )
        // Wine registry tools can resynchronize System32. Re-inspect after
        // every registry mutation, then normalize only the exact three files
        // owned by a prior NVIDIA MetalFX session. Unrelated renderer
        // contamination remains blocked by the final inspection.
        let postRegistryRendererInspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: capability,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        if rendererPolicyManager
            .isRecoverableNVIDIAMetalFXSessionResidue(
                postRegistryRendererInspection,
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            ) {
            try rendererPolicyManager
                .restoreNVIDIAMetalFXSessionModules(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable
                )
        }
        let rendererInspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: capability,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        guard rendererInspection.status == .ok else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(rendererInspection.userMessage)
        }
        var rendererSessionStaged = false
        if rendererSelection.usesD3DMetalNVIDIACompatibility {
            do {
                try await rendererPolicyManager
                    .stageNVIDIAMetalFXRegistrySession(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable,
                        runner: runner,
                        logDirectory: logDirectory
                    )
                _ = try rendererPolicyManager
                    .stageNVIDIAMetalFXBridgeModules(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable
                    )
                rendererSessionStaged = true
            } catch let stageError {
                let registryRollbackError: Error?
                do {
                    try await rendererPolicyManager
                        .restoreNVIDIAMetalFXRegistrySessionIfNeeded(
                            prefix: prefix,
                            runtimeExecutable: runtimeExecutable,
                            runner: runner,
                            logDirectory: logDirectory,
                            phase: .preparationRollback
                        )
                    registryRollbackError = nil
                } catch {
                    registryRollbackError = error
                }
                let preservationSource: Error
                let fallbackPhase: SteamRendererLifecyclePhase
                let fallbackOperation: SteamRendererLifecycleOperation
                let fallbackDetail: String?
                let additionalDetail: String?
                if let registryRollbackError {
                    preservationSource = registryRollbackError
                    fallbackPhase = .preparationRollback
                    fallbackOperation = .sessionRestoration
                    fallbackDetail =
                        "NGXCore registry rollback failed: " +
                        forgePlayTechnicalErrorSummary(registryRollbackError)
                    additionalDetail =
                        "renderer preparation failed before rollback: " +
                        forgePlayTechnicalErrorSummary(stageError)
                } else {
                    preservationSource = stageError
                    fallbackPhase = .preparation
                    fallbackOperation = .ngxCoreFullPathRegistration
                    fallbackDetail = nil
                    additionalDetail = nil
                }
                let lifecycleFailure = Self
                    .rendererLifecycleFailurePreservingStructuredError(
                        preservationSource,
                        fallbackPhase: fallbackPhase,
                        fallbackOperation: fallbackOperation,
                        fallbackTarget: prefix,
                        fallbackDetail: fallbackDetail,
                        additionalDetail: additionalDetail,
                        additionalProcessResults:
                            diagnosticProcessRunResults(from: stageError) +
                            (registryRollbackError.map {
                                diagnosticProcessRunResults(from: $0)
                            } ?? [])
                    )
                throw SteamLaunchError.rendererLifecycleFailed(
                    lifecycleFailure
                )
            }
        }
        let postDispatchRollbackOwnership =
            GameInputProtectionPostDispatchRollbackOwnership(
                requiresRendererRollback: rendererSessionStaged
            )
        var launchResultForRestorationRecovery: ProcessRunResult?
        do {
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
            pendingMappings: libraryDrivePreparation.pendingMappings,
            discoveries: libraryDrivePreparation.discoveries,
            logDirectory: logDirectory
        )
        if let steamLanguageOwnershipLease {
            _ = try await steamClientLanguageOwnershipPolicy.reaffirm(
                steamLanguageOwnershipLease,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        let fontProvisioningReceipt = try await
            reconcileWindowsFontCompatibilityProfile(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix
            )
        let finalRendererInspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: capability,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        let finalRendererSessionIsExact = rendererSessionStaged &&
            rendererPolicyManager.isRecoverableNVIDIAMetalFXSessionResidue(
                finalRendererInspection,
                prefix: prefix,
                runtimeExecutable: runtimeExecutable
            )
        guard finalRendererInspection.status == .ok ||
                finalRendererSessionIsExact else {
            throw SteamLaunchError.rendererPolicyVerificationFailed(
                finalRendererInspection.userMessage
            )
        }
        let launchExternalStorageRoots = libraryDrivePreparation.externalStorageRoots
        let resolvedSteamArguments =
            SteamClientLanguageOwnershipPolicy.launchArguments(
                baseArguments: steamArguments ??
                    SteamClientCompatibilityProfile.defaultLaunchArguments,
                lease: steamLanguageOwnershipLease
            )
        let rendererRouteReceipt = try rendererPolicyManager.applicationReceipt(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: capability,
            selection: rendererSelection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        var compatibilitySessionsCommitted = false
        defer {
            if !compatibilitySessionsCommitted &&
                !postDispatchRollbackOwnership
                    .localInputAndControllerRollbackCompleted {
                let prefixKey = prefix.standardizedFileURL.path
                GameInputProtectionPrecommitRestorationHandoff
                    .restoreOrInstallRetryOwner(
                        restore: { inputCompatibilitySession.restore() },
                        retain: {
                            activeInputCompatibilitySessions[prefixKey] =
                                inputCompatibilitySession
                        },
                        startMonitor: {
                            startInputOnlyCompatibilityRestorationMonitor(
                                prefix: prefix,
                                prefixKey: prefixKey
                            )
                        }
                    )
                controllerCompatibilitySession.restore()
            }
        }
        // Start host input interception only after every prefix/service/
        // renderer preparation step has succeeded. Pre-dispatch preparation
        // failures must not leave an input session active, and failures after
        // this point are covered by the restoration defer above.
        try inputCompatibilitySession.captureBeforeLaunch()
        let processSnapshotBeforeLaunch = processSnapshotProvider()
        let hostSteamProcessesBeforeLaunch =
            processSnapshotBeforeLaunch.hostMacOSSteamProcesses
        let externalRunnerProcessesBeforeLaunch =
            processSnapshotBeforeLaunch.externalApplicationRunnerProcesses
        let dumpsBeforeLaunchScan = steamLaunchDiagnosticsReporter.recentSteamCrashDumpScan(
            in: dumpsDirectory,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        let dumpsBeforeLaunch = dumpsBeforeLaunchScan.urls
        let dumpFingerprintsBeforeLaunch = dumpsBeforeLaunchScan.fingerprints
        let priorLaunchAttempts: [SteamLaunchAttemptEvidence] = []
        let steamUIStartupLogCursor = steamLaunchDiagnosticsReporter
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        try await awaitGameInputProtectionDispatchAdmission(
            prefixKey: prefixKey,
            site: .initial
        )
        try prefixExecutionLeaseTransition.prepareForExecution()
        try controllerCompatibilitySession.revalidateBeforeSpawn()
        try inputCompatibilitySession.requireNoTerminalFailure()
        var result = try await runManagedSteamLaunchDispatch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ) {
            try await runner.run(.launchSteam(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                steamExecutable: steamExecutable,
                steamArguments: resolvedSteamArguments,
                graphicsBackend: steamRendererPolicy,
                compatibilitySelection: launchCompatibilitySelection,
                gameModePolicy: gameModePolicy,
                logDirectory: logDirectory,
                externalStorageRoots: launchExternalStorageRoots
            ))
        }
        defer { launchResultForRestorationRecovery = result }
        let steamBootstrapUpdaterEvidenceSession =
            SteamBootstrapUpdaterEvidenceSession(
                cursor: bootstrapUpdateSourceCursor(
                    from: steamUIStartupLogCursor
                )
            )
        if result.succeeded,
           SteamLaunchDispatchDisposition.resolve(result)
            .acceptsSessionLifetime {
            try await attachProviderApplicationReceipts(
                to: &result,
                inputSession: inputCompatibilitySession,
                controllerSession: controllerCompatibilitySession,
                fontReceipt: fontProvisioningReceipt,
                rendererReceipt: rendererRouteReceipt,
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                logDirectory: logDirectory,
                expectedCompatibilitySelection: launchCompatibilitySelection
            )
        }
        let steamUIStartupObservation = await observeSteamUIStartup(
            result: result,
            prefix: prefix,
            steamDirectory: steamDirectory,
            launchTarget: launchTarget,
            logCursor: steamUIStartupLogCursor
        )
        // The accepted Steam dispatch owns a live user session. Cancellation
        // of the view/task that requested startup observation must not unwind
        // into renderer rollback, which first terminates the entire Prefix.
        let steamUIStartupFailureReason =
            verificationMode == .conformance &&
            steamUIStartupObservation.state != .ready
            ? (steamUIStartupObservation.reason ??
                "Steam WebHelper did not expose a usable login or desktop surface before the startup observation ended")
            : nil
        let launchLogCutoff = result.startedAt.addingTimeInterval(-2)
        let immediateProcessSnapshot: SteamLaunchProcessSnapshot
        if verificationMode == .conformance {
            immediateProcessSnapshot = await currentSteamLaunchProcessSnapshot(
                result: result,
                prefix: prefix,
                target: launchTarget
            )
        } else {
            immediateProcessSnapshot = await verifiedCurrentLaunchProcessSnapshot(
                result: result,
                prefix: prefix,
                target: launchTarget
            )
        }
        let initialBootstrapLogAssessment = steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: steamBootstrapUpdaterEvidenceSession.tracker.cursor
        )
        let initialBootstrapLifecycle =
            steamBootstrapUpdaterEvidenceSession.tracker.observe(
                assessment: initialBootstrapLogAssessment,
                at: Date(),
                idleTimeout: bootstrapProgressIdleTimeout
            )
        let initialBootstrapUpdateInProgress =
            initialBootstrapLifecycle.state == .inProgress &&
            initialBootstrapLifecycle.continuity == .recentOrAdvancing
        let observedProcessSnapshot: SteamLaunchProcessSnapshot
        if result.succeeded,
           SteamLaunchDispatchDisposition.resolve(result)
                .acceptsSessionLifetime,
           !initialBootstrapUpdateInProgress {
            observedProcessSnapshot = await waitForSteamLaunchProcessEvidence(
                for: launchTarget,
                initialSnapshot: immediateProcessSnapshot,
                result: result,
                verificationMode: verificationMode
            )
        } else if result.succeeded,
                  SteamLaunchDispatchDisposition.resolve(result)
                    .acceptsSessionLifetime,
                  initialBootstrapUpdateInProgress {
            observedProcessSnapshot = immediateProcessSnapshot
        } else {
            observedProcessSnapshot = immediateProcessSnapshot
        }
        let finalBootstrapLogAssessment = steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: steamBootstrapUpdaterEvidenceSession.tracker.cursor
        )
        let finalBootstrapLifecycle =
            steamBootstrapUpdaterEvidenceSession.tracker.observe(
                assessment: finalBootstrapLogAssessment,
                at: Date(),
                idleTimeout: bootstrapProgressIdleTimeout
            )
        let bootstrapUpdateInProgressBeforeRenderingObservation =
            finalBootstrapLifecycle.state == .inProgress &&
            finalBootstrapLifecycle.continuity == .recentOrAdvancing
        let renderingIssue: SteamWebHelperRenderingIssue?
        if verificationMode == .conformance,
           result.succeeded,
           SteamLaunchDispatchDisposition.resolve(result)
                .acceptsSessionLifetime,
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
        let liveBootstrapProcessSnapshot =
            await verifiedCurrentLaunchProcessSnapshot(
                result: result,
                prefix: prefix,
                target: launchTarget
            )
        let bootstrapUpdateInProgress = steamBootstrapUpdateIsInProgress(
            result: result,
            launchTarget: launchTarget,
            processSnapshot: liveBootstrapProcessSnapshot,
            renderingIssue: renderingIssue,
            fatalCrashDumps: fatalCrashDumps,
            hasBootstrapUpdateProgress: bootstrapUpdateInProgressBeforeRenderingObservation
        )
        let operationalProcessVerificationUnavailable =
            verificationMode == .operational &&
            hardGateAssessment.status == .deferred &&
            hardGateAssessment.reasonCodes.contains(
                .operationalProcessEvidenceUnavailable
            )
        let hasTerminalSteamUIFailure =
            !launchCommandSucceeded ||
            steamUIStartupFailureReason != nil ||
            !fatalCrashDumps.isEmpty ||
            renderingIssue != nil
        let shouldDeferSteamUIVerification = Self.shouldDeferSteamUIVerification(
            bootstrapUpdateInProgress: bootstrapUpdateInProgress,
            operationalProcessVerificationUnavailable:
                operationalProcessVerificationUnavailable,
            didObserveExternalRunnerDuringConformance:
                didObserveExternalRunnerDuringConformance,
            hasTerminalSteamUIFailure: hasTerminalSteamUIFailure
        )
        let effectiveHardGateAssessment = bootstrapUpdateInProgress
            ? steamBootstrapUpdateDeferredAssessment(from: hardGateAssessment)
            : hardGateAssessment
        let acceptedGateStatus: SteamLaunchGateStatus = verificationMode == .conformance ? .success : .launched
        let launchAssessmentAccepted = effectiveHardGateAssessment.status == acceptedGateStatus
        if shouldDeferSteamUIVerification {
            result.forgePlayStatusCode = bootstrapUpdateInProgress
                ? Self.steamBootstrapUpdateInProgressExitCode
                : Self.steamLaunchProcessVerificationUnavailableExitCode
        }
        // Once the user's Steam session has been dispatched, operational
        // diagnostics never acquire authority to terminate it. Cleanup after
        // dispatch is limited to a failed dispatch or an explicit conformance
        // run whose assessment reached a failed state.
        let shouldStopSteamAfterLaunch =
            !launchCommandSucceeded ||
            (verificationMode == .conformance &&
                (hasTerminalSteamUIFailure ||
                    hardGateAssessment.status == .failed))
        var didRequestFailureShutdown = false
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
                } else if renderingIssue != nil {
                    result.forgePlayStatusCode = Self.steamRenderingFailureExitCode
                } else if steamUIStartupFailureReason != nil {
                    result.forgePlayStatusCode = Self.steamUIStartupFailureExitCode
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
            didRequestFailureShutdown = true
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
                didRequestFailureShutdown = true
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
        if result.forgePlayStatusCode == Self.steamBootstrapUpdateInProgressExitCode ||
            result.forgePlayStatusCode == Self.steamLaunchProcessVerificationUnavailableExitCode {
            result.steamUIVerificationState = .launchedButUnverified
        } else if result.succeeded {
            result.steamUIVerificationState = verificationMode == .conformance ? .rendered : .launchedButUnverified
        } else if result.forgePlayStatusCode == Self.steamRenderingFailureExitCode {
            result.steamUIVerificationState = .blackScreenSuspected
        } else {
            result.steamUIVerificationState = .failed
        }
        result.steamUISurface = screenEvidence.surface
        let providerReceiptsVerified =
            result.inputCompatibilityReceipt?
                .isLifecycleAdmissionVerified == true &&
            result.controllerCompatibilityReceipt?
                .isStaticPreparationVerified == true
        let detachedHandoffAccepted =
            SteamLaunchDispatchDisposition.resolve(result)
                .isSuccessfulDetachedHelperHandoff
        if (providerReceiptsVerified || detachedHandoffAccepted),
           launchCommandSucceeded,
           !shouldStopSteamAfterLaunch,
           !didRequestFailureShutdown {
            try await commitCompatibilitySessionsAfterLaunch(
                inputCompatibilitySession,
                controllerSession: controllerCompatibilitySession,
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                logDirectory: logDirectory,
                restorationLease:
                    prefixExecutionLeaseTransition.restorationLease,
                rendererSession: rendererSessionStaged
                    ? ActiveNVIDIARendererSession(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable,
                        logDirectory: logDirectory
                    )
                    : nil,
                admission: providerReceiptsVerified
                    ? .providerReceiptsVerified
                    : .successfulDetachedHandoff(
                        rendererPreparationVerified:
                            rendererRouteReceipt.isPreparationVerified
                    ),
                result: &result,
                fontReceipt: fontProvisioningReceipt,
                rendererReceipt: rendererRouteReceipt,
                prepareForMutation:
                    prefixExecutionLeaseTransition.prepareForMutation,
                rollbackOwnership: postDispatchRollbackOwnership
            )
            compatibilitySessionsCommitted = true
            rendererSessionStaged = false
        }
        if rendererSessionStaged,
           launchCommandSucceeded,
           !shouldStopSteamAfterLaunch,
           !didRequestFailureShutdown {
            let admissionFailure =
                SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "renderer-session-lifetime-admission-unavailable"
                )
            try await containForegroundPostDispatchCommitFailure(
                admissionFailure,
                initialTerminalResolution: nil,
                inputSession: inputCompatibilitySession,
                controllerSession: controllerCompatibilitySession,
                rendererSession: ActiveNVIDIARendererSession(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    logDirectory: logDirectory
                ),
                rollbackOwnership: postDispatchRollbackOwnership,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory,
                prepareForMutation:
                    prefixExecutionLeaseTransition.prepareForMutation
            )
        }
        if rendererSessionStaged {
            try await requireManagedPrefixInactivityBeforeRendererRestoration(
                prefix
            )
            try prefixExecutionLeaseTransition.prepareForMutation()
            try await restoreNVIDIARendererSession(
                ActiveNVIDIARendererSession(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    logDirectory: logDirectory
                )
            )
            rendererSessionStaged = false
        }
        if let steamLanguageOwnershipLease,
           launchCommandSucceeded,
           !shouldStopSteamAfterLaunch,
           !didRequestFailureShutdown {
            // Language ownership crosses the same typed usable-UI boundary as
            // launch readiness. Registry readback races remain pending and
            // retryable instead of failing an otherwise successful launch.
            monitorSteamLanguageOwnershipUntilUserControlAvailable(
                steamLanguageOwnershipLease,
                prefix: prefix,
                steamDirectory: steamDirectory,
                logCursor: steamUIStartupLogCursor,
                processObservationLog: result.processObservationLog,
                result: result,
                launchTarget: launchTarget,
                initialObservation: steamUIStartupObservation
            )
        }
        return result
        } catch let launchError {
            if postDispatchRollbackOwnership.rendererRollbackCompleted {
                throw launchError
            }
            guard rendererSessionStaged else { throw launchError }
            var rendererRecoveryShutdownResult: ProcessRunResult?
            do {
                rendererRecoveryShutdownResult =
                    try await shutdownAndRequireManagedPrefixInactivityForRendererRestoration(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        logDirectory: logDirectory
                    )
                try prefixExecutionLeaseTransition.prepareForMutation()
                try await restoreNVIDIARendererSession(
                    ActiveNVIDIARendererSession(
                        prefix: prefix,
                        runtimeExecutable: runtimeExecutable,
                        logDirectory: logDirectory
                    )
                )
                rendererSessionStaged = false
            } catch let rollbackError {
                let processResults = (
                    diagnosticProcessRunResults(from: launchError) +
                    [rendererRecoveryShutdownResult].compactMap { $0 } +
                    diagnosticProcessRunResults(from: rollbackError)
                ).reduce(into: [ProcessRunResult]()) {
                    if !$0.contains($1) { $0.append($1) }
                }
                let lifecycleFailure = Self
                    .rendererLifecycleFailurePreservingStructuredError(
                        rollbackError,
                        fallbackPhase: .postLaunchRestoration,
                        fallbackOperation: .sessionRestoration,
                        fallbackTarget: prefix,
                        fallbackDetail:
                            "renderer rollback failed: " +
                            forgePlayTechnicalErrorSummary(rollbackError),
                        additionalDetail:
                            "launch or initial renderer restoration failed: " +
                            forgePlayTechnicalErrorSummary(launchError),
                        additionalProcessResults: processResults
                    )
                throw SteamLaunchError.rendererLifecycleFailed(
                    lifecycleFailure
                )
            }
            if let steamLaunchError = launchError as? SteamLaunchError,
               case .rendererLifecycleFailed(let failure) = steamLaunchError,
               failure.phase == .postLaunchRestoration,
               var recoveredResult = launchResultForRestorationRecovery {
                Self.attachLaunchChainEvidence(
                    [],
                    auxiliaryResults: failure.processResults +
                        [rendererRecoveryShutdownResult].compactMap { $0 },
                    to: &recoveredResult
                )
                recoveredResult.diagnosticCaptureWarning =
                    DiagnosticWarningText.combined(
                        recoveredResult.diagnosticCaptureWarning,
                        "The first renderer restoration attempt failed, but " +
                            "a bounded retry restored the session: " +
                            failure.detail
                    )
                return recoveredResult
            }
            throw launchError
        }
    }

    private func awaitGameInputProtectionDispatchAdmission(
        prefixKey: String,
        site: GameInputProtectionDispatchAdmissionSite
    ) async throws {
        _ = site
        try await GameInputProtectionContainmentAdmissionWaiter.wait(
            whileActive: { [weak self] in
                self?.gameInputProtectionContainmentClaims.hasClaim(
                    prefixKey: prefixKey
                ) == true
            }
        )
    }

    /// Once dispatch begins, a thrown runner error is not proof that no child
    /// was created. Always stop and observe the managed prefix before allowing
    /// the error to escape, preserving both launch and cleanup evidence.
    private func runManagedSteamLaunchDispatch(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        operation: () async throws -> ProcessRunResult
    ) async throws -> ProcessRunResult {
        do {
            return try await operation()
        } catch let dispatchError {
            let cleanup = await prefixProcessSupervisor.shutdownAfterFailure(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            var cleanupFailure = cleanup.error
            if cleanupFailure == nil {
                if let cleanupResult = cleanup.result {
                    if !cleanupResult.succeeded {
                        cleanupFailure = SteamLaunchError.prefixShutdownFailed(
                            cleanupResult
                        )
                    }
                } else {
                    cleanupFailure = SteamCompatibilityLaunchProfileErrorV1
                        .invalidReceipt("post-dispatch-shutdown-missing-result")
                }
            }
            if cleanupFailure == nil {
                do {
                    guard try await compatibilityPrefixExitWaiter(
                        prefix,
                        30,
                        0.2
                    ) else {
                        throw SteamCompatibilityLaunchProfileErrorV1
                            .invalidReceipt(
                                "post-dispatch-failure-prefix-still-active"
                            )
                    }
                } catch {
                    cleanupFailure = error
                }
            }

            let dispatchEvidence = diagnosticProcessRunResults(
                from: dispatchError
            )
            let cleanupEvidence = Array(dispatchEvidence.dropFirst()) +
                [cleanup.result].compactMap { $0 }
            throw SteamPrefixLifecycleCleanupError(
                originalDescription:
                    forgePlayTechnicalErrorSummary(dispatchError),
                cleanupDescription: cleanupFailure.map {
                    forgePlayTechnicalErrorSummary($0)
                } ?? "managed prefix shutdown and inactivity verified",
                originalError: dispatchError,
                cleanupError: cleanupFailure,
                originalProcessResult: dispatchEvidence.first,
                cleanupProcessResults: cleanupEvidence
            )
        }
    }

    private func attachProviderApplicationReceipts(
        to result: inout ProcessRunResult,
        inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        fontReceipt: WindowsFontProvisioningApplicationReceipt,
        rendererReceipt: SteamRendererRouteApplicationReceipt,
        prefix: URL,
        runtimeExecutable: URL,
        logDirectory: URL,
        expectedCompatibilitySelection: SteamPrelaunchCompatibilitySelection
    ) async throws {
        do {
            try await populateProviderApplicationReceipts(
                to: &result,
                inputSession: inputSession,
                controllerSession: controllerSession,
                fontReceipt: fontReceipt,
                rendererReceipt: rendererReceipt,
                prefix: prefix,
                expectedCompatibilitySelection: expectedCompatibilitySelection
            )
        } catch let receiptError {
            // Receipt construction occurs after the detached launcher exists.
            // A failed readback must therefore shut down the prefix before the
            // error is allowed to escape; otherwise a failed launch can leave
            // an unmanaged Steam process running.
            let cleanup = await prefixProcessSupervisor.shutdownAfterFailure(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            if let cleanupError = cleanup.error {
                throw SteamPrefixLifecycleCleanupError(
                    originalDescription:
                        forgePlayTechnicalErrorSummary(receiptError),
                    cleanupDescription:
                        forgePlayTechnicalErrorSummary(cleanupError),
                    originalError: receiptError,
                    cleanupError: cleanupError,
                    cleanupProcessResults: cleanup.result.map { [$0] } ?? []
                )
            }
            guard let cleanupResult = cleanup.result,
                  cleanupResult.succeeded else {
                let cleanupError = cleanup.result.map {
                    SteamLaunchError.prefixShutdownFailed($0)
                }
                throw SteamPrefixLifecycleCleanupError(
                    originalDescription:
                        forgePlayTechnicalErrorSummary(receiptError),
                    cleanupDescription: cleanupError.map {
                        forgePlayTechnicalErrorSummary($0)
                    } ?? "prefix shutdown returned no result",
                    originalError: receiptError,
                    cleanupError: cleanupError,
                    cleanupProcessResults: cleanup.result.map { [$0] } ?? []
                )
            }
            do {
                guard try await compatibilityPrefixExitWaiter(
                    prefix,
                    30,
                    0.2
                ) else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "post-receipt-failure-prefix-still-active"
                    )
                }
            } catch let cleanupVerificationError {
                throw SteamPrefixLifecycleCleanupError(
                    originalDescription:
                        forgePlayTechnicalErrorSummary(receiptError),
                    cleanupDescription:
                        forgePlayTechnicalErrorSummary(cleanupVerificationError),
                    originalError: receiptError,
                    cleanupError: cleanupVerificationError,
                    cleanupProcessResults: [cleanupResult]
                )
            }
            throw receiptError
        }
    }

    private func populateProviderApplicationReceipts(
        to result: inout ProcessRunResult,
        inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        fontReceipt: WindowsFontProvisioningApplicationReceipt,
        rendererReceipt: SteamRendererRouteApplicationReceipt,
        prefix: URL,
        expectedCompatibilitySelection: SteamPrelaunchCompatibilitySelection
    ) async throws {
        let currentFontReadback =
            WindowsFontCompatibilityProfileContract.inspect(
                prefix: prefix,
                fileManager: fileManager,
                requiresProfileMarker: true
            )
        let disposition = SteamLaunchDispatchDisposition.resolve(result)
        let processIdentifier: pid_t
        switch disposition {
        case .runningDetachedProcess:
            guard let launchedProcessIdentifier = result.processIdentifier,
                  launchedProcessIdentifier > 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "launch-provider-boundary-readback"
                )
            }
            processIdentifier = launchedProcessIdentifier
        case .successfulForgePlayLauncherHandoff:
            guard let detachedReadback = try await
                    detachedHandoffManagedWineReadbackProvider(prefix),
                  detachedReadback.processIdentifier > 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "detached-helper-managed-wine-readback"
                )
            }
            result.managedWineChildSynchronizationReadback = detachedReadback
            processIdentifier = detachedReadback.processIdentifier
        case .completedOrFailed:
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "launch-provider-boundary-readback"
            )
        }
        guard result.succeeded,
              let childSynchronizationReadback =
                result.managedWineChildSynchronizationReadback,
              childSynchronizationReadback.processIdentifier ==
                processIdentifier,
              childSynchronizationReadback.selection == .automatic,
              childSynchronizationReadback.backend == .server,
              let environmentProjection =
                result.managedWineLaunchEnvironmentProjection,
              environmentProjection.rendererSelection ==
                expectedCompatibilitySelection.rendererSelection.rawValue,
              environmentProjection.networkSelection ==
                expectedCompatibilitySelection.networkSelection.rawValue,
              environmentProjection.audioInputSelection ==
                expectedCompatibilitySelection.audioInputSelection.rawValue,
              fontReceipt.isAppliedAndReadBack,
              currentFontReadback.isSatisfied,
              rendererReceipt.isPreparationVerified else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "launch-provider-boundary-readback"
            )
        }
        try inputSession.bindManagedWineTransport(
            processIdentifier: processIdentifier
        )
        try controllerSession.bindManagedWineTransport(
            processIdentifier: processIdentifier
        )
        let inputReceipt = try inputSession.applicationReceipt()
        let controllerReceipt = try controllerSession.applicationReceipt()
        guard inputReceipt.isLifecycleAdmissionVerified,
              controllerReceipt.isStaticPreparationVerified else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "input-provider-readback"
            )
        }
        result.inputCompatibilityReceipt = inputReceipt
        result.controllerCompatibilityReceipt = controllerReceipt
        result.windowsFontProvisioningReceipt = fontReceipt
        result.rendererRouteApplicationReceipt = rendererReceipt
    }

    private func commitCompatibilitySessions(
        _ inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        prefix: URL,
        restorationLease: SteamCompatibilityRestorationPrefixLease?,
        rendererSession: ActiveNVIDIARendererSession?,
        admission: SteamCompatibilitySessionCommitAdmission
    ) async throws {
        let key = prefix.standardizedFileURL.path
        try inputSession.requireNoTerminalFailure()
        let inputRequiresRetention: Bool
        let controllerRequiresRetention: Bool
        switch admission {
        case .providerReceiptsVerified:
            inputRequiresRetention = inputSession.requiresLifecycleRetention
            controllerRequiresRetention =
                controllerSession.requiresLifecycleRetention
        case .successfulDetachedHandoff(
            let rendererPreparationVerified
        ):
            guard rendererPreparationVerified else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "detached-handoff-renderer-preparation"
                )
            }
            guard !inputSession
                    .requiresFailClosedManagedTransportBinding,
                  inputSession.permitsDetachedHandoffDegradation,
                  !controllerSession.requiresLifecycleRetention else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "detached-helper-input-binding-unavailable"
                )
            }
            inputRequiresRetention = false
            controllerRequiresRetention = false
        }
        let requiresPrefixMutationRestoration =
            controllerRequiresRetention ||
            rendererSession != nil
        let restorationPlan = GameInputProtectionRestorationPlan.resolve(
            inputRequiresRetention: inputRequiresRetention,
            prefixMutationRequiresRetention:
                requiresPrefixMutationRestoration,
            hasRestorationLease: restorationLease != nil
        )
        guard restorationPlan != .invalidMissingMutationLease else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "prefix-mutation-restoration-lease-required"
            )
        }
        await quiesceCompatibilityRestorationMonitor(forPrefixKey: key)
        try inputSession.requireNoTerminalFailure()
        if hasCompatibilityRestorationState(forPrefixKey: key) ||
            activeCompatibilityRestorationPrefixLeases[key] != nil {
            try await restoreCompatibilitySessions(forPrefixKey: key)
        }
        try inputSession.requireNoTerminalFailure()
        if restorationLease != nil,
           activeCompatibilityRestorationPrefixLeases[key] != nil {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "duplicate-restoration-prefix-lease"
            )
        }
        if inputRequiresRetention {
            activeInputCompatibilitySessions[key] = inputSession
        } else {
            guard inputSession.restore() else {
                throw SteamInputCompatibilitySessionError.cursorRestoreFailed(
                    "resource-free-session"
                )
            }
        }
        if controllerRequiresRetention {
            activeControllerCompatibilitySessions[key] = controllerSession
        } else {
            controllerSession.restore()
        }
        if let rendererSession {
            activeNVIDIARendererSessions[key] = rendererSession
        }
        guard activeInputCompatibilitySessions[key] != nil ||
                activeControllerCompatibilitySessions[key] != nil ||
                activeNVIDIARendererSessions[key] != nil else {
            compatibilitySessionRestorationFailures.removeValue(forKey: key)
            return
        }
        if restorationPlan == .leaseBacked,
           let restorationLease {
            activeCompatibilityRestorationPrefixLeases[key] = restorationLease
            restorationLease.markTransferred()
            startCompatibilityRestorationMonitor(prefix: prefix, prefixKey: key)
        } else if restorationPlan == .inputOnly,
                  activeInputCompatibilitySessions[key] != nil {
            startInputOnlyCompatibilityRestorationMonitor(
                prefix: prefix,
                prefixKey: key
            )
        }
    }

    private func commitCompatibilitySessionsAfterLaunch(
        _ inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        prefix: URL,
        runtimeExecutable: URL,
        logDirectory: URL,
        restorationLease: SteamCompatibilityRestorationPrefixLease?,
        rendererSession: ActiveNVIDIARendererSession?,
        admission: SteamCompatibilitySessionCommitAdmission,
        result: inout ProcessRunResult,
        fontReceipt: WindowsFontProvisioningApplicationReceipt,
        rendererReceipt: SteamRendererRouteApplicationReceipt,
        prepareForMutation: @escaping () throws -> Void,
        rollbackOwnership:
            GameInputProtectionPostDispatchRollbackOwnership
    ) async throws {
        do {
            if case .successfulDetachedHandoff = admission {
                try populateDetachedHandoffApplicationReceipts(
                    to: &result,
                    inputSession: inputSession,
                    controllerSession: controllerSession,
                    fontReceipt: fontReceipt,
                    rendererReceipt: rendererReceipt
                )
                if rendererSession != nil {
                    guard try await !compatibilityPrefixExitWaiter(
                        prefix,
                        0,
                        0.2
                    ) else {
                        throw SteamCompatibilityLaunchProfileErrorV1
                            .invalidReceipt(
                                "detached-helper-prefix-inactive"
                            )
                    }
                }
            }
            try await commitCompatibilitySessions(
                inputSession,
                controllerSession: controllerSession,
                prefix: prefix,
                restorationLease: restorationLease,
                rendererSession: rendererSession,
                admission: admission
            )
        } catch {
            let commitFailure = error
            let resolution = GameInputProtectionCommitFailureResolver
                .resolve(
                    sessionTerminalFailure: inputSession.terminalFailure,
                    commitFailure: commitFailure,
                    technicalDescription: {
                        forgePlayTechnicalErrorSummary($0)
                    }
                )
            try await containForegroundPostDispatchCommitFailure(
                commitFailure,
                initialTerminalResolution: resolution,
                inputSession: inputSession,
                controllerSession: controllerSession,
                rendererSession: rendererSession,
                rollbackOwnership: rollbackOwnership,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory,
                prepareForMutation: prepareForMutation
            )
        }
    }

    private func populateDetachedHandoffApplicationReceipts(
        to result: inout ProcessRunResult,
        inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        fontReceipt: WindowsFontProvisioningApplicationReceipt,
        rendererReceipt: SteamRendererRouteApplicationReceipt
    ) throws {
        guard SteamLaunchDispatchDisposition.resolve(result) ==
                .successfulForgePlayLauncherHandoff,
              inputSession.permitsDetachedHandoffDegradation,
              !inputSession.requiresFailClosedManagedTransportBinding,
              fontReceipt.isAppliedAndReadBack,
              rendererReceipt.isPreparationVerified else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "detached-handoff-resource-free-readback"
            )
        }
        let controllerReceipt = try controllerSession
            .resourceFreeDetachedHandoffReceipt()
        guard controllerReceipt.isStaticPreparationVerified else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "detached-handoff-resource-free-receipt"
            )
        }
        if inputSession.isResourceFreeProtectionPolicy {
            let inputReceipt = try inputSession.applicationReceipt()
            guard inputReceipt.isResourceFreeNoMutation else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "detached-handoff-resource-free-receipt"
                )
            }
            result.inputCompatibilityReceipt = inputReceipt
        } else {
            result.inputCompatibilityReceipt = nil
            result.inputProtectionDegradedForDetachedHandoff = true
            result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                result.diagnosticCaptureWarning,
                "Pointer-only game protection was not bound because the " +
                    "detached Steam launcher had already exited; Steam and " +
                    "the renderer session remain managed."
            )
        }
        result.controllerCompatibilityReceipt = controllerReceipt
        result.windowsFontProvisioningReceipt = fontReceipt
        result.rendererRouteApplicationReceipt = rendererReceipt
    }

    private func containForegroundPostDispatchCommitFailure(
        _ commitFailure: any Error,
        initialTerminalResolution:
            GameInputProtectionCommitFailureResolution?,
        inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        rendererSession: ActiveNVIDIARendererSession?,
        rollbackOwnership:
            GameInputProtectionPostDispatchRollbackOwnership,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        prepareForMutation: @escaping () throws -> Void
    ) async throws -> Never {
        let key = prefix.standardizedFileURL.path
        let token = await GameInputProtectionForegroundClaimAcquirer
            .acquireFreshClaim(
                acquire: {
                    self.gameInputProtectionContainmentClaims.acquire(
                        prefixKey: key
                    )
                },
                waitForCompletion: { existingToken in
                    await GameInputProtectionContainmentClaimCompletionWaiter
                        .wait(
                            whileCurrent: {
                                self.gameInputProtectionContainmentClaims
                                    .isCurrent(
                                        prefixKey: key,
                                        token: existingToken
                                    )
                            }
                        )
                }
            )
        let processEvidence =
            GameInputProtectionContainmentProcessEvidence()
        let cleanup = await
            GameInputProtectionForegroundContainmentCleanup.run(
                attempt: { [weak self] phase in
                    guard let self else { return .cancelled }
                    return await self
                        .performForegroundPostDispatchContainmentAttempt(
                            phase: phase,
                            inputSession: inputSession,
                            controllerSession: controllerSession,
                            rendererSession: rendererSession,
                            rollbackOwnership: rollbackOwnership,
                            runtimeExecutable: runtimeExecutable,
                            prefix: prefix,
                            prefixKey: key,
                            logDirectory: logDirectory,
                            processEvidence: processEvidence,
                            prepareForMutation: prepareForMutation
                        )
                },
                failureRecorded: { [weak self] state, detail in
                    self?.compatibilitySessionRestorationFailures[key] =
                        "foreground post-dispatch containment " +
                        "\(state.phase) attempt " +
                        "\(state.consecutiveFailures) failed: " +
                        "\(detail); retrying"
                },
                cleanupFinished: { [weak self] completed in
                    guard completed else { return }
                    self?.compatibilitySessionRestorationFailures
                        .removeValue(forKey: key)
                    if let self {
                        GameInputProtectionPostDispatchClaimReleaseGate
                            .releaseIfRollbackCompleted(
                                ownership: rollbackOwnership,
                                registry:
                                    &self.gameInputProtectionContainmentClaims,
                                prefixKey: key,
                                token: token
                            )
                    }
                }
            )
        let terminalResolution = GameInputProtectionCommitFailureResolver
            .resolve(
                sessionTerminalFailure: inputSession.terminalFailure,
                commitFailure: commitFailure,
                technicalDescription: {
                    forgePlayTechnicalErrorSummary($0)
                }
            ) ?? initialTerminalResolution
        let prioritizedError = GameInputProtectionPostDispatchFailurePriority.error(
            originalCommitFailure: commitFailure,
            originalFailureTechnicalDescription:
                forgePlayTechnicalErrorSummary(commitFailure),
            terminalResolution: terminalResolution,
            cleanupCompleted: cleanup.cleanupCompleted,
            callerCancellationObserved:
                cleanup.callerCancellationObserved
        )
        guard !processEvidence.processResults.isEmpty else {
            throw prioritizedError
        }
        throw GameInputProtectionContainmentDiagnosticError(
            underlyingError: prioritizedError,
            diagnosticProcessResults: processEvidence.processResults
        )
    }

    private func scheduleGameInputProtectionTerminalContainment(
        session: GameInputProtectionSessionIdentity,
        failure: GameInputProtectionTerminalFailure,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) {
        let key = prefix.standardizedFileURL.path
        guard !isApplicationTerminationContainmentDrainActive else { return }
        guard GameInputProtectionCommittedSessionGate
            .permitsBackgroundContainment(
                terminalSession: session,
                committedSession:
                    activeInputCompatibilitySessions[key]?.identity,
                hasExistingContainment:
                    gameInputProtectionContainmentClaims.hasClaim(
                        prefixKey: key
                    )
            ) else {
            return
        }
        guard case .acquired(let claimToken) =
                gameInputProtectionContainmentClaims.acquire(prefixKey: key)
        else { return }
        compatibilitySessionRestorationFailures[key] =
            "game input protection terminal failure; containment started: " +
            (failure.errorDescription ?? String(describing: failure))
        let lifecycleGate = GameInputProtectionSafetyFirstLifecycleGate()
        let lifecycleHandler = gameInputProtectionLifecycleEventHandler
        let protectionLostDelivery: (@MainActor @Sendable () -> Void)?
        let containmentCompletedDelivery: (@MainActor @Sendable () -> Void)?
        if let lifecycleHandler {
            protectionLostDelivery = {
                lifecycleHandler(
                    .protectionLost(session: session, failure: failure)
                )
            }
            containmentCompletedDelivery = {
                lifecycleHandler(
                    .containmentCompleted(session: session, failure: failure)
                )
            }
        } else {
            protectionLostDelivery = nil
            containmentCompletedDelivery = nil
        }
        let processEvidence =
            GameInputProtectionContainmentProcessEvidence()
        gameInputProtectionTerminalContainmentTasks[key] = Task { [weak self] in
            let completed = await
                GameInputProtectionTerminalContainmentCoordinator.run(
                    attempt: { phase in
                        guard let self else { return .cancelled }
                        if phase == .shutdown {
                            lifecycleGate
                                .admitShutdownAttemptAndQueueLossEvent(
                                    protectionLostDelivery
                                )
                        }
                        return await self
                            .performGameInputProtectionTerminalContainmentAttempt(
                                phase: phase,
                                runtimeExecutable: runtimeExecutable,
                                prefix: prefix,
                                prefixKey: key,
                                logDirectory: logDirectory,
                                processEvidence: processEvidence
                            )
                    },
                    failureRecorded: { state, detail in
                        self?.compatibilitySessionRestorationFailures[key] =
                            "game input protection terminal containment " +
                            "\(state.phase) attempt " +
                            "\(state.consecutiveFailures) failed after " +
                            "\(failure): \(detail); retrying"
                    }
                )
            guard let self else { return }
            guard self.gameInputProtectionContainmentClaims.release(
                prefixKey: key,
                token: claimToken
            ) else { return }
            self.gameInputProtectionTerminalContainmentTasks.removeValue(
                forKey: key
            )
            guard completed else {
                self.compatibilitySessionRestorationFailures[key] =
                    "game input protection terminal containment was drained; " +
                    "retained compatibility state awaits the termination " +
                    "coordinator"
                return
            }
            self.compatibilitySessionRestorationFailures.removeValue(
                forKey: key
            )
            if let containmentCompletedDelivery {
                lifecycleGate.queueCompletionAfterLossEvent(
                    containmentCompletedDelivery
                )
            }
        }
    }

    private func performForegroundPostDispatchContainmentAttempt(
        phase: GameInputProtectionTerminalContainmentState.Phase,
        inputSession: SteamInputCompatibilitySession,
        controllerSession: SteamControllerCompatibilitySession,
        rendererSession: ActiveNVIDIARendererSession?,
        rollbackOwnership:
            GameInputProtectionPostDispatchRollbackOwnership,
        runtimeExecutable: URL,
        prefix: URL,
        prefixKey key: String,
        logDirectory: URL,
        processEvidence: GameInputProtectionContainmentProcessEvidence,
        prepareForMutation: @escaping () throws -> Void
    ) async -> GameInputProtectionTerminalContainmentCoordinator.AttemptResult {
        guard phase == .restoration else {
            return await performGameInputProtectionTerminalContainmentAttempt(
                phase: phase,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                prefixKey: key,
                logDirectory: logDirectory,
                processEvidence: processEvidence
            )
        }
        await quiesceCompatibilityRestorationMonitor(forPrefixKey: key)
        do {
            try prepareForMutation()
            try await restoreCompatibilitySessions(forPrefixKey: key)
            guard inputSession.restore() else {
                return .failure("local input session restore failed")
            }
            controllerSession.restore()
            rollbackOwnership.markLocalInputAndControllerRollbackCompleted()
            if let rendererSession {
                try await restoreNVIDIARendererSession(rendererSession)
            }
            rollbackOwnership.markRendererRollbackCompleted()
            return .success
        } catch {
            return .failure(forgePlayTechnicalErrorSummary(error))
        }
    }

    private func performGameInputProtectionTerminalContainmentAttempt(
        phase: GameInputProtectionTerminalContainmentState.Phase,
        runtimeExecutable: URL,
        prefix: URL,
        prefixKey key: String,
        logDirectory: URL,
        processEvidence: GameInputProtectionContainmentProcessEvidence
    ) async -> GameInputProtectionTerminalContainmentCoordinator.AttemptResult {
        switch phase {
        case .shutdown:
            let outcome = await prefixProcessSupervisor.shutdownAfterFailure(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
            await retainGameInputProtectionContainmentShutdownEvidence(
                outcome,
                processEvidence: processEvidence
            )
            do {
                if try await compatibilityPrefixExitWaiter(prefix, 30, 0.2) {
                    return .success
                }
            } catch {
                return .failure(forgePlayTechnicalErrorSummary(error))
            }
            let detail = outcome.error.map {
                forgePlayTechnicalErrorSummary($0)
            } ?? outcome.result.map {
                let status = $0.forgePlayStatusCode.map(String.init) ?? "unavailable"
                return "shutdown status \(status); " +
                "managed prefix remained active"
            } ?? "shutdown produced no result and managed prefix remained active"
            return .failure(detail)
        case .restoration:
            await quiesceCompatibilityRestorationMonitor(forPrefixKey: key)
            do {
                try await restoreCompatibilitySessions(forPrefixKey: key)
                return .success
            } catch {
                return .failure(forgePlayTechnicalErrorSummary(error))
            }
        case .complete:
            return .success
        }
    }

    private func retainGameInputProtectionContainmentShutdownEvidence(
        _ outcome: (result: ProcessRunResult?, error: Error?),
        processEvidence: GameInputProtectionContainmentProcessEvidence
    ) async {
        var candidates = [outcome.result].compactMap { $0 }
        if let error = outcome.error {
            candidates.append(contentsOf: diagnosticProcessRunResults(from: error))
        }
        var seen = Set<ProcessRunResult>()
        for candidate in candidates where seen.insert(candidate).inserted {
            let linkedResult = processEvidence.preparingForFinalization(candidate)
            let finalizedResult = await runner.finalizeProcessEvidence(linkedResult)
            processEvidence.recordFinalized(finalizedResult)
        }
    }

    /// Host input filtering owns no prefix mutation. This monitor is the only
    /// nil-restoration-lease path and must never absorb controller/renderer
    /// restoration responsibilities.
#if DEBUG
    /// Debug-only lifecycle seam. It installs the same retained session and
    /// production monitor used by the precommit handoff, allowing cancellation
    /// and owner-deallocation behavior to be verified without launching Wine.
    func debugInstallInputOnlyCompatibilityRestorationMonitor(
        session: SteamInputCompatibilitySession,
        prefix: URL
    ) {
        let key = prefix.standardizedFileURL.path
        precondition(!hasCompatibilityRestorationState(forPrefixKey: key))
        precondition(activeCompatibilityRestorationPrefixLeases[key] == nil)
        activeInputCompatibilitySessions[key] = session
        startInputOnlyCompatibilityRestorationMonitor(
            prefix: prefix,
            prefixKey: key
        )
    }
#endif

    private func startInputOnlyCompatibilityRestorationMonitor(
        prefix: URL,
        prefixKey key: String
    ) {
        guard inputCompatibilityTerminationMonitors[key] == nil,
              activeInputCompatibilitySessions[key] != nil,
              activeControllerCompatibilitySessions[key] == nil,
              activeNVIDIARendererSessions[key] == nil,
              activeCompatibilityRestorationPrefixLeases[key] == nil else {
            return
        }
        let token = UUID()
        let prefixExitWaiter = compatibilityPrefixExitWaiter
        let task = Task { @MainActor [weak self] in
            defer {
                self?.removeCompatibilityRestorationMonitor(
                    forPrefixKey: key,
                    ownedBy: token
                )
            }
            let completed = await
                GameInputProtectionRestorationMonitorLoop.run(
                    observeInactivity: { @MainActor in
                        do {
                            return try await Self
                                .waitForCompatibilityPrefixToBecomeInactive(
                                    prefix,
                                    using: prefixExitWaiter
                                )
                                ? .success
                                : .stop
                        } catch {
                            return .retry(
                                forgePlayTechnicalErrorSummary(error)
                            )
                        }
                    },
                    restore: { @MainActor [weak self] in
                        guard let self else {
                            return .stop
                        }
                        do {
                            try restoreInputOnlyCompatibilitySession(
                                forPrefixKey: key
                            )
                            return .success
                        } catch {
                            return .retry(
                                forgePlayTechnicalErrorSummary(error)
                            )
                        }
                    },
                    failureRecorded: { @MainActor [weak self]
                        kind, failureCount, detail in
                        let label = kind == .observation
                            ? "input-only process observation"
                            : "input-only restoration"
                        self?.compatibilitySessionRestorationFailures[key] =
                            "\(label) attempt \(failureCount) " +
                            "failed closed: \(detail)"
                    }
                )
            if completed {
                self?.compatibilitySessionRestorationFailures.removeValue(
                    forKey: key
                )
            }
        }
        inputCompatibilityTerminationMonitors[key] =
            CompatibilityRestorationMonitor(token: token, task: task)
    }

    private func startCompatibilityRestorationMonitor(
        prefix: URL,
        prefixKey key: String
    ) {
        guard inputCompatibilityTerminationMonitors[key] == nil,
              hasCompatibilityRestorationState(forPrefixKey: key),
              activeCompatibilityRestorationPrefixLeases[key] != nil else {
            return
        }
        let token = UUID()
        let prefixExitWaiter = compatibilityPrefixExitWaiter
        let task = Task { @MainActor [weak self] in
            defer {
                self?.removeCompatibilityRestorationMonitor(
                    forPrefixKey: key,
                    ownedBy: token
                )
            }
            let completed = await
                GameInputProtectionRestorationMonitorLoop.run(
                    observeInactivity: { @MainActor in
                        do {
                            return try await Self
                                .waitForCompatibilityPrefixToBecomeInactive(
                                    prefix,
                                    using: prefixExitWaiter
                                )
                                ? .success
                                : .stop
                        } catch {
                            return .retry(
                                forgePlayTechnicalErrorSummary(error)
                            )
                        }
                    },
                    restore: { @MainActor [weak self] in
                        guard let self else {
                            return .stop
                        }
                        do {
                            try await restoreCompatibilitySessions(
                                forPrefixKey: key
                            )
                            return .success
                        } catch {
                            return .retry(
                                forgePlayTechnicalErrorSummary(error)
                            )
                        }
                    },
                    failureRecorded: { @MainActor [weak self]
                        kind, failureCount, detail in
                        let label = kind == .observation
                            ? "process observation"
                            : "restoration"
                        self?.compatibilitySessionRestorationFailures[key] =
                            "\(label) attempt \(failureCount) failed: " +
                            detail
                    }
                )
            if completed {
                self?.compatibilitySessionRestorationFailures.removeValue(
                    forKey: key
                )
            }
        }
        inputCompatibilityTerminationMonitors[key] =
            CompatibilityRestorationMonitor(token: token, task: task)
    }

    private func removeCompatibilityRestorationMonitor(
        forPrefixKey key: String,
        ownedBy token: UUID
    ) {
        guard GameInputProtectionRestorationMonitorOwnerGate.permitsRemoval(
            currentToken: inputCompatibilityTerminationMonitors[key]?.token,
            ownerToken: token
        ) else {
            return
        }
        inputCompatibilityTerminationMonitors.removeValue(forKey: key)
    }

    private func hasCompatibilityRestorationState(
        forPrefixKey key: String
    ) -> Bool {
        activeInputCompatibilitySessions[key] != nil ||
            activeControllerCompatibilitySessions[key] != nil ||
            activeNVIDIARendererSessions[key] != nil
    }

    private func quiesceCompatibilityRestorationMonitor(
        forPrefixKey key: String
    ) async {
        guard let previousMonitor = inputCompatibilityTerminationMonitors
            .removeValue(forKey: key) else {
            return
        }
        previousMonitor.task.cancel()
        await previousMonitor.task.value
    }

    private func restoreCompatibilitySessions(
        forPrefixKey key: String
    ) async throws {
        guard compatibilityRestorationClaims.insert(key).inserted else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "compatibility-restoration-already-in-progress"
            )
        }
        defer { compatibilityRestorationClaims.remove(key) }
        let requiresPrefixMutationRestoration =
            activeControllerCompatibilitySessions[key] != nil ||
            activeNVIDIARendererSessions[key] != nil
        guard activeCompatibilityRestorationPrefixLeases[key] != nil ||
                !requiresPrefixMutationRestoration else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "prefix-mutation-restoration-lease-missing"
            )
        }
        if let restorationLease =
                activeCompatibilityRestorationPrefixLeases[key] {
            try restorationLease.prepareForMutation()
        }
        if let inputSession = activeInputCompatibilitySessions[key] {
            guard inputSession.restore() else {
                throw SteamInputCompatibilitySessionError.cursorRestoreFailed(
                    "active-session"
                )
            }
            activeInputCompatibilitySessions.removeValue(forKey: key)
        }
        if let controllerSession = activeControllerCompatibilitySessions[key] {
            controllerSession.restore()
            activeControllerCompatibilitySessions.removeValue(forKey: key)
        }
        if let rendererSession = activeNVIDIARendererSessions[key] {
            try await restoreNVIDIARendererSession(rendererSession)
            activeNVIDIARendererSessions.removeValue(forKey: key)
        }
        if !hasCompatibilityRestorationState(forPrefixKey: key),
           let restorationLease = activeCompatibilityRestorationPrefixLeases
            .removeValue(forKey: key) {
            restorationLease.release()
        }
    }

    private func restoreInputOnlyCompatibilitySession(
        forPrefixKey key: String
    ) throws {
        guard compatibilityRestorationClaims.insert(key).inserted else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "compatibility-restoration-already-in-progress"
            )
        }
        defer { compatibilityRestorationClaims.remove(key) }
        guard activeControllerCompatibilitySessions[key] == nil,
              activeNVIDIARendererSessions[key] == nil,
              activeCompatibilityRestorationPrefixLeases[key] == nil else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "input-only-restoration-scope-expanded"
            )
        }
        if let inputSession = activeInputCompatibilitySessions[key] {
            guard inputSession.restore() else {
                throw SteamInputCompatibilitySessionError.cursorRestoreFailed(
                    "input-only-active-session"
                )
            }
            activeInputCompatibilitySessions.removeValue(forKey: key)
        }
    }

    /// Completes every session-scoped compatibility owner after the managed
    /// Wine prefix has been stopped during application termination or a root
    /// transition. The termination coordinator must await this barrier before
    /// it accepts the prefix as clean; otherwise a renderer restoration monitor
    /// can be cancelled with ForgePlay-owned NVIDIA registry/modules still
    /// staged, or its retained prefix lease can race the final shutdown check.
    func completeRetainedCompatibilitySessionsAfterPrefixShutdown(
        prefix: URL
    ) async throws {
        let key = prefix.standardizedFileURL.path
        await quiesceCompatibilityRestorationMonitor(forPrefixKey: key)

        guard try await compatibilityPrefixExitWaiter(prefix, 30, 0.2) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "application-termination-managed-prefix-still-active"
            )
        }

        try await restoreCompatibilitySessions(forPrefixKey: key)

        guard !hasCompatibilityRestorationState(forPrefixKey: key),
              activeCompatibilityRestorationPrefixLeases[key] == nil else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "application-termination-compatibility-restoration-incomplete"
            )
        }
        guard try await compatibilityPrefixExitWaiter(prefix, 30, 0.2) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "application-termination-restoration-prefix-still-active"
            )
        }
        compatibilitySessionRestorationFailures.removeValue(forKey: key)
    }

    /// A successful wineserver shutdown can wake the previous launch's
    /// termination monitor. Quiesce that task before the new launch mutates
    /// renderer or prefix state, then perform any remaining restoration while
    /// the caller still owns the exclusive mutation lease.
    private func reconcileCompatibilitySessionsAfterSuccessfulShutdown(
        prefix: URL
    ) async throws {
        let key = prefix.standardizedFileURL.path
        await quiesceCompatibilityRestorationMonitor(forPrefixKey: key)
        do {
            try await restoreCompatibilitySessions(
                forPrefixKey: key
            )
            compatibilitySessionRestorationFailures.removeValue(forKey: key)
        } catch {
            compatibilitySessionRestorationFailures[key] =
                "exclusive reconciliation restoration failed; retry monitor re-armed: " +
                forgePlayTechnicalErrorSummary(error)
            if hasCompatibilityRestorationState(forPrefixKey: key) {
                if activeCompatibilityRestorationPrefixLeases[key] != nil {
                    startCompatibilityRestorationMonitor(
                        prefix: prefix,
                        prefixKey: key
                    )
                } else {
                    startInputOnlyCompatibilityRestorationMonitor(
                        prefix: prefix,
                        prefixKey: key
                    )
                }
            }
            throw error
        }
    }

    func waitForCompatibilityPrefixToBecomeInactive(
        _ prefix: URL
    ) async throws -> Bool {
        try await Self.waitForCompatibilityPrefixToBecomeInactive(
            prefix,
            using: compatibilityPrefixExitWaiter
        )
    }

    private nonisolated static func waitForCompatibilityPrefixToBecomeInactive(
        _ prefix: URL,
        using prefixExitWaiter: CompatibilityPrefixExitWaiter
    ) async throws -> Bool {
        try await GameInputProtectionRestorationInactivityWaiter
            .waitUntilInactive(prefix, using: prefixExitWaiter)
    }

    /// Renderer rollback mutates registry and System32 state. A prefix lease
    /// only serializes ForgePlay callers; it is not evidence that detached
    /// Wine processes have stopped. Never begin that rollback until the
    /// managed-process journal proves the prefix is inactive.
    private func requireManagedPrefixInactivityBeforeRendererRestoration(
        _ prefix: URL
    ) async throws {
        guard try await compatibilityPrefixExitWaiter(
            prefix,
            30,
            0.2
        ) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "renderer-restoration-managed-prefix-still-active"
            )
        }
    }

    /// An exceptional post-dispatch path may reach the outer recovery owner
    /// without having completed its earlier shutdown. Observe an already-idle
    /// prefix cheaply; otherwise issue a bounded shutdown and require both a
    /// successful shutdown result and explicit inactivity before mutation.
    private func shutdownAndRequireManagedPrefixInactivityForRendererRestoration(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult? {
        if (try? await compatibilityPrefixExitWaiter(prefix, 0, 0.2)) == true {
            return nil
        }

        let cleanup = await prefixProcessSupervisor.shutdownAfterFailure(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        if let cleanupError = cleanup.error {
            throw cleanupError
        }
        guard let cleanupResult = cleanup.result else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "renderer-restoration-shutdown-missing-result"
            )
        }
        guard cleanupResult.succeeded else {
            throw SteamLaunchError.prefixShutdownFailed(cleanupResult)
        }
        try await requireManagedPrefixInactivityBeforeRendererRestoration(
            prefix
        )
        return cleanupResult
    }

    private func restoreNVIDIARendererSession(
        _ session: ActiveNVIDIARendererSession
    ) async throws {
        do {
            try await rendererPolicyManager
                .restoreNVIDIAMetalFXRegistrySessionIfNeeded(
                    prefix: session.prefix,
                    runtimeExecutable: session.runtimeExecutable,
                    runner: runner,
                    logDirectory: session.logDirectory
                )
        } catch {
            let lifecycleFailure = Self
                .rendererLifecycleFailurePreservingStructuredError(
                    error,
                    fallbackPhase: .postLaunchRestoration,
                    fallbackOperation: .sessionRestoration,
                    fallbackTarget: session.prefix,
                    fallbackDetail:
                        "registry: \(forgePlayTechnicalErrorSummary(error))"
                )
            throw SteamLaunchError.rendererLifecycleFailed(
                lifecycleFailure
            )
        }
        do {
            try rendererPolicyManager.restoreNVIDIAMetalFXSessionModules(
                prefix: session.prefix,
                runtimeExecutable: session.runtimeExecutable
            )
        } catch {
            let lifecycleFailure = Self
                .rendererLifecycleFailurePreservingStructuredError(
                    error,
                    fallbackPhase: .postLaunchRestoration,
                    fallbackOperation: .sessionRestoration,
                    fallbackTarget: session.prefix,
                    fallbackDetail:
                        "modules: \(forgePlayTechnicalErrorSummary(error))"
                )
            throw SteamLaunchError.rendererLifecycleFailed(
                lifecycleFailure
            )
        }
    }

    func completeCompatibilitySessionIfInactive(
        prefix: URL,
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int,
        persistentStateDigest: String? = nil
    ) async throws -> String {
        guard try await compatibilityPrefixExitWaiter(
            prefix,
            0,
            0.05
        ) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "managed-prefix-still-active"
            )
        }
        let key = prefix.standardizedFileURL.path
        await quiesceCompatibilityRestorationMonitor(forPrefixKey: key)
        try await restoreCompatibilitySessions(forPrefixKey: key)
        compatibilitySessionRestorationFailures.removeValue(
            forKey: key
        )
        return "forgeplay-transient-compatibility-session-reconciled-v1"
    }

    nonisolated static let steamCrashDumpExitCode: Int32 = 70
    nonisolated static let steamRenderingFailureExitCode: Int32 = 71
    nonisolated static let hostSteamLaunchContaminationExitCode: Int32 = 72
    nonisolated static let externalRunnerContaminationExitCode: Int32 = 73
    nonisolated static let hardGateEvidenceIncompleteExitCode: Int32 = 74
    nonisolated static let steamLaunchBlockedExitCode: Int32 = 75
    nonisolated static let steamBootstrapUpdateInProgressExitCode: Int32 = 76
    nonisolated static let steamLaunchProcessVerificationUnavailableExitCode: Int32 = 77
    nonisolated static let steamUIStartupFailureExitCode: Int32 = 78

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

    private nonisolated static func existingRendererLifecycleFailure(
        from error: Error,
        recursionDepth: Int = 0
    ) -> SteamRendererLifecycleFailure? {
        guard recursionDepth < 8 else { return nil }
        if let steamLaunchError = error as? SteamLaunchError,
           case .rendererLifecycleFailed(let failure) = steamLaunchError {
            return failure
        }
        if let evidenceError = error as? ProcessExecutionEvidenceError {
            return existingRendererLifecycleFailure(
                from: evidenceError.underlyingError,
                recursionDepth: recursionDepth + 1
            )
        }
        let bridged = error as NSError
        if let underlyingError = bridged.userInfo[NSUnderlyingErrorKey] as? Error,
           forgePlayTechnicalErrorSummary(underlyingError) !=
            forgePlayTechnicalErrorSummary(error) {
            return existingRendererLifecycleFailure(
                from: underlyingError,
                recursionDepth: recursionDepth + 1
            )
        }
        return nil
    }

    private nonisolated static func processDiagnosticUnderlyingError(
        from error: Error,
        recursionDepth: Int = 0
    ) -> Error {
        guard recursionDepth < 8 else { return error }
        if let evidenceError = error as? ProcessExecutionEvidenceError {
            return processDiagnosticUnderlyingError(
                from: evidenceError.underlyingError,
                recursionDepth: recursionDepth + 1
            )
        }
        if let containmentError =
            error as? GameInputProtectionContainmentDiagnosticError {
            return processDiagnosticUnderlyingError(
                from: containmentError.underlyingError,
                recursionDepth: recursionDepth + 1
            )
        }
        return error
    }

    nonisolated static func rendererLifecycleFailurePreservingStructuredError(
        _ error: Error,
        fallbackPhase: SteamRendererLifecyclePhase,
        fallbackOperation: SteamRendererLifecycleOperation,
        fallbackTarget: URL,
        fallbackDetail: String? = nil,
        additionalDetail: String? = nil,
        additionalProcessResults: [ProcessRunResult] = []
    ) -> SteamRendererLifecycleFailure {
        let existingFailure = existingRendererLifecycleFailure(from: error)
        let detail = [
            existingFailure?.detail ?? fallbackDetail ??
                forgePlayTechnicalErrorSummary(error),
            additionalDetail
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "; ")
        let processResults = (
            (existingFailure?.processResults ?? []) +
            diagnosticProcessRunResults(from: error) +
            additionalProcessResults
        ).reduce(into: [ProcessRunResult]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return SteamRendererLifecycleFailure(
            phase: existingFailure?.phase ?? fallbackPhase,
            operation: existingFailure?.operation ?? fallbackOperation,
            target: existingFailure?.target ?? fallbackTarget,
            detail: detail,
            processResults: processResults
        )
    }

    fileprivate nonisolated static func attachLaunchChainEvidence(
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
        runtimeCapability: WindowsRuntimeCapability? = nil,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int? = nil
    ) -> SteamRendererPolicyInspection {
        rendererPolicyManager.inspect(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: runtimeCapability,
            selection: selection,
            videoMemorySizeMB: videoMemorySizeMB
        )
    }

    /// Readiness keeps exact ForgePlay-owned transient NVIDIA session residue
    /// distinct from arbitrary renderer contamination. The launch preflight
    /// already admits this marker-backed transaction and restores it only
    /// after the managed prefix is inactive. Projecting that typed state here
    /// lets a restarted app return to Steam Launch without claiming that the
    /// renderer policy is already clean or weakening fail-closed inspection
    /// for any mismatched/unowned files.
    func inspectSteamRendererPolicyForReadiness(
        prefix: URL,
        runtimeExecutable: URL,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int? = nil
    ) -> SteamRendererPolicyInspection {
        let inspection = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: runtimeCapability,
            selection: selection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        guard rendererPolicyManager.isRecoverableNVIDIAMetalFXSessionResidue(
            inspection,
            prefix: prefix,
            runtimeExecutable: runtimeExecutable
        ) else {
            return inspection
        }
        return SteamRendererPolicyInspection(
            selection: inspection.selection,
            resolvedPolicy: inspection.resolvedPolicy,
            status: .warning,
            userMessage: "이전 Steam 세션의 ForgePlay 관리 항목이 남아 있습니다. 다음 Steam 실행 준비 단계에서 프리픽스가 종료된 것을 확인한 뒤 자동 복구를 시도합니다.",
            appliedModules: inspection.appliedModules,
            missingModules: inspection.missingModules,
            mixedModules: inspection.mixedModules,
            appliedProfileOverrides: inspection.appliedProfileOverrides,
            missingProfileOverrides: inspection.missingProfileOverrides,
            staleProfileOverrides: inspection.staleProfileOverrides,
            appliedSteamClientFiles: inspection.appliedSteamClientFiles,
            missingSteamClientFiles: inspection.missingSteamClientFiles,
            staleSteamClientFiles: inspection.staleSteamClientFiles,
            recoveryKind: .automaticSessionRecovery
        )
    }

    func captureCompatibilityPersistentPrefixSnapshot(
        prefix: URL
    ) throws -> SteamCompatibilityPersistentPrefixSnapshot {
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            prefix,
            fileManager: fileManager
        )
        let prefixDescriptor = try Self.openPersistentPrefixDirectory(
            prefix,
            failureCode: "persistent-prefix-parent-containment"
        )
        defer { Darwin.close(prefixDescriptor) }
        let metadata = try Self.boundedStableOptionalFileData(
            relativePathComponents: ["prefix.json"],
            prefixDescriptor: prefixDescriptor,
            parentFailureCode: "persistent-prefix-parent-containment",
            maximumByteCount: 1_048_576
        )
        let libraryFolders = try Self.boundedStableOptionalFileData(
            relativePathComponents: [
                "drive_c",
                "Program Files (x86)",
                "Steam",
                "steamapps",
                "libraryfolders.vdf"
            ],
            prefixDescriptor: prefixDescriptor,
            parentFailureCode: "persistent-prefix-parent-containment",
            maximumByteCount: 8 * 1_048_576
        )
        let dosDevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            dosDevices,
            fileManager: fileManager
        )
        let names = try fileManager.contentsOfDirectory(atPath: dosDevices.path)
            .sorted()
        var targets: [String: String] = [:]
        for name in names {
            guard !name.contains("/") && name != "." && name != ".." else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "dosdevices-entry-name"
                )
            }
            let url = dosDevices.appending(path: name)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFLNK else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "dosdevices-entry-type"
                )
            }
            targets[name] = try fileManager.destinationOfSymbolicLink(
                atPath: url.path
            )
        }
        let digest = Self.persistentPrefixSnapshotDigest(
            metadata: metadata,
            libraryFolders: libraryFolders,
            dosDeviceSymlinkTargets: targets
        )
        return SteamCompatibilityPersistentPrefixSnapshot(
            prefixMetadata: metadata,
            steamLibraryFolders: libraryFolders,
            dosDeviceSymlinkTargets: targets,
            digest: digest
        )
    }

    func restoreCompatibilityPersistentPrefixSnapshot(
        _ snapshot: SteamCompatibilityPersistentPrefixSnapshot,
        prefix: URL
    ) throws {
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            prefix,
            fileManager: fileManager
        )
        let prefixDescriptor = try Self.openPersistentPrefixDirectory(
            prefix,
            failureCode: "persistent-prefix-restore-parent-containment"
        )
        defer { Darwin.close(prefixDescriptor) }
        let metadataPathComponents = ["prefix.json"]
        let libraryFoldersPathComponents = [
            "drive_c",
            "Program Files (x86)",
            "Steam",
            "steamapps",
            "libraryfolders.vdf"
        ]
        try Self.validatePersistentFileRestoreDestination(
            relativePathComponents: metadataPathComponents,
            prefixDescriptor: prefixDescriptor,
            parentFailureCode: "persistent-prefix-restore-parent-containment"
        )
        try Self.validatePersistentFileRestoreDestination(
            relativePathComponents: libraryFoldersPathComponents,
            prefixDescriptor: prefixDescriptor,
            parentFailureCode: "persistent-prefix-restore-parent-containment"
        )
        try Self.restorePersistentFile(
            relativePathComponents: metadataPathComponents,
            prefixDescriptor: prefixDescriptor,
            data: snapshot.prefixMetadata,
            parentFailureCode: "persistent-prefix-restore-parent-containment"
        )
        try Self.restorePersistentFile(
            relativePathComponents: libraryFoldersPathComponents,
            prefixDescriptor: prefixDescriptor,
            data: snapshot.steamLibraryFolders,
            parentFailureCode: "persistent-prefix-restore-parent-containment"
        )
        let dosDevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            dosDevices,
            fileManager: fileManager
        )
        let currentNames = try fileManager.contentsOfDirectory(
            atPath: dosDevices.path
        )
        for name in currentNames.sorted() {
            let url = dosDevices.appending(path: name)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFLNK else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "dosdevices-restore-entry-type"
                )
            }
            let currentTarget = try fileManager.destinationOfSymbolicLink(
                atPath: url.path
            )
            if snapshot.dosDeviceSymlinkTargets[name] != currentTarget {
                try fileManager.removeItem(at: url)
            }
        }
        for (name, target) in snapshot.dosDeviceSymlinkTargets.sorted(
            by: { $0.key < $1.key }
        ) {
            let url = dosDevices.appending(path: name)
            if fileManager.fileExists(atPath: url.path) ||
                (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                let current = try fileManager.destinationOfSymbolicLink(
                    atPath: url.path
                )
                guard current == target else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "dosdevices-restore-collision"
                    )
                }
            } else {
                try fileManager.createSymbolicLink(
                    atPath: url.path,
                    withDestinationPath: target
                )
            }
        }
        guard try captureCompatibilityPersistentPrefixSnapshot(prefix: prefix) ==
                snapshot else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "persistent-prefix-restore-readback"
            )
        }
    }

    private nonisolated static func persistentPrefixSnapshotDigest(
        metadata: Data?,
        libraryFolders: Data?,
        dosDeviceSymlinkTargets: [String: String]
    ) -> String {
        var data = Data("forgeplay-persistent-prefix-state-v1\n".utf8)
        for (label, value) in [
            ("prefix.json", metadata),
            ("libraryfolders.vdf", libraryFolders)
        ] {
            data.append(contentsOf: "\(label)=\(value?.count ?? -1):".utf8)
            if let value { data.append(value) }
            data.append(10)
        }
        for (name, target) in dosDeviceSymlinkTargets.sorted(
            by: { $0.key < $1.key }
        ) {
            data.append(contentsOf: "link=\(name.utf8.count):\(name)=".utf8)
            data.append(contentsOf: "\(target.utf8.count):\(target)\n".utf8)
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private nonisolated static func openPersistentPrefixDirectory(
        _ prefix: URL,
        failureCode: String
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            prefix.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                failureCode
            )
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                failureCode
            )
        }
        return descriptor
    }

    /// Opens a persistent-state file relative to the already verified prefix.
    /// Every existing parent is opened with `O_NOFOLLOW`. A first missing
    /// parent means the optional file is absent; components below that point
    /// cannot exist without the missing ancestor and are deliberately not
    /// treated as a containment failure.
    private nonisolated static func boundedStableOptionalFileData(
        relativePathComponents: [String],
        prefixDescriptor: Int32,
        parentFailureCode: String,
        maximumByteCount: Int
    ) throws -> Data? {
        guard let parentDescriptor = try openPersistentPrefixParent(
            relativePathComponents: relativePathComponents,
            prefixDescriptor: prefixDescriptor,
            createMissingDirectories: false,
            failureCode: parentFailureCode
        ) else {
            return nil
        }
        defer { Darwin.close(parentDescriptor) }
        guard let leaf = relativePathComponents.last else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                parentFailureCode
            )
        }
        let descriptor = leaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        let openError = errno
        if descriptor < 0, openError == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "persistent-prefix-file-open"
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= maximumByteCount else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "persistent-prefix-file-bounds"
            )
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remainingByteCount = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    remainingByteCount,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-file-read"
                )
            }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "persistent-prefix-file-raced"
            )
        }
        return Data(bytes)
    }

    /// Returns a descriptor for the leaf's parent. Existing components are
    /// always traversed descriptor-relative without following symlinks. When
    /// creation is disabled, the first missing component returns `nil` so an
    /// optional nested file can be represented by a nil snapshot.
    private nonisolated static func openPersistentPrefixParent(
        relativePathComponents: [String],
        prefixDescriptor: Int32,
        createMissingDirectories: Bool,
        failureCode: String
    ) throws -> Int32? {
        guard !relativePathComponents.isEmpty,
              relativePathComponents.allSatisfy({ component in
                  !component.isEmpty &&
                      component != "." &&
                      component != ".." &&
                      !component.contains("/")
              }) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                failureCode
            )
        }
        var descriptor = Darwin.fcntl(
            prefixDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard descriptor >= 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                failureCode
            )
        }
        for component in relativePathComponents.dropLast() {
            var nextDescriptor = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            var componentError = errno
            if nextDescriptor < 0,
               componentError == ENOENT,
               createMissingDirectories {
                let createResult = component.withCString {
                    Darwin.mkdirat(descriptor, $0, 0o755)
                }
                componentError = errno
                guard createResult == 0 || componentError == EEXIST else {
                    Darwin.close(descriptor)
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        failureCode
                    )
                }
                nextDescriptor = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                    )
                }
                componentError = errno
            }
            if nextDescriptor < 0,
               componentError == ENOENT,
               !createMissingDirectories {
                Darwin.close(descriptor)
                return nil
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(descriptor)
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    failureCode
                )
            }
            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }
        return descriptor
    }

    private nonisolated static func persistentPrefixLeafStatus(
        parentDescriptor: Int32,
        leaf: String,
        failureCode: String
    ) throws -> stat? {
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let statusError = errno
        if result < 0, statusError == ENOENT { return nil }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                failureCode
            )
        }
        return status
    }

    /// Validates every currently existing restore destination before any
    /// persistent file is changed. This keeps a pre-existing symlink,
    /// hardlink, directory, or other foreign entry from causing a partial
    /// multi-file rollback.
    private nonisolated static func validatePersistentFileRestoreDestination(
        relativePathComponents: [String],
        prefixDescriptor: Int32,
        parentFailureCode: String
    ) throws {
        guard let leaf = relativePathComponents.last else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                parentFailureCode
            )
        }
        guard let parentDescriptor = try openPersistentPrefixParent(
            relativePathComponents: relativePathComponents,
            prefixDescriptor: prefixDescriptor,
            createMissingDirectories: false,
            failureCode: parentFailureCode
        ) else {
            return
        }
        defer { Darwin.close(parentDescriptor) }
        _ = try persistentPrefixLeafStatus(
            parentDescriptor: parentDescriptor,
            leaf: leaf,
            failureCode: "persistent-prefix-restore-entry-type"
        )
    }

    private nonisolated static func restorePersistentFile(
        relativePathComponents: [String],
        prefixDescriptor: Int32,
        data: Data?,
        parentFailureCode: String
    ) throws {
        guard let leaf = relativePathComponents.last else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                parentFailureCode
            )
        }
        guard let parentDescriptor = try openPersistentPrefixParent(
            relativePathComponents: relativePathComponents,
            prefixDescriptor: prefixDescriptor,
            createMissingDirectories: data != nil,
            failureCode: parentFailureCode
        ) else {
            return
        }
        defer { Darwin.close(parentDescriptor) }
        let existingStatus = try persistentPrefixLeafStatus(
            parentDescriptor: parentDescriptor,
            leaf: leaf,
            failureCode: "persistent-prefix-restore-entry-type"
        )
        guard let data else {
            guard existingStatus != nil else { return }
            let result = leaf.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-restore-remove"
                )
            }
            return
        }

        let temporaryName = ".forgeplay-restore-\(UUID().uuidString.lowercased())"
        let mode = existingStatus.map {
            mode_t($0.st_mode & 0o777)
        } ?? mode_t(0o600)
        let temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "persistent-prefix-restore-temp-open"
            )
        }
        var temporaryExists = true
        defer {
            Darwin.close(temporaryDescriptor)
            if temporaryExists {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, 0)
                }
            }
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(
                    temporaryDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-restore-write"
                )
            }
            offset += written
        }
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "persistent-prefix-restore-sync"
            )
        }

        if let existingStatus {
            let swapResult = temporaryName.withCString { temporaryPointer in
                leaf.withCString { leafPointer in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        temporaryPointer,
                        parentDescriptor,
                        leafPointer,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapResult == 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-restore-swap"
                )
            }
            let replacedStatus: stat?
            do {
                replacedStatus = try persistentPrefixLeafStatus(
                    parentDescriptor: parentDescriptor,
                    leaf: temporaryName,
                    failureCode: "persistent-prefix-restore-raced"
                )
            } catch {
                let rollbackResult = temporaryName.withCString { temporaryPointer in
                    leaf.withCString { leafPointer in
                        Darwin.renameatx_np(
                            parentDescriptor,
                            temporaryPointer,
                            parentDescriptor,
                            leafPointer,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard rollbackResult == 0 else {
                    temporaryExists = false
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "persistent-prefix-restore-race-rollback"
                    )
                }
                throw error
            }
            guard replacedStatus?.st_dev == existingStatus.st_dev,
                  replacedStatus?.st_ino == existingStatus.st_ino else {
                let rollbackResult = temporaryName.withCString { temporaryPointer in
                    leaf.withCString { leafPointer in
                        Darwin.renameatx_np(
                            parentDescriptor,
                            temporaryPointer,
                            parentDescriptor,
                            leafPointer,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard rollbackResult == 0 else {
                    temporaryExists = false
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "persistent-prefix-restore-race-rollback"
                    )
                }
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-restore-raced"
                )
            }
            let removeResult = temporaryName.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            guard removeResult == 0 else {
                temporaryExists = false
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-restore-old-remove"
                )
            }
            temporaryExists = false
        } else {
            let installResult = temporaryName.withCString { temporaryPointer in
                leaf.withCString { leafPointer in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        temporaryPointer,
                        parentDescriptor,
                        leafPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard installResult == 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "persistent-prefix-restore-raced"
                )
            }
            temporaryExists = false
        }
    }

    func compatibilityLaunchBaselineDigest(
        prefix: URL,
        runtimeExecutable: URL,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int,
        persistentStateDigest suppliedPersistentStateDigest: String? = nil
    ) throws -> String {
        let renderer = inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable,
            runtimeCapability: runtimeCapability,
            selection: selection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        let fonts = WindowsFontCompatibilityProfileContract.inspect(
            prefix: prefix,
            fileManager: fileManager,
            requiresProfileMarker: true
        )
        let prefixKey = prefix.standardizedFileURL.path
        let persistentStateDigest: String
        if let suppliedPersistentStateDigest {
            persistentStateDigest = suppliedPersistentStateDigest
        } else {
            persistentStateDigest = try captureCompatibilityPersistentPrefixSnapshot(
                prefix: prefix
            ).digest
        }
        var values = [
            "forgeplay-steam-launch-authoritative-baseline-v1",
            "renderer-status=\(String(describing: renderer.status))",
            "renderer-requires-apply=\(renderer.requiresApply ? 1 : 0)",
            "persistent-state=\(persistentStateDigest)",
            "input-session-active=\(activeInputCompatibilitySessions[prefixKey] == nil ? 0 : 1)",
            "controller-session-active=\(activeControllerCompatibilitySessions[prefixKey] == nil ? 0 : 1)"
        ]
        values.append(contentsOf: renderer.appliedModules.sorted().map {
            "renderer-applied=\($0)"
        })
        values.append(contentsOf: renderer.missingModules.sorted().map {
            "renderer-missing=\($0)"
        })
        values.append(contentsOf: renderer.mixedModules.sorted().map {
            "renderer-mixed=\($0)"
        })
        values.append(contentsOf: fonts.appliedItems.sorted().map {
            "font-applied=\($0)"
        })
        values.append(contentsOf: fonts.missingItems.sorted().map {
            "font-missing=\($0)"
        })
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        let accessPlan: SteamLibraryDriveAccessPlan
        do {
            accessPlan = try steamLibraryDriveAccessPlan(
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
                    NSLog(
                        "ForgePlay Steam library discovery audit write failed after product failure: %@; audit failure: %@",
                        forgePlayTechnicalErrorSummary(error),
                        forgePlayTechnicalErrorSummary(auditError)
                    )
                }
            }
            throw error
        }
        let normalizedReservedRoots = steamLibraryReservationRoots(
            reservedLibraryRoots
        )
        let storagePreparation: SteamStorageDrivePreparation
        if accessPlan.mappedStorageRoots.isEmpty,
           accessPlan.driveSources.isEmpty,
           !accessPlan.directProcessAccessRoots.isEmpty {
            // Direct steamapps authorization is already held for the launch
            // lifetime. Do not create a drive rooted at `steamapps` and do not
            // touch unrelated drive assignments merely to publish that grant.
            storagePreparation = SteamStorageDrivePreparation(
                externalStorageRoots: [],
                libraryMappings: [],
                pendingLibraryMappings: []
            )
        } else {
            storagePreparation = try libraryDriveMapper
                .prepareStorageDriveLinks(
                    prefix: prefix,
                    authorizedStorageRoots: accessPlan.mappedStorageRoots,
                    sources: accessPlan.driveSources,
                    reservedDriveRoots: normalizedReservedRoots,
                    reconciliationScope: accessPlan.reconciliationScope
                )
        }
        let processAccessRoots = steamLibraryReservationRoots(
            storagePreparation.externalStorageRoots +
                accessPlan.directProcessAccessRoots
        )
        return SteamLibraryDrivePreparation(
            mappings: storagePreparation.libraryMappings,
            pendingMappings: storagePreparation.pendingLibraryMappings,
            externalStorageRoots: processAccessRoots,
            discoveries: discoveries
        )
    }

    func synchronizeSteamLibraryRegistrations(
        prefix: URL,
        mappings: [SteamLibraryDriveMapping],
        pendingMappings: [SteamLibraryDriveMapping] = [],
        discoveries: [SteamLibraryRootDiscoveryResult] = [],
        logDirectory: URL? = nil
    ) throws {
        do {
            try libraryDriveMapper.synchronizeDriveMappingsWithSteam(
                prefix: prefix,
                mappings: mappings,
                pendingMappings: pendingMappings,
                reconciliationScope:
                    steamLibraryDriveReconciliationScope(
                        for: discoveries
                    )
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
                    NSLog(
                        "ForgePlay Steam library registration audit write failed after product failure: %@; audit failure: %@",
                        forgePlayTechnicalErrorSummary(error),
                        forgePlayTechnicalErrorSummary(auditError)
                    )
                }
            }
            throw error
        }
        if let logDirectory {
            do {
                let status: String
                if !mappings.isEmpty {
                    status = "success"
                } else if !pendingMappings.isEmpty {
                    status = "storage_drive_ready_registration_pending"
                } else if discoveries.isEmpty {
                    status = "no_authorized_storage"
                } else if steamLibraryDriveReconciliationScope(
                    for: discoveries
                ) == .preservingUnrepresentedState {
                    status = "direct_steamapps_access_ready"
                } else {
                    status = "storage_drive_ready_no_existing_library"
                }
                try persistSteamLibraryRegistrationAudit(
                    prefix: prefix,
                    mappings: mappings,
                    discoveries: discoveries,
                    status: status,
                    errorDescription: nil,
                    logDirectory: logDirectory
                )
            } catch let auditError {
                NSLog(
                    "ForgePlay Steam library registration succeeded but its optional audit write failed: %@",
                    forgePlayTechnicalErrorSummary(auditError)
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
        if let failedCompatibilitySetup = try await steamClientCompatibilityProfile.apply(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            videoMemorySizeMB: videoMemorySizeMB
        ) {
            throw SteamLaunchError.steamClientCompatibilitySetupFailed(failedCompatibilitySetup)
        }
    }

    /// Wine registry operations can rebuild host-font projections. Keep the
    /// font profile as the last registry convergence barrier before dispatch,
    /// after service, client, renderer, library, and language preparation have
    /// run.
    func reconcileWindowsFontCompatibilityProfile(
        runtimeExecutable: URL,
        prefix: URL
    ) async throws -> WindowsFontProvisioningApplicationReceipt {
        let logDirectory = try pathManager.url(for: .launchLogs)
        return try await windowsFontCompatibilityProfile.provisionForLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
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

    /// Runs only after a successful prefix shutdown while the caller retains
    /// the exclusive prefix mutation lease. Failures are diagnostic-only so an
    /// unsafe log cannot be mistaken for authority to block or alter Steam.
    func rotateOfflineSteamClientLogsIfNeeded(prefix: URL) async -> String? {
        do {
            guard pathManager.rootURL != nil else {
                throw PathManagerError.rootNotConfigured
            }
            let managedLogsRoot = try pathManager.url(for: .logs)
            let result = try await Task.detached(priority: .utility) {
                try SteamClientLogRetentionService.rotateOfflineLogs(
                    in: prefix,
                    managedLogsRoot: managedLogsRoot
                )
            }.value
            return result.diagnosticMessage
        } catch {
            return "Offline Steam client log rotation was skipped: \(forgePlayTechnicalErrorSummary(error))"
        }
    }

    /// Stops only the managed Steam runtime. Provider rollback subsequently
    /// restores session and persistent state through its retained transaction
    /// lease; this method deliberately does not release that lease or mutate
    /// the captured baseline.
    func shutdownManagedSteamRuntimeOnly(
        runtimeExecutable: URL
    ) async throws -> ProcessRunResult {
        let prefix = try steamPrefixURL(for: runtimeExecutable)
        let logDirectory = try pathManager.url(for: .launchLogs)
        let shutdownResult = try await prefixProcessSupervisor.shutdownBeforeLaunch(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        )
        guard try await compatibilityPrefixExitWaiter(
            prefix,
            30,
            0.2
        ) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "managed-runtime-shutdown-not-observed"
            )
        }
        await quiesceCompatibilityRestorationMonitor(
            forPrefixKey: prefix.standardizedFileURL.path
        )
        return shutdownResult
    }

    func restoreSteamRendererBridgeModules(
        prefix: URL,
        runtimeExecutable: URL,
        logDirectory: URL? = nil
    ) async throws {
        try await rendererPolicyManager
            .restoreNVIDIAMetalFXRegistrySessionIfNeeded(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runner: runner,
                logDirectory:
                    logDirectory ??
                    pathManager.url(for: .launchLogs),
                phase: .priorSessionRestoration
            )
        // The transient NVIDIA module transaction owns its exact System32
        // files and snapshots. Retire it before the broad renderer cleanup so
        // app/runtime upgrades and partial prior sessions preserve their
        // marker-backed restoration contract.
        try rendererPolicyManager.restoreNVIDIAMetalFXSessionModules(
            prefix: prefix,
            runtimeExecutable: runtimeExecutable
        )
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
            result.skippedInputPaths.subtract(
                ignorableMissingSteamAppsPath(for: discovery)
            )
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
            result.skippedInputPaths.subtract(
                ignorableMissingSteamAppsPath(for: discovery)
            )
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

    private func ignorableMissingSteamAppsPath(
        for discovery: SteamLibraryRootDiscoveryResult
    ) -> Set<String> {
        guard case .noVerifiedSteamLibrary? = discovery.failure,
              discovery.resolution == nil else {
            return []
        }
        return [discovery.selectedRoot.standardizedFileURL.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        ).standardizedFileURL.path]
    }

    private func verifiedSteamLibraryRoots(
        from discoveries: [SteamLibraryRootDiscoveryResult]
    ) throws -> [URL] {
        var seen = Set<String>()
        var verifiedRoots: [URL] = []
        for discovery in discoveries {
            for libraryRoot in try discoveredLibraryRootsForUse(discovery) {
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

    private struct SteamLibraryDriveAccessPlan {
        var driveSources: [SteamLibraryDriveSource]
        var mappedStorageRoots: [URL]
        var directProcessAccessRoots: [URL]
        var reconciliationScope: SteamLibraryDriveReconciliationScope
    }

    /// Separates persistent storage ownership from a direct game-library
    /// capability. Selecting `SteamLibrary` authorizes that directory for Wine
    /// drive mapping and Steam registration. Selecting its `steamapps` child
    /// authorizes only that exact subtree for this process lifetime; it never
    /// implies permission to read, map, or register the parent directory.
    private func steamLibraryDriveAccessPlan(
        discoveries: [SteamLibraryRootDiscoveryResult]
    ) throws -> SteamLibraryDriveAccessPlan {
        var seenSources = Set<String>()
        var seenMappedRoots = Set<String>()
        var seenDirectRoots = Set<String>()
        var sources: [SteamLibraryDriveSource] = []
        var mappedRoots: [URL] = []
        var directRoots: [URL] = []
        var reconciliationScope =
            SteamLibraryDriveReconciliationScope
                .authoritativeStorageInventory
        for discovery in discoveries {
            let libraryRoots = try discoveredLibraryRootsForUse(discovery)
            let selectedRoot = discovery.selectedRoot.standardizedFileURL
            if discovery.resolution == .selectedSteamApps {
                guard libraryRoots.count == 1,
                      selectedRoot.lastPathComponent.caseInsensitiveCompare(
                          "steamapps"
                      ) == .orderedSame,
                      selectedRoot.deletingLastPathComponent()
                        .standardizedFileURL ==
                        libraryRoots[0].standardizedFileURL,
                      FileSystemItemPolicy.isNonSymlinkDirectory(
                          selectedRoot,
                          fileManager: fileManager
                      ) else {
                    throw SteamLibraryRootDiscoveryError
                        .noVerifiedSteamLibrary(
                            selectedRoot,
                            skippedPaths: [selectedRoot.path]
                        )
                }
                let identity = selectedRoot.resolvingSymlinksInPath()
                    .standardizedFileURL.path
                if seenDirectRoots.insert(identity).inserted {
                    directRoots.append(selectedRoot)
                }
                reconciliationScope = .preservingUnrepresentedState
                continue
            }

            for libraryRoot in libraryRoots {
                let normalizedLibraryRoot = libraryRoot.standardizedFileURL
                let normalizedAuthorizedRoot = try steamLibraryDriveRoot(
                    for: discovery,
                    libraryRoot: normalizedLibraryRoot
                )
                let identity = [
                    normalizedAuthorizedRoot.resolvingSymlinksInPath().path,
                    normalizedLibraryRoot.resolvingSymlinksInPath().path
                ].joined(separator: "|")
                guard seenSources.insert(identity).inserted else { continue }
                sources.append(SteamLibraryDriveSource(
                    authorizedRootURL: normalizedAuthorizedRoot,
                    libraryURL: normalizedLibraryRoot
                ))
            }
            let mappedIdentity = selectedRoot.resolvingSymlinksInPath()
                .standardizedFileURL.path
            if seenMappedRoots.insert(mappedIdentity).inserted {
                mappedRoots.append(selectedRoot)
            }
        }
        return SteamLibraryDriveAccessPlan(
            driveSources: sources,
            mappedStorageRoots: mappedRoots.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            directProcessAccessRoots: directRoots.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            reconciliationScope: reconciliationScope
        )
    }

    /// A writable authorized storage root is valid even before it contains a
    /// Steam library. Discovery failures caused by traversal or authorization
    /// remain fatal; the absence of `steamapps` only means there is nothing to
    /// scan or register yet.
    private func discoveredLibraryRootsForUse(
        _ discovery: SteamLibraryRootDiscoveryResult
    ) throws -> [URL] {
        guard let failure = discovery.failure else {
            return discovery.libraryRoots
        }
        if case .noVerifiedSteamLibrary = failure {
            // A blank drive/folder is valid storage. A malformed explicit
            // Steam subtree is not a blank drive and must never be reinterpreted
            // as one. Verified direct steamapps access is handled separately
            // by `steamLibraryDriveAccessPlan` without parent promotion.
            guard discovery.resolution == nil else { throw failure }
            return []
        }
        throw failure
    }

    private func steamLibraryDriveReconciliationScope(
        for discoveries: [SteamLibraryRootDiscoveryResult]
    ) -> SteamLibraryDriveReconciliationScope {
        discoveries.contains {
            $0.failure == nil && $0.resolution == .selectedSteamApps
        } ? .preservingUnrepresentedState : .authoritativeStorageInventory
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
        guard result.succeeded,
              SteamLaunchDispatchDisposition.resolve(result)
                .acceptsSessionLifetime else { return false }
        guard renderingIssue == nil, fatalCrashDumps.isEmpty else { return false }
        guard processSnapshot.containsVerifiedCurrentRunSteamClientProcess(
            for: launchTarget
        ) else { return false }
        guard processSnapshot.managedWineJournalWebHelperCommandLines(
            for: launchTarget
        ).isEmpty else { return false }
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
        steamDirectory: URL,
        since cursor: SteamBootstrapUpdateSourceCursor
    ) -> Bool {
        steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: cursor
        ).hasProgress == true
    }

    func steamBootstrapUpdateLogAssessment(
        result: ProcessRunResult,
        steamDirectory: URL,
        since cursor: SteamBootstrapUpdateSourceCursor
    ) -> SteamBootstrapUpdateLogAssessment {
        let bootstrapLog = steamDirectory.appending(path: "logs/bootstrap_log.txt")
        let sources: [(SteamBootstrapUpdaterEvidenceSource, SteamBootstrapLogSourceAssessment)] = [
            (.stdout, secureAppendedBootstrapEvidence(
                from: result.stdoutLog,
                since: cursor.stdout,
                maxBytes: 128_000,
                anchoredAt: result.stdoutLog.deletingLastPathComponent(),
                required: true
            )),
            (.bootstrapLog, secureAppendedBootstrapEvidence(
                from: bootstrapLog,
                since: cursor.bootstrapLog,
                maxBytes: 128_000,
                anchoredAt: steamDirectory,
                required: false
            ))
        ]
        // Resolve each source in its own append order. Steam legitimately emits
        // "Verification complete" before beginning both its win32 and win64
        // update stages, so unordered whole-batch substring arbitration can
        // invert the real lifecycle. The last relevant event in each source is
        // authoritative for that source; a current progress event wins a
        // cross-source completion conflict conservatively.
        let sourceEvents = sources.flatMap { sourceKind, source -> [SteamBootstrapOrderedEvent] in
            guard !source.evidenceUnavailable,
                  let generationCursor = source.nextCursor else { return [] }
            return source.text
                .split(whereSeparator: \.isNewline)
                .enumerated()
                .compactMap { index, line -> SteamBootstrapOrderedEvent? in
                    let normalizedLine = String(line).lowercased()
                    guard let kind = steamBootstrapOrderedEventKind(
                        in: normalizedLine
                    ) else { return nil }
                    return SteamBootstrapOrderedEvent(
                        source: sourceKind,
                        kind: kind,
                        normalizedLine: normalizedLine,
                        sourceURL: source.url,
                        lineIndex: index,
                        generationCursor: generationCursor
                    )
                }
        }
        let lastRelevantEvents = SteamBootstrapUpdaterEvidenceSource.allCases
            .compactMap { source in
                sourceEvents.last { $0.source == source }
            }
        let observedProgress = lastRelevantEvents.contains {
            $0.kind == .progress
        }
        let observedCompletion = !observedProgress && lastRelevantEvents.contains {
            $0.kind == .completion
        }
        let evidenceUnavailable = sources.contains { $0.1.evidenceUnavailable }
        let progressEvents = observedProgress
            ? lastRelevantEvents.filter { $0.kind == .progress }
            : []
        let progressEvidence = progressEvents
            .map(\.identity)
            .joined(separator: "\n")
        let progressIdentity: String? = evidenceUnavailable || progressEvidence.isEmpty
            ? nil
            : SHA256.hash(data: Data(progressEvidence.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        let hasProgress: Bool?
        if evidenceUnavailable {
            hasProgress = nil
        } else {
            hasProgress = observedProgress
        }

        let state: SteamEvidenceReadState
        if sources.contains(where: { $0.1.state == .unsafe }) {
            state = .unsafe
        } else if sources.contains(where: { $0.1.state == .changedDuringRead }) {
            state = .changedDuringRead
        } else if sources.contains(where: { $0.1.state == .unreadable }) {
            state = .unreadable
        } else if sources.contains(where: { $0.1.state == .missing && $0.1.required }) {
            state = .missing
        } else if sources.contains(where: { $0.1.state == .truncated }) {
            state = .truncated
        } else if sources.contains(where: { $0.1.state == .captured }) {
            state = .captured
        } else {
            state = .missing
        }
        let detail = sources.map {
            "\($0.1.url.lastPathComponent)=\($0.1.state.rawValue) (\($0.1.detail))"
        }.joined(separator: "; ")
        return SteamBootstrapUpdateLogAssessment(
            hasProgress: hasProgress,
            state: state,
            detail: detail,
            sources: sources.map { $0.1 },
            progressIdentity: progressIdentity,
            observedProgress: observedProgress,
            observedCompletion: observedCompletion,
            nextCursor: SteamBootstrapUpdateSourceCursor(
                stdout: sources[0].1.nextCursor ?? cursor.stdout,
                bootstrapLog: sources[1].1.nextCursor ?? cursor.bootstrapLog
            ),
            sourceEvents: sourceEvents
        )
    }

    private func steamBootstrapOrderedEventKind(
        in normalizedLine: String
    ) -> SteamBootstrapOrderedEventKind? {
        // "Verification complete" is deliberately absent. Real Steam logs
        // emit it immediately before "업데이트 다운로드 중" for each staged
        // client architecture, so it is a phase boundary rather than terminal
        // updater completion. WebHelper executable text is likewise process
        // diagnostics, not updater completion evidence.
        let completionSignals = [
            "업데이트 완료! steam 실행 중",
            "update complete! launching steam",
            "update complete, launching steam",
            "nothing to do",
            "download skipped"
        ]
        if completionSignals.contains(where: { normalizedLine.contains($0) }) {
            return .completion
        }
        let progressSignals = [
            "업데이트 다운로드 중",
            "사용 가능한 업데이트 확인 중",
            "다운로드 완료",
            "패키지 압축 푸는 중",
            "업데이트 설치 중",
            "설치 확인 중",
            "downloading update",
            "download update",
            "downloading manifest",
            "manifest download:",
            "updating steam",
            "extracting package",
            "installing update",
            "verifying installation"
        ]
        if progressSignals.contains(where: { normalizedLine.contains($0) }) {
            return .progress
        }
        return nil
    }

    /// Captures the Darwin snapshot before awaiting journal validation, then
    /// binds only rows whose PID and kernel start identity both match the exact
    /// current-run journal readback. No append-only Windows creation record is
    /// admitted to this current-liveness boundary.
    private func verifiedCurrentLaunchProcessSnapshot(
        result: ProcessRunResult,
        prefix: URL,
        target _: SteamLaunchTarget
    ) async -> SteamLaunchProcessSnapshot {
        let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(
            for: result.stderrLog
        ).lowercased()
        do {
            let processIdentities =
                try await managedWineLaunchProcessIdentityProvider(
                    prefix,
                    runIdentifier
                )
            let managedSnapshot = managedWineJournalProcessSnapshotProvider(
                processIdentities
            )
            let diagnosticSnapshot = processSnapshotProvider()
            // Generic enumeration remains useful diagnostics, but it cannot
            // create current-run ownership. In particular, the deployed child
            // executable is wine.bin, which is deliberately outside the
            // generic basename filter and is captured through the exact
            // provider identities above instead.
            return managedSnapshot.merging(diagnosticSnapshot)
        } catch {
            let diagnosticSnapshot = processSnapshotProvider()
            return diagnosticSnapshot.reportingManagedWineLaunchVerificationFailure(
                "the exact current-run Managed Wine process identities could not be verified: " +
                    forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    /// Diagnostic/conformance evidence may combine current Darwin liveness
    /// with this launch's append-only Windows creation journal. Lifecycle and
    /// renderer promotion deliberately use `verifiedCurrent...` above instead.
    private func currentSteamLaunchProcessSnapshot(
        result: ProcessRunResult,
        prefix: URL,
        target: SteamLaunchTarget
    ) async -> SteamLaunchProcessSnapshot {
        let currentSnapshot = await verifiedCurrentLaunchProcessSnapshot(
            result: result,
            prefix: prefix,
            target: target
        )
        let sameRunEvidence = SteamLaunchProcessSnapshot.sameRunLaunchEvidence(
                for: result,
                target: target,
                fileManager: fileManager
            )
            .reconcilingProcessCreationEvidence(with: currentSnapshot)
        return currentSnapshot.merging(sameRunEvidence)
    }

    /// Binds log-level renderer evidence to the exact currently observed
    /// Steam client/WebHelper process set. PID-bearing diagnostic lines are
    /// part of the identity, so a process exit/restart cannot inherit the
    /// previous process's completed renderer grace interval.
    private nonisolated static func processBoundRendererObservation(
        _ input: SteamWebHelperStartupObservation,
        snapshot: SteamLaunchProcessSnapshot,
        launchTarget: SteamLaunchTarget
    ) -> SteamWebHelperStartupObservation? {
        guard snapshot.containsVerifiedCurrentRunSteamClientProcess(
            for: launchTarget
        ) else { return nil }
        let allWebHelperProcessLines = snapshot
            .managedWineJournalWebHelperCommandLines(for: launchTarget)
        let rootWebHelperProcessLines = allWebHelperProcessLines.filter {
            !SteamWebHelperLaunchPolicy.isChromiumSubprocessCommandLine($0)
        }.sorted()
        guard !rootWebHelperProcessLines.isEmpty,
              let logAttemptIdentity = input.rendererAttemptIdentity,
              !logAttemptIdentity.isEmpty else { return nil }
        let identityMaterial = ([logAttemptIdentity] + rootWebHelperProcessLines)
            .joined(separator: "\u{0}")
        var output = input
        output.rendererAttemptIdentity = SHA256.hash(
            data: Data(identityMaterial.utf8)
        )
            .map { String(format: "%02x", $0) }
            .joined()
        return output
    }

    /// Production UI startup wait with renderer grace bound to both the
    /// newest log epoch and the exact current process identities. The reporter
    /// retains an unscoped wait for focused log tests; product admission uses
    /// this process-scoped path.
    private func waitForSteamWebHelperStartupWithProcessLiveness(
        result: ProcessRunResult,
        prefix: URL,
        in steamDirectory: URL,
        since logCursor: SteamWebHelperStartupLogCursor,
        launchTarget: SteamLaunchTarget,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async -> SteamWebHelperStartupObservation {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let boundedPollInterval = max(0.1, pollInterval)
        let rendererStabilizationInterval = min(
            Self.steamUIProvisionalSurfaceStabilizationInterval,
            max(0.25, max(0, timeout) / 2)
        )
        var rendererStabilization =
            SteamWebHelperRendererStabilizationTracker()
        while !Task.isCancelled && Date() < deadline {
            var observation = steamLaunchDiagnosticsReporter
                .detectSteamWebHelperStartup(
                    in: steamDirectory,
                    since: logCursor
                )
            if observation.state == .provisionalSurface {
                let snapshot = await verifiedCurrentLaunchProcessSnapshot(
                    result: result,
                    prefix: prefix,
                    target: launchTarget
                )
                if let processBoundObservation =
                    Self.processBoundRendererObservation(
                        observation,
                        snapshot: snapshot,
                        launchTarget: launchTarget
                    ) {
                    if rendererStabilization.observePositiveRenderer(
                        in: processBoundObservation,
                        at: Date(),
                        requiredInterval: rendererStabilizationInterval
                    ) {
                        observation.state = .ready
                        observation.usableUIReadiness =
                            observation.provisionalSurfaceReadiness
                        return observation
                    }
                } else {
                    rendererStabilization.reset()
                }
            } else {
                rendererStabilization.reset()
                if observation.state != .pending { return observation }
            }
            do {
                try await Task.sleep(for: .seconds(boundedPollInterval))
            } catch {
                break
            }
        }
        var observation = steamLaunchDiagnosticsReporter
            .detectSteamWebHelperStartup(
                in: steamDirectory,
                since: logCursor
            )
        if observation.state == .pending ||
            observation.state == .provisionalSurface {
            observation.state = .timedOut
        }
        return observation
    }

    private func observeSteamUIStartup(
        result: ProcessRunResult,
        prefix: URL,
        steamDirectory: URL,
        launchTarget: SteamLaunchTarget,
        logCursor: SteamWebHelperStartupLogCursor
    ) async -> SteamWebHelperStartupObservation {
        guard result.succeeded,
              SteamLaunchDispatchDisposition.resolve(result)
                .acceptsSessionLifetime,
              steamUIStartupObservationTimeout > 0 else {
            return SteamWebHelperStartupObservation(
                state: .timedOut,
                reason: nil,
                steamUIHTMLTail: [],
                consoleTail: [],
                webHelperTail: []
            )
        }

        func validatingCurrentSurfaceProcessLiveness(
            _ input: SteamWebHelperStartupObservation
        ) async -> SteamWebHelperStartupObservation {
            guard input.state == .ready else { return input }
            let snapshot = await verifiedCurrentLaunchProcessSnapshot(
                result: result,
                prefix: prefix,
                target: launchTarget
            )
            guard snapshot.containsVerifiedCurrentRunSteamClientProcess(
                for: launchTarget
            ), !snapshot.managedWineJournalWebHelperCommandLines(
                for: launchTarget
            ).isEmpty else {
                var observation = input
                observation.state = .retryableFailure
                observation.reason =
                    "Steam exposed provisional UI evidence, but the current expected Steam/WebHelper processes were not both live at promotion"
                return observation
            }
            return input
        }

        return await validatingCurrentSurfaceProcessLiveness(
            await waitForSteamWebHelperStartupWithProcessLiveness(
                result: result,
                prefix: prefix,
                in: steamDirectory,
                since: logCursor,
                launchTarget: launchTarget,
                timeout: steamUIStartupObservationTimeout,
                pollInterval: steamUIStartupObservationPollInterval
            )
        )
    }

    func bootstrapUpdateSourceCursor(
        from launchCursor: SteamWebHelperStartupLogCursor
    ) -> SteamBootstrapUpdateSourceCursor {
        SteamBootstrapUpdateSourceCursor(
            stdout: SteamLogFileCursor(
                byteCount: 0,
                fileNumber: nil,
                deviceNumber: nil,
                modificationDate: nil,
                trailingSignature: Data(),
                endsAtLineBoundary: true,
                captureState: .missing,
                captureDetail: "per-launch stdout did not exist before dispatch"
            ),
            bootstrapLog: launchCursor.bootstrapLog
        )
    }

    /// Reads only the exact bytes appended after `cursor`. Monotonic appends
    /// beyond the initially opened byte window are permitted; replacement,
    /// truncation, device/inode changes, mutation inside that exact window, and
    /// a delta larger than the bound return no text and cannot advance updater
    /// progress.
    private func secureAppendedBootstrapEvidence(
        from url: URL,
        since cursor: SteamLogFileCursor,
        maxBytes: Int,
        anchoredAt root: URL,
        required: Bool
    ) -> SteamBootstrapLogSourceAssessment {
        guard ![SteamEvidenceReadState.unsafe, .unreadable, .changedDuringRead]
            .contains(cursor.captureState) else {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: cursor.captureState,
                detail: "launch cursor was not safely captured: \(cursor.captureDetail ?? "no detail")",
                text: ""
            )
        }
        let boundedMaxBytes = max(maxBytes, 0)
        guard boundedMaxBytes > 0 else {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .unreadable,
                detail: "zero-byte append bound cannot establish updater progress",
                text: ""
            )
        }

        let descriptor: Int32
        let metadata: BootstrapEvidenceFileMetadata
        switch openBootstrapEvidenceFile(at: url, anchoredAt: root) {
        case .failed(let state, let detail):
            if state == .missing, cursor.captureState == .missing {
                return SteamBootstrapLogSourceAssessment(
                    url: url,
                    required: required,
                    state: .missing,
                    detail: detail,
                    text: "",
                    nextCursor: cursor
                )
            }
            if state == .missing {
                return SteamBootstrapLogSourceAssessment(
                    url: url,
                    required: required,
                    state: .changedDuringRead,
                    detail: "captured updater evidence disappeared or rotated after the launch cursor: \(detail)",
                    text: ""
                )
            }
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: state,
                detail: detail,
                text: ""
            )
        case .opened(let openedDescriptor, let openedMetadata):
            descriptor = openedDescriptor
            metadata = openedMetadata
        }
        defer { Darwin.close(descriptor) }

        let appendOffset: UInt64
        if cursor.captureState == .missing {
            appendOffset = 0
        } else {
            guard cursor.captureState == .captured,
                  cursor.deviceNumber == metadata.deviceNumber,
                  cursor.fileNumber == metadata.fileNumber,
                  metadata.byteCount >= cursor.byteCount else {
                return SteamBootstrapLogSourceAssessment(
                    url: url,
                    required: required,
                    state: .changedDuringRead,
                    detail: "updater evidence generation was replaced or truncated after the launch cursor",
                    text: ""
                )
            }
            guard bootstrapEvidenceContainsTrailingSignature(
                descriptor: descriptor,
                cursor: cursor
            ) else {
                return SteamBootstrapLogSourceAssessment(
                    url: url,
                    required: required,
                    state: .changedDuringRead,
                    detail: "updater evidence bytes preceding the append offset changed",
                    text: ""
                )
            }
            appendOffset = cursor.byteCount
        }

        let appendedByteCount = metadata.byteCount - appendOffset
        guard appendedByteCount <= UInt64(boundedMaxBytes) else {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .truncated,
                detail: "appended updater evidence exceeded the \(boundedMaxBytes)-byte monotonic-read bound",
                text: ""
            )
        }
        let data: Data
        do {
            data = try readBootstrapEvidenceBytes(
                descriptor: descriptor,
                offset: appendOffset,
                count: Int(appendedByteCount)
            )
        } catch {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .unreadable,
                detail: "bounded append read failed: \(forgePlayTechnicalErrorSummary(error))",
                text: ""
            )
        }
        let postReadMetadata = bootstrapEvidenceMetadata(
            descriptor: descriptor
        )
        let rereadData: Data
        do {
            rereadData = try readBootstrapEvidenceBytes(
                descriptor: descriptor,
                offset: appendOffset,
                count: Int(appendedByteCount)
            )
        } catch {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .unreadable,
                detail: "bounded append verification read failed: \(forgePlayTechnicalErrorSummary(error))",
                text: ""
            )
        }
        let postRereadMetadata = bootstrapEvidenceMetadata(
            descriptor: descriptor
        )
        guard data.count == Int(appendedByteCount),
              rereadData.count == Int(appendedByteCount),
              Self.bootstrapEvidenceReadWindowIsStable(
                initialMetadata: metadata,
                postReadMetadata: postReadMetadata,
                postRereadMetadata: postRereadMetadata,
                capturedData: data,
                rereadData: rereadData
              ),
              bootstrapEvidenceContainsTrailingSignature(
                descriptor: descriptor,
                cursor: cursor
              ) else {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .changedDuringRead,
                detail: "updater evidence was replaced, truncated, or mutated inside the stable bounded read window",
                text: ""
            )
        }
        let consumedByteCount: UInt64
        let consumedData: Data
        if cursor.endsAtLineBoundary {
            if let finalNewline = data.lastIndex(of: 0x0A) {
                let count = data.distance(
                    from: data.startIndex,
                    to: data.index(after: finalNewline)
                )
                consumedByteCount = UInt64(count)
                consumedData = Data(data.prefix(count))
            } else {
                consumedByteCount = 0
                consumedData = Data()
            }
        } else if let baselineContinuationNewline = data.firstIndex(of: 0x0A) {
            // The row began before dispatch. Consume its post-launch suffix so
            // it is discarded exactly once, then attribute only complete rows
            // that begin after that newline to this launch.
            let firstLaunchRow = data.index(after: baselineContinuationNewline)
            let launchData = data[firstLaunchRow...]
            if let finalNewline = launchData.lastIndex(of: 0x0A) {
                let count = data.distance(
                    from: data.startIndex,
                    to: data.index(after: finalNewline)
                )
                consumedByteCount = UInt64(count)
                consumedData = Data(data[firstLaunchRow...finalNewline])
            } else {
                let count = data.distance(
                    from: data.startIndex,
                    to: firstLaunchRow
                )
                consumedByteCount = UInt64(count)
                consumedData = Data()
            }
        } else {
            consumedByteCount = 0
            consumedData = Data()
        }
        let nextByteCount = appendOffset + consumedByteCount
        let signature: Data
        do {
            signature = try bootstrapEvidenceTrailingSignature(
                descriptor: descriptor,
                byteCount: nextByteCount
            )
        } catch {
            return SteamBootstrapLogSourceAssessment(
                url: url,
                required: required,
                state: .unreadable,
                detail: "could not capture the next updater evidence generation",
                text: ""
            )
        }
        let nextCursor = SteamLogFileCursor(
            byteCount: nextByteCount,
            fileNumber: metadata.fileNumber,
            deviceNumber: metadata.deviceNumber,
            modificationDate: metadata.modificationDate,
            trailingSignature: signature,
            endsAtLineBoundary:
                consumedByteCount > 0 ? true : cursor.endsAtLineBoundary,
            captureState: .captured,
            captureDetail: "exact updater append generation captured"
        )
        return SteamBootstrapLogSourceAssessment(
            url: url,
            required: required,
            state: .captured,
            detail: "captured \(consumedByteCount) complete-line byte(s) appended after the exact source cursor",
            text: String(decoding: consumedData, as: UTF8.self),
            nextCursor: nextCursor
        )
    }

    private func bootstrapEvidenceTrailingSignature(
        descriptor: Int32,
        byteCount: UInt64
    ) throws -> Data {
        guard byteCount > 0 else { return Data() }
        let length = min(byteCount, 64)
        return try readBootstrapEvidenceBytes(
            descriptor: descriptor,
            offset: byteCount - length,
            count: Int(length)
        )
    }

    private func bootstrapEvidenceContainsTrailingSignature(
        descriptor: Int32,
        cursor: SteamLogFileCursor
    ) -> Bool {
        guard !cursor.trailingSignature.isEmpty else {
            return cursor.byteCount == 0
        }
        guard cursor.byteCount >= UInt64(cursor.trailingSignature.count),
              let data = try? readBootstrapEvidenceBytes(
                descriptor: descriptor,
                offset: cursor.byteCount - UInt64(cursor.trailingSignature.count),
                count: cursor.trailingSignature.count
              ) else { return false }
        return data == cursor.trailingSignature
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
            let containsExpectedPrefixSteam = verificationMode == .operational
                ? snapshot.containsVerifiedCurrentRunSteamProcess(for: target)
                : snapshot.containsExpectedPrefixSteamProcess(for: target)
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
            if verificationMode == .conformance {
                snapshot = await currentSteamLaunchProcessSnapshot(
                    result: result,
                    prefix: target.expectedPrefixPath,
                    target: target
                )
            } else {
                snapshot = await verifiedCurrentLaunchProcessSnapshot(
                    result: result,
                    prefix: target.expectedPrefixPath,
                    target: target
                )
            }
        }
        return snapshot
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
                "Steam UI startup did not reach a usable surface during the bounded observation: \(steamUIStartupFailure)"
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
                    "Steam WebHelper same-run command line must contain \(SteamWebHelperLaunchPolicy.requiredArguments.joined(separator: ", "))"
                )
            }
            if !screenEvidence.verifiesWindowsSteamUI {
                append(.failedVisibleUINotVerified, "screen-final.png visual evidence did not verify Windows Steam login, Steam Guard, or Library UI: \(screenEvidence.message)")
            }
        } else {
            if !after.containsExpectedRunnerProcess(for: target) {
                details.append("operational same-run launch evidence did not observe the runner")
            }
            if !after.containsVerifiedCurrentRunSteamProcess(for: target) {
                append(
                    .operationalProcessEvidenceUnavailable,
                    "operational launch did not observe steam.exe or steamwebhelper.exe in the expected WINEPREFIX before the bounded process-evidence deadline"
                )
            }
            if after.managedWineJournalWebHelperCommandLines(
                for: target
            ).isEmpty {
                details.append("operational same-run launch evidence did not capture Steam WebHelper; UI verification remains pending")
            } else if !after
                .managedWineJournalWebHelperCommandLinesContainRequiredLaunchPolicy(
                    for: target
                ) {
                details.append("operational Steam WebHelper evidence is missing the executable-scoped CEF compatibility arguments; UI verification remains pending")
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
    case managedWineJournal

    var processIdentifierNamespace: SteamLaunchProcessIdentifierNamespace {
        switch self {
        case .systemSnapshot, .runnerLaunch, .managedWineJournal:
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
    var processStartedAtUnixMicroseconds: UInt64?

    init(
        processID: Int32,
        command: String,
        evidenceSource: SteamLaunchProcessEvidenceSource = .systemSnapshot,
        processStartedAtUnixMicroseconds: UInt64? = nil
    ) {
        self.processID = processID
        self.command = command
        self.evidenceSource = evidenceSource
        self.processStartedAtUnixMicroseconds =
            processStartedAtUnixMicroseconds
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
        var identityFailureCount = 0
        for processID in processIDs {
            let startIdentityBeforeRead = ManagedWineProcessJournal
                .processStartTimeUnixMicroseconds(for: processID)
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
            let startIdentityAfterRead = ManagedWineProcessJournal
                .processStartTimeUnixMicroseconds(for: processID)
            guard let startIdentityBeforeRead,
                  startIdentityBeforeRead == startIdentityAfterRead else {
                identityFailureCount += 1
                continue
            }
            processes.append(SteamLaunchObservedProcess(
                processID: processID,
                command: diagnosticCommandLine(
                    executablePath: executablePath,
                    processArguments: processArguments
                ),
                processStartedAtUnixMicroseconds: startIdentityBeforeRead
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
        if identityFailureCount > 0 {
            issues.append(.init(
                code: .systemProcessIdentityReadFailed,
                affectedRecordCount: identityFailureCount,
                detail: "one or more relevant process rows changed identity while being inspected and were discarded"
            ))
        }
        return DarwinProcessSnapshotReadResult(
            processes: processes,
            state: issues.isEmpty ? .complete : .recovered,
            issues: issues
        )
    }

    /// Captures only the exact process identities already admitted by the
    /// managed Wine journal. Unlike the generic diagnostic snapshot, this path
    /// does not filter by executable basename: the provider's validated
    /// executable object is the allowlist boundary. PID, kernel start identity,
    /// executable path, arguments, and the same kernel start identity after the
    /// read must all agree before a current-lifecycle row is synthesized.
    static func currentManagedWineJournalProcesses(
        _ identities: Set<ManagedWineLaunchProcessIdentity>
    ) -> DarwinProcessSnapshotReadResult {
        currentManagedWineJournalProcesses(
            identities,
            processStartTimeProvider: {
                ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                    for: $0
                )
            },
            executablePathProvider: { executablePath(for: $0) },
            processArgumentsProvider: { arguments(for: $0) }
        )
    }

    static func currentManagedWineJournalProcesses(
        _ identities: Set<ManagedWineLaunchProcessIdentity>,
        processStartTimeProvider: (pid_t) -> UInt64?,
        executablePathProvider: (pid_t) -> String?,
        processArgumentsProvider: (pid_t) -> DarwinProcessArguments?
    ) -> DarwinProcessSnapshotReadResult {
        var processes: [SteamLaunchObservedProcess] = []
        var issues: [SteamProcessObservationReadIssue] = []
        for identity in identities.sorted(by: {
            if $0.processID != $1.processID {
                return $0.processID < $1.processID
            }
            if $0.processStartedAtUnixMicroseconds !=
                $1.processStartedAtUnixMicroseconds {
                return $0.processStartedAtUnixMicroseconds <
                    $1.processStartedAtUnixMicroseconds
            }
            return $0.executableURL.path < $1.executableURL.path
        }) {
            let processID = pid_t(identity.processID)
            guard processStartTimeProvider(processID) ==
                    identity.processStartedAtUnixMicroseconds else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) no longer has its verified kernel start identity"
                ))
                continue
            }
            guard let executablePath = executablePathProvider(processID) else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) executable path could not be read"
                ))
                continue
            }
            let observedExecutableURL = URL(fileURLWithPath: executablePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let expectedExecutableURL = identity.executableURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard observedExecutableURL == expectedExecutableURL else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) executable changed after journal verification"
                ))
                continue
            }
            guard let processArguments = processArgumentsProvider(processID)
            else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) arguments could not be read"
                ))
                continue
            }
            guard let executablePathAfterArguments =
                    executablePathProvider(processID) else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) executable path could not be re-read after its arguments"
                ))
                continue
            }
            let observedExecutableURLAfterArguments = URL(
                fileURLWithPath: executablePathAfterArguments
            )
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard observedExecutableURLAfterArguments == expectedExecutableURL
            else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) executable changed while its arguments were captured"
                ))
                continue
            }
            guard processStartTimeProvider(processID) ==
                    identity.processStartedAtUnixMicroseconds else {
                issues.append(.init(
                    code: .managedWineLaunchProcessVerificationFailed,
                    affectedRecordCount: 1,
                    detail: "managed Wine PID \(identity.processID) changed identity while its command was captured"
                ))
                continue
            }
            processes.append(SteamLaunchObservedProcess(
                processID: identity.processID,
                command: diagnosticCommandLine(
                    executablePath: executablePath,
                    processArguments: processArguments
                ),
                evidenceSource: .managedWineJournal,
                processStartedAtUnixMicroseconds:
                    identity.processStartedAtUnixMicroseconds
            ))
        }
        let state: SteamProcessObservationReadState
        if issues.isEmpty {
            state = .complete
        } else if processes.isEmpty {
            state = .unavailable
        } else {
            state = .recovered
        }
        return DarwinProcessSnapshotReadResult(
            processes: processes,
            state: state,
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

    private static func executablePath(for processID: pid_t) -> String? {
        guard case .success(let path) = executablePathResult(for: processID)
        else { return nil }
        return path
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

struct SteamGameRendererBaseHelperObservation: Sendable, Hashable {
    var recordSequence: Int
    var processID: Int32
    var route: String
    var reason: String
    var executable: String
}

enum SteamD3DMetalNVAPIBootstrapState: String, Sendable, Hashable {
    case initialized
    case failed
}

struct SteamD3DMetalNVAPIBootstrapObservation: Sendable, Hashable {
    var recordSequence: Int
    var processID: Int32
    var state: SteamD3DMetalNVAPIBootstrapState
    var module: String
    var loadStatus: UInt32
    var procedureStatus: UInt32
    var exceptionStatus: UInt32
    var initializeResult: Int32

    var diagnosticDescription: String {
        "state=\(state.rawValue); module=\(module); " +
            "load-status=\(Self.statusHex(loadStatus)); " +
            "procedure-status=\(Self.statusHex(procedureStatus)); " +
            "exception-status=\(Self.statusHex(exceptionStatus)); " +
            "initialize-result=\(initializeResult)"
    }

    private static func statusHex(_ status: UInt32) -> String {
        String(format: "0x%08X", status)
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
    case systemProcessIdentityReadFailed
    case managedWineLaunchProcessVerificationFailed
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
    var gameRendererBaseHelpers: [SteamGameRendererBaseHelperObservation] = []
    var d3dMetalNVAPIBootstraps: [SteamD3DMetalNVAPIBootstrapObservation] = []
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
    private static let gameRendererBaseHelperRecordPrefix =
        "FORGEPLAY_GAME_RENDERER_BASE_HELPER_V1"
    private static let d3dMetalNVAPIBootstrapRecordPrefix =
        "FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP_V1"
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
        "nvapi.dll",
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

    static func gameRendererBaseHelpers(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamGameRendererBaseHelperObservation] {
        read(at: url, fileManager: fileManager).gameRendererBaseHelpers
    }

    static func d3dMetalNVAPIBootstraps(
        at url: URL?,
        fileManager: FileManager = .default
    ) -> [SteamD3DMetalNVAPIBootstrapObservation] {
        read(at: url, fileManager: fileManager).d3dMetalNVAPIBootstraps
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

    static func parseGameRendererBaseHelpers(
        _ data: Data
    ) -> [SteamGameRendererBaseHelperObservation] {
        parseResult(data).gameRendererBaseHelpers
    }

    static func parseD3DMetalNVAPIBootstraps(
        _ data: Data
    ) -> [SteamD3DMetalNVAPIBootstrapObservation] {
        parseResult(data).d3dMetalNVAPIBootstraps
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
        var rendererBaseHelpers: [SteamGameRendererBaseHelperObservation] = []
        var nvapiBootstraps: [SteamD3DMetalNVAPIBootstrapObservation] = []
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
            } else if fields[0] == gameRendererBaseHelperRecordPrefix {
                let payload = String(fields[2])
                let components = payload.components(separatedBy: " | ")
                guard components.count >= 3,
                      payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: {
                          $0.value < 0x20
                      }),
                      let route = value(
                        in: components[0],
                        after: "route="
                      ),
                      route == "base-runtime",
                      let reason = value(
                        in: components[1],
                        after: "reason="
                      ),
                      reason == "host-owned-exact-suffix-rule" else {
                    malformedCount += 1
                    continue
                }
                let executable = components.dropFirst(2)
                    .joined(separator: " | ")
                guard !executable.isEmpty else {
                    malformedCount += 1
                    continue
                }
                rendererBaseHelpers.append(
                    SteamGameRendererBaseHelperObservation(
                        recordSequence: recordSequence,
                        processID: processID,
                        route: route,
                        reason: reason,
                        executable: executable
                    )
                )
            } else if fields[0] == d3dMetalNVAPIBootstrapRecordPrefix {
                let payload = String(fields[2])
                let components = payload.components(separatedBy: " | ")
                guard components.count == 6,
                      payload.utf8.count <= maximumCommandSize,
                      !payload.unicodeScalars.contains(where: {
                          $0.value < 0x20
                      }),
                      let stateText = value(
                        in: components[0],
                        after: "state="
                      ),
                      let state = SteamD3DMetalNVAPIBootstrapState(
                        rawValue: stateText
                      ),
                      let module = value(
                        in: components[1],
                        after: "module="
                      )?.lowercased(),
                      module == "nvapi64.dll",
                      let loadStatus = hexadecimalStatus(
                        in: components[2],
                        after: "load-status=0x"
                      ),
                      let procedureStatus = hexadecimalStatus(
                        in: components[3],
                        after: "procedure-status=0x"
                      ),
                      let exceptionStatus = hexadecimalStatus(
                        in: components[4],
                        after: "exception-status=0x"
                      ),
                      let initializeResultText = value(
                        in: components[5],
                        after: "initialize-result="
                      ),
                      let initializeResult = Int32(
                        initializeResultText
                      ) else {
                    malformedCount += 1
                    continue
                }
                let initialized = loadStatus == 0 &&
                    procedureStatus == 0 &&
                    exceptionStatus == 0 &&
                    initializeResult == 0
                guard (state == .initialized) == initialized else {
                    malformedCount += 1
                    continue
                }
                nvapiBootstraps.append(
                    SteamD3DMetalNVAPIBootstrapObservation(
                        recordSequence: recordSequence,
                        processID: processID,
                        state: state,
                        module: module,
                        loadStatus: loadStatus,
                        procedureStatus: procedureStatus,
                        exceptionStatus: exceptionStatus,
                        initializeResult: initializeResult
                    )
                )
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
            gameRendererBaseHelpers: rendererBaseHelpers,
            d3dMetalNVAPIBootstraps: nvapiBootstraps,
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

    private static func hexadecimalStatus(
        in component: String,
        after prefix: String
    ) -> UInt32? {
        guard let text = value(in: component, after: prefix),
              text.count == 8,
              text.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return UInt32(text, radix: 16)
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
        let nvapiBootstraps = rendererObservation.map {
            correlatedD3DMetalNVAPIBootstraps(
                for: $0,
                in: processObservation
            )
        } ?? []
        let baseHelperEvidence = correlatedBaseHelperEvidence(
            in: processObservation,
            trackedCommandsByProcessID: trackedCommandsByProcessID
        )
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
        evidence.append(contentsOf: nvapiBootstraps.suffix(8).map {
            "FORGEPLAY D3DMetal NVAPI bootstrap: pid=\($0.processID); " +
                $0.diagnosticDescription
        })
        evidence.append(contentsOf: baseHelperEvidence.suffix(16))
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
                unverifiedRendererModuleLoads.isEmpty &&
                nvapiBootstraps.allSatisfy { $0.state == .initialized }
                ? nil
                : failedRendererModuleLoads.map {
                    "\($0.module)=\($0.statusHex)"
                } + unverifiedRendererModuleLoads.map {
                    "\($0.module)=load-path-\($0.pathOwnership.rawValue):" +
                        "\($0.actualPath ?? "unavailable")"
                } + nvapiBootstraps.compactMap {
                    guard $0.state == .failed else { return nil }
                    return "nvapi-bootstrap=\($0.diagnosticDescription)"
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

    /// NVAPI initializes before the game entry point and therefore before the
    /// parent commits the matching route record. Bind it to the uniquely
    /// nearest route for the same Wine PID so PID reuse cannot move bootstrap
    /// evidence between launch attempts.
    private static func correlatedD3DMetalNVAPIBootstraps(
        for route: SteamGameRendererObservation,
        in observation: SteamProcessObservationReadResult
    ) -> [SteamD3DMetalNVAPIBootstrapObservation] {
        let sameProcessRoutes = observation.gameRendererObservations.filter {
            $0.processID == route.processID
        }
        return observation.d3dMetalNVAPIBootstraps.filter { bootstrap in
            guard bootstrap.processID == route.processID else {
                return false
            }
            let distances = sameProcessRoutes.map {
                abs($0.recordSequence - bootstrap.recordSequence)
            }
            guard let nearestDistance = distances.min() else {
                return false
            }
            let nearestRoutes = sameProcessRoutes.filter {
                abs($0.recordSequence - bootstrap.recordSequence) ==
                    nearestDistance
            }
            return nearestRoutes.count == 1 &&
                nearestRoutes[0].recordSequence == route.recordSequence
        }
        .sorted { $0.recordSequence < $1.recordSequence }
    }

    private static func correlatedBaseHelperEvidence(
        in observation: SteamProcessObservationReadResult,
        trackedCommandsByProcessID: [Int32: String]
    ) -> [String] {
        observation.gameRendererBaseHelpers
            .filter { helper in
                trackedCommandsByProcessID.values.contains {
                    self.trackedCommand(
                        $0,
                        matchesExecutable: helper.executable
                    )
                }
            }
            .sorted { $0.recordSequence < $1.recordSequence }
            .map {
                "FORGEPLAY base-runtime helper: pid=\($0.processID); " +
                    "route=\($0.route); reason=\($0.reason); " +
                    "executable=\($0.executable)"
            }
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

    static func currentManagedWineJournalProcesses(
        _ identities: Set<ManagedWineLaunchProcessIdentity>
    ) -> SteamLaunchProcessSnapshot {
        let snapshot = DarwinProcessSnapshotReader
            .currentManagedWineJournalProcesses(identities)
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

    /// Correlates a previously captured Darwin process snapshot with exact,
    /// current-run Managed Wine journal identities. Both PID and kernel start
    /// identity must intersect; no process is synthesized and no command-name
    /// match can create ownership by itself.
    func bindingManagedWineJournalProcessIdentities(
        _ verifiedProcessIdentities: Set<ManagedWineLaunchProcessIdentity>
    ) -> SteamLaunchProcessSnapshot {
        guard !verifiedProcessIdentities.isEmpty else { return self }
        return SteamLaunchProcessSnapshot(
            processes: processes.map { process in
                guard process.evidenceSource == .systemSnapshot,
                      let processStartedAtUnixMicroseconds =
                        process.processStartedAtUnixMicroseconds,
                      verifiedProcessIdentities.contains(where: {
                        $0.processID == process.processID &&
                            $0.processStartedAtUnixMicroseconds ==
                                processStartedAtUnixMicroseconds
                      }) else {
                    return process
                }
                return SteamLaunchObservedProcess(
                    processID: process.processID,
                    command: process.command,
                    evidenceSource: .managedWineJournal,
                    processStartedAtUnixMicroseconds:
                        processStartedAtUnixMicroseconds
                )
            },
            processObservationReadState: processObservationReadState,
            processObservationReadIssues: processObservationReadIssues
        )
    }

    func reportingManagedWineLaunchVerificationFailure(
        _ detail: String
    ) -> SteamLaunchProcessSnapshot {
        var issues = processObservationReadIssues
        issues.append(SteamProcessObservationReadIssue(
            code: .managedWineLaunchProcessVerificationFailed,
            affectedRecordCount: 1,
            detail: detail
        ))
        return SteamLaunchProcessSnapshot(
            processes: processes,
            processObservationReadState: .unavailable,
            processObservationReadIssues: issues
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

    /// Process-lifecycle proof for the Steam client/updater itself. WebHelper
    /// children intentionally do not satisfy this predicate: an old bootstrap
    /// progress line plus a hung WebHelper must not keep updater observation or
    /// a deferred launch alive after `steam.exe` has exited.
    func containsExpectedPrefixSteamClientProcess(
        for target: SteamLaunchTarget
    ) -> Bool {
        let clientOnlySnapshot = SteamLaunchProcessSnapshot(
            processes: processes.filter { process in
                let command = Self.normalizedCommand(process.command)
                return command.contains("steam.exe") &&
                    !command.contains("steamwebhelper.exe")
            },
            processObservationReadState: processObservationReadState,
            processObservationReadIssues: processObservationReadIssues
        )
        return clientOnlySnapshot.containsExpectedPrefixSteamProcess(
            for: target
        )
    }

    /// Lifecycle proof for the exact current launch. A same-prefix process
    /// from an older or external session may remain visible in the system
    /// snapshot, but it cannot extend updater waits or authorize recovery.
    func containsVerifiedCurrentRunSteamClientProcess(
        for target: SteamLaunchTarget
    ) -> Bool {
        SteamLaunchProcessSnapshot(
            processes: processes.filter {
                $0.evidenceSource == .managedWineJournal
            },
            processObservationReadState: processObservationReadState,
            processObservationReadIssues: processObservationReadIssues
        ).containsExpectedPrefixSteamClientProcess(for: target)
    }

    func containsVerifiedCurrentRunSteamProcess(
        for target: SteamLaunchTarget
    ) -> Bool {
        SteamLaunchProcessSnapshot(
            processes: processes.filter {
                $0.evidenceSource == .managedWineJournal
            },
            processObservationReadState: processObservationReadState,
            processObservationReadIssues: processObservationReadIssues
        ).containsExpectedPrefixSteamProcess(for: target)
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

    /// Current WebHelper liveness admitted by the exact current-run Managed
    /// Wine journal. Append-only Windows creation records and unbound system
    /// rows are intentionally excluded from renderer/UI promotion.
    func managedWineJournalWebHelperCommandLines(
        for target: SteamLaunchTarget
    ) -> [String] {
        SteamLaunchProcessSnapshot(
            processes: processes.filter {
                $0.evidenceSource == .managedWineJournal
            },
            processObservationReadState: processObservationReadState,
            processObservationReadIssues: processObservationReadIssues
        ).webHelperCommandLines(for: target)
    }

    func managedWineJournalWebHelperCommandLinesContainRequiredLaunchPolicy(
        for target: SteamLaunchTarget
    ) -> Bool {
        let rootCommandLines = managedWineJournalWebHelperCommandLines(
            for: target
        ).filter {
            !SteamWebHelperLaunchPolicy.isChromiumSubprocessCommandLine($0)
        }
        return !rootCommandLines.isEmpty && rootCommandLines.allSatisfy {
            SteamWebHelperLaunchPolicy.rootCommandLineContainsRequiredArguments($0)
        }
    }

    func webHelperCommandLinesContainRequiredLaunchPolicy(for target: SteamLaunchTarget) -> Bool {
        let rootCommandLines = webHelperCommandLines(for: target).filter {
            !SteamWebHelperLaunchPolicy.isChromiumSubprocessCommandLine($0)
        }
        return !rootCommandLines.isEmpty && rootCommandLines.allSatisfy {
            SteamWebHelperLaunchPolicy.rootCommandLineContainsRequiredArguments($0)
        }
    }

    /// Assesses only WebHelper commands attributable to this snapshot's target.
    /// Callers that require same-launch proof must construct the snapshot from
    /// the current launch's process-creation journal (directly or through
    /// `sameRunLaunchEvidence`); a broad system snapshot is not a session token.
    func webHelperLanguageReadback(
        for target: SteamLaunchTarget,
        expected language: SteamClientLanguage
    ) -> SteamWebHelperLanguageReadback {
        let commandLines = webHelperCommandLines(for: target)
        var observedLocaleIdentifiers: [String] = []
        var seen = Set<String>()
        for locale in commandLines.flatMap({
            SteamWebHelperLaunchPolicy.observedLanguageLocaleIdentifiers(in: $0)
        }) {
            let identity = locale.lowercased()
            if seen.insert(identity).inserted {
                observedLocaleIdentifiers.append(locale)
            }
        }

        guard !observedLocaleIdentifiers.isEmpty else {
            return SteamWebHelperLanguageReadback(
                state: processObservationReadState == .complete
                    ? .pending
                    : .evidenceUnavailable,
                observedLocaleIdentifiers: []
            )
        }
        let expectedLocale = SteamWebHelperLaunchPolicy
            .normalizedLanguageLocaleIdentifier(
                language.webHelperLocaleIdentifier
            )
        let allMatch = expectedLocale != nil &&
            observedLocaleIdentifiers.allSatisfy {
                SteamWebHelperLaunchPolicy
                    .normalizedLanguageLocaleIdentifier($0) == expectedLocale
            }
        return SteamWebHelperLanguageReadback(
            state: allMatch ? .matched : .mismatched,
            observedLocaleIdentifiers: observedLocaleIdentifiers
        )
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
        guard evidenceSource == .processCreationObservation ||
                evidenceSource == .managedWineJournal else {
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
