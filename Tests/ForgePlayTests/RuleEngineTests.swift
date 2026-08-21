import SwiftData
import XCTest
@testable import ForgePlay

final class RuleEngineTests: XCTestCase {
    func testDetectsVisualCRuntime() {
        let results = RuleEngine().analyze(logText: "error: msvcp140.dll was not found")

        XCTAssertTrue(results.contains { $0.category == .missingRuntime })
        XCTAssertTrue(results.flatMap(\.recommendedActions).contains { $0.runtime == .vcrun2022 })
    }

    func testRuntimeActionReasonNamesPrefixInstallation() {
        let results = RuleEngine().analyze(logText: "error: msvcp140.dll was not found")
        let action = results.flatMap(\.recommendedActions).first { $0.runtime == .vcrun2022 }

        XCTAssertEqual(action?.type, .installRuntime)
        XCTAssertTrue(action?.reason.contains("공식 설치 파일") == true)
        XCTAssertTrue(action?.reason.contains("Steam 프리픽스") == true)
    }

    func testDetectsAntiCheatAsHighRisk() {
        let results = RuleEngine().analyze(logText: "EasyAntiCheat failed to initialize")
        let antiCheat = results.first { $0.category == .antiCheat }

        XCTAssertEqual(antiCheat?.riskLevel, .high)
        XCTAssertEqual(antiCheat?.recommendedActions.first?.type, .markUnsupported)
    }

    func testAntiCheatDetectorDoesNotMatchSubstringsInsideNormalWords() {
        let results = RuleEngine().analyze(logText: "failed to reach content server")

        XCTAssertFalse(results.contains { $0.category == .antiCheat })
    }

    func testDetectsConcreteKernelDriverDependencyAsUnsupported() {
        let log = """
        CreateServiceW failed for BEDaisy service.
        ServiceBinary=C:\\Windows\\System32\\drivers\\BEDaisy.sys
        ServiceType=SERVICE_KERNEL_DRIVER
        """

        let results = RuleEngine().analyze(logText: log)
        let kernelDependency = results.first { $0.category == .kernelDependency }

        XCTAssertEqual(kernelDependency?.riskLevel, .high)
        XCTAssertEqual(kernelDependency?.recommendedActions.first?.type, .markUnsupported)
        XCTAssertEqual(kernelDependency?.userMessage, "Windows 커널 드라이버 의존성이 감지되었습니다: %@")
        XCTAssertEqual(kernelDependency?.userMessageFormatArguments?.first?.contains("BEDaisy.sys"), true)
        XCTAssertEqual(kernelDependency?.technicalSummary.contains("감지된 항목:"), true)
        XCTAssertFalse(kernelDependency?.recommendedActions.contains { $0.type == .installRuntime } == true)
    }

    @MainActor
    func testUnsupportedDependencyGuidanceExplainsUserNextSteps() {
        let appState = AppState()
        appState.languageMode = .korean
        let results = RuleEngine().analyze(logText: """
        CreateServiceW failed for BEDaisy service.
        ServiceBinary=C:\\Windows\\System32\\drivers\\BEDaisy.sys
        ServiceType=SERVICE_KERNEL_DRIVER
        """)
        let action = results
            .first { $0.category == .kernelDependency }?
            .recommendedActions
            .first

        let steps = action?.localizedRemediationSteps(appState: appState) ?? []

        XCTAssertTrue(steps.contains { $0.contains("감지된 항목 이름") })
        XCTAssertTrue(steps.contains { $0.contains("공식 옵션이 없으면 우회하지 않습니다") })
        XCTAssertTrue(steps.contains { $0.contains("DLL이나 Runtime을 추가 설치해도 해결되지 않습니다") })
        XCTAssertTrue(steps.contains { $0.contains("공식 Mac 버전") && $0.contains("Windows PC") })
    }

    func testKernelDriverDetectorIgnoresWineBuiltinSystemDrivers() {
        let log = """
        setupapi: installing built-in Wine driver mountmgr.sys
        setupapi: installing built-in Wine driver winebus.sys
        0170:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\winebth": c00000e5
        002c:err:setupapi:SetupDiInstallDevice Failed to start service L"winebth" for device L"ROOT\\WINE\\WINEBTH", error 1359.
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)

        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
    }

    func testGameLaunchWineVulkanFailureIsGraphicsIssueNotKernelDependency() {
        let log = """
        00a8:err:vulkan:vulkan_init_once Wine was built without Vulkan support.
        00f4:err:setupapi:SetupDefaultQueueCallbackW copy error 1812 L"@C:\\windows\\system32\\drivers\\wineusb.sys,-1" -> L"C:\\windows\\inf\\wineusb.inf"
        0170:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\winebth": c00000e5
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let graphicsIssue = results.first { $0.category == .graphicsIssue }

        XCTAssertNotNil(graphicsIssue)
        XCTAssertEqual(graphicsIssue?.recommendedActions.first?.type, .askUserToUpdateRuntime)
        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
    }

    func testRendererSelectionMetadataWithoutFailureDoesNotCreateGraphicsIssue() {
        let log = """
        Selected game renderer payload: d3dMetal
        Selected Direct3D generation: d3d12
        Steam WebHelper/CEF/GPU fatal evidence count: 0
        """

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)

        XCTAssertFalse(results.contains { $0.category == .graphicsIssue })
        XCTAssertFalse(results.flatMap(\.recommendedActions).contains {
            $0.type == .importAppleSupplementalRenderer
        })
    }

    func testExplicitD3DMetalRendererFailureStillCreatesGraphicsIssue() {
        let log = """
        0114:err:d3dmetal:D3DMetalCreateDevice failed to create MTLDevice for D3D12 renderer
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let graphicsIssue = results.first { $0.category == .graphicsIssue }

        XCTAssertNotNil(graphicsIssue)
        XCTAssertEqual(graphicsIssue?.recommendedActions.first?.type, .importAppleSupplementalRenderer)
        XCTAssertTrue(graphicsIssue?.technicalSummary.contains("graphics failure patterns") == true)
    }

    func testRepeatedVulkanUnsupportedPageFaultIsGraphicsIssueNotRuntimeDependency() {
        let log = """
        00a4:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\\\Registry\\\\Machine\\\\System\\\\CurrentControlSet\\\\Services\\\\winebth": c00000e5
        003c:fixme:service:scmdatabase_autostart_services Auto-start service L"winebth" failed to start: 1359
        00dc:err:vulkan:vulkan_init_once Wine was built without Vulkan support.
        wine: Unhandled page fault on read access to 0000000000000000 at address 00007FF80FC2119F (thread 0114), starting debugger...
        011c:err:vulkan:vulkan_init_once Wine was built without Vulkan support.
        0124:err:vulkan:vulkan_init_once Wine was built without Vulkan support.
        wine: Unhandled page fault on read access to 0000000000000000 at address 00007FF80FC2119F (thread 0130), starting debugger...
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let graphicsIssue = results.first { $0.category == .graphicsIssue }

        XCTAssertEqual(results.first?.category, .graphicsIssue)
        XCTAssertEqual(graphicsIssue?.userMessage, "앱에 포함된 ForgePlay Runtime에 Vulkan 그래픽 지원이 없어 실행이 막혔습니다.")
        XCTAssertTrue(graphicsIssue?.technicalSummary.contains("without Vulkan support") == true)
        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
        XCTAssertFalse(results.contains { $0.category == .missingRuntime })
    }

    func testSteamCrashDumpOutranksVulkanProbeNoise() {
        let log = """
        00d8:err:vulkan:vulkan_init_once Wine was built without Vulkan support.
        ForgePlay detected Steam crash dump(s) after launch. Windows Steam did not stay alive under the bundled ForgePlay Runtime.
        - /prefix/Steam/dumps/crash_steam.exe_test.dmp (exception=0xC0000005 access violation address=0x7FF80FC2119F)
        """

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)
        let steamIssue = results.first { $0.category == .steamIssue }

        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            steamIssue?.userMessage,
            "Windows용 Steam 클라이언트가 ForgePlay Runtime 안에서 시작 직후 크래시했습니다."
        )
        XCTAssertEqual(steamIssue?.recommendedActions.first?.type, .askUserToUpdateRuntime)
    }

    func testInvalidReuseAfterInitializationFailureIsSteamInitializationIssue() {
        let results = RuleEngine().analyze(
            logText: "invalid reuse after initialization failure",
            context: .setupOrInstaller
        )
        let steamIssue = results.first { $0.category == .steamIssue }

        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            steamIssue?.userMessage,
            "Windows용 Steam 또는 Steam WebHelper가 초기화 실패 뒤 같은 초기화 경로를 다시 사용하려다 중단됐습니다."
        )
        XCTAssertEqual(steamIssue?.recommendedActions.first?.type, .noAction)
    }

    func testSteamCEFBlackWindowSignatureIsSteamIssue() {
        let log = """
        ForgePlay detected Windows Steam CEF/WebHelper rendering warnings after launch and marked this launch unusable.
        Windows Steam CEF login UI was created while WebHelper GPU initialization reported the black-window signature. ForgePlay records this as rendering evidence and treats the visible Steam window as unusable.
        Steam webhelper GPU log tail:
        eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED
        Internal Vulkan error (-9)
        Steam UI HTML log tail:
        CreateBrowser PopupHTMLWindow (-2147483648, -2147483648) 0x0
        Steam login log tail:
        WaitingForCredentials
        """

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)
        let steamIssue = results.first { $0.category == .steamIssue }

        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            steamIssue?.userMessage,
            "Windows용 Steam 창이 열렸지만 검은 화면으로만 렌더링되고 있습니다."
        )
        XCTAssertEqual(steamIssue?.recommendedActions.first?.type, .askUserToUpdateRuntime)
        XCTAssertNil(steamIssue?.recommendedActions.first?.launchOption)
        XCTAssertFalse(
            steamIssue?.recommendedActions.first?.reason.contains("-cef-use-angle") == true
        )
        XCTAssertFalse(
            steamIssue?.technicalSummary.contains("did not hold ANGLE on D3D11") == true
        )
        XCTAssertFalse(results.contains { $0.category == .missingRuntime })
    }

    @MainActor
    func testSteamCEFMitigationEvidenceIsNotTreatedAsRenderingSuccess() {
        let log = """
        The executable-scoped Steam WebHelper process policy reached the Valve-managed WebHelper. This proves only that the bundled Wine CreateProcess policy was applied.
        [2026-07-05 10:13:04] Disabling GPU acceleration: Disabled/CommandLine
        """
        let appState = AppState()
        appState.languageMode = .korean

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)
        let steamIssue = results.first { $0.category == .steamIssue }
        let action = steamIssue?.recommendedActions.first
        let steps = action?.localizedRemediationSteps(appState: appState) ?? []

        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            steamIssue?.userMessage,
            "Steam WebHelper 프로세스 정책은 적용됐지만 화면 렌더링은 별도 확인이 필요합니다."
        )
        XCTAssertEqual(action?.type, .noAction)
        XCTAssertTrue(steamIssue?.technicalSummary.contains("not proof") == true)
        XCTAssertTrue(steps.contains { $0.contains("교차 프로세스 창 표면") })
        XCTAssertTrue(steps.contains { $0.contains("손상이 확인된 경우에만") })
        XCTAssertFalse(steps.contains { $0.contains("인자를 바꿔") })
    }

    func testSteamCEFFatalSharedContextOutranksBrowserReady() {
        let results = RuleEngine().analyze(
            logText: """
            BrowserReady: handle:65536
            ContextResult::kFatalFailure: Failed to create shared context for virtualization
            """,
            context: .setupOrInstaller
        )
        let steamIssue = results.first { $0.category == .steamIssue }

        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            steamIssue?.userMessage,
            "Windows용 Steam UI 그래픽 컨텍스트 초기화가 실패해 표시 가능한 창을 만들지 못했습니다."
        )
        XCTAssertEqual(steamIssue?.recommendedActions.first?.type, .askUserToUpdateRuntime)
        XCTAssertTrue(steamIssue?.technicalSummary.contains("fatal shared") == true)
    }

    func testSteamWebHelperRequiredGPUPolicyIsEvidenceNotFailure() {
        let results = RuleEngine().analyze(
            logText: #"steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu"#,
            context: .setupOrInstaller
        )
        let steamIssue = results.first { $0.category == .steamIssue }

        XCTAssertEqual(results.first?.category, .steamIssue)
        XCTAssertEqual(
            steamIssue?.userMessage,
            "Steam WebHelper 프로세스 정책은 적용됐지만 화면 렌더링은 별도 확인이 필요합니다."
        )
        XCTAssertTrue(steamIssue?.technicalSummary.contains("process policy") == true)
        XCTAssertEqual(steamIssue?.recommendedActions.first?.type, .noAction)
    }

    func testTypedWebHelperArgumentsDoNotProveRootProcessPolicy() {
        let results = RuleEngine().analyze(
            logText:
                #"steamwebhelper.exe --type=renderer --no-sandbox --in-process-gpu --disable-gpu"#,
            context: .setupOrInstaller
        )

        XCTAssertFalse(results.contains {
            $0.technicalSummary.contains("process policy")
        })
    }

    func testWebHelperArgumentsSplitAcrossLinesDoNotProveRootProcessPolicy() {
        let results = RuleEngine().analyze(
            logText: """
            steamwebhelper.exe --no-sandbox
            unrelated.exe --in-process-gpu --disable-gpu
            """,
            context: .setupOrInstaller
        )

        XCTAssertFalse(results.contains {
            $0.technicalSummary.contains("process policy")
        })
    }

    func testSteamInitializationFailureOutranksRootProcessPolicyEvidence() {
        let results = RuleEngine().analyze(
            logText: """
            steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu
            invalid reuse after initialization failure
            """,
            context: .setupOrInstaller
        )

        XCTAssertEqual(
            results.first?.userMessage,
            "Windows용 Steam 또는 Steam WebHelper가 초기화 실패 뒤 같은 초기화 경로를 다시 사용하려다 중단됐습니다."
        )
    }

    func testSteamCrashOutranksRootProcessPolicyEvidence() {
        let results = RuleEngine().analyze(
            logText: """
            steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu
            steamwebhelper access violation
            """,
            context: .setupOrInstaller
        )

        XCTAssertEqual(
            results.first?.userMessage,
            "Windows용 Steam 클라이언트가 ForgePlay Runtime 안에서 시작 직후 크래시했습니다."
        )
    }

    func testSteamWebHelperDisableGPUCompositingIsNotMisclassifiedAsForbiddenGPUOverride() {
        let results = RuleEngine().analyze(
            logText: #"steamwebhelper.exe: disabling GPU acceleration due to --disable-gpu-compositing"#,
            context: .setupOrInstaller
        )
        let steamIssue = results.first { $0.category == .steamIssue }

        XCTAssertEqual(
            steamIssue?.userMessage,
            "Steam WebHelper 프로세스 정책은 적용됐지만 화면 렌더링은 별도 확인이 필요합니다."
        )
        XCTAssertEqual(steamIssue?.recommendedActions.first?.type, .noAction)
        XCTAssertFalse(steamIssue?.technicalSummary.contains("fatal shared") == true)
    }

    func testPlainWinePrefixContextDoesNotImplyPrefixCorruption() {
        let log = "WINEPREFIX=/Volumes/TestVolume/Prefixes/SteamShared registry initialized"

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)

        XCTAssertFalse(results.contains { $0.category == .prefixCorruption })
    }

    func testConcreteRegistryOpenFailureReportsPrefixCorruption() {
        let log = "wineserver: could not save registry branch to user.reg"

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)

        XCTAssertTrue(results.contains { $0.category == .prefixCorruption })
    }

    func testPageFaultBeforeVulkanUnsupportedStillReportsGraphicsIssue() {
        let log = """
        wine: Unhandled page fault on read access to 0000000000000000 at address 00007FF80FC2119F (thread 0130), starting debugger...
        0138:err:vulkan:vulkan_init_once Wine was built without Vulkan support.
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let graphicsIssue = results.first { $0.category == .graphicsIssue }

        XCTAssertEqual(results.first?.category, .graphicsIssue)
        XCTAssertEqual(
            graphicsIssue?.userMessage,
            "앱에 포함된 ForgePlay Runtime에 Vulkan 그래픽 지원이 없어 실행이 막혔습니다."
        )
        XCTAssertTrue(graphicsIssue?.technicalSummary.contains("without Vulkan support") == true)
        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
        XCTAssertFalse(results.contains { $0.category == .missingRuntime })
    }

    func testKernel32LoadFailureIsPrefixIssueNotKernelDependency() {
        let log = """
        Using a 32-bit prefix in Wow64 mode (/Volumes/TestVolume/ForgePlay/Prefixes/SteamShared)
        wine: could not load kernel32.dll, status c000007b
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let prefixIssue = results.first { $0.category == .prefixCorruption }

        XCTAssertNotNil(prefixIssue)
        XCTAssertEqual(prefixIssue?.recommendedActions.first?.type, .noAction)
        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
    }

    func testSetupContextDoesNotReportUnsupportedKernelDependency() {
        let log = """
        0170:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System\\CurrentControlSet\\Services\\BEDaisy": c00000e5
        """

        let results = RuleEngine().analyze(logText: log, context: .setupOrInstaller)

        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
    }

    func testKernelDriverDetectorRequiresSysDriverFilenameAndContext() {
        let results = RuleEngine().analyze(logText: "loading texture.sysmeta from asset bundle")

        XCTAssertFalse(results.contains { $0.category == .kernelDependency })
    }

    func testClassifiesKnownWineDiagnosticsAsLowRisk() {
        let log = """
        0078:fixme:hid:handle_IRP_MN_QUERY_ID Unhandled type 00000005
        0170:fixme:thread:get_thread_times not implemented on this platform
        00dc:fixme:win:NtUserActivateKeyboardLayout Aliased keyboard layout not yet implemented
        0170:fixme:ver:GetCurrentPackageId (000000000010DA90 0000000000000000): stub
        0170:fixme:kernelbase:AppPolicyGetProcessTerminationMethod FFFFFFFFFFFFFFFA, 000000000010FEB0
        00d4:fixme:bitmap:NtGdiCreateBitmap planes = 0
        00d4:err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems
        00d4:err:ntlm:ntlm_LsaApInitializePackage no NTLM support, expect problems
        """

        let results = RuleEngine().analyze(logText: log)
        let wineDiagnostic = results.first { $0.category == .wineDiagnostic }

        XCTAssertEqual(wineDiagnostic?.riskLevel, .low)
        XCTAssertEqual(wineDiagnostic?.recommendedActions.first?.type, .noAction)
        XCTAssertFalse(results.contains { $0.category == .unknown })
    }

    func testUnhandledPageFaultIsClassifiedAsGameProcessCrash() {
        let log = """
        wine: Unhandled page fault on read access to 0000000000000000 at address 00007FF80FC2119F (thread 0174), starting debugger...
        0170:fixme:thread:get_thread_times not implemented on this platform
        0170:fixme:ver:GetCurrentPackageId (000000000010DA90 0000000000000000): stub
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let crash = results.first { $0.category == .unknown }

        XCTAssertEqual(crash?.riskLevel, .medium)
        XCTAssertEqual(crash?.userMessage, "게임 프로세스가 ForgePlay Runtime 안에서 크래시했습니다.")
        XCTAssertEqual(crash?.recommendedActions.first?.type, .noAction)
        XCTAssertEqual(
            crash?.recommendedActions.first?.reason,
            "게임 프로세스가 ForgePlay Runtime 안에서 크래시했습니다. Windows용 Steam 실행 상태, Steam 라이브러리 연결, 호환성 정보, 게임 렌더러 payload를 순서대로 확인해야 합니다."
        )
    }

    func testDisplayMonitorPathFailureBeforePageFaultIsGraphicsIssueNotRuntimeDependency() {
        let log = """
        0198:err:system:find_monitor_from_path Failed to find monitor with path "DISPLAY\\\\APPA061\\\\0000&0000"
        0198:fixme:thread:get_thread_times not implemented on this platform
        wine: Unhandled page fault on read access to 0000000000000000 at address 00007FF80FC2119F (thread 019c), starting debugger...
        0198:fixme:ver:GetCurrentPackageId (000000000010DA90 0000000000000000): stub
        0198:fixme:kernelbase:AppPolicyGetProcessTerminationMethod FFFFFFFFFFFFFFFA, 000000000010FEB0
        """

        let results = RuleEngine().analyze(logText: log, context: .gameLaunch)
        let graphicsIssue = results.first { $0.category == .graphicsIssue }

        XCTAssertEqual(results.first?.category, .graphicsIssue)
        XCTAssertEqual(
            graphicsIssue?.userMessage,
            "게임이 디스플레이/그래픽 초기화 단계에서 크래시한 것으로 보입니다."
        )
        XCTAssertTrue(graphicsIssue?.technicalSummary.contains("display monitor path") == true)
        XCTAssertTrue(graphicsIssue?.confidence ?? 0 > (results.first { $0.category == .unknown }?.confidence ?? 0))
        XCTAssertTrue(graphicsIssue?.recommendedActions.contains { action in
            action.type == .addLaunchOption &&
            action.launchOption == "-windowed" &&
            action.reason == "모니터/전체 화면 초기화 실패가 감지되어 창 모드로 먼저 실행해 봅니다."
        } == true)
        XCTAssertTrue(graphicsIssue?.recommendedActions.contains { action in
            action.type == .noAction &&
            action.reason == "Steam 실행 화면에서 현재 게임의 DirectX 세대에 맞는 단일 백엔드를 직접 선택한 뒤 Steam을 다시 실행합니다."
        } == true)
        XCTAssertFalse(results.contains { $0.category == .missingRuntime })
    }

    func testDiagnosticRecordSourceNormalizesLegacyStorageValues() {
        XCTAssertEqual(DiagnosticRecordSource(storageValue: "Rule Engine"), .ruleEngine)
        XCTAssertEqual(DiagnosticRecordSource(storageValue: "ruleEngine"), .ruleEngine)
        XCTAssertEqual(DiagnosticRecordSource(storageValue: "Apple Foundation Models"), .appleFoundationModels)
        XCTAssertEqual(DiagnosticRecordSource(storageValue: "LLM"), .appleFoundationModels)
        XCTAssertNil(DiagnosticRecordSource(storageValue: "provider-x"))
    }

    func testDetectsBundledRuntimeDylibDependencyFailure() {
        let log = """
        dyld[18373]: Library not loaded: @rpath/libinotify.0.dylib
          Referenced from: /Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wineserver
          Reason: tried: '/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/../../libinotify.0.dylib' (no such file)
        """

        let results = RuleEngine().analyze(logText: log)
        let dependency = results.first { $0.category == .runtimeDependency }

        XCTAssertEqual(dependency?.recommendedActions.first?.type, .askUserToUpdateRuntime)
        XCTAssertFalse(results.contains { $0.category == .unknown })
    }

    func testGuidanceBuilderReturnsFallbackWhenLocalRulesDoNotMatch() {
        let results = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: RuleEngine(),
            logText: "",
            language: .english,
            fallbackReason: "Fallback instruction"
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.category, .unknown)
        XCTAssertEqual(results.first?.recommendedActions.first?.reason, "Fallback instruction")
    }

    func testDiagnosticGuidancePayloadCarriesPersistenceWarning() {
        let diagnostic = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: RuleEngine(),
            logText: "",
            language: .english,
            fallbackReason: "Fallback instruction"
        )

        let payload = DiagnosticGuidancePayload(
            title: "Steam",
            diagnostics: diagnostic,
            logURL: nil,
            persistenceWarning: "Could not save"
        )

        XCTAssertEqual(payload.persistenceWarning, "Could not save")
        XCTAssertEqual(payload.diagnostics.count, 1)
    }

    @MainActor
    func testModelContextSaveDiagnosticRecordsPersistsRecords() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let diagnostics = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: RuleEngine(),
            logText: "",
            language: .english,
            fallbackReason: "Fallback instruction"
        )

        let insertedCount = try context.saveDiagnosticRecords(
            diagnostics,
            gameId: "42",
            launchRecordId: "launch-42"
        )

        let records = try context.fetch(FetchDescriptor<DiagnosticRecord>())
        XCTAssertEqual(insertedCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.gameId, "42")
        XCTAssertEqual(records.first?.launchRecordId, "launch-42")
        XCTAssertEqual(records.first?.source, DiagnosticRecordSource.ruleEngine.rawValue)
    }

    func testGuidanceBuilderLocalizesFallbackDiagnosticPayload() {
        let results = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: RuleEngine(),
            logText: "",
            language: .german,
            fallbackReason: ForgePlayLocalization.localized(
                "실행 준비 단계에서 실패했습니다. 로그를 열어 마지막 오류를 확인하고, ForgePlay Runtime 또는 Steam 프리픽스 상태를 다시 점검하세요.",
                language: .german
            )
        )

        let result = results.first
        XCTAssertEqual(
            result?.userMessage,
            ForgePlayLocalization.localized(
                "실행은 실패했지만 로컬 규칙으로는 원인을 특정하지 못했습니다.",
                language: .german
            )
        )
        XCTAssertEqual(
            result?.technicalSummary,
            ForgePlayLocalization.localized(
                "프로세스가 로컬 Rule Engine 매칭 없이 실패했습니다.",
                language: .german
            )
        )
        XCTAssertNil(result?.userMessage.range(of: "[가-힣]", options: .regularExpression))
        XCTAssertNil(result?.recommendedActions.first?.reason.range(of: "[가-힣]", options: .regularExpression))
    }

    @MainActor
    func testLegacyKernelDriverTechnicalSummaryIsLocalizedForDisplay() {
        let appState = AppState()
        appState.languageMode = .korean
        let diagnostic = DiagnosticResult(
            category: .kernelDependency,
            confidence: 0.86,
            userMessage: "Windows 커널 드라이버가 필요해 지원이 어렵습니다",
            technicalSummary: "Kernel driver dependency marker detected.",
            riskLevel: .high,
            recommendedActions: []
        )

        XCTAssertEqual(
            diagnostic.localizedTechnicalSummary(appState: appState),
            "Windows 커널 드라이버 의존성은 Mac 앱 내부에서 대체할 수 없습니다."
        )
    }

    @MainActor
    func testModelContextSaveDiagnosticRecordsThrowsOnEncodingFailure() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let invalidDiagnostic = DiagnosticResult(
            category: .unknown,
            confidence: .nan,
            userMessage: "Invalid confidence",
            technicalSummary: "JSONEncoder should reject non-conforming floats.",
            riskLevel: .medium,
            recommendedActions: []
        )

        XCTAssertThrowsError(
            try context.saveDiagnosticRecords([invalidDiagnostic], gameId: "42", launchRecordId: "launch-42")
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<DiagnosticRecord>()).count, 0)
    }

    @MainActor
    func testModelContextSaveDiagnosticRecordsRollsBackPartialInsertsOnEncodingFailure() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let validDiagnostic = DiagnosticResult(
            category: .unknown,
            confidence: 0.4,
            userMessage: "First diagnostic",
            technicalSummary: "This record should not remain if the batch fails.",
            riskLevel: .medium,
            recommendedActions: []
        )
        let invalidDiagnostic = DiagnosticResult(
            category: .unknown,
            confidence: .nan,
            userMessage: "Invalid confidence",
            technicalSummary: "JSONEncoder should reject non-conforming floats.",
            riskLevel: .medium,
            recommendedActions: []
        )

        XCTAssertThrowsError(
            try context.saveDiagnosticRecords([validDiagnostic, invalidDiagnostic], gameId: "42", launchRecordId: "launch-42")
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<DiagnosticRecord>()).count, 0)
    }

    func testModelContextDiagnosticRecordPersistenceUsesFailableUTF8Conversion() throws {
        let source = try String(
            contentsOf: try projectRoot().appending(path: "Sources/ForgePlay/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("guard let json = String(data: data, encoding: .utf8) else"))
        XCTAssertTrue(source.contains("throw DiagnosticRecordPersistenceError.utf8ConversionFailed"))
        XCTAssertFalse(source.contains("String(decoding: data, as: UTF8.self)"))
    }

    func testModelContextDiagnosticRecordPersistenceUsesRollbackSavingContract() throws {
        let source = try String(
            contentsOf: try projectRoot().appending(path: "Sources/ForgePlay/App/AppState.swift"),
            encoding: .utf8
        )
        let helperRange = try XCTUnwrap(source.range(of: "func saveDiagnosticRecords("))
        let helperSource = String(source[helperRange.lowerBound...])

        XCTAssertTrue(helperSource.contains("try saveOrRollback()"))
        XCTAssertFalse(helperSource.contains("try save()\n        return insertedCount"))
    }

    func testRecipeContributesRuntimeAction() {
        let recipe = CompatibilityRecipe(
            id: "test",
            steamAppId: "1",
            name: "Test Game",
            supportStatus: "partial",
            beginnerSummary: "Needs runtime",
            technicalSummary: "Runtime",
            confidence: 0.7,
            requiredRuntimes: [.openal],
            launchOptions: ["-windowed"],
            notes: [],
            lastVerifiedAt: nil
        )

        let results = RuleEngine().analyze(logText: "", recipe: recipe)
        let actions = results.flatMap(\.recommendedActions)

        XCTAssertTrue(actions.contains { $0.runtime == .openal })
        XCTAssertTrue(actions.contains { $0.launchOption == "-windowed" })
    }

    @MainActor
    func testRecipeDiagnosticUserMessageUsesLocalizedFormatArguments() {
        let recipe = CompatibilityRecipe(
            id: "test",
            steamAppId: "1",
            name: "Test Game",
            supportStatus: "partial",
            beginnerSummary: "Needs runtime",
            technicalSummary: "Runtime",
            confidence: 0.7,
            requiredRuntimes: [.openal],
            launchOptions: [],
            notes: [],
            lastVerifiedAt: nil
        )
        let appState = AppState()
        appState.languageMode = .english

        let result = RuleEngine().analyze(logText: "", recipe: recipe).first

        XCTAssertEqual(result?.userMessage, "저장된 호환성 정보가 있습니다: %@")
        XCTAssertEqual(result?.userMessageFormatArguments, ["Needs runtime"])
        XCTAssertEqual(
            result?.localizedUserMessage(appState: appState),
            "Saved compatibility information is available: Needs runtime."
        )
        XCTAssertNotEqual(result?.userMessage, "저장된 호환성 정보가 있습니다: Needs runtime")
    }

    func testRecipeActionsUseRecommendedActionPolicy() {
        let recipe = CompatibilityRecipe(
            id: "test",
            steamAppId: "1",
            name: "Test Game",
            supportStatus: "partial",
            beginnerSummary: "Needs launch options",
            technicalSummary: "Launch options",
            confidence: 0.7,
            requiredRuntimes: [.openal, .openal],
            launchOptions: [" -Windowed ", "; rm -rf /", "-windowed", "-force-d3d11"],
            notes: [],
            lastVerifiedAt: nil
        )

        let actions = RuleEngine()
            .analyze(logText: "", recipe: recipe)
            .flatMap(\.recommendedActions)

        XCTAssertEqual(actions.filter { $0.runtime == .openal }.count, 1)
        XCTAssertTrue(actions.contains { $0.launchOption == "-windowed" })
        XCTAssertTrue(actions.contains { $0.launchOption == "-force-d3d11" })
        XCTAssertFalse(actions.contains { $0.launchOption == "; rm -rf /" })
        XCTAssertFalse(actions.contains { $0.type == .noAction })
    }

    func testGameNameAloneDoesNotInjectCompatibilityActionsWithoutRecipe() {
        let game = SteamGame(
            steamAppId: "1245620",
            name: "ELDEN RING",
            installDir: "ELDEN RING",
            libraryPath: "/fixture/SteamLibrary",
            manifestPath: "/fixture/SteamLibrary/steamapps/appmanifest_1245620.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        let actions = RuleEngine()
            .analyze(logText: "", game: game, recipe: nil)
            .flatMap(\.recommendedActions)

        XCTAssertFalse(actions.contains {
            $0.type == .importAppleSupplementalRenderer
        })
    }

    private func projectRoot() throws -> URL {
        var projectRoot = URL(fileURLWithPath: #filePath)
        while projectRoot.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: projectRoot.appending(path: "project.yml").path) {
            projectRoot.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: projectRoot.appending(path: "project.yml").path) else {
            throw XCTSkip("Could not locate project root from #filePath")
        }
        return projectRoot
    }
}

final class LLMRecommendedActionPolicyTests: XCTestCase {
    func testKeepsValidRuntimeActionAndUsesRuntimeRisk() {
        let action = makeAction(
            type: .installRuntime,
            runtime: .dotnet48,
            riskLevel: .high,
            reason: "  Needs .NET  "
        )

        let normalized = LLMRecommendedActionPolicy.normalizedAction(action)

        XCTAssertEqual(normalized.type, .installRuntime)
        XCTAssertEqual(normalized.runtime, .dotnet48)
        XCTAssertEqual(normalized.riskLevel, .medium)
        XCTAssertEqual(normalized.reason, "Needs .NET")
        XCTAssertNil(normalized.launchOption)
    }

    func testBlocksRuntimeActionWithoutRuntime() {
        let action = makeAction(type: .installRuntime, runtime: nil, reason: "Runtime may be missing")

        let normalized = LLMRecommendedActionPolicy.normalizedAction(action)

        XCTAssertEqual(normalized.type, .noAction)
        XCTAssertNil(normalized.runtime)
        XCTAssertFalse(normalized.requiresUserConfirmation)
    }

    func testNormalizesWindowsVersionToSupportedValueOnly() {
        let blankVersion = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .setWindowsVersion,
            windowsVersion: "  ",
            reason: "Use the default Wine version"
        ))
        let unsupportedVersion = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .setWindowsVersion,
            windowsVersion: "win7",
            reason: "Try old Windows"
        ))

        XCTAssertEqual(blankVersion.type, .noAction)
        XCTAssertNil(blankVersion.windowsVersion)
        XCTAssertEqual(unsupportedVersion.type, .noAction)
        XCTAssertNil(unsupportedVersion.windowsVersion)
    }

    func testNormalizesDLLOverrideAndBlocksUnsafeOrIncompleteValues() {
        let missingOverride = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .setDLLOverride,
            dll: "D3DCompiler_47.dll",
            override: nil,
            reason: "Use native DLL"
        ))
        let valid = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .setDLLOverride,
            dll: "D3DCompiler_47.dll",
            override: "native,builtin",
            reason: "Use native DLL"
        ))
        let unsafe = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .setDLLOverride,
            dll: "C:\\Windows\\evil.dll",
            override: "native,builtin",
            reason: "Unsafe DLL"
        ))

        XCTAssertEqual(missingOverride.type, .noAction)
        XCTAssertNil(missingOverride.override)
        XCTAssertEqual(valid.type, .setDLLOverride)
        XCTAssertEqual(valid.dll, "d3dcompiler_47")
        XCTAssertEqual(valid.override, "native,builtin")
        XCTAssertEqual(unsafe.type, .noAction)
        XCTAssertNil(unsafe.dll)
    }

    func testAllowsOnlyKnownLaunchOptions() {
        let valid = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .addLaunchOption,
            launchOption: " -Windowed ",
            reason: "Try windowed mode"
        ))
        let unsafe = LLMRecommendedActionPolicy.normalizedAction(makeAction(
            type: .addLaunchOption,
            launchOption: "; rm -rf /",
            reason: "Unsafe launch option"
        ))

        XCTAssertEqual(valid.type, .addLaunchOption)
        XCTAssertEqual(valid.launchOption, "-windowed")
        XCTAssertEqual(unsafe.type, .noAction)
        XCTAssertNil(unsafe.launchOption)
    }

    func testAcceptedActionsDropBlockedNonNoActionEntries() {
        let unsafe = makeAction(
            type: .addLaunchOption,
            launchOption: "; rm -rf /",
            reason: "Unsafe launch option"
        )
        let explicitNoAction = makeAction(
            type: .noAction,
            requiresUserConfirmation: false,
            riskLevel: .low,
            reason: "Read the logs first"
        )

        let accepted = LLMRecommendedActionPolicy.normalizedAcceptedActions([unsafe, explicitNoAction])

        XCTAssertEqual(accepted.map(\.type), [.noAction])
        XCTAssertEqual(accepted.first?.reason, "Read the logs first")
    }

    func testStoredDiagnosticDecodeNormalizesActionsBeforeDisplay() throws {
        let diagnostic = DiagnosticResult(
            category: .unknown,
            confidence: 1.7,
            userMessage: "  Stored\u{0000} diagnostic  ",
            technicalSummary: String(repeating: "T", count: 2_050),
            riskLevel: .medium,
            recommendedActions: [
                makeAction(
                    type: .addLaunchOption,
                    launchOption: "; rm -rf /",
                    reason: "Unsafe stored action"
                ),
                makeAction(
                    type: .addLaunchOption,
                    launchOption: " -Windowed ",
                    reason: "Safe stored action"
                )
            ]
        )
        let data = try JSONEncoder().encode(diagnostic)
        let record = DiagnosticRecord(
            source: "LLM",
            resultJSON: String(data: data, encoding: .utf8) ?? "{}"
        )

        let decoded = try XCTUnwrap(record.decodedResult)
        let requiredDecoded = try record.requiredDecodedResult()

        XCTAssertEqual(decoded.recommendedActions.count, 1)
        XCTAssertEqual(decoded.recommendedActions.first?.type, .addLaunchOption)
        XCTAssertEqual(decoded.recommendedActions.first?.launchOption, "-windowed")
        XCTAssertEqual(decoded.confidence, 1)
        XCTAssertEqual(decoded.userMessage, "Stored diagnostic")
        XCTAssertEqual(decoded.technicalSummary.count, 2_003)
        XCTAssertEqual(requiredDecoded.recommendedActions.first?.launchOption, "-windowed")
    }

    @MainActor
    func testStoredDiagnosticDecodePreservesUserMessageFormatArguments() throws {
        let diagnostic = DiagnosticResult(
            category: .unknown,
            confidence: 0.7,
            userMessage: "저장된 호환성 정보가 있습니다: %@",
            userMessageFormatArguments: [" Needs\u{0000} runtime "],
            technicalSummary: "Compatibility recipe",
            riskLevel: .low,
            recommendedActions: []
        )
        let data = try JSONEncoder().encode(diagnostic)
        let record = DiagnosticRecord(
            source: "ruleEngine",
            resultJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
        let appState = AppState()
        appState.languageMode = .english

        let decoded = try record.requiredDecodedResult()

        XCTAssertEqual(decoded.userMessage, "저장된 호환성 정보가 있습니다: %@")
        XCTAssertEqual(decoded.userMessageFormatArguments, ["Needs runtime"])
        XCTAssertEqual(
            decoded.localizedUserMessage(appState: appState),
            "Saved compatibility information is available: Needs runtime."
        )
    }

    func testStoredDiagnosticDecodeRejectsOversizedResultJSON() {
        let record = DiagnosticRecord(
            source: "LLM",
            resultJSON: String(repeating: "x", count: DiagnosticRecord.maxResultJSONBytes + 1)
        )

        XCTAssertNil(record.decodedResult)
        XCTAssertThrowsError(try record.requiredDecodedResult()) { error in
            guard let decodeError = error as? DiagnosticRecordDecodeError,
                  case .oversized = decodeError else {
                return XCTFail("Expected oversized, got \(error)")
            }
        }
    }

    func testStoredDiagnosticDecodeSurfacesInvalidJSON() {
        let record = DiagnosticRecord(
            id: "diagnostic-invalid-json",
            source: "LLM",
            resultJSON: "{"
        )

        XCTAssertNil(record.decodedResult)
        XCTAssertThrowsError(try record.requiredDecodedResult()) { error in
            guard let decodeError = error as? DiagnosticRecordDecodeError,
                  case .decodeFailed("diagnostic-invalid-json") = decodeError else {
                return XCTFail("Expected decodeFailed, got \(error)")
            }
        }
    }

    func testClearsIrrelevantParametersFromNonRuntimeActions() {
        let action = makeAction(
            type: .askUserToUpdateRuntime,
            runtime: .vcrun2022,
            windowsVersion: "win10",
            dll: "d3d9",
            override: "native,builtin",
            launchOption: "-windowed",
            riskLevel: .high,
            reason: "Repair the runner"
        )

        let normalized = LLMRecommendedActionPolicy.normalizedAction(action)

        XCTAssertEqual(normalized.type, .askUserToUpdateRuntime)
        XCTAssertNil(normalized.runtime)
        XCTAssertNil(normalized.windowsVersion)
        XCTAssertNil(normalized.dll)
        XCTAssertNil(normalized.override)
        XCTAssertNil(normalized.launchOption)
        XCTAssertEqual(normalized.riskLevel, .low)
    }

    func testDiagnosticResultPolicyNormalizesModelTextConfidenceAndActions() {
        let result = DiagnosticResult(
            category: .unknown,
            confidence: .infinity,
            userMessage: " \u{0008} \n\t ",
            technicalSummary: String(repeating: "A", count: 2_100),
            riskLevel: .medium,
            recommendedActions: [
                makeAction(type: .addLaunchOption, launchOption: "; rm -rf /", reason: "Unsafe"),
                makeAction(type: .addLaunchOption, launchOption: " -Safe ", reason: "Safe mode")
            ]
        )

        let normalized = LLMDiagnosticResultPolicy.normalizedResult(result, language: .english)

        XCTAssertEqual(normalized.confidence, 0.45)
        XCTAssertEqual(
            normalized.userMessage,
            ForgePlayLocalization.localized(
                "AI 문제 진단 결과를 정리했지만 명확한 원인은 확인하지 못했습니다.",
                language: .english
            )
        )
        XCTAssertEqual(normalized.technicalSummary.count, 2_003)
        XCTAssertEqual(normalized.recommendedActions.count, 1)
        XCTAssertEqual(normalized.recommendedActions.first?.launchOption, "-safe")
    }

    private func makeAction(
        type: RecommendedActionType,
        runtime: RuntimeId? = nil,
        windowsVersion: String? = nil,
        dll: String? = nil,
        override: String? = nil,
        launchOption: String? = nil,
        requiresUserConfirmation: Bool = true,
        riskLevel: RiskLevel = .medium,
        reason: String = "AI action"
    ) -> RecommendedAction {
        RecommendedAction(
            type: type,
            runtime: runtime,
            windowsVersion: windowsVersion,
            dll: dll,
            override: override,
            launchOption: launchOption,
            requiresUserConfirmation: requiresUserConfirmation,
            riskLevel: riskLevel,
            reason: reason
        )
    }

}
