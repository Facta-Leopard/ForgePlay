import SwiftUI

enum ForgePlaySceneID {
    static let main = "forgeplay-main"
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case setup
    case steamLaunch
    case diagnostics
    case hallOfSupporters
    case developerApps
    case settings
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "대시보드"
        case .setup: "처음 설정"
        case .steamLaunch: "Steam 실행"
        case .diagnostics: "문제 진단"
        case .hallOfSupporters: "후원자 명예의 전당"
        case .developerApps: "제작자의 다른 앱"
        case .settings: "설정"
        case .advanced: "고급 정보"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .setup: "checklist"
        case .steamLaunch: "play.circle.fill"
        case .diagnostics: "waveform.path.ecg.rectangle"
        case .hallOfSupporters: "building.columns.fill"
        case .developerApps: "square.grid.3x3.square"
        case .settings: "gearshape"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }
}

enum SetupStage: Int, CaseIterable, Identifiable {
    case chooseRoot
    case checkMac
    case prepareEngine
    case prepareSteamEnvironment
    case installSteam
    case configureRenderer
    case authenticateSteam
    case connectLibrary
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .chooseRoot: "앱 데이터 준비"
        case .checkMac: "Mac 상태 확인"
        case .prepareEngine: "ForgePlay Runtime"
        case .prepareSteamEnvironment: "Steam 프리픽스"
        case .installSteam: "Steam 설치"
        case .configureRenderer: "Steam 실행 경로 정비"
        case .authenticateSteam: "Steam 로그인 및 라이브러리"
        case .connectLibrary: "라이브러리 연결"
        case .ready: "Steam 실행"
        }
    }

    var beginnerDescription: String {
        switch self {
        case .chooseRoot:
            "ForgePlay가 Steam 프리픽스, 캐시, 로그를 기본 내부 앱 데이터 위치에 자동으로 준비합니다. 이후 설정에서 앱 데이터 위치를 변경할 수 있으며, Steam 게임 라이브러리는 별도로 연결합니다."
        case .checkMac:
            "ForgePlay가 이 Mac에서 Windows용 Steam을 실행할 준비가 되었는지 확인합니다."
        case .prepareEngine:
            "앱에 포함된 ForgePlay Runtime의 실행 파일과 렌더러 구성을 확인합니다."
        case .prepareSteamEnvironment:
            "Windows용 Steam을 설치할 안전한 공간을 만듭니다."
        case .installSteam:
            "사용자가 직접 받은 Steam 설치 파일을 Steam 프리픽스 안에서 실행합니다."
        case .configureRenderer:
            "Steam 클라이언트 호환 프로필을 적용하고 남은 D3DMetal/DXVK overlay를 복구합니다."
        case .authenticateSteam:
            "Windows용 Steam에서 직접 로그인하고 인증 후 라이브러리 화면이 열리는지 확인합니다."
        case .connectLibrary:
            "선택 사항으로 Steam 라이브러리 참고 목록을 찾거나 외장 라이브러리를 Windows 드라이브로 연결합니다."
        case .ready:
            "Windows용 Steam을 실행할 준비가 되었습니다."
        }
    }

    var symbolName: String {
        switch self {
        case .chooseRoot: "internaldrive"
        case .checkMac: "desktopcomputer"
        case .prepareEngine: "gearshape.2"
        case .prepareSteamEnvironment: "externaldrive"
        case .installSteam: "square.and.arrow.down"
        case .configureRenderer: "display"
        case .authenticateSteam: "person.crop.circle.badge.checkmark"
        case .connectLibrary: "externaldrive.badge.plus"
        case .ready: "checkmark.seal"
        }
    }
}

enum SheetDestination: Identifiable {
    case chooseRoot
    case importAppleSupplementalRenderer
    case chooseSteamInstaller
    case chooseRuntimeInstallerCatalog
    case chooseRuntimeInstaller(RuntimeId)
    case diagnosticGuide(DiagnosticGuidancePayload)
    case supportBundle(URL)
    case usageGuide
    case sectionHelp(AppSection)

    var id: String {
        switch self {
        case .chooseRoot: "chooseRoot"
        case .importAppleSupplementalRenderer: "importAppleSupplementalRenderer"
        case .chooseSteamInstaller: "chooseSteamInstaller"
        case .chooseRuntimeInstallerCatalog: "chooseRuntimeInstallerCatalog"
        case .chooseRuntimeInstaller(let runtime): "chooseRuntimeInstaller-\(runtime.rawValue)"
        case .diagnosticGuide(let payload): "diagnosticGuide-\(payload.id)"
        case .supportBundle(let url): "supportBundle-\(url.path)"
        case .usageGuide: "usageGuide"
        case .sectionHelp(let section): "sectionHelp-\(section.rawValue)"
        }
    }
}

struct DiagnosticGuidancePayload: Identifiable, Hashable {
    let id: String
    var title: String
    var diagnostics: [DiagnosticResult]
    var logURL: URL?
    var persistenceWarning: String?

    init(title: String, diagnostics: [DiagnosticResult], logURL: URL?, persistenceWarning: String? = nil) {
        id = "diagnostic-guide-\(UUID().uuidString)"
        self.title = title
        self.diagnostics = Self.visibleDiagnostics(from: diagnostics)
        self.logURL = logURL
        self.persistenceWarning = persistenceWarning
    }

    var primaryDiagnostic: DiagnosticResult? {
        diagnostics.first
    }

    private static func visibleDiagnostics(from diagnostics: [DiagnosticResult]) -> [DiagnosticResult] {
        let actionable = diagnostics.filter { diagnostic in
            diagnostic.category != .wineDiagnostic ||
                diagnostic.recommendedActions.contains { $0.type != .noAction }
        }
        return actionable.isEmpty ? diagnostics : actionable
    }
}
