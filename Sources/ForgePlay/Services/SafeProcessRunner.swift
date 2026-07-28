// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import Darwin
import CryptoKit
import Foundation

struct ProcessRunResult: Sendable, Hashable {
    var actionName: String
    var executable: URL
    var arguments: [String]
    var startedAt: Date
    var endedAt: Date
    var exitCode: Int32
    /// `false` for failures that occurred before an operating-system process
    /// produced an exit status. `exitCode` remains non-optional for source
    /// compatibility, but must not be persisted or presented as a real process
    /// status in that case.
    var hasProcessExitCode: Bool = true
    /// ForgePlay's own operation/verification result. This is intentionally
    /// separate from `exitCode`: values such as Steam evidence gate 74 are not
    /// operating-system process exit statuses.
    var forgePlayStatusCode: Int32? = nil
    var stdoutLog: URL
    var stderrLog: URL
    var diagnosticLog: URL? = nil
    var didTimeOut: Bool
    var waitedForExit: Bool = true
    var outcome: ProcessRunOutcome = .unknown
    var terminationSignal: Int32? = nil
    var rawWaitStatus: Int32? = nil
    var steamUIVerificationState: SteamUIVerificationState? = nil
    var steamUISurface: SteamUISurface? = nil
    var processIdentifier: Int32? = nil
    var processObservationLog: URL? = nil
    var steamUIStartupRecoveryAttemptCount: Int = 0
    var steamUIStartupRecoveryReason: String? = nil
    var runEvidenceLog: URL? = nil
    /// Structured sidecars for additional commands that are part of this
    /// operation (for example a Wine shutdown barrier or a prior retry).
    var relatedRunEvidenceLogs: [URL] = []
    var evidenceCaptureWarning: String? = nil
    var diagnosticCaptureWarning: String? = nil
    /// A localization key for a bounded warning that should be shown alongside
    /// an otherwise successful process launch. Technical diagnostics remain in
    /// `diagnosticCaptureWarning` and the structured process evidence.
    var userFacingWarningLocalizationKey: String? = nil
    /// The authoritative postcondition for a multi-process operation. Wine
    /// prefix shutdown uses this to preserve a failed/timed-out signal attempt
    /// while still reporting success when cleanup plus the wineserver exit
    /// barrier prove that the prefix is no longer active.
    var postconditionSatisfied: Bool? = nil
}

struct CommandSpec: Sendable, Hashable {
    var actionName: String
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var runtimeCompatibility: [String: String] = [:]
    var workingDirectory: URL?
    var stdoutLog: URL
    var stderrLog: URL
    var timeout: TimeInterval?
    var waitsForExit: Bool = true
    var startupValidationInterval: TimeInterval = 0
    var processObservationLog: URL? = nil
    /// Path-free, bounded records written before the child starts so the child
    /// inherits a log offset after these records and cannot overwrite them.
    var preparationDiagnosticMarkers: [String] = []
    var preparationDiagnosticWarning: String? = nil
    var userFacingWarningLocalizationKey: String? = nil
}

private struct RunnerSearchPaths {
    var dynamicLibraries: [String]
    var frameworks: [String]
    var d3dMetalFrameworkExecutables: [String]
    var wineDLLs: [String]
    var vulkanICDs: [String]
}

enum WineSynchronizationBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case server

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let legacyValue = try container.decode(String.self)
        guard ["server", "msync", "esync"].contains(legacyValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Wine synchronization backend: \(legacyValue)"
            )
        }
        self = .server
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.server.rawValue)
    }
}

/// Records every Wine prefix touched by this ForgePlay process. The registry is
/// deliberately independent of the actor so the synchronous application-
/// termination planner can include prefixes used before a storage-root change.
struct ManagedWineProcessLaunchSession: Hashable, Sendable {
    let prefixURL: URL
    let runIdentifier: String
    let evidenceURL: URL
    let runtimeRootURL: URL
    let runtimeFingerprint: String
    let prefixScope: String
    let registeredAt: Date
}

final class ManagedWineSessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var prefixesByPath: [String: URL] = [:]
    private var launchSessionsByPrefixPath:
        [String: [String: ManagedWineProcessLaunchSession]] = [:]

    func record(_ prefix: URL) {
        let normalized = prefix.standardizedFileURL
        lock.withLock {
            prefixesByPath[normalized.path] = normalized
        }
    }

    var prefixURLs: [URL] {
        lock.withLock {
            prefixesByPath.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        }
    }

    func record(_ launchSession: ManagedWineProcessLaunchSession) {
        let prefix = launchSession.prefixURL.standardizedFileURL
        lock.withLock {
            prefixesByPath[prefix.path] = prefix
            var sessions = launchSessionsByPrefixPath[prefix.path] ?? [:]
            sessions[launchSession.runIdentifier] = launchSession
            launchSessionsByPrefixPath[prefix.path] = sessions
        }
    }

    func launchSessions(for prefix: URL) -> [ManagedWineProcessLaunchSession] {
        let prefixPath = prefix.standardizedFileURL.path
        return lock.withLock {
            guard let sessions = launchSessionsByPrefixPath[prefixPath] else {
                return []
            }
            return sessions.values.sorted { $0.registeredAt < $1.registeredAt }
        }
    }

    func completeSessions(
        for prefix: URL
    ) -> [ManagedWineProcessLaunchSession] {
        let prefixPath = prefix.standardizedFileURL.path
        return lock.withLock {
            prefixesByPath.removeValue(forKey: prefixPath)
            guard let sessions = launchSessionsByPrefixPath.removeValue(
                forKey: prefixPath
            ) else {
                return []
            }
            return sessions.values.sorted {
                $0.registeredAt < $1.registeredAt
            }
        }
    }
}

enum ManagedWineProcessJournal {
    static let evidenceFileKey =
        "FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE"
    static let runIdentifierKey =
        "FORGEPLAY_MANAGED_WINE_PROCESS_RUN_ID"
    static let prefixScopeKey =
        "FORGEPLAY_MANAGED_WINE_PREFIX_SCOPE"
    static let runtimeFingerprintKey =
        "FORGEPLAY_MANAGED_WINE_RUNTIME_FINGERPRINT"
    static let evidenceDirectoryName = "ManagedWineProcessEvidence"

    static func prefixScope(for prefix: URL) -> String {
        let normalizedPath = prefix.standardizedFileURL.path
        let input = Data(
            ("forgeplay-managed-wine-prefix-v1\n" + normalizedPath)
                .utf8
        )
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func evidenceFileURL(
        runIdentifier: String,
        fallbackDirectory: URL,
        fileManager: FileManager = .default,
        sandboxEnabled: Bool =
            ForgePlaySandboxPolicy.isAppSandboxEnabled
    ) throws -> URL {
        guard let normalizedRunIdentifier = UUID(uuidString: runIdentifier)?
            .uuidString.lowercased() else {
            throw SafeProcessRunnerError.cannotCreateLog(fallbackDirectory)
        }
        let fileName = "\(normalizedRunIdentifier).jsonl"
        guard sandboxEnabled else {
            return fallbackDirectory
                .appending(
                    path: fileName,
                    directoryHint: .notDirectory
                )
                .standardizedFileURL
        }
        guard let applicationGroupIdentifier =
                ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
              let groupContainer = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier:
                    applicationGroupIdentifier
              ) else {
            throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
        }
        let directory = groupContainer
            .appending(
                path: "Library/Application Support/ForgePlay",
                directoryHint: .isDirectory
            )
            .appending(
                path: evidenceDirectoryName,
                directoryHint: .isDirectory
            )
            .standardizedFileURL
        do {
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                directory,
                trustedAncestor: groupContainer,
                privateTailComponentCount: 1
            )
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                directory,
                fileManager: fileManager
            ) else {
                throw SafeProcessRunnerError.cannotCreateLog(directory)
            }
            return directory.appending(
                path: fileName,
                directoryHint: .notDirectory
            )
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(directory)
        }
    }
}

struct WineSynchronizationPolicy: Hashable, Sendable {
    var selection: WineSynchronizationSelection
    var backend: WineSynchronizationBackend

    static let automaticServer = WineSynchronizationPolicy(
        selection: .automatic,
        backend: .server
    )

    static func isConsistent(
        selection: WineSynchronizationSelection,
        backend: WineSynchronizationBackend
    ) -> Bool {
        // Legacy selections remain decodable only for migration. ForgePlay's
        // direct runtime contract exposes one deterministic synchronization path.
        backend == .server
    }

    var isConsistent: Bool {
        Self.isConsistent(selection: selection, backend: backend)
    }
}

struct WineSynchronizationRuntimeCapabilities: Hashable, Sendable {
    var supportedBackends: Set<WineSynchronizationBackend>

    func supports(_ backend: WineSynchronizationBackend) -> Bool {
        supportedBackends.contains(backend)
    }

    var preferredAutomaticBackend: WineSynchronizationBackend {
        .server
    }
}

enum RunnerAction: Sendable, Hashable {
    case initializePrefix(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case migratePrefixRuntime(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case waitForWinePrefix(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case probeRuntime(executable: URL, logDirectory: URL)
    case installSteam(runtimeExecutable: URL, prefix: URL, installer: URL, logDirectory: URL)
    case requestSteamClientShutdown(runtimeExecutable: URL, prefix: URL, steamExecutable: URL, logDirectory: URL)
    case shutdownWinePrefix(runtimeExecutable: URL, prefix: URL, logDirectory: URL)
    case launchSteam(
        runtimeExecutable: URL,
        prefix: URL,
        steamExecutable: URL,
        steamArguments: [String],
        graphicsBackend: SteamRendererPolicyPreference?,
        gameModePolicy: SteamGameModeLaunchPolicy = .standard,
        logDirectory: URL,
        externalStorageRoots: [URL] = []
    )
    case extractRuntimeArchive(runtimeExecutable: URL, prefix: URL, archive: URL, extractionDirectory: URL, runtime: RuntimeId, logDirectory: URL)
    case installRuntime(runtimeExecutable: URL, prefix: URL, installer: URL, runtime: RuntimeId, logDirectory: URL)
    case setWindowsVersion(runtimeExecutable: URL, prefix: URL, version: String, logDirectory: URL)
    case setRegistryValue(runtimeExecutable: URL, prefix: URL, registryPath: String, valueName: String, valueType: String?, value: String, logDirectory: URL)
    case setDLLOverride(runtimeExecutable: URL, prefix: URL, dll: String, override: String, logDirectory: URL)
    case setAppDLLOverride(runtimeExecutable: URL, prefix: URL, appExecutable: String, dll: String, override: String, logDirectory: URL)
    case deleteAppDLLOverrideIfPresent(runtimeExecutable: URL, prefix: URL, appExecutable: String, dll: String, logDirectory: URL)
    case createSupportArchive(sourceDirectory: URL, destinationZip: URL, logDirectory: URL)
}

extension RunnerAction {
    var diagnosticLogDirectoryURL: URL {
        switch self {
        case .initializePrefix(_, _, let logDirectory),
             .migratePrefixRuntime(_, _, let logDirectory),
             .waitForWinePrefix(_, _, let logDirectory),
             .probeRuntime(_, let logDirectory),
             .installSteam(_, _, _, let logDirectory),
             .requestSteamClientShutdown(_, _, _, let logDirectory),
             .shutdownWinePrefix(_, _, let logDirectory),
             .launchSteam(_, _, _, _, _, _, let logDirectory, _),
             .extractRuntimeArchive(_, _, _, _, _, let logDirectory),
             .installRuntime(_, _, _, _, let logDirectory),
             .setWindowsVersion(_, _, _, let logDirectory),
             .setRegistryValue(_, _, _, _, _, _, let logDirectory),
             .setDLLOverride(_, _, _, _, let logDirectory),
             .setAppDLLOverride(_, _, _, _, _, let logDirectory),
             .deleteAppDLLOverrideIfPresent(_, _, _, _, let logDirectory),
             .createSupportArchive(_, _, let logDirectory):
            logDirectory
        }
    }

    var detachedProcessPrefixURL: URL? {
        switch self {
        case .initializePrefix(_, let prefix, _),
             .migratePrefixRuntime(_, let prefix, _),
             .waitForWinePrefix(_, let prefix, _),
             .installSteam(_, let prefix, _, _),
             .requestSteamClientShutdown(_, let prefix, _, _),
             .shutdownWinePrefix(_, let prefix, _),
             .launchSteam(_, let prefix, _, _, _, _, _, _),
             .extractRuntimeArchive(_, let prefix, _, _, _, _),
             .installRuntime(_, let prefix, _, _, _),
             .setWindowsVersion(_, let prefix, _, _),
             .setRegistryValue(_, let prefix, _, _, _, _, _),
             .setDLLOverride(_, let prefix, _, _, _),
             .setAppDLLOverride(_, let prefix, _, _, _, _),
             .deleteAppDLLOverrideIfPresent(_, let prefix, _, _, _):
            return prefix.standardizedFileURL
        case .probeRuntime, .createSupportArchive:
            return nil
        }
    }

    var windowsRuntimeExecutableURL: URL? {
        switch self {
        case .initializePrefix(let runtimeExecutable, _, _),
             .migratePrefixRuntime(let runtimeExecutable, _, _),
             .waitForWinePrefix(let runtimeExecutable, _, _),
             .installSteam(let runtimeExecutable, _, _, _),
             .requestSteamClientShutdown(let runtimeExecutable, _, _, _),
             .shutdownWinePrefix(let runtimeExecutable, _, _),
             .launchSteam(let runtimeExecutable, _, _, _, _, _, _, _),
             .extractRuntimeArchive(let runtimeExecutable, _, _, _, _, _),
             .installRuntime(let runtimeExecutable, _, _, _, _),
             .setWindowsVersion(let runtimeExecutable, _, _, _),
             .setRegistryValue(let runtimeExecutable, _, _, _, _, _, _),
             .setDLLOverride(let runtimeExecutable, _, _, _, _),
             .setAppDLLOverride(let runtimeExecutable, _, _, _, _, _),
             .deleteAppDLLOverrideIfPresent(let runtimeExecutable, _, _, _, _):
            runtimeExecutable
        case .probeRuntime(let executable, _):
            executable
        case .createSupportArchive:
            nil
        }
    }

    var requiresWindowsRuntime: Bool {
        switch self {
        case .createSupportArchive:
            false
        case .initializePrefix,
             .migratePrefixRuntime,
             .waitForWinePrefix,
             .probeRuntime,
             .installSteam,
             .requestSteamClientShutdown,
             .shutdownWinePrefix,
             .launchSteam,
             .extractRuntimeArchive,
             .installRuntime,
             .setWindowsVersion,
             .setRegistryValue,
             .setDLLOverride,
             .setAppDLLOverride,
             .deleteAppDLLOverrideIfPresent:
            true
        }
    }

    var requiresManagedWineProcessJournal: Bool {
        switch self {
        case .waitForWinePrefix,
             .probeRuntime,
             .shutdownWinePrefix,
             .createSupportArchive:
            false
        case .initializePrefix,
             .migratePrefixRuntime,
             .installSteam,
             .requestSteamClientShutdown,
             .launchSteam,
             .extractRuntimeArchive,
             .installRuntime,
             .setWindowsVersion,
             .setRegistryValue,
             .setDLLOverride,
             .setAppDLLOverride,
             .deleteAppDLLOverrideIfPresent:
            true
        }
    }

    var capabilityActionName: String {
        switch self {
        case .initializePrefix:
            "initializePrefix"
        case .migratePrefixRuntime:
            "migratePrefixRuntime"
        case .waitForWinePrefix:
            "waitForWinePrefix"
        case .probeRuntime:
            "probeRuntime"
        case .installSteam:
            "installSteam"
        case .requestSteamClientShutdown:
            "requestSteamClientShutdown"
        case .shutdownWinePrefix:
            "shutdownWinePrefix"
        case .launchSteam:
            "launchSteam"
        case .extractRuntimeArchive:
            "extractRuntimeArchive"
        case .installRuntime:
            "installRuntime"
        case .setWindowsVersion:
            "setWindowsVersion"
        case .setRegistryValue:
            "setRegistryValue"
        case .setDLLOverride:
            "setDLLOverride"
        case .setAppDLLOverride:
            "setAppDLLOverride"
        case .deleteAppDLLOverrideIfPresent:
            "deleteAppDLLOverrideIfPresent"
        case .createSupportArchive:
            "createSupportArchive"
        }
    }
}

enum ForgePlayRuntimeCapabilityError: LocalizedError, ForgePlayTechnicalDescribingError, Sendable {
    case bundledRuntimeUnavailable(actionName: String)
    case nonBundledRuntimeRejected(actionName: String, path: String)
    case bundledRuntimeIdentityIncomplete(actionName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .bundledRuntimeUnavailable(let actionName):
            "앱에 포함된 ForgePlay Runtime을 사용할 수 없습니다: \(actionName)"
        case .nonBundledRuntimeRejected(let actionName, let path):
            "ForgePlay는 앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용합니다: \(actionName), \(path)"
        case .bundledRuntimeIdentityIncomplete(let actionName, let reason):
            "앱에 포함된 ForgePlay Runtime의 핵심 모듈 무결성을 확인할 수 없습니다: \(actionName). \(reason)"
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .bundledRuntimeUnavailable(let actionName):
            "bundled ForgePlay Runtime is unavailable: action=\(actionName)"
        case .nonBundledRuntimeRejected(let actionName, let path):
            "non-bundled Windows runtime rejected: action=\(actionName), path=\(path)"
        case .bundledRuntimeIdentityIncomplete(let actionName, let reason):
            "bundled ForgePlay Runtime identity is incomplete: action=\(actionName), reason=\(reason)"
        }
    }
}

enum ForgePlayRuntimeCapabilityPolicy {
    private static let legacyIdentityCleanupActions: Set<String> = [
        "shutdownWinePrefix"
    ]

    static var canImportAppleSupplementalRenderer: Bool {
        true
    }

    static func allowsLegacyIdentityForCleanup(
        actionName: String,
        schemaVersion: Int
    ) -> Bool {
        legacyIdentityCleanupActions.contains(actionName) &&
            schemaVersion >= 2 &&
            schemaVersion < RuntimeManifest.currentSchemaVersion
    }

    static var bundledWindowsRuntimeExecutableURL: URL? {
        ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL()
    }

    static var canRunBundledWindowsRuntime: Bool {
        guard let executable = bundledWindowsRuntimeExecutableURL else { return false }
        return (try? validateBundledWindowsRuntime(
            executable: executable,
            actionName: "runtimeCapability"
        )) != nil
    }

    static var unavailableReasonKey: String {
        "앱에 포함된 ForgePlay Runtime을 사용할 수 없습니다. Runtime이 온전히 포함된 ForgePlay 빌드를 다시 설치하세요."
    }

    static var supplementalRendererImportDetailKey: String {
        "실행 엔진은 항상 앱에 포함된 ForgePlay Runtime입니다. 필요한 경우 Apple 공식 Evaluation environment의 D3DMetal 보조 렌더러만 가져올 수 있습니다."
    }

    static var runtimeUpdateGuidanceKey: String {
        "앱에 포함된 ForgePlay Runtime은 앱 업데이트로만 교체됩니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
    }

    static func validateBundledWindowsRuntime(
        executable: URL,
        actionName: String
    ) throws {
        guard ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(executable) else {
            throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                actionName: actionName,
                path: executable.path
            )
        }
        do {
            let manifest = try RuntimeManifestResolver().manifest(for: executable)
            // Cleanup must remain available when an app update raises the
            // launch/runtime identity schema. Otherwise an older, still
            // bundled Wine environment cannot be stopped before storage
            // activation or app termination. This exception is deliberately
            // limited to the fixed wineserver shutdown action; launching Wine,
            // Steam, installers, or games still requires current core identity.
            if allowsLegacyIdentityForCleanup(
                actionName: actionName,
                schemaVersion: manifest.schemaVersion
            ) {
                return
            }
            guard manifest.schemaVersion == RuntimeManifest.currentSchemaVersion,
                  manifest.corePayloadFingerprintState == "verified",
                  manifest.identityIssues?.isEmpty == true else {
                throw ForgePlayRuntimeCapabilityError.bundledRuntimeIdentityIncomplete(
                    actionName: actionName,
                    reason: manifest.identityIssues?.joined(separator: " | ") ??
                        "runtime manifest schema \(manifest.schemaVersion) is not release-current"
                )
            }
        } catch let error as ForgePlayRuntimeCapabilityError {
            throw error
        } catch {
            throw ForgePlayRuntimeCapabilityError.bundledRuntimeIdentityIncomplete(
                actionName: actionName,
                reason: forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    static func validateBundledWindowsRuntimeAvailability(actionName: String) throws {
        guard canRunBundledWindowsRuntime else {
            throw ForgePlayRuntimeCapabilityError.bundledRuntimeUnavailable(
                actionName: actionName
            )
        }
    }
}

enum SafeProcessRunnerError: LocalizedError, ForgePlayTechnicalDescribingError {
    case executableMissing(URL)
    case unsafeExecutable(URL)
    case unsafeActionInput(URL)
    case unsafeArchivePath(URL)
    case cannotCreateLog(URL)
    case metadataReadFailed(URL, String)
    case runnerLibrarySearchFailed(URL, Error)
    case prefixProcessVerificationFailed(URL, String)
    case manualRendererSelectionRequired
    case gameRendererPayloadMissing(URL, String)
    case invalidPrefixSynchronizationProfile(URL)
    case sandboxIPCConfigurationMissing
    case unsafeWineServerRoot(URL, String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let url):
            "실행 파일을 찾을 수 없습니다: \(url.path)"
        case .unsafeExecutable(let url):
            "실행 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: \(url.path)"
        case .unsafeActionInput(let url):
            "실행 입력 경로가 안전한 일반 파일/폴더가 아닙니다: \(url.path)"
        case .unsafeArchivePath(let url):
            "압축 파일 경로가 안전한 일반 경로가 아닙니다: \(url.path)"
        case .cannotCreateLog(let url):
            "로그 파일을 만들 수 없습니다: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "실행 입력 경로 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .runnerLibrarySearchFailed(let url, let error):
            "ForgePlay Runtime의 라이브러리 경로를 검사하지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .prefixProcessVerificationFailed(let url, let message):
            "ForgePlay Runtime 프로세스 정리 상태를 확인하지 못했습니다: \(url.path). \(message)"
        case .manualRendererSelectionRequired:
            "Steam을 실행하기 전에 D3DMetal, DXMT, D9VK 또는 DXVK 중 하나를 직접 선택해야 합니다."
        case .gameRendererPayloadMissing(let url, let architecture):
            "선택한 게임 렌더러의 \(architecture) DLL payload를 찾지 못했습니다: \(url.path)"
        case .invalidPrefixSynchronizationProfile(let url):
            "Steam 프리픽스의 Wine 동기화 설정을 읽을 수 없습니다: \(url.path)"
        case .sandboxIPCConfigurationMissing:
            "샌드박스 배포 앱의 ForgePlay Runtime IPC 구성이 없습니다. App Group이 포함된 앱을 다시 설치하세요."
        case .unsafeWineServerRoot(let url, let reason):
            "Wine 서버 경로를 안전하게 준비하지 못했습니다: \(url.path). \(reason)"
        }
    }

    var forgePlayTechnicalDescription: String {
        errorDescription ?? "ForgePlay Runtime process error"
    }
}

actor SafeProcessRunner {
    typealias WindowsRuntimeValidator = @Sendable (_ executable: URL, _ actionName: String) throws -> Void
    typealias ManagedWineRuntimeFingerprintResolver =
        @Sendable (_ executable: URL) throws -> String
    typealias ExternalStorageGrantPublisher = @Sendable (
        _ roots: [URL],
        _ prefix: URL,
        _ runIdentifier: String
    ) throws -> SteamExternalStorageProcessGrant
    typealias GameModeSteamChildSelectionResolver = @Sendable (
        _ runtimeExecutable: URL,
        _ prefix: URL,
        _ evidenceLogURL: URL,
        _ runIdentifier: String
    ) throws -> GameModeSteamChildHostSelection

    private struct TrackedDetachedProcess {
        let process: Process
        let prefixPath: String
    }

    private struct GameModeHostLaunchRecord: Hashable, Sendable {
        let prefixPath: String
        let runIdentifier: String
        let evidenceURL: URL
        let executableURL: URL
        let registeredAt: Date
    }

    private struct GameModeHostEvidenceRecord: Decodable {
        let schemaVersion: Int
        let producer: String
        let eventCode: String
        let recordedAtUnixMilliseconds: Int64
        let darwinPID: Int32
        let runIdentifier: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case producer
            case eventCode = "event_code"
            case recordedAtUnixMilliseconds = "recorded_at_unix_milliseconds"
            case darwinPID = "darwin_pid"
            case runIdentifier = "run_identifier"
        }
    }

    private struct GameModeHostEvidenceProcessIdentity: Hashable, Sendable {
        let processID: pid_t
        let recordedAt: Date
    }

    private struct ManagedWineProcessEvidenceRecord: Decodable {
        let schemaVersion: Int
        let producer: String
        let eventCode: String
        let role: String
        let runIdentifier: String
        let prefixScope: String
        let runtimeFingerprint: String
        let darwinPID: Int32
        let recordedAtUnixMilliseconds: Int64
        let processStartedAtUnixMicroseconds: Int64

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case producer
            case eventCode = "event_code"
            case role
            case runIdentifier = "run_identifier"
            case prefixScope = "prefix_scope"
            case runtimeFingerprint = "runtime_fingerprint"
            case darwinPID = "darwin_pid"
            case recordedAtUnixMilliseconds = "recorded_at_unix_milliseconds"
            case processStartedAtUnixMicroseconds =
                "process_started_at_unix_microseconds"
        }
    }

    private struct ManagedWineProcessEvidenceIdentity: Hashable, Sendable {
        let processID: pid_t
        let processStartedAt: Date
    }

    private let fileManager: FileManager
    private let sandboxEnabled: Bool
    private let managedWineProcessEvidenceSandboxEnabled: Bool
    private let windowsRuntimeValidator: WindowsRuntimeValidator
    private let managedWineRuntimeFingerprintResolver:
        ManagedWineRuntimeFingerprintResolver
    private let externalStorageGrantPublisher:
        ExternalStorageGrantPublisher
    private let gameModeSteamChildSelectionResolver:
        GameModeSteamChildSelectionResolver
    private let managedWineSessionRegistry: ManagedWineSessionRegistry
    private var trackedDetachedProcesses: [pid_t: TrackedDetachedProcess] = [:]
    private var gameModeHostLaunchRecords: Set<GameModeHostLaunchRecord> = []

    init(
        fileManager: FileManager = .default,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        managedWineProcessEvidenceSandboxEnabled: Bool? = nil,
        managedWineSessionRegistry: ManagedWineSessionRegistry =
            ManagedWineSessionRegistry(),
        externalStorageGrantPublisher:
            @escaping ExternalStorageGrantPublisher = {
                roots,
                prefix,
                runIdentifier in
                try SteamExternalStorageProcessGrantPublisher().publish(
                    roots: roots,
                    prefix: prefix,
                    runIdentifier: runIdentifier
                )
            },
        gameModeSteamChildSelectionResolver:
            @escaping GameModeSteamChildSelectionResolver = {
                runtimeExecutable,
                prefix,
                evidenceLogURL,
                runIdentifier in
                try GameModeHostCapabilityInspector()
                    .inspectSteamChildSelection(
                        runtimeExecutable: runtimeExecutable,
                        prefix: prefix,
                        evidenceLogURL: evidenceLogURL,
                        runIdentifier: runIdentifier
                    )
            },
        managedWineRuntimeFingerprintResolver:
            @escaping ManagedWineRuntimeFingerprintResolver = {
                executable in
                try RuntimeManifestResolver()
                    .manifest(for: executable)
                    .runnerBuildFingerprint
            },
        windowsRuntimeValidator: @escaping WindowsRuntimeValidator = { executable, actionName in
            try ForgePlayRuntimeCapabilityPolicy.validateBundledWindowsRuntime(
                executable: executable,
                actionName: actionName
            )
        }
    ) {
        self.fileManager = fileManager
        self.sandboxEnabled = sandboxEnabled
        self.managedWineProcessEvidenceSandboxEnabled =
            managedWineProcessEvidenceSandboxEnabled ?? sandboxEnabled
        self.managedWineSessionRegistry = managedWineSessionRegistry
        self.externalStorageGrantPublisher =
            externalStorageGrantPublisher
        self.gameModeSteamChildSelectionResolver =
            gameModeSteamChildSelectionResolver
        self.managedWineRuntimeFingerprintResolver =
            managedWineRuntimeFingerprintResolver
        self.windowsRuntimeValidator = windowsRuntimeValidator
    }

    func run(_ action: RunnerAction) async throws -> ProcessRunResult {
        let attemptStartedAt = Date()
        if let prefix = action.detachedProcessPrefixURL {
            managedWineSessionRegistry.record(prefix)
        }
        let spec: CommandSpec
        do {
            if action.requiresWindowsRuntime {
                guard let executable = action.windowsRuntimeExecutableURL else {
                    throw ForgePlayRuntimeCapabilityError.bundledRuntimeUnavailable(
                        actionName: action.capabilityActionName
                    )
                }
                try windowsRuntimeValidator(executable, action.capabilityActionName)
                try requireExecutableFile(executable)
                guard fileManager.isExecutableFile(atPath: executable.path) else {
                    throw SafeProcessRunnerError.executableMissing(executable)
                }
            }
            try validateActionInputs(for: action)
            var preparedSpec = try makeCommandSpec(for: action)
            if action.requiresManagedWineProcessJournal,
               let prefix = action.detachedProcessPrefixURL,
               let runtimeExecutable =
                action.windowsRuntimeExecutableURL {
                preparedSpec = try attachingManagedWineProcessJournal(
                    to: preparedSpec,
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: action.diagnosticLogDirectoryURL
                )
            }
            preparedSpec.runtimeCompatibility.merge(
                Self.runtimeCompatibilityDiagnostics(
                    from: preparedSpec.environment
                ),
                uniquingKeysWith: { preparedValue, _ in preparedValue }
            )
            spec = preparedSpec
            registerGameModeHostLaunch(
                from: spec,
                prefix: action.detachedProcessPrefixURL,
                registeredAt: attemptStartedAt
            )
        } catch {
            if let result = persistActionPreparationFailureEvidence(
                action: action,
                startedAt: attemptStartedAt,
                error: error
            ) {
                throw ProcessExecutionEvidenceError(underlyingError: error, result: result)
            }
            throw error
        }
        pruneTrackedDetachedProcesses()
        var result: ProcessRunResult
        do {
            result = try run(
                spec,
                detachedProcessPrefix: action.detachedProcessPrefixURL
            )
            result = Self.applyingPreparationDiagnostics(
                from: spec,
                to: result
            )
            registerManagedWineProcessLaunch(
                from: spec,
                prefix: action.detachedProcessPrefixURL,
                registeredAt: attemptStartedAt,
                result: result
            )
        } catch {
            if let failureResult = persistSpawnFailureEvidence(
                spec: spec,
                startedAt: attemptStartedAt,
                error: error
            ) {
                // A launcher can fail its parent-side startup gate after Wine
                // already created detached children. Preserve the journal
                // session whenever that failure still produced runtime
                // evidence so application termination cannot lose ownership
                // of those children.
                registerManagedWineProcessLaunch(
                    from: spec,
                    prefix: action.detachedProcessPrefixURL,
                    registeredAt: attemptStartedAt,
                    result: failureResult
                )
                throw ProcessExecutionEvidenceError(underlyingError: error, result: failureResult)
            }
            throw error
        }
        switch action {
        case .shutdownWinePrefix(let runtimeExecutable, let prefix, let logDirectory):
            do {
                result = try completeWinePrefixShutdown(
                    after: result,
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    logDirectory: logDirectory
                )
            } catch {
                // Preserve the primary attempt and link any secondary-command
                // evidence when a barrier or recovery command could not start.
                var failedShutdown = result
                if let secondaryFailure = diagnosticProcessRunResult(from: error),
                   let secondaryEvidence = secondaryFailure.runEvidenceLog {
                    failedShutdown.relatedRunEvidenceLogs.append(secondaryEvidence)
                }
                failedShutdown.relatedRunEvidenceLogs = Self.deduplicated(
                    failedShutdown.relatedRunEvidenceLogs.map(\.standardizedFileURL)
                )
                failedShutdown.postconditionSatisfied = false
                let warning =
                    "Wine prefix shutdown verification could not complete: " +
                    forgePlayTechnicalErrorSummary(error)
                failedShutdown.diagnosticCaptureWarning = DiagnosticWarningText.combined(
                    failedShutdown.diagnosticCaptureWarning,
                    warning
                )
                _ = appendDiagnosticLines(
                    ["", "[ForgePlay] \(warning)"],
                    to: failedShutdown.stderrLog
                )
                let persisted = persistProcessEvidence(failedShutdown, spec: spec)
                throw ProcessExecutionEvidenceError(
                    underlyingError: error,
                    result: persisted
                )
            }
        default:
            break
        }
        return persistProcessEvidence(result, spec: spec)
    }

    private nonisolated static func applyingPreparationDiagnostics(
        from spec: CommandSpec,
        to input: ProcessRunResult
    ) -> ProcessRunResult {
        var result = input
        result.diagnosticCaptureWarning = DiagnosticWarningText.combined(
            result.diagnosticCaptureWarning,
            spec.preparationDiagnosticWarning
        )
        result.userFacingWarningLocalizationKey =
            spec.userFacingWarningLocalizationKey ??
            result.userFacingWarningLocalizationKey
        return result
    }

    /// Rewrites the primary process sidecar after the owning operation has
    /// attached its final policy status, diagnostics, warnings, and related
    /// process evidence. The replacement is atomic and identity-checked so a
    /// stale or substituted sidecar can never be updated in place.
    func finalizeProcessEvidence(
        _ input: ProcessRunResult,
        finalizedAt: Date = Date()
    ) -> ProcessRunResult {
        var result = input
        guard let evidenceURL = result.runEvidenceLog else { return result }

        let expectedURL = ProcessRunEvidenceWriter.evidenceURL(for: result.stderrLog)
            .standardizedFileURL
        guard evidenceURL.standardizedFileURL == expectedURL else {
            return processEvidenceFinalizationFailure(
                result,
                error: ProcessRunEvidenceWriterError.invalidEvidenceIdentity(evidenceURL)
            )
        }

        do {
            var document = try ProcessRunEvidenceWriter.read(
                from: expectedURL,
                fileManager: fileManager
            )
            let expectedRunIdentifier = ProcessRunEvidenceWriter.runIdentifier(
                for: result.stderrLog
            )
            guard ProcessRunEvidenceDocument.readableSchemaVersions.contains(document.schemaVersion),
                  document.runIdentifier.lowercased() == expectedRunIdentifier.lowercased(),
                  URL(fileURLWithPath: document.stderrLog).standardizedFileURL ==
                    result.stderrLog.standardizedFileURL else {
                throw ProcessRunEvidenceWriterError.invalidEvidenceIdentity(expectedURL)
            }

            document.schemaVersion = ProcessRunEvidenceDocument.schemaVersion
            document.finalizedAt = finalizedAt
            document.activityLeaseExpiresAt = Self.evidenceActivityLeaseExpiration(
                for: result,
                relativeTo: finalizedAt
            )
            document.endedAt = result.endedAt
            document.durationMilliseconds = Int64(
                max(0, result.endedAt.timeIntervalSince(result.startedAt) * 1_000)
            )
            document.outcome = result.outcome
            document.exitCode = result.processExitCode
            document.forgePlayStatusCode = result.forgePlayStatusCode
            document.relatedRunEvidenceLogs = result.relatedRunEvidenceLogs.map {
                $0.standardizedFileURL.path
            }
            document.terminationSignal = result.terminationSignal
            document.rawWaitStatus = result.rawWaitStatus
            document.didTimeOut = result.didTimeOut
            document.waitedForExit = result.waitedForExit
            document.processIdentifier = result.processIdentifier
            document.stdoutLog = result.stdoutLog.standardizedFileURL.path
            document.stderrLog = result.stderrLog.standardizedFileURL.path
            document.processObservationLog = result.processObservationLog?
                .standardizedFileURL.path
            document.diagnosticLog = result.diagnosticLog?.standardizedFileURL.path
            document.evidenceCaptureWarning = result.evidenceCaptureWarning
            document.diagnosticCaptureWarning = result.diagnosticCaptureWarning
            document.postconditionSatisfied = result.postconditionSatisfied
            try ProcessRunEvidenceWriter.write(
                document,
                to: expectedURL,
                fileManager: fileManager
            )
            result.runEvidenceLog = expectedURL
        } catch {
            result = processEvidenceFinalizationFailure(result, error: error)
        }
        return result
    }

    func hasManagedPrefixActivity(_ prefix: URL) throws -> Bool {
        return try !managedPrefixActivityProcessIDs(under: prefix).isEmpty
    }

    func waitForManagedPrefixProcessesToExit(
        _ prefix: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        repeat {
            if try managedPrefixActivityProcessIDs(under: prefix).isEmpty {
                return true
            }
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .seconds(max(pollInterval, 0.05)))
        } while !Task.isCancelled
        return false
    }

    private func run(
        _ spec: CommandSpec,
        detachedProcessPrefix: URL?
    ) throws -> ProcessRunResult {
        if !FileSystemItemPolicy.isRegularNonSymlinkFile(spec.executable, fileManager: fileManager) {
            try requireExecutableFile(spec.executable)
        }
        guard fileManager.isExecutableFile(atPath: spec.executable.path) else {
            throw SafeProcessRunnerError.executableMissing(spec.executable)
        }

        guard spec.stdoutLog.standardizedFileURL.path != spec.stderrLog.standardizedFileURL.path else {
            throw SafeProcessRunnerError.cannotCreateLog(spec.stdoutLog)
        }

        if let observationLog = spec.processObservationLog {
            let observationPath = observationLog.standardizedFileURL.path
            guard observationPath != spec.stdoutLog.standardizedFileURL.path,
                  observationPath != spec.stderrLog.standardizedFileURL.path else {
                throw SafeProcessRunnerError.cannotCreateLog(observationLog)
            }
            let observation = try Self.openLogFileHandle(at: observationLog, fileManager: fileManager)
            try? observation.close()
        }

        let stdout = try Self.openLogFileHandle(at: spec.stdoutLog, fileManager: fileManager)
        let stderr: FileHandle
        do {
            stderr = try Self.openLogFileHandle(at: spec.stderrLog, fileManager: fileManager)
        } catch {
            try? stdout.close()
            throw error
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        if !spec.preparationDiagnosticMarkers.isEmpty {
            let payload = spec.preparationDiagnosticMarkers
                .joined(separator: "\n") + "\n"
            // The same structured state is also persisted in
            // `runtimeCompatibility`. A best-effort raw marker must not turn an
            // optional external-storage failure back into a launch blocker.
            try? stderr.write(contentsOf: Data(payload.utf8))
        }

        let processEnvironment = Self.processEnvironment(overrides: spec.environment)
        let startedAt = Date()
        if spec.waitsForExit, let timeout = spec.timeout, timeout > 0 {
            let execution = try BoundedProcessExecutor.run(
                executable: spec.executable,
                arguments: spec.arguments,
                environment: processEnvironment,
                workingDirectory: spec.workingDirectory,
                stdoutDescriptor: stdout.fileDescriptor,
                stderrDescriptor: stderr.fileDescriptor,
                timeout: timeout
            )
            return ProcessRunResult(
                actionName: spec.actionName,
                executable: spec.executable,
                arguments: spec.arguments,
                startedAt: startedAt,
                endedAt: Date(),
                exitCode: execution.processExitCode ?? 0,
                hasProcessExitCode: execution.processExitCode != nil,
                forgePlayStatusCode: execution.forgePlayStatusCode,
                stdoutLog: spec.stdoutLog,
                stderrLog: spec.stderrLog,
                didTimeOut: execution.waitOutcome.didTimeOut,
                waitedForExit: execution.waitOutcome.didExit,
                outcome: execution.waitOutcome.didTimeOut
                    ? .timedOut
                    : (execution.rawWaitStatus == nil
                        ? .unknown
                        : (execution.terminationSignal == nil ? .exited : .signaled)),
                terminationSignal: execution.terminationSignal,
                rawWaitStatus: execution.rawWaitStatus,
                processIdentifier: execution.processIdentifier,
                processObservationLog: spec.processObservationLog,
                evidenceCaptureWarning: execution.waitStatusCaptureError.map {
                    "Process exit status capture failed: \($0)"
                }
            )
        }

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = processEnvironment
        process.currentDirectoryURL = spec.workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        guard spec.waitsForExit else {
            if spec.startupValidationInterval > 0 {
                let deadline = Date().addingTimeInterval(spec.startupValidationInterval)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if !process.isRunning {
                    process.waitUntilExit()
                    let endedAt = Date()
                    return ProcessRunResult(
                        actionName: spec.actionName,
                        executable: spec.executable,
                        arguments: spec.arguments,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        exitCode: process.terminationStatus,
                        hasProcessExitCode: process.terminationReason == .exit,
                        stdoutLog: spec.stdoutLog,
                        stderrLog: spec.stderrLog,
                        didTimeOut: false,
                        waitedForExit: true,
                        outcome: process.terminationReason == .uncaughtSignal ? .signaled : .exited,
                        terminationSignal: process.terminationReason == .uncaughtSignal
                            ? process.terminationStatus
                            : nil,
                        processIdentifier: process.processIdentifier,
                        processObservationLog: spec.processObservationLog
                    )
                }
            }
            if let detachedProcessPrefix, process.isRunning {
                trackDetachedProcess(process, for: detachedProcessPrefix)
            }
            let endedAt = Date()
            return ProcessRunResult(
                actionName: spec.actionName,
                executable: spec.executable,
                arguments: spec.arguments,
                startedAt: startedAt,
                endedAt: endedAt,
                exitCode: 0,
                hasProcessExitCode: false,
                stdoutLog: spec.stdoutLog,
                stderrLog: spec.stderrLog,
                didTimeOut: false,
                waitedForExit: false,
                outcome: .runningDetached,
                processIdentifier: process.processIdentifier,
                processObservationLog: spec.processObservationLog
            )
        }
        process.waitUntilExit()
        let endedAt = Date()

        return ProcessRunResult(
            actionName: spec.actionName,
            executable: spec.executable,
            arguments: spec.arguments,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: process.terminationStatus,
            hasProcessExitCode: process.terminationReason == .exit,
            stdoutLog: spec.stdoutLog,
            stderrLog: spec.stderrLog,
            didTimeOut: false,
            waitedForExit: true,
            outcome: process.terminationReason == .uncaughtSignal ? .signaled : .exited,
            terminationSignal: process.terminationReason == .uncaughtSignal
                ? process.terminationStatus
                : nil,
            processIdentifier: process.processIdentifier,
            processObservationLog: spec.processObservationLog
        )
    }

    private enum PrefixProcessCleanupState: Hashable {
        case clean
        case cleaned([pid_t])
        case remaining([pid_t])
        case verificationUnavailable(String)
    }

    private nonisolated static let prefixProcessCleanupFailureExitCode: Int32 = 74

    private struct WinePrefixCleanupReconciliation {
        var result: ProcessRunResult
        var state: PrefixProcessCleanupState

        var confirmsCleanPrefix: Bool {
            switch state {
            case .clean, .cleaned:
                true
            case .remaining, .verificationUnavailable:
                false
            }
        }
    }

    /// Completes Wine shutdown by evaluating the actual postcondition rather
    /// than trusting a single `wineserver` invocation. Every command keeps its
    /// own raw sidecar; the primary result links those attempts and records the
    /// authoritative prefix-shutdown postcondition separately.
    private func completeWinePrefixShutdown(
        after shutdownResult: ProcessRunResult,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) throws -> ProcessRunResult {
        let initialCleanup = finalizeWinePrefixShutdown(shutdownResult, prefix: prefix)
        var finalized = initialCleanup.result
        if shutdownResult.didTimeOut {
            _ = appendDiagnosticLines([
                "",
                "[ForgePlay] Initial Wine shutdown attempt timed out: " +
                    "pid=\(shutdownResult.processIdentifier.map(String.init) ?? "unavailable") " +
                    "signal=\(shutdownResult.diagnosticTerminationSignalDescription) " +
                    "rawWaitStatus=\(shutdownResult.rawWaitStatus.map(String.init) ?? "unavailable") " +
                    "durationMs=\(Int64(max(0, shutdownResult.endedAt.timeIntervalSince(shutdownResult.startedAt) * 1_000)))",
                "[ForgePlay] ForgePlay will decide this operation from cleanup plus the wineserver exit barrier instead of the timed-out attempt alone."
            ], to: finalized.stderrLog)
        }

        let barrierSpec = try makeWinePrefixWaitCommandSpec(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            actionName: "confirmWinePrefixShutdown",
            logName: "wine_prefix_shutdown_wait",
            timeout: 15,
            allowsInvalidPrefixSynchronizationProfileForCleanup: true
        )
        let forceSpec = try makeWinePrefixSignalCommandSpec(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            signal: SIGKILL,
            actionName: "forceWinePrefixShutdown",
            logName: "wine_prefix_shutdown_force",
            timeout: 5
        )
        let forcedBarrierSpec = try makeWinePrefixWaitCommandSpec(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            actionName: "confirmForcedWinePrefixShutdown",
            logName: "wine_prefix_shutdown_force_wait",
            timeout: 15,
            allowsInvalidPrefixSynchronizationProfileForCleanup: true
        )

        let barrierResult = try runWineServerControlCommand(barrierSpec)
        finalized = attachingRunEvidence(from: barrierResult, to: finalized)
        if barrierResult.succeeded, initialCleanup.confirmsCleanPrefix {
            finalized.postconditionSatisfied = true
            finalized.forgePlayStatusCode = 0
            let recoveryNote = shutdownResult.succeeded
                ? "Wine prefix shutdown barrier completed; wineserver has exited for this prefix."
                : "The initial Wine shutdown attempt did not succeed, but cleanup and the wineserver exit barrier confirmed that the prefix is inactive."
            _ = appendDiagnosticLines(["", "[ForgePlay] \(recoveryNote)"], to: finalized.stderrLog)
            clearManagedProcessLaunchRecords(for: prefix)
            return finalized
        }

        if !barrierResult.succeeded {
            _ = appendDiagnosticLines([
                "",
                "[ForgePlay] Wine prefix shutdown barrier failed: processExit=\(barrierResult.diagnosticExitCodeDescription) " +
                    "forgePlayStatus=\(barrierResult.diagnosticForgePlayStatusDescription) " +
                    "timeout=\(barrierResult.didTimeOut) stderr=\(barrierResult.stderrLog.path) " +
                    "runEvidence=\(barrierResult.runEvidenceLog?.path ?? "unavailable")"
            ], to: finalized.stderrLog)
        }

        if case .verificationUnavailable = initialCleanup.state {
            finalized.postconditionSatisfied = false
            finalized.forgePlayStatusCode = Self.prefixProcessCleanupFailureExitCode
            finalized.didTimeOut = finalized.didTimeOut || barrierResult.didTimeOut
            return finalized
        }

        _ = appendDiagnosticLines([
            "",
            "[ForgePlay] The shutdown postcondition was not confirmed. Requesting a separately logged forced wineserver stop before checking again."
        ], to: finalized.stderrLog)

        let rawForceResult = try runWineServerControlCommand(forceSpec)
        let forceCleanup = finalizeWinePrefixShutdown(rawForceResult, prefix: prefix)
        let forceResult = persistProcessEvidence(forceCleanup.result, spec: forceSpec)
        finalized = attachingRunEvidence(from: forceResult, to: finalized)

        let forcedBarrierResult = try runWineServerControlCommand(forcedBarrierSpec)
        finalized = attachingRunEvidence(from: forcedBarrierResult, to: finalized)
        if forcedBarrierResult.succeeded, forceCleanup.confirmsCleanPrefix {
            finalized.postconditionSatisfied = true
            finalized.forgePlayStatusCode = 0
            _ = appendDiagnosticLines([
                "",
                "[ForgePlay] Forced shutdown recovery completed; cleanup and the final wineserver exit barrier confirmed that the prefix is inactive.",
                "[ForgePlay] Recovery evidence: \(forceResult.runEvidenceLog?.path ?? "unavailable")",
                "[ForgePlay] Final barrier evidence: \(forcedBarrierResult.runEvidenceLog?.path ?? "unavailable")"
            ], to: finalized.stderrLog)
            clearManagedProcessLaunchRecords(for: prefix)
            return finalized
        }

        finalized.postconditionSatisfied = false
        finalized.forgePlayStatusCode = forcedBarrierResult.succeeded
            ? Self.prefixProcessCleanupFailureExitCode
            : winePrefixShutdownFailureStatus(for: forcedBarrierResult)
        finalized.didTimeOut = finalized.didTimeOut ||
            barrierResult.didTimeOut || rawForceResult.didTimeOut || forcedBarrierResult.didTimeOut
        _ = appendDiagnosticLines([
            "",
            "[ForgePlay] Wine prefix shutdown remained unconfirmed after forced recovery: " +
                "processExit=\(forcedBarrierResult.diagnosticExitCodeDescription) " +
                "forgePlayStatus=\(forcedBarrierResult.diagnosticForgePlayStatusDescription) " +
                "timeout=\(forcedBarrierResult.didTimeOut) stderr=\(forcedBarrierResult.stderrLog.path) " +
                "runEvidence=\(forcedBarrierResult.runEvidenceLog?.path ?? "unavailable")"
        ], to: finalized.stderrLog)
        return finalized
    }

    private func clearManagedProcessLaunchRecords(for prefix: URL) {
        let prefixPath = prefix.standardizedFileURL.path
        let completedLaunchSessions =
            managedWineSessionRegistry.completeSessions(for: prefix)
        for launchSession in completedLaunchSessions {
            // These path-free PID journals are needed only until the prefix
            // postcondition is proven. Remove only the exact owner-private
            // regular files that this launch registered; a failed cleanup
            // keeps both the registry entries and evidence intact.
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                    launchSession.evidenceURL,
                    fileManager: fileManager
                )
            } catch {
                continue
            }
            var status = stat()
            guard lstat(launchSession.evidenceURL.path, &status) == 0,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  (status.st_mode & mode_t(0o777)) ==
                    (S_IRUSR | S_IWUSR) else {
                continue
            }
            try? fileManager.removeItem(at: launchSession.evidenceURL)
        }
        gameModeHostLaunchRecords = gameModeHostLaunchRecords.filter {
            $0.prefixPath != prefixPath
        }
    }

    private func runWineServerControlCommand(_ spec: CommandSpec) throws -> ProcessRunResult {
        let startedAt = Date()
        do {
            let result = try run(spec, detachedProcessPrefix: nil)
            return persistProcessEvidence(result, spec: spec)
        } catch {
            if let failureResult = persistSpawnFailureEvidence(
                spec: spec,
                startedAt: startedAt,
                error: error
            ) {
                return failureResult
            }
            throw error
        }
    }

    private func attachingRunEvidence(
        from relatedResult: ProcessRunResult,
        to primaryResult: ProcessRunResult
    ) -> ProcessRunResult {
        var primaryResult = primaryResult
        if let evidence = relatedResult.runEvidenceLog {
            primaryResult.relatedRunEvidenceLogs.append(evidence.standardizedFileURL)
        }
        primaryResult.relatedRunEvidenceLogs = Self.deduplicated(
            primaryResult.relatedRunEvidenceLogs
        )
        return primaryResult
    }

    private nonisolated func winePrefixShutdownFailureStatus(
        for result: ProcessRunResult
    ) -> Int32 {
        result.forgePlayStatusCode ?? result.processExitCode ?? Self.prefixProcessCleanupFailureExitCode
    }

    private func finalizeWinePrefixShutdown(
        _ result: ProcessRunResult,
        prefix: URL
    ) -> WinePrefixCleanupReconciliation {
        var finalized = result
        let processLogsWereEmpty = processLogsAreEmpty(finalized)
        let cleanup = cleanupProcessesHoldingPrefix(prefix, logURL: result.stderrLog)
        let isExpectedNoServerExit = finalized.processExitCode == 1 &&
            !finalized.didTimeOut &&
            processLogsWereEmpty
        switch cleanup {
        case .clean:
            if isExpectedNoServerExit {
                appendDiagnosticLines([
                    "",
                    "[ForgePlay] wineserver reported no active server and no ForgePlay-managed process remains for this prefix. Treating the prefix as clean."
                ], to: result.stderrLog)
                finalized.forgePlayStatusCode = 0
            }
        case .cleaned(let pids):
            appendDiagnosticLines([
                "",
                "[ForgePlay] Removed stale process(es) holding Wine prefix: \(Self.formattedPIDList(pids))."
            ], to: result.stderrLog)
            if isExpectedNoServerExit {
                finalized.forgePlayStatusCode = 0
            }
        case .remaining(let pids):
            appendDiagnosticLines([
                "",
                "[ForgePlay] Failed to remove process(es) still holding Wine prefix: \(Self.formattedPIDList(pids))."
            ], to: result.stderrLog)
            finalized.forgePlayStatusCode = Self.prefixProcessCleanupFailureExitCode
        case .verificationUnavailable(let message):
            appendDiagnosticLines([
                "",
                "[ForgePlay] Could not verify Wine prefix process cleanup: \(message)"
            ], to: result.stderrLog)
            finalized.forgePlayStatusCode = Self.prefixProcessCleanupFailureExitCode
        }
        return WinePrefixCleanupReconciliation(result: finalized, state: cleanup)
    }

    private func cleanupProcessesHoldingPrefix(
        _ prefix: URL,
        logURL: URL
    ) -> PrefixProcessCleanupState {
        let initial: [pid_t]
        do {
            initial = try managedProcessIDsHoldingOpenFiles(under: prefix)
        } catch {
            return .verificationUnavailable(forgePlayTechnicalErrorSummary(error))
        }
        guard !initial.isEmpty else {
            return .clean
        }

        appendDiagnosticLines([
            "",
            "[ForgePlay] Detected process(es) still holding Wine prefix after wineserver shutdown: \(Self.formattedPIDList(initial)).",
            "[ForgePlay] Sending SIGTERM before retrying cleanup."
        ], to: logURL)
        sendSignal(SIGTERM, to: initial)
        Thread.sleep(forTimeInterval: 1)

        let afterTerminate: [pid_t]
        do {
            afterTerminate = try managedProcessIDsHoldingOpenFiles(under: prefix)
        } catch {
            return .verificationUnavailable(forgePlayTechnicalErrorSummary(error))
        }
        guard !afterTerminate.isEmpty else {
            return .cleaned(initial)
        }

        appendDiagnosticLines([
            "[ForgePlay] Process(es) still holding prefix after SIGTERM: \(Self.formattedPIDList(afterTerminate)).",
                "[ForgePlay] Sending SIGKILL to stale ForgePlay Runtime process(es)."
        ], to: logURL)
        sendSignal(SIGKILL, to: afterTerminate)
        Thread.sleep(forTimeInterval: 1)

        let afterKill: [pid_t]
        do {
            afterKill = try managedProcessIDsHoldingOpenFiles(under: prefix)
        } catch {
            return .verificationUnavailable(forgePlayTechnicalErrorSummary(error))
        }
        if afterKill.isEmpty {
            return .cleaned(initial)
        }
        return .remaining(afterKill)
    }

    private nonisolated static func formattedPIDList(_ pids: [pid_t]) -> String {
        pids.map(String.init).joined(separator: ", ")
    }

    private func managedProcessIDsHoldingOpenFiles(under prefix: URL) throws -> [pid_t] {
        var processIDs = Set(trackedDetachedProcessIDs(for: prefix))
        processIDs.formUnion(try registeredManagedWineProcessIDs(for: prefix))
        processIDs.formUnion(try registeredGameModeHostProcessIDs(for: prefix))
        // App Sandbox cannot inspect the host process table. Prefix-specific wineserver IPC
        // handles cross-session shutdown; this actor owns and verifies processes from this session.
        guard !sandboxEnabled else {
            return processIDs.sorted()
        }

        let holders = try processIDsHoldingOpenFiles(under: prefix)
        for pid in holders {
            guard let command = try processCommand(for: pid),
                  Self.isManagedWineOrSteamProcessCommand(command) else {
                continue
            }
            processIDs.insert(pid)
        }
        return processIDs.sorted()
    }

    private func registerManagedWineProcessLaunch(
        from spec: CommandSpec,
        prefix: URL?,
        registeredAt: Date,
        result: ProcessRunResult
    ) {
        guard let prefix,
              let runIdentifier =
                spec.environment[ManagedWineProcessJournal.runIdentifierKey],
              UUID(uuidString: runIdentifier) != nil,
              let evidencePath =
                spec.environment[ManagedWineProcessJournal.evidenceFileKey],
              evidencePath.hasPrefix("/"),
              let prefixScope =
                spec.environment[ManagedWineProcessJournal.prefixScopeKey],
              prefixScope.count == 64,
              let runtimeFingerprint =
                spec.environment[
                    ManagedWineProcessJournal.runtimeFingerprintKey
                ],
              runtimeFingerprint.count == 64,
              let wineLoaderPath = spec.environment["WINELOADER"],
              wineLoaderPath.hasPrefix("/") else {
            return
        }
        let evidenceURL = URL(fileURLWithPath: evidencePath)
            .standardizedFileURL
        let evidenceAttributes = try? fileManager.attributesOfItem(
            atPath: evidenceURL.path
        )
        let evidenceSize = (
            evidenceAttributes?[.size] as? NSNumber
        )?.int64Value ?? 0
        guard result.succeeded || evidenceSize > 0 else {
            return
        }
        let wineLoaderURL = URL(fileURLWithPath: wineLoaderPath)
            .standardizedFileURL
        let binDirectory = wineLoaderURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return }
        managedWineSessionRegistry.record(ManagedWineProcessLaunchSession(
            prefixURL: prefix.standardizedFileURL,
            runIdentifier: runIdentifier.lowercased(),
            evidenceURL: evidenceURL,
            runtimeRootURL: binDirectory.deletingLastPathComponent(),
            runtimeFingerprint: runtimeFingerprint,
            prefixScope: prefixScope,
            registeredAt: registeredAt
        ))
    }

    private func registeredManagedWineProcessIDs(
        for prefix: URL
    ) throws -> [pid_t] {
        let launchSessions = managedWineSessionRegistry.launchSessions(
            for: prefix
        )
        guard !launchSessions.isEmpty else { return [] }

        var processIDs = Set<pid_t>()
        for launchSession in launchSessions {
            guard let data = try ownerPrivateProcessEvidenceTail(
                at: launchSession.evidenceURL,
                purpose: "managed Wine process"
            ) else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    launchSession.evidenceURL,
                    "managed Wine process evidence is missing"
                )
            }
            let candidates = Self.managedWineProcessEvidenceIdentities(
                in: data,
                launchSession: launchSession
            )
            guard !candidates.isEmpty else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    launchSession.evidenceURL,
                    "the launched Wine session produced no valid Darwin PID evidence"
                )
            }

            let allowedExecutables = Self.allowedManagedWineExecutables(
                for: launchSession
            )
            for candidate in candidates {
                guard let processStartedAt = Self.processStartDate(
                    for: candidate.processID
                ) else {
                    if Darwin.kill(candidate.processID, 0) == -1,
                       errno == ESRCH {
                        continue
                    }
                    throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                        launchSession.evidenceURL,
                        "could not verify Darwin PID start identity: \(candidate.processID)"
                    )
                }
                // A different start time means the PID was safely reused after
                // the recorded Wine process exited. Never signal that process.
                guard abs(
                    processStartedAt.timeIntervalSince(
                        candidate.processStartedAt
                    )
                ) <= 0.01 else {
                    continue
                }
                guard let command = try processCommand(
                    for: candidate.processID
                ) else {
                    continue
                }
                let commandURL = URL(fileURLWithPath: command)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard allowedExecutables.contains(commandURL) else {
                    throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                        launchSession.evidenceURL,
                        "Darwin PID \(candidate.processID) no longer has an exact ForgePlay Runtime executable identity"
                    )
                }
                processIDs.insert(candidate.processID)
            }
        }
        return processIDs.sorted()
    }

    nonisolated static func managedWineProcessEvidenceIDs(
        in data: Data,
        launchSession: ManagedWineProcessLaunchSession,
        observedAt: Date = Date()
    ) -> [pid_t] {
        managedWineProcessEvidenceIdentities(
            in: data,
            launchSession: launchSession,
            observedAt: observedAt
        ).map(\.processID)
    }

    private nonisolated static func managedWineProcessEvidenceIdentities(
        in data: Data,
        launchSession: ManagedWineProcessLaunchSession,
        observedAt: Date = Date()
    ) -> [ManagedWineProcessEvidenceIdentity] {
        let decoder = JSONDecoder()
        let acceptedRoles: Set<String> = ["wine-loader", "wineserver"]
        var startsByProcessID: [pid_t: Date] = [:]
        for line in data.split(separator: 0x0A)
        where !line.isEmpty && line.count <= 2_048 {
            guard let record = try? decoder.decode(
                ManagedWineProcessEvidenceRecord.self,
                from: Data(line)
            ),
            record.schemaVersion == 1,
            record.producer == "forgeplay-wine-runtime",
            record.eventCode == "darwin_process_started",
            acceptedRoles.contains(record.role),
            record.runIdentifier.lowercased() ==
                launchSession.runIdentifier,
            record.prefixScope == launchSession.prefixScope,
            record.runtimeFingerprint == launchSession.runtimeFingerprint,
            record.darwinPID > 1,
            record.darwinPID != Darwin.getpid(),
            record.processStartedAtUnixMicroseconds > 0 else {
                continue
            }

            let recordedAt = Date(
                timeIntervalSince1970:
                    Double(record.recordedAtUnixMilliseconds) / 1_000
            )
            let processStartedAt = Date(
                timeIntervalSince1970:
                    Double(record.processStartedAtUnixMicroseconds) /
                        1_000_000
            )
            guard processStartedAt >=
                    launchSession.registeredAt.addingTimeInterval(-2),
                  processStartedAt <= recordedAt.addingTimeInterval(1),
                  recordedAt >=
                    launchSession.registeredAt.addingTimeInterval(-2),
                  recordedAt <= observedAt.addingTimeInterval(5) else {
                continue
            }
            let processID = pid_t(record.darwinPID)
            if let existing = startsByProcessID[processID],
               abs(existing.timeIntervalSince(processStartedAt)) > 0.01 {
                continue
            }
            startsByProcessID[processID] = processStartedAt
        }
        return startsByProcessID
            .map {
                ManagedWineProcessEvidenceIdentity(
                    processID: $0.key,
                    processStartedAt: $0.value
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    private nonisolated static func allowedManagedWineExecutables(
        for launchSession: ManagedWineProcessLaunchSession
    ) -> Set<URL> {
        let runtimeRoot = launchSession.runtimeRootURL.standardizedFileURL
        let paths = [
            runtimeRoot.appending(
                path: "bin/wine.bin",
                directoryHint: .notDirectory
            ),
            runtimeRoot.appending(
                path: "bin/wineserver.bin",
                directoryHint: .notDirectory
            ),
            runtimeRoot.appending(
                path: "lib/wine/x86_64-unix/wine",
                directoryHint: .notDirectory
            ),
            GameModeHostCapabilityInspector.bundledHostAppURL()
                .appending(
                    path: "Contents/MacOS/GameModeProcessHost",
                    directoryHint: .notDirectory
                )
        ]
        return Set(paths.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        })
    }

    private func registerGameModeHostLaunch(
        from spec: CommandSpec,
        prefix: URL?,
        registeredAt: Date
    ) {
        guard let prefix,
              spec.environment[GameModeHostEnvironment.enabledKey] == "1",
              let runIdentifier =
                spec.environment[GameModeHostEnvironment.runIdentifierKey],
              UUID(uuidString: runIdentifier) != nil,
              let evidencePath =
                spec.environment[GameModeHostEnvironment.evidenceFileKey],
              let executablePath =
                spec.environment[GameModeHostEnvironment.executableKey],
              evidencePath.hasPrefix("/"),
              executablePath.hasPrefix("/") else {
            return
        }
        gameModeHostLaunchRecords.insert(GameModeHostLaunchRecord(
            prefixPath: prefix.standardizedFileURL.path,
            runIdentifier: runIdentifier.lowercased(),
            evidenceURL: URL(fileURLWithPath: evidencePath).standardizedFileURL,
            executableURL: URL(fileURLWithPath: executablePath).standardizedFileURL,
            registeredAt: registeredAt
        ))
    }

    private func registeredGameModeHostProcessIDs(
        for prefix: URL
    ) throws -> [pid_t] {
        let prefixPath = prefix.standardizedFileURL.path
        let launchRecords = gameModeHostLaunchRecords.filter {
            $0.prefixPath == prefixPath
        }
        guard !launchRecords.isEmpty else { return [] }

        var evidenceByURL: [URL: Data] = [:]
        var processIDs = Set<pid_t>()
        for launchRecord in launchRecords {
            let data: Data
            if let cached = evidenceByURL[launchRecord.evidenceURL] {
                data = cached
            } else {
                guard let loaded = try ownerPrivateProcessEvidenceTail(
                    at: launchRecord.evidenceURL,
                    purpose: "Game Mode host"
                ) else {
                    continue
                }
                evidenceByURL[launchRecord.evidenceURL] = loaded
                data = loaded
            }
            let candidates = Self.gameModeHostEvidenceProcessIdentities(
                in: data,
                runIdentifier: launchRecord.runIdentifier,
                registeredAt: launchRecord.registeredAt
            )
            for candidate in candidates {
                guard let executable = try processCommand(for: candidate.processID),
                      URL(fileURLWithPath: executable).standardizedFileURL ==
                        launchRecord.executableURL,
                      Self.processStartDate(for: candidate.processID).map({
                          $0 >= launchRecord.registeredAt.addingTimeInterval(-2) &&
                              $0 <= candidate.recordedAt.addingTimeInterval(2)
                      }) == true else {
                    continue
                }
                processIDs.insert(candidate.processID)
            }
        }
        return processIDs.sorted()
    }

    private func ownerPrivateProcessEvidenceTail(
        at url: URL,
        purpose: String
    ) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                url,
                fileManager: fileManager
            )
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_uid == geteuid(),
                  (status.st_mode & mode_t(0o777)) == (S_IRUSR | S_IWUSR) else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    url,
                    "\(purpose) evidence is not an owner-private file"
                )
            }

            let maximumTailBytes: UInt64 = 4 * 1024 * 1024
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            let offset = fileSize > maximumTailBytes
                ? fileSize - maximumTailBytes
                : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: Int(maximumTailBytes) + 1) ?? Data()
            guard data.count <= Int(maximumTailBytes) else {
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    url,
                    "\(purpose) evidence tail exceeded the bounded read"
                )
            }
            if offset > 0,
               let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...firstNewline)
            }
            return data
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    nonisolated static func gameModeHostEvidenceProcessIDs(
        in data: Data,
        runIdentifier: String,
        registeredAt: Date,
        observedAt: Date = Date()
    ) -> [pid_t] {
        gameModeHostEvidenceProcessIdentities(
            in: data,
            runIdentifier: runIdentifier,
            registeredAt: registeredAt,
            observedAt: observedAt
        ).map(\.processID)
    }

    private nonisolated static func gameModeHostEvidenceProcessIdentities(
        in data: Data,
        runIdentifier: String,
        registeredAt: Date,
        observedAt: Date = Date()
    ) -> [GameModeHostEvidenceProcessIdentity] {
        let acceptedEvents: Set<String> = [
            "inherited_execution_verified",
            "prefix_execution_lease_acquired",
            "wine_main_entered"
        ]
        let normalizedRunIdentifier = runIdentifier.lowercased()
        let decoder = JSONDecoder()
        var recordedAtByProcessID: [pid_t: Date] = [:]
        for line in data.split(separator: 0x0A) where !line.isEmpty && line.count <= 2_048 {
            guard let record = try? decoder.decode(
                GameModeHostEvidenceRecord.self,
                from: Data(line)
            ),
            record.schemaVersion == 1,
            record.producer == "game-mode-process-host",
            acceptedEvents.contains(record.eventCode),
            record.runIdentifier?.lowercased() == normalizedRunIdentifier,
            record.darwinPID > 1,
            record.darwinPID != Darwin.getpid() else {
                continue
            }
            let recordedAt = Date(
                timeIntervalSince1970:
                    Double(record.recordedAtUnixMilliseconds) / 1_000
            )
            guard recordedAt >= registeredAt.addingTimeInterval(-2),
                  recordedAt <= observedAt.addingTimeInterval(5) else {
                continue
            }
            let processID = pid_t(record.darwinPID)
            recordedAtByProcessID[processID] = max(
                recordedAtByProcessID[processID] ?? .distantPast,
                recordedAt
            )
        }
        return recordedAtByProcessID
            .map {
                GameModeHostEvidenceProcessIdentity(
                    processID: $0.key,
                    recordedAt: $0.value
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    private nonisolated static func processStartDate(for pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copiedSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                expectedSize
            )
        }
        guard copiedSize == expectedSize else { return nil }
        return Date(
            timeIntervalSince1970:
                TimeInterval(info.pbi_start_tvsec) +
                TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
    }

    private func managedPrefixActivityProcessIDs(under prefix: URL) throws -> [pid_t] {
        // The managed lifecycle journal carries exact Darwin PID/start
        // identities from Wine itself. Prefix activity is therefore answered
        // by that evidence, directly tracked Process objects, and (outside the
        // App Sandbox) the existing process-table/open-file fallback.
        try managedProcessIDsHoldingOpenFiles(under: prefix)
    }

    private func processLogsAreEmpty(_ result: ProcessRunResult) -> Bool {
        [result.stdoutLog, result.stderrLog].allSatisfy { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.int64Value == 0
        }
    }

    func trackDetachedProcess(_ process: Process, for prefix: URL) {
        guard process.processIdentifier > 0, process.isRunning else { return }
        trackedDetachedProcesses[process.processIdentifier] = TrackedDetachedProcess(
            process: process,
            prefixPath: prefix.standardizedFileURL.path
        )
    }

    private func trackedDetachedProcessIDs(for prefix: URL) -> [pid_t] {
        pruneTrackedDetachedProcesses()
        let prefixPath = prefix.standardizedFileURL.path
        return trackedDetachedProcesses.compactMap { pid, record in
            guard record.prefixPath == prefixPath, record.process.isRunning else {
                return nil
            }
            return pid
        }
    }

    private func pruneTrackedDetachedProcesses() {
        trackedDetachedProcesses = trackedDetachedProcesses.filter { _, record in
            record.process.isRunning
        }
    }

    private func processCommand(for pid: pid_t) throws -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            if errno == ESRCH {
                return nil
            }
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                URL(fileURLWithPath: "PID-\(pid)"),
                String(cString: strerror(errno))
            )
        }
        let executableBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executablePath = String(decoding: executableBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return executablePath.isEmpty ? nil : executablePath
    }

    private nonisolated static func isManagedWineOrSteamProcessCommand(_ command: String) -> Bool {
        let executableName = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last?
            .lowercased()
        guard let executableName, !executableName.isEmpty else { return false }
        return [
            "wine",
            "wine64",
            "wine.bin",
            "wine64.bin",
            "wine-preloader",
            "wine64-preloader",
            "wineserver",
            "wineserver.bin",
            "steam.exe",
            "steamwebhelper.exe",
            "wineboot.exe",
            "control.exe",
            "rundll32.exe",
            "msiexec.exe",
            "services.exe",
            "winedevice.exe",
            "explorer.exe",
            "rpcss.exe",
            "plugplay.exe",
            "svchost.exe",
            "conhost.exe"
        ].contains(executableName)
    }

    private func processIDsHoldingOpenFiles(under prefix: URL) throws -> [pid_t] {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard fileManager.isExecutableFile(atPath: lsof.path) else {
            throw SafeProcessRunnerError.executableMissing(lsof)
        }
        let capture = try BoundedProcessExecutor.capture(
            executable: lsof,
            arguments: ["-t", "+D", prefix.path],
            timeout: 10,
            fileManager: fileManager
        )
        guard capture.didExit else {
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                prefix,
                "lsof did not exit before the prefix inspection deadline"
            )
        }
        let output = capture.stdout
        let errorOutput = capture.stderr
        let currentPID = Darwin.getpid()
        let pids = String(data: output, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 && $0 != currentPID } ?? []
        if !pids.isEmpty {
            return pids
        }
        if capture.exitCode == 1, output.isEmpty, errorOutput.isEmpty {
            return []
        }
        if capture.exitCode != 0 {
            let message = String(data: errorOutput, encoding: .utf8) ??
                String(data: output, encoding: .utf8) ??
                "lsof exited with \(capture.exitCode)"
            throw SafeProcessRunnerError.prefixProcessVerificationFailed(prefix, message)
        }
        return []
    }

    private nonisolated func sendSignal(_ signal: Int32, to pids: [pid_t]) {
        for pid in Set(pids) where pid > 0 && pid != Darwin.getpid() {
            Darwin.kill(pid, signal)
        }
    }

    private func persistProcessEvidence(
        _ input: ProcessRunResult,
        spec: CommandSpec
    ) -> ProcessRunResult {
        var result = input
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: spec.stderrLog)
        appendSyntheticProcessSummaryIfNeeded(
            for: result,
            spec: spec,
            evidenceURL: evidenceURL
        )
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: spec.stderrLog),
            actionName: spec.actionName,
            executable: spec.executable.path,
            arguments: spec.arguments,
            environmentOverrides: spec.environment,
            runtimeCompatibility: spec.runtimeCompatibility.isEmpty
                ? nil
                : spec.runtimeCompatibility,
            workingDirectory: spec.workingDirectory?.path,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            durationMilliseconds: Int64(max(0, result.endedAt.timeIntervalSince(result.startedAt) * 1_000)),
            outcome: result.outcome,
            exitCode: result.processExitCode,
            forgePlayStatusCode: result.forgePlayStatusCode,
            relatedRunEvidenceLogs: result.relatedRunEvidenceLogs.map(\.path),
            terminationSignal: result.terminationSignal,
            rawWaitStatus: result.rawWaitStatus,
            didTimeOut: result.didTimeOut,
            waitedForExit: result.waitedForExit,
            processIdentifier: result.processIdentifier,
            stdoutLog: result.stdoutLog.path,
            stderrLog: result.stderrLog.path,
            processObservationLog: result.processObservationLog?.path,
            finalizedAt: spec.actionName == "launchSteam" ? nil : Date(),
            activityLeaseExpiresAt: Self.evidenceActivityLeaseExpiration(
                for: result,
                relativeTo: result.endedAt
            ),
            diagnosticLog: result.diagnosticLog?.path,
            evidenceCaptureWarning: result.evidenceCaptureWarning,
            diagnosticCaptureWarning: result.diagnosticCaptureWarning,
            postconditionSatisfied: result.postconditionSatisfied,
            captureError: nil
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
        } catch {
            let warning = "Process evidence metadata could not be written: \(forgePlayTechnicalErrorSummary(error))"
            result.runEvidenceLog = nil
            result.evidenceCaptureWarning = DiagnosticWarningText.combined(
                result.evidenceCaptureWarning,
                warning
            )
            _ = appendDiagnosticLines(["", "[ForgePlay] \(warning)"], to: result.stderrLog)
        }
        return result
    }

    /// Some tools, including wineserver, legitimately emit no text while they
    /// are stuck or killed. Never leave the human-facing failure log empty when
    /// ForgePlay already has the decisive process metadata.
    private func appendSyntheticProcessSummaryIfNeeded(
        for result: ProcessRunResult,
        spec: CommandSpec,
        evidenceURL: URL
    ) {
        let needsSummary = result.didTimeOut || (!result.succeeded && processLogsAreEmpty(result))
        guard needsSummary, diagnosticLogIsEmpty(result.stderrLog) else { return }

        let durationMilliseconds = Int64(
            max(0, result.endedAt.timeIntervalSince(result.startedAt) * 1_000)
        )
        let timeoutDescription = spec.timeout.map {
            String(format: "%.3f seconds", $0)
        } ?? "none"
        let prefixDescription = spec.environment["WINEPREFIX"] ?? "not set"
        _ = appendDiagnosticLines([
            "[ForgePlay] Process execution summary",
            "[ForgePlay] Action: \(result.actionName)",
            "[ForgePlay] Executable: \(result.executable.path)",
            "[ForgePlay] Process ID: \(result.processIdentifier.map(String.init) ?? "unavailable")",
            "[ForgePlay] Configured timeout: \(timeoutDescription)",
            "[ForgePlay] Duration: \(durationMilliseconds) ms",
            "[ForgePlay] Outcome: \(result.outcome.rawValue)",
            "[ForgePlay] Process exit: \(result.diagnosticExitCodeDescription)",
            "[ForgePlay] ForgePlay status: \(result.diagnosticForgePlayStatusDescription)",
            "[ForgePlay] Timed out: \(result.didTimeOut)",
            "[ForgePlay] Termination signal: \(result.diagnosticTerminationSignalDescription)",
            "[ForgePlay] Raw wait status: \(result.rawWaitStatus.map(String.init) ?? "unavailable")",
            "[ForgePlay] Waited for exit: \(result.waitedForExit)",
            "[ForgePlay] Working directory: \(spec.workingDirectory?.path ?? "not set")",
            "[ForgePlay] WINEPREFIX: \(prefixDescription)",
            "[ForgePlay] Standard output: \(result.stdoutLog.path)",
            "[ForgePlay] Structured run evidence: \(evidenceURL.path)"
        ], to: result.stderrLog)
    }

    private func diagnosticLogIsEmpty(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == 0
    }

    private func processEvidenceFinalizationFailure(
        _ input: ProcessRunResult,
        error: Error
    ) -> ProcessRunResult {
        var result = input
        let warning = "Process evidence metadata could not be finalized: " +
            forgePlayTechnicalErrorSummary(error)
        result.evidenceCaptureWarning = DiagnosticWarningText.combined(
            result.evidenceCaptureWarning,
            warning
        )
        _ = appendDiagnosticLines(["", "[ForgePlay] \(warning)"], to: result.stderrLog)
        return result
    }

    private nonisolated static func evidenceActivityLeaseExpiration(
        for result: ProcessRunResult,
        relativeTo referenceDate: Date
    ) -> Date? {
        switch result.outcome {
        case .runningDetached, .unknown:
            return referenceDate.addingTimeInterval(
                ProcessRunEvidenceDocument.defaultActivityLeaseDuration
            )
        case .exited, .signaled, .timedOut:
            return result.waitedForExit
                ? nil
                : referenceDate.addingTimeInterval(
                    ProcessRunEvidenceDocument.defaultActivityLeaseDuration
                )
        case .preflightFailed, .spawnFailed:
            return nil
        }
    }

    @discardableResult
    private func persistActionPreparationFailureEvidence(
        action: RunnerAction,
        startedAt: Date,
        error: Error
    ) -> ProcessRunResult? {
        let logs = Self.logPair(
            in: action.diagnosticLogDirectoryURL,
            name: "\(action.capabilityActionName)_preflight"
        )
        do {
            let stdout = try Self.openLogFileHandle(at: logs.stdout, fileManager: fileManager)
            try stdout.close()
            let stderr = try Self.openLogFileHandle(at: logs.stderr, fileManager: fileManager)
            try stderr.close()
        } catch {
            return nil
        }

        let endedAt = Date()
        let summary = forgePlayTechnicalErrorSummary(error)
        let bridgedError = error as NSError
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: logs.stderr)
        var result = ProcessRunResult(
            actionName: "\(action.capabilityActionName):preflight",
            executable: action.windowsRuntimeExecutableURL ?? URL(fileURLWithPath: "/<unresolved>"),
            arguments: [],
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: 1,
            hasProcessExitCode: false,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .preflightFailed
        )
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: logs.stderr),
            actionName: result.actionName,
            executable: action.windowsRuntimeExecutableURL?.path ?? "unresolved",
            arguments: [],
            environmentOverrides: [:],
            workingDirectory: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: Int64(max(0, endedAt.timeIntervalSince(startedAt) * 1_000)),
            outcome: .preflightFailed,
            exitCode: nil,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: nil,
            stdoutLog: logs.stdout.path,
            stderrLog: logs.stderr.path,
            processObservationLog: nil,
            captureError: "Action preparation failed before a command could start: \(summary)",
            failureDomain: bridgedError.domain,
            failureCode: bridgedError.code
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
            _ = appendDiagnosticLines(
                ["[ForgePlay] Action preparation failed before a command could start: \(summary)",
                 "[ForgePlay] Structured failure evidence: \(evidenceURL.path)"],
                to: logs.stderr
            )
            return result
        } catch {
            let warning = "Structured failure evidence could not be written: \(forgePlayTechnicalErrorSummary(error))"
            result.evidenceCaptureWarning = warning
            _ = appendDiagnosticLines(
                ["[ForgePlay] Action preparation failed before a command could start: \(summary)",
                 "[ForgePlay] \(warning)"],
                to: logs.stderr
            )
            return result
        }
    }

    @discardableResult
    private func persistSpawnFailureEvidence(
        spec: CommandSpec,
        startedAt: Date,
        error: Error
    ) -> ProcessRunResult? {
        guard ensureDiagnosticLogExists(spec.stdoutLog),
              ensureDiagnosticLogExists(spec.stderrLog) else {
            return nil
        }
        let endedAt = Date()
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: spec.stderrLog)
        let summary = forgePlayTechnicalErrorSummary(error)
        let bridgedError = error as NSError
        var result = ProcessRunResult(
            actionName: spec.actionName,
            executable: spec.executable,
            arguments: spec.arguments,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: 1,
            hasProcessExitCode: false,
            stdoutLog: spec.stdoutLog,
            stderrLog: spec.stderrLog,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .spawnFailed,
            processObservationLog: spec.processObservationLog
        )
        result = Self.applyingPreparationDiagnostics(from: spec, to: result)
        let document = ProcessRunEvidenceDocument(
            runIdentifier: ProcessRunEvidenceWriter.runIdentifier(for: spec.stderrLog),
            actionName: spec.actionName,
            executable: spec.executable.path,
            arguments: spec.arguments,
            environmentOverrides: spec.environment,
            runtimeCompatibility: spec.runtimeCompatibility.isEmpty
                ? nil
                : spec.runtimeCompatibility,
            workingDirectory: spec.workingDirectory?.path,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: Int64(max(0, endedAt.timeIntervalSince(startedAt) * 1_000)),
            outcome: .spawnFailed,
            exitCode: nil,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: nil,
            stdoutLog: spec.stdoutLog.path,
            stderrLog: spec.stderrLog.path,
            processObservationLog: spec.processObservationLog?.path,
            diagnosticCaptureWarning: result.diagnosticCaptureWarning,
            captureError: summary,
            failureDomain: bridgedError.domain,
            failureCode: bridgedError.code
        )
        do {
            try ProcessRunEvidenceWriter.write(document, to: evidenceURL, fileManager: fileManager)
            result.runEvidenceLog = evidenceURL
            _ = appendDiagnosticLines(
                ["[ForgePlay] Process start failed before a result was produced: \(summary)",
                 "[ForgePlay] Structured failure evidence: \(evidenceURL.path)"],
                to: spec.stderrLog
            )
            return result
        } catch {
            let warning = "Structured failure evidence could not be written: \(forgePlayTechnicalErrorSummary(error))"
            result.evidenceCaptureWarning = warning
            _ = appendDiagnosticLines(
                ["[ForgePlay] Process start failed before a result was produced: \(summary)",
                 "[ForgePlay] \(warning)"],
                to: spec.stderrLog
            )
            return result
        }
    }

    private func ensureDiagnosticLogExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            do {
                try Self.requireNonSymlinkDirectory(
                    url.deletingLastPathComponent(),
                    fileManager: fileManager,
                    unsafeError: SafeProcessRunnerError.cannotCreateLog
                )
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
                return true
            } catch {
                return false
            }
        }
        do {
            let handle = try Self.openLogFileHandle(at: url, fileManager: fileManager)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func appendDiagnosticLines(_ lines: [String], to url: URL) -> Bool {
        guard !lines.isEmpty else {
            return false
        }
        do {
            try Self.requireNonSymlinkDirectory(
                url.deletingLastPathComponent(),
                fileManager: fileManager,
                unsafeError: SafeProcessRunnerError.cannotCreateLog
            )
        } catch {
            return false
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        do {
            try Self.validateOpenedLogDescriptor(descriptor, url: url)
        } catch {
            Darwin.close(descriptor)
            return false
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.joined(separator: "\n").utf8))
            try handle.write(contentsOf: Data("\n".utf8))
            return true
        } catch {
            return false
        }
    }

    nonisolated static func openLogFileHandle(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> FileHandle {
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(url)
        }
        try requireNonSymlinkDirectory(directory, fileManager: fileManager) { _ in
            SafeProcessRunnerError.cannotCreateLog(url)
        }

        for _ in 0..<2 {
            if fileManager.fileExists(atPath: url.path) {
                guard existingLogFileIsSafe(url) else {
                    throw SafeProcessRunnerError.cannotCreateLog(url)
                }
                let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    throw SafeProcessRunnerError.cannotCreateLog(url)
                }
                do {
                    try validateOpenedLogDescriptor(descriptor, url: url)
                    guard ftruncate(descriptor, 0) == 0 else {
                        Darwin.close(descriptor)
                        throw SafeProcessRunnerError.cannotCreateLog(url)
                    }
                    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }

            let descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            if descriptor >= 0 {
                do {
                    try validateOpenedLogDescriptor(descriptor, url: url)
                    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
            }
            if errno == EEXIST {
                continue
            }
            throw SafeProcessRunnerError.cannotCreateLog(url)
        }
        throw SafeProcessRunnerError.cannotCreateLog(url)
    }

    nonisolated static func validateSupportArchivePaths(
        sourceDirectory: URL,
        destinationZip: URL,
        fileManager: FileManager = .default
    ) throws {
        try requireNonSymlinkDirectory(sourceDirectory, fileManager: fileManager, unsafeError: SafeProcessRunnerError.unsafeArchivePath)
        guard destinationZip.pathExtension.lowercased() == "zip" else {
            throw SafeProcessRunnerError.unsafeArchivePath(destinationZip)
        }
        let destinationDirectory = destinationZip.deletingLastPathComponent()
        try requireNonSymlinkDirectory(destinationDirectory, fileManager: fileManager, unsafeError: SafeProcessRunnerError.unsafeArchivePath)
        guard !fileManager.fileExists(atPath: destinationZip.path) else {
            throw SafeProcessRunnerError.unsafeArchivePath(destinationZip)
        }
    }

    private nonisolated static func existingLogFileIsSafe(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink <= 1
    }

    private nonisolated static func validateOpenedLogDescriptor(_ descriptor: Int32, url: URL) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink <= 1 else {
            throw SafeProcessRunnerError.cannotCreateLog(url)
        }
    }

    private func makeCommandSpec(for action: RunnerAction) throws -> CommandSpec {
        switch action {
        case .initializePrefix(let runtimeExecutable, let prefix, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "prefix_initialize")
            return CommandSpec(
                actionName: "initializePrefix",
                executable: runtimeExecutable,
                arguments: ["wineboot", "-u"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: [
                        "WINEPREFIX": prefix.path,
                        "WINEARCH": WinePrefixDefaults.architecture,
                        "WINEDLLOVERRIDES": WinePrefixDefaults.bootstrapDisabledAddonDLLOverrides
                    ]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 180
            )
        case .migratePrefixRuntime(let runtimeExecutable, let prefix, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "prefix_runtime_migrate")
            return CommandSpec(
                actionName: "migratePrefixRuntime",
                executable: runtimeExecutable,
                arguments: ["wineboot", "-u"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: [
                        "WINEPREFIX": prefix.path,
                        "WINEARCH": WinePrefixDefaults.architecture,
                        "WINEDLLOVERRIDES": WinePrefixDefaults.bootstrapDisabledAddonDLLOverrides
                    ]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 600
            )
        case .waitForWinePrefix(let runtimeExecutable, let prefix, let logDirectory):
            return try makeWinePrefixWaitCommandSpec(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                logDirectory: logDirectory,
                actionName: "waitForWinePrefix",
                logName: "wine_prefix_wait",
                timeout: 60
            )
        case .probeRuntime(let executable, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "runtime_probe")
            return CommandSpec(
                actionName: "probeBundledRuntime",
                executable: executable,
                arguments: ["--version"],
                environment: try Self.runnerEnvironment(for: executable),
                workingDirectory: nil,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 8
            )
        case .installSteam(let runtimeExecutable, let prefix, let installer, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "steam_install")
            return CommandSpec(
                actionName: "installSteam",
                executable: runtimeExecutable,
                arguments: [installer.path, "/S"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: installer.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 600
            )
        case .requestSteamClientShutdown(let runtimeExecutable, let prefix, let steamExecutable, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "steam_client_shutdown")
            let steamCommand = [
                Self.windowsPath(for: steamExecutable, in: prefix) ?? Self.windowsHostPath(for: steamExecutable),
                "-shutdown"
            ]
            let steamLaunch = steamLaunchInvocation(
                for: runtimeExecutable,
                prefix: prefix,
                steamCommand: steamCommand
            )
            return CommandSpec(
                actionName: "requestSteamClientShutdown",
                executable: steamLaunch.executable,
                arguments: steamLaunch.arguments,
                environment: try Self.runnerEnvironment(
                    for: steamLaunch.executable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: steamExecutable.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 5
            )
        case .shutdownWinePrefix(let runtimeExecutable, let prefix, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "wine_prefix_shutdown")
            if let wineserver = Self.wineserverExecutable(for: runtimeExecutable) {
                return CommandSpec(
                    actionName: "shutdownWinePrefix",
                    executable: wineserver,
                    // An explicit signal asks wineserver to return after the
                    // request instead of entering its own long implicit wait.
                    // ForgePlay owns the authoritative `-w` barrier below.
                    arguments: ["--kill=\(SIGTERM)"],
                    environment: try Self.runnerEnvironment(
                        for: runtimeExecutable,
                        base: ["WINEPREFIX": prefix.path],
                        allowsInvalidPrefixSynchronizationProfileForCleanup: true
                    ),
                    workingDirectory: prefix,
                    stdoutLog: logs.stdout,
                    stderrLog: logs.stderr,
                    timeout: 5
                )
            }
            return CommandSpec(
                actionName: "shutdownWinePrefix",
                executable: runtimeExecutable,
                arguments: ["wineserver", "--kill=\(SIGTERM)"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path],
                    allowsInvalidPrefixSynchronizationProfileForCleanup: true
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 5
            )
        case .launchSteam(
            let runtimeExecutable,
            let prefix,
            let steamExecutable,
            let steamArguments,
            let graphicsBackend,
            let gameModePolicy,
            let logDirectory,
            let externalStorageRoots
        ):
            guard let graphicsBackend else {
                throw SafeProcessRunnerError.manualRendererSelectionRequired
            }
            let logs = Self.logPair(in: logDirectory, name: "steam_launch")
            let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(for: logs.stderr)
            let gameRunLogDirectory = logDirectory.appending(
                path: "GameRuns/\(runIdentifier)",
                directoryHint: .isDirectory
            )
            // Renderer and crash diagnostics for an actual Steam session use
            // the managed GameRuns UUID directory. Non-launch Wine actions
            // keep their lifecycle journal out of this game-only namespace.
            _ = try makeGameRunEvidenceDirectory(
                in: logDirectory,
                runIdentifier: runIdentifier
            )
            let processObservationLog = logs.stderr
                .deletingPathExtension()
                .appendingPathExtension("process-observation.log")
            let steamCommand = [
                Self.windowsPath(for: steamExecutable, in: prefix) ?? Self.windowsHostPath(for: steamExecutable)
            ] + steamArguments
            let steamLaunch = steamLaunchInvocation(
                for: runtimeExecutable,
                prefix: prefix,
                steamCommand: steamCommand
            )
            // Steam and WebHelper stay on the base Wine path. The bundled Wine
            // process policy applies exactly the renderer selected for this
            // Steam session to game children below steamapps/common.
            let steamClientGraphicsBackend: SteamRendererPolicyPreference? = nil
            let exposesVulkanICD = try Self.shouldExposeSteamClientVulkanICD(
                for: steamLaunch.executable,
                graphicsBackend: steamClientGraphicsBackend
            )
            var environment = try Self.runnerEnvironment(
                for: steamLaunch.executable,
                base: try Self.launchSteamBaseEnvironment(
                    runnerExecutable: steamLaunch.executable,
                    prefix: prefix,
                    gameGraphicsBackend: graphicsBackend,
                    logDirectory: gameRunLogDirectory,
                    processObservationLog: processObservationLog,
                    correlationIdentifier: runIdentifier
                ),
                graphicsBackend: steamClientGraphicsBackend,
                exposesVulkanICD: exposesVulkanICD,
                injectGraphicsDLLOverrides: false,
                restoresSteamWebHelperVulkanICD: true
            )
            switch gameModePolicy {
            case .standard:
                environment = GameModeHostEnvironment.applyingStandardLaunch(
                    to: environment,
                    evidenceLogURL: logs.stderr
                        .deletingPathExtension()
                        .appendingPathExtension("game-mode-host.jsonl"),
                    runIdentifier: runIdentifier
                )
            case .experimentalRequiredHost:
                let gameModeEvidenceLog = try GameModeHostCoordinationPaths.evidenceLogURL(
                    fallbackLogURL: logs.stderr
                        .deletingPathExtension()
                        .appendingPathExtension("game-mode-host.jsonl")
                )
                let selection = try gameModeSteamChildSelectionResolver(
                    runtimeExecutable,
                    prefix,
                    gameModeEvidenceLog,
                    runIdentifier
                )
                environment = GameModeHostEnvironment.applying(
                    selection,
                    to: environment
                )
            }
            environment = SteamExternalStorageProcessGrant
                .removingEnvironment(from: environment)
            var preparationDiagnosticMarkers: [String] = []
            var preparationDiagnosticWarning: String?
            var userFacingWarningLocalizationKey: String?
            var launchRuntimeCompatibility: [String: String] = [:]
            if sandboxEnabled, !externalStorageRoots.isEmpty {
                do {
                    let grant = try externalStorageGrantPublisher(
                        externalStorageRoots,
                        prefix,
                        runIdentifier
                    )
                    environment.merge(
                        grant.environmentOverrides,
                        uniquingKeysWith: { _, grantValue in grantValue }
                    )
                    launchRuntimeCompatibility[
                        "externalStorageGrantPublicationStatus"
                    ] = "published"
                } catch {
                    let reasonCode =
                        Self.externalStorageGrantPublicationFailureCode(
                            for: error
                        )
                    launchRuntimeCompatibility[
                        "externalStorageGrantPublicationStatus"
                    ] = "failed"
                    launchRuntimeCompatibility[
                        "externalStorageGrantPublicationFailureReason"
                    ] = reasonCode
                    preparationDiagnosticMarkers.append(
                        "FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1 " +
                            "program=forgeplay-publisher status=failed " +
                            "reason=\(reasonCode)"
                    )
                    preparationDiagnosticWarning =
                        "External-storage process access was not published; " +
                        "Steam continued without external-library access for " +
                        "this launch (reason=\(reasonCode))."
                    userFacingWarningLocalizationKey =
                        "외장 저장소 접근 권한을 Windows용 Steam에 전달하지 못했습니다. " +
                        "ForgePlay에서 저장공간을 다시 연결한 뒤 Steam을 다시 실행하세요."
                }
            }
            Self.captureSteamBaseRendererEnvironment(in: &environment)
            return CommandSpec(
                actionName: "launchSteam",
                executable: steamLaunch.executable,
                arguments: steamLaunch.arguments,
                environment: environment,
                runtimeCompatibility: launchRuntimeCompatibility,
                workingDirectory: steamExecutable.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: nil,
                waitsForExit: false,
                startupValidationInterval: steamLaunch.validatesStartup ? 6 : 0,
                processObservationLog: processObservationLog,
                preparationDiagnosticMarkers: preparationDiagnosticMarkers,
                preparationDiagnosticWarning: preparationDiagnosticWarning,
                userFacingWarningLocalizationKey:
                    userFacingWarningLocalizationKey
            )
        case .extractRuntimeArchive(let runtimeExecutable, let prefix, let archive, let extractionDirectory, let runtime, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "\(runtime.rawValue)_extract")
            return CommandSpec(
                actionName: "extractRuntimeArchive:\(runtime.rawValue)",
                executable: runtimeExecutable,
                arguments: [
                    archive.path,
                    "/Q",
                    "/T:\(Self.windowsHostPath(for: extractionDirectory))"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: archive.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 300
            )
        case .installRuntime(let runtimeExecutable, let prefix, let installer, let runtime, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "\(runtime.rawValue)_install")
            return CommandSpec(
                actionName: "installRuntime:\(runtime.rawValue)",
                executable: runtimeExecutable,
                arguments: Self.installerCommand(for: installer),
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: installer.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 1_800
            )
        case .setWindowsVersion(let runtimeExecutable, let prefix, let version, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "windows_version_\(version)")
            return CommandSpec(
                actionName: "setWindowsVersion:\(version)",
                executable: runtimeExecutable,
                arguments: [
                    "reg",
                    "add",
                    "HKCU\\Software\\Wine",
                    "/v",
                    "Version",
                    "/d",
                    version,
                    "/f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .setRegistryValue(let runtimeExecutable, let prefix, let registryPath, let valueName, let valueType, let value, let logDirectory):
            let safeRegistryName = PathManager.sanitizedFileName(registryPath)
            let safeValueName = PathManager.sanitizedFileName(valueName)
            let logs = Self.logPair(in: logDirectory, name: "registry_value_\(safeRegistryName)_\(safeValueName)")
            var command = [
                "reg",
                "add",
                registryPath,
                "/v",
                valueName
            ]
            if let valueType {
                command.append(contentsOf: ["/t", valueType])
            }
            command.append(contentsOf: [
                "/d",
                value,
                "/f"
            ])
            return CommandSpec(
                actionName: "setRegistryValue:\(registryPath):\(valueName)",
                executable: runtimeExecutable,
                arguments: command,
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .setDLLOverride(let runtimeExecutable, let prefix, let dll, let override, let logDirectory):
            let logs = Self.logPair(in: logDirectory, name: "dll_override_\(dll)")
            return CommandSpec(
                actionName: "setDLLOverride:\(dll)",
                executable: runtimeExecutable,
                arguments: [
                    "reg",
                    "add",
                    "HKCU\\Software\\Wine\\DllOverrides",
                    "/v",
                    dll,
                    "/d",
                    override,
                    "/f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .setAppDLLOverride(let runtimeExecutable, let prefix, let appExecutable, let dll, let override, let logDirectory):
            let safeAppName = PathManager.sanitizedFileName(appExecutable)
            let safeDLLName = PathManager.sanitizedFileName(dll)
            let logs = Self.logPair(in: logDirectory, name: "app_dll_override_\(safeAppName)_\(safeDLLName)")
            return CommandSpec(
                actionName: "setAppDLLOverride:\(appExecutable):\(dll)",
                executable: runtimeExecutable,
                arguments: [
                    "reg",
                    "add",
                    "HKCU\\Software\\Wine\\AppDefaults\\\(appExecutable)\\DllOverrides",
                    "/v",
                    dll,
                    "/d",
                    override,
                    "/f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .deleteAppDLLOverrideIfPresent(let runtimeExecutable, let prefix, let appExecutable, let dll, let logDirectory):
            let safeAppName = PathManager.sanitizedFileName(appExecutable)
            let safeDLLName = PathManager.sanitizedFileName(dll)
            let logs = Self.logPair(in: logDirectory, name: "app_dll_override_delete_\(safeAppName)_\(safeDLLName)")
            let registryPath = "HKCU\\Software\\Wine\\AppDefaults\\\(appExecutable)\\DllOverrides"
            return CommandSpec(
                actionName: "deleteAppDLLOverrideIfPresent:\(appExecutable):\(dll)",
                executable: runtimeExecutable,
                arguments: [
                    "cmd",
                    "/c",
                    "reg query \"\(registryPath)\" /v \(dll) >NUL 2>NUL || exit /b 0 & reg delete \"\(registryPath)\" /v \(dll) /f"
                ],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path]
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 30
            )
        case .createSupportArchive(let sourceDirectory, let destinationZip, let logDirectory):
            try Self.validateSupportArchivePaths(
                sourceDirectory: sourceDirectory,
                destinationZip: destinationZip,
                fileManager: fileManager
            )
            let logs = Self.logPair(in: logDirectory, name: "support_bundle")
            return CommandSpec(
                actionName: "createSupportArchive",
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--keepParent", sourceDirectory.path, destinationZip.path],
                environment: [:],
                workingDirectory: sourceDirectory.deletingLastPathComponent(),
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: 60
            )
        }
    }

    private func attachingManagedWineProcessJournal(
        to input: CommandSpec,
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL
    ) throws -> CommandSpec {
        var spec = input
        let runIdentifier = ProcessRunEvidenceWriter.runIdentifier(
            for: spec.stderrLog
        ).lowercased()
        guard UUID(uuidString: runIdentifier) != nil else {
            throw SafeProcessRunnerError.cannotCreateLog(spec.stderrLog)
        }
        let runtimeFingerprint =
            try managedWineRuntimeFingerprintResolver(runtimeExecutable)
        guard runtimeFingerprint.utf8.count == 64,
              runtimeFingerprint.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw SafeProcessRunnerError.metadataReadFailed(
                runtimeExecutable,
                "managed Wine runtime fingerprint is invalid"
            )
        }
        let fallbackDirectory = managedWineProcessEvidenceSandboxEnabled
            ? logDirectory
            : try makeManagedWineProcessEvidenceDirectory(
                in: logDirectory
            )
        let evidenceURL = try ManagedWineProcessJournal.evidenceFileURL(
            runIdentifier: runIdentifier,
            fallbackDirectory: fallbackDirectory,
            fileManager: fileManager,
            sandboxEnabled: managedWineProcessEvidenceSandboxEnabled
        )
        let evidenceHandle = try Self.openLogFileHandle(
            at: evidenceURL,
            fileManager: fileManager
        )
        try evidenceHandle.close()

        spec.environment[ManagedWineProcessJournal.evidenceFileKey] =
            evidenceURL.path
        spec.environment[ManagedWineProcessJournal.runIdentifierKey] =
            runIdentifier
        spec.environment[ManagedWineProcessJournal.prefixScopeKey] =
            ManagedWineProcessJournal.prefixScope(for: prefix)
        spec.environment[ManagedWineProcessJournal.runtimeFingerprintKey] =
            runtimeFingerprint
        spec.runtimeCompatibility["managedWineProcessJournal"] = "enabled"
        spec.runtimeCompatibility["managedWineProcessJournalSchema"] = "1"
        return spec
    }

    private func makeManagedWineProcessEvidenceDirectory(
        in logDirectory: URL
    ) throws -> URL {
        do {
            try fileManager.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            try Self.requireNonSymlinkDirectory(
                logDirectory,
                fileManager: fileManager,
                unsafeError: SafeProcessRunnerError.cannotCreateLog
            )
            let directory = logDirectory.appending(
                path: ManagedWineProcessJournal.evidenceDirectoryName,
                directoryHint: .isDirectory
            )
            try Self.createPrivateDiagnosticDirectory(
                directory,
                parent: logDirectory,
                fileManager: fileManager
            )
            return directory
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(logDirectory)
        }
    }

    private func makeGameRunEvidenceDirectory(
        in logDirectory: URL,
        runIdentifier: String
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try Self.requireNonSymlinkDirectory(
                logDirectory,
                fileManager: fileManager,
                unsafeError: SafeProcessRunnerError.cannotCreateLog
            )
            let gameRuns = logDirectory.appending(path: "GameRuns", directoryHint: .isDirectory)
            try Self.createPrivateDiagnosticDirectory(
                gameRuns,
                parent: logDirectory,
                fileManager: fileManager
            )
            let runDirectory = gameRuns.appending(path: runIdentifier, directoryHint: .isDirectory)
            try Self.createPrivateDiagnosticDirectory(
                runDirectory,
                parent: gameRuns,
                fileManager: fileManager
            )
            return runDirectory
        } catch let error as SafeProcessRunnerError {
            throw error
        } catch {
            throw SafeProcessRunnerError.cannotCreateLog(logDirectory)
        }
    }

    private nonisolated static func createPrivateDiagnosticDirectory(
        _ directory: URL,
        parent: URL,
        fileManager: FileManager
    ) throws {
        try requireNonSymlinkDirectory(
            parent,
            fileManager: fileManager,
            unsafeError: SafeProcessRunnerError.cannotCreateLog
        )
        if mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
            throw SafeProcessRunnerError.cannotCreateLog(directory)
        }
        try requireNonSymlinkDirectory(
            directory,
            fileManager: fileManager,
            unsafeError: SafeProcessRunnerError.cannotCreateLog
        )
    }

    private func makeWinePrefixWaitCommandSpec(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        actionName: String,
        logName: String,
        timeout: TimeInterval,
        allowsInvalidPrefixSynchronizationProfileForCleanup: Bool = false
    ) throws -> CommandSpec {
        let logs = Self.logPair(in: logDirectory, name: logName)
        if let wineserver = Self.wineserverExecutable(for: runtimeExecutable) {
            return CommandSpec(
                actionName: actionName,
                executable: wineserver,
                arguments: ["-w"],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path],
                    allowsInvalidPrefixSynchronizationProfileForCleanup:
                        allowsInvalidPrefixSynchronizationProfileForCleanup
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: timeout
            )
        }
        return CommandSpec(
            actionName: actionName,
            executable: runtimeExecutable,
            arguments: ["wineserver", "-w"],
            environment: try Self.runnerEnvironment(
                for: runtimeExecutable,
                base: ["WINEPREFIX": prefix.path],
                allowsInvalidPrefixSynchronizationProfileForCleanup:
                    allowsInvalidPrefixSynchronizationProfileForCleanup
            ),
            workingDirectory: prefix,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            timeout: timeout
        )
    }

    private func makeWinePrefixSignalCommandSpec(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        signal: Int32,
        actionName: String,
        logName: String,
        timeout: TimeInterval
    ) throws -> CommandSpec {
        let logs = Self.logPair(in: logDirectory, name: logName)
        let signalArgument = "--kill=\(signal)"
        if let wineserver = Self.wineserverExecutable(for: runtimeExecutable) {
            return CommandSpec(
                actionName: actionName,
                executable: wineserver,
                arguments: [signalArgument],
                environment: try Self.runnerEnvironment(
                    for: runtimeExecutable,
                    base: ["WINEPREFIX": prefix.path],
                    allowsInvalidPrefixSynchronizationProfileForCleanup: true
                ),
                workingDirectory: prefix,
                stdoutLog: logs.stdout,
                stderrLog: logs.stderr,
                timeout: timeout
            )
        }
        return CommandSpec(
            actionName: actionName,
            executable: runtimeExecutable,
            arguments: ["wineserver", signalArgument],
            environment: try Self.runnerEnvironment(
                for: runtimeExecutable,
                base: ["WINEPREFIX": prefix.path],
                allowsInvalidPrefixSynchronizationProfileForCleanup: true
            ),
            workingDirectory: prefix,
            stdoutLog: logs.stdout,
            stderrLog: logs.stderr,
            timeout: timeout
        )
    }

    private static func launchSteamBaseEnvironment(
        runnerExecutable: URL,
        prefix: URL,
        gameGraphicsBackend: SteamRendererPolicyPreference,
        logDirectory: URL,
        processObservationLog: URL,
        correlationIdentifier: String
    ) throws -> [String: String] {
        var environment = [
            "WINEPREFIX": prefix.path,
            "MTL_HUD_ENABLED": "0",
            "FORGEPLAY_PROCESS_ARGUMENT_TARGET": SteamWebHelperLaunchPolicy.executableName,
            "FORGEPLAY_PROCESS_ARGUMENT_APPEND": SteamWebHelperLaunchPolicy.requiredArguments.joined(separator: " "),
            "FORGEPLAY_PROCESS_OBSERVATION_FILE": Self.windowsHostPath(for: processObservationLog),
            SteamGameCEFBrowserLaunchPolicy.environmentKey:
                SteamGameCEFBrowserLaunchPolicy.enabledValue,
            "FORGEPLAY_GAME_RENDERER_CORRELATION_ID": correlationIdentifier
        ]
        if let wineDebug = ProcessInfo.processInfo.environment["FORGEPLAY_WINEDEBUG"],
           !wineDebug.isEmpty {
            environment["WINEDEBUG"] = wineDebug
        }
        environment.merge(
            try steamGameRendererPolicyEnvironment(
                for: runnerExecutable,
                prefix: prefix,
                graphicsBackend: gameGraphicsBackend,
                logDirectory: logDirectory
            ),
            uniquingKeysWith: { _, rendererValue in rendererValue }
        )
        return environment
    }

    static func steamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        logDirectory: URL
    ) throws -> [String: String] {
        switch graphicsBackend {
        case .d3dMetal:
            return try d3dMetalSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                logDirectory: logDirectory,
                scope: .direct3D12
            )
        case .dxmt:
            return try dxmtSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        case .d9vk:
            return try d9VKSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                logDirectory: logDirectory
            )
        case .vulkan:
            return try fixedSteamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                graphicsBackend: graphicsBackend,
                logDirectory: logDirectory
            )
        }
    }

    private static func d3dMetalSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL,
        scope: D3DMetalRendererPayloadContract.LaunchScope
    ) throws -> [String: String] {
        let d3dMetalRoot = try requiredD3DMetalRendererRoot(
            for: executable,
            prefix: prefix,
            scope: scope
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: d3dMetalRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        selectedModules["syswow64"] = []
        guard !rendererModuleDirectories(
            selectedModules["system32", default: []]
        ).isEmpty else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "D3DMetal \(scope.rawValue) system32"
            )
        }

        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .d3dMetal,
            requested: .d3dMetal,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [d3dMetalRoot],
            requiresVulkan: false,
            d3dMetalRoot: d3dMetalRoot
        )
    }

    private static func requiredD3DMetalRendererRoot(
        for executable: URL,
        prefix: URL,
        scope: D3DMetalRendererPayloadContract.LaunchScope
    ) throws -> URL {
        let fileManager = FileManager.default
        var candidates = rendererSupportContentsDirectories(for: executable).map {
            $0.appending(
                path: "Frameworks/renderer/d3dmetal",
                directoryHint: .isDirectory
            )
        }
        if let wineRoot = wineRootDirectory(for: executable) {
            candidates.append(
                wineRoot.appending(path: "lib64/apple_gptk", directoryHint: .isDirectory)
            )
        }
        // The app-bundled renderer is authoritative. A managed Apple renderer is
        // considered only when no bundled root satisfies this exact generation.
        if let supplemental = usableSupplementalRendererRoot(containingPrefix: prefix) {
            candidates.append(supplemental)
        }
        if let selected = deduplicated(candidates).first(where: {
            D3DMetalRendererPayloadContract.isUsable(
                for: scope,
                at: $0,
                fileManager: fileManager
            )
        }) {
            return selected
        }
        throw SafeProcessRunnerError.gameRendererPayloadMissing(
            executable,
            "D3DMetal \(scope.rawValue)"
        )
    }

    private static func fixedSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        logDirectory: URL
    ) throws -> [String: String] {
        guard graphicsBackend == .vulkan else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "fixed renderer profile \(graphicsBackend.rawValue)"
            )
        }
        let dxvkRoot = try requiredRendererComponentRoot(
            named: "dxvk",
            executable: executable,
            prefix: prefix,
            requiredWindowsDirectories: ["system32", "syswow64"]
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: dxvkRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .vulkan,
            requested: .vulkan,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [dxvkRoot],
            requiresVulkan: true,
            d3dMetalRoot: nil
        )
    }

    private static func dxmtSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL
    ) throws -> [String: String] {
        let dxmtRoot = try requiredRendererComponentRoot(
            named: "dxmt",
            executable: executable,
            prefix: prefix,
            requiredWindowsDirectories: ["system32", "syswow64"]
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: dxmtRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .dxmt,
            requested: .dxmt,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [dxmtRoot],
            requiresVulkan: false,
            d3dMetalRoot: nil
        )
    }

    private static func d9VKSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL
    ) throws -> [String: String] {
        let d9VKRoot = try requiredRendererComponentRoot(
            named: "d9vk",
            executable: executable,
            prefix: prefix,
            requiredWindowsDirectories: ["system32", "syswow64"]
        )
        var selectedModules: [String: [URL]] = [:]
        try appendRendererWindowsModuleFilesByWindowsDirectory(
            wineModulesRoot: d9VKRoot.appending(path: "wine", directoryHint: .isDirectory),
            fileManager: .default,
            modulesByWindowsDirectory: &selectedModules
        )
        return try exactSteamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            logDirectory: logDirectory,
            policy: .d9vk,
            requested: .d9vk,
            modulesByWindowsDirectory: selectedModules,
            componentRoots: [d9VKRoot],
            requiresVulkan: true,
            d3dMetalRoot: nil
        )
    }

    private static func requiredRendererComponentRoot(
        named componentName: String,
        executable: URL,
        prefix: URL?,
        requiredWindowsDirectories: [String]
    ) throws -> URL {
        var candidates = rendererSupportContentsDirectories(for: executable).map {
            $0.appending(
                path: "Frameworks/renderer/\(componentName)",
                directoryHint: .isDirectory
            )
        }
        if componentName == "d3dmetal", let prefix,
           let supplemental = usableSupplementalRendererRoot(containingPrefix: prefix) {
            candidates.append(supplemental)
        }

        for candidate in deduplicated(candidates) where rendererComponentIsUsable(
            named: componentName,
            at: candidate,
            fileManager: .default
        ) {
            var modulesByWindowsDirectory: [String: [URL]] = [:]
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: candidate.appending(path: "wine", directoryHint: .isDirectory),
                fileManager: .default,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
            if requiredWindowsDirectories.allSatisfy({
                !rendererModuleDirectories(
                    modulesByWindowsDirectory[$0, default: []]
                ).isEmpty
            }) {
                return candidate
            }
        }
        throw SafeProcessRunnerError.gameRendererPayloadMissing(
            executable,
            "\(componentName) \(requiredWindowsDirectories.joined(separator: "+"))"
        )
    }

    private static func exactSteamGameRendererPolicyEnvironment(
        for executable: URL,
        prefix: URL,
        logDirectory: URL,
        policy: SteamRendererPolicyPreference,
        requested: SteamRendererPolicySelection,
        modulesByWindowsDirectory: [String: [URL]],
        componentRoots: [URL],
        requiresVulkan: Bool,
        d3dMetalRoot: URL?
    ) throws -> [String: String] {
        let x64Directories = rendererModuleDirectories(
            modulesByWindowsDirectory["system32", default: []]
        )
        let x86Directories = rendererModuleDirectories(
            modulesByWindowsDirectory["syswow64", default: []]
        )
        guard !x64Directories.isEmpty else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "exact 64-bit renderer profile"
            )
        }

        var rendererBase = ["WINEPREFIX": prefix.path]
        if requiresVulkan {
            let videoMemorySizeMB = SteamClientCompatibilityProfileContract
                .configuredVideoMemorySizeMB(in: prefix) ??
                SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB
            rendererBase["DXVK_LOG_PATH"] = logDirectory.path
            rendererBase["DXVK_LOG_LEVEL"] = "info"
            rendererBase["DXVK_CONFIG"] =
                "dxgi.maxDeviceMemory = \(videoMemorySizeMB); " +
                "d3d9.maxAvailableMemory = \(videoMemorySizeMB)"
        }
        var rendererEnvironment = try runnerEnvironment(
            for: executable,
            base: rendererBase,
            graphicsBackend: nil,
            exposesVulkanICD: requiresVulkan,
            injectGraphicsDLLOverrides: false
        )

        let exactRoots = deduplicated(componentRoots)
        let wineRoots = exactRoots.map {
            $0.appending(path: "wine", directoryHint: .isDirectory)
        }.filter { FileSystemItemPolicy.isNonSymlinkDirectory($0) }
        let unixModuleDirectories = wineRoots.map {
            $0.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        }.filter { FileSystemItemPolicy.isNonSymlinkDirectory($0) }
        // WINEDLLPATH entries are Wine layout roots, not architecture leaf
        // directories. Wine appends its paired `x86_64-windows` and
        // `x86_64-unix` suffixes to the same entry when it maps a builtin PE
        // module. Putting the Windows leaf first makes an Apple D3DMetal
        // `dxgi.dll` bind to a nonexistent adjacent `dxgi.so`, so its
        // PROCESS_ATTACH returns false with c0000142.
        let wineDLLPaths = wineRoots.map(\.path)
        var dynamicLibraryDirectories = exactRoots + unixModuleDirectories

        if let d3dMetalRoot {
            let external = d3dMetalRoot.appending(
                path: "external",
                directoryHint: .isDirectory
            )
            let frameworkExecutable = external.appending(
                path: "D3DMetal.framework/D3DMetal"
            )
            let sharedLibrary = external.appending(path: "libd3dshared.dylib")
            guard FileSystemItemPolicy.isNonSymlinkDirectory(external),
                  D3DMetalRendererPayloadContract.isSafePayloadPath(
                    "external/D3DMetal.framework/D3DMetal",
                    at: d3dMetalRoot
                  ),
                  D3DMetalRendererPayloadContract.isSafePayloadPath(
                    D3DMetalRendererPayloadContract.sharedLibraryRelativePath,
                    at: d3dMetalRoot
                  ) else {
                throw SafeProcessRunnerError.gameRendererPayloadMissing(
                    executable,
                    "D3DMetal host closure"
                )
            }
            dynamicLibraryDirectories.append(external)
            rendererEnvironment["DYLD_FRAMEWORK_PATH"] = mergedPathList(
                [external.path],
                existing: rendererEnvironment["DYLD_FRAMEWORK_PATH"]
            )
            rendererEnvironment["D3DMETAL_FRAMEWORK_PATH"] = frameworkExecutable.path
            rendererEnvironment["D3DMETAL_SHARED_LIBRARY"] = sharedLibrary.path
            rendererEnvironment["D3DM_WINE_UNIX_CALL"] = "1"
        } else {
            for key in [
                "DYLD_FRAMEWORK_PATH",
                "D3DMETAL_FRAMEWORK_PATH",
                "D3DMETAL_SHARED_LIBRARY",
                "D3DM_WINE_UNIX_CALL"
            ] {
                rendererEnvironment.removeValue(forKey: key)
            }
        }

        let dynamicLibraryPaths = deduplicated(dynamicLibraryDirectories).map(\.path)
        rendererEnvironment["WINEDLLPATH"] = mergedPathList(
            wineDLLPaths,
            existing: rendererEnvironment["WINEDLLPATH"]
        )
        rendererEnvironment["DYLD_LIBRARY_PATH"] = mergedPathList(
            dynamicLibraryPaths,
            existing: rendererEnvironment["DYLD_LIBRARY_PATH"]
        )
        rendererEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = mergedPathList(
            dynamicLibraryPaths,
            existing: rendererEnvironment["DYLD_FALLBACK_LIBRARY_PATH"]
        )

        let overrideModuleNames = deduplicated(
            (modulesByWindowsDirectory["system32", default: []] +
             modulesByWindowsDirectory["syswow64", default: []]).map {
                $0.deletingPathExtension().lastPathComponent.lowercased()
             }
        ).sorted()
        guard !overrideModuleNames.isEmpty else {
            throw SafeProcessRunnerError.gameRendererPayloadMissing(
                executable,
                "exact renderer DLL override"
            )
        }
        rendererEnvironment["WINEDLLOVERRIDES"] = mergedWineDLLOverrides(
            "\(overrideModuleNames.joined(separator: ","))=n,b",
            existing: rendererEnvironment["WINEDLLOVERRIDES"]
        )

        let selectedComponentName: String
        switch policy {
        case .d3dMetal:
            selectedComponentName = "d3dmetal"
        case .dxmt:
            selectedComponentName = "dxmt"
        case .d9vk:
            selectedComponentName = "d9vk"
        case .vulkan:
            selectedComponentName = "dxvk"
        }

        var policyEnvironment = [
            "FORGEPLAY_GAME_RENDERER_POLICY_ENABLED": "1",
            "FORGEPLAY_GAME_RENDERER_POLICY": policy.rawValue,
            "FORGEPLAY_GAME_RENDERER_REQUESTED": requested.rawValue,
            "FORGEPLAY_GAME_RENDERER_COMPONENTS_X64": selectedComponentName,
            "FORGEPLAY_GAME_RENDERER_COMPONENTS_X86":
                x86Directories.isEmpty ? "" : selectedComponentName,
            "FORGEPLAY_GAME_RENDERER_DLL_PATH_X64": x64Directories
                .map(windowsHostPath(for:))
                .joined(separator: ";"),
            "FORGEPLAY_GAME_RENDERER_DLL_PATH_X86": x86Directories
                .map(windowsHostPath(for:))
                .joined(separator: ";")
        ]
        for key in gameRendererUnixEnvironmentKeys {
            policyEnvironment["FORGEPLAY_GAME_RENDERER_ENV_\(key)"] =
                rendererEnvironment[key] ?? gameRendererUnsetValue
        }
        return policyEnvironment
    }

    private static func rendererModuleDirectories(_ modules: [URL]) -> [URL] {
        deduplicated(modules.map { $0.deletingLastPathComponent() })
    }

    private func validateActionInputs(for action: RunnerAction) throws {
        switch action {
        case .initializePrefix(_, let prefix, _),
             .migratePrefixRuntime(_, let prefix, _),
             .waitForWinePrefix(_, let prefix, _):
            try requireRunnerDirectory(prefix)
        case .probeRuntime:
            return
        case .installSteam(_, let prefix, let installer, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(installer)
        case .requestSteamClientShutdown(_, let prefix, let steamExecutable, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(steamExecutable)
        case .shutdownWinePrefix(_, let prefix, _):
            try requireRunnerDirectory(prefix)
        case .launchSteam(_, let prefix, let steamExecutable, _, _, _, _, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(steamExecutable)
        case .extractRuntimeArchive(_, let prefix, let archive, let extractionDirectory, _, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(archive)
            try requireRunnerDirectory(extractionDirectory)
        case .installRuntime(_, let prefix, let installer, _, _):
            try requireRunnerDirectory(prefix)
            try requireRunnerRegularFile(installer)
        case .setWindowsVersion(_, let prefix, _, _),
             .setRegistryValue(_, let prefix, _, _, _, _, _),
             .setDLLOverride(_, let prefix, _, _, _),
             .setAppDLLOverride(_, let prefix, _, _, _, _),
             .deleteAppDLLOverrideIfPresent(_, let prefix, _, _, _):
            try requireRunnerDirectory(prefix)
        case .createSupportArchive(let sourceDirectory, let destinationZip, _):
            try Self.validateSupportArchivePaths(
                sourceDirectory: sourceDirectory,
                destinationZip: destinationZip,
                fileManager: fileManager
            )
        }
    }

    private func requireRunnerDirectory(_ url: URL) throws {
        try Self.requireNonSymlinkDirectory(url, fileManager: fileManager, unsafeError: SafeProcessRunnerError.unsafeActionInput)
    }

    private func requireRunnerRegularFile(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SafeProcessRunnerError.metadataReadFailed(url, message)
        } catch {
            throw SafeProcessRunnerError.unsafeActionInput(url)
        }
    }

    private func requireExecutableFile(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notRegularNonSymlinkFile {
            if fileManager.fileExists(atPath: url.path) {
                throw SafeProcessRunnerError.unsafeExecutable(url)
            }
            throw SafeProcessRunnerError.executableMissing(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SafeProcessRunnerError.metadataReadFailed(url, message)
        } catch {
            throw SafeProcessRunnerError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private nonisolated static func requireNonSymlinkDirectory(
        _ url: URL,
        fileManager: FileManager,
        unsafeError: (URL) -> SafeProcessRunnerError
    ) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SafeProcessRunnerError.metadataReadFailed(url, message)
        } catch {
            throw unsafeError(url)
        }
    }

    nonisolated static func processEnvironment(
        overrides: [String: String],
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = sanitizedParentEnvironment(from: inherited)
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private nonisolated static func sanitizedParentEnvironment(from inherited: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": defaultExecutableSearchPath
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        for (key, value) in inherited where key == "LC_ALL" || key.hasPrefix("LC_") {
            if !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    private static func windowsPath(for url: URL, in prefix: URL) -> String? {
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory).standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(driveC + "/") else {
            return nil
        }
        let relative = String(target.dropFirst(driveC.count + 1))
        return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    private static func windowsHostPath(for url: URL) -> String {
        "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    private func steamLaunchInvocation(
        for executable: URL,
        prefix _: URL,
        steamCommand: [String]
    ) -> (executable: URL, arguments: [String], validatesStartup: Bool) {
        if let steamLauncher = Self.forgePlaySteamLauncherExecutable(
            for: executable,
            fileManager: fileManager
        ) {
            return (
                executable,
                [steamLauncher.path, "--detach", "--"] + steamCommand,
                true
            )
        }

        return (
            executable,
            steamCommand,
            true
        )
    }

    private static func installerCommand(for installer: URL) -> [String] {
        if installer.pathExtension.lowercased() == "msi" {
            return ["msiexec", "/i", installer.path]
        }
        return [installer.path]
    }

    private nonisolated static func externalStorageGrantPublicationFailureCode(
        for error: Error
    ) -> String {
        guard let grantError =
                error as? SteamExternalStorageProcessGrantError else {
            return "publisher-error"
        }
        switch grantError {
        case .invalidRunIdentifier:
            return "run-identifier-invalid"
        case .externalStorageRootRequired:
            return "root-required"
        case .tooManyRoots:
            return "root-limit-exceeded"
        case .applicationGroupUnavailable:
            return "application-group-unavailable"
        case .bridgeUnavailable:
            return "bridge-unavailable"
        case .invalidExternalStorageRoot:
            return "root-invalid"
        case .bookmarkCreationFailed:
            return "bookmark-creation-failed"
        case .manifestTooLarge:
            return "manifest-size-exceeded"
        case .unsafeGrantDirectory:
            return "grant-directory-unsafe"
        case .unsafeGrantFile:
            return "grant-file-unsafe"
        case .grantPersistenceFailed:
            return "grant-persistence-failed"
        case .staleGrantCleanupFailed:
            return "grant-cleanup-failed"
        }
    }

    private nonisolated static func runtimeCompatibilityDiagnostics(
        from environment: [String: String]
    ) -> [String: String] {
        let fields = [
            ("synchronizationSelection", "FORGEPLAY_SYNCHRONIZATION_SELECTION"),
            ("synchronizationBackend", "FORGEPLAY_SYNCHRONIZATION_BACKEND"),
            ("gameRendererRequested", "FORGEPLAY_GAME_RENDERER_REQUESTED"),
            ("gameRendererPolicy", "FORGEPLAY_GAME_RENDERER_POLICY"),
            ("gameRendererCorrelationID", "FORGEPLAY_GAME_RENDERER_CORRELATION_ID"),
            ("gameRendererComponentsX64", "FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"),
            ("gameRendererComponentsX86", "FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"),
            ("gameModeHostRequested", "FORGEPLAY_GAME_MODE_HOST_REQUESTED"),
            ("gameModeHostAvailability", "FORGEPLAY_GAME_MODE_HOST_AVAILABILITY"),
            ("gameModeHostDisabledReason", "FORGEPLAY_GAME_MODE_HOST_DISABLED_REASON"),
            ("gameModeHostBundleIdentifier", "FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER"),
            ("gameModeHostExecutableSHA256", "FORGEPLAY_GAME_MODE_HOST_EXECUTABLE_SHA256"),
            ("gameModeHostRunIdentifier", "FORGEPLAY_GAME_MODE_HOST_RUN_ID"),
            (
                "externalStorageGrantRunIdentifier",
                SteamExternalStorageProcessGrant.runIdentifierEnvironmentKey
            ),
            (
                "externalStorageGrantSHA256",
                SteamExternalStorageProcessGrant.manifestSHA256EnvironmentKey
            )
        ]
        return fields.reduce(into: [String: String]()) { result, field in
            guard let value = environment[field.1], !value.isEmpty else { return }
            result[field.0] = value
        }
    }

    /// Routed games replace the real loader variables, but an excluded Steam
    /// infrastructure child can be launched by that game and inherit them. Keep
    /// a host-owned snapshot of the pristine Steam environment so Wine can scrub
    /// the renderer state without discarding the base runtime search paths.
    private nonisolated static func captureSteamBaseRendererEnvironment(
        in environment: inout [String: String]
    ) {
        for profileKey in gameRendererUnixEnvironmentKeys {
            let actualKey = profileKey == "D3DMETAL_SHARED_LIBRARY"
                ? "FORGEPLAY_D3DMETAL_SHARED_LIBRARY"
                : profileKey
            environment["FORGEPLAY_GAME_RENDERER_BASE_ENV_\(profileKey)"] =
                environment[actualKey] ?? gameRendererUnsetValue
        }
    }

    static func runnerEnvironment(
        for executable: URL,
        base: [String: String] = [:],
        graphicsBackend: SteamRendererPolicyPreference? = nil,
        exposesVulkanICD: Bool = false,
        injectGraphicsDLLOverrides: Bool = true,
        restoresSteamWebHelperVulkanICD: Bool = false,
        allowsInvalidPrefixSynchronizationProfileForCleanup: Bool = false
    ) throws -> [String: String] {
        var environment = base
        var supplementalRendererRoot: URL?
        if let prefixPath = environment["WINEPREFIX"], !prefixPath.isEmpty {
            let prefix = URL(fileURLWithPath: prefixPath, isDirectory: true)
            let synchronizationProfile: PrefixSynchronizationProfile
            do {
                synchronizationProfile = try appliedSynchronizationProfile(
                    in: prefix
                )
            } catch {
                guard allowsInvalidPrefixSynchronizationProfileForCleanup else {
                    throw error
                }
                synchronizationProfile = PrefixSynchronizationProfile(
                    selection: .automatic,
                    backend: .server
                )
            }
            applySynchronizationProfile(synchronizationProfile, to: &environment)
            supplementalRendererRoot = usableSupplementalRendererRoot(containingPrefix: prefix)
            if ForgePlaySandboxPolicy.isAppSandboxEnabled {
                guard let applicationGroupIdentifier = ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier else {
                    throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
                }
                guard let applicationGroupContainer = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
                ) else {
                    throw SafeProcessRunnerError.sandboxIPCConfigurationMissing
                }
                let serverRoot = wineServerRoot(
                    forPrefix: prefix,
                    sandboxEnabled: true,
                    applicationGroupContainerURL: applicationGroupContainer
                )
                try prepareWineServerRoot(
                    serverRoot,
                    trustedAncestor: applicationGroupContainer,
                    privateTailComponentCount: 2
                )
                environment["WINE_SERVER_ROOT"] = serverRoot.path
                let machServiceName = wineMachServiceName(
                    forPrefix: prefix,
                    applicationGroupIdentifier: applicationGroupIdentifier
                )
                environment["WINE_MACH_SERVICE_NAME"] = machServiceName
            } else {
                let serverRoot = wineServerRoot(
                    forPrefix: prefix,
                    sandboxEnabled: false
                )
                try prepareWineServerRoot(serverRoot, trustedAncestor: prefix)
                environment["WINE_SERVER_ROOT"] = serverRoot.path
            }
        }
        let rendererUsesVulkan = try rendererCompositionRequiresVulkan(
            for: executable,
            graphicsBackend: graphicsBackend
        )
        let exposesRequiredVulkanICD = exposesVulkanICD || rendererUsesVulkan
        let searchPaths = try runnerSearchPaths(
            for: executable,
            graphicsBackend: graphicsBackend,
            exposesVulkanICD: exposesRequiredVulkanICD,
            supplementalRendererRoot: supplementalRendererRoot
        )
        let webHelperVulkanICDs = restoresSteamWebHelperVulkanICD &&
            Self.shouldSuppressVulkanICD(
                for: graphicsBackend,
                explicitSteamClientExposure: exposesRequiredVulkanICD
            )
            ? try runnerSearchPaths(
                for: executable,
                graphicsBackend: graphicsBackend,
                exposesVulkanICD: true,
                supplementalRendererRoot: supplementalRendererRoot
            ).vulkanICDs
            : []
        if injectGraphicsDLLOverrides {
            applyGraphicsBackend(
                graphicsBackend,
                hasD3DMetalFramework: !searchPaths.d3dMetalFrameworkExecutables.isEmpty,
                to: &environment
            )
        }
        if !searchPaths.dynamicLibraries.isEmpty {
            environment["DYLD_LIBRARY_PATH"] = mergedPathList(
                searchPaths.dynamicLibraries,
                existing: nil
            )
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = mergedPathList(
                searchPaths.dynamicLibraries,
                existing: nil
            )
        }
        if !searchPaths.frameworks.isEmpty {
            environment["DYLD_FRAMEWORK_PATH"] = mergedPathList(
                searchPaths.frameworks,
                existing: environment["DYLD_FRAMEWORK_PATH"]
            )
        }
        if (graphicsBackend == .d3dMetal || graphicsBackend == .dxmt),
           environment["D3DMETAL_FRAMEWORK_PATH"] == nil,
           let d3dMetalFramework = searchPaths.d3dMetalFrameworkExecutables.first {
            environment["D3DMETAL_FRAMEWORK_PATH"] = d3dMetalFramework
        }
        if Self.shouldSuppressVulkanICD(
            for: graphicsBackend,
            explicitSteamClientExposure: exposesRequiredVulkanICD
        ) {
            environment["VK_ICD_FILENAMES"] = "/dev/null"
            environment["VK_DRIVER_FILES"] = "/dev/null"
            if !webHelperVulkanICDs.isEmpty {
                let icdPathList = mergedPathList(webHelperVulkanICDs, existing: nil)
                environment["FORGEPLAY_STEAM_WEBHELPER_VK_ICD_FILENAMES"] = icdPathList
                environment["FORGEPLAY_STEAM_WEBHELPER_VK_DRIVER_FILES"] = icdPathList
            }
        } else if !searchPaths.vulkanICDs.isEmpty {
            let icdPathList = mergedPathList(
                searchPaths.vulkanICDs,
                existing: environment["VK_ICD_FILENAMES"]
            )
            environment["VK_ICD_FILENAMES"] = icdPathList
            environment["VK_DRIVER_FILES"] = mergedPathList(
                searchPaths.vulkanICDs,
                existing: environment["VK_DRIVER_FILES"]
            )
        }

        if let binDirectory = wineBinDirectory(for: executable) {
            environment["PATH"] = mergedPathList(
                [binDirectory.path],
                existing: defaultExecutableSearchPath
            )
            let wineloader = binDirectory.appending(path: "wine.bin")
            if FileSystemItemPolicy.isRegularNonSymlinkFile(wineloader) &&
                FileManager.default.isExecutableFile(atPath: wineloader.path) {
                environment["WINELOADER"] = wineloader.path
            }
            if let steamLauncher = forgePlaySteamLauncherExecutable(for: executable) {
                environment["FORGEPLAY_STEAM_LAUNCHER"] = steamLauncher.path
            }
            let wineserver = binDirectory.appending(path: "wineserver")
            if FileSystemItemPolicy.isRegularNonSymlinkFile(wineserver) &&
                FileManager.default.isExecutableFile(atPath: wineserver.path) {
                environment["WINESERVER"] = wineserver.path
            }
        }

        if let wineRoot = wineRootDirectory(for: executable) {
            let gstreamerRoot = wineRoot.appending(
                path: "gstreamer",
                directoryHint: .isDirectory
            )
            let pluginDirectory = gstreamerRoot.appending(
                path: "lib/gstreamer-1.0",
                directoryHint: .isDirectory
            )
            if FileSystemItemPolicy.isNonSymlinkDirectory(
                pluginDirectory,
                fileManager: FileManager.default
            ) {
                // Only load the reviewed, runtime-bundled plug-ins. Allowing a
                // host installation into this process would make Media
                // Foundation support depend on machine state and architecture.
                environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = ""
                environment["GST_PLUGIN_PATH_1_0"] = pluginDirectory.path
            }
        }

        if !searchPaths.wineDLLs.isEmpty {
            environment["WINEDLLPATH"] = mergedPathList(
                searchPaths.wineDLLs,
                existing: nil
            )
        }

        return environment
    }

    nonisolated static func wineServerRoot(
        forPrefix prefix: URL,
        sandboxEnabled: Bool = ForgePlaySandboxPolicy.isAppSandboxEnabled,
        applicationGroupContainerURL: URL? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        if sandboxEnabled {
            let sharedContainer = applicationGroupContainerURL ?? temporaryDirectory
            return sharedContainer
                .appending(path: "Library/Caches/ForgePlay/WineServer", directoryHint: .isDirectory)
                .appending(
                    path: wineServerScopeIdentifier(forPrefix: prefix),
                    directoryHint: .isDirectory
                )
                .standardizedFileURL
        }
        return prefix
            .appending(path: ".forgeplay-wineserver", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// Creates the per-prefix Wine server directory without following a
    /// symlink at any path component. Wine transports process-scoped IPC
    /// through this directory, so accepting a replaced component would let a
    /// different filesystem location impersonate the selected prefix scope.
    nonisolated static func prepareWineServerRoot(
        _ root: URL,
        trustedAncestor: URL,
        privateTailComponentCount: Int = 1
    ) throws {
        do {
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                root,
                trustedAncestor: trustedAncestor,
                privateTailComponentCount: privateTailComponentCount
            )
        } catch {
            throw SafeProcessRunnerError.unsafeWineServerRoot(
                root.standardizedFileURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    nonisolated static func wineMachServiceName(
        forPrefix prefix: URL,
        applicationGroupIdentifier: String
    ) -> String {
        "\(applicationGroupIdentifier).wineserver.\(wineServerScopeIdentifier(forPrefix: prefix))"
    }

    nonisolated static func wineServerScopeIdentifier(forPrefix prefix: URL) -> String {
        let canonicalPrefixPath = prefix.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return SHA256.hash(data: Data(canonicalPrefixPath.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func rendererWindowsModuleFiles(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        prefix: URL? = nil
    ) throws -> [URL] {
        try rendererWindowsModuleFilesByWindowsDirectory(
            for: executable,
            graphicsBackend: graphicsBackend,
            prefix: prefix
        )["system32"] ?? []
    }

    static func rendererWindowsModuleFilesByWindowsDirectory(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        prefix: URL? = nil
    ) throws -> [String: [URL]] {
        let fileManager = FileManager.default
        var modulesByWindowsDirectory: [String: [URL]] = [:]

        if let wineRoot = wineRootDirectory(for: executable) {
            let runtimeRoot = wineRoot.deletingLastPathComponent()
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                frameworks: runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: runtimeRoot,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
            switch graphicsBackend {
            case .d3dMetal:
                let appleD3DMetal = wineRoot.appending(path: "lib64/apple_gptk", directoryHint: .isDirectory)
                if rendererComponentIsUsable(named: "d3dmetal", at: appleD3DMetal, fileManager: fileManager) {
                    try appendRendererWindowsModuleFilesByWindowsDirectory(
                        wineModulesRoot: appleD3DMetal.appending(path: "wine", directoryHint: .isDirectory),
                        fileManager: fileManager,
                        modulesByWindowsDirectory: &modulesByWindowsDirectory
                    )
                }
            case .dxmt:
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: runtimeRoot.appending(
                        path: "Frameworks/renderer/dxmt/wine",
                        directoryHint: .isDirectory
                    ),
                    fileManager: fileManager,
                    modulesByWindowsDirectory: &modulesByWindowsDirectory
                )
            case .d9vk:
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: runtimeRoot.appending(
                        path: "Frameworks/renderer/d9vk/wine",
                        directoryHint: .isDirectory
                    ),
                    fileManager: fileManager,
                    modulesByWindowsDirectory: &modulesByWindowsDirectory
                )
            case .vulkan:
                try appendRendererWindowsModuleFilesByWindowsDirectory(
                    wineModulesRoot: wineRoot.appending(path: "lib/dxvk", directoryHint: .isDirectory),
                    fileManager: fileManager,
                    modulesByWindowsDirectory: &modulesByWindowsDirectory
                )
            }
        }
        if let contents = bundleContentsDirectory(for: executable) {
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                frameworks: contents.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: contents,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }
        if graphicsBackend == .d3dMetal,
           let prefix,
           let supplementalRendererRoot = usableSupplementalRendererRoot(containingPrefix: prefix),
           rendererComponentIsUsable(
            named: "d3dmetal",
            at: supplementalRendererRoot,
            fileManager: fileManager
           ) {
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: supplementalRendererRoot.appending(path: "wine", directoryHint: .isDirectory),
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }

        return modulesByWindowsDirectory.mapValues { modules in
            let deduplicatedModules = deduplicated(modules)
            guard graphicsBackend == .d3dMetal else {
                return deduplicatedModules
            }
            return deduplicatedModules.filter { module in
                let moduleName = module.lastPathComponent.lowercased()
                guard moduleName == "d3d12.dll" ||
                        moduleName == "d3d12core.dll" else {
                    return true
                }
                let rendererRoot = module
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                return D3DMetalRendererPayloadContract.isUsable(
                    for: .direct3D12,
                    at: rendererRoot,
                    fileManager: fileManager
                )
            }
        }
    }

    private static func rendererWindowsModuleFilesByWindowsDirectory(
        forNamedComponent componentName: String,
        executable: URL,
        prefix: URL? = nil
    ) throws -> [String: [URL]] {
        let fileManager = FileManager.default
        var modulesByWindowsDirectory: [String: [URL]] = [:]

        for contentsDirectory in rendererSupportContentsDirectories(for: executable) {
            let componentRoot = contentsDirectory
                .appending(path: "Frameworks/renderer", directoryHint: .isDirectory)
                .appending(path: componentName, directoryHint: .isDirectory)
            guard rendererComponentIsUsable(
                named: componentName,
                at: componentRoot,
                fileManager: fileManager
            ) else {
                continue
            }
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: componentRoot.appending(path: "wine", directoryHint: .isDirectory),
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }
        if componentName == "d3dmetal",
           let prefix,
           let supplementalRendererRoot = usableSupplementalRendererRoot(containingPrefix: prefix),
           rendererComponentIsUsable(
            named: componentName,
            at: supplementalRendererRoot,
            fileManager: fileManager
           ) {
            try appendRendererWindowsModuleFilesByWindowsDirectory(
                wineModulesRoot: supplementalRendererRoot.appending(
                    path: "wine",
                    directoryHint: .isDirectory
                ),
                fileManager: fileManager,
                modulesByWindowsDirectory: &modulesByWindowsDirectory
            )
        }
        return modulesByWindowsDirectory.mapValues(deduplicated)
    }

    private static func applyGraphicsBackend(
        _ graphicsBackend: SteamRendererPolicyPreference?,
        hasD3DMetalFramework: Bool,
        to environment: inout [String: String]
    ) {
        guard let graphicsBackend else { return }
        let override: String?
        switch graphicsBackend {
        case .d3dMetal:
            override = [
                "\(direct3DDLLOverrideGroup)=n,b",
                "nvapi64,nvngx,nvngx-on-metalfx=n,b",
                "winemetal=n,b"
            ].joined(separator: ";")
        case .dxmt:
            override = [
                "\(direct3DDLLOverrideGroup)=n,b",
                "winemetal=n,b"
            ].joined(separator: ";")
        case .d9vk, .vulkan:
            override = "\(direct3DDLLOverrideGroup)=n,b"
        }
        guard let override else { return }
        environment["WINEDLLOVERRIDES"] = mergedWineDLLOverrides(
            override,
            existing: environment["WINEDLLOVERRIDES"]
        )
    }

    private static func runnerSearchPaths(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?,
        exposesVulkanICD: Bool,
        supplementalRendererRoot: URL?
    ) throws -> RunnerSearchPaths {
        let fileManager = FileManager.default
        var dynamicLibraryPaths: [String] = []
        var frameworkPaths: [String] = []
        var d3dMetalFrameworkExecutables: [String] = []
        var rendererWineDLLPaths: [String] = []
        var baseWineDLLPaths: [String] = []
        var vulkanICDs: [String] = []

        if let wineRoot = wineRootDirectory(for: executable) {
            let lib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(lib, fileManager: fileManager) {
                dynamicLibraryPaths.append(lib.path)
            }
            let gstreamerLib = wineRoot.appending(
                path: "gstreamer/lib",
                directoryHint: .isDirectory
            )
            if FileSystemItemPolicy.isNonSymlinkDirectory(
                gstreamerLib,
                fileManager: fileManager
            ) {
                dynamicLibraryPaths.append(gstreamerLib.path)
            }
            let lib64 = wineRoot.appending(path: "lib64", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(lib64, fileManager: fileManager) {
                dynamicLibraryPaths.append(lib64.path)
            }
            if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
                vulkanICDs.append(contentsOf: vulkanICDFiles(in: wineRoot, fileManager: fileManager))
            }
            let dllPath = wineRoot.appending(path: "lib/wine", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(dllPath, fileManager: fileManager) {
                baseWineDLLPaths.append(contentsOf: wineDLLSearchDirectories(for: dllPath, fileManager: fileManager))
            }
            let appleD3DMetal = wineRoot.appending(path: "lib64/apple_gptk", directoryHint: .isDirectory)
            if graphicsBackend == .d3dMetal || graphicsBackend == .dxmt,
               FileSystemItemPolicy.isNonSymlinkDirectory(appleD3DMetal, fileManager: fileManager),
               rendererComponentIsUsable(named: "d3dmetal", at: appleD3DMetal, fileManager: fileManager) {
                let external = appleD3DMetal.appending(path: "external", directoryHint: .isDirectory)
                appendD3DMetalExternalPathsIfComplete(
                    in: external,
                    fileManager: fileManager,
                    dynamicLibraryPaths: &dynamicLibraryPaths,
                    frameworkPaths: &frameworkPaths,
                    d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
                )
                let appleD3DMetalWine = appleD3DMetal.appending(path: "wine", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(appleD3DMetalWine, fileManager: fileManager) {
                    rendererWineDLLPaths.append(contentsOf: wineDLLSearchDirectories(for: appleD3DMetalWine, fileManager: fileManager))
                    let unix = appleD3DMetalWine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
                    if FileSystemItemPolicy.isNonSymlinkDirectory(unix, fileManager: fileManager) {
                        dynamicLibraryPaths.append(unix.path)
                    }
                }
            }
            if graphicsBackend == .vulkan {
                let dxvk = wineRoot.appending(path: "lib/dxvk", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(dxvk, fileManager: fileManager) {
                    rendererWineDLLPaths.append(contentsOf: wineDLLSearchDirectories(for: dxvk, fileManager: fileManager))
                }
            }
            let external = wineRoot.appending(path: "lib/external", directoryHint: .isDirectory)
            if graphicsBackend == .d3dMetal,
               FileSystemItemPolicy.isNonSymlinkDirectory(external, fileManager: fileManager) {
                appendD3DMetalExternalPathsIfComplete(
                    in: external,
                    fileManager: fileManager,
                    dynamicLibraryPaths: &dynamicLibraryPaths,
                    frameworkPaths: &frameworkPaths,
                    d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
                )
            }
            let runtimeRoot = wineRoot.deletingLastPathComponent()
            try appendFrameworkSearchPaths(
                frameworks: runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: runtimeRoot,
                graphicsBackend: graphicsBackend,
                exposesVulkanICD: exposesVulkanICD,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables,
                rendererWineDLLPaths: &rendererWineDLLPaths,
                vulkanICDs: &vulkanICDs
            )
        }

        return try runnerSearchPaths(
            executable: executable,
            graphicsBackend: graphicsBackend,
            exposesVulkanICD: exposesVulkanICD,
            fileManager: fileManager,
            dynamicLibraryPaths: dynamicLibraryPaths,
            frameworkPaths: frameworkPaths,
            d3dMetalFrameworkExecutables: d3dMetalFrameworkExecutables,
            rendererWineDLLPaths: rendererWineDLLPaths,
            baseWineDLLPaths: baseWineDLLPaths,
            vulkanICDs: vulkanICDs,
            supplementalRendererRoot: supplementalRendererRoot
        )
    }

    private static func usableSupplementalRendererRoot(containingPrefix prefix: URL) -> URL? {
        guard let rendererRoot = ForgePlaySupplementalRendererPolicy.rendererRoot(containingPrefix: prefix),
              FileSystemItemPolicy.isNonSymlinkDirectory(rendererRoot) else {
            return nil
        }
        return rendererRoot
    }

    private static func appendStandaloneRendererSearchPaths(
        rendererRoot: URL,
        fileManager: FileManager,
        dynamicLibraryPaths: inout [String],
        frameworkPaths: inout [String],
        d3dMetalFrameworkExecutables: inout [String],
        rendererWineDLLPaths: inout [String]
    ) {
        dynamicLibraryPaths.append(rendererRoot.path)
        let external = rendererRoot.appending(path: "external", directoryHint: .isDirectory)
        if FileSystemItemPolicy.isNonSymlinkDirectory(external, fileManager: fileManager) {
            appendD3DMetalExternalPathsIfComplete(
                in: external,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
            )
        }

        let wine = rendererRoot.appending(path: "wine", directoryHint: .isDirectory)
        guard FileSystemItemPolicy.isNonSymlinkDirectory(wine, fileManager: fileManager) else { return }
        rendererWineDLLPaths.append(contentsOf: rendererWineDLLSearchDirectories(
            for: wine,
            rendererName: "d3dmetal",
            compositionHasD3DMetal: true,
            fileManager: fileManager
        ))
        let unix = wine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        if FileSystemItemPolicy.isNonSymlinkDirectory(unix, fileManager: fileManager) {
            dynamicLibraryPaths.append(unix.path)
        }
    }

    private static func runnerSearchPaths(
        executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?,
        exposesVulkanICD: Bool,
        fileManager: FileManager,
        dynamicLibraryPaths initialDynamicLibraryPaths: [String],
        frameworkPaths initialFrameworkPaths: [String],
        d3dMetalFrameworkExecutables initialD3DMetalFrameworkExecutables: [String],
        rendererWineDLLPaths initialRendererWineDLLPaths: [String],
        baseWineDLLPaths initialBaseWineDLLPaths: [String],
        vulkanICDs initialVulkanICDs: [String],
        supplementalRendererRoot: URL?
    ) throws -> RunnerSearchPaths {
        var dynamicLibraryPaths = initialDynamicLibraryPaths
        var frameworkPaths = initialFrameworkPaths
        var d3dMetalFrameworkExecutables = initialD3DMetalFrameworkExecutables
        var rendererWineDLLPaths = initialRendererWineDLLPaths
        let baseWineDLLPaths = initialBaseWineDLLPaths
        var vulkanICDs = initialVulkanICDs

        if let contents = bundleContentsDirectory(for: executable) {
            if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
                vulkanICDs.append(contentsOf: vulkanICDFiles(in: contents, fileManager: fileManager))
            }
            try appendFrameworkSearchPaths(
                frameworks: contents.appending(path: "Frameworks", directoryHint: .isDirectory),
                contentsDirectory: contents,
                graphicsBackend: graphicsBackend,
                exposesVulkanICD: exposesVulkanICD,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables,
                rendererWineDLLPaths: &rendererWineDLLPaths,
                vulkanICDs: &vulkanICDs
            )
        }
        if graphicsBackend == .d3dMetal,
           let supplementalRendererRoot,
           rendererComponentIsUsable(
            named: "d3dmetal",
            at: supplementalRendererRoot,
            fileManager: fileManager
           ) {
            appendStandaloneRendererSearchPaths(
                rendererRoot: supplementalRendererRoot,
                fileManager: fileManager,
                dynamicLibraryPaths: &dynamicLibraryPaths,
                frameworkPaths: &frameworkPaths,
                d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables,
                rendererWineDLLPaths: &rendererWineDLLPaths
            )
        }

        return RunnerSearchPaths(
            dynamicLibraries: deduplicated(dynamicLibraryPaths),
            frameworks: deduplicated(frameworkPaths),
            d3dMetalFrameworkExecutables: deduplicated(d3dMetalFrameworkExecutables),
            wineDLLs: deduplicated(rendererWineDLLPaths + baseWineDLLPaths),
            vulkanICDs: deduplicated(vulkanICDs)
        )
    }

    private static func appendFrameworkSearchPaths(
        frameworks: URL,
        contentsDirectory: URL,
        graphicsBackend: SteamRendererPolicyPreference?,
        exposesVulkanICD: Bool,
        fileManager: FileManager,
        dynamicLibraryPaths: inout [String],
        frameworkPaths: inout [String],
        d3dMetalFrameworkExecutables: inout [String],
        rendererWineDLLPaths: inout [String],
        vulkanICDs: inout [String]
    ) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(frameworks, fileManager: fileManager) else {
            return
        }

        // Keep general host support libraries on DYLD_FALLBACK_LIBRARY_PATH. Putting this
        // directory on DYLD_LIBRARY_PATH lets GNU libiconv override macOS libiconv for
        // Wine's Homebrew-built TLS dependencies, which makes GnuTLS fail to load.
        if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
            vulkanICDs.append(contentsOf: vulkanICDFiles(in: frameworks, fileManager: fileManager))
        }

        let renderer = frameworks.appending(path: "renderer", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: renderer.path) {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(renderer, fileManager: fileManager) else {
                return
            }
            let rendererContents: [URL]
            do {
                rendererContents = try fileManager.contentsOfDirectory(
                    at: renderer,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SafeProcessRunnerError.runnerLibrarySearchFailed(renderer, error)
            }
            let rendererDirectories = selectedRendererDirectories(
                from: rendererContents,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager
            )
            let compositionHasD3DMetal = rendererDirectories.contains {
                $0.lastPathComponent.caseInsensitiveCompare("d3dmetal") == .orderedSame
            }
            for url in rendererDirectories {
                dynamicLibraryPaths.append(url.path)
                let external = url.appending(path: "external", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(external, fileManager: fileManager) {
                    appendD3DMetalExternalPathsIfComplete(
                        in: external,
                        fileManager: fileManager,
                        dynamicLibraryPaths: &dynamicLibraryPaths,
                        frameworkPaths: &frameworkPaths,
                        d3dMetalFrameworkExecutables: &d3dMetalFrameworkExecutables
                    )
                }
                if Self.shouldExposeVulkanICD(for: graphicsBackend, explicitSteamClientExposure: exposesVulkanICD) {
                    vulkanICDs.append(contentsOf: vulkanICDFiles(in: url, fileManager: fileManager))
                }
                let wine = url.appending(path: "wine", directoryHint: .isDirectory)
                if FileSystemItemPolicy.isNonSymlinkDirectory(wine, fileManager: fileManager) {
                    rendererWineDLLPaths.append(contentsOf: rendererWineDLLSearchDirectories(
                        for: wine,
                        rendererName: url.lastPathComponent.lowercased(),
                        compositionHasD3DMetal: compositionHasD3DMetal,
                        fileManager: fileManager
                    ))
                    let unix = wine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
                    if FileSystemItemPolicy.isNonSymlinkDirectory(unix, fileManager: fileManager) {
                        dynamicLibraryPaths.append(unix.path)
                    }
                }
            }
        }

    }

    private static func appendRendererWindowsModuleFilesByWindowsDirectory(
        frameworks: URL,
        contentsDirectory: URL,
        graphicsBackend: SteamRendererPolicyPreference,
        fileManager: FileManager,
        modulesByWindowsDirectory: inout [String: [URL]]
    ) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(frameworks, fileManager: fileManager) else {
            return
        }
        let renderer = frameworks.appending(path: "renderer", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: renderer.path) else {
            return
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(renderer, fileManager: fileManager) else {
            return
        }
        let rendererContents: [URL]
        do {
            rendererContents = try fileManager.contentsOfDirectory(
                at: renderer,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SafeProcessRunnerError.runnerLibrarySearchFailed(renderer, error)
        }
        let rendererDirectories = selectedRendererDirectories(
            from: rendererContents,
            graphicsBackend: graphicsBackend,
            fileManager: fileManager
        )
        let compositionHasD3DMetal = rendererDirectories.contains {
            $0.lastPathComponent.caseInsensitiveCompare("d3dmetal") == .orderedSame
        }
        for url in rendererDirectories {
            let rendererName = url.lastPathComponent.lowercased()
            for mapping in rendererWindowsModuleDirectoryMappings {
                guard shouldUseRendererComponent(
                    rendererName,
                    forWindowsDirectory: mapping.windowsDirectory,
                    compositionHasD3DMetal: compositionHasD3DMetal
                ) else {
                    continue
                }
                let windowsModules = url.appending(path: "wine/\(mapping.rendererDirectory)", directoryHint: .isDirectory)
                guard FileSystemItemPolicy.isNonSymlinkDirectory(windowsModules, fileManager: fileManager) else {
                    continue
                }
                let files: [URL]
                do {
                    files = try fileManager.contentsOfDirectory(
                        at: windowsModules,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    throw SafeProcessRunnerError.runnerLibrarySearchFailed(windowsModules, error)
                }
                for file in files {
                    let moduleName = file.lastPathComponent.lowercased()
                    guard rendererBridgeDLLNames.contains(moduleName),
                          FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager) else {
                        continue
                    }
                    var modules = modulesByWindowsDirectory[mapping.windowsDirectory, default: []]
                    guard !modules.contains(where: { $0.lastPathComponent.lowercased() == moduleName }) else {
                        continue
                    }
                    modules.append(file)
                    modulesByWindowsDirectory[mapping.windowsDirectory] = modules
                }
            }
        }
    }

    private static func appendRendererWindowsModuleFilesByWindowsDirectory(
        wineModulesRoot: URL,
        fileManager: FileManager,
        modulesByWindowsDirectory: inout [String: [URL]]
    ) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(wineModulesRoot, fileManager: fileManager) else {
            return
        }
        for mapping in rendererWindowsModuleDirectoryMappings {
            let windowsModules = wineModulesRoot.appending(path: mapping.rendererDirectory, directoryHint: .isDirectory)
            guard FileSystemItemPolicy.isNonSymlinkDirectory(windowsModules, fileManager: fileManager) else {
                continue
            }
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: windowsModules,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SafeProcessRunnerError.runnerLibrarySearchFailed(windowsModules, error)
            }
            for file in files {
                let moduleName = file.lastPathComponent.lowercased()
                guard rendererBridgeDLLNames.contains(moduleName),
                      FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager) else {
                    continue
                }
                var modules = modulesByWindowsDirectory[mapping.windowsDirectory, default: []]
                guard !modules.contains(where: { $0.lastPathComponent.lowercased() == moduleName }) else {
                    continue
                }
                modules.append(file)
                modulesByWindowsDirectory[mapping.windowsDirectory] = modules
            }
        }
    }

    private static func wineDLLSearchDirectories(for wineDLLRoot: URL, fileManager: FileManager) -> [String] {
        let architectureDirectories = [
            wineDLLRoot.appending(path: "x86_64-unix", directoryHint: .isDirectory),
            wineDLLRoot.appending(path: "x86_64-windows", directoryHint: .isDirectory),
            wineDLLRoot.appending(path: "i386-windows", directoryHint: .isDirectory)
        ].filter {
            FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
        }
        return ([wineDLLRoot] + architectureDirectories).map(\.path)
    }

    private static func rendererWineDLLSearchDirectories(
        for wineDLLRoot: URL,
        rendererName: String,
        compositionHasD3DMetal: Bool,
        fileManager: FileManager
    ) -> [String] {
        let relativeDirectories: [String]
        switch rendererName {
        case "d3dmetal":
            relativeDirectories = ["x86_64-unix", "x86_64-windows"]
        case "dxmt" where compositionHasD3DMetal:
            // D3DMetal owns 64-bit D3D11/DXGI/D3D12. Keep only DXMT's
            // WoW64 Windows modules and Unix Metal bridge in the mixed stack.
            relativeDirectories = ["x86_64-unix", "i386-windows"]
        case "d9vk", "dxvk":
            relativeDirectories = ["x86_64-windows", "i386-windows"]
        default:
            relativeDirectories = ["x86_64-unix", "x86_64-windows", "i386-windows"]
        }
        let directories = relativeDirectories
            .map { wineDLLRoot.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager) }
        return ([wineDLLRoot] + directories).map(\.path)
    }

    private static func shouldUseRendererComponent(
        _ rendererName: String,
        forWindowsDirectory windowsDirectory: String,
        compositionHasD3DMetal: Bool
    ) -> Bool {
        switch rendererName {
        case "d3dmetal":
            return windowsDirectory == "system32"
        case "dxmt" where compositionHasD3DMetal:
            return windowsDirectory == "syswow64"
        default:
            return true
        }
    }

    private static func appendD3DMetalExternalPathsIfComplete(
        in externalDirectory: URL,
        fileManager: FileManager,
        dynamicLibraryPaths: inout [String],
        frameworkPaths: inout [String],
        d3dMetalFrameworkExecutables: inout [String]
    ) {
        let sharedLibrary = externalDirectory.appending(path: "libd3dshared.dylib")
        let frameworkExecutable = externalDirectory
            .appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
            .appending(path: "D3DMetal")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(sharedLibrary, fileManager: fileManager),
              FileSystemItemPolicy.isRegularNonSymlinkFile(frameworkExecutable, fileManager: fileManager) else {
            return
        }
        dynamicLibraryPaths.append(externalDirectory.path)
        frameworkPaths.append(externalDirectory.path)
        d3dMetalFrameworkExecutables.append(frameworkExecutable.path)
    }

    private static func d3dMetalSharedLibraryPath(
        forFrameworkExecutablePath frameworkExecutablePath: String,
        fileManager: FileManager = .default
    ) -> String? {
        let executable = URL(fileURLWithPath: frameworkExecutablePath)
        let framework = executable.deletingLastPathComponent()
        let external = framework.deletingLastPathComponent()
        guard executable.lastPathComponent == "D3DMetal",
              framework.lastPathComponent == "D3DMetal.framework",
              external.lastPathComponent == "external" else {
            return nil
        }
        let sharedLibrary = external.appending(path: "libd3dshared.dylib")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(
            sharedLibrary,
            fileManager: fileManager
        ) else {
            return nil
        }
        return sharedLibrary.path
    }

    private static func vulkanICDFiles(in root: URL, fileManager: FileManager) -> [String] {
        let candidateDirectories = [
            root.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory),
            root.appending(path: "share/vulkan/icd.d", directoryHint: .isDirectory),
            root.appending(path: "lib/vulkan/icd.d", directoryHint: .isDirectory),
            root.appending(path: "vulkan/icd.d", directoryHint: .isDirectory)
        ]
        var paths: [String] = []
        for directory in candidateDirectories where FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) {
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }
            for file in files where file.pathExtension.lowercased() == "json" {
                guard FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager) else {
                    continue
                }
                paths.append(file.path)
            }
        }
        return deduplicated(paths)
    }

    private static func selectedRendererDirectories(
        from rendererContents: [URL],
        graphicsBackend: SteamRendererPolicyPreference?,
        fileManager: FileManager
    ) -> [URL] {
        let directoriesByName = Dictionary(
            uniqueKeysWithValues: rendererContents
                .filter { FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager) }
                .map { ($0.lastPathComponent.lowercased(), $0) }
        )
        let usableDirectoriesByName = directoriesByName.filter {
            rendererComponentIsUsable(
                named: $0.key,
                at: $0.value,
                fileManager: fileManager
            )
        }
        let preferredNames = rendererPreferenceOrder(
            graphicsBackend: graphicsBackend,
            availableRendererNames: Set(usableDirectoriesByName.keys)
        )
        return deduplicated(preferredNames.compactMap { usableDirectoriesByName[$0] })
    }

    private static func rendererPreferenceOrder(
        graphicsBackend: SteamRendererPolicyPreference?,
        availableRendererNames: Set<String>
    ) -> [String] {
        switch graphicsBackend {
        case .d3dMetal:
            return ["d3dmetal"]
        case .dxmt:
            return ["dxmt"]
        case .d9vk:
            return ["d9vk"]
        case .vulkan:
            return ["dxvk"]
        case nil:
            return []
        }
    }

    private static func rendererComponentIsUsable(
        named name: String,
        at rendererDirectory: URL,
        fileManager: FileManager,
        d3dMetalScope: D3DMetalRendererPayloadContract.LaunchScope? = nil
    ) -> Bool {
        if name == "d3dmetal" {
            if let d3dMetalScope {
                return D3DMetalRendererPayloadContract.isUsable(
                    for: d3dMetalScope,
                    at: rendererDirectory,
                    fileManager: fileManager
                )
            }
            return D3DMetalRendererPayloadContract.isUsable(
                for: .direct3D11Family,
                at: rendererDirectory,
                fileManager: fileManager
            ) || D3DMetalRendererPayloadContract.isUsable(
                for: .direct3D12,
                at: rendererDirectory,
                fileManager: fileManager
            )
        }

        let requiredRelativePaths: [String]
        switch name {
        case "d9vk":
            requiredRelativePaths = [
                "wine/i386-windows/d3d9.dll",
                "wine/x86_64-windows/d3d9.dll"
            ]
        case "dxmt":
            requiredRelativePaths = [
                "wine/i386-windows/d3d10core.dll",
                "wine/i386-windows/d3d11.dll",
                "wine/i386-windows/dxgi.dll",
                "wine/i386-windows/winemetal.dll",
                "wine/x86_64-unix/winemetal.so",
                "wine/x86_64-windows/d3d11.dll",
                "wine/x86_64-windows/dxgi.dll",
                "wine/x86_64-windows/winemetal.dll"
            ]
        case "dxvk":
            requiredRelativePaths = [
                "wine/i386-windows/d3d8.dll",
                "wine/i386-windows/d3d9.dll",
                "wine/i386-windows/d3d10core.dll",
                "wine/i386-windows/d3d11.dll",
                "wine/i386-windows/dxgi.dll",
                "wine/x86_64-windows/d3d8.dll",
                "wine/x86_64-windows/d3d9.dll",
                "wine/x86_64-windows/d3d10core.dll",
                "wine/x86_64-windows/d3d11.dll",
                "wine/x86_64-windows/dxgi.dll"
            ]
        default:
            return false
        }

        return requiredRelativePaths.allSatisfy {
            FileSystemItemPolicy.isRegularNonSymlinkFile(
                rendererDirectory.appending(path: $0),
                fileManager: fileManager
            )
        }
    }

    private static func rendererCompositionRequiresVulkan(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?
    ) throws -> Bool {
        guard let graphicsBackend else { return false }
        if graphicsBackend == .vulkan { return true }

        let fileManager = FileManager.default
        for contentsDirectory in rendererSupportContentsDirectories(for: executable) {
            let rendererRoot = contentsDirectory.appending(
                path: "Frameworks/renderer",
                directoryHint: .isDirectory
            )
            guard FileSystemItemPolicy.isNonSymlinkDirectory(rendererRoot, fileManager: fileManager) else {
                continue
            }
            let rendererContents: [URL]
            do {
                rendererContents = try fileManager.contentsOfDirectory(
                    at: rendererRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SafeProcessRunnerError.runnerLibrarySearchFailed(rendererRoot, error)
            }
            let selected = selectedRendererDirectories(
                from: rendererContents,
                graphicsBackend: graphicsBackend,
                fileManager: fileManager
            )
            if selected.contains(where: { ["d9vk", "dxvk"].contains($0.lastPathComponent.lowercased()) }) {
                return true
            }
        }
        return false
    }

    private static func rendererSupportContentsDirectories(for executable: URL) -> [URL] {
        var directories: [URL] = []
        if let wineRoot = wineRootDirectory(for: executable) {
            directories.append(wineRoot.deletingLastPathComponent())
        }
        if let contents = bundleContentsDirectory(for: executable) {
            directories.append(contents)
        }
        return deduplicated(directories)
    }

    private static func shouldExposeVulkanRendererPaths(for graphicsBackend: SteamRendererPolicyPreference?) -> Bool {
        switch graphicsBackend {
        case .d3dMetal, .dxmt:
            false
        case nil:
            false
        case .d9vk, .vulkan:
            true
        }
    }

    private static func shouldExposeVulkanICD(
        for graphicsBackend: SteamRendererPolicyPreference?,
        explicitSteamClientExposure: Bool
    ) -> Bool {
        explicitSteamClientExposure || Self.shouldExposeVulkanRendererPaths(for: graphicsBackend)
    }

    private static func shouldSuppressVulkanICD(
        for graphicsBackend: SteamRendererPolicyPreference?,
        explicitSteamClientExposure: Bool
    ) -> Bool {
        !Self.shouldExposeVulkanICD(
            for: graphicsBackend,
            explicitSteamClientExposure: explicitSteamClientExposure
        )
    }

    private static func shouldExposeSteamClientVulkanICD(
        for executable: URL,
        graphicsBackend: SteamRendererPolicyPreference?
    ) throws -> Bool {
        switch graphicsBackend {
        case .d9vk, .vulkan:
            return true
        case .d3dMetal, .dxmt:
            return false
        case nil:
            return true
        }
    }

    private static func wineBinDirectory(for executable: URL) -> URL? {
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        return binDirectory
    }

    private static func wineRootDirectory(for executable: URL) -> URL? {
        guard let binDirectory = wineBinDirectory(for: executable) else { return nil }
        return binDirectory.deletingLastPathComponent()
    }

    nonisolated static func runtimeLayoutSearchRoots(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates = [executable.deletingLastPathComponent()]
        if let wineRoot = wineRootDirectory(for: executable) {
            candidates.append(wineRoot)
            candidates.append(wineRoot.deletingLastPathComponent())
        }
        if let contents = bundleContentsDirectory(for: executable) {
            candidates.append(contents)
            candidates.append(contents.deletingLastPathComponent())
        }
        return deduplicated(candidates).filter {
            FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
        }
    }

    nonisolated static func wineSynchronizationRuntimeCapabilities(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> WineSynchronizationRuntimeCapabilities {
        _ = executable
        _ = fileManager
        return WineSynchronizationRuntimeCapabilities(supportedBackends: [.server])
    }

    private struct PrefixSynchronizationDocument: Decodable {
        var synchronizationSelection: String?
        var synchronizationBackend: String?
    }

    private struct PrefixSynchronizationProfile {
        var selection: WineSynchronizationSelection
        var backend: WineSynchronizationBackend
    }

    private static func appliedSynchronizationProfile(
        in prefix: URL,
        fileManager: FileManager = .default
    ) throws -> PrefixSynchronizationProfile {
        let metadataURL = prefix.appending(path: "prefix.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return PrefixSynchronizationProfile(selection: .automatic, backend: .server)
        }
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(metadataURL, fileManager: fileManager),
              let byteCount = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              byteCount <= 1_048_576,
              let data = try? Data(contentsOf: metadataURL),
              let document = try? JSONDecoder().decode(PrefixSynchronizationDocument.self, from: data) else {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(metadataURL)
        }
        let legacySelections = Set(["automatic", "msync", "esync"])
        if let selection = document.synchronizationSelection,
           !legacySelections.contains(selection) {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(metadataURL)
        }
        let legacyBackends = Set(["server", "msync", "esync"])
        if let backend = document.synchronizationBackend,
           !legacyBackends.contains(backend) {
            throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(metadataURL)
        }
        return PrefixSynchronizationProfile(selection: .automatic, backend: .server)
    }

    private static func applySynchronizationProfile(
        _ profile: PrefixSynchronizationProfile,
        to environment: inout [String: String]
    ) {
        _ = profile
        environment["FORGEPLAY_SYNCHRONIZATION_SELECTION"] = WineSynchronizationSelection.automatic.rawValue
        environment["FORGEPLAY_SYNCHRONIZATION_BACKEND"] = WineSynchronizationBackend.server.rawValue
    }

    private static func forgePlaySteamLauncherExecutable(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(executable),
              let wineRoot = wineRootDirectory(for: executable) else {
            return nil
        }
        let candidate = wineRoot.appending(
            path: "lib/wine/x86_64-windows/forgeplay-steam-launcher.exe"
        )
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager) else {
            return nil
        }
        return candidate
    }

    private static func wineserverExecutable(for executable: URL) -> URL? {
        if ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(executable) {
            return nil
        }
        let candidates: [URL]
        if let binDirectory = wineBinDirectory(for: executable) {
            candidates = [binDirectory.appending(path: "wineserver")]
        } else if let contents = bundleContentsDirectory(for: executable) {
            candidates = [
                contents.appending(path: "SharedSupport/wine/bin/wineserver"),
                contents.appending(path: "Resources/wine/bin/wineserver")
            ]
        } else {
            candidates = []
        }
        return candidates.first {
            FileSystemItemPolicy.isRegularNonSymlinkFile($0) &&
                FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func bundleContentsDirectory(for executable: URL) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let contentsIndex = components.lastIndex(of: "Contents") else { return nil }
        let contents = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...contentsIndex])))
        return FileSystemItemPolicy.isNonSymlinkDirectory(contents) ? contents : nil
    }

    private static func mergedPathList(_ paths: [String], existing: String?) -> String {
        var merged = deduplicated(paths)
        if let existing, !existing.isEmpty {
            merged.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        return deduplicated(merged).joined(separator: ":")
    }

    private nonisolated static let direct3DDLLOverrideGroup = [
        "d3d8",
        "d3d9",
        "d3d10",
        "d3d10_1",
        "d3d10core",
        "d3d11",
        "dxgi",
        "d3d12",
        "d3d12core"
    ].joined(separator: ",")

    nonisolated static let rendererBridgeDLLNames: Set<String> = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
        "d3d12.dll",
        "d3d12core.dll",
        "nvapi64.dll",
        "nvngx.dll",
        "nvngx-on-metalfx.dll",
        "winemetal.dll"
    ]

    private nonisolated static let rendererWindowsModuleDirectoryMappings: [(windowsDirectory: String, rendererDirectory: String)] = [
        ("system32", "x86_64-windows"),
        ("syswow64", "i386-windows")
    ]

    private static func mergedWineDLLOverrides(_ override: String, existing: String?) -> String {
        var values = [override]
        if let existing, !existing.isEmpty {
            values.append(contentsOf: existing.split(separator: ";").map(String.init))
        }
        return deduplicated(values).joined(separator: ";")
    }

    private nonisolated static let defaultExecutableSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private nonisolated static let gameRendererUnsetValue = "__FORGEPLAY_UNSET__"

    private nonisolated static let gameRendererUnixEnvironmentKeys = [
        "WINEDLLOVERRIDES",
        "WINEDLLPATH",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "D3DMETAL_FRAMEWORK_PATH",
        "D3DMETAL_SHARED_LIBRARY",
        "D3DM_WINE_UNIX_CALL",
        "VK_ICD_FILENAMES",
        "VK_DRIVER_FILES",
        "DXVK_LOG_PATH",
        "DXVK_LOG_LEVEL",
        "DXVK_CONFIG"
    ]

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where !value.isEmpty && seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }

    private static func deduplicated(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for value in values {
            let path = value.standardizedFileURL.path
            if seen.insert(path).inserted {
                output.append(value)
            }
        }
        return output
    }

    private static func logPair(in directory: URL, name: String) -> (stdout: URL, stderr: URL) {
        let stamp = logTimestampFormatter.string(from: Date())
        let safeName = PathManager.sanitizedFileName(name)
        let uniqueID = UUID().uuidString
        return (
            directory.appending(path: "\(stamp)_\(safeName)_\(uniqueID)_stdout.log"),
            directory.appending(path: "\(stamp)_\(safeName)_\(uniqueID)_stderr.log")
        )
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

extension ProcessRunResult {
    /// A process exit status exists only when the operating system actually
    /// started the command and reported one. Preflight/spawn failures keep a
    /// raw compatibility slot but must never present or persist it as real.
    var processExitCode: Int32? {
        hasProcessExitCode ? exitCode : nil
    }

    var diagnosticExitCodeDescription: String {
        processExitCode.map(String.init) ??
            "unavailable (the process did not produce an exit status)"
    }

    var diagnosticForgePlayStatusDescription: String {
        forgePlayStatusCode.map(String.init) ?? "none"
    }

    var diagnosticTerminationSignalDescription: String {
        guard let terminationSignal else { return "none" }
        let name: String
        switch terminationSignal {
        case SIGABRT: name = "SIGABRT"
        case SIGBUS: name = "SIGBUS"
        case SIGFPE: name = "SIGFPE"
        case SIGILL: name = "SIGILL"
        case SIGINT: name = "SIGINT"
        case SIGKILL: name = "SIGKILL"
        case SIGSEGV: name = "SIGSEGV"
        case SIGTERM: name = "SIGTERM"
        default: name = "signal"
        }
        return "\(name) (\(terminationSignal))"
    }

    var succeeded: Bool {
        if let postconditionSatisfied {
            return postconditionSatisfied
        }
        guard !didTimeOut else { return false }
        if let forgePlayStatusCode {
            return forgePlayStatusCode == 0
        }
        if outcome == .runningDetached {
            return true
        }
        return processExitCode == 0
    }

    var preferredDiagnosticLog: URL {
        let candidates = [diagnosticLog, Optional(stderrLog), Optional(stdoutLog), runEvidenceLog]
            .compactMap { $0 }
        return candidates.first(where: forgePlayDiagnosticLogIsNonEmptyRegularFile) ??
            runEvidenceLog ?? diagnosticLog ?? stderrLog
    }

    var diagnosticSourceLogs: [URL] {
        var logs: [URL]
        if let diagnosticLog {
            logs = [diagnosticLog, stderrLog, stdoutLog]
        } else {
            logs = [stdoutLog, stderrLog]
        }
        if let runEvidenceLog {
            logs.append(runEvidenceLog)
        }
        return logs
    }
}

private func forgePlayDiagnosticLogIsNonEmptyRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    ),
    values.isRegularFile == true,
    values.isSymbolicLink != true,
    let fileSize = values.fileSize else {
        return false
    }
    return fileSize > 0
}
