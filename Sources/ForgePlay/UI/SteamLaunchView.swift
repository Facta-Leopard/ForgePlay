// This file contains separately licensed ForgePlay Game Mode code.
// The exact GPL-3.0-only declarations are listed in
// LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md.
// This notice does not apply GPL-3.0-only to unrelated code in this file.

import SwiftData
import SwiftUI

private enum SteamWorkspace: String, CaseIterable, Identifiable {
    case launch
    case storage
    case components

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launch: "실행 및 그래픽"
        case .storage: "저장공간"
        case .components: "구성요소"
        }
    }

    var symbolName: String {
        switch self {
        case .launch: "play.circle"
        case .storage: "externaldrive"
        case .components: "puzzlepiece.extension"
        }
    }
}

private struct ActiveSteamSessionConfiguration {
    let rendererSelection: SteamRendererPolicySelection
    let gameModePolicy: SteamGameModeLaunchPolicy
}

struct SteamLaunchView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \SteamStorageMountRecord.path) private var steamStorageMounts: [SteamStorageMountRecord]
    @Query(sort: \PrefixRecord.displayName) private var prefixes: [PrefixRecord]
    @Query(sort: \LaunchRecord.startedAt, order: .reverse) private var launchRecords: [LaunchRecord]
    @State private var steamReferencePendingRemoval: SteamGameRecord?
    @State private var steamStoragePendingRemoval: SteamStorageMountRecord?
    @State private var isShowingSteamPrefixRebuildConfirmation = false
    @State private var isRebuildingSteamPrefix = false
    @State private var steamInstallerPersistenceWarningForRebuild: String?
    @State private var selectedWorkspace: SteamWorkspace = .launch
    @State private var selectedRendererForNextSteamLaunch: SteamRendererPolicySelection?
    @State private var activeSteamSessionConfiguration: ActiveSteamSessionConfiguration?
    @State private var isExperimentalGameModeEnabledForNextLaunch = false
    @State private var steamStorageHealthReports: [String: SteamStorageHealthReport] = [:]
    @State private var steamStorageHealthErrorMessage: String?
    @State private var steamStorageHealthRefreshGeneration = 0
    @State private var isCheckingSteamStorageHealth = false
    let helpSection: AppSection

    private var readiness: SetupReadiness {
        appState.setupReadiness
    }

    init(helpSection: AppSection = .steamLaunch) {
        self.helpSection = helpSection
    }

    private var displayedSteamReferences: [SteamGameRecord] {
        #if DEBUG
        if appState.debugAppStoreScreenshotFixture {
            let persistedAppIds = Set(games.map(\.steamAppId))
            return SteamGameRecord.debugAppStoreScreenshotFixtureRecords()
                .filter { !persistedAppIds.contains($0.steamAppId) } + games
        }
        if appState.debugSteamLaunchLayoutFixture {
            let persistedAppIds = Set(games.map(\.steamAppId))
            return SteamGameRecord.debugLayoutFixtureRecords()
                .filter { !persistedAppIds.contains($0.steamAppId) } + games
        }
        #endif
        return games
    }

    private var displayedSteamStorageMounts: [SteamStorageMountRecord] {
        var seenPaths = Set<String>()
        return steamStorageMounts.filter { mount in
            seenPaths.insert(mount.url.path).inserted
        }
    }

    private var steamStorageHealthTaskID: String {
        let mountsFingerprint = displayedSteamStorageMounts.map { mount in
            [
                mount.id,
                mount.url.path,
                String(mount.updatedAt.timeIntervalSinceReferenceDate),
                String(mount.bookmark?.hashValue ?? 0)
            ].joined(separator: "|")
        }.joined(separator: ";")
        return [
            selectedWorkspace.rawValue,
            String(steamStorageHealthRefreshGeneration),
            mountsFingerprint
        ].joined(separator: "#")
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgePageScaffold(
            "Steam 실행",
            subtitle: "Windows용 Steam 실행, 게임 그래픽, 저장공간을 한곳에서 관리합니다.",
            systemImage: "play.circle.fill"
        ) {
            SectionHelpButton(section: helpSection)
        } content: {
            steamWorkspacePicker(palette: palette)
            steamWorkspaceContent(palette: palette)
        }
        .task {
            refreshSetupReadiness()
            if appState.setupStage == .connectLibrary {
                selectedWorkspace = .storage
            }
        }
        .task(id: steamStorageHealthTaskID) {
            guard selectedWorkspace == .storage else {
                isCheckingSteamStorageHealth = false
                return
            }
            await refreshSteamStorageHealth(taskID: steamStorageHealthTaskID)
        }
        .onChange(of: games.count) { _, _ in
            refreshSetupReadiness()
        }
        .onChange(of: SteamLaunchRecordLookup.stateFingerprint(from: launchRecords)) { _, _ in
            refreshSetupReadiness()
        }
        .onChange(of: services.steamEnvironmentRevision) { _, _ in
            refreshSetupReadiness()
        }
        .confirmationDialog(
            appState.localizedFormat("%@을 목록에서 제거할까요?", steamReferencePendingRemoval?.name ?? ""),
            isPresented: Binding(
                get: { steamReferencePendingRemoval != nil },
                set: { isPresented in
                    if !isPresented { steamReferencePendingRemoval = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(appState.localized("목록에서 제거"), role: .destructive) {
                if let game = steamReferencePendingRemoval {
                    removeSteamReferenceRecord(game)
                }
                steamReferencePendingRemoval = nil
            }
            Button(appState.localized("취소"), role: .cancel) {
                steamReferencePendingRemoval = nil
            }
        } message: {
            Text(appState.localized("ForgePlay의 참고 목록 기록만 제거합니다. 실제 Steam 게임 파일, Steam 프리픽스, 실행 기록, 진단 기록은 삭제하지 않습니다."))
        }
        .confirmationDialog(
            appState.localized("이 Steam 저장공간 연결을 해제할까요?"),
            isPresented: Binding(
                get: { steamStoragePendingRemoval != nil },
                set: { isPresented in
                    if !isPresented { steamStoragePendingRemoval = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(appState.localized("연결 해제"), role: .destructive) {
                if let mount = steamStoragePendingRemoval {
                    removeSteamStorageMount(mount)
                }
                steamStoragePendingRemoval = nil
            }
            Button(appState.localized("취소"), role: .cancel) {
                steamStoragePendingRemoval = nil
            }
        } message: {
            Text(appState.localized("ForgePlay의 macOS 접근 권한과 Wine 드라이브 연결, ForgePlay가 자동 추가한 Steam 등록만 제거합니다. 외장 저장공간의 실제 파일은 삭제하지 않습니다. 실행 중인 Steam에는 다음 실행부터 반영됩니다."))
        }
        .confirmationDialog(
            appState.localized("Steam 프리픽스를 삭제하고 다시 만들까요?"),
            isPresented: $isShowingSteamPrefixRebuildConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("삭제 후 재생성"), role: .destructive) {
                rebuildSteamPrefixAndInstallSteam()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localized("현재 Windows용 Steam 프리픽스를 완전히 새로 만들고 선택된 SteamSetup.exe를 다시 설치합니다. 이 작업은 Windows Steam 로그인 상태와 프리픽스 내부 사용자 데이터를 지우지만 외장 Steam 라이브러리 파일은 삭제하지 않습니다."))
        }
    }

    private func steamWorkspacePicker(palette: ForgePlayPalette) -> some View {
        Picker(
            appState.localized("Steam 작업"),
            selection: $selectedWorkspace
        ) {
            ForEach(SteamWorkspace.allCases) { workspace in
                Label(appState.localized(workspace.title), systemImage: workspace.symbolName)
                    .tag(workspace)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 620, alignment: .leading)
        .tint(palette.primary)
        .accessibilityLabel(appState.localized("Steam 작업"))
    }

    @ViewBuilder
    private func steamWorkspaceContent(palette: ForgePlayPalette) -> some View {
        switch selectedWorkspace {
        case .launch:
            VStack(alignment: .leading, spacing: ForgePlayLayout.sectionSpacing) {
                steamLaunchPanel(palette: palette)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .storage:
            libraryManagementPanel(palette: palette)
            steamReferenceRecordsPanel(palette: palette)
        case .components:
            RuntimeDependencyWorkflowCard()
        }
    }

    private func steamLaunchPanel(palette: ForgePlayPalette) -> some View {
        ForgeCard("백엔드 선택 후 실행", systemImage: "play.circle.fill", emphasis: .accent) {
            VStack(alignment: .leading, spacing: 10) {
                manualRendererSelectionGrid(palette: palette)
                experimentalGameModeControl(palette: palette)

                ResponsiveActionRow {
                    ThemedActionButton(
                        title: "선택한 백엔드로 Steam 실행",
                        systemImage: "play.fill",
                        prominence: .primary,
                        isDisabled: selectedRendererForNextSteamLaunch == nil ||
                            appState.isSteamLaunchInProgress ||
                            appState.steamStorageOperationMountID != nil ||
                            services.steamPrefixLifecycleCoordinator.isBusy ||
                            steamLaunchBlocker != nil ||
                            selectedRendererLaunchBlocker != nil
                    ) {
                        launchSteam(
                            rendererPolicySelection: selectedRendererForNextSteamLaunch,
                            gameModePolicy: isExperimentalGameModeEnabledForNextLaunch
                                ? .experimentalRequiredHost
                                : .standard
                        )
                    }
                    ThemedActionButton(
                        title: "저장공간 관리",
                        systemImage: "externaldrive",
                        prominence: .secondary
                    ) {
                        selectedWorkspace = .storage
                    }
                }
                .frame(maxWidth: .infinity)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        StatusBadge(label: steamLaunchStatusLabel, status: steamLaunchStatus)
                        Text(steamLaunchDetailText)
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        StatusBadge(label: steamLaunchStatusLabel, status: steamLaunchStatus)
                        Text(steamLaunchDetailText)
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let selectedRendererForNextSteamLaunch {
                    Text(appState.localizedFormat(
                        "이번 실행: %@ 단일 백엔드 · Game Mode %@",
                        appState.localized(selectedRendererForNextSteamLaunch.labelKey),
                        gameModeStateLabel(
                            isEnabled: isExperimentalGameModeEnabledForNextLaunch
                        )
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        selectedRendererLaunchBlocker == nil
                            ? palette.success
                            : palette.warning
                    )
                } else if let activeSteamSessionConfiguration {
                    Text(appState.localizedFormat(
                        "현재 Steam 세션: %@ 단일 백엔드 · Game Mode %@ · 다음 Steam 실행에서는 다시 선택해야 합니다.",
                        appState.localized(
                            activeSteamSessionConfiguration.rendererSelection.labelKey
                        ),
                        gameModeStateLabel(
                            isEnabled: activeSteamSessionConfiguration.gameModePolicy ==
                                .experimentalRequiredHost
                        )
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.success)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(appState.localized("백엔드를 선택하기 전에는 Steam을 실행할 수 없습니다. 선택은 자동 저장하거나 자동 변경하지 않습니다."))
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let blocker = selectedRendererLaunchBlocker {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SteamLaunchRecordStatusPanel(
                    record: latestSteamLaunchRecord,
                    onConfirmSurface: confirmSteamUISurface,
                    onMarkBlackScreen: markSteamUIBlackScreen
                )

                steamSessionStatusRow(palette: palette)

                Divider()

                steamEnvironmentMaintenanceRow(palette: palette)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.localized("ForgePlay는 개별 게임을 직접 실행하지 않습니다. Windows용 Steam을 먼저 열고, 열린 Steam 창의 라이브러리에서 사용자가 직접 게임을 실행합니다."))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appState.localized("외장 저장공간은 Steam 실행 직전에 Windows 드라이브로 연결하며, 실제 steamapps 폴더가 있는 라이브러리를 Windows용 Steam에 자동 등록합니다."))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func manualRendererSelectionGrid(
        palette: ForgePlayPalette
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 145, maximum: 240), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(SteamRendererPolicySelection.allCases) { selection in
                let isSelected = selectedRendererForNextSteamLaunch == selection
                let compactLabelKey =
                    selection.forcedPreference?.labelKey ?? selection.labelKey
                Button {
                    selectedRendererForNextSteamLaunch = selection
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isSelected ? palette.primary : palette.secondaryText)
                        Text(appState.localized(compactLabelKey))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isSelected ? palette.primary.opacity(0.10) : palette.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius)
                            .stroke(
                                isSelected ? palette.primary : palette.border,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .clipShape(
                        RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius)
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    appState.isSteamLaunchInProgress ||
                        services.steamPrefixLifecycleCoordinator.isBusy
                )
                .help(appState.localized(selection.detailKey))
                .accessibilityLabel(
                    appState.localizedFormat(
                        "%@ 선택",
                        appState.localized(compactLabelKey)
                    )
                )
                .accessibilityHint(appState.localized(selection.detailKey))
            }
        }
    }

    private func experimentalGameModeControl(
        palette: ForgePlayPalette
    ) -> some View {
        Toggle(isOn: $isExperimentalGameModeEnabledForNextLaunch) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localized("Game Mode (베타)"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(appState.localized(
                    "게임 프로세스를 Game Mode 호스트로 실행합니다. 기본값은 끔이며, 실패하면 게임 실행도 중단됩니다."
                ))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(palette.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
        .help(appState.localized(
            "기본값은 끔입니다. 켜면 이번 Steam 세션에서 Steam이 시작한 게임 프로세스를 동일 프로세스 Game Mode 호스트로 실행합니다. Steam 실행 후 토글은 다음 세션용으로 초기화되며, 현재 세션 상태는 아래에 계속 표시됩니다. 호스트 적용에 실패하면 해당 게임 실행도 중단됩니다."
        ))
        .accessibilityHint(appState.localized(
            "기본값은 끔입니다. 켜면 이번 Steam 세션에서 Steam이 시작한 게임 프로세스를 동일 프로세스 Game Mode 호스트로 실행합니다. Steam 실행 후 토글은 다음 세션용으로 초기화되며, 현재 세션 상태는 아래에 계속 표시됩니다. 호스트 적용에 실패하면 해당 게임 실행도 중단됩니다."
        ))
    }

    private func gameModeStateLabel(isEnabled: Bool) -> String {
        appState.localized(isEnabled ? "켬" : "끔")
    }

    private func steamEnvironmentMaintenanceRow(palette: ForgePlayPalette) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                steamEnvironmentMaintenanceText(palette: palette)
                Spacer(minLength: 16)
                steamEnvironmentRebuildButton
            }
            VStack(alignment: .leading, spacing: 10) {
                steamEnvironmentMaintenanceText(palette: palette)
                steamEnvironmentRebuildButton
                    .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    private func steamEnvironmentMaintenanceText(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.localized("Steam 프리픽스 재생성"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            Text(appState.localized(
                steamPrefixRebuildBlocker ??
                    "Steam 프리픽스 검증에서 레지스트리나 필수 파일 손상이 확인된 경우에만 프리픽스를 재생성합니다."
            ))
                .font(.caption)
                .foregroundStyle(steamPrefixRebuildBlocker == nil ? palette.secondaryText : palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steamEnvironmentRebuildButton: some View {
        ThemedActionButton(
            title: "Steam 프리픽스 재생성",
            systemImage: "arrow.triangle.2.circlepath",
            prominence: .secondary,
            isDisabled: isRebuildingSteamPrefix ||
                services.steamPrefixLifecycleCoordinator.isBusy ||
                steamPrefixRebuildBlocker != nil,
            controlSize: .small
        ) {
            requestSteamPrefixRebuild()
        }
        .frame(minWidth: 150, idealWidth: 180, maxWidth: 220)
    }

    private func steamSessionStatusRow(palette: ForgePlayPalette) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                StatusBadge(label: steamSessionStatusLabel, status: steamSessionStatus)
                Text(steamSessionDetailText)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(label: steamSessionStatusLabel, status: steamSessionStatus)
                Text(steamSessionDetailText)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func libraryManagementPanel(palette: ForgePlayPalette) -> some View {
        ForgeCard("Steam 저장공간 연결", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                Text(appState.localized("macOS 폴더를 연결해 ForgePlay에 접근 권한을 부여하세요. 다음 Steam 실행 때 ForgePlay가 실제 steamapps 폴더를 찾아 아래 Windows 경로로 자동 연결합니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !displayedSteamStorageMounts.isEmpty {
                    SteamStorageHealthSummaryView(
                        mountCount: displayedSteamStorageMounts.count,
                        reports: displayedSteamStorageMounts.compactMap {
                            steamStorageHealthReports[$0.id]
                        },
                        isChecking: isCheckingSteamStorageHealth,
                        errorMessage: steamStorageHealthErrorMessage,
                        isRefreshDisabled: appState.steamStorageOperationMountID != nil ||
                            services.isSteamReferenceRefreshInProgress ||
                            services.steamPrefixLifecycleCoordinator.isBusy,
                        onRefresh: requestSteamStorageHealthRefresh
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    LibraryActionButton(
                        title: "외장 드라이브/폴더 연결",
                        detail: "외장 드라이브의 루트 또는 SteamLibrary 폴더를 선택합니다. 실제 steamapps 라이브러리를 전용 Windows 경로로 자동 연결하며 파일은 복사하지 않습니다.",
                        systemImage: "externaldrive.badge.plus",
                        isDisabled: services.isSteamReferenceRefreshInProgress ||
                            services.steamPrefixLifecycleCoordinator.isBusy ||
                            appState.steamStorageOperationMountID != nil
                    ) {
                        chooseAndLinkLibrary()
                    }
                    LibraryActionButton(
                        title: steamReferenceRefreshActionTitleKey,
                        detail: "Steam 프리픽스와 연결된 라이브러리의 appmanifest 파일을 다시 읽습니다.",
                        systemImage: "arrow.clockwise",
                        isDisabled: services.isSteamReferenceRefreshInProgress ||
                            services.steamPrefixLifecycleCoordinator.isBusy ||
                            appState.steamStorageOperationMountID != nil
                    ) {
                        refreshSteamReferences(extraRoots: [])
                    }
                }

                if displayedSteamStorageMounts.isEmpty {
                    Text(appState.localized("Windows용 Steam 안에서 폴더를 선택하는 것만으로는 macOS 접근 권한이 생기지 않습니다. 먼저 위 버튼으로 외장 드라이브나 SteamLibrary 폴더를 연결하세요."))
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(displayedSteamStorageMounts) { mount in
                            steamStorageMountRow(mount, palette: palette)
                            if mount.id != displayedSteamStorageMounts.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func steamStorageMountRow(
        _ mount: SteamStorageMountRecord,
        palette: ForgePlayPalette
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                steamStorageMountDetails(mount, palette: palette)
                Spacer(minLength: 12)
                steamStorageMountActions(mount)
            }
            VStack(alignment: .leading, spacing: 10) {
                steamStorageMountDetails(mount, palette: palette)
                steamStorageMountActions(mount)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func steamStorageMountDetails(
        _ mount: SteamStorageMountRecord,
        palette: ForgePlayPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mount.url.lastPathComponent)
                .font(.headline)
                .foregroundStyle(palette.text)
            AdaptivePathText(
                path: mount.path,
                font: .caption,
                color: palette.secondaryText,
                isTextSelectionEnabled: false
            )
            Text(mappedWindowsStoragePath(for: mount))
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(palette.primary)
                .textSelection(.enabled)
            SteamStorageHealthStatusView(
                report: steamStorageHealthReports[mount.id],
                isChecking: isCheckingSteamStorageHealth
            )
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func steamStorageMountActions(_ mount: SteamStorageMountRecord) -> some View {
        ResponsiveActionRow(spacing: 8) {
            if steamStorageHealthReports[mount.id]?.requiresReconnect == true {
                ThemedActionButton(
                    title: "원래 폴더 다시 선택",
                    systemImage: "arrow.triangle.2.circlepath",
                    prominence: .secondary,
                    isDisabled: appState.steamStorageOperationMountID != nil ||
                        services.isSteamReferenceRefreshInProgress ||
                        services.steamPrefixLifecycleCoordinator.isBusy,
                    controlSize: .small
                ) {
                    chooseAndReconnectSteamStorageMount(mount)
                }
                .frame(minWidth: 154, idealWidth: 180, maxWidth: 220)
                .accessibilityLabel(
                    "\(mount.url.lastPathComponent), \(appState.localized("원래 폴더 다시 선택"))"
                )
                .accessibilityHint(appState.localized("원래 폴더를 다시 선택합니다."))
            }
            steamStorageRemoveButton(mount)
        }
    }

    private func steamStorageRemoveButton(_ mount: SteamStorageMountRecord) -> some View {
        ThemedActionButton(
            title: "연결 해제",
            systemImage: "eject",
            prominence: .secondary,
            isDisabled: services.isSteamReferenceRefreshInProgress ||
                appState.steamStorageOperationMountID != nil,
            controlSize: .small
        ) {
            steamStoragePendingRemoval = mount
        }
        .frame(minWidth: 110, idealWidth: 124, maxWidth: 160)
        .accessibilityLabel(
            "\(mount.url.lastPathComponent), \(appState.localized("연결 해제"))"
        )
    }

    private func mappedWindowsStoragePath(for mount: SteamStorageMountRecord) -> String {
        guard let prefix = readiness.steamPrefixURL else {
            return appState.localized("다음 Steam 실행 시 Windows 경로가 배정됩니다")
        }
        let mappedPaths = services.steamManager
            .normalizedLibraryRoots(for: mount.url)
            .compactMap {
                SteamManager.mappedWindowsLibraryPath(for: $0, prefix: prefix)
            }
        return mappedPaths.isEmpty
            ? appState.localized("다음 Steam 실행 시 Windows 경로가 배정됩니다")
            : mappedPaths.joined(separator: ", ")
    }

    private func steamReferenceRecordsPanel(palette: ForgePlayPalette) -> some View {
        let referenceRecords = displayedSteamReferences

        return ForgeCard("Steam 라이브러리 참고 목록", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                Text(appState.localized("이 목록은 Steam 라이브러리 연결과 진단 참고용입니다. ForgePlay는 여기서 게임을 직접 실행하지 않고 Windows용 Steam만 실행합니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if referenceRecords.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "Steam 참고 기록이 비어 있습니다",
                        message: "Windows용 Steam에서 게임을 설치한 뒤 Steam 참고 목록을 새로고침하거나, 기존 Steam 라이브러리를 연결하세요.",
                        fillsAvailableHeight: false
                    )
                    .frame(minHeight: 220)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(referenceRecords) { game in
                            steamReferenceRecordRow(game, palette: palette)
                        }
                    }
                }
            }
        }
    }

    private func steamReferenceRecordRow(_ game: SteamGameRecord, palette: ForgePlayPalette) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                steamReferenceRecordIcon(palette: palette)
                steamReferenceRecordDetails(game, palette: palette)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                steamReferenceRemoveButton(game)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    steamReferenceRecordIcon(palette: palette)
                    steamReferenceRecordDetails(game, palette: palette)
                        .layoutPriority(1)
                }
                steamReferenceRemoveButton(game)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .padding(12)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func steamReferenceRecordIcon(palette: ForgePlayPalette) -> some View {
        Image(systemName: "play.square.stack")
            .font(.title3)
            .foregroundStyle(palette.primary)
            .frame(width: 28)
            .padding(.top, 2)
    }

    private func steamReferenceRecordDetails(_ game: SteamGameRecord, palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(game.name)
                .font(.headline)
                .foregroundStyle(palette.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localizedFormat(
                "Steam App ID: %@ · %@",
                game.steamAppId,
                appState.localizedByteCount(game.sizeOnDisk)
            ))
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            AdaptivePathText(
                path: game.libraryPath,
                font: .caption,
                color: palette.secondaryText,
                isTextSelectionEnabled: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func steamReferenceRemoveButton(_ game: SteamGameRecord) -> some View {
        ThemedActionButton(
            title: "목록에서 제거",
            systemImage: "trash",
            prominence: .secondary,
            controlSize: .small
        ) {
            steamReferencePendingRemoval = game
        }
        .frame(minWidth: 118, idealWidth: 132, maxWidth: 170)
    }

    private var steamLaunchStatusLabel: String {
        if steamLaunchBlocker != nil { return appState.localized("Steam 실행 차단") }
        if let latestSteamLaunchRecord {
            switch latestSteamLaunchRecord.steamUIVerificationState {
            case .blackScreenSuspected:
                return appState.localized("Steam 검은 화면 의심")
            case .failed:
                return appState.localized("Steam 실행 실패")
            case .launchedButUnverified:
                let label = latestSteamLaunchRecord.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode
                    ? "Steam 명령 전달됨 · 수동 확인 필요"
                    : "Steam 프로세스 시작됨"
                return appState.localized(label)
            case .notRun:
                return appState.localized("Steam 실행 중")
            case .rendered:
                return appState.localized(steamSurfaceStatusLabel(for: latestSteamLaunchRecord))
            }
        }
        if let rendererInspection = readiness.rendererInspection,
           rendererInspection.status != .ok {
            return appState.localized(rendererInspection.recoveryStatusLabelKey)
        }
        return appState.localized(
            readiness.steamPrefixState == .launchReady ? "Steam 로그인 필요" : "Steam 상태 확인 필요"
        )
    }

    private var steamLaunchStatus: CheckStatus {
        if steamLaunchBlocker != nil { return .warning }
        if let latestSteamLaunchRecord {
            switch latestSteamLaunchRecord.steamUIVerificationState {
            case .rendered:
                return latestSteamLaunchRecord.steamUISurface == .library ? .ok : .warning
            case .blackScreenSuspected, .failed:
                return .error
            case .launchedButUnverified:
                return .warning
            case .notRun:
                return .unknown
            }
        }
        if let rendererInspection = readiness.rendererInspection {
            return rendererInspection.status
        }
        return .warning
    }

    private var steamLaunchDetailText: String {
        if let blocker = steamLaunchBlocker {
            return blocker
        }
        if let rendererInspection = readiness.rendererInspection,
           rendererInspection.status != .ok {
            return appState.localized(rendererInspection.userMessage)
        }
        if let steamExecutable = readiness.steamExecutableURL {
            return appState.localizedFormat("Windows용 Steam을 실행합니다. 설치 위치: %@", steamExecutable.path)
        }
        return appState.localized("Windows용 Steam 설치와 Steam 프리픽스가 준비되면 이 버튼으로 Steam 클라이언트만 실행합니다.")
    }

    private func steamSurfaceStatusLabel(for record: LaunchRecord) -> String {
        switch record.steamUISurface {
        case .some(.signIn): "Steam 로그인 화면 확인됨"
        case .some(.steamGuard): "Steam Guard 화면 확인됨"
        case .some(.library): "Steam 라이브러리 확인됨"
        case .some(.unknown), .none: "Steam 화면 확인됨"
        }
    }

    private var latestSteamLaunchRecord: LaunchRecord? {
        SteamLaunchRecordLookup.latestSteamLaunchRecord(
            from: launchRecords,
            environmentGenerationID: readiness.steamEnvironmentGenerationID,
            environmentCreatedAt: readiness.steamEnvironmentCreatedAt,
            currentAppSessionID: services.appSessionID
        )
    }

    private var steamSessionStatusLabel: String {
        if readiness.steamUISurface == .steamGuard {
            return appState.localized("Steam Guard 진행 중")
        }
        if readiness.steamUISurface == .signIn {
            return appState.localized("Steam 로그인 필요")
        }
        if readiness.hasVerifiedSessionPersistence {
            return appState.localized("로그인 세션 유지 확인됨")
        }
        if readiness.hasVerifiedAuthenticatedLibrary {
            return appState.localized("Steam 라이브러리 확인됨")
        }
        if readiness.hasDetectedSteamAccountSession {
            return appState.localized("로그인 정보 감지됨")
        }
        if readiness.steamSessionInspection.state == .noAccountData {
            return appState.localized("Steam 로그인 필요")
        }
        return switch readiness.steamSessionInspection.state {
        case .accountDataPresent, .rememberedSignInConfigured:
            appState.localized("로그인 정보 감지됨")
        case .invalid:
            appState.localized("로그인 상태 확인 오류")
        case .unavailable:
            appState.localized("로그인 상태 미확인")
        case .noAccountData:
            appState.localized("Steam 로그인 필요")
        }
    }

    private var steamSessionStatus: CheckStatus {
        if readiness.currentSteamSurfaceRequiresAuthentication {
            return .warning
        }
        if readiness.hasUsableAuthenticatedSteamSession || readiness.hasDetectedSteamAccountSession {
            return .ok
        }
        if readiness.steamSessionInspection.state == .invalid {
            return .error
        }
        return .warning
    }

    private var steamSessionDetailText: String {
        if readiness.steamUISurface == .steamGuard {
            return appState.localized("Steam Guard 인증을 완료한 뒤 열린 라이브러리 화면을 기록하세요.")
        }
        if readiness.steamUISurface == .signIn {
            return appState.localized("Windows Steam 로그인 화면이 정상 표시됐습니다. Steam 창에서 직접 로그인한 뒤 라이브러리 화면을 기록하세요.")
        }
        if readiness.hasVerifiedSessionPersistence {
            return appState.localized("같은 Steam 프리픽스에서 앱을 다시 실행한 뒤 라이브러리 화면이 다시 확인됐습니다.")
        }
        if readiness.hasVerifiedAuthenticatedLibrary {
            return appState.localized("인증 후 Steam 라이브러리 화면이 확인됐습니다. 앱을 종료했다가 다시 실행해 라이브러리가 유지되는지 한 번 더 확인하세요.")
        }
        switch readiness.steamSessionInspection.state {
        case .rememberedSignInConfigured:
            return appState.localized("Steam 프리픽스에 로그인 기억 설정이 있지만 실제 세션 유지는 아직 확인되지 않았습니다. Steam을 실행해 라이브러리를 확인하세요.")
        case .accountDataPresent:
            return appState.localized("Steam 프리픽스에 로컬 계정 데이터가 있지만 인증 세션이 유효한지는 확인되지 않았습니다. Steam을 실행해 라이브러리를 확인하세요.")
        case .noAccountData:
            return appState.localized("이 Steam 프리픽스에는 아직 로컬 계정 데이터가 없습니다. Windows Steam에서 직접 로그인하세요.")
        case .invalid:
            return appState.localizedFormat(
                "Steam 로그인 상태 파일을 안전하게 읽지 못했습니다: %@",
                readiness.steamSessionInspection.issue ?? appState.localized("원인 미확인")
            )
        case .unavailable:
            return appState.localized("Windows용 Steam을 설치하고 실행하면 로그인 상태를 확인할 수 있습니다.")
        }
    }

    private var steamReferenceRefreshActionTitleKey: String {
        services.isSteamReferenceRefreshInProgress ? "참고 목록 찾는 중" : "Steam 참고 목록 새로고침"
    }

    private var canRunBundledWindowsRuntime: Bool {
        #if DEBUG
        if appState.debugAppStoreScreenshotFixture {
            return true
        }
        #endif
        return ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReason: String? {
        canRunBundledWindowsRuntime
            ? nil
            : appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    private var steamLaunchBlocker: String? {
        #if DEBUG
        if appState.debugAppStoreScreenshotFixture {
            return nil
        }
        #endif
        if let bundledRuntimeUnavailableReason {
            return bundledRuntimeUnavailableReason
        }
        if let issue = readiness.rootIssue {
            return appState.localizedError(issue)
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            return appState.localized("ForgePlay Runtime을 먼저 확인하세요.")
        }
        do {
            let verification = try services.steamPrefixService.inspectSteamClientCompatibility(runtimeExecutable)
            guard verification.canLaunchWindowsSteam else {
                return appState.localized(verification.userMessage)
            }
        } catch {
            return appState.localizedError(error)
        }
        if let issue = readiness.steamPrefixIssue {
            return appState.localizedError(issue)
        }
        guard readiness.hasSteamPrefix else {
            return appState.localized("Steam 프리픽스를 먼저 만들어야 합니다.")
        }
        guard readiness.hasSteamExecutable else {
            return appState.localized("Windows용 Steam을 먼저 설치하세요.")
        }
        guard readiness.canAttemptWindowsSteamLaunch else {
            return readiness.localizedSteamPrefixStateBlocker(appState: appState)
        }
        return nil
    }

    private var selectedRendererLaunchBlocker: String? {
        guard let selection = selectedRendererForNextSteamLaunch,
              let renderer = selection.forcedPreference,
              let runtimeExecutable = appState.runtimeExecutableURL else {
            return nil
        }
        do {
            let capability = try services.windowsRuntimeService.inspectRuntimeCapability(
                executable: runtimeExecutable
            )
            guard renderer.isSatisfied(by: capability) else {
                return appState.localizedFormat(
                    "%@ 단일 백엔드 파일이 완전하지 않아 이번 Steam 실행을 시작할 수 없습니다. 다른 백엔드를 선택하거나 ForgePlay Runtime을 다시 설치하세요.",
                    appState.localized(selection.labelKey)
                )
            }
            return nil
        } catch {
            return appState.localizedError(error)
        }
    }

    private var steamPrefixRebuildBlocker: String? {
        #if DEBUG
        if appState.debugAppStoreScreenshotFixture {
            return nil
        }
        #endif
        if let bundledRuntimeUnavailableReason {
            return bundledRuntimeUnavailableReason
        }
        if let issue = readiness.rootIssue {
            return appState.localizedError(issue)
        }
        guard appState.runtimeExecutableURL != nil else {
            return appState.localized("ForgePlay Runtime을 먼저 확인하세요.")
        }
        return nil
    }

    private func chooseAndLinkLibrary() {
        guard !services.isSteamReferenceRefreshInProgress else {
            appState.setNotice(appState.localized("Steam 참고 목록 새로고침이 이미 진행 중입니다."), kind: .warning)
            return
        }
        guard let url = OpenPanelPresenter.chooseDirectory(
            title: appState.localized("외장 드라이브 또는 폴더 선택"),
            message: appState.localized("외장 드라이브의 최상위 폴더나 SteamLibrary 폴더를 선택하세요. ForgePlay가 실제 steamapps 폴더를 찾아 다음 Steam 실행 때 자동 연결합니다."),
            prompt: appState.localized("드라이브 연결"),
            initialDirectory: URL(fileURLWithPath: "/Volumes", isDirectory: true)
        ) else { return }
        beginSteamStorageConnectionOperation(id: "new:\(UUID().uuidString)") {
            guard let authorization = await appState.authorizeSteamStorageSelection(url) else {
                return
            }
            do {
                let didRetainAccess = try appState.connectSteamStorageMount(
                    authorization,
                    in: modelContext
                )
                if didRetainAccess {
                    appState.setNotice(
                        appState.localized("외장 드라이브를 연결했습니다. 다음 Steam 실행 때 기존 Steam 라이브러리를 자동으로 인식하도록 등록합니다."),
                        kind: .success
                    )
                } else {
                    appState.setNotice(
                        appState.localized("저장공간 연결은 저장했지만 현재 세션의 접근 권한을 유지하지 못했습니다. 다시 연결하거나 앱을 다시 시작하세요."),
                        kind: .warning
                    )
                }
                steamStorageHealthRefreshGeneration += 1
            } catch {
                appState.setError(error)
            }
        }
    }

    private func chooseAndReconnectSteamStorageMount(_ mount: SteamStorageMountRecord) {
        guard let selected = OpenPanelPresenter.chooseDirectory(
            title: appState.localized("Steam 저장공간 다시 연결"),
            message: appState.localized("이전에 연결한 폴더를 선택하세요. 다른 폴더를 선택하면 이 연결 위치가 바뀝니다."),
            prompt: appState.localized("다시 연결"),
            initialDirectory: nearestExistingDirectory(for: mount.url),
            canCreateDirectories: false
        ) else { return }

        beginSteamStorageConnectionOperation(id: mount.id) {
            guard let authorization = await appState.authorizeSteamStorageSelection(selected) else {
                return
            }
            do {
                let didRetainAccess = try appState.reconnectSteamStorageMount(
                    mount,
                    to: authorization,
                    in: modelContext
                )
                if didRetainAccess {
                    appState.setNotice(
                        appState.localized("Steam 저장공간을 다시 연결했습니다. 필요하면 Steam 참고 목록을 새로고침하세요."),
                        kind: .success
                    )
                } else {
                    appState.setNotice(
                        appState.localized("저장공간 연결은 저장했지만 현재 세션의 접근 권한을 유지하지 못했습니다. 다시 연결하거나 앱을 다시 시작하세요."),
                        kind: .warning
                    )
                }
                steamStorageHealthRefreshGeneration += 1
            } catch {
                appState.setError(error)
            }
        }
    }

    private func beginSteamStorageConnectionOperation(
        id: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard appState.beginSteamStorageConnectionOperation(
            id: id,
            operation: operation
        ) else {
            appState.setNotice(
                appState.localized("Steam 저장공간 연결 작업이 진행 중입니다. 완료된 뒤 다시 시도하세요."),
                kind: .warning
            )
            return
        }
    }

    private func nearestExistingDirectory(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while candidate.pathComponents.count > 1 {
            if FileSystemItemPolicy.isNonSymlinkDirectory(candidate) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true)
    }

    private func requestSteamStorageHealthRefresh() {
        steamStorageHealthRefreshGeneration += 1
    }

    @MainActor
    private func refreshSteamStorageHealth(taskID: String) async {
        let snapshots = displayedSteamStorageMounts.map(SteamStorageMountSnapshot.init(record:))
        guard !snapshots.isEmpty else {
            steamStorageHealthReports = [:]
            steamStorageHealthErrorMessage = nil
            isCheckingSteamStorageHealth = false
            return
        }

        isCheckingSteamStorageHealth = true
        steamStorageHealthErrorMessage = nil
        defer {
            if taskID == steamStorageHealthTaskID {
                isCheckingSteamStorageHealth = false
            }
        }

        do {
            let reports = try await SteamStorageHealthService().diagnose(
                snapshots,
                requiresSecurityScope: ForgePlaySandboxPolicy.isAppSandboxEnabled
            )
            guard !Task.isCancelled, taskID == steamStorageHealthTaskID else { return }
            steamStorageHealthReports = Dictionary(
                uniqueKeysWithValues: reports.map { ($0.mountID, $0) }
            )
        } catch is CancellationError {
            return
        } catch {
            guard taskID == steamStorageHealthTaskID else { return }
            steamStorageHealthErrorMessage = appState.localizedFormat(
                "저장공간 상태 확인을 완료하지 못했습니다: %@",
                appState.localizedError(error)
            )
        }
    }

    private func refreshSteamReferences(
        extraRoots: [URL],
        libraryBookmarksByPath: [String: Data] = [:]
    ) {
        guard appState.steamStorageOperationMountID == nil else {
            appState.setNotice(
                appState.localized("Steam 저장공간 연결 작업이 진행 중입니다. 완료된 뒤 다시 시도하세요."),
                kind: .warning
            )
            return
        }
        guard let refreshToken = services.beginSteamReferenceRefresh() else {
            let message = services.isSteamReferenceRefreshInProgress
                ? "Steam 참고 목록 새로고침이 이미 진행 중입니다."
                : "다른 Steam 프리픽스 작업이 이미 진행 중입니다. 완료된 뒤 다시 시도하세요."
            appState.setNotice(appState.localized(message), kind: .warning)
            return
        }
        let taskNoticeID = appState.setTask(
            appState.localized("Steam 라이브러리 참고 목록을 찾는 중입니다.")
        )?.id
        Task {
            defer { services.endSteamReferenceRefresh(refreshToken) }
            do {
                let storageAccess = try appState.restorePersistedSteamStorageAccess(
                    in: modelContext
                )
                let scanResult = try await services.steamManager.scanInstalledGamesResultInBackground(
                    extraLibraryRoots: storageAccess.roots + extraRoots
                )
                guard services.isCurrentSteamReferenceRefresh(refreshToken) else {
                    if let taskNoticeID { appState.clearNotice(id: taskNoticeID) }
                    return
                }
                let removesStaleRecords = scanResult.allowsRemovingStaleReferences(
                    whenStorageAccessIsComplete: storageAccess.allowsRemovingStaleReferences
                )
                _ = try modelContext.reconcileSteamGameReferences(
                    scanResult.games,
                    libraryBookmarksByPath: libraryBookmarksByPath,
                    removesStaleRecords: removesStaleRecords
                )
                try modelContext.saveOrRollback()
                services.synchronizeSetupWorkflow(
                    appState: appState,
                    hasSteamReferences: scanResult.hasReferencesAfterScan(
                        existingCount: storageAccess.sourceGameRecordCount,
                        whenStorageAccessIsComplete: storageAccess.allowsRemovingStaleReferences
                    ),
                    launchRecords: launchRecords
                )
                let hasAccessWarning = storageAccess.unavailableCount > 0 ||
                    storageAccess.bookmarkPersistenceFailed ||
                    !scanResult.isComplete
                let noticeKind: AppNoticeKind = scanResult.games.isEmpty || hasAccessWarning ? .warning : .success
                let notice = appState.setNotice(
                    steamReferenceRefreshNotice(
                        scannedCount: scanResult.games.count,
                        storageAccess: storageAccess,
                        skippedInputCount: scanResult.skippedInputCount
                    ),
                    kind: noticeKind
                )
                if noticeKind == .success {
                    clearTaskLater(notice.id)
                }
            } catch {
                guard services.isCurrentSteamReferenceRefresh(refreshToken) else {
                    if let taskNoticeID { appState.clearNotice(id: taskNoticeID) }
                    return
                }
                appState.setError(error)
            }
        }
    }

    private func steamReferenceRefreshNotice(
        scannedCount: Int,
        storageAccess: SteamLibraryAccessRestoration,
        skippedInputCount: Int
    ) -> String {
        let summary = appState.localizedFormat("%d개 Steam 참고 기록을 찾았습니다.", scannedCount)
        var warning: String?
        if storageAccess.unavailableCount > 0 || storageAccess.bookmarkPersistenceFailed {
            warning = appState.localizedFormat(
                "%d개 Steam 저장공간 접근 권한을 복원하지 못했습니다. 해당 폴더를 다시 연결하세요.",
                storageAccess.unavailableCount
            )
        }
        if skippedInputCount > 0 {
            warning = DiagnosticWarningText.combined(
                warning,
                appState.localizedFormat(
                    "Steam 라이브러리 입력 %d개를 안전하게 읽지 못해 기존 참고 기록을 유지했습니다.",
                    skippedInputCount
                )
            )
        }
        return DiagnosticWarningText.combined(summary, warning) ?? summary
    }

    private func requestSteamPrefixRebuild() {
        if let blocker = steamPrefixRebuildBlocker {
            appState.setNotice(blocker, kind: .warning)
            return
        }
        steamInstallerPersistenceWarningForRebuild = nil
        guard ensureSteamInstallerForRebuild() != nil else {
            return
        }
        isShowingSteamPrefixRebuildConfirmation = true
    }

    private func ensureSteamInstallerForRebuild() -> URL? {
        if let installer = appState.steamInstallerURL,
           services.validateSteamInstaller(installer) {
            return installer
        }
        guard let installer = OpenPanelPresenter.chooseFile(
            title: appState.localized("SteamSetup.exe 선택"),
            message: appState.localized("Steam 공식 페이지에서 받은 Windows용 설치 파일인 SteamSetup.exe를 선택하세요."),
            prompt: appState.localized("선택"),
            allowedExtensions: ["exe"]
        ) else {
            return nil
        }
        guard services.validateSteamInstaller(installer) else {
            appState.setNotice(appState.localized("SteamSetup.exe 파일을 선택해야 합니다."), kind: .warning)
            return nil
        }
        appState.setPersistedFileSelection(installer, for: .steamInstaller)
        if let warning = appState.saveWarning(to: modelContext) {
            steamInstallerPersistenceWarningForRebuild = warning
            appState.setNotice(warning, kind: .warning)
        }
        return installer
    }

    private func rebuildSteamPrefixAndInstallSteam() {
        guard !isRebuildingSteamPrefix else { return }
        if let blocker = steamPrefixRebuildBlocker {
            appState.setNotice(blocker, kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        guard let installer = ensureSteamInstallerForRebuild() else {
            return
        }

        isRebuildingSteamPrefix = true
        appState.setTask(appState.localized("Steam 프리픽스를 삭제하고 다시 설치하는 중입니다."))
        Task {
            defer { isRebuildingSteamPrefix = false }
            do {
                let rebuild = try await services.rebuildSteamSharedPrefix(
                    runtimeExecutable: runtimeExecutable,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let prefixPersistenceWarning = savePrefixRecordWarning(metadata: rebuild.metadata)
                let rollbackCleanupWarning = rebuild.localizedPreviousEnvironmentCleanupWarning(appState: appState)
                refreshSetupReadiness()

                let installResult = try await services.installSteamInSteamPrefix(
                    runtimeExecutable: runtimeExecutable,
                    installer: installer,
                    videoMemorySelection: appState.steamVideoMemorySelection,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let result = installResult.processResult
                _ = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )

                if installResult.installationVerified {
                    let message = DiagnosticWarningText.combined(
                        appState.localized("Steam 프리픽스를 새로 만들고 Windows용 Steam을 다시 설치했습니다."),
                        steamInstallerPersistenceWarningForRebuild,
                        prefixPersistenceWarning,
                        rollbackCleanupWarning,
                        installResult.compatibilityPreparationWarning.map {
                            appState.localizedFormat("Steam 실행 경로 자동 준비는 완료하지 못했습니다. 첫 Steam 실행에서 다시 시도합니다: %@", $0)
                        }
                    ) ?? appState.localized("Steam 프리픽스를 새로 만들고 Windows용 Steam을 다시 설치했습니다.")
                    let notice = appState.setNotice(
                        message,
                        kind: steamInstallerPersistenceWarningForRebuild == nil &&
                            prefixPersistenceWarning == nil &&
                            rollbackCleanupWarning == nil &&
                            installResult.compatibilityPreparationWarning == nil ? .success : .warning,
                        logURL: result.stdoutLog
                    )
                    clearTaskLater(notice.id)
                } else {
                    presentSteamGuidance(
                        for: result,
                        prefixPersistenceWarning: prefixPersistenceWarning
                    )
                    appState.setNotice(
                        appState.localizedFormat("Steam 재설치에 실패했습니다. 로그를 확인하세요: %@", result.stderrLog.path),
                        kind: .failure,
                        logURL: result.stderrLog,
                        diagnosticProcessResult: result
                    )
                }
            } catch {
                if let result = processRunResult(from: error) {
                    presentSteamGuidance(for: result)
                }
                appState.setError(error)
            }
        }
    }

    private func launchSteam(
        rendererPolicySelection: SteamRendererPolicySelection?,
        gameModePolicy: SteamGameModeLaunchPolicy
    ) {
        guard let rendererPolicySelection else {
            appState.setNotice(
                appState.localized("이번 Steam 실행에 사용할 그래픽 백엔드를 직접 선택하세요."),
                kind: .warning
            )
            return
        }
        guard !appState.isSteamLaunchInProgress else {
            appState.setNotice(appState.localized("Steam 실행이 이미 진행 중입니다."), kind: .warning)
            return
        }
        guard appState.steamStorageOperationMountID == nil else {
            appState.setNotice(
                appState.localized("Steam 저장공간 연결 작업이 진행 중입니다. 완료된 뒤 다시 시도하세요."),
                kind: .warning
            )
            return
        }
        guard !services.steamPrefixLifecycleCoordinator.isBusy else {
            appState.setNotice(
                appState.localized("다른 Steam 프리픽스 작업이 이미 진행 중입니다. 완료된 뒤 다시 시도하세요."),
                kind: .warning
            )
            return
        }
        if let blocker = steamLaunchBlocker {
            appState.setNotice(blocker, kind: .warning)
            return
        }
        if let blocker = selectedRendererLaunchBlocker {
            appState.setNotice(blocker, kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        activeSteamSessionConfiguration = nil
        selectedRendererForNextSteamLaunch = nil
        isExperimentalGameModeEnabledForNextLaunch = false
        appState.isSteamLaunchInProgress = true
        appState.setTask(appState.localized("Windows용 Steam을 실행하는 중입니다."))
        let selectedGameContext = appState.selectedSteamReference.map {
            DiagnosticEnvironmentSnapshotCollector.captureLaunchSelectedGameContext($0.game)
        }
        Task {
            defer { appState.isSteamLaunchInProgress = false }
            var launchRecord: LaunchRecord?
            do {
                let libraryAccess = try appState.restorePersistedSteamStorageAccess(
                    in: modelContext
                )
                let launch = try await services.steamPrefixService.launchSteam(
                    runtimeExecutable: runtimeExecutable,
                    rendererPolicySelection: rendererPolicySelection,
                    gameModePolicy: gameModePolicy,
                    videoMemorySelection: appState.steamVideoMemorySelection,
                    synchronizationSelection: appState.wineSynchronizationSelection,
                    libraryRoots: libraryAccess.roots,
                    reservedLibraryRoots: libraryAccess.driveReservationRoots,
                    prepareLaunch: {
                        let environmentGenerationID = try services.currentSteamEnvironmentGenerationID()
                        let record = try modelContext.createSteamLaunchRecord(
                            appSessionID: services.appSessionID,
                            environmentGenerationID: environmentGenerationID,
                            selectedGameContext: selectedGameContext
                        )
                        launchRecord = record
                        return record
                    }
                )
                let result = launch.processResult
                let record = launch.context
                let launchPersistenceWarning = steamLaunchRecordLifecycle.saveLaunchResult(result, launchRecord: record)
                let processUserFacingWarning =
                    result.userFacingWarningLocalizationKey.map(appState.localized)
                let gameModeVerificationWarning =
                    gameModePolicy == .experimentalRequiredHost
                    ? appState.localized(
                        "현재 Steam 세션은 Game Mode(베타) 켬으로 시작했습니다. Steam에서 실행하는 게임 프로세스에 호스트를 적용하며, 전체 화면 실행 중 macOS 메뉴 막대에서 활성 상태를 확인할 수 있습니다."
                    )
                    : nil
                refreshSetupReadiness()
                if result.succeeded {
                    activeSteamSessionConfiguration = ActiveSteamSessionConfiguration(
                        rendererSelection: rendererPolicySelection,
                        gameModePolicy: gameModePolicy
                    )
                    let message = result.steamUIStartupRecoveryAttemptCount > 0
                        ? appState.localized("Steam UI 초기화 실패를 자동으로 복구하고 Windows용 Steam을 다시 시작했습니다. 로그인 또는 라이브러리 화면을 확인하세요.")
                        : appState.localized("Windows용 Steam 프로세스를 시작했습니다. Steam 창에서 로그인 또는 라이브러리 화면이 보이는지 확인하세요.")
                    let notice = appState.setNotice(
                        DiagnosticWarningText.combined(
                            message,
                            libraryAccess.unavailableCount > 0
                                ? appState.localizedFormat(
                                    "%d개 Steam 저장공간 접근 권한을 복원하지 못해 이번 Steam 실행에서 제외했습니다. 해당 폴더를 다시 연결하세요.",
                                    libraryAccess.unavailableCount
                                )
                                : nil,
                            processUserFacingWarning,
                            gameModeVerificationWarning,
                            launchPersistenceWarning
                        ) ?? message,
                        kind: .warning,
                        logURL: result.preferredDiagnosticLog
                    )
                    if libraryAccess.unavailableCount == 0 &&
                        processUserFacingWarning == nil &&
                        gameModeVerificationWarning == nil &&
                        launchPersistenceWarning == nil {
                        clearTaskLater(notice.id)
                    }
                } else if result.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
                    activeSteamSessionConfiguration = ActiveSteamSessionConfiguration(
                        rendererSelection: rendererPolicySelection,
                        gameModePolicy: gameModePolicy
                    )
                    let message = appState.localized("Windows용 Steam 업데이트가 진행 중입니다. ForgePlay가 Steam을 종료하지 않았습니다. 업데이트가 끝나면 같은 화면에서 Steam UI 렌더링을 확인하세요.")
                    let notice = appState.setNotice(
                        DiagnosticWarningText.combined(
                            message,
                            processUserFacingWarning,
                            gameModeVerificationWarning,
                            launchPersistenceWarning
                        ) ?? message,
                        kind: .warning,
                        logURL: result.preferredDiagnosticLog
                    )
                    if processUserFacingWarning == nil &&
                        gameModeVerificationWarning == nil &&
                        launchPersistenceWarning == nil {
                        clearTaskLater(notice.id)
                    }
                } else if result.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode {
                    let message = appState.localized("Windows용 Steam 실행 명령은 전달됐지만 실제 프로세스 실행 증거를 확인하지 못했습니다. Steam 창을 직접 확인해야 하며, 검은 화면이면 성공으로 보지 않습니다.")
                    let notice = appState.setNotice(
                        DiagnosticWarningText.combined(
                            message,
                            processUserFacingWarning,
                            gameModeVerificationWarning,
                            launchPersistenceWarning
                        ) ?? message,
                        kind: .warning,
                        logURL: result.preferredDiagnosticLog
                    )
                    if processUserFacingWarning == nil &&
                        gameModeVerificationWarning == nil &&
                        launchPersistenceWarning == nil {
                        clearTaskLater(notice.id)
                    }
                } else {
                    presentSteamGuidance(
                        for: result,
                        launchPersistenceWarning: launchPersistenceWarning,
                        launchRecordId: record.id,
                        gameId: record.gameId
                    )
                    appState.setNotice(
                        appState.localizedFormat("Steam 실행에 실패했습니다. 로그를 확인하세요: %@", result.preferredDiagnosticLog.path),
                        kind: .failure,
                        logURL: result.preferredDiagnosticLog,
                        diagnosticProcessResult: result
                    )
                }
            } catch {
                activeSteamSessionConfiguration = nil
                if let result = processRunResult(from: error) {
                    presentSteamGuidance(
                        for: result,
                        launchRecordId: launchRecord?.id,
                        gameId: launchRecord?.gameId ?? selectedGameContext?.steamAppID
                    )
                }
                steamLaunchRecordLifecycle.handleLaunchFailure(
                    launchRecord,
                    error: error,
                    surfaceIdentifier: "steam-launch"
                )
            }
        }
    }

    private func removeSteamStorageMount(_ mount: SteamStorageMountRecord) {
        services.invalidateSteamReferenceRefresh()
        do {
            try appState.disconnectSteamStorageMount(mount, in: modelContext)
            steamStorageHealthReports.removeValue(forKey: mount.id)
            steamStorageHealthRefreshGeneration += 1
            appState.setNotice(
                appState.localized("Steam 저장공간 연결을 해제했습니다. 실행 중인 Steam에는 다음 실행부터 반영됩니다."),
                kind: .success
            )
        } catch {
            appState.setError(error)
        }
    }

    private func refreshSetupReadiness() {
        services.synchronizeSetupWorkflow(
            appState: appState,
            hasSteamReferences: !games.isEmpty,
            launchRecords: launchRecords
        )
    }

    private func savePrefixRecordWarning(metadata: PrefixMetadata) -> String? {
        do {
            try PrefixRecord.upsert(metadata: metadata, in: modelContext)
            try modelContext.saveOrRollback()
            return nil
        } catch {
            modelContext.rollback()
            return appState.localizedFormat(
                "Steam 프리픽스는 준비됐지만 기록을 저장하지 못했습니다: %@",
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private var steamLaunchRecordLifecycle: SteamLaunchRecordLifecycle {
        SteamLaunchRecordLifecycle(modelContext: modelContext, appState: appState, services: services)
    }

    private func confirmSteamUISurface(_ launchRecord: LaunchRecord, surface: SteamUISurface) {
        if let notice = steamLaunchRecordLifecycle.confirmSteamUISurface(
            surface,
            launchRecord: launchRecord
        ) {
            clearTaskLater(notice.id)
        }
        refreshSetupReadiness()
    }

    private func markSteamUIBlackScreen(_ launchRecord: LaunchRecord) {
        if let notice = steamLaunchRecordLifecycle.markSteamUIBlackScreen(launchRecord) {
            clearTaskLater(notice.id)
        }
        refreshSetupReadiness()
    }

    private func presentSteamGuidance(
        for result: ProcessRunResult,
        prefixPersistenceWarning: String? = nil,
        launchPersistenceWarning: String? = nil,
        launchRecordId: String? = nil,
        gameId: String? = nil
    ) {
        let logSnapshot = LogTextReader.tolerantDiagnosticSnapshot(from: result.diagnosticSourceLogs)
        let diagnostics = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: services.ruleEngine,
            logText: logSnapshot.text,
            context: .setupOrInstaller,
            language: appState.effectiveLanguageMode,
            fallbackReason: appState.localized("Steam 실행 단계에서 실패했습니다. 로그를 열어 마지막 오류를 확인하고, Steam 프리픽스와 ForgePlay Runtime 상태를 다시 점검하세요.")
        )
        let diagnosticPersistenceWarning = saveDiagnosticRecords(
            diagnostics,
            launchRecordId: launchRecordId,
            gameId: gameId ?? appState.selectedSteamReference?.steamAppId
        )
        appState.presentDiagnosticGuide(
            title: "Steam",
            diagnostics: diagnostics,
            logURL: result.preferredDiagnosticLog,
            persistenceWarning: DiagnosticWarningText.combined(
                logSnapshot.readError.map { appState.localizedError($0) },
                prefixPersistenceWarning,
                launchPersistenceWarning,
                diagnosticPersistenceWarning
            )
        )
    }

    private func saveDiagnosticRecords(
        _ diagnostics: [DiagnosticResult],
        launchRecordId: String?,
        gameId: String? = nil
    ) -> String? {
        do {
            try modelContext.saveDiagnosticRecords(
                diagnostics,
                gameId: gameId,
                launchRecordId: launchRecordId
            )
            return nil
        } catch {
            modelContext.rollback()
            return appState.localizedFormat("진단 결과를 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
        }
    }

    private func processRunResult(from error: Error) -> ProcessRunResult? {
        diagnosticProcessRunResult(from: error)
    }

    private func removeSteamReferenceRecord(_ game: SteamGameRecord) {
        services.invalidateSteamReferenceRefresh()
        let removedName = game.name
        let shouldClearSelection = appState.selectedSteamReference?.steamAppId == game.steamAppId
        do {
            modelContext.delete(game)
            try modelContext.saveOrRollback()
            if shouldClearSelection {
                appState.selectedSteamReference = nil
            }
            let notice = appState.setNotice(
                appState.localizedFormat("%@을 참고 목록에서 제거했습니다.", removedName),
                kind: .success
            )
            clearTaskLater(notice.id)
            refreshSetupReadiness()
        } catch {
            appState.setError(error)
        }
    }

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}

private struct LibraryActionButton: View {
    var title: String
    var detail: String
    var systemImage: String
    var isDisabled = false
    var action: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    actionIcon(palette: palette)
                    actionText(palette: palette)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    chevron(palette: palette)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        actionIcon(palette: palette)
                        chevron(palette: palette)
                    }
                    actionText(palette: palette)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ForgeActionButtonStyle(cornerRadius: 8))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
    }

    private func actionIcon(palette: ForgePlayPalette) -> some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(palette.primary)
            .frame(width: 26, alignment: .center)
    }

    private func chevron(palette: ForgePlayPalette) -> some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
    }

    private func actionText(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appState.localized(title))
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localized(detail))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension SteamGameRecord {
    var isDebugLayoutFixture: Bool {
        #if DEBUG
        steamAppId.hasPrefix(Self.debugLayoutFixtureAppIdPrefix) ||
        Self.debugAppStoreScreenshotFixtureAppIds.contains(steamAppId)
        #else
        false
        #endif
    }
}

#if DEBUG
private extension SteamGameRecord {
    static let debugLayoutFixtureAppIdPrefix = "debug-layout-"
    static let debugAppStoreScreenshotFixtureAppIds: Set<String> = ["990001", "990002"]

    static func debugLayoutFixtureRecords() -> [SteamGameRecord] {
        [
            SteamGameRecord(
                steamAppId: "\(debugLayoutFixtureAppIdPrefix)long-name",
                name: "The Extremely Long Windows Game Title: Definitive Compatibility Validation Edition",
                installDir: "The Extremely Long Windows Game Title Definitive Compatibility Validation Edition",
                libraryPath: "/Volumes/External Storage/SteamLibrary With A Very Long Folder Name/steamapps/common/The Extremely Long Windows Game Title Definitive Compatibility Validation Edition",
                manifestPath: "/Volumes/External Storage/SteamLibrary With A Very Long Folder Name/steamapps/appmanifest_990001.acf",
                sizeOnDisk: 184_392_847_360,
                lastUpdated: Date(timeIntervalSince1970: 1_782_000_000),
                lastLaunchStatus: "failed"
            ),
            SteamGameRecord(
                steamAppId: "\(debugLayoutFixtureAppIdPrefix)portable-copy",
                name: "Portable Copy With Offline Runtime Requirements And Long Localized Status",
                installDir: "Portable Copy With Offline Runtime Requirements",
                libraryPath: "/Users/Shared/ForgePlay Layout Fixture/Managed Steam Libraries/Portable Copy With Offline Runtime Requirements",
                manifestPath: "/Users/Shared/ForgePlay Layout Fixture/Managed Steam Libraries/appmanifest_990002.acf",
                sizeOnDisk: 42_949_672_960,
                lastUpdated: Date(timeIntervalSince1970: 1_783_000_000),
                lastLaunchStatus: "neverLaunched"
            )
        ]
    }

    static func debugAppStoreScreenshotFixtureRecords() -> [SteamGameRecord] {
        [
            SteamGameRecord(
                steamAppId: "990001",
                name: "Nebula Rally",
                installDir: "Nebula Rally",
                libraryPath: "/Sample Games/SteamLibrary/steamapps/common/Nebula Rally",
                manifestPath: "/Sample Games/SteamLibrary/steamapps/appmanifest_990001.acf",
                sizeOnDisk: 68_719_476_736,
                lastUpdated: Date(timeIntervalSince1970: 1_782_000_000),
                lastLaunchStatus: "finished"
            ),
            SteamGameRecord(
                steamAppId: "990002",
                name: "Iron Orchard",
                installDir: "Iron Orchard",
                libraryPath: "/Sample Games/SteamLibrary/steamapps/common/Iron Orchard",
                manifestPath: "/Sample Games/SteamLibrary/steamapps/appmanifest_990002.acf",
                sizeOnDisk: 31_457_280_000,
                lastUpdated: Date(timeIntervalSince1970: 1_783_000_000),
                lastLaunchStatus: "neverLaunched"
            )
        ]
    }

    var debugLayoutExecutableCandidates: [URL] {
        let gameRoot = URL(fileURLWithPath: libraryPath)
        return [
            gameRoot.appending(path: "Binaries/Win64/ForgePlayCompatibilityValidation-Win64-Shipping.exe"),
            gameRoot.appending(path: "Launcher/VeryLongLauncherExecutableNameForLayoutVerification.exe")
        ]
    }

    var debugLayoutCompatibilityRecipe: CompatibilityRecipe {
        CompatibilityRecipe(
            id: steamAppId.hasPrefix(Self.debugLayoutFixtureAppIdPrefix) ? "debug-layout-\(steamAppId)" : "sample-\(steamAppId)",
            steamAppId: steamAppId,
            name: name,
            supportStatus: CompatibilitySupportStatus.partial.rawValue,
            beginnerSummary: "Steam 실행 화면에서 Windows용 Steam을 열고, 게임 렌더러 payload 선택과 Steam 라이브러리 참고 목록을 확인할 수 있습니다.",
            technicalSummary: steamAppId.hasPrefix(Self.debugLayoutFixtureAppIdPrefix)
                ? "Debug-only game library layout fixture."
                : "Sample compatibility guidance for App Store screenshots.",
            confidence: 0.78,
            requiredRuntimes: steamAppId.hasPrefix(Self.debugLayoutFixtureAppIdPrefix)
                ? [.vcrun2022, .d3dx9, .dotnet48, .openal]
                : [.vcrun2022, .d3dx9],
            launchOptions: ["-windowed", "-nolauncher"],
            notes: [
                "외장 드라이브의 루트나 원하는 폴더를 선택해 Steam 실행 전에 Windows 드라이브로 연결할 수 있습니다.",
                "Steam 로그인 후 Steam 참고 목록을 새로고침하거나, 외장 저장공간에 이미 설치된 Steam 라이브러리를 연결하세요."
            ],
            lastVerifiedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )
    }
}
#endif
