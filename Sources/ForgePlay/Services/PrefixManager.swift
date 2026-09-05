import Darwin
import Foundation

protocol PrefixDirectorySwapping {
    func swap(_ first: URL, _ second: URL) throws
}

struct AtomicPrefixDirectorySwapper: PrefixDirectorySwapping {
    func swap(_ first: URL, _ second: URL) throws {
        let result: Int32 = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct PrefixMetadata: Codable, Hashable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var id: String
    var environmentGenerationID: String? = nil
    var synchronizationSelection: WineSynchronizationSelection? = nil
    var synchronizationBackend: WineSynchronizationBackend? = nil
    var displayName: String
    var path: String
    var mode: PrefixMode
    var runner: String
    var runtimeBinding: PrefixRuntimeBinding? = nil
    var architecture: String
    var windowsVersion: String
    var createdAt: Date
    var updatedAt: Date
    var installedRuntimes: [RuntimeId]
    var dllOverrides: [String]
    var environmentVariables: [String: String]
    var launchOptions: [String]
    var snapshots: [String]
}

struct PrefixRuntimeMigrationResult: Hashable {
    var metadata: PrefixMetadata
    var processResult: ProcessRunResult?
    var didMigrate: Bool
}

struct PrefixPreparationResult: Hashable {
    var metadata: PrefixMetadata
    var processResult: ProcessRunResult?
    var isInitialized: Bool
    var residualPreviousEnvironmentURL: URL? = nil
}

struct PrefixRebuildResult: Hashable {
    var metadata: PrefixMetadata
    var processResult: ProcessRunResult
    var residualPreviousEnvironmentURL: URL?
}

private struct PrefixArchitectureResetResult {
    var metadata: PrefixMetadata
    var processResult: ProcessRunResult?
    var residualPreviousEnvironmentURL: URL?
}

enum WinePrefixDefaults {
    static let runner = "ForgePlay Runtime"
    static let architecture = "win64"
    static let windowsVersion = WindowsCompatibilityVersion.windows10.rawValue
    static let bootstrapDisabledAddonDLLOverrides = "mscoree,mshtml="
}

enum PrefixManagerError: LocalizedError {
    case initializationFailed(ProcessRunResult)
    case initializationCleanupFailed(
        initialization: ProcessRunResult,
        cleanupDescription: String
    )
    case runtimeReconciliationFailed(ProcessRunResult)
    case runtimeReconciliationCleanupFailed(
        reconciliation: ProcessRunResult,
        cleanupDescription: String
    )

    var result: ProcessRunResult {
        switch self {
        case .initializationFailed(let result):
            result
        case .initializationCleanupFailed(let initialization, _):
            initialization
        case .runtimeReconciliationFailed(let result):
            result
        case .runtimeReconciliationCleanupFailed(let reconciliation, _):
            reconciliation
        }
    }

    var localizationKey: String {
        switch self {
        case .initializationFailed(let result) where result.didTimeOut:
            "Steam 프리픽스 초기화 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: %@"
        case .initializationFailed:
            "Steam 프리픽스 초기화에 실패했습니다. 로그를 확인하세요: %@"
        case .initializationCleanupFailed:
            "Steam 프리픽스 초기화에 실패했고 남은 Wine 프로세스도 정리하지 못했습니다. 초기화 로그: %@. 정리 오류: %@"
        case .runtimeReconciliationFailed(let result) where result.didTimeOut:
            "ForgePlay Runtime과 Steam 프리픽스의 호환성 갱신 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: %@"
        case .runtimeReconciliationFailed:
            "ForgePlay Runtime과 Steam 프리픽스의 호환성 갱신에 실패했습니다. 로그를 확인하세요: %@"
        case .runtimeReconciliationCleanupFailed:
            "ForgePlay Runtime 호환성 갱신 후 남은 Wine 프로세스를 정리하지 못했습니다. 갱신 로그: %@. 정리 오류: %@"
        }
    }

    var localizationArguments: [CVarArg] {
        switch self {
        case .initializationFailed(let result):
            [result.stderrLog.path]
        case .initializationCleanupFailed(let initialization, let cleanupDescription):
            [initialization.stderrLog.path, cleanupDescription]
        case .runtimeReconciliationFailed(let result):
            [result.stderrLog.path]
        case .runtimeReconciliationCleanupFailed(let reconciliation, let cleanupDescription):
            [reconciliation.stderrLog.path, cleanupDescription]
        }
    }

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let result):
            if result.didTimeOut {
                return "Steam 프리픽스 초기화 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
            }
            return "Steam 프리픽스 초기화에 실패했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
        case .initializationCleanupFailed(let initialization, let cleanupDescription):
            return "Steam 프리픽스 초기화에 실패했고 남은 Wine 프로세스도 정리하지 못했습니다. 초기화 로그: \(initialization.stderrLog.path). 정리 오류: \(cleanupDescription)"
        case .runtimeReconciliationFailed(let result):
            if result.didTimeOut {
                return "ForgePlay Runtime과 Steam 프리픽스의 호환성 갱신 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
            }
            return "ForgePlay Runtime과 Steam 프리픽스의 호환성 갱신에 실패했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
        case .runtimeReconciliationCleanupFailed(let reconciliation, let cleanupDescription):
            return "ForgePlay Runtime 호환성 갱신 후 남은 Wine 프로세스를 정리하지 못했습니다. 갱신 로그: \(reconciliation.stderrLog.path). 정리 오류: \(cleanupDescription)"
        }
    }
}

enum PrefixRuntimeCompatibilityError: LocalizedError, Equatable {
    case migrationRequired(String)
    case runtimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .migrationRequired(let reason):
            "ForgePlay Runtime과 Steam 프리픽스의 명시적 호환성 이관이 필요합니다. 먼저 Steam 프리픽스 준비를 실행하세요. \(reason)"
        case .runtimeUnavailable(let reason):
            "ForgePlay Runtime identity를 확인할 수 없습니다. \(reason)"
        }
    }
}

struct SteamPrefixLifecycleCleanupError: LocalizedError, @unchecked Sendable {
    var originalDescription: String
    var cleanupDescription: String
    var originalError: Error?
    var cleanupError: Error?
    var originalProcessResult: ProcessRunResult?
    var cleanupProcessResults: [ProcessRunResult]

    init(
        originalDescription: String,
        cleanupDescription: String,
        originalError: Error? = nil,
        cleanupError: Error? = nil,
        originalProcessResult: ProcessRunResult? = nil,
        cleanupProcessResults: [ProcessRunResult] = []
    ) {
        self.originalDescription = originalDescription
        self.cleanupDescription = cleanupDescription
        self.originalError = originalError
        self.cleanupError = cleanupError
        self.originalProcessResult = originalProcessResult
        self.cleanupProcessResults = cleanupProcessResults
    }

    var errorDescription: String? {
        "Steam 프리픽스 작업에 실패했고 남은 Wine 프로세스도 정리하지 못했습니다. 원인: \(originalDescription). 정리 오류: \(cleanupDescription)"
    }
}

enum PrefixMetadataError: LocalizedError, Equatable {
    case unsafePrefixDirectory(URL)
    case unsafeMetadataFile(URL)
    case metadataReadFailed(URL, String)
    case metadataTooLarge(URL, Int, Int)
    case invalidMetadata(URL)

    var errorDescription: String? {
        switch self {
        case .unsafePrefixDirectory(let url):
            "Steam 프리픽스 폴더는 symlink가 아닌 일반 폴더여야 합니다: \(url.path)"
        case .unsafeMetadataFile(let url):
            "Steam 프리픽스 메타데이터는 symlink가 아닌 일반 파일이어야 합니다: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "Steam 프리픽스 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .metadataTooLarge(let url, let byteCount, let limit):
            "Steam 프리픽스 메타데이터가 너무 큽니다: \(url.path) \(byteCount) bytes / limit \(limit) bytes"
        case .invalidMetadata(let url):
            "Steam 프리픽스 메타데이터가 올바르지 않습니다: \(url.path)"
        }
    }
}

enum PrefixRestoreError: LocalizedError {
    case rollbackFailed(destination: URL, backup: URL, originalError: Error, rollbackError: Error)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let destination, let backup, let originalError, let rollbackError):
            "Steam 프리픽스 복원에 실패했고 기존 프리픽스를 되돌리지 못했습니다: \(destination.path). 백업 위치: \(backup.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 복구 오류: \(forgePlayTechnicalErrorSummary(rollbackError))"
        }
    }
}

enum PrefixResetError: LocalizedError {
    case rollbackFailed(destination: URL, displacedEnvironment: URL, originalError: Error, rollbackError: Error)
    case steamLibraryPreservationFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let destination, let displacedEnvironment, let originalError, let rollbackError):
            "Steam 프리픽스 재설정에 실패했고 기존 프리픽스를 되돌리지 못했습니다: \(destination.path). 기존 환경 임시 위치: \(displacedEnvironment.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 복구 오류: \(forgePlayTechnicalErrorSummary(rollbackError))"
        case .steamLibraryPreservationFailed(let url, let reason):
            "Steam 프리픽스 내부 라이브러리를 보존하지 못해 기존 프리픽스로 되돌렸습니다: \(url.path). \(reason)"
        }
    }
}

enum PrefixUsabilityError: LocalizedError, Equatable, Hashable {
    case missingRequiredItem(URL)
    case unsafeRequiredItem(URL)
    case unreadableRequiredItem(URL, String)
    case invalidMetadata(URL, String)
    case architectureMismatch(URL, expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case .missingRequiredItem(let url):
            "Steam 프리픽스에 필요한 항목을 찾을 수 없습니다: \(url.path)"
        case .unsafeRequiredItem(let url):
            "Steam 프리픽스에 필요한 항목이 안전한 일반 파일/폴더가 아닙니다: \(url.path)"
        case .unreadableRequiredItem(let url, let message):
            "Steam 프리픽스에 필요한 항목을 읽지 못했습니다: \(url.path). \(message)"
        case .invalidMetadata(let url, let message):
            "Steam 프리픽스 메타데이터를 사용할 수 없습니다: \(url.path). \(message)"
        case .architectureMismatch(let url, let expected, let actual):
            "Steam 프리픽스 아키텍처가 일치하지 않습니다: \(url.path). expected \(expected), actual \(actual ?? "unknown")"
        }
    }
}

@MainActor
final class PrefixManager {
    private final class ReplacementStagingLifecycleState {
        enum Phase {
            case notLaunched
            case mayHaveProcesses
            case verifiedQuiescent
        }

        private(set) var phase: Phase = .notLaunched

        func markMayHaveProcesses() {
            phase = .mayHaveProcesses
        }

        func markVerifiedQuiescent() {
            phase = .verifiedQuiescent
        }
    }

    private struct ReplacementArtifactCleanupCandidate: Sendable {
        let url: URL
        let device: UInt64
        let inode: UInt64
    }

    private struct InternalSteamAppsIdentity: Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct InternalSteamVisibilitySnapshot: Sendable {
        let data: Data
        let permissions: mode_t
    }

    private struct InternalSteamLibraryPreservationPlan: Sendable {
        let steamAppsIdentity: InternalSteamAppsIdentity?
        let configLibraryFolders: InternalSteamVisibilitySnapshot?

        var requiresPreservation: Bool {
            steamAppsIdentity != nil || configLibraryFolders != nil
        }
    }

    private struct InternalSteamLibraryTransplantJournal: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let canonicalPrefixPath: String
        let replacementStagingPath: String
        let steamAppsDevice: UInt64?
        let steamAppsInode: UInt64?
        let preservesConfigLibraryFolders: Bool
    }

    nonisolated static let maxMetadataBytes = 256 * 1024
    private static let maxMetadataListItems = 128
    private static let maxMetadataStringLength = 512
    private static let maxSteamLibraryVisibilityMetadataBytes = 8 * 1_024 * 1_024
    private static let maxSteamLibraryTransplantJournalBytes = 16 * 1_024
    private static let maxSteamLibraryTransplantRecoveryCandidates = 8
    private static let wineFontFileExtensions: Set<String> = ["fon", "otf", "ttc", "ttf"]
    private static let recoveryPreservationMarkerName = ".forgeplay-preserve-recovery"
    private static let deferredDeletionMarkerName = ".forgeplay-delete-on-next-launch"
    private static let steamLibraryTransplantJournalName =
        ".forgeplay-steam-library-transplant-v1.json"

    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let fileManager: FileManager
    private let directorySwapper: PrefixDirectorySwapping
    private let lifecycleCoordinator: SteamPrefixLifecycleCoordinator
    private let runtimeManifestProvider: any RuntimeManifestProviding
    private let prefixReplacementQuiescenceVerifier:
        @MainActor (URL) async throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var activeReplacementArtifactPaths: Set<String> = []

    init(
        pathManager: PathManager,
        runner: SafeProcessRunner,
        fileManager: FileManager = .default,
        directorySwapper: PrefixDirectorySwapping = AtomicPrefixDirectorySwapper(),
        lifecycleCoordinator: SteamPrefixLifecycleCoordinator? = nil,
        runtimeManifestProvider: any RuntimeManifestProviding = RuntimeManifestResolver(),
        prefixReplacementQuiescenceVerifier:
            (@MainActor (URL) async throws -> Void)? = nil
    ) {
        self.pathManager = pathManager
        self.runner = runner
        self.fileManager = fileManager
        self.directorySwapper = directorySwapper
        self.lifecycleCoordinator = lifecycleCoordinator ?? SteamPrefixLifecycleCoordinator()
        self.runtimeManifestProvider = runtimeManifestProvider
        self.prefixReplacementQuiescenceVerifier =
            prefixReplacementQuiescenceVerifier ?? { prefix in
                try await runner.requirePrefixReplacementQuiescence(prefix)
            }
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func acquireManagedRootOperationLease() throws -> [ManagedRootOperationLease] {
        let root = try pathManager.validateCurrentManagedRoot()
        return try ManagedRootOperationLease.acquireExclusive(
            forManagedRoots: [root],
            fileManager: fileManager
        )
    }

    func currentManagedRootURL() throws -> URL {
        try pathManager.validateCurrentManagedRoot()
    }

    func steamSharedPrefixURL() throws -> URL {
        try pathManager.url(for: .steamSharedPrefix)
    }

    func steamSharedPrefixMetadataExists() throws -> Bool {
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        guard fileManager.fileExists(atPath: prefixURL.path) else { return false }
        try validatePrefixDirectory(prefixURL)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else { return false }
        try requirePrefixMetadataFile(metadataURL)
        return true
    }

    func steamSharedPrefixHasExistingContent() throws -> Bool {
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        guard fileManager.fileExists(atPath: prefixURL.path) else { return false }
        try validatePrefixDirectory(prefixURL)
        return try !fileManager.contentsOfDirectory(
            at: prefixURL,
            includingPropertiesForKeys: nil
        ).isEmpty
    }

    func createSteamSharedPrefix(
        synchronizationPolicy: WineSynchronizationPolicy? = nil
    ) throws -> PrefixMetadata {
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        if let synchronizationPolicy {
            try requireConsistentSynchronizationPolicy(
                synchronizationPolicy,
                metadataURL: prefixURL.appending(path: "prefix.json")
            )
        }
        try createPrefixDirectory(at: prefixURL)

        let metadataURL = prefixURL.appending(path: "prefix.json")
        if fileManager.fileExists(atPath: metadataURL.path) {
            let metadata = try loadMetadata(at: prefixURL)
            if let synchronizationPolicy,
               appliedSynchronizationPolicy(in: metadata) != synchronizationPolicy {
                throw PrefixMetadataError.invalidMetadata(metadataURL)
            }
            return metadata
        }

        let metadata = freshSteamSharedMetadata(
            at: prefixURL,
            synchronizationPolicy: synchronizationPolicy ?? .automaticServer
        )
        try save(metadata, at: prefixURL)
        return metadata
    }

    func prepareSteamSharedPrefix(
        runtimeExecutable: URL,
        synchronizationPolicy: WineSynchronizationPolicy? = nil
    ) async throws -> PrefixPreparationResult {
        let configuredPrefixURL = try pathManager.url(for: .steamSharedPrefix)
        if fileManager.fileExists(atPath: configuredPrefixURL.path) {
            try recoverInterruptedInternalSteamLibraryTransplant(
                at: configuredPrefixURL
            )
        }
        let manifest = try runtimeManifestProvider.manifest(for: runtimeExecutable)
        var metadata = try createSteamSharedPrefix(synchronizationPolicy: synchronizationPolicy)
        let prefixURL = URL(fileURLWithPath: metadata.path)
        if metadata.environmentGenerationID == nil {
            metadata.environmentGenerationID = UUID().uuidString
            metadata.updatedAt = Date()
            try save(metadata, at: prefixURL)
        }
        let resetResult = try await resetPrefixIfArchitectureMismatch(
            metadata: metadata,
            prefixURL: prefixURL,
            runtimeExecutable: runtimeExecutable,
            manifest: manifest
        )
        metadata = resetResult.metadata
        if try !prefixNeedsInitialization(prefixURL, expectedArchitecture: metadata.architecture) {
            try seedWineFontsIfAvailable(from: runtimeExecutable, into: prefixURL)
            let migration = try await migrateSteamSharedPrefixRuntime(
                runtimeExecutable: runtimeExecutable,
                manifest: manifest
            )
            return PrefixPreparationResult(
                metadata: migration.metadata,
                processResult: resetResult.processResult ?? migration.processResult,
                isInitialized: true,
                residualPreviousEnvironmentURL: resetResult.residualPreviousEnvironmentURL
            )
        }

        let initialization = try await initializeMissingPrefixAtomically(
            metadata: metadata,
            prefixURL: prefixURL,
            runtimeExecutable: runtimeExecutable,
            manifest: manifest
        )

        return PrefixPreparationResult(
            metadata: initialization.metadata,
            processResult: initialization.processResult,
            isInitialized: true,
            residualPreviousEnvironmentURL: initialization.residualPreviousEnvironmentURL ??
                resetResult.residualPreviousEnvironmentURL
        )
    }

    func inspectSteamSharedPrefixRuntimeCompatibility(
        runtimeExecutable: URL
    ) -> PrefixRuntimeCompatibilityInspection {
        do {
            let prefixURL = try pathManager.url(for: .steamSharedPrefix)
            let manifest = try runtimeManifestProvider.manifest(for: runtimeExecutable)
            return inspectRuntimeCompatibility(at: prefixURL, manifest: manifest)
        } catch {
            return .runtimeUnavailable(forgePlayTechnicalErrorSummary(error))
        }
    }

    func inspectSteamSharedPrefixRuntimeCompatibility(
        manifest: RuntimeManifest
    ) -> PrefixRuntimeCompatibilityInspection {
        do {
            let prefixURL = try pathManager.url(for: .steamSharedPrefix)
            return inspectRuntimeCompatibility(
                at: prefixURL,
                manifest: manifest
            )
        } catch {
            return .runtimeUnavailable(forgePlayTechnicalErrorSummary(error))
        }
    }

    func requireSteamSharedPrefixRuntimeCompatibility(runtimeExecutable: URL) throws {
        switch inspectSteamSharedPrefixRuntimeCompatibility(runtimeExecutable: runtimeExecutable) {
        case .compatible:
            return
        case .migrationRequired(let reason):
            throw PrefixRuntimeCompatibilityError.migrationRequired(reason)
        case .runtimeUnavailable(let reason):
            throw PrefixRuntimeCompatibilityError.runtimeUnavailable(reason)
        }
    }

    /// Owns the lifecycle of a replacement staging directory. Most failures
    /// can safely discard the staging tree, but an unconfirmed Wine cleanup
    /// means a descendant may still hold or mutate that tree. Preserve it in
    /// that case so later verified cleanup can retire it without racing a live
    /// process or deleting files underneath Wine.
    private func withReplacementStaging<Value>(
        at staging: URL,
        runtimeExecutable: URL,
        logDirectory: URL,
        operation: (ReplacementStagingLifecycleState) async throws -> (
            value: Value,
            preserveStagingOnExit: Bool
        )
    ) async throws -> Value {
        var preserveStagingOnExit = false
        let lifecycleState = ReplacementStagingLifecycleState()
        defer {
            if !preserveStagingOnExit {
                try? fileManager.removeItem(at: staging)
            }
        }

        do {
            let completion = try await operation(lifecycleState)
            preserveStagingOnExit = completion.preserveStagingOnExit
            return completion.value
        } catch {
            let operationError = error
            if lifecycleState.phase == .mayHaveProcesses {
                do {
                    try await shutdownExistingPrefixBeforeReplacementIfNeeded(
                        runtimeExecutable: runtimeExecutable,
                        prefixURL: staging,
                        logDirectory: logDirectory
                    )
                    try markReplacementStagingVerifiedQuiescent(
                        staging,
                        lifecycleState: lifecycleState
                    )
                } catch let cleanupError {
                    preserveStagingOnExit = true
                    do {
                        try markReplacementStagingForRecovery(staging)
                    } catch let markerError {
                        throw SteamPrefixLifecycleCleanupError(
                            originalDescription: forgePlayTechnicalErrorSummary(operationError),
                            cleanupDescription: "Replacement staging cleanup remained unconfirmed (\(forgePlayTechnicalErrorSummary(cleanupError))), and its cross-restart preservation marker could not be verified: \(forgePlayTechnicalErrorSummary(markerError))",
                            originalError: operationError,
                            cleanupError: cleanupError,
                            originalProcessResult: diagnosticProcessRunResult(from: operationError),
                            cleanupProcessResults: diagnosticProcessRunResults(from: cleanupError)
                        )
                    }
                    throw replacementStagingCleanupFailure(
                        after: operationError,
                        cleanupError: cleanupError
                    )
                }
            }
            if let resetError = operationError as? PrefixResetError,
               case .rollbackFailed = resetError {
                preserveStagingOnExit = true
            }
            throw operationError
        }
    }

    private func markReplacementStagingForRecovery(_ staging: URL) throws {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        try requirePrefixDirectory(staging)
        let marker = staging.appending(path: Self.recoveryPreservationMarkerName)
        if fileManager.fileExists(atPath: marker.path),
           !FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager) {
            throw PrefixMetadataError.unsafeMetadataFile(marker)
        }
        try Data("preserve\n".utf8).write(to: marker, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: marker.path
        )
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager) else {
            throw PrefixMetadataError.unsafeMetadataFile(marker)
        }
    }

    private func markReplacementStagingMayHaveProcesses(
        _ staging: URL,
        lifecycleState: ReplacementStagingLifecycleState
    ) throws {
        try markReplacementStagingForRecovery(staging)
        lifecycleState.markMayHaveProcesses()
    }

    private func markReplacementStagingVerifiedQuiescent(
        _ staging: URL,
        lifecycleState: ReplacementStagingLifecycleState
    ) throws {
        let marker = staging.appending(path: Self.recoveryPreservationMarkerName)
        if fileManager.fileExists(atPath: marker.path) {
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager) else {
                throw PrefixMetadataError.unsafeMetadataFile(marker)
            }
            try fileManager.removeItem(at: marker)
        }
        lifecycleState.markVerifiedQuiescent()
    }

    private func replacementStagingCleanupFailure(
        after operationError: Error,
        cleanupError: Error
    ) -> Error {
        let cleanupDescription = forgePlayTechnicalErrorSummary(cleanupError)
        if let prefixError = operationError as? PrefixManagerError {
            switch prefixError {
            case .initializationFailed(let initialization),
                 .initializationCleanupFailed(let initialization, _):
                return PrefixManagerError.initializationCleanupFailed(
                    initialization: initialization,
                    cleanupDescription: cleanupDescription
                )
            case .runtimeReconciliationFailed(let reconciliation),
                 .runtimeReconciliationCleanupFailed(let reconciliation, _):
                return PrefixManagerError.runtimeReconciliationCleanupFailed(
                    reconciliation: reconciliation,
                    cleanupDescription: cleanupDescription
                )
            }
        }
        return SteamPrefixLifecycleCleanupError(
            originalDescription: forgePlayTechnicalErrorSummary(operationError),
            cleanupDescription: cleanupDescription,
            originalError: operationError,
            cleanupError: cleanupError,
            originalProcessResult: diagnosticProcessRunResult(from: operationError),
            cleanupProcessResults: diagnosticProcessRunResults(from: cleanupError)
        )
    }

    private func prefixShutdownPostconditionIsVerified(_ result: ProcessRunResult) -> Bool {
        result.succeeded && result.postconditionSatisfied == true
    }

    private func prefixShutdownFailureDescription(_ result: ProcessRunResult) -> String {
        "process exit \(result.diagnosticExitCodeDescription), " +
            "ForgePlay status \(result.diagnosticForgePlayStatusDescription), " +
            "postcondition \(result.postconditionSatisfied.map(String.init) ?? "unavailable"), " +
            "log: \(result.stderrLog.path)"
    }

    private func requireVerifiedPrefixReplacementQuiescence(
        at prefix: URL,
        cleanupProcessResults: [ProcessRunResult] = []
    ) async throws {
        do {
            try await prefixReplacementQuiescenceVerifier(prefix)
        } catch {
            throw SteamPrefixLifecycleCleanupError(
                originalDescription: "Steam prefix replacement requires a quiescent prefix",
                cleanupDescription: forgePlayTechnicalErrorSummary(error),
                cleanupError: error,
                cleanupProcessResults: cleanupProcessResults
            )
        }
    }

    func migrateSteamSharedPrefixRuntime(
        runtimeExecutable: URL
    ) async throws -> PrefixRuntimeMigrationResult {
        let manifest = try runtimeManifestProvider.manifest(for: runtimeExecutable)
        return try await migrateSteamSharedPrefixRuntime(
            runtimeExecutable: runtimeExecutable,
            manifest: manifest
        )
    }

    private func migrateSteamSharedPrefixRuntime(
        runtimeExecutable: URL,
        manifest: RuntimeManifest
    ) async throws -> PrefixRuntimeMigrationResult {
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        try validateUsablePrefix(at: prefixURL)
        if inspectRuntimeCompatibility(at: prefixURL, manifest: manifest).isCompatible {
            return PrefixRuntimeMigrationResult(
                metadata: try loadMetadata(at: prefixURL),
                processResult: nil,
                didMigrate: false
            )
        }
        let logDirectory = try pathManager.url(for: .installLogs)
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        let destinationParent = prefixURL.deletingLastPathComponent()
        try requirePrefixDirectory(destinationParent)
        let staging = destinationParent.appending(
            path: ".\(prefixURL.lastPathComponent).runtime-migration-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let migrationResult = try await withReplacementStaging(
            at: staging,
            runtimeExecutable: runtimeExecutable,
            logDirectory: logDirectory
        ) { stagingLifecycle in

        let canonicalMetadata = try loadMetadata(at: prefixURL)
        if fileManager === FileManager.default {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: prefixURL, to: staging)
            }.value
        } else {
            try fileManager.copyItem(at: prefixURL, to: staging)
        }
        var stagingMetadata = canonicalMetadata
        stagingMetadata.path = staging.path
        try save(stagingMetadata, at: staging)
        try registerActiveReplacementPrefix(staging)
        defer { unregisterActiveReplacementPrefix(staging) }
        try markReplacementStagingMayHaveProcesses(
            staging,
            lifecycleState: stagingLifecycle
        )

        let migration: ProcessRunResult
        do {
            migration = try await runner.run(.migratePrefixRuntime(
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            ))
        } catch {
            try await throwThrownInitializationFailureAfterCleanup(
                error,
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            )
        }
        guard migration.succeeded else {
            try await throwRuntimeReconciliationFailureAfterCleanup(
                migration,
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            )
        }

        let registryFlush: ProcessRunResult
        do {
            registryFlush = try await runner.run(.waitForWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            ))
        } catch {
            try await throwThrownInitializationFailureAfterCleanup(
                error,
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            )
        }
        guard registryFlush.succeeded else {
            try await throwRuntimeReconciliationFailureAfterCleanup(
                registryFlush,
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            )
        }
        try validateUsablePrefix(at: staging)

        do {
            let cleanup = try await runner.run(.shutdownWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: staging,
                logDirectory: logDirectory
            ))
            guard prefixShutdownPostconditionIsVerified(cleanup) else {
                throw PrefixManagerError.runtimeReconciliationCleanupFailed(
                    reconciliation: migration,
                    cleanupDescription: prefixShutdownFailureDescription(cleanup)
                )
            }
            try await requireVerifiedPrefixReplacementQuiescence(
                at: staging,
                cleanupProcessResults: [cleanup]
            )
            try markReplacementStagingVerifiedQuiescent(
                staging,
                lifecycleState: stagingLifecycle
            )
        } catch let error as PrefixManagerError {
            throw error
        } catch {
            throw PrefixManagerError.runtimeReconciliationCleanupFailed(
                reconciliation: migration,
                cleanupDescription: forgePlayTechnicalErrorSummary(error)
            )
        }

        var metadata = try loadMetadata(at: staging)
        metadata.schemaVersion = 2
        metadata.runtimeBinding = PrefixRuntimeBinding(manifest: manifest)
        metadata.environmentGenerationID = UUID().uuidString
        metadata.updatedAt = Date()
        metadata.path = prefixURL.path
        try disableAutomaticWinePrefixUpdates(at: staging)
        try lifecycleCoordinator.checkpoint()

        let residualPreviousEnvironmentURL = try await replacePrefixAtomically(
            at: prefixURL,
            with: staging,
            metadata: metadata,
            stagingLifecycleState: stagingLifecycle
        )

        return (
            value: PrefixRuntimeMigrationResult(
                metadata: metadata,
                processResult: migration,
                didMigrate: true
            ),
            preserveStagingOnExit: residualPreviousEnvironmentURL != nil
        )
        }

        guard inspectRuntimeCompatibility(at: prefixURL, manifest: manifest).isCompatible else {
            throw PrefixRuntimeCompatibilityError.migrationRequired(
                "runtime migration completed, but its binding could not be committed"
            )
        }
        return migrationResult
    }

    func rebuildSteamSharedPrefix(
        runtimeExecutable: URL,
        reason _: String = "steam-repair",
        synchronizationPolicy requestedSynchronizationPolicy: WineSynchronizationPolicy? = nil
    ) async throws -> PrefixRebuildResult {
        let manifest = try runtimeManifestProvider.manifest(for: runtimeExecutable)
        let prefixURL = try pathManager.url(for: .steamSharedPrefix)
        if fileManager.fileExists(atPath: prefixURL.path) {
            try recoverInterruptedInternalSteamLibraryTransplant(at: prefixURL)
        }
        if let requestedSynchronizationPolicy {
            try requireConsistentSynchronizationPolicy(
                requestedSynchronizationPolicy,
                metadataURL: prefixURL.appending(path: "prefix.json")
            )
        }
        let canonicalMetadata: PrefixMetadata
        if fileManager.fileExists(atPath: prefixURL.path) {
            try validatePrefixDirectory(prefixURL)
            let metadataURL = prefixURL.appending(path: "prefix.json")
            if fileManager.fileExists(atPath: metadataURL.path) {
                do {
                    canonicalMetadata = try loadMetadata(at: prefixURL)
                } catch is DecodingError {
                    // Rebuild is the explicit destructive repair operation. A
                    // safe regular metadata file with corrupt contents must not
                    // prevent replacing the already-discarded environment.
                    try requirePrefixMetadataFile(metadataURL)
                    canonicalMetadata = freshSteamSharedMetadata(
                        at: prefixURL,
                        synchronizationPolicy:
                            requestedSynchronizationPolicy ?? .automaticServer
                    )
                } catch PrefixMetadataError.invalidMetadata {
                    try requirePrefixMetadataFile(metadataURL)
                    canonicalMetadata = freshSteamSharedMetadata(
                        at: prefixURL,
                        synchronizationPolicy:
                            requestedSynchronizationPolicy ?? .automaticServer
                    )
                }
            } else {
                canonicalMetadata = freshSteamSharedMetadata(
                    at: prefixURL,
                    synchronizationPolicy: requestedSynchronizationPolicy ?? .automaticServer
                )
                try save(canonicalMetadata, at: prefixURL)
            }
        } else {
            try createPrefixDirectory(at: prefixURL)
            canonicalMetadata = freshSteamSharedMetadata(
                at: prefixURL,
                synchronizationPolicy: requestedSynchronizationPolicy ?? .automaticServer
            )
            try save(canonicalMetadata, at: prefixURL)
        }
        let synchronizationPolicy = requestedSynchronizationPolicy ??
            appliedSynchronizationPolicy(in: canonicalMetadata)
        if let requestedSynchronizationPolicy,
           appliedSynchronizationPolicy(in: canonicalMetadata) != requestedSynchronizationPolicy {
            throw PrefixMetadataError.invalidMetadata(prefixURL.appending(path: "prefix.json"))
        }
        let logDirectory = try pathManager.url(for: .installLogs)
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        let internalSteamLibraryPlan = try
            captureInternalSteamLibraryPreservationPlan(in: prefixURL)

        let destinationParent = prefixURL.deletingLastPathComponent()
        try requirePrefixDirectory(destinationParent)
        let staging = destinationParent.appending(
            path: ".\(prefixURL.lastPathComponent).rebuild-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        return try await withReplacementStaging(
            at: staging,
            runtimeExecutable: runtimeExecutable,
            logDirectory: logDirectory
        ) { stagingLifecycle in

        let rebuildStartedAt = Date()
        let stagingMetadata = freshSteamSharedMetadata(
            at: staging,
            createdAt: rebuildStartedAt,
            synchronizationPolicy: synchronizationPolicy
        )
        try save(stagingMetadata, at: staging)
        try registerActiveReplacementPrefix(staging)
        defer { unregisterActiveReplacementPrefix(staging) }
        try markReplacementStagingMayHaveProcesses(
            staging,
            lifecycleState: stagingLifecycle
        )

        let result = try await initializePrefixAndWaitForRegistryFlush(
            runtimeExecutable: runtimeExecutable,
            prefix: staging,
            logDirectory: logDirectory
        )
        try seedWineFontsIfAvailable(from: runtimeExecutable, into: staging)
        do {
            try validateUsablePrefix(at: staging, expectedArchitecture: stagingMetadata.architecture)
        } catch {
            throw PrefixManagerError.initializationFailed(result)
        }
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: staging,
            logDirectory: logDirectory
        )
        try markReplacementStagingVerifiedQuiescent(
            staging,
            lifecycleState: stagingLifecycle
        )
        let boundStagingMetadata = try bindRuntime(
            manifest,
            to: stagingMetadata,
            at: staging
        )
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        try lifecycleCoordinator.checkpoint()

        var finalMetadata = boundStagingMetadata
        finalMetadata.path = prefixURL.path
        finalMetadata.updatedAt = Date()
        let residualPreviousEnvironmentURL = try await
            replacePrefixAtomicallyPreservingInternalSteamLibrary(
                at: prefixURL,
                with: staging,
                metadata: finalMetadata,
                stagingLifecycleState: stagingLifecycle,
                preservationPlan: internalSteamLibraryPlan
            )
        return (
            value: PrefixRebuildResult(
                metadata: finalMetadata,
                processResult: result,
                residualPreviousEnvironmentURL: residualPreviousEnvironmentURL
            ),
            preserveStagingOnExit: residualPreviousEnvironmentURL != nil
        )
        }
    }

    private func initializeMissingPrefixAtomically(
        metadata: PrefixMetadata,
        prefixURL: URL,
        runtimeExecutable: URL,
        manifest: RuntimeManifest
    ) async throws -> PrefixArchitectureResetResult {
        let logDirectory = try pathManager.url(for: .installLogs)
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        let internalSteamLibraryPlan = try
            captureInternalSteamLibraryPreservationPlan(in: prefixURL)

        let destinationParent = prefixURL.deletingLastPathComponent()
        try requirePrefixDirectory(destinationParent)
        let staging = destinationParent.appending(
            path: ".\(prefixURL.lastPathComponent).initialize-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        return try await withReplacementStaging(
            at: staging,
            runtimeExecutable: runtimeExecutable,
            logDirectory: logDirectory
        ) { stagingLifecycle in

        let stagingMetadata = freshSteamSharedMetadata(
            at: staging,
            architecture: metadata.architecture,
            windowsVersion: metadata.windowsVersion,
            createdAt: metadata.createdAt,
            synchronizationPolicy: appliedSynchronizationPolicy(in: metadata)
        )
        try save(stagingMetadata, at: staging)
        try registerActiveReplacementPrefix(staging)
        defer { unregisterActiveReplacementPrefix(staging) }
        try markReplacementStagingMayHaveProcesses(
            staging,
            lifecycleState: stagingLifecycle
        )

        let result = try await initializePrefixAndWaitForRegistryFlush(
            runtimeExecutable: runtimeExecutable,
            prefix: staging,
            logDirectory: logDirectory
        )
        try seedWineFontsIfAvailable(from: runtimeExecutable, into: staging)
        do {
            try validateUsablePrefix(at: staging, expectedArchitecture: stagingMetadata.architecture)
        } catch {
            throw PrefixManagerError.initializationFailed(result)
        }
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: staging,
            logDirectory: logDirectory
        )
        try markReplacementStagingVerifiedQuiescent(
            staging,
            lifecycleState: stagingLifecycle
        )
        let boundStagingMetadata = try bindRuntime(
            manifest,
            to: stagingMetadata,
            at: staging
        )
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        try lifecycleCoordinator.checkpoint()

        var finalMetadata = boundStagingMetadata
        finalMetadata.path = prefixURL.path
        finalMetadata.updatedAt = Date()
        let residualPreviousEnvironmentURL = try await
            replacePrefixAtomicallyPreservingInternalSteamLibrary(
                at: prefixURL,
                with: staging,
                metadata: finalMetadata,
                stagingLifecycleState: stagingLifecycle,
                preservationPlan: internalSteamLibraryPlan
            )
        return (
            value: PrefixArchitectureResetResult(
                metadata: finalMetadata,
                processResult: result,
                residualPreviousEnvironmentURL: residualPreviousEnvironmentURL
            ),
            preserveStagingOnExit: residualPreviousEnvironmentURL != nil
        )
        }
    }

    private func initializePrefixAndWaitForRegistryFlush(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> ProcessRunResult {
        let result: ProcessRunResult
        do {
            result = try await runner.run(.initializePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
        } catch {
            try await throwThrownInitializationFailureAfterCleanup(
                error,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        guard result.succeeded else {
            try await throwInitializationFailureAfterCleanup(
                result,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }

        let registryFlush: ProcessRunResult
        do {
            registryFlush = try await runner.run(.waitForWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
        } catch {
            try await throwThrownInitializationFailureAfterCleanup(
                error,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        guard registryFlush.succeeded else {
            try await throwInitializationFailureAfterCleanup(
                registryFlush,
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        }
        return result
    }

    private func throwInitializationFailureAfterCleanup(
        _ initialization: ProcessRunResult,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> Never {
        do {
            let cleanup = try await runner.run(.shutdownWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
            guard prefixShutdownPostconditionIsVerified(cleanup) else {
                throw PrefixManagerError.initializationCleanupFailed(
                    initialization: initialization,
                    cleanupDescription: prefixShutdownFailureDescription(cleanup)
                )
            }
        } catch let error as PrefixManagerError {
            throw error
        } catch {
            throw PrefixManagerError.initializationCleanupFailed(
                initialization: initialization,
                cleanupDescription: forgePlayTechnicalErrorSummary(error)
            )
        }
        throw PrefixManagerError.initializationFailed(initialization)
    }

    private func throwRuntimeReconciliationFailureAfterCleanup(
        _ reconciliation: ProcessRunResult,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> Never {
        do {
            let cleanup = try await runner.run(.shutdownWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
            guard prefixShutdownPostconditionIsVerified(cleanup) else {
                throw PrefixManagerError.runtimeReconciliationCleanupFailed(
                    reconciliation: reconciliation,
                    cleanupDescription: prefixShutdownFailureDescription(cleanup)
                )
            }
        } catch let error as PrefixManagerError {
            throw error
        } catch {
            throw PrefixManagerError.runtimeReconciliationCleanupFailed(
                reconciliation: reconciliation,
                cleanupDescription: forgePlayTechnicalErrorSummary(error)
            )
        }
        throw PrefixManagerError.runtimeReconciliationFailed(reconciliation)
    }

    private func throwThrownInitializationFailureAfterCleanup(
        _ initializationError: Error,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) async throws -> Never {
        do {
            let cleanup = try await runner.run(.shutdownWinePrefix(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory
            ))
            guard prefixShutdownPostconditionIsVerified(cleanup) else {
                throw SteamPrefixLifecycleCleanupError(
                    originalDescription: forgePlayTechnicalErrorSummary(initializationError),
                    cleanupDescription: prefixShutdownFailureDescription(cleanup),
                    originalError: initializationError,
                    originalProcessResult: diagnosticProcessRunResult(from: initializationError),
                    cleanupProcessResults: [cleanup]
                )
            }
        } catch let error as SteamPrefixLifecycleCleanupError {
            throw error
        } catch {
            throw SteamPrefixLifecycleCleanupError(
                originalDescription: forgePlayTechnicalErrorSummary(initializationError),
                cleanupDescription: forgePlayTechnicalErrorSummary(error),
                originalError: initializationError,
                cleanupError: error,
                originalProcessResult: diagnosticProcessRunResult(from: initializationError),
                cleanupProcessResults: diagnosticProcessRunResults(from: error)
            )
        }
        throw initializationError
    }

    private func shutdownExistingPrefixBeforeReplacementIfNeeded(
        runtimeExecutable: URL,
        prefixURL: URL,
        logDirectory: URL
    ) async throws {
        guard fileManager.fileExists(atPath: prefixURL.path) else {
            try await requireVerifiedPrefixReplacementQuiescence(at: prefixURL)
            return
        }
        try validatePrefixDirectory(prefixURL)
        let result = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: runtimeExecutable,
            prefix: prefixURL,
            logDirectory: logDirectory
        ))
        guard prefixShutdownPostconditionIsVerified(result) else {
            throw SteamPrefixLifecycleCleanupError(
                originalDescription: "Steam prefix replacement requires a verified inactive prefix",
                cleanupDescription: prefixShutdownFailureDescription(result),
                originalProcessResult: result,
                cleanupProcessResults: [result]
            )
        }
        try await requireVerifiedPrefixReplacementQuiescence(
            at: prefixURL,
            cleanupProcessResults: [result]
        )
    }

    /// Preserve only Steam's game-library payload and the small compatibility
    /// copy that makes registered libraries visible. Login state, userdata and
    /// the rest of the old Steam installation remain part of the fresh-prefix
    /// replacement contract.
    private func captureInternalSteamLibraryPreservationPlan(
        in prefix: URL
    ) throws -> InternalSteamLibraryPreservationPlan {
        let steamRoot = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamApps = steamRoot.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        let configDirectory = steamRoot.appending(
            path: "config",
            directoryHint: .isDirectory
        )
        let configLibraryFolders = configDirectory.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )

        let steamAppsIdentity: InternalSteamAppsIdentity?
        if let status = try optionalInternalSteamItemStatus(at: steamApps) {
            try requireInternalSteamDirectoryChain(
                ["drive_c", "Program Files (x86)", "Steam", "steamapps"],
                in: prefix
            )
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    steamApps,
                    "steamapps가 symlink가 아닌 일반 폴더가 아닙니다."
                )
            }
            steamAppsIdentity = InternalSteamAppsIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        } else {
            steamAppsIdentity = nil
        }

        let visibilitySnapshot: InternalSteamVisibilitySnapshot?
        if let initialStatus = try optionalInternalSteamItemStatus(
            at: configLibraryFolders
        ) {
            try requireInternalSteamDirectoryChain(
                ["drive_c", "Program Files (x86)", "Steam", "config"],
                in: prefix
            )
            guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
                  initialStatus.st_nlink == 1,
                  initialStatus.st_size >= 0,
                  initialStatus.st_size <=
                    off_t(Self.maxSteamLibraryVisibilityMetadataBytes) else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    configLibraryFolders,
                    "libraryfolders.vdf가 안전한 크기의 일반 파일이 아닙니다."
                )
            }
            let data = try Data(
                contentsOf: configLibraryFolders,
                options: .mappedIfSafe
            )
            guard data.count == Int(initialStatus.st_size),
                  let finalStatus = try optionalInternalSteamItemStatus(
                    at: configLibraryFolders
                  ),
                  internalSteamItemIdentityIsUnchanged(
                    initialStatus,
                    finalStatus
                  ) else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    configLibraryFolders,
                    "libraryfolders.vdf가 보존 정보를 읽는 동안 변경됐습니다."
                )
            }
            visibilitySnapshot = InternalSteamVisibilitySnapshot(
                data: data,
                permissions: mode_t(initialStatus.st_mode & 0o777)
            )
        } else {
            visibilitySnapshot = nil
        }

        return InternalSteamLibraryPreservationPlan(
            steamAppsIdentity: steamAppsIdentity,
            configLibraryFolders: visibilitySnapshot
        )
    }

    private func writeInternalSteamLibraryTransplantJournal(
        _ plan: InternalSteamLibraryPreservationPlan,
        canonicalPrefix: URL,
        replacementStaging: URL
    ) throws {
        guard plan.requiresPreservation,
              isManagedFreshReplacementStaging(
                replacementStaging,
                for: canonicalPrefix
              ) else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                canonicalPrefix,
                "Steam 라이브러리 이식 journal 대상이 올바르지 않습니다."
            )
        }
        let journal = InternalSteamLibraryTransplantJournal(
            schemaVersion: 1,
            canonicalPrefixPath: canonicalPrefix.standardizedFileURL.path,
            replacementStagingPath: replacementStaging.standardizedFileURL.path,
            steamAppsDevice: plan.steamAppsIdentity?.device,
            steamAppsInode: plan.steamAppsIdentity?.inode,
            preservesConfigLibraryFolders: plan.configLibraryFolders != nil
        )
        let journalURL = canonicalPrefix.appending(
            path: Self.steamLibraryTransplantJournalName,
            directoryHint: .notDirectory
        )
        if let status = try optionalInternalSteamItemStatus(at: journalURL) {
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1 else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    journalURL,
                    "Steam 라이브러리 이식 journal이 안전한 일반 파일이 아닙니다."
                )
            }
        }
        let data = try encoder.encode(journal)
        guard data.count <= Self.maxSteamLibraryTransplantJournalBytes else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal이 허용 크기를 초과했습니다."
            )
        }
        try data.write(to: journalURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )
        guard try loadInternalSteamLibraryTransplantJournal(
                from: canonicalPrefix,
                canonicalPrefix: canonicalPrefix
              ) == journal else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal readback이 일치하지 않습니다."
            )
        }
    }

    private func loadInternalSteamLibraryTransplantJournal(
        from physicalPrefix: URL,
        canonicalPrefix: URL
    ) throws -> InternalSteamLibraryTransplantJournal? {
        let journalURL = physicalPrefix.appending(
            path: Self.steamLibraryTransplantJournalName,
            directoryHint: .notDirectory
        )
        guard let initialStatus = try optionalInternalSteamItemStatus(
            at: journalURL
        ) else {
            return nil
        }
        guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size >= 0,
              initialStatus.st_size <=
                off_t(Self.maxSteamLibraryTransplantJournalBytes) else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal이 안전한 크기의 일반 파일이 아닙니다."
            )
        }
        let data = try Data(contentsOf: journalURL, options: .mappedIfSafe)
        guard data.count == Int(initialStatus.st_size),
              let finalStatus = try optionalInternalSteamItemStatus(
                at: journalURL
              ),
              internalSteamItemIdentityIsUnchanged(
                initialStatus,
                finalStatus
              ) else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal이 읽는 동안 변경됐습니다."
            )
        }
        let journal: InternalSteamLibraryTransplantJournal
        do {
            journal = try decoder.decode(
                InternalSteamLibraryTransplantJournal.self,
                from: data
            )
        } catch {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal을 해석하지 못했습니다."
            )
        }
        let hasCompleteSteamAppsIdentity =
            (journal.steamAppsDevice == nil) ==
                (journal.steamAppsInode == nil)
        let staging = URL(
            fileURLWithPath: journal.replacementStagingPath
        ).standardizedFileURL
        guard journal.schemaVersion == 1,
              URL(fileURLWithPath: journal.canonicalPrefixPath)
                .standardizedFileURL.path ==
                canonicalPrefix.standardizedFileURL.path,
              hasCompleteSteamAppsIdentity,
              journal.steamAppsDevice != nil ||
                journal.preservesConfigLibraryFolders,
              isManagedFreshReplacementStaging(
                staging,
                for: canonicalPrefix
              ) else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal 계약이 올바르지 않습니다."
            )
        }
        return journal
    }

    private func removeInternalSteamLibraryTransplantJournal(
        from prefix: URL
    ) throws {
        let journalURL = prefix.appending(
            path: Self.steamLibraryTransplantJournalName,
            directoryHint: .notDirectory
        )
        guard let status = try optionalInternalSteamItemStatus(
            at: journalURL
        ) else {
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal을 안전하게 제거할 수 없습니다."
            )
        }
        try fileManager.removeItem(at: journalURL)
    }

    /// The marker is the cross-restart authority that allows a surviving
    /// transplant journal to be recovered. Never remove that authority until
    /// journal removal has succeeded and its absence has been read back.
    private func removeInternalSteamLibraryTransplantJournalAndMarker(
        from prefix: URL
    ) throws {
        try removeInternalSteamLibraryTransplantJournal(from: prefix)
        let journalURL = prefix.appending(
            path: Self.steamLibraryTransplantJournalName,
            directoryHint: .notDirectory
        )
        guard try optionalInternalSteamItemStatus(at: journalURL) == nil else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                journalURL,
                "Steam 라이브러리 이식 journal 제거를 확인하지 못했습니다."
            )
        }
        try removeRecoveryPreservationMarker(from: prefix)
    }

    private func isManagedFreshReplacementStaging(
        _ staging: URL,
        for canonicalPrefix: URL
    ) -> Bool {
        let normalizedStaging = staging.standardizedFileURL
        let normalizedCanonical = canonicalPrefix.standardizedFileURL
        guard normalizedStaging.deletingLastPathComponent().path ==
                normalizedCanonical.deletingLastPathComponent().path else {
            return false
        }
        let name = normalizedStaging.lastPathComponent
        return [
            ".\(normalizedCanonical.lastPathComponent).initialize-staging-",
            ".\(normalizedCanonical.lastPathComponent).rebuild-staging-",
            ".\(normalizedCanonical.lastPathComponent).reset-staging-"
        ].contains { name.hasPrefix($0) }
    }

    private func internalSteamLibraryTransplantJournalMatches(
        _ journal: InternalSteamLibraryTransplantJournal,
        plan: InternalSteamLibraryPreservationPlan
    ) -> Bool {
        let identityMatches: Bool
        switch (
            journal.steamAppsDevice,
            journal.steamAppsInode,
            plan.steamAppsIdentity
        ) {
        case (nil, nil, nil):
            identityMatches = true
        case let (device?, inode?, identity?):
            identityMatches = device == identity.device &&
                inode == identity.inode
        default:
            identityMatches = false
        }
        return identityMatches &&
            journal.preservesConfigLibraryFolders ==
                (plan.configLibraryFolders != nil)
    }

    private func requireInternalSteamLibraryRecoveryMarker(
        at prefix: URL
    ) throws {
        let marker = prefix.appending(
            path: Self.recoveryPreservationMarkerName,
            directoryHint: .notDirectory
        )
        guard let status = try optionalInternalSteamItemStatus(at: marker),
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                marker,
                "중단된 Steam 라이브러리 이식의 보존 marker가 없습니다."
            )
        }
    }

    private func recoverInterruptedInternalSteamLibraryTransplant(
        at canonicalPrefix: URL
    ) throws {
        try validatePrefixDirectory(canonicalPrefix)

        if let journal = try loadInternalSteamLibraryTransplantJournal(
            from: canonicalPrefix,
            canonicalPrefix: canonicalPrefix
        ) {
            try requireInternalSteamLibraryRecoveryMarker(at: canonicalPrefix)
            let canonicalPlan = try captureInternalSteamLibraryPreservationPlan(
                in: canonicalPrefix
            )
            guard internalSteamLibraryTransplantJournalMatches(
                journal,
                plan: canonicalPlan
            ) else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    canonicalPrefix,
                    "교체 전 Steam 라이브러리 identity가 journal과 일치하지 않습니다."
                )
            }
            try removeInternalSteamLibraryTransplantJournalAndMarker(
                from: canonicalPrefix
            )
        }

        let candidates = try interruptedInternalSteamLibraryTransplantCandidates(
            at: canonicalPrefix
        )
        for candidate in candidates {
            try recoverInterruptedInternalSteamLibraryTransplant(
                from: candidate,
                to: canonicalPrefix
            )
        }
    }

    private func interruptedInternalSteamLibraryTransplantCandidates(
        at canonicalPrefix: URL
    ) throws -> [URL] {
        let parent = canonicalPrefix.deletingLastPathComponent()
        try requirePrefixDirectory(parent)
        let candidates = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { candidate in
            isManagedFreshReplacementStaging(
                candidate,
                for: canonicalPrefix
            ) &&
                !activeReplacementArtifactPaths.contains(
                    candidate.standardizedFileURL.path
                ) &&
                fileManager.fileExists(
                    atPath: candidate.appending(
                        path: Self.steamLibraryTransplantJournalName
                    ).path
                )
        }.sorted { $0.path < $1.path }
        guard candidates.count <=
                Self.maxSteamLibraryTransplantRecoveryCandidates else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                canonicalPrefix,
                "중단된 Steam 라이브러리 이식 후보가 허용 개수를 초과했습니다."
            )
        }
        return candidates
    }

    private func recoverInterruptedInternalSteamLibraryTransplant(
        from displacedPrefix: URL,
        to canonicalPrefix: URL
    ) throws {
        try validatePrefixDirectory(displacedPrefix)
        let journal = try loadInternalSteamLibraryTransplantJournal(
            from: displacedPrefix,
            canonicalPrefix: canonicalPrefix
        )
        guard let journal,
              URL(fileURLWithPath: journal.replacementStagingPath)
                .standardizedFileURL.path ==
                displacedPrefix.standardizedFileURL.path else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                displacedPrefix,
                "중단된 Steam 라이브러리 이식 후보가 journal과 일치하지 않습니다."
            )
        }
        let deletionMarker = displacedPrefix.appending(
            path: Self.deferredDeletionMarkerName,
            directoryHint: .notDirectory
        )
        if FileSystemItemPolicy.isRegularNonSymlinkFile(
            deletionMarker,
            fileManager: fileManager
        ) {
            _ = retireDisplacedEnvironment(displacedPrefix)
            return
        }
        try requireInternalSteamLibraryRecoveryMarker(at: displacedPrefix)

        let canonicalPlan = try captureInternalSteamLibraryPreservationPlan(
            in: canonicalPrefix
        )
        if journal.steamAppsDevice != nil,
           internalSteamLibraryTransplantJournalMatches(
            journal,
            plan: canonicalPlan
           ) {
            _ = retireDisplacedEnvironment(displacedPrefix)
            return
        }

        let displacedPlan = try captureInternalSteamLibraryPreservationPlan(
            in: displacedPrefix
        )
        guard internalSteamLibraryTransplantJournalMatches(
            journal,
            plan: displacedPlan
        ) else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                displacedPrefix,
                "보존된 Steam 라이브러리 identity가 journal과 일치하지 않습니다."
            )
        }
        try requireInternalSteamLibraryRecoveryDestination(
            canonicalPrefix,
            for: displacedPlan
        )
        try transplantInternalSteamLibrary(
            displacedPlan,
            from: displacedPrefix,
            to: canonicalPrefix
        )
        _ = retireDisplacedEnvironment(displacedPrefix)
    }

    private func requireInternalSteamLibraryRecoveryDestination(
        _ canonicalPrefix: URL,
        for plan: InternalSteamLibraryPreservationPlan
    ) throws {
        guard let expectedIdentity = plan.steamAppsIdentity else { return }
        let destination = canonicalPrefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        if let status = try optionalInternalSteamItemStatus(at: destination) {
            try requireInternalSteamDirectoryChain(
                ["drive_c", "Program Files (x86)", "Steam", "steamapps"],
                in: canonicalPrefix
            )
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  UInt64(status.st_dev) == expectedIdentity.device,
                  try fileManager.contentsOfDirectory(atPath: destination.path)
                    .isEmpty else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    destination,
                    "복구 대상 steamapps가 비어 있는 동일 볼륨의 일반 폴더가 아닙니다."
                )
            }
            return
        }

        let driveC = canonicalPrefix.appending(
            path: "drive_c",
            directoryHint: .isDirectory
        )
        try requireInternalSteamDirectoryChain(["drive_c"], in: canonicalPrefix)
        guard let driveCStatus = try optionalInternalSteamItemStatus(at: driveC),
              UInt64(driveCStatus.st_dev) == expectedIdentity.device else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                driveC,
                "Steam 라이브러리를 복구할 동일 볼륨을 확인하지 못했습니다."
            )
        }
    }

    /// Commits a freshly initialized prefix while moving the existing internal
    /// Steam game library inode into it. If the library exchange fails, the
    /// complete displaced prefix is atomically restored before the error is
    /// surfaced. This is shared by explicit rebuild and automatic fresh-prefix
    /// replacement paths so neither can silently discard installed games.
    private func replacePrefixAtomicallyPreservingInternalSteamLibrary(
        at destination: URL,
        with staging: URL,
        metadata: PrefixMetadata,
        stagingLifecycleState: ReplacementStagingLifecycleState,
        preservationPlan: InternalSteamLibraryPreservationPlan
    ) async throws -> URL? {
        if preservationPlan.requiresPreservation {
            try markReplacementStagingForRecovery(destination)
            do {
                try writeInternalSteamLibraryTransplantJournal(
                    preservationPlan,
                    canonicalPrefix: destination,
                    replacementStaging: staging
                )
            } catch {
                let journalWriteError = error
                do {
                    try removeInternalSteamLibraryTransplantJournalAndMarker(
                        from: destination
                    )
                } catch let cleanupError {
                    throw PrefixResetError.steamLibraryPreservationFailed(
                        destination,
                        "journal 작성 실패 후 복구 권한을 안전하게 정리하지 못했습니다: " +
                            "\(forgePlayTechnicalErrorSummary(journalWriteError)); " +
                            "cleanup: \(forgePlayTechnicalErrorSummary(cleanupError))"
                    )
                }
                throw journalWriteError
            }
        }

        var displacedEnvironment: URL?
        do {
            displacedEnvironment = try await replacePrefixAtomically(
                at: destination,
                with: staging,
                metadata: metadata,
                stagingLifecycleState: stagingLifecycleState,
                retainDisplacedEnvironment:
                    preservationPlan.requiresPreservation
            )
        } catch {
            if preservationPlan.requiresPreservation {
                try removeInternalSteamLibraryTransplantJournalAndMarker(
                    from: destination
                )
            }
            throw error
        }

        guard preservationPlan.requiresPreservation else {
            return displacedEnvironment
        }
        guard let displacedEnvironment else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                destination,
                "기존 프리픽스의 보존 위치를 확인하지 못했습니다."
            )
        }

        do {
            try transplantInternalSteamLibrary(
                preservationPlan,
                from: displacedEnvironment,
                to: destination
            )
        } catch {
            let preservationError = error
            do {
                try directorySwapper.swap(displacedEnvironment, destination)
                try removeInternalSteamLibraryTransplantJournalAndMarker(
                    from: destination
                )
            } catch let rollbackError {
                let preservedEnvironment = preserveDisplacedEnvironment(
                    displacedEnvironment,
                    canonicalDestination: destination
                )
                throw PrefixResetError.rollbackFailed(
                    destination: destination,
                    displacedEnvironment: preservedEnvironment,
                    originalError: preservationError,
                    rollbackError: rollbackError
                )
            }
            throw preservationError
        }

        return retireDisplacedEnvironment(displacedEnvironment)
    }

    private func transplantInternalSteamLibrary(
        _ plan: InternalSteamLibraryPreservationPlan,
        from displacedPrefix: URL,
        to replacementPrefix: URL
    ) throws {
        let replacementSteamRoot = try ensureInternalSteamDirectoryChain(
            ["drive_c", "Program Files (x86)", "Steam"],
            in: replacementPrefix
        )

        if let visibility = plan.configLibraryFolders {
            let replacementConfig = try ensureInternalSteamDirectoryChain(
                ["drive_c", "Program Files (x86)", "Steam", "config"],
                in: replacementPrefix
            )
            let destination = replacementConfig.appending(
                path: "libraryfolders.vdf",
                directoryHint: .notDirectory
            )
            if let status = try optionalInternalSteamItemStatus(at: destination) {
                guard (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_nlink == 1 else {
                    throw PrefixResetError.steamLibraryPreservationFailed(
                        destination,
                        "새 프리픽스의 libraryfolders.vdf 대상이 안전한 일반 파일이 아닙니다."
                    )
                }
            }
            try visibility.data.write(to: destination, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: visibility.permissions],
                ofItemAtPath: destination.path
            )
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(
                    destination,
                    fileManager: fileManager
                  ),
                  try Data(contentsOf: destination, options: .mappedIfSafe) ==
                    visibility.data else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    destination,
                    "새 프리픽스의 libraryfolders.vdf readback이 일치하지 않습니다."
                )
            }
        }

        guard let expectedIdentity = plan.steamAppsIdentity else { return }
        let source = displacedPrefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try requireInternalSteamDirectoryChain(
            ["drive_c", "Program Files (x86)", "Steam", "steamapps"],
            in: displacedPrefix
        )
        guard let sourceStatus = try optionalInternalSteamItemStatus(at: source),
              (sourceStatus.st_mode & S_IFMT) == S_IFDIR,
              UInt64(sourceStatus.st_dev) == expectedIdentity.device,
              UInt64(sourceStatus.st_ino) == expectedIdentity.inode else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                source,
                "기존 steamapps 폴더 identity가 prefix 교체 중 변경됐습니다."
            )
        }

        let destination = replacementSteamRoot.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        if let destinationStatus = try optionalInternalSteamItemStatus(
            at: destination
        ) {
            guard (destinationStatus.st_mode & S_IFMT) == S_IFDIR,
                  try fileManager.contentsOfDirectory(atPath: destination.path)
                    .isEmpty else {
                throw PrefixResetError.steamLibraryPreservationFailed(
                    destination,
                    "새 프리픽스에 비어 있지 않은 steamapps 폴더가 이미 있습니다."
                )
            }
        } else {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            try requireNonSymlinkDirectory(destination)
        }
        guard let destinationStatus = try optionalInternalSteamItemStatus(
                at: destination
              ),
              UInt64(destinationStatus.st_dev) == expectedIdentity.device else {
            throw PrefixResetError.steamLibraryPreservationFailed(
                destination,
                "steamapps를 복사 없이 교환할 수 있는 동일 볼륨이 아닙니다."
            )
        }

        // This is RENAME_SWAP through the same primitive that commits the
        // prefix itself. A successful call moves the original directory inode;
        // no game file is copied and no second game-library payload is created.
        try directorySwapper.swap(source, destination)
    }

    private func optionalInternalSteamItemStatus(
        at url: URL
    ) throws -> stat? {
        var status = stat()
        if Darwin.lstat(url.path, &status) == 0 { return status }
        if errno == ENOENT { return nil }
        throw PrefixResetError.steamLibraryPreservationFailed(
            url,
            "파일 identity를 확인하지 못했습니다: errno \(errno)."
        )
    }

    private func requireInternalSteamDirectoryChain(
        _ components: [String],
        in prefix: URL
    ) throws {
        try requireInternalSteamPreservationDirectory(prefix)
        var current = prefix
        for component in components {
            current = current.appending(
                path: component,
                directoryHint: .isDirectory
            )
            try requireInternalSteamPreservationDirectory(current)
        }
    }

    @discardableResult
    private func ensureInternalSteamDirectoryChain(
        _ components: [String],
        in prefix: URL
    ) throws -> URL {
        try requireInternalSteamPreservationDirectory(prefix)
        var current = prefix
        for component in components {
            current = current.appending(
                path: component,
                directoryHint: .isDirectory
            )
            if try optionalInternalSteamItemStatus(at: current) == nil {
                try fileManager.createDirectory(
                    at: current,
                    withIntermediateDirectories: false
                )
            }
            try requireInternalSteamPreservationDirectory(current)
        }
        return current
    }

    private func requireInternalSteamPreservationDirectory(
        _ directory: URL
    ) throws {
        do {
            try requireNonSymlinkDirectory(directory)
        } catch {
            throw PrefixResetError.steamLibraryPreservationFailed(
                directory,
                "Steam 라이브러리 경로가 안전한 일반 폴더가 아닙니다."
            )
        }
    }

    private func internalSteamItemIdentityIsUnchanged(
        _ first: stat,
        _ second: stat
    ) -> Bool {
        first.st_dev == second.st_dev &&
            first.st_ino == second.st_ino &&
            first.st_size == second.st_size &&
            first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
            first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private func removeRecoveryPreservationMarker(from prefix: URL) throws {
        let marker = prefix.appending(path: Self.recoveryPreservationMarkerName)
        guard let status = try optionalInternalSteamItemStatus(at: marker) else {
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw PrefixMetadataError.unsafeMetadataFile(marker)
        }
        try fileManager.removeItem(at: marker)
    }

    private func retireDisplacedEnvironment(_ displaced: URL) -> URL? {
        do {
            try fileManager.removeItem(at: displaced)
            return nil
        } catch {
            let deletionMarker = displaced.appending(
                path: Self.deferredDeletionMarkerName
            )
            do {
                try Data("delete\n".utf8).write(
                    to: deletionMarker,
                    options: [.atomic]
                )
                guard FileSystemItemPolicy.isRegularNonSymlinkFile(
                    deletionMarker,
                    fileManager: fileManager
                ) else {
                    return displaced
                }
                try removeInternalSteamLibraryTransplantJournalAndMarker(
                    from: displaced
                )
            } catch {
                // Keep the recovery marker unless both the deletion marker and
                // transplant-journal cleanup are durable. The next exclusive
                // cleanup can then finish or recover the transplant instead of
                // orphaning it.
            }
            return displaced
        }
    }

    private func replacePrefixAtomically(
        at destination: URL,
        with staging: URL,
        metadata: PrefixMetadata,
        stagingLifecycleState: ReplacementStagingLifecycleState,
        retainDisplacedEnvironment: Bool = false
    ) async throws -> URL? {
        let destinationParent = destination.deletingLastPathComponent()
        try requirePrefixDirectory(destinationParent)
        try validatePrefixDirectory(staging)
        try validatePrefixDirectory(destination)
        try writeMetadata(metadata, physicallyAt: staging, validatingFor: destination)
        try markReplacementStagingMayHaveProcesses(
            staging,
            lifecycleState: stagingLifecycleState
        )
        try await requireVerifiedPrefixReplacementQuiescence(at: staging)
        try markReplacementStagingVerifiedQuiescent(
            staging,
            lifecycleState: stagingLifecycleState
        )
        try await requireVerifiedPrefixReplacementQuiescence(at: destination)

        var didSwap = false
        do {
            try directorySwapper.swap(staging, destination)
            didSwap = true
            try validateUsablePrefix(at: destination, expectedArchitecture: metadata.architecture)
        } catch {
            if didSwap,
               fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: staging.path) {
                do {
                    try directorySwapper.swap(staging, destination)
                } catch let rollbackError {
                    let preservedEnvironment = preserveDisplacedEnvironment(
                        staging,
                        canonicalDestination: destination
                    )
                    throw PrefixResetError.rollbackFailed(
                        destination: destination,
                        displacedEnvironment: preservedEnvironment,
                        originalError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            throw error
        }

        if retainDisplacedEnvironment { return staging }
        return retireDisplacedEnvironment(staging)
    }

    func isUsablePrefix(at prefixURL: URL, expectedArchitecture explicitArchitecture: String? = nil) -> Bool {
        (try? validateUsablePrefix(at: prefixURL, expectedArchitecture: explicitArchitecture)) != nil
    }

    func cleanupInterruptedReplacementArtifacts(at prefixURL: URL) throws {
        let managedRootLeases = try acquireManagedRootOperationLease()
        defer { managedRootLeases.reversed().forEach { $0.release() } }

        try cleanupInterruptedReplacementArtifactsAssumingExclusiveAccess(at: prefixURL)
    }

    func cleanupInterruptedReplacementArtifactsAssumingExclusiveAccess(at prefixURL: URL) throws {
        try recoverInterruptedInternalSteamLibraryTransplant(at: prefixURL)
        let candidates = try replacementArtifactCleanupCandidates(
            at: prefixURL
        )
        for candidate in candidates {
            try Self.removeReplacementArtifact(
                candidate,
                fileManager: fileManager
            )
        }
    }

    func cleanupInterruptedReplacementArtifactsAssumingExclusiveAccess(
        at prefixURL: URL
    ) async throws {
        try recoverInterruptedInternalSteamLibraryTransplant(at: prefixURL)
        let candidates = try replacementArtifactCleanupCandidates(
            at: prefixURL
        )
        guard !candidates.isEmpty else { return }
        if fileManager === FileManager.default {
            try await Task.detached(priority: .utility) {
                for candidate in candidates {
                    try Self.removeReplacementArtifact(candidate)
                }
            }.value
        } else {
            for candidate in candidates {
                try Self.removeReplacementArtifact(
                    candidate,
                    fileManager: self.fileManager
                )
            }
        }
    }

    private func replacementArtifactCleanupCandidates(
        at prefixURL: URL
    ) throws -> [ReplacementArtifactCleanupCandidate] {
        guard fileManager.fileExists(atPath: prefixURL.path) else { return [] }
        if try !isUninitializedPrefixPlaceholder(at: prefixURL) {
            _ = try loadMetadata(at: prefixURL)
        }

        let parent = prefixURL.deletingLastPathComponent()
        try requirePrefixDirectory(parent)
        let artifactPrefixes = [
            ".\(prefixURL.lastPathComponent).initialize-staging-",
            ".\(prefixURL.lastPathComponent).rebuild-staging-",
            ".\(prefixURL.lastPathComponent).runtime-migration-staging-",
            ".\(prefixURL.lastPathComponent).reset-staging-"
        ]
        let candidates = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { candidate in
            artifactPrefixes.contains { candidate.lastPathComponent.hasPrefix($0) } &&
                !activeReplacementArtifactPaths.contains(candidate.path)
        }

        return try candidates.compactMap { candidate in
            try requirePrefixDirectory(candidate)
            if replacementArtifactMustBePreserved(candidate, canonicalPrefix: prefixURL) {
                return nil
            }
            var status = stat()
            guard Darwin.lstat(candidate.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR else {
                throw PrefixMetadataError.unsafePrefixDirectory(candidate)
            }
            return ReplacementArtifactCleanupCandidate(
                url: candidate,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        }
    }

    private nonisolated static func removeReplacementArtifact(
        _ candidate: ReplacementArtifactCleanupCandidate,
        fileManager: FileManager = .default
    ) throws {
        var status = stat()
        guard Darwin.lstat(candidate.url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              UInt64(status.st_dev) == candidate.device,
              UInt64(status.st_ino) == candidate.inode else {
            throw PrefixMetadataError.unsafePrefixDirectory(candidate.url)
        }
        try fileManager.removeItem(at: candidate.url)
    }

    func isUninitializedPrefixPlaceholder(at prefixURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: prefixURL.path) else { return false }
        try validatePrefixDirectory(prefixURL)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        if fileManager.fileExists(atPath: metadataURL.path) {
            return false
        }

        let contents = try fileManager.contentsOfDirectory(
            at: prefixURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        return contents.allSatisfy { candidate in
            candidate.lastPathComponent == ".DS_Store" &&
                FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager)
        }
    }

    private func preserveDisplacedEnvironment(
        _ displacedEnvironment: URL,
        canonicalDestination: URL
    ) -> URL {
        let recovery = canonicalDestination.deletingLastPathComponent().appending(
            path: ".\(canonicalDestination.lastPathComponent).recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.moveItem(at: displacedEnvironment, to: recovery)
            return recovery
        } catch {
            let marker = displacedEnvironment.appending(path: Self.recoveryPreservationMarkerName)
            try? Data("preserve\n".utf8).write(to: marker, options: [.atomic])
            return displacedEnvironment
        }
    }

    private func replacementArtifactMustBePreserved(
        _ candidate: URL,
        canonicalPrefix: URL
    ) -> Bool {
        let marker = candidate.appending(path: Self.recoveryPreservationMarkerName)
        if FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager) {
            return true
        }
        let deletionMarker = candidate.appending(path: Self.deferredDeletionMarkerName)
        if FileSystemItemPolicy.isRegularNonSymlinkFile(deletionMarker, fileManager: fileManager) {
            return false
        }

        let metadataURL = candidate.appending(path: "prefix.json")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(metadataURL, fileManager: fileManager),
              let values = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= Self.maxMetadataBytes,
              let data = try? Data(contentsOf: metadataURL),
              data.count <= Self.maxMetadataBytes,
              let metadata = try? decoder.decode(PrefixMetadata.self, from: data) else {
            return false
        }
        return URL(fileURLWithPath: metadata.path).standardizedFileURL.path ==
            canonicalPrefix.standardizedFileURL.path
    }

    private func registerActiveReplacementPrefix(_ prefix: URL) throws {
        try lifecycleCoordinator.registerManagedPrefix(prefix)
        activeReplacementArtifactPaths.insert(prefix.standardizedFileURL.path)
    }

    private func unregisterActiveReplacementPrefix(_ prefix: URL) {
        activeReplacementArtifactPaths.remove(prefix.standardizedFileURL.path)
        lifecycleCoordinator.unregisterManagedPrefix(prefix)
    }

    private func seedWineFontsIfAvailable(from runtimeExecutable: URL, into prefixURL: URL) throws {
        let sourceDirectories = wineFontSourceDirectories(for: runtimeExecutable)
        let fontFiles = try sourceDirectories.flatMap { directory -> [URL] in
            guard FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) else {
                return []
            }
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            return contents.filter { candidate in
                Self.wineFontFileExtensions.contains(candidate.pathExtension.lowercased()) &&
                    FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager)
            }
        }
        guard !fontFiles.isEmpty else {
            return
        }

        let driveC = prefixURL.appending(path: "drive_c", directoryHint: .isDirectory)
        let windows = driveC.appending(path: "windows", directoryHint: .isDirectory)
        let fonts = windows.appending(path: "Fonts", directoryHint: .isDirectory)
        try requireNonSymlinkDirectory(prefixURL)
        try requireNonSymlinkDirectory(driveC)
        if fileManager.fileExists(atPath: windows.path) {
            try requireNonSymlinkDirectory(windows)
        } else {
            try fileManager.createDirectory(at: windows, withIntermediateDirectories: false)
            try requireNonSymlinkDirectory(windows)
        }
        if fileManager.fileExists(atPath: fonts.path) {
            try requireNonSymlinkDirectory(fonts)
        } else {
            try fileManager.createDirectory(at: fonts, withIntermediateDirectories: false)
            try requireNonSymlinkDirectory(fonts)
        }

        var copiedNames = Set<String>()
        for font in fontFiles {
            let name = font.lastPathComponent
            guard copiedNames.insert(name).inserted else {
                continue
            }
            let destination = fonts.appending(path: name)
            if fileManager.fileExists(atPath: destination.path) {
                try requireRegularNonSymlinkFile(destination)
                continue
            }
            try fileManager.copyItem(at: font, to: destination)
            try requireRegularNonSymlinkFile(destination)
        }
    }

    private func wineFontSourceDirectories(for runtimeExecutable: URL) -> [URL] {
        var directories: [URL] = []
        if let wineRoot = wineRootDirectory(for: runtimeExecutable) {
            directories.append(wineRoot.appending(path: "share/wine/fonts", directoryHint: .isDirectory))
        }
        if let contents = bundleContentsDirectory(for: runtimeExecutable) {
            directories.append(contents.appending(path: "Resources/wine/share/wine/fonts", directoryHint: .isDirectory))
            directories.append(contents.appending(path: "SharedSupport/wine/share/wine/fonts", directoryHint: .isDirectory))
        }
        return deduplicated(directories.map(\.standardizedFileURL))
    }

    private func wineRootDirectory(for executable: URL) -> URL? {
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent.lowercased() == "bin" else {
            return nil
        }
        return binDirectory.deletingLastPathComponent()
    }

    private func bundleContentsDirectory(for executable: URL) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let contentsIndex = components.lastIndex(of: "Contents") else {
            return nil
        }
        let contents = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...contentsIndex])))
        return FileSystemItemPolicy.isNonSymlinkDirectory(contents, fileManager: fileManager) ? contents : nil
    }

    private func prefixNeedsInitialization(
        _ prefixURL: URL,
        expectedArchitecture explicitArchitecture: String?
    ) throws -> Bool {
        do {
            try validateUsablePrefix(at: prefixURL, expectedArchitecture: explicitArchitecture)
            return false
        } catch PrefixUsabilityError.missingRequiredItem {
            return true
        } catch {
            throw error
        }
    }

    func validateUsablePrefix(at prefixURL: URL, expectedArchitecture explicitArchitecture: String? = nil) throws {
        let driveC = prefixURL.appending(path: "drive_c", directoryHint: .isDirectory)
        let systemRegistry = prefixURL.appending(path: "system.reg")
        let userRegistry = prefixURL.appending(path: "user.reg")
        let dosdevices = prefixURL.appending(path: "dosdevices", directoryHint: .isDirectory)
        let cDriveLink = dosdevices.appending(path: "c:")
        let zDriveLink = dosdevices.appending(path: "z:")

        try requireNonSymlinkDirectory(prefixURL)
        try requireNonSymlinkDirectory(driveC)
        try requireRegularNonSymlinkFile(systemRegistry)
        try requireRegularNonSymlinkFile(userRegistry)
        try requireNonSymlinkDirectory(dosdevices)
        guard fileManager.fileExists(atPath: cDriveLink.path) || fileManager.fileExists(atPath: zDriveLink.path) else {
            throw PrefixUsabilityError.missingRequiredItem(cDriveLink)
        }

        let metadataURL = prefixURL.appending(path: "prefix.json")
        let metadataArchitecture: String?
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                let metadata = try loadMetadata(at: prefixURL)
                metadataArchitecture = explicitArchitecture ?? metadata.architecture
            } catch {
                throw PrefixUsabilityError.invalidMetadata(metadataURL, forgePlayTechnicalErrorSummary(error))
            }
        } else {
            if let explicitArchitecture {
                metadataArchitecture = explicitArchitecture
            } else {
                metadataArchitecture = nil
            }
        }
        let actualArchitecture: String?
        do {
            actualArchitecture = try prefixArchitecture(at: prefixURL)
        } catch {
            throw PrefixUsabilityError.unreadableRequiredItem(systemRegistry, forgePlayTechnicalErrorSummary(error))
        }
        guard let expectedArchitecture = metadataArchitecture?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedArchitecture.isEmpty else {
            return
        }
        guard let actualArchitecture else {
            throw PrefixUsabilityError.architectureMismatch(
                prefixURL,
                expected: expectedArchitecture,
                actual: nil
            )
        }
        guard actualArchitecture.caseInsensitiveCompare(expectedArchitecture) == .orderedSame else {
            throw PrefixUsabilityError.architectureMismatch(
                prefixURL,
                expected: expectedArchitecture,
                actual: actualArchitecture
            )
        }
    }

    func prefixArchitecture(at prefixURL: URL) throws -> String? {
        let systemRegistry = prefixURL.appending(path: "system.reg")
        try requireRegularNonSymlinkFile(systemRegistry)
        let descriptor = Darwin.open(
            systemRegistry.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        defer { Darwin.close(descriptor) }
        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1 else {
            throw PrefixUsabilityError.unsafeRequiredItem(systemRegistry)
        }
        let maximumHeaderBytes = 64 * 1024
        var data = Data(count: maximumHeaderBytes)
        let byteCount = data.withUnsafeMutableBytes { bytes in
            Darwin.pread(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        guard byteCount >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        data.removeSubrange(Int(byteCount)..<data.count)
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              initialStatus.st_dev == finalStatus.st_dev,
              initialStatus.st_ino == finalStatus.st_ino,
              initialStatus.st_size == finalStatus.st_size,
              initialStatus.st_mtimespec.tv_sec ==
                finalStatus.st_mtimespec.tv_sec,
              initialStatus.st_mtimespec.tv_nsec ==
                finalStatus.st_mtimespec.tv_nsec,
              initialStatus.st_ctimespec.tv_sec ==
                finalStatus.st_ctimespec.tv_sec,
              initialStatus.st_ctimespec.tv_nsec ==
                finalStatus.st_ctimespec.tv_nsec else {
            throw PrefixUsabilityError.unreadableRequiredItem(
                systemRegistry,
                "system.reg header changed while it was being read"
            )
        }
        let content = String(decoding: data, as: UTF8.self)

        for line in content.split(whereSeparator: \.isNewline).prefix(50) {
            let trimmed = String(line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard trimmed.hasPrefix("#arch=") else { continue }
            let value = trimmed.dropFirst("#arch=".count)
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private func requireNonSymlinkDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PrefixUsabilityError.missingRequiredItem(url)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw PrefixUsabilityError.unreadableRequiredItem(url, forgePlayTechnicalErrorSummary(error))
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PrefixUsabilityError.unsafeRequiredItem(url)
        }
    }

    private func requireRegularNonSymlinkFile(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw PrefixUsabilityError.missingRequiredItem(url)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey])
        } catch {
            throw PrefixUsabilityError.unreadableRequiredItem(url, forgePlayTechnicalErrorSummary(error))
        }
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true,
              (values.linkCount ?? 1) == 1 else {
            throw PrefixUsabilityError.unsafeRequiredItem(url)
        }
    }

    func snapshot(prefixURL: URL, reason: String) async throws -> URL {
        try validatePrefixDirectory(prefixURL)
        var metadata = try loadMetadata(at: prefixURL)
        let snapshotsRoot = try pathManager.url(for: .prefixSnapshots)
        try pathManager.createDirectoryIfNeeded(snapshotsRoot)
        let safeName = PathManager.sanitizedFileName(prefixURL.lastPathComponent)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let identifier = UUID().uuidString
        let destination = snapshotsRoot.appending(
            path: "\(safeName)_\(stamp)_\(identifier)_\(PathManager.sanitizedFileName(reason))",
            directoryHint: .isDirectory
        )
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.copyItem(at: prefixURL, to: destination)
        }.value

        if !metadata.snapshots.contains(destination.path) {
            metadata.snapshots.append(destination.path)
        }
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
        return destination
    }

    func restore(snapshotURL: URL, to prefixURL: URL) throws {
        try validatePrefixDirectory(snapshotURL)
        let destinationParent = prefixURL.deletingLastPathComponent()
        try requirePrefixDirectory(destinationParent)

        let staging = destinationParent.appending(
            path: ".\(prefixURL.lastPathComponent).restore-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let backup = destinationParent.appending(
            path: ".\(prefixURL.lastPathComponent).restore-backup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var didMoveExistingToBackup = false
        var shouldRemoveBackup = true
        defer {
            try? fileManager.removeItem(at: staging)
            if shouldRemoveBackup {
                try? fileManager.removeItem(at: backup)
            }
        }

        try fileManager.copyItem(at: snapshotURL, to: staging)
        try validatePrefixDirectory(staging)

        if fileManager.fileExists(atPath: prefixURL.path) {
            try validatePrefixDirectory(prefixURL)
            try fileManager.moveItem(at: prefixURL, to: backup)
            didMoveExistingToBackup = true
        }

        do {
            try fileManager.moveItem(at: staging, to: prefixURL)
            try validatePrefixDirectory(prefixURL)
        } catch {
            if fileManager.fileExists(atPath: prefixURL.path) {
                do {
                    try fileManager.removeItem(at: prefixURL)
                } catch let cleanupError {
                    shouldRemoveBackup = false
                    throw PrefixRestoreError.rollbackFailed(
                        destination: prefixURL,
                        backup: backup,
                        originalError: error,
                        rollbackError: cleanupError
                    )
                }
            }
            if didMoveExistingToBackup,
               !fileManager.fileExists(atPath: prefixURL.path),
               fileManager.fileExists(atPath: backup.path) {
                do {
                    try fileManager.moveItem(at: backup, to: prefixURL)
                } catch let rollbackError {
                    shouldRemoveBackup = false
                    throw PrefixRestoreError.rollbackFailed(
                        destination: prefixURL,
                        backup: backup,
                        originalError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            throw error
        }
    }

    func delete(prefixURL: URL) throws {
        if fileManager.fileExists(atPath: prefixURL.path) {
            try validatePrefixDirectory(prefixURL)
            try fileManager.removeItem(at: prefixURL)
        }
    }

    func loadMetadata(at prefixURL: URL) throws -> PrefixMetadata {
        try validatePrefixDirectory(prefixURL)
        let metadataURL = prefixURL.appending(path: "prefix.json")
        try requirePrefixMetadataFile(metadataURL)
        let fileSize: Int
        do {
            fileSize = try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw PrefixMetadataError.metadataReadFailed(metadataURL, forgePlayTechnicalErrorSummary(error))
        }
        guard fileSize <= Self.maxMetadataBytes else {
            throw PrefixMetadataError.metadataTooLarge(metadataURL, fileSize, Self.maxMetadataBytes)
        }
        let data = try Data(contentsOf: metadataURL)
        guard data.count <= Self.maxMetadataBytes else {
            throw PrefixMetadataError.metadataTooLarge(metadataURL, data.count, Self.maxMetadataBytes)
        }
        let metadata = try decoder.decode(PrefixMetadata.self, from: data)
        return try validatedMetadata(metadata, prefixURL: prefixURL)
    }

    func save(_ metadata: PrefixMetadata, at prefixURL: URL) throws {
        try pathManager.createDirectoryIfNeeded(prefixURL)
        try validatePrefixDirectory(prefixURL)
        try writeMetadata(metadata, physicallyAt: prefixURL, validatingFor: prefixURL)
    }

    private func writeMetadata(
        _ metadata: PrefixMetadata,
        physicallyAt physicalPrefixURL: URL,
        validatingFor logicalPrefixURL: URL
    ) throws {
        try validatePrefixDirectory(physicalPrefixURL)
        let metadata = try validatedMetadata(metadata, prefixURL: logicalPrefixURL)
        let data = try encoder.encode(metadata)
        guard data.count <= Self.maxMetadataBytes else {
            throw PrefixMetadataError.metadataTooLarge(
                physicalPrefixURL.appending(path: "prefix.json"),
                data.count,
                Self.maxMetadataBytes
            )
        }
        try data.write(to: physicalPrefixURL.appending(path: "prefix.json"), options: [.atomic])
    }

    func markRuntimeInstalled(_ runtime: RuntimeId, prefixURL: URL) throws {
        var metadata = try loadMetadata(at: prefixURL)
        if !metadata.installedRuntimes.contains(runtime) {
            metadata.installedRuntimes.append(runtime)
        }
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
    }

    @discardableResult
    func ensureEnvironmentGenerationID(at prefixURL: URL) throws -> String {
        var metadata = try loadMetadata(at: prefixURL)
        if let generationID = metadata.environmentGenerationID {
            return generationID
        }
        let generationID = UUID().uuidString
        metadata.environmentGenerationID = generationID
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
        return generationID
    }

    @discardableResult
    func rotateEnvironmentGeneration(at prefixURL: URL) throws -> String {
        var metadata = try loadMetadata(at: prefixURL)
        let generationID = UUID().uuidString
        metadata.environmentGenerationID = generationID
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
        return generationID
    }

    @discardableResult
    func ensureSteamSharedEnvironmentGenerationID() throws -> String {
        try ensureEnvironmentGenerationID(at: pathManager.url(for: .steamSharedPrefix))
    }

    @discardableResult
    func rotateSteamSharedEnvironmentGeneration() throws -> String {
        try rotateEnvironmentGeneration(at: pathManager.url(for: .steamSharedPrefix))
    }

    func appliedSynchronizationBackend(at prefixURL: URL) throws -> WineSynchronizationBackend {
        try loadMetadata(at: prefixURL).synchronizationBackend ?? .server
    }

    @discardableResult
    func setAppliedSynchronizationPolicy(
        selection: WineSynchronizationSelection,
        backend: WineSynchronizationBackend,
        at prefixURL: URL
    ) throws -> Bool {
        let synchronizationPolicy = WineSynchronizationPolicy(
            selection: selection,
            backend: backend
        )
        try requireConsistentSynchronizationPolicy(
            synchronizationPolicy,
            metadataURL: prefixURL.appending(path: "prefix.json")
        )
        var metadata = try loadMetadata(at: prefixURL)
        let previousBackend = metadata.synchronizationBackend ?? .server
        let previousSelection = metadata.synchronizationSelection ?? .automatic
        guard previousBackend != backend || previousSelection != selection else { return false }
        metadata.synchronizationSelection = selection
        metadata.synchronizationBackend = backend
        if previousBackend != backend {
            metadata.environmentGenerationID = UUID().uuidString
        }
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
        return previousBackend != backend
    }

    func applyWindowsVersion(_ version: String, prefixURL: URL, runtimeExecutable: URL) async throws -> ProcessRunResult {
        try validateUsablePrefix(at: prefixURL)
        let logDirectory = try pathManager.url(for: .runtimeLogs)
        let result = try await runner.run(.setWindowsVersion(
            runtimeExecutable: runtimeExecutable,
            prefix: prefixURL,
            version: version,
            logDirectory: logDirectory
        ))
        if result.succeeded {
            try setWindowsVersion(version, prefixURL: prefixURL)
        }
        return result
    }

    func setWindowsVersion(_ version: String, prefixURL: URL) throws {
        var metadata = try loadMetadata(at: prefixURL)
        metadata.windowsVersion = version
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
    }

    func applyDLLOverride(_ dll: String, override: String, prefixURL: URL, runtimeExecutable: URL) async throws -> ProcessRunResult {
        try validateUsablePrefix(at: prefixURL)
        let logDirectory = try pathManager.url(for: .runtimeLogs)
        let result = try await runner.run(.setDLLOverride(
            runtimeExecutable: runtimeExecutable,
            prefix: prefixURL,
            dll: dll,
            override: override,
            logDirectory: logDirectory
        ))
        if result.succeeded {
            try addDLLOverride("\(dll)=\(override)", prefixURL: prefixURL)
        }
        return result
    }

    func addLaunchOption(_ option: String, prefixURL: URL) throws {
        var metadata = try loadMetadata(at: prefixURL)
        if !metadata.launchOptions.contains(option) {
            metadata.launchOptions.append(option)
        }
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
    }

    func addDLLOverride(_ override: String, prefixURL: URL) throws {
        var metadata = try loadMetadata(at: prefixURL)
        if !metadata.dllOverrides.contains(override) {
            metadata.dllOverrides.append(override)
        }
        metadata.updatedAt = Date()
        try save(metadata, at: prefixURL)
    }

    private func snapshotExistingPrefixIfNeeded(prefixURL: URL, reason: String) async throws -> URL? {
        guard fileManager.fileExists(atPath: prefixURL.path) else {
            return nil
        }
        try validatePrefixDirectory(prefixURL)
        let meaningfulEntries = try fileManager.contentsOfDirectory(
            at: prefixURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard meaningfulEntries.contains(where: { $0.lastPathComponent != "prefix.json" }) else {
            return nil
        }
        return try await snapshot(prefixURL: prefixURL, reason: reason)
    }

    private func resetPrefixIfArchitectureMismatch(
        metadata: PrefixMetadata,
        prefixURL: URL,
        runtimeExecutable: URL,
        manifest: RuntimeManifest
    ) async throws -> PrefixArchitectureResetResult {
        let actualArchitecture: String?
        do {
            actualArchitecture = try prefixArchitecture(at: prefixURL)
        } catch PrefixUsabilityError.missingRequiredItem {
            return PrefixArchitectureResetResult(
                metadata: metadata,
                processResult: nil,
                residualPreviousEnvironmentURL: nil
            )
        }
        guard let actualArchitecture,
              actualArchitecture.caseInsensitiveCompare(metadata.architecture) != .orderedSame else {
            return PrefixArchitectureResetResult(
                metadata: metadata,
                processResult: nil,
                residualPreviousEnvironmentURL: nil
            )
        }

        let logDirectory = try pathManager.url(for: .installLogs)
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        let internalSteamLibraryPlan = try
            captureInternalSteamLibraryPreservationPlan(in: prefixURL)

        let destinationParent = prefixURL.deletingLastPathComponent()
        try requirePrefixDirectory(destinationParent)
        let staging = destinationParent.appending(
            path: ".\(prefixURL.lastPathComponent).reset-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        return try await withReplacementStaging(
            at: staging,
            runtimeExecutable: runtimeExecutable,
            logDirectory: logDirectory
        ) { stagingLifecycle in

        let stagingMetadata = freshSteamSharedMetadata(
            at: staging,
            architecture: metadata.architecture,
            windowsVersion: metadata.windowsVersion,
            synchronizationPolicy: appliedSynchronizationPolicy(in: metadata)
        )
        try save(stagingMetadata, at: staging)
        try registerActiveReplacementPrefix(staging)
        defer { unregisterActiveReplacementPrefix(staging) }
        try markReplacementStagingMayHaveProcesses(
            staging,
            lifecycleState: stagingLifecycle
        )

        let result = try await initializePrefixAndWaitForRegistryFlush(
            runtimeExecutable: runtimeExecutable,
            prefix: staging,
            logDirectory: logDirectory
        )
        try seedWineFontsIfAvailable(from: runtimeExecutable, into: staging)
        do {
            try validateUsablePrefix(at: staging, expectedArchitecture: stagingMetadata.architecture)
        } catch {
            throw PrefixManagerError.initializationFailed(result)
        }
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: staging,
            logDirectory: logDirectory
        )
        try markReplacementStagingVerifiedQuiescent(
            staging,
            lifecycleState: stagingLifecycle
        )
        let boundStagingMetadata = try bindRuntime(
            manifest,
            to: stagingMetadata,
            at: staging
        )
        try await shutdownExistingPrefixBeforeReplacementIfNeeded(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL,
            logDirectory: logDirectory
        )
        try lifecycleCoordinator.checkpoint()

        var finalMetadata = boundStagingMetadata
        finalMetadata.path = prefixURL.path
        finalMetadata.updatedAt = Date()
        let residualPreviousEnvironmentURL = try await
            replacePrefixAtomicallyPreservingInternalSteamLibrary(
                at: prefixURL,
                with: staging,
                metadata: finalMetadata,
                stagingLifecycleState: stagingLifecycle,
                preservationPlan: internalSteamLibraryPlan
            )
        return (
            value: PrefixArchitectureResetResult(
                metadata: finalMetadata,
                processResult: result,
                residualPreviousEnvironmentURL: residualPreviousEnvironmentURL
            ),
            preserveStagingOnExit: residualPreviousEnvironmentURL != nil
        )
        }
    }

    private func createPrefixDirectory(at prefixURL: URL) throws {
        do {
            try pathManager.createDirectoryIfNeeded(prefixURL)
        } catch PathManagerError.unsafeDirectory {
            throw PrefixMetadataError.unsafePrefixDirectory(prefixURL)
        }
        try validatePrefixDirectory(prefixURL)
    }

    private func validatePrefixDirectory(_ prefixURL: URL) throws {
        try requirePrefixDirectory(prefixURL)
    }

    private func requirePrefixDirectory(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            throw PrefixMetadataError.unsafePrefixDirectory(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw PrefixMetadataError.metadataReadFailed(url, message)
        } catch {
            throw PrefixMetadataError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private func requirePrefixMetadataFile(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notRegularNonSymlinkFile {
            throw PrefixMetadataError.unsafeMetadataFile(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw PrefixMetadataError.metadataReadFailed(url, message)
        } catch {
            throw PrefixMetadataError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private func validatedMetadata(_ metadata: PrefixMetadata, prefixURL: URL) throws -> PrefixMetadata {
        let metadataURL = prefixURL.appending(path: "prefix.json")
        guard (1...PrefixMetadata.currentSchemaVersion).contains(metadata.schemaVersion),
              metadata.path == prefixURL.path,
              !metadata.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.environmentGenerationID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw PrefixMetadataError.invalidMetadata(metadataURL)
        }

        if metadata.schemaVersion == 1, metadata.runtimeBinding != nil {
            throw PrefixMetadataError.invalidMetadata(metadataURL)
        }
        if let binding = metadata.runtimeBinding {
            guard (1...PrefixRuntimeBinding.currentSchemaVersion)
                    .contains(binding.schemaVersion),
                  !binding.runtimeIdentifier.isEmpty,
                  binding.runtimeIdentifier.count <= Self.maxMetadataStringLength,
                  isLowercaseSHA256(binding.runnerBuildFingerprint),
                  isLowercaseSHA256(binding.prefixCompatibilityFingerprint),
                  isLowercaseSHA256(binding.wineInfSHA256) else {
                throw PrefixMetadataError.invalidMetadata(metadataURL)
            }
            switch binding.schemaVersion {
            case 1:
                guard binding.prefixCompatibilityEpoch == nil else {
                    throw PrefixMetadataError.invalidMetadata(metadataURL)
                }
            case PrefixRuntimeBinding.currentSchemaVersion:
                guard binding.prefixCompatibilityEpoch ==
                        PrefixRuntimeBinding.currentPrefixCompatibilityEpoch else {
                    throw PrefixMetadataError.invalidMetadata(metadataURL)
                }
            default:
                throw PrefixMetadataError.invalidMetadata(metadataURL)
            }
        }

        var normalized = metadata
        normalized.installedRuntimes = deduplicated(normalized.installedRuntimes)
        normalized.dllOverrides = normalizedStringList(normalized.dllOverrides)
        normalized.launchOptions = deduplicated(normalized.launchOptions.compactMap {
            LLMRecommendedActionPolicy.normalizedLaunchOption($0)
        })
        normalized.snapshots = normalizedStringList(normalized.snapshots)
        normalized.environmentVariables = [:]
        normalized.synchronizationSelection = .automatic
        normalized.synchronizationBackend = .server

        guard WineSynchronizationPolicy.isConsistent(
                  selection: normalized.synchronizationSelection ?? .automatic,
                  backend: normalized.synchronizationBackend ?? .server
              ),
              normalized.installedRuntimes.count <= Self.maxMetadataListItems,
              normalized.dllOverrides.count <= Self.maxMetadataListItems,
              normalized.launchOptions.count <= Self.maxMetadataListItems,
              normalized.snapshots.count <= Self.maxMetadataListItems else {
            throw PrefixMetadataError.invalidMetadata(metadataURL)
        }

        return normalized
    }

    private func normalizedStringList(_ values: [String]) -> [String] {
        deduplicated(values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= Self.maxMetadataStringLength,
                  trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            return trimmed
        })
    }

    private func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private func inspectRuntimeCompatibility(
        at prefixURL: URL,
        manifest: RuntimeManifest
    ) -> PrefixRuntimeCompatibilityInspection {
        do {
            let metadata = try loadMetadata(at: prefixURL)
            guard metadata.schemaVersion == PrefixMetadata.currentSchemaVersion else {
                return .migrationRequired("legacy prefix metadata has no runtime binding")
            }
            guard let binding = metadata.runtimeBinding else {
                return .migrationRequired("prefix runtime binding is missing")
            }
            guard binding.matchesPrefixCompatibility(manifest) else {
                return .migrationRequired(
                    "Prefix compatibility contract does not match the bundled ForgePlay Runtime"
                )
            }
            guard automaticWinePrefixUpdatesAreDisabled(at: prefixURL) else {
                return .migrationRequired("Wine automatic prefix update marker is not controlled by ForgePlay")
            }
            return .compatible
        } catch {
            return .runtimeUnavailable(forgePlayTechnicalErrorSummary(error))
        }
    }

    private func bindRuntime(
        _ manifest: RuntimeManifest,
        to metadata: PrefixMetadata,
        at prefixURL: URL
    ) throws -> PrefixMetadata {
        var bound = metadata
        bound.schemaVersion = PrefixMetadata.currentSchemaVersion
        bound.runtimeBinding = PrefixRuntimeBinding(manifest: manifest)
        bound.environmentGenerationID = UUID().uuidString
        bound.updatedAt = Date()
        try disableAutomaticWinePrefixUpdates(at: prefixURL)
        try save(bound, at: prefixURL)
        return bound
    }

    private func disableAutomaticWinePrefixUpdates(at prefixURL: URL) throws {
        try validatePrefixDirectory(prefixURL)
        let marker = prefixURL.appending(path: ".update-timestamp")
        if fileManager.fileExists(atPath: marker.path),
           !FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager) {
            throw PrefixMetadataError.unsafeMetadataFile(marker)
        }
        try Data("disable\n".utf8).write(to: marker, options: [.atomic])
        guard automaticWinePrefixUpdatesAreDisabled(at: prefixURL) else {
            throw PrefixMetadataError.invalidMetadata(marker)
        }
    }

    private func automaticWinePrefixUpdatesAreDisabled(at prefixURL: URL) -> Bool {
        let marker = prefixURL.appending(path: ".update-timestamp")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(marker, fileManager: fileManager),
              let values = try? marker.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= 64,
              let value = try? String(contentsOf: marker, encoding: .utf8) else {
            return false
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == "disable"
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private func freshSteamSharedMetadata(
        at prefixURL: URL,
        architecture: String = WinePrefixDefaults.architecture,
        windowsVersion: String = WinePrefixDefaults.windowsVersion,
        createdAt: Date = Date(),
        synchronizationPolicy: WineSynchronizationPolicy = .automaticServer
    ) -> PrefixMetadata {
        precondition(synchronizationPolicy.isConsistent)
        return PrefixMetadata(
            schemaVersion: PrefixMetadata.currentSchemaVersion,
            id: PrefixIdentifier.steamShared,
            environmentGenerationID: UUID().uuidString,
            synchronizationSelection: synchronizationPolicy.selection,
            synchronizationBackend: synchronizationPolicy.backend,
            displayName: PrefixMode.steamShared.beginnerName,
            path: prefixURL.path,
            mode: .steamShared,
            runner: WinePrefixDefaults.runner,
            runtimeBinding: nil,
            architecture: architecture,
            windowsVersion: windowsVersion,
            createdAt: createdAt,
            updatedAt: createdAt,
            installedRuntimes: [],
            dllOverrides: [],
            environmentVariables: [:],
            launchOptions: [],
            snapshots: []
        )
    }

    private func appliedSynchronizationPolicy(
        in metadata: PrefixMetadata
    ) -> WineSynchronizationPolicy {
        WineSynchronizationPolicy(
            selection: metadata.synchronizationSelection ?? .automatic,
            backend: metadata.synchronizationBackend ?? .server
        )
    }

    private func requireConsistentSynchronizationPolicy(
        _ synchronizationPolicy: WineSynchronizationPolicy,
        metadataURL: URL
    ) throws {
        guard synchronizationPolicy.isConsistent else {
            throw PrefixMetadataError.invalidMetadata(metadataURL)
        }
    }
}
