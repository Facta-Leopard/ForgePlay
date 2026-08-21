#if DEBUG
import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class DebugLaunchOptionsTests: XCTestCase {
    func testUIFixtureLaunchOptionsAlwaysRequireEphemeralStore() {
        for key in ForgePlayApp.ephemeralDebugLaunchKeys {
            XCTAssertTrue(
                ForgePlayApp.debugLaunchRequiresEphemeralStore(
                    environment: [key: "fixture"],
                    arguments: []
                ),
                key
            )
            XCTAssertTrue(
                ForgePlayApp.debugLaunchRequiresEphemeralStore(
                    environment: [:],
                    arguments: ["ForgePlay", "--\(key)=fixture"]
                ),
                key
            )
        }
    }

    func testTerminationQAHooksDoNotForceEphemeralStore() {
        XCTAssertFalse(
            ForgePlayApp.debugLaunchRequiresEphemeralStore(
                environment: ["FORGEPLAY_QA_AUTO_TERMINATE_AFTER_SECONDS": "2"],
                arguments: []
            )
        )
    }

    func testDebugLaunchOptionPresentsRuntimeCatalogFromEnvironment() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SHEET": "runtimeCatalog"],
            arguments: []
        )

        XCTAssertEqual(appState.presentedSheet?.id, SheetDestination.chooseRuntimeInstallerCatalog.id)
    }

    func testDebugLaunchOptionPresentsSteamInstallerSheet() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SHEET": "steamInstaller"],
            arguments: []
        )

        XCTAssertEqual(appState.presentedSheet?.id, SheetDestination.chooseSteamInstaller.id)
    }

    func testDebugLaunchOptionSelectsSection() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SECTION": "settings"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .settings)
    }

    func testDebugLaunchOptionSelectsSteamLaunchSectionByCanonicalName() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SECTION": "steamLaunch"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .steamLaunch)
    }

    func testDebugLaunchOptionIgnoresUnknownSection() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SECTION": "hidden"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .dashboard)
    }

    func testDebugLaunchOptionPresentsSpecificRuntimeFromArgument() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_SHEET=runtime:vcrun2022"]
        )

        XCTAssertEqual(appState.presentedSheet?.id, SheetDestination.chooseRuntimeInstaller(.vcrun2022).id)
    }

    func testDebugLaunchOptionIgnoresUnsupportedValues() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SHEET": "runtime:../../bad"],
            arguments: []
        )

        XCTAssertNil(appState.presentedSheet)
    }

    func testDebugLaunchOptionAppliesDynamicTypeFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_DYNAMIC_TYPE": "accessibility3"],
            arguments: []
        )

        XCTAssertEqual(appState.debugDynamicTypeSize, .accessibility3)
    }

    func testDebugLaunchOptionAppliesThemeFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_THEME": ForgePlayThemeMode.burntSienna.rawValue],
            arguments: []
        )

        XCTAssertEqual(appState.themeMode, .burntSienna)
    }

    func testDebugLaunchOptionAppliesLanguageFixtureFromRawValueArgument() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_LANGUAGE=german"]
        )

        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertEqual(appState.debugLanguageModeOverride, .german)
        XCTAssertEqual(appState.effectiveLanguageMode, .german)
    }

    func testDebugLaunchOptionIgnoresLanguageFixtureFromAmbientEnvironment() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_LANGUAGE": "german"],
            arguments: []
        )

        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertNil(appState.debugLanguageModeOverride)
        XCTAssertEqual(appState.effectiveLanguageMode, .system)
    }

    func testDebugLaunchOptionAppliesLanguageFixtureFromLocaleIdentifierArgument() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_LANGUAGE=zh-Hant"]
        )

        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertEqual(appState.debugLanguageModeOverride, .traditionalChinese)
        XCTAssertEqual(appState.effectiveLanguageMode, .traditionalChinese)
    }

    func testDebugLaunchOptionIgnoresUnknownLanguageFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_LANGUAGE=pirate"]
        )

        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertNil(appState.debugLanguageModeOverride)
        XCTAssertEqual(appState.effectiveLanguageMode, .system)
    }

    func testDebugLanguageFixtureDoesNotPersistAsUserLanguageSelection() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_LANGUAGE=german"]
        )
        appState.save(to: context)

        let settings = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.system.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, false)
        XCTAssertEqual(appState.effectiveLanguageMode, .german)
    }

    func testUserLanguageSelectionClearsDebugLanguageFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_LANGUAGE=german"]
        )
        appState.setLanguageModeFromUserSelection(.korean)

        XCTAssertNil(appState.debugLanguageModeOverride)
        XCTAssertEqual(appState.languageMode, .korean)
        XCTAssertEqual(appState.effectiveLanguageMode, .korean)
    }

    func testSystemLanguageSelectionClearsDebugLanguageFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_LANGUAGE=german"]
        )
        appState.setLanguageModeFromUserSelection(.system)

        XCTAssertNil(appState.debugLanguageModeOverride)
        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertEqual(appState.effectiveLanguageMode, .system)
    }

    func testDebugLaunchOptionCanResetLanguageFixtureToSystemAfterLaunch() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: [
                "ForgePlay",
                "--FORGEPLAY_QA_LANGUAGE=german",
                "--FORGEPLAY_QA_RESET_LANGUAGE_TO_SYSTEM_AFTER_LAUNCH=1"
            ]
        )
        XCTAssertEqual(appState.effectiveLanguageMode, .german)
        XCTAssertTrue(appState.debugShouldResetLanguageToSystemAfterLaunch)

        await appState.applyDebugPostLaunchActionsIfNeeded(saveTo: context, resetDelay: .zero)

        let settings = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertFalse(appState.debugShouldResetLanguageToSystemAfterLaunch)
        XCTAssertNil(appState.debugLanguageModeOverride)
        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertEqual(appState.effectiveLanguageMode, .system)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.system.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, false)
        XCTAssertNil(settings.languageModeOverrideSource)
    }

    func testDebugLaunchOptionCanDismissPresentedSheetAfterLaunch() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: [
                "ForgePlay",
                "--FORGEPLAY_QA_SECTION=setup",
                "--FORGEPLAY_QA_SHEET=apple-renderer",
                "--FORGEPLAY_QA_DISMISS_SHEET_AFTER_LAUNCH=1"
            ]
        )

        XCTAssertEqual(appState.selectedSection, .setup)
        XCTAssertEqual(appState.presentedSheet?.id, SheetDestination.importAppleSupplementalRenderer.id)
        XCTAssertTrue(appState.debugShouldDismissPresentedSheetAfterLaunch)

        await appState.applyDebugPostLaunchActionsIfNeeded(saveTo: context, resetDelay: .zero)

        XCTAssertFalse(appState.debugShouldDismissPresentedSheetAfterLaunch)
        XCTAssertNil(appState.presentedSheet)
    }

    func testProgrammaticLanguageModeChangeDoesNotPersistAsUserLanguageSelection() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let appState = AppState()

        appState.languageMode = .german
        appState.save(to: context)

        let settings = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.system.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, false)
        XCTAssertNil(settings.languageModeOverrideSource)
    }

    func testUserLanguageSelectionPersistsWithUserSource() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let appState = AppState()

        appState.setLanguageModeFromUserSelection(.german)
        appState.save(to: context)

        let settings = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.german.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, true)
        XCTAssertEqual(settings.languageModeOverrideSource, AppLanguageModeOverrideSource.userSettings.rawValue)
    }

    func testPersistedLegacyLanguageWithoutExplicitOverrideFallsBackToSystem() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(languageMode: ForgePlayLanguageMode.german.rawValue)
        settings.isLanguageModeOverrideEnabled = nil
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertEqual(appState.effectiveLanguageMode, .system)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.system.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, false)
    }

    func testPersistedLegacyLanguageOverrideWithoutUserSourceFallsBackToSystem() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            languageMode: ForgePlayLanguageMode.german.rawValue,
            isLanguageModeOverrideEnabled: true
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        XCTAssertEqual(appState.languageMode, .system)
        XCTAssertEqual(appState.effectiveLanguageMode, .system)
        XCTAssertEqual(settings.languageMode, ForgePlayLanguageMode.system.rawValue)
        XCTAssertEqual(settings.isLanguageModeOverrideEnabled, false)
        XCTAssertNil(settings.languageModeOverrideSource)
    }

    func testPersistedUserLanguageOverrideIsLoaded() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            languageMode: ForgePlayLanguageMode.german.rawValue,
            isLanguageModeOverrideEnabled: true,
            languageModeOverrideSource: AppLanguageModeOverrideSource.userSettings.rawValue
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        XCTAssertEqual(appState.languageMode, .german)
        XCTAssertEqual(appState.effectiveLanguageMode, .german)
    }

    func testDebugLaunchOptionBuildsDiagnosticsPreviewFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_DIAGNOSTICS_PREVIEW": "1"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .diagnostics)
        XCTAssertTrue(appState.debugDiagnosticsPreviewFixture)
    }

    func testDebugLaunchOptionBuildsDiagnosticsPreviewFixtureFromArgument() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: [:],
            arguments: ["ForgePlay", "--FORGEPLAY_QA_DIAGNOSTICS_PREVIEW=true"]
        )

        XCTAssertEqual(appState.selectedSection, .diagnostics)
        XCTAssertTrue(appState.debugDiagnosticsPreviewFixture)
    }

    func testDebugLaunchOptionBuildsSteamLaunchLayoutFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_STEAM_LAUNCH_FIXTURE": "1"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .steamLaunch)
        XCTAssertTrue(appState.debugSteamLaunchLayoutFixture)
    }

    func testDebugLaunchOptionBuildsAppStoreScreenshotFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE": "steamLaunch"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .steamLaunch)
        XCTAssertTrue(appState.debugAppStoreScreenshotFixture)
        XCTAssertEqual(appState.effectiveLanguageMode, .english)
        XCTAssertEqual(appState.latestChecks.map(\.status), [.ok])
        XCTAssertEqual(appState.selectedRootURL?.path, "/Sample Games/ForgePlay Library")
        XCTAssertEqual(
            appState.runtimeExecutableURL?.path,
            ForgePlayDevelopmentFixturePaths.appStoreScreenshotRuntimeExecutablePath
        )
    }

    func testAppStoreScreenshotFixtureDoesNotOverwriteUserRootOrPersistLegacyRuntimeSelection() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let userRoot = URL(fileURLWithPath: "/tmp/UserForgePlayRoot", isDirectory: true)
        let settings = AppSettingsRecord(
            selectedRootPath: userRoot.path,
            gptkExecutablePath: "/tmp/legacy-runtime/wine",
            gptkExecutableBookmark: Data("retired-runtime-bookmark".utf8)
        )
        context.insert(settings)
        try context.save()
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE": "steamLaunch"],
            arguments: []
        )
        appState.save(to: context)

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(reloaded.selectedRootPath, userRoot.path)
        XCTAssertNil(reloaded.gptkExecutablePath)
        XCTAssertNil(reloaded.gptkExecutableBookmark)
    }

    func testDebugLaunchOptionBuildsAppStoreDiagnosticsScreenshotFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE": "diagnostics"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .diagnostics)
        XCTAssertTrue(appState.debugAppStoreScreenshotFixture)
        XCTAssertTrue(appState.debugDiagnosticsPreviewFixture)
    }

    func testDebugLaunchOptionCanDisableSteamLaunchLayoutFixture() {
        let appState = AppState()
        appState.debugSteamLaunchLayoutFixture = true
        appState.selectedSection = .steamLaunch

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_STEAM_LAUNCH_FIXTURE": "0"],
            arguments: []
        )

        XCTAssertEqual(appState.selectedSection, .steamLaunch)
        XCTAssertFalse(appState.debugSteamLaunchLayoutFixture)
    }

    func testDebugLaunchOptionIgnoresUnknownDynamicTypeFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_DYNAMIC_TYPE": "huge"],
            arguments: []
        )

        XCTAssertNil(appState.debugDynamicTypeSize)
    }

    func testDebugLaunchOptionBuildsDiagnosticGuideFixture() {
        let appState = AppState()

        appState.applyDebugLaunchOptionsIfNeeded(
            environment: ["FORGEPLAY_QA_SHEET": "diagnosticGuide"],
            arguments: []
        )

        guard case .diagnosticGuide(let payload) = appState.presentedSheet else {
            return XCTFail("Expected diagnostic guide sheet")
        }
        XCTAssertEqual(payload.title, appState.localized("레이아웃 검증"))
        XCTAssertEqual(payload.diagnostics.count, 1)
        XCTAssertEqual(payload.diagnostics.first?.recommendedActions.count, 2)
    }

    func testVisualQAWindowCaptureScriptUsesTargetWindowID() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Scripts/capture-app-window.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(source.contains("kCGWindowOwnerName"))
        XCTAssertTrue(source.contains("process.executableURL = URL(fileURLWithPath: \"/usr/sbin/screencapture\")"))
        XCTAssertTrue(source.contains("process.arguments = [\"-x\", \"-l\", String(window.id), outputPath]"))
        XCTAssertTrue(source.contains("ownerName = \"ForgePlay\""))
    }

    func testSettingsLanguageLayoutCaptureVerifierUsesExplicitLanguageArgument() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Scripts/verify-settings-language-layout-capture.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("launchctl setenv FORGEPLAY_QA_IN_MEMORY_STORE 1"))
        XCTAssertTrue(source.contains("launch_section_capture()"))
        XCTAssertTrue(source.contains("launch_settings_capture \"settings-system\""))
        XCTAssertTrue(source.contains(#""--FORGEPLAY_QA_LANGUAGE=german""#))
        XCTAssertTrue(source.contains(#""--FORGEPLAY_QA_RESET_LANGUAGE_TO_SYSTEM_AFTER_LAUNCH=1""#))
        XCTAssertTrue(source.contains("german-to-system-reset"))
        XCTAssertTrue(source.contains("german-preview-accessibility"))
        XCTAssertTrue(source.contains("german-to-system-reset-accessibility"))
        XCTAssertTrue(source.contains("FORGEPLAY_VISUAL_QA_DYNAMIC_TYPE"))
        XCTAssertTrue(source.contains(#""--FORGEPLAY_QA_DYNAMIC_TYPE=$DYNAMIC_TYPE_CAPTURE_SIZE""#))
        XCTAssertTrue(source.contains("launchctl setenv FORGEPLAY_QA_SECTION \"$section\""))
        XCTAssertTrue(source.contains("launch_section_capture \"steamLaunch\""))
        XCTAssertTrue(source.contains("FORGEPLAY_QA_STEAM_LAUNCH_FIXTURE_FOR_CAPTURE=1"))
        XCTAssertTrue(source.contains("launchctl setenv FORGEPLAY_QA_STEAM_LAUNCH_FIXTURE \"$steam_launch_fixture\""))
        XCTAssertTrue(source.contains("launch_setup_capture \"setup-system\""))
        XCTAssertTrue(source.contains("launch_steam_launch_capture \"steam-launch-system\""))
        XCTAssertTrue(source.contains("setup-after-apple-renderer-sheet-dismiss"))
        XCTAssertTrue(source.contains(#""--FORGEPLAY_QA_SHEET=apple-renderer""#))
        XCTAssertTrue(source.contains(#""--FORGEPLAY_QA_DISMISS_SHEET_AFTER_LAUNCH=1""#))
        XCTAssertTrue(source.contains("capture-app-window.swift"))
        XCTAssertTrue(source.contains("pgrep -x ForgePlay"))
        XCTAssertTrue(source.contains("sips -g pixelWidth -g pixelHeight"))
        XCTAssertTrue(source.contains("FORGEPLAY_VISUAL_QA_ALLOW_EXISTING"))
        XCTAssertTrue(source.contains("FORGEPLAY_VISUAL_QA_LANGUAGE_RESET_CAPTURE_DELAY_SECONDS"))
    }

    func testAppStoreScreenshotCaptureScriptRegeneratesRealWindowFixtures() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Scripts/capture-app-store-screenshots.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("FORGEPLAY_QA_IN_MEMORY_STORE=1"))
        XCTAssertTrue(source.contains("FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE"))
        XCTAssertTrue(source.contains(#"capture_fixture "steamLaunch" "01-steam-launch.png""#))
        XCTAssertTrue(source.contains(#"capture_fixture "diagnostics" "02-diagnostics.png""#))
        XCTAssertTrue(source.contains(#"capture_fixture "settings" "03-setup-status.png""#))
        XCTAssertTrue(source.contains("capture-app-window.swift"))
        XCTAssertTrue(source.contains("sips -c 1800 2880"))
        XCTAssertTrue(source.contains("--cropOffset 0 0"))
        XCTAssertTrue(source.contains("Scripts/verify-app-store-screenshots.sh"))
        XCTAssertTrue(source.contains("pgrep -x ForgePlay"))
    }

    func testAppStoreScreenshotFixtureResizesRealWindowInDebugOnly() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/RootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("#if DEBUG"))
        XCTAssertTrue(source.contains("activateWindowForDebugCaptureIfNeeded"))
        XCTAssertTrue(source.contains("NSApplication.shared.activate"))
        XCTAssertTrue(source.contains("resizeAppStoreScreenshotWindowIfNeeded"))
        XCTAssertTrue(source.contains("appState.debugAppStoreScreenshotFixture"))
        XCTAssertTrue(source.contains("NSApplication.shared.windows.first"))
        XCTAssertTrue(source.contains("NSSize(width: 1440, height: 900)"))
        XCTAssertTrue(source.contains("window.setFrame"))
    }

    func testVisualQAUsesAnIsolatedInMemoryStoreWithoutCreatingPersistentFiles() throws {
        let fileManager = FileManager.default
        let persistentDirectory = fileManager.temporaryDirectory.appending(
            path: "ForgePlay-VisualQA-PersistentStore-Sentinel-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: persistentDirectory) }

        let container = try ForgePlayApp.makeModelContainer(
            isStoredInMemoryOnly: true,
            applicationSupportDirectory: persistentDirectory
        )
        let context = container.mainContext
        context.insert(AppSettingsRecord())
        try context.save()

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AppSettingsRecord>()).count,
            1
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: persistentDirectory.path),
            "An in-memory QA store must not create or touch the persistent-store directory."
        )
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
        }
        throw XCTSkip("Could not locate project root from #filePath")
    }
}
#endif
