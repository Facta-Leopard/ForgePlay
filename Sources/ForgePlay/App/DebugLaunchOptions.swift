#if DEBUG
import Foundation
import SwiftData
import SwiftUI

extension AppState {
    func applyDebugLaunchOptionsIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        if let languageValue = Self.debugLaunchArgumentValue(
            key: "FORGEPLAY_QA_LANGUAGE",
            arguments: arguments
        ),
           let languageMode = Self.debugLanguageMode(from: languageValue) {
            debugLanguageModeOverride = languageMode
        }

        if Self.debugLaunchBooleanValue(
            key: "FORGEPLAY_QA_RESET_LANGUAGE_TO_SYSTEM_AFTER_LAUNCH",
            environment: environment,
            arguments: arguments
        ) == true {
            debugShouldResetLanguageToSystemAfterLaunch = true
        }

        if Self.debugLaunchBooleanValue(
            key: "FORGEPLAY_QA_DISMISS_SHEET_AFTER_LAUNCH",
            environment: environment,
            arguments: arguments
        ) == true {
            debugShouldDismissPresentedSheetAfterLaunch = true
        }

        if let dynamicTypeValue = Self.debugLaunchValue(
            key: "FORGEPLAY_QA_DYNAMIC_TYPE",
            environment: environment,
            arguments: arguments
        ) {
            debugDynamicTypeSize = Self.debugDynamicTypeSize(from: dynamicTypeValue)
        }

        if let themeValue = Self.debugLaunchValue(
            key: "FORGEPLAY_QA_THEME",
            environment: environment,
            arguments: arguments
        ),
           let requestedTheme = ForgePlayThemeMode(
               rawValue: themeValue.trimmingCharacters(in: .whitespacesAndNewlines)
           ) {
            themeMode = requestedTheme
        }

        if let sectionValue = Self.debugLaunchValue(
            key: "FORGEPLAY_QA_SECTION",
            environment: environment,
            arguments: arguments
        ),
           let section = AppSection(rawValue: sectionValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            selectedSection = section
        }

        if Self.debugLaunchBooleanValue(
            key: "FORGEPLAY_QA_DIAGNOSTICS_PREVIEW",
            environment: environment,
            arguments: arguments
        ) == true {
            selectedSection = .diagnostics
            debugDiagnosticsPreviewFixture = true
        }

        if let isEnabled = Self.debugLaunchBooleanValue(
            key: "FORGEPLAY_QA_STEAM_LAUNCH_FIXTURE",
            environment: environment,
            arguments: arguments
        ) {
            debugSteamLaunchLayoutFixture = isEnabled
            if isEnabled {
                selectedSection = .steamLaunch
            }
        }

        if let screenshotFixture = Self.debugLaunchValue(
            key: "FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE",
            environment: environment,
            arguments: arguments
        ) {
            applyAppStoreScreenshotFixture(screenshotFixture)
        }

        guard let rawValue = Self.debugLaunchValue(
            key: "FORGEPLAY_QA_SHEET",
            environment: environment,
            arguments: arguments
        ) else {
            return
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "root":
            presentedSheet = .chooseRoot
        case "usageGuide":
            presentedSheet = .usageGuide
        case "apple-renderer":
            presentedSheet = .importAppleSupplementalRenderer
        case "steamInstaller":
            presentedSheet = .chooseSteamInstaller
        case "runtimeCatalog":
            presentedSheet = .chooseRuntimeInstallerCatalog
        case let value where value.hasPrefix("runtime:"):
            let runtimeValue = String(value.dropFirst("runtime:".count))
            if let runtime = RuntimeId(rawValue: runtimeValue) {
                presentedSheet = .chooseRuntimeInstaller(runtime)
            }
        case "diagnosticGuide":
            presentDiagnosticGuide(
                title: localized("레이아웃 검증"),
                diagnostics: [Self.debugDiagnosticResult()],
                logURL: nil
            )
        default:
            break
        }
    }

    private func applyAppStoreScreenshotFixture(_ rawValue: String) {
        debugAppStoreScreenshotFixture = true
        debugLanguageModeOverride = .english
        latestChecks = [
            SystemCheckResult(
                title: "macOS",
                detail: "Ready for local game environment management.",
                status: .ok,
                technicalDetail: nil
            )
        ]
        selectedRootURL = URL(
            fileURLWithPath: ForgePlayDevelopmentFixturePaths.appStoreScreenshotRootPath,
            isDirectory: true
        )
        runtimeExecutableURL = URL(
            fileURLWithPath: ForgePlayDevelopmentFixturePaths.appStoreScreenshotRuntimeExecutablePath
        )

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "steamLaunch":
            selectedSection = .steamLaunch
        case "diagnostics":
            selectedSection = .diagnostics
            debugDiagnosticsPreviewFixture = true
        case "settings":
            selectedSection = .settings
        default:
            break
        }
    }

    private static func debugLaunchValue(
        key: String,
        environment: [String: String],
        arguments: [String]
    ) -> String? {
        if let value = environment[key], !value.isEmpty {
            return value
        }
        return debugLaunchArgumentValue(key: key, arguments: arguments)
    }

    private static func debugLaunchArgumentValue(
        key: String,
        arguments: [String]
    ) -> String? {
        let prefix = "--\(key)="
        return arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func debugLaunchBooleanValue(
        key: String,
        environment: [String: String],
        arguments: [String]
    ) -> Bool? {
        guard let value = debugLaunchValue(key: key, environment: environment, arguments: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func debugDynamicTypeSize(from rawValue: String) -> DynamicTypeSize? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "xSmall": .xSmall
        case "small": .small
        case "medium": .medium
        case "large": .large
        case "xLarge": .xLarge
        case "xxLarge": .xxLarge
        case "xxxLarge": .xxxLarge
        case "accessibility1": .accessibility1
        case "accessibility2": .accessibility2
        case "accessibility3": .accessibility3
        case "accessibility4": .accessibility4
        case "accessibility5": .accessibility5
        default: nil
        }
    }

    private static func debugLanguageMode(from rawValue: String) -> ForgePlayLanguageMode? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let language = ForgePlayLanguageMode(rawValue: value) {
            return language
        }
        return ForgePlayLanguageMode.allCases.first { $0.localeIdentifier == value }
    }

    func applyDebugPostLaunchActionsIfNeeded(
        saveTo context: ModelContext,
        resetDelay: Duration = .milliseconds(900)
    ) async {
        guard debugShouldResetLanguageToSystemAfterLaunch || debugShouldDismissPresentedSheetAfterLaunch else { return }
        let shouldResetLanguage = debugShouldResetLanguageToSystemAfterLaunch
        let shouldDismissSheet = debugShouldDismissPresentedSheetAfterLaunch
        debugShouldResetLanguageToSystemAfterLaunch = false
        debugShouldDismissPresentedSheetAfterLaunch = false

        try? await Task.sleep(for: resetDelay)
        if shouldResetLanguage {
            saveUserPreferencesAfterMutation(to: context) {
                setLanguageModeFromUserSelection(.system)
            }
        }
        if shouldDismissSheet {
            presentedSheet = nil
        }
    }

    private static func debugDiagnosticResult() -> DiagnosticResult {
        DiagnosticResult(
            category: .missingRuntime,
            confidence: 0.82,
            userMessage: "VC++, DirectX, .NET, OpenAL, XNA, PhysX 같은 Windows 필수 구성요소는 게임별로 필요할 때만 설치합니다.",
            technicalSummary: "Debug-only layout diagnostic payload.",
            riskLevel: .medium,
            recommendedActions: [
                RecommendedAction(
                    type: .installRuntime,
                    runtime: .vcrun2022,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "%@(%@) 누락 신호입니다. 공식 설치 파일을 받아 Steam 프리픽스에 설치해야 합니다."
                ),
                RecommendedAction(
                    type: .askUserToUpdateRuntime,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .medium,
                    reason: "Apple 공식 보조 렌더러 최신 버전을 다시 가져와 보세요."
                )
            ]
        )
    }
}
#endif
