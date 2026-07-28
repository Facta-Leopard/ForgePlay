import Foundation

extension SetupReadiness {
    @MainActor
    func localizedSteamPrefixStateBlocker(appState: AppState) -> String {
        switch steamPrefixState {
        case .rootNotConfigured:
            appState.localized("내부 앱 데이터 위치를 준비하지 못했습니다.")
        case .rootUnavailable:
            rootIssue.map { appState.localizedError($0) } ?? appState.localized("내부 앱 데이터 위치를 확인하세요.")
        case .prefixMissing:
            appState.localized("Steam 프리픽스를 먼저 만들어야 합니다.")
        case .prefixInvalid:
            steamPrefixIssue.map { appState.localizedError($0) } ?? appState.localized("Steam 프리픽스를 먼저 복구하세요.")
        case .steamMissing:
            appState.localized("Windows용 Steam을 먼저 설치하세요.")
        case .runtimeMigrationRequired:
            appState.localized("ForgePlay Runtime 변경 사항을 Steam 프리픽스에 적용해야 합니다. 처음 설정에서 Steam 프리픽스 준비를 다시 실행하세요.")
        case .rendererUnverified:
            appState.localized("Steam 실행 경로를 먼저 적용/검증하세요.")
        case .rendererNeedsApply, .rendererNeedsRepair:
            rendererInspection.map { appState.localized($0.userMessage) } ?? appState.localized("Steam 실행 경로를 먼저 적용/검증하세요.")
        case .runtimeUnavailable:
            rendererInspection.map { appState.localized($0.userMessage) } ?? appState.localized("ForgePlay Runtime을 다시 확인하고, 필요하면 최신 ForgePlay 빌드를 설치해야 합니다.")
        case .launchReady:
            appState.localized("Windows용 Steam을 실행할 준비가 되었습니다.")
        }
    }
}

extension RuntimeId {
    @MainActor
    func localizedName(appState: AppState) -> String {
        appState.localized(beginnerName)
    }

    @MainActor
    func localizedTitle(appState: AppState) -> String {
        appState.localizedFormat("%@(%@)", localizedName(appState: appState), technicalName)
    }
}

extension PrefixRecord {
    @MainActor
    func localizedDisplayName(appState: AppState) -> String {
        PrefixDisplayNamePresentation.localizedDisplayName(
            id: id,
            mode: PrefixMode(rawValue: mode),
            displayName: displayName,
            appState: appState
        )
    }
}

extension PrefixMetadata {
    @MainActor
    func localizedDisplayName(appState: AppState) -> String {
        PrefixDisplayNamePresentation.localizedDisplayName(
            id: id,
            mode: mode,
            displayName: displayName,
            appState: appState
        )
    }
}

extension PrefixPreparationResult {
    @MainActor
    func localizedPreviousEnvironmentCleanupWarning(appState: AppState) -> String? {
        SteamEnvironmentReplacementPresentation.cleanupWarning(
            residualURL: residualPreviousEnvironmentURL,
            appState: appState
        )
    }
}

extension PrefixRebuildResult {
    @MainActor
    func localizedPreviousEnvironmentCleanupWarning(appState: AppState) -> String? {
        SteamEnvironmentReplacementPresentation.cleanupWarning(
            residualURL: residualPreviousEnvironmentURL,
            appState: appState
        )
    }
}

private enum SteamEnvironmentReplacementPresentation {
    @MainActor
    static func cleanupWarning(residualURL: URL?, appState: AppState) -> String? {
        residualURL.map {
            appState.localizedFormat(
                "이전 Steam 프리픽스의 임시 롤백 폴더를 정리하지 못했습니다: %@",
                $0.path
            )
        }
    }
}

private enum PrefixDisplayNamePresentation {
    private static let legacySteamSharedDisplayNames: Set<String> = [
        "Steam Prefix"
    ]

    @MainActor
    static func localizedDisplayName(
        id: String,
        mode: PrefixMode?,
        displayName: String,
        appState: AppState
    ) -> String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        if id == PrefixIdentifier.steamShared ||
            mode == .steamShared ||
            trimmedName == PrefixMode.steamShared.beginnerName ||
            legacySteamSharedDisplayNames.contains(trimmedName) {
            return appState.localized(PrefixMode.steamShared.beginnerName)
        }

        if case .legacy = mode {
            return appState.localized(PrefixMode.legacy("").beginnerName)
        }

        if let mode, trimmedName == mode.beginnerName {
            return appState.localized(mode.beginnerName)
        }

        return appState.localized(trimmedName.isEmpty ? "이전 프리픽스 기록" : trimmedName)
    }
}

extension RuntimeDefinition {
    @MainActor
    func localizedRemediationSteps(appState: AppState) -> [String] {
        var steps = [
            appState.localizedFormat("공식 출처: %@", officialSourceName),
            appState.localizedFormat("다운로드할 파일: %@", downloadHintSummary),
            appState.localizedFormat("ForgePlay에서 선택할 파일: %@", installerHintSummary)
        ]
        steps.insert(contentsOf: preparationNotes.map { appState.localized($0) }, at: 2)
        if !extractableArchiveHints.isEmpty {
            steps.append(
                appState.localizedFormat(
                    "압축 해제용 파일을 받은 경우 ForgePlay에서 %@를 선택하면 RuntimeCache/ExtractedInstallers에 풀고 추출된 설치 파일을 이어서 실행합니다.",
                    extractableArchiveHintSummary
                )
            )
        }
        steps.append(appState.localized("ForgePlay는 Steam 프리픽스의 스냅샷을 먼저 만든 뒤, 포함 Runtime으로 설치 파일을 그 Steam 프리픽스 안에서 실행합니다."))
        steps.append(appState.localized("선택한 설치 파일은 내부 앱 데이터의 RuntimeCache/Installers에 복사되어 같은 파일을 다시 찾을 수 있습니다."))
        steps.append(appState.localized("DLL 파일만 따로 내려받아 게임 폴더에 복사하지 마세요. 공식 설치 프로그램으로 Steam 프리픽스에 설치해야 등록 정보와 의존 DLL이 같이 들어갑니다."))
        return steps
    }

    @MainActor
    func localizedSelectionPanelMessage(appState: AppState) -> String {
        if extractableArchiveHints.isEmpty {
            return appState.localizedFormat(
                "공식 출처에서 받은 파일만 사용하세요. ForgePlay에서 선택할 수 있는 최종 설치 파일: %@. 다운로드한 파일이 zip 또는 압축 해제용 exe라면 먼저 압축을 풀고 실제 설치 파일을 선택하세요.",
                installerHintSummary
            )
        }
        return appState.localizedFormat(
            "공식 출처에서 받은 파일만 사용하세요. 최종 설치 파일: %@. 압축 해제용 파일도 지원합니다: %@.",
            installerHintSummary,
            extractableArchiveHintSummary
        )
    }
}

extension DiagnosticResult {
    @MainActor
    func localizedUserMessage(appState: AppState) -> String {
        switch (userMessage, userMessageFormatArguments) {
        case ("저장된 호환성 정보가 있습니다: %@", let arguments?) where arguments.count == 1:
            return appState.localizedFormat(userMessage, arguments[0])
        case (let message, let arguments?) where arguments.count == 1:
            return appState.localizedFormat(message, arguments[0])
        default:
            return appState.localized(userMessage)
        }
    }

    @MainActor
    func localizedTechnicalSummary(appState: AppState) -> String {
        technicalSummary
            .components(separatedBy: .newlines)
            .map { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else { return line }
                if let localizedKey = Self.knownTechnicalSummaryLocalizationKeys[trimmedLine] {
                    return appState.localized(localizedKey)
                }
                if trimmedLine.hasPrefix(Self.detectedItemsPrefix) {
                    let detectedItems = String(trimmedLine.dropFirst(Self.detectedItemsPrefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return appState.localizedFormat("감지된 항목: %@", detectedItems)
                }
                return appState.localized(trimmedLine)
            }
            .joined(separator: "\n")
    }

    private static let detectedItemsPrefix = "감지된 항목:"

    private static let knownTechnicalSummaryLocalizationKeys: [String: String] = [
        "Kernel driver dependency marker detected.": "Windows 커널 드라이버 의존성은 Mac 앱 내부에서 대체할 수 없습니다."
    ]
}

extension RecommendedAction {
    @MainActor
    func localizedRemediationSteps(
        appState: AppState,
        runtimeDefinition: RuntimeDefinition? = nil
    ) -> [String] {
        switch type {
        case .installRuntime:
            if let runtimeDefinition {
                return runtimeDefinition.localizedRemediationSteps(appState: appState)
            }
            return [
                appState.localized("공식 배포처에서 필요한 Windows 런타임 설치 파일을 받습니다."),
                appState.localized("ForgePlay에서 설치 파일을 선택하면 Steam 프리픽스 스냅샷을 만든 뒤 포함 Runtime으로 실행합니다."),
                appState.localized("설치가 실패하면 저장된 설치 로그를 다시 진단해 누락 DLL 또는 호환성 오류를 확인합니다.")
            ]
        case .setWindowsVersion:
            guard let windowsVersion else {
                return [
                    appState.localized("Windows 버전 값이 지정되지 않아 이 조치는 자동 적용하지 않습니다."),
                    appState.localized("새 로그를 다시 진단하거나 호환성 정보에서 명시된 조치만 적용하세요.")
                ]
            }
            let command = "reg add HKCU\\Software\\Wine /v Version /d \(windowsVersion) /f"
            return [
                appState.localized("적용 전에 ForgePlay가 Steam 프리픽스 스냅샷을 만듭니다."),
                appState.localizedFormat("ForgePlay Runtime으로 `%@` 명령을 실행합니다.", command),
                appState.localized("같은 게임을 다시 실행해 보고, 동일하게 실패하면 새 로그로 다시 진단합니다.")
            ]
        case .setDLLOverride:
            guard let dll, let override else {
                return [
                    appState.localized("DLL 이름 또는 override 값이 지정되지 않아 이 조치는 자동 적용하지 않습니다."),
                    appState.localized("새 로그를 다시 진단하거나 호환성 정보에서 명시된 조치만 적용하세요.")
                ]
            }
            let value = "\(dll)=\(override)"
            return [
                appState.localized("적용 전에 ForgePlay가 Steam 프리픽스 스냅샷을 만듭니다."),
                appState.localizedFormat("ForgePlay Runtime으로 `%@` 값을 기록합니다.", value),
                appState.localized("게임 폴더에 DLL을 직접 복사하기 전에 공식 런타임 설치 여부를 먼저 확인합니다.")
            ]
        case .addLaunchOption:
            guard let launchOption else {
                return [
                    appState.localized("실행 옵션 값이 지정되지 않아 이 조치는 자동 적용하지 않습니다."),
                    appState.localized("새 로그를 다시 진단하거나 호환성 정보에서 명시된 조치만 적용하세요.")
                ]
            }
            return [
                appState.localizedFormat(
                    "ForgePlay가 Steam 프리픽스 설정에 실행 옵션 `%@`을 추가하기 전에 스냅샷을 만듭니다.",
                    launchOption
                ),
                appState.localized("다음 실행부터 해당 게임을 이 옵션으로 시작합니다."),
                appState.localized("게임 설정 화면에 들어가면 해상도/창 모드를 저장한 뒤 옵션이 계속 필요한지 확인합니다.")
            ]
        case .askUserToUpdateRuntime:
            return [
                appState.localized("앱에 포함된 ForgePlay Runtime은 실행 중에 수정하지 않습니다."),
                appState.localized("앱에 포함된 ForgePlay Runtime은 앱 업데이트로만 교체됩니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."),
                appState.localized("업데이트 후 같은 실행을 다시 시도하고, 반복되면 새 실패 로그로 진단합니다.")
            ]
        case .markUnsupported:
            return [
                appState.localized("감지된 항목 이름으로 게임 공식 지원 문서, Steam 공지, 런처 설정을 검색해 안티치트 또는 Windows 커널 드라이버 요구 여부를 확인합니다."),
                appState.localized("게임이 공식적으로 안티치트 비활성화, 싱글플레이 전용, 또는 별도 런처 모드를 제공하는지 확인합니다. 공식 옵션이 없으면 우회하지 않습니다."),
                appState.localized("커널 드라이버 의존성은 Steam 프리픽스 안에 DLL이나 Runtime을 추가 설치해도 해결되지 않습니다."),
                appState.localized("공식 Mac 버전, 클라우드 게임, 콘솔, 또는 Windows PC 실행처럼 커널 드라이버를 지원하는 경로를 선택합니다."),
                appState.localized("게임 업데이트나 안티치트 정책 변경 후에는 새 로그로 다시 진단하고, 필요하면 지원 번들을 만들어 공유합니다.")
            ]
        case .importAppleSupplementalRenderer:
            return [
                appState.localized("ForgePlay Runtime을 다시 확인하고, 필요하면 최신 ForgePlay 빌드를 설치해야 합니다."),
                appState.localized("Apple 공식 Evaluation environment는 선택적 D3DMetal 보조 렌더러이며 단독 실행 엔진이 아닙니다."),
                appState.localized("설정에서 Apple 공식 Evaluation environment DMG 또는 redist 폴더를 선택하면 ForgePlay가 보조 렌더러만 가져옵니다.")
            ]
        case .askUserToUpdateMacOS:
            return [
                appState.localized("macOS 소프트웨어 업데이트 화면을 열어 현재 설치 가능한 업데이트를 확인합니다."),
                appState.localized("업데이트 후 ForgePlay에서 Mac 상태 확인을 다시 실행합니다."),
                appState.localized("같은 그래픽 오류가 반복되면 ForgePlay Runtime 상태와 게임 로그를 다시 진단합니다.")
            ]
        case .noAction:
            if reason == "Steam 실행 화면에서 현재 게임의 DirectX 세대에 맞는 단일 백엔드를 직접 선택한 뒤 Steam을 다시 실행합니다." {
                return [
                    appState.localized("Steam 실행 화면에서 D3DMetal, DXMT, D9VK 또는 DXVK 중 하나를 직접 선택한 뒤 Steam을 다시 실행합니다."),
                    appState.localized("DirectX 11/12는 D3DMetal, DirectX 9는 D9VK를 먼저 시도하고, DXMT 또는 DXVK는 같은 세대의 대체 경로로 비교합니다."),
                    appState.localized("백엔드를 바꿔도 같은 page fault로 종료되면 최신 실행 로그를 문제 진단에서 다시 분석합니다.")
                ]
            }
            if reason == "게임 프로세스가 ForgePlay Runtime 안에서 크래시했습니다. Windows용 Steam 실행 상태, Steam 라이브러리 연결, 호환성 정보, 게임 렌더러 payload를 순서대로 확인해야 합니다." {
                return [
                    appState.localized("ForgePlay에서 Windows용 Steam을 연 뒤 Steam 창의 라이브러리에서 같은 게임이 보이는지 확인합니다."),
                    appState.localized("외장 저장공간 라이브러리는 Steam 실행 전에 Windows 드라이브 문자로 연결됩니다. Steam 창에서 라이브러리가 보이지 않으면 Steam 실행 화면에서 라이브러리를 다시 연결한 뒤 Steam을 다시 여세요."),
                    appState.localized("호환성 정보가 있으면 권장 Runtime, 실행 옵션, Windows 버전을 먼저 적용합니다."),
                    appState.localized("같은 page fault가 반복되면 D3DMetal/Vulkan 구성이 포함된 ForgePlay Runtime으로 다시 실행합니다.")
                ]
            }
            if reason == "Steam 프리픽스를 새로 만든 뒤 Steam에서 다시 실행해야 합니다." {
                return [
                    appState.localized("Steam 프리픽스를 다시 만들고, Windows용 Steam에서 같은 게임을 다시 실행합니다."),
                    appState.localized("같은 로그에 `kernel32.dll` 또는 `c000007b`가 반복되면 기존 Steam 프리픽스 아키텍처가 꼬인 상태로 보고 새 Steam 프리픽스를 사용합니다."),
                    appState.localized("이 문제는 Steam 프리픽스 안에 Windows를 설치해서 해결하는 방식이 아닙니다.")
                ]
            }
            if reason == "Windows Steam 화면은 실행 인자 수가 아니라 ForgePlay Runtime의 WebHelper 프로세스 정책과 교차 프로세스 창 표면 경로로 확인해야 합니다." {
                return [
                    appState.localized("Windows Steam 창에서 로그인, Steam Guard 또는 라이브러리 화면이 실제로 보이는지 확인합니다."),
                    appState.localized("검은 화면이면 실행 인자를 바꾸지 말고 최신 진단에서 번들 Runtime의 WebHelper 프로세스 정책과 교차 프로세스 창 표면 기록을 확인합니다."),
                    appState.localized("Steam 프리픽스 검증에서 레지스트리나 필수 파일 손상이 확인된 경우에만 프리픽스를 재생성합니다.")
                ]
            }
            return [
                appState.localized("이 로그 줄만으로는 설치해야 할 Windows DLL이나 런타임이 확정되지 않았습니다."),
                appState.localized("Steam 설치 창이나 게임 창이 열려 있다면 그대로 진행합니다."),
                appState.localized("창이 닫히거나 실제 실행이 실패하면 ForgePlay가 저장한 최신 stdout/stderr 로그를 다시 분석합니다.")
            ]
        }
    }

    @MainActor
    func localizedReason(appState: AppState) -> String {
        guard type == .installRuntime, let runtime else {
            return Self.localizedKnownReason(reason, appState: appState)
        }

        let runtimeName = runtime.localizedName(appState: appState)
        switch reason {
        case "%@(%@) 누락 신호입니다. 공식 설치 파일을 받아 Steam 프리픽스에 설치해야 합니다.":
            return appState.localizedFormat(reason, runtimeName, runtime.technicalName)
        case "호환성 정보에 %@(%@) 설치 필요가 표시되어 있습니다. 공식 설치 파일을 Steam 프리픽스에 적용합니다.":
            return appState.localizedFormat(reason, runtimeName, runtime.technicalName)
        default:
            return Self.localizedKnownReason(reason, appState: appState)
        }
    }

    @MainActor
    private static func localizedKnownReason(_ reason: String, appState: AppState) -> String {
        knownLocalizedReasonKeys.contains(reason) ? appState.localized(reason) : reason
    }

    private static let knownLocalizedReasonKeys: Set<String> = [
        "추가 정보가 필요합니다. 지원 번들을 만들어 공유하거나 AI 문제 진단을 켤 수 있습니다.",
        "Apple 공식 보조 렌더러 최신 버전을 가져왔는지 확인합니다.",
        "Apple 공식 보조 렌더러 최신 버전을 다시 가져와 보세요.",
        "일부 게임은 창 모드로 먼저 실행하면 설정 화면까지 진입할 수 있습니다.",
        "모니터/전체 화면 초기화 실패가 감지되어 창 모드로 먼저 실행해 봅니다.",
        "Steam 실행 화면에서 현재 게임의 DirectX 세대에 맞는 단일 백엔드를 직접 선택한 뒤 Steam을 다시 실행합니다.",
        "ForgePlay가 관리하는 Steam/Wine 프로세스를 모두 종료한 뒤 다시 실행하고, 반복되면 Runtime의 WebHelper 프로세스 생성 및 창 표면 로그를 확인합니다.",
        "ForgePlay에서 Steam 실행 버튼을 눌러 로그인 후 게임을 다시 실행하세요.",
        "Steam 프리픽스를 Windows 10 64-bit 기준으로 맞춥니다.",
        "Steam 프리픽스 검증에서 레지스트리 파일 손상이 확인된 경우에만 새 프리픽스를 만들고 SteamSetup.exe를 다시 설치합니다.",
        "Vulkan 또는 D3DMetal 게임 렌더러 payload를 포함한 ForgePlay Runtime이 필요합니다.",
        "창이 정상적으로 열렸다면 그대로 진행하세요. 창이 닫히거나 로그인/설치가 실제로 막히면 그때 저장된 로그와 함께 다시 진단합니다.",
        "커널 수준 안티치트는 Windows 호환 런타임에서 지원되지 않는 경우가 많습니다.",
        "Windows 커널 드라이버 의존성은 Mac 앱 내부에서 대체할 수 없습니다.",
        "Steam 프리픽스를 새로 만든 뒤 Steam에서 다시 실행해야 합니다.",
        "Windows Steam 화면은 실행 인자 수가 아니라 ForgePlay Runtime의 WebHelper 프로세스 정책과 교차 프로세스 창 표면 경로로 확인해야 합니다.",
        "게임 프로세스가 ForgePlay Runtime 안에서 크래시했습니다. Windows용 Steam 실행 상태, Steam 라이브러리 연결, 호환성 정보, 게임 렌더러 payload를 순서대로 확인해야 합니다.",
        "호환성 정보에 권장 실행 옵션으로 등록되어 있습니다.",
        "AI가 권장한 조치입니다. 적용 전 내용을 확인하세요."
    ]
}

extension AutoFixExecutionResult {
    @MainActor
    func localizedMessage(appState: AppState) -> String {
        if action.type == .setWindowsVersion, let version = action.windowsVersion {
            return appState.localizedFormat("Windows 설정을 %@로 기록했습니다.", version)
        }

        guard action.type == .installRuntime, let runtime = action.runtime else {
            return appState.localized(message)
        }

        return appState.localizedFormat(
            "%@(%@) 설치를 실행했습니다.",
            runtime.localizedName(appState: appState),
            runtime.technicalName
        )
    }
}
