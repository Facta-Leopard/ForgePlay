import SwiftData
import SwiftUI

struct SetupProgressResetCard: View {
    var onReset: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingConfirmation = false
    @State private var isResetting = false

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgeCard("처음 설정 다시 검증", systemImage: "arrow.counterclockwise.circle") {
            Text(appState.localized("내부 앱 데이터 위치는 유지하고 Runtime 확인부터 설정 진행 상태를 다시 검증합니다."))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                ResponsiveActionRow {
                    ThemedActionButton(
                        title: "처음 설정 다시 시작",
                        systemImage: "arrow.counterclockwise",
                        prominence: .secondary,
                        isDisabled: isResetting || services.steamPrefixLifecycleCoordinator.isBusy,
                        controlSize: .small
                    ) {
                        isShowingConfirmation = true
                    }
                    .frame(minWidth: 172, idealWidth: 210, maxWidth: 260)
                }

                Text(appState.localized("외장 Steam 저장공간 연결과 실제 내부 앱 데이터, 프리픽스 폴더, 외장 게임 파일은 유지합니다."))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            appState.localized("처음 설정 상태로 되돌릴까요?"),
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("앱 상태만 초기화"), role: .destructive) {
                resetSetupProgress()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localized("앱이 기억하는 Runtime, Steam 설치 파일, 프리픽스/게임/실행/진단 기록만 초기화합니다. 내부 앱 데이터 위치와 외장 Steam 저장공간 연결, 실제 파일은 그대로 둡니다."))
        }
    }

    private func resetSetupProgress() {
        guard !isResetting else { return }
        isResetting = true
        Task {
            defer { isResetting = false }
            do {
                let result = try await services.resetSetupProgress(
                    appState: appState,
                    in: modelContext
                )
                onReset?()
                let notice = appState.setNotice(
                    appState.localizedFormat(
                        "처음 설정 상태로 되돌렸습니다. 앱 기록 %d개를 초기화했습니다.",
                        result.deletedRecordCount
                    ),
                    kind: .success
                )
                clearTaskLater(notice.id)
            } catch {
                appState.setError(error)
            }
        }
    }

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}
