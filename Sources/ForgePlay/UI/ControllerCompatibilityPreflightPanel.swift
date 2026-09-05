import SwiftUI

struct ControllerCompatibilityPreflightPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: ControllerCompatibilityPreflightSnapshot?

    var body: some View {
        let palette = ForgePlayTheme.palette(
            mode: appState.themeMode,
            colorScheme: colorScheme
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label(appState.localized("컨트롤러 사전 점검"), systemImage: "gamecontroller")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                SecondaryActionButton(
                    title: snapshot == nil ? "컨트롤러 확인" : "다시 확인",
                    systemImage: "arrow.clockwise"
                ) {
                    snapshot = services.controllerCompatibilityPreflightService
                        .inspectConnectedControllers()
                }
            }

            if let snapshot {
                preflightResult(snapshot, palette: palette)
            } else {
                Text(appState.localized(
                    "macOS의 Game Controller 발견 단계와 Windows 세션 확인 단계를 분리해 점검합니다."
                ))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    @ViewBuilder
    private func preflightResult(
        _ snapshot: ControllerCompatibilityPreflightSnapshot,
        palette: ForgePlayPalette
    ) -> some View {
        switch snapshot.macState {
        case .noControllerDetected:
            Text(appState.localized(
                "macOS에서 연결된 컨트롤러를 찾지 못했습니다. 다시 연결하고 macOS의 연결 승인 알림을 확인하세요."
            ))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .controllerDetected:
            Text(appState.localizedFormat(
                "macOS 감지 %d개 · 확장 게임패드 %d개",
                snapshot.connectedControllerCount,
                snapshot.extendedGamepadCount
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.text)
            if !snapshot.productCategories.isEmpty {
                Text(appState.localizedFormat(
                    "감지 종류: %@",
                    snapshot.productCategories.joined(separator: ", ")
                ))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(appState.localized(
                "이 결과는 macOS 발견만 확인합니다. 자동 모드는 번들 Wine의 macOS IOHID 경로를 사용합니다. ForgePlay는 기존 프리픽스에도 DisableHidraw=0, DisableInput=1, Enable SDL=0, Map Controllers=0을 적용해 일반 게임패드를 raw IOHID로 전달합니다. 이 화면은 Wine 자식의 실제 장치·XInput·Steam Input 열거를 확인하지 않으며, 컨트롤러 연결 여부나 열거 미확인을 이유로 Steam 실행을 차단하지 않습니다. 모델별 최종 인식은 실기기에서 확인합니다."
            ))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
