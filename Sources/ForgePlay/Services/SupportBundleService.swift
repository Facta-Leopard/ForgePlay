// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import CryptoKit
import Darwin
import Foundation

private let supportBundleMaximumCollectionIssues = 1_000

/// `FileManager` is documented for concurrent use, but its Sendable annotation
/// is not available on every deployment SDK supported by this project. The
/// support service awaits the read-only identity task before reusing this
/// reference, so this sendability boundary makes that transfer explicit without silently
/// replacing an injected manager with `FileManager.default`.
private struct SupportBundleFileManagerReference: @unchecked Sendable {
    let value: FileManager
}

enum SupportBundleServiceError: LocalizedError {
    case rootMissing
    case archiveFailed(ProcessRunResult)
    case archiveCleanupFailed(destination: URL, processResult: ProcessRunResult, cleanupError: Error)
    case archiveValidationFailed(URL, String)
    case scanFailed(URL, Error)
    case metadataReadFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .rootMissing:
            "지원 번들을 만들 저장 위치가 아직 없습니다."
        case .archiveFailed(let result):
            "지원 번들 압축 파일을 만들지 못했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
        case .archiveCleanupFailed(let destination, let result, let cleanupError):
            "지원 번들 압축 파일을 만들지 못했고 부분 파일을 정리하지 못했습니다: \(destination.path). 로그: \(result.stderrLog.path). 정리 오류: \(forgePlayTechnicalErrorSummary(cleanupError))"
        case .archiveValidationFailed(let url, let message):
            "지원 번들 압축 결과를 검증하지 못했습니다: \(url.path). \(message)"
        case .scanFailed(let url, let error):
            "지원 번들 자료 폴더를 검사하지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .metadataReadFailed(let url, let error):
            "지원 번들 자료 파일을 읽지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        }
    }
}

struct SupportBundleDiagnosticRecordSummary: Codable, Hashable, Sendable {
    var recordIdentifier: String
    var gameID: String?
    var launchRecordIdentifier: String?
    var source: String
    var createdAt: Date
    var decodeStatus: String
    var resultIdentifier: String?
    var decodeError: String?
}

/// User-confirmed context for the concrete problem that motivated a support
/// bundle. Launch evidence explains what ForgePlay observed; this context
/// explains what the user expected and actually saw.
struct SupportIncidentContext: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var incidentIdentifier: String
    var launchRecordIdentifier: String?
    var steamAppID: String?
    var gameName: String?
    var occurredAt: Date
    var expectedResult: String?
    var actualSymptoms: String?
    var reproductionSteps: String?
    var userNotes: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        incidentIdentifier: String = UUID().uuidString.lowercased(),
        launchRecordIdentifier: String? = nil,
        steamAppID: String? = nil,
        gameName: String? = nil,
        occurredAt: Date = Date(),
        expectedResult: String? = nil,
        actualSymptoms: String? = nil,
        reproductionSteps: String? = nil,
        userNotes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.incidentIdentifier = incidentIdentifier
        self.launchRecordIdentifier = launchRecordIdentifier
        self.steamAppID = steamAppID
        self.gameName = gameName
        self.occurredAt = occurredAt
        self.expectedResult = expectedResult
        self.actualSymptoms = actualSymptoms
        self.reproductionSteps = reproductionSteps
        self.userNotes = userNotes
    }

    fileprivate func normalized() -> SupportIncidentContext {
        SupportIncidentContext(
            schemaVersion: Self.currentSchemaVersion,
            incidentIdentifier: Self.bounded(incidentIdentifier, limit: 128) ?? UUID().uuidString.lowercased(),
            launchRecordIdentifier: Self.bounded(launchRecordIdentifier, limit: 256),
            steamAppID: Self.bounded(steamAppID, limit: 64),
            gameName: Self.bounded(gameName, limit: 256),
            occurredAt: occurredAt,
            expectedResult: Self.bounded(expectedResult, limit: 4_096),
            actualSymptoms: Self.bounded(actualSymptoms, limit: 4_096),
            reproductionSteps: Self.bounded(reproductionSteps, limit: 8_192),
            userNotes: Self.bounded(userNotes, limit: 4_096)
        )
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        return bounded(value, limit: limit)
    }

    private static func bounded(_ value: String, limit: Int) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .filter { character in
                character == "\n" || character == "\t" ||
                    !character.unicodeScalars.allSatisfy {
                        CharacterSet.controlCharacters.contains($0)
                    }
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }
}

private struct SupportBundleSkippedFile: Codable, Hashable, Sendable {
    let anonymousSourceIdentifier: String
    let sourceCategory: String
    let artifactRole: String
    let runIdentifier: String?
    let actionName: String?
    let byteCount: Int64
    let reason: String
}

private struct SupportBundleIncludedFile: Codable, Hashable, Sendable {
    let anonymousSourceIdentifier: String
    let archiveEntry: String
    let sourceCategory: String
    let artifactRole: String
    let runIdentifier: String?
    let actionName: String?
    let originalByteCount: Int64
    let byteCount: Int64
    let contentKind: String
    let sourceEncoding: String
    let truncated: Bool
    let sourceModifiedAt: Date?
    let sha256: String
}

private struct SupportBundleCollectionIssue: Codable, Hashable, Sendable {
    let component: String
    let anonymousSourceIdentifier: String?
    let message: String
}

private func appendBoundedSupportBundleIssue(
    _ issue: SupportBundleCollectionIssue,
    to issues: inout [SupportBundleCollectionIssue]
) {
    guard supportBundleMaximumCollectionIssues > 0 else { return }
    if issues.count < supportBundleMaximumCollectionIssues - 1 {
        issues.append(issue)
        return
    }
    guard issues.count == supportBundleMaximumCollectionIssues - 1 else { return }
    issues.append(.init(
        component: "collectionIssues.limit",
        anonymousSourceIdentifier: nil,
        message: "additional collection issues were omitted at the configured issue limit"
    ))
}

private func appendBoundedSupportBundleIssues(
    _ newIssues: [SupportBundleCollectionIssue],
    to issues: inout [SupportBundleCollectionIssue]
) {
    for issue in newIssues {
        appendBoundedSupportBundleIssue(issue, to: &issues)
    }
}

private extension Array where Element == SupportBundleCollectionIssue {
    mutating func appendBounded(_ issue: SupportBundleCollectionIssue) {
        appendBoundedSupportBundleIssue(issue, to: &self)
    }
}

private struct SupportBundleLimits: Codable, Hashable, Sendable {
    let maxIncludedFiles: Int
    let maxIncludedBytes: Int64
    let maxTextBytesPerArtifact: Int
    let maxScannedItemsPerRoot: Int
    let maxPrioritizedGameRunScannedItems: Int
    let maxSteamLateLogFiles: Int
    let maxSteamDumpScannedItems: Int
    let maxSteamDumpInventoryItems: Int
    let maxLaunchRecords: Int
    let maxDiagnosticRecords: Int
    let maxDiagnosticResults: Int
    let maxSystemChecks: Int
    let maxSteamStoragePaths: Int
    let maxProcessRunEvidenceDocuments: Int
    let maxProcessRunEvidenceDiscoveryBytes: Int64
    let maxCollectionIssues: Int
    let manifestByteReserve: Int
    let readmeByteReserve: Int
}

private struct SupportBundleLaunchRecordSource: Hashable, Sendable {
    let recordIdentifier: String
    let gameID: String?
    let gameName: String?
    let gameBuildID: String?
    let gameManifestStateFlags: Int?
    let gameInstalledByteCount: Int64?
    let gameLastUpdatedAt: Date?
    let gameManifestAvailable: Bool?
    let gameManifestCaptureIssue: String?
    let gameAssociationSource: String?
    let prefixIdentifier: String
    let commandKind: String
    let startedAt: Date
    let endedAt: Date?
    /// Actual operating-system process exit status, when available.
    let exitCode: Int32?
    /// ForgePlay launch/verification decision; never an OS exit status.
    let forgePlayStatusCode: Int32?
    let status: String
    let steamUIVerificationStatus: String?
    let steamUIVerificationDetail: String?
    let steamUISurface: String?
    let hostAppSessionIdentifier: String?
    let environmentGenerationIdentifier: String?
    let processSteamUIVerificationStatus: String?
    let didTimeOut: Bool?
    let waitedForExit: Bool?
    let processIdentifier: Int32?
    let processOutcome: String?
    let terminationSignal: Int32?
    let rawWaitStatus: Int32?
    let evidenceCaptureWarning: String?
    let diagnosticCaptureWarning: String?
    let failureDomain: String?
    let failureCode: Int?
    let failureSummary: String?
    let artifactPaths: [String: String]
}

private struct SupportBundleLaunchRecordSnapshot: Codable, Hashable, Sendable {
    let recordIdentifier: String
    let gameID: String?
    let gameName: String?
    let gameBuildID: String?
    let gameManifestStateFlags: Int?
    let gameInstalledByteCount: Int64?
    let gameLastUpdatedAt: Date?
    let gameManifestAvailable: Bool?
    let gameManifestCaptureIssue: String?
    let gameAssociationSource: String?
    let prefixIdentifier: String
    let commandKind: String
    let startedAt: Date
    let endedAt: Date?
    let durationMilliseconds: Int64?
    /// Actual operating-system process exit status, when available.
    let exitCode: Int32?
    /// ForgePlay launch/verification decision; never an OS exit status.
    let forgePlayStatusCode: Int32?
    let status: String
    let steamUIVerificationStatus: String?
    let steamUIVerificationDetail: String?
    let steamUISurface: String?
    let hostAppSessionIdentifier: String?
    let environmentGenerationIdentifier: String?
    let processSteamUIVerificationStatus: String?
    let didTimeOut: Bool?
    let waitedForExit: Bool?
    let processIdentifier: Int32?
    let processOutcome: String?
    let terminationSignal: Int32?
    let rawWaitStatus: Int32?
    let evidenceCaptureWarning: String?
    let diagnosticCaptureWarning: String?
    let failureDomain: String?
    let failureCode: Int?
    let failureSummary: String?
    let artifactReferences: [String: String]
    let missingArtifactRoles: [String]
}

private struct SupportBundleIncidentSnapshot: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let incidentIdentifier: String
    let launchRecordIdentifier: String?
    let launchRecordIncluded: Bool?
    let steamAppID: String?
    let gameName: String?
    let occurredAt: Date
    let expectedResult: String?
    let actualSymptoms: String?
    let reproductionSteps: String?
    let userNotes: String?

    init(context: SupportIncidentContext, launchRecordIncluded: Bool?) {
        schemaVersion = context.schemaVersion
        incidentIdentifier = context.incidentIdentifier
        launchRecordIdentifier = context.launchRecordIdentifier
        self.launchRecordIncluded = launchRecordIncluded
        steamAppID = context.steamAppID
        gameName = context.gameName
        occurredAt = context.occurredAt
        expectedResult = context.expectedResult
        actualSymptoms = context.actualSymptoms
        reproductionSteps = context.reproductionSteps
        userNotes = context.userNotes
    }
}

private struct SupportBundleManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let createdAt: Date
    let collectionStatus: String
    let incident: SupportBundleIncidentSnapshot?
    let environment: DiagnosticEnvironmentSnapshot
    let launches: [SupportBundleLaunchRecordSnapshot]
    let diagnosticRecords: [SupportBundleDiagnosticRecordSummary]
    let steamLateEvidence: SupportBundleSteamLateEvidenceStatus
    let includedFiles: [SupportBundleIncludedFile]
    let skippedFiles: [SupportBundleSkippedFile]
    let collectionIssues: [SupportBundleCollectionIssue]
    let limits: SupportBundleLimits
    let manifestSelfHashExcluded: Bool
}

private struct SupportBundleCopyResult: Sendable {
    var includedFiles: [SupportBundleIncludedFile] = []
    var skippedFiles: [SupportBundleSkippedFile] = []
    var collectionIssues: [SupportBundleCollectionIssue] = []
    var archiveEntryBySourcePath: [String: String] = [:]
    var steamLateEvidenceStatus: SupportBundleSteamLateEvidenceStatus?

    mutating func appendCollectionIssue(_ issue: SupportBundleCollectionIssue) {
        appendBoundedSupportBundleIssue(issue, to: &collectionIssues)
    }

    mutating func appendCollectionIssues(_ issues: [SupportBundleCollectionIssue]) {
        appendBoundedSupportBundleIssues(issues, to: &collectionIssues)
    }

    mutating func merge(_ other: SupportBundleCopyResult) {
        includedFiles.append(contentsOf: other.includedFiles)
        skippedFiles.append(contentsOf: other.skippedFiles)
        appendCollectionIssues(other.collectionIssues)
        archiveEntryBySourcePath.merge(other.archiveEntryBySourcePath) { current, _ in current }
        if let status = other.steamLateEvidenceStatus {
            steamLateEvidenceStatus = status
        }
    }
}

private struct SupportBundleSourceItem: Sendable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let fileSize: Int
    let linkCount: Int
    let contentModificationDate: Date?
}

private struct SupportBundleArtifactIdentity: Sendable {
    let sourceCategory: String
    let role: String
    let runIdentifier: String?
    let actionName: String?
}

private struct SupportBundleTextRead: Sendable {
    let text: String
    let originalByteCount: Int64
    let encoding: String
    let truncated: Bool
    let lossy: Bool
    let snapshotChangedOrUnverifiable: Bool
}

private struct SupportBundleSteamLateEvidenceStatus: Codable, Hashable, Sendable {
    let state: String
    let logsDirectoryState: String
    let dumpsDirectoryState: String
    let includedLogRoles: [String]
    let missingOptionalLogRoles: [String]
    let dumpInventoryArchiveEntry: String?
    let observedDumpCount: Int
    let retainedDumpCount: Int
}

private struct SupportBundleSteamDumpInventory: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let collectionStatus: String
    let scannedItemCount: Int
    let observedDumpCount: Int
    let retainedDumpCount: Int
    let scanLimitReached: Bool
    let items: [SupportBundleSteamDumpInventoryItem]
}

private struct SupportBundleSteamDumpInventoryItem: Codable, Hashable, Sendable {
    let anonymousDumpIdentifier: String
    let filenameSHA256: String
    let byteCount: Int64
    let modifiedAt: Date?
    let fileExtension: String
}

private struct SupportBundleBudget: Sendable {
    // These two index files are required for a developer to orient the bundle.
    // Reserve them before optional evidence so a large log set produces a
    // partial, usable bundle rather than a ZIP that later fails validation.
    var includedFileCount = 2
    var includedByteCount: Int64 = Int64(
        SupportBundleService.manifestByteReserve + SupportBundleService.readmeByteReserve
    )

    mutating func reserve(byteCount: Int64) -> String? {
        guard includedFileCount < SupportBundleService.maxIncludedFiles else {
            return "supportBundleFileCountLimit"
        }
        guard byteCount >= 0,
              includedByteCount <= SupportBundleService.maxIncludedBytes - byteCount else {
            return "supportBundleTotalByteLimit"
        }
        includedFileCount += 1
        includedByteCount += byteCount
        return nil
    }
}

enum SupportBundleEvidencePreparationResult: Sendable, Equatable {
    case captured
    case notApplicable
    case skipped(String)
    case failed(String)
}

/// Immutable context passed to the application-owned evidence refresher just
/// before the support-bundle filesystem snapshot begins. An incident link is
/// authoritative: refreshers must not silently substitute a newer launch.
struct SupportBundleEvidencePreparationRequest {
    let launchRecords: [LaunchRecord]
    let incidentLaunchRecordIdentifier: String?
}

@MainActor
final class SupportBundleService {
    typealias EvidencePreCaptureHook = @MainActor @Sendable (
        SupportBundleEvidencePreparationRequest
    ) async -> SupportBundleEvidencePreparationResult

    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let redactor: Redactor
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let prepareEvidenceForCapture: EvidencePreCaptureHook

    init(
        pathManager: PathManager,
        runner: SafeProcessRunner,
        redactor: Redactor,
        fileManager: FileManager = .default,
        prepareEvidenceForCapture: @escaping EvidencePreCaptureHook = { _ in .notApplicable }
    ) {
        self.pathManager = pathManager
        self.runner = runner
        self.redactor = redactor
        self.fileManager = fileManager
        self.encoder = Self.makeEncoder()
        self.prepareEvidenceForCapture = prepareEvidenceForCapture
    }

    func createSupportBundle(
        diagnostics: [DiagnosticResult],
        checks: [SystemCheckResult],
        selectedSteamReference: SteamGame? = nil,
        runtimeExecutable: URL? = nil,
        launchRecords: [LaunchRecord] = [],
        diagnosticRecords: [SupportBundleDiagnosticRecordSummary] = [],
        steamStoragePaths: [String] = [],
        synchronizationSelection: String? = nil,
        rendererSelection: String? = nil,
        videoMemorySelection: String? = nil,
        resolvedVideoMemoryMB: Int? = nil,
        incident: SupportIncidentContext? = nil
    ) async throws -> URL {
        let managedRoot = try pathManager.validateCurrentManagedRoot()
        let destinationRoot = try pathManager.url(for: .supportBundles)
        try pathManager.createDirectoryIfNeeded(destinationRoot)
        let logsRoot = try pathManager.url(for: .logs)
        let emergencyDiagnosticsRoot = FailureDiagnosticEvidenceService
            .defaultEmergencyDiagnosticDirectory(fileManager: fileManager)
        let gameModeHostEvidenceRoot = GameModeHostCoordinationPaths
            .existingEvidenceDirectoryURL(fileManager: fileManager)
        let prefixesRoot = try pathManager.url(for: .prefixes)
        let steamSharedPrefix = try pathManager.url(for: .steamSharedPrefix)
        let createdAt = Date()
        let bundleIdentifier = UUID().uuidString.lowercased()

        let stamp = Self.timestampFormatter.string(from: createdAt)
        let staging = fileManager.temporaryDirectory
            .appending(path: "ForgePlaySupport_\(stamp)_\(UUID().uuidString)", directoryHint: .isDirectory)
        let redactedLogs = staging.appending(path: "redacted-logs", directoryHint: .isDirectory)
        let metadata = staging.appending(path: "metadata", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }

        var inputIssues: [SupportBundleCollectionIssue] = []
        let boundedSteamStoragePaths = Array(steamStoragePaths.prefix(Self.maxSteamStoragePaths))
        Self.recordInputLimitIssue(
            component: "steamStoragePaths",
            originalCount: steamStoragePaths.count,
            retainedCount: boundedSteamStoragePaths.count,
            into: &inputIssues
        )

        var sensitivePaths = DiagnosticPathRedactionPolicy.sensitivePaths(
            rootURL: pathManager.rootURL,
            selectedSteamReference: selectedSteamReference,
            runtimeExecutable: runtimeExecutable
        )
        sensitivePaths.append(contentsOf: boundedSteamStoragePaths)
        sensitivePaths.append(emergencyDiagnosticsRoot.path)
        let supportRedactor = redactor
            .addingSensitivePaths(sensitivePaths)
            .addingSensitiveTerms(DiagnosticPathRedactionPolicy.sensitiveTerms(
                selectedSteamReference: selectedSteamReference
            ))
        let supportBundleFileManager = SupportBundleFileManagerReference(value: fileManager)
        let runtimeIdentity = await Task.detached(priority: .utility) {
            DiagnosticEnvironmentSnapshotCollector.resolveRuntimeIdentity(
                for: runtimeExecutable,
                fileManager: supportBundleFileManager.value
            )
        }.value
        let environment = DiagnosticEnvironmentSnapshotCollector.capture(
            managedRoot: managedRoot,
            selectedSteamReference: selectedSteamReference,
            runtimeExecutable: runtimeExecutable,
            steamStoragePaths: boundedSteamStoragePaths,
            synchronizationSelection: synchronizationSelection,
            rendererSelection: rendererSelection,
            videoMemorySelection: videoMemorySelection,
            resolvedVideoMemoryMB: resolvedVideoMemoryMB,
            runtimeIdentity: runtimeIdentity,
            fileManager: fileManager
        )
        let boundedLaunchRecords = Array(
            launchRecords
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(Self.maxLaunchRecords)
        )
        let boundedDiagnosticRecords = Array(
            diagnosticRecords
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(Self.maxDiagnosticRecords)
        )
        let boundedDiagnostics = Array(diagnostics.prefix(Self.maxDiagnosticResults))
        let boundedChecks = Array(checks.prefix(Self.maxSystemChecks))
        let normalizedIncident = incident?.normalized()
        let incidentSnapshot = normalizedIncident.map { context in
            SupportBundleIncidentSnapshot(
                context: context,
                launchRecordIncluded: context.launchRecordIdentifier.map { identifier in
                    boundedLaunchRecords.contains { $0.id == identifier }
                }
            )
        }
        Self.recordInputLimitIssue(
            component: "launchRecords",
            originalCount: launchRecords.count,
            retainedCount: boundedLaunchRecords.count,
            into: &inputIssues
        )
        Self.recordInputLimitIssue(
            component: "diagnosticRecords",
            originalCount: diagnosticRecords.count,
            retainedCount: boundedDiagnosticRecords.count,
            into: &inputIssues
        )
        Self.recordInputLimitIssue(
            component: "diagnosticResults",
            originalCount: diagnostics.count,
            retainedCount: boundedDiagnostics.count,
            into: &inputIssues
        )
        Self.recordInputLimitIssue(
            component: "systemChecks",
            originalCount: checks.count,
            retainedCount: boundedChecks.count,
            into: &inputIssues
        )
        if let incidentSnapshot,
           incidentSnapshot.launchRecordIdentifier != nil,
           incidentSnapshot.launchRecordIncluded == false {
            appendBoundedSupportBundleIssue(.init(
                component: "incident.launchRecordLink",
                anonymousSourceIdentifier: nil,
                message: "the user-selected incident launch record was not available in the bounded launch timeline"
            ), to: &inputIssues)
        }
        let relatedEvidenceLimitReachedCount = boundedLaunchRecords.reduce(into: 0) { count, record in
            if record.relatedRunEvidencePaths.count > Self.maxRelatedRunEvidencePathsPerLaunch {
                count += 1
            }
        }
        if relatedEvidenceLimitReachedCount > 0 {
            appendBoundedSupportBundleIssue(.init(
                component: "launchRecords.relatedRunEvidencePaths",
                anonymousSourceIdentifier: nil,
                message: "related process evidence paths were limited for \(relatedEvidenceLimitReachedCount) launch records"
            ), to: &inputIssues)
        }
        let launchSources = boundedLaunchRecords.map(Self.launchRecordSource)
        let allPrioritizedLaunchArtifactPaths = launchSources.flatMap { source in
            source.artifactPaths
                .sorted { $0.key < $1.key }
                .map(\.value)
        }
        let prioritizedLaunchArtifactPaths = Array(
            allPrioritizedLaunchArtifactPaths.prefix(Self.maxPrioritizedLaunchArtifactPaths)
        )
        Self.recordInputLimitIssue(
            component: "launchArtifactPaths",
            originalCount: allPrioritizedLaunchArtifactPaths.count,
            retainedCount: prioritizedLaunchArtifactPaths.count,
            into: &inputIssues
        )
        let processRunEvidencePathSet = Set(launchSources.flatMap { source in
            source.artifactPaths.compactMap { role, path in
                role == "processRunMetadata" || role.hasPrefix("relatedProcessRunMetadata.")
                    ? URL(fileURLWithPath: path).standardizedFileURL.path
                    : nil
            }
        })
        let prioritizedProcessRunEvidencePaths = prioritizedLaunchArtifactPaths.filter {
            processRunEvidencePathSet.contains(URL(fileURLWithPath: $0).standardizedFileURL.path)
        }
        let prioritizedGameRunIdentifiers = Self.launchRunIdentifiers(from: launchSources)
        let metadataPayloads = try makeDiagnosticPayloads(
            boundedDiagnostics,
            checks: boundedChecks,
            diagnosticRecords: boundedDiagnosticRecords,
            environment: environment,
            selectedSteamReference: selectedSteamReference,
            redactor: supportRedactor
        )

        // The hook is injected by AppServices so this service remains unaware
        // of Steam internals. It runs after metadata preparation and directly
        // before the detached filesystem scan, closing monitor-backoff races.
        let evidencePreparationResult = await prepareEvidenceForCapture(.init(
            launchRecords: boundedLaunchRecords,
            incidentLaunchRecordIdentifier: incidentSnapshot?.launchRecordIdentifier
        ))
        switch evidencePreparationResult {
        case .captured, .notApplicable:
            break
        case .skipped(let reason):
            appendBoundedSupportBundleIssue(.init(
                component: "steamGameLaunchEvidencePreCapture",
                anonymousSourceIdentifier: nil,
                message: "game launch evidence refresh was skipped: \(reason)"
            ), to: &inputIssues)
        case .failed(let reason):
            appendBoundedSupportBundleIssue(.init(
                component: "steamGameLaunchEvidencePreCapture",
                anonymousSourceIdentifier: nil,
                message: "game launch evidence refresh failed: \(reason)"
            ), to: &inputIssues)
        }
        try await Task.detached(priority: .userInitiated) {
            let fileManager = supportBundleFileManager.value
            var budget = SupportBundleBudget()
            try fileManager.createDirectory(at: redactedLogs, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)

            // Preserve the machine-readable environment before optional evidence
            // can consume the shared support-bundle budget.
            var includedFiles: [SupportBundleIncludedFile] = []
            var skippedFiles: [SupportBundleSkippedFile] = []
            for (name, data) in metadataPayloads.sorted(by: { $0.key < $1.key }) {
                let archiveEntry = "metadata/\(name)"
                if let reason = budget.reserve(byteCount: Int64(data.count)) {
                    skippedFiles.append(Self.metadataSkippedFile(name: name, byteCount: data.count, reason: reason))
                    continue
                }
                try data.write(to: metadata.appending(path: name), options: [.atomic])
                includedFiles.append(Self.metadataIncludedFile(
                    name: name,
                    archiveEntry: archiveEntry,
                    data: data
                ))
            }

            // Explicit artifacts named by recent launch records are the strongest
            // diagnostic evidence. Reserve them before optional prefix and broad
            // managed-log discovery so they cannot be starved by unrelated files.
            let expandedPriority = Self.expandedProcessRunEvidenceArtifactPaths(
                baseSourcePaths: prioritizedLaunchArtifactPaths,
                processRunEvidenceSourcePaths: prioritizedProcessRunEvidencePaths,
                under: logsRoot,
                filesystemAnchor: managedRoot,
                excludedRoots: [destinationRoot],
                fileManager: fileManager
            )
            var collectedCopy = Self.copyRedactedTree(
                from: logsRoot,
                to: redactedLogs,
                filesystemAnchor: managedRoot,
                excludedRoots: [destinationRoot],
                prioritizedSourcePaths: expandedPriority.paths,
                prioritizedGameRunIdentifiers: prioritizedGameRunIdentifiers,
                includeBroadScan: false,
                sourceIdentifierPrefix: "launch-log",
                redactor: supportRedactor,
                fileManager: fileManager,
                budget: &budget
            )
            collectedCopy.appendCollectionIssues(expandedPriority.issues)
            if let gameModeHostEvidenceRoot {
                let evidenceFile = gameModeHostEvidenceRoot.appending(
                    path: GameModeHostCoordinationPaths.evidenceFileName,
                    directoryHint: .notDirectory
                )
                let gameModeHostCopy = Self.copyRedactedTree(
                    from: gameModeHostEvidenceRoot,
                    to: redactedLogs.appending(
                        path: "game-mode-process-host",
                        directoryHint: .isDirectory
                    ),
                    filesystemAnchor: gameModeHostEvidenceRoot,
                    excludedRoots: [],
                    prioritizedSourcePaths: [evidenceFile.path],
                    includeBroadScan: false,
                    sourceIdentifierPrefix: "game-mode-host",
                    redactor: supportRedactor,
                    fileManager: fileManager,
                    budget: &budget
                )
                collectedCopy.merge(gameModeHostCopy)
            }
            let steamLateCopy = Self.copySteamLateEvidence(
                from: steamSharedPrefix,
                to: staging,
                filesystemAnchor: managedRoot,
                redactor: supportRedactor,
                fileManager: fileManager,
                budget: &budget
            )
            collectedCopy.merge(steamLateCopy)
            let logCopy = Self.copyRedactedTree(
                from: logsRoot,
                to: redactedLogs,
                filesystemAnchor: managedRoot,
                excludedRoots: [destinationRoot],
                excludedSourcePaths: Set(collectedCopy.archiveEntryBySourcePath.keys),
                redactor: supportRedactor,
                fileManager: fileManager,
                budget: &budget
            )
            collectedCopy.merge(logCopy)
            if FileSystemItemPolicy.isNonSymlinkDirectory(
                emergencyDiagnosticsRoot,
                fileManager: fileManager
            ) {
                let emergencyCopy = Self.copyRedactedTree(
                    from: emergencyDiagnosticsRoot,
                    to: redactedLogs.appending(
                        path: "emergency-diagnostics",
                        directoryHint: .isDirectory
                    ),
                    filesystemAnchor: emergencyDiagnosticsRoot,
                    excludedRoots: [],
                    sourceIdentifierPrefix: "emergency-diagnostic",
                    redactor: supportRedactor,
                    fileManager: fileManager,
                    budget: &budget
                )
                collectedCopy.merge(emergencyCopy)
            }
            let prefixCopy = Self.copyPrefixMetadata(
                from: prefixesRoot,
                to: metadata.appending(path: "prefixes", directoryHint: .isDirectory),
                filesystemAnchor: managedRoot,
                redactor: supportRedactor,
                fileManager: fileManager,
                budget: &budget
            )
            collectedCopy.merge(prefixCopy)

            includedFiles.append(contentsOf: collectedCopy.includedFiles)
            skippedFiles.append(contentsOf: collectedCopy.skippedFiles)
            var collectionIssues: [SupportBundleCollectionIssue] = []
            appendBoundedSupportBundleIssues(collectedCopy.collectionIssues, to: &collectionIssues)
            appendBoundedSupportBundleIssues(inputIssues, to: &collectionIssues)
            appendBoundedSupportBundleIssues(environment.collectionIssues.map {
                SupportBundleCollectionIssue(
                    component: $0.component,
                    anonymousSourceIdentifier: nil,
                    message: $0.message
                )
            }, to: &collectionIssues)

            let launches = launchSources.map {
                Self.launchRecordSnapshot(
                    $0,
                    archiveEntryBySourcePath: collectedCopy.archiveEntryBySourcePath
                )
            }
            let steamLateEvidence = collectedCopy.steamLateEvidenceStatus ??
                Self.unavailableSteamLateEvidenceStatus()
            let readme = Self.makeReadme(
                bundleIdentifier: bundleIdentifier,
                createdAt: createdAt,
                incident: incidentSnapshot,
                environment: environment,
                launches: launches,
                steamLateEvidence: steamLateEvidence,
                includedFiles: includedFiles,
                skippedFiles: skippedFiles,
                collectionIssues: collectionIssues
            )
            let readmeData = Data(supportRedactor.redact(readme).utf8)
            guard readmeData.count <= Self.readmeByteReserve else {
                throw SupportBundleConstructionError.readmeExceedsReservedBytes(
                    actual: readmeData.count,
                    limit: Self.readmeByteReserve
                )
            }
            try readmeData.write(to: staging.appending(path: "README.md"), options: [.atomic])
            includedFiles.append(Self.metadataIncludedFile(
                name: "README.md",
                archiveEntry: "README.md",
                data: readmeData,
                contentKind: "humanReadableDiagnosticSummary"
            ))

            if !skippedFiles.isEmpty {
                let encodedSkippedFiles = try Self.makeEncoder().encode(skippedFiles)
                let redactedSkippedFiles = try supportRedactor.redactedJSONData(encodedSkippedFiles)
                _ = try JSONSerialization.jsonObject(with: redactedSkippedFiles)
                if let reason = budget.reserve(byteCount: Int64(redactedSkippedFiles.count)) {
                    skippedFiles.append(Self.metadataSkippedFile(
                        name: "skipped-files.json",
                        byteCount: redactedSkippedFiles.count,
                        reason: reason
                    ))
                } else {
                    try redactedSkippedFiles.write(
                        to: metadata.appending(path: "skipped-files.json"),
                        options: [.atomic]
                    )
                    includedFiles.append(Self.metadataIncludedFile(
                        name: "skipped-files.json",
                        archiveEntry: "metadata/skipped-files.json",
                        data: redactedSkippedFiles
                    ))
                }
            }

            let manifest = SupportBundleManifest(
                schemaVersion: 3,
                bundleIdentifier: bundleIdentifier,
                createdAt: createdAt,
                collectionStatus: skippedFiles.isEmpty && collectionIssues.isEmpty ? "complete" : "partial",
                incident: incidentSnapshot,
                environment: environment,
                launches: launches,
                diagnosticRecords: boundedDiagnosticRecords,
                steamLateEvidence: steamLateEvidence,
                includedFiles: includedFiles.sorted { $0.archiveEntry < $1.archiveEntry },
                skippedFiles: skippedFiles,
                collectionIssues: collectionIssues,
                limits: SupportBundleLimits(
                    maxIncludedFiles: Self.maxIncludedFiles,
                    maxIncludedBytes: Self.maxIncludedBytes,
                    maxTextBytesPerArtifact: Self.maxTextBytesPerArtifact,
                    maxScannedItemsPerRoot: Self.maxScannedItemsPerRoot,
                    maxPrioritizedGameRunScannedItems: Self.maxPrioritizedGameRunScannedItems,
                    maxSteamLateLogFiles: Self.steamLateLogAllowlist.count,
                    maxSteamDumpScannedItems: Self.maxSteamDumpScannedItems,
                    maxSteamDumpInventoryItems: Self.maxSteamDumpInventoryItems,
                    maxLaunchRecords: Self.maxLaunchRecords,
                    maxDiagnosticRecords: Self.maxDiagnosticRecords,
                    maxDiagnosticResults: Self.maxDiagnosticResults,
                    maxSystemChecks: Self.maxSystemChecks,
                    maxSteamStoragePaths: Self.maxSteamStoragePaths,
                    maxProcessRunEvidenceDocuments: Self.maxProcessRunEvidenceDocuments,
                    maxProcessRunEvidenceDiscoveryBytes: Self.maxProcessRunEvidenceDiscoveryBytes,
                    maxCollectionIssues: supportBundleMaximumCollectionIssues,
                    manifestByteReserve: Self.manifestByteReserve,
                    readmeByteReserve: Self.readmeByteReserve
                ),
                manifestSelfHashExcluded: true
            )
            let encodedManifest = try Self.makeEncoder().encode(manifest)
            let redactedManifest = try supportRedactor.redactedJSONData(encodedManifest)
            _ = try JSONSerialization.jsonObject(with: redactedManifest)
            guard redactedManifest.count <= Self.manifestByteReserve else {
                throw SupportBundleConstructionError.manifestExceedsReservedBytes(
                    actual: redactedManifest.count,
                    limit: Self.manifestByteReserve
                )
            }
            try redactedManifest.write(
                to: metadata.appending(path: "bundle-manifest.json"),
                options: [.atomic]
            )
            try Self.validateRedactionClosure(
                in: staging,
                redactor: supportRedactor,
                fileManager: fileManager
            )
        }.value

        let destinationZip = destinationRoot.appending(path: "ForgePlaySupport_\(stamp)_\(UUID().uuidString).zip")
        let result = try await runner.run(.createSupportArchive(
            sourceDirectory: staging,
            destinationZip: destinationZip,
            logDirectory: destinationRoot
        ))
        guard result.succeeded else {
            do {
                try removeSupportArchiveIfPresent(destinationZip)
            } catch let cleanupError {
                throw SupportBundleServiceError.archiveCleanupFailed(
                    destination: destinationZip,
                    processResult: result,
                    cleanupError: cleanupError
                )
            }
            throw SupportBundleServiceError.archiveFailed(result)
        }
        do {
            guard chmod(destinationZip.path, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            }
            try Self.validateCreatedArchive(destinationZip, fileManager: fileManager)
        } catch {
            do {
                try removeSupportArchiveIfPresent(destinationZip)
            } catch let cleanupError {
                throw SupportBundleServiceError.archiveCleanupFailed(
                    destination: destinationZip,
                    processResult: result,
                    cleanupError: cleanupError
                )
            }
            throw SupportBundleServiceError.archiveValidationFailed(
                destinationZip,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        return destinationZip
    }

    private func removeSupportArchiveIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func makeDiagnosticPayloads(
        _ diagnostics: [DiagnosticResult],
        checks: [SystemCheckResult],
        diagnosticRecords: [SupportBundleDiagnosticRecordSummary],
        environment: DiagnosticEnvironmentSnapshot,
        selectedSteamReference: SteamGame?,
        redactor: Redactor
    ) throws -> [String: Data] {
        let diagnosticData = try encoder.encode(diagnostics)
        let recordData = try encoder.encode(diagnosticRecords)
        let checkSummaries = checks.map {
            [
                "category": $0.category.rawValue,
                "title": $0.title,
                "detail": $0.detail,
                "status": $0.status.rawValue,
                "technicalDetail": $0.technicalDetail ?? ""
            ]
        }
        let checksData = try JSONSerialization.data(
            withJSONObject: checkSummaries,
            options: [.prettyPrinted, .sortedKeys]
        )
        let environmentData = try encoder.encode(environment)
        let appInfo: [String: Any] = [
            "appName": environment.application.name,
            "bundleIdentifier": environment.application.bundleIdentifier,
            "appVersion": environment.application.version,
            "build": environment.application.build,
            "macOS": environment.host.operatingSystemVersion,
            "macOSBuild": environment.host.operatingSystemBuild ?? "unknown",
            "architecture": environment.application.processArchitecture,
            "selectedSteamReference": selectedSteamReference.map {
                [
                    "steamAppId": $0.steamAppId,
                    "name": $0.name,
                    "installDir": $0.installDir,
                    "sizeOnDisk": String($0.sizeOnDisk)
                ]
            } ?? [:]
        ]
        let appInfoData = try JSONSerialization.data(
            withJSONObject: appInfo,
            options: [.prettyPrinted, .sortedKeys]
        )

        let payloads = [
            "diagnostics.json": diagnosticData,
            "diagnostic-records.json": recordData,
            "system-checks.json": checksData,
            "environment.json": environmentData,
            "app-info.json": appInfoData
        ]
        return try payloads.mapValues { data in
            let redacted = try redactor.redactedJSONData(data)
            _ = try JSONSerialization.jsonObject(with: redacted, options: [.fragmentsAllowed])
            return redacted
        }
    }

    /// Steam continues writing some of its most useful game/content evidence
    /// after the launcher process observed by ForgePlay has returned. Inspect
    /// only known files under the managed SteamShared installation: never walk
    /// the Wine prefix looking for logs.
    private nonisolated static func copySteamLateEvidence(
        from steamSharedPrefix: URL,
        to stagingRoot: URL,
        filesystemAnchor: URL,
        redactor: Redactor,
        fileManager: FileManager,
        budget: inout SupportBundleBudget
    ) -> SupportBundleCopyResult {
        var result = SupportBundleCopyResult()
        var steamDirectoryAvailable = false
        var logsDirectoryState = "notPresent"
        var dumpsDirectoryState = "notPresent"
        var includedLogRoles: [String] = []
        var missingOptionalLogRoles = steamLateLogAllowlist.map(\.role)
        var dumpInventoryArchiveEntry: String?
        var observedDumpCount = 0
        var retainedDumpCount = 0
        var hadCollectionFailure = false

        func finishedResult() -> SupportBundleCopyResult {
            var finished = result
            let didCollectEvidence = !includedLogRoles.isEmpty || dumpInventoryArchiveEntry != nil
            let state: String
            if hadCollectionFailure {
                state = "partial"
            } else if didCollectEvidence {
                state = "collected"
            } else if steamDirectoryAvailable {
                state = "optionalEvidenceNotGenerated"
            } else {
                state = "notAvailable"
            }
            finished.steamLateEvidenceStatus = .init(
                state: state,
                logsDirectoryState: logsDirectoryState,
                dumpsDirectoryState: dumpsDirectoryState,
                includedLogRoles: includedLogRoles.sorted(),
                missingOptionalLogRoles: missingOptionalLogRoles.sorted(),
                dumpInventoryArchiveEntry: dumpInventoryArchiveEntry,
                observedDumpCount: observedDumpCount,
                retainedDumpCount: retainedDumpCount
            )
            return finished
        }

        let steamDirectory = SteamClientCompatibilityProfileContract
            .steamDirectory(in: steamSharedPrefix)
        let steamDirectoryItem: SupportBundleSourceItem?
        do {
            steamDirectoryItem = try directSourceItem(
                at: steamDirectory,
                relativePath: "steam-installation"
            )
        } catch {
            hadCollectionFailure = true
            logsDirectoryState = "unreadable"
            dumpsDirectoryState = "unreadable"
            result.appendCollectionIssue(.init(
                component: "steamLateEvidence.scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(error)
            ))
            return finishedResult()
        }
        guard let steamDirectoryItem else {
            return finishedResult()
        }
        guard steamDirectoryItem.isDirectory,
              !steamDirectoryItem.isSymbolicLink,
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                  from: steamSharedPrefix,
                  to: steamDirectory,
                  fileManager: fileManager
              ) else {
            hadCollectionFailure = true
            logsDirectoryState = "unsafe"
            dumpsDirectoryState = "unsafe"
            result.appendCollectionIssue(.init(
                component: "steamLateEvidence.scan",
                anonymousSourceIdentifier: nil,
                message: "Steam installation directory was not a safe non-symlink directory chain"
            ))
            return finishedResult()
        }
        steamDirectoryAvailable = true

        let lateEvidenceDirectory = stagingRoot.appending(
            path: "redacted-logs/steam-late-evidence",
            directoryHint: .isDirectory
        )
        let logsDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        do {
            if let logsDirectoryItem = try directSourceItem(
                at: logsDirectory,
                relativePath: "steam-logs"
            ) {
                if logsDirectoryItem.isDirectory,
                   !logsDirectoryItem.isSymbolicLink,
                   FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                       from: steamSharedPrefix,
                       to: logsDirectory,
                       fileManager: fileManager
                   ) {
                    logsDirectoryState = "available"
                    for (index, candidate) in steamLateLogAllowlist.enumerated() {
                        let sourceID = anonymousIdentifier(prefix: "steam-late", index: index + 1)
                        let identity = SupportBundleArtifactIdentity(
                            sourceCategory: "steamLateEvidence",
                            role: candidate.role,
                            runIdentifier: nil,
                            actionName: nil
                        )
                        let sourceURL = logsDirectory.appending(path: candidate.fileName)
                        let item: SupportBundleSourceItem?
                        do {
                            item = try directSourceItem(
                                at: sourceURL,
                                relativePath: candidate.fileName
                            )
                        } catch {
                            hadCollectionFailure = true
                            result.skippedFiles.append(skippedFile(
                                sourceID: sourceID,
                                identity: identity,
                                byteCount: 0,
                                reason: "metadataReadFailed"
                            ))
                            result.appendCollectionIssue(.init(
                                component: "steamLateEvidence.metadata",
                                anonymousSourceIdentifier: sourceID,
                                message: forgePlayTechnicalErrorSummary(error)
                            ))
                            continue
                        }
                        guard let item else { continue }
                        missingOptionalLogRoles.removeAll { $0 == candidate.role }
                        guard validateCandidate(
                            item,
                            sourceID: sourceID,
                            identity: identity,
                            result: &result
                        ) else {
                            hadCollectionFailure = true
                            continue
                        }
                        do {
                            let read = try readBoundedText(
                                from: item.url,
                                anchoredAt: filesystemAnchor
                            )
                            let redactedData = Data(redactor.redact(read.text).utf8)
                            if let reason = budget.reserve(byteCount: Int64(redactedData.count)) {
                                hadCollectionFailure = true
                                result.skippedFiles.append(skippedFile(
                                    sourceID: sourceID,
                                    identity: identity,
                                    byteCount: read.originalByteCount,
                                    reason: reason
                                ))
                                continue
                            }
                            try fileManager.createDirectory(
                                at: lateEvidenceDirectory,
                                withIntermediateDirectories: true
                            )
                            let archiveEntry = "redacted-logs/steam-late-evidence/\(sourceID).log"
                            try redactedData.write(
                                to: lateEvidenceDirectory.appending(path: "\(sourceID).log"),
                                options: [.atomic]
                            )
                            var contentKind = "redactedSteamLateTextLog"
                            if read.lossy { contentKind += ".lossyDecode" }
                            result.includedFiles.append(includedFile(
                                sourceID: sourceID,
                                archiveEntry: archiveEntry,
                                identity: identity,
                                read: read,
                                archivedData: redactedData,
                                sourceModifiedAt: item.contentModificationDate,
                                contentKind: contentKind
                            ))
                            result.archiveEntryBySourcePath[item.url.standardizedFileURL.path] = archiveEntry
                            includedLogRoles.append(candidate.role)
                            if read.snapshotChangedOrUnverifiable {
                                hadCollectionFailure = true
                                result.appendCollectionIssue(.init(
                                    component: "steamLateEvidence.snapshot",
                                    anonymousSourceIdentifier: sourceID,
                                    message: "source changed or final metadata could not be verified after the bounded snapshot was read"
                                ))
                            }
                        } catch {
                            hadCollectionFailure = true
                            recordReadFailure(
                                error,
                                item: item,
                                sourceID: sourceID,
                                identity: identity,
                                result: &result
                            )
                        }
                    }
                } else {
                    hadCollectionFailure = true
                    logsDirectoryState = "unsafe"
                    result.appendCollectionIssue(.init(
                        component: "steamLateEvidence.scan",
                        anonymousSourceIdentifier: nil,
                        message: "Steam logs directory was not a safe non-symlink directory chain"
                    ))
                }
            }
        } catch {
            hadCollectionFailure = true
            logsDirectoryState = "unreadable"
            result.appendCollectionIssue(.init(
                component: "steamLateEvidence.scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(error)
            ))
        }

        let dumpsDirectory = steamDirectory.appending(path: "dumps", directoryHint: .isDirectory)
        do {
            if let dumpsDirectoryItem = try directSourceItem(
                at: dumpsDirectory,
                relativePath: "steam-dumps"
            ) {
                if dumpsDirectoryItem.isDirectory,
                   !dumpsDirectoryItem.isSymbolicLink,
                   FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                       from: steamSharedPrefix,
                       to: dumpsDirectory,
                       fileManager: fileManager
                   ) {
                    dumpsDirectoryState = "available"
                    var dumpCollectionFailure = false
                    let dumpScan = steamDumpSourceItems(
                        under: dumpsDirectory,
                        fileManager: fileManager
                    )
                    result.appendCollectionIssues(dumpScan.issues)
                    if !dumpScan.issues.isEmpty || dumpScan.limitReached {
                        hadCollectionFailure = true
                        dumpCollectionFailure = true
                    }

                    var inventoryItems: [SupportBundleSteamDumpInventoryItem] = []
                    for (index, item) in dumpScan.items.enumerated() {
                        let sourceID = anonymousIdentifier(prefix: "steam-dump", index: index + 1)
                        let identity = SupportBundleArtifactIdentity(
                            sourceCategory: "steamLateEvidence",
                            role: "steamDumpBinary",
                            runIdentifier: nil,
                            actionName: nil
                        )
                        guard validateCandidate(
                            item,
                            sourceID: sourceID,
                            identity: identity,
                            result: &result
                        ) else {
                            hadCollectionFailure = true
                            dumpCollectionFailure = true
                            continue
                        }
                        observedDumpCount += 1
                        guard inventoryItems.count < maxSteamDumpInventoryItems else { continue }
                        let originalName = item.url.lastPathComponent
                        let rawExtension = item.url.pathExtension.lowercased()
                        inventoryItems.append(.init(
                            anonymousDumpIdentifier: sourceID,
                            filenameSHA256: sha256(Data(originalName.utf8)),
                            byteCount: Int64(item.fileSize),
                            modifiedAt: item.contentModificationDate,
                            fileExtension: rawExtension.isEmpty
                                ? "none"
                                : PathManager.sanitizedFileExtension(rawExtension)
                        ))
                        result.skippedFiles.append(skippedFile(
                            sourceID: sourceID,
                            identity: identity,
                            byteCount: Int64(item.fileSize),
                            reason: "binaryCrashEvidenceExcludedWithMetadataInventory"
                        ))
                    }
                    retainedDumpCount = inventoryItems.count
                    if observedDumpCount > retainedDumpCount {
                        hadCollectionFailure = true
                        dumpCollectionFailure = true
                        result.appendCollectionIssue(.init(
                            component: "steamLateEvidence.dumps",
                            anonymousSourceIdentifier: nil,
                            message: "retained the newest \(retainedDumpCount) of \(observedDumpCount) dump metadata records"
                        ))
                    }

                    let inventory = SupportBundleSteamDumpInventory(
                        schemaVersion: 1,
                        collectionStatus: dumpCollectionFailure ? "partial" : "complete",
                        scannedItemCount: dumpScan.scannedItemCount,
                        observedDumpCount: observedDumpCount,
                        retainedDumpCount: retainedDumpCount,
                        scanLimitReached: dumpScan.limitReached,
                        items: inventoryItems
                    )
                    let inventorySourceID = anonymousIdentifier(
                        prefix: "steam-late",
                        index: steamLateLogAllowlist.count + 1
                    )
                    let inventoryIdentity = SupportBundleArtifactIdentity(
                        sourceCategory: "steamLateEvidence",
                        role: "steamDumpInventory",
                        runIdentifier: nil,
                        actionName: nil
                    )
                    do {
                        let encoded = try makeEncoder().encode(inventory)
                        let redactedData = try redactor.redactedJSONData(encoded)
                        _ = try JSONSerialization.jsonObject(with: redactedData)
                        if let reason = budget.reserve(byteCount: Int64(redactedData.count)) {
                            hadCollectionFailure = true
                            result.skippedFiles.append(skippedFile(
                                sourceID: inventorySourceID,
                                identity: inventoryIdentity,
                                byteCount: Int64(redactedData.count),
                                reason: reason
                            ))
                        } else {
                            try fileManager.createDirectory(
                                at: lateEvidenceDirectory,
                                withIntermediateDirectories: true
                            )
                            let archiveEntry = "redacted-logs/steam-late-evidence/\(inventorySourceID).json"
                            try redactedData.write(
                                to: lateEvidenceDirectory.appending(path: "\(inventorySourceID).json"),
                                options: [.atomic]
                            )
                            result.includedFiles.append(includedDataFile(
                                sourceID: inventorySourceID,
                                archiveEntry: archiveEntry,
                                identity: inventoryIdentity,
                                data: redactedData,
                                contentKind: "redactedSteamDumpMetadataInventory"
                            ))
                            dumpInventoryArchiveEntry = archiveEntry
                        }
                    } catch {
                        hadCollectionFailure = true
                        result.skippedFiles.append(skippedFile(
                            sourceID: inventorySourceID,
                            identity: inventoryIdentity,
                            byteCount: 0,
                            reason: "inventoryWriteFailed"
                        ))
                        result.appendCollectionIssue(.init(
                            component: "steamLateEvidence.dumps",
                            anonymousSourceIdentifier: inventorySourceID,
                            message: forgePlayTechnicalErrorSummary(error)
                        ))
                    }
                } else {
                    hadCollectionFailure = true
                    dumpsDirectoryState = "unsafe"
                    result.appendCollectionIssue(.init(
                        component: "steamLateEvidence.scan",
                        anonymousSourceIdentifier: nil,
                        message: "Steam dumps directory was not a safe non-symlink directory chain"
                    ))
                }
            }
        } catch {
            hadCollectionFailure = true
            dumpsDirectoryState = "unreadable"
            result.appendCollectionIssue(.init(
                component: "steamLateEvidence.scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(error)
            ))
        }

        return finishedResult()
    }

    private nonisolated static func copyPrefixMetadata(
        from prefixes: URL,
        to destination: URL,
        filesystemAnchor: URL,
        redactor: Redactor,
        fileManager: FileManager,
        budget: inout SupportBundleBudget
    ) -> SupportBundleCopyResult {
        var result = SupportBundleCopyResult()
        guard fileManager.fileExists(atPath: prefixes.path) else {
            result.appendCollectionIssue(.init(
                component: "prefixMetadata",
                anonymousSourceIdentifier: nil,
                message: "prefix root is missing"
            ))
            return result
        }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            result.appendCollectionIssue(.init(
                component: "prefixMetadata",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(error)
            ))
            return result
        }
        let scan = prefixMetadataSourceItems(under: prefixes, fileManager: fileManager)
        result.appendCollectionIssues(scan.issues)
        var sourceIndex = 0
        for item in scan.items where item.url.lastPathComponent == "prefix.json" {
            sourceIndex += 1
            let sourceID = anonymousIdentifier(prefix: "prefix", index: sourceIndex)
            let identity = SupportBundleArtifactIdentity(
                sourceCategory: "prefixMetadata",
                role: "prefixMetadata",
                runIdentifier: nil,
                actionName: nil
            )
            guard validateCandidate(item, sourceID: sourceID, identity: identity, result: &result) else {
                continue
            }
            do {
                let read = try readBoundedText(
                    from: item.url,
                    anchoredAt: filesystemAnchor
                )
                guard read.originalByteCount <= Int64(PrefixManager.maxMetadataBytes) else {
                    result.skippedFiles.append(skippedFile(
                        sourceID: sourceID,
                        identity: identity,
                        byteCount: read.originalByteCount,
                        reason: "largerThanPrefixMetadataLimit"
                    ))
                    continue
                }
                let utf8 = Data(read.text.utf8)
                let redactedData: Data
                do {
                    redactedData = try redactor.redactedJSONData(utf8)
                    _ = try JSONSerialization.jsonObject(with: redactedData)
                } catch {
                    result.skippedFiles.append(skippedFile(
                        sourceID: sourceID,
                        identity: identity,
                        byteCount: read.originalByteCount,
                        reason: "invalidStructuredPrefixMetadata"
                    ))
                    result.appendCollectionIssue(.init(
                        component: "prefixMetadata",
                        anonymousSourceIdentifier: sourceID,
                        message: forgePlayTechnicalErrorSummary(error)
                    ))
                    continue
                }
                if let reason = budget.reserve(byteCount: Int64(redactedData.count)) {
                    result.skippedFiles.append(skippedFile(
                        sourceID: sourceID,
                        identity: identity,
                        byteCount: read.originalByteCount,
                        reason: reason
                    ))
                    continue
                }
                let archiveName = "\(sourceID).json"
                let archiveEntry = "metadata/prefixes/\(archiveName)"
                try redactedData.write(to: destination.appending(path: archiveName), options: [.atomic])
                result.includedFiles.append(includedFile(
                    sourceID: sourceID,
                    archiveEntry: archiveEntry,
                    identity: identity,
                    read: read,
                    archivedData: redactedData,
                    sourceModifiedAt: item.contentModificationDate,
                    contentKind: "redactedPrefixMetadata"
                ))
                result.archiveEntryBySourcePath[item.url.standardizedFileURL.path] = archiveEntry
                if read.snapshotChangedOrUnverifiable {
                    result.appendCollectionIssue(.init(
                        component: "prefixMetadata.snapshot",
                        anonymousSourceIdentifier: sourceID,
                        message: "source changed or final metadata could not be verified after the bounded snapshot was read"
                    ))
                }
            } catch {
                recordReadFailure(
                    error,
                    item: item,
                    sourceID: sourceID,
                    identity: identity,
                    result: &result
                )
            }
        }
        return result
    }

    private nonisolated static func copyRedactedTree(
        from source: URL,
        to destination: URL,
        filesystemAnchor: URL,
        excludedRoots: [URL],
        prioritizedSourcePaths: [String] = [],
        prioritizedGameRunIdentifiers: [String] = [],
        excludedSourcePaths: Set<String> = [],
        includeBroadScan: Bool = true,
        sourceIdentifierPrefix: String = "log",
        redactor: Redactor,
        fileManager: FileManager,
        budget: inout SupportBundleBudget
    ) -> SupportBundleCopyResult {
        var result = SupportBundleCopyResult()
        do {
            try validateSecureDirectory(source, anchoredAt: filesystemAnchor)
        } catch {
            result.appendCollectionIssue(.init(
                component: "logs.scan",
                anonymousSourceIdentifier: nil,
                message: "logs root was missing, unreadable, or no longer a safe managed directory: \(forgePlayTechnicalErrorSummary(error))"
            ))
            return result
        }
        let priorityScan = prioritizedLaunchArtifactSourceItems(
            prioritizedSourcePaths,
            under: source,
            excludedRoots: excludedRoots,
            fileManager: fileManager
        )
        result.appendCollectionIssues(priorityScan.issues)
        let gameRunScan = prioritizedGameRunSourceItems(
            prioritizedGameRunIdentifiers,
            under: source,
            excludedRoots: excludedRoots,
            fileManager: fileManager
        )
        result.appendCollectionIssues(gameRunScan.issues)
        var seenPriorityPaths = Set<String>()
        let priorityItems = (priorityScan.items + gameRunScan.items).filter {
            let path = $0.url.standardizedFileURL.path
            return !excludedSourcePaths.contains(path) && seenPriorityPaths.insert(path).inserted
        }
        let prioritizedPaths = Set(priorityItems.map { $0.url.standardizedFileURL.path })
        let scan: (items: [SupportBundleSourceItem], issues: [SupportBundleCollectionIssue]) = includeBroadScan
            ? supportBundleSourceItems(
                under: source,
                excludedRoots: excludedRoots,
                fileManager: fileManager
            )
            : (items: [], issues: [])
        result.appendCollectionIssues(scan.issues)
        var sourceIndex = 0
        let orderedItems = priorityItems + scan.items.filter {
            let path = $0.url.standardizedFileURL.path
            return !prioritizedPaths.contains(path) && !excludedSourcePaths.contains(path)
        }
        for item in orderedItems {
            if item.isDirectory, !item.isSymbolicLink { continue }
            sourceIndex += 1
            let sourceID = anonymousIdentifier(prefix: sourceIdentifierPrefix, index: sourceIndex)
            let identity = artifactIdentity(for: item)
            guard validateCandidate(item, sourceID: sourceID, identity: identity, result: &result) else {
                continue
            }
            if identity.role == "screenOCR" {
                result.skippedFiles.append(skippedFile(
                    sourceID: sourceID,
                    identity: identity,
                    byteCount: Int64(item.fileSize),
                    reason: "screenOCRExcludedForPrivacy"
                ))
                continue
            }
            guard isTextArtifact(item.url) else {
                result.skippedFiles.append(skippedFile(
                    sourceID: sourceID,
                    identity: identity,
                    byteCount: Int64(item.fileSize),
                    reason: binaryEvidenceExclusionReason(item.url)
                ))
                continue
            }
            do {
                let read = try readBoundedText(
                    from: item.url,
                    anchoredAt: filesystemAnchor
                )
                var redactedData: Data
                var contentKind = "redactedTextLog"
                if item.url.pathExtension.lowercased() == "json", !read.truncated {
                    do {
                        redactedData = try redactor.redactedJSONData(Data(read.text.utf8))
                        _ = try JSONSerialization.jsonObject(with: redactedData, options: [.fragmentsAllowed])
                        contentKind = "redactedStructuredJSON"
                    } catch {
                        redactedData = Data(redactor.redact(read.text).utf8)
                        contentKind = "redactedTextWithInvalidJSONSource"
                        result.appendCollectionIssue(.init(
                            component: "logs.structuredJSON",
                            anonymousSourceIdentifier: sourceID,
                            message: "source used a .json extension but was not valid JSON: \(forgePlayTechnicalErrorSummary(error))"
                        ))
                    }
                } else {
                    redactedData = Data(redactor.redact(read.text).utf8)
                }
                if read.lossy {
                    contentKind += ".lossyDecode"
                }
                if let reason = budget.reserve(byteCount: Int64(redactedData.count)) {
                    result.skippedFiles.append(skippedFile(
                        sourceID: sourceID,
                        identity: identity,
                        byteCount: read.originalByteCount,
                        reason: reason
                    ))
                    continue
                }
                let archiveEntry = archiveEntry(
                    sourceID: sourceID,
                    sourceURL: item.url,
                    identity: identity,
                    contentKind: contentKind
                )
                let destinationURL = destination.deletingLastPathComponent().appending(path: archiveEntry)
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try redactedData.write(to: destinationURL, options: [.atomic])
                result.includedFiles.append(includedFile(
                    sourceID: sourceID,
                    archiveEntry: archiveEntry,
                    identity: identity,
                    read: read,
                    archivedData: redactedData,
                    sourceModifiedAt: item.contentModificationDate,
                    contentKind: contentKind
                ))
                result.archiveEntryBySourcePath[item.url.standardizedFileURL.path] = archiveEntry
                if read.snapshotChangedOrUnverifiable {
                    result.appendCollectionIssue(.init(
                        component: "logs.snapshot",
                        anonymousSourceIdentifier: sourceID,
                        message: "source changed or final metadata could not be verified after the bounded snapshot was read"
                    ))
                }
            } catch {
                recordReadFailure(
                    error,
                    item: item,
                    sourceID: sourceID,
                    identity: identity,
                    result: &result
                )
            }
        }
        return result
    }

    /// Resolve the process-run UUID attached to each newest LaunchRecord. The
    /// persisted artifact paths are preferred because LaunchRecord's own UUID
    /// identifies the database record, while SafeProcessRunner's UUID identifies
    /// `Logs/Launch/GameRuns/<UUID>` renderer evidence. The record UUID remains a
    /// compatibility fallback for older records that did not persist paths.
    private nonisolated static func launchRunIdentifiers(
        from sources: [SupportBundleLaunchRecordSource]
    ) -> [String] {
        var seen = Set<String>()
        var identifiers: [String] = []
        for source in sources {
            let artifactIdentifiers = source.artifactPaths
                .sorted { $0.key < $1.key }
                .compactMap { uuidMatch(in: $0.value)?.value }
            let rawIdentifiers = artifactIdentifiers.isEmpty
                ? [uuidMatch(in: source.recordIdentifier)?.value].compactMap { $0 }
                : artifactIdentifiers
            for rawIdentifier in rawIdentifiers {
                guard let identifier = UUID(uuidString: rawIdentifier)?.uuidString.lowercased(),
                      seen.insert(identifier).inserted else {
                    continue
                }
                identifiers.append(identifier)
                if identifiers.count >= maxPrioritizedLaunchArtifactPaths {
                    return identifiers
                }
            }
        }
        return identifiers
    }

    /// Game renderer logs are emitted into one direct directory per process run.
    /// Scan only the known UUID directories, never recurse, and share one strict
    /// item cap across all recent runs so priority collection stays predictable.
    private nonisolated static func prioritizedGameRunSourceItems(
        _ runIdentifiers: [String],
        under root: URL,
        excludedRoots: [URL],
        fileManager: FileManager
    ) -> (items: [SupportBundleSourceItem], issues: [SupportBundleCollectionIssue]) {
        guard !runIdentifiers.isEmpty else { return ([], []) }
        let gameRunsRoot = root
            .appending(path: "Launch", directoryHint: .isDirectory)
            .appending(path: "GameRuns", directoryHint: .isDirectory)
        var items: [SupportBundleSourceItem] = []
        var issues: [SupportBundleCollectionIssue] = []
        var scannedItemCount = 0
        var limitReached = false

        runLoop: for (index, identifier) in runIdentifiers.prefix(maxPrioritizedLaunchArtifactPaths).enumerated() {
            if scannedItemCount >= maxPrioritizedGameRunScannedItems {
                limitReached = true
                break
            }
            let sourceID = anonymousIdentifier(prefix: "launch-run", index: index + 1)
            guard UUID(uuidString: identifier) != nil else { continue }
            let runDirectory = gameRunsRoot.appending(path: identifier, directoryHint: .isDirectory)
            let runDirectoryItem: SupportBundleSourceItem?
            do {
                runDirectoryItem = try directSourceItem(
                    at: runDirectory,
                    relativePath: "Launch/GameRuns/\(identifier)"
                )
            } catch {
                issues.appendBounded(.init(
                    component: "launchRenderer.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: forgePlayTechnicalErrorSummary(error)
                ))
                continue
            }
            // Renderer evidence is optional, so a missing directory is not a
            // partial collection. Unsafe or unreadable directories are.
            guard let runDirectoryItem else { continue }
            guard runDirectoryItem.isDirectory,
                  !runDirectoryItem.isSymbolicLink,
                  pathIsInsideOrEqual(runDirectory, root: root),
                  !excludedRoots.contains(where: { pathIsInsideOrEqual(runDirectory, root: $0) }),
                  FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                      from: root,
                      to: runDirectory,
                      fileManager: fileManager
                  ) else {
                issues.appendBounded(.init(
                    component: "launchRenderer.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: "renderer evidence directory was not a safe managed directory"
                ))
                continue
            }

            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: runDirectory,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                issues.appendBounded(.init(
                    component: "launchRenderer.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: "renderer evidence directory could not be enumerated"
                ))
                continue
            }

            var runItems: [SupportBundleSourceItem] = []
            for case let url as URL in enumerator {
                if scannedItemCount >= maxPrioritizedGameRunScannedItems {
                    limitReached = true
                    break
                }
                scannedItemCount += 1
                let relativePath = String(url.path.dropFirst(root.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                do {
                    guard let item = try directSourceItem(at: url, relativePath: relativePath) else {
                        issues.appendBounded(.init(
                            component: "launchRenderer.priority",
                            anonymousSourceIdentifier: sourceID,
                            message: "a renderer artifact disappeared while metadata was collected"
                        ))
                        continue
                    }
                    if item.isDirectory, !item.isSymbolicLink { continue }
                    runItems.append(item)
                } catch {
                    issues.appendBounded(.init(
                        component: "launchRenderer.priority",
                        anonymousSourceIdentifier: sourceID,
                        message: forgePlayTechnicalErrorSummary(error)
                    ))
                }
            }
            items.append(contentsOf: runItems.sorted(by: newestSourceItemFirst))
            if let enumerationError {
                issues.appendBounded(.init(
                    component: "launchRenderer.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: forgePlayTechnicalErrorSummary(enumerationError)
                ))
            }
            if limitReached { break runLoop }
        }
        if limitReached {
            issues.appendBounded(.init(
                component: "launchRenderer.priority",
                anonymousSourceIdentifier: nil,
                message: "priority renderer evidence scan stopped at the configured item limit"
            ))
        }
        return (items, issues)
    }

    private nonisolated static func validateCandidate(
        _ item: SupportBundleSourceItem,
        sourceID: String,
        identity: SupportBundleArtifactIdentity,
        result: inout SupportBundleCopyResult
    ) -> Bool {
        if item.isSymbolicLink {
            result.skippedFiles.append(skippedFile(
                sourceID: sourceID,
                identity: identity,
                byteCount: 0,
                reason: "symbolicLink"
            ))
            return false
        }
        guard item.isRegularFile else {
            result.skippedFiles.append(skippedFile(
                sourceID: sourceID,
                identity: identity,
                byteCount: 0,
                reason: "notRegularFile"
            ))
            return false
        }
        if item.linkCount > 1 {
            result.skippedFiles.append(skippedFile(
                sourceID: sourceID,
                identity: identity,
                byteCount: Int64(item.fileSize),
                reason: "hardlinkedFile"
            ))
            return false
        }
        return true
    }

    private nonisolated static func recordReadFailure(
        _ error: Error,
        item: SupportBundleSourceItem,
        sourceID: String,
        identity: SupportBundleArtifactIdentity,
        result: inout SupportBundleCopyResult
    ) {
        result.skippedFiles.append(skippedFile(
            sourceID: sourceID,
            identity: identity,
            byteCount: Int64(item.fileSize),
            reason: "readFailed"
        ))
        result.appendCollectionIssue(.init(
            component: "artifactRead",
            anonymousSourceIdentifier: sourceID,
            message: forgePlayTechnicalErrorSummary(error)
        ))
    }

    /// A related process-run document is an index for several more useful
    /// artifacts. Follow that graph before the broad Logs scan, but keep the
    /// traversal bounded and resolve every document through the same managed-
    /// root descriptor policy used when artifacts are copied into the bundle.
    private nonisolated static func expandedProcessRunEvidenceArtifactPaths(
        baseSourcePaths: [String],
        processRunEvidenceSourcePaths: [String],
        under root: URL,
        filesystemAnchor: URL,
        excludedRoots: [URL],
        fileManager: FileManager
    ) -> (paths: [String], issues: [SupportBundleCollectionIssue]) {
        let standardizedRoot = root.standardizedFileURL
        var orderedPaths: [String] = []
        var seenArtifactPaths = Set<String>()
        for rawPath in baseSourcePaths.prefix(maxPrioritizedLaunchArtifactPaths) {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard seenArtifactPaths.insert(path).inserted else { continue }
            orderedPaths.append(path)
        }

        let basePathSet = seenArtifactPaths
        var queuedDocumentPaths = Set<String>()
        var documentQueue: [String] = []
        for rawPath in processRunEvidenceSourcePaths {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard basePathSet.contains(path), queuedDocumentPaths.insert(path).inserted else {
                continue
            }
            documentQueue.append(path)
        }

        var issues: [SupportBundleCollectionIssue] = []
        var queueIndex = 0
        var visitedDocumentCount = 0
        var discoveryByteCount: Int64 = 0
        var artifactPathLimitReached = false
        var documentLimitReached = false
        var discoveryByteLimitReached = false
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        documentLoop: while queueIndex < documentQueue.count {
            guard visitedDocumentCount < maxProcessRunEvidenceDocuments else {
                documentLimitReached = true
                break
            }
            let documentPath = documentQueue[queueIndex]
            queueIndex += 1
            visitedDocumentCount += 1
            let sourceID = anonymousIdentifier(
                prefix: "run-evidence-index",
                index: visitedDocumentCount
            )
            let candidate = URL(fileURLWithPath: documentPath).standardizedFileURL

            guard documentPath.hasPrefix("/"),
                  candidate.path != standardizedRoot.path,
                  pathIsInsideOrEqual(candidate, root: standardizedRoot),
                  !excludedRoots.contains(where: { pathIsInsideOrEqual(candidate, root: $0) }) else {
                issues.appendBounded(.init(
                    component: "launchArtifact.runEvidenceExpansion",
                    anonymousSourceIdentifier: sourceID,
                    message: "process-run evidence document was outside the collectable managed Logs tree"
                ))
                continue
            }
            guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: standardizedRoot,
                to: candidate,
                fileManager: fileManager
            ) else {
                issues.appendBounded(.init(
                    component: "launchArtifact.runEvidenceExpansion",
                    anonymousSourceIdentifier: sourceID,
                    message: "process-run evidence document had an unsafe or missing parent directory chain"
                ))
                continue
            }

            do {
                let relativePath = String(candidate.path.dropFirst(standardizedRoot.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let item = try directSourceItem(at: candidate, relativePath: relativePath) else {
                    issues.appendBounded(.init(
                        component: "launchArtifact.runEvidenceExpansion",
                        anonymousSourceIdentifier: sourceID,
                        message: "process-run evidence document was missing during bounded discovery"
                    ))
                    continue
                }
                guard item.isRegularFile, !item.isSymbolicLink, item.linkCount == 1 else {
                    issues.appendBounded(.init(
                        component: "launchArtifact.runEvidenceExpansion",
                        anonymousSourceIdentifier: sourceID,
                        message: "process-run evidence document was not a safe single-link regular file"
                    ))
                    continue
                }

                let remainingDiscoveryBytes = maxProcessRunEvidenceDiscoveryBytes - discoveryByteCount
                guard remainingDiscoveryBytes > 0 else {
                    discoveryByteLimitReached = true
                    break
                }
                let readLimit = Int(min(
                    Int64(maxTextBytesPerArtifact),
                    remainingDiscoveryBytes
                ))
                let read = try readBoundedText(
                    from: candidate,
                    anchoredAt: filesystemAnchor,
                    maximumBytes: readLimit
                )
                discoveryByteCount += min(read.originalByteCount, Int64(readLimit))
                guard !read.truncated else {
                    issues.appendBounded(.init(
                        component: "launchArtifact.runEvidenceExpansion",
                        anonymousSourceIdentifier: sourceID,
                        message: "process-run evidence document exceeded the bounded discovery read limit and was not decoded"
                    ))
                    if readLimit < maxTextBytesPerArtifact ||
                        discoveryByteCount >= maxProcessRunEvidenceDiscoveryBytes {
                        discoveryByteLimitReached = true
                        break
                    }
                    continue
                }
                if read.snapshotChangedOrUnverifiable {
                    issues.appendBounded(.init(
                        component: "launchArtifact.runEvidenceExpansion",
                        anonymousSourceIdentifier: sourceID,
                        message: "process-run evidence document changed or could not be verified after its bounded snapshot was read"
                    ))
                }

                let document = try decoder.decode(
                    ProcessRunEvidenceDocument.self,
                    from: Data(read.text.utf8)
                )
                let relatedDocumentPaths = document.relatedRunEvidenceLogs ?? []
                if relatedDocumentPaths.count > maxRelatedRunEvidencePathsPerLaunch {
                    issues.appendBounded(.init(
                        component: "launchArtifact.runEvidenceExpansion",
                        anonymousSourceIdentifier: sourceID,
                        message: "related process-run evidence references were limited for one document"
                    ))
                }
                let artifactReferences: [(path: String, isRunEvidenceDocument: Bool)] = [
                    (document.stdoutLog, false),
                    (document.stderrLog, false)
                ] + [document.processObservationLog, document.diagnosticLog].compactMap { path in
                    path.map { ($0, false) }
                } + relatedDocumentPaths
                    .prefix(maxRelatedRunEvidencePathsPerLaunch)
                    .map { ($0, true) }

                for reference in artifactReferences {
                    guard reference.path.hasPrefix("/") else {
                        issues.appendBounded(.init(
                            component: "launchArtifact.runEvidenceExpansion",
                            anonymousSourceIdentifier: sourceID,
                            message: "process-run evidence contained a non-absolute artifact reference"
                        ))
                        continue
                    }
                    let referencedURL = URL(fileURLWithPath: reference.path).standardizedFileURL
                    let referencedPath = referencedURL.path
                    guard referencedPath != standardizedRoot.path,
                          pathIsInsideOrEqual(referencedURL, root: standardizedRoot),
                          !excludedRoots.contains(where: {
                              pathIsInsideOrEqual(referencedURL, root: $0)
                          }) else {
                        issues.appendBounded(.init(
                            component: "launchArtifact.runEvidenceExpansion",
                            anonymousSourceIdentifier: sourceID,
                            message: "process-run evidence referenced an artifact outside the collectable managed Logs tree"
                        ))
                        continue
                    }

                    if seenArtifactPaths.insert(referencedPath).inserted {
                        guard orderedPaths.count < maxPrioritizedLaunchArtifactPaths else {
                            seenArtifactPaths.remove(referencedPath)
                            artifactPathLimitReached = true
                            break documentLoop
                        }
                        orderedPaths.append(referencedPath)
                    }
                    if reference.isRunEvidenceDocument,
                       queuedDocumentPaths.insert(referencedPath).inserted {
                        documentQueue.append(referencedPath)
                    }
                }
            } catch {
                issues.appendBounded(.init(
                    component: "launchArtifact.runEvidenceExpansion",
                    anonymousSourceIdentifier: sourceID,
                    message: "process-run evidence document could not be safely decoded: \(forgePlayTechnicalErrorSummary(error))"
                ))
            }
        }

        if artifactPathLimitReached {
            issues.appendBounded(.init(
                component: "launchArtifact.runEvidenceExpansion",
                anonymousSourceIdentifier: nil,
                message: "process-run evidence expansion stopped at the prioritized artifact path limit"
            ))
        }
        if documentLimitReached {
            issues.appendBounded(.init(
                component: "launchArtifact.runEvidenceExpansion",
                anonymousSourceIdentifier: nil,
                message: "process-run evidence expansion stopped at the document traversal limit"
            ))
        }
        if discoveryByteLimitReached {
            issues.appendBounded(.init(
                component: "launchArtifact.runEvidenceExpansion",
                anonymousSourceIdentifier: nil,
                message: "process-run evidence expansion stopped at the bounded discovery byte limit"
            ))
        }
        return (orderedPaths, issues)
    }

    /// LaunchRecord paths are the authoritative pointers to the evidence needed
    /// to explain a particular failure. Resolve this bounded set directly before
    /// the broad tree scan so FileManager enumeration order cannot hide them
    /// behind the general 5,000-item scan limit.
    private nonisolated static func prioritizedLaunchArtifactSourceItems(
        _ sourcePaths: [String],
        under root: URL,
        excludedRoots: [URL],
        fileManager: FileManager
    ) -> (items: [SupportBundleSourceItem], issues: [SupportBundleCollectionIssue]) {
        let standardizedRoot = root.standardizedFileURL
        var seenPaths = Set<String>()
        var items: [SupportBundleSourceItem] = []
        var issues: [SupportBundleCollectionIssue] = []

        for (index, rawPath) in sourcePaths.enumerated() {
            let sourceID = anonymousIdentifier(prefix: "launch-artifact", index: index + 1)
            let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
            let candidatePath = candidate.path
            guard seenPaths.insert(candidatePath).inserted else { continue }
            guard candidatePath != standardizedRoot.path,
                  pathIsInsideOrEqual(candidate, root: standardizedRoot),
                  !excludedRoots.contains(where: { pathIsInsideOrEqual(candidate, root: $0) }) else {
                issues.appendBounded(.init(
                    component: "launchArtifact.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: "referenced launch artifact was outside the collectable managed Logs tree"
                ))
                continue
            }
            guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: standardizedRoot,
                to: candidate,
                fileManager: fileManager
            ) else {
                issues.appendBounded(.init(
                    component: "launchArtifact.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: "referenced launch artifact had an unsafe or missing parent directory chain"
                ))
                continue
            }

            let relativePath = String(candidatePath.dropFirst(standardizedRoot.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            do {
                guard let item = try directSourceItem(
                    at: candidate,
                    relativePath: relativePath
                ) else {
                    issues.appendBounded(.init(
                        component: "launchArtifact.priority",
                        anonymousSourceIdentifier: sourceID,
                        message: "referenced launch artifact was missing when the support bundle was collected"
                    ))
                    continue
                }
                if item.isDirectory, !item.isSymbolicLink {
                    issues.appendBounded(.init(
                        component: "launchArtifact.priority",
                        anonymousSourceIdentifier: sourceID,
                        message: "referenced launch artifact was a directory rather than a file"
                    ))
                    continue
                }
                items.append(item)
            } catch {
                issues.appendBounded(.init(
                    component: "launchArtifact.priority",
                    anonymousSourceIdentifier: sourceID,
                    message: forgePlayTechnicalErrorSummary(error)
                ))
            }
        }
        return (items, issues)
    }

    private nonisolated static func supportBundleSourceItems(
        under root: URL,
        excludedRoots: [URL],
        fileManager: FileManager
    ) -> (items: [SupportBundleSourceItem], issues: [SupportBundleCollectionIssue]) {
        var issues: [SupportBundleCollectionIssue] = []
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .linkCountKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return true
            }
        ) else {
            return ([], [.init(
                component: "scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(CocoaError(.fileReadUnknown))
            )])
        }

        var items: [SupportBundleSourceItem] = []
        var visitedItemCount = 0
        for case let url as URL in enumerator {
            if visitedItemCount >= maxScannedItemsPerRoot {
                issues.appendBounded(.init(
                    component: "scan",
                    anonymousSourceIdentifier: nil,
                    message: "scan stopped at the configured item limit"
                ))
                break
            }
            visitedItemCount += 1
            do {
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .linkCountKey,
                    .contentModificationDateKey
                ])
                if excludedRoots.contains(where: { pathIsInsideOrEqual(url, root: $0) }) {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if values.isSymbolicLink == true, values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                let relativePath = String(url.path.dropFirst(root.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relativePath.isEmpty else { continue }
                items.append(.init(
                    url: url,
                    relativePath: relativePath,
                    isDirectory: values.isDirectory == true,
                    isRegularFile: values.isRegularFile == true,
                    isSymbolicLink: values.isSymbolicLink == true,
                    fileSize: values.fileSize ?? 0,
                    linkCount: values.linkCount ?? 1,
                    contentModificationDate: values.contentModificationDate
                ))
            } catch {
                issues.appendBounded(.init(
                    component: "scan.metadata",
                    anonymousSourceIdentifier: nil,
                    message: forgePlayTechnicalErrorSummary(error)
                ))
            }
        }
        if let enumerationError {
            issues.appendBounded(.init(
                component: "scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(enumerationError)
            ))
        }
        return (items.sorted(by: newestSourceItemFirst), issues)
    }

    /// A non-recursive, bounded scan of the one known Steam dumps directory.
    /// File names stay internal to sorting/redaction and are never used as ZIP
    /// entry names or manifest source identifiers.
    private nonisolated static func steamDumpSourceItems(
        under root: URL,
        fileManager: FileManager
    ) -> (
        items: [SupportBundleSourceItem],
        issues: [SupportBundleCollectionIssue],
        scannedItemCount: Int,
        limitReached: Bool
    ) {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            return ([], [.init(
                component: "steamLateEvidence.dumps",
                anonymousSourceIdentifier: nil,
                message: "Steam dump directory could not be enumerated"
            )], 0, false)
        }

        var items: [SupportBundleSourceItem] = []
        var issues: [SupportBundleCollectionIssue] = []
        var scannedItemCount = 0
        var limitReached = false
        for case let url as URL in enumerator {
            if scannedItemCount >= maxSteamDumpScannedItems {
                limitReached = true
                issues.appendBounded(.init(
                    component: "steamLateEvidence.dumps",
                    anonymousSourceIdentifier: nil,
                    message: "Steam dump metadata scan stopped at the configured item limit"
                ))
                break
            }
            scannedItemCount += 1
            do {
                guard let item = try directSourceItem(
                    at: url,
                    relativePath: url.lastPathComponent
                ) else {
                    issues.appendBounded(.init(
                        component: "steamLateEvidence.dumps",
                        anonymousSourceIdentifier: nil,
                        message: "a dump entry disappeared while metadata was being collected"
                    ))
                    continue
                }
                if item.isDirectory, !item.isSymbolicLink { continue }
                items.append(item)
            } catch {
                issues.appendBounded(.init(
                    component: "steamLateEvidence.dumps",
                    anonymousSourceIdentifier: nil,
                    message: forgePlayTechnicalErrorSummary(error)
                ))
            }
        }
        if let enumerationError {
            issues.appendBounded(.init(
                component: "steamLateEvidence.dumps",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(enumerationError)
            ))
        }
        return (
            items.sorted(by: newestSourceItemFirst),
            issues,
            scannedItemCount,
            limitReached
        )
    }

    /// Uses lstat so an absent optional Steam artifact is distinguishable from
    /// a metadata failure and so the final component is never followed merely
    /// to decide whether it is collectable.
    private nonisolated static func directSourceItem(
        at url: URL,
        relativePath: String
    ) throws -> SupportBundleSourceItem? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            let capturedErrno = errno
            if capturedErrno == ENOENT || capturedErrno == ENOTDIR {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }
        let itemType = status.st_mode & S_IFMT
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) +
                (TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
        )
        return .init(
            url: url,
            relativePath: relativePath,
            isDirectory: itemType == S_IFDIR,
            isRegularFile: itemType == S_IFREG,
            isSymbolicLink: itemType == S_IFLNK,
            fileSize: max(0, Int(clamping: status.st_size)),
            linkCount: max(0, Int(clamping: status.st_nlink)),
            contentModificationDate: modifiedAt
        )
    }

    /// Prefixes can contain a complete Windows filesystem. Walking that tree to
    /// find a single `prefix.json` per prefix both wastes time and can exhaust the
    /// scan budget before later prefixes are reached. Inspect only the managed
    /// prefix containers and their direct metadata file.
    private nonisolated static func prefixMetadataSourceItems(
        under root: URL,
        fileManager: FileManager
    ) -> (items: [SupportBundleSourceItem], issues: [SupportBundleCollectionIssue]) {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(root, fileManager: fileManager)
        } catch {
            return ([], [.init(
                component: "prefixMetadata.scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(error)
            )])
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .linkCountKey,
            .contentModificationDateKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            return ([], [.init(
                component: "prefixMetadata.scan",
                anonymousSourceIdentifier: nil,
                message: "prefix metadata root could not be enumerated"
            )])
        }

        var items: [SupportBundleSourceItem] = []
        var issues: [SupportBundleCollectionIssue] = []
        var children: [URL] = []
        var visitedItemCount = 0
        var limitReached = false
        for case let child as URL in enumerator {
            if visitedItemCount >= maxScannedItemsPerRoot {
                limitReached = true
                break
            }
            visitedItemCount += 1
            children.append(child)
        }
        if let enumerationError {
            issues.appendBounded(.init(
                component: "prefixMetadata.scan",
                anonymousSourceIdentifier: nil,
                message: forgePlayTechnicalErrorSummary(enumerationError)
            ))
        }
        let sortedChildren = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if limitReached {
            issues.appendBounded(.init(
                component: "prefixMetadata.scan",
                anonymousSourceIdentifier: nil,
                message: "prefix metadata scan stopped at the configured item limit"
            ))
        }
        for child in sortedChildren {
            do {
                let childValues = try child.resourceValues(forKeys: keys)
                let candidate: URL
                if childValues.isSymbolicLink == true {
                    issues.appendBounded(.init(
                        component: "prefixMetadata.scan",
                        anonymousSourceIdentifier: nil,
                        message: "a symbolic-link prefix container was skipped"
                    ))
                    continue
                } else if childValues.isDirectory == true {
                    candidate = child.appending(path: "prefix.json")
                } else if childValues.isRegularFile == true,
                          child.lastPathComponent == "prefix.json" {
                    candidate = child
                } else {
                    continue
                }

                guard fileManager.fileExists(atPath: candidate.path) else { continue }
                let values = try candidate.resourceValues(forKeys: keys)
                let relativePath = String(candidate.path.dropFirst(root.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                items.append(.init(
                    url: candidate,
                    relativePath: relativePath,
                    isDirectory: values.isDirectory == true,
                    isRegularFile: values.isRegularFile == true,
                    isSymbolicLink: values.isSymbolicLink == true,
                    fileSize: values.fileSize ?? 0,
                    linkCount: values.linkCount ?? 1,
                    contentModificationDate: values.contentModificationDate
                ))
            } catch {
                issues.appendBounded(.init(
                    component: "prefixMetadata.scan",
                    anonymousSourceIdentifier: nil,
                    message: forgePlayTechnicalErrorSummary(error)
                ))
            }
        }
        return (items.sorted(by: newestSourceItemFirst), issues)
    }

    private nonisolated static func newestSourceItemFirst(
        _ lhs: SupportBundleSourceItem,
        _ rhs: SupportBundleSourceItem
    ) -> Bool {
        let lhsDate = lhs.contentModificationDate ?? .distantPast
        let rhsDate = rhs.contentModificationDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
    }

    private enum SecureOpenItemKind: Equatable {
        case directory
        case regularFile
    }

    private nonisolated static func validateSecureDirectory(
        _ url: URL,
        anchoredAt anchor: URL
    ) throws {
        let descriptor = try openSecureDescriptor(
            for: url,
            anchoredAt: anchor,
            kind: .directory
        )
        Darwin.close(descriptor)
    }

    /// Resolve every component below the already validated managed root with
    /// `openat(..., O_NOFOLLOW)`. A path-based check followed by `open(path)`
    /// would still follow a Logs directory or intermediate directory replaced
    /// after enumeration.
    private nonisolated static func openSecureDescriptor(
        for url: URL,
        anchoredAt anchor: URL,
        kind: SecureOpenItemKind
    ) throws -> Int32 {
        let standardizedAnchor = anchor.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        guard pathIsInsideOrEqual(standardizedURL, root: standardizedAnchor) else {
            throw POSIXError(.EPERM)
        }

        var descriptor = Darwin.open(
            standardizedAnchor.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let anchorComponents = standardizedAnchor.pathComponents
        let targetComponents = standardizedURL.pathComponents
        let relativeComponents = targetComponents.dropFirst(anchorComponents.count)
        for (index, component) in relativeComponents.enumerated() {
            let isFinal = index == relativeComponents.count - 1
            let flags: Int32
            if isFinal, kind == .regularFile {
                flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            } else {
                flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            }
            let nextDescriptor = component.withCString {
                Darwin.openat(descriptor, $0, flags)
            }
            let capturedErrno = errno
            Darwin.close(descriptor)
            guard nextDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
            }
            descriptor = nextDescriptor
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let capturedErrno = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }
        let expectedType: mode_t = kind == .directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard status.st_mode & S_IFMT == expectedType,
              kind == .directory || status.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        return descriptor
    }

    private nonisolated static func readBoundedText(
        from url: URL,
        anchoredAt anchor: URL,
        maximumBytes: Int = maxTextBytesPerArtifact
    ) throws -> SupportBundleTextRead {
        guard maximumBytes > 0 else {
            throw SupportBundleServiceError.metadataReadFailed(url, CocoaError(.fileReadTooLarge))
        }
        let descriptor = try openSecureDescriptor(
            for: url,
            anchoredAt: anchor,
            kind: .regularFile
        )
        defer { Darwin.close(descriptor) }
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size >= 0 else {
            throw SupportBundleServiceError.metadataReadFailed(url, CocoaError(.fileReadUnknown))
        }
        let originalSize = Int64(initialStatus.st_size)
        let truncated = originalSize > Int64(maximumBytes)
        let headLimit = truncated ? maximumBytes / 2 : Int(originalSize)
        let head = try preadData(descriptor: descriptor, offset: 0, count: headLimit)
        let encoding = detectedEncoding(head)
        let headText = decodedText(head, encoding: encoding)
        var text = headText.text
        var lossy = headText.lossy
        if truncated {
            var tailOffset = max(0, originalSize - Int64(maximumBytes / 2))
            if encoding.isUTF16, tailOffset % 2 != 0 { tailOffset += 1 }
            let tailCount = Int(max(0, originalSize - tailOffset))
            let tail = try preadData(descriptor: descriptor, offset: tailOffset, count: tailCount)
            let tailText = decodedText(tail, encoding: encoding)
            lossy = lossy || tailText.lossy
            text += "\n[ForgePlay: source truncated; original_bytes=\(originalSize); retained=head+tail]\n"
            text += tailText.text
        }
        var finalStatus = stat()
        let finalStatusAvailable = fstat(descriptor, &finalStatus) == 0
        return SupportBundleTextRead(
            text: text,
            originalByteCount: originalSize,
            encoding: encoding.name,
            truncated: truncated,
            lossy: lossy,
            snapshotChangedOrUnverifiable: !finalStatusAvailable ||
                Int64(finalStatus.st_size) != originalSize ||
                finalStatus.st_mtimespec.tv_sec != initialStatus.st_mtimespec.tv_sec ||
                finalStatus.st_mtimespec.tv_nsec != initialStatus.st_mtimespec.tv_nsec
        )
    }

    private enum TextEncoding {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case lossyUTF8

        var name: String {
            switch self {
            case .utf8: "utf-8"
            case .utf16LittleEndian: "utf-16le"
            case .utf16BigEndian: "utf-16be"
            case .lossyUTF8: "utf-8-lossy"
            }
        }

        var isUTF16: Bool {
            self == .utf16LittleEndian || self == .utf16BigEndian
        }
    }

    private nonisolated static func detectedEncoding(_ data: Data) -> TextEncoding {
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        let sample = Array(data.prefix(512))
        guard sample.count >= 4 else { return .lossyUTF8 }
        let evenNulls = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        let oddNulls = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
        if oddNulls > sample.count / 8 { return .utf16LittleEndian }
        if evenNulls > sample.count / 8 { return .utf16BigEndian }
        return .lossyUTF8
    }

    private nonisolated static func decodedText(
        _ data: Data,
        encoding: TextEncoding
    ) -> (text: String, lossy: Bool) {
        let stringEncoding: String.Encoding
        switch encoding {
        case .utf8, .lossyUTF8:
            stringEncoding = .utf8
        case .utf16LittleEndian:
            stringEncoding = .utf16LittleEndian
        case .utf16BigEndian:
            stringEncoding = .utf16BigEndian
        }
        if let exact = String(data: data, encoding: stringEncoding) {
            return (exact, encoding == .lossyUTF8)
        }
        return (String(decoding: data, as: UTF8.self), true)
    }

    private nonisolated static func preadData(
        descriptor: Int32,
        offset: Int64,
        count: Int
    ) throws -> Data {
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

    private nonisolated static func artifactIdentity(
        for item: SupportBundleSourceItem
    ) -> SupportBundleArtifactIdentity {
        let relative = item.relativePath
        let lowerName = item.url.lastPathComponent.lowercased()
        let sourceCategory: String = {
            guard let first = relative.split(separator: "/").first else { return "logs" }
            switch first.lowercased() {
            case "launch": return "launch"
            case "install": return "install"
            case "runtime": return "runtime"
            case "diagnostic": return "diagnostic"
            default: return "logs"
            }
        }()
        let role: String
        let lowerRelativePath = relative.lowercased()
        let isGameRunArtifact = lowerRelativePath.hasPrefix("gameruns/") ||
            lowerRelativePath.hasPrefix("launch/gameruns/") ||
            lowerRelativePath.contains("/gameruns/")
        if lowerName == "game-launch-capture.json" {
            role = "gameLaunchCapture"
        } else if lowerName == "game-launch-diagnostic.json" {
            role = "gameLaunchDiagnostic"
        } else if lowerName.hasPrefix("game-launch-attempt-"),
                  lowerName.hasSuffix(".json") {
            role = "gameLaunchAttemptDiagnostic"
        } else if lowerName.hasPrefix("wine-crash-"),
                  lowerName.hasSuffix(".log") {
            role = "wineCrashReport"
        } else if isGameRunArtifact, lowerName.hasSuffix(".log") {
            role = "rendererLog"
        } else if lowerName == "screen-ocr.txt" {
            role = "screenOCR"
        } else if lowerName.hasSuffix(".run.json") {
            role = "processRunMetadata"
        } else if lowerName.hasSuffix(".diagnostics.log") {
            role = "diagnostics"
        } else if lowerName.contains("process-observation") {
            role = "processObservation"
        } else if lowerName.hasSuffix("_stdout.log") {
            role = "stdout"
        } else if lowerName.hasSuffix("_stderr.log") {
            role = "stderr"
        } else if lowerName == "manifest.json" {
            role = "evidenceManifest"
        } else if lowerName == "index.md" {
            role = "evidenceIndex"
        } else if lowerName == "final-verdict.txt" {
            role = "finalVerdict"
        } else if ["png", "jpg", "jpeg", "heic"].contains(item.url.pathExtension.lowercased()) {
            role = "screenEvidence"
        } else if ["dmp", "mdmp", "crash"].contains(item.url.pathExtension.lowercased()) {
            role = "crashEvidence"
        } else {
            role = "supportingLog"
        }
        let match = uuidMatch(in: relative)
        let runIdentifier = match?.value.lowercased()
        let actionName: String?
        if let match,
           let prefixRange = relative.range(
               of: match.value,
               options: [.caseInsensitive]
           ) {
            var prefix = String(relative[..<prefixRange.lowerBound])
            if let component = prefix.split(separator: "/").last {
                prefix = String(component)
            }
            prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
            if prefix.count >= 20,
               prefix.prefix(4).allSatisfy(\.isNumber),
               prefix.dropFirst(4).first == "-" {
                prefix = String(prefix.dropFirst(20))
            }
            actionName = prefix.isEmpty ? nil : prefix
        } else {
            actionName = nil
        }
        return .init(
            sourceCategory: sourceCategory,
            role: role,
            runIdentifier: runIdentifier,
            actionName: actionName
        )
    }

    private nonisolated static func uuidMatch(in text: String) -> (value: String, range: NSRange)? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let uuidExpression,
              let match = uuidExpression.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return (String(text[swiftRange]), match.range)
    }

    private nonisolated static func archiveEntry(
        sourceID: String,
        sourceURL: URL,
        identity: SupportBundleArtifactIdentity,
        contentKind: String
    ) -> String {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        // A malformed or truncated JSON source is intentionally preserved as
        // redacted diagnostic text. Give the staged copy a text extension so
        // the closure validator and downstream tools never mistake it for
        // machine-readable JSON.
        let fileExtension = sourceExtension == "json" &&
            !contentKind.hasPrefix("redactedStructuredJSON")
            ? "txt"
            : sourceExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        guard let runIdentifier = identity.runIdentifier else {
            return "redacted-logs/unassigned/\(sourceID)\(suffix)"
        }
        let safeRole = PathManager.sanitizedFileName(identity.role)
        return "redacted-logs/runs/\(runIdentifier)/\(safeRole)-\(sourceID)\(suffix)"
    }

    private nonisolated static func isTextArtifact(_ url: URL) -> Bool {
        ["log", "txt", "json", "reg", "acf", "vdf", "plist", "crash", "md", "csv", "yml", "yaml"]
            .contains(url.pathExtension.lowercased())
    }

    private nonisolated static func binaryEvidenceExclusionReason(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic":
            "imageEvidenceExcludedForPrivacy"
        case "dmp", "mdmp":
            "binaryCrashEvidenceExcluded"
        default:
            "unsupportedBinaryOrFileType"
        }
    }

    private nonisolated static func includedFile(
        sourceID: String,
        archiveEntry: String,
        identity: SupportBundleArtifactIdentity,
        read: SupportBundleTextRead,
        archivedData: Data,
        sourceModifiedAt: Date?,
        contentKind: String
    ) -> SupportBundleIncludedFile {
        .init(
            anonymousSourceIdentifier: sourceID,
            archiveEntry: archiveEntry,
            sourceCategory: identity.sourceCategory,
            artifactRole: identity.role,
            runIdentifier: identity.runIdentifier,
            actionName: identity.actionName,
            originalByteCount: read.originalByteCount,
            byteCount: Int64(archivedData.count),
            contentKind: contentKind,
            sourceEncoding: read.encoding,
            truncated: read.truncated,
            sourceModifiedAt: sourceModifiedAt,
            sha256: sha256(archivedData)
        )
    }

    private nonisolated static func includedDataFile(
        sourceID: String,
        archiveEntry: String,
        identity: SupportBundleArtifactIdentity,
        data: Data,
        contentKind: String
    ) -> SupportBundleIncludedFile {
        .init(
            anonymousSourceIdentifier: sourceID,
            archiveEntry: archiveEntry,
            sourceCategory: identity.sourceCategory,
            artifactRole: identity.role,
            runIdentifier: identity.runIdentifier,
            actionName: identity.actionName,
            originalByteCount: Int64(data.count),
            byteCount: Int64(data.count),
            contentKind: contentKind,
            sourceEncoding: "utf-8",
            truncated: false,
            sourceModifiedAt: nil,
            sha256: sha256(data)
        )
    }

    private nonisolated static func skippedFile(
        sourceID: String,
        identity: SupportBundleArtifactIdentity,
        byteCount: Int64,
        reason: String
    ) -> SupportBundleSkippedFile {
        .init(
            anonymousSourceIdentifier: sourceID,
            sourceCategory: identity.sourceCategory,
            artifactRole: identity.role,
            runIdentifier: identity.runIdentifier,
            actionName: identity.actionName,
            byteCount: byteCount,
            reason: reason
        )
    }

    private nonisolated static func metadataIncludedFile(
        name: String,
        archiveEntry: String,
        data: Data,
        contentKind: String = "structuredMetadata"
    ) -> SupportBundleIncludedFile {
        .init(
            anonymousSourceIdentifier: "metadata-\(PathManager.sanitizedFileName(name))",
            archiveEntry: archiveEntry,
            sourceCategory: "metadata",
            artifactRole: name,
            runIdentifier: nil,
            actionName: nil,
            originalByteCount: Int64(data.count),
            byteCount: Int64(data.count),
            contentKind: contentKind,
            sourceEncoding: "utf-8",
            truncated: false,
            sourceModifiedAt: nil,
            sha256: sha256(data)
        )
    }

    private nonisolated static func metadataSkippedFile(
        name: String,
        byteCount: Int,
        reason: String
    ) -> SupportBundleSkippedFile {
        .init(
            anonymousSourceIdentifier: "metadata-\(PathManager.sanitizedFileName(name))",
            sourceCategory: "metadata",
            artifactRole: name,
            runIdentifier: nil,
            actionName: nil,
            byteCount: Int64(byteCount),
            reason: reason
        )
    }

    private nonisolated static func recordInputLimitIssue(
        component: String,
        originalCount: Int,
        retainedCount: Int,
        into issues: inout [SupportBundleCollectionIssue]
    ) {
        guard originalCount > retainedCount else { return }
        issues.appendBounded(.init(
            component: component,
            anonymousSourceIdentifier: nil,
            message: "retained \(retainedCount) of \(originalCount) inputs because the support-bundle input limit was reached"
        ))
    }

    private nonisolated static func unavailableSteamLateEvidenceStatus()
    -> SupportBundleSteamLateEvidenceStatus {
        .init(
            state: "notAvailable",
            logsDirectoryState: "notPresent",
            dumpsDirectoryState: "notPresent",
            includedLogRoles: [],
            missingOptionalLogRoles: steamLateLogAllowlist.map(\.role).sorted(),
            dumpInventoryArchiveEntry: nil,
            observedDumpCount: 0,
            retainedDumpCount: 0
        )
    }

    private nonisolated static func launchRecordSource(
        _ record: LaunchRecord
    ) -> SupportBundleLaunchRecordSource {
        var paths: [String: String] = [:]
        if let path = record.stdoutPath { paths["stdout"] = path }
        if let path = record.stderrPath { paths["stderr"] = path }
        if let path = record.diagnosticLogPath { paths["diagnostics"] = path }
        if let path = record.processObservationPath { paths["processObservation"] = path }
        if let path = record.runEvidencePath { paths["processRunMetadata"] = path }
        for (index, path) in record.relatedRunEvidencePaths
            .prefix(maxRelatedRunEvidencePathsPerLaunch)
            .enumerated() {
            paths["relatedProcessRunMetadata.\(index + 1)"] = path
        }
        return .init(
            recordIdentifier: record.id,
            gameID: record.gameId,
            gameName: record.gameName,
            gameBuildID: record.gameBuildID,
            gameManifestStateFlags: record.gameManifestStateFlags,
            gameInstalledByteCount: record.gameInstalledByteCount,
            gameLastUpdatedAt: record.gameLastUpdatedAt,
            gameManifestAvailable: record.gameManifestAvailable,
            gameManifestCaptureIssue: record.gameManifestCaptureIssue,
            gameAssociationSource: record.gameAssociationSource,
            prefixIdentifier: record.prefixId,
            commandKind: record.commandKind,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            exitCode: record.exitCode,
            forgePlayStatusCode: record.forgePlayStatusCode,
            status: record.status,
            steamUIVerificationStatus: record.steamUIVerificationStatus,
            steamUIVerificationDetail: record.steamUIVerificationDetail,
            steamUISurface: record.steamUISurfaceRawValue,
            hostAppSessionIdentifier: record.hostAppSessionID,
            environmentGenerationIdentifier: record.environmentGenerationID,
            processSteamUIVerificationStatus: record.processSteamUIVerificationStatus,
            didTimeOut: record.didTimeOut,
            waitedForExit: record.waitedForExit,
            processIdentifier: record.processIdentifier,
            processOutcome: record.processOutcome,
            terminationSignal: record.terminationSignal,
            rawWaitStatus: record.rawWaitStatus,
            evidenceCaptureWarning: record.evidenceCaptureWarning,
            diagnosticCaptureWarning: record.diagnosticCaptureWarning,
            failureDomain: record.failureDomain,
            failureCode: record.failureCode,
            failureSummary: record.failureSummary,
            artifactPaths: paths
        )
    }

    private nonisolated static func launchRecordSnapshot(
        _ source: SupportBundleLaunchRecordSource,
        archiveEntryBySourcePath: [String: String]
    ) -> SupportBundleLaunchRecordSnapshot {
        var references: [String: String] = [:]
        var missing: [String] = []
        for (role, path) in source.artifactPaths.sorted(by: { $0.key < $1.key }) {
            if let entry = archiveEntryBySourcePath[URL(fileURLWithPath: path).standardizedFileURL.path] {
                references[role] = entry
            } else {
                missing.append(role)
            }
        }
        let duration = source.endedAt.map {
            Int64(max(0, $0.timeIntervalSince(source.startedAt) * 1_000))
        }
        return .init(
            recordIdentifier: source.recordIdentifier,
            gameID: source.gameID,
            gameName: source.gameName,
            gameBuildID: source.gameBuildID,
            gameManifestStateFlags: source.gameManifestStateFlags,
            gameInstalledByteCount: source.gameInstalledByteCount,
            gameLastUpdatedAt: source.gameLastUpdatedAt,
            gameManifestAvailable: source.gameManifestAvailable,
            gameManifestCaptureIssue: source.gameManifestCaptureIssue,
            gameAssociationSource: source.gameAssociationSource,
            prefixIdentifier: source.prefixIdentifier,
            commandKind: source.commandKind,
            startedAt: source.startedAt,
            endedAt: source.endedAt,
            durationMilliseconds: duration,
            exitCode: source.exitCode,
            forgePlayStatusCode: source.forgePlayStatusCode,
            status: source.status,
            steamUIVerificationStatus: source.steamUIVerificationStatus,
            steamUIVerificationDetail: source.steamUIVerificationDetail,
            steamUISurface: source.steamUISurface,
            hostAppSessionIdentifier: source.hostAppSessionIdentifier,
            environmentGenerationIdentifier: source.environmentGenerationIdentifier,
            processSteamUIVerificationStatus: source.processSteamUIVerificationStatus,
            didTimeOut: source.didTimeOut,
            waitedForExit: source.waitedForExit,
            processIdentifier: source.processIdentifier,
            processOutcome: source.processOutcome,
            terminationSignal: source.terminationSignal,
            rawWaitStatus: source.rawWaitStatus,
            evidenceCaptureWarning: source.evidenceCaptureWarning,
            diagnosticCaptureWarning: source.diagnosticCaptureWarning,
            failureDomain: source.failureDomain,
            failureCode: source.failureCode,
            failureSummary: source.failureSummary,
            artifactReferences: references,
            missingArtifactRoles: missing
        )
    }

    private nonisolated static func makeReadme(
        bundleIdentifier: String,
        createdAt: Date,
        incident: SupportBundleIncidentSnapshot?,
        environment: DiagnosticEnvironmentSnapshot,
        launches: [SupportBundleLaunchRecordSnapshot],
        steamLateEvidence: SupportBundleSteamLateEvidenceStatus,
        includedFiles: [SupportBundleIncludedFile],
        skippedFiles: [SupportBundleSkippedFile],
        collectionIssues: [SupportBundleCollectionIssue]
    ) -> String {
        let collectionStatus = skippedFiles.isEmpty && collectionIssues.isEmpty ? "complete" : "partial"
        let osBuild = environment.host.operatingSystemBuild ?? "unknown"
        let model = environment.host.modelIdentifier ?? "unknown"
        let cpu = environment.host.cpuBrand ?? "unknown"
        let graphics = environment.graphicsDevices.map(\.name).joined(separator: ", ").nilIfEmpty ?? "unknown"
        let synchronizationSelection = environment.synchronizationSelection ?? "not captured"
        let appliedSynchronizationSelection = environment.appliedSynchronizationSelection ?? "not captured"
        let appliedSynchronizationBackend = environment.appliedSynchronizationBackend ?? "not captured"
        let rendererSelection = environment.rendererSelection ?? "not captured"
        let videoMemorySelection = environment.videoMemorySelection ?? "not captured"
        let resolvedVideoMemory = environment.resolvedVideoMemoryMB.map(String.init) ?? "unknown"
        let runtimeBackend = environment.runtime.graphicsBackend ?? "unknown"
        let direct3D = environment.runtime.supportedDirect3DGenerations.joined(separator: ", ").nilIfEmpty ?? "none detected"
        let direct3DSupportByBackend = environment.runtime.supportedDirect3DGenerationsByBackend ?? [:]
        let direct3DByBackend = direct3DSupportByBackend
            .keys
            .sorted()
            .map { backend in
                "\(backend)=[\(direct3DSupportByBackend[backend, default: []].joined(separator: ","))]"
            }
            .joined(separator: "; ")
            .nilIfEmpty ?? "none detected"
        let runtimeIdentity = environment.runtime.identity
        var lines = [
            "# ForgePlay Support Bundle",
            "",
            "Bundle ID: \(bundleIdentifier)",
            "Created: \(ISO8601DateFormatter().string(from: createdAt))",
            "Schema: 3",
            "Collection status: \(collectionStatus)",
            "",
            "## Start here",
            "",
            "`metadata/bundle-manifest.json` is the authoritative machine-readable index. It links the reported incident and each launch to redacted artifacts without exposing original file names or user paths."
        ]
        appendIncidentSection(incident, to: &lines)
        lines.append(contentsOf: [
            "",
            "## Host (captured when this support bundle was created)",
            "",
            "- Application: \(environment.application.name)",
            "- App version/build: \(environment.application.version) (\(environment.application.build))",
            "- Build configuration: \(environment.application.buildConfiguration)",
            "- macOS: \(environment.host.operatingSystemVersion) (build \(osBuild))",
            "- Model: \(model)",
            "- CPU: \(cpu)",
            "- Memory: \(environment.host.physicalMemoryBytes) bytes",
            "- Architecture: \(environment.application.processArchitecture)",
            "- Sandbox: \(environment.application.sandboxed)",
            "- Graphics: \(graphics)",
            "- Runtime executable: \(environment.runtime.executableName ?? "not configured")",
            "- Wine synchronization backends: \(environment.runtime.supportedSynchronizationBackends?.joined(separator: ", ").nilIfEmpty ?? "not detected")",
            "- Synchronization requested: \(synchronizationSelection)",
            "- Synchronization applied to Steam prefix: selection=\(appliedSynchronizationSelection), backend=\(appliedSynchronizationBackend)",
            "- Runtime graphics backend: \(runtimeBackend)",
            "- Runtime Direct3D generations: \(direct3D)",
            "- Runtime Direct3D generations by backend: \(direct3DByBackend)",
            "- Renderer selection: \(rendererSelection)",
            "- Video memory policy: \(videoMemorySelection) / resolved \(resolvedVideoMemory) MB",
            "- Runtime identity: state=\(runtimeIdentity.state), source=\(runtimeIdentity.identitySource ?? "unknown"), runtimeIdentifier=\(runtimeIdentity.runtimeIdentifier ?? "unknown"), wine=\(runtimeIdentity.wineVersion ?? "unknown"), architecture=\(runtimeIdentity.architecture ?? "unknown")",
            "- Runtime source tree fingerprint: \(runtimeIdentity.sourceTreeSHA256 ?? "unavailable")",
            "- Runtime patch-set fingerprint: \(runtimeIdentity.patchSetSHA256 ?? "unavailable")",
            "- Runtime build fingerprint: \(runtimeIdentity.runnerBuildFingerprint ?? "unavailable")",
            "- Runtime prefix compatibility fingerprint: \(runtimeIdentity.prefixCompatibilityFingerprint ?? "unavailable")",
            "- Runtime core payload fingerprint: \(runtimeIdentity.corePayloadFingerprint ?? "unavailable")"
        ])
        for issue in runtimeIdentity.identityIssues {
            lines.append("- Runtime identity issue: \(issue)")
        }
        if let validationError = runtimeIdentity.validationError {
            lines.append("- Runtime identity validation error: \(validationError)")
        }
        lines.append(contentsOf: ["", "### Displays", ""])
        if environment.displays.isEmpty {
            lines.append("- No display metadata was captured.")
        } else {
            for (index, display) in environment.displays.enumerated() {
                lines.append(
                    "- Display \(index + 1): \(display.pixelWidth)x\(display.pixelHeight), scale=\(display.scaleFactor), primary=\(display.primary)"
                )
            }
        }
        lines.append(contentsOf: ["", "### Volumes", ""])
        if environment.volumes.isEmpty {
            lines.append("- No volume metadata was captured.")
        } else {
            for volume in environment.volumes {
                lines.append(
                    "- \(volume.role): available=\(volume.available), format=\(volume.formatDescription ?? "unknown"), capacityBytes=\(volume.totalCapacityBytes.map(String.init) ?? "unknown"), freeBytes=\(volume.availableCapacityBytes.map(String.init) ?? "unknown"), readOnly=\(volume.readOnly.map(String.init) ?? "unknown"), removable=\(volume.removable.map(String.init) ?? "unknown"), internal=\(volume.internalVolume.map(String.init) ?? "unknown")"
                )
            }
        }
        lines.append(contentsOf: ["", "## Selected game reference", ""])
        if let game = environment.selectedGame {
            lines.append("- Steam App ID: \(game.steamAppID)")
            lines.append("- Name: \(game.name)")
            lines.append("- Manifest available: \(game.manifestAvailable)")
            lines.append("- Build ID: \(game.buildID ?? "unknown")")
            lines.append("- State flags: \(game.stateFlags.map(String.init) ?? "unknown")")
            lines.append("- This is the game selected when support context was captured; it is not proof that the game executable ran.")
        } else {
            lines.append("- No game was selected when this bundle was created. Use launch game IDs and process evidence instead of assuming a current game.")
        }
        lines.append(contentsOf: ["", "## Launch timeline", ""])
        lines.append("- Host/runtime values above are current bundle-creation context. Each launch's linked Steam diagnostics and process `.run.json` are the authoritative launch-time runtime, renderer, command, and host evidence; do not attribute current settings to an older launch without matching its timestamps and environment generation.")
        if launches.isEmpty {
            lines.append("- No persisted launch records were available.")
        } else {
            for launch in launches.prefix(50) {
                let end = launch.endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not ended"
                let outcome = launch.processOutcome ?? "unknown"
                let exitCode = launch.exitCode.map(String.init) ?? "none"
                let forgePlayStatusCode = launch.forgePlayStatusCode.map(String.init) ?? "none"
                let gameID = launch.gameID ?? "none"
                lines.append(
                    "- \(launch.recordIdentifier): \(launch.commandKind), status=\(launch.status), outcome=\(outcome), processExit=\(exitCode), forgePlayStatus=\(forgePlayStatusCode), started=\(ISO8601DateFormatter().string(from: launch.startedAt)), ended=\(end), game=\(gameID)"
                )
                if let associationSource = launch.gameAssociationSource {
                    lines.append(
                        "  - game association source: \(associationSource); launch-time selected reference, not execution verification"
                    )
                }
                if launch.gameID != nil || launch.gameName != nil {
                    lines.append(
                        "  - selected game snapshot: name=\(launch.gameName ?? "unknown"), build=\(launch.gameBuildID ?? "unknown"), stateFlags=\(launch.gameManifestStateFlags.map(String.init) ?? "unknown"), installedBytes=\(launch.gameInstalledByteCount.map(String.init) ?? "unknown"), manifestAvailable=\(launch.gameManifestAvailable.map(String.init) ?? "unknown")"
                    )
                    if let lastUpdated = launch.gameLastUpdatedAt {
                        lines.append("  - selected game last updated: \(ISO8601DateFormatter().string(from: lastUpdated))")
                    }
                    if let captureIssue = launch.gameManifestCaptureIssue {
                        lines.append("  - selected game manifest capture issue: \(captureIssue)")
                    }
                }
                if let failure = launch.failureSummary { lines.append("  - failure: \(failure)") }
                if let warning = launch.diagnosticCaptureWarning { lines.append("  - diagnostics warning: \(warning)") }
                if !launch.missingArtifactRoles.isEmpty {
                    lines.append("  - missing artifacts: \(launch.missingArtifactRoles.joined(separator: ", "))")
                }
            }
        }
        lines.append(contentsOf: [
            "",
            "## Steam late evidence",
            "",
            "- State: \(steamLateEvidence.state)",
            "- Logs directory: \(steamLateEvidence.logsDirectoryState)",
            "- Dumps directory: \(steamLateEvidence.dumpsDirectoryState)",
            "- Included log roles: \(steamLateEvidence.includedLogRoles.joined(separator: ", ").nilIfEmpty ?? "none")",
            "- Missing optional log roles: \(steamLateEvidence.missingOptionalLogRoles.joined(separator: ", ").nilIfEmpty ?? "none")",
            "- Dump metadata: observed=\(steamLateEvidence.observedDumpCount), retained=\(steamLateEvidence.retainedDumpCount), inventory=\(steamLateEvidence.dumpInventoryArchiveEntry ?? "not generated")",
            "",
            "`steamGameProcessLog` can provide actual AppID plus process start/exit evidence that a launch-time selected game reference cannot. Steam late logs are cumulative and are not assigned to a launch UUID; correlate their internal timestamps and source modification times with the launch timeline.",
            "Dump binaries are never included. Only bounded, redacted metadata inventory is retained.",
            ""
        ])
        lines.append(contentsOf: [
            "## Evidence completeness",
            "",
            "- Included artifacts: \(includedFiles.count)",
            "- Skipped artifacts: \(skippedFiles.count)",
            "- Collection issues: \(collectionIssues.count)",
            "",
            "A skipped or unreadable artifact is not equivalent to ‘no error detected’. Review `skippedFiles` and `collectionIssues` in the manifest before drawing a conclusion.",
            ""
        ])
        return lines.joined(separator: "\n")
    }

    private nonisolated static func appendIncidentSection(
        _ incident: SupportBundleIncidentSnapshot?,
        to lines: inout [String]
    ) {
        lines.append(contentsOf: ["", "## Reported incident", ""])
        guard let incident else {
            lines.append("- No user-confirmed incident context was provided by this caller.")
            return
        }

        let linkState: String
        if incident.launchRecordIdentifier == nil {
            linkState = "not linked"
        } else if incident.launchRecordIncluded == true {
            linkState = "included in launch timeline"
        } else {
            linkState = "linked record unavailable in this bundle"
        }
        lines.append("- Incident ID: \(incident.incidentIdentifier)")
        lines.append("- Occurred: \(ISO8601DateFormatter().string(from: incident.occurredAt))")
        lines.append("- Linked launch record: \(incident.launchRecordIdentifier ?? "none") (\(linkState))")
        lines.append("- Steam App ID: \(incident.steamAppID ?? "not provided")")
        lines.append("- Game: \(incident.gameName ?? "not provided")")
        appendIncidentText(title: "Expected result", value: incident.expectedResult, to: &lines)
        appendIncidentText(title: "Actual symptoms", value: incident.actualSymptoms, to: &lines)
        appendIncidentText(title: "Reproduction steps", value: incident.reproductionSteps, to: &lines)
        appendIncidentText(title: "User notes", value: incident.userNotes, to: &lines)
    }

    private nonisolated static func appendIncidentText(
        title: String,
        value: String?,
        to lines: inout [String]
    ) {
        lines.append(contentsOf: ["", "### \(title)", ""])
        guard let value, !value.isEmpty else {
            lines.append("    Not provided.")
            return
        }
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("    \(line)")
        }
    }

    private nonisolated static func validateCreatedArchive(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= 22,
              status.st_nlink == 1,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IRWXG | S_IRWXO)) == 0,
              (status.st_mode & S_IRUSR) != 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let signature = try preadData(descriptor: descriptor, offset: 0, count: 4)
        guard signature.count == 4,
              signature[signature.startIndex] == 0x50,
              signature[signature.index(after: signature.startIndex)] == 0x4B,
              signature[signature.index(signature.startIndex, offsetBy: 2)] == 0x03,
              signature[signature.index(signature.startIndex, offsetBy: 3)] == 0x04 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // A leading PK signature alone is not enough to prove that ditto completed a
        // usable archive. Parse the standard ZIP end record and central directory so
        // a truncated or unrelated PK-prefixed file is never offered as a support
        // bundle. Bundle limits keep the archive below the ZIP64 thresholds.
        let fileSize = Int64(status.st_size)
        let maximumEndRecordSearchBytes = 65_557 // 22-byte EOCD + 65,535-byte comment
        let tailByteCount = Int(min(fileSize, Int64(maximumEndRecordSearchBytes)))
        let tailOffset = fileSize - Int64(tailByteCount)
        let tail = try preadData(
            descriptor: descriptor,
            offset: tailOffset,
            count: tailByteCount
        )
        guard tail.count == tailByteCount,
              let endRecordOffset = zipEndOfCentralDirectoryOffset(in: tail) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let diskNumber = zipUInt16(tail, at: endRecordOffset + 4)
        let centralDirectoryDisk = zipUInt16(tail, at: endRecordOffset + 6)
        let entryCountOnDisk = zipUInt16(tail, at: endRecordOffset + 8)
        let entryCount = zipUInt16(tail, at: endRecordOffset + 10)
        let centralDirectoryByteCount = zipUInt32(tail, at: endRecordOffset + 12)
        let centralDirectoryOffset = zipUInt32(tail, at: endRecordOffset + 16)
        guard diskNumber == 0,
              centralDirectoryDisk == 0,
              entryCountOnDisk == entryCount,
              entryCount > 0,
              entryCount != UInt16.max,
              centralDirectoryByteCount != UInt32.max,
              centralDirectoryOffset != UInt32.max else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let absoluteEndRecordOffset = tailOffset + Int64(endRecordOffset)
        let centralDirectoryStart = Int64(centralDirectoryOffset)
        let centralDirectoryLength = Int64(centralDirectoryByteCount)
        guard centralDirectoryStart >= 0,
              centralDirectoryLength > 0,
              centralDirectoryStart <= absoluteEndRecordOffset,
              centralDirectoryLength <= absoluteEndRecordOffset - centralDirectoryStart,
              centralDirectoryStart + centralDirectoryLength == absoluteEndRecordOffset,
              centralDirectoryLength <= Int64(Int.max) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let centralDirectory = try preadData(
            descriptor: descriptor,
            offset: centralDirectoryStart,
            count: Int(centralDirectoryLength)
        )
        guard centralDirectory.count == Int(centralDirectoryLength) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var entryOffset = 0
        var entryNames = Set<String>()
        for _ in 0..<Int(entryCount) {
            guard entryOffset <= centralDirectory.count - 46,
                  zipUInt32(centralDirectory, at: entryOffset) == 0x0201_4B50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameLength = Int(zipUInt16(centralDirectory, at: entryOffset + 28))
            let extraLength = Int(zipUInt16(centralDirectory, at: entryOffset + 30))
            let commentLength = Int(zipUInt16(centralDirectory, at: entryOffset + 32))
            let entryLength = 46 + nameLength + extraLength + commentLength
            guard entryLength >= 46,
                  entryOffset <= centralDirectory.count - entryLength else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameRange = (entryOffset + 46)..<(entryOffset + 46 + nameLength)
            guard let name = String(data: centralDirectory.subdata(in: nameRange), encoding: .utf8),
                  !name.contains("\0") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            entryNames.insert(name.replacingOccurrences(of: "\\", with: "/"))
            entryOffset += entryLength
        }
        guard entryOffset == centralDirectory.count,
              zipContainsRequiredEntry("README.md", entryNames: entryNames),
              zipContainsRequiredEntry("metadata/bundle-manifest.json", entryNames: entryNames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func validateRedactionClosure(
        in stagingRoot: URL,
        redactor: Redactor,
        fileManager: FileManager
    ) throws {
        try FileSystemItemPolicy.requireNonSymlinkDirectory(stagingRoot, fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .linkCountKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            throw SupportBundleConstructionError.redactionGateUnreadable("staging enumeration unavailable")
        }

        var inspectedFileCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .linkCountKey
            ])
            guard values.isRegularFile == true else { continue }
            inspectedFileCount += 1
            guard inspectedFileCount <= maxIncludedFiles + 64 else {
                throw SupportBundleConstructionError.redactionGateUnreadable(
                    "staging file count exceeded the verified bundle bound"
                )
            }
            guard values.isSymbolicLink != true,
                  values.linkCount == nil || values.linkCount == 1,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maxTextBytesPerArtifact + manifestByteReserve + readmeByteReserve,
                  FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                    from: stagingRoot,
                    to: url,
                    fileManager: fileManager
                  ) else {
                throw SupportBundleConstructionError.redactionGateUnreadable(
                    "staged artifact failed the private text-file policy"
                )
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                throw SupportBundleConstructionError.redactionGateUnreadable(
                    "staged artifact was not UTF-8 diagnostic text"
                )
            }
            let secondPass: String
            if url.pathExtension.lowercased() == "json" {
                do {
                    let secondPassData = try redactor.redactedJSONData(data)
                    guard let structuredText = String(data: secondPassData, encoding: .utf8) else {
                        throw SupportBundleConstructionError.redactionGateUnreadable(
                            "structured redaction output was not UTF-8"
                        )
                    }
                    secondPass = structuredText
                } catch {
                    throw SupportBundleConstructionError.redactionGateUnreadable(
                        "structured JSON redaction verification failed"
                    )
                }
            } else {
                secondPass = redactor.redact(text)
            }
            guard secondPass != "[REDACTION_FAILED]" else {
                throw SupportBundleConstructionError.redactionGateUnreadable(
                    "redaction engine could not verify a staged artifact"
                )
            }
            guard secondPass == text else {
                let relativePath = String(
                    url.standardizedFileURL.path.dropFirst(stagingRoot.standardizedFileURL.path.count)
                )
                throw SupportBundleConstructionError.redactionLeakageDetected(
                    relativePath.isEmpty ? "unknown-artifact" : relativePath
                )
            }
        }
    }

    private nonisolated static func zipEndOfCentralDirectoryOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            guard zipUInt32(data, at: offset) == 0x0605_4B50 else { continue }
            let commentLength = Int(zipUInt16(data, at: offset + 20))
            if offset + 22 + commentLength == data.count {
                return offset
            }
        }
        return nil
    }

    private nonisolated static func zipUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else { return 0 }
        return UInt16(data[data.startIndex + offset]) |
            (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private nonisolated static func zipUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return UInt32(data[data.startIndex + offset]) |
            (UInt32(data[data.startIndex + offset + 1]) << 8) |
            (UInt32(data[data.startIndex + offset + 2]) << 16) |
            (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    private nonisolated static func zipContainsRequiredEntry(
        _ requiredPath: String,
        entryNames: Set<String>
    ) -> Bool {
        entryNames.contains {
            $0 == requiredPath || $0.hasSuffix("/\(requiredPath)")
        }
    }

    private nonisolated static func pathIsInsideOrEqual(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if candidatePath == rootPath { return true }
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private nonisolated static func anonymousIdentifier(prefix: String, index: Int) -> String {
        String(format: "%@-%06d", prefix, index)
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    fileprivate nonisolated static let maxTextBytesPerArtifact = 2 * 1024 * 1024
    fileprivate nonisolated static let maxIncludedBytes: Int64 = 64 * 1024 * 1024
    fileprivate nonisolated static let maxIncludedFiles = 1_000
    fileprivate nonisolated static let maxScannedItemsPerRoot = 5_000
    fileprivate nonisolated static let maxPrioritizedGameRunScannedItems = 5_000
    fileprivate nonisolated static let maxSteamDumpScannedItems = 5_000
    fileprivate nonisolated static let maxSteamDumpInventoryItems = 256
    fileprivate nonisolated static let maxLaunchRecords = 500
    fileprivate nonisolated static let maxRelatedRunEvidencePathsPerLaunch = 32
    fileprivate nonisolated static let maxPrioritizedLaunchArtifactPaths = 5_000
    fileprivate nonisolated static let maxProcessRunEvidenceDocuments = 256
    fileprivate nonisolated static let maxProcessRunEvidenceDiscoveryBytes: Int64 = 8 * 1024 * 1024
    fileprivate nonisolated static let maxDiagnosticRecords = 1_000
    fileprivate nonisolated static let maxDiagnosticResults = 1_000
    fileprivate nonisolated static let maxSystemChecks = 100
    fileprivate nonisolated static let maxSteamStoragePaths =
        DiagnosticEnvironmentSnapshotCollector.maximumSteamStoragePaths
    fileprivate nonisolated static let manifestByteReserve = 4 * 1024 * 1024
    fileprivate nonisolated static let readmeByteReserve = 256 * 1024

    private nonisolated static let steamLateLogAllowlist: [(fileName: String, role: String)] = [
        ("gameprocess_log.txt", "steamGameProcessLog"),
        ("content_log.txt", "steamContentLog"),
        ("shader_log.txt", "steamShaderLog"),
        ("console_log.txt", "steamConsoleLog"),
        ("bootstrap_log.txt", "steamBootstrapLog"),
        ("webhelper_gpu.txt", "steamWebHelperGPULog"),
        ("steamui_html.txt", "steamUIHTMLLog"),
        ("steamui_login.txt", "steamUILoginLog"),
        ("webhelper.txt", "steamWebHelperLog")
    ]

    private nonisolated static let uuidExpression = try? NSRegularExpression(
        pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
    )

}

struct EmergencySupportBundle: Codable, Hashable, Sendable {
    struct Application: Codable, Hashable, Sendable {
        var name: String
        var bundleIdentifier: String
        var version: String
        var build: String
        var buildConfiguration: String
        var processArchitecture: String
        var sandboxed: Bool
    }

    struct Host: Codable, Hashable, Sendable {
        var operatingSystemVersion: String
        var operatingSystemVersionString: String
        var operatingSystemBuild: String?
        var kernelVersion: String?
        var modelIdentifier: String?
        var cpuBrand: String?
        var processorCount: Int
        var activeProcessorCount: Int
        var physicalMemoryBytes: UInt64
        var translatedProcess: Bool?
        var thermalState: String
    }

    struct Disk: Codable, Hashable, Sendable {
        var role: String
        var requestedPath: String?
        var probedPath: String?
        var requestedPathExists: Bool
        var formatDescription: String?
        var totalCapacityBytes: Int64?
        var availableCapacityBytes: Int64?
        var readOnly: Bool?
        var removable: Bool?
        var internalVolume: Bool?
        var collectionError: String?
    }

    struct CapturedError: Codable, Hashable, Sendable {
        var depth: Int
        var domain: String
        var code: Int
        var typeName: String
        var summary: String
        var failureReason: String?
        var recoverySuggestion: String?
        var debugDescription: String?
    }

    struct Bootstrap: Codable, Hashable, Sendable {
        var phase: String
        var applicationSupportDirectory: String?
        var applicationSupportDirectoryExists: Bool
        var persistentStorePath: String?
        var persistentStoreExists: Bool
        var writeAheadLogExists: Bool
        var sharedMemoryFileExists: Bool
        var migrationLockExists: Bool
        var notes: [String]
    }

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var bundleIdentifier: String
    var capturedAt: Date
    var application: Application
    var host: Host
    var disks: [Disk]
    var errorChain: [CapturedError]
    var bootstrap: Bootstrap
    var privacyNotice: String
}

/// A last-resort report writer that deliberately has no dependency on
/// SwiftData, AppServices, PathManager's managed root, or an external archiver.
/// It writes one redacted JSON file to a private temporary directory.
@MainActor
final class EmergencySupportBundleService {
    private let fileManager: FileManager
    private let redactor: Redactor
    private let destinationDirectory: URL?

    init(
        fileManager: FileManager = .default,
        redactor: Redactor = Redactor(),
        destinationDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.redactor = redactor
        self.destinationDirectory = destinationDirectory
    }

    func createBundle(
        for error: Error,
        bootstrapPhase: String = "swiftDataModelContainerInitialization",
        capturedAt: Date = Date()
    ) throws -> URL {
        let applicationSupportDirectory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: ForgePlayApp.applicationSupportDirectoryName, directoryHint: .isDirectory)
        let persistentStoreURL = applicationSupportDirectory?
            .appending(path: ForgePlayApp.persistentStoreFileName, directoryHint: .notDirectory)
        let destination = destinationDirectory ?? fileManager.temporaryDirectory
            .appending(path: "ForgePlayEmergencySupport", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileSystemItemPolicy.requireNonSymlinkDirectory(destination, fileManager: fileManager)

        let bundle = EmergencySupportBundle(
            schemaVersion: EmergencySupportBundle.currentSchemaVersion,
            bundleIdentifier: UUID().uuidString.lowercased(),
            capturedAt: capturedAt,
            application: Self.applicationSnapshot(),
            host: Self.hostSnapshot(),
            disks: [
                Self.diskSnapshot(role: "temporaryDirectory", url: fileManager.temporaryDirectory, fileManager: fileManager),
                Self.diskSnapshot(role: "applicationSupport", url: applicationSupportDirectory, fileManager: fileManager)
            ],
            errorChain: Self.errorChain(from: error),
            bootstrap: .init(
                phase: bootstrapPhase,
                applicationSupportDirectory: applicationSupportDirectory?.path,
                applicationSupportDirectoryExists: applicationSupportDirectory.map {
                    fileManager.fileExists(atPath: $0.path)
                } ?? false,
                persistentStorePath: persistentStoreURL?.path,
                persistentStoreExists: persistentStoreURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
                writeAheadLogExists: persistentStoreURL.map {
                    fileManager.fileExists(atPath: $0.path + "-wal")
                } ?? false,
                sharedMemoryFileExists: persistentStoreURL.map {
                    fileManager.fileExists(atPath: $0.path + "-shm")
                } ?? false,
                migrationLockExists: applicationSupportDirectory.map {
                    fileManager.fileExists(
                        atPath: $0.appending(path: ".\(ForgePlayApp.persistentStoreFileName)-migration.lock").path
                    )
                } ?? false,
                notes: [
                    "Captured before the normal SwiftData-backed application environment became available.",
                    "File existence is observational and does not prove that a store is valid or corrupt."
                ]
            ),
            privacyNotice: "This local report applies best-effort redaction. Review it before sharing; do not add passwords, Steam Guard codes, or tokens."
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(bundle)
        var sensitivePaths = [
            destination.path,
            fileManager.temporaryDirectory.path
        ]
        sensitivePaths.append(contentsOf: [
            applicationSupportDirectory?.path,
            persistentStoreURL?.path
        ].compactMap { $0 }
        )
        let redactedData = try redactor
            .addingSensitivePaths(sensitivePaths)
            .redactedJSONData(encoded)
        _ = try JSONSerialization.jsonObject(with: redactedData)

        let stamp = ISO8601DateFormatter().string(from: capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let output = destination.appending(
            path: "ForgePlayEmergencySupport_\(stamp)_\(UUID().uuidString.lowercased()).json",
            directoryHint: .notDirectory
        )
        try redactedData.write(to: output, options: Data.WritingOptions.atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return output
    }

    private nonisolated static func applicationSnapshot() -> EmergencySupportBundle.Application {
        EmergencySupportBundle.Application(
            name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ForgePlay",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            buildConfiguration: buildConfiguration,
            processArchitecture: processArchitecture,
            sandboxed: ForgePlaySandboxPolicy.isAppSandboxEnabled
        )
    }

    private nonisolated static func hostSnapshot() -> EmergencySupportBundle.Host {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        return .init(
            operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemVersionString: processInfo.operatingSystemVersionString,
            operatingSystemBuild: sysctlString("kern.osversion"),
            kernelVersion: sysctlString("kern.version"),
            modelIdentifier: sysctlString("hw.model"),
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            translatedProcess: sysctlInt32("sysctl.proc_translated").map { $0 == 1 },
            thermalState: thermalStateName(processInfo.thermalState)
        )
    }

    private nonisolated static func diskSnapshot(
        role: String,
        url: URL?,
        fileManager: FileManager
    ) -> EmergencySupportBundle.Disk {
        guard let url else {
            return .init(
                role: role,
                requestedPath: nil,
                probedPath: nil,
                requestedPathExists: false,
                formatDescription: nil,
                totalCapacityBytes: nil,
                availableCapacityBytes: nil,
                readOnly: nil,
                removable: nil,
                internalVolume: nil,
                collectionError: "requested path was unavailable"
            )
        }
        let existingURL = nearestExistingAncestor(of: url, fileManager: fileManager)
        guard let existingURL else {
            return .init(
                role: role,
                requestedPath: url.path,
                probedPath: nil,
                requestedPathExists: false,
                formatDescription: nil,
                totalCapacityBytes: nil,
                availableCapacityBytes: nil,
                readOnly: nil,
                removable: nil,
                internalVolume: nil,
                collectionError: "path and its ancestors were unavailable"
            )
        }
        do {
            let values = try existingURL.resourceValues(forKeys: [
                .volumeLocalizedFormatDescriptionKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeIsReadOnlyKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey
            ])
            return .init(
                role: role,
                requestedPath: url.path,
                probedPath: existingURL.path,
                requestedPathExists: fileManager.fileExists(atPath: url.path),
                formatDescription: values.volumeLocalizedFormatDescription,
                totalCapacityBytes: values.volumeTotalCapacity.map(Int64.init),
                availableCapacityBytes: values.volumeAvailableCapacityForImportantUsage,
                readOnly: values.volumeIsReadOnly,
                removable: values.volumeIsRemovable,
                internalVolume: values.volumeIsInternal,
                collectionError: nil
            )
        } catch {
            return .init(
                role: role,
                requestedPath: url.path,
                probedPath: existingURL.path,
                requestedPathExists: fileManager.fileExists(atPath: url.path),
                formatDescription: nil,
                totalCapacityBytes: nil,
                availableCapacityBytes: nil,
                readOnly: nil,
                removable: nil,
                internalVolume: nil,
                collectionError: forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private nonisolated static func errorChain(from error: Error) -> [EmergencySupportBundle.CapturedError] {
        var result: [EmergencySupportBundle.CapturedError] = []
        var current: NSError? = error as NSError
        var seen = Set<String>()
        while let captured = current, result.count < 12 {
            let signature = "\(captured.domain):\(captured.code):\(captured.localizedDescription)"
            guard seen.insert(signature).inserted else { break }
            result.append(.init(
                depth: result.count,
                domain: captured.domain,
                code: captured.code,
                typeName: result.isEmpty ? String(reflecting: type(of: error)) : "Foundation.NSError",
                summary: forgePlayTechnicalErrorSummary(captured),
                failureReason: captured.localizedFailureReason,
                recoverySuggestion: captured.localizedRecoverySuggestion,
                debugDescription: captured.userInfo[NSDebugDescriptionErrorKey] as? String
            ))
            current = captured.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private nonisolated static func nearestExistingAncestor(
        of url: URL,
        fileManager: FileManager
    ) -> URL? {
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return candidate
    }

    private nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private nonisolated static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private nonisolated static var processArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "unsupported-host-architecture"
        #endif
    }

    private nonisolated static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

private enum SupportBundleConstructionError: LocalizedError {
    case manifestExceedsReservedBytes(actual: Int, limit: Int)
    case readmeExceedsReservedBytes(actual: Int, limit: Int)
    case redactionLeakageDetected(String)
    case redactionGateUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .manifestExceedsReservedBytes(let actual, let limit):
            "지원 번들 manifest가 예약된 크기를 초과했습니다: \(actual) / \(limit) bytes"
        case .readmeExceedsReservedBytes(let actual, let limit):
            "지원 번들 README가 예약된 크기를 초과했습니다: \(actual) / \(limit) bytes"
        case .redactionLeakageDetected(let artifact):
            "지원 번들 가림 검증에서 민감 정보가 남은 파일을 발견했습니다: \(artifact)"
        case .redactionGateUnreadable(let reason):
            "지원 번들 가림 검증을 완료하지 못했습니다: \(reason)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
