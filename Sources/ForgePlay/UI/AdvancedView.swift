import SwiftData
import SwiftUI

struct AdvancedView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \PrefixRecord.displayName) private var prefixes: [PrefixRecord]
    @Query(sort: \RuntimeRecord.runtime) private var runtimes: [RuntimeRecord]
    private let pathRowTitleMinimumWidth: CGFloat = 132
    private let pathRowTitleIdealWidth: CGFloat = 168
    private let pathRowTitleMaximumWidth: CGFloat = 240

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: ForgePlayLayout.pageSpacing) {
                advancedHeader(palette: palette)

                SetupProgressResetCard()

                ForgeCard("경로", systemImage: "folder") {
                    pathRow("앱 데이터", appState.selectedRootURL)
                    pathRow("ForgePlay Runtime", appState.runtimeExecutableURL)
                    pathRow("Steam 설치 파일", appState.steamInstallerURL)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 360), spacing: ForgePlayLayout.sectionSpacing)
                    ],
                    alignment: .leading,
                    spacing: ForgePlayLayout.sectionSpacing
                ) {
                    ForgeCard("Steam 프리픽스 기록", systemImage: "externaldrive") {
                        if prefixes.isEmpty {
                            Text(appState.localized("SwiftData에 기록된 Steam 프리픽스가 없습니다. 설정에서 Steam 프리픽스를 만들면 기록됩니다."))
                                .foregroundStyle(palette.secondaryText)
                        } else {
                            ForEach(prefixes) { prefix in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(prefix.localizedDisplayName(appState: appState))
                                        .font(.headline)
                                    AdaptiveValueText(
                                        text: prefixDetailText(prefix),
                                        font: .caption,
                                        color: palette.secondaryText
                                    )
                                }
                                Divider()
                            }
                        }
                    }

                    ForgeCard("필수 구성요소(Runtime)", systemImage: "shippingbox") {
                        if runtimes.isEmpty {
                            Text(appState.localized("아직 설치 기록이 없습니다. 진단 결과가 필요하다고 판단할 때만 설치를 안내합니다."))
                                .foregroundStyle(palette.secondaryText)
                        } else {
                            ForEach(runtimes) { runtime in
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(runtimeTitleText(runtime.runtime))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 12)
                                        Text(runtimeStatusText(runtime.status))
                                            .foregroundStyle(palette.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(runtimeTitleText(runtime.runtime))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(runtimeStatusText(runtime.status))
                                            .foregroundStyle(palette.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }

            }
            .frame(maxWidth: ForgePlayLayout.pageMaximumWidth, alignment: .leading)
        }
    }

    private func advancedHeader(palette: ForgePlayPalette) -> some View {
        ForgePageHeader(
            "고급 정보",
            subtitle: "초보자 화면에서 숨긴 경로와 기술 상태입니다. 문제 해결이나 개발자 서명/배포 확인에 사용합니다.",
            systemImage: "wrench.and.screwdriver.fill"
        ) {
            SectionHelpButton(section: .advanced)
        }
    }

    private func pathRow(_ title: String, _ url: URL?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                pathRowTitle(title)
                    .frame(
                        minWidth: pathRowTitleMinimumWidth,
                        idealWidth: pathRowTitleIdealWidth,
                        maxWidth: pathRowTitleMaximumWidth,
                        alignment: .leading
                    )
                    .layoutPriority(1)
                pathRowValue(url)
                    .layoutPriority(2)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                pathRowTitle(title)
                pathRowValue(url)
            }
        }
    }

    private func pathRowTitle(_ title: String) -> some View {
        Text(appState.localized(title))
            .font(.subheadline.weight(.semibold))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pathRowValue(_ url: URL?) -> some View {
        AdaptiveValueText(
            text: url?.path ?? appState.localized("미설정"),
            font: .system(.caption, design: .monospaced),
            color: palette.secondaryText
        )
    }

    private func runtimeStatusText(_ status: String) -> String {
        if let installationStatus = RuntimeInstallationStatus(rawValue: status) {
            return appState.localized(installationStatus.label)
        }
        return appState.localizedFormat("알 수 없는 Runtime 상태: %@", status)
    }

    private func runtimeTitleText(_ runtime: String) -> String {
        if let runtimeId = RuntimeId(rawValue: runtime) {
            return runtimeId.localizedTitle(appState: appState)
        }
        return appState.localizedFormat("알 수 없는 Runtime: %@", runtime)
    }

    private func prefixDetailText(_ prefix: PrefixRecord) -> String {
        [
            prefixModeText(prefix.mode),
            windowsCompatibilityVersionText(prefix.windowsVersion),
            prefix.path
        ].joined(separator: " · ")
    }

    private func prefixModeText(_ mode: String) -> String {
        if let prefixMode = PrefixMode(rawValue: mode) {
            return appState.localized(prefixMode.beginnerName)
        }
        return appState.localizedFormat("알 수 없는 프리픽스 모드: %@", mode)
    }

    private func windowsCompatibilityVersionText(_ version: String) -> String {
        if let compatibilityVersion = WindowsCompatibilityVersion(rawValue: version) {
            return appState.localized(compatibilityVersion.label)
        }
        return appState.localizedFormat("알 수 없는 Windows 버전: %@", version)
    }
}
