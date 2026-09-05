import CoreGraphics
import XCTest
@testable import ForgePlay

final class GameInputProtectionLocalizationTests: XCTestCase {
    private let keys = [
        "입력 및 게임 보호",
        "게임 입력 및 macOS 단축키 보호",
        "일반 Steam과 Steam 호환성 실행에 공통으로 적용됩니다. 각 Steam 세션은 시작 시점 설정의 변경 불가능한 스냅샷을 사용하므로 여기서 바꾼 내용은 다음 실행부터 적용됩니다. 필터는 관리되는 세션의 정상 종료가 확인되면 해제됩니다. 실행 중 필터가 상실되면 입력 보호만 비활성화하고 Wine과 Steam 실행은 유지합니다.",
        "입력 보호는 선택 기능입니다. Steam 실행이나 게임 키 바인딩 자체에는 필요하지 않으며, ForgePlay가 보조키를 변환하고 macOS 단축키를 차단할 때만 손쉬운 사용과 입력 모니터링 권한을 사용합니다.",
        "입력 보호 권한 요청",
        "권한 요청 및 설정 열기",
        "손쉬운 사용 권한", "입력 모니터링 권한", "사전 확인 통과", "허용 필요",
        "손쉬운 사용 설정 열기", "입력 모니터링 설정 열기", "권한 상태 다시 확인",
        "‘사전 확인 통과’는 macOS 권한 API의 응답이며 실제 입력 필터 생성 성공을 보장하지 않습니다. 앱을 새 빌드로 교체한 뒤 필터가 거부되면 두 권한 목록에서 기존 ForgePlay를 제거하고 현재 앱을 다시 추가하세요.",
        "권한 필요 보호 끄기",
        "권한 요청 후 열린 개인정보 보호 및 보안 화면에서 ForgePlay를 켜세요. 목록에 없으면 +를 누르고 Finder에서 보기를 사용해 현재 ForgePlay.app을 선택하세요. 두 권한이 모두 필요한 경우 앱으로 돌아와 권한 버튼을 다시 누르면 남은 설정을 엽니다. macOS가 재실행을 요청하면 ForgePlay를 종료했다가 다시 여세요.",
        "시스템 설정을 자동으로 열지 못했습니다. 개인정보 보호 및 보안에서 손쉬운 사용과 입력 모니터링을 직접 여세요.",
        "권한이 필요한 입력 보호를 껐습니다. Steam은 권한이 필요한 보호 없이 실행할 수 있습니다.",
        "이 빌드에서는 게임 입력 보호를 사용할 수 없습니다.",
        "게임이 전면일 때 macOS 포인터 숨기기 (베타)",
        "실험 단계의 기능으로 동작을 보장하지 않습니다. 관리 중인 Steam 또는 게임이 전면에 있을 때 공개 macOS API를 통해 시스템 포인터 숨김을 요청합니다. 포인터 잠금, 상대 이동, 입력 지연 개선 기능은 제공하지 않습니다. macOS에서는 포인터가 실제로 숨겨졌는지 앱이 확인할 수 없으며, ForgePlay가 백그라운드에 있으면 적용되지 않을 수 있습니다.",
        "게임용 보조키 매핑 사용",
        "관리되는 게임이 전면일 때 macOS 호스트의 물리 Command·Option·Control 이벤트를 Ctrl·Alt 또는 전달 안 함으로 각각 독립 변환하려고 시도합니다. 여러 키를 같은 대상으로 연결할 수 있고 Windows 키는 만들지 않습니다. 실제 Wine·게임 자식의 수신은 별도로 확인하지 않으며 문자 키나 게임 내부 단축키를 바꾸지 않습니다.",
        "물리 Command 키", "물리 Option 키", "물리 Control 키", "Ctrl로 전달", "Alt로 전달", "전달 안 함",
        "게임 중 앱 종료·창 관리 단축키 차단", "Command-Q·W·H·M을 대상으로 합니다.",
        "게임 중 앱 전환·검색 단축키 차단", "Command-Tab·Shift-Command-Tab과 Command-Space를 대상으로 합니다.",
        "게임 중 Mission Control·Spaces 키보드 단축키 차단", "Control-방향키와 macOS가 일반 키 이벤트로 전달하는 F3·F11을 대상으로 합니다. 트랙패드 제스처는 대상이 아닙니다.",
        "게임 중 macOS 기본 스크린샷 단축키 차단",
        "스크린샷 옵션은 Command-Shift-3·4·5·6과 Control 변형만 대상으로 합니다. 다른 캡처 앱·화면 공유·Dock·트랙패드 제스처는 차단하지 않습니다. Option-Command-Escape 강제 종료, Control-Command-Q 화면 잠금, 전원·비상 입력은 항상 허용합니다.",
        "이 빌드에서 지원 안 함", "입력 보호 꺼짐", "입력 보호 사용 준비됨", "포인터 숨김 사용 준비됨",
        "손쉬운 사용 권한 필요", "입력 모니터링 권한 필요", "손쉬운 사용·입력 모니터링 권한 필요",
        "게임 입력 보호 권한이 준비되었습니다.",
        "선택한 보호 기능에는 macOS 손쉬운 사용 권한이 필요합니다. 권한이 없으면 입력 보호만 비활성화하고 Steam 실행은 계속합니다.",
        "선택한 보호 기능에는 macOS 입력 모니터링 권한이 필요합니다. 권한이 없으면 입력 보호만 비활성화하고 Steam 실행은 계속합니다.",
        "선택한 보호 기능에는 macOS 손쉬운 사용 및 입력 모니터링 권한이 필요합니다. 권한이 없으면 입력 보호만 비활성화하고 Steam 실행은 계속합니다.",
        "게임 입력 보호 권한을 확인했습니다.",
        "시스템 설정의 개인정보 보호 및 보안 > 손쉬운 사용에서 ForgePlay를 허용한 뒤 앱으로 돌아오세요.",
        "시스템 설정의 개인정보 보호 및 보안 > 입력 모니터링에서 ForgePlay를 허용한 뒤 앱으로 돌아오세요.",
        "시스템 설정의 개인정보 보호 및 보안 > 손쉬운 사용과 입력 모니터링에서 ForgePlay를 허용한 뒤 앱으로 돌아오세요.",
        "Steam 프리픽스 내부 키보드 입력은 System Default로 유지됩니다. 호스트 보조키 매핑과 macOS 단축키 보호는 설정 > 입력 및 게임 보호에서 관리합니다.",
        "프리픽스 키보드 입력은 읽기 전용이며 System Default로 유지됩니다. 호스트 입력 보호는 설정에서 관리합니다.",
        "게임 입력 보호를 사용하려면 손쉬운 사용 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요.",
        "게임 입력 보호를 사용하려면 입력 모니터링 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요.",
        "게임 입력 보호를 사용하려면 손쉬운 사용 및 입력 모니터링 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요.",
        "macOS에 저장된 권한 등록과 현재 ForgePlay.app이 일치하지 않거나 실제 입력 필터 승인이 갱신되지 않았습니다. 손쉬운 사용과 입력 모니터링에서 기존 ForgePlay 항목을 각각 제거한 뒤, Finder에서 보기로 현재 ForgePlay.app을 다시 추가해 두 권한을 켜고 ForgePlay를 완전히 종료했다가 다시 여세요.",
        "macOS 게임 입력 필터가 활성화된 것으로 확인되지 않았습니다. 손쉬운 사용 및 입력 모니터링 권한을 확인한 뒤 다시 실행해 주세요.",
        "macOS 게임 입력 필터가 시간 초과 후 다시 활성화되지 않아 입력 보호를 비활성화합니다. Wine과 Steam 실행은 유지됩니다.",
        "macOS 게임 입력 필터가 반복해서 시간 초과되어 입력 보호를 비활성화합니다. Wine과 Steam 실행은 유지됩니다.",
        "macOS가 게임 입력 필터를 비활성화하여 입력 보호를 종료합니다. Wine과 Steam 실행은 유지됩니다.",
        "macOS 포인터를 다시 표시하지 못해 입력 보호를 비활성화하고 포인터 복원을 다시 시도합니다. Wine과 Steam 실행은 유지됩니다.",
        "변환된 보조키를 해제하지 못해 입력 보호를 비활성화하고 입력 상태 복원을 다시 시도합니다. Wine과 Steam 실행은 유지됩니다. (프로세스 %lld)",
        "macOS가 이번 포인터 숨김 요청을 수락하지 않았습니다. Steam 실행은 계속되며 다음에 관리되는 게임이 전면으로 전환되면 다시 시도할 수 있습니다 (베타).",
        "게임 입력 보호가 %@ 이유로 중단되어 입력 보호만 비활성화했습니다. Wine과 Steam 실행은 유지되며, 진단 기록을 확인하세요.",
        "관리되는 게임 프로세스(%lld)의 입력 보호 대상을 확인할 수 없습니다. Steam을 종료한 뒤 다시 시도하세요.",
        "관리되는 게임 프로세스(%lld)의 입력 보호 연결이 확인 중 변경되었습니다. Steam을 종료한 뒤 다시 시도하세요."
    ]

    func testGameInputProtectionKeysExistInEverySupportedLocale() {
        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(localized.isEmpty, "Missing game-input localization for \(language): \(key)")
                if language != .korean {
                    XCTAssertNotEqual(localized, key, "Untranslated game-input localization for \(language): \(key)")
                }
            }
        }
    }

    func testGameInputProtectionFormatPlaceholdersHaveParity() {
        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertEqual(
                    placeholderCount(in: localized),
                    placeholderCount(in: key),
                    "Placeholder mismatch for \(language): \(key)"
                )
            }
        }
    }

    func testManagedProcessErrorsFormatInEverySupportedLocale() {
        let errorKeys = [
            "변환된 보조키를 해제하지 못해 입력 보호를 비활성화하고 입력 상태 복원을 다시 시도합니다. Wine과 Steam 실행은 유지됩니다. (프로세스 %lld)",
            "관리되는 게임 프로세스(%lld)의 입력 보호 대상을 확인할 수 없습니다. Steam을 종료한 뒤 다시 시도하세요.",
            "관리되는 게임 프로세스(%lld)의 입력 보호 연결이 확인 중 변경되었습니다. Steam을 종료한 뒤 다시 시도하세요."
        ]
        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in errorKeys {
                let localized = ForgePlayLocalization.localizedFormat(
                    key,
                    language: language,
                    arguments: [Int64(42)]
                )
                XCTAssertTrue(localized.contains("42"), "Process identifier was not formatted for \(language)")
            }
        }
    }

    @MainActor
    func testModifierReleaseFailureHasExactLocalizedAndTechnicalIdentity() {
        let key = "변환된 보조키를 해제하지 못해 입력 보호를 비활성화하고 입력 상태 복원을 다시 시도합니다. Wine과 Steam 실행은 유지됩니다. (프로세스 %lld)"
        let failure = GameInputProtectionTerminalFailure
            .modifierReleaseEmissionFailed(42)
        let bridgedError = failure as NSError
        let appState = AppState()

        for language in ForgePlayLanguageMode.allCases where language != .system {
            appState.languageMode = language
            let message = appState.localizedError(failure)
            let expected = ForgePlayLocalization.localizedFormat(
                key,
                language: language,
                arguments: [Int64(42)]
            )

            XCTAssertFalse(message.isEmpty, "Empty modifier-release message for \(language)")
            XCTAssertEqual(message, expected, "Wrong modifier-release message for \(language)")
            XCTAssertTrue(message.contains("42"), message)
            XCTAssertFalse(message.contains(bridgedError.domain), message)
            XCTAssertFalse(message.contains("Error Domain"), message)
        }

        XCTAssertEqual(
            forgePlayTechnicalErrorSummary(failure),
            "game-input-protection terminal=modifier-release-emission-failed pid=42"
        )
    }

    @MainActor
    func testTerminalErrorsUseLocalizedMessagesInsteadOfRawNSErrorIdentity() {
        let appState = AppState()
        for failure in [
            GameInputProtectionTerminalFailure.timeoutReenableReadbackFailed,
            .repeatedTapTimeout,
            .disabledByUserInput,
            .pointerVisibilityRestoreFailed(CGError.cannotComplete.rawValue),
            .modifierReleaseEmissionFailed(4242)
        ] {
            let message = appState.localizedError(failure)
            XCTAssertFalse(message.contains("ForgePlay."))
            XCTAssertFalse(message.contains("Error Domain"))
            XCTAssertTrue(
                forgePlayTechnicalErrorSummary(failure)
                    .hasPrefix("game-input-protection terminal=")
            )
        }
        let cleanupError = GameInputProtectionTerminalCleanupError(
            terminalFailure: .repeatedTapTimeout,
            cleanupCompleted: true,
            callerCancellationObserved: true,
            maskedCommitFailureTechnicalDescription: "commit-restore-failed"
        )
        XCTAssertEqual(
            appState.localizedError(cleanupError),
            appState.localizedError(
                GameInputProtectionTerminalFailure.repeatedTapTimeout
            )
        )
        XCTAssertTrue(
            forgePlayTechnicalErrorSummary(cleanupError)
                .contains("callerCancellationObserved=true")
        )
        XCTAssertTrue(
            forgePlayTechnicalErrorSummary(cleanupError)
                .contains("maskedCommitFailure=commit-restore-failed")
        )
        let postDispatchError = GameInputProtectionPostDispatchCleanupError(
            originalFailureDescription: "localized original failure",
            originalFailureTechnicalDescription: "original-technical",
            cleanupCompleted: true,
            callerCancellationObserved: true
        )
        XCTAssertEqual(
            appState.localizedError(postDispatchError),
            "localized original failure"
        )
        XCTAssertTrue(
            forgePlayTechnicalErrorSummary(postDispatchError)
                .contains("post-dispatch-original=original-technical")
        )
    }

    @MainActor
    func testTerminalLifecycleBridgeCreatesEvidenceAndReusesItsURLOnCompletion()
        throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayGameInputBridge-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let evidenceService = FailureDiagnosticEvidenceService(
            pathManager: pathManager,
            redactor: Redactor()
        )
        let appState = AppState()
        appState.configureFailureDiagnostics(
            service: evidenceService,
            pathManager: pathManager
        )
        let session = GameInputProtectionSessionIdentity()
        let failure = GameInputProtectionTerminalFailure.repeatedTapTimeout

        appState.handleGameInputProtectionLifecycleEvent(
            .protectionLost(session: session, failure: failure)
        )
        let evidenceURL = try XCTUnwrap(appState.currentNotice?.logURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceURL.path))
        XCTAssertEqual(appState.currentNotice?.kind.rawValue, "failure")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(
            FailureDiagnosticEvidenceDocument.self,
            from: Data(contentsOf: evidenceURL)
        )
        XCTAssertEqual(
            evidence.operationIdentifier,
            "steam.game-input-protection"
        )
        XCTAssertEqual(
            evidence.surfaceIdentifier,
            "steam.game-input-protection.terminal-protection-loss"
        )

        appState.handleGameInputProtectionLifecycleEvent(
            .containmentCompleted(session: session, failure: failure)
        )
        XCTAssertEqual(appState.currentNotice?.kind.rawValue, "warning")
        XCTAssertEqual(appState.currentNotice?.logURL, evidenceURL)
        XCTAssertTrue(
            appState.currentNotice?.message.contains(
                appState.localizedError(failure)
            ) == true
        )
    }

    @MainActor
    func testContainmentCompletionDoesNotOverwriteNewerUnrelatedNotice() {
        let appState = AppState()
        let session = GameInputProtectionSessionIdentity()
        let failure = GameInputProtectionTerminalFailure.repeatedTapTimeout

        appState.handleGameInputProtectionLifecycleEvent(
            .protectionLost(session: session, failure: failure)
        )
        let unrelated = appState.setNotice(
            "newer-unrelated-notice",
            kind: .failure,
            captureFailureEvidence: false
        )

        appState.handleGameInputProtectionLifecycleEvent(
            .containmentCompleted(session: session, failure: failure)
        )
        XCTAssertEqual(appState.currentNotice?.id, unrelated.id)
        XCTAssertEqual(appState.currentNotice?.message, "newer-unrelated-notice")

        appState.clearNotice(id: unrelated.id)
        appState.handleGameInputProtectionLifecycleEvent(
            .containmentCompleted(session: session, failure: failure)
        )
        XCTAssertNil(appState.currentNotice)
    }

    @MainActor
    func testPointerHideFailureProducesBoundedLocalizedBetaWarning() {
        let appState = AppState()
        appState.handleGameInputPointerHideFailure(
            GameInputProtectionPointerHideFailureEvent(
                session: GameInputProtectionSessionIdentity(),
                resultCode: CGError.cannotComplete.rawValue
            )
        )

        XCTAssertEqual(appState.currentNotice?.kind.rawValue, "warning")
        XCTAssertNil(appState.currentNotice?.logURL)
        XCTAssertEqual(
            appState.currentNotice?.message,
            appState.localized(
                "macOS가 이번 포인터 숨김 요청을 수락하지 않았습니다. Steam 실행은 계속되며 다음에 관리되는 게임이 전면으로 전환되면 다시 시도할 수 있습니다 (베타)."
            )
        )
    }

    private func placeholderCount(in value: String) -> Int {
        ["%lld", "%@"].reduce(0) {
            $0 + value.components(separatedBy: $1).count - 1
        }
    }
}
