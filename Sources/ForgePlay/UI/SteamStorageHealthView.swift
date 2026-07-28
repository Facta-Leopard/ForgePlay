import SwiftUI

struct SteamStorageHealthSummaryView: View {
    var mountCount: Int
    var reports: [SteamStorageHealthReport]
    var isChecking: Bool
    var errorMessage: String?
    var isRefreshDisabled: Bool
    var onRefresh: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    summaryStatus(palette: palette)
                    Spacer(minLength: 12)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    summaryStatus(palette: palette)
                    refreshButton
                }
            }

            Text(appState.localized(
                "실제 읽기, 쓰기, 다시 읽기, 삭제 권한을 확인합니다. Steam 게임 파일은 변경하지 않습니다."
            ))
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(palette.surfaceElevated)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.controlCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.controlCornerRadius,
                style: .continuous
            )
            .stroke(palette.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func summaryStatus(palette: ForgePlayPalette) -> some View {
        if isChecking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(appState.localized("상태 확인 중"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(appState.localized("저장공간 상태"))
            .accessibilityValue(appState.localized("상태 확인 중"))
        } else if reports.isEmpty {
            StatusBadge(label: "아직 확인하지 않음", status: .unknown)
                .accessibilityLabel(appState.localized("저장공간 상태"))
                .accessibilityValue(appState.localized("아직 확인하지 않음"))
        } else {
            let healthyCount = reports.filter { $0.status == .healthy }.count
            let issueCount = max(0, mountCount - healthyCount)
            let summary = appState.localizedFormat(
                "%d개 정상 · %d개 확인 필요",
                healthyCount,
                issueCount
            )
            StatusBadge(
                label: summary,
                status: issueCount == 0 ? .ok : .warning
            )
            .accessibilityLabel(appState.localized("저장공간 상태"))
            .accessibilityValue(summary)
        }
    }

    private var refreshButton: some View {
        ThemedActionButton(
            title: isChecking ? "상태 확인 중" : "상태 확인",
            systemImage: "checkmark.shield",
            prominence: .secondary,
            isDisabled: isRefreshDisabled || isChecking,
            controlSize: .small,
            action: onRefresh
        )
        .frame(minWidth: 116, idealWidth: 136, maxWidth: 170)
    }
}

struct SteamStorageHealthStatusView: View {
    var report: SteamStorageHealthReport?
    var isChecking: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 5) {
            if isChecking {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(appState.localized("상태 확인 중"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(appState.localized("저장공간 상태"))
                .accessibilityValue(appState.localized("상태 확인 중"))
            } else {
                StatusBadge(label: statusLabel, status: checkStatus)
                    .accessibilityLabel(appState.localized("저장공간 상태"))
                    .accessibilityValue(appState.localized(statusLabel))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(checkStatus == .error ? palette.danger : palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLabel: String {
        guard let report else { return "아직 확인하지 않음" }
        switch report.status {
        case .healthy:
            return "접근 정상"
        case .degraded, .reconnectRequired:
            return "다시 연결 필요"
        case .unavailable:
            return "접근 오류"
        }
    }

    private var checkStatus: CheckStatus {
        guard let report else { return .unknown }
        switch report.status {
        case .healthy:
            return .ok
        case .degraded, .reconnectRequired:
            return .warning
        case .unavailable:
            return .error
        }
    }

    private var detailText: String {
        guard let report else { return appState.localized("아직 확인하지 않음") }
        guard report.status != .healthy else {
            return appState.localized("저장공간 접근 권한과 읽기·쓰기 상태가 정상입니다.")
        }
        let stage = appState.localized(report.failedStage?.displayNameKey ?? "저장된 접근 권한")
        return appState.localizedFormat(
            "저장공간 상태 확인 실패: %@. 원래 폴더를 다시 선택하세요.",
            stage
        )
    }
}
