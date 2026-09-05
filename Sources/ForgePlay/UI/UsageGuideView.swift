import SwiftUI

struct UsageGuideView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var steps: [UsageGuideStep] {
        [
            UsageGuideStep(
                id: 1,
                title: "앱 시작 화면",
                systemImage: "rectangle.and.hand.point.up.left",
                body: "저장된 구성이 Windows용 Steam을 실행할 수 있으면 앱을 열 때 Steam 실행 화면으로 이동합니다. 준비가 막혀 있으면 설정 화면이 열리며, 로그나 알림이 있다는 이유만으로 대시보드가 자동으로 열리지는 않습니다."
            ),
            UsageGuideStep(
                id: 2,
                title: "설정",
                systemImage: "checklist",
                body: "설정에서는 앱 데이터, ForgePlay Runtime, Steam 프리픽스, Steam 설치를 순서대로 준비합니다. 노란색 현재 단계를 따라가고, 외장 라이브러리는 필요할 때 별도로 연결하세요."
            ),
            UsageGuideStep(
                id: 3,
                title: "Steam 실행",
                systemImage: "play.circle.fill",
                body: "Steam 실행은 모든 게임에 공통으로 사용하는 표준 경로입니다. 그래픽 백엔드와 호환성 설정을 선택하고, 다음 실행에도 재사용하려면 저장하세요. Windows용 Steam이 열리면 라이브러리에서 게임을 실행합니다."
            ),
            UsageGuideStep(
                id: 4,
                title: "Steam 호환성 실행 (베타)",
                systemImage: "gamecontroller.fill",
                body: "Steam 호환성 실행 (베타)은 선택한 게임 프로필만을 위한 별도 실행 경로입니다. 일반 Steam 실행 화면의 공통 설정과 독립적으로 저장되며 그 설정을 덮어쓰지 않습니다."
            ),
            UsageGuideStep(
                id: 5,
                title: "D3DMetal - NVIDIA",
                systemImage: "sparkles.tv",
                body: "D3DMetal - NVIDIA는 지원되는 NVIDIA DLSS/NGX 요청을 Apple MetalFX 업스케일링으로 연결합니다.",
                linkTitle: "Apple WWDC25에서 MetalFX 업스케일링 보기",
                linkURL: URL(string: "https://developer.apple.com/videos/play/wwdc2025/211/?time=133")
            ),
            UsageGuideStep(
                id: 6,
                title: "외장 Steam 라이브러리",
                systemImage: "externaldrive.badge.plus",
                body: "빈 외장 드라이브/폴더는 Steam이 새 라이브러리를 만들 수 있는 Windows 드라이브로 연결하고, 기존 SteamLibrary는 자동 인식합니다. 파일은 복사하지 않습니다."
            ),
            UsageGuideStep(
                id: 7,
                title: "문제 진단 (베타)",
                systemImage: "stethoscope",
                body: "문제 진단은 실행 실패 로그를 읽고, 로컬 규칙 분석과 선택형 로컬 AI 분석으로 원인과 다음 조치를 정리하는 화면입니다."
            ),
            UsageGuideStep(
                id: 8,
                title: "업데이트 확인 (베타)",
                systemImage: "checkmark.arrow.trianglehead.counterclockwise",
                body: "사이드바의 업데이트 확인 (베타) 버튼은 ForgePlay 홈페이지의 공개 릴리스 정보를 확인합니다. 업데이트가 있으면 버튼을 다시 눌러 공식 릴리스 페이지를 엽니다."
            ),
            UsageGuideStep(
                id: 9,
                title: "EXE 실행 (베타)",
                systemImage: "terminal.fill",
                body: "EXE 실행은 Windows 보조 도구, 고전 게임 또는 독립 실행형 Windows 프로그램을 SteamShared 프리픽스에서 실행하는 별도 경로입니다."
            )
        ]
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 18) {
            headerText(palette: palette)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        UsageGuideStepRow(step: step)
                    }
                }
            }

            ResponsiveActionRow {
                ThemedActionButton(title: "설정 열기", systemImage: "wand.and.sparkles", prominence: .primary) {
                    appState.selectedSection = .setup
                    dismiss()
                }

                ThemedActionButton(title: "Steam 실행 화면 열기", systemImage: "play.circle", prominence: .secondary) {
                    appState.selectedSection = .steamLaunch
                    dismiss()
                }
            }
            .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 720, maxWidth: 720, minHeight: 560, idealHeight: 640, maxHeight: 720)
        .background(palette.background)
    }

    private func headerText(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.localized("사용법"))
                .font(.title2.weight(.bold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localized("아래 순서는 현재 구현된 실행 경로와 기능을 기준으로 합니다."))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct UsageGuideStep: Identifiable {
    let id: Int
    var title: String
    var systemImage: String
    var body: String
    var linkTitle: String? = nil
    var linkURL: URL? = nil
}

private struct UsageGuideStepRow: View {
    var step: UsageGuideStep
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        HStack(alignment: .top, spacing: 12) {
            Text("\(step.id)")
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.onPrimary)
                .frame(width: 28, height: 28)
                .background(palette.primary)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ForgePlayLayout.controlCornerRadius,
                        style: .continuous
                    )
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: step.systemImage)
                        .foregroundStyle(palette.primary)
                    Text(appState.localized(step.title))
                        .font(.headline)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(appState.localized(step.body))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let linkTitle = step.linkTitle,
                   let linkURL = step.linkURL {
                    Link(destination: linkURL) {
                        Label(
                            appState.localized(linkTitle),
                            systemImage: "arrow.up.right.square"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(palette.primary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

struct SectionHelpButton: View {
    var section: AppSection
    var controlSize: ControlSize = .small
    var action: (() -> Void)? = nil
    @Environment(AppState.self) private var appState

    var body: some View {
        ThemedActionButton(
            title: "사용법",
            systemImage: "questionmark.circle",
            prominence: .secondary,
            controlSize: controlSize
        ) {
            if let action {
                action()
            } else {
                appState.presentedSheet = .sectionHelp(section)
            }
        }
        .frame(minWidth: controlSize == .small ? 96 : 120, idealWidth: 118, maxWidth: 160)
        .help("\(appState.localized(section.title)) \(appState.localized("사용법"))")
    }
}

struct ContextualHelpView: View {
    let section: AppSection
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var guide: SectionHelpGuide {
        SectionHelpGuide.guide(for: section)
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 18) {
            headerText(palette: palette)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(guide.groups) { group in
                        ContextualHelpGroupRow(group: group)
                    }
                }
                .padding(.trailing, 6)
            }

            ResponsiveActionRow {
                ThemedActionButton(
                    title: "전체 사용법 보기",
                    systemImage: "list.number",
                    prominence: .secondary
                ) {
                    if let sheetPresenter {
                        sheetPresenter(.usageGuide)
                    } else {
                        appState.presentedSheet = .usageGuide
                    }
                }

                ThemedActionButton(
                    title: guide.primaryNavigationTitle.text(appState: appState),
                    systemImage: guide.primaryNavigationSystemImage,
                    prominence: .primary
                ) {
                    appState.selectedSection = guide.primaryNavigationSection
                    dismiss()
                }
            }
            .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 780, maxWidth: 820, minHeight: 620, idealHeight: 740, maxHeight: 820)
        .background(palette.background)
    }

    private func headerText(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(appState.localized(section.title)) \(appState.localized("사용법"))")
                .font(.title2.weight(.bold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(guide.summary.text(appState: appState))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct ContextualHelpGroupRow: View {
    var group: SectionHelpGuide.Group
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: group.systemImage)
                .font(.title3)
                .foregroundStyle(palette.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(group.title.text(appState: appState))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 20, alignment: .trailing)
                            Text(item.text(appState: appState))
                                .font(.callout)
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SectionHelpGuide {
    struct Group: Identifiable {
        var id: String
        var title: HelpText
        var systemImage: String
        var items: [HelpText]
    }

    var summary: HelpText
    var groups: [Group]
    var primaryNavigationSection: AppSection
    var primaryNavigationTitle: HelpText
    var primaryNavigationSystemImage: String

    static func guide(for section: AppSection) -> SectionHelpGuide {
        switch section {
        case .dashboard:
            dashboard
        case .setup:
            setup
        case .steamLaunch:
            steamLaunch
        case .steamCompatibilityLaunch:
            steamCompatibilityLaunch
        case .compatibilityCatalog:
            compatibilityCatalog
        case .windowsUtility:
            windowsUtility
        case .diagnostics:
            diagnostics
        case .learnAboutForgePlay:
            learnAboutForgePlay
        case .hallOfSupporters:
            hallOfSupporters
        case .developerApps:
            developerApps
        case .settings:
            settings
        case .advanced:
            advanced
        }
    }

    private static let dashboard = SectionHelpGuide(
        summary: HelpText(
            ko: "대시보드는 ForgePlay의 현재 준비 상태를 한눈에 보는 화면입니다. Windows용 Steam을 열 수 있는지, 무엇이 막혀 있는지, 최근 진단이 있는지를 여기서 확인합니다.",
            en: "The dashboard is the status overview for ForgePlay. Use it to see whether Windows Steam can be opened, what is blocking setup, and whether recent diagnostics need attention."
        ),
        groups: [
            Group(
                id: "dashboard-role",
                title: HelpText(ko: "이 화면에서 확인할 것", en: "What to check here"),
                systemImage: "gauge.with.dots.needle.67percent",
                items: [
                    HelpText(ko: "저장된 구성이 Windows용 Steam을 실행할 수 있으면 앱을 열 때 Steam 실행 화면으로 이동합니다. 준비가 막혀 있으면 설정 화면이 열리며, 로그나 알림이 있다는 이유만으로 대시보드가 자동으로 열리지는 않습니다.", en: "When the saved configuration can launch Windows Steam, ForgePlay opens Steam Launch at startup. If preparation is blocked, it opens Setup instead. Logs or notices alone do not automatically open the Dashboard."),
                    HelpText(ko: "Steam 실행 카드는 Windows용 Steam을 열 수 있는지 보여줍니다. 개별 게임을 직접 실행하지 않고 Steam 클라이언트만 실행합니다.", en: "The Steam launch card shows whether Windows Steam can be opened. ForgePlay launches the Steam client, not a game executable directly."),
                    HelpText(ko: "실행 구성 카드는 ForgePlay Runtime, Steam 프리픽스, Windows용 Steam 설치 여부를 요약합니다. 경고가 있으면 해당 설정이 아직 끝나지 않은 것입니다.", en: "The run configuration card summarizes ForgePlay Runtime, Steam Prefix, and Windows Steam installation. A warning means that part is not ready yet."),
                    HelpText(ko: "최근 문제 분석 기록은 마지막 실패 로그와 진단 결과를 빠르게 보여줍니다. Steam 실행 또는 Steam 안에서 시작한 게임이 실패했다면 이 카드에서 문제 진단 화면으로 이동하세요.", en: "Recent diagnostics shows the latest failed launch logs and analysis. If Steam or a Steam-launched game failed, jump to Diagnostics from this card.")
                ]
            ),
            Group(
                id: "dashboard-actions",
                title: HelpText(ko: "주요 버튼 사용법", en: "Main buttons"),
                systemImage: "cursorarrow.click.2",
                items: [
                    HelpText(ko: "상태 새로고침은 현재 저장 위치, ForgePlay Runtime, Steam 프리픽스를 다시 검사합니다. 외부 폴더를 옮겼거나 설정을 바꾼 직후 눌러 확인하세요.", en: "Refresh Status rechecks storage, ForgePlay Runtime, and Steam Prefix state. Use it after moving folders or changing setup."),
                    HelpText(ko: "Steam/라이브러리 관리는 Steam 실행, 게임 렌더러 payload, 외장 저장공간 연결, 참고 목록 관리를 한 화면에서 처리합니다.", en: "Steam/Library Management keeps Steam launch, game renderer payload selection, external storage connections, and reference list maintenance in one screen."),
                    HelpText(ko: "Steam 실행은 Windows용 Steam이 준비된 뒤 Steam 클라이언트를 실행합니다. Steam 설치나 로그인은 Steam 창 안에서 직접 진행합니다.", en: "Launch Steam starts the Windows Steam client after it is installed. Installation and sign-in happen inside the Steam window.")
                ]
            ),
            Group(
                id: "dashboard-order",
                title: HelpText(ko: "막혔을 때 진행 순서", en: "If something is blocked"),
                systemImage: "list.bullet.rectangle",
                items: [
                    HelpText(ko: "저장 위치가 없으면 설정에서 새 ForgePlay 라이브러리 폴더를 선택합니다.", en: "If no storage location is set, open Setup and choose a new ForgePlay library folder."),
                    HelpText(ko: "앱에 포함된 ForgePlay Runtime을 사용할 수 없습니다. Runtime이 온전히 포함된 ForgePlay 빌드를 다시 설치하세요.", en: "The bundled ForgePlay Runtime is unavailable. Reinstall a ForgePlay build that contains the complete Runtime."),
                    HelpText(ko: "게임 참고 목록이 없어도 Steam 실행은 가능합니다. 외장 저장공간이 필요하면 Steam 실행 화면에서 드라이브나 폴더를 먼저 연결하세요. 빈 위치는 Steam이 새 라이브러리를 만들 수 있고, 기존 라이브러리는 자동 인식됩니다.", en: "Steam can be launched without reference games. To use external storage, first connect its drive or folder in Steam Launch. Steam can create a library in an empty location, while an existing library is recognized automatically.")
                ]
            )
        ],
        primaryNavigationSection: .setup,
        primaryNavigationTitle: HelpText(ko: "설정으로 이동", en: "Open Settings"),
        primaryNavigationSystemImage: "wand.and.sparkles"
    )

    private static let setup = SectionHelpGuide(
        summary: HelpText(
            ko: "설정에서는 앱 데이터, ForgePlay Runtime, Steam 프리픽스, Steam 설치를 순서대로 준비합니다. 노란색 현재 단계를 따라가고, 외장 라이브러리는 필요할 때 별도로 연결하세요.",
            en: "Setup prepares app data, ForgePlay Runtime, the Steam Prefix, and Steam installation in order. Follow the highlighted current step, and connect an external library separately only when needed."
        ),
        groups: [
            Group(
                id: "setup-flow",
                title: HelpText(ko: "권장 진행 순서", en: "Recommended order"),
                systemImage: "arrow.down.circle",
                items: [
                    HelpText(ko: "첫 실행은 Steam 프리픽스, 캐시, 로그를 Mac 내부 Application Support에 자동으로 준비합니다. 설정에서 사용자가 승인한 다른 폴더로 앱 데이터를 옮길 수 있습니다.", en: "First launch prepares the Steam Prefix, caches, and logs in the Mac's internal Application Support directory. Settings can move app data to another user-approved folder."),
                    HelpText(ko: "Mac 상태 확인은 Apple Silicon과 macOS 조건, 현재 앱 데이터 위치의 쓰기 가능 여부를 확인합니다.", en: "Check Mac Status verifies Apple Silicon, macOS requirements, and write access to the current app data location."),
                    HelpText(ko: "ForgePlay Runtime 단계는 앱에 포함된 Runtime이 Windows용 Steam을 실행할 수 있는지 확인합니다.", en: "The ForgePlay Runtime step verifies that the bundled Runtime can launch Windows Steam."),
                    HelpText(ko: "Steam 프리픽스를 만들면 Windows의 C 드라이브처럼 쓰이는 폴더가 생성됩니다. 처음 생성은 프리픽스 초기화 때문에 시간이 걸릴 수 있습니다.", en: "Creating the Steam Prefix builds the folder that behaves like Windows C:. The first initialization can take time because the Prefix has to create its registry and drive layout."),
                    HelpText(ko: "Windows용 Steam 설치는 사용자가 공식 SteamSetup.exe를 직접 받아 선택하는 방식입니다. ForgePlay는 비밀번호를 묻거나 저장하지 않습니다.", en: "Windows Steam installation uses the official SteamSetup.exe selected by the user. ForgePlay never asks for or stores the Steam password.")
                ]
            ),
            Group(
                id: "setup-buttons",
                title: HelpText(ko: "버튼별 의미", en: "What the buttons mean"),
                systemImage: "button.programmable",
                items: [
                    HelpText(ko: "앱 데이터 관리는 현재 Steam 프리픽스, 캐시, 로그 위치를 Finder에 표시하거나 사용자가 승인한 다른 폴더로 옮깁니다. Steam 게임 라이브러리는 이 위치와 별도로 관리합니다.", en: "Manage App Data reveals the current Steam Prefix, cache, and log location or moves it to another user-approved folder. Steam game libraries are managed separately."),
                    HelpText(ko: "확인은 현재 Mac과 선택된 위치를 검사합니다. 검사 결과는 대시보드와 설정 상태에도 반영됩니다.", en: "Check validates the Mac and selected location. Results also appear in Dashboard and Settings."),
                    HelpText(ko: "준비 또는 만들기는 선택된 단계의 실제 작업을 실행합니다. 비활성화되어 있으면 오른쪽 안내 문구가 먼저 해결해야 할 조건입니다.", en: "Prepare or Create runs the current step. If the button is disabled, the message next to it explains what must be fixed first."),
                    HelpText(ko: "필수 구성요소 설치 도구는 게임별로 필요한 VC++, DirectX, .NET 같은 설치 파일을 공식 출처에서 받아 Steam 프리픽스 안에 설치할 때 사용합니다.", en: "Runtime Installer helps install game-specific components such as VC++, DirectX, and .NET into the Steam Prefix from official installers.")
                ]
            ),
            Group(
                id: "setup-troubleshooting",
                title: HelpText(ko: "문제가 생겼을 때", en: "Troubleshooting"),
                systemImage: "wrench.and.screwdriver",
                items: [
                    HelpText(ko: "앱 데이터 쓰기 실패가 보이면 현재 폴더 권한과 디스크 여유 공간을 확인하세요. 사용자 선택 앱 데이터나 외장 게임 라이브러리 권한 오류는 해당 폴더를 다시 연결합니다.", en: "If app data cannot be written, check the current folder permission and free disk space. Reconnect the selected app-data folder or SteamLibrary when its permission expires."),
                    HelpText(ko: "ForgePlay Runtime이 준비되지 않으면 실패 로그를 확인하고 Runtime이 온전히 포함된 최신 ForgePlay 빌드를 다시 설치하세요.", en: "If ForgePlay Runtime is not ready, inspect the failure log and reinstall the latest ForgePlay build with the complete bundled Runtime."),
                    HelpText(ko: "Steam 설치 창이 떠 있지만 ForgePlay가 대기 중이면 Steam 설치 창에서 설치를 끝낸 뒤 ForgePlay로 돌아와 Steam 실행 또는 라이브러리 연결을 진행합니다.", en: "If the Steam installer is open while ForgePlay is waiting, finish installation in that window, then return to ForgePlay and launch Steam or link a library.")
                ]
            )
        ],
        primaryNavigationSection: .steamLaunch,
        primaryNavigationTitle: HelpText(ko: "Steam 실행 화면으로 이동", en: "Open Steam Launch"),
        primaryNavigationSystemImage: "play.circle"
    )

    private static let steamLaunch = SectionHelpGuide(
        summary: HelpText(
            ko: "이 화면은 모든 게임에 공통으로 사용하는 일반 Steam 실행 경로입니다. 게임별 호환성 프로필은 별도의 Steam 호환성 실행 화면에서 관리하며 이 설정을 덮어쓰지 않습니다.",
            en: "This is the standard Steam launch path shared by all games. Game-specific compatibility profiles are managed separately in Steam Compatibility Launch and do not overwrite these settings."
        ),
        groups: [
            Group(
                id: "steam-launch-routes",
                title: HelpText(ko: "Steam 실행 방식", en: "Steam launch paths"),
                systemImage: "arrow.triangle.branch",
                items: [
                    HelpText(ko: "Steam 실행은 개별 게임을 직접 실행하지 않고 Windows용 Steam 자체를 엽니다. 열린 Steam 창에서 라이브러리의 게임을 눌러 실행합니다.", en: "Launch Steam opens Windows Steam itself instead of running a game executable directly. Start the game from the Steam library window that opens."),
                    HelpText(ko: "Steam 호환성 실행 (베타)은 선택한 게임 프로필만을 위한 별도 실행 경로입니다. 일반 Steam 실행 화면의 공통 설정과 독립적으로 저장되며 그 설정을 덮어쓰지 않습니다.", en: "Steam Compatibility Launch (Beta) is a separate path for the selected game profile. It is saved independently from the shared settings in standard Steam Launch and does not overwrite them.")
                ]
            ),
            Group(
                id: "steam-reference-list",
                title: HelpText(ko: "라이브러리와 참고 목록 관리", en: "Managing libraries and references"),
                systemImage: "list.bullet",
                items: [
                    HelpText(ko: "Steam 참고 목록 새로고침은 Steam 프리픽스와 연결된 Steam 라이브러리에서 appmanifest 파일을 다시 읽어 참고 목록을 갱신합니다.", en: "Refresh Steam References rereads appmanifest files from the Steam Prefix and linked Steam libraries to refresh the reference list."),
                    HelpText(ko: "외장 드라이브/폴더 연결은 게임 파일을 복사하지 않습니다. ForgePlay가 선택 위치에서 실제 steamapps 폴더를 찾아 전용 Windows 하위 경로로 연결합니다.", en: "Connect External Drive/Folder does not copy game files. ForgePlay finds the actual steamapps folder in the selection and maps it through a dedicated Windows subpath."),
                    HelpText(ko: "Steam을 다시 열기 직전에 ForgePlay가 소유한 라이브러리 등록만 안전하게 추가하거나 정리합니다. 기존 Steam 등록은 그대로 보존합니다.", en: "Immediately before Steam reopens, ForgePlay safely adds or removes only registrations it owns. Existing Steam registrations are preserved."),
                    HelpText(ko: "감지된 Steam 참고 목록은 실행 버튼이 아니라 라이브러리 진단 기록입니다. 실행은 항상 Windows용 Steam 창에서 직접 합니다.", en: "The detected Steam reference list is library diagnostic information, not a launcher. Start games from the Windows Steam window.")
                ]
            ),
            Group(
                id: "steam-launch-actions",
                title: HelpText(ko: "Steam 실행에서 할 일", en: "Using Steam launch"),
                systemImage: "play.circle",
                items: [
                    HelpText(ko: "Steam 실행은 모든 게임에 공통으로 사용하는 표준 경로입니다. 그래픽 백엔드와 호환성 설정을 선택하고, 다음 실행에도 재사용하려면 저장하세요. Windows용 Steam이 열리면 라이브러리에서 게임을 실행합니다.", en: "Steam Launch is the standard path shared by all games. Choose the graphics backend and compatibility settings, and save them if you want to reuse them on later launches. Start the game from the library after Windows Steam opens."),
                    HelpText(ko: "외장 저장공간은 Steam 실행 전에 쓰기 가능한 전용 Windows 드라이브로 연결됩니다. 기존 라이브러리만 자동 등록하며, 빈 위치의 새 라이브러리는 Steam 저장공간 화면에서 직접 만듭니다.", en: "External storage is mapped as a writable dedicated Windows drive before Steam launches. Existing libraries are registered automatically; create a new library in an empty location from Steam's Storage screen."),
                    HelpText(ko: "감지된 실행 파일은 진단 참고용입니다. 기본 실행 경로는 Steam 클라이언트이며, 런처 선택을 사용자가 직접 고르는 방식이 아닙니다.", en: "Detected executables are diagnostic references. The primary launch path is the Steam client, not manual launcher selection."),
                    HelpText(ko: "Windows용 Steam UI는 렌더러 주입 없이 기본 Wine 경로로 엽니다. 다음 실행 초안에는 그래픽 백엔드, 네트워크 표시, 오디오 입력, 동기화, 비디오 메모리, Game Mode 값이 함께 표시됩니다. 구성을 저장하면 다음 실행에도 다시 사용하고, 저장하지 않고 Steam을 실행하면 현재 초안은 이번 세션에만 적용됩니다. 새 구성의 Game Mode 호스트 기본값은 켬입니다. 게임에는 선택한 백엔드 하나만 적용되고 D3DMetal - NVIDIA는 GPU 공급자와 Apple MetalFX용 NGX 브리지를 함께 준비합니다.", en: "Windows Steam UI opens on the base Wine path without renderer injection. The next-launch draft shows the graphics backend, network presentation, audio input, synchronization, video memory, and Game Mode together. Saving the configuration reuses it on later launches; launching Steam without saving applies the current draft only to this session. Game Mode defaults to on for a new configuration. Games receive only the selected backend, and D3DMetal - NVIDIA prepares the reported GPU vendor and Apple's MetalFX NGX bridge."),
                    HelpText(ko: "D3DMetal - NVIDIA는 지원되는 NVIDIA DLSS/NGX 요청을 Apple MetalFX 업스케일링으로 연결합니다.", en: "D3DMetal - NVIDIA routes supported NVIDIA DLSS/NGX requests through Apple MetalFX upscaling.")
                ]
            ),
            Group(
                id: "steam-launch-troubleshooting",
                title: HelpText(ko: "실행이 실패할 때", en: "If launch fails"),
                systemImage: "stethoscope",
                items: [
                    HelpText(ko: "먼저 Windows용 Steam이 정상적으로 열리고, Steam 창의 라이브러리에 해당 게임이 보이는지 확인합니다.", en: "First verify that Windows Steam opens and that the game appears in the Steam library."),
                    HelpText(ko: "외장 라이브러리 게임이 보이지 않으면 실제 SteamLibrary 폴더 또는 그 상위 외장 디스크를 다시 연결하고 Steam을 다시 실행합니다. 빈 디스크라면 먼저 Steam의 저장공간 화면에서 새 라이브러리를 만든 뒤 다시 확인합니다.", en: "If an external-library game is missing, reconnect the SteamLibrary folder or its parent external disk and relaunch Steam. For an empty disk, first create a new library from Steam's Storage screen, then check again."),
                    HelpText(ko: "VC++, DirectX, .NET 같은 오류가 보이면 진단 결과의 권장 조치나 설정의 필수 구성요소 설치 도구를 사용합니다.", en: "If errors mention VC++, DirectX, or .NET, use the recommended action in Diagnostics or the Runtime Installer in Setup.")
                ]
            )
        ],
        primaryNavigationSection: .diagnostics,
        primaryNavigationTitle: HelpText(ko: "문제 진단 (베타)으로 이동", en: "Open Diagnostics (Beta)"),
        primaryNavigationSystemImage: "stethoscope"
    )

    private static let steamCompatibilityLaunch = SectionHelpGuide(
        summary: HelpText(
            ko: "게임별 호환성 프로필을 저장하고 별도의 Steam 실행 경로에 적용합니다.",
            en: "Save a game-specific compatibility profile and apply it through a separate Steam launch path."
        ),
        groups: [
            Group(
                id: "steam-compatibility-profile",
                title: HelpText(ko: "프로필과 저장 값", en: "Profiles and saved values"),
                systemImage: "list.bullet.rectangle",
                items: [
                    HelpText(ko: "프로필을 선택하면 해당 레시피의 전체 권장 초안이 채워집니다. 같은 프로필의 저장 값이 있으면 명시적으로 저장한 값을 그대로 복원합니다.", en: "Selecting a profile fills the complete recommended draft from its recipe. If that exact profile has a saved value, the explicit saved selections are restored unchanged."),
                    HelpText(ko: "프로필 권장값 복원은 화면의 사용자 선택 가능 초안만 바꾸며 저장 버튼이나 세션 준비 요청 전에는 저장소를 변경하지 않습니다.", en: "Restore Profile Recommendations changes only user-selectable draft fields; it does not modify storage until Save or Prepare Session is explicitly used."),
                    HelpText(ko: "Steam 호환성 실행 (베타)은 선택한 게임 프로필만을 위한 별도 실행 경로입니다. 일반 Steam 실행 화면의 공통 설정과 독립적으로 저장되며 그 설정을 덮어쓰지 않습니다.", en: "Steam Compatibility Launch (Beta) is a separate path for the selected game profile. It is saved independently from the shared settings in standard Steam Launch and does not overwrite them.")
                ]
            ),
            Group(
                id: "steam-compatibility-preparation",
                title: HelpText(ko: "저장 및 세션 준비", en: "Save and prepare the session"),
                systemImage: "checkmark.shield",
                items: [
                    HelpText(ko: "이 프로필이 적용될 설치의 매니페스트 루트 폴더를 선택하세요.", en: "Select the manifest root folder for the installation that will use this profile."),
                    HelpText(ko: "앱에 포함되어 검증된 ForgePlay Runtime 권한을 준비해야 합니다.", en: "The verified ForgePlay Runtime bundled with the app must be ready."),
                    HelpText(ko: "시작이 끝나기 전에는 이 값을 현재 Steam 세션에 적용된 것으로 표시하지 않습니다.", en: "ForgePlay does not show these values as applied to the current Steam session until startup finishes.")
                ]
            ),
            Group(
                id: "steam-compatibility-boundaries",
                title: HelpText(ko: "필수 자동 정책", en: "Required automatic policy"),
                systemImage: "exclamationmark.triangle",
                items: [
                    HelpText(ko: "호환성 프로필의 필수 자동 정책은 일부 게임 보조 프로세스에 렌더러 설정이 전달되지 않도록 제한할 수 있습니다. 프로세스를 종료하거나 게임 파일·보안 모듈을 변경하거나 검증을 우회하지 않습니다.", en: "A compatibility profile's required automatic policy may prevent renderer settings from being passed to some game helper processes. It does not terminate processes, modify game files or security modules, or bypass verification.")
                ]
            )
        ],
        primaryNavigationSection: .steamLaunch,
        primaryNavigationTitle: HelpText(ko: "표준 Steam 실행으로 이동", en: "Open Standard Steam Launch"),
        primaryNavigationSystemImage: "play.circle"
    )

    private static let compatibilityCatalog = SectionHelpGuide(
        summary: HelpText(
            ko: "호환성 목록은 릴리스 전에 수집된 프로젝트 확인, GitHub 이슈, 커뮤니티 제보를 표시하는 읽기 전용 증거 화면입니다. 이 목록은 Steam 실행 설정을 자동으로 적용하지 않습니다.",
            en: "The compatibility catalog is a read-only evidence view for project checks, GitHub issues, and community reports collected before a release. It never applies Steam launch settings automatically."
        ),
        groups: [
            Group(
                id: "compatibility-catalog-evidence",
                title: HelpText(ko: "목록을 해석하는 방법", en: "How to read the catalog"),
                systemImage: "list.bullet.rectangle",
                items: [
                    HelpText(ko: "게임, macOS, ForgePlay 또는 Runtime 업데이트 뒤에는 결과가 달라질 수 있습니다. 앱에는 오프라인 스냅샷이 표시되고 최신 회신 상태는 홈페이지에서 확인합니다.", en: "Results may change after a game, macOS, ForgePlay, or Runtime update. The app shows an offline snapshot; use the website for the latest report-review status."),
                    HelpText(ko: "제보에 Mac·OS 세부 정보가 없으면 앱은 값을 추측하지 않고 미제공으로 표시합니다.", en: "When a report omits Mac or OS details, ForgePlay labels them as not reported instead of inventing defaults."),
                    HelpText(ko: "목록 항목은 호환성 실행 레시피로 승격되지 않으며 Prefix, 렌더러 또는 실행 옵션을 변경할 수 없습니다.", en: "Catalog entries are never promoted into compatibility launch recipes and cannot change a Prefix, renderer, or launch option.")
                ]
            ),
            Group(
                id: "compatibility-catalog-reporting",
                title: HelpText(ko: "호환성 제보", en: "Compatibility reports"),
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                items: [
                    HelpText(ko: "GitHub 이슈에 Mac 칩·메모리, 정확한 macOS·ForgePlay·Runtime·게임 버전, 렌더러, 선택한 호환성 옵션과 증상을 적어주세요.", en: "Include the Mac chip and memory, exact macOS, ForgePlay, Runtime and game versions, renderer, selected compatibility options, and symptoms in the GitHub issue."),
                    HelpText(ko: "지원 번들은 공유 전에 검토하고 가림 처리하며, 비밀번호·Steam Guard 코드·일련번호·관련 없는 개인 파일은 첨부하지 마세요.", en: "Review and redact a support bundle before sharing it. Never attach passwords, Steam Guard codes, serial numbers, or unrelated personal files.")
                ]
            )
        ],
        primaryNavigationSection: .steamCompatibilityLaunch,
        primaryNavigationTitle: HelpText(ko: "Steam 호환성 실행 (베타)으로 이동", en: "Open Steam Compatibility Launch (Beta)"),
        primaryNavigationSystemImage: "gamecontroller.fill"
    )

    private static let windowsUtility = SectionHelpGuide(
        summary: HelpText(
            ko: "EXE 실행은 Windows 보조 도구, 고전 게임 또는 독립 실행형 Windows 프로그램을 SteamShared 프리픽스에서 실행하는 별도 경로입니다.",
            en: "Run EXE is a separate path for launching Windows utilities, classic games, or standalone Windows programs inside the SteamShared prefix."
        ),
        groups: [
            Group(
                id: "windows-utility-purpose",
                title: HelpText(
                    ko: "보조 도구와 독립 실행형 EXE",
                    en: "Utilities and standalone executables"
                ),
                systemImage: "terminal",
                items: [
                    HelpText(
                        ko: "선택한 EXE는 Windows용 Steam과 같은 C: 드라이브와 레지스트리를 보며, 보조 도구·고전 게임·독립 실행형 Windows 프로그램을 실행할 수 있습니다.",
                        en: "The selected EXE sees the same C: drive and registry as Windows Steam and can be a utility, classic game, or standalone Windows program."
                    ),
                    HelpText(
                        ko: "패처가 SteamLibrary의 게임 파일을 수정해야 하면 EXE가 든 폴더와 연결된 Steam 저장공간 접근 권한이 해당 실행에 전달됩니다.",
                        en: "If a patcher needs to modify files in a SteamLibrary, ForgePlay passes the selected EXE folder and connected Steam-storage access to that run."
                    )
                ]
            ),
            Group(
                id: "windows-utility-renderer",
                title: HelpText(ko: "선택 그래픽 백엔드", en: "Graphics backend selection"),
                systemImage: "paintbrush",
                items: [
                    HelpText(
                        ko: "Wine 기본은 고전 2D/GDI·소프트웨어 렌더링 또는 WineD3D(OpenGL 변환)를 사용할 수 있으며 항상 CPU 전용인 것은 아닙니다.",
                        en: "Wine Default can use classic 2D/GDI, software rendering, or WineD3D (OpenGL translation), so it is not necessarily CPU-only."
                    ),
                    HelpText(
                        ko: "D9VK는 DX9 고전 3D, DXVK는 DX10/11, DXMT는 DX11 대안, D3DMetal은 최신 Direct3D에 적합합니다. 백엔드 지원 여부는 설치되고 인증된 ForgePlay Runtime 페이로드에 따라 달라집니다.",
                        en: "D9VK suits classic DX9 3D, DXVK targets DX10/11, DXMT is an alternative for DX11, and D3DMetal suits modern Direct3D. Availability depends on the installed and authenticated ForgePlay Runtime payload."
                    )
                ]
            ),
            Group(
                id: "windows-utility-boundaries",
                title: HelpText(
                    ko: "이 경로에 적용되지 않는 설정",
                    en: "Settings not applied on this path"
                ),
                systemImage: "nosign",
                items: [
                    HelpText(
                        ko: "직접 EXE 실행에는 Game Mode가 없으며 Steam 네트워크·오디오·컨트롤러·게임 호환성 프로필을 적용하지 않습니다.",
                        en: "Direct EXE launch does not provide Game Mode and does not apply Steam network, audio, controller, or game compatibility profiles."
                    )
                ]
            ),
            Group(
                id: "windows-utility-safety",
                title: HelpText(ko: "실행 전 확인", en: "Before running"),
                systemImage: "exclamationmark.shield",
                items: [
                    HelpText(
                        ko: "패처가 게임 파일이나 보안 모듈을 바꾼다면 충돌과 부분 적용을 피하도록 Steam과 게임을 먼저 완전히 종료하세요.",
                        en: "If the patcher changes game files or security modules, fully quit Steam and the game first to avoid conflicts or partial application."
                    ),
                    HelpText(
                        ko: "ForgePlay는 선택한 제3자 패처의 출처, 동작, 계정 제재 위험을 검증하거나 보증하지 않습니다. 신뢰하는 파일만 선택하고 필요한 경우 게임 파일을 먼저 백업하세요.",
                        en: "ForgePlay does not verify or endorse a third-party patcher's source, behavior, or account-sanction risk. Select only a tool you trust and back up game files when appropriate."
                    ),
                    HelpText(
                        ko: "안티치트나 보안 모듈을 우회·변경하는 도구는 게임 약관이나 계정 정책에 영향을 줄 수 있습니다. 도구 제작자의 문서와 대상 게임 정책을 직접 확인하세요.",
                        en: "Tools that bypass or alter anti-cheat or security modules may affect game terms or account policy. Review the tool documentation and the game's policy yourself."
                    )
                ]
            )
        ],
        primaryNavigationSection: .windowsUtility,
        primaryNavigationTitle: HelpText(
            ko: "EXE 실행 (베타)으로 돌아가기",
            en: "Return to Run EXE (Beta)"
        ),
        primaryNavigationSystemImage: "terminal.fill"
    )

    private static let diagnostics = SectionHelpGuide(
        summary: HelpText(
            ko: "문제 진단은 실행 실패 로그를 읽고, 로컬 규칙 분석과 선택형 로컬 AI 분석으로 원인과 다음 조치를 정리하는 화면입니다.",
            en: "Diagnostics reads failed launch logs and summarizes causes and next steps through local rules and optional local AI analysis."
        ),
        groups: [
            Group(
                id: "diagnostics-analysis",
                title: HelpText(ko: "분석 방식", en: "Analysis methods"),
                systemImage: "cpu",
                items: [
                    HelpText(ko: "최근 로그 다시 분석은 저장된 최신 실행 로그를 로컬 Rule Engine으로 분석합니다. 네트워크를 쓰지 않고 정해진 오류 패턴을 찾습니다.", en: "Recent Log Analysis uses the local rule engine on the newest saved launch log. It does not use the network and looks for known error patterns."),
                    HelpText(ko: "AI 로컬 분석 전 미리보기는 분석에 들어갈 텍스트와 가림 처리 결과를 먼저 보여줍니다. 사용자가 확인한 뒤에만 실행합니다.", en: "AI Preview shows the text and redaction result before analysis. It only runs after user confirmation."),
                    HelpText(ko: "AI 진단은 설정에서 켠 경우에만 Apple Foundation Models를 사용합니다. 외부 AI 서버로 로그를 보내는 구조가 아닙니다.", en: "AI diagnostics use Apple Foundation Models only when enabled in Settings. Logs are not sent to an external AI server.")
                ]
            ),
            Group(
                id: "diagnostics-actions",
                title: HelpText(ko: "권장 조치 읽는 법", en: "Reading recommended actions"),
                systemImage: "wand.and.stars",
                items: [
                    HelpText(ko: "런타임 설치 권장은 VC++, DirectX, .NET 같은 구성요소가 필요할 가능성을 뜻합니다. 공식 설치 파일을 받아 선택해야 합니다.", en: "Runtime recommendations mean components such as VC++, DirectX, or .NET may be needed. Download the official installer and select it."),
                    HelpText(ko: "Windows 버전 또는 DLL override 권장은 Steam 프리픽스 설정 변경입니다. Steam 실행 모델에서는 Steam 프리픽스가 적용 대상입니다.", en: "Windows version and DLL override recommendations modify Steam Prefix settings. In the Steam launch model, the Steam Prefix is the target."),
                    HelpText(ko: "지원되지 않음 또는 업데이트 권장은 현재 ForgePlay Runtime, macOS, 게임 상태에서 바로 실행하기 어렵다는 의미입니다. 로그를 보관하고 앱/런타임 업데이트를 확인하세요.", en: "Unsupported or update recommendations mean the current ForgePlay Runtime, macOS, or game state may not run it yet. Keep the logs and check for app/runtime updates.")
                ]
            ),
            Group(
                id: "diagnostics-support",
                title: HelpText(ko: "지원 번들", en: "Support bundle"),
                systemImage: "doc.zipper",
                items: [
                    HelpText(ko: "지원 번들 v2는 가림 처리한 로그와 진단, 사용 가능한 실행 기록·프리픽스 메타데이터, 앱·Mac·Runtime·그래픽·디스플레이·저장공간 상태를 로컬 ZIP으로 묶습니다.", en: "Support Bundle v2 creates a local ZIP containing redacted logs and diagnostics, available launch records and Prefix metadata, plus app, Mac, runtime, graphics, display, and storage status."),
                    HelpText(ko: "README.md를 먼저 읽고, 제작자 분석에는 metadata/bundle-manifest.json을 함께 전달하세요. manifest는 실행별 로그 역할·종료 결과·누락 자료·수집 오류를 연결합니다.", en: "Read README.md first and include metadata/bundle-manifest.json for developer analysis. The manifest links each launch to log roles, process outcomes, missing evidence, and collection errors."),
                    HelpText(ko: "collectionStatus가 partial이거나 skippedFiles 또는 collectionIssues가 있으면 일부 증거가 누락된 것입니다. 이는 오류가 없다는 뜻이 아닙니다.", en: "If collectionStatus is partial or skippedFiles or collectionIssues are present, some evidence is missing. That does not mean no error occurred."),
                    HelpText(ko: "큰 텍스트 로그는 앞뒤만 남을 수 있고 스크린샷과 바이너리 크래시 덤프는 개인정보 보호를 위해 제외됩니다. 가림 처리는 완전한 보장이 아니므로 전송 전 Finder에서 내용을 직접 확인하고 비밀번호·Steam Guard 코드·토큰이 보이면 공유하지 마세요.", en: "Large text logs may retain only their beginning and end, while screenshots and binary crash dumps are excluded for privacy. Redaction is not a complete guarantee, so review the archive in Finder and do not share it if you see passwords, Steam Guard codes, or tokens.")
                ]
            )
        ],
        primaryNavigationSection: .settings,
        primaryNavigationTitle: HelpText(ko: "설정으로 이동", en: "Open Settings"),
        primaryNavigationSystemImage: "gearshape"
    )

    private static let learnAboutForgePlay = SectionHelpGuide(
        summary: HelpText(
            ko: "ForgePlay를 만든 이유와 공개된 제작자 노트 전문을 앱 언어로 읽습니다.",
            en: "Read why ForgePlay was built and the complete public creator’s note in the app’s language."
        ),
        groups: [
            Group(
                id: "learn-about-forgeplay-links",
                title: HelpText(ko: "제작자 노트 전문", en: "Complete Creator’s Note"),
                systemImage: "book.closed",
                items: [
                    HelpText(ko: "앱에 포함된 전문을 현재 표시 언어로 읽습니다. 인터넷 연결이나 홈페이지 로딩이 필요하지 않습니다.", en: "Read the complete note bundled with the app in the current display language. No internet connection or website loading is required."),
                    HelpText(ko: "GitHub 저장소 상단의 Star로 ForgePlay에 좋아요를 표시하거나 GitHub Sponsors에서 개발과 호환성 테스트를 후원할 수 있습니다.", en: "Use Star at the top of the GitHub repository to like ForgePlay, or support development and compatibility testing through GitHub Sponsors."),
                    HelpText(ko: "제작자 노트는 웹페이지가 아니라 선택하고 복사할 수 있는 앱의 네이티브 글자로 표시됩니다.", en: "The creator’s note is shown as selectable, copyable native app text instead of a webpage.")
                ]
            )
        ],
        primaryNavigationSection: .learnAboutForgePlay,
        primaryNavigationTitle: HelpText(ko: "만든 이유", en: "Why I Built It"),
        primaryNavigationSystemImage: "book.closed.fill"
    )

    private static let developerApps = SectionHelpGuide(
        summary: HelpText(
            ko: "제작자의 다른 앱 화면은 출시된 앱과 출시 예정 프로젝트를 앱 카탈로그에서 소개하고, 별도의 개발 중 탭에서 진행 중인 프로젝트를 보여줍니다.",
            en: "Other Apps by the Developer presents released apps and upcoming projects in the App Catalog, with a separate In Development tab for ongoing projects."
        ),
        groups: [
            Group(
                id: "developer-apps-catalog",
                title: HelpText(ko: "앱 카탈로그와 출시 예정", en: "App Catalog and upcoming releases"),
                systemImage: "rectangle.3.group",
                items: [
                    HelpText(ko: "앱 카탈로그 탭 상단에는 MajorDex와 ForgeKit이 출시 예정 프로젝트로 표시됩니다.", en: "The top of the App Catalog tab presents MajorDex and ForgeKit as upcoming projects."),
                    HelpText(ko: "Mac, iPad, iPhone 탭을 선택하면 해당 플랫폼용 앱만 표시됩니다.", en: "Choose the Mac, iPad, or iPhone tab to show only apps for that platform."),
                    HelpText(ko: "앱 이름 검색은 현재 선택한 플랫폼 안에서 이름과 짧은 소개를 함께 검색합니다.", en: "App search checks names and short descriptions within the selected platform."),
                    HelpText(ko: "각 출시된 앱 카드에는 실제 지원 언어가 표시됩니다. App Store에서 보기를 누르면 공식 제품 페이지가 열립니다.", en: "Each released-app card lists its actual supported languages. View in App Store opens the official product page.")
                ]
            ),
            Group(
                id: "developer-apps-in-development",
                title: HelpText(ko: "개발 중 프로젝트", en: "Projects in development"),
                systemImage: "hammer",
                items: [
                    HelpText(ko: "개발 중 탭에는 HareWatch와 WarrenNet의 아이콘과 프로젝트 이름만 표시됩니다.", en: "The In Development tab shows only the project icons and names for HareWatch and WarrenNet."),
                    HelpText(ko: "개발 중 표시는 출시 일정이나 배포 준비 완료를 의미하지 않습니다.", en: "In Development does not indicate a release date or distribution readiness.")
                ]
            )
        ],
        primaryNavigationSection: .developerApps,
        primaryNavigationTitle: HelpText(ko: "앱 카탈로그로 돌아가기", en: "Return to App Catalog"),
        primaryNavigationSystemImage: "square.grid.3x3.square"
    )

    private static let hallOfSupporters = SectionHelpGuide(
        summary: HelpText(ko: "", en: ""),
        groups: [],
        primaryNavigationSection: .hallOfSupporters,
        primaryNavigationTitle: HelpText(ko: "명예의 전당으로 돌아가기", en: "Return to Hall of Supporters"),
        primaryNavigationSystemImage: "building.columns.fill"
    )

    private static let settings = SectionHelpGuide(
        summary: HelpText(
            ko: "설정 화면은 언어, 저장 위치, ForgePlay Runtime, Steam 설치 파일, AI 진단, 호환성 DB, 로그 정리, 법무 문서를 관리합니다.",
            en: "Settings manages language, storage, ForgePlay Runtime, Steam installer, AI diagnostics, compatibility DB, log cleanup, and legal documents."
        ),
        groups: [
            Group(
                id: "settings-language",
                title: HelpText(ko: "언어 설정", en: "Language settings"),
                systemImage: "globe",
                items: [
                    HelpText(ko: "기본값은 시스템 언어 따르기입니다. 사용자가 직접 언어를 고른 경우에만 수동 설정으로 저장됩니다.", en: "The default is Follow System Language. A manual language is saved only when the user explicitly selects one."),
                    HelpText(ko: "시스템 언어 따르기를 누르면 저장된 수동 언어 override를 끄고 macOS 표시 언어 순서를 다시 따릅니다.", en: "Follow System Language disables the manual override and follows the macOS display language order again."),
                    HelpText(ko: "언어 변경 후 글자가 길어져 버튼이 줄바꿈될 수 있습니다. 잘림이 보이면 창 폭을 넓히거나 해당 화면을 알려주세요.", en: "Some labels may wrap after language changes. If text is clipped, widen the window or report the affected screen.")
                ]
            ),
            Group(
                id: "settings-status",
                title: HelpText(ko: "설정 상태 관리", en: "Managing setup status"),
                systemImage: "list.bullet.rectangle",
                items: [
                    HelpText(ko: "앱 데이터, Mac 상태, ForgePlay Runtime, Steam 프리픽스, Steam 설치 파일은 설정과 같은 실제 상태를 공유합니다.", en: "App data, Mac status, ForgePlay Runtime, Steam Prefix, and the Steam installer share the same state as Setup."),
                    HelpText(ko: "앱 데이터는 기본적으로 내부 Application Support에 있으며 설정에서 다른 폴더로 옮길 수 있습니다. 외장 게임 라이브러리는 Steam 저장공간 연결에서 별도로 관리합니다.", en: "App data defaults to internal Application Support and can be moved to another folder from Settings. External game libraries remain separate under Steam Storage linking."),
                    HelpText(ko: "설정 저장 실패가 표시되면 앱 상태는 이전 값으로 되돌아가며, 경고 내용을 확인한 뒤 다시 시도해야 합니다.", en: "If saving settings fails, the app restores the previous values. Read the warning and retry after fixing the cause.")
                ]
            ),
            Group(
                id: "settings-maintenance",
                title: HelpText(ko: "유지보수 기능", en: "Maintenance"),
                systemImage: "wrench.and.screwdriver",
                items: [
                    HelpText(ko: "로그 자동 정리는 오래된 로그와 과도하게 많은 실행 로그를 줄입니다. 문제 재현 중에는 보관 기간을 너무 짧게 잡지 마세요.", en: "Automatic log cleanup removes old or excessive launch logs. During troubleshooting, avoid setting retention too low."),
                    HelpText(ko: "사이드바의 업데이트 확인 (베타) 버튼은 ForgePlay 홈페이지의 공개 릴리스 정보를 확인합니다. 업데이트가 있으면 버튼을 다시 눌러 공식 릴리스 페이지를 엽니다.", en: "The Check for Updates (Beta) button in the sidebar checks public release information on the ForgePlay website. If an update is available, select the button again to open the official release page."),
                    HelpText(ko: "호환성 DB 업데이트는 신뢰된 공개키와 HTTPS 피드가 있어야 동작합니다. 잘못된 URL이나 개인 네트워크 주소는 거부됩니다.", en: "Compatibility DB updates require a trusted public key and HTTPS feed. Invalid URLs and private network addresses are rejected."),
                    HelpText(ko: "법무/개인정보 문서는 앱 안의 고지와 GitHub Pages용 공개 문서를 확인하는 용도입니다.", en: "Legal and privacy documents let you review in-app notices and the public GitHub Pages material.")
                ]
            )
        ],
        primaryNavigationSection: .advanced,
        primaryNavigationTitle: HelpText(ko: "고급 정보로 이동", en: "Open Advanced"),
        primaryNavigationSystemImage: "wrench.and.screwdriver.fill"
    )

    private static let advanced = SectionHelpGuide(
        summary: HelpText(
            ko: "고급 정보는 일반 사용 흐름에서 숨긴 실제 경로, 프리픽스 기록, Runtime 기록, 배포 메모를 확인하는 화면입니다. 문제 해결이나 배포 검토 때 사용합니다.",
            en: "Advanced Information shows paths, Prefix records, runtime records, and release notes hidden from the beginner flow. Use it for troubleshooting and release review."
        ),
        groups: [
            Group(
                id: "advanced-paths",
                title: HelpText(ko: "경로 읽는 법", en: "Reading paths"),
                systemImage: "folder",
                items: [
                    HelpText(ko: "앱 데이터는 Steam 프리픽스, RuntimeCache, Logs 같은 실행 상태를 보관합니다. 외장 Steam 게임 라이브러리는 이 위치와 분리되어 security-scoped bookmark로 연결됩니다.", en: "App data stores the Steam Prefix, RuntimeCache, Logs, and other execution state. External Steam game libraries remain separate and are connected with security-scoped bookmarks."),
                    HelpText(ko: "ForgePlay Runtime은 Windows용 Steam과 Steam 게임 실행에 쓰는 앱 내장 실행 엔진입니다. 모든 배포 빌드가 같은 번들 Runtime만 사용합니다.", en: "ForgePlay Runtime is the bundled execution engine for Windows Steam and Steam games. Every distribution uses the same bundled Runtime only."),
                    HelpText(ko: "Steam 설치 파일은 사용자가 선택한 SteamSetup.exe 경로입니다. 설치가 끝난 뒤에도 다시 설치할 때 참고용으로 남을 수 있습니다.", en: "Steam Installer is the selected SteamSetup.exe path. It can remain for reinstall reference after installation.")
                ]
            ),
            Group(
                id: "advanced-records",
                title: HelpText(ko: "기록 확인", en: "Inspecting records"),
                systemImage: "doc.text.magnifyingglass",
                items: [
                    HelpText(ko: "Steam 프리픽스 기록은 현재 실행에 사용하는 프리픽스의 경로, Windows 버전, 아키텍처 정보를 보여줍니다. 이전 버전의 게임별 프리픽스 기록이 있더라도 현재 실행 경로는 Steam 프리픽스입니다.", en: "Steam Prefix records show the path, Windows version, and architecture for the Prefix used by the current launch path. Legacy per-game Prefix records, if present, are not used for launch."),
                    HelpText(ko: "Runtime 기록은 VC++, DirectX, .NET 같은 구성요소를 어떤 Steam 프리픽스에 설치했는지 보여줍니다.", en: "Runtime records show which Steam Prefix received components such as VC++, DirectX, or .NET."),
                    HelpText(ko: "기록이 비어 있으면 아직 해당 작업을 하지 않았거나 저장 위치가 초기화된 상태입니다.", en: "Empty records mean the operation has not been performed yet or the storage workflow was reset.")
                ]
            ),
            Group(
                id: "advanced-caution",
                title: HelpText(ko: "주의할 점", en: "Cautions"),
                systemImage: "exclamationmark.triangle",
                items: [
                    HelpText(ko: "고급 정보의 경로를 Finder에서 직접 수정하면 ForgePlay의 저장 기록과 실제 파일 상태가 어긋날 수 있습니다.", en: "Editing these paths directly in Finder can desynchronize ForgePlay records from actual files."),
                    HelpText(ko: "처음부터 다시 설정해야 할 때는 설정 다시 시작 기능을 사용하고, 원본 게임 파일 삭제 여부는 Finder에서 별도로 판단하세요.", en: "When starting over, use Restart Settings. Decide separately in Finder whether original game files should be deleted."),
                    HelpText(ko: "배포 메모는 앱 번들, Developer ID 서명, DMG 공증과 릴리스 검증 상태를 확인하기 위한 내부 기록입니다.", en: "Release notes are internal records for checking the app bundle, Developer ID signing, DMG notarization, and release-verification state.")
                ]
            )
        ],
        primaryNavigationSection: .settings,
        primaryNavigationTitle: HelpText(ko: "설정으로 이동", en: "Open Settings"),
        primaryNavigationSystemImage: "gearshape"
    )
}

private struct HelpText {
    var ko: String
    var en: String

    @MainActor
    func text(appState: AppState) -> String {
        let language: ForgePlayLanguageMode
        #if DEBUG
        if let debugLanguageModeOverride = appState.debugLanguageModeOverride {
            language = debugLanguageModeOverride
        } else {
            language = appState.languageMode
        }
        #else
        language = appState.languageMode
        #endif

        let resolved = language == .system
            ? ForgePlaySystemLanguageResolver.resolvedLanguageMode()
            : language
        let localized = appState.localized(ko)
        if resolved == .korean || localized != ko {
            return localized
        }
        return en
    }
}
