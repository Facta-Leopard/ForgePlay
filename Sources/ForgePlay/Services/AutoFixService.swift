import Foundation

struct AutoFixExecutionResult: Hashable {
    var action: RecommendedAction
    var snapshotURL: URL?
    var processResult: ProcessRunResult?
    var message: String
}

enum AutoFixServiceError: LocalizedError {
    case missingRuntime
    case missingInstaller
    case invalidInstaller
    case missingBundledRuntime
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            "설치할 필수 구성요소(Runtime)를 알 수 없습니다."
        case .missingInstaller:
            "설치 파일을 먼저 선택해야 합니다."
        case .invalidInstaller:
            "선택한 설치 파일이 이 필수 구성요소와 맞지 않습니다."
        case .missingBundledRuntime:
            "ForgePlay Runtime을 먼저 확인해야 합니다."
        case .unsupportedAction:
            "이 조치는 자동으로 적용할 수 없습니다."
        }
    }
}

@MainActor
final class AutoFixService {
    private let prefixManager: PrefixManager
    private let runtimeManager: RuntimeManager
    private let steamPrefixService: SteamPrefixService

    init(
        prefixManager: PrefixManager,
        runtimeManager: RuntimeManager,
        steamPrefixService: SteamPrefixService
    ) {
        self.prefixManager = prefixManager
        self.runtimeManager = runtimeManager
        self.steamPrefixService = steamPrefixService
    }

    func apply(
        action: RecommendedAction,
        prefixURL: URL,
        runtimeExecutable: URL?,
        installerURL: URL? = nil
    ) async throws -> AutoFixExecutionResult {
        let action = LLMRecommendedActionPolicy.normalizedAction(action)
        switch action.type {
        case .installRuntime, .setWindowsVersion, .setDLLOverride:
            return try await steamPrefixService.performMaintenance {
                try await applyExclusive(
                    action: action,
                    prefixURL: prefixURL,
                    runtimeExecutable: runtimeExecutable,
                    installerURL: installerURL
                )
            }
        case .addLaunchOption,
             .importAppleSupplementalRenderer,
             .markUnsupported,
             .askUserToUpdateRuntime,
             .askUserToUpdateMacOS,
             .noAction:
            return try await applyExclusive(
                action: action,
                prefixURL: prefixURL,
                runtimeExecutable: runtimeExecutable,
                installerURL: installerURL
            )
        }
    }

    private func applyExclusive(
        action: RecommendedAction,
        prefixURL: URL,
        runtimeExecutable: URL?,
        installerURL: URL?
    ) async throws -> AutoFixExecutionResult {
        switch action.type {
        case .installRuntime:
            guard let runtime = action.runtime else { throw AutoFixServiceError.missingRuntime }
            guard let installerURL else { throw AutoFixServiceError.missingInstaller }
            guard let runtimeExecutable else { throw AutoFixServiceError.missingBundledRuntime }
            guard runtimeManager.isInstaller(installerURL, plausibleFor: runtime) else {
                throw AutoFixServiceError.invalidInstaller
            }
            try prefixManager.validateUsablePrefix(at: prefixURL)
            return try await runtimeManager.withQuiescentPrefixMutation(
                runtimeExecutable: runtimeExecutable,
                prefixURL: prefixURL,
                operationDescription: "runtime install \(runtime.rawValue)"
            ) {
                let snapshot = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "before-\(runtime.rawValue)")
                let result = try await runtimeManager.install(
                    runtime: runtime,
                    installer: installerURL,
                    runtimeExecutable: runtimeExecutable,
                    prefixURL: prefixURL
                )
                if result.succeeded {
                    try prefixManager.markRuntimeInstalled(runtime, prefixURL: prefixURL)
                }
                return AutoFixExecutionResult(
                    action: action,
                    snapshotURL: snapshot,
                    processResult: result,
                    message: "%@(%@) 설치를 실행했습니다."
                )
            }
        case .setWindowsVersion:
            guard let version = action.windowsVersion else { throw AutoFixServiceError.unsupportedAction }
            guard let runtimeExecutable else { throw AutoFixServiceError.missingBundledRuntime }
            try prefixManager.validateUsablePrefix(at: prefixURL)
            return try await runtimeManager.withQuiescentPrefixMutation(
                runtimeExecutable: runtimeExecutable,
                prefixURL: prefixURL,
                operationDescription: "Windows version update"
            ) {
                let snapshot = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "before-windows-version")
                let result = try await prefixManager.applyWindowsVersion(
                    version,
                    prefixURL: prefixURL,
                    runtimeExecutable: runtimeExecutable
                )
                return AutoFixExecutionResult(
                    action: action,
                    snapshotURL: snapshot,
                    processResult: result,
                    message: "Windows 설정을 %@로 기록했습니다."
                )
            }
        case .setDLLOverride:
            guard let dll = action.dll else { throw AutoFixServiceError.unsupportedAction }
            guard let override = action.override else { throw AutoFixServiceError.unsupportedAction }
            guard let runtimeExecutable else { throw AutoFixServiceError.missingBundledRuntime }
            try prefixManager.validateUsablePrefix(at: prefixURL)
            return try await runtimeManager.withQuiescentPrefixMutation(
                runtimeExecutable: runtimeExecutable,
                prefixURL: prefixURL,
                operationDescription: "DLL override update"
            ) {
                let snapshot = try await prefixManager.snapshot(prefixURL: prefixURL, reason: "before-dll-override")
                let result = try await prefixManager.applyDLLOverride(
                    dll,
                    override: override,
                    prefixURL: prefixURL,
                    runtimeExecutable: runtimeExecutable
                )
                return AutoFixExecutionResult(
                    action: action,
                    snapshotURL: snapshot,
                    processResult: result,
                    message: "DLL 사용 방식 설정을 기록했습니다."
                )
            }
        case .addLaunchOption, .importAppleSupplementalRenderer:
            throw AutoFixServiceError.unsupportedAction
        case .askUserToUpdateRuntime:
            return AutoFixExecutionResult(
                action: action,
                snapshotURL: nil,
                processResult: nil,
                message: "앱에 포함된 ForgePlay Runtime은 앱 업데이트로만 교체됩니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
            )
        case .markUnsupported:
            throw AutoFixServiceError.unsupportedAction
        case .askUserToUpdateMacOS, .noAction:
            return AutoFixExecutionResult(
                action: action,
                snapshotURL: nil,
                processResult: nil,
                message: action.reason
            )
        }
    }

}
