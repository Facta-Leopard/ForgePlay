import Foundation

struct SteamInstallResult: Hashable {
    var processResult: ProcessRunResult
    var steamExecutableURL: URL
    var hasSteamExecutable: Bool
    var hadSteamExecutableBeforeInstall: Bool
    var didObserveSteamExecutableMutation: Bool
    var compatibilityPreparationWarning: String? = nil

    var installationVerified: Bool {
        processResult.succeeded &&
            hasSteamExecutable &&
            (!hadSteamExecutableBeforeInstall || didObserveSteamExecutableMutation)
    }
}

enum WindowsSteamInstallationLayout {
    static func executable(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
    }

    static func configuration(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.cfg")
    }

    static func steamCfgPinPresent(in prefix: URL, fileManager: FileManager = .default) -> Bool {
        let steamConfiguration = configuration(in: prefix)
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(steamConfiguration, fileManager: fileManager),
              let data = try? Data(contentsOf: steamConfiguration),
              data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("BootStrapperInhibitAll=enable") &&
            text.contains("BootStrapperForceSelfUpdate=disable")
    }
}

/// Diagnostic boundary for processes launched from another macOS app bundle.
/// ForgePlay never uses such an executable as its runtime; observing one during
/// a conformance run is recorded as foreign-process contamination.
enum ExternalApplicationRunnerPolicy {
    static func isUnsupportedRunnerExecutable(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager),
              fileManager.isExecutableFile(atPath: url.path),
              containingApplicationBundle(for: url, fileManager: fileManager) != nil else {
            return false
        }
        return !ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(url)
    }

    static func containingApplicationBundle(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let bundleIndex = components.lastIndex(where: {
            $0.lowercased().hasSuffix(".app")
        }), bundleIndex > 0 else {
            return nil
        }
        let bundle = URL(
            fileURLWithPath: NSString.path(withComponents: Array(components[0...bundleIndex])),
            isDirectory: true
        )
        guard FileSystemItemPolicy.isNonSymlinkDirectory(bundle, fileManager: fileManager) else {
            return nil
        }
        return bundle
    }
}

struct SteamLaunchTarget: Hashable, Sendable {
    var expectedRunnerPath: URL
    var expectedPrefixPath: URL
    var expectedSteamExecutablePath: URL
    var allowHostSteam: Bool = false

    var normalizedRunnerPath: String {
        expectedRunnerPath.standardizedFileURL.path
    }

    var normalizedRunnerDirectoryPath: String {
        expectedRunnerPath.deletingLastPathComponent().standardizedFileURL.path
    }

    var normalizedRunnerWineRootPath: String {
        expectedRunnerPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path
    }

    var normalizedPrefixPath: String {
        expectedPrefixPath.standardizedFileURL.path
    }

    var normalizedSteamExecutablePath: String {
        expectedSteamExecutablePath.standardizedFileURL.path
    }
}

enum SteamWebHelperLaunchPolicy {
    static let executableName = "steamwebhelper.exe"
    static let requiredArguments = ["--no-sandbox", "--in-process-gpu", "--disable-gpu"]

    static func commandLineContainsRequiredArguments(_ commandLine: String) -> Bool {
        let arguments = Set(commandLine.split(whereSeparator: \.isWhitespace).map(String.init))
        return requiredArguments.allSatisfy(arguments.contains)
    }
}

enum SteamGameCEFBrowserLaunchPolicy {
    static let environmentKey = "FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED"
    static let enabledValue = "1"
    static let requiredArgument = "--in-process-gpu"
}

enum SteamLaunchGateStatus: String, Codable, Hashable, Sendable {
    case success = "SUCCESS"
    case launched = "LAUNCHED"
    case failed = "FAILED"
    case blocked = "BLOCKED"
    case deferred = "DEFERRED"
}

enum SteamLaunchVerificationMode: Hashable, Sendable {
    case operational
    case conformance

    var requiresVisibleUIEvidence: Bool {
        self == .conformance
    }
}

enum SteamLaunchGateReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case blockedRunnerPreflightFailed = "blocked-runner-preflight-failed"
    case blockedMissingWineFreetypeRuntime = "blocked-missing-wine-freetype-runtime"
    case blockedRunnerMissing = "blocked-runner-missing"
    case blockedPrefixHeldByStaleProcess = "blocked-prefix-held-by-stale-process"
    case blockedHostSteamRunning = "blocked-host-steam-running"
    case blockedExternalApplicationRunner = "blocked-external-application-runner"
    case blockedSupplementalDMGIsNotRuntime = "blocked-supplemental-renderer-is-not-runtime"
    case failedLaunchCommand = "failed-launch-command"
    case failedSteamCrashDumpCreated = "failed-steam-crash-dump-created"
    case failedSteamAccessViolation = "failed-steam-access-violation"
    case failedExpectedPrefixNotObserved = "failed-expected-prefix-not-observed"
    case failedWebHelperCommandLineMissing = "failed-webhelper-commandline-missing"
    case failedWebHelperLaunchPolicyMissing = "failed-webhelper-launch-policy-missing"
    case failedSteamUIStartup = "failed-steam-ui-startup"
    case failedVisibleUINotVerified = "failed-visible-ui-not-verified"
    case failedHostSteamContamination = "failed-host-steam-contamination"
    case failedExternalRunnerContamination = "failed-external-runner-contamination"
    case steamBootstrapUpdateInProgress = "steam-bootstrap-update-in-progress"
    case operationalProcessEvidenceUnavailable = "operational-process-evidence-unavailable"

    var diagnosticMessage: String {
        switch self {
        case .blockedRunnerPreflightFailed:
            "runner preflight failed before Windows Steam launch"
        case .blockedMissingWineFreetypeRuntime:
            "Wine-root FreeType runtime is missing; Steam launch was not attempted"
        case .blockedRunnerMissing:
            "expected runner path is missing or not executable"
        case .blockedPrefixHeldByStaleProcess:
            "expected WINEPREFIX is held by an existing process"
        case .blockedHostSteamRunning:
            "macOS Steam.app process is running in pure validation mode"
        case .blockedExternalApplicationRunner:
            "an unsupported external app-bundled runner is running or selected in pure validation mode"
        case .blockedSupplementalDMGIsNotRuntime:
            "Apple supplemental renderer input is not the bundled runtime executable"
        case .failedLaunchCommand:
            "launch command did not succeed"
        case .failedSteamCrashDumpCreated:
            "Steam crash dump was created during this run"
        case .failedSteamAccessViolation:
            "Steam crash dump reports 0xC0000005 access violation"
        case .failedExpectedPrefixNotObserved:
            "expected WINEPREFIX was not observed with steam.exe or steamwebhelper.exe in same-run launch evidence"
        case .failedWebHelperCommandLineMissing:
            "Steam WebHelper command line evidence for the expected prefix is missing"
        case .failedWebHelperLaunchPolicyMissing:
            "Steam WebHelper same-run command line is missing the required ForgePlay launch policy arguments"
        case .failedSteamUIStartup:
            "Steam WebHelper shared UI context did not start after one automatic prefix restart"
        case .failedVisibleUINotVerified:
            "screen-final.png visual evidence did not verify Windows Steam login, Steam Guard, or Library UI"
        case .failedHostSteamContamination:
            "macOS Steam.app process was present in the launch window"
        case .failedExternalRunnerContamination:
            "a foreign macOS application runtime process was present in the launch window"
        case .steamBootstrapUpdateInProgress:
            "Steam bootstrap update is still in progress; UI verification is deferred"
        case .operationalProcessEvidenceUnavailable:
            "Steam launch command succeeded, but live process evidence was unavailable; UI verification is deferred without stopping Steam"
        }
    }
}

struct SteamLaunchGateAssessment: Hashable, Sendable {
    var status: SteamLaunchGateStatus
    var reasonCodes: [SteamLaunchGateReasonCode]
    var details: [String] = []

    var diagnosticReasons: [String] {
        let codeLines = reasonCodes.map { "\($0.rawValue): \($0.diagnosticMessage)" }
        return codeLines + details
    }
}

struct SteamLaunchHardGateManifest: Codable, Hashable {
    struct Target: Codable, Hashable {
        var app: String
        var runner: String
        var wineprefix: String
        var steamExe: String

        enum CodingKeys: String, CodingKey {
            case app
            case runner
            case wineprefix
            case steamExe = "steam_exe"
        }
    }

    struct Evidence: Codable, Hashable {
        var diagnosticsLog: String
        var stderrLog: String
        var stdoutLog: String
        var evidenceDirectory: String
        var dumpsBefore: [String]
        var dumpsAfter: [String]
        var webhelperCommandLine: [String]
        var screenshots: [String]

        enum CodingKeys: String, CodingKey {
            case diagnosticsLog = "diagnostics_log"
            case stderrLog = "stderr_log"
            case stdoutLog = "stdout_log"
            case evidenceDirectory = "evidence_dir"
            case dumpsBefore = "dumps_before"
            case dumpsAfter = "dumps_after"
            case webhelperCommandLine = "webhelper_command_line"
            case screenshots
        }
    }

    var runID: String
    var status: SteamLaunchGateStatus
    var reasonCodes: [SteamLaunchGateReasonCode]
    var target: Target
    var evidence: Evidence
    var expectedRunner: String
    var actualRunnerProcesses: [String]
    var expectedPrefix: String
    var observedSteamProcesses: [String]
    var observedWebhelperProcesses: [String]
    var hostMacOSSteamContamination: Bool
    var externalRunnerContamination: Bool
    var unsupportedExternalRunnerDetected: Bool
    var webhelperCommandLineCaptured: Bool
    var windowsSteamUIVisible: Bool
    var steamUISurface: SteamUISurface?
    var screenshotPath: String?
    var newCrashDumpCount: Int
    var newAssertDumpCount: Int
    var steamCfgPinPresent: Bool
    var steamLaunchArgs: [String]

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case reasonCodes = "reason_codes"
        case target
        case evidence
        case expectedRunner = "expected_runner"
        case actualRunnerProcesses = "actual_runner_processes"
        case expectedPrefix = "expected_prefix"
        case observedSteamProcesses = "observed_steam_processes"
        case observedWebhelperProcesses = "observed_webhelper_processes"
        case hostMacOSSteamContamination = "host_macos_steam_contamination"
        case externalRunnerContamination = "external_runner_contamination"
        case unsupportedExternalRunnerDetected = "unsupported_external_runner_detected"
        case webhelperCommandLineCaptured = "webhelper_command_line_captured"
        case windowsSteamUIVisible = "windows_steam_ui_visible"
        case steamUISurface = "steam_ui_surface"
        case screenshotPath = "screenshot_path"
        case newCrashDumpCount = "new_crash_dump_count"
        case newAssertDumpCount = "new_assert_dump_count"
        case steamCfgPinPresent = "steam_cfg_pin_present"
        case steamLaunchArgs = "steam_launch_args"
    }
}

enum SteamRendererPolicyRecoveryKind: Hashable {
    case applyPolicy
    case repairPolicy
    case runtimeUnavailable
}

struct SteamLibraryDriveMapping: Hashable {
    var driveLetter: String
    var macDriveRootURL: URL
    var macLibraryURL: URL
    var windowsLibraryPath: String

    init(
        driveLetter: String,
        macLibraryURL: URL,
        windowsLibraryPath: String,
        macDriveRootURL: URL? = nil
    ) {
        self.driveLetter = driveLetter
        self.macDriveRootURL = macDriveRootURL ?? macLibraryURL
        self.macLibraryURL = macLibraryURL
        self.windowsLibraryPath = windowsLibraryPath
    }
}

/// One macOS folder authorization can contain one or more Steam libraries.
/// The Wine drive must target the user-authorized root directly; Steam then
/// receives the real library's relative Windows path within that drive.
struct SteamLibraryDriveSource: Hashable {
    var authorizedRootURL: URL
    var libraryURL: URL
}

struct SteamRendererPolicyInspection: Hashable {
    var selection: SteamRendererPolicySelection
    var resolvedPolicy: SteamRendererPolicyPreference?
    var status: CheckStatus
    var userMessage: String
    var appliedModules: [String]
    var missingModules: [String]
    var mixedModules: [String]
    var appliedProfileOverrides: [String] = []
    var missingProfileOverrides: [String] = []
    var staleProfileOverrides: [String] = []
    var appliedSteamClientFiles: [String] = []
    var missingSteamClientFiles: [String] = []
    var staleSteamClientFiles: [String] = []
    var recoveryKind: SteamRendererPolicyRecoveryKind? = nil

    var effectiveRecoveryKind: SteamRendererPolicyRecoveryKind {
        if let recoveryKind {
            return recoveryKind
        }
        if status == .error || !mixedModules.isEmpty {
            return .repairPolicy
        }
        return .applyPolicy
    }

    var requiresRepair: Bool {
        effectiveRecoveryKind == .repairPolicy
    }

    var requiresApply: Bool {
        effectiveRecoveryKind == .applyPolicy && status == .warning && (
            !missingModules.isEmpty ||
            !missingProfileOverrides.isEmpty ||
            !staleProfileOverrides.isEmpty ||
            !missingSteamClientFiles.isEmpty ||
            !staleSteamClientFiles.isEmpty
        )
    }

    var allowsRecoveryAction: Bool {
        status != .ok && effectiveRecoveryKind != .runtimeUnavailable
    }

    var recoveryStatusLabelKey: String {
        switch effectiveRecoveryKind {
        case .applyPolicy:
            "Steam 실행 경로 적용 필요"
        case .repairPolicy:
            "Steam 실행 경로 정비 필요"
        case .runtimeUnavailable:
            "ForgePlay Runtime 교체 필요"
        }
    }

    var recoveryActionTitleKey: String {
        switch effectiveRecoveryKind {
        case .applyPolicy:
            "실행 경로 적용/검증"
        case .repairPolicy:
            "실행 경로 정비/검증"
        case .runtimeUnavailable:
            "Runtime 확인"
        }
    }

    var setupRecoveryActionTitleKey: String {
        switch effectiveRecoveryKind {
        case .applyPolicy:
            "Steam 실행 경로 적용"
        case .repairPolicy:
            "Steam 실행 경로 정비"
        case .runtimeUnavailable:
            "Runtime 확인"
        }
    }
}

enum SteamUIVerificationState: String, Codable, CaseIterable, Hashable {
    case notRun
    case launchedButUnverified
    case rendered
    case blackScreenSuspected
    case failed

    static func inferred(from result: ProcessRunResult) -> SteamUIVerificationState {
        if let explicitState = result.steamUIVerificationState {
            return explicitState
        }
        if result.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
            return .launchedButUnverified
        }
        if result.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode {
            return .launchedButUnverified
        }
        if result.forgePlayStatusCode == SteamManager.steamRenderingFailureExitCode {
            return .blackScreenSuspected
        }
        guard result.succeeded else {
            return .failed
        }
        return .launchedButUnverified
    }
}

enum SteamInstallError: LocalizedError, Equatable {
    case invalidInstaller(URL)
    case installerMetadataReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidInstaller(let url):
            "Steam 공식 페이지에서 받은 일반 파일 SteamSetup.exe를 선택해야 합니다: \(url.path)"
        case .installerMetadataReadFailed(let url, let message):
            "Steam 설치 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        }
    }
}

enum SteamLaunchError: LocalizedError {
    case prefixShutdownFailed(ProcessRunResult)
    case rendererBridgeInstallFailed(URL, String)
    case rendererPolicyUnavailable(String)
    case rendererPolicyVerificationFailed(String)
    case steamClientCompatibilityFileInstallFailed(URL, String)
    case steamClientCompatibilitySetupFailed(ProcessRunResult)
    case steamClientCompatibilityVerificationFailed(String)
    case steamExecutableUnavailable(URL)
    case steamExecutableMetadataReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .prefixShutdownFailed(let result):
            "Windows용 Steam 실행 전에 기존 ForgePlay Runtime 프로세스를 정리하지 못했습니다. \(Self.processFailureDetail(result))"
        case .rendererBridgeInstallFailed(let url, let message):
            "게임 렌더러 payload 파일을 Steam 프리픽스에 준비하지 못했습니다: \(url.path). \(message)"
        case .rendererPolicyUnavailable(let message):
            message
        case .rendererPolicyVerificationFailed(let message):
            message
        case .steamClientCompatibilityFileInstallFailed(let url, let message):
            "Windows용 Steam 호환성 파일을 적용하지 못했습니다: \(url.path). \(message)"
        case .steamClientCompatibilitySetupFailed(let result):
            "Windows용 Steam 호환성 설정을 Steam 프리픽스에 적용하지 못했습니다. \(Self.processFailureDetail(result))"
        case .steamClientCompatibilityVerificationFailed(let detail):
            "Windows용 Steam 호환성 설정을 적용한 뒤 검증에 실패했습니다: \(detail)"
        case .steamExecutableUnavailable(let url):
            "Windows용 Steam 실행 파일을 찾지 못했거나 안전한 일반 파일이 아닙니다. SteamSetup.exe를 Steam 프리픽스 안에 먼저 설치하세요: \(url.path)"
        case .steamExecutableMetadataReadFailed(let url, let message):
            "Windows용 Steam 실행 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        }
    }

    private static func processFailureDetail(_ result: ProcessRunResult) -> String {
        let timeout = result.didTimeOut ? ", 시간 초과" : ""
        let processIdentifier = result.processIdentifier.map(String.init) ?? "unavailable"
        return "실패 작업: \(result.actionName), 프로세스 PID: \(processIdentifier), 프로세스 종료 코드: \(result.diagnosticExitCodeDescription), 종료 신호: \(result.diagnosticTerminationSignalDescription), ForgePlay 상태 코드: \(result.diagnosticForgePlayStatusDescription)\(timeout), 로그: \(result.preferredDiagnosticLog.path)"
    }
}

enum SteamLibraryScanError: LocalizedError, Equatable {
    case scanFailed(URL, String)
    case metadataReadFailed(URL, String)
    case fileReadFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .scanFailed(let url, let message):
            "Steam 라이브러리 폴더를 검사하지 못했습니다: \(url.path). \(message)"
        case .metadataReadFailed(let url, let message):
            "Steam 라이브러리 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .fileReadFailed(let url, let message):
            "Steam 라이브러리 파일을 읽지 못했습니다: \(url.path). \(message)"
        }
    }
}

enum SteamLibraryDriveBridgeError: LocalizedError, Equatable {
    case dosdevicesUnavailable(URL)
    case libraryRootUnavailable(URL)
    case noAvailableDriveLetter(URL)
    case driveLetterOccupied(URL)
    case libraryFoldersUnavailable(URL)
    case libraryFoldersInvalid(URL, String)
    case libraryFoldersWriteFailed(URL, String)
    case bridgeDirectoryUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .dosdevicesUnavailable(let url):
            "Steam 라이브러리 드라이브를 연결할 수 없습니다. 프리픽스 dosdevices 폴더를 확인하세요: \(url.path)"
        case .libraryRootUnavailable(let url):
            "Steam 라이브러리 폴더가 안전한 일반 폴더가 아닙니다: \(url.path)"
        case .noAvailableDriveLetter(let url):
            "Steam 라이브러리 폴더에 배정할 Windows 드라이브 문자가 부족합니다: \(url.path)"
        case .driveLetterOccupied(let url):
            "Steam 라이브러리 드라이브 문자가 이미 다른 항목으로 사용 중입니다: \(url.path)"
        case .libraryFoldersUnavailable(let url):
            "Windows용 Steam 라이브러리 설정 폴더를 사용할 수 없습니다: \(url.path)"
        case .libraryFoldersInvalid(let url, let message):
            "Windows용 Steam 라이브러리 설정을 읽거나 검증하지 못했습니다: \(url.path). \(message)"
        case .libraryFoldersWriteFailed(let url, let message):
            "외장 Steam 라이브러리를 Windows용 Steam에 등록하지 못했습니다: \(url.path). \(message)"
        case .bridgeDirectoryUnavailable(let url):
            "외장 Steam 라이브러리용 Windows 드라이브 브리지를 만들 수 없습니다: \(url.path)"
        }
    }
}
