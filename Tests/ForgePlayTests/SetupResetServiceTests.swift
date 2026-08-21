import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class SetupResetServiceTests: XCTestCase {
    func testSetupProgressResetClearsSetupStateAndPreservesAppPreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySetupReset-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let service = SetupResetService(pathManager: pathManager)
        let appState = AppState()
        try seedConfiguredState(appState: appState, context: context, root: root)
        let bundledRuntime = try XCTUnwrap(appState.runtimeExecutableURL)

        let result = try service.resetSetupProgress(appState: appState, in: context)

        XCTAssertEqual(result.clearedSelectionCount, 1)
        XCTAssertEqual(result.deletedRecordCount, 6)
        XCTAssertEqual(appState.selectedRootURL?.path, root.path)
        XCTAssertEqual(
            appState.runtimeExecutableURL?.standardizedFileURL.path,
            bundledRuntime.standardizedFileURL.path
        )
        XCTAssertNil(appState.steamInstallerURL)
        XCTAssertNil(appState.selectedSteamReference)
        XCTAssertTrue(appState.latestChecks.isEmpty)
        XCTAssertTrue(appState.activeDiagnostics.isEmpty)
        XCTAssertEqual(appState.setupStage, .checkMac)
        XCTAssertEqual(appState.selectedSection, .setup)
        XCTAssertEqual(pathManager.rootURL?.path, root.path)

        let settings = try appState.loadOrCreateSettings(in: context)
        XCTAssertEqual(settings.selectedRootPath, root.path)
        XCTAssertEqual(settings.selectedRootBookmark, Data([1, 2, 3]))
        XCTAssertEqual(settings.managedStorageLayoutVersion, ForgePlayManagedStorageLayout.currentVersion)
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertNil(settings.lastSteamInstallerPath)
        XCTAssertEqual(settings.themeMode, ForgePlayThemeMode.pumpkinSpice.rawValue)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.english.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, true)
        XCTAssertEqual(settings.languageModeOverrideSource, AppLanguageModeOverrideSource.userSettings.rawValue)
        XCTAssertTrue(settings.isLLMDiagnosticsEnabled)
        XCTAssertEqual(settings.logRetentionDays, 14)
        XCTAssertEqual(try recordCount(CompatibilityRecipeRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(PrefixRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(RuntimeRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(SteamGameRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(SteamStorageMountRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(LaunchRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(DiagnosticRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(AutoFixRecord.self, in: context), 0)
    }

    func testSetupProgressResetClearsBookmarkForDefaultInternalRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySetupReset-DefaultRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let service = SetupResetService(
            pathManager: pathManager,
            defaultManagedRootURL: { root }
        )
        let appState = AppState()
        try seedConfiguredState(appState: appState, context: context, root: root)

        _ = try service.resetSetupProgress(appState: appState, in: context)

        let settings = try appState.loadOrCreateSettings(in: context)
        XCTAssertEqual(settings.selectedRootPath, root.path)
        XCTAssertNil(settings.selectedRootBookmark)
    }

    func testSetupProgressResetDoesNotReplaceAuthorizationBlockedCustomRoot() throws {
        let customRoot = URL(fileURLWithPath: "/Volumes/Unavailable/ForgePlayData", isDirectory: true)
        let defaultRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayResetDefault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: defaultRoot) }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: customRoot.path,
            selectedRootBookmark: Data("bookmark".utf8),
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        )
        context.insert(settings)
        try context.save()
        let service = SetupResetService(
            pathManager: PathManager(),
            defaultManagedRootURL: { defaultRoot }
        )

        XCTAssertThrowsError(
            try service.resetSetupProgress(appState: AppState(), in: context)
        ) { error in
            XCTAssertEqual(
                error as? ManagedStorageActivationError,
                .managedRootAuthorizationRequired(customRoot.path)
            )
        }
        XCTAssertEqual(settings.selectedRootPath, customRoot.path)
        XCTAssertEqual(settings.selectedRootBookmark, Data("bookmark".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultRoot.path))
    }

    func testFreshDefaultManagedStorageLeavesLegacyFilesUntouchedAndResetsWorkflow() async throws {
        let legacyRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFreshLegacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaultRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFreshDefault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: legacyRoot)
            try? FileManager.default.removeItem(at: defaultRoot)
        }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        try pathManager.configureRoot(legacyRoot)
        let storageMigrationService = StorageMigrationService(pathManager: pathManager)
        let service = SetupResetService(
            pathManager: pathManager,
            storageMigrationService: storageMigrationService,
            defaultManagedRootURL: { defaultRoot }
        )
        let appState = AppState()
        try seedConfiguredState(appState: appState, context: context, root: legacyRoot)
        let legacySentinel = legacyRoot.appending(path: "Config/legacy-only.txt")
        try Data("legacy data must remain".utf8).write(to: legacySentinel)

        let result = try await service.startFreshWithDefaultManagedStorage(
            appState: appState,
            in: context
        )

        let settings = try appState.loadOrCreateSettings(in: context)
        XCTAssertEqual(result.deletedRecordCount, 6)
        XCTAssertEqual(pathManager.rootURL?.path, defaultRoot.path)
        XCTAssertEqual(appState.selectedRootURL?.path, defaultRoot.path)
        XCTAssertEqual(settings.selectedRootPath, defaultRoot.path)
        XCTAssertNil(settings.selectedRootBookmark)
        XCTAssertEqual(settings.managedStorageLayoutVersion, ForgePlayManagedStorageLayout.currentVersion)
        XCTAssertEqual(settings.legacyManagedRootPath, legacyRoot.path)
        XCTAssertNil(settings.managedStorageMigrationCompletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: defaultRoot.appending(path: "Config/legacy-only.txt").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: defaultRoot.appending(path: ForgePlayManagedStorageLayout.markerFileName).path
        ))
        XCTAssertEqual(try recordCount(PrefixRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(SteamStorageMountRecord.self, in: context), 1)
    }

    func testFreshDefaultManagedStorageEscapesUnavailablePersistedRoot() async throws {
        let unavailableRoot = URL(
            fileURLWithPath: "/Volumes/Unavailable/ForgePlayData-\(UUID().uuidString)",
            isDirectory: true
        )
        let defaultRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFreshUnavailableDefault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: defaultRoot) }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: unavailableRoot.path,
            selectedRootBookmark: Data("stale bookmark".utf8),
            managedStorageLayoutVersion: nil
        )
        context.insert(settings)
        try context.save()
        let pathManager = PathManager()
        let service = SetupResetService(
            pathManager: pathManager,
            defaultManagedRootURL: { defaultRoot }
        )
        let appState = AppState()

        _ = try await service.startFreshWithDefaultManagedStorage(appState: appState, in: context)

        XCTAssertEqual(pathManager.rootURL?.path, defaultRoot.path)
        XCTAssertEqual(appState.selectedRootURL?.path, defaultRoot.path)
        XCTAssertEqual(settings.selectedRootPath, defaultRoot.path)
        XCTAssertNil(settings.selectedRootBookmark)
        XCTAssertEqual(settings.managedStorageLayoutVersion, ForgePlayManagedStorageLayout.currentVersion)
        XCTAssertEqual(settings.legacyManagedRootPath, unavailableRoot.path)
    }

    func testPathBoundWorkflowResetKeepsExternalSelectionsAndCurrentRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPathBoundReset-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalInstaller = FileManager.default.temporaryDirectory
            .appending(path: "SteamSetup-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let service = SetupResetService(pathManager: pathManager)
        let appState = AppState()
        try seedConfiguredState(appState: appState, context: context, root: root)
        let bundledRuntime = try XCTUnwrap(appState.runtimeExecutableURL)

        let settings = try appState.loadOrCreateSettings(in: context)
        settings.lastSteamInstallerPath = externalInstaller.path
        appState.steamInstallerURL = externalInstaller
        try context.save()

        let result = try service.resetPathBoundWorkflowState(appState: appState, oldRoot: root, in: context)

        XCTAssertEqual(result.clearedSelectionCount, 0)
        XCTAssertEqual(result.deletedRecordCount, 7)
        XCTAssertEqual(appState.selectedRootURL?.path, root.path)
        XCTAssertEqual(pathManager.rootURL?.path, root.path)
        XCTAssertEqual(
            appState.runtimeExecutableURL?.standardizedFileURL.path,
            bundledRuntime.standardizedFileURL.path
        )
        XCTAssertEqual(appState.steamInstallerURL?.path, externalInstaller.path)
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerPath, externalInstaller.path)
        XCTAssertEqual(try recordCount(CompatibilityRecipeRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(PrefixRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(SteamGameRecord.self, in: context), 0)
        XCTAssertEqual(try recordCount(SteamStorageMountRecord.self, in: context), 0)
    }

    func testPathBoundWorkflowResetCanBeRolledBackWhenSaveIsDeferred() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDeferredPathBoundReset-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeModelContainer()
        let context = ModelContext(container)
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let service = SetupResetService(pathManager: pathManager)
        let appState = AppState()
        try seedConfiguredState(appState: appState, context: context, root: root)
        let settingsBeforeReset = try appState.loadOrCreateSettings(in: context)
        settingsBeforeReset.gptkExecutablePath = nil
        settingsBeforeReset.gptkExecutableBookmark = nil
        try context.save()

        _ = try service.resetPathBoundWorkflowState(
            appState: appState,
            oldRoot: root,
            in: context,
            saveImmediately: false
        )
        context.rollback()

        let settings = try appState.loadOrCreateSettings(in: context)
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerPath, root.appending(path: "RuntimeCache/Installers/SteamSetup.exe").path)
        XCTAssertEqual(try recordCount(CompatibilityRecipeRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(PrefixRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(RuntimeRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(SteamGameRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(SteamStorageMountRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(LaunchRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(DiagnosticRecord.self, in: context), 1)
        XCTAssertEqual(try recordCount(AutoFixRecord.self, in: context), 1)
    }

    private func seedConfiguredState(appState: AppState, context: ModelContext, root: URL) throws {
        let legacyRuntime = root.appending(path: "LegacyRuntimeSelection/wine")
        let bundledRuntime = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutableURL()
        let steamInstaller = root.appending(path: "RuntimeCache/Installers/SteamSetup.exe")
        let settings = try appState.loadOrCreateSettings(in: context)
        settings.selectedRootPath = root.path
        settings.selectedRootBookmark = Data([1, 2, 3])
        settings.gptkExecutablePath = legacyRuntime.path
        settings.gptkExecutableBookmark = Data([4, 5, 6])
        settings.lastSteamInstallerPath = steamInstaller.path
        settings.lastSteamInstallerBookmark = Data([7, 8, 9])
        settings.themeMode = ForgePlayThemeMode.pumpkinSpice.rawValue
        settings.languageMode = ForgePlayLanguageMode.english.rawValue
        settings.isLanguageModeOverrideEnabled = true
        settings.languageModeOverrideSource = AppLanguageModeOverrideSource.userSettings.rawValue
        settings.isLLMDiagnosticsEnabled = true
        settings.logRetentionDays = 14

        let prefix = PrefixRecord(
            id: "prefix",
            displayName: "Steam Shared",
            path: root.appending(path: "Prefixes/SteamShared").path
        )
        let game = SteamGameRecord(
            steamAppId: "42",
            name: "Reset Fixture Game",
            installDir: "Reset Fixture Game",
            libraryPath: root.appending(path: "SteamLibraries/DefaultLibrary").path,
            manifestPath: root.appending(path: "SteamLibraries/DefaultLibrary/steamapps/appmanifest_42.acf").path
        )
        let storageMount = SteamStorageMountRecord(
            path: root.appending(path: "SteamLibraries/DefaultLibrary").path,
            bookmark: Data([10, 11, 12])
        )

        context.insert(prefix)
        context.insert(RuntimeRecord(id: "runtime", prefixId: "prefix", runtime: .vcrun2022))
        context.insert(game)
        context.insert(storageMount)
        context.insert(LaunchRecord(id: "launch", gameId: "42", prefixId: "prefix", commandKind: "game"))
        context.insert(DiagnosticRecord(id: "diagnostic", gameId: "42", launchRecordId: "launch", source: "rule", resultJSON: "{}"))
        context.insert(AutoFixRecord(id: "autofix", diagnosticId: "diagnostic", actionType: .noAction, status: "pending"))
        context.insert(CompatibilityRecipeRecord(
            recipeId: "recipe",
            steamAppId: "42",
            name: "Keep Recipe",
            supportStatus: "supported",
            confidence: 1,
            recipeJSON: "{}"
        ))

        appState.selectedRootURL = root
        appState.runtimeExecutableURL = bundledRuntime
        appState.steamInstallerURL = steamInstaller
        appState.selectedSteamReference = game.game
        appState.selectedSection = .steamLaunch
        appState.setupStage = .ready
        appState.latestChecks = [
            SystemCheckResult(title: "Check", detail: "OK", status: .ok)
        ]
        appState.activeDiagnostics = [
            DiagnosticResult(
                category: .unknown,
                confidence: 0.5,
                userMessage: "Needs review",
                technicalSummary: "Test diagnostic",
                riskLevel: .low,
                recommendedActions: []
            )
        ]

        try context.save()
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            AppSettingsRecord.self,
            PrefixRecord.self,
            RuntimeRecord.self,
            SteamGameRecord.self,
            SteamStorageMountRecord.self,
            LaunchRecord.self,
            DiagnosticRecord.self,
            CompatibilityRecipeRecord.self,
            AutoFixRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func recordCount<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<T>()).count
    }
}
