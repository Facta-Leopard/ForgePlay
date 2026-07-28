import Foundation

private struct StorageCheckInspection: Sendable {
    var availableBytes: Int64?
    var errorSummary: String?
}

@MainActor
final class SystemCheckService {
    private let windowsRuntimeService: WindowsRuntimeService
    private let prefixManager: PrefixManager
    private let steamClientCompatibilityVerifier: SteamClientCompatibilityVerifier
    private let canRunBundledWindowsRuntime: () -> Bool
    private let bundledRuntimeUnavailableReasonKey: () -> String
    private let runtimeTranslationAvailability: () -> String

    init(
        pathManager _: PathManager,
        windowsRuntimeService: WindowsRuntimeService,
        prefixManager: PrefixManager,
        steamClientCompatibilityVerifier: SteamClientCompatibilityVerifier = SteamClientCompatibilityVerifier(),
        canRunBundledWindowsRuntime: @escaping () -> Bool = {
            ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
        },
        bundledRuntimeUnavailableReasonKey: @escaping () -> String = {
            ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey
        },
        runtimeTranslationAvailability: @escaping () -> String = {
            ProcessRunHostContext.capture().rosettaTranslationAvailability ?? "unknown"
        }
    ) {
        self.windowsRuntimeService = windowsRuntimeService
        self.prefixManager = prefixManager
        self.steamClientCompatibilityVerifier = steamClientCompatibilityVerifier
        self.canRunBundledWindowsRuntime = canRunBundledWindowsRuntime
        self.bundledRuntimeUnavailableReasonKey = bundledRuntimeUnavailableReasonKey
        self.runtimeTranslationAvailability = runtimeTranslationAvailability
    }

    func runChecks(rootURL: URL?, runtimeExecutable: URL?) async -> [SystemCheckResult] {
        var results: [SystemCheckResult] = []

        #if arch(arm64)
        results.append(SystemCheckResult(
            category: .appleSilicon,
            title: "Apple Silicon",
            detail: "이 Mac은 ForgePlay 실행 조건을 만족합니다.",
            status: .ok,
            technicalDetail: "arm64"
        ))
        #else
        results.append(SystemCheckResult(
            category: .appleSilicon,
            title: "Apple Silicon",
            detail: "ForgePlay는 Apple Silicon Mac을 대상으로 합니다.",
            status: .error,
            technicalDetail: "non-arm64"
        ))
        #endif

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isSupported = version.majorVersion >= 26
        results.append(SystemCheckResult(
            category: .operatingSystem,
            title: "macOS 26 이상",
            detail: isSupported ? "현재 macOS 버전은 지원 대상입니다." : "macOS 26 이상이 필요합니다.",
            status: isSupported ? .ok : .error,
            technicalDetail: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        ))

        if let rootURL {
            let inspection = await Self.inspectStorageRoot(rootURL)
            if let available = inspection.availableBytes {
                results.append(SystemCheckResult(
                    category: .storage,
                    title: "저장 위치",
                    detail: "선택한 위치에 파일을 저장할 수 있습니다.",
                    status: available > 20_000_000_000 ? .ok : .warning,
                    technicalDetail: "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available"
                ))
            } else {
                results.append(SystemCheckResult(
                    category: .storage,
                    title: "저장 위치",
                    detail: "선택한 위치에 쓸 수 없습니다. 다른 위치를 선택하세요.",
                    status: .error,
                    technicalDetail: inspection.errorSummary
                ))
            }
        } else {
            results.append(SystemCheckResult(
                category: .storage,
                title: "저장 위치",
                detail: "게임과 Steam 프리픽스를 저장할 위치를 먼저 선택해야 합니다.",
                status: .warning,
                technicalDetail: nil
            ))
        }

        if let runtimeExecutable {
            let translationAvailability = runtimeTranslationAvailability()
            if translationAvailability == "notDetected" {
                results.append(SystemCheckResult(
                    category: .windowsRuntime,
                    title: "ForgePlay Runtime",
                    detail: "Apple Silicon에서 번들 ForgePlay Runtime을 실행하려면 Rosetta가 필요합니다. macOS에서 Rosetta를 설치한 뒤 다시 확인하세요.",
                    status: .error,
                    technicalDetail: "rosetta-translation-not-detected"
                ))
            } else if !canRunBundledWindowsRuntime() {
                results.append(SystemCheckResult(
                    category: .windowsRuntime,
                    title: "ForgePlay Runtime",
                    detail: bundledRuntimeUnavailableReasonKey(),
                    status: .error,
                    technicalDetail: "bundled-runtime-unavailable"
                ))
            } else {
                do {
                    let validation = try windowsRuntimeService.validateExecutableStrict(runtimeExecutable)
                    if validation.isValid, rootURL != nil {
                        do {
                            _ = try await windowsRuntimeService.probeAndValidate(executable: runtimeExecutable)
                            let capability = try windowsRuntimeService.inspectRuntimeCapability(executable: runtimeExecutable)
                            let verification = steamClientCompatibilityVerifier.verify(capability: capability)
                            if verification.canLaunchWindowsSteam {
                                let detail = capability.steamUIRenderingValidationWarningMessage
                                    ?? (capability.supportsModernDirect3DGames
                                        ? "ForgePlay Runtime 실행 파일, Steam TLS 구성, Steam 클라이언트 호환 프로필, 게임 렌더러를 확인했습니다."
                                        : "Steam TLS 구성은 일부 확인됐지만, 현대 Direct3D 게임용 D3DMetal/DXVK renderer payload는 포함되어 있지 않습니다.")
                                results.append(SystemCheckResult(
                                    category: .windowsRuntime,
                                    title: "ForgePlay Runtime",
                                    detail: detail,
                                    status: .warning,
                                    technicalDetail: "\(validation.message). \(capability.technicalSummary)"
                                ))
                            } else {
                                results.append(SystemCheckResult(
                                    category: .windowsRuntime,
                                    title: "ForgePlay Runtime",
                                    detail: verification.userMessage,
                                    status: .error,
                                    technicalDetail: capability.technicalSummary
                                ))
                            }
                        } catch WindowsRuntimeServiceError.probeFailed(let result) {
                            results.append(SystemCheckResult(
                                category: .windowsRuntime,
                                title: "ForgePlay Runtime",
                                detail: "앱에 포함된 ForgePlay Runtime을 실행할 수 없습니다. 실패 로그를 확인하고 최신 빌드를 다시 설치하세요.",
                                status: .error,
                                technicalDetail: result.stderrLog.path
                            ))
                        } catch {
                            results.append(SystemCheckResult(
                                category: .windowsRuntime,
                                title: "ForgePlay Runtime",
                                detail: "앱에 포함된 ForgePlay Runtime을 확인하는 중 오류가 발생했습니다.",
                                status: .error,
                                technicalDetail: forgePlayTechnicalErrorSummary(error)
                            ))
                        }
                    } else {
                        results.append(SystemCheckResult(
                            category: .windowsRuntime,
                            title: "ForgePlay Runtime",
                            detail: validation.isValid ? "ForgePlay Runtime 실행 파일을 찾았습니다." : "앱에 포함된 ForgePlay Runtime이 손상되었거나 실행에 필요한 파일이 없습니다.",
                            status: validation.isValid ? .ok : .error,
                            technicalDetail: validation.message
                        ))
                    }
                } catch {
                    results.append(SystemCheckResult(
                            category: .windowsRuntime,
                        title: "ForgePlay Runtime",
                        detail: "앱에 포함된 ForgePlay Runtime을 확인하는 중 오류가 발생했습니다.",
                        status: .error,
                        technicalDetail: forgePlayTechnicalErrorSummary(error)
                    ))
                }
            }
        } else {
            if !canRunBundledWindowsRuntime() {
                results.append(SystemCheckResult(
                    category: .windowsRuntime,
                    title: "ForgePlay Runtime",
                    detail: bundledRuntimeUnavailableReasonKey(),
                    status: .error,
                    technicalDetail: "windows-runner-unavailable-in-current-build"
                ))
            } else {
                results.append(SystemCheckResult(
                    category: .windowsRuntime,
                    title: "ForgePlay Runtime",
                    detail: "앱에 포함된 ForgePlay Runtime을 확인해야 합니다.",
                    status: .warning,
                    technicalDetail: "bundled-runtime-not-configured"
                ))
            }
        }

        if let rootURL {
            let steamPrefix = rootURL.appending(
                path: ForgePlayPathRole.steamSharedPrefix.rawValue,
                directoryHint: .isDirectory
            )
            do {
                try prefixManager.validateUsablePrefix(at: steamPrefix)
                results.append(SystemCheckResult(
                    category: .steamPrefix,
                    title: "Steam 프리픽스",
                    detail: "Steam을 설치할 Steam 프리픽스가 준비되어 있습니다.",
                    status: .ok,
                    technicalDetail: steamPrefix.path
                ))
            } catch PrefixUsabilityError.missingRequiredItem {
                results.append(SystemCheckResult(
                    category: .steamPrefix,
                    title: "Steam 프리픽스",
                    detail: "Steam 프리픽스를 아직 초기화하지 않았습니다.",
                    status: .warning,
                    technicalDetail: steamPrefix.path
                ))
            } catch {
                results.append(SystemCheckResult(
                    category: .steamPrefix,
                    title: "Steam 프리픽스",
                    detail: "Steam 프리픽스를 사용할 수 없습니다. 처음 설정 또는 설정 화면에서 오류를 확인하세요.",
                    status: .error,
                    technicalDetail: forgePlayTechnicalErrorSummary(error)
                ))
            }
        } else {
            results.append(SystemCheckResult(
                category: .steamPrefix,
                title: "Steam 프리픽스",
                detail: "앱 데이터 위치가 준비된 뒤 만들 수 있습니다.",
                status: .unknown,
                technicalDetail: "managed-root-not-configured"
            ))
        }

        return results
    }

    private nonisolated static func inspectStorageRoot(_ rootURL: URL) async -> StorageCheckInspection {
        await Task.detached(priority: .utility) {
            do {
                try PathManager.validateManagedRoot(rootURL)
                let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return StorageCheckInspection(
                    availableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0,
                    errorSummary: nil
                )
            } catch {
                return StorageCheckInspection(
                    availableBytes: nil,
                    errorSummary: forgePlayTechnicalErrorSummary(error)
                )
            }
        }.value
    }
}
