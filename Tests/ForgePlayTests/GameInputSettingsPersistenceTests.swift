import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class GameInputSettingsPersistenceTests: XCTestCase {
    private struct SaveFailure: Error {}

    func testNewStateAndRecordKeepEventTapProtectionOffAndPointerHidingOnByDefault() {
        let state = AppState()
        let settings = AppSettingsRecord()

        XCTAssertFalse(state.isGameInputModifierMappingEnabled)
        XCTAssertNil(state.gameInputModifierMap)
        XCTAssertEqual(state.gameInputCommandBinding, .control)
        XCTAssertEqual(state.gameInputOptionBinding, .alt)
        XCTAssertEqual(state.gameInputControlBinding, .control)
        XCTAssertFalse(state.blocksGameAppWindowManagementShortcuts)
        XCTAssertFalse(state.blocksGameAppSwitchingShortcuts)
        XCTAssertFalse(state.blocksGameMissionControlSpaceShortcuts)
        XCTAssertFalse(state.blocksGameScreenshotShortcuts)
        XCTAssertTrue(state.hidesPointerWhileManagedGameFrontmost)
        XCTAssertFalse(state.hasEnabledGameInputEventTapProtection)
        XCTAssertTrue(state.hasEnabledGameInputProtection)
        XCTAssertEqual(settings.isGameInputModifierMappingEnabled, false)
        XCTAssertEqual(settings.blocksGameAppWindowManagementShortcuts, false)
        XCTAssertEqual(settings.blocksGameAppSwitchingShortcuts, false)
        XCTAssertEqual(settings.blocksGameMissionControlSpaceShortcuts, false)
        XCTAssertEqual(settings.blocksGameScreenshotShortcuts, false)
        XCTAssertEqual(settings.hidesPointerWhileManagedGameFrontmost, true)
        XCTAssertEqual(
            settings.gameInputProtectionPreferenceVersion,
            GameInputProtectionPreferenceSchema.currentVersion
        )
    }

    func testGameInputSettingsPersistAndReloadIndependentManyToOnePolicy() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let state = AppState()

        let warning = state.saveUserPreferencesAfterMutation(to: context) {
            state.isGameInputModifierMappingEnabled = true
            state.setGameInputModifierBinding(.command, to: .control)
            state.setGameInputModifierBinding(.option, to: .control)
            state.setGameInputModifierBinding(.control, to: .disabled)
            state.blocksGameAppWindowManagementShortcuts = true
            state.blocksGameAppSwitchingShortcuts = true
            state.blocksGameMissionControlSpaceShortcuts = true
            state.blocksGameScreenshotShortcuts = true
            state.hidesPointerWhileManagedGameFrontmost = true
        }

        XCTAssertNil(warning)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(settings.isGameInputModifierMappingEnabled, true)
        XCTAssertEqual(settings.gameInputCommandBinding, GameInputModifierBinding.control.rawValue)
        XCTAssertEqual(settings.gameInputOptionBinding, GameInputModifierBinding.control.rawValue)
        XCTAssertEqual(settings.gameInputControlBinding, GameInputModifierBinding.disabled.rawValue)
        XCTAssertEqual(settings.blocksGameAppWindowManagementShortcuts, true)
        XCTAssertEqual(settings.blocksGameAppSwitchingShortcuts, true)
        XCTAssertEqual(settings.blocksGameMissionControlSpaceShortcuts, true)
        XCTAssertEqual(settings.blocksGameScreenshotShortcuts, true)
        XCTAssertEqual(settings.hidesPointerWhileManagedGameFrontmost, true)

        let reloaded = AppState()
        try reloaded.load(from: context)
        XCTAssertTrue(reloaded.isGameInputModifierMappingEnabled)
        XCTAssertEqual(
            reloaded.gameInputModifierMap,
            GameInputModifierMap(command: .control, option: .control, control: .disabled)
        )
        XCTAssertTrue(reloaded.blocksGameAppWindowManagementShortcuts)
        XCTAssertTrue(reloaded.blocksGameAppSwitchingShortcuts)
        XCTAssertTrue(reloaded.blocksGameMissionControlSpaceShortcuts)
        XCTAssertTrue(reloaded.blocksGameScreenshotShortcuts)
        XCTAssertTrue(reloaded.hidesPointerWhileManagedGameFrontmost)
    }

    func testChangingOneBindingDoesNotRewriteOthersAndSupportsDisabled() {
        let state = AppState()

        state.isGameInputModifierMappingEnabled = true
        state.setGameInputModifierBinding(.option, to: .control)
        state.setGameInputModifierBinding(.control, to: .disabled)

        XCTAssertEqual(state.gameInputCommandBinding, .control)
        XCTAssertEqual(state.gameInputOptionBinding, .control)
        XCTAssertEqual(state.gameInputControlBinding, .disabled)
        XCTAssertEqual(
            state.gameInputModifierMap,
            GameInputModifierMap(command: .control, option: .control, control: .disabled)
        )
    }

    func testPersistedWindowsBindingNormalizesWithoutEnablingModifierMapping() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let settings = AppSettingsRecord(
            isGameInputModifierMappingEnabled: true,
            gameInputCommandBinding: GameInputModifierBinding.control.rawValue,
            gameInputOptionBinding: GameInputModifierBinding.control.rawValue,
            gameInputControlBinding: "windows",
            blocksGameAppWindowManagementShortcuts: false,
            blocksGameAppSwitchingShortcuts: false,
            blocksGameMissionControlSpaceShortcuts: false,
            blocksGameScreenshotShortcuts: false,
            hidesPointerWhileManagedGameFrontmost: false
        )
        context.insert(settings)
        try context.save()

        let state = AppState()
        try state.load(from: context)

        XCTAssertFalse(state.isGameInputModifierMappingEnabled)
        XCTAssertEqual(state.gameInputCommandBinding, .control)
        XCTAssertEqual(state.gameInputOptionBinding, .alt)
        XCTAssertEqual(state.gameInputControlBinding, .control)
        XCTAssertNil(state.gameInputModifierMap)
        XCTAssertFalse(state.hasEnabledGameInputProtection)
    }

    func testExplicitlyDisabledProtectionRemainsDisabled() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(AppSettingsRecord(
            isGameInputModifierMappingEnabled: false,
            gameInputCommandBinding: GameInputModifierBinding.control.rawValue,
            gameInputOptionBinding: GameInputModifierBinding.alt.rawValue,
            gameInputControlBinding: GameInputModifierBinding.control.rawValue,
            blocksGameAppWindowManagementShortcuts: false,
            blocksGameAppSwitchingShortcuts: false,
            blocksGameMissionControlSpaceShortcuts: false,
            blocksGameScreenshotShortcuts: false,
            hidesPointerWhileManagedGameFrontmost: false
        ))
        try context.save()

        let state = AppState()
        try state.load(from: context)

        XCTAssertFalse(state.isGameInputModifierMappingEnabled)
        XCTAssertFalse(state.blocksGameAppWindowManagementShortcuts)
        XCTAssertFalse(state.blocksGameAppSwitchingShortcuts)
        XCTAssertFalse(state.blocksGameMissionControlSpaceShortcuts)
        XCTAssertFalse(state.blocksGameScreenshotShortcuts)
        XCTAssertFalse(state.hidesPointerWhileManagedGameFrontmost)
        XCTAssertFalse(state.hasEnabledGameInputProtection)
    }

    func testFailedSaveRestoresEveryGameInputPreference() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let state = AppState()

        let warning = state.saveUserPreferencesAfterMutation(
            to: context,
            saveChanges: { _ in throw SaveFailure() }
        ) {
            state.isGameInputModifierMappingEnabled = true
            state.setGameInputModifierBinding(.command, to: .disabled)
            state.setGameInputModifierBinding(.option, to: .control)
            state.setGameInputModifierBinding(.control, to: .alt)
            state.blocksGameAppWindowManagementShortcuts = true
            state.blocksGameAppSwitchingShortcuts = true
            state.blocksGameMissionControlSpaceShortcuts = true
            state.blocksGameScreenshotShortcuts = true
            state.hidesPointerWhileManagedGameFrontmost = false
        }

        XCTAssertNotNil(warning)
        XCTAssertFalse(state.isGameInputModifierMappingEnabled)
        XCTAssertEqual(state.gameInputCommandBinding, .control)
        XCTAssertEqual(state.gameInputOptionBinding, .alt)
        XCTAssertEqual(state.gameInputControlBinding, .control)
        XCTAssertFalse(state.blocksGameAppWindowManagementShortcuts)
        XCTAssertFalse(state.blocksGameAppSwitchingShortcuts)
        XCTAssertFalse(state.blocksGameMissionControlSpaceShortcuts)
        XCTAssertFalse(state.blocksGameScreenshotShortcuts)
        XCTAssertTrue(state.hidesPointerWhileManagedGameFrontmost)
    }

    func testNilEventTapColumnsDefaultOffWhileNilPointerColumnDefaultsOn() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let settings = AppSettingsRecord(
            isGameInputModifierMappingEnabled: nil,
            gameInputCommandBinding: nil,
            gameInputOptionBinding: nil,
            gameInputControlBinding: nil,
            blocksGameAppWindowManagementShortcuts: nil,
            blocksGameAppSwitchingShortcuts: nil,
            blocksGameMissionControlSpaceShortcuts: nil,
            blocksGameScreenshotShortcuts: nil,
            hidesPointerWhileManagedGameFrontmost: nil,
            gameInputProtectionPreferenceVersion: nil
        )
        context.insert(settings)
        try context.save()

        let state = AppState()
        try state.load(from: context)

        XCTAssertFalse(state.isGameInputModifierMappingEnabled)
        XCTAssertNil(state.gameInputModifierMap)
        XCTAssertEqual(state.gameInputCommandBinding, .control)
        XCTAssertEqual(state.gameInputOptionBinding, .alt)
        XCTAssertEqual(state.gameInputControlBinding, .control)
        XCTAssertFalse(state.blocksGameAppWindowManagementShortcuts)
        XCTAssertFalse(state.blocksGameAppSwitchingShortcuts)
        XCTAssertFalse(state.blocksGameMissionControlSpaceShortcuts)
        XCTAssertFalse(state.blocksGameScreenshotShortcuts)
        XCTAssertTrue(state.hidesPointerWhileManagedGameFrontmost)
        XCTAssertFalse(state.hasEnabledGameInputEventTapProtection)
        XCTAssertTrue(state.hasEnabledGameInputProtection)
    }

    func testLegacyDefaultOnRecordMigratesPermissionRequiredProtectionOffOnce() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let settings = AppSettingsRecord(
            isGameInputModifierMappingEnabled: true,
            blocksGameAppWindowManagementShortcuts: true,
            blocksGameAppSwitchingShortcuts: true,
            blocksGameMissionControlSpaceShortcuts: true,
            blocksGameScreenshotShortcuts: true,
            hidesPointerWhileManagedGameFrontmost: true,
            gameInputProtectionPreferenceVersion: nil
        )
        context.insert(settings)
        try context.save()

        let state = AppState()
        try state.load(from: context)

        XCTAssertFalse(state.hasEnabledGameInputEventTapProtection)
        XCTAssertTrue(state.hidesPointerWhileManagedGameFrontmost)
        XCTAssertEqual(
            settings.gameInputProtectionPreferenceVersion,
            GameInputProtectionPreferenceSchema.currentVersion
        )
        XCTAssertEqual(settings.isGameInputModifierMappingEnabled, false)
        XCTAssertEqual(settings.blocksGameAppWindowManagementShortcuts, false)
        XCTAssertEqual(settings.blocksGameAppSwitchingShortcuts, false)
        XCTAssertEqual(settings.blocksGameMissionControlSpaceShortcuts, false)
        XCTAssertEqual(settings.blocksGameScreenshotShortcuts, false)
    }

    func testCurrentOptInRecordPreservesExplicitEventTapProtection() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(AppSettingsRecord(
            isGameInputModifierMappingEnabled: true,
            blocksGameAppWindowManagementShortcuts: true,
            blocksGameAppSwitchingShortcuts: true,
            blocksGameMissionControlSpaceShortcuts: true,
            blocksGameScreenshotShortcuts: true,
            hidesPointerWhileManagedGameFrontmost: true,
            gameInputProtectionPreferenceVersion:
                GameInputProtectionPreferenceSchema.currentVersion
        ))
        try context.save()

        let state = AppState()
        try state.load(from: context)

        XCTAssertTrue(state.isGameInputModifierMappingEnabled)
        XCTAssertTrue(state.blocksGameAppWindowManagementShortcuts)
        XCTAssertTrue(state.blocksGameAppSwitchingShortcuts)
        XCTAssertTrue(state.blocksGameMissionControlSpaceShortcuts)
        XCTAssertTrue(state.blocksGameScreenshotShortcuts)
        XCTAssertTrue(state.hidesPointerWhileManagedGameFrontmost)
        XCTAssertTrue(state.hasEnabledGameInputEventTapProtection)
    }

    func testSavingPreferencesDoesNotDowngradeFutureMigrationMarker() throws {
        let container = try ModelContainer(
            for: AppSettingsRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let futureVersion = GameInputProtectionPreferenceSchema.currentVersion + 10
        let settings = AppSettingsRecord(
            gameInputProtectionPreferenceVersion: futureVersion
        )
        context.insert(settings)
        try context.save()

        let state = AppState()
        try state.load(from: context)
        let warning = state.saveUserPreferencesAfterMutation(to: context) {
            state.hidesPointerWhileManagedGameFrontmost = false
        }

        XCTAssertNil(warning)
        XCTAssertEqual(
            settings.gameInputProtectionPreferenceVersion,
            futureVersion
        )
    }

    func testPointerHidingParticipatesInImmutablePolicyFingerprint() {
        let state = AppState()
        let enabledFingerprint = state.gameInputProtectionSettingsFingerprint

        state.hidesPointerWhileManagedGameFrontmost = false

        XCTAssertNotEqual(
            state.gameInputProtectionSettingsFingerprint,
            enabledFingerprint
        )
        XCTAssertFalse(state.hasEnabledGameInputProtection)
        XCTAssertFalse(state.hasEnabledGameInputEventTapProtection)
    }

    func testDisablingPermissionRequiredProtectionPreservesPointerPreference() {
        let state = AppState()
        state.isGameInputModifierMappingEnabled = true
        state.blocksGameAppWindowManagementShortcuts = true
        state.blocksGameAppSwitchingShortcuts = true
        state.blocksGameMissionControlSpaceShortcuts = true
        state.blocksGameScreenshotShortcuts = true
        state.hidesPointerWhileManagedGameFrontmost = true

        state.disableGameInputEventTapProtection()

        XCTAssertFalse(state.hasEnabledGameInputEventTapProtection)
        XCTAssertTrue(state.hidesPointerWhileManagedGameFrontmost)
        XCTAssertTrue(state.hasEnabledGameInputProtection)
    }
}
