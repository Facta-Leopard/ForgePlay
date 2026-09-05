import Foundation
import Observation
import SwiftData
import SwiftUI

enum AppNoticeKind: String {
    case progress
    case success
    case warning
    case failure

    var symbolName: String {
        switch self {
        case .progress: "hourglass"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    var status: CheckStatus {
        switch self {
        case .progress: .unknown
        case .success: .ok
        case .warning: .warning
        case .failure: .error
        }
    }
}

struct SteamLibrarySelectionAuthorization {
    var roots: [URL]
    var bookmarksByPath: [String: Data]
}

struct SteamStorageSelectionAuthorization {
    var root: URL
    var bookmark: Data?
}

enum SteamStorageMountMutationError: Error, Equatable {
    case mountNotFound(String)
    case persistenceVerificationFailed(String)
    case persistenceRecoveryFailed(
        originalFailure: String,
        recoveryFailure: String
    )
}

private struct SteamStorageMountPersistenceSnapshot {
    var id: String
    var path: String
    var bookmark: Data?
    var createdAt: Date
    var updatedAt: Date

    init(record: SteamStorageMountRecord) {
        id = record.id
        path = record.path
        bookmark = record.bookmark
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    func apply(to record: SteamStorageMountRecord) {
        record.path = path
        record.bookmark = bookmark
        record.createdAt = createdAt
        record.updatedAt = updatedAt
    }

    func makeRecord() -> SteamStorageMountRecord {
        let record = SteamStorageMountRecord(
            id: id,
            path: path,
            bookmark: bookmark,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        // Preserve the exact stored representation as well as its normalized
        // identity; legacy rows may contain harmless `/.` components.
        record.path = path
        return record
    }

    func matches(_ record: SteamStorageMountRecord) -> Bool {
        record.id == id &&
            record.path == path &&
            record.bookmark == bookmark &&
            record.createdAt == createdAt &&
            record.updatedAt == updatedAt
    }
}

private struct SteamGamePersistenceSnapshot {
    var steamAppId: String
    var name: String
    var installDir: String
    var libraryPath: String
    var manifestPath: String
    var sizeOnDisk: Int64
    var lastUpdated: Date?
    var lastLaunchStatus: String?
    var graphicsBackendSelection: String?
    var libraryBookmark: Data?

    init(record: SteamGameRecord) {
        steamAppId = record.steamAppId
        name = record.name
        installDir = record.installDir
        libraryPath = record.libraryPath
        manifestPath = record.manifestPath
        sizeOnDisk = record.sizeOnDisk
        lastUpdated = record.lastUpdated
        lastLaunchStatus = record.lastLaunchStatus
        graphicsBackendSelection = record.graphicsBackendSelection
        libraryBookmark = record.libraryBookmark
    }

    func apply(to record: SteamGameRecord) {
        record.name = name
        record.installDir = installDir
        record.libraryPath = libraryPath
        record.manifestPath = manifestPath
        record.sizeOnDisk = sizeOnDisk
        record.lastUpdated = lastUpdated
        record.lastLaunchStatus = lastLaunchStatus
        record.graphicsBackendSelection = graphicsBackendSelection
        record.libraryBookmark = libraryBookmark
    }

    func makeRecord() -> SteamGameRecord {
        SteamGameRecord(
            steamAppId: steamAppId,
            name: name,
            installDir: installDir,
            libraryPath: libraryPath,
            manifestPath: manifestPath,
            sizeOnDisk: sizeOnDisk,
            lastUpdated: lastUpdated,
            lastLaunchStatus: lastLaunchStatus,
            graphicsBackendSelection: graphicsBackendSelection,
            libraryBookmark: libraryBookmark
        )
    }

    func matches(_ record: SteamGameRecord) -> Bool {
        record.steamAppId == steamAppId &&
            record.name == name &&
            record.installDir == installDir &&
            record.libraryPath == libraryPath &&
            record.manifestPath == manifestPath &&
            record.sizeOnDisk == sizeOnDisk &&
            record.lastUpdated == lastUpdated &&
            record.lastLaunchStatus == lastLaunchStatus &&
            record.graphicsBackendSelection == graphicsBackendSelection &&
            record.libraryBookmark == libraryBookmark
    }
}

struct AppNotice: Identifiable, Hashable {
    let id = UUID()
    var message: String
    var kind: AppNoticeKind
    var logURL: URL?
}

private struct AppNoticeFailureEvidenceError: LocalizedError {
    var message: String

    var errorDescription: String? { message }
}

private struct GameInputProtectionFailureNoticeBinding {
    let lossNoticeIdentifier: UUID
    let evidenceURL: URL?
}

private struct PersistedFileSelectionLoadResult {
    var url: URL?
    var refreshedBookmark: Data?
}

#if DEBUG
enum ForgePlayDevelopmentFixturePaths {
    static let appStoreScreenshotRootPath = "/Sample Games/ForgePlay Library"
    static let appStoreScreenshotRuntimeExecutablePath =
        "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"
}
#endif

@MainActor
@Observable
final class AppState {
    var selectedSection: AppSection = .dashboard
    var setupStage: SetupStage = .chooseRoot
    var selectedRootURL: URL?
    /// Session-scoped diagnostic context. Keep a detached value snapshot
    /// instead of retaining a SwiftData row that a library rescan may delete.
    var selectedSteamReference: SteamGame?
    var activeDiagnostics: [DiagnosticResult] = []
    var latestChecks: [SystemCheckResult] = []
    var setupReadiness: SetupReadiness = .empty
    var currentTaskMessage: String?
    var currentNotice: AppNotice?
    var presentedSheet: SheetDestination?

    var systemCheckSummary: SystemCheckSummary {
        SystemCheckSummary(results: latestChecks)
    }
    var themeMode: ForgePlayThemeMode = .system
    var languageMode: ForgePlayLanguageMode = .system
    var steamRendererPolicySelection: SteamRendererPolicySelection = .d3dMetalNVIDIA
    var wineSynchronizationSelection: WineSynchronizationSelection = .automatic
    var steamVideoMemorySelection: SteamVideoMemorySelection = .automatic
    var isGameInputModifierMappingEnabled = false
    var gameInputCommandBinding: GameInputModifierBinding = .control
    var gameInputOptionBinding: GameInputModifierBinding = .alt
    var gameInputControlBinding: GameInputModifierBinding = .control
    var blocksGameAppWindowManagementShortcuts = false
    var blocksGameAppSwitchingShortcuts = false
    var blocksGameMissionControlSpaceShortcuts = false
    var blocksGameScreenshotShortcuts = false
    var hidesPointerWhileManagedGameFrontmost = true
    var isSteamLaunchInProgress = false
    var isAdvancedModeEnabled = false
    var isLLMDiagnosticsEnabled = false
    var isLogAutoCleanupEnabled = true
    var logRetentionDays = 30
    var launchLogLimit = 20
    private(set) var steamStorageOperationMountID: String?
    var runtimeExecutableURL: URL?
    var steamInstallerURL: URL?
    var lastSupportBundleURL: URL?
    var lastFailureEvidenceURL: URL?
    #if DEBUG
    var debugLanguageModeOverride: ForgePlayLanguageMode?
    var debugDynamicTypeSize: DynamicTypeSize?
    var debugDiagnosticsPreviewFixture = false
    var debugSteamLaunchLayoutFixture = false
    var debugAppStoreScreenshotFixture = false
    var debugShouldResetLanguageToSystemAfterLaunch = false
    var debugShouldDismissPresentedSheetAfterLaunch = false
    #endif
    @ObservationIgnored private var retainedSecurityScopedURLs: [PersistedFileSelectionRole: URL] = [:]
    @ObservationIgnored private var retainedSteamLibrarySecurityScopedURLs: [String: URL] = [:]
    @ObservationIgnored private var pendingBookmarkReplacementRoles: Set<PersistedFileSelectionRole> = []
    @ObservationIgnored private var languageModeOverrideSource: AppLanguageModeOverrideSource?
    @ObservationIgnored private var hasLoadedPersistentSettings = false
    @ObservationIgnored private var failureDiagnosticEvidenceService: FailureDiagnosticEvidenceService?
    @ObservationIgnored private var failureDiagnosticPathManager: PathManager?
    @ObservationIgnored private var steamStorageConnectionTask: Task<Void, Never>?
    @ObservationIgnored private var gameInputProtectionFailureNoticeBindings:
        [GameInputProtectionSessionIdentity:
            GameInputProtectionFailureNoticeBinding] = [:]

    private struct PersistentLoadStateSnapshot {
        var selectedRootURL: URL?
        var runtimeExecutableURL: URL?
        var steamInstallerURL: URL?
        var themeMode: ForgePlayThemeMode
        var languageMode: ForgePlayLanguageMode
        var languageModeOverrideSource: AppLanguageModeOverrideSource?
        var steamRendererPolicySelection: SteamRendererPolicySelection
        var wineSynchronizationSelection: WineSynchronizationSelection
        var steamVideoMemorySelection: SteamVideoMemorySelection
        var isGameInputModifierMappingEnabled: Bool
        var gameInputCommandBinding: GameInputModifierBinding
        var gameInputOptionBinding: GameInputModifierBinding
        var gameInputControlBinding: GameInputModifierBinding
        var blocksGameAppWindowManagementShortcuts: Bool
        var blocksGameAppSwitchingShortcuts: Bool
        var blocksGameMissionControlSpaceShortcuts: Bool
        var blocksGameScreenshotShortcuts: Bool
        var hidesPointerWhileManagedGameFrontmost: Bool
        var isAdvancedModeEnabled: Bool
        var isLLMDiagnosticsEnabled: Bool
        var isLogAutoCleanupEnabled: Bool
        var logRetentionDays: Int
        var launchLogLimit: Int
        var hasLoadedPersistentSettings: Bool
        var pendingBookmarkReplacementRoles: Set<PersistedFileSelectionRole>
    }

    private struct UserPreferenceSnapshot {
        var themeMode: ForgePlayThemeMode
        var languageMode: ForgePlayLanguageMode
        var languageModeOverrideSource: AppLanguageModeOverrideSource?
        var steamRendererPolicySelection: SteamRendererPolicySelection
        var wineSynchronizationSelection: WineSynchronizationSelection
        var steamVideoMemorySelection: SteamVideoMemorySelection
        var isGameInputModifierMappingEnabled: Bool
        var gameInputCommandBinding: GameInputModifierBinding
        var gameInputOptionBinding: GameInputModifierBinding
        var gameInputControlBinding: GameInputModifierBinding
        var blocksGameAppWindowManagementShortcuts: Bool
        var blocksGameAppSwitchingShortcuts: Bool
        var blocksGameMissionControlSpaceShortcuts: Bool
        var blocksGameScreenshotShortcuts: Bool
        var hidesPointerWhileManagedGameFrontmost: Bool
        var isAdvancedModeEnabled: Bool
        var isLLMDiagnosticsEnabled: Bool
        #if DEBUG
        var debugLanguageModeOverride: ForgePlayLanguageMode?
        #endif
    }

    private struct PersistedUserPreferenceSnapshot {
        var themeMode: String
        var languageMode: String?
        var isLanguageModeOverrideEnabled: Bool?
        var languageModeOverrideSource: String?
        var isAdvancedModeEnabled: Bool
        var isLLMDiagnosticsEnabled: Bool
        var llmProvider: String
        var llmBaseURL: String
        var llmModel: String
        var steamGraphicsBackendSelection: String?
        var wineSynchronizationSelection: String?
        var steamVideoMemorySelection: String?
        var isGameInputModifierMappingEnabled: Bool?
        var gameInputCommandBinding: String?
        var gameInputOptionBinding: String?
        var gameInputControlBinding: String?
        var blocksGameAppWindowManagementShortcuts: Bool?
        var blocksGameAppSwitchingShortcuts: Bool?
        var blocksGameMissionControlSpaceShortcuts: Bool?
        var blocksGameScreenshotShortcuts: Bool?
        var hidesPointerWhileManagedGameFrontmost: Bool?
        var gameInputProtectionPreferenceVersion: Int?
        var updatedAt: Date

        init(settings: AppSettingsRecord) {
            themeMode = settings.themeMode
            languageMode = settings.languageMode
            isLanguageModeOverrideEnabled = settings.isLanguageModeOverrideEnabled
            languageModeOverrideSource = settings.languageModeOverrideSource
            isAdvancedModeEnabled = settings.isAdvancedModeEnabled
            isLLMDiagnosticsEnabled = settings.isLLMDiagnosticsEnabled
            llmProvider = settings.llmProvider
            llmBaseURL = settings.llmBaseURL
            llmModel = settings.llmModel
            steamGraphicsBackendSelection = settings.steamGraphicsBackendSelection
            wineSynchronizationSelection = settings.wineSynchronizationSelection
            steamVideoMemorySelection = settings.steamVideoMemorySelection
            isGameInputModifierMappingEnabled = settings.isGameInputModifierMappingEnabled
            gameInputCommandBinding = settings.gameInputCommandBinding
            gameInputOptionBinding = settings.gameInputOptionBinding
            gameInputControlBinding = settings.gameInputControlBinding
            blocksGameAppWindowManagementShortcuts =
                settings.blocksGameAppWindowManagementShortcuts
            blocksGameAppSwitchingShortcuts = settings.blocksGameAppSwitchingShortcuts
            blocksGameMissionControlSpaceShortcuts =
                settings.blocksGameMissionControlSpaceShortcuts
            blocksGameScreenshotShortcuts = settings.blocksGameScreenshotShortcuts
            hidesPointerWhileManagedGameFrontmost =
                settings.hidesPointerWhileManagedGameFrontmost
            gameInputProtectionPreferenceVersion =
                settings.gameInputProtectionPreferenceVersion
            updatedAt = settings.updatedAt
        }

        func restore(into settings: AppSettingsRecord) {
            settings.themeMode = themeMode
            settings.languageMode = languageMode
            settings.isLanguageModeOverrideEnabled = isLanguageModeOverrideEnabled
            settings.languageModeOverrideSource = languageModeOverrideSource
            settings.isAdvancedModeEnabled = isAdvancedModeEnabled
            settings.isLLMDiagnosticsEnabled = isLLMDiagnosticsEnabled
            settings.llmProvider = llmProvider
            settings.llmBaseURL = llmBaseURL
            settings.llmModel = llmModel
            settings.steamGraphicsBackendSelection = steamGraphicsBackendSelection
            settings.wineSynchronizationSelection = wineSynchronizationSelection
            settings.steamVideoMemorySelection = steamVideoMemorySelection
            settings.isGameInputModifierMappingEnabled = isGameInputModifierMappingEnabled
            settings.gameInputCommandBinding = gameInputCommandBinding
            settings.gameInputOptionBinding = gameInputOptionBinding
            settings.gameInputControlBinding = gameInputControlBinding
            settings.blocksGameAppWindowManagementShortcuts =
                blocksGameAppWindowManagementShortcuts
            settings.blocksGameAppSwitchingShortcuts = blocksGameAppSwitchingShortcuts
            settings.blocksGameMissionControlSpaceShortcuts =
                blocksGameMissionControlSpaceShortcuts
            settings.blocksGameScreenshotShortcuts = blocksGameScreenshotShortcuts
            settings.hidesPointerWhileManagedGameFrontmost =
                hidesPointerWhileManagedGameFrontmost
            settings.gameInputProtectionPreferenceVersion =
                gameInputProtectionPreferenceVersion
            settings.updatedAt = updatedAt
        }
    }

    var isRootConfigured: Bool { selectedRootURL != nil }
    var isRuntimeConfigured: Bool { runtimeExecutableURL != nil }

    var gameInputModifierMap: GameInputModifierMap? {
        guard isGameInputModifierMappingEnabled else { return nil }
        return GameInputModifierMap(
            command: gameInputCommandBinding,
            option: gameInputOptionBinding,
            control: gameInputControlBinding
        )
    }

    var hasEnabledGameInputEventTapProtection: Bool {
        isGameInputModifierMappingEnabled ||
            blocksGameAppWindowManagementShortcuts ||
            blocksGameAppSwitchingShortcuts ||
            blocksGameMissionControlSpaceShortcuts ||
            blocksGameScreenshotShortcuts
    }

    var hasEnabledGameInputProtection: Bool {
        hasEnabledGameInputEventTapProtection ||
            hidesPointerWhileManagedGameFrontmost
    }

    func disableGameInputEventTapProtection() {
        isGameInputModifierMappingEnabled = false
        blocksGameAppWindowManagementShortcuts = false
        blocksGameAppSwitchingShortcuts = false
        blocksGameMissionControlSpaceShortcuts = false
        blocksGameScreenshotShortcuts = false
    }

    var gameInputProtectionSettingsFingerprint: String {
        [
            isGameInputModifierMappingEnabled ? "1" : "0",
            gameInputCommandBinding.rawValue,
            gameInputOptionBinding.rawValue,
            gameInputControlBinding.rawValue,
            blocksGameAppWindowManagementShortcuts ? "1" : "0",
            blocksGameAppSwitchingShortcuts ? "1" : "0",
            blocksGameMissionControlSpaceShortcuts ? "1" : "0",
            blocksGameScreenshotShortcuts ? "1" : "0",
            hidesPointerWhileManagedGameFrontmost ? "1" : "0"
        ].joined(separator: "|")
    }

    func setGameInputModifierBinding(
        _ hostKey: HostModifierKey,
        to binding: GameInputModifierBinding
    ) {
        switch hostKey {
        case .command: gameInputCommandBinding = binding
        case .option: gameInputOptionBinding = binding
        case .control: gameInputControlBinding = binding
        }
    }

    func gameInputModifierBinding(for hostKey: HostModifierKey) -> GameInputModifierBinding {
        switch hostKey {
        case .command: gameInputCommandBinding
        case .option: gameInputOptionBinding
        case .control: gameInputControlBinding
        }
    }

    #if DEBUG
    var retainedSteamLibrarySecurityScopedPathsForTesting: Set<String> {
        Set(retainedSteamLibrarySecurityScopedURLs.keys)
    }
    #endif

    func load(from context: ModelContext) throws {
        let previousState = PersistentLoadStateSnapshot(
            selectedRootURL: selectedRootURL,
            runtimeExecutableURL: runtimeExecutableURL,
            steamInstallerURL: steamInstallerURL,
            themeMode: themeMode,
            languageMode: languageMode,
            languageModeOverrideSource: languageModeOverrideSource,
            steamRendererPolicySelection: steamRendererPolicySelection,
            wineSynchronizationSelection: wineSynchronizationSelection,
            steamVideoMemorySelection: steamVideoMemorySelection,
            isGameInputModifierMappingEnabled: isGameInputModifierMappingEnabled,
            gameInputCommandBinding: gameInputCommandBinding,
            gameInputOptionBinding: gameInputOptionBinding,
            gameInputControlBinding: gameInputControlBinding,
            blocksGameAppWindowManagementShortcuts:
                blocksGameAppWindowManagementShortcuts,
            blocksGameAppSwitchingShortcuts: blocksGameAppSwitchingShortcuts,
            blocksGameMissionControlSpaceShortcuts: blocksGameMissionControlSpaceShortcuts,
            blocksGameScreenshotShortcuts: blocksGameScreenshotShortcuts,
            hidesPointerWhileManagedGameFrontmost:
                hidesPointerWhileManagedGameFrontmost,
            isAdvancedModeEnabled: isAdvancedModeEnabled,
            isLLMDiagnosticsEnabled: isLLMDiagnosticsEnabled,
            isLogAutoCleanupEnabled: isLogAutoCleanupEnabled,
            logRetentionDays: logRetentionDays,
            launchLogLimit: launchLogLimit,
            hasLoadedPersistentSettings: hasLoadedPersistentSettings,
            pendingBookmarkReplacementRoles: pendingBookmarkReplacementRoles
        )
        let previousRetainedURLs = retainedSecurityScopedURLs
        retainedSecurityScopedURLs = [:]
        var didCompleteLoad = false
        defer {
            if didCompleteLoad {
                previousRetainedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
            } else {
                retainedSecurityScopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
                retainedSecurityScopedURLs = previousRetainedURLs
                selectedRootURL = previousState.selectedRootURL
                runtimeExecutableURL = previousState.runtimeExecutableURL
                steamInstallerURL = previousState.steamInstallerURL
                themeMode = previousState.themeMode
                languageMode = previousState.languageMode
                languageModeOverrideSource = previousState.languageModeOverrideSource
                steamRendererPolicySelection = previousState.steamRendererPolicySelection
                wineSynchronizationSelection = previousState.wineSynchronizationSelection
                steamVideoMemorySelection = previousState.steamVideoMemorySelection
                isGameInputModifierMappingEnabled = previousState.isGameInputModifierMappingEnabled
                gameInputCommandBinding = previousState.gameInputCommandBinding
                gameInputOptionBinding = previousState.gameInputOptionBinding
                gameInputControlBinding = previousState.gameInputControlBinding
                blocksGameAppWindowManagementShortcuts =
                    previousState.blocksGameAppWindowManagementShortcuts
                blocksGameAppSwitchingShortcuts =
                    previousState.blocksGameAppSwitchingShortcuts
                blocksGameMissionControlSpaceShortcuts =
                    previousState.blocksGameMissionControlSpaceShortcuts
                blocksGameScreenshotShortcuts = previousState.blocksGameScreenshotShortcuts
                hidesPointerWhileManagedGameFrontmost =
                    previousState.hidesPointerWhileManagedGameFrontmost
                isAdvancedModeEnabled = previousState.isAdvancedModeEnabled
                isLLMDiagnosticsEnabled = previousState.isLLMDiagnosticsEnabled
                isLogAutoCleanupEnabled = previousState.isLogAutoCleanupEnabled
                logRetentionDays = previousState.logRetentionDays
                launchLogLimit = previousState.launchLogLimit
                hasLoadedPersistentSettings = previousState.hasLoadedPersistentSettings
                pendingBookmarkReplacementRoles = previousState.pendingBookmarkReplacementRoles
            }
        }

        let settings = try loadOrCreateSettings(in: context)
        themeMode = ForgePlayThemeMode(rawValue: settings.themeMode) ?? .system
        var didNormalizeSettings = false
        let persistedSource = settings.languageModeOverrideSource
            .flatMap(AppLanguageModeOverrideSource.init(rawValue:))
        if settings.isLanguageModeOverrideEnabled == true,
           persistedSource == .userSettings,
           let persistedLanguage = settings.languageMode.flatMap(ForgePlayLanguageMode.init(rawValue:)),
           persistedLanguage != .system {
            languageMode = persistedLanguage
            languageModeOverrideSource = .userSettings
        } else {
            languageMode = .system
            languageModeOverrideSource = nil
            if settings.languageMode != ForgePlayLanguageMode.system.rawValue ||
                settings.isLanguageModeOverrideEnabled != false ||
                settings.languageModeOverrideSource != nil {
                settings.languageMode = ForgePlayLanguageMode.system.rawValue
                settings.isLanguageModeOverrideEnabled = false
                settings.languageModeOverrideSource = nil
                settings.updatedAt = Date()
                didNormalizeSettings = true
            }
        }
        isAdvancedModeEnabled = settings.isAdvancedModeEnabled
        isLLMDiagnosticsEnabled = settings.isLLMDiagnosticsEnabled
        isLogAutoCleanupEnabled = settings.isLogAutoCleanupEnabled ?? true
        logRetentionDays = min(max(settings.logRetentionDays ?? 30, 1), 365)
        launchLogLimit = min(max(settings.launchLogLimit ?? 20, 1), 200)
        if let persistedRetentionDays = settings.logRetentionDays,
           persistedRetentionDays != logRetentionDays {
            settings.logRetentionDays = logRetentionDays
            settings.updatedAt = Date()
            didNormalizeSettings = true
        }
        if let persistedLaunchLogLimit = settings.launchLogLimit,
           persistedLaunchLogLimit != launchLogLimit {
            settings.launchLogLimit = launchLogLimit
            settings.updatedAt = Date()
            didNormalizeSettings = true
        }
        steamRendererPolicySelection = SteamRendererPolicySelection.persistedValue(
            settings.steamGraphicsBackendSelection
        ).normalizedForCurrentRelease
        wineSynchronizationSelection = .automatic
        if settings.wineSynchronizationSelection != nil {
            settings.wineSynchronizationSelection = nil
            settings.updatedAt = Date()
            didNormalizeSettings = true
        }
        steamVideoMemorySelection = settings.steamVideoMemorySelection
            .flatMap(SteamVideoMemorySelection.init(rawValue:)) ?? .automatic
        if (settings.gameInputProtectionPreferenceVersion ?? 0) <
            GameInputProtectionPreferenceSchema.optInMigrationVersion {
            // Version 1 changes event-tap protection from implicit defaults to
            // explicit opt-in. Existing beta records cannot distinguish a
            // deliberate choice from the old default-on values, so migrate
            // only the permission-requiring switches once and preserve the
            // independent pointer preference.
            settings.isGameInputModifierMappingEnabled = false
            settings.blocksGameAppWindowManagementShortcuts = false
            settings.blocksGameAppSwitchingShortcuts = false
            settings.blocksGameMissionControlSpaceShortcuts = false
            settings.blocksGameScreenshotShortcuts = false
            settings.gameInputProtectionPreferenceVersion =
                max(
                    settings.gameInputProtectionPreferenceVersion ?? 0,
                    GameInputProtectionPreferenceSchema.currentVersion
                )
            settings.updatedAt = Date()
            didNormalizeSettings = true
        }
        let persistedCommandBinding = settings.gameInputCommandBinding
            .flatMap(GameInputModifierBinding.init(rawValue:))
        let persistedOptionBinding = settings.gameInputOptionBinding
            .flatMap(GameInputModifierBinding.init(rawValue:))
        let persistedControlBinding = settings.gameInputControlBinding
            .flatMap(GameInputModifierBinding.init(rawValue:))
        let persistedGameInputBindingsAreAbsent =
            settings.gameInputCommandBinding == nil &&
            settings.gameInputOptionBinding == nil &&
            settings.gameInputControlBinding == nil
        let hasValidGameInputBindings: Bool
        if let persistedCommandBinding,
           let persistedOptionBinding,
           let persistedControlBinding {
            gameInputCommandBinding = persistedCommandBinding
            gameInputOptionBinding = persistedOptionBinding
            gameInputControlBinding = persistedControlBinding
            hasValidGameInputBindings = true
        } else {
            let recommendedMap = GameInputModifierMap.recommended
            gameInputCommandBinding = recommendedMap.command
            gameInputOptionBinding = recommendedMap.option
            gameInputControlBinding = recommendedMap.control
            hasValidGameInputBindings = persistedGameInputBindingsAreAbsent
            if persistedGameInputBindingsAreAbsent {
                if settings.isGameInputModifierMappingEnabled == nil {
                    settings.isGameInputModifierMappingEnabled = false
                }
            } else {
                settings.isGameInputModifierMappingEnabled = false
            }
            settings.gameInputCommandBinding = gameInputCommandBinding.rawValue
            settings.gameInputOptionBinding = gameInputOptionBinding.rawValue
            settings.gameInputControlBinding = gameInputControlBinding.rawValue
            settings.updatedAt = Date()
            didNormalizeSettings = true
        }
        isGameInputModifierMappingEnabled = hasValidGameInputBindings &&
            (settings.isGameInputModifierMappingEnabled ?? false)
        blocksGameAppWindowManagementShortcuts =
            settings.blocksGameAppWindowManagementShortcuts ?? false
        blocksGameAppSwitchingShortcuts = settings.blocksGameAppSwitchingShortcuts ?? false
        blocksGameMissionControlSpaceShortcuts =
            settings.blocksGameMissionControlSpaceShortcuts ?? false
        blocksGameScreenshotShortcuts = settings.blocksGameScreenshotShortcuts ?? false
        hidesPointerWhileManagedGameFrontmost =
            settings.hidesPointerWhileManagedGameFrontmost ?? true
        if settings.normalizeAIDiagnosticProviderConfiguration() {
            didNormalizeSettings = true
        }
        #if DEBUG
        if normalizeNonUserPersistedFileSelections(settings) {
            didNormalizeSettings = true
        }
        #endif
        let defaultManagedRoot = try PathManager.defaultManagedRootURL()
        let persistedRootPath = settings.selectedRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        if persistedRootPath == defaultManagedRoot.path {
            selectedRootURL = defaultManagedRoot
            if settings.selectedRootBookmark != nil {
                settings.selectedRootBookmark = nil
                settings.updatedAt = Date()
                didNormalizeSettings = true
            }
        } else {
            let selectedRoot = resolvedPersistedFileSelection(
                path: settings.selectedRootPath,
                bookmark: settings.selectedRootBookmark,
                role: .selectedRoot
            )
            selectedRootURL = selectedRoot.url
            if let refreshedBookmark = selectedRoot.refreshedBookmark {
                settings.selectedRootBookmark = refreshedBookmark
                settings.updatedAt = Date()
                didNormalizeSettings = true
            }
        }

        do {
            let bundledRuntime = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutableURL()
            runtimeExecutableURL = bundledRuntime
            if settings.gptkExecutablePath != nil || settings.gptkExecutableBookmark != nil {
                // Retire every historical external/managed Runtime selection.
                // The active executable is derived from the current app bundle
                // and is intentionally absent from persisted user selections.
                settings.gptkExecutablePath = nil
                settings.gptkExecutableBookmark = nil
                settings.updatedAt = Date()
                didNormalizeSettings = true
            }
        } catch {
            runtimeExecutableURL = nil
            if settings.gptkExecutablePath != nil || settings.gptkExecutableBookmark != nil {
                settings.gptkExecutablePath = nil
                settings.gptkExecutableBookmark = nil
                settings.updatedAt = Date()
                didNormalizeSettings = true
            }
            setNotice(localizedError(error), kind: .failure)
        }

        let steamInstaller = resolvedPersistedFileSelection(
            path: settings.lastSteamInstallerPath,
            bookmark: settings.lastSteamInstallerBookmark,
            role: .steamInstaller
        )
        steamInstallerURL = steamInstaller.url
        if let refreshedBookmark = steamInstaller.refreshedBookmark {
            settings.lastSteamInstallerBookmark = refreshedBookmark
            settings.updatedAt = Date()
            didNormalizeSettings = true
        }
        if didNormalizeSettings {
            try context.saveOrRollback()
        }
        hasLoadedPersistentSettings = true
        pendingBookmarkReplacementRoles.removeAll()
        didCompleteLoad = true
    }

    func loadIfNeeded(from context: ModelContext) throws {
        guard !hasLoadedPersistentSettings else { return }
        try load(from: context)
    }

    func saveWarning(to context: ModelContext) -> String? {
        do {
            let settings = try loadOrCreateSettings(in: context)
            persistFileSelection(selectedRootURL, for: .selectedRoot, into: settings)
            settings.gptkExecutablePath = nil
            settings.gptkExecutableBookmark = nil
            persistFileSelection(steamInstallerURL, for: .steamInstaller, into: settings)
            persistUserPreferences(into: settings)
            try context.saveOrRollback()
            pendingBookmarkReplacementRoles.removeAll()
            return nil
        } catch {
            context.rollback()
            return localizedFormat("설정을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
        }
    }

    @discardableResult
    func clearPersistedRootAfterRestoreFailure(in context: ModelContext, reason: Error) throws -> String {
        let message = localizedFormat(
            "이전 ForgePlay 저장 위치를 사용할 수 없어 다시 선택해야 합니다: %@",
            localizedError(reason)
        )
        let settings = try loadOrCreateSettings(in: context)
        settings.selectedRootPath = nil
        settings.selectedRootBookmark = nil
        settings.updatedAt = Date()
        try context.saveOrRollback()
        clearPersistedFileSelection(for: .selectedRoot)
        setupStage = .chooseRoot
        setNotice(message, kind: .warning)
        return message
    }

    @discardableResult
    func save(to context: ModelContext) -> String? {
        let warning = saveWarning(to: context)
        if let warning {
            setNotice(warning, kind: .failure)
        }
        return warning
    }

    @discardableResult
    func saveUserPreferencesAfterMutation(
        to context: ModelContext,
        saveChanges: (ModelContext) throws -> Void = { try $0.saveOrRollback() },
        _ mutate: () -> Void
    ) -> String? {
        let snapshot = userPreferenceSnapshot()
        mutate()
        if let warning = saveUserPreferencesWarning(to: context, saveChanges: saveChanges) {
            restoreUserPreferences(snapshot)
            setNotice(warning, kind: .failure)
            return warning
        }
        return nil
    }

    private func saveUserPreferencesWarning(
        to context: ModelContext,
        saveChanges: (ModelContext) throws -> Void
    ) -> String? {
        do {
            let settings = try loadOrCreateSettings(in: context)
            let persistedSnapshot = PersistedUserPreferenceSnapshot(settings: settings)
            persistUserPreferences(into: settings)
            do {
                try saveChanges(context)
                return nil
            } catch {
                context.rollback()
                persistedSnapshot.restore(into: settings)
                return localizedFormat("설정을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
            }
        } catch {
            context.rollback()
            return localizedFormat("설정을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
        }
    }

    private func persistUserPreferences(into settings: AppSettingsRecord) {
        settings.themeMode = themeMode.rawValue
        let shouldPersistLanguageOverride = languageMode != .system &&
            languageModeOverrideSource == .userSettings
        settings.languageMode = shouldPersistLanguageOverride
            ? languageMode.rawValue
            : ForgePlayLanguageMode.system.rawValue
        settings.isLanguageModeOverrideEnabled = shouldPersistLanguageOverride
        settings.languageModeOverrideSource = shouldPersistLanguageOverride
            ? AppLanguageModeOverrideSource.userSettings.rawValue
            : nil
        settings.isAdvancedModeEnabled = isAdvancedModeEnabled
        settings.isLLMDiagnosticsEnabled = isLLMDiagnosticsEnabled
        settings.steamGraphicsBackendSelection = steamRendererPolicySelection.rawValue
        settings.wineSynchronizationSelection = wineSynchronizationSelection == .automatic
            ? nil
            : wineSynchronizationSelection.rawValue
        settings.steamVideoMemorySelection = steamVideoMemorySelection == .automatic
            ? nil
            : steamVideoMemorySelection.rawValue
        settings.isGameInputModifierMappingEnabled = isGameInputModifierMappingEnabled
        settings.gameInputCommandBinding = gameInputCommandBinding.rawValue
        settings.gameInputOptionBinding = gameInputOptionBinding.rawValue
        settings.gameInputControlBinding = gameInputControlBinding.rawValue
        settings.blocksGameAppWindowManagementShortcuts =
            blocksGameAppWindowManagementShortcuts
        settings.blocksGameAppSwitchingShortcuts = blocksGameAppSwitchingShortcuts
        settings.blocksGameMissionControlSpaceShortcuts = blocksGameMissionControlSpaceShortcuts
        settings.blocksGameScreenshotShortcuts = blocksGameScreenshotShortcuts
        settings.hidesPointerWhileManagedGameFrontmost =
            hidesPointerWhileManagedGameFrontmost
        settings.gameInputProtectionPreferenceVersion =
            max(
                settings.gameInputProtectionPreferenceVersion ?? 0,
                GameInputProtectionPreferenceSchema.currentVersion
            )
        settings.normalizeAIDiagnosticProviderConfiguration()
        settings.updatedAt = Date()
    }

    private func userPreferenceSnapshot() -> UserPreferenceSnapshot {
        #if DEBUG
        UserPreferenceSnapshot(
            themeMode: themeMode,
            languageMode: languageMode,
            languageModeOverrideSource: languageModeOverrideSource,
            steamRendererPolicySelection: steamRendererPolicySelection,
            wineSynchronizationSelection: wineSynchronizationSelection,
            steamVideoMemorySelection: steamVideoMemorySelection,
            isGameInputModifierMappingEnabled: isGameInputModifierMappingEnabled,
            gameInputCommandBinding: gameInputCommandBinding,
            gameInputOptionBinding: gameInputOptionBinding,
            gameInputControlBinding: gameInputControlBinding,
            blocksGameAppWindowManagementShortcuts:
                blocksGameAppWindowManagementShortcuts,
            blocksGameAppSwitchingShortcuts: blocksGameAppSwitchingShortcuts,
            blocksGameMissionControlSpaceShortcuts: blocksGameMissionControlSpaceShortcuts,
            blocksGameScreenshotShortcuts: blocksGameScreenshotShortcuts,
            hidesPointerWhileManagedGameFrontmost:
                hidesPointerWhileManagedGameFrontmost,
            isAdvancedModeEnabled: isAdvancedModeEnabled,
            isLLMDiagnosticsEnabled: isLLMDiagnosticsEnabled,
            debugLanguageModeOverride: debugLanguageModeOverride
        )
        #else
        UserPreferenceSnapshot(
            themeMode: themeMode,
            languageMode: languageMode,
            languageModeOverrideSource: languageModeOverrideSource,
            steamRendererPolicySelection: steamRendererPolicySelection,
            wineSynchronizationSelection: wineSynchronizationSelection,
            steamVideoMemorySelection: steamVideoMemorySelection,
            isGameInputModifierMappingEnabled: isGameInputModifierMappingEnabled,
            gameInputCommandBinding: gameInputCommandBinding,
            gameInputOptionBinding: gameInputOptionBinding,
            gameInputControlBinding: gameInputControlBinding,
            blocksGameAppWindowManagementShortcuts:
                blocksGameAppWindowManagementShortcuts,
            blocksGameAppSwitchingShortcuts: blocksGameAppSwitchingShortcuts,
            blocksGameMissionControlSpaceShortcuts: blocksGameMissionControlSpaceShortcuts,
            blocksGameScreenshotShortcuts: blocksGameScreenshotShortcuts,
            hidesPointerWhileManagedGameFrontmost:
                hidesPointerWhileManagedGameFrontmost,
            isAdvancedModeEnabled: isAdvancedModeEnabled,
            isLLMDiagnosticsEnabled: isLLMDiagnosticsEnabled
        )
        #endif
    }

    private func restoreUserPreferences(_ snapshot: UserPreferenceSnapshot) {
        themeMode = snapshot.themeMode
        languageMode = snapshot.languageMode
        languageModeOverrideSource = snapshot.languageModeOverrideSource
        steamRendererPolicySelection = snapshot.steamRendererPolicySelection
        wineSynchronizationSelection = snapshot.wineSynchronizationSelection
        steamVideoMemorySelection = snapshot.steamVideoMemorySelection
        isGameInputModifierMappingEnabled = snapshot.isGameInputModifierMappingEnabled
        gameInputCommandBinding = snapshot.gameInputCommandBinding
        gameInputOptionBinding = snapshot.gameInputOptionBinding
        gameInputControlBinding = snapshot.gameInputControlBinding
        blocksGameAppWindowManagementShortcuts =
            snapshot.blocksGameAppWindowManagementShortcuts
        blocksGameAppSwitchingShortcuts = snapshot.blocksGameAppSwitchingShortcuts
        blocksGameMissionControlSpaceShortcuts =
            snapshot.blocksGameMissionControlSpaceShortcuts
        blocksGameScreenshotShortcuts = snapshot.blocksGameScreenshotShortcuts
        hidesPointerWhileManagedGameFrontmost =
            snapshot.hidesPointerWhileManagedGameFrontmost
        isAdvancedModeEnabled = snapshot.isAdvancedModeEnabled
        isLLMDiagnosticsEnabled = snapshot.isLLMDiagnosticsEnabled
        #if DEBUG
        debugLanguageModeOverride = snapshot.debugLanguageModeOverride
        #endif
    }

    func setLanguageModeFromUserSelection(_ languageMode: ForgePlayLanguageMode) {
        #if DEBUG
        debugLanguageModeOverride = nil
        #endif
        self.languageMode = languageMode
        languageModeOverrideSource = languageMode == .system ? nil : .userSettings
    }

    func loadOrCreateSettings(in context: ModelContext) throws -> AppSettingsRecord {
        let descriptor = FetchDescriptor<AppSettingsRecord>()
        if let settings = try context.fetch(descriptor).first {
            return settings
        }
        let settings = AppSettingsRecord()
        context.insert(settings)
        return settings
    }

    func advanceSetupIfPossible() {
        if let next = SetupStage(rawValue: setupStage.rawValue + 1) {
            setupStage = next
        }
    }

    func updateSetupStage(readiness: SetupReadiness) {
        setupReadiness = readiness
        if selectedRootURL == nil {
            setupStage = .chooseRoot
        } else if readiness.rootIssue != nil {
            setupStage = .chooseRoot
        } else if let blockingStage = setupStageForBlockingSystemChecks(readiness: readiness) {
            setupStage = blockingStage
        } else if systemCheckSummary.phase == .unverified {
            setupStage = .checkMac
        } else if runtimeExecutableURL == nil {
            setupStage = .prepareEngine
        } else if !readiness.hasSteamPrefix ||
                    (readiness.steamPrefixState == .prefixInvalid &&
                        !readiness.canAttemptWindowsSteamLaunch) ||
                    readiness.steamPrefixState == .rootNotConfigured {
            setupStage = .prepareSteamEnvironment
        } else if readiness.steamPrefixState == .steamMissing {
            setupStage = .installSteam
        } else if readiness.steamUIVerificationState == .blackScreenSuspected ||
                    readiness.steamUIVerificationState == .failed {
            setupStage = .authenticateSteam
        } else if !readiness.hasUsableAuthenticatedSteamSession {
            setupStage = .authenticateSteam
        } else {
            setupStage = .ready
        }
    }

    private func setupStageForBlockingSystemChecks(readiness: SetupReadiness) -> SetupStage? {
        guard systemCheckSummary.phase == .blocked else { return nil }

        if hasBlockingSystemCheck(.storage) {
            return .chooseRoot
        }
        if hasBlockingSystemCheck(.appleSilicon) ||
            hasBlockingSystemCheck(.operatingSystem) {
            return .checkMac
        }
        if runtimeExecutableURL == nil {
            return .prepareEngine
        }
        if !readiness.hasSteamPrefix ||
            (readiness.steamPrefixState == .prefixInvalid &&
                !readiness.canAttemptWindowsSteamLaunch) ||
            readiness.steamPrefixState == .rootNotConfigured ||
            (!readiness.canAttemptWindowsSteamLaunch &&
                hasBlockingSystemCheck(.steamPrefix)) {
            return .prepareSteamEnvironment
        }
        // Other failed checks are operational diagnostics. They remain visible
        // without becoming a setup-stage launch gate; concrete missing inputs
        // below still route to their owning preparation stage.
        return nil
    }

    private func hasBlockingSystemCheck(_ category: SystemCheckCategory) -> Bool {
        latestChecks.contains { $0.category == category && $0.status == .error }
    }

    func updateSetupStage(hasSteamPrefix: Bool, hasSteamExecutable: Bool, hasSteamReferences: Bool) {
        updateSetupStage(readiness: SetupReadiness(
            hasSteamPrefix: hasSteamPrefix,
            hasSteamExecutable: hasSteamExecutable,
            hasSteamReferences: hasSteamReferences,
            steamPrefixURL: nil,
            steamExecutableURL: nil
        ))
    }

    @discardableResult
    func setTask(_ message: String?, kind: AppNoticeKind = .progress, logURL: URL? = nil) -> AppNotice? {
        guard let message else {
            clearNotice()
            return nil
        }
        return setNotice(message, kind: kind, logURL: logURL)
    }

    @discardableResult
    func setNotice(
        _ message: String,
        kind: AppNoticeKind,
        logURL: URL? = nil,
        diagnosticProcessResult: ProcessRunResult? = nil,
        captureFailureEvidence: Bool = true,
        operationIdentifier: String = #function,
        surfaceIdentifier: String? = nil
    ) -> AppNotice {
        var resolvedMessage = message
        var resolvedLogURL = logURL
        if kind == .failure,
           captureFailureEvidence,
           resolvedLogURL == nil || diagnosticProcessResult != nil {
            let evidenceError: Error
            if let diagnosticProcessResult {
                evidenceError = ProcessExecutionEvidenceError(
                    underlyingError: AppNoticeFailureEvidenceError(message: message),
                    result: diagnosticProcessResult
                )
            } else {
                evidenceError = AppNoticeFailureEvidenceError(message: message)
            }
            let capture = self.captureFailureEvidence(
                for: evidenceError,
                operationIdentifier: operationIdentifier,
                surfaceIdentifier: surfaceIdentifier
            )
            resolvedLogURL = resolvedLogURL ?? capture.logURL
            resolvedMessage = DiagnosticWarningText.combined(
                message,
                capture.warning
            ) ?? message
        }

        let notice = AppNotice(
            message: resolvedMessage,
            kind: kind,
            logURL: resolvedLogURL
        )
        currentTaskMessage = resolvedMessage
        currentNotice = notice
        return notice
    }

    func clearNotice() {
        currentTaskMessage = nil
        currentNotice = nil
    }

    func clearNotice(id: UUID) {
        guard currentNotice?.id == id else { return }
        clearNotice()
    }

    func presentDiagnosticGuide(
        title: String,
        diagnostics: [DiagnosticResult],
        logURL: URL?,
        persistenceWarning: String? = nil
    ) {
        guard let destination = diagnosticGuideDestination(
            title: title,
            diagnostics: diagnostics,
            logURL: logURL,
            persistenceWarning: persistenceWarning
        ) else { return }
        presentedSheet = destination
    }

    func diagnosticGuideDestination(
        title: String,
        diagnostics: [DiagnosticResult],
        logURL: URL?,
        persistenceWarning: String? = nil
    ) -> SheetDestination? {
        let payload = DiagnosticGuidancePayload(
            title: title,
            diagnostics: diagnostics,
            logURL: logURL,
            persistenceWarning: persistenceWarning
        )
        guard !payload.diagnostics.isEmpty else { return nil }
        activeDiagnostics = payload.diagnostics
        return .diagnosticGuide(payload)
    }

    func configureFailureDiagnostics(
        service: FailureDiagnosticEvidenceService,
        pathManager: PathManager
    ) {
        failureDiagnosticEvidenceService = service
        failureDiagnosticPathManager = pathManager
    }

    @discardableResult
    func setError(
        _ error: Error,
        operationIdentifier: String = #function,
        surfaceIdentifier: String? = nil,
        captureFailureEvidence: Bool = true
    ) -> AppNotice {
        var preferredLogURL: URL?
        if let diagnosticError = error as? ForgePlayDiagnosticLogProvidingError {
            preferredLogURL = diagnosticError.forgePlayDiagnosticLogURL
        } else if let prefixError = error as? PrefixManagerError {
            preferredLogURL = prefixError.result.stderrLog
        }

        var evidenceWarning: String?
        if captureFailureEvidence {
            let capture = self.captureFailureEvidence(
                for: error,
                operationIdentifier: operationIdentifier,
                surfaceIdentifier: surfaceIdentifier
            )
            preferredLogURL = capture.logURL ?? preferredLogURL
            evidenceWarning = capture.warning
        }

        let message = DiagnosticWarningText.combined(
            localizedError(error),
            evidenceWarning
        ) ?? localizedError(error)
        return setNotice(
            message,
            kind: .failure,
            logURL: preferredLogURL,
            captureFailureEvidence: false
        )
    }

    func handleGameInputProtectionLifecycleEvent(
        _ event: GameInputProtectionLifecycleEvent
    ) {
        switch event {
        case .protectionLost(let session, let failure):
            let lossNotice = setError(
                failure,
                operationIdentifier: "steam.game-input-protection",
                surfaceIdentifier:
                    "steam.game-input-protection.terminal-protection-loss"
            )
            gameInputProtectionFailureNoticeBindings[session] =
                GameInputProtectionFailureNoticeBinding(
                    lossNoticeIdentifier: lossNotice.id,
                    evidenceURL: lossNotice.logURL
                )
        case .containmentCompleted(let session, let failure):
            guard let binding = gameInputProtectionFailureNoticeBindings
                .removeValue(forKey: session)
            else { return }
            guard currentNotice == nil ||
                    currentNotice?.id == binding.lossNoticeIdentifier else {
                return
            }
            setNotice(
                localizedFormat(
                    "게임 입력 보호가 %@ 이유로 중단되어 입력 보호만 비활성화했습니다. Wine과 Steam 실행은 유지되며, 진단 기록을 확인하세요.",
                    localizedError(failure)
                ),
                kind: .warning,
                logURL: binding.evidenceURL,
                captureFailureEvidence: false,
                operationIdentifier: "steam.game-input-protection",
                surfaceIdentifier:
                    "steam.game-input-protection.containment-completed"
            )
        }
    }

    func handleGameInputPointerHideFailure(
        _ event: GameInputProtectionPointerHideFailureEvent
    ) {
        _ = event
        setNotice(
            localized(
                "macOS가 이번 포인터 숨김 요청을 수락하지 않았습니다. Steam 실행은 계속되며 다음에 관리되는 게임이 전면으로 전환되면 다시 시도할 수 있습니다 (베타)."
            ),
            kind: .warning,
            captureFailureEvidence: false
        )
    }

    private func captureFailureEvidence(
        for error: Error,
        operationIdentifier: String,
        surfaceIdentifier: String?
    ) -> (logURL: URL?, warning: String?) {
        guard let failureDiagnosticEvidenceService,
              let failureDiagnosticPathManager else {
            return (nil, nil)
        }

        let selectedGame = selectedSteamReference
        let additionalSensitivePaths = DiagnosticPathRedactionPolicy.sensitivePaths(
            rootURL: selectedRootURL ?? failureDiagnosticPathManager.rootURL,
            selectedSteamReference: selectedGame,
            runtimeExecutable: runtimeExecutableURL
        )
        let additionalSensitiveTerms = DiagnosticPathRedactionPolicy.sensitiveTerms(
            selectedSteamReference: selectedGame
        )
        do {
            let resolution = try failureDiagnosticEvidenceService.ensureEvidence(
                for: error,
                operationIdentifier: operationIdentifier,
                surfaceIdentifier: surfaceIdentifier ?? "ui.\(selectedSection.rawValue)",
                additionalSensitivePaths: additionalSensitivePaths,
                additionalSensitiveTerms: additionalSensitiveTerms
            )
            lastFailureEvidenceURL = resolution.url
            return (resolution.url, nil)
        } catch {
            return (
                nil,
                localizedFormat(
                    "실패 진단 기록을 저장하지 못했습니다: %@",
                    forgePlayTechnicalErrorSummary(error)
                )
            )
        }
    }

    @discardableResult
    func openExternalURL(_ url: URL?) -> Bool {
        guard let url else {
            setNotice(localized("열 링크를 찾을 수 없습니다."), kind: .failure)
            return false
        }
        guard ExternalLinkPolicy.open(url) else {
            setNotice(localizedFormat("링크를 열 수 없습니다: %@", url.absoluteString), kind: .failure)
            return false
        }
        return true
    }

    @discardableResult
    func openFileURL(_ url: URL?) -> Bool {
        guard let url else {
            setNotice(localized("열 항목을 찾을 수 없습니다."), kind: .failure)
            return false
        }
        guard ExternalLinkPolicy.open(url) else {
            setNotice(localizedFormat("항목을 열 수 없습니다: %@", url.path), kind: .failure)
            return false
        }
        return true
    }

    @discardableResult
    func revealInFinder(_ url: URL) -> Bool {
        guard ExternalLinkPolicy.revealInFinder(url) else {
            setNotice(localizedFormat("Finder에서 항목을 찾을 수 없습니다: %@", url.path), kind: .failure)
            return false
        }
        return true
    }

    func setPersistedFileSelection(
        _ url: URL?,
        for role: PersistedFileSelectionRole,
        requiresBookmarkReplacement: Bool = true
    ) {
        if requiresBookmarkReplacement {
            pendingBookmarkReplacementRoles.insert(role)
        }
        switch role {
        case .selectedRoot:
            selectedRootURL = url
        case .steamInstaller:
            steamInstallerURL = url
        case .steamLibrary:
            break
        }
        retainSecurityScopedAccess(to: url, for: role)
    }

    func activateManagedRoot(_ url: URL) {
        let normalized = url.standardizedFileURL
        if retainedSecurityScopedURLs[.selectedRoot]?.standardizedFileURL.path != normalized.path {
            releaseSecurityScopedAccess(for: .selectedRoot)
        }
        selectedRootURL = normalized
    }

    func clearPersistedFileSelection(for role: PersistedFileSelectionRole) {
        setPersistedFileSelection(nil, for: role)
    }

    #if DEBUG
    private func normalizeNonUserPersistedFileSelections(_ settings: AppSettingsRecord) -> Bool {
        guard Self.normalizedFilePath(settings.selectedRootPath) == ForgePlayDevelopmentFixturePaths.appStoreScreenshotRootPath else {
            return false
        }
        var changed = false
        settings.selectedRootPath = nil
        settings.selectedRootBookmark = nil
        changed = true
        settings.gptkExecutablePath = nil
        settings.gptkExecutableBookmark = nil
        settings.updatedAt = Date()
        return changed
    }
    #endif

    private func persistFileSelection(
        _ url: URL?,
        for role: PersistedFileSelectionRole,
        into settings: AppSettingsRecord
    ) {
        #if DEBUG
        if shouldSkipPersistingDebugFixtureFileSelection(url, for: role) {
            return
        }
        #endif

        switch role {
        case .selectedRoot:
            let previousPath = settings.selectedRootPath
            settings.selectedRootPath = url?.path
            guard let url else {
                settings.selectedRootBookmark = nil
                return
            }
            let defaultManagedRoot = try? PathManager.defaultManagedRootURL()
            if defaultManagedRoot?.standardizedFileURL.path == url.standardizedFileURL.path {
                settings.selectedRootBookmark = nil
            } else if let bookmark = bookmarkData(for: url, role: .selectedRoot) {
                settings.selectedRootBookmark = bookmark
            } else if previousPath != url.path || pendingBookmarkReplacementRoles.contains(role) {
                settings.selectedRootBookmark = nil
            }
        case .steamInstaller:
            let previousPath = settings.lastSteamInstallerPath
            settings.lastSteamInstallerPath = url?.path
            if let url,
               let bookmark = bookmarkData(for: url, role: .steamInstaller) {
                settings.lastSteamInstallerBookmark = bookmark
            } else if previousPath != url?.path || pendingBookmarkReplacementRoles.contains(role) {
                settings.lastSteamInstallerBookmark = nil
            }
        case .steamLibrary:
            break
        }
    }

    private nonisolated static func normalizedFilePath(_ path: String?) -> String? {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    #if DEBUG
    private func shouldSkipPersistingDebugFixtureFileSelection(
        _ url: URL?,
        for role: PersistedFileSelectionRole
    ) -> Bool {
        guard debugAppStoreScreenshotFixture else { return false }
        let path = url?.standardizedFileURL.path
        switch role {
        case .selectedRoot:
            return path == ForgePlayDevelopmentFixturePaths.appStoreScreenshotRootPath
        case .steamInstaller:
            return false
        case .steamLibrary:
            return false
        }
    }
    #endif

    func retainSecurityScopedAccess(to url: URL?, for role: PersistedFileSelectionRole) {
        releaseSecurityScopedAccess(for: role)
        guard let url else { return }
        if url.startAccessingSecurityScopedResource() {
            retainedSecurityScopedURLs[role] = url
        }
    }

    func releaseSecurityScopedAccess(for role: PersistedFileSelectionRole) {
        if let url = retainedSecurityScopedURLs.removeValue(forKey: role) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func releaseSteamStorageSecurityScopedAccess(for url: URL) {
        let path = url.standardizedFileURL.path
        if let retained = retainedSteamLibrarySecurityScopedURLs.removeValue(forKey: path) {
            retained.stopAccessingSecurityScopedResource()
        }
    }

    func releaseAllSecurityScopedAccess() {
        for url in retainedSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        retainedSecurityScopedURLs.removeAll()
        for url in retainedSteamLibrarySecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        retainedSteamLibrarySecurityScopedURLs.removeAll()
    }

    func restoreSteamLibraryAccess(
        from records: [SteamGameRecord],
        in modelContext: ModelContext,
        allowsPathFallback: Bool = !ForgePlaySandboxPolicy.isAppSandboxEnabled,
        reportsUnavailableAccess: Bool = true,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL = {
            try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0)
        },
        securityScopeStarter: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    ) -> SteamLibraryAccessRestoration {
        let grouped = Dictionary(grouping: records) {
            URL(fileURLWithPath: $0.libraryPath).standardizedFileURL.path
        }
        var restored: [URL] = []
        var restoredSourcePaths = Set<String>()
        var restoredBookmarkPaths = Set<String>()
        var didRefreshBookmark = false
        var bookmarkPersistenceFailed = false
        var unavailableCount = 0

        for path in grouped.keys.sorted() {
            guard let recordsForPath = grouped[path], !recordsForPath.isEmpty else { continue }
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if let selectedRootURL,
               Self.isURL(root, containedBy: selectedRootURL) {
                restored.append(root)
                restoredSourcePaths.insert(path)
                continue
            }

            let bookmarkResolution = Self.resolveSteamLibraryBookmarkCandidates(
                path: path,
                bookmarks: recordsForPath.compactMap(\.libraryBookmark),
                allowsPathFallback: allowsPathFallback,
                bookmarkResolver: bookmarkResolver,
                securityScopeStarter: securityScopeStarter
            )
            switch bookmarkResolution.resolution {
            case .restored(let access):
                let authorizationURL = access.url.standardizedFileURL
                let restoredRoot = Self.isURL(root, containedBy: authorizationURL)
                    ? root
                    : authorizationURL
                if let previous = retainedSteamLibrarySecurityScopedURLs.removeValue(forKey: root.path) {
                    previous.stopAccessingSecurityScopedResource()
                }
                retainedSteamLibrarySecurityScopedURLs[root.path] = access.url
                restored.append(restoredRoot)
                restoredSourcePaths.insert(path)
                restoredBookmarkPaths.insert(path)
                if access.isStale,
                   let refreshed = bookmarkData(for: access.url, role: .steamLibrary) {
                    recordsForPath.forEach { $0.libraryBookmark = refreshed }
                    didRefreshBookmark = true
                } else if let workingBookmark = bookmarkResolution.bookmark,
                          recordsForPath.contains(where: { $0.libraryBookmark != workingBookmark }) {
                    recordsForPath.forEach { $0.libraryBookmark = workingBookmark }
                    didRefreshBookmark = true
                }
            case .pathFallback(let url):
                restored.append(url.standardizedFileURL)
                restoredSourcePaths.insert(path)
            case .unavailable, .empty:
                unavailableCount += 1
            }
        }

        if didRefreshBookmark {
            do {
                try modelContext.saveOrRollback()
            } catch {
                modelContext.rollback()
                bookmarkPersistenceFailed = true
                setNotice(
                    localizedFormat("외장 Steam 라이브러리 접근 권한 갱신을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error)),
                    kind: .warning
                )
            }
        }
        if reportsUnavailableAccess, unavailableCount > 0 {
            setNotice(
                localizedFormat("%d개 외장 Steam 라이브러리 접근 권한을 복원하지 못해 이번 Steam 실행에서 제외했습니다. 라이브러리를 다시 연결하세요.", unavailableCount),
                kind: .warning
            )
        }
        return SteamLibraryAccessRestoration(
            roots: restored,
            unavailableCount: unavailableCount,
            bookmarkPersistenceFailed: bookmarkPersistenceFailed,
            restoredSourcePaths: restoredSourcePaths,
            restoredBookmarkPaths: restoredBookmarkPaths,
            driveReservationRoots: Self.driveReservationRoots(
                activeRoots: restored,
                expectedSourcePaths: Set(grouped.keys),
                restoredSourcePaths: restoredSourcePaths
            )
        )
    }

    func restoreSteamStorageMountAccess(
        from records: [SteamStorageMountRecord],
        in modelContext: ModelContext,
        allowsPathFallback: Bool = !ForgePlaySandboxPolicy.isAppSandboxEnabled,
        reportsUnavailableAccess: Bool = true,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL = {
            try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0)
        },
        securityScopeStarter: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        bookmarkCreator: (URL) throws -> Data = {
            try SecurityScopedBookmarkPolicy.bookmarkData(for: $0)
        },
        saveChanges: (ModelContext) throws -> Void = { try $0.saveOrRollback() }
    ) -> SteamLibraryAccessRestoration {
        let recordStates = records.map {
            (
                record: $0,
                path: $0.path,
                bookmark: $0.bookmark,
                updatedAt: $0.updatedAt
            )
        }
        let grouped = Dictionary(grouping: records) {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path
        }
        var restored: [URL] = []
        var restoredSourcePaths = Set<String>()
        var restoredBookmarkPaths = Set<String>()
        var retainedPathMigrations: [(from: String, to: String)] = []
        var didUpdateBookmarkRecords = false
        var bookmarkPersistenceFailed = false
        var unavailableCount = 0

        for path in grouped.keys.sorted() {
            guard let recordsForPath = grouped[path], !recordsForPath.isEmpty else { continue }
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL

            if let selectedRootURL,
               Self.isURL(root, containedBy: selectedRootURL) {
                restored.append(root)
                restoredSourcePaths.insert(root.path)
                continue
            }

            let bookmarkResolution = Self.resolveSteamLibraryBookmarkCandidates(
                path: path,
                bookmarks: recordsForPath.compactMap(\.bookmark),
                allowsPathFallback: allowsPathFallback,
                bookmarkResolver: bookmarkResolver,
                securityScopeStarter: securityScopeStarter
            )
            switch bookmarkResolution.resolution {
            case .restored(let access):
                let authorizationURL = access.url.standardizedFileURL
                let resolvedURL = Self.isURL(root, containedBy: authorizationURL)
                    ? root
                    : authorizationURL
                if let previous = retainedSteamLibrarySecurityScopedURLs.removeValue(forKey: root.path) {
                    previous.stopAccessingSecurityScopedResource()
                }
                retainedSteamLibrarySecurityScopedURLs[root.path] = access.url
                restored.append(resolvedURL)
                restoredSourcePaths.formUnion([root.path, resolvedURL.path])
                restoredBookmarkPaths.formUnion([root.path, resolvedURL.path])
                let refreshedBookmark = access.isStale
                    ? bookmarkData(
                        for: access.url,
                        role: .steamLibrary,
                        bookmarkCreator: bookmarkCreator
                    )
                    : nil
                if let workingBookmark = refreshedBookmark ?? bookmarkResolution.bookmark {
                    let now = Date()
                    var didUpdatePath = false
                    for record in recordsForPath {
                        var didUpdateRecord = false
                        if record.path != resolvedURL.path {
                            record.path = resolvedURL.path
                            didUpdatePath = true
                            didUpdateRecord = true
                        }
                        if record.bookmark != workingBookmark {
                            record.bookmark = workingBookmark
                            didUpdateRecord = true
                        }
                        if didUpdateRecord {
                            record.updatedAt = now
                            didUpdateBookmarkRecords = true
                        }
                    }
                    if root.path != resolvedURL.path {
                        if didUpdatePath {
                            retainedPathMigrations.append((root.path, resolvedURL.path))
                        }
                    }
                }
            case .pathFallback(let url):
                restored.append(url.standardizedFileURL)
                restoredSourcePaths.insert(root.path)
            case .unavailable, .empty:
                unavailableCount += 1
            }
        }

        if didUpdateBookmarkRecords {
            do {
                try saveChanges(modelContext)
                for migration in retainedPathMigrations {
                    migrateRetainedSteamLibrarySecurityScope(
                        from: migration.from,
                        to: migration.to
                    )
                }
            } catch {
                modelContext.rollback()
                for state in recordStates {
                    state.record.path = state.path
                    state.record.bookmark = state.bookmark
                    state.record.updatedAt = state.updatedAt
                }
                bookmarkPersistenceFailed = true
                setNotice(
                    localizedFormat("Steam 저장공간 접근 권한 갱신을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error)),
                    kind: .warning
                )
            }
        }
        if reportsUnavailableAccess, unavailableCount > 0 {
            setNotice(
                localizedFormat("%d개 Steam 저장공간 접근 권한을 복원하지 못했습니다. 해당 폴더를 다시 연결하세요.", unavailableCount),
                kind: .warning
            )
        }
        return SteamLibraryAccessRestoration(
            roots: restored,
            unavailableCount: unavailableCount,
            bookmarkPersistenceFailed: bookmarkPersistenceFailed,
            restoredSourcePaths: restoredSourcePaths,
            restoredBookmarkPaths: restoredBookmarkPaths,
            driveReservationRoots: Self.driveReservationRoots(
                activeRoots: restored,
                expectedSourcePaths: Set(grouped.keys),
                restoredSourcePaths: restoredSourcePaths
            )
        )
    }

    func disconnectSteamStorageMount(
        _ mount: SteamStorageMountRecord,
        in modelContext: ModelContext,
        saveChanges: (ModelContext) throws -> Void = { try $0.saveOrRollback() }
    ) throws {
        let disconnectedPath = mount.url.path
        let gameRecords = try modelContext.fetch(FetchDescriptor<SteamGameRecord>())
        let mountRecords = try modelContext.fetch(FetchDescriptor<SteamStorageMountRecord>())
        guard mountRecords.contains(where: { $0.id == mount.id }) else {
            throw SteamStorageMountMutationError.mountNotFound(mount.id)
        }

        let disconnectedRoot = URL(fileURLWithPath: disconnectedPath, isDirectory: true)
            .standardizedFileURL
        let affectedGames = gameRecords.filter { game in Self.isURL(
            URL(fileURLWithPath: game.libraryPath, isDirectory: true),
            containedBy: disconnectedRoot
        ) }
        let gameStates = affectedGames.map { (record: $0, libraryBookmark: $0.libraryBookmark) }
        let affectedMounts = mountRecords.filter { $0.url.path == disconnectedPath }
        let mountStates = affectedMounts.map {
            (
                record: $0,
                path: $0.path,
                bookmark: $0.bookmark,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }

        for game in affectedGames {
            game.libraryBookmark = nil
        }
        for record in affectedMounts {
            modelContext.delete(record)
        }
        do {
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            for state in mountStates {
                if state.record.modelContext == nil {
                    modelContext.insert(state.record)
                }
                state.record.path = state.path
                state.record.bookmark = state.bookmark
                state.record.createdAt = state.createdAt
                state.record.updatedAt = state.updatedAt
            }
            for state in gameStates {
                state.record.libraryBookmark = state.libraryBookmark
            }
            throw error
        }
        releaseSteamStorageSecurityScopedAccess(for: disconnectedRoot)
    }

    @discardableResult
    func connectSteamStorageMount(
        _ authorization: SteamStorageSelectionAuthorization,
        in modelContext: ModelContext,
        saveChanges: (ModelContext) throws -> Void = { try $0.saveOrRollback() }
    ) throws -> Bool {
        let existingMounts = try modelContext.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let normalizedPath = authorization.root.standardizedFileURL.path
        let matchingMounts = existingMounts.filter { $0.url.path == normalizedPath }
        let persistedMountSnapshot = matchingMounts.map {
            SteamStorageMountPersistenceSnapshot(record: $0)
        }
        let mountStates = matchingMounts.map {
            (
                record: $0,
                path: $0.path,
                bookmark: $0.bookmark,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        let connectedMount = try modelContext.upsertSteamStorageMount(
            url: authorization.root,
            bookmark: authorization.bookmark
        )
        if let oldestCreationDate = matchingMounts.map(\.createdAt).min() {
            connectedMount.createdAt = oldestCreationDate
        }
        for duplicate in matchingMounts where duplicate.id != connectedMount.id {
            modelContext.delete(duplicate)
        }
        do {
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            for state in mountStates {
                if state.record.modelContext == nil {
                    modelContext.insert(state.record)
                }
                state.record.path = state.path
                state.record.bookmark = state.bookmark
                state.record.createdAt = state.createdAt
                state.record.updatedAt = state.updatedAt
            }
            if matchingMounts.isEmpty, connectedMount.modelContext != nil {
                modelContext.delete(connectedMount)
                modelContext.rollback()
            }
            throw error
        }
        do {
            try Self.verifyPersistedSteamStorageMount(
                in: modelContext,
                expectedID: connectedMount.id,
                expectedPath: normalizedPath,
                expectedBookmark: connectedMount.bookmark
            )
        } catch let verificationError {
            modelContext.rollback()
            for state in mountStates where state.record.modelContext != nil {
                state.record.path = state.path
                state.record.bookmark = state.bookmark
                state.record.createdAt = state.createdAt
                state.record.updatedAt = state.updatedAt
            }
            if persistedMountSnapshot.isEmpty,
               connectedMount.modelContext != nil {
                modelContext.delete(connectedMount)
            }
            do {
                try Self.restorePersistedSteamStorageMutation(
                    in: modelContext,
                    mountSnapshots: persistedMountSnapshot,
                    affectedMountIDs: [connectedMount.id],
                    affectedMountPaths: [normalizedPath],
                    gameSnapshots: []
                )
            } catch let recoveryError {
                throw SteamStorageMountMutationError.persistenceRecoveryFailed(
                    originalFailure: forgePlayTechnicalErrorSummary(verificationError),
                    recoveryFailure: forgePlayTechnicalErrorSummary(recoveryError)
                )
            }
            throw verificationError
        }
        return retainSteamStorageAuthorization(authorization)
    }

    @discardableResult
    func reconnectSteamStorageMount(
        _ mount: SteamStorageMountRecord,
        to authorization: SteamStorageSelectionAuthorization,
        in modelContext: ModelContext,
        now: Date = Date(),
        saveChanges: (ModelContext) throws -> Void = { try $0.saveOrRollback() }
    ) throws -> Bool {
        let oldRoot = mount.url
        let newRoot = authorization.root.standardizedFileURL
        let mountRecords = try modelContext.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let gameRecords = try modelContext.fetch(FetchDescriptor<SteamGameRecord>())
        guard let primaryMount = mountRecords.first(where: { $0.id == mount.id }) else {
            throw SteamStorageMountMutationError.mountNotFound(mount.id)
        }

        let matchingMounts = mountRecords.filter {
            let path = $0.url.path
            return path == oldRoot.path || path == newRoot.path
        }
        let persistedMountSnapshot = matchingMounts.map {
            SteamStorageMountPersistenceSnapshot(record: $0)
        }
        let mountStates = matchingMounts.map {
            (
                record: $0,
                path: $0.path,
                bookmark: $0.bookmark,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        let affectedGames = gameRecords.filter {
            let libraryURL = URL(
                fileURLWithPath: $0.libraryPath,
                isDirectory: true
            ).standardizedFileURL
            return Self.isURL(libraryURL, containedBy: oldRoot) ||
                Self.isURL(libraryURL, containedBy: newRoot)
        }
        let persistedGameSnapshot = affectedGames.map {
            SteamGamePersistenceSnapshot(record: $0)
        }
        let gameStates = affectedGames.map {
            (
                record: $0,
                libraryPath: $0.libraryPath,
                manifestPath: $0.manifestPath,
                libraryBookmark: $0.libraryBookmark
            )
        }
        if let oldestCreationDate = matchingMounts.map(\.createdAt).min() {
            primaryMount.createdAt = oldestCreationDate
        }
        primaryMount.path = newRoot.path
        primaryMount.bookmark = authorization.bookmark
        primaryMount.updatedAt = now

        for game in gameRecords {
            let originalLibraryURL = URL(
                fileURLWithPath: game.libraryPath,
                isDirectory: true
            ).standardizedFileURL
            let originalManifestURL = URL(fileURLWithPath: game.manifestPath)
                .standardizedFileURL
            let belongedToOldRoot = Self.isURL(originalLibraryURL, containedBy: oldRoot)
            let belongsToNewRoot = Self.isURL(originalLibraryURL, containedBy: newRoot)

            if belongedToOldRoot {
                if let rebasedLibraryPath = Self.rebasedPath(
                    originalLibraryURL.path,
                    from: oldRoot,
                    to: newRoot
                ) {
                    game.libraryPath = rebasedLibraryPath
                }
                if let rebasedManifestPath = Self.rebasedPath(
                    originalManifestURL.path,
                    from: oldRoot,
                    to: newRoot
                ) {
                    game.manifestPath = rebasedManifestPath
                }
            }
            if belongedToOldRoot || belongsToNewRoot {
                game.libraryBookmark = nil
            }
        }

        for duplicate in matchingMounts where duplicate.id != primaryMount.id {
            modelContext.delete(duplicate)
        }

        do {
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            for state in mountStates {
                if state.record.modelContext == nil {
                    modelContext.insert(state.record)
                }
                state.record.path = state.path
                state.record.bookmark = state.bookmark
                state.record.createdAt = state.createdAt
                state.record.updatedAt = state.updatedAt
            }
            for state in gameStates {
                state.record.libraryPath = state.libraryPath
                state.record.manifestPath = state.manifestPath
                state.record.libraryBookmark = state.libraryBookmark
            }
            throw error
        }
        do {
            try Self.verifyPersistedSteamStorageMount(
                in: modelContext,
                expectedID: primaryMount.id,
                expectedPath: newRoot.path,
                expectedBookmark: primaryMount.bookmark
            )
        } catch let verificationError {
            modelContext.rollback()
            for state in mountStates where state.record.modelContext != nil {
                state.record.path = state.path
                state.record.bookmark = state.bookmark
                state.record.createdAt = state.createdAt
                state.record.updatedAt = state.updatedAt
            }
            for state in gameStates where state.record.modelContext != nil {
                state.record.libraryPath = state.libraryPath
                state.record.manifestPath = state.manifestPath
                state.record.libraryBookmark = state.libraryBookmark
            }
            do {
                try Self.restorePersistedSteamStorageMutation(
                    in: modelContext,
                    mountSnapshots: persistedMountSnapshot,
                    affectedMountIDs: [primaryMount.id],
                    affectedMountPaths: [oldRoot.path, newRoot.path],
                    gameSnapshots: persistedGameSnapshot
                )
            } catch let recoveryError {
                throw SteamStorageMountMutationError.persistenceRecoveryFailed(
                    originalFailure: forgePlayTechnicalErrorSummary(verificationError),
                    recoveryFailure: forgePlayTechnicalErrorSummary(recoveryError)
                )
            }
            throw verificationError
        }
        let didRetainAccess = retainSteamStorageAuthorization(authorization)
        if oldRoot.path != newRoot.path {
            releaseSteamStorageSecurityScopedAccess(for: oldRoot)
        }
        return didRetainAccess
    }

    private static func verifyPersistedSteamStorageMount(
        in modelContext: ModelContext,
        expectedID: String,
        expectedPath: String,
        expectedBookmark: Data?
    ) throws {
        let normalizedPath = URL(
            fileURLWithPath: expectedPath,
            isDirectory: true
        ).standardizedFileURL.path
        let verificationContext = ModelContext(modelContext.container)
        let persistedRecords = try verificationContext.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        )
        let matchingRecords = persistedRecords.filter {
            $0.url.path == normalizedPath
        }
        guard matchingRecords.count == 1,
              let persisted = matchingRecords.first,
              persisted.id == expectedID,
              persisted.bookmark == expectedBookmark else {
            throw SteamStorageMountMutationError.persistenceVerificationFailed(
                normalizedPath
            )
        }
    }

    private static func restorePersistedSteamStorageMutation(
        in modelContext: ModelContext,
        mountSnapshots: [SteamStorageMountPersistenceSnapshot],
        affectedMountIDs: Set<String>,
        affectedMountPaths: Set<String>,
        gameSnapshots: [SteamGamePersistenceSnapshot]
    ) throws {
        let normalizedAffectedPaths = Set(affectedMountPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        })
        let recoveryContext = ModelContext(modelContext.container)
        let persistedMounts = try recoveryContext.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        )
        let mountSnapshotsByID = Dictionary(
            uniqueKeysWithValues: mountSnapshots.map { ($0.id, $0) }
        )
        var restoredMountIDs = Set<String>()

        for persistedMount in persistedMounts {
            if let snapshot = mountSnapshotsByID[persistedMount.id] {
                snapshot.apply(to: persistedMount)
                restoredMountIDs.insert(snapshot.id)
            } else if affectedMountIDs.contains(persistedMount.id) ||
                        normalizedAffectedPaths.contains(persistedMount.url.path) {
                recoveryContext.delete(persistedMount)
            }
        }
        for snapshot in mountSnapshots
        where !restoredMountIDs.contains(snapshot.id) {
            recoveryContext.insert(snapshot.makeRecord())
        }

        let persistedGames = try recoveryContext.fetch(
            FetchDescriptor<SteamGameRecord>()
        )
        let gameSnapshotsByID = Dictionary(
            uniqueKeysWithValues: gameSnapshots.map {
                ($0.steamAppId, $0)
            }
        )
        var restoredGameIDs = Set<String>()
        for persistedGame in persistedGames {
            guard let snapshot = gameSnapshotsByID[persistedGame.steamAppId] else {
                continue
            }
            snapshot.apply(to: persistedGame)
            restoredGameIDs.insert(snapshot.steamAppId)
        }
        for snapshot in gameSnapshots
        where !restoredGameIDs.contains(snapshot.steamAppId) {
            recoveryContext.insert(snapshot.makeRecord())
        }
        try recoveryContext.saveOrRollback()

        let verificationContext = ModelContext(modelContext.container)
        let verifiedMounts = try verificationContext.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        ).filter {
            mountSnapshotsByID[$0.id] != nil ||
                affectedMountIDs.contains($0.id) ||
                normalizedAffectedPaths.contains($0.url.path)
        }
        guard verifiedMounts.count == mountSnapshots.count,
              verifiedMounts.allSatisfy({
                  guard let snapshot = mountSnapshotsByID[$0.id] else {
                      return false
                  }
                  return snapshot.matches($0)
              }) else {
            throw SteamStorageMountMutationError.persistenceVerificationFailed(
                normalizedAffectedPaths.sorted().joined(separator: ", ")
            )
        }

        let verifiedGames = try verificationContext.fetch(
            FetchDescriptor<SteamGameRecord>()
        ).filter { gameSnapshotsByID[$0.steamAppId] != nil }
        guard verifiedGames.count == gameSnapshots.count,
              verifiedGames.allSatisfy({
                  guard let snapshot = gameSnapshotsByID[$0.steamAppId] else {
                      return false
                  }
                  return snapshot.matches($0)
              }) else {
            throw SteamStorageMountMutationError.persistenceVerificationFailed(
                "Steam game reference recovery"
            )
        }
    }

    func restoreSteamStorageAccess(
        from storageMounts: [SteamStorageMountRecord],
        legacyGameRecords: [SteamGameRecord],
        in modelContext: ModelContext,
        allowsPathFallback: Bool = !ForgePlaySandboxPolicy.isAppSandboxEnabled,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL = {
            try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0)
        },
        securityScopeStarter: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    ) -> SteamLibraryAccessRestoration {
        var effectiveMounts = storageMounts
        var migrationPersistenceFailed = false

        let mountAccess = restoreSteamStorageMountAccess(
            from: effectiveMounts,
            in: modelContext,
            allowsPathFallback: allowsPathFallback,
            reportsUnavailableAccess: false,
            bookmarkResolver: bookmarkResolver,
            securityScopeStarter: securityScopeStarter
        )
        let activeMountRoots = Self.collapsedSteamStorageRoots(
            mountAccess.roots
        )
        let legacyFallbackRecords = legacyGameRecords.filter {
            guard $0.libraryBookmark != nil else { return false }
            let libraryRoot = URL(
                fileURLWithPath: $0.libraryPath,
                isDirectory: true
            )
            return !activeMountRoots.contains {
                Self.isURLCanonicallyContained(libraryRoot, by: $0)
            }
        }
        let legacyByPath = Dictionary(grouping: legacyFallbackRecords) {
            URL(fileURLWithPath: $0.libraryPath, isDirectory: true)
                .standardizedFileURL.path
        }
        let legacyAccess = restoreSteamLibraryAccess(
            from: legacyFallbackRecords,
            in: modelContext,
            allowsPathFallback: allowsPathFallback,
            reportsUnavailableAccess: false,
            bookmarkResolver: bookmarkResolver,
            securityScopeStarter: securityScopeStarter
        )

        if !legacyAccess.bookmarkPersistenceFailed {
            do {
                var didUpdateMount = false
                var mountsByPath: [String: SteamStorageMountRecord] = [:]
                for mount in effectiveMounts where mountsByPath[mount.url.path] == nil {
                    mountsByPath[mount.url.path] = mount
                }
                for path in legacyAccess.restoredBookmarkPaths.sorted() {
                    guard let bookmark = legacyByPath[path]?.compactMap(\.libraryBookmark).first else { continue }
                    if let mount = mountsByPath[path] {
                        if mount.bookmark != bookmark {
                            mount.bookmark = bookmark
                            mount.updatedAt = Date()
                            didUpdateMount = true
                        }
                    } else {
                        _ = try modelContext.upsertSteamStorageMount(
                            url: URL(fileURLWithPath: path, isDirectory: true),
                            bookmark: bookmark
                        )
                        didUpdateMount = true
                    }
                }
                if didUpdateMount {
                    try modelContext.saveOrRollback()
                    effectiveMounts = try modelContext.fetch(FetchDescriptor<SteamStorageMountRecord>())
                }
            } catch {
                modelContext.rollback()
                migrationPersistenceFailed = true
                setNotice(
                    localizedFormat(
                        "기존 Steam 라이브러리 접근 권한을 저장공간 연결로 전환하지 못했습니다: %@",
                        forgePlayTechnicalErrorSummary(error)
                    ),
                    kind: .warning
                )
            }
        }

        let roots = Self.collapsedSteamStorageRoots(
            mountAccess.roots + legacyAccess.roots
        )
        let expectedSourcePaths = Set(effectiveMounts.map { $0.url.path }).union(legacyByPath.keys)
        let ancestorCoveredSourcePaths = Set(expectedSourcePaths.filter { path in
            let sourceRoot = URL(fileURLWithPath: path, isDirectory: true)
            return roots.contains {
                Self.isURLCanonicallyContained(sourceRoot, by: $0)
            }
        })
        let restoredSourcePaths = mountAccess.restoredSourcePaths
            .union(legacyAccess.restoredSourcePaths)
            .union(ancestorCoveredSourcePaths)
        let unavailableCount = expectedSourcePaths.subtracting(restoredSourcePaths).count
        if unavailableCount > 0 {
            setNotice(
                localizedFormat("%d개 Steam 저장공간 접근 권한을 복원하지 못했습니다. 해당 폴더를 다시 연결하세요.", unavailableCount),
                kind: .warning
            )
        }
        return SteamLibraryAccessRestoration(
            roots: roots,
            unavailableCount: unavailableCount,
            bookmarkPersistenceFailed: migrationPersistenceFailed ||
                mountAccess.bookmarkPersistenceFailed ||
                legacyAccess.bookmarkPersistenceFailed,
            restoredSourcePaths: restoredSourcePaths,
            restoredBookmarkPaths: mountAccess.restoredBookmarkPaths.union(legacyAccess.restoredBookmarkPaths),
            driveReservationRoots: Self.driveReservationRoots(
                activeRoots: roots,
                expectedSourcePaths: expectedSourcePaths,
                restoredSourcePaths: restoredSourcePaths
            )
        )
    }

    /// Restores external Steam storage from a fresh SwiftData fetch.
    ///
    /// SwiftUI `@Query` collections are presentation snapshots and can lag a
    /// just-completed storage connection save by a render pass. Launch and
    /// library scans must use the persisted model state instead, so all
    /// execution surfaces enter through this method immediately before they
    /// prepare external storage access.
    func restorePersistedSteamStorageAccess(
        in modelContext: ModelContext,
        allowsPathFallback: Bool = !ForgePlaySandboxPolicy.isAppSandboxEnabled,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL = {
            try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0)
        },
        securityScopeStarter: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    ) throws -> SteamLibraryAccessRestoration {
        let persistedMounts = try modelContext.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        )
        let persistedGames = try modelContext.fetch(
            FetchDescriptor<SteamGameRecord>()
        )
        var restoration = restoreSteamStorageAccess(
            from: persistedMounts,
            legacyGameRecords: persistedGames,
            in: modelContext,
            allowsPathFallback: allowsPathFallback,
            bookmarkResolver: bookmarkResolver,
            securityScopeStarter: securityScopeStarter
        )
        restoration.sourceGameRecordCount = persistedGames.count
        return restoration
    }

    func restoredSteamLibraryRoots(
        from records: [SteamGameRecord],
        in modelContext: ModelContext,
        allowsPathFallback: Bool = !ForgePlaySandboxPolicy.isAppSandboxEnabled,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL = {
            try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0)
        },
        securityScopeStarter: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    ) -> [URL] {
        restoreSteamLibraryAccess(
            from: records,
            in: modelContext,
            allowsPathFallback: allowsPathFallback,
            bookmarkResolver: bookmarkResolver,
            securityScopeStarter: securityScopeStarter
        ).roots
    }

    func authorizeSteamLibrarySelections(
        _ selectedURLs: [URL],
        normalizedRoots: (URL) -> [URL]
    ) -> SteamLibrarySelectionAuthorization {
        var roots: [URL] = []
        var bookmarksByPath: [String: Data] = [:]

        for selectedURL in selectedURLs {
            let selected = selectedURL.standardizedFileURL
            for normalizedRoot in normalizedRoots(selected) {
                let root = normalizedRoot.standardizedFileURL
                if ForgePlaySandboxPolicy.isAppSandboxEnabled,
                   root.path != selected.path {
                    setNotice(
                        localized("샌드박스 배포 앱에서는 steamapps 하위 폴더가 아니라 그 폴더를 포함하는 SteamLibrary 루트를 선택하세요."),
                        kind: .warning
                    )
                    continue
                }

                let bookmark = bookmarkData(for: selected, role: .steamLibrary)
                if ForgePlaySandboxPolicy.isAppSandboxEnabled, bookmark == nil {
                    continue
                }
                if let previous = retainedSteamLibrarySecurityScopedURLs.removeValue(forKey: root.path) {
                    previous.stopAccessingSecurityScopedResource()
                }
                if selected.startAccessingSecurityScopedResource() {
                    retainedSteamLibrarySecurityScopedURLs[root.path] = selected
                }
                roots.append(root)
                if let bookmark {
                    bookmarksByPath[root.path] = bookmark
                }
            }
        }

        return SteamLibrarySelectionAuthorization(
            roots: roots,
            bookmarksByPath: bookmarksByPath
        )
    }

    func authorizeSteamStorageSelection(
        _ selectedURL: URL,
        healthService: SteamStorageHealthService = SteamStorageHealthService()
    ) async -> SteamStorageSelectionAuthorization? {
        do {
            let validation = try await healthService.validateSelection(
                selectedURL,
                requiresSecurityScope: ForgePlaySandboxPolicy.isAppSandboxEnabled
            )
            return SteamStorageSelectionAuthorization(
                root: validation.root,
                bookmark: validation.bookmark
            )
        } catch is CancellationError {
            return nil
        } catch {
            setError(
                error,
                operationIdentifier: "steam-storage-selection",
                surfaceIdentifier: "steam-launch-storage"
            )
            return nil
        }
    }

    /// Owns a storage authorization task at application scope so navigating
    /// away from `SteamLaunchView` cannot cancel validation after the user has
    /// already granted folder access.
    @discardableResult
    func beginSteamStorageConnectionOperation(
        id: String,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard steamStorageConnectionTask == nil,
              steamStorageOperationMountID == nil else {
            return false
        }

        steamStorageOperationMountID = id
        steamStorageConnectionTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   self.steamStorageOperationMountID == id {
                    self.steamStorageOperationMountID = nil
                    self.steamStorageConnectionTask = nil
                }
            }
            await operation()
        }
        return true
    }

    private func retainSteamStorageAuthorization(
        _ authorization: SteamStorageSelectionAuthorization,
        allowsPathFallback: Bool = !ForgePlaySandboxPolicy.isAppSandboxEnabled
    ) -> Bool {
        let root = authorization.root.standardizedFileURL
        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: root.path,
            bookmark: authorization.bookmark,
            role: .steamLibrary,
            allowsPathFallback: allowsPathFallback
        )

        switch resolution {
        case .restored(let access):
            let previous = retainedSteamLibrarySecurityScopedURLs.updateValue(
                access.url,
                forKey: root.path
            )
            previous?.stopAccessingSecurityScopedResource()
            return true
        case .pathFallback:
            return true
        case .unavailable, .empty:
            return false
        }
    }

    private nonisolated static func isURL(_ candidate: URL, containedBy root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private nonisolated static func isURLCanonicallyContained(
        _ candidate: URL,
        by root: URL
    ) -> Bool {
        let canonicalCandidate = candidate
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalRoot = root
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return isURL(canonicalCandidate, containedBy: canonicalRoot)
    }

    private nonisolated static func collapsedSteamStorageRoots(
        _ roots: [URL]
    ) -> [URL] {
        let candidates = roots.map {
            (
                original: $0.standardizedFileURL,
                canonical: $0
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            )
        }.sorted {
            if $0.canonical.pathComponents.count !=
                $1.canonical.pathComponents.count {
                return $0.canonical.pathComponents.count <
                    $1.canonical.pathComponents.count
            }
            let canonicalOrder = $0.canonical.path.localizedStandardCompare(
                $1.canonical.path
            )
            if canonicalOrder != .orderedSame {
                return canonicalOrder == .orderedAscending
            }
            return $0.original.path.localizedStandardCompare(
                $1.original.path
            ) == .orderedAscending
        }

        var collapsed: [(original: URL, canonical: URL)] = []
        for candidate in candidates {
            guard !collapsed.contains(where: {
                isURL(candidate.canonical, containedBy: $0.canonical)
            }) else {
                continue
            }
            collapsed.append(candidate)
        }
        return collapsed
            .map(\.original)
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
    }

    private nonisolated static func rebasedPath(
        _ path: String,
        from sourceRoot: URL,
        to destinationRoot: URL
    ) -> String? {
        let source = sourceRoot.standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard isURL(candidate, containedBy: source) else { return nil }
        guard candidate.path != source.path else { return destination.path }

        let relativePath = String(candidate.path.dropFirst(source.path.count + 1))
        return destination
            .appending(path: relativePath)
            .standardizedFileURL
            .path
    }

    private nonisolated static func resolveSteamLibraryBookmarkCandidates(
        path: String,
        bookmarks: [Data],
        allowsPathFallback: Bool,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL,
        securityScopeStarter: (URL) -> Bool
    ) -> (resolution: SecurityScopedBookmarkResolution, bookmark: Data?) {
        var seenBookmarks = Set<Data>()
        for bookmark in bookmarks where !bookmark.isEmpty && seenBookmarks.insert(bookmark).inserted {
            let resolution = SecurityScopedBookmarkPolicy.resolve(
                path: path,
                bookmark: bookmark,
                role: .steamLibrary,
                allowsPathFallback: false,
                bookmarkResolver: bookmarkResolver,
                securityScopeStarter: securityScopeStarter
            )
            if case .restored = resolution {
                return (resolution, bookmark)
            }
        }

        return (
            SecurityScopedBookmarkPolicy.resolve(
                path: path,
                bookmark: nil,
                role: .steamLibrary,
                allowsPathFallback: allowsPathFallback,
                bookmarkResolver: bookmarkResolver,
                securityScopeStarter: securityScopeStarter
            ),
            nil
        )
    }

    private nonisolated static func driveReservationRoots(
        activeRoots: [URL],
        expectedSourcePaths: Set<String>,
        restoredSourcePaths: Set<String>
    ) -> [URL] {
        let unresolvedRoots = expectedSourcePaths
            .subtracting(restoredSourcePaths)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return Dictionary(
            grouping: activeRoots + unresolvedRoots,
            by: { $0.standardizedFileURL.path }
        ).keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func migrateRetainedSteamLibrarySecurityScope(
        from sourcePath: String,
        to destinationPath: String
    ) {
        guard sourcePath != destinationPath,
              let retained = retainedSteamLibrarySecurityScopedURLs.removeValue(forKey: sourcePath) else {
            return
        }
        if let previous = retainedSteamLibrarySecurityScopedURLs.removeValue(forKey: destinationPath) {
            previous.stopAccessingSecurityScopedResource()
        }
        retainedSteamLibrarySecurityScopedURLs[destinationPath] = retained
    }

    private func resolvedPersistedFileSelection(
        path: String?,
        bookmark: Data?,
        role: PersistedFileSelectionRole
    ) -> PersistedFileSelectionLoadResult {
        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: path,
            bookmark: bookmark,
            role: role,
            allowsPathFallback: !ForgePlaySandboxPolicy.isAppSandboxEnabled
        )
        switch resolution {
        case .restored(let access):
            if access.didStartSecurityScope {
                releaseSecurityScopedAccess(for: role)
                retainedSecurityScopedURLs[role] = access.url
            }
            var bookmarkRefreshFailure: SecurityScopedBookmarkCreationFailure?
            let refreshedBookmark = access.isStale
                ? bookmarkData(for: access.url, role: role) {
                    bookmarkRefreshFailure = $0
                }
                : nil
            if let bookmarkRefreshFailure {
                setNotice(bookmarkCreationFailureMessage(bookmarkRefreshFailure), kind: .warning)
            } else if access.isStale && refreshedBookmark == nil {
                setNotice(
                    localizedFormat(
                        "저장된 %@ 접근 권한이 만료되었습니다. 시스템 선택 창에서 다시 선택하세요.",
                        localized(role.displayNameKey)
                    ),
                    kind: .warning
                )
            }
            return PersistedFileSelectionLoadResult(
                url: access.url,
                refreshedBookmark: refreshedBookmark
            )
        case .pathFallback(let url):
            return PersistedFileSelectionLoadResult(url: url, refreshedBookmark: nil)
        case .unavailable(let failure):
            setNotice(
                localizedFormat(
                    "저장된 %@ 접근 권한을 복원하지 못했습니다. 시스템 선택 창에서 다시 선택하세요.",
                    localized(failure.role.displayNameKey)
                ),
                kind: .warning
            )
            return PersistedFileSelectionLoadResult(url: nil, refreshedBookmark: nil)
        case .empty:
            return PersistedFileSelectionLoadResult(url: nil, refreshedBookmark: nil)
        }
    }

    func bookmarkData(
        for url: URL,
        role: PersistedFileSelectionRole,
        onFailure: ((SecurityScopedBookmarkCreationFailure) -> Void)? = nil
    ) -> Data? {
        switch SecurityScopedBookmarkPolicy.createBookmarkData(for: url, role: role) {
        case .success(let data):
            return data
        case .failure(let failure):
            if let onFailure {
                onFailure(failure)
            } else {
                setNotice(bookmarkCreationFailureMessage(failure), kind: .warning)
            }
            return nil
        }
    }

    private func bookmarkData(
        for url: URL,
        role: PersistedFileSelectionRole,
        bookmarkCreator: (URL) throws -> Data
    ) -> Data? {
        switch SecurityScopedBookmarkPolicy.createBookmarkData(
            for: url,
            role: role,
            bookmarkCreator: bookmarkCreator
        ) {
        case .success(let data):
            return data
        case .failure(let failure):
            setNotice(bookmarkCreationFailureMessage(failure), kind: .warning)
            return nil
        }
    }

    func bookmarkCreationFailureMessage(_ failure: SecurityScopedBookmarkCreationFailure) -> String {
        localizedFormat(
            "선택한 %@ 접근 권한을 저장하지 못했습니다. 시스템 선택 창에서 다시 선택해야 할 수 있습니다: %@",
            localized(failure.role.displayNameKey),
            failure.reason
        )
    }

    deinit {
        steamStorageConnectionTask?.cancel()
        for url in retainedSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        for url in retainedSteamLibrarySecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { path }
}

struct SteamLibraryAccessRestoration: Hashable {
    var roots: [URL]
    var unavailableCount: Int
    var bookmarkPersistenceFailed: Bool = false
    var restoredSourcePaths: Set<String> = []
    var restoredBookmarkPaths: Set<String> = []
    var driveReservationRoots: [URL] = []
    var sourceGameRecordCount = 0

    var allowsRemovingStaleReferences: Bool {
        unavailableCount == 0 && !bookmarkPersistenceFailed
    }

    func hasSteamReferencesAfterScan(scannedCount: Int, existingCount: Int) -> Bool {
        scannedCount > 0 || (!allowsRemovingStaleReferences && existingCount > 0)
    }
}

enum DiagnosticRecordPersistenceError: LocalizedError, Equatable {
    case utf8ConversionFailed

    var errorDescription: String? {
        switch self {
        case .utf8ConversionFailed:
            "진단 기록 JSON을 UTF-8 텍스트로 저장하지 못했습니다."
        }
    }
}

extension ModelContext {
    @discardableResult
    func insertDiagnosticRecords(
        _ diagnostics: [DiagnosticResult],
        gameId: String? = nil,
        launchRecordId: String? = nil,
        source: DiagnosticRecordSource = .ruleEngine,
        aiMetadata: AIDiagnosticRecordMetadataV1? = nil
    ) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var insertedCount = 0
        for diagnostic in diagnostics {
            let data = try encoder.encode(diagnostic)
            guard let json = String(data: data, encoding: .utf8) else {
                throw DiagnosticRecordPersistenceError.utf8ConversionFailed
            }
            insert(DiagnosticRecord(
                gameId: gameId,
                launchRecordId: launchRecordId,
                source: source.rawValue,
                resultJSON: json,
                evidenceEnvelopeJSON: aiMetadata?.evidenceEnvelopeJSON,
                evidenceEnvelopeSHA256: aiMetadata?.evidenceEnvelopeSHA256,
                executionReceiptJSON: aiMetadata?.executionReceiptJSON,
                normalizedResultSHA256: aiMetadata?.normalizedResultSHA256,
                proposalDisposition: aiMetadata?.proposalDisposition
            ))
            insertedCount += 1
        }
        return insertedCount
    }

    @discardableResult
    func saveDiagnosticRecords(
        _ diagnostics: [DiagnosticResult],
        gameId: String? = nil,
        launchRecordId: String? = nil,
        source: DiagnosticRecordSource = .ruleEngine,
        aiMetadata: AIDiagnosticRecordMetadataV1? = nil
    ) throws -> Int {
        do {
            let insertedCount = try insertDiagnosticRecords(
                diagnostics,
                gameId: gameId,
                launchRecordId: launchRecordId,
                source: source,
                aiMetadata: aiMetadata
            )
            guard insertedCount > 0 else { return 0 }
            try saveOrRollback()
            return insertedCount
        } catch {
            rollback()
            throw error
        }
    }
}

enum DiagnosticGuidanceBuilder {
    static func diagnostics(
        ruleEngine: RuleEngine,
        logText: String,
        game: SteamGame? = nil,
        recipe: CompatibilityRecipe? = nil,
        context: DiagnosticRuleContext = .manualLog,
        language: ForgePlayLanguageMode,
        fallbackReason: String
    ) -> [DiagnosticResult] {
        let diagnostics = ruleEngine.analyze(
            logText: logText,
            game: game,
            recipe: recipe,
            context: context
        )
        guard diagnostics.isEmpty else { return diagnostics }

        return [DiagnosticResult(
            category: .unknown,
            confidence: 0.25,
            userMessage: ForgePlayLocalization.localized(
                "실행은 실패했지만 로컬 규칙으로는 원인을 특정하지 못했습니다.",
                language: language
            ),
            technicalSummary: ForgePlayLocalization.localized(
                "프로세스가 로컬 Rule Engine 매칭 없이 실패했습니다.",
                language: language
            ),
            riskLevel: .low,
            recommendedActions: [RecommendedAction(
                type: .noAction,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: false,
                riskLevel: .low,
                reason: fallbackReason
            )]
        )]
    }
}
