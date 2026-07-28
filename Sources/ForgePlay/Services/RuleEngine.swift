import Foundation

struct RuleEngineMatch: Hashable {
    var category: DiagnosticCategory
    var confidence: Double
    var userMessage: String
    var userMessageFormatArguments: [String]?
    var technicalSummary: String
    var riskLevel: RiskLevel
    var actions: [RecommendedAction]
}

struct LogDocument: Hashable {
    var title: String
    var text: String
    var sourceURL: URL?
}

enum DiagnosticRuleContext: Hashable {
    case manualLog
    case gameLaunch
    case setupOrInstaller

    var allowsUnsupportedDependencyDetection: Bool {
        switch self {
        case .manualLog, .gameLaunch:
            true
        case .setupOrInstaller:
            false
        }
    }
}

private struct UnsupportedDependencySignal: Hashable {
    var detectedItems: [String]

    var summary: String {
        let uniqueItems = Array(NSOrderedSet(array: detectedItems)).compactMap { $0 as? String }
        guard !uniqueItems.isEmpty else {
            return "Windows kernel driver"
        }
        let visibleItems = uniqueItems.prefix(6)
        let suffix = uniqueItems.count > visibleItems.count ? ", ..." : ""
        return visibleItems.joined(separator: ", ") + suffix
    }
}

struct RuleEngine {
    func analyze(
        logs: [LogDocument],
        game: SteamGame? = nil,
        recipe: CompatibilityRecipe? = nil,
        context: DiagnosticRuleContext = .manualLog
    ) -> [DiagnosticResult] {
        let combined = logs.map(\.text).joined(separator: "\n")
        return analyze(logText: combined, game: game, recipe: recipe, context: context)
    }

    func analyze(
        logText: String,
        game: SteamGame? = nil,
        recipe: CompatibilityRecipe? = nil,
        context: DiagnosticRuleContext = .manualLog
    ) -> [DiagnosticResult] {
        let normalized = logText.lowercased()
        var matches: [RuleEngineMatch] = []

        if let recipe {
            matches.append(recipeMatch(recipe))
        }

        matches.append(contentsOf: runtimeMatches(in: normalized))
        matches.append(contentsOf: graphicsMatches(in: normalized))
        matches.append(contentsOf: steamMatches(in: normalized))
        matches.append(contentsOf: runtimeDependencyMatches(in: normalized))
        matches.append(contentsOf: prefixMatches(in: normalized))
        matches.append(contentsOf: gameProcessCrashMatches(in: normalized))
        if context.allowsUnsupportedDependencyDetection {
            matches.append(contentsOf: unsupportedMatches(in: normalized))
        }
        matches.append(contentsOf: wineDiagnosticMatches(in: normalized))

        if matches.isEmpty, !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matches.append(RuleEngineMatch(
                category: .unknown,
                confidence: 0.35,
                userMessage: "실행 기록은 찾았지만 흔한 오류 패턴은 확인되지 않았습니다.",
                technicalSummary: "No local rule matched the supplied logs.",
                riskLevel: .low,
                actions: [RecommendedAction(
                    type: .noAction,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .low,
                    reason: "추가 정보가 필요합니다. 지원 번들을 만들어 공유하거나 AI 문제 진단을 켤 수 있습니다."
                )]
            ))
        }

        if let game, game.name.localizedCaseInsensitiveContains("elden ring") {
            matches.append(RuleEngineMatch(
                category: .graphicsIssue,
                confidence: 0.62,
                userMessage: "ELDEN RING은 최신 ForgePlay Runtime과 그래픽 호환성이 중요합니다.",
                technicalSummary: "Known high-demand D3D12 title; verify Runtime/D3DMetal version and launch path.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .importAppleSupplementalRenderer,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "Direct3D 12용 Apple 보조 렌더러가 준비되어 있는지 확인합니다."
                )]
            ))
        }

        return merge(matches)
    }

    private func runtimeMatches(in text: String) -> [RuleEngineMatch] {
        var matches: [RuleEngineMatch] = []
        let runtimePatterns: [(patterns: [String], runtime: RuntimeId, category: DiagnosticCategory, message: String)] = [
            (["vcruntime140", "msvcp140", "api-ms-win-crt", "ucrtbase"], .vcrun2022, .missingRuntime, "Microsoft Visual C++ 구성요소가 부족해 보입니다."),
            (["msvcr120", "msvcp120"], .vcrun2013, .missingRuntime, "오래된 Visual C++ 2013 구성요소가 필요해 보입니다."),
            (["msvcr110", "msvcp110"], .vcrun2012, .missingRuntime, "오래된 Visual C++ 2012 구성요소가 필요해 보입니다."),
            (["msvcr100", "msvcp100"], .vcrun2010, .missingRuntime, "오래된 Visual C++ 2010 구성요소가 필요해 보입니다."),
            (["d3dx9_43", "d3dcompiler_43", "xinput1_3"], .d3dx9, .directXIssue, "오래된 DirectX 구성요소가 필요해 보입니다."),
            (["xinput1_4", "xinput9_1_0"], .xinput, .directXIssue, "게임패드 입력용 DirectX 구성요소가 필요해 보입니다."),
            (["clr20r3", ".net framework", "mscoree", "system.io.fileloadexception"], .dotnet48, .dotnetIssue, ".NET 구성요소가 필요해 보입니다."),
            (["openal32", "alc_open_device", "oalinst"], .openal, .missingRuntime, "OpenAL 오디오 구성요소가 필요해 보입니다."),
            (["microsoft.xna", "xna framework"], .xna40, .missingRuntime, "XNA 게임 구성요소가 필요해 보입니다."),
            (["physxloader", "physx"], .physx, .missingRuntime, "PhysX 물리 엔진 구성요소가 필요해 보입니다.")
        ]

        for item in runtimePatterns where item.patterns.contains(where: text.contains) {
            matches.append(RuleEngineMatch(
                category: item.category,
                confidence: 0.82,
                userMessage: item.message,
                technicalSummary: "Matched runtime pattern for \(item.runtime.rawValue).",
                riskLevel: item.runtime.riskLevel,
                actions: [RecommendedAction(
                    type: .installRuntime,
                    runtime: item.runtime,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: item.runtime.riskLevel,
                    reason: "%@(%@) 누락 신호입니다. 공식 설치 파일을 받아 Steam 프리픽스에 설치해야 합니다."
                )]
            ))
        }
        return matches
    }

    private func runtimeDependencyMatches(in text: String) -> [RuleEngineMatch] {
        let hasDyldMissingLibrary = text.contains("dyld") &&
            text.contains("library not loaded") &&
            text.contains(".dylib")
        let mentionsBundledRuntime = text.contains("/wine/bin/") ||
            text.contains("wineserver") ||
            text.contains("/runners/forgeplayruntime/") ||
            text.contains("forgeplay runtime")
        guard hasDyldMissingLibrary && mentionsBundledRuntime else {
            return []
        }

        return [RuleEngineMatch(
            category: .runtimeDependency,
            confidence: 0.9,
            userMessage: "ForgePlay Runtime의 macOS 라이브러리 경로가 맞지 않아 실행이 막혔습니다.",
            technicalSummary: "Matched a missing dylib failure from the bundled ForgePlay Runtime.",
            riskLevel: .medium,
            actions: [RecommendedAction(
                type: .askUserToUpdateRuntime,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: false,
                riskLevel: .low,
                reason: "번들 Runtime 파일이 손상되었을 수 있으므로 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
            )]
        )]
    }

    private func graphicsMatches(in text: String) -> [RuleEngineMatch] {
        var matches: [RuleEngineMatch] = []
        if ["d3dmetal", "metal error", "mtldevice", "dxgi_error", "d3d12", "vkd3d"].contains(where: text.contains) {
            matches.append(RuleEngineMatch(
                category: .graphicsIssue,
                confidence: 0.74,
                userMessage: "그래픽 변환 과정에서 문제가 난 것으로 보입니다.",
                technicalSummary: "Matched D3DMetal/DXGI/D3D12 graphics failure patterns.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .importAppleSupplementalRenderer,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "Apple 보조 렌더러를 가져온 뒤 해당 실행의 렌더러 라우팅 로그를 다시 확인하세요."
                )]
            ))
        }
        if ["vulkan_init_once wine was built without vulkan support", "wine was built without vulkan support"].contains(where: text.contains) {
            matches.append(RuleEngineMatch(
                category: .graphicsIssue,
                confidence: 0.88,
                userMessage: "앱에 포함된 ForgePlay Runtime에 Vulkan 그래픽 지원이 없어 실행이 막혔습니다.",
                technicalSummary: "The bundled ForgePlay Runtime reported: Wine was built without Vulkan support.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .askUserToUpdateRuntime,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "Vulkan 또는 D3DMetal 게임 렌더러 payload를 포함한 ForgePlay Runtime이 필요합니다."
                )]
            ))
        }
        if [
            "find_monitor_from_path failed to find monitor with path",
            "failed to find monitor with path",
            "display\\\\"
        ].contains(where: text.contains) {
            matches.append(RuleEngineMatch(
                category: .graphicsIssue,
                confidence: 0.89,
                userMessage: "게임이 디스플레이/그래픽 초기화 단계에서 크래시한 것으로 보입니다.",
                technicalSummary: "Wine failed to resolve a display monitor path before the game process crashed. This points to fullscreen/display initialization or game renderer payload handling, not a confirmed Windows runtime dependency.",
                riskLevel: .medium,
                actions: [
                    RecommendedAction(
                        type: .addLaunchOption,
                        runtime: nil,
                        windowsVersion: nil,
                        dll: nil,
                        override: nil,
                        launchOption: "-windowed",
                        requiresUserConfirmation: true,
                        riskLevel: .low,
                        reason: "모니터/전체 화면 초기화 실패가 감지되어 창 모드로 먼저 실행해 봅니다."
                    ),
                    RecommendedAction(
                        type: .noAction,
                        runtime: nil,
                        windowsVersion: nil,
                        dll: nil,
                        override: nil,
                        launchOption: nil,
                        requiresUserConfirmation: false,
                        riskLevel: .low,
                        reason: "Steam 실행 화면에서 현재 게임의 DirectX 세대에 맞는 단일 백엔드를 직접 선택한 뒤 Steam을 다시 실행합니다."
                    )
                ]
            ))
        }
        if ["err:winediag:nodrv_createwindow", "failed to create window", "no vulkan", "graphics driver"].contains(where: text.contains) {
            matches.append(RuleEngineMatch(
                category: .graphicsIssue,
                confidence: 0.64,
                userMessage: "게임 창을 만들지 못했습니다. 전체 화면/창 모드 설정이 영향을 줄 수 있습니다.",
                technicalSummary: "Window creation or graphics driver style error detected.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .addLaunchOption,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: "-windowed",
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "일부 게임은 창 모드로 먼저 실행하면 설정 화면까지 진입할 수 있습니다."
                )]
            ))
        }
        return matches
    }

    private func steamMatches(in text: String) -> [RuleEngineMatch] {
        let steamCEFWindowFailed =
            text.contains("windows steam cef login ui was created, but steam webhelper rendering failed") ||
            text.contains("windows steam cef login ui was created while webhelper gpu initialization reported the black-window signature") ||
            (
                text.contains("steam webhelper") &&
                text.contains("black-window signature")
            ) ||
            (
                text.contains("steam webhelper gpu log tail") &&
                text.contains("eglinitialize d3d11 failed") &&
                text.contains("steam ui html log tail") &&
                text.contains("createbrowser") &&
                text.contains("steam login log tail") &&
                text.contains("waitingforcredentials")
            )
        if steamCEFWindowFailed {
            return [RuleEngineMatch(
                category: .steamIssue,
                confidence: 0.96,
                userMessage: "Windows용 Steam 창이 열렸지만 검은 화면으로만 렌더링되고 있습니다.",
                technicalSummary: "Matched Windows Steam CEF/WebHelper black-window signature. The Steam process can stay alive while the visible CEF window is unusable.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .askUserToUpdateRuntime,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "Windows용 Steam 창이 실제로 검은 화면이면 Steam CEF/WebHelper 렌더링을 지원하는 ForgePlay Runtime으로 다시 실행하세요."
                )]
            )]
        }
        if text.contains("the executable-scoped steam webhelper process policy reached") ||
            text.contains("steam cef gpu mitigation reached steam webhelper") ||
            text.contains("steam cef gpu/compositing mitigation flags reached steam webhelper") ||
            text.contains("disabling gpu acceleration: disabled/commandline") ||
            text.contains("--in-process-gpu") ||
            text.contains("disabling gpu acceleration due to --disable-gpu-compositing") {
            return [RuleEngineMatch(
                category: .steamIssue,
                confidence: 0.62,
                userMessage: "Steam WebHelper 프로세스 정책은 적용됐지만 화면 렌더링은 별도 확인이 필요합니다.",
                technicalSummary: "Matched the executable-scoped Steam WebHelper process policy. This confirms the bundled Wine CreateProcess policy reached WebHelper, but it is not proof that the Windows Steam UI rendered.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .noAction,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .low,
                    reason: "Windows Steam 화면은 실행 인자 수가 아니라 ForgePlay Runtime의 WebHelper 프로세스 정책과 교차 프로세스 창 표면 경로로 확인해야 합니다."
                )]
            )]
        }
        if text.contains("invalid reuse after initialization failure") {
            return [RuleEngineMatch(
                category: .steamIssue,
                confidence: 0.88,
                userMessage: "Windows용 Steam 또는 Steam WebHelper가 초기화 실패 뒤 같은 초기화 경로를 다시 사용하려다 중단됐습니다.",
                technicalSummary: "Matched invalid reuse after initialization failure. In ForgePlay launch logs this points to a failed Steam/CEF initialization path being reused inside the ForgePlay Runtime process.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .noAction,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .low,
                    reason: "ForgePlay가 관리하는 Steam/Wine 프로세스를 모두 종료한 뒤 다시 실행하고, 반복되면 Runtime의 WebHelper 프로세스 생성 및 창 표면 로그를 확인합니다."
                )]
            )]
        }
        if text.contains("forgeplay detected steam crash dump") ||
            (text.contains("steamwebhelper") && text.contains("access violation")) ||
            (text.contains("crash_steam.exe") && text.contains("0xc0000005")) {
            return [RuleEngineMatch(
                category: .steamIssue,
                confidence: 0.94,
                userMessage: "Windows용 Steam 클라이언트가 ForgePlay Runtime 안에서 시작 직후 크래시했습니다.",
                technicalSummary: "Matched Steam crash dump or Steam WebHelper access violation after launch.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .askUserToUpdateRuntime,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "앱에 포함된 ForgePlay Runtime과 최신 Windows용 Steam CEF/WebHelper 조합이 맞지 않습니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치한 뒤 재확인하세요."
                )]
            )]
        }
        guard ["steam api", "steam_api64", "steamclient", "steam not running", "failed to init steam"].contains(where: text.contains) else {
            return []
        }
        return [RuleEngineMatch(
            category: .steamIssue,
            confidence: 0.76,
            userMessage: "Steam이 먼저 실행되어 로그인되어 있어야 할 수 있습니다.",
            technicalSummary: "Matched Steam API/client initialization failure.",
            riskLevel: .low,
            actions: [RecommendedAction(
                type: .noAction,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: false,
                riskLevel: .low,
                reason: "ForgePlay에서 Steam 실행 버튼을 눌러 로그인 후 게임을 다시 실행하세요."
            )]
        )]
    }

    private func prefixMatches(in text: String) -> [RuleEngineMatch] {
        var matches: [RuleEngineMatch] = []
        if [
            "bad exe format",
            "wrong architecture",
            "win32",
            "could not load kernel32.dll",
            "status c000007b",
            "using a 32-bit prefix in wow64 mode"
        ].contains(where: text.contains) {
            matches.append(RuleEngineMatch(
                category: .prefixCorruption,
                confidence: text.contains("could not load kernel32.dll") ? 0.86 : 0.7,
                userMessage: "Steam 프리픽스의 아키텍처 또는 Windows 구성 파일이 맞지 않습니다.",
                technicalSummary: "Architecture, WoW64, or kernel32.dll load failure detected in the Wine prefix.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .noAction,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .low,
                    reason: "Steam 프리픽스를 새로 만든 뒤 Steam에서 다시 실행해야 합니다."
                )]
            ))
        }
        let concreteRegistryFailure = [
            "regopenkeyex failed",
            "failed to open registry key",
            "unable to open registry key",
            "could not load user.reg",
            "could not load system.reg",
            "wineserver: could not save registry",
            "invalid wine prefix",
            "is not a wine prefix",
            "prefix is not a wineprefix"
        ].contains(where: text.contains)
        if concreteRegistryFailure {
            matches.append(RuleEngineMatch(
                category: .prefixCorruption,
                confidence: 0.55,
                userMessage: "Steam 프리픽스 안의 설정 파일을 확인해야 할 수 있습니다.",
                technicalSummary: "Registry or Wine prefix pattern detected.",
                riskLevel: .medium,
                actions: [RecommendedAction(
                    type: .noAction,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .low,
                    reason: "Steam 프리픽스 검증에서 레지스트리 파일 손상이 확인된 경우에만 새 프리픽스를 만들고 SteamSetup.exe를 다시 설치합니다."
                )]
            ))
        }
        return matches
    }

    private func gameProcessCrashMatches(in text: String) -> [RuleEngineMatch] {
        guard text.contains("wine: unhandled page fault") ||
              text.contains("unhandled page fault on read access") ||
              text.contains("unhandled page fault on write access") else {
            return []
        }

        return [RuleEngineMatch(
            category: .unknown,
            confidence: 0.82,
            userMessage: "게임 프로세스가 ForgePlay Runtime 안에서 크래시했습니다.",
            technicalSummary: "Wine reported an unhandled page fault. This is a process crash after the runner started, not a missing Wine core file or a request to install Windows into the Steam Prefix.",
            riskLevel: .medium,
            actions: [RecommendedAction(
                type: .noAction,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: false,
                riskLevel: .low,
                    reason: "게임 프로세스가 ForgePlay Runtime 안에서 크래시했습니다. Windows용 Steam 실행 상태, Steam 라이브러리 연결, 호환성 정보, 게임 렌더러 payload를 순서대로 확인해야 합니다."
            )]
        )]
    }

    private func wineDiagnosticMatches(in text: String) -> [RuleEngineMatch] {
        let knownDiagnostics: [(needle: String, summary: String)] = [
            ("fixme:hid:handle_irp_mn_query_id", "HID device query stub"),
            ("fixme:thread:get_thread_times", "thread timing API stub"),
            ("fixme:win:ntuseractivatekeyboardlayout", "keyboard layout alias stub"),
            ("fixme:ver:getcurrentpackageid", "Windows package identity API stub"),
            ("fixme:kernelbase:apppolicygetprocessterminationmethod", "Windows app policy API stub"),
            ("fixme:bitmap:ntgdicreatebitmap planes = 0", "bitmap compatibility stub"),
            ("err:kerberos:kerberos_lsaapinitializepackage no kerberos support", "Kerberos package unavailable"),
            ("err:ntlm:ntlm_lsaapinitializepackage no ntlm support", "NTLM package unavailable"),
            ("experimental wow64 mode", "Wine WoW64 compatibility notice")
        ]
        let found = knownDiagnostics
            .filter { text.contains($0.needle) }
            .map(\.summary)

        guard !found.isEmpty else { return [] }

        return [RuleEngineMatch(
            category: .wineDiagnostic,
            confidence: 0.78,
            userMessage: "ForgePlay Runtime이 내부 호환성 로그를 출력했습니다. 설치 창이나 Steam 창이 열려 있다면 이 줄들만으로는 실패가 아닙니다.",
            technicalSummary: "Known ForgePlay Runtime diagnostic lines: \(found.joined(separator: ", ")). These messages are not treated as launch failure unless the process exits unsuccessfully or another concrete error is present.",
            riskLevel: .low,
            actions: [RecommendedAction(
                type: .noAction,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: false,
                riskLevel: .low,
                reason: "창이 정상적으로 열렸다면 그대로 진행하세요. 창이 닫히거나 로그인/설치가 실제로 막히면 그때 저장된 로그와 함께 다시 진단합니다."
            )]
        )]
    }

    private func unsupportedMatches(in text: String) -> [RuleEngineMatch] {
        var matches: [RuleEngineMatch] = []
        if let antiCheatSignal = antiCheatSignal(in: text) {
            matches.append(RuleEngineMatch(
                category: .antiCheat,
                confidence: 0.9,
                userMessage: "안티치트 의존성이 감지되었습니다: %@",
                userMessageFormatArguments: [antiCheatSignal.summary],
                technicalSummary: """
                커널 수준 안티치트는 Windows 호환 런타임에서 지원되지 않는 경우가 많습니다.
                감지된 항목: \(antiCheatSignal.summary)
                """,
                riskLevel: .high,
                actions: [RecommendedAction(
                    type: .markUnsupported,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .high,
                    reason: "커널 수준 안티치트는 Windows 호환 런타임에서 지원되지 않는 경우가 많습니다."
                )]
            ))
        }
        if let kernelSignal = kernelDriverDependencySignal(in: text) {
            matches.append(RuleEngineMatch(
                category: .kernelDependency,
                confidence: 0.86,
                userMessage: "Windows 커널 드라이버 의존성이 감지되었습니다: %@",
                userMessageFormatArguments: [kernelSignal.summary],
                technicalSummary: """
                Windows 커널 드라이버 의존성은 Mac 앱 내부에서 대체할 수 없습니다.
                감지된 항목: \(kernelSignal.summary)
                """,
                riskLevel: .high,
                actions: [RecommendedAction(
                    type: .markUnsupported,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .high,
                    reason: "Windows 커널 드라이버 의존성은 Mac 앱 내부에서 대체할 수 없습니다."
                )]
            ))
        }
        return matches
    }

    private func antiCheatSignal(in text: String) -> UnsupportedDependencySignal? {
        let knownAntiCheats: [(patterns: [String], displayName: String)] = [
            (["easyanticheat", "easy anti-cheat", "easy anti cheat"], "Easy Anti-Cheat"),
            (["battleye", "battl eye"], "BattlEye"),
            (["ricochet anti-cheat", "ricochet anti cheat"], "RICOCHET Anti-Cheat"),
            (["vanguard anti-cheat", "vanguard anti cheat"], "Riot Vanguard"),
            (["kernel anti-cheat", "kernel anti cheat", "kernel anticheat"], "Kernel-level anti-cheat"),
            (["anti-cheat", "anti cheat"], "Anti-cheat")
        ]

        var items = knownAntiCheats.compactMap { candidate -> String? in
            candidate.patterns.contains(where: text.contains) ? candidate.displayName : nil
        }
        if containsStandaloneToken("eac", in: text) {
            items.append("Easy Anti-Cheat (EAC)")
        }

        guard !items.isEmpty else { return nil }
        return UnsupportedDependencySignal(detectedItems: items)
    }

    private func kernelDriverDependencySignal(in text: String) -> UnsupportedDependencySignal? {
        let kernelApiMarkers: [(needle: String, displayName: String)] = [
            ("zwloaddriver", "Windows driver loader (ZwLoadDriver)"),
            ("ntloaddriver", "Windows driver loader (NtLoadDriver)"),
            ("iocreatedevice", "Windows kernel device API (IoCreateDevice)"),
            ("driverentry", "Windows kernel driver entry point (DriverEntry)"),
            ("service_kernel_driver", "Windows kernel-mode service"),
            ("service kernel driver", "Windows kernel-mode service"),
            ("kernel-mode driver", "Windows kernel-mode driver"),
            ("kernel mode driver", "Windows kernel-mode driver"),
            ("windows kernel driver", "Windows kernel driver")
        ]
        var detectedItems: [String] = []

        let driverContextMarkers = [
            "create service",
            "createservice",
            "start service",
            "startservice",
            "servicebinary",
            "service binary",
            "service type",
            "servicetype",
            "kernel",
            "driver",
            "system32\\drivers\\",
            "system32/drivers/",
            "load",
            "loading",
            "install",
            "failed"
        ]

        let driverContextLines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                guard !isWineInternalDriverLine(line) else { return false }
                let hasDriverFile = containsWindowsDriverFilename(in: line)
                let hasKernelApi = kernelApiMarkers.contains { line.contains($0.needle) }
                let hasDriverContext = driverContextMarkers.contains(where: line.contains)
                return (hasDriverFile || hasKernelApi) && hasDriverContext
            }

        for line in driverContextLines {
            detectedItems.append(contentsOf: kernelApiMarkers.compactMap { marker in
                line.contains(marker.needle) ? marker.displayName : nil
            })
            detectedItems.append(contentsOf: windowsDriverFilenames(in: line).map(kernelDriverDisplayName(for:)))
            detectedItems.append(contentsOf: serviceNames(in: line).map { "Service: \($0)" })
        }

        guard !detectedItems.isEmpty else { return nil }
        return UnsupportedDependencySignal(detectedItems: detectedItems)
    }

    private func containsWindowsDriverFilename(in line: String) -> Bool {
        !windowsDriverFilenames(in: line).isEmpty
    }

    private func windowsDriverFilenames(in line: String) -> [String] {
        let pattern = #"(?<![a-z0-9_.-])[a-z0-9_.-]+\.sys(?![a-z0-9_.-])"#
        return regexMatches(pattern, in: line)
            .filter { !containsKnownWineSystemDriver(in: $0) }
    }

    private func kernelDriverDisplayName(for filename: String) -> String {
        let knownDrivers = [
            "bedaisy.sys": "BattlEye driver (BEDaisy.sys)",
            "eac.sys": "Easy Anti-Cheat driver (eac.sys)",
            "easyanticheat.sys": "Easy Anti-Cheat driver (EasyAntiCheat.sys)",
            "vgk.sys": "Riot Vanguard driver (vgk.sys)",
            "xhunter1.sys": "XIGNCODE3 driver (xhunter1.sys)",
            "mhyprot2.sys": "HoYoverse protection driver (mhyprot2.sys)",
            "ace-base.sys": "Tencent ACE driver (ACE-BASE.sys)",
            "faceit.sys": "FACEIT Anti-Cheat driver (faceit.sys)"
        ]
        return knownDrivers[filename] ?? "Driver file: \(filename)"
    }

    private func serviceNames(in line: String) -> [String] {
        let patterns = [
            #"createservicew?\s+failed\s+for\s+([a-z0-9_.-]+)"#,
            #"startservicew?\s+failed\s+for\s+([a-z0-9_.-]+)"#,
            #"services\\([a-z0-9_.-]+)"#,
            #"service\s+name\s*[:=]\s*['"]?([a-z0-9_.-]+)"#,
            #"[\\/]services[\\/]([a-z0-9_.-]+)"#
        ]
        return patterns
            .flatMap { regexMatches($0, in: line, captureIndex: 1) }
            .filter { !isWineInternalDriverName($0) }
    }

    private func containsStandaloneToken(_ token: String, in text: String) -> Bool {
        let escapedToken = NSRegularExpression.escapedPattern(for: token)
        let pattern = #"(?<![a-z0-9_])"# + escapedToken + #"(?![a-z0-9_])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func containsKnownWineSystemDriver(in line: String) -> Bool {
        let wineSystemDrivers = [
            "mountmgr.sys",
            "http.sys",
            "ndis.sys",
            "nsiproxy.sys",
            "hidclass.sys",
            "mouhid.sys",
            "winebth.sys",
            "winebus.sys",
            "winehid.sys",
            "wineusb.sys",
            "winexinput.sys"
        ]
        return wineSystemDrivers.contains(where: line.contains)
    }

    private func isWineInternalDriverLine(_ line: String) -> Bool {
        containsKnownWineSystemDriver(in: line) ||
            ["winebth", "winebus", "winehid", "wineusb", "winexinput", "root\\wine\\", "winedevice"]
            .contains(where: line.contains)
    }

    private func isWineInternalDriverName(_ name: String) -> Bool {
        ["winebth", "winebus", "winehid", "wineusb", "winexinput", "mountmgr"]
            .contains(name)
    }

    private func regexMatches(_ pattern: String, in text: String, captureIndex: Int = 0) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > captureIndex,
                  let matchRange = Range(match.range(at: captureIndex), in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private func recipeMatch(_ recipe: CompatibilityRecipe) -> RuleEngineMatch {
        var seenRuntimes = Set<RuntimeId>()
        var seenLaunchOptions = Set<String>()

        let runtimeActions = recipe.requiredRuntimes.compactMap { runtime -> RecommendedAction? in
            guard seenRuntimes.insert(runtime).inserted else { return nil }
            return RecommendedAction(
                type: .installRuntime,
                runtime: runtime,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: true,
                riskLevel: runtime.riskLevel,
                reason: "호환성 정보에 %@(%@) 설치 필요가 표시되어 있습니다. 공식 설치 파일을 Steam 프리픽스에 적용합니다."
            )
        }
        let launchOptionActions = recipe.launchOptions.compactMap { option -> RecommendedAction? in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seenLaunchOptions.insert(trimmed).inserted else { return nil }
            return RecommendedAction(
                type: .addLaunchOption,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: trimmed,
                requiresUserConfirmation: true,
                riskLevel: .low,
                reason: "호환성 정보에 권장 실행 옵션으로 등록되어 있습니다."
            )
        }
        let actions = LLMRecommendedActionPolicy
            .normalizedActions(runtimeActions + launchOptionActions)
            .filter { $0.type != .noAction }

        let supportStatus = CompatibilitySupportStatus(rawValue: recipe.supportStatus) ?? .unknown
        let graphicsBackendSummary = recipe.preferredGraphicsBackend
            .map { ", preferredGraphicsBackend=\($0.rawValue)" } ?? ""

        return RuleEngineMatch(
            category: supportStatus == .unsupported ? .unsupported : .unknown,
            confidence: recipe.confidence,
            userMessage: "저장된 호환성 정보가 있습니다: %@",
            userMessageFormatArguments: [recipe.beginnerSummary],
            technicalSummary: "Compatibility recipe \(recipe.id), status=\(recipe.supportStatus)\(graphicsBackendSummary), summary=\(recipe.beginnerSummary).",
            riskLevel: supportStatus == .unsupported ? .high : .low,
            actions: actions
        )
    }

    private func merge(_ matches: [RuleEngineMatch]) -> [DiagnosticResult] {
        var byCategory: [DiagnosticCategory: RuleEngineMatch] = [:]
        for match in matches {
            if let existing = byCategory[match.category] {
                var merged = existing
                merged.confidence = max(existing.confidence, match.confidence)
                merged.riskLevel = maxRisk(existing.riskLevel, match.riskLevel)
                merged.technicalSummary += "\n" + match.technicalSummary
                merged.actions.append(contentsOf: match.actions.filter { !existing.actions.contains($0) })
                byCategory[match.category] = merged
            } else {
                byCategory[match.category] = match
            }
        }

        return byCategory.values
            .sorted { $0.confidence > $1.confidence }
            .map {
                DiagnosticResult(
                    category: $0.category,
                    confidence: min(max($0.confidence, 0), 1),
                    userMessage: $0.userMessage,
                    userMessageFormatArguments: $0.userMessageFormatArguments,
                    technicalSummary: $0.technicalSummary,
                    riskLevel: $0.riskLevel,
                    recommendedActions: $0.actions
                )
            }
    }

    private func maxRisk(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        let order: [RiskLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (order[lhs, default: 0] >= order[rhs, default: 0]) ? lhs : rhs
    }
}
