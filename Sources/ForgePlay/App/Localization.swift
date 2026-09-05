import Foundation
import SwiftUI

enum ForgePlayLanguageMode: String, CaseIterable, Identifiable {
    case system
    case english
    case korean
    case spanish
    case german
    case japanese
    case simplifiedChinese
    case traditionalChinese
    case french

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .system: "시스템 언어 따르기"
        case .english: "English"
        case .korean: "한국어"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .french: "Français"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .korean: "ko"
        case .spanish: "es"
        case .german: "de"
        case .japanese: "ja"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .french: "fr"
        }
    }

    var localizationDirectory: String? {
        ForgePlaySystemLanguageResolver.localizationDirectory(for: self)
    }

    var locale: Locale {
        let resolvedIdentifier = switch self {
        case .system:
            ForgePlaySystemLanguageResolver.resolvedLocaleIdentifier()
        default:
            localeIdentifier
        }
        if let localeIdentifier = resolvedIdentifier {
            return Locale(identifier: localeIdentifier)
        }
        return .autoupdatingCurrent
    }

    var diagnosticResponseLanguageName: String {
        switch self {
        case .system:
            "the user's macOS system language"
        case .english:
            "English"
        case .korean:
            "Korean"
        case .spanish:
            "Spanish"
        case .german:
            "German"
        case .japanese:
            "Japanese"
        case .simplifiedChinese:
            "Simplified Chinese"
        case .traditionalChinese:
            "Traditional Chinese"
        case .french:
            "French"
        }
    }
}

enum ForgePlaySystemLanguageResolver {
    static let fallbackLanguage: ForgePlayLanguageMode = .english

    static func resolvedLanguageMode(
        preferredLanguageIdentifiers: [String] = systemPreferredLanguageIdentifiers()
    ) -> ForgePlayLanguageMode {
        for identifier in preferredLanguageIdentifiers {
            if let language = supportedLanguage(for: identifier) {
                return language
            }
        }
        return fallbackLanguage
    }

    static func resolvedLocaleIdentifier(
        preferredLanguageIdentifiers: [String] = systemPreferredLanguageIdentifiers()
    ) -> String? {
        let resolvedLanguage = resolvedLanguageMode(preferredLanguageIdentifiers: preferredLanguageIdentifiers)
        guard let languageIdentifier = resolvedLanguage.localeIdentifier else {
            return nil
        }
        let normalizedLanguageIdentifier = normalize(languageIdentifier)
        return preferredLanguageIdentifiers
            .map(normalize)
            .first { identifier in
                identifier == normalizedLanguageIdentifier ||
                    identifier.hasPrefix("\(normalizedLanguageIdentifier)-")
            } ?? languageIdentifier
    }

    static func systemPreferredLanguageIdentifiers() -> [String] {
        systemPreferredLanguageIdentifiers(
            currentLocaleIdentifier: Locale.autoupdatingCurrent.identifier,
            localePreferredLanguages: Locale.preferredLanguages,
            globalLanguageIdentifiers: systemGlobalLanguageIdentifiers()
        )
    }

    static func systemPreferredLanguageIdentifiers(
        currentLocaleIdentifier: String? = nil,
        localePreferredLanguages: [String],
        globalLanguageIdentifiers: [String]?
    ) -> [String] {
        let orderedIdentifiers = [
            localePreferredLanguages,
            globalLanguageIdentifiers ?? [],
            currentLocaleIdentifier.map { [$0] } ?? []
        ].flatMap { $0 }

        var seen: Set<String> = []
        let systemLanguageIdentifiers = orderedIdentifiers.compactMap { identifier -> String? in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = normalize(trimmed)
            guard !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return trimmed
        }
        return systemLanguageIdentifiers
    }

    private static func systemGlobalLanguageIdentifiers(
        userDefaults: UserDefaults = .standard
    ) -> [String]? {
        userDefaults
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
    }

    static func supportedLanguage(for identifier: String) -> ForgePlayLanguageMode? {
        let normalizedIdentifier = normalize(identifier)
        guard !normalizedIdentifier.isEmpty else { return nil }

        if normalizedIdentifier.hasPrefix("zh-hant") ||
            normalizedIdentifier == "zh-tw" ||
            normalizedIdentifier == "zh-hk" ||
            normalizedIdentifier == "zh-mo" {
            return .traditionalChinese
        }
        if normalizedIdentifier.hasPrefix("zh-hans") ||
            normalizedIdentifier == "zh-cn" ||
            normalizedIdentifier == "zh-sg" {
            return .simplifiedChinese
        }

        return ForgePlayLanguageMode.allCases.first { language in
            guard language != .system,
                  let localeIdentifier = language.localeIdentifier.map(normalize) else {
                return false
            }
            return normalizedIdentifier == localeIdentifier ||
                normalizedIdentifier.hasPrefix("\(localeIdentifier)-")
        }
    }

    static func localizationDirectory(
        for language: ForgePlayLanguageMode,
        preferredLanguageIdentifiers: [String] = systemPreferredLanguageIdentifiers()
    ) -> String? {
        switch language {
        case .system:
            resolvedLanguageMode(preferredLanguageIdentifiers: preferredLanguageIdentifiers).localeIdentifier
        default:
            language.localeIdentifier
        }
    }

    private static func normalize(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}

extension ForgePlayLanguageMode {
    func resolvedSteamClientLanguage(
        preferredLanguageIdentifiers: [String] =
            ForgePlaySystemLanguageResolver.systemPreferredLanguageIdentifiers()
    ) -> SteamClientLanguage {
        let resolvedMode = self == .system
            ? ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: preferredLanguageIdentifiers
            )
            : self
        switch resolvedMode {
        case .system, .english:
            return .english
        case .korean:
            return .koreana
        case .spanish:
            return .spanish
        case .german:
            return .german
        case .japanese:
            return .japanese
        case .simplifiedChinese:
            return .schinese
        case .traditionalChinese:
            return .tchinese
        case .french:
            return .french
        }
    }
}

enum ForgePlayLocalization {
    static func localized(
        _ key: String,
        language: ForgePlayLanguageMode,
        systemLanguageIdentifiers: [String]? = nil
    ) -> String {
        guard !key.isEmpty else { return key }
        let bundle = bundle(for: language, systemLanguageIdentifiers: systemLanguageIdentifiers)
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func localizedFormat(
        _ key: String,
        language: ForgePlayLanguageMode,
        arguments: [CVarArg],
        systemLanguageIdentifiers: [String]? = nil
    ) -> String {
        let format = localized(
            key,
            language: language,
            systemLanguageIdentifiers: systemLanguageIdentifiers
        )
        let locale = locale(for: language, systemLanguageIdentifiers: systemLanguageIdentifiers)
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func localizedByteCount(
        _ bytes: Int64,
        language: ForgePlayLanguageMode,
        systemLanguageIdentifiers: [String]? = nil
    ) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale(
            for: language,
            systemLanguageIdentifiers: systemLanguageIdentifiers
        )))
    }

    private static func bundle(
        for language: ForgePlayLanguageMode,
        systemLanguageIdentifiers: [String]? = nil
    ) -> Bundle {
        let directory = if let systemLanguageIdentifiers {
            ForgePlaySystemLanguageResolver.localizationDirectory(
                for: language,
                preferredLanguageIdentifiers: systemLanguageIdentifiers
            )
        } else {
            ForgePlaySystemLanguageResolver.localizationDirectory(for: language)
        }
        guard let directory,
              let path = Bundle.main.path(forResource: directory, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    private static func locale(
        for language: ForgePlayLanguageMode,
        systemLanguageIdentifiers: [String]? = nil
    ) -> Locale {
        if let systemLanguageIdentifiers,
           language == .system,
           let localeIdentifier = ForgePlaySystemLanguageResolver.resolvedLocaleIdentifier(
               preferredLanguageIdentifiers: systemLanguageIdentifiers
           ) {
            return Locale(identifier: localeIdentifier)
        }
        return language.locale
    }
}

protocol ForgePlayUserFacingLocalizedError: Error {
    @MainActor
    func localizedDescription(appState: AppState) -> String
}

protocol ForgePlayDiagnosticLogProvidingError: Error {
    var forgePlayDiagnosticLogURL: URL? { get }
}

extension AWDLControlError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsupportedBuild:
            appState.localized(
                "이 빌드에서는 AWDL 수동 제어를 사용할 수 없습니다."
            )
        case .operationInProgress:
            appState.localized("AWDL 상태 변경 중")
        case .helperNotFound:
            appState.localized(
                "AWDL 제어 도우미를 찾을 수 없습니다. ForgePlay DMG를 다시 설치하세요."
            )
        case .helperRequiresApproval:
            appState.localized(
                "AWDL 제어 도우미를 사용하려면 시스템 설정의 로그인 항목에서 ForgePlay를 허용하세요."
            )
        case .registrationFailed:
            appState.localized(
                "AWDL 제어 도우미를 활성화하지 못했습니다."
            )
        case .connectionFailed:
            appState.localized(
                "AWDL 제어 도우미에 연결하지 못했습니다."
            )
        case .requestTimedOut:
            appState.localized(
                "AWDL 상태 변경 응답 시간이 초과되었습니다."
            )
        case .helperRejected:
            appState.localized(
                "AWDL 상태를 변경하지 못했습니다. 현재 상태를 다시 확인하세요."
            )
        case .readbackMismatch:
            appState.localized(
                "AWDL 상태 변경 결과가 요청과 일치하지 않습니다."
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .unsupportedBuild:
            "awdl-control error=unsupported-build"
        case .operationInProgress:
            "awdl-control error=operation-in-progress"
        case .helperNotFound:
            "awdl-control error=helper-not-found"
        case .helperRequiresApproval:
            "awdl-control error=helper-requires-approval"
        case .registrationFailed(let detail):
            "awdl-control error=registration-failed detail=\(detail)"
        case .connectionFailed(let detail):
            "awdl-control error=connection-failed detail=\(detail)"
        case .requestTimedOut:
            "awdl-control error=request-timed-out"
        case .helperRejected(let code, let detail):
            "awdl-control error=helper-rejected code=\(code) detail=\(detail)"
        case .readbackMismatch:
            "awdl-control error=readback-mismatch"
        }
    }
}

extension GameInputProtectionTerminalFailure:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .timeoutReenableReadbackFailed:
            appState.localized(
                "macOS 게임 입력 필터가 시간 초과 후 다시 활성화되지 않아 입력 보호를 비활성화합니다. Wine과 Steam 실행은 유지됩니다."
            )
        case .repeatedTapTimeout:
            appState.localized(
                "macOS 게임 입력 필터가 반복해서 시간 초과되어 입력 보호를 비활성화합니다. Wine과 Steam 실행은 유지됩니다."
            )
        case .disabledByUserInput:
            appState.localized(
                "macOS가 게임 입력 필터를 비활성화하여 입력 보호를 종료합니다. Wine과 Steam 실행은 유지됩니다."
            )
        case .pointerVisibilityRestoreFailed:
            appState.localized(
                "macOS 포인터를 다시 표시하지 못해 입력 보호를 비활성화하고 포인터 복원을 다시 시도합니다. Wine과 Steam 실행은 유지됩니다."
            )
        case .modifierReleaseEmissionFailed(let processIdentifier):
            appState.localizedFormat(
                "변환된 보조키를 해제하지 못해 입력 보호를 비활성화하고 입력 상태 복원을 다시 시도합니다. Wine과 Steam 실행은 유지됩니다. (프로세스 %lld)",
                Int64(processIdentifier)
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .timeoutReenableReadbackFailed:
            "game-input-protection terminal=timeout-reenable-readback-failed"
        case .repeatedTapTimeout:
            "game-input-protection terminal=repeated-tap-timeout"
        case .disabledByUserInput:
            "game-input-protection terminal=disabled-by-user-input"
        case .pointerVisibilityRestoreFailed(let resultCode):
            "game-input-protection terminal=pointer-visibility-restore-failed" +
                " cgError=\(resultCode)"
        case .modifierReleaseEmissionFailed(let processIdentifier):
            "game-input-protection terminal=modifier-release-emission-failed" +
                " pid=\(processIdentifier)"
        }
    }
}

extension NavigationStableSessionOwnershipError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        guard let errorDescription else { return "" }
        return appState.localized(errorDescription)
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .transitionInProgress:
            "steam-session-ownership case=transition-in-progress"
        case .sessionAlreadyActive:
            "steam-session-ownership case=session-already-active"
        case .noActiveSession:
            "steam-session-ownership case=no-active-session"
        case .preparationNotInProgress:
            "steam-session-ownership case=preparation-not-in-progress"
        case .standardSteamLaunchReserved:
            "steam-session-ownership case=standard-steam-launch-reserved"
        case .standardSteamLaunchReservationMismatch:
            "steam-session-ownership case=standard-steam-launch-reservation-mismatch"
        case .standardSteamLaunchNotReady:
            "steam-session-ownership case=standard-steam-launch-not-ready"
        case .windowsExecutableLaunchReserved:
            "steam-session-ownership case=windows-executable-launch-reserved"
        case .windowsExecutableLaunchBlockedByCompatibilitySession:
            "steam-session-ownership case=windows-executable-blocked-by-compatibility-session"
        case .windowsExecutableLaunchBlockedByCompatibilityTransition:
            "steam-session-ownership case=windows-executable-blocked-by-compatibility-transition"
        case .windowsExecutableLaunchNotReady:
            "steam-session-ownership case=windows-executable-launch-not-ready"
        }
    }
}

extension GameInputProtectionTerminalCleanupError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        terminalFailure.localizedDescription(appState: appState)
    }

    var forgePlayTechnicalDescription: String {
        let maskedCommitFailure =
            maskedCommitFailureTechnicalDescription.map {
                " maskedCommitFailure=\($0)"
            } ?? ""
        return terminalFailure.forgePlayTechnicalDescription +
            " cleanupCompleted=\(cleanupCompleted)" +
            " callerCancellationObserved=\(callerCancellationObserved)" +
            maskedCommitFailure
    }
}

extension GameInputProtectionPostDispatchCleanupError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        originalFailureDescription
    }

    var forgePlayTechnicalDescription: String {
        "game-input-protection post-dispatch-original=" +
            originalFailureTechnicalDescription +
            " cleanupCompleted=\(cleanupCompleted)" +
            " callerCancellationObserved=\(callerCancellationObserved)"
    }
}

extension SteamCompatibilityLaunchProfileErrorV1:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsupportedContractVersion(let version):
            appState.localizedFormat(
                "이 Steam 호환성 프로필 버전은 지원되지 않습니다(%lld). ForgePlay를 업데이트한 뒤 다시 시도하세요.",
                Int64(version)
            )
        case .unsupportedRecipeSchemaVersion(let version):
            appState.localizedFormat(
                "이 Steam 호환성 레시피 버전은 지원되지 않습니다(%lld). ForgePlay를 업데이트한 뒤 다시 시도하세요.",
                Int64(version)
            )
        case .invalidRecipe(let reason):
            appState.localizedFormat(
                "Steam 호환성 레시피를 사용할 수 없습니다(%@). 기본 설정으로 되돌린 뒤 다시 시도하세요.",
                reason
            )
        case .identityMismatch:
            appState.localized(
                "선택한 게임과 저장된 Steam 호환성 프로필이 일치하지 않습니다. 해당 게임의 호환성 설정을 다시 여세요."
            )
        case .invalidPreference(let reason):
            appState.localizedFormat(
                "저장된 Steam 호환성 설정을 사용할 수 없습니다(%@). 설정을 기본값으로 재설정하세요.",
                reason
            )
        case .invalidCanonicalPayload(let reason):
            appState.localizedFormat(
                "저장된 Steam 호환성 설정 파일을 읽을 수 없습니다(%@). 설정을 기본값으로 재설정하세요.",
                reason
            )
        case .invalidManifestRootAuthorization(let reason):
            appState.localizedFormat(
                "Steam 라이브러리 접근 권한을 확인할 수 없습니다(%@). 라이브러리 폴더를 다시 연결하세요.",
                reason
            )
        case .attemptedAutomaticPolicyRemoval:
            appState.localized(
                "필수 자동 호환성 정책은 끌 수 없습니다. 자동 정책을 복원한 뒤 다시 시도하세요."
            )
        case .unsupportedCapability(let category, let value):
            appState.localizedFormat(
                "현재 실행 환경은 선택한 Steam 호환성 옵션을 지원하지 않습니다(%@=%@). 지원되는 옵션을 선택하거나 기본값으로 되돌리세요.",
                category,
                value
            )
        case .invalidReceipt(let reason):
            appState.localizedFormat(
                "Steam 호환성 설정이 실행 전에 확인되지 않았습니다(%@). 다시 시도하고 문제가 계속되면 진단 정보를 확인하세요.",
                reason
            )
        case .migrationRejected(let reason):
            appState.localizedFormat(
                "이전 Steam 호환성 설정을 변환할 수 없습니다(%@). 설정을 기본값으로 재설정하세요.",
                reason
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .unsupportedContractVersion(let version):
            "SteamCompatibilityLaunchProfileErrorV1 case=unsupportedContractVersion version=\(version)"
        case .unsupportedRecipeSchemaVersion(let version):
            "SteamCompatibilityLaunchProfileErrorV1 case=unsupportedRecipeSchemaVersion version=\(version)"
        case .invalidRecipe(let reason):
            "SteamCompatibilityLaunchProfileErrorV1 case=invalidRecipe reason=\(Self.sanitizedDiagnosticValue(reason))"
        case .identityMismatch(let expected, let actual):
            "SteamCompatibilityLaunchProfileErrorV1 case=identityMismatch expected=\(Self.sanitizedDiagnosticValue(expected)) actual=\(Self.sanitizedDiagnosticValue(actual))"
        case .invalidPreference(let reason):
            "SteamCompatibilityLaunchProfileErrorV1 case=invalidPreference reason=\(Self.sanitizedDiagnosticValue(reason))"
        case .invalidCanonicalPayload(let reason):
            "SteamCompatibilityLaunchProfileErrorV1 case=invalidCanonicalPayload reason=\(Self.sanitizedDiagnosticValue(reason))"
        case .invalidManifestRootAuthorization(let reason):
            "SteamCompatibilityLaunchProfileErrorV1 case=invalidManifestRootAuthorization reason=\(Self.sanitizedDiagnosticValue(reason))"
        case .attemptedAutomaticPolicyRemoval:
            "SteamCompatibilityLaunchProfileErrorV1 case=attemptedAutomaticPolicyRemoval"
        case .unsupportedCapability(let category, let value):
            "SteamCompatibilityLaunchProfileErrorV1 case=unsupportedCapability category=\(Self.sanitizedDiagnosticValue(category)) value=\(Self.sanitizedDiagnosticValue(value))"
        case .invalidReceipt(let reason):
            "SteamCompatibilityLaunchProfileErrorV1 case=invalidReceipt reason=\(Self.sanitizedDiagnosticValue(reason))"
        case .migrationRejected(let reason):
            "SteamCompatibilityLaunchProfileErrorV1 case=migrationRejected reason=\(Self.sanitizedDiagnosticValue(reason))"
        }
    }

    private static func sanitizedDiagnosticValue(_ value: String) -> String {
        let maximumUTF8Bytes = 256
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maximumUTF8Bytes))
        var consumedBytes = 0
        for byte in value.utf8 {
            guard consumedBytes < maximumUTF8Bytes else {
                result += "..."
                break
            }
            switch byte {
            case 45, 46, 47, 48 ... 57, 58, 65 ... 90, 92, 95, 97 ... 122:
                result += String(decoding: [byte], as: UTF8.self)
            default:
                result += String(format: "%%%02X", byte)
            }
            consumedBytes += 1
        }
        return result
    }
}

struct LocalizedText: View {
    var key: String
    @Environment(AppState.self) private var appState

    var body: some View {
        Text(appState.localized(key))
    }
}

extension AppState {
    var effectiveLanguageMode: ForgePlayLanguageMode {
        #if DEBUG
        if let debugLanguageModeOverride {
            return debugLanguageModeOverride
        }
        #endif
        return languageMode
    }

    var locale: Locale { effectiveLanguageMode.locale }

    var effectiveSteamClientLanguage: SteamClientLanguage {
        effectiveLanguageMode.resolvedSteamClientLanguage()
    }

    func localized(_ key: String) -> String {
        ForgePlayLocalization.localized(key, language: effectiveLanguageMode)
    }

    func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        ForgePlayLocalization.localizedFormat(key, language: effectiveLanguageMode, arguments: arguments)
    }

    func localizedByteCount(_ bytes: Int64) -> String {
        ForgePlayLocalization.localizedByteCount(bytes, language: effectiveLanguageMode)
    }

    func localizedError(_ error: Error) -> String {
        if let userFacingError = error as? ForgePlayUserFacingLocalizedError {
            return userFacingError.localizedDescription(appState: self)
        }
        if PathManager.isReadOnlyVolumeError(error) {
            if let path = forgePlayFileErrorPath(error) {
                return localizedFormat("선택한 위치에 쓸 수 없습니다: %@", path)
            }
            return localized("선택한 위치에 쓸 수 없습니다. 다른 위치를 선택하세요.")
        }
        return forgePlayTechnicalErrorSummary(error)
    }
}

private func forgePlayFileErrorPath(_ error: Error) -> String? {
    let nsError = error as NSError
    if let url = nsError.userInfo[NSURLErrorKey] as? URL {
        return url.path
    }
    if let path = nsError.userInfo[NSFilePathErrorKey] as? String,
       !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return path
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        return forgePlayFileErrorPath(underlying)
    }
    return nil
}

extension PrefixManagerError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        ForgePlayLocalization.localizedFormat(
            localizationKey,
            language: appState.effectiveLanguageMode,
            arguments: localizationArguments
        )
    }
}

extension SteamPrefixLifecycleError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .operationInProgress:
            appState.localized("다른 Steam 프리픽스 작업이 이미 진행 중입니다. 완료된 뒤 다시 시도하세요.")
        case .applicationTerminating:
            appState.localized("ForgePlay가 종료 중이어서 새 Steam 프리픽스 작업을 시작할 수 없습니다.")
        }
    }
}

extension WindowsExecutableExternalRootAccessError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .accessUnavailable(let root):
            appState.localizedFormat(
                "선택한 EXE 폴더의 보안 범위 접근을 시작할 수 없습니다: %@",
                root.path
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .accessUnavailable(let root):
            "Windows executable external-root security-scope access is unavailable: \(root.path)"
        }
    }
}

extension WindowsExecutableLaunchServiceError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unusableSharedPrefix(let prefix):
            appState.localizedFormat(
                "SteamShared 프리픽스를 사용할 수 없습니다: %@",
                prefix.path
            )
        case .rendererCapabilityUnavailable:
            appState.localized(
                "선택한 그래픽 백엔드를 현재 ForgePlay Runtime에서 사용할 수 없습니다."
            )
        case .prefixShutdownNotConfirmed(let prefix):
            appState.localizedFormat(
                "실행 중인 Windows 프로세스 종료를 확인하지 못했습니다: %@",
                prefix.path
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .unusableSharedPrefix(let prefix):
            "Windows executable launch cannot use the SteamShared prefix: \(prefix.path)"
        case .rendererCapabilityUnavailable:
            "Windows executable launch renderer capability unavailable"
        case .prefixShutdownNotConfirmed(let prefix):
            "Windows executable launch prefix shutdown not confirmed: \(prefix.path)"
        }
    }
}

extension GameInputProtectionError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .accessibilityPermissionRequired:
            appState.localized(
                "게임 입력 보호를 사용하려면 손쉬운 사용 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요."
            )
        case .inputMonitoringPermissionRequired:
            appState.localized(
                "게임 입력 보호를 사용하려면 입력 모니터링 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요."
            )
        case .accessibilityAndInputMonitoringPermissionsRequired:
            appState.localized(
                "게임 입력 보호를 사용하려면 손쉬운 사용 및 입력 모니터링 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요."
            )
        case .eventTapCreationFailed:
            appState.localized(
                "macOS에 저장된 권한 등록과 현재 ForgePlay.app이 일치하지 않거나 실제 입력 필터 승인이 갱신되지 않았습니다. 손쉬운 사용과 입력 모니터링에서 기존 ForgePlay 항목을 각각 제거한 뒤, Finder에서 보기로 현재 ForgePlay.app을 다시 추가해 두 권한을 켜고 ForgePlay를 완전히 종료했다가 다시 여세요."
            )
        case .eventTapEnableReadbackFailed:
            appState.localized(
                "macOS 게임 입력 필터가 활성화된 것으로 확인되지 않았습니다. 손쉬운 사용 및 입력 모니터링 권한을 확인한 뒤 다시 실행해 주세요."
            )
        case .managedProcessGroupUnavailable(let processIdentifier):
            appState.localizedFormat(
                "관리되는 게임 프로세스(%lld)의 입력 보호 대상을 확인할 수 없습니다. Steam을 종료한 뒤 다시 시도하세요.",
                Int64(processIdentifier)
            )
        case .managedProcessBindingReadbackFailed(let processIdentifier):
            appState.localizedFormat(
                "관리되는 게임 프로세스(%lld)의 입력 보호 연결이 확인 중 변경되었습니다. Steam을 종료한 뒤 다시 시도하세요.",
                Int64(processIdentifier)
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .accessibilityPermissionRequired:
            "GameInputProtectionError case=accessibilityPermissionRequired"
        case .inputMonitoringPermissionRequired:
            "GameInputProtectionError case=inputMonitoringPermissionRequired"
        case .accessibilityAndInputMonitoringPermissionsRequired:
            "GameInputProtectionError case=accessibilityAndInputMonitoringPermissionsRequired"
        case .eventTapCreationFailed:
            "GameInputProtectionError case=eventTapCreationFailed"
        case .eventTapEnableReadbackFailed:
            "GameInputProtectionError case=eventTapEnableReadbackFailed"
        case .managedProcessGroupUnavailable(let processIdentifier):
            "GameInputProtectionError case=managedProcessGroupUnavailable pid=\(processIdentifier)"
        case .managedProcessBindingReadbackFailed(let processIdentifier):
            "GameInputProtectionError case=managedProcessBindingReadbackFailed pid=\(processIdentifier)"
        }
    }
}

extension PrefixExecutionLeaseError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .conflictingOperation(let url, let mode):
            switch mode {
            case .sharedExecution:
                appState.localizedFormat(
                    "프리픽스 변경 작업이 진행 중이어서 게임 실행 세션에 참가할 수 없습니다: %@",
                    url.path
                )
            case .exclusiveMutation:
                appState.localizedFormat(
                    "Steam 또는 게임이 프리픽스를 사용 중이어서 변경할 수 없습니다: %@",
                    url.path
                )
            }
        case .unsafeLockFile(let url):
            appState.localizedFormat(
                "프리픽스 실행 잠금 파일이 안전한 일반 파일이 아닙니다: %@",
                url.path
            )
        case .lockFailed(let url, let message):
            appState.localizedFormat(
                "프리픽스 실행 잠금을 준비하지 못했습니다: %@. %@",
                url.path,
                message
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .conflictingOperation(let url, let mode):
            "Prefix execution lease conflict (\(mode.rawValue)): \(url.path)"
        case .unsafeLockFile(let url):
            "Prefix execution lease file is unsafe: \(url.path)"
        case .lockFailed(let url, let message):
            "Prefix execution lease failed: \(url.path). \(message)"
        }
    }
}

extension SteamPrefixLifecycleCleanupError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        appState.localizedFormat(
            "Steam 프리픽스 작업에 실패했고 남은 Wine 프로세스도 정리하지 못했습니다. 원인: %@. 정리 오류: %@",
            originalDescription,
            cleanupDescription
        )
    }
}

extension PrefixMetadataError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsafePrefixDirectory(let url):
            return appState.localizedFormat("Steam 프리픽스 폴더는 symlink가 아닌 일반 폴더여야 합니다: %@", url.path)
        case .unsafeMetadataFile(let url):
            return appState.localizedFormat("Steam 프리픽스 메타데이터는 symlink가 아닌 일반 파일이어야 합니다: %@", url.path)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("Steam 프리픽스 파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .metadataTooLarge(let url, let byteCount, let limit):
            return appState.localizedFormat("Steam 프리픽스 메타데이터가 너무 큽니다: %@ %d bytes / limit %d bytes", url.path, byteCount, limit)
        case .invalidMetadata(let url):
            return appState.localizedFormat("Steam 프리픽스 메타데이터가 올바르지 않습니다: %@", url.path)
        }
    }
}

extension PrefixRestoreError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .rollbackFailed(let destination, let backup, let originalError, let rollbackError):
            return appState.localizedFormat(
                "Steam 프리픽스 복원에 실패했고 기존 프리픽스를 되돌리지 못했습니다: %@. 백업 위치: %@. 원인: %@. 복구 오류: %@",
                destination.path,
                backup.path,
                forgePlayTechnicalErrorSummary(originalError),
                forgePlayTechnicalErrorSummary(rollbackError)
            )
        }
    }
}

extension PrefixResetError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .rollbackFailed(let destination, let displacedEnvironment, let originalError, let rollbackError):
            return appState.localizedFormat(
                "Steam 프리픽스 재설정에 실패했고 기존 프리픽스를 되돌리지 못했습니다: %@. 기존 환경 임시 위치: %@. 원인: %@. 복구 오류: %@",
                destination.path,
                displacedEnvironment.path,
                forgePlayTechnicalErrorSummary(originalError),
                forgePlayTechnicalErrorSummary(rollbackError)
            )
        case .steamLibraryPreservationFailed(let url, let reason):
            return appState.localizedFormat(
                "Steam 프리픽스 내부 라이브러리를 보존하지 못해 기존 프리픽스로 되돌렸습니다: %@. %@",
                url.path,
                reason
            )
        }
    }
}

extension PrefixUsabilityError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .missingRequiredItem(let url):
            return appState.localizedFormat("Steam 프리픽스에 필요한 항목을 찾을 수 없습니다: %@", url.path)
        case .unsafeRequiredItem(let url):
            return appState.localizedFormat("Steam 프리픽스에 필요한 항목이 안전한 일반 파일/폴더가 아닙니다: %@", url.path)
        case .unreadableRequiredItem(let url, let message):
            return appState.localizedFormat("Steam 프리픽스에 필요한 항목을 읽지 못했습니다: %@. %@", url.path, message)
        case .invalidMetadata(let url, let message):
            return appState.localizedFormat("Steam 프리픽스 메타데이터를 사용할 수 없습니다: %@. %@", url.path, message)
        case .architectureMismatch(let url, let expected, let actual):
            return appState.localizedFormat(
                "Steam 프리픽스 아키텍처가 일치하지 않습니다: %@. 예상: %@, 실제: %@",
                url.path,
                expected,
                actual ?? appState.localized("알 수 없음")
            )
        }
    }
}

extension RuntimeManagerError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsupportedInstaller(let url, let runtime):
            return appState.localizedFormat(
                "선택한 파일은 %@(%@) 설치 파일이 아닙니다: %@",
                appState.localized(runtime.beginnerName),
                runtime.technicalName,
                url.lastPathComponent
            )
        case .unsupportedExtractionArchive(let url, let runtime):
            return appState.localizedFormat(
                "선택한 파일은 %@(%@) 압축 해제용 파일이 아닙니다: %@",
                appState.localized(runtime.beginnerName),
                runtime.technicalName,
                url.lastPathComponent
            )
        case .unsafeCachedInstaller(let url):
            return appState.localizedFormat(
                "Runtime cache 설치 파일은 symlink나 hardlink가 아닌 일반 파일이어야 합니다: %@",
                url.path
            )
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat(
                "필수 구성요소 파일 정보를 읽지 못했습니다: %@. %@",
                url.path,
                message
            )
        case .archiveExtractionFailed(let result):
            return appState.localizedFormat("설치 파일 압축 해제에 실패했습니다. 로그를 확인하세요: %@", result.stderrLog.path)
        case .prefixShutdownFailed(let result):
            return appState.localizedFormat(
                "Runtime 설치 전에 Steam 프리픽스 프로세스를 정리하지 못했습니다. 로그를 확인하세요: %@",
                result.stderrLog.path
            )
        case .extractedInstallerScanFailed(let directory, let error):
            return appState.localizedFormat("압축을 푼 폴더를 읽을 수 없습니다: %@ (%@)", directory.path, forgePlayTechnicalErrorSummary(error))
        case .extractedInstallerMissing(let directory):
            return appState.localizedFormat("압축을 풀었지만 실행할 설치 파일을 찾지 못했습니다: %@", directory.path)
        case .extractionCleanupFailed(let directory, let originalError, let cleanupError):
            return appState.localizedFormat(
                "Runtime 설치 준비에 실패했고 임시 추출 폴더를 정리하지 못했습니다: %@. 원인: %@. 정리 오류: %@",
                directory.path,
                forgePlayTechnicalErrorSummary(originalError),
                forgePlayTechnicalErrorSummary(cleanupError)
            )
        case .extractionCleanupAfterUseFailed(let directory, let cleanupError):
            return appState.localizedFormat(
                "Runtime 설치 후 임시 추출 폴더를 정리하지 못했습니다: %@. 정리 오류: %@",
                directory.path,
                forgePlayTechnicalErrorSummary(cleanupError)
            )
        case .cacheCleanupFailed(let target, let originalError, let cleanupError):
            return appState.localizedFormat(
                "Runtime cache 설치 준비에 실패했고 부분 파일을 정리하지 못했습니다: %@. 원인: %@. 정리 오류: %@",
                target.path,
                forgePlayTechnicalErrorSummary(originalError),
                forgePlayTechnicalErrorSummary(cleanupError)
            )
        }
    }
}

extension RuntimeInstallerError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unusablePrefix(let name):
            return appState.localizedFormat("선택한 Steam 프리픽스를 사용할 수 없습니다: %@", name)
        }
    }
}

extension WindowsRuntimeServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .invalidSelection(let message):
            return appState.localizedFormat("ForgePlay Runtime을 확인할 수 없습니다. %@", message)
        case .probeFailed(let result):
            return appState.localizedFormat("ForgePlay Runtime을 실행해 확인하지 못했습니다. 로그를 확인하세요: %@", result.stderrLog.path)
        case .missingSteamRendererCapability(let capability):
            return appState.localizedFormat(
                "%@ Windows용 Steam을 실행하려면 D3DMetal 또는 Vulkan/DXVK 렌더러를 제공하는 ForgePlay Runtime이 필요합니다.",
                appState.localized(capability.userMessage)
            )
        case .sourceScanFailed(let directory, let error):
            return appState.localizedFormat("Apple 보조 렌더러 입력을 검사하지 못했습니다: %@. %@", directory.path, forgePlayTechnicalErrorSummary(error))
        case .supplementalRedistScanFailed(let directory, let error):
            return appState.localizedFormat("Evaluation environment redist를 검사하지 못했습니다: %@. %@", directory.path, forgePlayTechnicalErrorSummary(error))
        case .unsafeSupplementalRedistSymlink(let url):
            return appState.localizedFormat("Evaluation environment redist 안의 symlink가 redist 폴더 밖을 가리킵니다: %@", url.path)
        case .unsafeSupplementalRedistHardlink(let url):
            return appState.localizedFormat("Evaluation environment redist 안의 hardlink 파일을 제거해야 합니다: %@", url.path)
        case .payloadReplacementRollbackFailed(let destination, let backup, let originalError, let rollbackError):
            return appState.localizedFormat(
                "Apple 보조 렌더러 교체에 실패했고 기존 파일을 되돌리지 못했습니다: %@. 백업 위치: %@. 원인: %@. 복구 오류: %@",
                destination.path,
                backup.path,
                forgePlayTechnicalErrorSummary(originalError),
                forgePlayTechnicalErrorSummary(rollbackError)
            )
        }
    }
}

extension ForgePlayBundledWindowsRuntimePolicyError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .resourceDirectoryUnavailable:
            return appState.localized("앱 번들 리소스 폴더를 찾을 수 없습니다.")
        case .runtimeContainerUnavailable(let url, let message):
            return appState.localizedFormat(
                "앱에 포함된 ForgePlay Runtime 폴더를 사용할 수 없습니다: %@. %@",
                url.path,
                message
            )
        case .runtimeExecutableUnavailable(let url):
            return appState.localizedFormat(
                "앱에 포함된 ForgePlay Runtime에서 실행 파일을 찾지 못했습니다: %@",
                url.path
            )
        }
    }
}

extension PathManagerError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .applicationSupportUnavailable:
            return appState.localized("Mac 내부 Application Support 위치를 확인할 수 없습니다.")
        case .rootNotConfigured:
            return appState.localized("ForgePlay 앱 데이터가 아직 준비되지 않았습니다.")
        case .missing(let url):
            return appState.localizedFormat("ForgePlay 앱 데이터 위치를 찾을 수 없습니다: %@", url.path)
        case .notWritable(let url):
            return appState.localizedFormat("ForgePlay 앱 데이터 위치에 쓸 수 없습니다: %@", url.path)
        case .cannotCreate(let url):
            return appState.localizedFormat("필요한 폴더를 만들 수 없습니다: %@", url.path)
        case .unsafeDirectory(let url):
            return appState.localizedFormat("ForgePlay 앱 데이터 위치가 안전한 일반 폴더가 아닙니다: %@", url.path)
        case .validationFailed(let url, let message):
            if let url {
                return appState.localizedFormat("ForgePlay 앱 데이터 위치를 확인하지 못했습니다: %@. %@", url.path, message)
            }
            return appState.localizedFormat("ForgePlay 앱 데이터 위치를 확인하지 못했습니다: %@", message)
        }
    }
}

extension StorageMigrationError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .sameLocation:
            return appState.localized("이미 선택된 저장 위치입니다.")
        case .nestedLocation:
            return appState.localized("기존 저장 위치 안쪽이나 바깥쪽의 상위 폴더로는 바로 복사할 수 없습니다. 별도의 빈 폴더를 선택하세요.")
        case .destinationIsVolumeRoot(let url):
            return appState.localizedFormat(
                "드라이브 최상위는 앱 데이터 위치로 사용할 수 없습니다. 드라이브 안에 비어 있는 하위 폴더를 만든 뒤 선택하세요: %@",
                url.path
            )
        case .destinationNotEmpty(let url):
            return appState.localizedFormat("기존 데이터를 복사하려면 비어 있는 폴더를 선택해야 합니다: %@", url.path)
        case .insufficientSpace(let required, let available):
            return appState.localizedFormat(
                "저장 위치를 옮기기에 공간이 부족합니다. 필요 공간: %@, 여유 공간: %@",
                appState.localizedByteCount(required),
                appState.localizedByteCount(available)
            )
        case .unsafeSymlink(let url):
            return appState.localizedFormat("저장 위치를 옮기기 전에 외부를 가리키는 symlink를 제거해야 합니다: %@", url.path)
        case .unsafeHardlink(let url):
            return appState.localizedFormat("저장 위치를 옮기기 전에 hardlink 파일을 제거해야 합니다: %@", url.path)
        case .scanFailed(let url, let message):
            return appState.localizedFormat("저장 위치를 검사하지 못했습니다: %@. %@", url.path, message)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("저장 위치의 파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .recordProjectionFailed(let field):
            return appState.localizedFormat("저장 기록의 %@ JSON을 UTF-8 텍스트로 저장하지 못했습니다.", field)
        case .migrationInProgress(let url):
            return appState.localizedFormat("다른 ForgePlay 프로세스가 앱 데이터 이동을 진행 중입니다: %@", url.path)
        case .cleanupFailed(let destination, let originalError, let cleanupError):
            return appState.localizedFormat(
                "저장 위치 이동에 실패했고 부분 복사본을 정리하지 못했습니다: %@. 원인: %@. 정리 오류: %@",
                destination.path,
                forgePlayTechnicalErrorSummary(originalError),
                forgePlayTechnicalErrorSummary(cleanupError)
            )
        }
    }
}

extension ManagedRootOperationLeaseError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .operationInProgress(let url):
            return appState.localizedFormat(
                "다른 ForgePlay 프로세스가 이 앱 데이터 위치를 사용 중입니다: %@",
                url.path
            )
        case .unsafeLockFile(let url):
            return appState.localizedFormat(
                "앱 데이터 작업 잠금 파일이 안전한 일반 파일이 아닙니다: %@",
                url.path
            )
        case .lockFailed(let url, let message):
            return appState.localizedFormat(
                "앱 데이터 작업 잠금을 준비하지 못했습니다: %@. %@",
                url.path,
                message
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .operationInProgress(let url):
            "Managed root operation is already in progress: \(url.path)"
        case .unsafeLockFile(let url):
            "Managed root operation lock is not a safe regular file: \(url.path)"
        case .lockFailed(let url, let message):
            "Could not acquire the managed root operation lock: \(url.path). \(message)"
        }
    }
}

extension ManagedStorageActivationError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .legacyMigrationDecisionRequired(let path):
            return appState.localizedFormat(
                "기존 ForgePlay 앱 데이터의 처리 방법을 선택하세요: %@",
                path
            )
        case .legacyRootAuthorizationRequired(let path):
            return appState.localizedFormat(
                "기존 ForgePlay 데이터를 내부 저장소로 옮기려면 이전 저장 위치를 다시 연결해야 합니다: %@",
                path
            )
        case .managedRootAuthorizationRequired(let path):
            return appState.localizedFormat(
                "선택한 ForgePlay 앱 데이터 위치에 다시 접근할 권한이 필요합니다: %@",
                path
            )
        case .legacyRootDoesNotContainManagedData(let url):
            return appState.localizedFormat(
                "선택한 폴더에서 이전 ForgePlay 프리픽스를 찾을 수 없습니다: %@",
                url.path
            )
        case .managedRootDoesNotContainManagedData(let url):
            return appState.localizedFormat(
                "현재 ForgePlay 앱 데이터 위치에서 옮길 프리픽스를 찾을 수 없습니다: %@",
                url.path
            )
        case .managedRootBookmarkRequired(let url):
            return appState.localizedFormat(
                "선택한 앱 데이터 위치의 접근 권한을 저장하지 못했습니다. macOS 폴더 선택기에서 다시 선택하세요: %@",
                url.path
            )
        case .stateRollbackFailed(let message):
            return appState.localizedFormat(
                "앱 데이터 위치 전환 실패 후 이전 상태를 복원하지 못했습니다: %@",
                message
            )
        }
    }
}

extension ManagedStorageWorkflowError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .transitionInProgress:
            return appState.localized("다른 앱 데이터 작업이 진행 중입니다. 완료된 뒤 다시 시도하세요.")
        case .legacyMigrationDecisionUnavailable:
            return appState.localized("옮길 기존 ForgePlay 앱 데이터가 선택되지 않았습니다. 앱 데이터 설정을 다시 여세요.")
        }
    }
}

extension SteamInstallError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .invalidInstaller(let url):
            return appState.localizedFormat("Steam 공식 페이지에서 받은 일반 파일 SteamSetup.exe를 선택해야 합니다: %@", url.path)
        case .installerMetadataReadFailed(let url, let message):
            return appState.localizedFormat("Steam 설치 파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        }
    }
}

extension SteamLaunchError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError,
    ForgePlayDiagnosticLogProvidingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .rendererBridgeInstallFailed(let url, let message):
            return appState.localizedFormat(
                "D3DMetal MetalFX/NGX 브리지를 준비하지 못했습니다: %@. %@",
                url.path,
                appState.localized(message)
            )
        case .rendererPolicyVerificationFailed(let message):
            return appState.localized(message)
        default:
            return forgePlayTechnicalDescription
        }
    }

    var forgePlayTechnicalDescription: String {
        errorDescription ?? "Windows Steam launch failed"
    }

    var forgePlayDiagnosticLogURL: URL? {
        switch self {
        case .prefixShutdownFailed(let result),
             .steamClientCompatibilitySetupFailed(let result):
            result.preferredDiagnosticLog
        case .rendererLifecycleFailed(let failure):
            failure.processResults.first?.preferredDiagnosticLog
        case .rendererBridgeInstallFailed,
             .rendererPolicyUnavailable,
             .rendererPolicyVerificationFailed,
             .steamClientCompatibilityFileInstallFailed,
             .steamClientCompatibilityVerificationFailed,
             .steamExecutableUnavailable,
             .steamExecutableMetadataReadFailed:
            nil
        }
    }
}

extension SteamLibraryScanError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .scanFailed(let url, let message):
            return appState.localizedFormat("Steam 라이브러리 폴더를 검사하지 못했습니다: %@. %@", url.path, message)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("Steam 라이브러리 파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .fileReadFailed(let url, let message):
            return appState.localizedFormat("Steam 라이브러리 파일을 읽지 못했습니다: %@. %@", url.path, message)
        }
    }
}

extension SteamLibraryRootDiscoveryError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .traversalFailed(let url, let message):
            return appState.localizedFormat(
                "Steam 라이브러리 폴더를 검사하지 못했습니다: %@. %@",
                url.path,
                message
            )
        case .noVerifiedSteamLibrary(let url, _):
            return appState.localizedFormat(
                "Steam 라이브러리 폴더를 검사하지 못했습니다: %@. %@",
                url.path,
                appState.localized(
                    "외장 저장공간에서 steamapps 폴더를 포함하는 SteamLibrary 루트를 선택하세요. 게임 실행은 Windows용 Steam 안에서 직접 합니다."
                )
            )
        case .ancestorAuthorizationRequired(
            let selectedRoot,
            let requiredRoot
        ):
            return appState.localizedFormat(
                "Steam 라이브러리 폴더를 검사하지 못했습니다: %@. %@",
                selectedRoot.path,
                appState.localized(
                    "샌드박스 배포 앱에서는 steamapps 하위 폴더가 아니라 그 폴더를 포함하는 SteamLibrary 루트를 선택하세요."
                ) + " \(requiredRoot.path)"
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .traversalFailed(let url, let message):
            return "Steam library root traversal failed: \(url.path). \(message)"
        case .noVerifiedSteamLibrary(let url, let skippedPaths):
            return "No verified steamapps directory was found for the selected " +
                "Steam storage root: \(url.path). Skipped inputs: " +
                skippedPaths.joined(separator: ", ")
        case .ancestorAuthorizationRequired(
            let selectedRoot,
            let requiredRoot
        ):
            return "The selected Steam storage folder does not authorize its " +
                "ancestor library root: selected=\(selectedRoot.path), " +
                "required=\(requiredRoot.path)"
        }
    }
}

extension SteamGameIdentityError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .invalidGameIdentity(let game):
            return appState.localizedFormat("Steam 게임 식별 정보가 올바르지 않습니다: %@ / %@", game.steamAppId, game.name)
        }
    }
}

extension PrefixRecordProjectionError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .encodeFailed(let field):
            return appState.localizedFormat("프리픽스 기록의 %@ 값을 JSON으로 변환할 수 없습니다.", field)
        case .utf8ConversionFailed(let field):
            return appState.localizedFormat("프리픽스 기록의 %@ JSON을 UTF-8 문자열로 변환할 수 없습니다.", field)
        }
    }
}

extension LogTextReaderError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsafeLogFile(let url):
            return appState.localizedFormat("로그 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@", url.path)
        case .scanFailed(let url, let message):
            return appState.localizedFormat("최근 로그 폴더를 검사하지 못했습니다: %@. %@", url.path, message)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("최근 로그 파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .textDecodeFailed(let url):
            return appState.localizedFormat("최근 로그 파일을 UTF-8 텍스트로 읽지 못했습니다: %@", url.path)
        case .changedDuringRead(let url):
            return appState.localizedFormat("최근 로그 파일이 읽는 동안 변경되어 일관된 스냅샷을 만들지 못했습니다: %@", url.path)
        }
    }
}

extension FileSystemItemPolicyError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .notRegularNonSymlinkFile(let url):
            return appState.localizedFormat("파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@", url.path)
        case .notNonSymlinkDirectory(let url):
            return appState.localizedFormat("폴더는 symlink가 아닌 디렉터리여야 합니다: %@", url.path)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .unsafeManagedDirectory(let url, let message):
            return appState.localizedFormat(
                "관리 경로를 안전하게 준비하지 못했습니다: %@. %@",
                url.path,
                message
            )
        }
    }
}

extension WindowsFontCompatibilityProfileError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .bundledPayloadMissing:
            return appState.localized("번들 한글 글꼴 파일이 없거나 무결성 검사를 통과하지 못했습니다.")
        case .unsafeDestination(let url):
            return appState.localizedFormat(
                "Windows 글꼴을 적용할 대상이 안전한 폴더가 아닙니다: %@",
                url.path
            )
        case .verificationFailed(let missing):
            return appState.localizedFormat(
                "Windows 한글 글꼴 호환성 적용을 확인하지 못했습니다: %@",
                missing.joined(separator: ", ")
            )
        case .collision(let reason):
            return appState.localizedFormat(
                "기존 Windows 글꼴 호환성 상태와 충돌합니다: %@",
                reason
            )
        case .overlappingLifecycle(let prefix):
            return appState.localizedFormat(
                "같은 Windows prefix에서 글꼴 수명주기 작업이 이미 실행 중입니다: %@",
                prefix.path
            )
        case .malformedLifecycleEvidence:
            return appState.localized(
                "Windows 글꼴 수명주기 기록이 정규 형식이 아니므로 자동 복구하지 않았습니다."
            )
        case .registrySnapshotMalformed(let url):
            return appState.localizedFormat(
                "Wine 레지스트리 snapshot을 안전하게 읽지 못했습니다: %@",
                url.path
            )
        case .journalDurabilityFailed(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 transaction 기록을 내구성 있게 확정하지 못했습니다: %@",
                reason
            )
        case .cleanupDurabilityUnknown(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 정리 완료의 디렉터리 내구성을 확인하지 못했습니다: %@",
                reason
            )
        case .commitCleanupDurabilityUnknown(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 commit marker의 디렉터리 내구성을 확인하지 못했습니다: %@",
                reason
            )
        case .uninstallDurabilityUnknown(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 제거 marker의 디렉터리 내구성을 확인하지 못했습니다: %@",
                reason
            )
        case .rollbackIncomplete(let reason, let remaining):
            return appState.localizedFormat(
                "Windows 글꼴 rollback이 완료되지 않았습니다: %@. 남은 항목: %@",
                reason,
                remaining.joined(separator: ", ")
            )
        case .uninstallIncomplete(let reason, let remaining):
            return appState.localizedFormat(
                "Windows 글꼴 제거가 완료되지 않았습니다: %@. 남은 항목: %@",
                reason,
                remaining.joined(separator: ", ")
            )
        case .recoveryConflict(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 자동 복구가 현재 상태와 충돌합니다: %@",
                reason
            )
        case .operationProjectionMismatch(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 수명주기 작업 projection이 일치하지 않습니다: %@",
                reason
            )
        case .interruptedAfterOperation(let operationID):
            return appState.localizedFormat(
                "Windows 글꼴 수명주기 작업 직후 중단을 시뮬레이션했습니다: %@",
                operationID
            )
        case .filesystemFailure(let reason):
            return appState.localizedFormat(
                "Windows 글꼴 파일 시스템 작업이 실패했습니다: %@",
                reason
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .bundledPayloadMissing:
            "The bundled Korean font payload is missing or failed integrity verification."
        case .unsafeDestination(let url):
            "The Windows font compatibility destination is unsafe: \(url.path)"
        case .verificationFailed(let missing):
            "Windows font compatibility verification failed. Missing: \(missing.joined(separator: ", "))"
        case .collision(let reason):
            "The existing Windows font compatibility state conflicts with this operation: \(reason)"
        case .overlappingLifecycle(let prefix):
            "A Windows font lifecycle operation is already running for this prefix: \(prefix.path)"
        case .malformedLifecycleEvidence:
            "The Windows font lifecycle evidence is not canonical, so automatic recovery was not attempted."
        case .registrySnapshotMalformed(let url):
            "The Wine registry snapshot could not be read safely: \(url.path)"
        case .journalDurabilityFailed(let reason):
            "The Windows font transaction journal could not be committed durably: \(reason)"
        case .cleanupDurabilityUnknown(let reason):
            "The directory durability of Windows font cleanup could not be verified: \(reason)"
        case .commitCleanupDurabilityUnknown(let reason):
            "The directory durability of Windows font commit-marker cleanup could not be verified: \(reason)"
        case .uninstallDurabilityUnknown(let reason):
            "The directory durability of the Windows font uninstall marker could not be verified: \(reason)"
        case .rollbackIncomplete(let reason, let remaining):
            "Windows font rollback did not complete: \(reason). Remaining items: \(remaining.joined(separator: ", "))"
        case .uninstallIncomplete(let reason, let remaining):
            "Windows font removal did not complete: \(reason). Remaining items: \(remaining.joined(separator: ", "))"
        case .recoveryConflict(let reason):
            "Windows font automatic recovery conflicts with the current state: \(reason)"
        case .operationProjectionMismatch(let reason):
            "The Windows font lifecycle operation projection does not match: \(reason)"
        case .interruptedAfterOperation(let operationID):
            "Windows font lifecycle interruption was simulated immediately after operation: \(operationID)"
        case .filesystemFailure(let reason):
            "A Windows font filesystem operation failed: \(reason)"
        }
    }
}

extension SteamStorageMountMutationError:
    ForgePlayUserFacingLocalizedError,
    ForgePlayTechnicalDescribingError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .mountNotFound:
            return appState.localizedFormat(
                "저장공간 상태 확인을 완료하지 못했습니다: %@",
                appState.localized("저장된 접근 권한")
            )
        case .persistenceVerificationFailed:
            return appState.localized(
                "Steam 저장공간 접근 권한을 저장한 뒤 다시 확인하지 못했습니다. 폴더를 다시 연결하세요."
            )
        case .persistenceRecoveryFailed:
            return appState.localized(
                "Steam 저장공간 접근 권한을 저장한 뒤 다시 확인하지 못했습니다. 폴더를 다시 연결하세요."
            )
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .mountNotFound(let identifier):
            return "The Steam storage mount does not exist: \(identifier)"
        case .persistenceVerificationFailed(let path):
            return "Steam storage mount persistence readback failed: \(path)"
        case .persistenceRecoveryFailed(
            let originalFailure,
            let recoveryFailure
        ):
            return "Steam storage mount persistence recovery failed. " +
                "Original failure: \(originalFailure). " +
                "Recovery failure: \(recoveryFailure)"
        }
    }
}

extension SteamStorageAccessValidationError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        appState.localizedFormat(
            "저장공간 상태 확인 실패: %@. 원래 폴더를 다시 선택하세요.",
            appState.localized(stage.displayNameKey)
        )
    }
}

extension SteamExternalStorageProcessGrantError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        appState.localized(
            "외장 저장소 접근 권한을 Windows용 Steam에 전달하지 못했습니다. ForgePlay에서 저장공간을 다시 연결한 뒤 Steam을 다시 실행하세요."
        )
    }
}

extension SteamExternalStorageGrantPreparationError:
    ForgePlayUserFacingLocalizedError
{
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        appState.localized(
            "외장 저장소 접근 권한을 Windows용 Steam에 전달하지 못했습니다. ForgePlay에서 저장공간을 다시 연결한 뒤 Steam을 다시 실행하세요."
        )
    }
}

extension SteamStorageAccessStage {
    var displayNameKey: String {
        switch self {
        case .bookmarkCreation, .bookmarkResolution:
            "저장된 접근 권한"
        case .securityScope:
            "보안 범위 접근"
        case .directoryValidation:
            "폴더 안전성"
        case .directoryListing:
            "폴더 내용 읽기"
        case .temporaryFileWrite:
            "임시 확인 파일 쓰기"
        case .temporaryFileRead:
            "임시 확인 파일 다시 읽기"
        case .temporaryFileDeletion:
            "임시 확인 파일 삭제"
        case .bookmarkRefresh:
            "접근 권한 갱신"
        }
    }
}

extension DiagnosticRecordDecodeError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .invalidUTF8(let id):
            return appState.localizedFormat("저장된 진단 기록을 UTF-8로 읽지 못했습니다: %@", id)
        case .oversized(let id, let byteCount, let limit):
            return appState.localizedFormat("저장된 진단 기록이 너무 큽니다: %@ %d bytes / limit %d bytes", id, byteCount, limit)
        case .decodeFailed(let id):
            return appState.localizedFormat("저장된 진단 기록을 읽지 못했습니다: %@", id)
        case .invalidAIEvidenceMetadata(let id):
            return appState.localizedFormat(
                "저장된 AI 진단 증거 또는 실행 영수증이 결과와 일치하지 않습니다: %@",
                id
            )
        }
    }
}

extension DiagnosticRecordPersistenceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .utf8ConversionFailed:
            return appState.localized("진단 기록 JSON을 UTF-8 텍스트로 저장하지 못했습니다.")
        }
    }
}

extension SupportBundleServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .rootMissing:
            return appState.localized("지원 번들을 만들 저장 위치가 아직 없습니다.")
        case .archiveFailed(let result):
            return appState.localizedFormat("지원 번들 압축 파일을 만들지 못했습니다. 로그를 확인하세요: %@", result.stderrLog.path)
        case .archiveCleanupFailed(let destination, let result, let cleanupError):
            return appState.localizedFormat(
                "지원 번들 압축 파일을 만들지 못했고 부분 파일을 정리하지 못했습니다: %@. 로그: %@. 정리 오류: %@",
                destination.path,
                result.stderrLog.path,
                forgePlayTechnicalErrorSummary(cleanupError)
            )
        case .archiveValidationFailed(let url, let message):
            return appState.localizedFormat(
                "지원 번들 압축 결과를 검증하지 못했습니다: %@. %@",
                url.path,
                message
            )
        case .scanFailed(let url, let error):
            return appState.localizedFormat("지원 번들 자료 폴더를 검사하지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        case .metadataReadFailed(let url, let error):
            return appState.localizedFormat("지원 번들 자료 파일 정보를 읽지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        }
    }
}

extension LogRetentionServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .scanFailed(let url, let error):
            return appState.localizedFormat("로그 폴더를 검사하지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        case .metadataReadFailed(let url, let error):
            return appState.localizedFormat("로그 파일 정보를 읽지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        case .cleanupInProgress:
            return appState.localized("로그 정리가 이미 진행 중입니다. 완료된 뒤 다시 시도하세요.")
        }
    }
}

extension LLMServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .disabled:
            return appState.localized("AI 문제 진단이 꺼져 있습니다.")
        case .providerUnavailable(let availability):
            return appState.localized(availability.message)
        case .badResponse:
            return appState.localized("AI 진단 응답을 해석할 수 없습니다.")
        }
    }
}

extension AutoFixServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .missingRuntime:
            return appState.localized("설치할 필수 구성요소(Runtime)를 알 수 없습니다.")
        case .missingInstaller:
            return appState.localized("설치 파일을 먼저 선택해야 합니다.")
        case .invalidInstaller:
            return appState.localized("선택한 설치 파일이 이 필수 구성요소와 맞지 않습니다.")
        case .missingBundledRuntime:
            return appState.localized("ForgePlay Runtime을 먼저 확인해야 합니다.")
        case .unsupportedAction:
            return appState.localized("이 조치는 자동으로 적용할 수 없습니다.")
        }
    }
}

extension CompatibilityServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .decodeFailed(let url):
            return appState.localizedFormat("실행 규칙을 읽을 수 없습니다: %@", url.lastPathComponent)
        case .unsafeRecipeFile(let url):
            return appState.localizedFormat("실행 규칙 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@", url.lastPathComponent)
        case .recipeTooLarge(let url, let byteCount, let limit):
            return appState.localizedFormat("실행 규칙 파일이 너무 큽니다: %@ %d bytes / limit %d bytes", url.lastPathComponent, byteCount, limit)
        case .invalidRecipe(let url):
            return appState.localizedFormat("실행 규칙 내용이 제품 정책에 맞지 않습니다: %@", url.lastPathComponent)
        case .recipeDiscoveryFailed(let url, let error):
            return appState.localizedFormat("실행 규칙 파일 목록을 검사하지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        case .recipeMetadataReadFailed(let url, let error):
            return appState.localizedFormat("실행 규칙 파일 정보를 읽지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        case .storedRecipeInvalidUTF8(let id):
            return appState.localizedFormat("저장된 실행 규칙 JSON을 UTF-8로 읽지 못했습니다: %@", id)
        case .storedRecipeTooLarge(let id, let byteCount, let limit):
            return appState.localizedFormat("저장된 실행 규칙이 너무 큽니다: %@ %d bytes / limit %d bytes", id, byteCount, limit)
        case .storedRecipeDecodeFailed(let id):
            return appState.localizedFormat("저장된 실행 규칙을 읽지 못했습니다: %@", id)
        case .storedRecipeInvalid(let id):
            return appState.localizedFormat("저장된 실행 규칙 내용이 제품 정책에 맞지 않습니다: %@", id)
        case .storedRecipeRecordMismatch(let id):
            return appState.localizedFormat("저장된 실행 규칙이 저장 레코드와 일치하지 않습니다: %@", id)
        case .ambiguousSteamAppID(let steamAppID):
            return appState.localizedFormat("같은 Steam App ID에 여러 실행 규칙이 있어 임의로 선택하지 않았습니다: %@", steamAppID)
        }
    }
}

extension CompatibilityRecipeRecordProjectionError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .encodeFailed(let recipeId):
            return appState.localizedFormat("실행 규칙을 저장 가능한 JSON으로 변환할 수 없습니다: %@", recipeId)
        case .utf8ConversionFailed(let recipeId):
            return appState.localizedFormat("실행 규칙 JSON을 UTF-8 문자열로 변환할 수 없습니다: %@", recipeId)
        }
    }
}

extension CompatibilityDBUpdateError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .missingFeedURL:
            return appState.localized("실행 규칙 DB 업데이트 주소를 먼저 입력해야 합니다.")
        case .insecureFeedURL:
            return appState.localized("실행 규칙 DB 업데이트는 HTTPS 주소만 사용할 수 있습니다.")
        case .invalidFeedURL:
            return appState.localized("실행 규칙 DB 업데이트 주소는 호스트가 있는 HTTPS URL이어야 하며, 사용자 정보나 프래그먼트 또는 민감한 쿼리 매개변수를 포함할 수 없습니다.")
        case .insecureRecipeURL(let id):
            return appState.localizedFormat("실행 규칙 파일은 HTTPS 주소만 사용할 수 있습니다: %@", id)
        case .invalidRecipeDescriptor(let id):
            return appState.localizedFormat("실행 규칙 descriptor가 올바르지 않습니다: %@", id)
        case .duplicateRecipeDescriptor(let id):
            return appState.localizedFormat("실행 규칙 descriptor ID가 중복되었습니다: %@", id)
        case .tooManyRecipes(let count, let limit):
            return appState.localizedFormat("실행 규칙 DB index에 포함된 recipe가 너무 많습니다: %d / limit %d", count, limit)
        case .insecureResolvedURL(let context):
            return appState.localizedFormat("실행 규칙 DB 업데이트가 공개 HTTPS 최종 주소가 아닌 곳으로 이동해 중단했습니다: %@", context)
        case .invalidHTTPStatus(let context, let statusCode):
            return appState.localizedFormat("실행 규칙 DB 업데이트 서버 응답이 올바르지 않습니다: %@ HTTP %d", context, statusCode)
        case .responseTooLarge(let context, let byteCount, let limit):
            return appState.localizedFormat("실행 규칙 DB 업데이트 응답이 너무 큽니다: %@ %d bytes / limit %d bytes", context, byteCount, limit)
        case .signatureVerifierMissing:
            return appState.localized("이 앱에는 원격 실행 규칙 DB 서명 검증 키가 포함되어 있지 않아 원격 업데이트를 적용하지 않습니다.")
        case .invalidPublicKey:
            return appState.localized("실행 규칙 DB 서명 검증 키를 읽을 수 없습니다.")
        case .unsupportedSchemaVersion(let version):
            return appState.localizedFormat("지원하지 않는 실행 규칙 DB schema version입니다: %d", version)
        case .invalidIndexSignature:
            return appState.localized("실행 규칙 DB index.json 서명이 올바르지 않습니다.")
        case .invalidRecipeSignature(let id):
            return appState.localizedFormat("실행 규칙 파일 서명이 올바르지 않습니다: %@", id)
        case .checksumMismatch(let id):
            return appState.localizedFormat("실행 규칙 파일 무결성 검사가 실패했습니다: %@", id)
        case .recipeIdMismatch(let expected, let actual):
            return appState.localizedFormat("실행 규칙 파일 ID가 인덱스와 일치하지 않습니다. 예상: %@, 실제: %@", expected, actual)
        case .invalidRecipe(let id):
            return appState.localizedFormat("실행 규칙 파일을 해석할 수 없습니다: %@", id)
        case .duplicateStoredRecipeRecord(let id):
            return appState.localizedFormat("저장된 실행 규칙 ID가 중복되었습니다: %@", id)
        case .duplicateSteamAppID(let steamAppID):
            return appState.localizedFormat("한 Steam App ID에 여러 실행 규칙을 적용할 수 없습니다: %@", steamAppID)
        case .updateInProgress:
            return appState.localized("실행 규칙 DB 업데이트가 이미 진행 중입니다. 완료된 뒤 다시 시도하세요.")
        }
    }
}

extension AppUpdateCheckError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .invalidLocalVersion:
            return appState.localized("현재 ForgePlay 버전 번호를 읽을 수 없습니다.")
        case .invalidLocalBuild:
            return appState.localized("현재 ForgePlay 빌드 번호를 읽을 수 없습니다.")
        case .invalidManifest:
            return appState.localized("공개 릴리스 정보가 예상 형식 또는 보안 검증을 통과하지 못했습니다.")
        case .invalidHTTPStatus(let status):
            return appState.localizedFormat("공개 릴리스 정보 서버 응답이 올바르지 않습니다: HTTP %d", status)
        case .invalidResolvedURL:
            return appState.localized("공개 릴리스 정보가 허용되지 않은 주소로 이동해 업데이트 확인을 중단했습니다.")
        case .invalidMIMEType:
            return appState.localized("공개 릴리스 정보 서버가 JSON 응답을 반환하지 않았습니다.")
        case .responseTooLarge(let received, let limit):
            return appState.localizedFormat(
                "공개 릴리스 정보 응답이 너무 큽니다: %d bytes / limit %d bytes",
                received,
                limit
            )
        case .transport:
            return appState.localized("공개 릴리스 정보를 가져오지 못했습니다.")
        case .cancelled:
            return appState.localized("업데이트 확인이 취소되었습니다.")
        }
    }
}

extension CompatibilityDBPublicKeyResourceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsafeResource(let url):
            return appState.localizedFormat("실행 규칙 DB 서명 검증 키는 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@", url.path)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("실행 규칙 DB 서명 검증 키 파일 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .readFailed(let url, let message):
            return appState.localizedFormat("실행 규칙 DB 서명 검증 키 파일을 읽지 못했습니다: %@. %@", url.path, message)
        case .oversized(let url, let byteCount, let limit):
            return appState.localizedFormat("실행 규칙 DB 서명 검증 키 파일이 너무 큽니다: %@ %d bytes / limit %d bytes", url.path, byteCount, limit)
        case .textDecodeFailed(let url):
            return appState.localizedFormat("실행 규칙 DB 서명 검증 키 파일은 UTF-8 텍스트여야 합니다: %@", url.path)
        }
    }
}

extension ProcessRunEvidenceWriterError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsafeEvidencePath(let url):
            return appState.localizedFormat(
                "프로세스 증거 파일 경로가 안전하지 않습니다: %@",
                url.path
            )
        case .evidenceTooLarge(let url, let byteCount):
            return appState.localizedFormat(
                "프로세스 증거 파일이 허용 크기를 초과했습니다: %@ (%d bytes)",
                url.path,
                byteCount
            )
        case .evidenceChangedDuringRead(let url):
            return appState.localizedFormat(
                "프로세스 증거 파일이 읽는 동안 변경되었습니다: %@",
                url.path
            )
        case .invalidEvidenceIdentity(let url):
            return appState.localizedFormat(
                "프로세스 증거 파일의 실행 식별자가 일치하지 않습니다: %@",
                url.path
            )
        }
    }
}

extension FailureDiagnosticEvidenceServiceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .unsafeDiagnosticDirectory(let url):
            return appState.localizedFormat(
                "실패 진단 파일을 저장할 폴더가 안전한 관리 폴더가 아닙니다: %@",
                url.path
            )
        case .allDiagnosticStorageUnavailable(let primary, let emergency):
            return appState.localizedFormat(
                "기본 로그와 비상 진단 저장소를 모두 사용할 수 없습니다. 기본: %@. 비상: %@",
                primary,
                emergency
            )
        }
    }
}

extension SafeProcessRunnerError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .executableMissing(let url):
            return appState.localizedFormat("실행 파일을 찾을 수 없습니다: %@", url.path)
        case .unsafeExecutable(let url):
            return appState.localizedFormat("실행 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@", url.path)
        case .unsafeActionInput(let url):
            return appState.localizedFormat("실행 입력 경로가 안전한 일반 파일/폴더가 아닙니다: %@", url.path)
        case .unsafeCommandArgument(let name):
            return appState.localizedFormat("Windows 명령 입력에 허용되지 않은 문자가 있습니다: %@", name)
        case .unsafeArchivePath(let url):
            return appState.localizedFormat("압축 파일 경로가 안전한 일반 경로가 아닙니다: %@", url.path)
        case .cannotCreateLog(let url):
            return appState.localizedFormat("로그 파일을 만들 수 없습니다: %@", url.path)
        case .metadataReadFailed(let url, let message):
            return appState.localizedFormat("실행 입력 경로 정보를 읽지 못했습니다: %@. %@", url.path, message)
        case .runnerLibrarySearchFailed(let url, let error):
            return appState.localizedFormat("ForgePlay Runtime의 라이브러리 경로를 검사하지 못했습니다: %@. %@", url.path, forgePlayTechnicalErrorSummary(error))
        case .prefixProcessVerificationFailed(let url, let message):
            return appState.localizedFormat("ForgePlay Runtime 프로세스 정리 상태를 확인하지 못했습니다: %@. %@", url.path, message)
        case .manualRendererSelectionRequired:
            return appState.localized("Steam을 실행하기 전에 D3DMetal - NVIDIA, DXMT 또는 D9VK 중 하나를 직접 선택해야 합니다.")
        case .invalidSteamCompatibilitySelection:
            return appState.localized("선택한 그래픽 백엔드와 Steam 실행 호환성 설정이 일치하지 않습니다.")
        case .gameRendererPayloadMissing(let url, let architecture):
            return appState.localizedFormat("선택한 게임 렌더러의 %@ DLL payload를 찾지 못했습니다: %@", architecture, url.path)
        case .gameRendererBridgePreparationFailed(let url, let reason):
            return appState.localizedFormat(
                "D3DMetal MetalFX/NGX 브리지를 준비하지 못했습니다: %@. %@",
                url.path,
                reason
            )
        case .invalidPrefixSynchronizationProfile(let url):
            return appState.localizedFormat("Steam 프리픽스의 Wine 동기화 설정을 읽을 수 없습니다: %@", url.path)
        case .sandboxIPCConfigurationMissing:
            return appState.localized("샌드박스 배포 앱의 ForgePlay Runtime IPC 구성이 없습니다. App Group이 포함된 앱을 다시 설치하세요.")
        case .unsafeWineServerRoot(let url, let reason):
            return appState.localizedFormat(
                "Wine 서버 경로를 안전하게 준비하지 못했습니다: %@. %@",
                url.path,
                reason
            )
        case .invalidRosettaAVXHostOverride:
            return appState.localized(
                "Rosetta AVX 설정 값이 올바르지 않습니다. FORGEPLAY_ROSETTA_ADVERTISE_AVX에는 0 또는 1만 사용하세요."
            )
        }
    }
}

extension ProcessExecutionEvidenceError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        appState.localizedError(underlyingError)
    }
}

extension ForgePlayRuntimeCapabilityError: ForgePlayUserFacingLocalizedError {
    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .bundledRuntimeUnavailable(let actionName):
            return appState.localizedFormat(
                "앱에 포함된 ForgePlay Runtime을 사용할 수 없습니다: %@",
                actionName
            )
        case .nonBundledRuntimeRejected(let actionName, let path):
            return appState.localizedFormat(
                "ForgePlay는 앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용합니다: %@, %@",
                actionName,
                path
            )
        case .bundledRuntimeIdentityIncomplete(let actionName, let reason):
            return appState.localizedFormat(
                "앱에 포함된 ForgePlay Runtime의 핵심 모듈 무결성을 확인할 수 없습니다: %@. %@",
                actionName,
                reason
            )
        }
    }
}
