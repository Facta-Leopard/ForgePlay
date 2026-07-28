import AppKit
import SwiftUI

struct StartupFailureView: View {
    var title = "앱 데이터를 열 수 없습니다."
    var message = "ForgePlay의 저장 데이터베이스를 준비하지 못했습니다. 앱을 강제 종료하지 않고 오류 정보를 표시했습니다."
    var guidance = "앱을 다시 열어도 같은 문제가 계속되면 아래 오류를 확인한 뒤 긴급 지원 보고서를 만들어 제작자에게 전달하세요."
    var error: Error

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var recoveryActionErrorMessage: String?
    @State private var emergencySupportBundleURL: URL?
    @State private var isCreatingEmergencySupportBundle = false

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ZStack {
            palette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label {
                        Text(appState.localized(title))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(palette.text)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(CheckStatus.error.color(in: palette))
                    }

                    Text(appState.localized(message))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(appState.localized(guidance))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.localized("오류 정보"))
                            .font(.headline)
                            .foregroundStyle(palette.text)
                        Text(verbatim: errorDescription)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(palette.border, lineWidth: 1)
                            )
                    }

                    if let emergencySupportBundleURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(appState.localized("긴급 지원 보고서 생성 완료"), systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(CheckStatus.ok.color(in: palette))
                            Text(appState.localized("SwiftData 저장소 없이 앱·Mac·디스크·시작 오류 정보를 담은 가림 처리 JSON 보고서를 만들었습니다."))
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: emergencySupportBundleURL.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            ThemedActionButton(
                                title: "Finder에서 보기",
                                systemImage: "folder",
                                prominence: .secondary
                            ) {
                                _ = appState.revealInFinder(emergencySupportBundleURL)
                            }
                            .frame(maxWidth: 190)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CheckStatus.ok.color(in: palette).opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(CheckStatus.ok.color(in: palette).opacity(0.25), lineWidth: 1)
                        )
                    }

                    if let recoveryActionErrorMessage {
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(appState.localized("복구 작업을 완료하지 못했습니다."))
                                    .font(.headline)
                                    .foregroundStyle(palette.text)
                                Text(recoveryActionErrorMessage)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(CheckStatus.warning.color(in: palette))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CheckStatus.warning.color(in: palette).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(CheckStatus.warning.color(in: palette).opacity(0.28), lineWidth: 1)
                        )
                    }

                    ResponsiveActionRow {
                        ThemedActionButton(
                            title: "Application Support 열기",
                            systemImage: "folder",
                            prominence: .secondary
                        ) {
                            openApplicationSupport()
                        }

                        ThemedActionButton(
                            title: isCreatingEmergencySupportBundle
                                ? "긴급 지원 보고서 생성 중"
                                : "긴급 지원 보고서 생성",
                            systemImage: "doc.badge.gearshape",
                            prominence: .secondary,
                            isDisabled: isCreatingEmergencySupportBundle
                        ) {
                            createEmergencySupportBundle()
                        }

                        ThemedActionButton(
                            title: "오류 복사",
                            systemImage: "doc.on.doc",
                            prominence: .secondary
                        ) {
                            copyErrorDescription()
                        }

                        ThemedActionButton(
                            title: "앱 종료",
                            systemImage: "power",
                            prominence: .primary
                        ) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: 520, alignment: .center)
            }
        }
        .preferredColorScheme(appState.themeMode.preferredColorScheme)
        .tint(palette.primary)
    }

    private var errorDescription: String {
        forgePlayTechnicalErrorSummary(error)
    }

    private func openApplicationSupport() {
        do {
            let applicationSupport = try ForgePlayApp.applicationSupportDirectory()
            if ExternalLinkPolicy.open(applicationSupport) {
                recoveryActionErrorMessage = nil
            } else {
                recoveryActionErrorMessage = appState.localizedFormat("항목을 열 수 없습니다: %@", applicationSupport.path)
            }
        } catch {
            recoveryActionErrorMessage = appState.localizedError(error)
        }
    }

    private func copyErrorDescription() {
        recoveryActionErrorMessage = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(errorDescription, forType: .string)
    }

    private func createEmergencySupportBundle() {
        guard !isCreatingEmergencySupportBundle else { return }
        isCreatingEmergencySupportBundle = true
        defer { isCreatingEmergencySupportBundle = false }
        do {
            emergencySupportBundleURL = try EmergencySupportBundleService().createBundle(for: error)
            recoveryActionErrorMessage = nil
        } catch {
            recoveryActionErrorMessage = appState.localizedFormat(
                "긴급 지원 보고서를 만들지 못했습니다: %@",
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }
}
